# RunManager 运行态机 + multitask 策略 + cancel 完整源码

> 本文件是 `long-running-and-cancellation` skill 的深度代码分节：run 注册表、运行态机、multitask 抢占、cancel 协作、孤儿恢复、shutdown drain 的**完整真实源码**。
>
> 代码已按插件匿名化规则映射到自定结构（`helix.*` / `gateway.*`），去除一切项目字样；原代码注释保真，中文注解以行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱 ③路由 + 跨切不变量 3）、`[[gateway-runs-and-sse]]`（lifespan 装配 + 路由 + stream_mode 映射）、`stream-bridge-resume.md`（StreamBridge 续传契约 + on_disconnect/wait）、`worker-checkpoint-rollback.md`（pre-run 快照 + rollback 触发）。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `core/helix/runtime/runs/schemas.py` | `RunStatus` / `DisconnectMode` 枚举 |
| `core/helix/runtime/runs/manager.py` | `RunRecord` dataclass + `RunManager`（注册表 + 状态机 + multitask + cancel + 孤儿恢复 + shutdown drain）+ `ConflictError` / `UnsupportedStrategyError` + `PersistenceRetryPolicy` |

---

## 1. `schemas.py`（完整）

```python
# core/helix/runtime/runs/schemas.py
"""Run status and disconnect mode enums."""

from enum import StrEnum


class RunStatus(StrEnum):
    """Lifecycle status of a single run."""

    pending = "pending"
    running = "running"
    success = "success"
    error = "error"
    timeout = "timeout"
    interrupted = "interrupted"


class DisconnectMode(StrEnum):
    """Behaviour when the SSE consumer disconnects."""

    cancel = "cancel"
    continue_ = "continue"
```

> 注：`DisconnectMode.continue_` 带尾下划线是因为 `continue` 是 Python 关键字；其 `.value` 是字符串 `"continue"`（SSE 客户端传 `on_disconnect="continue"`）。

---

## 2. `manager.py` 头部 + 重试助手 + `PersistenceRetryPolicy`

```python
# core/helix/runtime/runs/manager.py
"""In-memory run registry with optional persistent RunStore backing."""

from __future__ import annotations

import asyncio
import logging
import sqlite3
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

from helix.utils.time import now_iso as _now_iso

from .schemas import DisconnectMode, RunStatus

if TYPE_CHECKING:
    from helix.runtime.runs.store.base import RunStore

logger = logging.getLogger(__name__)

_RETRYABLE_SQLITE_MESSAGES = (
    "database is locked",
    "database table is locked",
    "database is busy",
)

_RETRYABLE_SQLITE_ERROR_CODES = {
    sqlite3.SQLITE_BUSY,
    sqlite3.SQLITE_LOCKED,
}


def _is_retryable_persistence_error(exc: BaseException) -> bool:
    """Return True for transient SQLite persistence failures.

    SQLite lock contention normally surfaces through either sqlite3 exceptions
    or SQLAlchemy wrappers.  The short bounded retry here protects run status
    finalization from transient writer pressure without hiding permanent
    failures forever.
    """

    pending: list[BaseException] = [exc]
    seen: set[int] = set()
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        seen.add(id(current))

        message = str(current).lower()
        if any(fragment in message for fragment in _RETRYABLE_SQLITE_MESSAGES):
            return True
        if isinstance(current, (sqlite3.OperationalError, sqlite3.DatabaseError)):
            error_code = getattr(current, "sqlite_errorcode", None)
            if error_code in _RETRYABLE_SQLITE_ERROR_CODES:
                return True
        for chained in (getattr(current, "orig", None), current.__cause__, current.__context__):
            if isinstance(chained, BaseException):
                pending.append(chained)
    return False


@dataclass(frozen=True)
class PersistenceRetryPolicy:
    """Bounded retry policy for short run-store writes."""

    max_attempts: int = 5
    initial_delay: float = 0.05
    max_delay: float = 1.0
    backoff_factor: float = 2.0
```

> 重试只覆盖 SQLite 锁竞争类瞬时错误（`SQLITE_BUSY / SQLITE_LOCKED` 或消息含 `database is locked / busy`）；普通业务错和模式不匹配立即抛出。判定沿 `__cause__ / __context__ / orig` 递归走，确保 SQLAlchemy `DBAPIError` 包裹的 sqlite3 异常也能识别。

---

## 3. `RunRecord` dataclass（完整）

```python
# core/helix/runtime/runs/manager.py
@dataclass
class RunRecord:
    """Mutable record for a single run."""

    run_id: str
    thread_id: str
    assistant_id: str | None
    status: RunStatus
    on_disconnect: DisconnectMode
    multitask_strategy: str = "reject"
    metadata: dict = field(default_factory=dict)
    kwargs: dict = field(default_factory=dict)
    user_id: str | None = None
    created_at: str = ""
    updated_at: str = ""
    task: asyncio.Task | None = field(default=None, repr=False)
    abort_event: asyncio.Event = field(default_factory=asyncio.Event, repr=False)
    abort_action: str = "interrupt"
    error: str | None = None
    model_name: str | None = None
    store_only: bool = False
    total_input_tokens: int = 0
    total_output_tokens: int = 0
    total_tokens: int = 0
    llm_call_count: int = 0
    lead_agent_tokens: int = 0
    subagent_tokens: int = 0
    middleware_tokens: int = 0
    # Per-model token breakdown
    token_usage_by_model: dict[str, dict[str, int]] = field(default_factory=dict)
    message_count: int = 0
    last_ai_message: str | None = None
    first_human_message: str | None = None
    finalizing: bool = False
```

**关键字段语义**（长任务通道核心）：

| 字段 | 语义 |
|---|---|
| `task: asyncio.Task \| None` | 后台 `asyncio.create_task(run_agent(...))` 句柄；`cancel()` / `shutdown()` 对它 `.cancel()` |
| `abort_event: asyncio.Event` | 协作式取消信号；worker 流循环每 chunk 检查 `record.abort_event.is_set()` |
| `abort_action: str = "interrupt"` | `"interrupt"`（保留 checkpoint）/ `"rollback"`（回滚到 pre-run）；worker 终结路径读它决定走 `_rollback_to_pre_run_checkpoint` 还是仅 `set_status(interrupted)` |
| `finalizing: bool` | True 表示 run 正在做 post-cancel 清理（task 仍在 drain）；`create_or_reject` / `has_inflight` 把 `finalizing` 视为在途 |
| `on_disconnect: DisconnectMode` | 仅本 worker 拥有的 run 有意义；控制 `sse_consumer` / `wait_for_run_completion` 断连行为 |
| `multitask_strategy: str` | `"reject" / "interrupt" / "rollback"` |
| `store_only: bool` | True 仅在从 `RunStore` 行反水化的只读 `RunRecord` 上；`sse_consumer` / `wait_for_run_completion` 的 `finally` 对它跳过 `cancel()`（本 worker 无 task） |

---

## 4. `RunManager` 完整类

### 4.1 `__init__` + 线程二级索引助手

```python
# core/helix/runtime/runs/manager.py
class RunManager:
    """In-memory run registry with optional persistent RunStore backing.

    All mutations are protected by an asyncio lock. When a ``store`` is
    provided, serializable metadata is also persisted to the store so
    that run history survives process restarts.
    """

    def __init__(
        self,
        store: RunStore | None = None,
        *,
        persistence_retry_policy: PersistenceRetryPolicy | None = None,
    ) -> None:
        self._runs: dict[str, RunRecord] = {}
        # Secondary index: thread_id -> insertion-ordered run_id set (a dict is
        # used as an ordered set), maintained in lockstep with ``_runs`` so
        # per-thread queries avoid O(total in-memory runs) full scans while
        # preserving ``_runs`` iteration order (see ``_thread_records_locked``).
        self._runs_by_thread: dict[str, dict[str, None]] = {}
        self._lock = asyncio.Lock()
        self._store = store
        self._persistence_retry_policy = persistence_retry_policy or PersistenceRetryPolicy()

    def _index_run_locked(self, record: RunRecord) -> None:
        """Register *record* in the thread index. Caller must hold ``self._lock``."""
        self._runs_by_thread.setdefault(record.thread_id, {})[record.run_id] = None

    def _unindex_run_locked(self, run_id: str, thread_id: str) -> None:
        """Drop *run_id* from the thread index. Caller must hold ``self._lock``."""
        bucket = self._runs_by_thread.get(thread_id)
        if bucket is not None:
            bucket.pop(run_id, None)
            if not bucket:
                self._runs_by_thread.pop(thread_id, None)

    def _thread_records_locked(self, thread_id: str) -> list[RunRecord]:
        """Return live in-memory records for *thread_id*. Caller must hold ``self._lock``.

        Uses the ``_runs_by_thread`` index for O(runs-in-thread) lookup instead of
        scanning every in-memory run. Correctness rests on the index and ``_runs``
        being mutated in lockstep under ``self._lock`` (no ``await`` between the two
        writes), so any holder of the lock sees them agree. The ``self._runs.get``
        filter is defense-in-depth, not reconciliation: it drops a stale id still in
        the index but already gone from ``_runs``, yet it cannot recover a run that is
        in ``_runs`` but missing from the index (such a run would be silently
        omitted). It guards only that one direction, should a future refactor ever
        break the lockstep invariant.
        """
        run_ids = self._runs_by_thread.get(thread_id)
        if not run_ids:
            return []
        return [record for run_id in run_ids if (record := self._runs.get(run_id)) is not None]
```

> **二级索引原子性不变量**：`_runs` 与 `_runs_by_thread` 的写入在同一把 `_lock` 内串行（无 `await` 跨越），任何持锁读取都看到一致视图。索引把 per-thread 查询从 O(全部内存 run) 降到 O(该 thread 的 run)。

### 4.2 store 载荷 + 持久化助手

```python
# core/helix/runtime/runs/manager.py
    @staticmethod
    def _store_put_payload(record: RunRecord, *, error: str | None = None) -> dict[str, Any]:
        payload = {
            "thread_id": record.thread_id,
            "assistant_id": record.assistant_id,
            "status": record.status.value,
            "multitask_strategy": record.multitask_strategy,
            "metadata": record.metadata or {},
            "kwargs": record.kwargs or {},
            "error": error if error is not None else record.error,
            "created_at": record.created_at,
            "model_name": record.model_name,
        }
        if record.user_id is not None:
            payload["user_id"] = record.user_id
        return payload

    async def _call_store_with_retry(
        self,
        operation_name: str,
        run_id: str,
        operation: Callable[[], Awaitable[Any]],
    ) -> Any:
        """Run a short store operation with bounded retries for SQLite pressure."""
        policy = self._persistence_retry_policy
        attempt = 1
        delay = policy.initial_delay
        while True:
            try:
                return await operation()
            except Exception as exc:
                retryable = _is_retryable_persistence_error(exc)
                if attempt >= policy.max_attempts or not retryable:
                    raise
                logger.warning(
                    "Transient persistence failure during %s for run %s (attempt %d/%d); retrying",
                    operation_name,
                    run_id,
                    attempt,
                    policy.max_attempts,
                    exc_info=True,
                )
                if delay > 0:
                    await asyncio.sleep(delay)
                delay = min(policy.max_delay, delay * policy.backoff_factor if delay else policy.initial_delay)
                attempt += 1

    async def _persist_snapshot_to_store(self, run_id: str, payload: dict[str, Any]) -> bool:
        """Best-effort persist a previously captured run snapshot."""
        if self._store is None:
            return True
        try:
            await self._call_store_with_retry(
                "put",
                run_id,
                lambda: self._store.put(run_id, **payload),
            )
            return True
        except Exception:
            logger.warning("Failed to persist run %s to store", run_id, exc_info=True)
            return False

    async def _persist_new_run_to_store(self, record: RunRecord) -> None:
        """Persist a newly created run record to the backing store.

        Initial run creation is part of the run visibility boundary: callers
        should not observe a run in memory unless its backing store row exists.
        Unlike follow-up status/model updates, failures are propagated so the
        caller can treat creation as failed. Rollback is the caller's
        responsibility after inserting the record into ``_runs``.
        """
        if self._store is None:
            return
        await self._call_store_with_retry(
            "put",
            record.run_id,
            lambda: self._store.put(record.run_id, **self._store_put_payload(record)),
        )

    async def _persist_to_store(self, record: RunRecord, *, error: str | None = None) -> bool:
        """Best-effort persist run record to backing store."""
        return await self._persist_snapshot_to_store(
            record.run_id,
            self._store_put_payload(record, error=error),
        )

    async def _persist_status(self, record: RunRecord, status: RunStatus, *, error: str | None = None) -> bool:
        """Best-effort persist a status transition to the backing store."""
        if self._store is None:
            return True
        row_recovery_payload = self._store_put_payload(record, error=error)
        try:
            updated = await self._call_store_with_retry(
                "update_status",
                record.run_id,
                lambda: self._store.update_status(record.run_id, status.value, error=error),
            )
            if updated is False:
                return await self._persist_snapshot_to_store(record.run_id, row_recovery_payload)
            return True
        except Exception:
            logger.warning("Failed to persist status update for run %s", record.run_id, exc_info=True)
            return False

    @staticmethod
    def _record_from_store(row: dict[str, Any]) -> RunRecord:
        """Build a read-only runtime record from a serialized store row.

        NULL status/on_disconnect columns (e.g. from rows written before those
        columns were added) default to ``pending`` and ``cancel`` respectively.
        """
        return RunRecord(
            run_id=row["run_id"],
            thread_id=row["thread_id"],
            assistant_id=row.get("assistant_id"),
            status=RunStatus(row.get("status") or RunStatus.pending.value),
            on_disconnect=DisconnectMode(row.get("on_disconnect") or DisconnectMode.cancel.value),
            multitask_strategy=row.get("multitask_strategy") or "reject",
            metadata=row.get("metadata") or {},
            kwargs=row.get("kwargs") or {},
            created_at=row.get("created_at") or "",
            updated_at=row.get("updated_at") or "",
            user_id=row.get("user_id"),
            error=row.get("error"),
            model_name=row.get("model_name"),
            store_only=True,
            total_input_tokens=row.get("total_input_tokens") or 0,
            total_output_tokens=row.get("total_output_tokens") or 0,
            total_tokens=row.get("total_tokens") or 0,
            llm_call_count=row.get("llm_call_count") or 0,
            lead_agent_tokens=row.get("lead_agent_tokens") or 0,
            subagent_tokens=row.get("subagent_tokens") or 0,
            middleware_tokens=row.get("middleware_tokens") or 0,
            token_usage_by_model=row.get("token_usage_by_model") or {},
            message_count=row.get("message_count") or 0,
            last_ai_message=row.get("last_ai_message"),
            first_human_message=row.get("first_human_message"),
        )
```

> **创建可见性边界**：`_persist_new_run_to_store` 创建失败会回滚内存记录（见 `create` / `create_or_reject` 的 `finally`），杜绝"内存有但 store 没有"的脏状态。状态更新 `update_status` 是 best-effort（捕获日志），但创建是 fail-hard。

### 4.3 `update_run_completion` + `update_run_progress`

```python
# core/helix/runtime/runs/manager.py
    async def update_run_completion(self, run_id: str, **kwargs) -> None:
        """Persist token usage and completion data to the backing store."""
        row_recovery_payload: dict[str, Any] | None = None
        async with self._lock:
            record = self._runs.get(run_id)
            if record is not None:
                for key, value in kwargs.items():
                    if key == "status":
                        continue
                    if hasattr(record, key) and value is not None:
                        setattr(record, key, value)
                record.updated_at = _now_iso()
                row_recovery_payload = self._store_put_payload(record, error=kwargs.get("error"))
        if self._store is None:
            return
        try:
            updated = await self._call_store_with_retry(
                "update_run_completion",
                run_id,
                lambda: self._store.update_run_completion(run_id, **kwargs),
            )
            if updated is False:
                if row_recovery_payload is None:
                    logger.warning("Failed to recreate missing run %s for completion persistence", run_id)
                    return
                if not await self._persist_snapshot_to_store(run_id, row_recovery_payload):
                    return
                recovered = await self._call_store_with_retry(
                    "update_run_completion",
                    run_id,
                    lambda: self._store.update_run_completion(run_id, **kwargs),
                )
                if recovered is False:
                    logger.warning("Run completion update for %s affected no rows after row recreation", run_id)
        except Exception:
            logger.warning("Failed to persist run completion for %s", run_id, exc_info=True)

    async def update_run_progress(self, run_id: str, **kwargs) -> None:
        """Persist a running token/message snapshot without changing status."""
        should_persist = True
        async with self._lock:
            record = self._runs.get(run_id)
            if record is not None:
                should_persist = record.status == RunStatus.running
            if record is not None and should_persist:
                for key, value in kwargs.items():
                    if hasattr(record, key) and value is not None:
                        setattr(record, key, value)
                record.updated_at = _now_iso()
        if should_persist and self._store is not None:
            try:
                await self._store.update_run_progress(run_id, **kwargs)
            except Exception:
                logger.warning("Failed to persist run progress for %s", run_id, exc_info=True)
```

> **`update_run_progress` 终态守卫**：`should_persist = record.status == RunStatus.running` 是必须的，否则 token 累计会污染已经 success/error 的快照。

### 4.4 `create`

```python
# core/helix/runtime/runs/manager.py
    async def create(
        self,
        thread_id: str,
        assistant_id: str | None = None,
        *,
        on_disconnect: DisconnectMode = DisconnectMode.cancel,
        metadata: dict | None = None,
        kwargs: dict | None = None,
        multitask_strategy: str = "reject",
        user_id: str | None = None,
    ) -> RunRecord:
        """Create a new pending run and register it."""
        run_id = str(uuid.uuid4())
        now = _now_iso()
        record = RunRecord(
            run_id=run_id,
            thread_id=thread_id,
            assistant_id=assistant_id,
            status=RunStatus.pending,
            on_disconnect=on_disconnect,
            multitask_strategy=multitask_strategy,
            metadata=metadata or {},
            kwargs=kwargs or {},
            user_id=user_id,
            created_at=now,
            updated_at=now,
        )
        async with self._lock:
            self._runs[run_id] = record
            self._index_run_locked(record)
            persisted = False
            try:
                await self._persist_new_run_to_store(record)
                persisted = True
            except Exception:
                logger.warning("Failed to persist run %s; rolled back in-memory record", run_id, exc_info=True)
                raise
            finally:
                # Also covers cancellation, which bypasses ``except Exception``.
                if not persisted:
                    self._runs.pop(run_id, None)
                    self._unindex_run_locked(run_id, record.thread_id)
        logger.info("Run created: run_id=%s thread_id=%s", run_id, thread_id)
        return record
```

### 4.5 `get` + `aget`

```python
# core/helix/runtime/runs/manager.py
    async def get(self, run_id: str, *, user_id: str | None = None) -> RunRecord | None:
        """Return a run record by ID, or ``None``.

        Args:
            run_id: The run ID to look up.
            user_id: Optional user ID for permission filtering when hydrating from store.
        """
        async with self._lock:
            record = self._runs.get(run_id)
        if record is not None:
            return record
        if self._store is None:
            return None
        try:
            row = await self._store.get(run_id, user_id=user_id)
        except Exception:
            logger.warning("Failed to hydrate run %s from store", run_id, exc_info=True)
            return None
        # Re-check after store await: a concurrent create() may have inserted the
        # in-memory record while the store call was in flight.
        async with self._lock:
            record = self._runs.get(run_id)
        if record is not None:
            return record
        if row is None:
            return None
        try:
            return self._record_from_store(row)
        except Exception:
            logger.warning("Failed to map store row for run %s", run_id, exc_info=True)
            return None

    async def aget(self, run_id: str, *, user_id: str | None = None) -> RunRecord | None:
        """Return a run record by ID, checking the persistent store as fallback.

        Alias for :meth:`get` for backward compatibility.
        """
        return await self.get(run_id, user_id=user_id)
```

> `get` 先查内存；未命中再查 store 并反水化为 `store_only=True` 的只读 record。store await 后重查内存，防并发 `create()` 在 await 期间插入。

### 4.6 `list_by_thread`

```python
# core/helix/runtime/runs/manager.py
    async def list_by_thread(self, thread_id: str, *, user_id: str | None = None, limit: int = 100) -> list[RunRecord]:
        """Return runs for a given thread, newest first, at most ``limit`` records.

        In-memory runs take precedence only when the same ``run_id`` exists in both
        memory and the backing store. The merged result is then sorted newest-first
        by ``created_at`` and trimmed to ``limit`` (default 100).

        Args:
            thread_id: The thread ID to filter by.
            user_id: Optional user ID for permission filtering when hydrating from store.
            limit: Maximum number of runs to return.
        """
        async with self._lock:
            memory_records = self._thread_records_locked(thread_id)
        if self._store is None:
            return sorted(memory_records, key=lambda r: r.created_at, reverse=True)[:limit]
        records_by_id = {record.run_id: record for record in memory_records}
        store_limit = max(0, limit - len(memory_records))
        try:
            rows = await self._store.list_by_thread(thread_id, user_id=user_id, limit=store_limit)
        except Exception:
            logger.warning("Failed to hydrate runs for thread %s from store", thread_id, exc_info=True)
            return sorted(memory_records, key=lambda r: r.created_at, reverse=True)[:limit]
        for row in rows:
            run_id = row.get("run_id")
            if run_id and run_id not in records_by_id:
                try:
                    records_by_id[run_id] = self._record_from_store(row)
                except Exception:
                    logger.warning("Failed to map store row for run %s", run_id, exc_info=True)
        return sorted(records_by_id.values(), key=lambda record: record.created_at, reverse=True)[:limit]
```

### 4.7 `set_status` + `set_finalizing` + `wait_for_prior_finalizing` + `has_later_started_run`

```python
# core/helix/runtime/runs/manager.py
    async def set_status(self, run_id: str, status: RunStatus, *, error: str | None = None) -> None:
        """Transition a run to a new status."""
        async with self._lock:
            record = self._runs.get(run_id)
            if record is None:
                logger.warning("set_status called for unknown run %s", run_id)
                return
            record.status = status
            record.updated_at = _now_iso()
            if error is not None:
                record.error = error
        await self._persist_status(record, status, error=error)
        logger.info("Run %s -> %s", run_id, status.value)

    async def set_finalizing(self, run_id: str, finalizing: bool) -> None:
        """Mark whether a run is performing post-cancel cleanup."""
        async with self._lock:
            record = self._runs.get(run_id)
            if record is None:
                logger.warning("set_finalizing called for unknown run %s", run_id)
                return
            record.finalizing = finalizing
            record.updated_at = _now_iso()

    async def wait_for_prior_finalizing(
        self,
        thread_id: str,
        run_id: str,
        *,
        poll_interval: float = 0.01,
    ) -> None:
        """Wait until older same-thread runs have finished post-cancel cleanup."""
        while True:
            async with self._lock:
                found_current = False
                prior_finalizing = False
                for record in self._thread_records_locked(thread_id):
                    if record.run_id == run_id:
                        found_current = True
                        break
                    if record.finalizing:
                        prior_finalizing = True

                if not found_current or not prior_finalizing:
                    return

            await asyncio.sleep(poll_interval)

    async def has_later_run(self, thread_id: str, run_id: str) -> bool:
        """Return whether a newer in-memory run has been admitted for the thread."""
        async with self._lock:
            seen_current = False
            for record in self._thread_records_locked(thread_id):
                if record.run_id == run_id:
                    seen_current = True
                    continue
                if seen_current:
                    return True
        return False

    async def has_later_started_run(self, thread_id: str, run_id: str) -> bool:
        """Return whether a newer same-thread run may have already advanced state."""
        async with self._lock:
            seen_current = False
            for record in self._thread_records_locked(thread_id):
                if record.run_id == run_id:
                    seen_current = True
                    continue
                if seen_current and (record.status != RunStatus.pending or record.finalizing):
                    return True
        return False
```

> `wait_for_prior_finalizing` + `has_later_started_run` 是 multitask 抢占后的排序保证：新 run 等旧 run 的 rollback/interrupt 清理完再开工；若已有更晚的 run 起来推进了状态，本 run 的 interrupted-title 生成等清理跳过。

### 4.8 `cancel`（协作式取消核心）

```python
# core/helix/runtime/runs/manager.py
    async def cancel(self, run_id: str, *, action: str = "interrupt") -> bool:
        """Request cancellation of a run.

        Args:
            run_id: The run ID to cancel.
            action: "interrupt" keeps checkpoint, "rollback" reverts to pre-run state.

        Sets the abort event with the action reason and cancels the asyncio task.
        Returns ``True`` if cancellation was initiated **or** the run was already
        interrupted (idempotent - a second cancel is a no-op success).
        Returns ``False`` only when the run is unknown to this worker or has
        reached a terminal state other than interrupted (completed, failed, etc.).
        """
        async with self._lock:
            record = self._runs.get(run_id)
            if record is None:
                return False
            if record.status == RunStatus.interrupted:
                return True  # idempotent - already cancelled on this worker
            if record.status not in (RunStatus.pending, RunStatus.running):
                return False
            record.abort_action = action
            record.abort_event.set()
            task_active = record.task is not None and not record.task.done()
            record.finalizing = task_active
            if task_active:
                record.task.cancel()
            record.status = RunStatus.interrupted
            record.updated_at = _now_iso()
        await self._persist_status(record, RunStatus.interrupted)
        logger.info("Run %s cancelled (action=%s)", run_id, action)
        return True
```

> **`cancel` 只设状态、不做 IO 重活**：设 `abort_action` + `abort_event` + `task.cancel()`，回滚/状态恢复留给 worker 终结路径（在 worker 的 finally 语义内保证触发）。这把"取消决策"与"状态恢复"解耦，避免持锁做 checkpointer IO 阻塞 run 注册。
>
> **幂等**：已 `interrupted` 再次 `cancel` 返回 `True`（no-op 成功）；已 `success/error` 返回 `False`。前端重复点取消不致 500。
>
> **`abort_action` 先于 `abort_event` 设置**：rollback / interrupt 共用同一 `abort_event`，靠 action 字段区分；顺序反了 worker 看到 event 但读到旧 action。

### 4.9 `create_or_reject`（multitask 抢占）

```python
# core/helix/runtime/runs/manager.py
    async def create_or_reject(
        self,
        thread_id: str,
        assistant_id: str | None = None,
        *,
        on_disconnect: DisconnectMode = DisconnectMode.cancel,
        metadata: dict | None = None,
        kwargs: dict | None = None,
        multitask_strategy: str = "reject",
        model_name: str | None = None,
        user_id: str | None = None,
    ) -> RunRecord:
        """Atomically check for inflight runs and create a new one.

        For ``reject`` strategy, raises ``ConflictError`` if thread
        already has a pending/running run.  For ``interrupt``/``rollback``,
        cancels inflight runs before creating.

        This method holds the lock across both the check and the insert,
        eliminating the TOCTOU race in separate ``has_inflight`` + ``create``.
        """
        run_id = str(uuid.uuid4())
        now = _now_iso()

        _supported_strategies = ("reject", "interrupt", "rollback")
        interrupted_records: list[RunRecord] = []

        async with self._lock:
            if multitask_strategy not in _supported_strategies:
                raise UnsupportedStrategyError(f"Multitask strategy '{multitask_strategy}' is not yet supported. Supported strategies: {', '.join(_supported_strategies)}")

            inflight = [r for r in self._thread_records_locked(thread_id) if r.status in (RunStatus.pending, RunStatus.running) or r.finalizing]

            if multitask_strategy == "reject" and inflight:
                raise ConflictError(f"Thread {thread_id} already has an active run")

            if multitask_strategy in ("interrupt", "rollback") and inflight:
                logger.info(
                    "Preparing to cancel %d inflight run(s) on thread %s (strategy=%s)",
                    len(inflight),
                    thread_id,
                    multitask_strategy,
                )

            record = RunRecord(
                run_id=run_id,
                thread_id=thread_id,
                assistant_id=assistant_id,
                status=RunStatus.pending,
                on_disconnect=on_disconnect,
                multitask_strategy=multitask_strategy,
                metadata=metadata or {},
                kwargs=kwargs or {},
                user_id=user_id,
                created_at=now,
                updated_at=now,
                model_name=model_name,
            )
            self._runs[run_id] = record
            self._index_run_locked(record)
            persisted = False
            try:
                await self._persist_new_run_to_store(record)
                persisted = True
            except Exception:
                logger.warning("Failed to persist run %s; rolled back in-memory record", run_id, exc_info=True)
                raise
            finally:
                # Also covers cancellation, which bypasses ``except Exception``.
                if not persisted:
                    self._runs.pop(run_id, None)
                    self._unindex_run_locked(run_id, record.thread_id)

            if multitask_strategy in ("interrupt", "rollback") and inflight:
                for r in inflight:
                    if r.finalizing:
                        continue
                    r.abort_action = multitask_strategy   # 新 run 抢占时，旧 run 按 strategy 终结
                    r.abort_event.set()
                    task_active = r.task is not None and not r.task.done()
                    r.finalizing = task_active
                    if task_active:
                        r.task.cancel()
                    r.status = RunStatus.interrupted
                    r.updated_at = now
                    interrupted_records.append(r)

        for interrupted_record in interrupted_records:
            await self._persist_status(interrupted_record, RunStatus.interrupted)
        logger.info("Run created: run_id=%s thread_id=%s", run_id, thread_id)
        return record
```

> **multitask 策略**：
> - `reject`（默认）：thread 已有 pending/running/finalizing run -> 抛 `ConflictError` -> HTTP 409。
> - `interrupt`：对在途 run 设 `abort_action="interrupt"` + `abort_event` + `task.cancel()`，worker 终结时**保留 checkpoint**（`set_status(interrupted)`），新 run 接续。
> - `rollback`：同上但 `abort_action="rollback"`，worker 终结时**回滚到 pre-run checkpoint**（`_rollback_to_pre_run_checkpoint`），新 run 从干净状态开始。
>
> **TOCTOU 消除**：持锁跨"检查在途 + 插入新 run"，规避分立 `has_inflight` + `create` 的竞争窗口。`enqueue` 未实现，传入抛 `UnsupportedStrategyError` -> HTTP 501。

### 4.10 `reconcile_orphaned_inflight_runs`（启动孤儿恢复）

```python
# core/helix/runtime/runs/manager.py
    async def reconcile_orphaned_inflight_runs(
        self,
        *,
        error: str,
        before: str | None = None,
    ) -> list[RunRecord]:
        """Mark persisted active runs as failed when no local task owns them.

        Gateway runs are process-local: the asyncio task and abort event live in
        memory, while the run row is durable.  After a SQLite-backed gateway
        restart, any persisted ``pending`` or ``running`` row created before
        startup cannot still have a local worker.  This recovery step turns that
        ambiguous state into an explicit error instead of letting the UI show an
        indefinite active run.
        """
        if self._store is None:
            return []
        try:
            rows = await self._call_store_with_retry(
                "list_inflight",
                "*",
                lambda: self._store.list_inflight(before=before),
            )
        except Exception:
            logger.warning("Failed to list orphaned inflight runs for reconciliation", exc_info=True)
            return []

        recovered: list[RunRecord] = []
        now = _now_iso()
        for row in rows:
            try:
                record = self._record_from_store(row)
            except Exception:
                logger.warning("Failed to map orphaned run row during reconciliation", exc_info=True)
                continue

            async with self._lock:
                live_record = self._runs.get(record.run_id)
                if live_record is not None and live_record.status in (RunStatus.pending, RunStatus.running):
                    continue

            record.status = RunStatus.error
            record.error = error
            record.updated_at = now
            persisted = await self._persist_status(record, RunStatus.error, error=error)
            if not persisted:
                logger.warning("Skipped orphaned run %s recovery because error status was not persisted", record.run_id)
                continue
            recovered.append(record)

        if recovered:
            logger.warning("Recovered %d orphaned inflight run(s) as error", len(recovered))
        return recovered
```

> **孤儿恢复语义**：gateway run 是进程局部的（asyncio task/abort_event 在内存，run 行在 store 持久）。SQLite 单进程重启后，store 里残留的 `pending/running` 行不可能还有本地 worker。本方法把这些歧义行刷成 `error`，避免 UI 永久显示活跃 run。恢复后还需要 `publish_end` 收尾流 + 标记线程 error（见 `stream-bridge-resume.md` 的 `_publish_recovered_run_stream_end` / `_mark_latest_recovered_threads_error`）。

### 4.11 `has_inflight` + `cleanup`

```python
# core/helix/runtime/runs/manager.py
    async def has_inflight(self, thread_id: str) -> bool:
        """Return ``True`` if *thread_id* has a pending or running run."""
        async with self._lock:
            return any(r.status in (RunStatus.pending, RunStatus.running) or r.finalizing for r in self._thread_records_locked(thread_id))

    async def cleanup(self, run_id: str, *, delay: float = 300) -> None:
        """Remove a run record after an optional delay."""
        if delay > 0:
            await asyncio.sleep(delay)
        async with self._lock:
            record = self._runs.pop(run_id, None)
            if record is not None:
                self._unindex_run_locked(run_id, record.thread_id)
        logger.debug("Run record %s cleaned up", run_id)
```

> `cleanup(delay=300)`：内存 RunRecord 清理延迟 300s，给慢端点拉历史留时间（与 bridge 的 `cleanup(delay=60)` 区分：前者是控制面记录，后者是数据面事件流）。

### 4.12 `shutdown`（drain 全部在途 run）

```python
# core/helix/runtime/runs/manager.py
    async def shutdown(self, *, timeout: float = 5.0) -> None:
        """Cancel and bounded-await all in-flight runs on process shutdown.

        Chat runs execute in fire-and-forget background ``asyncio`` tasks that
        write checkpoints through a shared checkpointer. On shutdown the
        checkpointer's resources (e.g. the postgres connection pool owned by the
        gateway's ``AsyncExitStack``) are torn down; if a run task is still
        mid-graph at that point, langgraph's
        ``AsyncPregelLoop._checkpointer_put_after_previous`` runs its
        ``finally: await checkpointer.aput(...)`` against the closed pool. Because
        that put runs in a langgraph-internal task (not on ``run_agent``'s call
        stack), the resulting ``psycopg_pool.PoolClosed`` is not catchable by the
        worker and surfaces as an unhandled exception during ``asyncio.run()``
        shutdown (issue #3373).

        Draining in-flight runs *before* the checkpointer is closed lets each
        run that settles within ``timeout`` flush its final checkpoint while
        resources are still open. Only runs that do **not** settle on their own
        are marked ``interrupted`` - a run that completes (e.g. ``success``)
        during the drain keeps its real terminal status instead of being
        blanket-overwritten. The whole drain, including the trailing status
        persistence, is bounded by ``timeout`` so a run stuck in cleanup (or a
        slow store under DB pressure) cannot hang worker shutdown - the
        precondition for the signal-reentrancy deadlock guarded by
        ``gateway/gateway/app._SHUTDOWN_HOOK_TIMEOUT_SECONDS``. Runs still active
        after ``timeout`` are logged and may still race teardown.
        """
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout

        async with self._lock:
            inflight = [record for record in self._runs.values() if record.status in (RunStatus.pending, RunStatus.running) and record.task is not None and not record.task.done()]
            for record in inflight:
                record.abort_action = "interrupt"
                record.abort_event.set()
                record.task.cancel()  # type: ignore[union-attr]  # filtered above
                # Status is decided AFTER the drain (below), not here: a run that
                # completes on its own during the drain must keep its real status.

        if not inflight:
            return

        tasks = [record.task for record in inflight]
        _, pending = await asyncio.wait(tasks, timeout=timeout)

        # Only mark/persist ``interrupted`` for runs that did not settle on their
        # own (still pending after the timeout, or ended cancelled). A run that
        # finished normally during the drain keeps the status it set for itself.
        to_persist: list[RunRecord] = []
        async with self._lock:
            for record in inflight:
                task = record.task
                if task not in pending and not task.cancelled():
                    # Completed on its own - retrieve any surfaced exception so it
                    # is not reported as "never retrieved", and keep its status.
                    task.exception()  # type: ignore[union-attr]  # done & not cancelled
                    continue
                if record.status in (RunStatus.pending, RunStatus.running):
                    record.status = RunStatus.interrupted
                    record.updated_at = _now_iso()
                to_persist.append(record)

        # Bound the trailing status persistence within the remaining budget so a
        # slow store (``_call_store_with_retry`` can back off under DB pressure)
        # cannot push shutdown past ``timeout``.
        if to_persist:
            remaining = deadline - loop.time()
            if remaining <= 0:
                logger.warning("Run drain budget exhausted before persisting %d interrupted run(s) on shutdown", len(to_persist))
            else:
                try:
                    results = await asyncio.wait_for(
                        asyncio.gather(*(self._persist_status(record, RunStatus.interrupted) for record in to_persist), return_exceptions=True),
                        timeout=remaining,
                    )
                except TimeoutError:
                    logger.warning("Run drain status persistence exceeded the %.1fs budget; %d record(s) may not be persisted", timeout, len(to_persist))
                else:
                    # ``_persist_status`` is best-effort: it catches and logs its
                    # own failures, returning ``False``. Inspect the aggregate so a
                    # partial failure is surfaced at shutdown level (with the
                    # run_id) instead of being silently swallowed by the gather.
                    for record, result in zip(to_persist, results):
                        if isinstance(result, Exception):
                            logger.warning("Unexpected error persisting interrupted status for run %s during shutdown: %r", record.run_id, result)
                        elif result is False:
                            logger.warning("Could not persist interrupted status for run %s during shutdown", record.run_id)

        if pending:
            logger.warning("Run drain exceeded %.1fs on shutdown; %d run task(s) still active and may race checkpointer teardown", timeout, len(pending))
        logger.info("Drained %d in-flight run(s) on shutdown (%d settled within %.1fs)", len(inflight), len(inflight) - len(pending), timeout)
```

> **shutdown drain 不变量**：
> 1. 先 abort 全部在途 run，`asyncio.wait(tasks, timeout=...)` 让走得动的 run 自然 flush checkpoint。
> 2. drain 期间"自己跑完"的 run 保留真实终态（`success` / `error`），**不被** blanket 覆盖成 `interrupted`（`task not in pending and not task.cancelled()` 分支）。
> 3. 状态持久化在剩余预算内 `wait_for`，避免 store 卡 shutdown -> 信号重入死锁。
> 4. 整个 drain bounded by `timeout`（默认 5s），超时的 run 记 warn、可能 race checkpointer teardown。
>
> **issue #3373 根因**：langgraph 内部 task 跑 `finally: await checkpointer.aput(...)` 撞关闭的 pool，`PoolClosed` 不在 worker 调用栈上 -> 不可被 worker 捕获 -> `asyncio.run()` shutdown 抛未处理异常。drain 在 checkpointer 关闭前让 run 自然 settle 是修复。

### 4.13 异常类

```python
# core/helix/runtime/runs/manager.py
class ConflictError(Exception):
    """Raised when multitask_strategy=reject and thread has inflight runs."""


class UnsupportedStrategyError(Exception):
    """Raised when a multitask_strategy value is not yet implemented."""
```

---

## 关键不变量与测试锚点

1. **状态机**：`pending -> running -> {success | error | timeout | interrupted}`，终态吸收态；`set_status` 每次一行日志 `Run %s -> %s`。
2. **TOCTOU 消除**：`create_or_reject` 持锁跨"检查在途 + 插入"，无 `await` 跨越。
3. **二级索引原子**：`_runs` 与 `_runs_by_thread` 同一把 `_lock` 内串行写入。
4. **创建可见性边界**：`_persist_new_run_to_store` 失败回滚内存记录；状态更新 best-effort。
5. **cancel 幂等**：已 `interrupted` 返回 `True`，已终态返回 `False`。
6. **`abort_action` 先于 `abort_event`**：rollback/interrupt 共用 event，靠 action 区分。
7. **cancel 不持锁做 IO**：回滚/状态恢复留给 worker 终结路径。
8. **`finalizing` 视为在途**：`create_or_reject` / `has_inflight` 都把 `finalizing` 算活跃。
9. **孤儿恢复**：启动 `reconcile_orphaned_inflight_runs` 把 store 残留 pending/running 刷 `error`（仅 SQLite 单进程）。
10. **shutdown drain**：自跑完的保留真实终态；超时 `interrupted`；持久化在预算内 bounded。
11. **`store_only` 不可取消**：跨 worker 反水化的 record，`cancel` 返回 `False`（本 worker 无 task）。

> 关联：`[[gateway-runs-and-sse]]`（lifespan 装配 RunManager 单例 + 路由）、`stream-bridge-resume.md`（on_disconnect/wait/孤儿流收尾）、`worker-checkpoint-rollback.md`（worker 读 abort_action 走 rollback）。
