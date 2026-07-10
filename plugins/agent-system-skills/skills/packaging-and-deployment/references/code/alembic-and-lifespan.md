# 完整源码：alembic bootstrap + engine + env.py + Gateway lifespan

> 本文件给出数据库迁移自洽与启动期生命周期的**完整真实源码**：`bootstrap.py`（三分支 state machine + 跨进程锁）、`engine.py`（`init_engine` -> `bootstrap_schema`）、`migrations/env.py`（alembic env，SQLite busy_timeout 镜像）、`alembic.ini`、`gateway/gateway/app.py` 的 `lifespan` + `create_app`、`gateway/gateway/deps.py` 的 `langgraph_runtime`（启动期 bootstrap 编排）。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`、env 前缀 `HELIX_*`），去除一切项目字样。原代码注释保留以保真。

## 1. core/helix/persistence/bootstrap.py（三分支 schema bootstrap）

`bootstrap_schema(engine, *, backend)` 在 Gateway lifespan 启动期跑。三分支：empty（空库 `create_all` + stamp head）、legacy（老库 baseline backfill + stamp baseline + upgrade head）、versioned（`alembic upgrade head`）。`_BASELINE_TABLE_NAMES` frozenset 限制 legacy 分支的 `create_all` 范围，防 pre-empt 后续 revision 的 `op.create_table`。Postgres 用 `pg_advisory_lock` 真跨进程串行；SQLite 用 per-engine `asyncio.Lock`（`WeakKeyDictionary` 防 id 复用）+ 文件锁 best-effort。Postgres 额外 `SET LOCAL idle_in_transaction_session_timeout = 0` 防 managed PG 杀 idle-in-txn 释放锁。

```python
# core/helix/persistence/bootstrap.py
"""Hybrid schema bootstrap for the framework's application tables.

Replaces the unconditional ``Base.metadata.create_all`` at Gateway startup.
Combines two ideas:

1. ``create_all`` stays the empty-DB fast path -- it renders ``Base.metadata``
   faithfully across SQLite and Postgres dialects (JSON vs JSONB, server
   defaults, index/FK names, type affinity) without anyone having to hand-keep
   a mirror baseline in sync with the models.
2. **Alembic owns every change from baseline onward.** Any new ORM column /
   table / index must ship as a revision under ``migrations/versions/``.

Three-branch decision (see ``_decide_state``)
---------------------------------------------

| DB state                              | Action                                  |
|---------------------------------------|-----------------------------------------|
| empty (no framework tables)           | ``create_all`` + ``alembic stamp head`` |
| legacy (framework tables, no alembic) | ``create_all`` (baseline tables only, as backfill) + ``stamp 0001_baseline`` + ``upgrade head`` |
| versioned (``alembic_version`` row)   | ``alembic upgrade head``                |

The legacy branch handles pre-alembic databases that already have at least one
framework-owned table. ``create_all`` runs first because stamping at
``0001_baseline`` makes alembic skip the baseline's own ``create_table`` DDL on
the subsequent upgrade -- so any baseline table introduced into
``Base.metadata`` after the user's DB was first provisioned would otherwise
never be created, and the first request hitting that table would 500 with
``no such table``. The backfill is **restricted to ``_BASELINE_TABLE_NAMES``**
so it does not also create tables that future revisions introduce -- those
revisions' own ``op.create_table`` would then fail with ``relation already
exists``. A guard test pins the restriction set against ``0001_baseline.upgrade()``'s
actual output.

Concurrency safety
------------------

Layered, with different guarantees per backend. Postgres has true
cross-process serialisation. SQLite is single-process safe and cross-process
best-effort; multi-instance deployments should use Postgres.

* **Postgres -- true cross-process serialisation.** ``pg_advisory_lock`` runs
  the whole reflect-and-act sequence under an exclusive lock that survives
  cross-process. Concurrent Gateway instances queue cleanly and the second
  one observes head as a no-op.

* **SQLite -- single-process serialisation, best-effort cross-process.**
  A per-engine ``asyncio.Lock`` serialises those. For the rare cross-process
  case, we rely on SQLite's own file-level write lock plus a 30s
  ``PRAGMA busy_timeout``.

* **Idempotent revisions -- retry fallback.** Column revisions use the helpers
  in ``migrations/_helpers.py`` so repeated post-baseline changes, manual
  ALTERs, or retries after SQLite lock contention do not duplicate work.

``alembic upgrade head`` on a DB already at head is a no-op by alembic's own
semantics, so the second-N-th actor simply observes head and exits.
"""

from __future__ import annotations

import asyncio
import logging
import weakref
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from alembic import command as alembic_command
from alembic.config import Config as AlembicConfig
from alembic.script import ScriptDirectory
from sqlalchemy import inspect as sa_inspect
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

logger = logging.getLogger(__name__)


# Where the alembic environment lives, relative to this file.
_MIGRATIONS_DIR = Path(__file__).resolve().parent / "migrations"

# Cached migration head, computed once per process from the disk script tree.
_HEAD_REVISION: str | None = None

# Baseline (stamp target for legacy DBs). Pinned here so the bootstrap layer
# fails loudly if the baseline revision is ever renamed without updating the
# stamp call.
_BASELINE_REVISION = "0001_baseline"

# Stable advisory-lock key for Postgres. Two random 32-bit halves picked once
# so we never collide with any other application's advisory locks. Do not
# change without coordinating a one-time migration (a key change effectively
# releases the prior lock).
_PG_LOCK_KEY = 0x0DEE_12F1_0BEE_3682


# Tables created by ``0001_baseline.upgrade()``. The legacy branch restricts
# its ``create_all`` backfill to this set so it does NOT pre-empt later
# ``op.create_table`` revisions for models added after baseline.
_BASELINE_TABLE_NAMES: frozenset[str] = frozenset(
    {
        "channel_connections",
        "channel_conversations",
        "channel_credentials",
        "channel_oauth_states",
        "feedback",
        "run_events",
        "runs",
        "threads_meta",
        "users",
    }
)


# Per-engine SQLite bootstrap locks. Per-engine (not module-global) so each
# engine instance pairs with a lock bound to the event loop that uses that
# engine. Production uses one engine per process so this dict collapses to a
# single entry in practice. Keyed by the engine object itself via
# ``WeakKeyDictionary`` rather than ``id(engine)``: CPython recycles addresses
# after GC, so a stale ``id`` -> ``Lock`` entry from a dead engine could be
# returned to a new engine that happened to land on the same address.
_SQLITE_LOCKS: weakref.WeakKeyDictionary[AsyncEngine, asyncio.Lock] = weakref.WeakKeyDictionary()


def _get_sqlite_local_lock(engine: AsyncEngine) -> asyncio.Lock:
    lock = _SQLITE_LOCKS.get(engine)
    if lock is None:
        lock = asyncio.Lock()
        _SQLITE_LOCKS[engine] = lock
    return lock


def _escape_url_for_alembic(url: str) -> str:
    """Double literal ``%`` so ``ConfigParser`` interpolation leaves the URL intact."""
    return url.replace("%", "%%")


def _alembic_safe_url(engine: AsyncEngine) -> str:
    """Render *engine*'s URL in a form alembic ``set_main_option`` accepts."""
    rendered = engine.url.render_as_string(hide_password=False)
    return _escape_url_for_alembic(rendered)


def _get_alembic_config(engine: AsyncEngine) -> AlembicConfig:
    """Build an in-process alembic config pointing at our migrations dir.

    Avoids reading ``alembic.ini`` from disk so the production runtime doesn't
    depend on a working-directory-relative file lookup.
    """
    cfg = AlembicConfig()
    cfg.set_main_option("script_location", str(_MIGRATIONS_DIR))
    cfg.set_main_option("sqlalchemy.url", _alembic_safe_url(engine))
    return cfg


def _get_head_revision() -> str:
    """Return the head revision id from ``versions/``, cached per process."""
    global _HEAD_REVISION
    if _HEAD_REVISION is None:
        cfg = AlembicConfig()
        cfg.set_main_option("script_location", str(_MIGRATIONS_DIR))
        script = ScriptDirectory.from_config(cfg)
        head = script.get_current_head()
        if head is None:
            raise RuntimeError("alembic has no head revision -- versions/ directory is empty")
        _HEAD_REVISION = head
    return _HEAD_REVISION


def _reflect_state(sync_conn: Any) -> dict[str, bool]:
    """Inspect *sync_conn* and return whether alembic version / framework tables exist."""
    from helix.persistence.base import Base

    try:
        import helix.persistence.models  # noqa: F401
    except ImportError:
        logger.debug("helix.persistence.models not found; metadata may be incomplete")

    insp = sa_inspect(sync_conn)
    reflected = set(insp.get_table_names())
    metadata_tables = set(Base.metadata.tables)
    return {
        "has_alembic_version": "alembic_version" in reflected,
        "has_framework_tables": bool(reflected & metadata_tables),
    }


def _decide_state(state: dict[str, bool]) -> str:
    """Map a reflected DB state to one of three branch labels."""
    if state["has_alembic_version"]:
        return "versioned"
    if not state["has_framework_tables"]:
        return "empty"
    return "legacy"


def _run_create_all_sync(sync_conn: Any) -> None:
    """Create all framework-owned tables on *sync_conn*."""
    from helix.persistence.base import Base

    try:
        import helix.persistence.models  # noqa: F401
    except ImportError:
        logger.debug("helix.persistence.models not found; bootstrap will create empty schema")

    Base.metadata.create_all(sync_conn)


def _run_baseline_create_all_sync(sync_conn: Any) -> None:
    """Create only the baseline tables on *sync_conn* (idempotent via checkfirst).

    Used by the legacy branch to backfill baseline-era tables missing from
    the user's DB. Restricting the table list to ``_BASELINE_TABLE_NAMES``
    is the safety property: an unrestricted ``create_all`` would also create
    tables introduced by later revisions, which would then collide with
    those revisions' ``op.create_table`` calls when alembic ran upgrade.
    """
    from helix.persistence.base import Base

    try:
        import helix.persistence.models  # noqa: F401
    except ImportError:
        logger.debug("helix.persistence.models not found; baseline backfill may be incomplete")

    baseline_tables = [Base.metadata.tables[name] for name in _BASELINE_TABLE_NAMES if name in Base.metadata.tables]
    Base.metadata.create_all(sync_conn, tables=baseline_tables, checkfirst=True)


def _stamp(cfg: AlembicConfig, revision: str) -> None:
    """Synchronous alembic stamp; callers must wrap in ``asyncio.to_thread``."""
    alembic_command.stamp(cfg, revision)


def _upgrade(cfg: AlembicConfig, revision: str) -> None:
    """Synchronous alembic upgrade; callers must wrap in ``asyncio.to_thread``."""
    alembic_command.upgrade(cfg, revision)


# ---------------------------------------------------------------------------
# Cross-process locking
# ---------------------------------------------------------------------------


@asynccontextmanager
async def _postgres_lock(engine: AsyncEngine):
    """Hold a Postgres session-level advisory lock for the body of the block.

    Session-level (not transaction-level) so the lock outlives implicit
    transactions opened by alembic during ``stamp`` / ``upgrade``.

    Idle-in-transaction protection: ``SET LOCAL idle_in_transaction_session_timeout = 0``
    disables the kill for this transaction only. Must execute *before*
    ``pg_advisory_lock`` so a slow lock acquire is itself protected.
    """
    async with engine.connect() as conn:
        await conn.execute(text("SET LOCAL idle_in_transaction_session_timeout = 0"))
        await conn.execute(text("SELECT pg_advisory_lock(:k)"), {"k": _PG_LOCK_KEY})
        try:
            logger.info("bootstrap: acquired postgres advisory lock key=0x%x", _PG_LOCK_KEY)
            yield
        finally:
            try:
                await conn.execute(text("SELECT pg_advisory_unlock(:k)"), {"k": _PG_LOCK_KEY})
            except Exception:  # noqa: BLE001
                logger.warning("bootstrap: pg_advisory_unlock raised; session close will release", exc_info=True)


@asynccontextmanager
async def _sqlite_lock(engine: AsyncEngine):
    """Serialise SQLite bootstrap inside one process; cross-process is
    best-effort via SQLite's own file lock + ``PRAGMA busy_timeout``.
    """
    async with _get_sqlite_local_lock(engine):
        logger.info("bootstrap: acquired sqlite in-process lock")
        yield


def _bootstrap_lock(engine: AsyncEngine, *, backend: str):
    if backend == "postgres":
        return _postgres_lock(engine)
    if backend == "sqlite":
        return _sqlite_lock(engine)
    raise ValueError(f"bootstrap: unsupported backend {backend!r}")


# ---------------------------------------------------------------------------
# Top-level entry point
# ---------------------------------------------------------------------------


async def bootstrap_schema(engine: AsyncEngine, *, backend: str) -> None:
    """Bring the DB schema to head.

    Postgres calls are serialised across processes with an advisory lock.
    SQLite calls are serialised inside one process and are best-effort across
    processes via SQLite's file lock and ``busy_timeout``.

    ``alembic.command.stamp`` and ``alembic.command.upgrade`` are synchronous
    and would block the event loop; both are wrapped in ``asyncio.to_thread``.
    """
    head = _get_head_revision()
    cfg = _get_alembic_config(engine)

    async with _bootstrap_lock(engine, backend=backend):
        async with engine.connect() as conn:
            state = await conn.run_sync(_reflect_state)
        decision = _decide_state(state)

        if decision == "empty":
            logger.info("bootstrap: branch=empty -> create_all + stamp head (%s)", head)
            async with engine.begin() as conn:
                await conn.run_sync(_run_create_all_sync)
            await asyncio.to_thread(_stamp, cfg, head)

        elif decision == "legacy":
            logger.info(
                "bootstrap: branch=legacy -> create_all (backfill missing baseline tables) + stamp %s + upgrade head (%s)",
                _BASELINE_REVISION,
                head,
            )
            async with engine.begin() as conn:
                await conn.run_sync(_run_baseline_create_all_sync)
            await asyncio.to_thread(_stamp, cfg, _BASELINE_REVISION)
            await asyncio.to_thread(_upgrade, cfg, "head")

        elif decision == "versioned":
            logger.info("bootstrap: branch=versioned -> upgrade head (%s)", head)
            await asyncio.to_thread(_upgrade, cfg, "head")

        else:  # pragma: no cover -- defensive
            raise RuntimeError(f"bootstrap: unhandled decision {decision!r}")

    logger.info("bootstrap: complete (backend=%s)", backend)
```

## 2. core/helix/persistence/engine.py（init_engine -> bootstrap_schema）

`init_engine` 建 async engine + session factory，然后调 `bootstrap_schema`。SQLite 每 connection 设 `PRAGMA journal_mode=WAL; synchronous=NORMAL; foreign_keys=ON; busy_timeout=30000`。Postgres "database does not exist" 时 `_auto_create_postgres_db` 连 maintenance DB 建库再重试。`backend == "memory"` 时 no-op，`get_session_factory()` 返回 None，repositories 回退内存实现。

```python
# core/helix/persistence/engine.py
"""Async SQLAlchemy engine lifecycle management.

Initializes at Gateway startup, provides session factory for
repositories, disposes at shutdown.

When database.backend="memory", init_engine is a no-op and
get_session_factory() returns None. Repositories must check for
None and fall back to in-memory implementations.
"""

from __future__ import annotations

import asyncio
import json
import logging

from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine


def _json_serializer(obj: object) -> str:
    """JSON serializer with ensure_ascii=False for Chinese character support."""
    return json.dumps(obj, ensure_ascii=False)


logger = logging.getLogger(__name__)

_engine: AsyncEngine | None = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


async def _auto_create_postgres_db(url: str) -> None:
    """Connect to the ``postgres`` maintenance DB and CREATE DATABASE.

    The target database name is extracted from *url*.  The connection is
    made to the default ``postgres`` database on the same server using
    ``AUTOCOMMIT`` isolation (CREATE DATABASE cannot run inside a
    transaction).
    """
    from sqlalchemy import text
    from sqlalchemy.engine.url import make_url

    parsed = make_url(url)
    db_name = parsed.database
    if not db_name:
        raise ValueError("Cannot auto-create database: no database name in URL")

    maint_url = parsed.set(database="postgres")
    maint_engine = create_async_engine(maint_url, isolation_level="AUTOCOMMIT")
    try:
        async with maint_engine.connect() as conn:
            await conn.execute(text(f'CREATE DATABASE "{db_name}"'))
        logger.info("Auto-created PostgreSQL database: %s", db_name)
    finally:
        await maint_engine.dispose()


async def init_engine(
    backend: str,
    *,
    url: str = "",
    echo: bool = False,
    pool_size: int = 5,
    sqlite_dir: str = "",
) -> None:
    """Create the async engine and session factory, then auto-create tables.

    Args:
        backend: "memory", "sqlite", or "postgres".
        url: SQLAlchemy async URL (for sqlite/postgres).
        echo: Echo SQL to log.
        pool_size: Postgres connection pool size.
        sqlite_dir: Directory to create for SQLite (ensured to exist).
    """
    global _engine, _session_factory

    if backend == "memory":
        logger.info("Persistence backend=memory -- ORM engine not initialized")
        return

    if backend == "postgres":
        try:
            import asyncpg  # noqa: F401
        except ImportError:
            raise ImportError(
                "database.backend is set to 'postgres' but asyncpg is not installed.\n"
                "Install it with:\n"
                "    cd backend && uv sync --all-packages --extra postgres\n"
                "Set UV_EXTRAS=postgres in .env to opt in explicitly. Or switch to\n"
                "backend: sqlite in config.yaml for single-node deployment."
            ) from None

    if backend == "sqlite":
        import os

        from sqlalchemy import event

        # Offload the directory creation: ``init_engine`` runs on the FastAPI
        # lifespan event loop, and a sync ``os.makedirs`` blocks it during startup.
        await asyncio.to_thread(os.makedirs, sqlite_dir or ".", exist_ok=True)
        _engine = create_async_engine(url, echo=echo, json_serializer=_json_serializer)

        # Enable WAL on every new connection. SQLite PRAGMA settings are
        # per-connection, so we wire the listener instead of running PRAGMA
        # once at startup. We also widen ``busy_timeout`` to 30s here. The
        # same widened timeout is mirrored on the alembic-spawned engine in
        # ``migrations/env.py::run_migrations_online`` so its connections
        # behave identically.
        @event.listens_for(_engine.sync_engine, "connect")
        def _enable_sqlite_wal(dbapi_conn, _record):  # noqa: ARG001 - SQLAlchemy contract
            cursor = dbapi_conn.cursor()
            try:
                cursor.execute("PRAGMA journal_mode=WAL;")
                cursor.execute("PRAGMA synchronous=NORMAL;")
                cursor.execute("PRAGMA foreign_keys=ON;")
                cursor.execute("PRAGMA busy_timeout=30000;")
            finally:
                cursor.close()
    elif backend == "postgres":
        _engine = create_async_engine(
            url,
            echo=echo,
            pool_size=pool_size,
            pool_pre_ping=True,
            json_serializer=_json_serializer,
        )
    else:
        raise ValueError(f"Unknown persistence backend: {backend!r}")

    _session_factory = async_sessionmaker(_engine, expire_on_commit=False)

    # Schema bootstrap (hybrid):
    #   - empty DB        -> create_all + alembic stamp head
    #   - legacy DB       -> create_all (baseline tables only, backfill) + alembic stamp baseline + upgrade head
    #   - already managed -> alembic upgrade head
    # Concurrency: Postgres advisory lock (true cross-process); SQLite uses an
    # in-process asyncio.Lock plus a 30s PRAGMA busy_timeout.
    from helix.persistence.bootstrap import bootstrap_schema

    try:
        await bootstrap_schema(_engine, backend=backend)
    except Exception as exc:
        if backend == "postgres" and "does not exist" in str(exc):
            # Database not yet created -- attempt to auto-create it, then retry.
            await _auto_create_postgres_db(url)
            # Rebuild engine against the now-existing database
            await _engine.dispose()
            _engine = create_async_engine(url, echo=echo, pool_size=pool_size, pool_pre_ping=True, json_serializer=_json_serializer)
            _session_factory = async_sessionmaker(_engine, expire_on_commit=False)
            await bootstrap_schema(_engine, backend=backend)
        else:
            raise

    logger.info("Persistence engine initialized: backend=%s", backend)


async def init_engine_from_config(config) -> None:
    """Convenience: init engine from a DatabaseConfig object."""
    if config.backend == "memory":
        await init_engine("memory")
        return
    await init_engine(
        backend=config.backend,
        url=config.app_sqlalchemy_url,
        echo=config.echo_sql,
        pool_size=config.pool_size,
        sqlite_dir=config.sqlite_dir if config.backend == "sqlite" else "",
    )


def get_session_factory() -> async_sessionmaker[AsyncSession] | None:
    """Return the async session factory, or None if backend=memory."""
    return _session_factory


def get_engine() -> AsyncEngine | None:
    """Return the async engine, or None if not initialized."""
    return _engine


async def close_engine() -> None:
    """Dispose the engine, release all connections."""
    global _engine, _session_factory
    if _engine is not None:
        await _engine.dispose()
        logger.info("Persistence engine closed")
    _engine = None
    _session_factory = None
```

## 3. core/helix/persistence/migrations/env.py（alembic env）

alembic 自己 spawn 的 engine 也 wire `PRAGMA busy_timeout=30000`，与生产 engine 行为一致。`include_object` 过滤 LangGraph 自管表（checkpoints / checkpoint_blobs / checkpoint_writes / checkpoint_migrations），这些表由 LangGraph 自管 schema 生命周期，alembic 不得 touch。`render_as_batch=True` 让 SQLite ALTER TABLE 支持（SQLite 原生 ALTER 能力有限，batch 模式建新表拷数据替换）。

```python
# core/helix/persistence/migrations/env.py
"""Alembic environment for the framework's application tables.

ONLY manages the framework's tables (runs, threads_meta, feedback, users,
run_events, channel_connections, channel_credentials, channel_oauth_states,
channel_conversations).

LangGraph's checkpointer tables (``checkpoints``, ``checkpoint_blobs``,
``checkpoint_writes``, ``checkpoint_migrations``) are managed by LangGraph
itself -- they have their own schema lifecycle and must not be touched by
Alembic. The ``include_object`` filter below explicitly excludes them so a
future ``alembic revision --autogenerate`` will not emit ``drop_table`` for
tables it does not own.
"""

from __future__ import annotations

import asyncio
import logging
from logging.config import fileConfig

from alembic import context
from sqlalchemy.ext.asyncio import create_async_engine

from helix.persistence.base import Base
from helix.persistence.migrations._env_filters import (
    LANGGRAPH_OWNED_TABLES,
    include_object,
)

__all__ = ["LANGGRAPH_OWNED_TABLES", "include_object"]

# Import all models so metadata is populated.
try:
    import helix.persistence.models as models  # register ORM models with Base.metadata

    _ = models
except ImportError:
    logging.getLogger(__name__).warning("Could not import helix.persistence.models; Alembic may not detect all tables")

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        render_as_batch=True,
        include_object=include_object,
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection):
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        render_as_batch=True,  # Required for SQLite ALTER TABLE support
        include_object=include_object,
    )
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    connectable = create_async_engine(config.get_main_option("sqlalchemy.url"))

    # Cross-process bootstrap safety for SQLite: every connection alembic
    # opens needs a wide ``busy_timeout`` so that when another process holds
    # the file write lock (e.g. mid-bootstrap), our writes wait instead of
    # raising ``database is locked``. alembic spawns its OWN engine here --
    # those connections wouldn't inherit anything unless we wire the same hook.
    if connectable.url.drivername.startswith("sqlite"):
        from sqlalchemy import event

        @event.listens_for(connectable.sync_engine, "connect")
        def _alembic_sqlite_busy_timeout(dbapi_conn, _record):  # noqa: ARG001
            cursor = dbapi_conn.cursor()
            try:
                cursor.execute("PRAGMA busy_timeout=30000;")
            finally:
                cursor.close()

    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
```

## 4. core/helix/persistence/migrations/alembic.ini

alembic 配置。`script_location = %(here)s` 锚定 migrations 目录。默认 URL 仅 offline / autogenerate 用；运行时用框架 config 的 engine（`bootstrap_schema` 在 `_get_alembic_config` 里 `set_main_option("sqlalchemy.url", ...)` 覆盖）。

```ini
# core/helix/persistence/migrations/alembic.ini
[alembic]
script_location = %(here)s
# Default URL for offline mode / autogenerate.
# Runtime uses engine from framework config.
sqlalchemy.url = sqlite+aiosqlite:///./data/helix.db

[loggers]
keys = root,sqlalchemy,alembic

[handlers]
keys = console

[formatters]
keys = generic

[logger_root]
level = WARN
handlers = console

[logger_sqlalchemy]
level = WARN
handlers =
qualname = sqlalchemy.engine

[logger_alembic]
level = INFO
handlers =
qualname = alembic

[handler_console]
class = StreamHandler
args = (sys.stderr,)
level = NOTSET
formatter = generic

[formatter_generic]
format = %(levelname)-5.5s [%(name)s] %(message)s
datefmt = %H:%M:%S
```

## 5. gateway/gateway/app.py（lifespan + create_app）

Gateway FastAPI 应用。`lifespan` 启动序：`get_app_config()` + `configure_logging` -> tiktoken 预热（5s timeout，`token_counting='char'` 时跳过）-> upload staging 清理 -> `async with langgraph_runtime(app, startup_config)`（内含 `init_engine_from_config` -> `bootstrap_schema`）-> `_ensure_admin_user` -> channel service / scheduled task service 启动。`create_app` 装中间件链（AuthMiddleware fail-closed -> CSRFMiddleware 双提交 cookie -> CORS allowlist -> TraceMiddleware），挂路由，`app = create_app()` 供 uvicorn 引用。

```python
# gateway/gateway/app.py
import asyncio
import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from gateway.gateway.auth_disabled import warn_if_auth_disabled_enabled
from gateway.gateway.auth_middleware import AuthMiddleware
from gateway.gateway.config import get_gateway_config
from gateway.gateway.csrf_middleware import CSRFMiddleware, get_configured_cors_origins
from gateway.gateway.deps import langgraph_runtime
from gateway.gateway.routers import (
    agents, artifacts, assistants_compat, auth, channel_connections, channels,
    console, features, feedback, github_webhooks, input_polish, mcp, memory,
    models, runs, scheduled_tasks, skills, suggestions, thread_runs, threads,
    uploads,
)
from gateway.gateway.trace_middleware import TraceMiddleware, resolve_trace_enabled
from helix.config import app_config as helix_app_config
from helix.logging_config import DEFAULT_LOG_DATE_FORMAT, DEFAULT_LOG_FORMAT, configure_logging
from helix.uploads.manager import cleanup_stale_upload_staging_files

AppConfig = helix_app_config.AppConfig
get_app_config = helix_app_config.get_app_config

logging.basicConfig(
    level=logging.INFO,
    format=DEFAULT_LOG_FORMAT,
    datefmt=DEFAULT_LOG_DATE_FORMAT,
)

logger = logging.getLogger(__name__)

# Upper bound (seconds) each lifespan shutdown hook is allowed to run.
_SHUTDOWN_HOOK_TIMEOUT_SECONDS = 5.0


async def _ensure_admin_user(app: FastAPI) -> None:
    """Startup hook: handle first boot and migrate orphan threads otherwise."""
    from sqlalchemy import select

    from gateway.gateway.deps import get_local_provider
    from helix.persistence.engine import get_session_factory
    from helix.persistence.user.model import UserRow

    try:
        provider = get_local_provider()
    except RuntimeError:
        logger.warning("Auth persistence not ready; skipping admin bootstrap check")
        return

    sf = get_session_factory()
    if sf is None:
        return

    admin_count = await provider.count_admin_users()

    if admin_count == 0:
        logger.info("=" * 60)
        logger.info("  First boot detected - no admin account exists.")
        logger.info("  Visit /setup to complete admin account creation.")
        logger.info("=" * 60)
        return

    async with sf() as session:
        stmt = select(UserRow).where(UserRow.system_role == "admin").limit(1)
        row = (await session.execute(stmt)).scalar_one_or_none()

    if row is None:
        return

    admin_id = str(row.id)

    store = getattr(app.state, "store", None)
    if store is not None:
        try:
            migrated = await _migrate_orphaned_threads(store, admin_id)
            if migrated:
                logger.info("Migrated %d orphan LangGraph thread(s) to admin", migrated)
        except Exception:
            logger.exception("LangGraph thread migration failed (non-fatal)")


async def _iter_store_items(store, namespace, *, page_size: int = 500):
    """Paginated async iterator over a LangGraph store namespace."""
    offset = 0
    while True:
        batch = await store.asearch(namespace, limit=page_size, offset=offset)
        if not batch:
            return
        for item in batch:
            yield item
        if len(batch) < page_size:
            return
        offset += page_size


async def _migrate_orphaned_threads(store, admin_user_id: str) -> int:
    """Migrate LangGraph store threads with no user_id to the given admin."""
    migrated = 0
    async for item in _iter_store_items(store, ("threads",)):
        metadata = item.value.get("metadata", {})
        if not metadata.get("user_id"):
            metadata["user_id"] = admin_user_id
            item.value["metadata"] = metadata
            await store.aput(("threads",), item.key, item.value)
            migrated += 1
    return migrated


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Application lifespan handler."""

    # Load config and check necessary environment variables at startup.
    # `startup_config` is a local snapshot used only for one-shot bootstrap
    # work. Request-time config resolution always routes through
    # `get_app_config()` so `config.yaml` edits become visible without a
    # process restart. We deliberately do NOT cache this snapshot on
    # `app.state` to keep that contract enforceable.
    try:
        startup_config = get_app_config()
        configure_logging(startup_config)
        logger.info("Configuration loaded successfully")
        warn_if_auth_disabled_enabled()
    except Exception as e:
        error_msg = f"Failed to load configuration during gateway startup: {e}"
        logger.exception(error_msg)
        raise RuntimeError(error_msg) from e
    config = get_gateway_config()
    logger.info(f"Starting API Gateway on {config.host}:{config.port}")

    # Pre-warm tiktoken encoding cache so the first memory-injection request
    # never blocks on the BPE data download. When memory.token_counting is
    # "char", token counting never touches tiktoken, so skip the warm-up.
    if startup_config.memory.token_counting == "char":
        logger.info("memory.token_counting='char'; skipping tiktoken warm-up (network-free token estimation)")
    else:
        try:
            from helix.agents.memory.prompt import warm_tiktoken_cache

            warmed = await asyncio.wait_for(
                asyncio.to_thread(warm_tiktoken_cache),
                timeout=5,
            )
            if warmed:
                logger.info("tiktoken encoding cache warmed successfully")
            else:
                logger.warning("tiktoken encoding cache warm-up failed; token counting will use character-based fallback until tiktoken loads successfully")
        except TimeoutError:
            logger.warning("tiktoken encoding cache warm-up timed out; token counting will use character-based fallback until tiktoken loads successfully")
        except Exception:
            logger.warning("tiktoken warm-up skipped", exc_info=True)

    try:
        removed_upload_staging_files = await asyncio.to_thread(cleanup_stale_upload_staging_files)
        if removed_upload_staging_files:
            logger.info("Removed %d stale upload staging file(s)", removed_upload_staging_files)
    except Exception:
        logger.warning("Upload staging file cleanup skipped", exc_info=True)

    # Initialize LangGraph runtime components (StreamBridge, RunManager, checkpointer, store)
    async with langgraph_runtime(app, startup_config):
        logger.info("LangGraph runtime initialised")

        # Check admin bootstrap state and migrate orphan threads after admin exists.
        await _ensure_admin_user(app)

        # Start IM channel service if any channels are configured
        try:
            from channels.channels.service import start_channel_service

            channel_service = await start_channel_service(startup_config)
            logger.info("Channel service started: %s", channel_service.get_status())
        except Exception:
            logger.exception("No IM channels configured or channel service failed to start")

        try:
            from gateway.gateway.services import launch_scheduled_thread_run
            from scheduler.scheduler import ScheduledTaskService

            if getattr(app.state, "scheduled_task_repo", None) is not None and getattr(app.state, "scheduled_task_run_repo", None) is not None:
                scheduled_task_service = ScheduledTaskService(
                    task_repo=app.state.scheduled_task_repo,
                    task_run_repo=app.state.scheduled_task_run_repo,
                    launch_run=lambda **kwargs: launch_scheduled_thread_run(app=app, **kwargs),
                    poll_interval_seconds=startup_config.scheduler.poll_interval_seconds,
                    lease_seconds=startup_config.scheduler.lease_seconds,
                    max_concurrent_runs=startup_config.scheduler.max_concurrent_runs,
                )
                app.state.scheduled_task_service = scheduled_task_service
                if startup_config.scheduler.enabled:
                    await scheduled_task_service.start()
        except Exception:
            logger.exception("Failed to initialize scheduled task service")

        yield

        try:
            await auth.close_oidc_service()
        except Exception:
            logger.exception("Failed to close OIDC service")

        # Stop channel service on shutdown (bounded to prevent worker hang)
        try:
            from channels.channels.service import stop_channel_service

            await asyncio.wait_for(
                stop_channel_service(),
                timeout=_SHUTDOWN_HOOK_TIMEOUT_SECONDS,
            )
        except TimeoutError:
            logger.warning(
                "Channel service shutdown exceeded %.1fs; proceeding with worker exit.",
                _SHUTDOWN_HOOK_TIMEOUT_SECONDS,
            )
        except Exception:
            logger.exception("Failed to stop channel service")

        if getattr(app.state, "scheduled_task_service", None) is not None:
            try:
                await app.state.scheduled_task_service.stop()
            except Exception:
                logger.exception("Failed to stop scheduled task service")

    logger.info("Shutting down API Gateway")


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    config = get_gateway_config()
    docs_url = "/docs" if config.enable_docs else None
    redoc_url = "/redoc" if config.enable_docs else None
    openapi_url = "/openapi.json" if config.enable_docs else None

    app = FastAPI(
        title="Helix API Gateway",
        description="API Gateway for Helix - A LangGraph-based AI agent backend.",
        version="0.1.0",
        lifespan=lifespan,
        docs_url=docs_url,
        redoc_url=redoc_url,
        openapi_url=openapi_url,
    )

    # Auth: reject unauthenticated requests to non-public paths (fail-closed safety net)
    app.add_middleware(AuthMiddleware)

    # CSRF: Double Submit Cookie pattern for state-changing requests
    app.add_middleware(CSRFMiddleware)

    # CORS: the unified nginx endpoint is same-origin by default. Split-origin
    # browser clients must opt in with this explicit Gateway allowlist so CORS
    # and CSRF origin checks share the same source of truth.
    cors_origins = sorted(get_configured_cors_origins())
    if cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=cors_origins,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    # Request trace correlation: when logging.enhance.enabled=true, bind one
    # trace id per Gateway HTTP request.
    app.add_middleware(TraceMiddleware, enabled=_resolve_trace_enabled_for_app_construction())

    # Include routers (models, features, console, mcp, memory, skills, artifacts,
    # uploads, threads, scheduled_tasks, agents, suggestions, input_polish,
    # channel_connections, channels, assistants_compat, auth, feedback,
    # thread_runs, runs, github_webhooks) -- each mounted at /api/<resource>.
    # GitHub webhooks route is fail-closed: only mounted when a webhook secret
    # is configured (or HELIX_ALLOW_UNVERIFIED_GITHUB_WEBHOOKS=1 dev opt-in).
    # ... app.include_router(...) calls omitted for brevity ...

    @app.get("/health", tags=["health"])
    async def health_check() -> dict[str, str]:
        """Health check endpoint."""
        return {"status": "healthy", "service": "helix-gateway"}

    return app


def _resolve_trace_enabled_for_app_construction() -> bool:
    """Resolve the trace middleware flag without making imports require config.yaml."""
    try:
        return resolve_trace_enabled(get_app_config())
    except FileNotFoundError:
        logger.debug("config.yaml not found while constructing Gateway app; TraceMiddleware disabled for this app instance")
        return False


# Create app instance for uvicorn
app = create_app()
```

## 6. gateway/gateway/deps.py（langgraph_runtime -- 启动期 bootstrap 编排）

`langgraph_runtime` 是 `AsyncExitStack` 上下文，按序 bootstrap 所有 LangGraph runtime 单例：`_enforce_postgres_for_multi_worker`（multi-worker gate）-> `make_stream_bridge` -> `init_engine_from_config`（含 `bootstrap_schema`）-> `make_checkpointer` / `make_store` -> repositories -> `RunManager`（SQLite 下 `reconcile_orphaned_inflight_runs` 恢复）。所有 engine 绑定到 `startup_config` 快照（restart-required），request-time 消费走 `get_config()` 热重载。

```python
# gateway/gateway/deps.py（langgraph_runtime 节选）
"""Centralized accessors for singleton objects stored on ``app.state``.

``AppConfig`` is intentionally *not* cached on ``app.state``. Routers and the
run path resolve it through ``get_app_config()``, which performs mtime-based
hot reload, so edits to ``config.yaml`` take effect on the next request
without a process restart. The engines created in ``langgraph_runtime``
(stream bridge, persistence, checkpointer, store, run-event store) accept a
``startup_config`` snapshot - they are restart-required by design and stay
bound to that snapshot to keep the live process consistent with itself.
"""

from __future__ import annotations

import asyncio
import logging
import os
from collections.abc import AsyncGenerator, Callable
from contextlib import AsyncExitStack, asynccontextmanager
from typing import TYPE_CHECKING, TypeVar, cast

from fastapi import FastAPI, HTTPException, Request
from langgraph.types import Checkpointer

from helix.config.app_config import AppConfig, get_app_config
from helix.persistence.feedback import FeedbackRepository
from helix.runtime import RunContext, RunManager, StreamBridge
from helix.runtime.events.store.base import RunEventStore
from helix.runtime.runs.store.base import RunStore

logger = logging.getLogger(__name__)

_RUN_DRAIN_TIMEOUT_SECONDS = 5.0


def _enforce_postgres_for_multi_worker(config: AppConfig) -> None:
    """Refuse to start when GATEWAY_WORKERS > 1 and the DB backend is not Postgres.

    SQLite write-locks cannot support concurrent multi-process access.
    This gate runs once at startup before any persistence engine is
    initialised so the error message is clear and the process exits
    immediately.
    """
    try:
        workers = int(os.environ.get("GATEWAY_WORKERS", "1"))
    except (TypeError, ValueError):
        workers = 1

    if workers <= 1:
        return

    backend = getattr(config.database, "backend", None)
    if backend != "postgres":
        raise SystemExit(f"GATEWAY_WORKERS={workers} requires database.backend='postgres', but database.backend is '{backend}'. SQLite cannot support concurrent multi-process access. Set GATEWAY_WORKERS=1 or switch to Postgres.")


async def _drain_inflight_runs(run_manager: RunManager) -> None:
    """Drain in-flight runs before the checkpointer is torn down."""
    drain = asyncio.create_task(run_manager.shutdown(timeout=_RUN_DRAIN_TIMEOUT_SECONDS))
    try:
        await asyncio.shield(drain)
    except asyncio.CancelledError:
        try:
            await asyncio.shield(drain)
        except Exception:
            logger.exception("In-flight run drain failed after shutdown cancellation")
        raise
    except Exception:
        logger.exception("Failed to drain in-flight runs during shutdown")


@asynccontextmanager
async def langgraph_runtime(app: FastAPI, startup_config: AppConfig) -> AsyncGenerator[None, None]:
    """Bootstrap and tear down all LangGraph runtime singletons.

    ``startup_config`` is the ``AppConfig`` snapshot taken once during
    ``lifespan()`` for one-shot infrastructure bootstrap. The engines and
    stores constructed here (stream bridge, persistence engine, checkpointer,
    store, run-event store) are restart-required by design - they hold live
    connections, file handles, or singleton providers - so they bind to this
    snapshot and survive across `config.yaml` edits. Request-time consumers
    must still go through :func:`get_config` for any field that should be
    hot-reloadable.

    Usage in ``app.py``::

        async with langgraph_runtime(app, startup_config):
            yield
    """
    from helix.persistence.engine import close_engine, get_session_factory, init_engine_from_config
    from helix.runtime import make_store, make_stream_bridge
    from helix.runtime.checkpointer.async_provider import make_checkpointer
    from helix.runtime.events.store import make_run_event_store

    # ------------------------------------------------------------------
    # Multi-worker safety gate: reject SQLite when GATEWAY_WORKERS > 1.
    # ------------------------------------------------------------------
    _enforce_postgres_for_multi_worker(startup_config)

    async with AsyncExitStack() as stack:
        config = startup_config

        app.state.stream_bridge = await stack.enter_async_context(make_stream_bridge(config))

        # Initialize persistence engine BEFORE checkpointer so that
        # auto-create-database logic runs first (postgres backend).
        # ⭐ This is where bootstrap_schema runs (inside init_engine_from_config).
        await init_engine_from_config(config.database)

        app.state.checkpointer = await stack.enter_async_context(make_checkpointer(config))
        app.state.store = await stack.enter_async_context(make_store(config))

        # Initialize repositories - one get_session_factory() call for all.
        sf = get_session_factory()
        if sf is not None:
            from helix.persistence.feedback import FeedbackRepository
            from helix.persistence.run import RunRepository

            app.state.run_store = RunRepository(sf)
            app.state.feedback_repo = FeedbackRepository(sf)
        else:
            from helix.runtime.runs.store.memory import MemoryRunStore

            app.state.run_store = MemoryRunStore()
            app.state.feedback_repo = None

        from helix.persistence.thread_meta import make_thread_store

        app.state.thread_store = make_thread_store(sf, app.state.store)
        if sf is not None:
            from helix.persistence.scheduled_task_runs import (
                ScheduledTaskRunRepository,
            )
            from helix.persistence.scheduled_tasks import ScheduledTaskRepository

            app.state.scheduled_task_repo = ScheduledTaskRepository(sf)
            app.state.scheduled_task_run_repo = ScheduledTaskRunRepository(sf)
        else:
            app.state.scheduled_task_repo = None
            app.state.scheduled_task_run_repo = None

        # Run event store. The store and the matching ``run_events_config`` are
        # both frozen at startup so ``get_run_context`` does not combine a
        # freshly-reloaded ``AppConfig.run_events`` with a store still bound to
        # the previous backend.
        run_events_config = getattr(config, "run_events", None)
        app.state.run_events_config = run_events_config
        app.state.run_event_store = make_run_event_store(run_events_config)

        # RunManager with store backing for persistence
        app.state.run_manager = RunManager(store=app.state.run_store)
        if getattr(config.database, "backend", None) == "sqlite":
            from helix.utils.time import now_iso

            # Startup-only recovery: clean shutdowns return no active rows and
            # the thread-status update below becomes a no-op.
            recovered_runs = await app.state.run_manager.reconcile_orphaned_inflight_runs(
                error="Gateway restarted before this run reached a durable final state.",
                before=now_iso(),
            )
            sb_config = getattr(config, "stream_bridge", None)
            cleanup_delay = getattr(sb_config, "recovered_stream_cleanup_delay_seconds", 60.0) if sb_config else 60.0
            await _publish_recovered_run_stream_end(app.state.stream_bridge, recovered_runs, cleanup_delay=cleanup_delay)
            await _mark_latest_recovered_threads_error(app.state.run_manager, app.state.thread_store, recovered_runs)

        try:
            yield
        finally:
            # Drain in-flight runs before tearing down the checkpointer pool.
            if app.state.run_manager is not None:
                await _drain_inflight_runs(app.state.run_manager)
            await close_engine()
```
