# 孤儿 tool_call 清理完整源码 — context-window-management

> 本文件是 `context-window-management` skill 的 references/code，承载 `DanglingToolCallMiddleware` 的**完整真实源码**（已按插件匿名化规则映射到自定结构）。SKILL.md 只放入口片段，深度在此。

---

## 1. `DanglingToolCallMiddleware` 完整源码

真实路径 `core/helix/agents/middlewares/dangling_tool_call_middleware.py`。在 base 段（第 6 项），lead 与子代理都挂（`include_dangling_tool_call_patch=True`）。

**核心设计要点**：

- **用 `wrap_model_call` 而非 `before_model`**：`before_model` 返回的列表经 `add_messages` reducer 会**追加到末尾**，破坏"`AIMessage(tool_calls)` 紧跟其 `ToolMessage`"的因果序；`wrap_model_call` 在最终载荷上重组，把每个 ToolMessage 紧贴在其 AIMessage 之后。
- **三源归一化**（`_message_tool_calls`）：结构化 `msg.tool_calls` + 原始 provider payload `additional_kwargs["tool_calls"]`（结构化字段空时的兜底）+ `invalid_tool_calls`（malformed JSON args）。三源都视为"可能孤儿"。
- **per-request 载荷，不改 state**：`request.override(messages=patched)` 只动模型调用载荷，checkpoint 历史原貌不变。
- **`write_file` 专门引导**（issue #2894）：malformed write_file 带巨大 Markdown payload 时，合成 ToolMessage 不回显 payload，而是引导模型改用普通文本回复。

```python
# core/helix/agents/middlewares/dangling_tool_call_middleware.py
"""Middleware to fix dangling tool calls in message history.

A dangling tool call occurs when an AIMessage contains tool_calls but there are
no corresponding ToolMessages in the history (e.g., due to user interruption or
request cancellation). This causes LLM errors due to incomplete message format.

This middleware intercepts the model call to detect and patch such gaps by
inserting synthetic ToolMessages with an error indicator immediately after the
AIMessage that made the tool calls, ensuring correct message ordering.

Note: Uses wrap_model_call instead of before_model to ensure patches are inserted
at the correct positions (immediately after each dangling AIMessage), not appended
to the end of the message list as before_model + add_messages reducer would do.
"""

import json
import logging
from collections import defaultdict, deque
from collections.abc import Awaitable, Callable
from typing import override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelCallResult, ModelRequest, ModelResponse
from langchain_core.messages import ToolMessage

logger = logging.getLogger(__name__)

# Workaround for issue #2894: malformed write_file calls can carry huge Markdown
# payloads in invalid tool-call args. Keep recovery error details short so the
# synthetic ToolMessage does not echo large or malformed content back to the model.
_MAX_RECOVERY_ERROR_DETAIL_LEN = 500


class DanglingToolCallMiddleware(AgentMiddleware[AgentState]):
    """Inserts placeholder ToolMessages for dangling tool calls before model invocation.

    Scans the message history for AIMessages whose tool_calls lack corresponding
    ToolMessages, and injects synthetic error responses immediately after the
    offending AIMessage so the LLM receives a well-formed conversation.
    """

    @staticmethod
    def _message_tool_calls(msg) -> list[dict]:
        """Return normalized tool calls from structured fields or raw provider payloads.

        LangChain stores malformed provider function calls in invalid_tool_calls.
        They do not execute, but provider adapters may still serialize enough of
        the call id/name back into the next request that strict OpenAI-compatible
        validators expect a matching ToolMessage. Treat them as dangling calls so
        the next model request stays well-formed and the model sees a recoverable
        tool error instead of another provider 400.
        """
        normalized: list[dict] = []

        tool_calls = getattr(msg, "tool_calls", None) or []
        normalized.extend(list(tool_calls))

        raw_tool_calls = (getattr(msg, "additional_kwargs", None) or {}).get("tool_calls") or []
        if not tool_calls:
            for raw_tc in raw_tool_calls:
                if not isinstance(raw_tc, dict):
                    continue

                function = raw_tc.get("function")
                name = raw_tc.get("name")
                if not name and isinstance(function, dict):
                    name = function.get("name")

                args = raw_tc.get("args", {})
                if not args and isinstance(function, dict):
                    raw_args = function.get("arguments")
                    if isinstance(raw_args, str):
                        try:
                            parsed_args = json.loads(raw_args)
                        except (TypeError, ValueError, json.JSONDecodeError):
                            parsed_args = {}
                        args = parsed_args if isinstance(parsed_args, dict) else {}

                normalized.append(
                    {
                        "id": raw_tc.get("id"),
                        "name": name or "unknown",
                        "args": args if isinstance(args, dict) else {},
                    }
                )

        for invalid_tc in getattr(msg, "invalid_tool_calls", None) or []:
            if not isinstance(invalid_tc, dict):
                continue
            normalized.append(
                {
                    "id": invalid_tc.get("id"),
                    "name": invalid_tc.get("name") or "unknown",
                    "args": {},
                    "invalid": True,
                    "error": invalid_tc.get("error"),
                }
            )

        return normalized

    @staticmethod
    def _synthetic_tool_message_content(tool_call: dict) -> str:
        if tool_call.get("invalid"):
            name = tool_call.get("name")
            error = tool_call.get("error")
            error_text = error[:_MAX_RECOVERY_ERROR_DETAIL_LEN] if isinstance(error, str) and error else ""
            # Workaround for issue #2894: malformed write_file calls can carry huge Markdown
            # payloads in invalid tool-call args. Keep recovery guidance actionable without
            # echoing large or malformed content back to the model.
            if name == "write_file":
                details = f" Parser error: {error_text}" if error_text else ""
                return (
                    "[write_file failed before execution: the tool-call arguments were not valid JSON, "
                    "so no file was written. This often happens when the model tries to write a very "
                    "large Markdown file in a single tool call, especially when `content` contains "
                    "unescaped quotes, inline JSON, backslashes, or code fences. Do not retry the same "
                    "large `write_file` payload for this artifact; provide the report/content directly "
                    "as normal assistant text in your next response. If a file write is still needed "
                    f"later, split the file into smaller sections instead of one large payload.{details}]"
                )
            if error_text:
                return f"[Tool call could not be executed because its arguments were invalid: {error_text}]"
            return "[Tool call could not be executed because its arguments were invalid.]"
        return "[Tool call was interrupted and did not return a result.]"

    def _build_patched_messages(self, messages: list) -> list | None:
        """Return messages with tool results grouped after their tool-call AIMessage.

        This normalizes model-bound causal order before provider serialization while
        preserving already-valid transcripts unchanged.
        """
        tool_messages_by_id: dict[str, deque[ToolMessage]] = defaultdict(deque)
        for msg in messages:
            if isinstance(msg, ToolMessage):
                tool_messages_by_id[msg.tool_call_id].append(msg)

        tool_call_ids: set[str] = set()
        for msg in messages:
            if getattr(msg, "type", None) != "ai":
                continue
            for tc in self._message_tool_calls(msg):
                tc_id = tc.get("id")
                if tc_id:
                    tool_call_ids.add(tc_id)

        patched: list = []
        patch_count = 0
        for msg in messages:
            if isinstance(msg, ToolMessage) and msg.tool_call_id in tool_call_ids:
                continue

            patched.append(msg)
            if getattr(msg, "type", None) != "ai":
                continue

            for tc in self._message_tool_calls(msg):
                tc_id = tc.get("id")
                if not tc_id:
                    continue

                tool_msg_queue = tool_messages_by_id.get(tc_id)
                existing_tool_msg = tool_msg_queue.popleft() if tool_msg_queue else None
                if existing_tool_msg is not None:
                    patched.append(existing_tool_msg)
                else:
                    patched.append(
                        ToolMessage(
                            content=self._synthetic_tool_message_content(tc),
                            tool_call_id=tc_id,
                            name=tc.get("name", "unknown"),
                            status="error",
                        )
                    )
                    patch_count += 1

        if patched == messages:
            return None

        if patch_count:
            logger.warning(f"Injecting {patch_count} placeholder ToolMessage(s) for dangling tool calls")
        return patched

    @override
    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelCallResult:
        patched = self._build_patched_messages(request.messages)
        if patched is not None:
            request = request.override(messages=patched)
        return handler(request)

    @override
    async def awrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], Awaitable[ModelResponse]],
    ) -> ModelCallResult:
        patched = self._build_patched_messages(request.messages)
        if patched is not None:
            request = request.override(messages=patched)
        return await handler(request)
```

---

## 2. 产生孤儿的真实场景与补占位后的消息序列

**场景 A：用户中断**

```
turn N:   模型发 AIMessage(tool_calls=[{id:"tc_1", name:"bash", args:{command:"ls"}}])
          用户点"停止" -> tools 节点没跑 -> 无 ToolMessage(tc_1)
turn N+1: before_model / wrap_model_call 收到的 history 尾部是裸 tool_call
          -> DanglingToolCall 补占位：
             AIMessage(tool_calls=[tc_1])
             ToolMessage(tool_call_id="tc_1", content="[Tool call was interrupted...]", status="error")
          -> provider 收到合法 transcript，正常继续
```

**场景 B：malformed write_file（issue #2894）**

```
turn N:   模型发 AIMessage(invalid_tool_calls=[{id:"tc_2", name:"write_file",
                        error:"JSON parse error at ...huge markdown..."}])
          -> write_file 不执行（args 不合法），无 ToolMessage(tc_2)
          -> 但 provider 适配器下次仍可能把 tc_2 的 id/name 序列化进请求
turn N+1: DanglingToolCall._message_tool_calls 三源归一化扫到 invalid_tool_calls
          -> 补占位（write_file 专门引导，不回显 payload）：
             ToolMessage(tool_call_id="tc_2",
                         content="[write_file failed before execution: ...split into smaller sections...]",
                         status="error")
          -> 模型收到可恢复错误，改用普通文本或分段写入
```

**场景 C：历史裁剪 / checkpoint resume**

```
某种外部机制截断了消息历史，恰好保留 AIMessage(tool_calls=[tc_3]) 但丢了 ToolMessage(tc_3)
-> DanglingToolCall 扫描所有 AIMessage，对每个缺响应的 tool_call 补占位
-> ToolMessage 紧贴在 AIMessage 之后（wrap_model_call 重组，不是 before_model 追加末尾）
```

---

## 3. base 段的装配片段

真实路径 `core/helix/agents/middlewares/tool_error_handling_middleware.py`（共享基座 `_build_runtime_middlewares`）。DanglingToolCall 在 base 段第 6 项，lead 与子代理都挂（`include_dangling_tool_call_patch=True`）——子代理也会被取消产生孤儿。

```python
# core/helix/agents/middlewares/tool_error_handling_middleware.py
def build_lead_runtime_middlewares(*, app_config: AppConfig, lazy_init: bool = True) -> list[AgentMiddleware]:
    """lead agent 运行时在 lead 专用中间件之前共享的中间件。"""
    return _build_runtime_middlewares(
        app_config=app_config,
        include_uploads=True,                   # lead 才注入 uploads；子代理 include_uploads=False
        include_dangling_tool_call_patch=True,  # lead + 子代理都补孤儿占位
        lazy_init=lazy_init,
    )

# _build_runtime_middlewares 内部，Layer 1（外层 wrap_model_call 包装）装：
#   1 InputSanitization（最外层）
#   2 ToolOutputBudget
# Layer 2（before_agent 线程级钩子）装：
#   3 ThreadData -> 4 Uploads? -> 5 Sandbox
# Layer 3（后处理 append-only 尾部）装：
#   6 DanglingToolCall?（include_dangling_tool_call_patch 开关）
#   7 LLMErrorHandling
#   ...
# DanglingToolCall 用 wrap_model_call，在 Layer 1 与 Layer 3 都能正确插入
# （wrap_model_call 是洋葱模型，位置由 append 顺序决定）
```
