# 完整源码：RunJournal（LangChain callback -> 异步落库 + token 累加）

> 本文件给出 `core/helix/runtime/journal.py` 的**完整实现**：`RunJournal` callback handler。它坐在 LangChain 回调机制与可插拔 `RunEventStore` 之间，把回调数据标准化为 `RunEvent` 记录并处理 token 用量累加。SKILL.md 仅给出伪代码与架构思路，完整源码以此处为准。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`），去除一切项目字样。原代码注释保留以保真。

```python
# core/helix/runtime/journal.py
"""通过 LangChain callback 捕获 run 事件。

RunJournal 坐在 LangChain 的回调机制与可插拔 RunEventStore 之间。它把回调
数据标准化为 RunEvent 记录并处理 token 用量累加。

关键设计决策：
- on_llm_new_token 未实现--只通过 on_llm_end 取完整消息
- on_chat_model_start 捕获结构化 prompt 作 llm_request（OpenAI 格式），并抽
  首条 human message 作 run.input，因为它比 on_chain_start（每个 node 都触发）
  更可靠--此处消息已完全结构化。
- on_chain_start 且 parent_run_id=None 发 run.start trace，标记根调用。
- on_llm_end 发 llm_response（OpenAI Chat Completions 格式）
- token 用量内存累加，run 完成时写到 RunRow
- 通过 tags 注入识别 caller（lead_agent / subagent:{name} / middleware:{name}）
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable, Mapping
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any, cast
from uuid import UUID

from langchain_core.callbacks import BaseCallbackHandler
from langchain_core.messages import AIMessage, AnyMessage, BaseMessage, HumanMessage, ToolMessage
from langgraph.types import Command

from helix.agents.human_input import read_human_input_response
from helix.utils.messages import message_to_text

if TYPE_CHECKING:
    from helix.runtime.events.store.base import RunEventStore

logger = logging.getLogger(__name__)

_LEGACY_SUMMARY_MESSAGE_NAME = "summary"
_RECONCILED_TOOL_MESSAGE_NAMES = frozenset({"ask_clarification"})
_PERSISTED_HIDDEN_HUMAN_INPUT_RESPONSE_SOURCES = frozenset({"ask_clarification"})


def _should_persist_human_input_message(message: BaseMessage) -> bool:
    if not isinstance(message, HumanMessage):
        return False
    if message.name == _LEGACY_SUMMARY_MESSAGE_NAME:
        return False
    if message.additional_kwargs.get("hide_from_ui") is not True:
        return True
    response = read_human_input_response(message.additional_kwargs)
    return response is not None and response["source"] in _PERSISTED_HIDDEN_HUMAN_INPUT_RESPONSE_SOURCES


class RunJournal(BaseCallbackHandler):
    """把事件捕获到 RunEventStore 的 LangChain callback handler。"""

    def __init__(
        self,
        run_id: str,
        thread_id: str,
        event_store: RunEventStore,
        *,
        track_token_usage: bool = True,
        flush_threshold: int = 20,
        progress_reporter: Callable[[dict], Awaitable[None]] | None = None,
        progress_flush_interval: float = 5.0,
    ):
        super().__init__()
        self.run_id = run_id
        self.thread_id = thread_id
        self._store = event_store
        self._track_tokens = track_token_usage
        self._flush_threshold = flush_threshold
        self._progress_reporter = progress_reporter
        self._progress_flush_interval = progress_flush_interval

        # 写缓冲
        self._buffer: list[dict] = []
        self._pending_flush_tasks: set[asyncio.Task[None]] = set()
        self._pending_progress_task: asyncio.Task[None] | None = None
        self._pending_progress_delayed = False
        self._progress_dirty = False
        self._last_progress_flush = 0.0

        # token 累加器
        self._total_input_tokens = 0
        self._total_output_tokens = 0
        self._total_tokens = 0
        self._llm_call_count = 0

        # 按 caller 分桶的 token 累加器
        self._lead_agent_tokens = 0
        self._subagent_tokens = 0
        self._middleware_tokens = 0

        # per-model token 累加器
        self._tokens_by_model: dict[str, dict[str, int]] = {}

        # 去重：LangChain 可能对同一 run_id 多次触发 on_llm_end
        self._counted_llm_run_ids: set[str] = set()
        self._counted_external_source_ids: set[str] = set()
        self._counted_message_llm_run_ids: set[str] = set()

        # 便捷字段
        self._last_ai_msg: str | None = None
        self._first_human_msg: str | None = None
        self._msg_count = 0
        self._had_llm_error_fallback = False
        self._llm_error_fallback_message: str | None = None

        # 延迟追踪
        self._llm_start_times: dict[str, float] = {}  # langchain run_id -> 开始时间

        # LLM 请求/响应追踪
        self._llm_call_index = 0
        self._seen_llm_starts: set[str] = set()  # 触发过 on_chat_model_start 的 langchain run_id
        self._current_run_tool_call_names: dict[str, str] = {}
        self._persisted_tool_message_identities: set[str] = set()

    # -- 生命周期回调 --

    @staticmethod
    def _message_text(message: BaseMessage) -> str:
        """从消息的混合内容形状抽取可展示文本。"""
        return message_to_text(message, text_attribute_fallback=True)

    def _record_message_summary(self, message: BaseMessage, *, caller: str | None = None) -> None:
        """更新持久化 run row 的运行级便捷字段。"""
        self._msg_count += 1

        # last_ai_message 应代表 lead agent 的用户可见回答。中间件/subagent
        # 模型调用与空 tool-call-only AI 消息不得覆盖最后一条有用助手文本。
        is_ai_message = isinstance(message, AIMessage) or getattr(message, "type", None) == "ai"
        if is_ai_message and (caller is None or caller == "lead_agent"):
            text = self._message_text(message).strip()
            if text:
                self._last_ai_msg = text[:2000]

    def on_chain_start(
        self,
        serialized: dict[str, Any],
        inputs: dict[str, Any],
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        tags: list[str] | None = None,
        metadata: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> None:
        caller = self._identify_caller(tags)
        if parent_run_id is None:
            # 根图调用--为 run start 发一条 trace 事件
            chain_name = (serialized or {}).get("name", "unknown")
            self._put(
                event_type="run.start",
                category="trace",
                content={"chain": chain_name},
                metadata={"caller": caller, **(metadata or {})},
            )

    def on_chain_end(
        self,
        outputs: Any,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        **kwargs: Any,
    ) -> None:
        # 嵌套 chain end 为内部 graph node 触发；只有根 chain 代表用户可见 run 生命周期。
        if parent_run_id is not None:
            return
        self._reconcile_final_tool_messages(outputs)
        self._put(event_type="run.end", category="outputs", content=outputs, metadata={"status": "success"})
        self._flush_sync()

    def on_chain_error(self, error: BaseException, *, run_id: UUID, **kwargs: Any) -> None:
        self._put(
            event_type="run.error",
            category="error",
            content=str(error),
            metadata={"error_type": type(error).__name__},
        )
        self._flush_sync()

    # -- LLM 回调 --

    def on_chat_model_start(
        self,
        serialized: dict,
        messages: list[list[BaseMessage]],
        *,
        run_id: UUID,
        tags: list[str] | None = None,
        **kwargs: Any,
    ) -> None:
        """为 llm_request 事件捕获结构化 prompt 消息。

        这里也是抽取首条 human message 的规范位置：消息在此已完全结构化、
        只在实际 LLM 调用触发、且内容永不被 checkpoint 裁剪压缩。
        """
        rid = str(run_id)
        self._llm_start_times[rid] = time.monotonic()
        self._llm_call_index += 1
        self._seen_llm_starts.add(rid)

        logger.debug(
            "on_chat_model_start %s: tags=%s num_batches=%d message_counts=%s",
            run_id,
            tags,
            len(messages),
            [len(batch) for batch in messages],
        )

        # 捕获本次 run 发给 lead agent 的首条用户消息
        caller = self._identify_caller(tags)
        if caller == "lead_agent" and not self._first_human_msg and messages:
            for batch in reversed(messages):
                for m in reversed(batch):
                    if _should_persist_human_input_message(m):
                        self.set_first_human_message(m.text)
                        self._put(
                            event_type="llm.human.input",
                            category="message",
                            content=m.model_dump(),
                            metadata={"caller": caller},
                        )
                        self._record_message_summary(m, caller=caller)
                        break
                if self._first_human_msg:
                    break

    def on_llm_start(self, serialized: dict, prompts: list[str], *, run_id: UUID, parent_run_id: UUID | None = None, tags: list[str] | None = None, metadata: dict[str, Any] | None = None, **kwargs: Any) -> None:
        # 兜底：on_chat_model_start 优先。这里只追踪延迟。
        self._llm_start_times[str(run_id)] = time.monotonic()

    def on_llm_end(
        self,
        response: Any,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        tags: list[str] | None = None,
        **kwargs: Any,
    ) -> None:
        messages: list[AnyMessage] = []
        logger.debug("on_llm_end %s: tags=%s", run_id, tags)
        for generation in response.generations:
            for gen in generation:
                if hasattr(gen, "message"):
                    messages.append(gen.message)
                else:
                    logger.warning(f"on_llm_end {run_id}: generation has no message attribute: {gen}")

        for message in messages:
            caller = self._identify_caller(tags)
            self._remember_current_run_tool_calls(message, caller=caller)

            # 延迟
            rid = str(run_id)
            start = self._llm_start_times.pop(rid, None)
            latency_ms = int((time.monotonic() - start) * 1000) if start else None

            # 从消息取 token 用量
            usage = getattr(message, "usage_metadata", None)
            usage_dict = dict(usage) if usage else {}
            additional_kwargs = getattr(message, "additional_kwargs", None) or {}
            if isinstance(additional_kwargs, dict) and additional_kwargs.get("helix_error_fallback"):
                self._had_llm_error_fallback = True
                detail = additional_kwargs.get("error_detail")
                reason = additional_kwargs.get("error_reason")
                fallback_text = self._message_text(message).strip()
                if isinstance(detail, str) and detail.strip():
                    self._llm_error_fallback_message = detail.strip()
                elif isinstance(reason, str) and reason.strip():
                    self._llm_error_fallback_message = reason.strip()
                elif fallback_text:
                    self._llm_error_fallback_message = fallback_text[:2000]

            # 解析 call index
            call_index = self._llm_call_index
            if rid not in self._seen_llm_starts:
                # 兜底：on_chat_model_start 未被调用
                self._llm_call_index += 1
                call_index = self._llm_call_index
                self._seen_llm_starts.add(rid)

            # trace 事件：llm_response（OpenAI completion 格式）
            self._put(
                event_type="llm.ai.response",
                category="message",
                content=message.model_dump(),
                metadata={
                    "caller": caller,
                    "usage": usage_dict,
                    "latency_ms": latency_ms,
                    "llm_call_index": call_index,
                },
            )
            if rid not in self._counted_message_llm_run_ids:
                self._record_message_summary(message, caller=caller)

            # token 累加（按 langchain run_id 去重，避免同一 response 回调多次触发时双计）
            if self._track_tokens:
                input_tk = usage_dict.get("input_tokens", 0) or 0
                output_tk = usage_dict.get("output_tokens", 0) or 0
                total_tk = usage_dict.get("total_tokens", 0) or 0
                if total_tk == 0:
                    total_tk = input_tk + output_tk
                if total_tk > 0 and rid not in self._counted_llm_run_ids:
                    self._counted_llm_run_ids.add(rid)
                    self._total_input_tokens += input_tk
                    self._total_output_tokens += output_tk
                    self._total_tokens += total_tk
                    self._llm_call_count += 1

                    if caller.startswith("subagent:"):
                        self._subagent_tokens += total_tk
                    elif caller.startswith("middleware:"):
                        self._middleware_tokens += total_tk
                    else:
                        self._lead_agent_tokens += total_tk

                    # per-model 桶
                    response_metadata = getattr(message, "response_metadata", None) or {}
                    per_call_model: str | None = None
                    if isinstance(response_metadata, Mapping):
                        per_call_model = response_metadata.get("model_name") or response_metadata.get("model")
                    self._record_model_usage(per_call_model, input_tk, output_tk, total_tk, self._extract_cache_read(usage_dict))

                    self._schedule_progress_flush()

        if messages:
            self._counted_message_llm_run_ids.add(str(run_id))

    def on_llm_error(self, error: BaseException, *, run_id: UUID, **kwargs: Any) -> None:
        self._llm_start_times.pop(str(run_id), None)
        self._put(event_type="llm.error", category="trace", content=str(error))

    def on_tool_start(self, serialized, input_str, *, run_id, parent_run_id=None, tags=None, metadata=None, inputs=None, **kwargs):
        """处理 tool start 事件，缓存 tool call id 供后续关联"""
        tool_call_id = str(run_id)
        logger.debug("Tool start for node %s, tool_call_id=%s, tags=%s", run_id, tool_call_id, tags)

    def on_tool_end(self, output, *, run_id, parent_run_id=None, **kwargs):
        """处理 tool end 事件，追加消息并清除 node 数据"""
        try:
            if isinstance(output, ToolMessage):
                msg = cast(ToolMessage, output)
                self._persist_tool_result_message(msg)
            elif isinstance(output, Command):
                cmd = cast(Command, output)
                messages = cmd.update.get("messages", [])
                for message in messages:
                    if isinstance(message, BaseMessage):
                        self._persist_tool_result_message(message)
                    else:
                        logger.warning(f"on_tool_end {run_id}: command update message is not BaseMessage: {type(message)}")
            else:
                logger.warning(f"on_tool_end {run_id}: output is not ToolMessage: {type(output)}")
        finally:
            logger.debug("Tool end for node %s", run_id)

    # -- 内部方法 --

    @staticmethod
    def _message_identity(message: BaseMessage) -> str | None:
        tool_call_id = getattr(message, "tool_call_id", None)
        if isinstance(tool_call_id, str) and tool_call_id:
            return f"tool:{tool_call_id}"
        message_id = getattr(message, "id", None)
        if isinstance(message_id, str) and message_id:
            return f"message:{message_id}"
        return None

    @staticmethod
    def _tool_call_value(tool_call: Any, key: str) -> Any:
        if isinstance(tool_call, Mapping):
            return tool_call.get(key)
        return getattr(tool_call, key, None)

    def _remember_current_run_tool_calls(self, message: AnyMessage, *, caller: str) -> None:
        if caller != "lead_agent":
            return
        is_ai_message = isinstance(message, AIMessage) or getattr(message, "type", None) == "ai"
        if not is_ai_message:
            return
        tool_calls = getattr(message, "tool_calls", None) or []
        if not isinstance(tool_calls, list):
            return
        for tool_call in tool_calls:
            tool_call_id = self._tool_call_value(tool_call, "id")
            if not isinstance(tool_call_id, str) or not tool_call_id:
                continue
            name = self._tool_call_value(tool_call, "name")
            self._current_run_tool_call_names[tool_call_id] = str(name or "")

    def _persist_tool_result_message(self, message: BaseMessage) -> None:
        self._put(event_type="llm.tool.result", category="message", content=message.model_dump())
        identity = self._message_identity(message)
        if identity:
            self._persisted_tool_message_identities.add(identity)
        self._record_message_summary(message)

    def _final_output_messages(self, outputs: Any) -> list[Any]:
        if isinstance(outputs, Mapping):
            messages = outputs.get("messages", [])
            return messages if isinstance(messages, list) else []
        return []

    def _should_reconcile_tool_message(self, message: ToolMessage) -> bool:
        if message.additional_kwargs.get("hide_from_ui") is True:
            return False
        tool_call_id = getattr(message, "tool_call_id", None)
        if not isinstance(tool_call_id, str) or not tool_call_id:
            return False
        tool_call_name = self._current_run_tool_call_names.get(tool_call_id)
        if tool_call_name is None:
            return False
        message_name = getattr(message, "name", None)
        if message_name not in _RECONCILED_TOOL_MESSAGE_NAMES and tool_call_name not in _RECONCILED_TOOL_MESSAGE_NAMES:
            return False
        identity = self._message_identity(message)
        return identity is not None and identity not in self._persisted_tool_message_identities

    def _reconcile_final_tool_messages(self, outputs: Any) -> None:
        for message in self._final_output_messages(outputs):
            if not isinstance(message, ToolMessage):
                continue
            if self._should_reconcile_tool_message(message):
                self._persist_tool_result_message(message)

    def _put(self, *, event_type: str, category: str, content: str | dict = "", metadata: dict | None = None) -> None:
        self._buffer.append(
            {
                "thread_id": self.thread_id,
                "run_id": self.run_id,
                "event_type": event_type,
                "category": category,
                "content": content,
                "metadata": metadata or {},
                "created_at": datetime.now(UTC).isoformat(),
            }
        )
        if len(self._buffer) >= self._flush_threshold:
            self._flush_sync()

    def _flush_sync(self) -> None:
        """尽力把缓冲刷到 RunEventStore。

        BaseCallbackHandler 方法是同步的。若有 event loop 在跑，我们调度一个
        异步 put_batch；否则事件留在缓冲里，由 worker finally 块的异步 flush()
        稍后刷出。
        """
        if not self._buffer:
            return
        # 已有 flush 在途则跳过--避免多个 fire-and-forget 任务并发写同一 SQLite 文件
        if self._pending_flush_tasks:
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            # 无 event loop--事件留缓冲，稍后异步刷
            return
        batch = self._buffer.copy()
        self._buffer.clear()
        task = loop.create_task(self._flush_async(batch))
        self._pending_flush_tasks.add(task)
        task.add_done_callback(self._on_flush_done)

    async def _flush_async(self, batch: list[dict]) -> None:
        try:
            await self._store.put_batch(batch)
        except Exception:
            logger.warning(
                "Failed to flush %d events for run %s - returning to buffer",
                len(batch),
                self.run_id,
                exc_info=True,
            )
            # 失败事件回退缓冲，下次 flush 重试
            self._buffer = batch + self._buffer

    def _on_flush_done(self, task: asyncio.Task) -> None:
        self._pending_flush_tasks.discard(task)
        if task.cancelled():
            return
        exc = task.exception()
        if exc:
            logger.warning("Journal flush task failed: %s", exc)

    def _identify_caller(self, tags: list[str] | None) -> str:
        _tags = tags or []
        for tag in _tags:
            if isinstance(tag, str) and (tag.startswith("subagent:") or tag.startswith("middleware:") or tag == "lead_agent"):
                return tag
        # 默认 lead_agent：主 agent 图不注入 callback tags，而 subagent 与
        # middleware 显式 tag 自己。
        return "lead_agent"

    def _record_model_usage(
        self,
        model_name: str | None,
        input_tokens: int,
        output_tokens: int,
        total_tokens: int,
        cache_read_tokens: int = 0,
    ) -> None:
        """把单次 LLM 调用的 token 用量加到 per-model 累加器。

        缺失/空的 model_name 折叠进共享的 "unknown" 桶，使 provider 不上报
        response_metadata.model_name 时分桶仍可用。

        cache_read_tokens（prompt-cache 命中，来自
        usage_metadata.input_token_details.cache_read）作为稀疏桶 key 存储--
        仅非零时写--使无 cache 上报的 provider 的桶保持历史形状。
        """
        if total_tokens <= 0:
            return
        bucket = self._tokens_by_model.setdefault(
            model_name or "unknown",
            {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0},
        )
        bucket["input_tokens"] += int(input_tokens or 0)
        bucket["output_tokens"] += int(output_tokens or 0)
        bucket["total_tokens"] += int(total_tokens)
        if cache_read_tokens > 0:
            bucket["cache_read_tokens"] = bucket.get("cache_read_tokens", 0) + int(cache_read_tokens)

    @staticmethod
    def _extract_cache_read(usage_dict: dict) -> int:
        """LangChain 归一化 usage 中的 prompt-cache 命中 input token。"""
        details = usage_dict.get("input_token_details") or {}
        if not isinstance(details, Mapping):
            return 0
        try:
            return max(int(details.get("cache_read") or 0), 0)
        except (TypeError, ValueError):
            return 0

    # -- 公共方法（worker 调用）--

    def record_external_llm_usage_records(
        self,
        records: list[dict[str, int | str | None]],
    ) -> None:
        """记录来自外部源（如 subagent）的 token 用量。

        每条记录应含：
            source_run_id: 唯一标识，防双计
            caller: Caller tag（如 "subagent:general-purpose"）
            model_name: 真实 per-call 模型名（str 或 None；缺失时回退 "unknown" 桶）
            input_tokens: 输入 token 数
            output_tokens: 输出 token 数
            total_tokens: 总 token 数（0/缺失时由 input+output 计算）
            cache_read_tokens: 可选的 prompt-cache 命中 input token
        """
        if not self._track_tokens:
            return
        for record in records:
            source_id = str(record.get("source_run_id", ""))
            if not source_id:
                continue
            if source_id in self._counted_external_source_ids:
                continue

            total_tk = record.get("total_tokens", 0) or 0
            if total_tk <= 0:
                input_tk = record.get("input_tokens", 0) or 0
                output_tk = record.get("output_tokens", 0) or 0
                total_tk = input_tk + output_tk
            if total_tk <= 0:
                continue

            input_tk = record.get("input_tokens", 0) or 0
            output_tk = record.get("output_tokens", 0) or 0

            self._counted_external_source_ids.add(source_id)
            self._total_input_tokens += input_tk
            self._total_output_tokens += output_tk
            self._total_tokens += total_tk

            caller = str(record.get("caller", ""))
            if caller.startswith("subagent:"):
                self._subagent_tokens += total_tk
            elif caller.startswith("middleware:"):
                self._middleware_tokens += total_tk
            else:
                self._lead_agent_tokens += total_tk

            cache_read_tk = record.get("cache_read_tokens", 0) or 0
            self._record_model_usage(record.get("model_name"), input_tk, output_tk, total_tk, int(cache_read_tk))

            self._schedule_progress_flush()

    def set_first_human_message(self, content: str) -> None:
        """记录首条 human message 到便捷字段。"""
        self._first_human_msg = content[:2000] if content else None

    def record_middleware(self, tag: str, *, name: str, hook: str, action: str, changes: dict) -> None:
        """记录中间件状态变更事件。

        中间件实现执行有意义的状态变更（如标题生成、摘要、HITL 审批）时调用。
        纯观察型中间件不应调用此方法。

        Args:
            tag: 中间件短标识（如 "title"、"summarize"、"guardrail"）。
                用于构成 event_type="middleware:{tag}"。
            name: 完整中间件类名。
            hook: 触发该动作的生命周期 hook（如 "after_model"）。
            action: 执行的具体动作（如 "generate_title"）。
            changes: 描述所做状态变更的 dict。
        """
        self._put(
            event_type=f"middleware:{tag}",
            category="middleware",
            content={"name": name, "hook": hook, "action": action, "changes": changes},
        )

    async def flush(self) -> None:
        """强制刷剩余缓冲。worker finally 块调用。"""
        if self._pending_flush_tasks:
            await asyncio.gather(*tuple(self._pending_flush_tasks), return_exceptions=True)
        while self._pending_progress_task is not None and not self._pending_progress_task.done():
            if self._pending_progress_delayed:
                self._pending_progress_task.cancel()
                await asyncio.gather(self._pending_progress_task, return_exceptions=True)
                self._progress_dirty = False
                self._pending_progress_delayed = False
                break
            await asyncio.gather(self._pending_progress_task, return_exceptions=True)

        while self._buffer:
            batch = self._buffer[: self._flush_threshold]
            del self._buffer[: self._flush_threshold]
            try:
                await self._store.put_batch(batch)
            except Exception:
                self._buffer = batch + self._buffer
                raise

    def _schedule_progress_flush(self) -> None:
        """尽力节流地刷进度快照，供活跃 run 可见性。"""
        if self._progress_reporter is None:
            return
        now = time.monotonic()
        elapsed = now - self._last_progress_flush
        if elapsed < self._progress_flush_interval:
            self._progress_dirty = True
            self._schedule_delayed_progress_flush(self._progress_flush_interval - elapsed)
            return
        if self._pending_progress_task is not None and not self._pending_progress_task.done():
            self._progress_dirty = True
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        self._progress_dirty = False
        self._pending_progress_task = loop.create_task(self._flush_progress_async(snapshot=self.get_completion_data()))

    def _schedule_delayed_progress_flush(self, delay: float) -> None:
        if self._pending_progress_task is not None and not self._pending_progress_task.done():
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        delay = max(0.0, delay)
        self._pending_progress_delayed = delay > 0
        self._pending_progress_task = loop.create_task(self._flush_progress_async(delay=delay))

    async def _flush_progress_async(self, *, snapshot: dict | None = None, delay: float = 0.0) -> None:
        if self._progress_reporter is None:
            return
        if delay > 0:
            self._pending_progress_delayed = True
            await asyncio.sleep(delay)
            self._pending_progress_delayed = False
        dirty_before_write = self._progress_dirty
        self._progress_dirty = False
        snapshot_to_write = snapshot or self.get_completion_data()
        try:
            await self._progress_reporter(snapshot_to_write)
            self._last_progress_flush = time.monotonic()
        except Exception:
            logger.warning("Failed to persist progress snapshot for run %s", self.run_id, exc_info=True)
        if dirty_before_write or self._progress_dirty:
            self._progress_dirty = False
            self._pending_progress_task = None
            self._schedule_delayed_progress_flush(self._progress_flush_interval)

    def get_completion_data(self) -> dict:
        """返回 run 完成的累积 token 与消息数据。"""
        return {
            "total_input_tokens": self._total_input_tokens,
            "total_output_tokens": self._total_output_tokens,
            "total_tokens": self._total_tokens,
            "llm_call_count": self._llm_call_count,
            "lead_agent_tokens": self._lead_agent_tokens,
            "subagent_tokens": self._subagent_tokens,
            "middleware_tokens": self._middleware_tokens,
            "token_usage_by_model": {model: dict(usage) for model, usage in self._tokens_by_model.items()},
            "message_count": self._msg_count,
            "last_ai_message": self._last_ai_msg,
            "first_human_message": self._first_human_msg,
        }

    @property
    def had_llm_error_fallback(self) -> bool:
        return self._had_llm_error_fallback

    @property
    def llm_error_fallback_message(self) -> str | None:
        return self._llm_error_fallback_message
```
