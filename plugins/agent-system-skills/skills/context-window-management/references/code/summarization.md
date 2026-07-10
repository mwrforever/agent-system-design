# 摘要中间件完整源码 — context-window-management

> 本文件是 `context-window-management` skill 的 references/code，承载 `HelixSummarizationMiddleware` 及配套工厂、hook、config 的**完整真实源码**（已按插件匿名化规则映射到自定结构）。SKILL.md 只放入口片段，深度在此。

---

## 1. `HelixSummarizationMiddleware` 完整源码

真实路径 `core/helix/agents/middlewares/summarization_middleware.py`。继承 langchain 的 `SummarizationMiddleware`，重写摘要生成走 nostream 模型副本；在 `before_model` 编排触发 → 切分 → 保护 reminder → fire hooks → LLM 摘要 → RemoveMessage 替换历史。

```python
# core/helix/agents/middlewares/summarization_middleware.py
"""Summarization middleware extensions for Helix."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Protocol, override, runtime_checkable

from langchain.agents import AgentState
from langchain.agents.middleware import SummarizationMiddleware
from langchain_core.messages import AnyMessage, HumanMessage, RemoveMessage, get_buffer_string, trim_messages
from langgraph.config import get_config
from langgraph.constants import TAG_NOSTREAM
from langgraph.graph.message import REMOVE_ALL_MESSAGES
from langgraph.runtime import Runtime

from helix.agents.middlewares.dynamic_context_middleware import is_dynamic_context_reminder
from helix.config.app_config import get_app_config
from helix.models import create_chat_model

logger = logging.getLogger(__name__)
_SUMMARY_TRIGGER_MESSAGE_NAME = "summary"


@dataclass(frozen=True)
class SummarizationEvent:
    """Context emitted before conversation history is summarized away."""

    messages_to_summarize: tuple[AnyMessage, ...]
    preserved_messages: tuple[AnyMessage, ...]
    thread_id: str | None
    agent_name: str | None
    runtime: Runtime


@dataclass(frozen=True)
class ContextCompactionResult:
    """Result of summarizing old context and retaining the active tail."""

    summary_text: str
    messages_to_summarize: tuple[AnyMessage, ...]
    preserved_messages: tuple[AnyMessage, ...]
    total_tokens: int


@runtime_checkable
class BeforeSummarizationHook(Protocol):
    """Hook invoked before summarization removes messages from state."""

    def __call__(self, event: SummarizationEvent) -> None: ...


def _resolve_thread_id(runtime: Runtime) -> str | None:
    """Resolve the current thread ID from runtime context or LangGraph config."""
    thread_id = runtime.context.get("thread_id") if runtime.context else None
    if thread_id is None:
        try:
            config_data = get_config()
        except RuntimeError:
            return None
        thread_id = config_data.get("configurable", {}).get("thread_id")
    return thread_id


def _resolve_agent_name(runtime: Runtime) -> str | None:
    """Resolve the current agent name from runtime context or LangGraph config."""
    agent_name = runtime.context.get("agent_name") if runtime.context else None
    if agent_name is None:
        try:
            config_data = get_config()
        except RuntimeError:
            return None
        agent_name = config_data.get("configurable", {}).get("agent_name")
    return agent_name


class HelixSummarizationMiddleware(SummarizationMiddleware):
    """Summarization middleware with pre-compression hook dispatch."""

    def __init__(
        self,
        *args,
        before_summarization: list[BeforeSummarizationHook] | None = None,
        **kwargs,
    ) -> None:
        super().__init__(*args, **kwargs)
        self._before_summarization_hooks = before_summarization or []
        # The summary LLM call runs inside a LangGraph middleware hook, so its token
        # stream would otherwise be captured by the messages-tuple stream callback and
        # broadcast to the frontend as a phantom AI message. Tag a dedicated model copy
        # with TAG_NOSTREAM so the streaming handler skips it.
        # Keep self.model untagged so the parent's profile / ls_params inspection still works.
        #
        # Preserve any tags already bound on the model (e.g. "middleware:summarize" set in
        # lead/agent.py for RunJournal attribution): RunnableBinding.with_config does a
        # shallow merge that would otherwise overwrite the existing tags list entirely.
        existing_tags = list((getattr(self.model, "config", None) or {}).get("tags") or [])
        merged_tags = [*existing_tags, TAG_NOSTREAM] if TAG_NOSTREAM not in existing_tags else existing_tags
        self._summary_model = self.model.with_config(tags=merged_tags)

    @override
    def _create_summary(self, messages_to_summarize: list[AnyMessage]) -> str | None:
        return self._summarize_with(messages_to_summarize)

    @override
    async def _acreate_summary(self, messages_to_summarize: list[AnyMessage]) -> str | None:
        return await self._asummarize_with(messages_to_summarize)

    def _summarize_with(self, messages_to_summarize: list[AnyMessage], previous_summary: str | None = None) -> str | None:
        """Mirror the parent _create_summary but invoke the nostream-tagged model.

        We do not swap self.model at the instance level: the agent/middleware is
        cached and reused across concurrent runs, so a temporary swap would leak the
        RunnableBinding to other coroutines during await and break parent logic
        that inspects the raw model (profile / _get_ls_params).
        """
        if not messages_to_summarize:
            return "No previous conversation history."
        prompt = self._build_summary_prompt(messages_to_summarize, previous_summary=previous_summary)
        if prompt is None:
            return "Previous conversation was too long to summarize."
        try:
            response = self._summary_model.invoke(
                prompt,
                config={"metadata": {"lc_source": "summarization"}},
            )
            return response.text.strip()
        except Exception:
            logger.exception("Summary generation failed; skipping compaction this turn")
            return None

    async def _asummarize_with(self, messages_to_summarize: list[AnyMessage], previous_summary: str | None = None) -> str | None:
        """Async counterpart of :meth:`_summarize_with` using the nostream model."""
        if not messages_to_summarize:
            return "No previous conversation history."
        prompt = self._build_summary_prompt(messages_to_summarize, previous_summary=previous_summary)
        if prompt is None:
            return "Previous conversation was too long to summarize."
        try:
            response = await self._summary_model.ainvoke(
                prompt,
                config={"metadata": {"lc_source": "summarization"}},
            )
            return response.text.strip()
        except Exception:
            logger.exception("Summary generation failed; skipping compaction this turn")
            return None

    @staticmethod
    def _summary_count_message(summary_text: str) -> HumanMessage:
        return HumanMessage(content=summary_text, name=_SUMMARY_TRIGGER_MESSAGE_NAME)

    def _messages_for_trigger_count(self, messages: list[AnyMessage], summary_text: str | None) -> list[AnyMessage]:
        if not summary_text:
            return messages
        return [*messages, self._summary_count_message(summary_text)]

    @staticmethod
    def _bound_text(text: str, cap: int) -> str:
        if len(text) <= cap:
            return text
        if cap <= 0:
            return ""
        head = cap * 2 // 3
        omitted_marker = "\n...\n"
        if cap <= len(omitted_marker):
            return text[:cap]
        tail = max(0, cap - head - len(omitted_marker))
        if tail == 0:
            return text[:cap]
        return f"{text[:head]}{omitted_marker}{text[-tail:]}"

    def _trim_summary_section_text(self, text: str, max_tokens: int, *, strategy: str) -> str:
        if not text.strip():
            return ""
        max_tokens = max(1, max_tokens)
        try:
            trimmed = trim_messages(
                [HumanMessage(content=text)],
                max_tokens=max_tokens,
                token_counter=self.token_counter,
                strategy=strategy,
                allow_partial=True,
                text_splitter=list,
            )
            if trimmed:
                content = trimmed[-1].content
                if isinstance(content, str) and content.strip():
                    return content
        except Exception:
            logger.debug("Failed to trim summary prompt section with token counter; falling back to deterministic text cap", exc_info=True)
        return self._bound_text(text, max_tokens)

    def _build_summary_input_text(self, formatted_messages: str, previous_summary: str | None = None) -> str | None:
        if self.trim_tokens_to_summarize is None:
            trimmed_new_messages = formatted_messages
            trimmed_previous_summary = previous_summary.strip() if previous_summary else ""
        else:
            max_tokens = max(1, self.trim_tokens_to_summarize)
            if previous_summary:
                new_message_tokens = max(1, max_tokens // 2)
                previous_summary_tokens = max(1, max_tokens - new_message_tokens)
                trimmed_previous_summary = self._trim_summary_section_text(
                    previous_summary.strip(),
                    previous_summary_tokens,
                    strategy="last",
                )
                trimmed_new_messages = self._trim_summary_section_text(
                    formatted_messages,
                    new_message_tokens,
                    strategy="first",
                )
            else:
                trimmed_previous_summary = ""
                trimmed_new_messages = self._trim_summary_section_text(
                    formatted_messages,
                    max_tokens,
                    strategy="first",
                )

        parts: list[str] = []
        if trimmed_previous_summary:
            parts.extend(
                [
                    "<existing_summary>",
                    trimmed_previous_summary,
                    "</existing_summary>",
                    "",
                ]
            )
        if trimmed_new_messages:
            parts.extend(
                [
                    "<new_messages>",
                    trimmed_new_messages,
                    "</new_messages>",
                ]
            )
        if not parts:
            return None
        return "\n".join(parts)

    def _build_summary_prompt(self, messages_to_summarize: list[AnyMessage], previous_summary: str | None = None) -> str | None:
        """Build the summary prompt, returning None when trimming leaves nothing."""
        trimmed_messages = self._trim_messages_for_summary(messages_to_summarize)
        if not trimmed_messages:
            trimmed_messages = messages_to_summarize[-1:]
        if not trimmed_messages:
            return None
        # Format messages to avoid token inflation from metadata when str() is called on
        # message objects.
        formatted_messages = get_buffer_string(trimmed_messages)
        formatted_messages = self._build_summary_input_text(formatted_messages, previous_summary=previous_summary)
        if not formatted_messages:
            return None
        return self.summary_prompt.format(messages=formatted_messages).rstrip()

    def before_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._maybe_summarize(state, runtime)

    async def abefore_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return await self._amaybe_summarize(state, runtime)

    def _prepare_compaction(
        self,
        state: AgentState,
        *,
        force: bool = False,
    ) -> tuple[list[AnyMessage], list[AnyMessage], str | None, int] | None:
        messages = state["messages"]
        self._ensure_message_ids(messages)

        previous_summary = state.get("summary_text") if isinstance(state.get("summary_text"), str) else None
        trigger_messages = self._messages_for_trigger_count(messages, previous_summary)
        total_tokens = self.token_counter(trigger_messages)
        if not force and not self._should_summarize(trigger_messages, total_tokens):
            return None

        cutoff_index = self._determine_cutoff_index(messages)
        if cutoff_index <= 0:
            return None

        messages_to_summarize, preserved_messages = self._partition_messages(messages, cutoff_index)
        messages_to_summarize, preserved_messages = self._preserve_dynamic_context_reminders(messages_to_summarize, preserved_messages)
        if not messages_to_summarize:
            return None
        return messages_to_summarize, preserved_messages, previous_summary, total_tokens

    def compact_state(
        self,
        state: AgentState,
        runtime: Runtime,
        *,
        force: bool = False,
    ) -> ContextCompactionResult | None:
        prepared = self._prepare_compaction(state, force=force)
        if prepared is None:
            return None
        messages_to_summarize, preserved_messages, previous_summary, total_tokens = prepared
        self._fire_hooks(messages_to_summarize, preserved_messages, runtime)
        summary = self._summarize_with(messages_to_summarize, previous_summary=previous_summary)
        if summary is None:
            return None
        return ContextCompactionResult(
            summary_text=summary,
            messages_to_summarize=tuple(messages_to_summarize),
            preserved_messages=tuple(preserved_messages),
            total_tokens=total_tokens,
        )

    async def acompact_state(
        self,
        state: AgentState,
        runtime: Runtime,
        *,
        force: bool = False,
    ) -> ContextCompactionResult | None:
        prepared = self._prepare_compaction(state, force=force)
        if prepared is None:
            return None
        messages_to_summarize, preserved_messages, previous_summary, total_tokens = prepared
        self._fire_hooks(messages_to_summarize, preserved_messages, runtime)
        summary = await self._asummarize_with(messages_to_summarize, previous_summary=previous_summary)
        if summary is None:
            return None
        return ContextCompactionResult(
            summary_text=summary,
            messages_to_summarize=tuple(messages_to_summarize),
            preserved_messages=tuple(preserved_messages),
            total_tokens=total_tokens,
        )

    def _maybe_summarize(self, state: AgentState, runtime: Runtime) -> dict | None:
        result = self.compact_state(state, runtime, force=False)
        if result is None:
            return None
        return {
            "messages": [
                RemoveMessage(id=REMOVE_ALL_MESSAGES),
                *result.preserved_messages,
            ],
            "summary_text": result.summary_text,
        }

    async def _amaybe_summarize(self, state: AgentState, runtime: Runtime) -> dict | None:
        result = await self.acompact_state(state, runtime, force=False)
        if result is None:
            return None
        return {
            "messages": [
                RemoveMessage(id=REMOVE_ALL_MESSAGES),
                *result.preserved_messages,
            ],
            "summary_text": result.summary_text,
        }

    def _preserve_dynamic_context_reminders(
        self,
        messages_to_summarize: list[AnyMessage],
        preserved_messages: list[AnyMessage],
    ) -> tuple[list[AnyMessage], list[AnyMessage]]:
        """Keep hidden dynamic-context reminders and their ID-swap peers out of summary compression.

        These reminders carry the current date and optional memory. If summarization
        removes them, DynamicContextMiddleware can lose the already-injected reminder
        and inject a replacement into the wrong point of the conversation.

        The ID-swap triplet produced by _make_reminder_and_user_messages contains
        three messages: SystemMessage(id=X) and HumanMessage(id=X__memory) are
        both tagged with dynamic_context_reminder=True, but HumanMessage(id=X__user)
        carries the original user content and is **not** tagged. Without peer rescue,
        __user would stay in to_summarize and be compressed into prose — orphaning
        the tagged messages and losing the user question from the model's direct context.

        This method rescues tagged reminders and also rescues any untagged messages whose
        id shares the same stable_id prefix (i.e. X__user, X__memory).
        """
        reminders = [msg for msg in messages_to_summarize if is_dynamic_context_reminder(msg)]
        if not reminders:
            return messages_to_summarize, preserved_messages

        # Collect the base IDs (the stable_id prefix) from tagged reminders.
        # For a reminder with id="ctx-001__memory", the base is "ctx-001".
        # For a reminder with id="ctx-001" (SystemMessage), the base is "ctx-001".
        # removesuffix is suffix-only — it won't strip a "__" that sits in the
        # middle of a stable_id (e.g. "ctx__001" stays intact, unlike rsplit
        # which would mis-derive "ctx").  Only known ID-swap suffixes (__memory,
        # __user) are stripped; __user is not tagged so won't appear in reminders,
        # but is included defensively.
        reminder_base_ids: set[str] = set()
        for msg in reminders:
            if msg.id:
                base = msg.id.removesuffix("__memory").removesuffix("__user")
                reminder_base_ids.add(base)

        # Single-pass partition: walk messages_to_summarize in chronological order
        # and rescue both tagged reminders and untagged ID-swap peers (whose id
        # starts with a known base + "__").  This preserves the original message
        # order within rescued — critical when multiple triplets land in one
        # summarization window — and eliminates the need for id(m)-based dedup
        # that the previous reminders+peers concatenation required.
        rescued: list[AnyMessage] = []
        remaining: list[AnyMessage] = []
        for msg in messages_to_summarize:
            if is_dynamic_context_reminder(msg) or (msg.id and any(msg.id.startswith(b + "__") for b in reminder_base_ids)):
                rescued.append(msg)
            else:
                remaining.append(msg)
        return remaining, rescued + preserved_messages

    def _fire_hooks(
        self,
        messages_to_summarize: list[AnyMessage],
        preserved_messages: list[AnyMessage],
        runtime: Runtime,
    ) -> None:
        if not self._before_summarization_hooks:
            return

        event = SummarizationEvent(
            messages_to_summarize=tuple(messages_to_summarize),
            preserved_messages=tuple(preserved_messages),
            thread_id=_resolve_thread_id(runtime),
            agent_name=_resolve_agent_name(runtime),
            runtime=runtime,
        )

        for hook in self._before_summarization_hooks:
            try:
                hook(event)
            except Exception:
                hook_name = getattr(hook, "__name__", None) or type(hook).__name__
                logger.exception("before_summarization hook %s failed", hook_name)
```

---

## 2. `create_summarization_middleware` 工厂

lead 自动路径（`build_middlewares` 调 `_create_summarization_middleware`）与手动 `/compact` 路径（Gateway router `POST /api/threads/{id}/compact`）的**共同入口**，防 model 解析、hooks、prompt、retention 默认值漂移。

```python
# core/helix/agents/middlewares/summarization_middleware.py
def create_summarization_middleware(
    *,
    app_config: Any | None = None,
    keep: tuple[str, int | float] | None = None,
) -> HelixSummarizationMiddleware | None:
    """Create the configured summarization middleware.

    Both the lead-agent automatic path and the manual context-compaction path
    use this factory so model resolution, hooks, prompt config, and retention
    defaults cannot drift.
    """
    from helix.agents.memory.summarization_hook import memory_flush_hook

    resolved_app_config = app_config or get_app_config()
    config = resolved_app_config.summarization

    if not config.enabled:
        return None

    trigger = None
    if config.trigger is not None:
        if isinstance(config.trigger, list):
            trigger = [item.to_tuple() for item in config.trigger]
        else:
            trigger = config.trigger.to_tuple()

    if config.model_name:
        model = create_chat_model(
            name=config.model_name,
            thinking_enabled=False,
            app_config=resolved_app_config,
            attach_tracing=False,
        )
    else:
        model = create_chat_model(
            thinking_enabled=False,
            app_config=resolved_app_config,
            attach_tracing=False,
        )
    model = model.with_config(tags=["middleware:summarize"])

    kwargs: dict[str, Any] = {
        "model": model,
        "trigger": trigger,
        "keep": keep or config.keep.to_tuple(),
    }
    if config.trim_tokens_to_summarize is not None:
        kwargs["trim_tokens_to_summarize"] = config.trim_tokens_to_summarize
    if config.summary_prompt is not None:
        kwargs["summary_prompt"] = config.summary_prompt

    hooks: list[BeforeSummarizationHook] = []
    if resolved_app_config.memory.enabled:
        hooks.append(memory_flush_hook)

    return HelixSummarizationMiddleware(
        **kwargs,
        before_summarization=hooks,
    )
```

---

## 3. `memory_flush_hook`（摘要前把待压消息灌进记忆队列）

真实路径 `core/helix/agents/memory/summarization_hook.py`。注册为 `BeforeSummarizationHook`——一旦历史要被压掉，先把待压消息喂给记忆系统，否则用户刚说的话被压成摘要后就进不了 `memory.json`。

```python
# core/helix/agents/memory/summarization_hook.py
"""Hooks fired before summarization removes messages from state."""

from __future__ import annotations

from helix.agents.memory.message_processing import detect_correction, detect_reinforcement, filter_messages_for_memory
from helix.agents.memory.queue import get_memory_queue
from helix.agents.middlewares.summarization_middleware import SummarizationEvent
from helix.config.memory_config import get_memory_config
from helix.runtime.user_context import resolve_runtime_user_id


def memory_flush_hook(event: SummarizationEvent) -> None:
    """Flush messages about to be summarized into the memory queue."""
    if not get_memory_config().enabled or not event.thread_id:
        return

    filtered_messages = filter_messages_for_memory(list(event.messages_to_summarize))
    user_messages = [message for message in filtered_messages if getattr(message, "type", None) == "human"]
    assistant_messages = [message for message in filtered_messages if getattr(message, "type", None) == "ai"]
    if not user_messages or not assistant_messages:
        return

    correction_detected = detect_correction(filtered_messages)
    reinforcement_detected = not correction_detected and detect_reinforcement(filtered_messages)
    user_id = resolve_runtime_user_id(event.runtime)
    queue = get_memory_queue()
    queue.add_nowait(
        thread_id=event.thread_id,
        messages=filtered_messages,
        agent_name=event.agent_name,
        user_id=user_id,
        correction_detected=correction_detected,
        reinforcement_detected=reinforcement_detected,
    )
```

---

## 4. `SummarizationConfig` / `ContextSize`

真实路径 `core/helix/config/summarization_config.py`。`trigger` 支持单条或 list（任一满足即触发）；`keep` 是保留窗口策略；`trim_tokens_to_summarize` 限制摘要 prompt 自身体积。

```python
# core/helix/config/summarization_config.py
"""Configuration for conversation summarization."""

from typing import Literal

from pydantic import BaseModel, Field

ContextSizeType = Literal["fraction", "tokens", "messages"]
DEFAULT_SKILL_FILE_READ_TOOL_NAMES: tuple[str, ...] = ("read_file", "read", "view", "cat")


class ContextSize(BaseModel):
    """Context size specification for trigger or keep parameters."""

    type: ContextSizeType = Field(description="Type of context size specification")
    value: int | float = Field(description="Value for the context size specification")

    def to_tuple(self) -> tuple[ContextSizeType, int | float]:
        """Convert to tuple format expected by SummarizationMiddleware."""
        return (self.type, self.value)


class SummarizationConfig(BaseModel):
    """Configuration for automatic conversation summarization."""

    enabled: bool = Field(
        default=False,
        description="Whether to enable automatic conversation summarization",
    )
    model_name: str | None = Field(
        default=None,
        description="Model name to use for summarization (None = use a lightweight model)",
    )
    trigger: ContextSize | list[ContextSize] | None = Field(
        default=None,
        description="One or more thresholds that trigger summarization. When any threshold is met, summarization runs. "
        "Examples: {'type': 'messages', 'value': 50} triggers at 50 messages, "
        "{'type': 'tokens', 'value': 4000} triggers at 4000 tokens, "
        "{'type': 'fraction', 'value': 0.8} triggers at 80% of model's max input tokens",
    )
    keep: ContextSize = Field(
        default_factory=lambda: ContextSize(type="messages", value=20),
        description="Context retention policy after summarization. Specifies how much history to preserve. "
        "Examples: {'type': 'messages', 'value': 20} keeps 20 messages, "
        "{'type': 'tokens', 'value': 3000} keeps 3000 tokens, "
        "{'type': 'fraction', 'value': 0.3} keeps 30% of model's max input tokens",
    )
    trim_tokens_to_summarize: int | None = Field(
        default=4000,
        description="Maximum tokens to keep when preparing messages for summarization. Pass null to skip trimming.",
    )
    summary_prompt: str | None = Field(
        default=None,
        description="Custom prompt template for generating summaries. If not provided, uses the default LangChain prompt.",
    )
    skill_file_read_tool_names: list[str] = Field(
        default_factory=lambda: list(DEFAULT_SKILL_FILE_READ_TOOL_NAMES),
        description="Tool names treated as skill-file reads when capturing loaded skills into the durable skill_context channel.",
    )


# Global configuration instance
_summarization_config: SummarizationConfig = SummarizationConfig()


def get_summarization_config() -> SummarizationConfig:
    """Get the current summarization configuration."""
    return _summarization_config


def set_summarization_config(config: SummarizationConfig) -> None:
    """Set the summarization configuration."""
    global _summarization_config
    _summarization_config = config


def load_summarization_config_from_dict(config_dict: dict) -> None:
    """Load summarization configuration from a dictionary."""
    global _summarization_config
    _summarization_config = SummarizationConfig(**config_dict)
```

---

## 5. lead agent 的装配片段

真实路径 `core/helix/agents/lead/agent.py`。`build_middlewares` 在 base 段（1–12）之后续装第 16 号位的 Summarization（条件可选，config 驱动）。

```python
# core/helix/agents/lead/agent.py
from helix.agents.middlewares.summarization_middleware import HelixSummarizationMiddleware, create_summarization_middleware


def _create_summarization_middleware(*, app_config: AppConfig | None = None) -> HelixSummarizationMiddleware | None:
    """Create and configure the summarization middleware from config."""
    return create_summarization_middleware(app_config=app_config)


# build_middlewares 内部（顺序约束注释原样保留）：
# SummarizationMiddleware should be early to reduce context before other processing
def build_middlewares(config, model_name, agent_name=None, custom_middlewares=None, *,
                      available_skills=None, app_config=None, deferred_setup=None, user_id=None):
    resolved_app_config = app_config or get_app_config()
    middlewares = build_lead_runtime_middlewares(app_config=resolved_app_config, lazy_init=True)  # 1-12 共享基座
    # ... 13-15 DynamicContext / SkillActivation / DurableContext ...

    # Add summarization middleware if enabled
    summarization_middleware = _create_summarization_middleware(app_config=resolved_app_config)
    if summarization_middleware is not None:
        middlewares.append(summarization_middleware)                  # 16?

    # ... 17-29 后续中间件 ...
    return middlewares
```
