# 安全终止 + Loop/Token 预算完整源码

> 本文件是 `safety-and-guardrails` skill 的代码附件，收录 provider 安全终止抑制 + lead 级 loop/token 预算护栏的**完整真实源码**（已按插件匿名化规则映射到自定结构 `helix.*`，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。
>
> 子代理执行器如何**收集**这些护栏的 `consume_stop_reason` 并以 additive `stop_reason` 冒泡到主代理，见 [[subagent-delegation]] 的 `concurrency-and-guards.md`（本文件只含中间件本身的完整实现，不重复执行器侧收集逻辑）。

## 文件清单

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/agents/middlewares/safety_termination_detectors.py` | `SafetyTermination` / `SafetyTerminationDetector` 协议 + 3 个内置 detector（OpenAI content_filter / Anthropic refusal / Gemini SAFETY）+ `default_detectors` |
| `core/helix/agents/middlewares/safety_finish_reason_middleware.py` | `SafetyFinishReasonMiddleware`：`after_model` 抑制 provider 安全终止时的半截 tool_calls |
| `core/helix/agents/middlewares/token_budget_middleware.py` | `TokenBudgetMiddleware`：per-run token 预算，hard-stop 剥 tool_calls + `consume_stop_reason` 盖 `token_capped` |
| `core/helix/agents/middlewares/loop_detection_middleware.py` | `LoopDetectionMiddleware`：重复 tool-call 检测（hash + 频率双轴），hard-stop + `consume_stop_reason` 盖 `loop_capped` |
| `core/helix/agents/middlewares/_bounded_dict.py` | `BoundedDict`：per-`run_id` 状态的有界 OrderedDict（防泄漏） |
| `core/helix/agents/middlewares/tool_call_metadata.py` | `clone_ai_message_with_tool_calls`：清空 tool_calls 的统一入口（同步结构化 + provider 原始 + function_call） |
| `core/helix/config/safety_finish_reason_config.py` | `SafetyFinishReasonConfig` / `SafetyDetectorConfig` |
| `core/helix/config/token_budget_config.py` | `TokenBudgetConfig` |
| `core/helix/config/loop_detection_config.py` | `LoopDetectionConfig` / `ToolFreqOverride` |

---

## 1. SafetyTerminationDetector 协议与内置 detector

```python
# core/helix/agents/middlewares/safety_termination_detectors.py
"""Detectors for provider-side safety termination signals.

Different LLM providers signal "I stopped this response for safety reasons"
through different fields with different values. This module defines a small
strategy interface and three built-in detectors that cover the major
providers Helix supports today. New providers (Wenxin, Hunyuan, Bedrock
adapters, in-house gateways, ...) can be added by implementing
``SafetyTerminationDetector`` and wiring it through
``config.yaml: safety_finish_reason.detectors``.

The middleware that consumes these detectors lives in
``safety_finish_reason_middleware.py``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

from langchain_core.messages import AIMessage


@dataclass(frozen=True)
class SafetyTermination:
    """A detected safety-related termination signal.

    Attributes:
        detector: Name of the detector that produced this result. Used for
            observability so operators can see which provider rule fired.
        reason_field: The message metadata field that carried the signal
            (e.g. ``finish_reason``, ``stop_reason``).
        reason_value: The actual value of that field
            (e.g. ``content_filter``, ``refusal``, ``SAFETY``).
        extras: Provider-specific metadata that may help downstream
            consumers (e.g. Azure OpenAI content_filter_results, Gemini
            safety_ratings). Detectors are free to populate or skip this.
    """

    detector: str
    reason_field: str
    reason_value: str
    extras: dict[str, Any] = field(default_factory=dict)


@runtime_checkable
class SafetyTerminationDetector(Protocol):
    """Strategy interface for provider safety termination detection.

    策略接口：检测 provider 侧的安全终止信号。``detect`` 必须 side-effect free
    且容忍缺失/类型异常的 metadata--detector 跑在每条模型响应上。
    """

    name: str

    def detect(self, message: AIMessage) -> SafetyTermination | None:
        """Return a SafetyTermination if *message* indicates provider safety
        termination, otherwise return ``None``.

        Implementations must be side-effect free and tolerant of missing or
        oddly-typed metadata - detectors run on every model response.
        """
        ...


def _get_metadata_value(message: AIMessage, field_name: str) -> str | None:
    """Read a string-typed value from either ``response_metadata`` or
    ``additional_kwargs``.

    LangChain provider adapters are inconsistent about where they stash
    provider stop signals. Most modern adapters use ``response_metadata``,
    but some legacy / passthrough paths still surface them via
    ``additional_kwargs``. We check both, in that order, and only accept
    string values - Pydantic enums or dicts are ignored so we never raise
    on malformed inputs.
    """
    for container_name in ("response_metadata", "additional_kwargs"):
        container = getattr(message, container_name, None) or {}
        if not isinstance(container, dict):
            continue
        value = container.get(field_name)
        if isinstance(value, str) and value:
            return value
    return None


class OpenAICompatibleContentFilterDetector:
    """OpenAI-compatible content_filter signal.

    Covers OpenAI, Azure OpenAI, Moonshot/Kimi, DeepSeek, Mistral, vLLM,
    Qwen (OpenAI-compatible mode), and any other adapter that follows the
    OpenAI ``finish_reason`` convention.

    Some Chinese providers ship custom OpenAI-compatible gateways that use
    alternative tokens like ``sensitive`` or ``violation``. Extend the set
    via the ``finish_reasons`` kwarg in config.
    """

    name = "openai_compatible_content_filter"

    def __init__(self, finish_reasons: list[str] | tuple[str, ...] | None = None) -> None:
        configured = finish_reasons if finish_reasons is not None else ("content_filter",)
        self._finish_reasons: frozenset[str] = frozenset(r.lower() for r in configured)

    def detect(self, message: AIMessage) -> SafetyTermination | None:
        value = _get_metadata_value(message, "finish_reason")
        if value is None or value.lower() not in self._finish_reasons:
            return None

        extras: dict[str, Any] = {}
        # Azure OpenAI ships a structured content_filter_results block; carry it
        # through so operators can see *what* was filtered without re-tracing.
        response_metadata = getattr(message, "response_metadata", None) or {}
        if isinstance(response_metadata, dict):
            filter_results = response_metadata.get("content_filter_results")
            if filter_results:
                extras["content_filter_results"] = filter_results

        return SafetyTermination(
            detector=self.name,
            reason_field="finish_reason",
            reason_value=value,
            extras=extras,
        )


class AnthropicRefusalDetector:
    """Anthropic ``stop_reason == "refusal"`` signal.

    Anthropic models surface safety refusals via a dedicated ``stop_reason``
    rather than ``finish_reason``. See:
    https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/handle-streaming-refusals
    """

    name = "anthropic_refusal"

    def __init__(self, stop_reasons: list[str] | tuple[str, ...] | None = None) -> None:
        configured = stop_reasons if stop_reasons is not None else ("refusal",)
        self._stop_reasons: frozenset[str] = frozenset(r.lower() for r in configured)

    def detect(self, message: AIMessage) -> SafetyTermination | None:
        value = _get_metadata_value(message, "stop_reason")
        if value is None or value.lower() not in self._stop_reasons:
            return None
        return SafetyTermination(
            detector=self.name,
            reason_field="stop_reason",
            reason_value=value,
        )


class GeminiSafetyDetector:
    """Gemini / Vertex AI safety-related finish reasons.

    Gemini uses the same ``finish_reason`` field as OpenAI but with an
    enumerated upper-case taxonomy. The default set covers every Gemini
    finish_reason that means "the model stopped because the content/image
    tripped a safety, blocklist, recitation, or PII filter" - i.e. cases
    where any tool_calls returned alongside are likely truncated/
    unreliable. Full enum:
    https://docs.cloud.google.com/python/docs/reference/aiplatform/latest/google.cloud.aiplatform_v1.types.Candidate.FinishReason

    Intentionally **excluded** from the default set:
    - ``STOP``                       - normal termination.
    - ``MAX_TOKENS``                 - output length truncation, not safety
                                       (same root failure mode as
                                       content_filter, but issue #3028
                                       scopes it out; expose separately if
                                       desired).
    - ``LANGUAGE`` / ``NO_IMAGE``    - capability mismatches, unrelated to
                                       safety; tool_calls would be absent
                                       anyway.
    - ``MALFORMED_FUNCTION_CALL`` /
      ``UNEXPECTED_TOOL_CALL``       - tool-call protocol errors. The
                                       tool_calls are *also* unreliable
                                       here, but the failure category is
                                       distinct from safety filtering;
                                       handle in a dedicated detector to
                                       keep observability records honest.
    - ``OTHER`` / ``IMAGE_OTHER`` /
      ``FINISH_REASON_UNSPECIFIED``  - too broad to enable by default;
                                       opt in via ``finish_reasons=`` if
                                       your provider abuses these.
    """

    name = "gemini_safety"

    _DEFAULT_FINISH_REASONS = (
        # Text safety
        "SAFETY",
        "BLOCKLIST",
        "PROHIBITED_CONTENT",
        "SPII",
        "RECITATION",
        # Image safety (multimodal generation)
        "IMAGE_SAFETY",
        "IMAGE_PROHIBITED_CONTENT",
        "IMAGE_RECITATION",
    )

    def __init__(self, finish_reasons: list[str] | tuple[str, ...] | None = None) -> None:
        configured = finish_reasons if finish_reasons is not None else self._DEFAULT_FINISH_REASONS
        self._finish_reasons: frozenset[str] = frozenset(r.upper() for r in configured)

    def detect(self, message: AIMessage) -> SafetyTermination | None:
        value = _get_metadata_value(message, "finish_reason")
        if value is None or value.upper() not in self._finish_reasons:
            return None

        extras: dict[str, Any] = {}
        response_metadata = getattr(message, "response_metadata", None) or {}
        if isinstance(response_metadata, dict):
            # Gemini surfaces per-category scoring under safety_ratings.
            ratings = response_metadata.get("safety_ratings")
            if ratings:
                extras["safety_ratings"] = ratings

        return SafetyTermination(
            detector=self.name,
            reason_field="finish_reason",
            reason_value=value,
            extras=extras,
        )


def default_detectors() -> list[SafetyTerminationDetector]:
    """Built-in detector set used when no custom detectors are configured."""
    return [
        OpenAICompatibleContentFilterDetector(),
        AnthropicRefusalDetector(),
        GeminiSafetyDetector(),
    ]


__all__ = [
    "AnthropicRefusalDetector",
    "GeminiSafetyDetector",
    "OpenAICompatibleContentFilterDetector",
    "SafetyTermination",
    "SafetyTerminationDetector",
    "default_detectors",
]
```

---

## 2. SafetyFinishReasonMiddleware（provider 安全终止抑制）

```python
# core/helix/agents/middlewares/safety_finish_reason_middleware.py
"""Suppress tool execution when the provider safety-terminated the response.

Background - see issue #3028.

Some providers (OpenAI ``finish_reason='content_filter'``, Anthropic
``stop_reason='refusal'``, Gemini ``finish_reason='SAFETY'`` ...) can stop
generation mid-stream while still returning partially-formed ``tool_calls``.
LangChain's tool router treats any AIMessage with a non-empty ``tool_calls``
field as "go execute these", so half-truncated arguments - e.g. a markdown
``write_file`` that stops in the middle of a sentence - get dispatched as if
they were complete. The agent then sees the truncated file, tries to fix it,
gets filtered again, and loops.

This middleware sits at ``after_model`` and gates that behaviour: when a
configured ``SafetyTerminationDetector`` fires *and* the AIMessage carries
tool calls, we strip the tool calls (both structured and raw provider
payloads), append a user-facing explanation, and stash observability fields
in ``additional_kwargs.safety_termination`` so logs, traces, and SSE
consumers can see what happened.

Hook choice: ``after_model`` (not ``wrap_model_call``) because the response
is a *normal* return - not an exception - and we want to participate in the
same after-model chain as ``LoopDetectionMiddleware``, with which we share
the same tool-call-suppression mechanic but a different trigger.

Placement: register *after* ``LoopDetectionMiddleware`` in the middleware
list. LangChain factory wires ``after_model`` edges in reverse list order
(``langchain/agents/factory.py:add_edge("model", middleware_w_after_model[-1])``,
then walks ``range(len-1, 0, -1)``), so the *last* registered middleware is
the *first* to observe the model output. Registering Safety after Loop
means Safety sees the raw response first, clears tool calls if it fires,
and Loop then accounts against the cleaned message.

设计要点：
1. 只在有 tool_calls 时干预--content_filter 无 tool_calls 的纯文本响应原样放行。
2. 双清：结构化 ``tool_calls`` + provider 原始 ``additional_kwargs.tool_calls``，
   经 ``clone_ai_message_with_tool_calls`` 一次完成；``finish_reason`` 保留 provider
   原值（不改写成 ``tool_calls``），下游 SSE / 转换器才知道这是被安全抑制。
3. 注册在 LoopDetection 之后（链表中更靠后）--逆序 after_model 使 Safety 最先跑，
   清空 tool_calls 后 Loop 在干净消息上计数，不触发误报。
4. 不走 consume_stop_reason--provider 安全终止是另一类信号，不是 guard cap，
   不 surface 为 token_capped/loop_capped。
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import AIMessage
from langgraph.runtime import Runtime

from helix.agents.middlewares.safety_termination_detectors import (
    SafetyTermination,
    SafetyTerminationDetector,
    default_detectors,
)
from helix.agents.middlewares.tool_call_metadata import clone_ai_message_with_tool_calls

if TYPE_CHECKING:
    from helix.config.safety_finish_reason_config import SafetyFinishReasonConfig

logger = logging.getLogger(__name__)


_USER_FACING_MESSAGE = (
    "The model provider stopped this response with a safety-related signal "
    "({reason_field}={reason_value!r}, detector={detector!r}). Any tool "
    "calls produced in this turn were suppressed because their arguments "
    "may be truncated and unsafe to execute. Please rephrase the request "
    "or ask for a narrower output."
)


class SafetyFinishReasonMiddleware(AgentMiddleware[AgentState]):
    """Strip tool_calls from AIMessages flagged by a SafetyTerminationDetector."""

    def __init__(self, detectors: list[SafetyTerminationDetector] | None = None) -> None:
        super().__init__()
        # Copy so caller mutations after construction don't leak into us.
        self._detectors: list[SafetyTerminationDetector] = list(detectors) if detectors else default_detectors()

    @classmethod
    def from_config(cls, config: SafetyFinishReasonConfig) -> SafetyFinishReasonMiddleware:
        """Construct from validated Pydantic config, honouring the
        reflection-loaded detector list when provided.

        An explicit empty list is intentionally rejected - it would silently
        disable detection while leaving the middleware in the chain, which
        is the worst of both worlds. Use ``enabled: false`` instead.

        空 detectors 列表非法--要禁用就 ``enabled: false``，避免"中间件在链上
        却不检测"的最坏情况。
        """
        if config.detectors is None:
            return cls()

        if not config.detectors:
            raise ValueError("safety_finish_reason.detectors must be omitted (use built-ins) or contain at least one entry; use enabled=false to disable the middleware entirely.")

        from helix.reflection import resolve_variable

        detectors: list[SafetyTerminationDetector] = []
        for entry in config.detectors:
            detector_cls = resolve_variable(entry.use)
            kwargs = dict(entry.config) if entry.config else {}
            detector = detector_cls(**kwargs)
            if not isinstance(detector, SafetyTerminationDetector):
                raise TypeError(f"{entry.use} did not produce a SafetyTerminationDetector (got {type(detector).__name__}); ensure it has a `name` attribute and a `detect(message)` method")
            detectors.append(detector)
        return cls(detectors=detectors)

    # ----- detection -------------------------------------------------------

    def _detect(self, message: AIMessage) -> SafetyTermination | None:
        # 逐个 detector 探测，单个 detector 异常不传染--except 后继续遍历下一个。
        for detector in self._detectors:
            try:
                hit = detector.detect(message)
            except Exception:  # noqa: BLE001 - never let a buggy detector break the agent run
                logger.exception("SafetyTerminationDetector %r raised; treating as no-match", getattr(detector, "name", type(detector).__name__))
                continue
            if hit is not None:
                return hit
        return None

    # ----- message rewriting ----------------------------------------------

    @staticmethod
    def _append_user_message(content: object, text: str) -> str | list:
        """Append a plain-text explanation to AIMessage content.

        Mirrors ``LoopDetectionMiddleware._append_text`` so list-content
        responses (Anthropic thinking blocks, vLLM reasoning splits) keep
        their structure instead of being string-coerced into a TypeError.

        list-content 兼容：Anthropic thinking blocks / vLLM reasoning 分段把
        content 表示成 list[dict]，追加解释必须保持 list 结构（追加 text block），
        不能直接 str +，否则 TypeError。
        """
        if content is None or content == "":
            return text
        if isinstance(content, list):
            return [*content, {"type": "text", "text": f"\n\n{text}"}]
        if isinstance(content, str):
            return content + f"\n\n{text}"
        return str(content) + f"\n\n{text}"

    def _build_suppressed_message(
        self,
        message: AIMessage,
        termination: SafetyTermination,
    ) -> AIMessage:
        suppressed_names = [tc.get("name") or "unknown" for tc in (message.tool_calls or [])]
        explanation = _USER_FACING_MESSAGE.format(
            reason_field=termination.reason_field,
            reason_value=termination.reason_value,
            detector=termination.detector,
        )
        new_content = self._append_user_message(message.content, explanation)

        # clone_ai_message_with_tool_calls handles structured tool_calls,
        # raw additional_kwargs.tool_calls, and function_call in one shot.
        # It only rewrites finish_reason when the old value was "tool_calls",
        # which is not our case - content_filter / refusal / SAFETY stay put
        # so downstream SSE / converters keep seeing the real provider reason.
        cleared = clone_ai_message_with_tool_calls(message, [], content=new_content)

        # Re-clone additional_kwargs so we don't accidentally mutate the
        # dict returned by clone_ai_message_with_tool_calls (which already
        # made a shallow copy, but downstream model_copy still references
        # it). Then stamp the observability record.
        # 盖 additional_kwargs.safety_termination 可观测性记录，便于审计。
        kwargs = dict(getattr(cleared, "additional_kwargs", None) or {})
        kwargs["safety_termination"] = {
            "detector": termination.detector,
            "reason_field": termination.reason_field,
            "reason_value": termination.reason_value,
            "suppressed_tool_call_count": len(suppressed_names),
            "suppressed_tool_call_names": suppressed_names,
            "extras": dict(termination.extras) if termination.extras else {},
        }
        return cleared.model_copy(update={"additional_kwargs": kwargs})

    # ----- observability ---------------------------------------------------

    def _emit_event(
        self,
        termination: SafetyTermination,
        suppressed_names: list[str],
        runtime: Runtime,
    ) -> None:
        """Notify SSE consumers (e.g. the web UI) that a tool turn was
        suppressed so they can reconcile any "tool starting..." placeholders
        already streamed to the user. Failures are logged at debug and
        ignored - this is a best-effort signal."""
        try:
            from langgraph.config import get_stream_writer

            writer = get_stream_writer()
        except Exception:  # noqa: BLE001
            logger.debug("get_stream_writer unavailable; skipping safety_termination event", exc_info=True)
            return

        thread_id = None
        if runtime is not None and getattr(runtime, "context", None):
            thread_id = runtime.context.get("thread_id") if isinstance(runtime.context, dict) else None

        try:
            writer(
                {
                    "type": "safety_termination",
                    "detector": termination.detector,
                    "reason_field": termination.reason_field,
                    "reason_value": termination.reason_value,
                    "suppressed_tool_call_count": len(suppressed_names),
                    "suppressed_tool_call_names": suppressed_names,
                    "thread_id": thread_id,
                }
            )
        except Exception:  # noqa: BLE001
            logger.debug("Failed to emit safety_termination stream event", exc_info=True)

    def _record_audit_event(
        self,
        termination: SafetyTermination,
        message,
        tool_calls: list[dict],
        runtime: Runtime,
    ) -> None:
        """Write a ``middleware:safety_termination`` record to RunEventStore
        for post-run auditability.

        The custom stream event in ``_emit_event`` is consumed by live SSE
        clients and disappears after the run; this event is persisted so an
        operator can answer "which runs were safety-suppressed today?" from
        a single SQL query without joining the message body. Worker exposes
        the run-scoped ``RunJournal`` via ``runtime.context["__run_journal"]``;
        absent in unit-test / subagent / no-event-store paths, in which case
        we silently skip.

        Tool **arguments** are deliberately **not** recorded - those are the
        very content the provider filtered; persisting them would defeat the
        purpose of the safety filter. Names / count / ids are sufficient for
        audit and debugging (issue #3028 review).

        不持久化被过滤的 tool arguments--那是 provider 过滤的内容本身，重新落盘
        等于绕开 safety filter。只记 names / ids / count / detector。
        """
        journal = None
        if runtime is not None and getattr(runtime, "context", None):
            context = runtime.context
            if isinstance(context, dict):
                journal = context.get("__run_journal")
        if journal is None:
            return

        suppressed_names = [tc.get("name") or "unknown" for tc in tool_calls]
        suppressed_ids = [tc.get("id") for tc in tool_calls if tc.get("id")]

        changes = {
            "detector": termination.detector,
            "reason_field": termination.reason_field,
            "reason_value": termination.reason_value,
            "suppressed_tool_call_count": len(tool_calls),
            "suppressed_tool_call_names": suppressed_names,
            "suppressed_tool_call_ids": suppressed_ids,
            "message_id": getattr(message, "id", None),
            "extras": dict(termination.extras) if termination.extras else {},
        }

        try:
            journal.record_middleware(
                tag="safety_termination",
                name=type(self).__name__,
                hook="after_model",
                action="suppress_tool_calls",
                changes=changes,
            )
        except Exception:  # noqa: BLE001
            # Audit-event persistence must never break agent execution.
            logger.debug("Failed to record middleware:safety_termination event", exc_info=True)

    # ----- main apply ------------------------------------------------------

    def _apply(self, state: AgentState, runtime: Runtime) -> dict | None:
        messages = state.get("messages", [])
        if not messages:
            return None

        last = messages[-1]
        if not isinstance(last, AIMessage):
            return None

        # Issue scope: only intervene when there's something to suppress.
        # ``content_filter`` without tool_calls is allowed through unchanged
        # so the partial text response (if any) reaches the user naturally.
        # 只在有 tool_calls 时干预--无 tool_calls 的 content_filter 纯文本原样放行。
        tool_calls = last.tool_calls
        if not tool_calls:
            return None

        termination = self._detect(last)
        if termination is None:
            return None

        patched = self._build_suppressed_message(last, termination)

        thread_id = None
        if runtime is not None and getattr(runtime, "context", None):
            thread_id = runtime.context.get("thread_id") if isinstance(runtime.context, dict) else None

        logger.warning(
            "Provider safety termination detected - suppressed %d tool call(s)",
            len(tool_calls),
            extra={
                "thread_id": thread_id,
                "detector": termination.detector,
                "reason_field": termination.reason_field,
                "reason_value": termination.reason_value,
                "suppressed_tool_call_names": [tc.get("name") for tc in tool_calls],
            },
        )

        self._emit_event(termination, [tc.get("name") or "unknown" for tc in tool_calls], runtime)
        self._record_audit_event(termination, last, list(tool_calls), runtime)

        return {"messages": [patched]}

    # ----- hooks -----------------------------------------------------------

    @override
    def after_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)

    @override
    async def aafter_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)
```

---

## 3. TokenBudgetMiddleware（per-run token 预算 + token_capped）

```python
# core/helix/agents/middlewares/token_budget_middleware.py
"""Middleware to enforce per-run token budget limits.
Tracks cumulative token usage (input, output, total) across model calls within
a single agent run and enforces configurable soft-warning and hard-stop
thresholds.
Detection strategy:
  1. After each model response, sum the `usage_metadata` of all `AIMessage`s
     in the current thread history. This automatically captures tokens from
     subagents because `TokenUsageMiddleware` retroactively adds them to the
     history.
  2. If the highest fraction (input, output, or total) >= warn_threshold,
     queue a warning.
  3. If the highest fraction >= hard_stop_threshold, strip tool_calls.
Warning injection uses the deferred pattern:
  - after_model queues the warning (does NOT mutate state).
  - wrap_model_call injects it as a HumanMessage at the next model call.
This preserves AIMessage(tool_calls) -> ToolMessage pairing.

Stop-reason surfacing (#3875 Phase 2):
  The hard stop does NOT raise - it strips tool_calls so the agent loop
  terminates naturally and produces a final answer. To let the caller (e.g.
  the subagent executor) distinguish a budget-capped completion from a clean
  one, the run that triggered the hard stop is recorded in ``_stop_reason``
  and exposed via :meth:`consume_stop_reason`. That dict is intentionally NOT
  cleared by ``after_agent``/``_clear_run_state`` so the executor can read it
  after the run returns; the bounded dict prevents unbounded growth on
  abandoned runs, and each subagent run builds a fresh middleware instance so
  there is no cross-run contamination.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any, override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelCallResult, ModelRequest, ModelResponse
from langchain_core.messages import AIMessage, HumanMessage
from langgraph.runtime import Runtime

from helix.agents.middlewares._bounded_dict import BoundedDict
from helix.config.token_budget_config import TokenBudgetConfig

logger = logging.getLogger(__name__)

_BUDGET_WARNING_MSG = (
    "[TOKEN BUDGET WARNING] You have used {used:,} of your {budget:,} {reason} token budget ({percent:.0f}%). Wrap up your current work and produce a final answer. Avoid starting new tool calls unless absolutely necessary."
)
_BUDGET_EXCEEDED_MSG = "[TOKEN BUDGET EXCEEDED] The {reason} token usage ({used:,}) has exceeded the safety limit ({budget:,}). Producing final answer with results collected so far."


@dataclass
class TokenUsage:
    input: int = 0
    output: int = 0
    total: int = 0


class TokenBudgetMiddleware(AgentMiddleware[AgentState]):
    """Enforce per-run token budget limits."""

    def __init__(self, config: TokenBudgetConfig) -> None:
        super().__init__()
        self._config = config
        self._lock = threading.Lock()

        # Keyed strictly by run_id (clobber-safe) and bounded (leak-safe)
        # 所有 per-run 状态严格按 run_id 键控（防 clobber）且有界（防泄漏）。
        self._warned: BoundedDict[str, bool] = BoundedDict(1000)
        self._pending_warnings: BoundedDict[str, list[str]] = BoundedDict(1000)
        self._seen_messages: BoundedDict[str, dict[str, tuple[int, int]]] = BoundedDict(1000)
        self._cumulative_usage: BoundedDict[str, TokenUsage] = BoundedDict(1000)
        # Stop reason set when the hard-stop fires. NOT cleared by
        # ``_clear_run_state``/``after_agent`` so the executor can consume it
        # after the run returns; bounded so abandoned runs cannot leak.
        # hard-stop 触发时设置的 stop 原因。不被 after_agent 清除，使执行器能在
        # run 返回后消费；有界防泄漏。
        self._stop_reason: BoundedDict[str, str] = BoundedDict(1000)

    @classmethod
    def from_config(cls, config: TokenBudgetConfig) -> TokenBudgetMiddleware:
        return cls(config=config)

    def reset(self) -> None:
        with self._lock:
            self._warned.clear()
            self._pending_warnings.clear()
            self._seen_messages.clear()
            self._cumulative_usage.clear()
            self._stop_reason.clear()

    def consume_stop_reason(self, run_id: str | None) -> str | None:
        """Pop and return the stop reason the hard-stop set for this run.

        Returns ``"token_capped"`` when the budget hard-stop fired during the
        run, otherwise ``None``. The executor calls this after the run returns
        to decide whether a completed subagent was actually budget-capped
        (and should carry ``stop_reason=token_capped`` to the lead). Popping
        keeps the dict from accumulating across runs on a reused instance.

        lead agent 没有执行器调这个方法（lead run 是顶层），stop_reason 只会
        在 BoundedDict 里老化淘汰；子代理执行器会调（见 [[subagent-delegation]]）。
        """
        with self._lock:
            return self._stop_reason.pop(run_id, None)

    @staticmethod
    def _get_run_id(runtime: Runtime) -> str:
        ctx = getattr(runtime, "context", None)
        if isinstance(ctx, dict) and "run_id" in ctx:
            return ctx["run_id"]
        # Fallback to runtime object ID to prevent collisions across embedded client runs
        return str(id(runtime))

    def _clear_run_state(self, run_id: str) -> None:
        with self._lock:
            self._warned.pop(run_id, None)
            self._pending_warnings.pop(run_id, None)
            self._seen_messages.pop(run_id, None)
            self._cumulative_usage.pop(run_id, None)

    @override
    def before_agent(self, state: AgentState, runtime: Runtime) -> None:
        if not self._config.enabled:
            return

        # Mark all old messages from previous runs as 'seen' so they don't count toward THIS run's budget
        # 把历史 run 的旧消息标为 seen，不计入本次 run 的预算。
        messages = state.get("messages", [])
        if not messages:
            return

        run_id = self._get_run_id(runtime)
        with self._lock:
            seen = self._seen_messages.setdefault(run_id, {})
            self._cumulative_usage.setdefault(run_id, TokenUsage())

            for msg in messages:
                if isinstance(msg, AIMessage) and msg.id and hasattr(msg, "usage_metadata"):
                    usage = msg.usage_metadata or {}
                    input_tokens = usage.get("input_tokens", 0)
                    output_tokens = usage.get("output_tokens", 0)
                    seen[msg.id] = (input_tokens, output_tokens)

    @override
    async def abefore_agent(self, state: AgentState, runtime: Runtime) -> None:
        self.before_agent(state, runtime)

    @override
    def after_agent(self, state: AgentState, runtime: Runtime) -> None:
        if not self._config.enabled:
            return
        self._clear_run_state(self._get_run_id(runtime))

    @override
    async def aafter_agent(self, state: AgentState, runtime: Runtime) -> None:
        self.after_agent(state, runtime)

    @staticmethod
    def _append_text(content: str | list[dict | None] | None, stop_msg: str) -> str | list[dict | str]:
        """Append a stop message to an AIMessage.content field."""
        if content is None:
            return stop_msg
        if isinstance(content, str):
            if content:
                return f"{content}\n\n{stop_msg}"
            return f"\n\n{stop_msg}"
        if isinstance(content, list):
            new_content = list(content)
            new_content.append({"type": "text", "text": f"\n\n{stop_msg}"})
            return new_content
        return f"{content}\n\n{stop_msg}"

    def _build_hard_stop_update(self, msg: AIMessage, stop_msg: str) -> dict[str, Any]:
        """Build the state update dictionary for a hard stop.

        hard-stop 的状态更新：剥 tool_calls + 清 additional_kwargs 的
        tool_calls/function_call + 把 finish_reason 从 tool_calls 改成 stop。
        """
        updated_content = self._append_text(msg.content, stop_msg)
        kwargs = dict(msg.additional_kwargs) if msg.additional_kwargs else {}
        if "tool_calls" in kwargs:
            del kwargs["tool_calls"]
        if "function_call" in kwargs:
            del kwargs["function_call"]

        response_metadata = dict(getattr(msg, "response_metadata", {}) or {})

        if response_metadata.get("finish_reason") == "tool_calls":
            response_metadata["finish_reason"] = "stop"

        stopped_msg = msg.model_copy(update={"content": updated_content, "tool_calls": [], "additional_kwargs": kwargs, "response_metadata": response_metadata})
        return {"messages": [stopped_msg]}

    def _apply(self, state: AgentState, runtime: Runtime) -> dict | None:
        if not self._config.enabled:
            return None

        messages = state.get("messages", [])
        if not messages:
            return None

        last_msg = messages[-1]
        if not isinstance(last_msg, AIMessage):
            return None

        run_id = self._get_run_id(runtime)

        with self._lock:
            seen = self._seen_messages.setdefault(run_id, {})
            usage_accum = self._cumulative_usage.setdefault(run_id, TokenUsage())

            for msg in messages:
                if isinstance(msg, AIMessage) and msg.id and hasattr(msg, "usage_metadata"):
                    usage = msg.usage_metadata or {}

                    input_tokens = usage.get("input_tokens", 0)
                    output_tokens = usage.get("output_tokens", 0)

                    # Check what previously recorded for this exact message
                    prev_input, prev_output = seen.get(msg.id, (0, 0))

                    # Calculate if any new tokens were added (handles retroactive subagent tokens)
                    # 用 diff 累加，处理子代理 token 回填（TokenUsageMiddleware 事后加到历史）。
                    diff_input = max(0, input_tokens - prev_input)
                    diff_output = max(0, output_tokens - prev_output)

                    if diff_input > 0 or diff_output > 0:
                        usage_accum.input += diff_input
                        usage_accum.output += diff_output
                        usage_accum.total += diff_input + diff_output
                        seen[msg.id] = (input_tokens, output_tokens)

            if usage_accum.total <= 0:
                return None

            fractions = [("total", usage_accum.total, self._config.max_tokens)]
            if self._config.max_input_tokens:
                fractions.append(("input", usage_accum.input, self._config.max_input_tokens))
            if self._config.max_output_tokens:
                fractions.append(("output", usage_accum.output, self._config.max_output_tokens))

            highest_fraction = 0.0
            trigger_reason = ""
            trigger_used = 0
            trigger_budget = 0

            for reason, used, limit in fractions:
                frac = used / limit
                if frac > highest_fraction:
                    highest_fraction = frac
                    trigger_reason = reason
                    trigger_used = used
                    trigger_budget = limit

            if highest_fraction >= self._config.hard_stop_threshold:
                logger.warning("Token budget hard stop triggered for run %s: %s limit exceeded", run_id, trigger_reason)
                # Record the stop reason so the executor can surface
                # ``stop_reason=token_capped`` to the lead after the run
                # returns (the hard stop itself does not raise). See
                # ``consume_stop_reason``.
                self._stop_reason[run_id] = "token_capped"
                stop_text = _BUDGET_EXCEEDED_MSG.format(reason=trigger_reason, used=trigger_used, budget=trigger_budget)
                return self._build_hard_stop_update(last_msg, stop_text)

            if highest_fraction >= self._config.warn_threshold and not self._warned.get(run_id, False):
                self._warned[run_id] = True
                percent = highest_fraction * 100
                warn_text = _BUDGET_WARNING_MSG.format(reason=trigger_reason, used=trigger_used, budget=trigger_budget, percent=percent)
                logger.info("Token budget warning triggered for run %s: %s limit at %.1f%%", run_id, trigger_reason, percent)
                # queue warning for wrap_model_call
                warnings = self._pending_warnings.setdefault(run_id, [])
                warnings.append(warn_text)
                return None

            return None

    @override
    def after_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)

    @override
    async def aafter_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)

    def _drain_pending_warnings(self, runtime: Runtime) -> list[str]:
        if not self._config.enabled:
            return []

        run_id = self._get_run_id(runtime)
        with self._lock:
            warnings = self._pending_warnings.pop(run_id, None)
        return warnings or []

    def _inject_warnings(self, request: ModelRequest, warnings: list[str]) -> ModelRequest:
        if not warnings:
            return request

        merged_text = "\n\n".join(warnings)
        warning_msg = HumanMessage(content=merged_text, name="budget_warning")

        messages = getattr(request, "messages", [])
        new_messages = list(messages) + [warning_msg]
        return request.override(messages=new_messages)

    @override
    def wrap_model_call(self, request: ModelRequest, handler: Callable[[ModelRequest], ModelResponse]) -> ModelCallResult:

        warnings = self._drain_pending_warnings(request.runtime)
        request = self._inject_warnings(request, warnings)

        return handler(request)

    @override
    async def awrap_model_call(self, request: ModelRequest, handler: Callable[[ModelRequest], Awaitable[ModelResponse]]) -> ModelCallResult:
        warnings = self._drain_pending_warnings(request.runtime)
        request = self._inject_warnings(request, warnings)
        return await handler(request)
```

---

## 4. LoopDetectionMiddleware（重复 tool-call 检测 + loop_capped）

```python
# core/helix/agents/middlewares/loop_detection_middleware.py
"""Middleware to detect and break repetitive tool call loops.
P0 safety: prevents the agent from calling the same tool with the same
arguments indefinitely until the recursion limit kills the run.

Detection strategy:
  1. After each model response, hash the tool calls (name + args).
  2. Track recent hashes in a sliding window.
  3. If the same hash appears >= warn_threshold times, queue a
     "you are repeating yourself - wrap up" warning for the current
     thread/run. The warning is **injected at the next model call** (in
     ``wrap_model_call``) as a ``HumanMessage`` appended to the message
     list, *after* all ToolMessage responses to the previous
     AIMessage(tool_calls).
  4. If it appears >= hard_limit times, strip all tool_calls from the
     response so the agent is forced to produce a final text answer.

Why the warning is injected at ``wrap_model_call`` instead of
``after_model``:

  ``after_model`` fires immediately after the model emits an
  ``AIMessage`` that may carry ``tool_calls``. The tools node has not
  run yet, so no matching ``ToolMessage`` exists in the history. Any
  message we add here lands *between* the assistant's tool_calls and
  their responses. OpenAI/Moonshot reject the next request with
  ``"tool_call_ids did not have response messages"`` because their
  validators require the assistant's tool_calls to be followed
  immediately by tool messages. Anthropic also disallows mid-stream
  ``SystemMessage``. By deferring the warning to ``wrap_model_call``,
  every prior ToolMessage is already present in the request's message
  list and the warning is appended at the end - pairing intact, no
  ``AIMessage`` semantics are mutated.

Queued warnings are intentionally transient. If a run ends before the
next model request drains a queued warning, ``after_agent`` drops it
instead of carrying it into a later invocation for the same thread. The
hard-stop path still forces termination when the configured safety limit
is reached.

Stop-reason surfacing (#3875 Phase 2):
  Like the token-budget guard, the loop hard stop does NOT raise - it
  strips ``tool_calls`` so the agent loop terminates naturally with a
  final answer. To let the caller (the subagent executor) distinguish a
  loop-capped completion from a clean one, the run that triggered the hard
  stop is recorded in ``_stop_reason`` and exposed via
  :meth:`consume_stop_reason`. The executor collects that reason alongside
  the token-budget guard's so a loop-capped run surfaces as
  ``completed + loop_capped`` and the lead/ledger can tell it was capped
  without parsing result text.
"""

from __future__ import annotations

import hashlib
import json
import logging
import threading
from collections import OrderedDict, defaultdict
from collections.abc import Awaitable, Callable
from copy import deepcopy
from typing import TYPE_CHECKING, override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelCallResult, ModelRequest, ModelResponse
from langchain_core.messages import HumanMessage
from langgraph.runtime import Runtime

from helix.agents.middlewares._bounded_dict import BoundedDict

if TYPE_CHECKING:
    from helix.config.loop_detection_config import LoopDetectionConfig

logger = logging.getLogger(__name__)

# Defaults - can be overridden via constructor
_DEFAULT_WARN_THRESHOLD = 3  # inject warning after 3 identical calls
_DEFAULT_HARD_LIMIT = 5  # force-stop after 5 identical calls
_DEFAULT_WINDOW_SIZE = 20  # track last N tool calls
_DEFAULT_MAX_TRACKED_THREADS = 100  # LRU eviction limit
_DEFAULT_TOOL_FREQ_WARN = 30  # warn after 30 calls to the same tool type
_DEFAULT_TOOL_FREQ_HARD_LIMIT = 50  # force-stop after 50 calls to the same tool type
_MAX_PENDING_WARNINGS_PER_RUN = 4


def _normalize_tool_call_args(raw_args: object) -> tuple[dict, str | None]:
    """Normalize tool call args to a dict plus an optional fallback key.

    Some providers serialize ``args`` as a JSON string instead of a dict.
    We defensively parse those cases so loop detection does not crash while
    still preserving a stable fallback key for non-dict payloads.
    """
    if isinstance(raw_args, dict):
        return raw_args, None

    if isinstance(raw_args, str):
        try:
            parsed = json.loads(raw_args)
        except (TypeError, ValueError, json.JSONDecodeError):
            return {}, raw_args

        if isinstance(parsed, dict):
            return parsed, None
        return {}, json.dumps(parsed, sort_keys=True, default=str)

    if raw_args is None:
        return {}, None

    return {}, json.dumps(raw_args, sort_keys=True, default=str)


def _stable_tool_key(name: str, args: dict, fallback_key: str | None) -> str:
    """Derive a stable key from salient args without overfitting to noise.

    按工具类型选稳定键，避免误判循环：
    - read_file：路径 + start/end 行号按 200 行 bucket，避免连续翻页被误判循环；
    - write_file / str_replace：内容敏感，全 args hash，避免同路径不同 payload 被合并；
    - 其他工具：抽 salient 字段 (path/url/query/command/pattern/glob/cmd) 排序后 hash；
    - 没有 salient 字段：退化到全 args JSON。
    """
    if name == "read_file" and fallback_key is None:
        path = args.get("path") or ""
        start_line = args.get("start_line")
        end_line = args.get("end_line")

        bucket_size = 200
        try:
            start_line = int(start_line) if start_line is not None else 1
        except (TypeError, ValueError):
            start_line = 1
        try:
            end_line = int(end_line) if end_line is not None else start_line
        except (TypeError, ValueError):
            end_line = start_line

        start_line, end_line = sorted((start_line, end_line))
        bucket_start = max(start_line, 1)
        bucket_end = max(end_line, 1)
        bucket_start = (bucket_start - 1) // bucket_size
        bucket_end = (bucket_end - 1) // bucket_size
        return f"{path}:{bucket_start}-{bucket_end}"

    # write_file / str_replace are content-sensitive: same path may be updated
    # with different payloads during iteration. Using only salient fields (path)
    # can collapse distinct calls, so we hash full args to reduce false positives.
    if name in {"write_file", "str_replace"}:
        if fallback_key is not None:
            return fallback_key
        return json.dumps(args, sort_keys=True, default=str)

    salient_fields = ("path", "url", "query", "command", "pattern", "glob", "cmd")
    stable_args = {field: args[field] for field in salient_fields if args.get(field) is not None}
    if stable_args:
        return json.dumps(stable_args, sort_keys=True, default=str)

    if fallback_key is not None:
        return fallback_key

    return json.dumps(args, sort_keys=True, default=str)


def _hash_tool_calls(tool_calls: list[dict]) -> str:
    """Deterministic hash of a set of tool calls (name + stable key).

    This is intended to be order-independent: the same multiset of tool calls
    should always produce the same hash, regardless of their input order.

    多 tool_call 按 hash 排序后再 join，让"工具集合"而非"工具顺序"决定循环判定。
    """
    # Normalize each tool call to a stable (name, key) structure.
    normalized: list[str] = []
    for tc in tool_calls:
        name = tc.get("name", "")
        args, fallback_key = _normalize_tool_call_args(tc.get("args", {}))
        key = _stable_tool_key(name, args, fallback_key)

        normalized.append(f"{name}:{key}")

    # Sort so permutations of the same multiset of calls yield the same ordering.
    normalized.sort()
    blob = json.dumps(normalized, sort_keys=True, default=str)
    return hashlib.md5(blob.encode()).hexdigest()[:12]


_WARNING_MSG = "[LOOP DETECTED] You are repeating the same tool calls. Stop calling tools and produce your final answer now. If you cannot complete the task, summarize what you accomplished so far."

_TOOL_FREQ_WARNING_MSG = (
    "[LOOP DETECTED] You have called {tool_name} {count} times without producing a final answer. Stop calling tools and produce your final answer now. If you cannot complete the task, summarize what you accomplished so far."
)

_HARD_STOP_MSG = "[FORCED STOP] Repeated tool calls exceeded the safety limit. Producing final answer with results collected so far."

_TOOL_FREQ_HARD_STOP_MSG = "[FORCED STOP] Tool {tool_name} called {count} times - exceeded the per-tool safety limit. Producing final answer with results collected so far."


class LoopDetectionMiddleware(AgentMiddleware[AgentState]):
    """Detects and breaks repetitive tool call loops.

    Threshold parameters are validated upstream by :class:`LoopDetectionConfig`;
    construct via :meth:`from_config` to ensure values pass Pydantic validation.

    Args:
        warn_threshold: Number of identical tool call sets before injecting
            a warning message. Default: 3.
        hard_limit: Number of identical tool call sets before stripping
            tool_calls entirely. Default: 5.
        window_size: Size of the sliding window for tracking calls.
            Default: 20.
        max_tracked_threads: Maximum number of threads to track before
            evicting the least recently used. Default: 100.
        tool_freq_warn: Number of calls to the same tool *type* (regardless
            of arguments) before injecting a frequency warning. Catches
            cross-file read loops that hash-based detection misses.
            Default: 30.
        tool_freq_hard_limit: Number of calls to the same tool type before
            forcing a stop. Default: 50.
        tool_freq_overrides: Per-tool overrides for frequency thresholds,
            keyed by tool name. Each value is a ``(warn, hard_limit)`` tuple
            that replaces ``tool_freq_warn`` / ``tool_freq_hard_limit`` for
            that specific tool. Tools not listed here fall back to the global
            thresholds. Useful for raising limits on intentionally
            high-frequency tools (e.g. ``bash`` in batch pipelines) without
            weakening protection on all other tools. Default: ``None``
            (no overrides).
    """

    def __init__(
        self,
        warn_threshold: int = _DEFAULT_WARN_THRESHOLD,
        hard_limit: int = _DEFAULT_HARD_LIMIT,
        window_size: int = _DEFAULT_WINDOW_SIZE,
        max_tracked_threads: int = _DEFAULT_MAX_TRACKED_THREADS,
        tool_freq_warn: int = _DEFAULT_TOOL_FREQ_WARN,
        tool_freq_hard_limit: int = _DEFAULT_TOOL_FREQ_HARD_LIMIT,
        tool_freq_overrides: dict[str, tuple[int, int]] | None = None,
    ):
        super().__init__()
        self.warn_threshold = warn_threshold
        self.hard_limit = hard_limit
        self.window_size = window_size
        self.max_tracked_threads = max_tracked_threads
        self.tool_freq_warn = tool_freq_warn
        self.tool_freq_hard_limit = tool_freq_hard_limit
        self._tool_freq_overrides: dict[str, tuple[int, int]] = tool_freq_overrides or {}
        self._lock = threading.Lock()
        self._history: OrderedDict[str, list[str]] = OrderedDict()
        self._warned: dict[str, set[str]] = defaultdict(set)
        self._tool_freq: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
        self._tool_freq_warned: dict[str, set[str]] = defaultdict(set)
        # Per-thread/run queue of warnings to inject at the next model call.
        # Populated by ``after_model`` (detection) and drained by
        # ``wrap_model_call`` (injection); see module docstring.
        self._pending_warnings: dict[tuple[str, str], list[str]] = defaultdict(list)
        self._pending_warning_touch_order: OrderedDict[tuple[str, str], None] = OrderedDict()
        self._max_pending_warning_keys = max(1, self.max_tracked_threads * 2)
        # Stop reason set when a hard-stop fires (#3875 Phase 2). Keyed by run_id
        # (matching ``TokenBudgetMiddleware``) and bounded - the lead agent's
        # middleware instance is long-lived across many runs, so without a cap
        # an entry would accumulate for every looped lead run. Intentionally NOT
        # cleared by ``after_agent``/``_clear_current_run_pending_warnings`` so
        # the subagent executor can consume it after the run returns; ``reset()``
        # still drops it.
        self._stop_reason: BoundedDict[str, str] = BoundedDict(1000)

    @classmethod
    def from_config(cls, config: LoopDetectionConfig) -> LoopDetectionMiddleware:
        """Construct from a Pydantic-validated config, trusting its validation."""
        return cls(
            warn_threshold=config.warn_threshold,
            hard_limit=config.hard_limit,
            window_size=config.window_size,
            max_tracked_threads=config.max_tracked_threads,
            tool_freq_warn=config.tool_freq_warn,
            tool_freq_hard_limit=config.tool_freq_hard_limit,
            tool_freq_overrides={name: (o.warn, o.hard_limit) for name, o in config.tool_freq_overrides.items()},
        )

    def _get_thread_id(self, runtime: Runtime) -> str:
        """Extract thread_id from runtime context for per-thread tracking."""
        thread_id = runtime.context.get("thread_id") if runtime.context else None
        if thread_id:
            return str(thread_id)
        return "default"

    def _get_run_id(self, runtime: Runtime) -> str:
        """Extract run_id from runtime context for per-run warning scoping."""
        run_id = runtime.context.get("run_id") if runtime.context else None
        if run_id:
            return str(run_id)
        return "default"

    def consume_stop_reason(self, run_id: str | None) -> str | None:
        """Pop and return the stop reason the hard-stop set for this run.

        Returns ``"loop_capped"`` when a repeated tool-call loop tripped the hard
        stop during the run - the run still completed with a forced final answer
        (the hard stop strips ``tool_calls`` rather than raising). The subagent
        executor calls this after the run returns so a loop-capped completion
        carries ``stop_reason=loop_capped`` to the lead instead of looking like
        a clean ``completed``. Mirrors ``TokenBudgetMiddleware.consume_stop_reason``;
        popping keeps the dict from accumulating on a reused instance.
        """
        with self._lock:
            return self._stop_reason.pop(run_id, None)

    def _pending_key(self, runtime: Runtime) -> tuple[str, str]:
        """Return the pending-warning key for the current thread/run."""
        return self._get_thread_id(runtime), self._get_run_id(runtime)

    def _evict_if_needed(self) -> None:
        """Evict least recently used threads if over the limit.

        Must be called while holding self._lock.
        """
        while len(self._history) > self.max_tracked_threads:
            evicted_id, _ = self._history.popitem(last=False)
            self._warned.pop(evicted_id, None)
            self._tool_freq.pop(evicted_id, None)
            self._tool_freq_warned.pop(evicted_id, None)
            for key in list(self._pending_warnings):
                if key[0] == evicted_id:
                    self._drop_pending_warning_key_locked(key)
            logger.debug("Evicted loop tracking for thread %s (LRU)", evicted_id)

    def _drop_pending_warning_key_locked(self, key: tuple[str, str]) -> None:
        """Drop all pending-warning bookkeeping for one thread/run key.

        Must be called while holding self._lock.
        """
        self._pending_warnings.pop(key, None)
        self._pending_warning_touch_order.pop(key, None)

    def _touch_pending_warning_key_locked(self, key: tuple[str, str]) -> None:
        """Mark a pending-warning key as recently used.

        Must be called while holding self._lock.
        """
        self._pending_warning_touch_order[key] = None
        self._pending_warning_touch_order.move_to_end(key)

    def _prune_pending_warning_state_locked(self, protected_key: tuple[str, str]) -> None:
        """Cap pending-warning state across abnormal or concurrent runs.

        Must be called while holding self._lock.
        """
        overflow = len(self._pending_warning_touch_order) - self._max_pending_warning_keys
        if overflow <= 0:
            return

        candidates = [key for key in self._pending_warning_touch_order if key != protected_key]
        for key in candidates[:overflow]:
            self._drop_pending_warning_key_locked(key)

    def _queue_pending_warning(self, runtime: Runtime, warning: str) -> None:
        """Queue one transient warning for the current thread/run with caps."""
        pending_key = self._pending_key(runtime)
        with self._lock:
            warnings = self._pending_warnings[pending_key]
            if warning not in warnings:
                warnings.append(warning)
            if len(warnings) > _MAX_PENDING_WARNINGS_PER_RUN:
                del warnings[: len(warnings) - _MAX_PENDING_WARNINGS_PER_RUN]
            self._touch_pending_warning_key_locked(pending_key)
            self._prune_pending_warning_state_locked(protected_key=pending_key)

    def _track_and_check(self, state: AgentState, runtime: Runtime) -> tuple[str | None, bool]:
        """Track tool calls and check for loops.

        Two detection layers:
          1. **Hash-based** (existing): catches identical tool call sets.
          2. **Frequency-based** (new): catches the same *tool type* being
             called many times with varying arguments (e.g. ``read_file``
             on 40 different files).

        Returns:
            (warning_message_or_none, should_hard_stop)
        """
        messages = state.get("messages", [])
        if not messages:
            return None, False

        last_msg = messages[-1]
        if getattr(last_msg, "type", None) != "ai":
            return None, False

        tool_calls = getattr(last_msg, "tool_calls", None)
        if not tool_calls:
            return None, False

        thread_id = self._get_thread_id(runtime)
        call_hash = _hash_tool_calls(tool_calls)

        with self._lock:
            # Touch / create entry (move to end for LRU)
            if thread_id in self._history:
                self._history.move_to_end(thread_id)
            else:
                self._history[thread_id] = []
                self._evict_if_needed()

            history = self._history[thread_id]
            history.append(call_hash)
            if len(history) > self.window_size:
                history[:] = history[-self.window_size :]

            warned_hashes = self._warned.get(thread_id)
            if warned_hashes is not None:
                warned_hashes.intersection_update(history)
                if not warned_hashes:
                    self._warned.pop(thread_id, None)

            count = history.count(call_hash)
            tool_names = [tc.get("name", "?") for tc in tool_calls]

            # --- Layer 1: hash-based (identical call sets) ---
            if count >= self.hard_limit:
                logger.error(
                    "Loop hard limit reached - forcing stop",
                    extra={
                        "thread_id": thread_id,
                        "call_hash": call_hash,
                        "count": count,
                        "tools": tool_names,
                    },
                )
                return _HARD_STOP_MSG, True

            if count >= self.warn_threshold:
                warned = self._warned[thread_id]
                if call_hash not in warned:
                    warned.add(call_hash)
                    logger.warning(
                        "Repetitive tool calls detected - injecting warning",
                        extra={
                            "thread_id": thread_id,
                            "call_hash": call_hash,
                            "count": count,
                            "tools": tool_names,
                        },
                    )
                    return _WARNING_MSG, False

            # --- Layer 2: per-tool-type frequency ---
            freq = self._tool_freq[thread_id]
            for tc in tool_calls:
                name = tc.get("name", "")
                if not name:
                    continue
                freq[name] += 1
                tc_count = freq[name]

                if name in self._tool_freq_overrides:
                    eff_warn, eff_hard = self._tool_freq_overrides[name]
                else:
                    eff_warn, eff_hard = self.tool_freq_warn, self.tool_freq_hard_limit

                if tc_count >= eff_hard:
                    logger.error(
                        "Tool frequency hard limit reached - forcing stop",
                        extra={
                            "thread_id": thread_id,
                            "tool_name": name,
                            "count": tc_count,
                        },
                    )
                    return _TOOL_FREQ_HARD_STOP_MSG.format(tool_name=name, count=tc_count), True

                if tc_count >= eff_warn:
                    warned = self._tool_freq_warned[thread_id]
                    if name not in warned:
                        warned.add(name)
                        logger.warning(
                            "Tool frequency warning - too many calls to same tool type",
                            extra={
                                "thread_id": thread_id,
                                "tool_name": name,
                                "count": tc_count,
                            },
                        )
                        return _TOOL_FREQ_WARNING_MSG.format(tool_name=name, count=tc_count), False

        return None, False

    @staticmethod
    def _append_text(content: str | list | None, text: str) -> str | list:
        """Append *text* to AIMessage content, handling str, list, and None.

        When content is a list of content blocks (e.g. Anthropic thinking mode),
        we append a new ``{"type": "text", ...}`` block instead of concatenating
        a string to a list, which would raise ``TypeError``.
        """
        if content is None:
            return text
        if isinstance(content, list):
            return [*content, {"type": "text", "text": f"\n\n{text}"}]
        if isinstance(content, str):
            return content + f"\n\n{text}"
        # Fallback: coerce unexpected types to str to avoid TypeError
        return str(content) + f"\n\n{text}"

    @staticmethod
    def _build_hard_stop_update(last_msg, content: str | list) -> dict:
        """Clear tool-call metadata so forced-stop messages serialize as plain assistant text."""
        update = {
            "tool_calls": [],
            "content": content,
        }

        additional_kwargs = dict(getattr(last_msg, "additional_kwargs", {}) or {})
        for key in ("tool_calls", "function_call"):
            additional_kwargs.pop(key, None)
        update["additional_kwargs"] = additional_kwargs

        response_metadata = deepcopy(getattr(last_msg, "response_metadata", {}) or {})
        if response_metadata.get("finish_reason") == "tool_calls":
            response_metadata["finish_reason"] = "stop"
        update["response_metadata"] = response_metadata

        return update

    def _apply(self, state: AgentState, runtime: Runtime) -> dict | None:
        warning, hard_stop = self._track_and_check(state, runtime)

        if hard_stop:
            # Record the stop reason so the executor can surface
            # ``stop_reason=loop_capped`` after the run returns (#3875 Phase 2).
            # The hard stop does not raise - it strips tool_calls and lets the
            # run finish with a forced final answer - so without this the caller
            # would see a clean ``completed``. See ``consume_stop_reason``.
            # Written under the lock to match ``TokenBudgetMiddleware``: the lead
            # agent's middleware instance is shared across concurrent Gateway
            # threads, so the bounded-dict write needs the same guard.
            run_id = self._get_run_id(runtime)
            with self._lock:
                self._stop_reason[run_id] = "loop_capped"
            # Strip tool_calls from the last AIMessage to force text output.
            # Once tool_calls are stripped, the AIMessage no longer requires
            # matching ToolMessage responses, so mutating it in place here
            # is safe for OpenAI/Moonshot pairing validators.
            messages = state.get("messages", [])
            last_msg = messages[-1]
            content = self._append_text(last_msg.content, warning or _HARD_STOP_MSG)
            stripped_msg = last_msg.model_copy(update=self._build_hard_stop_update(last_msg, content))
            return {"messages": [stripped_msg]}

        if warning:
            # Defer injection to the next model call. We must NOT alter the
            # AIMessage(tool_calls=...) here (would put framework words in
            # the model's mouth, polluting downstream consumers like
            # MemoryMiddleware), nor insert a separate non-tool message
            # (would break OpenAI/Moonshot tool-call pairing because the
            # tools node has not produced ToolMessage responses yet). The
            # warning is delivered via ``wrap_model_call`` below.
            self._queue_pending_warning(runtime, warning)
            return None

        return None

    def _clear_other_run_pending_warnings(self, runtime: Runtime) -> None:
        """Drop stale pending warnings for previous runs in this thread."""
        thread_id, current_run_id = self._pending_key(runtime)
        with self._lock:
            for key in list(self._pending_warnings):
                if key[0] == thread_id and key[1] != current_run_id:
                    self._drop_pending_warning_key_locked(key)

    def _clear_current_run_pending_warnings(self, runtime: Runtime) -> None:
        """Drop pending warnings owned by the current thread/run."""
        pending_key = self._pending_key(runtime)
        with self._lock:
            self._drop_pending_warning_key_locked(pending_key)

    @staticmethod
    def _format_warning_message(warnings: list[str]) -> str:
        """Merge pending warnings into one prompt message."""
        deduped = list(dict.fromkeys(warnings))
        return "\n\n".join(deduped)

    @override
    def before_agent(self, state: AgentState, runtime: Runtime) -> dict | None:
        self._clear_other_run_pending_warnings(runtime)
        return None

    @override
    async def abefore_agent(self, state: AgentState, runtime: Runtime) -> dict | None:
        self._clear_other_run_pending_warnings(runtime)
        return None

    @override
    def after_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)

    @override
    async def aafter_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)

    @override
    def after_agent(self, state: AgentState, runtime: Runtime) -> dict | None:
        self._clear_current_run_pending_warnings(runtime)
        return None

    @override
    async def aafter_agent(self, state: AgentState, runtime: Runtime) -> dict | None:
        self._clear_current_run_pending_warnings(runtime)
        return None

    def _drain_pending_warnings(self, runtime: Runtime) -> list[str]:
        """Pop and return all queued warnings for *runtime*'s thread/run."""
        pending_key = self._pending_key(runtime)
        with self._lock:
            warnings = self._pending_warnings.pop(pending_key, [])
            self._pending_warning_touch_order.pop(pending_key, None)
        return warnings

    def _augment_request(self, request: ModelRequest) -> ModelRequest:
        """Append queued loop warnings (if any) to the outgoing message list.

        The warning is placed *after* every existing message, including the
        ToolMessage responses to the previous AIMessage(tool_calls). This
        keeps ``assistant tool_calls -> tool_messages`` pairing intact for
        OpenAI/Moonshot, avoids the Anthropic mid-stream SystemMessage
        restriction (we use HumanMessage), and never mutates an existing
        AIMessage.
        """
        warnings = self._drain_pending_warnings(request.runtime)
        if not warnings:
            return request
        new_messages = [
            *request.messages,
            HumanMessage(content=self._format_warning_message(warnings), name="loop_warning"),
        ]
        return request.override(messages=new_messages)

    @override
    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelCallResult:
        return handler(self._augment_request(request))

    @override
    async def awrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], Awaitable[ModelResponse]],
    ) -> ModelCallResult:
        return await handler(self._augment_request(request))

    def reset(self, thread_id: str | None = None) -> None:
        """Clear tracking state. If thread_id given, clear only that thread."""
        with self._lock:
            if thread_id:
                self._history.pop(thread_id, None)
                self._warned.pop(thread_id, None)
                self._tool_freq.pop(thread_id, None)
                self._tool_freq_warned.pop(thread_id, None)
                for key in list(self._pending_warnings):
                    if key[0] == thread_id:
                        self._drop_pending_warning_key_locked(key)
            else:
                self._history.clear()
                self._warned.clear()
                self._tool_freq.clear()
                self._tool_freq_warned.clear()
                self._pending_warnings.clear()
                self._pending_warning_touch_order.clear()
                self._stop_reason.clear()
```

---

## 5. BoundedDict（per-run_id 有界状态）

```python
# core/helix/agents/middlewares/_bounded_dict.py
"""A small bounded ``OrderedDict`` shared by guard middlewares.

Guard middlewares (``TokenBudgetMiddleware``, ``LoopDetectionMiddleware``) keep
per-``run_id`` state that must not grow without bound on abandoned or reused
runs. This module provides the single shared implementation so both middlewares
cap identically and a future guard does not reinvent it.
"""

from __future__ import annotations

from collections import OrderedDict
from typing import Any


class BoundedDict(OrderedDict):
    """An ``OrderedDict`` that evicts the oldest entry once ``maxsize`` is reached.

    Used for per-``run_id`` state (stop-reason flags, pending warnings, usage
    accumulators) so a long-lived middleware instance on the lead agent cannot
    leak memory across many runs. Insertion order is preserved, so the
    least-recently-inserted key is evicted first.

    lead agent 的中间件实例跨大量 run 长期存活，per-run_id 状态若无界会在每个
    run 累积一条；BoundedDict 在满额时淘汰最早插入的 key，防泄漏。
    """

    def __init__(self, maxsize: int = 1000, *args: Any, **kwds: Any) -> None:
        self.maxsize = maxsize
        super().__init__(*args, **kwds)

    def __setitem__(self, key: Any, value: Any) -> None:
        if key not in self:
            if len(self) >= self.maxsize:
                self.popitem(last=False)
        super().__setitem__(key, value)
```

---

## 6. clone_ai_message_with_tool_calls（清空 tool_calls 统一入口）

```python
# core/helix/agents/middlewares/tool_call_metadata.py
"""Helpers for keeping AIMessage tool-call metadata consistent."""

from __future__ import annotations

from typing import Any

from langchain_core.messages import AIMessage


def _raw_tool_call_id(raw_tool_call: Any) -> str | None:
    if not isinstance(raw_tool_call, dict):
        return None

    raw_id = raw_tool_call.get("id")
    return raw_id if isinstance(raw_id, str) and raw_id else None


def clone_ai_message_with_tool_calls(
    message: AIMessage,
    tool_calls: list[dict[str, Any]],
    *,
    content: Any | None = None,
) -> AIMessage:
    """Clone an AIMessage while keeping raw provider tool-call metadata in sync.

    清空 tool_calls 的统一入口：同时处理三处--结构化 ``tool_calls`` 字段、
    provider 原始 ``additional_kwargs.tool_calls``、``additional_kwargs.function_call``。
    只在 ``tool_calls`` 清空且原 ``finish_reason == "tool_calls"`` 时才改写成
    ``"stop"``，其他 provider 原值（content_filter / refusal / SAFETY）保留不动。
    """
    kept_ids = {tc["id"] for tc in tool_calls if isinstance(tc.get("id"), str) and tc["id"]}

    update: dict[str, Any] = {"tool_calls": tool_calls}
    if content is not None:
        update["content"] = content

    additional_kwargs = dict(getattr(message, "additional_kwargs", {}) or {})
    raw_tool_calls = additional_kwargs.get("tool_calls")
    if isinstance(raw_tool_calls, list):
        synced_raw_tool_calls = [raw_tc for raw_tc in raw_tool_calls if _raw_tool_call_id(raw_tc) in kept_ids]
        if synced_raw_tool_calls:
            additional_kwargs["tool_calls"] = synced_raw_tool_calls
        else:
            additional_kwargs.pop("tool_calls", None)

    if not tool_calls:
        additional_kwargs.pop("function_call", None)

    update["additional_kwargs"] = additional_kwargs

    response_metadata = dict(getattr(message, "response_metadata", {}) or {})
    if not tool_calls and response_metadata.get("finish_reason") == "tool_calls":
        response_metadata["finish_reason"] = "stop"
    update["response_metadata"] = response_metadata

    return message.model_copy(update=update)
```

---

## 7. 配置（Pydantic 校验）

### 7.1 SafetyFinishReasonConfig

```python
# core/helix/config/safety_finish_reason_config.py
"""Configuration for SafetyFinishReasonMiddleware.

Mirrors the shape of GuardrailsConfig: detectors are loaded by class path
through ``helix.reflection.resolve_variable`` (same loader the
``guardrails.provider`` config uses) so users can drop in custom provider
detectors without modifying core code.
"""

from __future__ import annotations

from pydantic import BaseModel, Field


class SafetyDetectorConfig(BaseModel):
    """One detector entry under ``safety_finish_reason.detectors``."""

    use: str = Field(
        description=("Class path of a SafetyTerminationDetector implementation (e.g. 'helix.agents.middlewares.safety_termination_detectors:OpenAICompatibleContentFilterDetector')."),
    )
    config: dict = Field(
        default_factory=dict,
        description="Constructor kwargs passed to the detector class.",
    )


class SafetyFinishReasonConfig(BaseModel):
    """Configuration for the SafetyFinishReasonMiddleware.

    The middleware intercepts AIMessages where the provider signaled a
    safety-related termination (e.g. OpenAI ``finish_reason='content_filter'``)
    while still returning tool calls, and suppresses those tool calls so the
    half-truncated arguments never execute.
    """

    enabled: bool = Field(
        default=True,
        description="Master switch for the SafetyFinishReasonMiddleware.",
    )
    detectors: list[SafetyDetectorConfig] | None = Field(
        default=None,
        description=(
            "Custom detector list. Leave unset (None) to use the built-in "
            "set covering OpenAI-compatible content_filter, Anthropic "
            "refusal, and Gemini SAFETY/BLOCKLIST/PROHIBITED_CONTENT/SPII/"
            "RECITATION. Provide a non-null list to fully override."
        ),
    )
```

### 7.2 TokenBudgetConfig

```python
# core/helix/config/token_budget_config.py
"""Config for token budget middleware."""

from pydantic import BaseModel, Field, model_validator


class TokenBudgetConfig(BaseModel):
    """Configuration for per-run token budget enforcement."""

    enabled: bool = Field(default=False, description="Whether to enable per-run token budget enforcement.")
    max_tokens: int = Field(default=200000, ge=1000, description="Maximum total tokens (input + output) allowed per run.")
    max_input_tokens: int | None = Field(default=None, ge=1, description="Optional separate limit for input tokens only.")
    max_output_tokens: int | None = Field(default=None, ge=1, description="Optional separate limit for output tokens only.")
    warn_threshold: float = Field(default=0.8, ge=0.0, le=1.0, description="Fraction of max_tokens at which a soft warning is injected. E.g., 0.8 means warn at 80% of max_tokens")
    hard_stop_threshold: float = Field(default=1.0, ge=0.0, le=1.0, description=("Fraction of max_tokens at which tool calls are stripped and the agent is forced to produce a final answer. E.g., 1.0 means stop at 100% of max_tokens."))

    @model_validator(mode="after")
    def validate_thresholds(self) -> "TokenBudgetConfig":
        """Ensure hard stop cannot trigger before the warning."""
        if self.hard_stop_threshold < self.warn_threshold:
            raise ValueError("hard_stop_threshold must be >= warn_threshold")
        return self
```

### 7.3 LoopDetectionConfig

```python
# core/helix/config/loop_detection_config.py
"""Configuration for loop detection middleware."""

from pydantic import BaseModel, Field, model_validator


class ToolFreqOverride(BaseModel):
    """Per-tool frequency threshold override.

    Can be higher or lower than the global defaults. Commonly used to raise
    thresholds for high-frequency tools like bash in batch workflows (e.g.
    RNA-seq pipelines) without weakening protection on every other tool.
    """

    warn: int = Field(ge=1)
    hard_limit: int = Field(ge=1)

    @model_validator(mode="after")
    def _validate(self) -> "ToolFreqOverride":
        if self.hard_limit < self.warn:
            raise ValueError("hard_limit must be >= warn")
        return self


class LoopDetectionConfig(BaseModel):
    """Configuration for repetitive tool-call loop detection."""

    enabled: bool = Field(
        default=True,
        description="Whether to enable repetitive tool-call loop detection",
    )
    warn_threshold: int = Field(
        default=3,
        ge=1,
        description="Number of identical tool-call sets before injecting a warning",
    )
    hard_limit: int = Field(
        default=5,
        ge=1,
        description="Number of identical tool-call sets before forcing a stop",
    )
    window_size: int = Field(
        default=20,
        ge=1,
        description="Number of recent tool-call sets to track per thread",
    )
    max_tracked_threads: int = Field(
        default=100,
        ge=1,
        description="Maximum number of thread histories to keep in memory",
    )
    tool_freq_warn: int = Field(
        default=30,
        ge=1,
        description="Number of calls to the same tool type before injecting a frequency warning",
    )
    tool_freq_hard_limit: int = Field(
        default=50,
        ge=1,
        description="Number of calls to the same tool type before forcing a stop",
    )
    tool_freq_overrides: dict[str, ToolFreqOverride] = Field(
        default_factory=dict,
        description=("Per-tool overrides for tool_freq_warn / tool_freq_hard_limit, keyed by tool name. Values can be higher or lower than the global defaults. Commonly used to raise thresholds for high-frequency tools like bash."),
    )

    @model_validator(mode="after")
    def validate_thresholds(self) -> "LoopDetectionConfig":
        """Ensure hard stop cannot happen before the warning threshold."""
        if self.hard_limit < self.warn_threshold:
            raise ValueError("hard_limit must be greater than or equal to warn_threshold")
        if self.tool_freq_hard_limit < self.tool_freq_warn:
            raise ValueError("tool_freq_hard_limit must be greater than or equal to tool_freq_warn")
        return self
```

---

## 关键不变量（从源码提炼）

1. **SafetyFinishReason 只在有 tool_calls 时干预**：无 tool_calls 的 content_filter 纯文本响应原样放行，让部分文本（若有）自然到达用户。
2. **双清 + 保留 provider finish_reason**：Safety / Loop / Token hard-stop 都经 `clone_ai_message_with_tool_calls`（或同型 `_build_hard_stop_update`）同时清结构化 `tool_calls` + `additional_kwargs.tool_calls` + `function_call`；`finish_reason` 只在原值是 `tool_calls` 时改写成 `stop`，provider 原值（content_filter / refusal / SAFETY）保留不动。
3. **注册顺序：Safety 在 Loop 之后**：逆序 `after_model` 派发使 Safety 最先跑，清空 tool_calls 后 Loop / TokenBudget 在干净消息上计数，不触发误报（见 [[middleware-chain-design]] 第 28 项）。
4. **hard-stop 不抛异常**：Token / Loop 的 hard-stop 剥 `tool_calls` + 强制 `finish_reason="stop"`，让 run 自然完成出最终答案；executor 靠 `consume_stop_reason` 事后得知被截断。
5. **additive stop_reason 不破契约**：`_stop_reason` 是 per-run_id 的 `BoundedDict`，不被 `after_agent` / `_clear_run_state` 清除（让 executor 在 run 返回后能读）；有界防泄漏。值域 `token_capped` / `loop_capped` 是 additive 字段，旧消费者静默忽略（见 [[subagent-delegation]]）。
6. **告警延后注入**：Token / Loop 的 warn 不在 `after_model` 注入（会破坏 `AIMessage(tool_calls) -> ToolMessage` 配对，OpenAI/Moonshot 拒收），而是 queue 到 `wrap_model_call` 在下次模型调用时作为 HumanMessage 追加到末尾。
7. **list-content 兼容**：Safety / Loop / Token 的"追加解释"都走 `_append_text`，list-content（Anthropic thinking blocks）追加 `{"type":"text"}` block，不直接 `str +`，避免 TypeError。
8. **Detector 异常不传染**：`_detect` 对单个 detector 的异常 `try/except` 后继续遍历下一个，绝不让某个 detector 的 bug 阻断所有响应。
9. **不持久化被过滤的 tool arguments**：Safety 审计事件只记 `suppressed_tool_call_names` / `ids` / `count` / `detector`，参数本身是 provider 过滤的内容，重新落盘等于绕开 safety filter。
10. **BoundedDict 防 lead 实例泄漏**：lead agent 的中间件实例跨大量 run 长期存活，per-run_id 状态满额时淘汰最早插入的 key，防泄漏。
