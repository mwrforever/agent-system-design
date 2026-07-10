# 完整源码：SSE 事件 schema

> 本文件给出 SSE 事件协议的**完整真实源码**：事件 dataclass、ring buffer 回放、SSE 线格式、LangGraph stream_mode 到 SSE 事件名映射、custom 事件 payload（`task_*` / `llm_retry`）。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`），去除一切项目字样。`@langchain/langgraph-sdk` / `langgraph` / `langchain_core` 等真实依赖名保留。原代码注释保留以保真；关键处补中文注解。

## §1 StreamEvent + sentinels + MemoryStreamBridge（ring buffer + Last-Event-ID O(1) 回放）

```python
# core/helix/runtime/stream_bridge/base.py
"""抽象 stream bridge 协议。

StreamBridge 解耦 agent worker（生产者）与 SSE 端点（消费者），
对齐 LangGraph Platform 的 Queue + StreamManager 架构。
"""

from __future__ import annotations

import abc
from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class StreamEvent:
    """单条流事件。

    Attributes:
        id: 单调递增的事件 ID（用作 SSE ``id:`` 字段，
            支持 ``Last-Event-ID`` 重连）。
        event: SSE 事件名，如 ``"metadata"`` / ``"updates"`` /
            ``"events"`` / ``"error"`` / ``"end"``。
        data: JSON 可序列化 payload。
    """

    id: str
    event: str
    data: Any


HEARTBEAT_SENTINEL = StreamEvent(id="", event="__heartbeat__", data=None)
END_SENTINEL = StreamEvent(id="", event="__end__", data=None)


class StreamBridge(abc.ABC):
    """stream bridge 抽象基类。"""

    supports_cross_process: bool = False

    @abc.abstractmethod
    async def publish(self, run_id: str, event: str, data: Any) -> None:
        """为 *run_id* 入队一条事件（生产者侧）。"""

    @abc.abstractmethod
    async def publish_end(self, run_id: str) -> None:
        """信号：*run_id* 不会再产出更多事件。"""

    @abc.abstractmethod
    def subscribe(
        self,
        run_id: str,
        *,
        last_event_id: str | None = None,
        heartbeat_interval: float = 15.0,
    ) -> AsyncIterator[StreamEvent]:
        """为 *run_id* 产出事件的异步迭代器（消费者侧）。

        *heartbeat_interval* 秒内无事件则 yield :data:`HEARTBEAT_SENTINEL`。
        生产者调 :meth:`publish_end` 后 yield :data:`END_SENTINEL`。
        """

    @abc.abstractmethod
    async def cleanup(self, run_id: str, *, delay: float = 0) -> None:
        """释放 *run_id* 关联的资源。*delay* > 0 时等待后再释放，
        给迟到订阅者排空剩余事件的机会。"""

    async def close(self) -> None:
        """释放后端资源。默认 no-op。"""
```

```python
# core/helix/runtime/stream_bridge/memory.py
"""进程内事件日志为后端的内存 stream bridge。"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from typing import Any

from .base import END_SENTINEL, HEARTBEAT_SENTINEL, StreamBridge, StreamEvent

logger = logging.getLogger(__name__)


@dataclass
class _RunStream:
    events: list[StreamEvent] = field(default_factory=list)
    condition: asyncio.Condition = field(default_factory=asyncio.Condition)
    ended: bool = False
    start_offset: int = 0


class MemoryStreamBridge(StreamBridge):
    """per-run 内存事件日志实现。

    每个 run 保留有界时间窗口内的事件，使迟到订阅者与重连客户端
    能从 ``Last-Event-ID`` 回放缓冲事件。
    """

    def __init__(self, *, queue_maxsize: int = 256) -> None:
        self._maxsize = queue_maxsize
        self._streams: dict[str, _RunStream] = {}
        self._counters: dict[str, int] = {}

    # -- helpers ---------------------------------------------------------------

    def _get_or_create_stream(self, run_id: str) -> _RunStream:
        if run_id not in self._streams:
            self._streams[run_id] = _RunStream()
            self._counters[run_id] = 0
        return self._streams[run_id]

    def _next_id(self, run_id: str) -> str:
        self._counters[run_id] = self._counters.get(run_id, 0) + 1
        ts = int(time.time() * 1000)
        seq = self._counters[run_id] - 1
        return f"{ts}-{seq}"

    @staticmethod
    def _parse_event_seq(event_id: str) -> int | None:
        """从 ``{ts}-{seq}`` 事件 id 提取 per-run 序列号。

        ``seq``（由 :meth:`_next_id` 分配）每发布一条事件 +1，
        故等于事件在 run 内的绝对偏移。格式不符返回 ``None``。
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

        # 事件 id 内嵌单调递增的 ``seq``，等于事件绝对偏移，故用 O(1) 算术
        # 定位而非线性扫描缓冲区。在计算出的 index 处验证 id，故过期/淘汰/
        # 外来/畸形 id 仍降级为从最早保留事件重放--与旧线性扫描等价。
        seq = self._parse_event_seq(last_event_id)
        if seq is not None:
            local_index = seq - stream.start_offset
            if 0 <= local_index < len(stream.events) and stream.events[local_index].id == last_event_id:
                return stream.start_offset + local_index + 1

        if stream.events:
            logger.warning(
                "last_event_id=%s not found in retained buffer; replaying from earliest retained event",
                last_event_id,
            )
        return stream.start_offset

    # -- StreamBridge API ------------------------------------------------------

    async def publish(self, run_id: str, event: str, data: Any) -> None:
        stream = self._get_or_create_stream(run_id)
        entry = StreamEvent(id=self._next_id(run_id), event=event, data=data)
        async with stream.condition:
            stream.events.append(entry)
            if len(stream.events) > self._maxsize:
                overflow = len(stream.events) - self._maxsize
                del stream.events[:overflow]
                stream.start_offset += overflow
            stream.condition.notify_all()

    async def publish_end(self, run_id: str) -> None:
        stream = self._get_or_create_stream(run_id)
        async with stream.condition:
            stream.ended = True
            stream.condition.notify_all()

    async def subscribe(
        self,
        run_id: str,
        *,
        last_event_id: str | None = None,
        heartbeat_interval: float = 15.0,
    ) -> AsyncIterator[StreamEvent]:
        stream = self._get_or_create_stream(run_id)
        async with stream.condition:
            next_offset = self._resolve_start_offset(stream, last_event_id)

        while True:
            async with stream.condition:
                if next_offset < stream.start_offset:
                    logger.warning(
                        "subscriber for run %s fell behind retained buffer; resuming from offset %s",
                        run_id,
                        stream.start_offset,
                    )
                    next_offset = stream.start_offset

                local_index = next_offset - stream.start_offset
                if 0 <= local_index < len(stream.events):
                    entry = stream.events[local_index]
                    next_offset += 1
                elif stream.ended:
                    entry = END_SENTINEL
                else:
                    try:
                        await asyncio.wait_for(stream.condition.wait(), timeout=heartbeat_interval)
                    except TimeoutError:
                        entry = HEARTBEAT_SENTINEL
                    else:
                        continue

            if entry is END_SENTINEL:
                yield END_SENTINEL
                return
            yield entry

    async def cleanup(self, run_id: str, *, delay: float = 0) -> None:
        if delay > 0:
            await asyncio.sleep(delay)
        self._streams.pop(run_id, None)
        self._counters.pop(run_id, None)

    async def close(self) -> None:
        self._streams.clear()
        self._counters.clear()
```

## §2 format_sse + sse_consumer（SSE 线格式 + Last-Event-ID 消费）

```python
# gateway/gateway/services.py
# （导入已匿名化：应用层网关路径 -> gateway，框架层包前缀 -> helix）
import json
import logging
from typing import Any

from gateway.utils import sanitize_log_param
from helix.runtime import (
    END_SENTINEL,
    HEARTBEAT_SENTINEL,
    ConflictError,
    DisconnectMode,
    StreamBridge,
)
# ... RunManager / RunRecord / RunStatus 等

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# SSE formatting
# ---------------------------------------------------------------------------


def format_sse(event: str, data: Any, *, event_id: str | None = None) -> str:
    """格式化单帧 SSE。

    字段顺序：``event:`` -> ``data:`` -> ``id:``（可选）-> 空行。
    匹配 LangGraph Platform 线格式，供 ``useStream`` React hook 与
    Python ``langgraph-sdk`` SSE 解码器消费。
    """
    payload = json.dumps(data, default=str, ensure_ascii=False)
    parts = [f"event: {event}", f"data: {payload}"]
    if event_id:
        parts.append(f"id: {event_id}")
    parts.append("")
    parts.append("")
    return "\n".join(parts)


def _run_is_terminal(record: RunRecord) -> bool:
    return record.status in _TERMINAL_RUN_STATUSES


async def _terminal_record_stream_missing(bridge: StreamBridge, record: RunRecord) -> bool:
    """终态 run 且 bridge 上无保留流时为 True。"""
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
    """从 bridge 产出 SSE 帧的异步生成器。

    ``finally`` 块实现 ``on_disconnect`` 语义：
    - ``cancel``：客户端断连时中止后台任务。
    - ``continue``：让任务继续；事件丢弃。
    """
    last_event_id = request.headers.get("Last-Event-ID")
    if await _terminal_record_stream_missing(bridge, record):
        yield format_sse("end", None)
        return

    try:
        async for entry in bridge.subscribe(record.run_id, last_event_id=last_event_id):
            if await request.is_disconnected():
                break

            if entry is HEARTBEAT_SENTINEL:
                if await _terminal_record_stream_missing(bridge, record):
                    yield format_sse("end", None)
                    return
                yield ": heartbeat\n\n"
                continue

            if entry is END_SENTINEL:
                yield format_sse("end", None, event_id=entry.id or None)
                return

            yield format_sse(entry.event, entry.data, event_id=entry.id or None)

    finally:
        # store_only record 是从 RunStore 水合的跨 worker run；本 worker 不持有
        # 其内存 task/abort 状态，故 run_mgr.cancel() 无法停止（会 409）。
        # 仅对本 worker 实际拥有的 run 执行 on_disconnect 取消。
        if not record.store_only and record.status in (RunStatus.pending, RunStatus.running):
            if record.on_disconnect == DisconnectMode.cancel:
                await run_mgr.cancel(record.run_id)
```

## §3 _lg_mode_to_sse_event + metadata 首发 + stream_mode 映射（worker.py）

```python
# core/helix/runtime/runs/worker.py
# （导入已匿名化：框架层包前缀 -> helix；trace 元数据键 -> HELIX_TRACE_METADATA_KEY）
import logging
from typing import Any

from helix.trace_context import HELIX_TRACE_METADATA_KEY, get_current_trace_id, normalize_trace_id
# ... 其他 helix.* 导入

logger = logging.getLogger(__name__)

# LangGraph graph.astream() 的合法 stream_mode 值
_VALID_LG_MODES = {"values", "updates", "checkpoints", "tasks", "debug", "messages", "custom"}


# ---- run_agent 内部（节选）----

# 2. Publish metadata - useStream needs both run_id AND thread_id
await bridge.publish(
    run_id,
    "metadata",
    {
        "run_id": run_id,
        "thread_id": thread_id,
    },
)

# ... 构造 agent、注入 runtime context ...

runtime_ctx = _build_runtime_context(thread_id, run_id, config.get("context"), ctx.app_config)
incoming_metadata = config.get("metadata") if isinstance(config.get("metadata"), dict) else {}
helix_trace_id = normalize_trace_id(incoming_metadata.get(HELIX_TRACE_METADATA_KEY)) or get_current_trace_id()
if helix_trace_id:
    runtime_ctx[HELIX_TRACE_METADATA_KEY] = helix_trace_id


# 6. Build LangGraph stream_mode list
#    "events" is NOT a valid astream mode - skip it
#    "messages-tuple" maps to LangGraph's "messages" mode
lg_modes: list[str] = []
for m in requested_modes:
    if m == "messages-tuple":
        lg_modes.append("messages")
    elif m == "events":
        # Skipped - see log above
        continue
    elif m in _VALID_LG_MODES:
        lg_modes.append(m)
if not lg_modes:
    lg_modes = ["values"]

# Deduplicate while preserving order
seen: set[str] = set()
deduped: list[str] = []
for m in lg_modes:
    if m not in seen:
        seen.add(m)
        deduped.append(m)
lg_modes = deduped

logger.info("Run %s: streaming with modes %s (requested: %s)", run_id, lg_modes, requested_modes)

# ... astream 循环内，每个 chunk 经 _lg_mode_to_sse_event 映射后 publish：
# async for chunk in agent.astream(input_payload, config=stream_config, stream_mode=lg_modes, ...):
#     ...
#     sse_event = _lg_mode_to_sse_event(mode)
#     await bridge.publish(run_id, sse_event, serialize(chunk, mode=mode))
#     if mode == "custom":
#         await subagent_events.add(chunk)


def _lg_mode_to_sse_event(mode: str) -> str:
    """Map LangGraph internal stream_mode name to SSE event name.

    LangGraph's ``astream(stream_mode="messages")`` produces message
    tuples.  The SSE protocol calls this ``messages-tuple`` when the
    client explicitly requests it, but the default SSE event name used
    by LangGraph Platform is simply ``"messages"``.
    """
    # All LG modes map 1:1 to SSE event names - "messages" stays "messages"
    return mode
```

## §4 custom 事件 payload（task_* + llm_retry）

### §4a task_* 事件（task_tool.py）

子代理 task 工具经 `get_stream_writer()` 发 `task_*` custom 事件。`writer({...})` 的 payload 即前端 `onCustomEvent` 收到的 `event` 对象。

```python
# core/helix/tools/builtins/task_tool.py
# （导入：from langgraph.config import get_stream_writer  -- 真实依赖名保留）

# ... task 后台轮询循环内 ...

writer = get_stream_writer()
# Send Task Started message
writer({"type": "task_started", "task_id": task_id, "description": description})

try:
    while True:
        result = get_background_task_result(task_id)

        if result is None:
            logger.error(f"[trace={trace_id}] Task {task_id} not found in background tasks")
            writer({"type": "task_failed", "task_id": task_id, "error": "Task disappeared from background tasks"})
            cleanup_background_task(task_id)
            error = f"Task {task_id} disappeared from background tasks"
            return _task_result_command(
                tool_call_id=tool_call_id,
                status="failed",
                error=error,
            )

        # Log status changes for debugging
        if result.status != last_status:
            logger.info(f"[trace={trace_id}] Task {task_id} status: {result.status.value}")
            last_status = result.status

        # Check for new AI messages and send task_running events
        ai_messages = result.ai_messages or []
        current_message_count = len(ai_messages)
        if current_message_count > last_message_count:
            # Send task_running event for each new message
            for i in range(last_message_count, current_message_count):
                message = ai_messages[i]
                writer(
                    {
                        "type": "task_running",
                        "task_id": task_id,
                        "message": message,
                        "message_index": i + 1,  # 1-based index for display
                        "total_messages": current_message_count,
                    }
                )
                logger.info(f"[trace={trace_id}] Task {task_id} sent message #{i + 1}/{current_message_count}")
            last_message_count = current_message_count

        # Check if task completed, failed, or timed out
        usage = _summarize_usage(getattr(result, "token_usage_records", None))
        if result.status == SubagentStatus.COMPLETED:
            _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
            _report_subagent_usage(runtime, result)
            writer({"type": "task_completed", "task_id": task_id, "result": result.result, "usage": usage})
            logger.info(f"[trace={trace_id}] Task {task_id} completed after {poll_count} polls")
            cleanup_background_task(task_id)
            # stop_reason carries a guardrail cap (token_capped / turn_capped)
            # when the run was ended early but still produced a final answer
            # - the work survives on result_brief like a clean success.
            return _task_result_command(
                tool_call_id=tool_call_id,
                status="completed",
                result=result.result,
                stop_reason=result.stop_reason,
            )
        elif result.status == SubagentStatus.FAILED:
            _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
            _report_subagent_usage(runtime, result)
            writer({"type": "task_failed", "task_id": task_id, "error": result.error, "usage": usage})
            logger.error(f"[trace={trace_id}] Task {task_id} failed: {result.error}")
            cleanup_background_task(task_id)
            # A turn-capped run with no usable output surfaces as failed +
            # stop_reason=turn_capped; the cap note lets the lead tell "out
            # of budget" from "broken subagent".
            return _task_result_command(
                tool_call_id=tool_call_id,
                status="failed",
                error=result.error,
                stop_reason=result.stop_reason,
            )
        elif result.status == SubagentStatus.CANCELLED:
            _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
            _report_subagent_usage(runtime, result)
            writer({"type": "task_cancelled", "task_id": task_id, "error": result.error, "usage": usage})
            logger.info(f"[trace={trace_id}] Task {task_id} cancelled: {result.error}")
            cleanup_background_task(task_id)
            return _task_result_command(
                tool_call_id=tool_call_id,
                status="cancelled",
                error=result.error,
            )
        elif result.status == SubagentStatus.TIMED_OUT:
            _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
            _report_subagent_usage(runtime, result)
            writer({"type": "task_timed_out", "task_id": task_id, "error": result.error, "usage": usage})
            logger.warning(f"[trace={trace_id}] Task {task_id} timed out: {result.error}")
            cleanup_background_task(task_id)
            return _task_result_command(
                tool_call_id=tool_call_id,
                status="timed_out",
                error=result.error,
            )

        # Still running, wait before next poll
        await asyncio.sleep(5)
        poll_count += 1

        # Polling timeout as a safety net (in case thread pool timeout doesn't work)
        if poll_count > max_poll_count:
            timeout_minutes = config.timeout_seconds // 60
            logger.error(f"[trace={trace_id}] Task {task_id} polling timed out after {poll_count} polls")
            _report_subagent_usage(runtime, result)
            usage = _summarize_usage(getattr(result, "token_usage_records", None))
            _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
            writer({"type": "task_timed_out", "task_id": task_id, "usage": usage})
            request_cancel_background_task(task_id)
            _schedule_deferred_subagent_cleanup(task_id, trace_id, max_poll_count)
            message = f"Task polling timed out after {timeout_minutes} minutes. This may indicate the background task is stuck. Status: {result.status.value}"
            return _task_result_command(
                tool_call_id=tool_call_id,
                status="polling_timed_out",
                error=message,
            )
except asyncio.CancelledError:
    # Signal the background subagent thread to stop cooperatively.
    request_cancel_background_task(task_id)
    # ... re-raise ...
```

### §4b llm_retry 事件（llm_error_handling_middleware.py）

```python
# core/helix/agents/middlewares/llm_error_handling_middleware.py
# （导入：from langgraph.config import get_stream_writer  -- 真实依赖名保留）

    def _emit_retry_event(self, attempt: int, wait_ms: int, reason: str) -> None:
        try:
            from langgraph.config import get_stream_writer

            writer = get_stream_writer()
            writer(
                {
                    "type": "llm_retry",
                    "attempt": attempt,
                    "max_attempts": self.retry_max_attempts,
                    "wait_ms": wait_ms,
                    "reason": reason,
                    "message": self._build_retry_message(attempt, wait_ms, reason),
                }
            )
        except Exception:
            logger.debug("Failed to emit llm_retry event", exc_info=True)
```

### §4c custom 事件 payload schema 汇总

| `type` | 关键字段 | 发送方 | 前端处理 |
|---|---|---|---|
| `task_started` | `task_id`, `description` | `task_tool.py` | 建子代理卡（in_progress） |
| `task_running` | `task_id`, `message`(AIMessage/ToolMessage), `message_index`(1-based), `total_messages` | `task_tool.py` | `updateSubtask`：`latestMessage` 覆盖 + `steps` 累积（`messageToStep`） |
| `task_completed` | `task_id`, `result`, `usage` | `task_tool.py` | 卡 completed + result |
| `task_failed` | `task_id`, `error`, `usage` | `task_tool.py` | 卡 failed + error |
| `task_cancelled` | `task_id`, `error`, `usage` | `task_tool.py` | 卡 failed + error |
| `task_timed_out` | `task_id`, `error?`, `usage` | `task_tool.py` | 卡 failed + error |
| `llm_retry` | `attempt`, `max_attempts`, `wait_ms`, `reason`, `message` | `llm_error_handling_middleware.py` | `toast(message)` |

> `task_running` 的 `message` 是 raw `AIMessage` / `ToolMessage` 的 model_dump。前端 `messageToStep`（见 [use-thread-stream.md](./use-thread-stream.md) §2）把它归一为 `SubtaskStep`（`kind:"ai"` 带 `tool_calls` / `kind:"tool"` 带 `tool_name`）。后端持久化路径 `build_subagent_step`（`step_events.py`）产出同形状 `subagent.step` run-event，前端 `eventsToSteps` 回放时直接复用。
