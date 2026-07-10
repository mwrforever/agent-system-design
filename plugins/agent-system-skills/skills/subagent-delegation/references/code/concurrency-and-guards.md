# 并发上限 + 步骤捕获 + 护栏 `consume_stop_reason`

> 真实实现（已按插件匿名化规则映射到自定结构 `helix.*`，去除项目字样）。原注释保留以保真，关键处补中文注解。本文件汇集与子代理直接相关的三段护栏/捕获代码：`SubagentLimitMiddleware`（并发硬上限）、`step_events.py`（步骤捕获）、以及 `TokenBudgetMiddleware` / `LoopDetectionMiddleware` 暴露 `consume_stop_reason` 的护栏 cap 机制。两个护栏中间件的完整源码属于 `[[middleware-chain-design]]` / `[[context-window-management]]`，本文件只摘取与子代理 stop_reason 冒泡直接相关的部分。

## 1. `SubagentLimitMiddleware` 全文（并发硬上限）

```python
# core/helix/agents/middlewares/subagent_limit_middleware.py
"""强制单条模型响应内并发子代理工具调用上限的中间件。"""

import logging
from typing import override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langgraph.runtime import Runtime

from helix.agents.middlewares.tool_call_metadata import clone_ai_message_with_tool_calls
from helix.subagents.executor import MAX_CONCURRENT_SUBAGENTS

logger = logging.getLogger(__name__)

# max_concurrent_subagents 的有效区间
MIN_SUBAGENT_LIMIT = 2
MAX_SUBAGENT_LIMIT = 4


def _clamp_subagent_limit(value: int) -> int:
    """把 subagent limit clamp 到 [2, 4]。"""
    return max(MIN_SUBAGENT_LIMIT, min(MAX_SUBAGENT_LIMIT, value))


class SubagentLimitMiddleware(AgentMiddleware[AgentState]):
    """从单条模型响应中截断超额的 'task' 工具调用。

    当 LLM 在一条响应中生成超过 max_concurrent 的并行 task 工具调用时，本
    中间件只保留前 max_concurrent 个，丢弃其余。这比基于 prompt 的限制更可靠。

    Args:
        max_concurrent: 允许的最大并发子代理调用数。默认 MAX_CONCURRENT_SUBAGENTS
            （3）。clamp 到 [2, 4]。
    """

    def __init__(self, max_concurrent: int = MAX_CONCURRENT_SUBAGENTS):
        super().__init__()
        self.max_concurrent = _clamp_subagent_limit(max_concurrent)

    def _truncate_task_calls(self, state: AgentState) -> dict | None:
        messages = state.get("messages", [])
        if not messages:
            return None

        last_msg = messages[-1]
        if getattr(last_msg, "type", None) != "ai":
            return None

        tool_calls = getattr(last_msg, "tool_calls", None)
        if not tool_calls:
            return None

        # 统计 task 工具调用
        task_indices = [i for i, tc in enumerate(tool_calls) if tc.get("name") == "task"]
        if len(task_indices) <= self.max_concurrent:
            return None

        # 构建要丢弃的索引集合（超额的 task 调用）
        indices_to_drop = set(task_indices[self.max_concurrent :])
        truncated_tool_calls = [tc for i, tc in enumerate(tool_calls) if i not in indices_to_drop]

        dropped_count = len(indices_to_drop)
        logger.warning(f"Truncated {dropped_count} excess task tool call(s) from model response (limit: {self.max_concurrent})")

        # 用截断后的 tool_calls 替换 AIMessage（同 id 触发 LangGraph reducer 替换）
        updated_msg = clone_ai_message_with_tool_calls(last_msg, truncated_tool_calls)
        return {"messages": [updated_msg]}

    @override
    def after_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._truncate_task_calls(state)

    @override
    async def aafter_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._truncate_task_calls(state)
```

> **链上位置**：lead 专用中间件链第 24 项（`build_middlewares`），注册晚于 `LoopDetectionMiddleware`（第 25 项）与 `SafetyFinishReasonMiddleware`（第 28 项）。LangChain 逆序派发 `after_model`，所以 Safety 先清异常、Loop 先修剪重复 tool_calls，截断才在干净输入上做最终裁剪。同时实现 sync/async，两种图都生效。

## 2. `step_events.py` 全文（步骤捕获 + 载荷裁剪）

```python
# core/helix/subagents/step_events.py
"""构建紧凑的子代理步骤载荷，用于流式 + 持久化。

Issue #3779：子代理（subtask）执行步骤之前只作为最新 streamed 帧可见，
从不持久化，所以用户无法在 reload 后查看子代理跑了哪些工具或每步产出了什么。

本模块是纯数据塑形层。它把一个捕获的子代理消息 dict——``AIMessage``（一个
助手 turn：文本 + tool-call 请求）或 ``ToolMessage``（工具输出）的
``model_dump()``——转换成小型、JSON 可序列化的 ``step`` 载荷，用于：

- 在 ``task_running`` 自定义事件内 live streamed（``task_tool.py``），以及
- 持久化为 ``subagent.step`` run event（``runtime/runs/worker.py``）。

保持纯函数意味着无需起图即可单测，且流式与持久化调用点共享一个"步骤"定义。
"""

from __future__ import annotations

import json
from typing import Any

from langchain_core.messages import AIMessage, BaseMessage, ToolMessage

from helix.utils.messages import message_content_to_text

#: ``text`` 字段的默认每步字符上限。工具输出（web search 结果、文件内容）可能
#: 很大；该上限约束持久化 run-event 行和 streamed 帧。它只影响展示/存储——
#: 子代理自己的 LLM 上下文由 ToolOutputBudgetMiddleware 单独约束。
SUBAGENT_STEP_MAX_CHARS = 8192

#: 持久化子代理步骤的 ``RunEvent.category``。专用 category（非 ``"message"``）
#: 让这些事件不进入 ``list_messages``（线程消息流），但仍被 ``list_events``
#: 返回供 fetch-on-expand（#3779）。
SUBAGENT_EVENT_CATEGORY = "subagent"

#: ``task_*`` 终端自定义事件类型到其持久化 status 的映射。
_TERMINAL_EVENT_STATUS: dict[str, str] = {
    "task_completed": "completed",
    "task_failed": "failed",
    "task_cancelled": "cancelled",
    "task_timed_out": "timed_out",
}


def capture_step_message(
    message: BaseMessage,
    captured: list[dict[str, Any]],
    seen_ids: set[str],
) -> bool:
    """若是新步骤，把 ``message.model_dump()`` 追加到 ``captured``。

    "步骤"是一个助手 turn（``AIMessage``）或工具结果（``ToolMessage``）——
    issue #3779 加入后者使工具输出得以保留。其他消息类型（如 ``HumanMessage``）
    被忽略。去重按 id（存在时），无 id 消息退化到全 dict 比较，使
    ``stream_mode="values"`` 重 yield 同一尾部消息保持 O(1)。

    追加了消息时返回 ``True``。
    """
    if not isinstance(message, (AIMessage, ToolMessage)):
        return False

    message_dict = message.model_dump()
    message_id = message_dict.get("id")
    if message_id:
        if message_id in seen_ids:
            return False
    elif message_dict in captured:
        return False

    captured.append(message_dict)
    if message_id:
        seen_ids.add(message_id)
    return True


def capture_new_step_messages(
    messages: list[BaseMessage],
    captured: list[dict[str, Any]],
    seen_ids: set[str],
    processed_count: int,
) -> int:
    """捕获自 ``processed_count`` 起追加的每一步消息（#3779）。

    ``stream_mode="values"`` 每个 chunk 重新 yield 全消息历史，单个 LangGraph
    super-step 可能一次 append 多条消息——最重要的是模型一 turn 发多个 tool_call
    时每个 tool_call 一条 ``ToolMessage``。只捕获 ``messages[-1]``（旧行为）
    会静默丢弃除最后一条以外的所有工具输出。

    历史增长时，遍历每个新增消息。未增长时，只重检尾部消息，使无 id 的原地
    替换（等长、新内容）仍被捕获——``capture_step_message`` 的去重让未变
    重 yield 成为 no-op。返回新游标。
    """
    total = len(messages)
    if total > processed_count:
        for message in messages[processed_count:total]:
            capture_step_message(message, captured, seen_ids)
        return total
    if messages:
        capture_step_message(messages[-1], captured, seen_ids)
    return max(processed_count, total)


def truncate_step_text(text: str, max_chars: int) -> tuple[str, bool]:
    """返回 ``(text, truncated)``，超长则裁剪到 ``max_chars``。"""
    if max_chars >= 0 and len(text) > max_chars:
        return text[:max_chars], True
    return text, False


def _bounded_tool_call(call: dict[str, Any], max_chars: int) -> dict[str, Any]:
    """为捕获的工具调用返回 ``{name, args}``，裁剪大 args（#3779）。

    ``build_subagent_step`` 裁剪 ``text`` 字段，但工具调用 ``args`` 原样复制，
    所以携带大载荷（完整文件内容、heredoc）的 ``write_file``/``bash`` 调用会
    产生无界的持久化 ``subagent.step`` 行和 streamed 帧。当 JSON 序列化的 args
    超过 ``max_chars`` 时，用截断的序列化预览替换结构化值并以 ``args_truncated``
    标记——小 args 保持结构化供卡片检视。
    """
    name = call.get("name")
    args = call.get("args")
    serialized = args if isinstance(args, str) else json.dumps(args, default=str, ensure_ascii=False)
    if max_chars >= 0 and len(serialized) > max_chars:
        return {"name": name, "args": serialized[:max_chars], "args_truncated": True}
    return {"name": name, "args": args}


def build_subagent_step(
    message: dict[str, Any],
    *,
    task_id: str,
    message_index: int,
    max_chars: int = SUBAGENT_STEP_MAX_CHARS,
) -> dict[str, Any]:
    """从捕获的子代理消息 dict 构建紧凑的步骤载荷。

    ``kind`` 对 ``ToolMessage``（``type == "tool"``）为 ``"tool"``，否则为
    ``"ai"``。AI 步骤携带 ``tool_calls``（仅 name + args，大 args 裁剪到
    ``max_chars``——见 ``_bounded_tool_call``）；tool 步骤携带来源
    ``tool_name``。``text`` 裁剪到 ``max_chars`` 并相应设置 ``truncated`` 标志。
    """
    kind = "tool" if message.get("type") == "tool" else "ai"
    # ``... or ""`` 让纯 tool-call turn 的 content=None 渲染为 ""
    # （否则 message_content_to_text 会 str()-ify 成 "None"）。
    text, truncated = truncate_step_text(message_content_to_text(message.get("content") or ""), max_chars)

    step: dict[str, Any] = {
        "task_id": task_id,
        "message_index": message_index,
        "kind": kind,
        "text": text,
        "truncated": truncated,
    }

    if kind == "tool":
        step["tool_name"] = message.get("name")
    else:
        step["tool_calls"] = [_bounded_tool_call(call, max_chars) for call in (message.get("tool_calls") or [])]

    return step


def subagent_run_event(chunk: Any) -> dict[str, Any] | None:
    """把 ``task_*`` 自定义流 chunk 映射到 ``RunEventStore.put`` kwargs。

    为可持久化的子代理生命周期事件返回 ``event_type`` / ``category`` /
    ``content`` / ``metadata``，对非子代理事件的 chunk 返回 ``None``
    （使 worker 只持久化它识别的内容）。``thread_id`` / ``run_id`` 由调用方填入。
    """
    if not isinstance(chunk, dict):
        return None

    event = chunk.get("type")
    if not isinstance(event, str) or not event.startswith("task_"):
        return None

    task_id = chunk.get("task_id")

    if event == "task_started":
        return {
            "event_type": "subagent.start",
            "category": SUBAGENT_EVENT_CATEGORY,
            "content": {"task_id": task_id, "description": chunk.get("description")},
            "metadata": {"task_id": task_id},
        }

    if event == "task_running":
        message_index = chunk.get("message_index")
        return {
            "event_type": "subagent.step",
            "category": SUBAGENT_EVENT_CATEGORY,
            "content": build_subagent_step(chunk.get("message") or {}, task_id=task_id, message_index=message_index),
            "metadata": {"task_id": task_id, "message_index": message_index},
        }

    status = _TERMINAL_EVENT_STATUS.get(event)
    if status is not None:
        content: dict[str, Any] = {"task_id": task_id, "status": status}
        # 最终 result/error 可能是多页报告；裁剪使持久化 run-event 行有界
        # （终端 ToolMessage 上仍保留原文，卡片单独读取）。
        if chunk.get("result") is not None:
            result, result_truncated = truncate_step_text(str(chunk["result"]), SUBAGENT_STEP_MAX_CHARS)
            content["result"] = result
            if result_truncated:
                content["result_truncated"] = True
        if chunk.get("error") is not None:
            error, error_truncated = truncate_step_text(str(chunk["error"]), SUBAGENT_STEP_MAX_CHARS)
            content["error"] = error
            if error_truncated:
                content["error_truncated"] = True
        return {
            "event_type": "subagent.end",
            "category": SUBAGENT_EVENT_CATEGORY,
            "content": content,
            "metadata": {"task_id": task_id},
        }

    return None
```

## 3. 护栏 `consume_stop_reason` 机制（additive cap 冒泡）

两个护栏中间件（`TokenBudgetMiddleware` / `LoopDetectionMiddleware`）都用同一模式：**hard-stop 不抛异常，而是剥除 `tool_calls` 让 run 自然完成；同时在 per-`run_id` 的有界 dict 上记录 cap 原因，经 `consume_stop_reason(run_id)` 暴露给子代理执行器**。下面摘取每个护栏与该机制直接相关的部分。

### 3.1 `TokenBudgetMiddleware`：token 轴（`token_capped`）

```python
# core/helix/agents/middlewares/token_budget_middleware.py — 与 stop_reason 相关的部分
"""（模块 docstring 节选）Stop-reason surfacing（#3875 Phase 2）：
hard stop 不抛异常——它剥除 tool_calls 使 agent loop 自然终止并产出最终答案。
为了让调用方（如子代理执行器）区分预算 cap 的完成与干净完成，触发 hard stop 的
run 记录在 ``_stop_reason`` 并通过 :meth:`consume_stop_reason` 暴露。该 dict 刻意
不被 ``after_agent``/``_clear_run_state`` 清除，使执行器能在 run 返回后读取；
有界 dict 防止被放弃的 run 无限增长，每个子代理 run 构建新的中间件实例所以无跨 run 污染。
"""
from helix.agents.middlewares._bounded_dict import BoundedDict
from helix.config.token_budget_config import TokenBudgetConfig


class TokenBudgetMiddleware(AgentMiddleware[AgentState]):
    """Enforce per-run token budget limits."""

    def __init__(self, config: TokenBudgetConfig) -> None:
        super().__init__()
        self._config = config
        self._lock = threading.Lock()

        # 严格按 run_id 键控（防 clobber）且有界（防泄漏）
        self._warned: BoundedDict[str, bool] = BoundedDict(1000)
        self._pending_warnings: BoundedDict[str, list[str]] = BoundedDict(1000)
        self._seen_messages: BoundedDict[str, dict[str, tuple[int, int]]] = BoundedDict(1000)
        self._cumulative_usage: BoundedDict[str, TokenUsage] = BoundedDict(1000)
        # hard-stop 触发时设置的 stop 原因。不被 ``_clear_run_state``/
        # ``after_agent`` 清除，使执行器能在 run 返回后消费；有界所以被放弃
        # 的 run 不会泄漏。
        self._stop_reason: BoundedDict[str, str] = BoundedDict(1000)

    def consume_stop_reason(self, run_id: str | None) -> str | None:
        """pop 并返回 hard-stop 为本次 run 设置的 stop 原因。

        预算 hard-stop 在 run 期间触发时返回 ``"token_capped"``，否则 ``None``。
        执行器在 run 返回后调用此方法判断一个 completed 子代理是否实际被预算
        截断（并应携带 ``stop_reason=token_capped`` 给主代理）。pop 防止 dict
        在复用实例上跨 run 累积。
        """
        with self._lock:
            return self._stop_reason.pop(run_id, None)

    @staticmethod
    def _get_run_id(runtime: Runtime) -> str:
        ctx = getattr(runtime, "context", None)
        if isinstance(ctx, dict) and "run_id" in ctx:
            return ctx["run_id"]
        # 回退到 runtime 对象 id 防止跨嵌入式客户端 run 碰撞
        return str(id(runtime))

    # after_agent 时刻意不清 _stop_reason（与 _clear_run_state 的其他键不同），
    # 让执行器在 run 返回后能读到。

    def _build_hard_stop_update(self, msg: AIMessage, stop_msg: str) -> dict[str, Any]:
        """为 hard stop 构建状态更新——剥除 tool_calls 让 run 自然完成。"""
        updated_content = self._append_text(msg.content, stop_msg)
        kwargs = dict(msg.additional_kwargs) if msg.additional_kwargs else {}
        if "tool_calls" in kwargs:
            del kwargs["tool_calls"]
        if "function_call" in kwargs:
            del kwargs["function_call"]

        response_metadata = dict(getattr(msg, "response_metadata", {}) or {})

        if response_metadata.get("finish_reason") == "tool_calls":
            response_metadata["finish_reason"] = "stop"   # 强制收尾

        stopped_msg = msg.model_copy(update={"content": updated_content, "tool_calls": [], "additional_kwargs": kwargs, "response_metadata": response_metadata})
        return {"messages": [stopped_msg]}

    def _apply(self, state: AgentState, runtime: Runtime) -> dict | None:
        # ...累加 token、算 fractions...
        if highest_fraction >= self._config.hard_stop_threshold:
            logger.warning("Token budget hard stop triggered for run %s: %s limit exceeded", run_id, trigger_reason)
            # 记录 stop 原因让执行器在 run 返回后 surface
            # ``stop_reason=token_capped``（hard stop 本身不抛异常）。见
            # ``consume_stop_reason``。
            self._stop_reason[run_id] = "token_capped"
            stop_text = _BUDGET_EXCEEDED_MSG.format(reason=trigger_reason, used=trigger_used, budget=trigger_budget)
            return self._build_hard_stop_update(last_msg, stop_text)
        # ...warn 阈值路径...
```

### 3.2 `LoopDetectionMiddleware`：loop 轴（`loop_capped`）

```python
# core/helix/agents/middlewares/loop_detection_middleware.py — 与 stop_reason 相关的部分
"""（模块 docstring 节选）Stop-reason surfacing（#3875 Phase 2）：
与 token-budget 护栏一样，loop hard stop 不抛异常——它剥除 ``tool_calls`` 使
agent loop 自然以最终答案终止。为了让调用方（子代理执行器）区分 loop-capped
完成与干净完成，触发 hard stop 的 run 记录在 ``_stop_reason`` 并通过
:meth:`consume_stop_reason` 暴露。执行器把该原因与 token-budget 护栏的一起
收集，使 loop-capped run surface 为 ``completed + loop_capped``，主代理/ledger
无需解析结果文本即可判断被截断。
"""
from helix.agents.middlewares._bounded_dict import BoundedDict


class LoopDetectionMiddleware(AgentMiddleware[AgentState]):
    """检测并打断重复 tool-call 循环。"""

    def __init__(self, warn_threshold=3, hard_limit=5, window_size=20,
                 max_tracked_threads=100, tool_freq_warn=30, tool_freq_hard_limit=50,
                 tool_freq_overrides=None):
        super().__init__()
        # ...各阈值...
        self._lock = threading.Lock()
        # ...history / warned / tool_freq 等按 thread_id 键控...
        # hard-stop 触发时设置的 stop 原因（#3875 Phase 2）。按 run_id 键控
        # （与 ``TokenBudgetMiddleware`` 一致）且有界——主代理的中间件实例跨
        # 多个 run 长寿命，不封顶则每个 looped lead run 都会累积一条。刻意
        # 不被 ``after_agent``/``_clear_current_run_pending_warnings`` 清除，
        # 使子代理执行器能在 run 返回后消费；``reset()`` 仍会丢弃。
        self._stop_reason: BoundedDict[str, str] = BoundedDict(1000)

    def _get_run_id(self, runtime: Runtime) -> str:
        """从 runtime context 抽 run_id，用于 per-run 警告作用域。"""
        run_id = runtime.context.get("run_id") if runtime.context else None
        if run_id:
            return str(run_id)
        return "default"

    def consume_stop_reason(self, run_id: str | None) -> str | None:
        """pop 并返回 hard-stop 为本次 run 设置的 stop 原因。

        run 期间重复 tool-call 循环触发 hard stop 时返回 ``"loop_capped"``——
        run 仍以强制最终答案完成（hard stop 剥除 ``tool_calls`` 而非抛异常）。
        子代理执行器在 run 返回后调用此方法，使 loop-capped 完成携带
        ``stop_reason=loop_capped`` 给主代理，而非看起来像干净 ``completed``。
        镜像 ``TokenBudgetMiddleware.consume_stop_reason``；pop 防止 dict 在
        复用实例上累积。
        """
        with self._lock:
            return self._stop_reason.pop(run_id, None)

    @staticmethod
    def _build_hard_stop_update(last_msg, content: str | list) -> dict:
        """清掉 tool-call 元数据，使强制停止消息序列化为纯助手文本。"""
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
            # 记录 stop 原因让执行器在 run 返回后 surface
            # ``stop_reason=loop_capped``（#3875 Phase 2）。hard stop 不抛——它
            # 剥除 tool_calls 让 run 以强制最终答案完成——所以缺这一步调用方会
            # 看到干净 ``completed``。见 ``consume_stop_reason``。在锁下写入以
            # 匹配 ``TokenBudgetMiddleware``：主代理的中间件实例被跨并发 Gateway
            # 线程共享，有界 dict 写入需要同样守护。
            run_id = self._get_run_id(runtime)
            with self._lock:
                self._stop_reason[run_id] = "loop_capped"
            # 从最后一条 AIMessage 剥除 tool_calls 强制文本输出。一旦 tool_calls
            # 被剥除，AIMessage 不再需要匹配的 ToolMessage 响应，所以这里原地
            # 变更对 OpenAI/Moonshot 配对验证器安全。
            messages = state.get("messages", [])
            last_msg = messages[-1]
            content = self._append_text(last_msg.content, warning or _HARD_STOP_MSG)
            stripped_msg = last_msg.model_copy(update=self._build_hard_stop_update(last_msg, content))
            return {"messages": [stripped_msg]}

        if warning:
            # 把注入推迟到下一次模型调用。这里绝不能改 AIMessage(tool_calls=...)
            # （会把框架的话放进模型嘴里，污染 MemoryMiddleware 等下游消费者），
            # 也不能插入单独的非工具消息（会破坏 OpenAI/Moonshot tool-call 配对，
            # 因为 tools node 还没产出 ToolMessage 响应）。警告由下面
            # ``wrap_model_call`` 投递。
            self._queue_pending_warning(runtime, warning)
            return None

        return None
```

## 关键不变量（从源码提炼）

1. **截断前 N、丢弃后**：`SubagentLimitMiddleware` 按 tool_call 在 AIMessage 的 index 排序，保留前 `max_concurrent` 个 task 调用；同 id 重写触发 LangGraph reducer 替换。
2. **clamp `[2, 4]`**：低于 2 无意义；高于 4 调度池成瓶颈且子代理内存线性放大。
3. **步骤捕获尾部扫描**：`capture_new_step_messages` 用 `processed_count` 游标，只扫 `messages[processed_count:total]` 新增尾部；历史未增长时只重检 `messages[-1]`（捕获无 id 原地替换）。
4. **O(1) 去重**：`seen_message_ids: set[str]` 按 message `id`；无 id 退化到 `message_dict in captured` 全比较。
5. **护栏 hard-stop 不抛**：剥 `tool_calls` + 强制 `finish_reason="stop"`，run 自然完成出最终答案；cap 原因经 `consume_stop_reason(run_id)` 事后暴露。
6. **`_stop_reason` 不被 `after_agent` 清**：让执行器在 run 返回后能读；有界 `BoundedDict(1000)` 防被放弃 run 泄漏。
7. **duck-typed 收集**：执行器 `[m for m in middlewares if hasattr(m, "consume_stop_reason")]`，零 import 耦合，新增护栏自动纳入。
