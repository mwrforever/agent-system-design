# 完整源码：动态注入 + SystemMessage 合并中间件

> 本文件给出两个中间件的**完整实现**（含所有辅助函数与边界处理）。SKILL.md 仅给出伪代码与架构思路，完整源码以此处为准。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`），去除一切项目字样。原代码注释保留以保真。

## 1. 动态注入中间件（完整）

```python
# core/helix/agents/middlewares/dynamic_context_middleware.py
"""把动态上下文（记忆、当前日期）作为 <system-reminder> 注入。

system prompt 保持纯静态以最大化跨用户/会话的 prefix-cache 复用。当前日期总是注入；
当 app config 的 memory.injection_enabled 为 True 时也注入 per-user 记忆。两者每会话
仅注入一次，作为一条独立 <system-reminder> SystemMessage 插在第一条用户消息之前（冻结快照模式）。

会话跨午夜时，中间件检测到日期变化，在当前 turn 前插入一条轻量日期校正 reminder。
该校正会被持久化，使新一天的后续 turn 看到一致历史、不再重复注入。
"""

from __future__ import annotations

import asyncio
import logging
import re
import uuid
from datetime import datetime
from typing import TYPE_CHECKING, override

from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.runtime import Runtime

if TYPE_CHECKING:
    from helix.config.app_config import AppConfig

logger = logging.getLogger(__name__)

# 单次 _inject() offload 的时间上限（秒）。若 gateway 启动期预热静默失败，首请求
# 仍可能命中冷 tiktoken BPE 下载并阻塞到 OS TCP 超时（~26 分钟）。此上限保证请求优雅降级。
_INJECT_TIMEOUT_SECONDS = 5.0

_DATE_RE = re.compile(r"<current_date>([^<]+)</current_date>")
_DYNAMIC_CONTEXT_REMINDER_KEY = "dynamic_context_reminder"
# 权威注入日期，记在日期 SystemMessage 的 additional_kwargs。检测读它而非 regex 解析内容，
# 使其永不受用户可影响的记忆内容影响。
_REMINDER_DATE_KEY = "reminder_date"
_SUMMARY_MESSAGE_NAME = "summary"


def _extract_date(content: str) -> str | None:
    """返回 content 中首个 <current_date> 值，无则 None。"""
    m = _DATE_RE.search(content)
    return m.group(1) if m else None


def is_dynamic_context_reminder(message: object) -> bool:
    """判断 message 是否为隐藏的动态上下文 reminder。"""
    # 弃用：HumanMessage reminder 仅存在于旧 PR 的 checkpoint。迁移完成后可移除 HumanMessage 分支。
    return isinstance(message, (HumanMessage, SystemMessage)) and bool(
        message.additional_kwargs.get(_DYNAMIC_CONTEXT_REMINDER_KEY))


def _last_injected_date(messages: list) -> str | None:
    """逆序扫描消息，返回最近注入的日期。

    检测用 additional_kwargs 的 dynamic_context_reminder 标志而非内容子串匹配，
    所以含 <system-reminder> 的用户消息不会被误判为已注入 reminder。

    权威日期是日期 SystemMessage additional_kwargs 的 reminder_date 值。无该值的
    reminder（独立的 <memory> HumanMessage，或任何未来无日期 reminder）不带日期、被跳过，
    不能遮蔽真实日期 reminder。
    """
    for msg in reversed(messages):
        if not is_dynamic_context_reminder(msg):
            continue
        structured = msg.additional_kwargs.get(_REMINDER_DATE_KEY)
        if isinstance(structured, str) and structured:
            return structured
        # 向后兼容：reminder_date 出现前写入的 checkpoint，日期存在 content 里。
        # 把 regex 限定到 SystemMessage，使其永不在用户可影响的记忆 HumanMessage 上运行
        # （保留 #3630 的 OWASP 角色分离，关闭记忆日期伪造漏洞）。
        if isinstance(msg, SystemMessage):
            content_str = msg.content if isinstance(msg.content, str) else str(msg.content)
            date = _extract_date(content_str)
            if date is not None:
                return date
    return None


def _is_user_injection_target(message: object) -> bool:
    """判断 message 是否可接收动态上下文 reminder。"""
    if not isinstance(message, HumanMessage):
        return False
    if is_dynamic_context_reminder(message):
        return False
    if message.name == _SUMMARY_MESSAGE_NAME:
        return False
    # 防递归 ID-swap：id 以 "__user" 结尾的消息是之前 _make_reminder_and_user_messages 产物，
    # 不可再处理 —— 否则导致无限后缀增长（id__user__user__user...）与幽灵消息重放。
    # 用 endswith（非子串 "in"）避免误命中中间恰好含 "__user" 的 id。
    if message.id and str(message.id).endswith("__user"):
        return False
    return True


class DynamicContextMiddleware(AgentMiddleware):
    """注入记忆与当前日期为 <system-reminder> SystemMessage。

    首轮
    ----
    在第一条 HumanMessage 前插入完整 reminder（记忆+日期）并持久化（同一 message id）。
    该首消息随后对整个会话冻结——其内容永不再变，故 prefix cache 在每个后续 turn 命中。

    跨午夜
    ------
    会话跨午夜时，当前日期与此前注入日期不同。此时在当前（最后一条）HumanMessage 前
    插入轻量日期校正 reminder 并持久化。新一天的后续 turn 在历史中看到校正日期、跳过重复注入。
    """

    def __init__(self, agent_name: str | None = None, *, app_config: "AppConfig | None" = None):
        super().__init__()
        self._agent_name = agent_name
        self._app_config = app_config

    def _build_full_reminder(self) -> tuple[str, str | None]:
        """返回 (date_reminder, memory_block | None)。

        框架权威数据(日期)与用户可影响数据(记忆)分离：下游 SystemMessage 只承载框架权威，
        记忆停留在 role:user —— 防止不可信内容获得 system 权限 (OWASP LLM01)。
        """
        from helix.agents.lead.prompt import _get_memory_context

        injection_enabled = self._app_config.memory.injection_enabled if self._app_config else True
        memory_context = _get_memory_context(self._agent_name, app_config=self._app_config) if injection_enabled else ""
        current_date = datetime.now().strftime("%Y-%m-%d, %A")

        date_reminder = "\n".join([
            "<system-reminder>",
            f"<current_date>{current_date}</current_date>",
            "</system-reminder>",
        ])
        memory_block = memory_context.strip() if memory_context else None
        return date_reminder, memory_block

    def _build_date_update_reminder(self) -> str:
        current_date = datetime.now().strftime("%Y-%m-%d, %A")
        return "\n".join([
            "<system-reminder>",
            f"<current_date>{current_date}</current_date>",
            "</system-reminder>",
        ])

    @staticmethod
    def _make_reminder_and_user_messages(
        original: HumanMessage, reminder_content: str, memory_content: str | None = None, *,
        reminder_date: str | None = None,
    ) -> list[SystemMessage | HumanMessage]:
        """ID-swap 技术返回消息。

        SystemMessage 承载框架权威数据(日期/元数据)——取原 id，使 add_messages 原地替换。
        reminder_date 记入其 additional_kwargs 作为权威注入日期（_last_injected_date 读它而非解析内容）。
        可选 HumanMessage 承载用户权威记忆内容，id 为 {id}__memory。真正用户消息 id 为 {id}__user。

        用 SystemMessage —— system 上下文不得伪装成用户输入 (#3630)。记忆刻意保持为 HumanMessage，
        使用户可影响内容不获得 system 权威 (OWASP LLM01) —— 且刻意永不带 reminder_date。
        """
        stable_id = original.id or str(uuid.uuid4())
        messages: list[SystemMessage | HumanMessage] = []

        reminder_kwargs = {"hide_from_ui": True, _DYNAMIC_CONTEXT_REMINDER_KEY: True}
        if reminder_date is not None:
            reminder_kwargs[_REMINDER_DATE_KEY] = reminder_date
        messages.append(SystemMessage(
            content=reminder_content, id=stable_id, additional_kwargs=reminder_kwargs))

        if memory_content:
            messages.append(HumanMessage(
                content=memory_content, id=f"{stable_id}__memory",
                additional_kwargs={"hide_from_ui": True, _DYNAMIC_CONTEXT_REMINDER_KEY: True}))

        messages.append(HumanMessage(
            content=original.content, id=f"{stable_id}__user",
            name=original.name, additional_kwargs=original.additional_kwargs))
        return messages

    def _inject(self, state) -> dict | None:
        messages = list(state.get("messages", []))
        if not messages:
            return None

        current_date = datetime.now().strftime("%Y-%m-%d, %A")
        last_date = _last_injected_date(messages)
        logger.debug("DynamicContextMiddleware._inject: msg_count=%d last_date=%r current_date=%r",
                     len(messages), last_date, current_date)

        if last_date is None:
            # 首轮：注入完整 reminder
            first_idx = next((i for i, m in enumerate(messages) if _is_user_injection_target(m)), None)
            if first_idx is None:
                return None
            date_reminder, memory_block = self._build_full_reminder()
            logger.info("DynamicContextMiddleware: injecting full reminder (has_memory=%s) into first HumanMessage id=%r",
                        memory_block is not None, messages[first_idx].id)
            result_msgs = self._make_reminder_and_user_messages(
                messages[first_idx], date_reminder, memory_block, reminder_date=current_date)
            return {"messages": result_msgs}

        if last_date == current_date:
            return None  # 同日：无需动作

        # 跨午夜：注入日期校正
        last_human_idx = next((i for i in reversed(range(len(messages))) if _is_user_injection_target(messages[i])), None)
        if last_human_idx is None:
            return None
        result_msgs = self._make_reminder_and_user_messages(
            messages[last_human_idx], self._build_date_update_reminder(), reminder_date=current_date)
        logger.info("DynamicContextMiddleware: midnight crossing detected — injected date update before current turn")
        return {"messages": result_msgs}

    @override
    def before_agent(self, state, runtime: Runtime) -> dict | None:
        return self._inject(state)

    @override
    async def abefore_agent(self, state, runtime: Runtime) -> dict | None:
        # _inject 含同步文件 IO（记忆 JSON 加载）与潜在阻塞网络（tiktoken 首次下载）。
        # 必须卸载到线程，否则阻塞事件循环、饿死所有并发 HTTP handler（鉴权、SSE 心跳等）。
        # 有界 timeout：若启动预热静默失败（如部署期网络抖动），首请求冷 tiktoken 下载可阻塞数十分钟。
        try:
            return await asyncio.wait_for(
                asyncio.to_thread(self._inject, state),
                timeout=_INJECT_TIMEOUT_SECONDS,
            )
        except TimeoutError:
            logger.warning("DynamicContextMiddleware: injection timed out (%.1fs); skipping memory/date injection for this turn",
                           _INJECT_TIMEOUT_SECONDS)
            return None
```

## 2. SystemMessage 合并中间件（完整）

```python
# core/helix/agents/middlewares/system_message_coalescing_middleware.py
"""把多条 SystemMessage 合并为单一首条。

严格 OpenAI 兼容后端（vLLM、SGLang、Qwen）与 Anthropic 拒绝非首条 SystemMessage，
报错如 "System message must be at the beginning" 或 "Received multiple non-consecutive system messages"。
官方 OpenAI API 容忍会话中段的 system message，故该问题仅在严格后端上出现。

lead agent 会累积多条 SystemMessage，因为 DynamicContextMiddleware 用 ID-swap 技术把
首/末 HumanMessage 替换为一个三元组，其首元素是 SystemMessage reminder（框架权威日期/元数据
不得伪装成用户输入，见 OWASP LLM01）。跨午夜时再注入第二条 SystemMessage（日期校正）。
create_agent 把静态 system_prompt 存在独立 request.system_message 字段，仅在 model-call
handler 内展平进消息列表（[request.system_message, *messages]）。

本中间件在 wrap_model_call 运行——早于 handler 展平二者——把 request.system_message 与
request.messages 中所有 SystemMessage 合并为一条通过 system_message 字段发出的首条 SystemMessage。
它只触碰请求载荷；持久化会话状态（checkpoint）不变，所以按标记扫描历史的中间件
（如 is_dynamic_context_reminder）继续工作。

注：镜像 Claude 在 claude_provider._coalesce_system_messages 已做的每请求合并，但提升到
provider 无关层，使每个后端从单一修复受益，而非逐 provider 打补丁。
"""

from collections.abc import Awaitable, Callable
from typing import override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelCallResult, ModelRequest, ModelResponse
from langchain_core.messages import SystemMessage

from helix.agents.middlewares.dynamic_context_middleware import is_dynamic_context_reminder


def _flatten_content(content) -> str:
    """把消息内容转为纯字符串，兼容 str 与 list 类型。

    langchain 消息支持 list 类型内容用于多模态（如 [{"type":"text","text":"..."}]）。
    SystemMessage 在本系统里始终是纯字符串，但此 helper 保证任意内容形状的健壮性。
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and "text" in item:
                parts.append(item["text"])
            else:
                parts.append(str(item))
        return "\n".join(parts)
    return str(content)


def _coalesce_request(request: ModelRequest) -> ModelRequest | None:
    """合并 request.system_message 与 messages 内的 SystemMessage 为一条。

    langchain >= 1.2.15 上静态 system prompt 在独立 request.system_message 字段，不在
    request.messages。model-call handler 在最后一刻展平（[system_message, *messages]），
    所以只扫描 messages 的中间件看不到 prompt、沦为 no-op。本 helper 同时检查两处，把每条
    SystemMessage 合并为单一条目，结果经 system_message 发出，使 handler 仍正确前置。

    messages 内无 SystemMessage 时返回 None——此时 system_message（若有）已是唯一首条 system 块，
    请求可零改动透传，保 prefix cache 命中。
    """
    in_msg_systems = [m for m in request.messages if isinstance(m, SystemMessage)]
    if not in_msg_systems:
        return None

    parts: list[SystemMessage] = []
    if request.system_message is not None:
        parts.append(request.system_message)
    parts.extend(in_msg_systems)

    # 去重 dynamic_context_reminder SystemMessage：只保留最后一条（最新日期），丢弃更早的 reminder。
    # 跨午夜时合并内容否则会含两个相邻、矛盾的 <current_date> 块且无时间锚——原本分隔它们的中间
    # turn 在合并后已消失。模型应只看到最新日期，而非必须猜测忽略的过期日期。
    reminder_indices = [i for i, p in enumerate(parts) if is_dynamic_context_reminder(p)]
    if len(reminder_indices) > 1:
        keep_last = reminder_indices[-1]
        parts = [p for i, p in enumerate(parts) if i not in reminder_indices[:-1] or i == keep_last]

    # 保留首条 SystemMessage 的 id（通常是静态 system_prompt），使按首条 system 消息 id keying 的
    # 下游消费者不受影响。合并所有 additional_kwargs，使 reminder 的 hide_from_ui /
    # dynamic_context_reminder 标记保留在合并块上。
    first = parts[0]
    merged_kwargs: dict = {}
    for p in parts:
        merged_kwargs.update(p.additional_kwargs or {})
    merged = SystemMessage(
        content="\n\n".join(_flatten_content(p.content) for p in parts),
        id=first.id,
        additional_kwargs=merged_kwargs,
    )

    non_system = [m for m in request.messages if not isinstance(m, SystemMessage)]
    return request.override(system_message=merged, messages=non_system)


class SystemMessageCoalescingMiddleware(AgentMiddleware[AgentState]):
    """把所有 SystemMessage 合并为单一首条 SystemMessage。

    用 wrap_model_call（非 before_agent），使合并在最终请求载荷上运行——此时 system_message
    与 messages 仍是分开字段——且永不触碰持久化 state["messages"]。这使 checkpoint 结构对每个
    扫描历史的消费者（记忆构造、journal、摘要、动态上下文检测）保持完整。
    """

    @staticmethod
    def _maybe_coalesce(request: ModelRequest) -> ModelRequest:
        coalesced = _coalesce_request(request)
        if coalesced is None:
            return request
        return coalesced

    @override
    def wrap_model_call(
        self, request: ModelRequest, handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelCallResult:
        return handler(self._maybe_coalesce(request))

    @override
    async def awrap_model_call(
        self, request: ModelRequest, handler: Callable[[ModelRequest], Awaitable[ModelResponse]],
    ) -> ModelCallResult:
        return await handler(self._maybe_coalesce(request))
```

## 关键不变量与测试锚点

1. **首轮冻结**：首轮注入后，第二轮同日 `_inject` 返回 `None`（不重复注入），保证 prefix cache 持续命中。
2. **角色分离**：日期必在 `SystemMessage`，记忆必在 `HumanMessage`；记忆 HumanMessage **永不**带 `reminder_date`。
3. **权威检测**：`_last_injected_date` 读 `additional_kwargs.reminder_date`，不 regex 解析内容；regex 仅作旧 checkpoint 向后兼容且限定到 `SystemMessage`。
4. **防递归 swap**：`_is_user_injection_target` 排除 `__user` 后缀消息，杜绝 id 无限增长与幽灵消息重放。
5. **合并只动载荷**：`_coalesce_request` 通过 `request.override(...)` 产出新请求，`state["messages"]` 不变。
6. **跨午夜去重**：合并后多条 reminder 只保留最新日期那条。
7. **阻塞 IO 卸载**：`abefore_agent` 用 `asyncio.to_thread` + `_INJECT_TIMEOUT_SECONDS` 有界超时，超时优雅降级返回 `None`。

> 关联：[[middleware-chain-design]]（本两件在链上的位置：DynamicContext 早段注入、Coalescing 在模型调用前合并）、[[system-prompt-template]]（SKILL.md）、[[context-window-management]]（prefix-cache 与摘要）。
