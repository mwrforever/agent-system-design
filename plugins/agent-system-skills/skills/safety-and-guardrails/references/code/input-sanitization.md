# 输入消毒中间件完整源码

> 本文件是 `safety-and-guardrails` skill 的代码附件，收录 `InputSanitizationMiddleware` 的**完整真实源码**（已按插件匿名化规则映射到自定结构 `helix.*`，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

## 文件清单

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/agents/middlewares/input_sanitization_middleware.py` | `InputSanitizationMiddleware`：`wrap_model_call` 最外层消毒，转义伪造的结构标签 + 包裹边界标记 |

> 依赖（中性名，保持不变）：`helix.utils.messages` 的 `ORIGINAL_USER_CONTENT_KEY` / `message_content_to_text`；`helix.agents.human_input` 的 `read_human_input_response`。

---

## InputSanitizationMiddleware 全文

```python
# core/helix/agents/middlewares/input_sanitization_middleware.py
"""Input guardrail middleware for prompt-injection defense (issue #3630).

Escapes blocked XML-like tags in the last genuine user message (e.g.
``<system>`` -> ``&lt;system&gt;``) so they render as literal text instead
of structured-context markers.  This preserves the user's intent ("how do
I use Helix's <think> tag?") while neutralizing injection attempts -
the same de-identify-don't-reject strategy as AWS Bedrock's PII ANONYMIZE.

Blocked: system-reserved tags (memory, analysis, etc.) + common injection
tags (system, instruction, role, etc.). Normal HTML/XML tags (<div>,
<span>) are NOT escaped.

Clean input is wrapped in plain-text boundary markers as a secondary
semantic defense (OWASP structured-prompt guidance).

设计要点：
1. 转义而非拒绝（de-identify-don't-reject）--保留用户意图，标签失去语义。
2. 只清"声称是系统标签"的注入，不动用户合法 HTML/XML（<div> 等不转义）。
3. 边界标记（BEGIN/END USER INPUT）作为次级语义防御（OWASP structured-prompt）。
4. 变换是临时的（wrap_model_call），永不写回 state--下游消费者经
   ``ORIGINAL_USER_CONTENT_KEY`` 读原始文本。
"""

from __future__ import annotations

import logging
import re
from collections.abc import Awaitable, Callable
from typing import override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import (
    ModelCallResult,
    ModelRequest,
    ModelResponse,
)
from langchain_core.messages import HumanMessage
from langgraph.errors import GraphBubbleUp

from helix.agents.human_input import read_human_input_response
from helix.utils.messages import ORIGINAL_USER_CONTENT_KEY, message_content_to_text

logger = logging.getLogger(__name__)

_SUMMARY_MESSAGE_NAME = "summary"

# Finite set of blocked tag names: system-reserved + common injection patterns.
# 有限封锁集：框架系统标签 + 常见注入伪标签。普通 HTML/XML 标签（<div> 等）不在内。
_BLOCKED_TAG_NAMES: frozenset[str] = frozenset(
    {
        # System-reserved tags (used by the agent framework for structured context)
        "system-reminder",
        "memory",
        "current_date",
        "think",
        "analysis",
        "subagent_system",
        "skill_system",
        "uploaded_files",
        "todo_list_system",
        # Common prompt-injection tag patterns
        "system",
        "instruction",
        "role",
        "important",
        "override",
        "ignore",
        "prompt",
    }
)

# Matches a full blocked tag: <tag>, </tag>, <tag attrs>, <tag/>, bare <tag
_BLOCKED_TAG_PATTERN = re.compile(
    r"<\s*/?\s*(?:" + "|".join(re.escape(t) for t in sorted(_BLOCKED_TAG_NAMES)) + r")\b[^>]*>?",
    re.IGNORECASE,
)

# Plain-text boundary markers (OWASP structured-prompt guidance).
_USER_INPUT_BEGIN = "--- BEGIN USER INPUT ---"
_USER_INPUT_END = "--- END USER INPUT ---"

# Neutralized forms injected when the user's text already contains a marker.
# These look visually similar but do not match the real boundary delimiters.
_NEUTRALIZED_BEGIN = "[BEGIN USER INPUT]"
_NEUTRALIZED_END = "[END USER INPUT]"

# Matches either boundary token as a standalone line or embedded in text.
_BOUNDARY_TOKEN_RE = re.compile(
    re.escape(_USER_INPUT_BEGIN) + r"|" + re.escape(_USER_INPUT_END),
)


def _escape_tag_match(match: re.Match) -> str:
    """Escape < and > in a blocked-tag match so it renders as literal text."""
    return match.group(0).replace("<", "&lt;").replace(">", "&gt;")


def _is_genuine_user_message(message: object) -> bool:
    """Return True for real user messages, excluding system-injected HumanMessages.

    ``hide_from_ui`` is also used by hidden UI replies from HumanInputCard, so
    only skip hidden HumanMessages that do not carry a valid user response.

    只对"真用户消息"消毒，跳过框架注入的 HumanMessage（summary、HumanInputCard
    隐藏回复等）--否则会破坏动态上下文注入与澄清回复的语义。
    """
    if not isinstance(message, HumanMessage):
        return False
    if message.name == _SUMMARY_MESSAGE_NAME:
        return False
    if message.additional_kwargs.get("hide_from_ui") and read_human_input_response(message.additional_kwargs) is None:
        return False
    return True


def _check_user_content(text: str) -> str:
    """Sanitize user content: escape blocked tags, then wrap in boundary markers.

    * Empty/whitespace-only -> return unchanged (no marker noise).
    * Blocked tags -> HTML-escape ``<``/``>`` (e.g. ``<system>`` -> ``&lt;system&gt;``).
    * Boundary tokens in user text -> neutralized so they cannot forge boundaries.
    * Already wrapped (strict prefix+suffix) -> return text unchanged (idempotent).
    * Otherwise -> wrap in boundary markers.

    幂等性：已严格包裹（prefix+suffix）的文本原样返回；但内部仍要 neutralize
    边界标记，防 break-out 攻击（用户伪造外层包裹绕过 neutralization 再注入
    内层边界标记）。
    """
    if not text.strip():
        return text
    text = _BLOCKED_TAG_PATTERN.sub(_escape_tag_match, text)
    # Idempotency: only skip if text is *exactly* wrapped (prefix+suffix),
    # not if the user merely typed the begin token somewhere.
    if text.startswith(_USER_INPUT_BEGIN) and text.endswith(_USER_INPUT_END):
        # Still neutralize boundary tokens in the inner content - a user
        # can forge the outer wrapping to bypass the neutralization below
        # and inject inner boundary markers (break-out attack).
        inner = text[len(_USER_INPUT_BEGIN) : -len(_USER_INPUT_END)]
        neutralized_inner = _BOUNDARY_TOKEN_RE.sub(
            lambda m: _NEUTRALIZED_BEGIN if m.group(0) == _USER_INPUT_BEGIN else _NEUTRALIZED_END,
            inner,
        )
        if neutralized_inner == inner:
            return text
        return f"{_USER_INPUT_BEGIN}{neutralized_inner}{_USER_INPUT_END}"
    # Neutralize any boundary tokens the user may have embedded, preventing
    # both self-suppression (begin token skips wrapping) and break-out
    # (end token creates a premature boundary inside the payload).
    text = _BOUNDARY_TOKEN_RE.sub(
        lambda m: _NEUTRALIZED_BEGIN if m.group(0) == _USER_INPUT_BEGIN else _NEUTRALIZED_END,
        text,
    )
    return f"{_USER_INPUT_BEGIN}\n{text}\n{_USER_INPUT_END}"


class InputSanitizationMiddleware(AgentMiddleware[AgentState]):
    """Guardrail middleware that escapes prompt-injection tags in user input.

    Blocked tags are HTML-escaped (not rejected) so the user's intent is
    preserved while the tags lose their semantic significance. Clean input
    is wrapped in plain-text boundary markers. Transformation is temporary
    (wrap_model_call) - never written to state.

    只处理"最后一条真用户消息"--历史消息在首轮已消毒（或无需再消毒），
    每轮只对新输入做变换，避免重复包裹破坏幂等性。
    """

    @staticmethod
    def _extract_text_from_content(content: str | list) -> tuple[str, list | None]:
        """Extract concatenated text from a plain-string or content-block-list.

        Returns ``(text, extracted_blocks)``. *extracted_blocks* is None when
        *content* is a string, or the list of text-content-block dicts when a list.

        多模态消息（含图像 block）的文本抽取：把多个 text block 拼成一段，
        记下原 block 引用以便回写时保留非文本 block。
        """
        if isinstance(content, str):
            return content, None
        if not isinstance(content, list):
            return "", None
        text_parts: list[str] = []
        text_blocks: list[dict] = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                text_parts.append(block["text"])
                text_blocks.append(block)
        return "\n".join(text_parts), text_blocks

    @staticmethod
    def _rebuild_content(
        original_content: list,
        processed_text: str,
        text_blocks: list[dict],
    ) -> list:
        """Replace text blocks with a single merged text block, preserving interleaved non-text blocks.

        For ``[text, image, text]`` the image block between the two text blocks
        is kept in place - only the text blocks are collapsed into one.

        回写多模态：把所有 text block 合并成一个，保留中间夹着的非文本 block
        （如图像），不丢多模态信息。
        """
        text_block_ids = {id(b) for b in text_blocks}
        first = last = None
        for i, block in enumerate(original_content):
            if id(block) in text_block_ids:
                if first is None:
                    first = i
                last = i
        if first is None:
            return original_content
        result: list = [*original_content[:first], {"type": "text", "text": processed_text}]
        # Re-insert any non-text blocks that sat between text blocks
        for i in range(first + 1, last + 1):
            if id(original_content[i]) not in text_block_ids:
                result.append(original_content[i])
        result.extend(original_content[last + 1 :])
        return result

    def _process_request(self, request: ModelRequest) -> ModelRequest:
        """Return a request with the last genuine user message sanitized.

        Blocked tags are HTML-escaped (not rejected) so the user's intent is
        preserved while the tags lose their semantic significance. Transformation
        is temporary - the original request is never mutated.

        从尾向头扫，找到第一条真用户消息（跳过 ToolMessage / AIMessage / 框架注入的
        HumanMessage），消毒后用 ``request.override`` 返回新请求（不改原引用）。
        """
        messages = list(request.messages)
        for i in range(len(messages) - 1, -1, -1):
            msg = messages[i]
            if not _is_genuine_user_message(msg):
                if isinstance(msg, HumanMessage):
                    logger.debug(
                        "_process_request: skipping non-genuine HumanMessage at pos=%d name=%s hide_from_ui=%s content_preview=%.80r",
                        i,
                        msg.name,
                        msg.additional_kwargs.get("hide_from_ui"),
                        msg.content,
                    )
                continue
            content = msg.content
            logger.debug("_process_request: found genuine user message at pos=%d content=%.120r", i, content)

            text_content, text_blocks = self._extract_text_from_content(content)

            # No text at all (e.g. image-only message) - pass through
            if not text_content and not isinstance(content, str):
                logger.debug("_process_request: no text content in message - passing through")
                return request

            processed = _check_user_content(text_content)

            if processed == text_content:
                # Already wrapped - no override needed
                return request

            if text_blocks:
                new_content = self._rebuild_content(content, processed, text_blocks)
            else:
                new_content = processed

            # Preserve the pre-sanitization user text so downstream consumers that
            # must see the genuine input (slash skill activation, regenerate) can
            # recover it after the BEGIN/END wrapping. setdefault keeps an existing
            # value (e.g. set by UploadsMiddleware or an IM channel) authoritative.
            # 保留消毒前原文到 additional_kwargs--slash skill 激活 / regenerate 等
            # 下游消费者经 ORIGINAL_USER_CONTENT_KEY 读真用户输入。setdefault 让
            # 已有值（UploadsMiddleware / IM channel 设的）保持权威。
            preserved_kwargs = dict(msg.additional_kwargs or {})
            preserved_kwargs.setdefault(ORIGINAL_USER_CONTENT_KEY, message_content_to_text(content))
            messages[i] = HumanMessage(
                content=new_content,
                id=msg.id,
                name=msg.name,
                additional_kwargs=preserved_kwargs,
            )
            logger.debug(
                "InputSanitizationMiddleware: original=%r -> processed=%r",
                content if isinstance(content, str) else "[content-blocks]",
                processed,
            )
            return request.override(messages=messages)
        return request

    def _try_process(self, request: ModelRequest) -> ModelRequest:
        """Sanitize request; fail-open on unexpected errors.

        GraphBubbleUp propagates; other exceptions return the original request.

        消毒失败时 fail-open--返回原请求让模型仍能响应，而非整 run 死。
        GraphBubbleUp（LangGraph 控制流）必须原样上抛。
        """
        try:
            return self._process_request(request)
        except GraphBubbleUp:
            raise
        except Exception:
            logger.warning(
                "Input guardrail processing failed; passing original request to model",
                exc_info=True,
            )
            return request

    @override
    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelCallResult:
        # 最外层 wrap_model_call：所有内层（含 LLM 重试）见消毒后消息。
        return handler(self._try_process(request))

    @override
    async def awrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], Awaitable[ModelResponse]],
    ) -> ModelCallResult:
        return await handler(self._try_process(request))
```

---

## 关键不变量（从源码提炼）

1. **只清最后一条真用户消息**：从尾向头扫，命中第一条 `_is_genuine_user_message` 即处理并返回；历史消息不重复消毒，避免重复包裹。
2. **跳过框架注入的 HumanMessage**：`_is_genuine_user_message` 排除 summary 消息、HumanInputCard 隐藏回复（`hide_from_ui` 且无有效用户响应）--否则会破坏动态上下文注入与澄清回复。
3. **转义而非拒绝**：封锁标签 HTML-escape（`<system>` -> `&lt;system&gt;`），保留用户意图（"how do I use Helix's `<think>` tag?"），标签失去语义。普通 HTML/XML（`<div>`）不转义。
4. **边界标记 + neutralize**：`--- BEGIN/END USER INPUT ---` 作为次级语义防御；用户文本里已有的边界标记被 neutralize 成 `[BEGIN/END USER INPUT]`，防 self-suppression 与 break-out 攻击。
5. **幂等性**：已严格包裹（prefix+suffix）的文本原样返回；但内部仍 neutralize 边界标记（防 break-out）。
6. **临时变换不写 state**：`wrap_model_call` 只改请求载荷，`request.override` 返回新请求，不污染 checkpoint。原文经 `ORIGINAL_USER_CONTENT_KEY` 保留在 `additional_kwargs`，下游（slash skill / regenerate）可恢复。
7. **多模态兼容**：`_rebuild_content` 把多个 text block 合并成一个，保留中间夹着的非文本 block（图像），不丢多模态信息。
8. **fail-open**：消毒异常返回原请求（不杀 run）；`GraphBubbleUp` 原样上抛。
