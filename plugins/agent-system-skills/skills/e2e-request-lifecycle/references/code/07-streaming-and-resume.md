# ⑦ 流式与续传 + 取消回滚完整源码

> 本文件是脊柱 `SKILL.md` 第⑦跳"流式"的深度展开，并覆盖跨切不变量 3（StreamBridge × checkpointer × 回滚）的完整源码。脊柱只给 stream_mode 映射片段 + bridge 抽象契约；此处给 `_lg_mode_to_sse_event`/`_unpack_stream_item` 完整、`StreamBridge` 契约 + `MemoryStreamBridge` 完整、`run_agent` 的 publish 与 pre-run 快照/rollback 协作完整、`_rollback_to_pre_run_checkpoint` 完整（含 pending_writes 恢复）、`RunManager.cancel`/`create_or_reject` 的 abort_action 协作。
>
> 代码已按插件匿名化规则映射到自定结构（`helix.*` / `gateway.*`），去除一切项目字样；原代码注释保真，中文注解以"注："或行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱）、`[[gateway-runs-and-sse]]`（RunManager + StreamBridge 全貌 + Redis 跨进程实现）、`[[long-running-and-cancellation]]`（multitask 策略 + 回滚）、`cross-cutting-invariants.md` 不变量 3。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `core/helix/runtime/runs/worker.py` | `run_agent`：pre-run 快照 + stream_mode 映射 + publish + 终结 rollback；`_rollback_to_pre_run_checkpoint` |
| `core/helix/runtime/stream_bridge/base.py` | `StreamBridge` 抽象契约 + `StreamEvent` |
| `core/helix/runtime/stream_bridge/memory.py` | `MemoryStreamBridge`：内存实现，O(1) 续传 + 有界 buffer |
| `core/helix/runtime/runs/manager.py` | `RunManager.cancel` / `create_or_reject`：abort_action 协作 |
| `gateway/gateway/services.py` | `sse_consumer`：从 bridge subscribe，带 `Last-Event-ID` 续传 |

---

## 1. `stream_mode` 映射 + publish（`worker.py` 完整片段）

```python
# core/helix/runtime/runs/worker.py
# LangGraph graph.astream() 的合法 stream_mode 值。
# 注："events" 不在其中--gateway 不支持 events 模式（需 astream_events + checkpoint 回调，
# 无法同时产 values 快照）。
_VALID_LG_MODES = {"values", "updates", "checkpoints", "tasks", "debug", "messages", "custom"}


def _lg_mode_to_sse_event(mode: str) -> str:
    """把 LangGraph 内部 stream_mode 名映射成 SSE 事件名。

    LangGraph 的 astream(stream_mode="messages") 产 message 元组。SSE 协议在客户端
    显式请求时称之为 messages-tuple，但 LangGraph Platform 用的默认 SSE 事件名就是 "messages"。
    """
    # 所有 LG 模式 1:1 映射成 SSE 事件名--messages 保持 messages
    return mode


def _unpack_stream_item(item: Any, lg_modes: list[str],
                        stream_subgraphs: bool) -> tuple[str | None, Any]:
    """把多模式或 subgraph 的流项解包成 (mode, chunk)。无法解析返回 (None, None)。"""
    if stream_subgraphs:
        if isinstance(item, tuple) and len(item) == 3:
            _ns, mode, chunk = item
            return str(mode), chunk
        if isinstance(item, tuple) and len(item) == 2:
            mode, chunk = item
            return str(mode), chunk
        return None, None

    if isinstance(item, tuple) and len(item) == 2:
        mode, chunk = item
        return str(mode), chunk

    # 回退：首模式的单元素输出
    return lg_modes[0] if lg_modes else None, item
```

`run_agent` 内的 stream_mode 装配 + publish 循环（单模式/多模式两路）：

```python
# core/helix/runtime/runs/worker.py - run_agent 内（stream_mode 装配 + 双路 publish）
# 6. 构建 LangGraph stream_mode 列表
#    "events" 不是合法 astream 模式--跳过
#    "messages-tuple" 映射到 LangGraph 的 "messages" 模式
lg_modes: list[str] = []
for m in requested_modes:
    if m == "messages-tuple":      # SDK 的 messages-tuple -> LG 的 messages
        lg_modes.append("messages")
    elif m == "events":            # 跳过--见上方日志
        continue
    elif m in _VALID_LG_MODES:
        lg_modes.append(m)
if not lg_modes:
    lg_modes = ["values"]          # 客户端没给合法模式时默认 values

# 去重保序
seen: set[str] = set()
deduped: list[str] = []
for m in lg_modes:
    if m not in seen:
        seen.add(m)
        deduped.append(m)
lg_modes = deduped

logger.info("Run %s: streaming with modes %s (requested: %s)", run_id, lg_modes, requested_modes)

async def _stream_once(input_payload: Any, stream_config: RunnableConfig) -> None:
    nonlocal llm_error_fallback_message
    if len(lg_modes) == 1 and not stream_subgraphs:
        # 单模式无 subgraphs：astream 产裸 chunk
        single_mode = lg_modes[0]
        async for chunk in agent.astream(input_payload, config=stream_config, stream_mode=single_mode):
            if record.abort_event.is_set():                 # 协作式取消：检测到 abort 立即停
                logger.info("Run %s abort requested - stopping", run_id)
                break
            llm_error_fallback_message = llm_error_fallback_message or _extract_llm_error_fallback_message(chunk, pre_existing_message_ids)
            sse_event = _lg_mode_to_sse_event(single_mode)
            await bridge.publish(run_id, sse_event, serialize(chunk, mode=single_mode))
            if single_mode == "custom":
                await subagent_events.add(chunk)             # 子代理 step 事件缓冲批量持久化
        return
    # 多模式或 subgraphs：astream 产元组
    async for item in agent.astream(
        input_payload,
        config=stream_config,
        stream_mode=lg_modes,
        subgraphs=stream_subgraphs,
    ):
        if record.abort_event.is_set():
            logger.info("Run %s abort requested - stopping", run_id)
            break

        mode, chunk = _unpack_stream_item(item, lg_modes, stream_subgraphs)
        if mode is None:
            continue

        llm_error_fallback_message = llm_error_fallback_message or _extract_llm_error_fallback_message(chunk, pre_existing_message_ids)
        sse_event = _lg_mode_to_sse_event(mode)
        await bridge.publish(run_id, sse_event, serialize(chunk, mode=mode))
        if mode == "custom":
            await subagent_events.add(chunk)

# 7. 流式本轮 turn，再可选继续隐藏 goal turn
await _stream_once(graph_input, initial_runnable_config)
while not record.abort_event.is_set() and not llm_error_fallback_message and (journal is None or not journal.had_llm_error_fallback):
    continuation_input = await _prepare_goal_continuation_input(
        bridge=bridge, checkpointer=checkpointer, thread_id=thread_id, run_id=run_id,
        model_name=record.model_name, app_config=ctx.app_config,
        evaluator_model_factory=_get_goal_evaluator_model, abort_event=record.abort_event)
    if continuation_input is None or record.abort_event.is_set():
        break
    await _stream_once(continuation_input, _continuation_runnable_config())
```

---

## 2. `run_agent` pre-run 快照 + 终结 rollback（`worker.py` 完整片段）

```python
# core/helix/runtime/runs/worker.py - run_agent 开头：pre-run checkpoint 快照（回滚锚点）
async def run_agent(
    bridge: StreamBridge, run_manager: RunManager, record: RunRecord, *,
    ctx: RunContext, agent_factory: Any, graph_input: dict, config: dict,
    stream_modes: list[str] | None = None, stream_subgraphs: bool = False,
    interrupt_before: list[str] | Literal["*"] | None = None,
    interrupt_after: list[str] | Literal["*"] | None = None,
) -> None:
    """在后台执行 agent，把事件 publish 到 bridge。"""
    checkpointer = ctx.checkpointer
    run_id, thread_id = record.run_id, record.thread_id
    requested_modes: set[str] = set(stream_modes or ["values"])
    pre_run_checkpoint_id: str | None = None
    pre_run_snapshot: dict[str, Any] | None = None
    snapshot_capture_failed = False
    # 其间还有 pre_existing_message_ids、journal、workspace 快照等初始化（与本不变量无关）
    try:
        # mark running、journal 初始化等步骤（与本不变量无关）
        # 运行前快照最新 checkpoint，供 rollback 恢复（本不变量回滚锚点）
        if checkpointer is not None:
            try:
                config_for_check = {"configurable": {"thread_id": thread_id, "checkpoint_ns": ""}}
                ckpt_tuple = await checkpointer.aget_tuple(config_for_check)
                if ckpt_tuple is not None:
                    ckpt_config = getattr(ckpt_tuple, "config", {}).get("configurable", {})
                    pre_run_checkpoint_id = ckpt_config.get("checkpoint_id")
                    # 深拷贝 checkpoint/metadata/pending_writes：run 期间 checkpointer 会写新 checkpoint，
                    # 必须冻结一份不可变快照，否则回滚时读到的是被本 run 污染后的状态。
                    pre_run_snapshot = {
                        "checkpoint_ns": ckpt_config.get("checkpoint_ns", ""),
                        "checkpoint": copy.deepcopy(getattr(ckpt_tuple, "checkpoint", {})),
                        "metadata": copy.deepcopy(getattr(ckpt_tuple, "metadata", {})),
                        "pending_writes": copy.deepcopy(getattr(ckpt_tuple, "pending_writes", []) or []),
                    }
                    pre_existing_message_ids = _collect_pre_existing_message_ids(pre_run_snapshot)
            except Exception:
                snapshot_capture_failed = True   # 快照失败：rollback 时降级跳过，不抛错卡住 run
                logger.warning("Could not capture pre-run checkpoint snapshot for run %s", run_id, exc_info=True)

        # publish metadata、建图、装 runtime context、起 astream 流式（见上节 + 脊柱 ⑦）
        # 其间步骤完整见源文件，与本不变量相关的是上面的快照与下面的终结 rollback
```

终结路径（正常 abort 退出 + `CancelledError`）：

```python
# core/helix/runtime/runs/worker.py - run_agent 状态收尾段
# 8. 最终状态
if record.abort_event.is_set():
    await run_manager.set_finalizing(run_id, True)
    action = record.abort_action
    if action == "rollback":
        await run_manager.set_status(run_id, RunStatus.error, error="Rolled back by user")
        try:
            await _rollback_to_pre_run_checkpoint(
                checkpointer=checkpointer, thread_id=thread_id, run_id=run_id,
                pre_run_checkpoint_id=pre_run_checkpoint_id,
                pre_run_snapshot=pre_run_snapshot,
                snapshot_capture_failed=snapshot_capture_failed)
            logger.info("Run %s rolled back to pre-run checkpoint %s", run_id, pre_run_checkpoint_id)
        except Exception:
            logger.warning("Failed to rollback checkpoint for run %s", run_id, exc_info=True)
    else:
        await run_manager.set_status(run_id, RunStatus.interrupted)   # interrupt：保留 checkpoint
elif llm_error_fallback_message or (journal is not None and journal.had_llm_error_fallback):
    error_msg = llm_error_fallback_message
    if error_msg is None and journal is not None:
        error_msg = journal.llm_error_fallback_message
    error_msg = error_msg or "LLM provider failed after retries"
    await run_manager.set_status(run_id, RunStatus.error, error=error_msg)
else:
    await run_manager.set_status(run_id, RunStatus.success)

except asyncio.CancelledError:
    # task.cancel() 触发：同样按 abort_action 决定回滚或 interrupt
    await run_manager.set_finalizing(run_id, True)
    action = record.abort_action
    if action == "rollback":
        await run_manager.set_status(run_id, RunStatus.error, error="Rolled back by user")
        try:
            await _rollback_to_pre_run_checkpoint(
                checkpointer=checkpointer, thread_id=thread_id, run_id=run_id,
                pre_run_checkpoint_id=pre_run_checkpoint_id,
                pre_run_snapshot=pre_run_snapshot,
                snapshot_capture_failed=snapshot_capture_failed)
            logger.info("Run %s was cancelled and rolled back", run_id)
        except Exception:
            logger.warning("Run %s cancellation rollback failed", run_id, exc_info=True)
    else:
        await run_manager.set_status(run_id, RunStatus.interrupted)
        logger.info("Run %s was cancelled", run_id)

except Exception as exc:
    error_msg = f"{exc}"
    logger.exception("Run %s failed: %s", run_id, error_msg)
    await run_manager.set_status(run_id, RunStatus.error, error=error_msg)
    await bridge.publish(run_id, "error", {"message": error_msg, "name": type(exc).__name__})

finally:
    # 其间还有 subagent_events flush、workspace changes 记录、journal flush、title 同步等（与本不变量无关）
    # 通知 bridge 本次 run 不再产事件，并延迟清理（给迟到订阅者排空机会）
    await bridge.publish_end(run_id)
    asyncio.create_task(bridge.cleanup(run_id, delay=60))
```

---

## 3. `_rollback_to_pre_run_checkpoint`（完整，含 pending_writes 恢复）

```python
# core/helix/runtime/runs/worker.py
async def _rollback_to_pre_run_checkpoint(
    *, checkpointer: Any, thread_id: str, run_id: str,
    pre_run_checkpoint_id: str | None, pre_run_snapshot: dict[str, Any] | None,
    snapshot_capture_failed: bool,
) -> None:
    """把线程状态恢复到 run 开始前快照的 checkpoint。"""
    if checkpointer is None:
        logger.info("Run %s rollback requested but no checkpointer is configured", run_id)
        return

    if snapshot_capture_failed:
        # 快照捕获失败：跳过回滚（不抛错卡住 run），记 warn
        logger.warning("Run %s rollback skipped: pre-run checkpoint snapshot capture failed", run_id)
        return

    if pre_run_snapshot is None:
        # run 前线程为空：直接删整个线程，回到空状态
        await _call_checkpointer_method(checkpointer, "adelete_thread", "delete_thread", thread_id)
        logger.info("Run %s rollback reset thread %s to empty state", run_id, thread_id)
        return

    checkpoint_to_restore = None
    metadata_to_restore: dict[str, Any] = {}
    checkpoint_ns = ""
    checkpoint = pre_run_snapshot.get("checkpoint")
    if not isinstance(checkpoint, dict):
        logger.warning("Run %s rollback skipped: invalid pre-run checkpoint snapshot", run_id)
        return
    checkpoint_to_restore = checkpoint
    if checkpoint_to_restore.get("id") is None and pre_run_checkpoint_id is not None:
        checkpoint_to_restore = {**checkpoint_to_restore, "id": pre_run_checkpoint_id}
    if checkpoint_to_restore.get("id") is None:
        logger.warning("Run %s rollback skipped: pre-run checkpoint has no checkpoint id", run_id)
        return
    # 新 id/ts 标记：回滚不是覆盖旧 checkpoint，而是写一个"新的"checkpoint，
    # 其 channel_values = pre-run 快照内容。新 id/ts 保证 DB-backed saver
    # （Postgres/Sqlite blob 按 channel_versions 键存）能正确写入新版本。
    restore_marker = _new_checkpoint_marker()   # empty_checkpoint() 产新 id/ts
    checkpoint_to_restore = {
        **checkpoint_to_restore,
        "id": restore_marker["id"],
        "ts": restore_marker["ts"],
    }
    metadata = pre_run_snapshot.get("metadata", {})
    metadata_to_restore = metadata if isinstance(metadata, dict) else {}
    raw_checkpoint_ns = pre_run_snapshot.get("checkpoint_ns")
    checkpoint_ns = raw_checkpoint_ns if isinstance(raw_checkpoint_ns, str) else ""

    channel_versions = checkpoint_to_restore.get("channel_versions")
    new_versions = dict(channel_versions) if isinstance(channel_versions, dict) else {}

    restore_config = {"configurable": {"thread_id": thread_id, "checkpoint_ns": checkpoint_ns}}
    # aput 写入恢复后的 checkpoint：线程最新 checkpoint 指向 pre-run 状态
    restored_config = await _call_checkpointer_method(
        checkpointer, "aput", "put",
        restore_config, checkpoint_to_restore,
        metadata_to_restore if isinstance(metadata_to_restore, dict) else {},
        new_versions)
    if not isinstance(restored_config, dict):
        raise RuntimeError(f"Run {run_id} rollback restore returned invalid config: expected dict")
    restored_configurable = restored_config.get("configurable", {})
    if not isinstance(restored_configurable, dict):
        raise RuntimeError(f"Run {run_id} rollback restore returned invalid config payload")
    restored_checkpoint_id = restored_configurable.get("checkpoint_id")
    if not restored_checkpoint_id:
        raise RuntimeError(f"Run {run_id} rollback restore did not return checkpoint_id")

    # 恢复 pending_writes：按 task_id 分组 aput_writes，使未完成写入也回到 pre-run 状态
    pending_writes = pre_run_snapshot.get("pending_writes", [])
    if not pending_writes:
        return

    writes_by_task: dict[str, list[tuple[str, Any]]] = {}
    for item in pending_writes:
        if not isinstance(item, (tuple, list)) or len(item) != 3:
            raise RuntimeError(f"Run {run_id} rollback failed: pending_write is not a 3-tuple: {item!r}")
        task_id, channel, value = item
        if not isinstance(channel, str):
            raise RuntimeError(f"Run {run_id} rollback failed: pending_write has non-string channel: task_id={task_id!r}, channel={channel!r}")
        writes_by_task.setdefault(str(task_id), []).append((channel, value))

    for task_id, writes in writes_by_task.items():
        await _call_checkpointer_method(
            checkpointer, "aput_writes", "put_writes",
            restored_config, writes, task_id=task_id)


def _new_checkpoint_marker() -> dict[str, str]:
    marker = empty_checkpoint()
    return {"id": marker["id"], "ts": marker["ts"]}
```

> 注：`_call_checkpointer_method` 是兼容 sync/async、新旧方法名（`aput`/`put`、`adelete_thread`/`delete_thread`、`aput_writes`/`put_writes`）的适配器（见 `core/helix/runtime/goal.py`）。`empty_checkpoint` 来自 `langgraph.checkpoint.base`，产全新 id/ts。

---

## 4. `StreamBridge` 抽象契约（`base.py` 完整）

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
    """单个流事件。

    Attributes:
        id: 单调递增的事件 ID（作为 SSE id: 字段，支持 Last-Event-ID 重连）。
        event: SSE 事件名，如 "metadata"/"updates"/"events"/"error"/"end"。
        data: JSON 可序列化载荷。
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
        """为 run_id 入队单个事件（生产者侧）。"""

    @abc.abstractmethod
    async def publish_end(self, run_id: str) -> None:
        """信号：run_id 不再产事件。"""

    @abc.abstractmethod
    def subscribe(
        self, run_id: str, *,
        last_event_id: str | None = None,
        heartbeat_interval: float = 15.0,
    ) -> AsyncIterator[StreamEvent]:
        """产 run_id 事件的异步迭代器（消费者侧）。

        heartbeat_interval 秒内无事件则 yield HEARTBEAT_SENTINEL。
        生产者调 publish_end 后 yield END_SENTINEL。"""

    @abc.abstractmethod
    async def cleanup(self, run_id: str, *, delay: float = 0) -> None:
        """释放 run_id 关联资源。delay>0 时等待后再释放，给迟到订阅者排空机会。"""

    async def close(self) -> None:
        """释放后端资源。默认 no-op。"""
```

---

## 5. `MemoryStreamBridge`（`memory.py` 完整）

```python
# core/helix/runtime/stream_bridge/memory.py
"""进程内事件日志支撑的内存 stream bridge。"""

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

    事件按有界时间窗 per-run 保留，使迟到订阅者和重连客户端可从 Last-Event-ID
    重放 buffer 内事件。
    """

    def __init__(self, *, queue_maxsize: int = 256) -> None:
        self._maxsize = queue_maxsize
        self._streams: dict[str, _RunStream] = {}
        self._counters: dict[str, int] = {}

    # -- helpers -----------------------------------------------------------

    def _get_or_create_stream(self, run_id: str) -> _RunStream:
        if run_id not in self._streams:
            self._streams[run_id] = _RunStream()
            self._counters[run_id] = 0
        return self._streams[run_id]

    def _next_id(self, run_id: str) -> str:
        # 事件 id = {ts}-{seq}；seq 是 per-run 单调递增的绝对偏移
        self._counters[run_id] = self._counters.get(run_id, 0) + 1
        ts = int(time.time() * 1000)
        seq = self._counters[run_id] - 1
        return f"{ts}-{seq}"

    @staticmethod
    def _parse_event_seq(event_id: str) -> int | None:
        """从 {ts}-{seq} id 抽 per-run seq。

        seq（由 _next_id 分配）每事件 +1，故等于事件在 run 内的绝对偏移。
        格式不符返回 None。"""
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

    # -- StreamBridge API --------------------------------------------------

    async def publish(self, run_id: str, event: str, data: Any) -> None:
        stream = self._get_or_create_stream(run_id)
        entry = StreamEvent(id=self._next_id(run_id), event=event, data=data)
        async with stream.condition:
            stream.events.append(entry)
            if len(stream.events) > self._maxsize:   # 有界 buffer：溢出驱逐最旧，start_offset 前移
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
        self, run_id: str, *,
        last_event_id: str | None = None,
        heartbeat_interval: float = 15.0,
    ) -> AsyncIterator[StreamEvent]:
        stream = self._get_or_create_stream(run_id)
        async with stream.condition:
            next_offset = self._resolve_start_offset(stream, last_event_id)   # 续传定位

        while True:
            async with stream.condition:
                # 订阅者落后于 buffer 驱逐速度：从最早保留事件恢复（降级，不丢已驱逐的）
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
                        entry = HEARTBEAT_SENTINEL   # 心跳：保活，防代理掐空闲连接
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

> 注：`RedisStreamBridge`（`core/helix/runtime/stream_bridge/redis.py`）是 `supports_cross_process = True` 的跨进程实现，用于多 worker 部署。其续传语义与 `MemoryStreamBridge` 一致（同样基于 `{ts}-{seq}` 绝对偏移 + Last-Event-ID），差异仅在事件存 Redis stream 而非进程内 list。深度见 `[[gateway-runs-and-sse]]`。

---

## 6. `RunManager.cancel` / `create_or_reject` 的 abort_action 协作（`manager.py` 完整片段）

```python
# core/helix/runtime/runs/manager.py - cancel：设 abort_action + abort_event，cancel 任务
async def cancel(self, run_id: str, *, action: str = "interrupt") -> bool:
    """请求取消一个 run。

    Args:
        run_id: 要取消的 run ID。
        action: "interrupt" 保留 checkpoint，"rollback" 回滚到 pre-run 状态。

    设带 action 原因的 abort_event 并 cancel asyncio 任务。
    取消已发起或 run 已 interrupted 时返回 True（幂等--第二次 cancel 是 no-op 成功）。
    仅当 run 在本 worker 未知或已达非 interrupted 终态（completed/failed 等）时返回 False。
    """
    async with self._lock:
        record = self._runs.get(run_id)
        if record is None:
            return False
        if record.status == RunStatus.interrupted:
            return True  # 幂等--已在本 worker 取消
        if record.status not in (RunStatus.pending, RunStatus.running):
            return False
        record.abort_action = action          # worker 终结时读它决定是否回滚
        record.abort_event.set()              # 协作式取消信号
        task_active = record.task is not None and not r.task.done()
        record.finalizing = task_active
        if task_active:
            record.task.cancel()              # 触发 asyncio.CancelledError
        record.status = RunStatus.interrupted
        record.updated_at = _now_iso()
    await self._persist_status(record, RunStatus.interrupted)
    logger.info("Run %s cancelled (action=%s)", run_id, action)
    return True
```

```python
# core/helix/runtime/runs/manager.py - create_or_reject：multitask 抢占时对在途 run 设 abort_action
async def create_or_reject(
    self, thread_id: str, assistant_id: str | None = None, *,
    on_disconnect: DisconnectMode = DisconnectMode.cancel,
    metadata: dict | None = None, kwargs: dict | None = None,
    multitask_strategy: str = "reject", model_name: str | None = None,
    user_id: str | None = None,
) -> RunRecord:
    """原子检查在途 run 并创建新 run。

    reject 策略：thread 已有 pending/running run 则抛 ConflictError。
    interrupt/rollback：取消在途 run 后再创建。

    本方法持锁跨"检查 + 插入"，消除分立 has_inflight + create 的 TOCTOU 竞争。
    """
    run_id = str(uuid.uuid4())
    now = _now_iso()

    _supported_strategies = ("reject", "interrupt", "rollback")
    interrupted_records: list[RunRecord] = []

    async with self._lock:
        if multitask_strategy not in _supported_strategies:
            raise UnsupportedStrategyError(f"Multitask strategy '{multitask_strategy}' is not yet supported. Supported strategies: {', '.join(_supported_strategies)}")

        inflight = [r for r in self._thread_records_locked(thread_id)
                    if r.status in (RunStatus.pending, RunStatus.running) or r.finalizing]

        if multitask_strategy == "reject" and inflight:
            raise ConflictError(f"Thread {thread_id} already has an active run")

        if multitask_strategy in ("interrupt", "rollback") and inflight:
            logger.info("Preparing to cancel %d inflight run(s) on thread %s (strategy=%s)",
                        len(inflight), thread_id, multitask_strategy)

        record = RunRecord(
            run_id=run_id, thread_id=thread_id, assistant_id=assistant_id,
            status=RunStatus.pending, on_disconnect=on_disconnect,
            multitask_strategy=multitask_strategy, metadata=metadata or {}, kwargs=kwargs or {},
            user_id=user_id, created_at=now, updated_at=now, model_name=model_name)
        self._runs[run_id] = record
        self._index_run_locked(record)
        # 持久化新 run（失败则回滚内存记录）
        # 其间有 _persist_new_run_to_store 与失败回滚，完整见源文件

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

> `RunRecord.abort_action` 默认 `"interrupt"`（见 `RunRecord` dataclass：`abort_action: str = "interrupt"`）。`cancel(action="rollback")` 或 `multitask_strategy="rollback"` 把它改 `"rollback"`，worker 终结路径读它决定走 `_rollback_to_pre_run_checkpoint` 还是仅 `set_status(interrupted)`。

---

## 7. `sse_consumer` 续传入口（`services.py` 完整片段）

```python
# gateway/gateway/services.py - sse_consumer：从 bridge subscribe，带 Last-Event-ID 续传
async def sse_consumer(bridge, record, request, run_mgr):
    """从 bridge 产 SSE 帧的异步生成器。

    finally 块实现 on_disconnect 语义：
    - cancel：客户端断开时中止后台任务。
    - continue：让任务继续；事件丢弃。
    """
    last_event_id = request.headers.get("Last-Event-ID")   # 客户端重连时带回最后收到的事件 id
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
                    break
                yield format_sse("heartbeat", None)   # 心跳帧保活
                continue

            # entry（StreamEvent）格式化为 SSE 帧：event:/id:/data: 三行
            yield format_sse(entry.event, entry.data, event_id=entry.id)
    finally:
        # on_disconnect 语义：cancel -> 中止后台任务；continue -> 任务继续，事件丢弃
        # 完整 disconnect 处理见源文件
        pass
```

> 注：`format_sse` 把 `StreamEvent` 序列化成 SSE 帧文本（`id: {id}\nevent: {event}\ndata: {json}\n\n`）。客户端 SDK（`useStream`）按 `id:` 字段记最后事件 id，重连时塞进 `Last-Event-ID` 请求头，形成续传闭环。

---

## 关键不变量与测试锚点

1. **stream_mode 1:1 映射**：`_lg_mode_to_sse_event` 直接返回 mode 名；`messages-tuple` -> LG `messages`；`events` 跳过（非合法 astream 模式）；无合法模式默认 `values`。
2. **事件 id = `{ts}-{seq}`**：`seq` 是 per-run 单调递增绝对偏移，使续传 O(1) 算术定位。
3. **续传 O(1) 命中**：`_resolve_start_offset` 用 `seq - start_offset` 算 `local_index`，校验 `events[local_index].id == last_event_id`，命中返回 `start_offset + local_index + 1`。
4. **续传降级**：陈旧/驱逐/伪造/他 run 的 id -> 从 `start_offset`（最早保留事件）重放，记 warn。
5. **buffer 有界**：`queue_maxsize=256`，溢出驱逐最旧、`start_offset` 前移；订阅者落后驱逐速度也降级恢复。
6. **心跳保活**：`heartbeat_interval=15.0` 秒无事件 yield `HEARTBEAT_SENTINEL`，防代理掐空闲连接。
7. **pre-run 快照深拷贝**：`copy.deepcopy` checkpoint/metadata/pending_writes，防 run 期间 checkpointer 写新 checkpoint 污染快照。
8. **快照失败降级**：`snapshot_capture_failed=True` 时 rollback 跳过并记 warn，不抛错卡住 run。
9. **rollback 写新 checkpoint**：`_new_checkpoint_marker()` 产新 id/ts，载 pre-run `channel_values`，`aput` 写入；不覆盖旧 checkpoint（DB-backed saver 版本冲突）。
10. **pending_writes 恢复**：按 `task_id` 分组 `aput_writes`，使未完成写也回 pre-run。
11. **abort_action 协作**：`cancel(action)` 与 `create_or_reject(multitask_strategy)` 都只设 `abort_action`+`abort_event`（不持锁做 IO），worker 终结路径（正常 abort / `CancelledError`）读它决定 rollback 或 interrupt。
12. **publish_end + 延迟 cleanup**：finally 里 `publish_end` 通知无更多事件，`cleanup(delay=60)` 给迟到订阅者排空机会。

> 关联：`[[gateway-runs-and-sse]]`（RunManager/run_agent/checkpointer 全貌 + Redis 跨进程 bridge）、`[[long-running-and-cancellation]]`（multitask 策略 + 回滚深度）、`[[frontend-streaming-protocol]]`（SSE schema + useStream 消费）、`cross-cutting-invariants.md` 不变量 3。
