# StreamBridge 续传契约 + on_disconnect/wait + 孤儿恢复完整源码

> 本文件是 `long-running-and-cancellation` skill 的深度代码分节：`StreamBridge` 抽象契约、`{ts}-{seq}` O(1) 续传定位、`END_SENTINEL` 跨进程 round-trip、`sse_consumer` 的 `on_disconnect` finally 语义、`wait_for_run_completion`（不 `await record.task`，issue #3265）、启动孤儿 run 恢复（`reconcile_orphaned_inflight_runs` + `_publish_recovered_run_stream_end` + `_mark_latest_recovered_threads_error`）的**完整真实源码**。
>
> 代码已按插件匿名化规则映射到自定结构（`helix.*` / `gateway.*`），去除一切项目字样；原代码注释保真，中文注解以行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱 ⑦流式 + 跨切不变量 3）、`[[gateway-runs-and-sse]]`（lifespan 装配 + Redis 跨进程 bridge 全貌 + 路由）、`run-manager.md`（`reconcile_orphaned_inflight_runs` / `cancel`）、`worker-checkpoint-rollback.md`（worker `publish_end` 触发 `END_SENTINEL`）。`MemoryStreamBridge` 的完整 `publish`/`subscribe` 循环亦见脊柱 `references/code/07-streaming-and-resume.md`；本文件聚焦续传定位 + 断连/等待/孤儿收尾。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `core/helix/runtime/stream_bridge/base.py` | `StreamBridge` 抽象契约 + `StreamEvent` + `HEARTBEAT_SENTINEL` / `END_SENTINEL` |
| `core/helix/runtime/stream_bridge/memory.py` | `MemoryStreamBridge`：`{ts}-{seq}` id + O(1) 续传定位 + 有界 buffer |
| `core/helix/runtime/stream_bridge/redis.py` | `RedisStreamBridge`：Redis Stream + `XREAD BLOCK` + `END_SENTINEL` 跨进程 + `stream_exists` |
| `gateway/gateway/services.py` | `format_sse` + `sse_consumer`（on_disconnect finally）+ `wait_for_run_completion` |
| `gateway/gateway/deps.py` | lifespan 孤儿恢复接线 + `_publish_recovered_run_stream_end` + `_mark_latest_recovered_threads_error` + `get_stream_bridge` / `get_run_manager` |
| `gateway/gateway/routers/thread_runs.py` | `join_run` / `stream_existing_run` / `cancel_run` 端点（重连 + 取消面） |

---

## 1. `StreamBridge` 抽象契约（`base.py` 完整）

```python
# core/helix/runtime/stream_bridge/base.py
"""Abstract stream bridge protocol.

StreamBridge decouples agent workers (producers) from SSE endpoints
(consumers), aligning with LangGraph Platform's Queue + StreamManager
architecture.
"""

from __future__ import annotations

import abc
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class StreamEvent:
    """Single stream event.

    Attributes:
        id: Monotonically increasing event ID (used as SSE ``id:`` field,
            supports ``Last-Event-ID`` reconnection).
        event: SSE event name, e.g. ``"metadata"``, ``"updates"``,
            ``"events"``, ``"error"``, ``"end"``.
        data: JSON-serialisable payload.
    """

    id: str
    event: str
    data: Any


HEARTBEAT_SENTINEL = StreamEvent(id="", event="__heartbeat__", data=None)
END_SENTINEL = StreamEvent(id="", event="__end__", data=None)


class StreamBridge(abc.ABC):
    """Abstract base for stream bridges."""

    supports_cross_process: bool = False

    @abc.abstractmethod
    async def publish(self, run_id: str, event: str, data: Any) -> None:
        """Enqueue a single event for *run_id* (producer side)."""

    @abc.abstractmethod
    async def publish_end(self, run_id: str) -> None:
        """Signal that no more events will be produced for *run_id*."""

    @abc.abstractmethod
    def subscribe(
        self,
        run_id: str,
        *,
        last_event_id: str | None = None,
        heartbeat_interval: float = 15.0,
    ) -> AsyncIterator[StreamEvent]:
        """Async iterator that yields events for *run_id* (consumer side).

        Yields :data:`HEARTBEAT_SENTINEL` when no event arrives within
        *heartbeat_interval* seconds.  Yields :data:`END_SENTINEL` once
        the producer calls :meth:`publish_end`.
        """

    @abc.abstractmethod
    async def cleanup(self, run_id: str, *, delay: float = 0) -> None:
        """Release resources associated with *run_id*.

        If *delay* > 0 the implementation should wait before releasing,
        giving late subscribers a chance to drain remaining events.
        """

    async def close(self) -> None:
        """Release backend resources.  Default is a no-op."""
```

> **单一事实源 + 0/多订阅者**：worker 是生产者（`publish`），HTTP SSE 端点是消费者（`subscribe`）。bridge 解耦二者：客户端断了不影响 worker；可以有 0 个（后台 run 无人看）或多个（管理端 + 用户端）订阅者。`supports_cross_process` 标志是否可跨进程（仅 `RedisStreamBridge` 为 True）。

---

## 2. `MemoryStreamBridge` 续传定位（`memory.py` 续传核心方法）

```python
# core/helix/runtime/stream_bridge/memory.py
class MemoryStreamBridge(StreamBridge):
    """Per-run in-memory event log implementation.

    Events are retained for a bounded time window per run so late subscribers
    and reconnecting clients can replay buffered events from ``Last-Event-ID``.
    """

    def __init__(self, *, queue_maxsize: int = 256) -> None:
        self._maxsize = queue_maxsize
        self._streams: dict[str, _RunStream] = {}
        self._counters: dict[str, int] = {}

    def _next_id(self, run_id: str) -> str:
        # 事件 id = {ts}-{seq}；seq 是 per-run 单调递增的绝对偏移
        self._counters[run_id] = self._counters.get(run_id, 0) + 1
        ts = int(time.time() * 1000)
        seq = self._counters[run_id] - 1
        return f"{ts}-{seq}"

    @staticmethod
    def _parse_event_seq(event_id: str) -> int | None:
        """Extract the per-run sequence number from a ``{ts}-{seq}`` event id.

        ``seq`` (assigned by :meth:`_next_id`) increases by one per published
        event, so it equals the event's absolute offset within the run. Returns
        ``None`` for ids that do not match the expected format.
        """
        _, sep, seq_text = event_id.rpartition("-")
        if not sep:
            return None
        try:
            return int(seq_text)
        except ValueError:
            return None

    def _resolve_start_offset(self, stream: _RunStream, last_event_id: str | None) -> int:
        if last_event_id is None:
            return stream.start_offset

        # 事件 id 内嵌 per-run 单调 seq == 绝对偏移，故用算术 O(1) 定位而非扫描 buffer。
        # 在算出的索引处再校验 id：陈旧/驱逐/伪造/他 run 的 id 仍降级到"从最早保留事件重放"--
        # 与旧线性扫描等价。
        seq = self._parse_event_seq(last_event_id)
        if seq is not None:
            local_index = seq - stream.start_offset
            if 0 <= local_index < len(stream.events) and stream.events[local_index].id == last_event_id:
                return stream.start_offset + local_index + 1   # 命中：从该事件之后续发

        if stream.events:
            logger.warning(
                "last_event_id=%s not found in retained buffer; replaying from earliest retained event",
                last_event_id,
            )
        return stream.start_offset
```

> **续传 O(1) 命中**：`_resolve_start_offset` 用 `seq - start_offset` 算 `local_index`，校验 `events[local_index].id == last_event_id`，命中返回 `start_offset + local_index + 1`。`seq` 是 per-run 单调递增绝对偏移，所以续传定位是算术 O(1)，无需线性扫描 buffer。
>
> **续传降级**：陈旧/驱逐/伪造/他 run 的 id -> 从 `start_offset`（最早保留事件）重放，记 warn。
>
> **buffer 有界**：`queue_maxsize=256`，溢出驱逐最旧、`start_offset` 前移（见 `publish`，完整实现见脊柱 `07-streaming-and-resume.md`）。订阅者落后驱逐速度时也降级恢复。
>
> `MemoryStreamBridge` 的完整 `publish` / `publish_end` / `subscribe` 循环（含 `END_SENTINEL` yield、心跳 `HEARTBEAT_SENTINEL`、`cleanup`）见脊柱 `references/code/07-streaming-and-resume.md`。

---

## 3. `RedisStreamBridge` 跨进程续传（`redis.py` 续传 + END_SENTINEL round-trip 关键方法）

```python
# core/helix/runtime/stream_bridge/redis.py
_KIND_EVENT = "event"
_KIND_END = "end"

# Batch size for ``XREAD``. Reading more than one entry per round-trip collapses
# a large ``Last-Event-ID`` replay into far fewer calls; live tailing still
# yields each event as it arrives because the consume loop returns mid-batch on
# the end marker.
_XREAD_COUNT = 64

# Maximum consecutive transient Redis errors tolerated during ``subscribe``.
_MAX_SUBSCRIBE_RETRIES = 3


class RedisStreamBridge(StreamBridge):
    """Per-run stream bridge backed by Redis Streams.

    Each run is stored in one Redis Stream and subscribers read directly with
    ``XREAD``.  This keeps the SSE bridge usable across multiple gateway
    worker processes while preserving ``Last-Event-ID`` replay semantics.
    """

    supports_cross_process = True

    def __init__(
        self,
        *,
        redis_url: str,
        queue_maxsize: int = 256,
        key_prefix: str = "helix:stream_bridge",
        max_connections: int | None = None,
        stream_ttl_seconds: int | None = 86400,
        client: Redis | None = None,
    ) -> None:
        self._redis_url = redis_url
        self._maxsize = max(1, queue_maxsize)
        self._key_prefix = key_prefix.rstrip(":")
        if stream_ttl_seconds is not None and stream_ttl_seconds > 0:
            self._stream_ttl_seconds = stream_ttl_seconds
        else:
            self._stream_ttl_seconds = None
        # Each live SSE subscriber holds one pooled connection blocked in
        # ``XREAD ... BLOCK`` for up to ``heartbeat_interval``. ``max_connections``
        # caps that pool; ``None`` keeps redis-py's effectively-unbounded default.
        self._redis = client if client is not None else Redis.from_url(redis_url, decode_responses=True, max_connections=max_connections)
        self._owns_client = client is None

    def _stream_key(self, run_id: str) -> str:
        return f"{self._key_prefix}:{run_id}"

    @staticmethod
    def _decode(value: Any) -> str:
        if isinstance(value, bytes):
            return value.decode("utf-8")
        return str(value)

    @staticmethod
    def _encode_data(data: Any) -> str:
        return json.dumps(data, default=str, ensure_ascii=False, separators=(",", ":"))

    @staticmethod
    def _decode_data(raw: str | None) -> Any:
        if raw is None:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            logger.warning("Redis stream bridge received non-JSON event data")
            return raw

    def _entry_from_redis(self, event_id: str, fields: Mapping[Any, Any]) -> StreamEvent:
        payload = self._normalise_fields(fields)
        kind = payload.get("kind", _KIND_EVENT)
        if kind == _KIND_END:
            return END_SENTINEL                    # 跨进程 END_SENTINEL：解码 {"kind":"end"} 回单例
        return StreamEvent(
            id=event_id,
            event=payload.get("event", "message"),
            data=self._decode_data(payload.get("data")),
        )

    async def publish(self, run_id: str, event: str, data: Any) -> None:
        key = self._stream_key(run_id)
        await self._xadd_retained(
            key,
            {
                "kind": _KIND_EVENT,
                "event": event,
                "data": self._encode_data(data),
            },
            maxlen=self._maxsize,
        )

    async def publish_end(self, run_id: str) -> None:
        # Keep the configured number of data events plus the internal end marker.
        key = self._stream_key(run_id)
        await self._xadd_retained(
            key,
            {"kind": _KIND_END},
            maxlen=self._maxsize + 1,
        )

    async def stream_exists(self, run_id: str) -> bool:
        """Return whether Redis still has retained stream data for *run_id*."""
        return bool(await self._redis.exists(self._stream_key(run_id)))

    async def subscribe(
        self,
        run_id: str,
        *,
        last_event_id: str | None = None,
        heartbeat_interval: float = 15.0,
    ) -> AsyncIterator[StreamEvent]:
        key = self._stream_key(run_id)
        stream_id = last_event_id or "0-0"             # 客户端 Last-Event-ID 直接做 XREAD 起点
        block_ms = max(1, int(heartbeat_interval * 1000)) if heartbeat_interval > 0 else 1
        consecutive_errors = 0

        while True:
            try:
                response = await self._redis.xread({key: stream_id}, count=_XREAD_COUNT, block=block_ms)
            except ResponseError:
                # The only client-controllable stream ID is the Last-Event-ID
                # header, so a rejected ID means a malformed reconnect token:
                # fall back to replaying from the earliest retained event. We key
                # off the control flow rather than the error wording, which is the
                # server's text (Redis/Valkey/Dragonfly) and not a stable API. If
                # the reset read from "0-0" also fails, the stream/connection is
                # genuinely broken, so re-raise.
                if stream_id == "0-0":
                    raise
                logger.warning(
                    "Redis rejected Last-Event-ID %r for stream bridge; replaying from earliest retained event",
                    stream_id,
                    exc_info=True,
                )
                stream_id = "0-0"
                continue
            except RedisError:
                consecutive_errors += 1
                if consecutive_errors > _MAX_SUBSCRIBE_RETRIES:
                    raise
                delay = min(2**consecutive_errors, heartbeat_interval)
                logger.warning(
                    "Transient Redis error in stream bridge subscriber (retry %d/%d); backing off %.1fs",
                    consecutive_errors,
                    _MAX_SUBSCRIBE_RETRIES,
                    delay,
                    exc_info=True,
                )
                await asyncio.sleep(delay)
                continue
            else:
                consecutive_errors = 0

            if not response:
                yield HEARTBEAT_SENTINEL               # BLOCK 超时无事件：心跳保活
                continue

            for _stream_name, entries in response:
                for event_id, fields in entries:
                    event_id = self._decode(event_id)
                    stream_id = event_id
                    entry = self._entry_from_redis(event_id, fields)
                    if entry is END_SENTINEL:
                        yield END_SENTINEL
                        return
                    yield entry
```

> **跨进程续传**：`RedisStreamBridge` 把每个 run 存进一个 Redis Stream，订阅者用 `XREAD ... BLOCK` 读。`Last-Event-ID` 请求头直接做 `XREAD` 的起点 stream id（无内存 bridge 的 `{ts}-{seq}` 解析--Redis Stream id 本身就是单调递增的）。`XREAD` 一次读 `_XREAD_COUNT=64` 条，把大段 `Last-Event-ID` 重放压成少数几个往返。
>
> **`END_SENTINEL` 跨进程 round-trip**：`publish_end` 写一条 `{"kind": "end"}` 的 `XADD`（`maxlen = _maxsize + 1` 保留 end marker）；订阅者 `_entry_from_redis` 识别 `kind == "end"` 返回 `END_SENTINEL` 单例。于是多 worker 部署下，worker A 的 run 被 worker B 的客户端 `join` 时也能正确收到 `END_SENTINEL`。
>
> **`stream_exists`**：`_terminal_record_stream_missing` 与孤儿恢复用它判断终态 run 的流是否还在（Redis TTL 可能已过期）。仅 `RedisStreamBridge` 实现该可选方法。
>
> **TTL 是泄漏安全网，不是超时**：`stream_ttl_seconds=86400` 给 Redis Stream 一个兜底过期，防 worker 崩溃没跑 `cleanup` 时流永久残留。它**不**是 run 的执行超时--run 能跑多久由模型/工具自身决定，TTL 只管事件流残留清理。
>
> `_xadd_retained` / `_normalise_fields` / `cleanup` / `close` 等完整实现见 `core/helix/runtime/stream_bridge/redis.py`（深度见 `[[gateway-runs-and-sse]]`）。

---

## 4. `format_sse` + 终态判定 + `sse_consumer`（`on_disconnect` finally）

```python
# gateway/gateway/services.py
def format_sse(event: str, data: Any, *, event_id: str | None = None) -> str:
    """Format a single SSE frame.

    Field order: ``event:`` -> ``data:`` -> ``id:`` (optional) -> blank line.
    This matches the LangGraph Platform wire format consumed by the
    ``useStream`` React hook and the Python ``langgraph-sdk`` SSE decoder.
    """
    payload = json.dumps(data, default=str, ensure_ascii=False)
    parts = [f"event: {event}", f"data: {payload}"]
    if event_id:
        parts.append(f"id: {event_id}")
    parts.append("")
    parts.append("")
    return "\n".join(parts)


_TERMINAL_RUN_STATUSES = {
    RunStatus.success,
    RunStatus.error,
    RunStatus.timeout,
    RunStatus.interrupted,
}


def _run_is_terminal(record: RunRecord) -> bool:
    return record.status in _TERMINAL_RUN_STATUSES


async def _terminal_record_stream_missing(bridge: StreamBridge, record: RunRecord) -> bool:
    """True when a terminal run has no retained stream on bridges that can tell."""
    if not _run_is_terminal(record):
        return False
    stream_exists = getattr(bridge, "stream_exists", None)
    if stream_exists is None:
        return False
    try:
        return not bool(await stream_exists(record.run_id))
    except Exception:
        logger.debug(
            "Failed to probe stream existence for terminal run %s",
            sanitize_log_param(record.run_id),
            exc_info=True,
        )
        return False


async def sse_consumer(
    bridge: StreamBridge,
    record: RunRecord,
    request: Request,
    run_mgr: RunManager,
):
    """Async generator that yields SSE frames from the bridge.

    The ``finally`` block implements ``on_disconnect`` semantics:
    - ``cancel``: abort the background task on client disconnect.
    - ``continue``: let the task run; events are discarded.
    """
    last_event_id = request.headers.get("Last-Event-ID")        # 客户端重连带回最后收到的事件 id
    if await _terminal_record_stream_missing(bridge, record):
        yield format_sse("end", None)
        return

    try:
        async for entry in bridge.subscribe(record.run_id, last_event_id=last_event_id):   # 续传定位
            if await request.is_disconnected():
                break

            if entry is HEARTBEAT_SENTINEL:
                if await _terminal_record_stream_missing(bridge, record):
                    yield format_sse("end", None)
                    return
                yield ": heartbeat\n\n"                          # 心跳帧保活（防 nginx/浏览器 60s 静默关）
                continue

            if entry is END_SENTINEL:
                yield format_sse("end", None, event_id=entry.id or None)
                return

            yield format_sse(entry.event, entry.data, event_id=entry.id or None)

    finally:
        # store_only records are cross-worker runs hydrated from the RunStore; this
        # worker holds no in-memory task/abort state for them, so run_mgr.cancel()
        # cannot stop the task (it would 409). Skip on_disconnect cancellation for
        # those and only act on runs this worker actually owns.
        if not record.store_only and record.status in (RunStatus.pending, RunStatus.running):
            if record.on_disconnect == DisconnectMode.cancel:
                await run_mgr.cancel(record.run_id)
```

> **`on_disconnect` 语义（finally 块）**：
> - `cancel`（默认）：客户端 SSE 断开 + run 仍 pending/running + 本 worker 拥有（`not store_only`）-> `run_mgr.cancel(run_id)` 中止后台任务。
> - `continue`：让任务继续后台跑，事件丢弃；后续可经 `/join` 续看。
> - `store_only` 例外：跨 worker 反水化的 record，本 worker 无 task，`cancel` 会 409，跳过。
>
> **`_terminal_record_stream_missing`**：终态 run（success/error/timeout/interrupted）若 bridge 已无保留流（Redis TTL 过期 / 内存 cleanup 完），直接发 `end` 帧，不挂等 `subscribe`。心跳分支也复检，防终态 run 卡心跳循环。

---

## 5. `wait_for_run_completion`（`/wait` 路径，不 `await record.task`）

```python
# gateway/gateway/services.py
async def wait_for_run_completion(
    bridge: StreamBridge,
    record: RunRecord,
    request: Request,
    run_mgr: RunManager,
) -> bool:
    """Block until the run publishes ``END_SENTINEL``, honouring on_disconnect.

    The non-streaming ``/wait`` endpoints used to ``await record.task``
    directly with no disconnect handling.  When the client (or an
    intermediate HTTP proxy) timed out during a long tool call such as
    ``pip install``, the handler would swallow ``CancelledError`` and
    serialize whatever checkpoint happened to exist - masking a half-finished
    run as a normal completion (issue #3265).

    This helper consumes the same bridge that ``sse_consumer`` does so the
    wait path shares its disconnect semantics: each wake-up polls
    ``request.is_disconnected()``; on a real disconnect it cancels the
    background run when ``record.on_disconnect`` is ``cancel``.  The bridge's
    heartbeat sentinels guarantee at least one wake-up per
    ``heartbeat_interval`` even when the agent emits no events for a while.

    Returns:
        ``True`` when ``END_SENTINEL`` was observed (run reached a terminal
        state), ``False`` when the loop exited because the client
        disconnected.  Callers must skip checkpoint serialization on
        ``False`` so a partial checkpoint is not returned as a normal
        response.
    """
    completed = False
    if await _terminal_record_stream_missing(bridge, record):
        return True

    try:
        async for entry in bridge.subscribe(record.run_id):
            # END_SENTINEL means the run reached a terminal state; honour it
            # even if the client just disconnected so the caller still serializes
            # the real final checkpoint.
            if entry is END_SENTINEL:
                completed = True
                return True
            if entry is HEARTBEAT_SENTINEL and await _terminal_record_stream_missing(bridge, record):
                completed = True
                return True
            if await request.is_disconnected():
                break
            # Heartbeats and regular events: keep waiting for END_SENTINEL.
        return completed
    finally:
        if not completed and record.status in (RunStatus.pending, RunStatus.running):
            if record.on_disconnect == DisconnectMode.cancel:
                await run_mgr.cancel(record.run_id)
```

> **issue #3265 根因与修复**：旧 `/wait` 直接 `await record.task`，客户端/代理超时（如长 `pip install`）时 handler 吞掉 `CancelledError` 并序列化恰巧存在的 checkpoint -> 把半截 run 伪装成正常完成。修复：`wait_for_run_completion` 消费与 `sse_consumer` 相同的 bridge，心跳 sentinel 保证每 `heartbeat_interval` 至少唤醒一次 poll `is_disconnected()`；真断连且 `on_disconnect=cancel` 时取消后台 run，返回 `False`。路由层（`thread_runs.py` / `runs.py`）在 `completed=False` 时**跳过 checkpoint 序列化**，只回 `{"status":..., "error":...}`，杜绝返回 stale checkpoint。

---

## 6. 启动孤儿 run 恢复（`deps.py` lifespan 接线 + 收尾助手）

```python
# gateway/gateway/deps.py - lifespan 内（仅 SQLite 单进程路径）
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
```

```python
# gateway/gateway/deps.py
async def _publish_recovered_run_stream_end(
    bridge: StreamBridge,
    recovered_runs: list[RunRecord],
    *,
    cleanup_delay: float = 60.0,
) -> None:
    """Terminate retained streams for runs recovered as orphaned at startup."""
    for record in recovered_runs:
        stream_exists = getattr(bridge, "stream_exists", None)
        if stream_exists is not None:
            try:
                if not await stream_exists(record.run_id):
                    logger.debug("Skipping recovered stream end for %s: stream already expired", record.run_id)
                    continue
            except Exception:
                logger.debug("Failed to check recovered stream existence for %s", record.run_id, exc_info=True)
        try:
            await bridge.publish_end(record.run_id)          # 给残留流发 END_SENTINEL，让挂着的订阅者收尾
        except Exception:
            logger.warning(
                "Failed to publish recovered run stream end for %s",
                record.run_id,
                exc_info=True,
            )
            continue
        task = asyncio.create_task(bridge.cleanup(record.run_id, delay=cleanup_delay))
        task.add_done_callback(lambda task, run_id=record.run_id: _log_recovered_stream_cleanup_result(task, run_id))


def _log_recovered_stream_cleanup_result(task: asyncio.Task[None], run_id: str) -> None:
    if task.cancelled():
        return
    try:
        task.result()
    except Exception:
        logger.warning("Failed to clean up recovered run stream for %s", run_id, exc_info=True)


async def _mark_latest_recovered_threads_error(
    run_manager: RunManager,
    thread_store: ThreadMetaStore,
    recovered_runs: list[RunRecord],
) -> None:
    """Mark thread status as error only when its newest run was recovered."""
    recovered_by_thread: dict[str, set[str]] = {}
    for record in recovered_runs:
        recovered_by_thread.setdefault(record.thread_id, set()).add(record.run_id)

    for thread_id, recovered_run_ids in recovered_by_thread.items():
        try:
            latest_runs = await run_manager.list_by_thread(thread_id, user_id=None, limit=1)
        except Exception:
            logger.warning("Failed to find latest run for thread %s during run reconciliation", thread_id, exc_info=True)
            continue
        if not latest_runs or latest_runs[0].run_id not in recovered_run_ids:
            continue
        try:
            await thread_store.update_status(thread_id, "error", user_id=None)
        except Exception:
            logger.warning("Failed to mark thread %s as error during run reconciliation", thread_id, exc_info=True)
```

> **孤儿恢复三步**（启动时，仅 `database.backend == "sqlite"` 单进程路径）：
> 1. `RunManager.reconcile_orphaned_inflight_runs`（见 `run-manager.md`）：把 store 里残留的 `pending/running` 行刷成 `error`（本进程无 task 接管）。
> 2. `_publish_recovered_run_stream_end`：对每条恢复 run，若 bridge 还有保留流（`stream_exists`），`publish_end` 发 `END_SENTINEL` 让挂着的订阅者收尾，再 `cleanup(delay=60)`。
> 3. `_mark_latest_recovered_threads_error`：仅当被恢复 run 是该 thread 的**最新** run 时，才把 `threads_meta.status` 标 `error`（避免旧 run 恢复误盖一个已正常完成的新 run 的线程状态）。
>
> **为何仅 SQLite 单进程**：gateway run 是进程局部的（asyncio task/abort_event 在内存）。SQLite 单进程下，重启后 store 残留行必然无本地 worker。多 pod 部署需要 worker ownership/liveness 才能安全 reaper，否则会把别的 pod 还在跑的 run 误判孤儿--故此路径显式 gate 在 `backend == "sqlite"`。

---

## 7. shutdown drain 接线（`deps.py`）

```python
# gateway/gateway/deps.py
_RUN_DRAIN_TIMEOUT_SECONDS = 5.0   # 与 gateway/gateway/app._SHUTDOWN_HOOK_TIMEOUT_SECONDS 对齐


async def _drain_inflight_runs(run_manager: RunManager) -> None:
    """Drain in-flight runs before the checkpointer is torn down (issue #3373).

    Shields the (internally-bounded) drain so that even if the lifespan
    coroutine is itself cancelled mid-shutdown - a second SIGINT or the server's
    graceful-shutdown timeout, i.e. the same signal storm behind #3373 - the
    checkpointer pool is not closed while run tasks are still writing
    checkpoints. On such a cancellation we let the already-running drain finish
    (it is bounded by ``RunManager.shutdown``'s own timeout) and then propagate
    the cancellation.
    """
    drain = asyncio.create_task(run_manager.shutdown(timeout=_RUN_DRAIN_TIMEOUT_SECONDS))
    try:
        await asyncio.shield(drain)
    except asyncio.CancelledError:
        # Re-shield so this second wait does not abandon the in-flight drain;
        # it is bounded, so this cannot hang. Then re-raise to honour shutdown.
        try:
            await asyncio.shield(drain)
        except Exception:
            logger.exception("In-flight run drain failed after shutdown cancellation")
        raise
    except Exception:
        logger.exception("Failed to drain in-flight runs during shutdown")
```

> shutdown 时 lifespan 的 `finally` 调 `_drain_inflight_runs(run_manager)` -> `RunManager.shutdown(timeout=5.0)`（见 `run-manager.md`）。`asyncio.shield` 防 lifespan 协程被二次 SIGINT 取消时抛弃在途 drain（drain 自身 bounded，不会 hang）。完整 `RunManager.shutdown` 语义见 `run-manager.md`。

---

## 8. 重连 + 取消端点（`thread_runs.py`）

```python
# gateway/gateway/routers/thread_runs.py
@router.get("/{thread_id}/runs/{run_id}/join")
@require_permission("runs", "read", owner_check=True)
async def join_run(thread_id: str, run_id: str, request: Request) -> StreamingResponse:
    """Join an existing run's SSE stream."""
    run_mgr = get_run_manager(request)
    record = await run_mgr.get(run_id)
    if record is None or record.thread_id != thread_id:
        raise HTTPException(status_code=404, detail=f"Run {run_id} not found")
    bridge = get_stream_bridge(request)
    if record.store_only and not bridge.supports_cross_process:
        raise HTTPException(status_code=409, detail=f"Run {run_id} is not active on this worker and cannot be streamed")

    return StreamingResponse(
        sse_consumer(bridge, record, request, run_mgr),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# Register GET and POST as separate routes so each method gets a unique OpenAPI
# operationId. ``api_route(methods=["GET", "POST"])`` shares one route registration
# across both methods, which makes FastAPI emit the same ``operationId`` twice and
# warn about a duplicate operation id during OpenAPI generation.
@router.get("/{thread_id}/runs/{run_id}/stream", response_model=None)
@router.post("/{thread_id}/runs/{run_id}/stream", response_model=None)
@require_permission("runs", "read", owner_check=True)
async def stream_existing_run(
    thread_id: str,
    run_id: str,
    request: Request,
    action: Literal["interrupt", "rollback"] | None = Query(default=None, description="Cancel action"),
    wait: int = Query(default=0, description="Block until cancelled (1) or return immediately (0)"),
):
    """Join an existing run's SSE stream (GET), or cancel-then-stream (POST).

    The LangGraph SDK's ``joinStream`` and ``useStream`` stop button both use
    ``POST`` to this endpoint.  When ``action=interrupt`` or ``action=rollback``
    is present the run is cancelled first; the response then streams any
    remaining buffered events so the client observes a clean shutdown.
    """
    run_mgr = get_run_manager(request)
    record = await run_mgr.get(run_id)
    if record is None or record.thread_id != thread_id:
        raise HTTPException(status_code=404, detail=f"Run {run_id} not found")
    bridge = get_stream_bridge(request)
    if record.store_only and action is None and not bridge.supports_cross_process:
        raise HTTPException(status_code=409, detail=f"Run {run_id} is not active on this worker and cannot be streamed")

    # Cancel if an action was requested (stop-button / interrupt flow)
    if action is not None:
        cancelled = await run_mgr.cancel(run_id, action=action)
        if not cancelled:
            raise HTTPException(status_code=409, detail=_cancel_conflict_detail(run_id, record))
        if wait and record.task is not None:
            try:
                await record.task
            except (asyncio.CancelledError, Exception):
                pass
            return Response(status_code=204)

    return StreamingResponse(
        sse_consumer(bridge, record, request, run_mgr),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@router.post("/{thread_id}/runs/{run_id}/cancel")
@require_permission("runs", "cancel", owner_check=True, require_existing=True)
async def cancel_run(
    thread_id: str,
    run_id: str,
    request: Request,
    wait: bool = Query(default=False, description="Block until run completes after cancel"),
    action: Literal["interrupt", "rollback"] = Query(default="interrupt", description="Cancel action"),
) -> Response:
    """Cancel a running or pending run.

    - action=interrupt: Stop execution, keep current checkpoint (can be resumed)
    - action=rollback: Stop execution, revert to pre-run checkpoint state
    - wait=true: Block until the run fully stops, return 204
    - wait=false: Return immediately with 202
    """
    run_mgr = get_run_manager(request)
    record = await run_mgr.get(run_id)
    if record is None or record.thread_id != thread_id:
        raise HTTPException(status_code=404, detail=f"Run {run_id} not found")

    cancelled = await run_mgr.cancel(run_id, action=action)
    if not cancelled:
        raise HTTPException(status_code=409, detail=_cancel_conflict_detail(run_id, record))

    if wait and record.task is not None:
        try:
            await record.task
        except asyncio.CancelledError:
            pass
        return Response(status_code=204)

    return Response(status_code=202)
```

```python
# gateway/gateway/deps.py - 单例依赖访问器
def _require(attr: str, label: str) -> Callable[[Request], T]:
    """Create a FastAPI dependency that returns ``app.state.<attr>`` or 503."""

    def dep(request: Request) -> T:
        val = getattr(request.app.state, attr, None)
        if val is None:
            raise HTTPException(status_code=503, detail=f"{label} not available")
        return cast(T, val)

    dep.__name__ = dep.__qualname__ = f"get_{attr}"
    return dep


get_stream_bridge: Callable[[Request], StreamBridge] = _require("stream_bridge", "Stream bridge")
get_run_manager: Callable[[Request], RunManager] = _require("run_manager", "Run manager")
```

> **重连与取消面**：
> - `GET /{thread_id}/runs/{run_id}/join`：重连一个在途 run 的 SSE 流（带 `Last-Event-ID` 续传）。`store_only` record（跨 worker）仅 `supports_cross_process=True` 的 bridge（Redis）可 join，否则 409。
> - `GET|POST /{thread_id}/runs/{run_id}/stream`：GET 同 join；POST 带 `action=interrupt|rollback` 先取消再流剩余事件（SDK `joinStream` / 前端 stop 按钮走此）。`wait=1` 等取消完成后回 204。
> - `POST /{thread_id}/runs/{run_id}/cancel`：纯取消，`action=interrupt|rollback`，`wait=true` 等停后 204，否则 202。
>
> `stream_run` / `wait_run`（创建并流式 / 创建并等待）端点见 `[[gateway-runs-and-sse]]`。

---

## 关键不变量与测试锚点

1. **续传 O(1)**：内存 bridge 用 `{ts}-{seq}` 的 `seq` 算术定位；Redis bridge 用 `Last-Event-ID` 直接做 `XREAD` 起点。
2. **续传降级**：陈旧/驱逐/伪造/他 run id -> 从最早保留事件重放（内存）或 `ResponseError` 回退 `0-0`（Redis）。
3. **buffer 有界**：内存 `queue_maxsize=256` 驱逐最旧；Redis `XADD maxlen` + 可选 `expire` TTL。
4. **`END_SENTINEL` 跨进程**：Redis `{"kind":"end"}` XADD -> 解码回单例。
5. **`on_disconnect` finally**：`cancel` 断连取消后台 run；`continue` 丢弃事件；`store_only` 跳过（409）。
6. **`wait_for_run_completion` 不 await task**：消费 bridge，`completed=False` 时路由跳过 checkpoint 序列化（issue #3265）。
7. **心跳保活**：`heartbeat_interval=15.0` 无事件 yield `HEARTBEAT_SENTINEL`；`/wait` 靠心跳唤醒 poll `is_disconnected()`。
8. **孤儿恢复仅 SQLite**：`reconcile_orphaned_inflight_runs` + `publish_end` 收尾 + 线程 error 标记（仅最新 run）。
9. **`stream_exists` 可选**：仅 Redis 实现；终态判定 + 孤儿恢复用它防卡等。
10. **TTL 是泄漏安全网**：`stream_ttl_seconds=86400` 兜底过期残留流，非 run 执行超时。

> 关联：`run-manager.md`（`reconcile_orphaned_inflight_runs` / `cancel` / `shutdown`）、`worker-checkpoint-rollback.md`（`publish_end` 触发 `END_SENTINEL`）、`[[gateway-runs-and-sse]]`（lifespan 装配 + Redis bridge 全貌 + 创建端点）、`[[frontend-streaming-protocol]]`（`useStream` 消费 + `Last-Event-ID` 重连）、`[[e2e-request-lifecycle]]`（跨切不变量 3）。
