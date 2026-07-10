# references/code/tui.md — TUI（CLI + persistence + session + pyproject）

> 自定路径：`core/helix/tui/cli.py`、`core/helix/tui/persistence.py`、`core/helix/tui/session.py`、`core/pyproject.toml`
> 真实职责：TUI 是 `HelixClient` 之上的 Textual UI 外壳——没有自己独立的 agent。`helix` console script 按 TTY 状态决定开终端 UI 还是跑 headless one-shot；`textual` 缺失时降级为 headless help。`persistence.py` 通过 Core 自带的 `init_engine_from_config()` 写 `threads_meta` 让 TUI 会话在 Web UI 可见，无需启动 Gateway。
>
> 设计要点：纯 / Textual-free 层（`cli.py::plan_launch`、`view_state.py`、`runtime.py`、`message_format.py` 等）全单元测试覆盖；Textual `app.py` 走 Textual Pilot API 测试。`cli.py` 必须**绝对 import** `from helix.tui.app import run_tui`（非 `from .app`），否则边界测试会按字面记录模块名 `app` 误判（见 [boundary-and-ci-test.md](./boundary-and-ci-test.md)）。

## §1 CLI 入口（`core/helix/tui/cli.py`）

```python
"""Command-line entry point and launch-mode planning for the Helix TUI.

``plan_launch`` is a pure decision function (fully unit-tested): given argv, TTY
state and the environment, it decides whether to open the terminal UI or run a
headless one-shot. ``main`` wires that decision to the embedded ``HelixClient``
and lazily imports the Textual app only when actually launching the UI, so the
``helix`` console script still runs headless commands without Textual present.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Literal

_UNSET = object()

Mode = Literal["tui", "print", "json", "headless-help"]


@dataclass
class LaunchPlan:
    mode: Mode
    message: str | None = None
    read_stdin: bool = False
    thread_id: str | None = None
    continue_recent: bool = False
    forced_tui: bool = False
    reason: str = ""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="helix",
        description="Helix terminal workbench — a TUI over the embedded Helix core.",
        add_help=True,
    )
    parser.add_argument("message", nargs="*", help="initial prompt for the TUI, or message in --cli mode")
    parser.add_argument(
        "--print",
        dest="print",
        nargs="?",
        const=None,
        default=_UNSET,
        metavar="MESSAGE",
        help="headless one-shot: print the final answer and exit (reads stdin if no MESSAGE)",
    )
    parser.add_argument(
        "--json",
        dest="json",
        nargs="?",
        const=None,
        default=_UNSET,
        metavar="MESSAGE",
        help="headless streaming: emit newline-delimited JSON StreamEvents and exit",
    )
    parser.add_argument("--tui", action="store_true", help="force the terminal UI (error if unavailable)")
    parser.add_argument("--cli", action="store_true", help="force headless/classic mode for one invocation")
    parser.add_argument("--continue", dest="continue_recent", action="store_true", help="resume the most recent thread")
    parser.add_argument("--resume", dest="resume", metavar="THREAD", default=None, help="resume a thread by id or title")
    return parser


def _strip_chat(argv: Sequence[str]) -> list[str]:
    """Accept an optional leading ``chat`` subcommand as an alias for the default surface."""
    argv = list(argv)
    if argv and argv[0] == "chat":
        return argv[1:]
    return argv


def _truthy(value: object) -> bool:
    return isinstance(value, str) and value.strip().lower() in {"1", "true", "yes", "on"}


def plan_launch(
    argv: Sequence[str],
    *,
    stdin_isatty: bool,
    stdout_isatty: bool,
    env: dict[str, str],
) -> LaunchPlan:
    """Decide what surface to launch. Pure: no I/O, no client construction."""
    args = build_parser().parse_args(_strip_chat(argv))
    positional = " ".join(args.message).strip() or None
    resume = args.resume
    continue_recent = bool(args.continue_recent)

    if args.print is not _UNSET:
        message = args.print if isinstance(args.print, str) else None
        if message is None and stdin_isatty:
            return LaunchPlan(mode="headless-help", reason="--print needs a MESSAGE argument or piped stdin.")
        return LaunchPlan(mode="print", message=message, read_stdin=message is None, thread_id=resume, continue_recent=continue_recent)

    if args.json is not _UNSET:
        message = args.json if isinstance(args.json, str) else None
        if message is None and stdin_isatty:
            return LaunchPlan(mode="headless-help", reason="--json needs a MESSAGE argument or piped stdin.")
        return LaunchPlan(mode="json", message=message, read_stdin=message is None, thread_id=resume, continue_recent=continue_recent)

    if args.cli:
        if positional:
            return LaunchPlan(mode="print", message=positional, thread_id=resume, continue_recent=continue_recent)
        # Mirror --print: a piped message or --continue is enough to run headless.
        if continue_recent or not stdin_isatty:
            return LaunchPlan(mode="print", message=None, read_stdin=True, thread_id=resume, continue_recent=continue_recent)
        return LaunchPlan(
            mode="headless-help",
            reason='--cli needs a message. Try: helix --print "your question".',
        )

    forced_tui = bool(args.tui)
    if forced_tui or _truthy(env.get("HELIX_TUI")) or (stdin_isatty and stdout_isatty):
        return LaunchPlan(
            mode="tui",
            message=positional,
            thread_id=resume,
            continue_recent=continue_recent,
            forced_tui=forced_tui,
        )

    return LaunchPlan(
        mode="headless-help",
        message=positional,
        thread_id=resume,
        continue_recent=continue_recent,
        reason="No interactive terminal detected. Use --print MESSAGE for one-shot output, or --tui to force the UI.",
    )


# --------------------------------------------------------------------------- #
# Runtime dispatch (not unit-tested here; covered by smoke + integration).
# --------------------------------------------------------------------------- #

_HEADLESS_HELP = """\
helix — Helix terminal workbench

  helix                      launch the terminal UI (TTY required)
  helix --tui                force the terminal UI
  helix --continue           resume the most recent thread in the UI
  helix --resume THREAD      resume a thread by id or title
  helix --print "question"   one-shot answer to stdout
  helix --json "question"    stream newline-delimited JSON events
  echo "question" | helix --print
"""


def _resolve_message(plan: LaunchPlan) -> str:
    if plan.read_stdin:
        return sys.stdin.read().strip()
    return plan.message or ""


def main(argv: Sequence[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    plan = plan_launch(
        argv,
        stdin_isatty=sys.stdin.isatty(),
        stdout_isatty=sys.stdout.isatty(),
        env=dict(os.environ),
    )

    if plan.mode == "headless-help":
        if plan.reason:
            print(plan.reason, file=sys.stderr)
        print(_HEADLESS_HELP, file=sys.stderr)
        return 0 if not plan.reason else 2

    if plan.mode == "print":
        return _run_print(plan)

    if plan.mode == "json":
        return _run_json(plan)

    return _run_tui(plan)


def _make_session():
    # Imported lazily so the pure planning path never imports the heavy core.
    # Headless one-shots never use the threads_meta writer, so skip persistence
    # (no background loop / engine / connection pool just to discard it).
    from .session import open_session

    return open_session(persistence=False)


def _run_print(plan: LaunchPlan) -> int:
    message = _resolve_message(plan)
    if not message:
        print("No message provided.", file=sys.stderr)
        return 2
    session = _make_session()
    thread_id = session.resolve_thread(plan)
    answer = session.client.chat(message, thread_id=thread_id)
    print(answer)
    return 0


def _run_json(plan: LaunchPlan) -> int:
    message = _resolve_message(plan)
    if not message:
        print("No message provided.", file=sys.stderr)
        return 2
    session = _make_session()
    thread_id = session.resolve_thread(plan)
    for event in session.client.stream(message, thread_id=thread_id):
        payload = {"type": event.type, "data": event.data}
        sys.stdout.write(json.dumps(payload, ensure_ascii=False, default=str) + "\n")
        sys.stdout.flush()
    return 0


def _run_tui(plan: LaunchPlan) -> int:
    try:
        # Absolute import (not `from .app`) so the core import-boundary check,
        # which records relative import module names verbatim, doesn't mistake the sibling
        # `helix.tui.app` module for a forbidden top-level app package.
        from helix.tui.app import run_tui
    except ModuleNotFoundError as exc:  # textual missing
        if getattr(exc, "name", "") == "textual" or "textual" in str(exc):
            msg = "The terminal UI needs the optional 'textual' dependency.\nInstall it with:  uv pip install 'helix[tui]'   (or: pip install textual)\n"
            if plan.forced_tui:
                print(msg, file=sys.stderr)
                return 1
            print(msg + "\nFalling back to headless help:\n", file=sys.stderr)
            print(_HEADLESS_HELP, file=sys.stderr)
            return 0
        raise
    return run_tui(plan)


if __name__ == "__main__":
    raise SystemExit(main())
```

**关键实现细节**：
- **`plan_launch` 纯决策**：给定 argv / TTY / env 返回 `LaunchPlan`，无 IO、无 client 构造——可全单元测试。`--print` / `--json` / `--cli` / `--tui` / `--continue` / `--resume` 的优先级与 stdin TTY 检测全在此函数。
- **惰性 import**：`_make_session` 里 `from .session import open_session` 在函数体内，纯规划路径（`plan_launch`）永不被重 core 拖慢；headless 调用跳过持久化（不起后台 loop / engine 仅为丢弃）。
- **绝对 import 避误判**：`_run_tui` 用 `from helix.tui.app import run_tui`（绝对），而非 `from .app`（相对）——边界测试按字面记录 import 模块名，相对 import 会让 `app` 出现在记录里。绝对 import 让模块名是 `helix.tui.app`，干净。
- **textual 缺失优雅降级**：`ModuleNotFoundError` 且 `name == "textual"` 时，`--tui` 强制模式退出码 1，非强制打印安装提示 + headless help 退出码 0；其它 `ModuleNotFoundError` 直接 raise。

## §2 共享持久化（`core/helix/tui/persistence.py`）+ 引擎入口（`core/helix/persistence/engine.py`）

### `tui/persistence.py`

```python
"""Shared-persistence wiring so terminal sessions show up in the Web UI.

The Web UI lists conversations from the ``threads_meta`` SQL table (filtered by
``user_id``), not from the checkpointer. An embedded run only writes the
checkpointer, so a TUI thread would be invisible in the sidebar. This module
closes that gap: it writes a ``threads_meta`` row (owned by the local default
user) into the **same** database the Gateway reads — without requiring the
Gateway process to be running.

Everything here is best-effort: when the database is memory-backed or
unavailable, the writer degrades to a no-op and the TUI keeps working.

The SQLAlchemy async engine is bound to the event loop that created it, so all
DB work runs on one long-lived background loop (``_LoopThread``) rather than a
fresh ``asyncio.run`` per call (which would bind connections to throwaway loops).
"""

from __future__ import annotations

import asyncio
import threading
from collections.abc import Awaitable
from typing import Any

from helix.runtime.user_context import DEFAULT_USER_ID


class _LoopThread:
    """A daemon thread running a single asyncio event loop for DB work."""

    def __init__(self) -> None:
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, name="helix-tui-db", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def run(self, coro: Awaitable[Any], *, timeout: float = 15.0) -> Any:
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        return future.result(timeout)

    def close(self) -> None:
        self._loop.call_soon_threadsafe(self._loop.stop)


class ThreadMetaWriter:
    """Writes/updates ``threads_meta`` rows for the local default user.

    All methods swallow errors: persistence visibility is a convenience, never a
    reason to break the conversation.
    """

    def __init__(self, loop: _LoopThread, store: Any) -> None:
        self._loop = loop
        self._store = store
        self.user_id = DEFAULT_USER_ID

    @property
    def enabled(self) -> bool:
        return self._store is not None

    def ensure_created(self, thread_id: str, *, assistant_id: str | None = None, metadata: dict | None = None) -> None:
        if not self._store or not thread_id:
            return
        try:
            self._loop.run(self._ensure_created(thread_id, assistant_id, metadata))
        except Exception:  # noqa: BLE001 - best-effort
            pass

    async def _ensure_created(self, thread_id: str, assistant_id: str | None, metadata: dict | None) -> None:
        existing = await self._store.get(thread_id, user_id=self.user_id)
        if existing is None:
            await self._store.create(
                thread_id,
                assistant_id=assistant_id,
                user_id=self.user_id,
                metadata=metadata or {"source": "tui"},
            )

    def set_title(self, thread_id: str, title: str) -> None:
        if not self._store or not thread_id or not title:
            return
        try:
            self._loop.run(self._store.update_display_name(thread_id, title, user_id=self.user_id))
        except Exception:  # noqa: BLE001 - best-effort
            pass


def build_persistence() -> tuple[_LoopThread, ThreadMetaWriter]:
    """Initialise the shared engine on a background loop and return a writer.

    Returns a ``ThreadMetaWriter`` that is a no-op when the configured database
    backend is ``memory`` (no SQL session factory) or initialisation fails.
    """
    loop = _LoopThread()
    store = None
    try:
        from helix.config.app_config import get_app_config
        from helix.persistence.engine import get_session_factory, init_engine_from_config
        from helix.persistence.thread_meta import make_thread_store

        config = get_app_config()
        loop.run(init_engine_from_config(config.database))
        session_factory = get_session_factory()
        if session_factory is not None:
            store = make_thread_store(session_factory)
    except Exception:  # noqa: BLE001 - degrade to no-op writer
        store = None
    return loop, ThreadMetaWriter(loop, store)
```

### `persistence/engine.py`（`init_engine_from_config` 节选 — 嵌入式/TUI 用的最薄入口）

```python
"""Async SQLAlchemy engine lifecycle management.

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

    # ...（sqlite / postgres 分支建 engine；SQLite 走 WAL + busy_timeout；
    #  postgres 走 pool_pre_ping）...

    _session_factory = async_sessionmaker(_engine, expire_on_commit=False)

    # Schema bootstrap (hybrid)：空库 create_all + alembic stamp head；
    #  库 create_all（baseline only, backfill）+ stamp baseline + upgrade head；
    #  已纳管 alembic upgrade head。并发：Postgres advisory lock / SQLite asyncio.Lock。
    from helix.persistence.bootstrap import bootstrap_schema

    try:
        await bootstrap_schema(_engine, backend=backend)
    except Exception as exc:
        if backend == "postgres" and "does not exist" in str(exc):
            # 数据库不存在——自动建库后重试
            await _auto_create_postgres_db(url)
            await _engine.dispose()
            _engine = create_async_engine(url, echo=echo, pool_size=pool_size, pool_pre_ping=True, json_serializer=_json_serializer)
            _session_factory = async_sessionmaker(_engine, expire_on_commit=False)
            await bootstrap_schema(_engine, backend=backend)
        else:
            raise

    logger.info("Persistence engine initialized: backend=%s", backend)


async def init_engine_from_config(config) -> None:
    """Convenience: init engine from a DatabaseConfig object.

    嵌入式 / TUI 用的最薄入口；不依赖 FastAPI ``app.state``。
    """
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


async def close_engine() -> None:
    """Dispose the engine, release all connections."""
    global _engine, _session_factory
    if _engine is not None:
        await _engine.dispose()
        logger.info("Persistence engine closed")
    _engine = None
    _session_factory = None
```

**关键实现细节**：
- **`_LoopThread` 单 loop**：daemon 线程跑一个 asyncio loop，所有 DB 工作通过 `run_coroutine_threadsafe` 上这个 loop——SQLAlchemy async engine 绑定到创建它的 loop，若每次 `asyncio.run` 会绑到一次性 loop，连接泄漏 / 跨 loop 报错。
- **best-effort 吞异常**：`ThreadMetaWriter` 所有方法 + `build_persistence` 全 `try/except` 降级——持久化可见性是便利，绝不应打断对话；`memory` 后端或初始化失败 → no-op writer。
- **`init_engine_from_config` 独立于 FastAPI**：Core 自带的最薄入口，嵌入式 / TUI 不启动 Gateway 也能建 engine 写 `threads_meta`。`memory` 后端是 no-op（`_session_factory = None`）。
- **schema bootstrap 混合策略**：空库 → `create_all` + `alembic stamp head`；库 → backfill + stamp baseline + upgrade；已纳管 → upgrade。Postgres 库不存在自动建库后重试。

## §3 Session 装配（`core/helix/tui/session.py`）

```python
"""Embedded session wiring for the TUI.

Owns construction of the ``HelixClient`` (with a persistent checkpointer),
thread resolution for ``--continue`` / ``--resume`` (by id **or** title), and the
shared-persistence writer that makes terminal sessions visible in the Web UI (see
``helix.tui.persistence``).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # avoid importing the heavy client during pure planning
    from helix.client import HelixClient

    from .cli import LaunchPlan
    from .persistence import ThreadMetaWriter, _LoopThread


@dataclass
class Session:
    client: HelixClient
    writer: ThreadMetaWriter | None = None
    _loop: _LoopThread | None = None

    def resolve_thread(self, plan: LaunchPlan) -> str | None:
        """Resolve the thread id to run against, honoring --resume / --continue."""
        if plan.thread_id:
            return self.resolve_ref(plan.thread_id)
        if plan.continue_recent:
            threads = self.client.list_threads(limit=1).get("thread_list", [])
            if threads:
                return threads[0].get("thread_id")
        return None

    def resolve_ref(self, ref: str) -> str:
        """Resolve a thread reference (id or title) to a thread id.

        Matches an existing thread by id first, then by exact title. Falls back to
        the literal ref (treated as an id) when nothing matches, so an unknown id
        still continues/creates that namespace.
        """
        try:
            threads = self.client.list_threads(limit=100).get("thread_list", [])
        except Exception:  # noqa: BLE001 - resolution is best-effort
            return ref
        if any(t.get("thread_id") == ref for t in threads):
            return ref
        for thread in threads:
            if (thread.get("title") or "") == ref:
                return thread.get("thread_id") or ref
        return ref

    def recent_threads(self, limit: int = 20) -> list[dict]:
        return self.client.list_threads(limit=limit).get("thread_list", [])

    def close(self) -> None:
        """Stop the background DB loop and dispose the engine (best-effort)."""
        loop = self._loop
        if loop is None:
            return
        self._loop = None
        try:
            from helix.persistence.engine import close_engine

            loop.run(close_engine())
        except Exception:  # noqa: BLE001 - teardown is best-effort
            pass
        loop.close()


def open_session(persistence: bool = True) -> Session:
    """Build an embedded session backed by the configured checkpointer.

    ``persistence`` controls the shared ``threads_meta`` writer (and its background
    DB loop/engine). Headless one-shots never use the writer, so they pass
    ``persistence=False`` to avoid standing up an event loop + connection pool only
    to discard it.
    """
    from helix.client import HelixClient
    from helix.runtime.checkpointer.provider import get_checkpointer

    checkpointer = get_checkpointer()
    client = HelixClient(checkpointer=checkpointer)
    if not persistence:
        return Session(client=client)

    from .persistence import build_persistence

    loop, writer = build_persistence()
    return Session(client=client, writer=writer, _loop=loop)
```

**关键实现细节**：
- **`TYPE_CHECKING` 守卫**：`from helix.client import HelixClient` 在 `TYPE_CHECKING` 下，纯规划路径（`cli.py::plan_launch`）不 import 重 client——type checker 看得到类型，runtime 不付 import 成本。
- **`resolve_ref` id-or-title**：先按 `thread_id` 精确匹配，再按 `title` 精确匹配，都没中就返回 ref 本身（当 id 用）——`--resume "my chat"` 能按标题续。
- **`close()` best-effort**：`close_engine()` 通过后台 loop 跑，异常吞掉；TUI 退出时清理 engine。

## §4 pyproject（`core/pyproject.toml` 节选）

```toml
[project]
name = "helix"
version = "2.1.0"
description = "Helix agent core framework"
requires-python = ">=3.12"
dependencies = [
    # ...（langchain / langgraph / sqlalchemy / alembic / pydantic 等核心依赖）...
]

[project.scripts]
helix = "helix.tui.cli:main"

[project.optional-dependencies]
# Terminal workbench (TUI). Kept optional so the core install stays lean;
# the `helix` console script degrades to headless help when textual is absent.
tui = ["textual>=0.80"]
# 其它可选 extra：ollama / postgres / boxlite 等
```

**关键实现细节**：
- **console script 与 Core 同包**：`[project.scripts] helix = "helix.tui.cli:main"`——TUI 入口由 Core 包提供，不需要单独的 TUI 包。`helix` 命令就是 Core 的 console script。
- **`textual` 可选 extra**：Core 默认安装不含 `textual`，保持精简；需要 TUI 装 `helix[tui]`。缺失时 `cli.py::_run_tui` 降级为安装提示 + headless help，不崩溃。
- **包名 `helix`**：可发布到 PyPI；应用层（`gateway/` / `channels/` / `scheduler/`）各是独立的项目，依赖 `helix`。
