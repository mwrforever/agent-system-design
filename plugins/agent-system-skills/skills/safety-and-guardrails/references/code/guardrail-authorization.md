# Guardrail 授权完整源码

> 本文件是 `safety-and-guardrails` skill 的代码附件，收录工具调用授权链的**完整真实源码**（已按插件匿名化规则映射到自定结构 `helix.*`，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

## 文件清单

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/guardrails/provider.py` | `GuardrailProvider` 协议 + `GuardrailRequest` / `GuardrailReason` / `GuardrailDecision` 数据结构 |
| `core/helix/guardrails/builtin.py` | `AllowlistProvider`：内置 allow/deny list provider（零依赖） |
| `core/helix/guardrails/middleware.py` | `GuardrailMiddleware`：`wrap_tool_call` 拦截，调 provider 授权，fail-closed 返回 error ToolMessage |
| `core/helix/agents/middlewares/tool_error_handling_middleware.py` | `_build_runtime_middlewares` 中反射加载 provider 并装配 `GuardrailMiddleware` 的构造块 |
| `core/helix/config/guardrails_config.py` | `GuardrailsConfig` / `GuardrailProviderConfig`（Pydantic 校验） |

---

## 1. GuardrailProvider 协议与数据结构

```python
# core/helix/guardrails/provider.py
"""GuardrailProvider protocol and data structures for pre-tool-call authorization."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable


@dataclass
class GuardrailRequest:
    """Context passed to the provider for each tool call.

    每次工具调用传给 provider 的上下文。除了 tool_name + tool_input（完整参数），
    还携带身份字段（user_id / user_role / oauth_* / is_subagent / run_id），
    使 provider 能按身份做差异化策略：路径授权（inspect tool_input["path"]）、
    网络访问策略（inspect tool_input["url"]）、角色感知（inspect user_role）。
    内置 AllowlistProvider 只用 tool_name 做 allow/deny； richer 的 OAP / 自定义
    provider 通过反射加载后可读全部字段。
    """

    tool_name: str
    tool_input: dict[str, Any]
    agent_id: str | None = None
    thread_id: str | None = None
    is_subagent: bool = False
    timestamp: str = ""
    user_id: str | None = None
    user_role: str | None = None
    oauth_provider: str | None = None
    oauth_id: str | None = None
    run_id: str | None = None
    tool_call_id: str | None = None


@dataclass
class GuardrailReason:
    """Structured reason for an allow/deny decision (OAP reason object).

    OAP（Open Agent Protocol）reason 对象：code 是机读策略标识
    （如 ``oap.tool_not_allowed``），message 是人读说明。
    """

    code: str
    message: str = ""


@dataclass
class GuardrailDecision:
    """Provider's allow/deny verdict (aligned with OAP Decision object).

    与 OAP Decision 对齐的裁决。reasons 至少一条；policy_id 标识命中的策略；
    metadata 留给 provider 附带任意结构化数据。
    """

    allow: bool
    reasons: list[GuardrailReason] = field(default_factory=list)
    policy_id: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


@runtime_checkable
class GuardrailProvider(Protocol):
    """Contract for pluggable tool-call authorization.

    可插拔工具调用授权的契约。任何具备这两个方法的对象都可注入--无需继承基类。
    provider 通过类路径由 ``resolve_variable`` 加载（与 model / tool / sandbox
    同源机制），所以框架只定义契约 + 内置实现， richer 的 OAP / 业务策略源
    通过 config 反射加入，core 不感知具体策略。
    """

    name: str

    def evaluate(self, request: GuardrailRequest) -> GuardrailDecision:
        """Evaluate whether a tool call should proceed."""
        ...

    async def aevaluate(self, request: GuardrailRequest) -> GuardrailDecision:
        """Async variant."""
        ...
```

---

## 2. 内置 AllowlistProvider（allow/deny list）

```python
# core/helix/guardrails/builtin.py
"""Built-in guardrail providers that ship with Helix."""

from helix.guardrails.provider import GuardrailDecision, GuardrailReason, GuardrailRequest


class AllowlistProvider:
    """Simple allowlist/denylist provider. No external dependencies.

    内置零依赖 provider：仅按 tool_name 做 allow/deny。
    - ``allowed_tools`` 非 None 时走白名单模式（不在白名单即拒）；
    - ``denied_tools`` 走黑名单模式（在黑名单即拒）；
    - 两者可共存：先查白名单，再查黑名单。

    路径授权 / 网络访问策略等 richer 策略由自定义 provider 读
    ``GuardrailRequest.tool_input`` 实现，框架不内置（避免 core 耦合业务策略）。
    """

    name = "allowlist"

    def __init__(self, *, allowed_tools: list[str] | None = None, denied_tools: list[str] | None = None):
        self._allowed = set(allowed_tools) if allowed_tools else None
        self._denied = set(denied_tools) if denied_tools else set()

    def evaluate(self, request: GuardrailRequest) -> GuardrailDecision:
        if self._allowed is not None and request.tool_name not in self._allowed:
            return GuardrailDecision(allow=False, reasons=[GuardrailReason(code="oap.tool_not_allowed", message=f"tool '{request.tool_name}' not in allowlist")])
        if request.tool_name in self._denied:
            return GuardrailDecision(allow=False, reasons=[GuardrailReason(code="oap.tool_not_allowed", message=f"tool '{request.tool_name}' is denied")])
        return GuardrailDecision(allow=True, reasons=[GuardrailReason(code="oap.allowed")])

    async def aevaluate(self, request: GuardrailRequest) -> GuardrailDecision:
        # 默认转发到同步 evaluate--内置 provider 无 I/O。
        # 写自定义 provider 走 HTTP 策略服务时，单独实现 aevaluate 并加 3-5s 超时。
        return self.evaluate(request)
```

---

## 3. GuardrailMiddleware（wrap_tool_call 拦截 + fail-closed）

```python
# core/helix/guardrails/middleware.py
"""GuardrailMiddleware - evaluates tool calls against a GuardrailProvider before execution."""

import logging
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from typing import override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import ToolMessage
from langgraph.errors import GraphBubbleUp
from langgraph.prebuilt.tool_node import ToolCallRequest
from langgraph.types import Command

from helix.guardrails.provider import GuardrailDecision, GuardrailProvider, GuardrailReason, GuardrailRequest

logger = logging.getLogger(__name__)

_REASON_MESSAGE_LIMIT = 500


class GuardrailMiddleware(AgentMiddleware[AgentState]):
    """Evaluate tool calls against a GuardrailProvider before execution.

    Denied calls return an error ToolMessage so the agent can adapt.
    If the provider raises, behavior depends on fail_closed:
      - True (default): block the call
      - False: allow it through with a warning

    核心设计：拒绝不抛异常，而是返回 error ToolMessage 让 run 继续--模型读到
    拒绝原因后可自行换路径，而非整 run 死掉。唯一例外是 ``GraphBubbleUp``
    （LangGraph 的 interrupt / pause / resume 控制流），必须原样上抛。
    """

    def __init__(self, provider: GuardrailProvider, *, fail_closed: bool = True, passport: str | None = None):
        self.provider = provider
        self.fail_closed = fail_closed
        self.passport = passport

    @staticmethod
    def _resolve_context(request: ToolCallRequest) -> dict:
        # 从 runtime.context 抽身份字段（user_id / user_role / oauth_* / run_id / is_subagent）
        runtime = getattr(request, "runtime", None)
        context = getattr(runtime, "context", None) if runtime is not None else None
        return context if isinstance(context, dict) else {}

    def _build_request(self, request: ToolCallRequest, context: dict) -> GuardrailRequest:
        # 把 ToolCallRequest + runtime context 组装成 GuardrailRequest。
        # passport 透传到 agent_id，供 OAP 策略按 agent 维度审计。
        return GuardrailRequest(
            tool_name=str(request.tool_call.get("name", "")),
            tool_input=request.tool_call.get("args", {}),
            agent_id=self.passport,
            thread_id=context.get("thread_id"),
            is_subagent=bool(context.get("is_subagent")),
            timestamp=datetime.now(UTC).isoformat(),
            user_id=context.get("user_id"),
            user_role=context.get("user_role"),
            oauth_provider=context.get("oauth_provider"),
            oauth_id=context.get("oauth_id"),
            run_id=context.get("run_id"),
            tool_call_id=request.tool_call.get("id"),
        )

    def _build_denied_message(self, request: ToolCallRequest, decision: GuardrailDecision) -> ToolMessage:
        # 拒绝时返回 error ToolMessage--把首条 reason 的 code + message 嵌进去，
        # LLM 能据此自我调整路径（而非盲目重试同样的调用）。
        tool_name = str(request.tool_call.get("name", "unknown_tool"))
        tool_call_id = str(request.tool_call.get("id", "missing_id"))
        reason_text = decision.reasons[0].message if decision.reasons else "blocked by guardrail policy"
        reason_code = decision.reasons[0].code if decision.reasons else "oap.denied"
        return ToolMessage(
            content=f"Guardrail denied: tool '{tool_name}' was blocked ({reason_code}). Reason: {reason_text}. Choose an alternative approach.",
            tool_call_id=tool_call_id,
            name=tool_name,
            status="error",
        )

    def _record_guardrail_event(
        self,
        context: dict,
        guardrail_request: GuardrailRequest,
        decision: GuardrailDecision,
        *,
        action: str,
        provider_error: bool,
    ) -> None:
        """Persist a security-relevant guardrail decision to RunJournal.

        把安全相关的 guardrail 决策持久化到 RunJournal。遵循可选 Journal 模式：
        审计持久化是 best-effort，绝不改变工具执行行为。无 ``__run_journal`` 的
        运行时（嵌入式 / 子代理）跳过持久化。
        """
        journal = context.get("__run_journal")
        if journal is None:
            return

        reason_codes = [reason.code for reason in decision.reasons if reason.code]
        reason_messages = [reason.message[:_REASON_MESSAGE_LIMIT] for reason in decision.reasons if reason.message]

        changes = {
            "tool_name": guardrail_request.tool_name,
            "tool_call_id": guardrail_request.tool_call_id,
            "agent_id": guardrail_request.agent_id,
            # Native subagents do not currently inherit __run_journal; custom
            # runtimes may still provide one with subagent attribution.
            "is_subagent": guardrail_request.is_subagent,
            "user_role": guardrail_request.user_role,
            "allow": decision.allow,
            "policy_id": decision.policy_id,
            "reason_codes": reason_codes,
            "reason_messages": reason_messages,
            "fail_closed": self.fail_closed,
            "provider_error": provider_error,
        }

        try:
            journal.record_middleware(
                tag="guardrail",
                name=type(self).__name__,
                hook="wrap_tool_call",
                action=action,
                changes=changes,
            )
        except Exception:  # noqa: BLE001
            logger.debug("Failed to record middleware:guardrail event", exc_info=True)

    @override
    def wrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], ToolMessage | Command],
    ) -> ToolMessage | Command:
        # 同步路径：调 provider.evaluate -> decision -> allow 透传 / deny 返回 error ToolMessage。
        context = self._resolve_context(request)
        gr = self._build_request(request, context)
        try:
            decision = self.provider.evaluate(gr)
        except GraphBubbleUp:
            # 保留 LangGraph 控制流信号（interrupt / pause / resume）。
            raise
        except Exception:
            # provider 异常：fail_closed=true -> 拒绝；fail_closed=false -> 放行 + warn。
            # 绝不把异常上抛终止整 run。
            logger.exception("Guardrail provider error (sync)")
            if self.fail_closed:
                decision = GuardrailDecision(allow=False, reasons=[GuardrailReason(code="oap.evaluator_error", message="guardrail provider error (fail-closed)")])
                self._record_guardrail_event(
                    context,
                    gr,
                    decision,
                    action="deny_tool_call",
                    provider_error=True,
                )
                return self._build_denied_message(request, decision)
            else:
                decision = GuardrailDecision(allow=True, reasons=[GuardrailReason(code="oap.evaluator_error", message="guardrail provider error (fail-open)")])
                self._record_guardrail_event(
                    context,
                    gr,
                    decision,
                    action="allow_tool_call_after_provider_error",
                    provider_error=True,
                )
                return handler(request)
        if not decision.allow:
            logger.warning("Guardrail denied: tool=%s policy=%s code=%s", gr.tool_name, decision.policy_id, decision.reasons[0].code if decision.reasons else "unknown")
            self._record_guardrail_event(
                context,
                gr,
                decision,
                action="deny_tool_call",
                provider_error=False,
            )
            return self._build_denied_message(request, decision)
        return handler(request)

    @override
    async def awrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], Awaitable[ToolMessage | Command]],
    ) -> ToolMessage | Command:
        # 异步路径：调 provider.aevaluate，拦截语义与同步完全一致。
        context = self._resolve_context(request)
        gr = self._build_request(request, context)
        try:
            decision = await self.provider.aevaluate(gr)
        except GraphBubbleUp:
            # 保留 LangGraph 控制流信号（interrupt / pause / resume）。
            raise
        except Exception:
            logger.exception("Guardrail provider error (async)")
            if self.fail_closed:
                decision = GuardrailDecision(allow=False, reasons=[GuardrailReason(code="oap.evaluator_error", message="guardrail provider error (fail-closed)")])
                self._record_guardrail_event(
                    context,
                    gr,
                    decision,
                    action="deny_tool_call",
                    provider_error=True,
                )
                return self._build_denied_message(request, decision)
            else:
                decision = GuardrailDecision(allow=True, reasons=[GuardrailReason(code="oap.evaluator_error", message="guardrail provider error (fail-open)")])
                self._record_guardrail_event(
                    context,
                    gr,
                    decision,
                    action="allow_tool_call_after_provider_error",
                    provider_error=True,
                )
                return await handler(request)
        if not decision.allow:
            logger.warning("Guardrail denied: tool=%s policy=%s code=%s", gr.tool_name, decision.policy_id, decision.reasons[0].code if decision.reasons else "unknown")
            self._record_guardrail_event(
                context,
                gr,
                decision,
                action="deny_tool_call",
                provider_error=False,
            )
            return self._build_denied_message(request, decision)
        return await handler(request)
```

---

## 4. 构造块：反射加载 provider 并装配 GuardrailMiddleware

以下片段来自共享基座构造函数 `_build_runtime_middlewares`（见 [[middleware-chain-design]] 的 `build-middlewares.md`）。当 `guardrails.enabled` 且配置了 provider 时，反射加载 provider 类、按需注入 `framework` hint、构造 `GuardrailMiddleware` 追加到 tail。这一层是**配置驱动**的--core 只定义契约，具体 provider 由 config 决定。

```python
# core/helix/agents/middlewares/tool_error_handling_middleware.py - _build_runtime_middlewares 内 Guardrail 构造块
    # Guardrail middleware (if configured)
    guardrails_config = app_config.guardrails
    if guardrails_config.enabled and guardrails_config.provider:
        import inspect

        from helix.guardrails.middleware import GuardrailMiddleware
        from helix.reflection import resolve_variable

        # 反射加载 provider 类（与 model / tool / sandbox 同源机制）
        provider_cls = resolve_variable(guardrails_config.provider.use)
        provider_kwargs = dict(guardrails_config.provider.config) if guardrails_config.provider.config else {}
        # Pass framework hint if the provider accepts it (e.g. for config discovery).
        # Built-in providers like AllowlistProvider don't need it, so only inject
        # when the constructor accepts 'framework' or '**kwargs'.
        if "framework" not in provider_kwargs:
            try:
                sig = inspect.signature(provider_cls.__init__)
                if "framework" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                    provider_kwargs["framework"] = "helix"
            except (ValueError, TypeError):
                pass
        provider = provider_cls(**provider_kwargs)
        tail.append(GuardrailMiddleware(provider, fail_closed=guardrails_config.fail_closed, passport=guardrails_config.passport))
```

> `tail` 是 `_build_runtime_middlewares` 的第三层（后处理 append-only 中间件），`GuardrailMiddleware` 在这里追加，随后是 `SandboxAuditMiddleware` 等。`wrap_tool_call` 是洋葱模型，链表顺序即外->内包裹顺序（见 [[middleware-chain-design]] 链顺序清单第 8 项）。

---

## 5. 配置（Pydantic 校验）

```python
# core/helix/config/guardrails_config.py
"""Configuration for pre-tool-call authorization."""

from pydantic import BaseModel, Field


class GuardrailProviderConfig(BaseModel):
    """Configuration for a guardrail provider."""

    use: str = Field(description="Class path (e.g. 'helix.guardrails.builtin:AllowlistProvider')")
    config: dict = Field(default_factory=dict, description="Provider-specific settings passed as kwargs")


class GuardrailsConfig(BaseModel):
    """Configuration for pre-tool-call authorization.

    When enabled, every tool call passes through the configured provider
    before execution. The provider receives tool name, arguments, and the
    agent's passport reference, and returns an allow/deny decision.

    ``fail_closed`` 决定 provider 异常时的行为：true（默认）拒绝，false 放行 + warn。
    ``passport`` 透传到 ``GuardrailRequest.agent_id``，供 OAP 策略按 agent 维度审计。
    ``provider`` 是反射加载入口--类路径指向任何实现了 evaluate/aevaluate 的对象。
    """

    enabled: bool = Field(default=False, description="Enable guardrail middleware")
    fail_closed: bool = Field(default=True, description="Block tool calls if provider errors")
    passport: str | None = Field(default=None, description="OAP passport path or hosted agent ID")
    provider: GuardrailProviderConfig | None = Field(default=None, description="Guardrail provider configuration")


_guardrails_config: GuardrailsConfig | None = None


def get_guardrails_config() -> GuardrailsConfig:
    """Get the guardrails config, returning defaults if not loaded."""
    global _guardrails_config
    if _guardrails_config is None:
        _guardrails_config = GuardrailsConfig()
    return _guardrails_config


def load_guardrails_config_from_dict(data: dict) -> GuardrailsConfig:
    """Load guardrails config from a dict (called during AppConfig loading)."""
    global _guardrails_config
    _guardrails_config = GuardrailsConfig.model_validate(data)
    return _guardrails_config


def reset_guardrails_config() -> None:
    """Reset the cached config instance. Used in tests to prevent singleton leaks."""
    global _guardrails_config
    _guardrails_config = None
```

### 配置示例

```yaml
# config.yaml
guardrails:
  enabled: true
  fail_closed: true               # provider 异常时拒绝（默认）
  passport: "lead-agent-v1"       # 透传到 GuardrailRequest.agent_id
  provider:
    use: helix.guardrails.builtin:AllowlistProvider   # 反射加载类路径
    config:
      allowed_tools: [read_file, ls, web_search, str_replace]   # 白名单
      denied_tools: [bash]                                       # 黑名单
```

> 更 richer 的策略（路径授权、网络访问策略、角色感知）通过把 `use` 指向自定义 provider 类实现：该 provider 读 `GuardrailRequest.tool_input`（完整参数）+ 身份字段，返回 `GuardrailDecision`。框架 core 不内置这些策略，避免耦合业务规则。
