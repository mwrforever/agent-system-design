# 29 项链顺序清单（含 hook 类型标注）+ 关键中间件片段

> 与 [SKILL.md](../../SKILL.md) 同步。本文件给两样东西：
>
> 1. **29 项链顺序清单**（完整），每项标注它 override 的 LangChain `AgentMiddleware` 钩子类型（`before_agent` / `before_model` / `wrap_model_call` / `after_model` / `wrap_tool_call` / `after_agent`）+ 所属段（base / lead-only）+ 条件门。这是 `middleware-chain-design` skill 相对脊柱 05-middleware-chain.md 的新增价值（脊柱清单未标 hook 类型）。
> 2. **关键中间件入口片段**（DynamicContext / SystemMessageCoalescing / DeferredToolFilter / ClarificationMiddleware 链尾），给"链顺序不变量"的可读锚点。完整源码指向 `[[system-prompt-template]]` 与脊柱 [references/code/05-middleware-chain.md](../../../e2e-request-lifecycle/references/code/05-middleware-chain.md)。
>
> 代码为真实实现（已按插件匿名化规则映射到自定结构 `helix.*`，去除一切项目字样）。

---

## 1. LangChain AgentMiddleware 钩子执行序（框架规则）

理解 29 项链的顺序之前，先固定框架的钩子派发规则（来自 `langchain/agents/middleware/types.py` 与 `langchain/agents/factory.py`）：

| 钩子 | 派发方向 | 语义 | 链表位置 -> 执行位置 |
|---|---|---|---|
| `before_agent` / `abefore_agent` | **正序**（第 1 项先跑） | 进入图前一次性预处理；返回 `dict` 经 reducer 合并入 state | 链首 = 最先 |
| `before_model` | **正序** | 模型调用前预处理 state | 链首 = 最先 |
| `wrap_model_call` / `awrap_model_call` | **洋葱**（第 1 项最外层） | 包裹模型调用；接收 `ModelRequest` 返回 `ModelResponse` | 链首 = 最外层 |
| `after_model` / `aafter_model` | **逆序**（最后注册的最先跑） | 模型返回后处理 | 链尾 = 最先 |
| `wrap_tool_call` / `awrap_tool_call` | **洋葱**（第 1 项最外层） | 包裹单次工具执行；可短路返回 `ToolMessage` 或 `Command` | 链首 = 最外层 |
| `after_agent` / `aafter_agent` | **正序** | 图退出前清理 | 链首 = 最先 |

**关键推论**：
- `wrap_model_call` 与 `wrap_tool_call` 是洋葱模型：链表第 1 项是**最外层**，包裹所有内层；第 N 项是最内层（最贴近真实模型/工具）。
- `after_model` 是 LIFO 出口：最后注册的中间件**最先**看到模型输出。这是 `SafetyFinishReasonMiddleware` 必须注册在 `LoopDetectionMiddleware` **之后**（链表中更靠后）的原因--逆序派发使 Safety 先跑、清空安全终止的 tool_calls，Loop 再对清理后消息计数。
- **中断型中间件必须链尾**：`ClarificationMiddleware` 返回 `Command(goto=END)` 中断 run。若它不在链尾，排在它后面的中间件的 `after_model` / `after_agent` 钩子会在中断后错过，状态不一致（TokenBudget 计量丢失、SafetyFinishReason 清理未跑）。

---

## 2. 29 项链顺序清单（含 hook 类型）

`?` 标注的是 config/runtime 条件可选。段标注：`base` = 共享基座（lead + 子代理复用），`lead` = lead 专用续装。

```
共享基座 build_lead_runtime_middlewares（子代理经 build_subagent_runtime_middlewares 复用大部分）：
 1  InputSanitization       [wrap_model_call]                base   - 最外层 wrap_model_call，所有内层见消毒后消息
 2  ToolOutputBudget        [wrap_model_call, wrap_tool_call] base   - 工具输出体积上限
 3  ThreadData              [before_agent]                   base   - 建 per-thread 目录（user_id 隔离）
 4  Uploads                 [before_agent]                   base*  - 注入新上传文件（仅 lead，include_uploads=True）
 5  Sandbox                 [before_agent, after_agent, wrap_tool_call] base - 申请沙箱，存 sandbox_id 到 state
 6  DanglingToolCall        [wrap_model_call]                base   - 为缺响应的 tool_call 注入占位 ToolMessage
 7  LLMErrorHandling        [wrap_model_call]                base   - 归一化模型调用失败为可恢复错误
 8  Guardrail?              [wrap_tool_call]                 base?  - 工具调用前授权（可插拔 GuardrailProvider）
 9  SandboxAudit            [wrap_tool_call]                 base   - 审计沙箱 shell/file 操作
10  ReadBeforeWrite?        [wrap_tool_call]                 base?  - 写前必读门（content hash 校验）
11  ToolProgress?           [before_agent, wrap_tool_call, wrap_model_call] base? - 工具停滞状态机守卫
12  ToolErrorHandling       [wrap_tool_call]                 base   - 工具异常转 ToolMessage，盖 helix_tool_meta 元数据

lead 专用 build_middlewares（agent.py）续装：
13  DynamicContext          [before_agent]                   lead   - 注入日期/记忆 <system-reminder>（见 [[system-prompt-template]]）
14  SkillActivation         [wrap_model_call]                lead   - /skill-name 显式激活，注入 SKILL.md
15  DurableContext          [before_model, after_model, wrap_model_call] lead - 捕获 task 委派 + 技能引用，防被摘要压掉
16  Summarization?          [before_model]                   lead?  - 上下文压缩
17  TodoList?               [before_model, before_agent, after_model, wrap_model_call, after_agent] lead? - plan mode 任务追踪
18  TokenUsage?             [after_model]                    lead?  - 记录 token 用量
19  Title                   [after_model]                    lead   - 首轮交换后自动起标题
20  Memory                  [after_agent]                    lead   - 排队异步记忆更新
21  ViewImage?              [before_model]                   lead?  - 视觉模型注入 base64 图像
22  DeferredToolFilter?     [wrap_model_call, wrap_tool_call] lead?  - 延迟 MCP 工具，tool_search 提升前隐藏 schema
23  SystemMessageCoalescing [wrap_model_call]                lead   - 合并所有 SystemMessage 为一条首条（provider 兜底）
24  SubagentLimit?          [after_model]                    lead?  - 截断超额 task 调用，强制并发上限
25  LoopDetection?          [before_agent, after_model, after_agent, wrap_model_call] lead? - 检测重复 tool-call 循环并硬停
26  TokenBudget?            [before_agent, after_agent, after_model, wrap_model_call] lead? - 每 run token 上限
27  [custom]                [user-defined]                   lead   - 自定义中间件注入点
28  SafetyFinishReason?     [after_model]                    lead?  - provider 安全终止时抑制工具执行
29  Clarification           [wrap_tool_call]                 lead   - 链尾：拦截 ask_clarification，Command(goto=END) 中断
```

**hook 类型分布速览**（一眼看出哪些钩子被哪些项占用）：

- `before_agent`（正序）：3 ThreadData, 4 Uploads, 5 Sandbox, 11 ToolProgress?, 13 DynamicContext, 17 TodoList?(before_agent), 25 LoopDetection?, 26 TokenBudget?
- `before_model`（正序）：15 DurableContext, 16 Summarization?, 17 TodoList?(before_model), 21 ViewImage?
- `wrap_model_call`（洋葱，链首最外）：1 InputSanitization, 2 ToolOutputBudget, 6 DanglingToolCall, 7 LLMErrorHandling, 11 ToolProgress?(wrap_model_call), 14 SkillActivation, 15 DurableContext(wrap_model_call), 17 TodoList?(wrap_model_call), 22 DeferredToolFilter?, 23 SystemMessageCoalescing, 25 LoopDetection?(wrap_model_call), 26 TokenBudget?(wrap_model_call)
- `after_model`（逆序，链尾最先）：15 DurableContext(after_model), 17 TodoList?(after_model), 18 TokenUsage?, 19 Title, 24 SubagentLimit?, 25 LoopDetection?(after_model), 26 TokenBudget?(after_model), 28 SafetyFinishReason?
- `wrap_tool_call`（洋葱，链首最外）：2 ToolOutputBudget, 5 Sandbox, 8 Guardrail?, 9 SandboxAudit, 10 ReadBeforeWrite?, 11 ToolProgress?(wrap_tool_call), 12 ToolErrorHandling, 22 DeferredToolFilter?, 29 Clarification
- `after_agent`（正序）：5 Sandbox, 17 TodoList?(after_agent), 20 Memory, 25 LoopDetection?(after_agent), 26 TokenBudget?(after_agent)

> 注：`base*` = base 段但仅 lead 打开（`include_uploads=True`）；子代理 `include_uploads=False` 跳过该项。`base?` / `lead?` = config 条件可选（`app_config.<feature>.enabled` 闸门）。

---

## 3. 顺序不变量（违反即 bug）

1. **InputSanitization 必须最外层**（index 1）：它在 `outer_wrappers` 首位，所有内层（含 LLM 重试中间件）见消毒后消息。违反后果：LLM 重试中间件先看到未消毒内容，触发提供商级 4xx。
2. **ThreadData 必须在 Sandbox 之前**（3 < 5）：SandboxMiddleware 的 `before_agent` 读 thread_id 建沙箱目录，thread_id 由 ThreadDataMiddleware 注入。违反后果：沙箱目录落到错误位置。
3. **ToolProgress 必须在 ToolErrorHandling 之外**（11 < 12，index 更小）：ToolProgress 的 `wrap_tool_call` 链要包住 ToolErrorHandling 的 `helix_tool_meta` stamping 步骤，否则 ToolProgress 读到未盖 meta 的结果。装配时有 `isinstance` 运行时断言守护（反序 `raise RuntimeError`）。
4. **Summarization 应靠前**（16）：在其他处理前压缩上下文，使后续中间件见的 history 已瘦身。
5. **Title 在 Memory 之前**（19 < 20）：TitleMiddleware 起标题后，MemoryMiddleware 排队含标题的对话进异步记忆更新。
6. **SystemMessageCoalescing 在 DeferredToolFilter 之后**（22 < 23）：合并发生在工具 schema 已过滤、模型调用前的最后一刻。
7. **SafetyFinishReason 注册在 LoopDetection 之后**（25 < 28）：LangChain 逆序 `after_model` 派发使 Safety 先跑、清空安全终止的 tool_calls，Loop 再对清理后消息计数（`safety_finish_reason_middleware.py` docstring 要求 "register after LoopDetection"）。
8. **Clarification 必须永远最后**（29）：`# ClarificationMiddleware should always be last`。它返回 `Command(goto=END)` 中断 run，若不在链尾，后面的 `after_model`（TokenBudget 计量、SafetyFinishReason 清理）会在中断后错过，状态不一致。
9. **custom 中间件在 Clarification 之前、Safety 之后**（27）：自定义中间件注入点固定在 26 与 28 之间，使其既在计量/检测之后（可见最终状态），又在 Clarification 中断之前（不被跳过）。

---

## 4. 关键中间件入口片段

### 4.1 DynamicContextMiddleware（第 13 项，`before_agent` 正序）

> 完整源码见 `[[system-prompt-template]]` 的 [references/code/dynamic-context-and-coalescing.md](../../../system-prompt-template/references/code/dynamic-context-and-coalescing.md)。此处给入口签名 + 与链顺序相关的关键不变量。

```python
# core/helix/agents/middlewares/dynamic_context_middleware.py（入口与不变量，完整实现见 system-prompt-template skill）
class DynamicContextMiddleware(AgentMiddleware):
    """注入记忆与当前日期为 <system-reminder> SystemMessage。

    首轮：在首条 HumanMessage 前插完整 reminder（记忆+日期）并持久化（同一 message id）。
    该首消息对整个会话冻结--内容永不再变，故 prefix cache 在每个后续 turn 命中。
    跨午夜：在当前 HumanMessage 前插轻量日期校正 reminder 并持久化。"""

    def __init__(self, agent_name: str | None = None, *, app_config: "AppConfig | None" = None):
        super().__init__()
        self._agent_name = agent_name
        self._app_config = app_config

    @override
    def before_agent(self, state, runtime: Runtime) -> dict | None:
        return self._inject(state)   # 注：before_agent 正序执行，第 13 项在基座之后跑

    @override
    async def abefore_agent(self, state, runtime: Runtime) -> dict | None:
        # _inject 含同步文件 IO（记忆 JSON 加载）与潜在阻塞网络（tiktoken 首次下载）。
        # 必须卸载到线程，否则阻塞事件循环、饿死所有并发 HTTP handler（鉴权、SSE 心跳等）。
        # 有界 timeout：启动预热静默失败时，首请求冷 tiktoken 下载可阻塞数十分钟。
        try:
            return await asyncio.wait_for(asyncio.to_thread(self._inject, state),
                                          timeout=_INJECT_TIMEOUT_SECONDS)
        except TimeoutError:
            logger.warning("DynamicContextMiddleware: injection timed out (%.1fs); skipping memory/date injection for this turn",
                           _INJECT_TIMEOUT_SECONDS)
            return None   # 注：超时优雅降级返回 None，不阻塞 turn
```

**关键不变量**（与链顺序相关）：
- DynamicContext 在基座（1–12）之后、Summarization（16）之前注入，保证摘要压缩前 reminder 已在历史里。
- 角色分离：日期在 `SystemMessage`（框架权威），记忆在 `HumanMessage`（用户可影响）--记忆永不获得 system 权威（OWASP LLM01）。
- 阻塞 IO 经 `asyncio.to_thread` + 有界超时卸载，超时降级不阻塞事件循环。

### 4.2 SystemMessageCoalescingMiddleware（第 23 项，`wrap_model_call` 洋葱）

> 完整源码见 `[[system-prompt-template]]` 的 [references/code/dynamic-context-and-coalescing.md](../../../system-prompt-template/references/code/dynamic-context-and-coalescing.md)。

```python
# core/helix/agents/middlewares/system_message_coalescing_middleware.py（入口与不变量，完整实现见 system-prompt-template skill）
class SystemMessageCoalescingMiddleware(AgentMiddleware[AgentState]):
    """把所有 SystemMessage 合并为单一首条 SystemMessage。

    用 wrap_model_call（非 before_agent），使合并在最终请求载荷上运行--此时
    system_message 与 messages 仍是分开字段--且永不触碰持久化 state['messages']。
    这使 checkpoint 结构对每个扫描历史的消费者（记忆构造、journal、摘要、动态上下文检测）保持完整。"""

    @override
    def wrap_model_call(self, request: ModelRequest, handler: Callable[[ModelRequest], ModelResponse]) -> ModelCallResult:
        return handler(self._maybe_coalesce(request))   # 注：wrap_model_call 洋葱模型，第 23 项包裹 24-29

    @override
    async def awrap_model_call(self, request: ModelRequest, handler: Callable[[ModelRequest], Awaitable[ModelResponse]]) -> ModelCallResult:
        return await handler(self._maybe_coalesce(request))
```

**关键不变量**：
- 用 `wrap_model_call`（非 `before_agent`）：合并在请求载荷上运行，`state["messages"]` 不变，checkpoint 结构完整。
- 在 DeferredToolFilter（22）之后、SubagentLimit（24）之前：合并发生在工具 schema 已过滤、模型调用前的最后一刻。
- 跨午夜去重：合并后多条 reminder 只保留最新日期那条。

### 4.3 DeferredToolFilterMiddleware（第 22 项，`wrap_model_call` + `wrap_tool_call`，完整）

```python
# core/helix/agents/middlewares/deferred_tool_filter_middleware.py
class DeferredToolFilterMiddleware(AgentMiddleware[AgentState]):
    """在延迟工具被提升前，从绑定的模型隐藏其 schema。

    ToolNode 仍持有所有工具（含延迟）供执行路由，但 LLM 只看到 active 工具
    schema 加已提升工具（记在 state['promoted'] 当前 catalog hash 下）。"""

    def __init__(self, deferred_names: frozenset[str], catalog_hash: str | None):
        super().__init__()
        self._deferred = deferred_names
        self._catalog_hash = catalog_hash

    def _promoted(self, state) -> set[str]:
        promoted = (state or {}).get("promoted")
        if promoted and promoted.get("catalog_hash") == self._catalog_hash:
            return set(promoted.get("names") or [])
        return set()

    def _hidden(self, state) -> set[str]:
        return set(self._deferred) - self._promoted(state)

    def _filter_tools(self, request: ModelRequest) -> ModelRequest:
        if not self._deferred:
            return request
        hide = self._hidden(request.state)
        if not hide:
            return request
        active = [t for t in request.tools if getattr(t, "name", None) not in hide]
        if len(active) < len(request.tools):
            logger.debug("Filtered %d deferred tool schema(s) from model binding", len(request.tools) - len(active))
        return request.override(tools=active)

    def _blocked_tool_message(self, request: ToolCallRequest) -> ToolMessage | None:
        # 防御：模型若仍尝试调延迟工具（如旧 checkpoint 历史），返回 error ToolMessage
        if not self._deferred:
            return None
        name = str(request.tool_call.get("name") or "")
        if not name or name not in self._hidden(request.state):
            return None
        tool_call_id = str(request.tool_call.get("id") or "missing_tool_call_id")
        return ToolMessage(
            content=("Error: Tool '{name}' is deferred and has not been promoted yet. "
                     "Call tool_search first to expose and promote this tool's schema, then retry.").format(name=name),
            tool_call_id=tool_call_id,
            name=name,
            status="error",
        )

    @override
    def wrap_model_call(self, request: ModelRequest, handler: Callable[[ModelRequest], ModelResponse]) -> ModelCallResult:
        return handler(self._filter_tools(request))   # 注：模型绑定前过滤 schema

    @override
    def wrap_tool_call(self, request: ToolCallRequest, handler: Callable[[ToolCallRequest], ToolMessage | Command]) -> ToolMessage | Command:
        blocked = self._blocked_tool_message(request)
        if blocked is not None:
            return blocked
        return handler(request)

    @override
    async def awrap_model_call(self, request: ModelRequest, handler: Callable[[ModelRequest], Awaitable[ModelResponse]]) -> ModelCallResult:
        return await handler(self._filter_tools(request))
```

### 4.4 ClarificationMiddleware（第 29 项，链尾，`wrap_tool_call`，完整）

> 这是跨切不变量 1 的纵深防御落点：即便 `ask_clarification` 未被 `non_interactive` 剥离（如 webhook 通道走 `disable_clarification`），本中间件读 `runtime.context["disable_clarification"]` 决定是中断还是放行。完整源码亦见脊柱 [references/code/05-middleware-chain.md](../../../e2e-request-lifecycle/references/code/05-middleware-chain.md)。

```python
# core/helix/agents/middlewares/clarification_middleware.py
"""拦截澄清请求并呈现给用户的中间件。"""

import json
import logging
from collections.abc import Callable
from hashlib import sha256
from typing import Any, override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import ToolMessage
from langgraph.graph import END
from langgraph.prebuilt.tool_node import ToolCallRequest
from langgraph.types import Command

logger = logging.getLogger(__name__)


class ClarificationMiddlewareState(AgentState):
    """兼容 ThreadState schema。"""
    pass


class ClarificationMiddleware(AgentMiddleware[ClarificationMiddlewareState]):
    """拦截澄清工具调用并中断执行以向用户呈现问题。

    模型调用 ask_clarification 工具时，本中间件：
    1. 执行前拦截工具调用
    2. 抽取澄清问题与元数据
    3. 格式化为用户友好消息
    4. 返回中断执行并呈现问题的 Command
    5. 等用户回复后再继续

    这取代了澄清继续对话流的旧基于工具的方案。
    """

    state_schema = ClarificationMiddlewareState

    def _stable_message_id(self, tool_call_id: str, formatted_message: str) -> str:
        """构建确定性 message ID，使重试的澄清调用替换而非追加。"""
        if tool_call_id:
            return f"clarification:{tool_call_id}"
        digest = sha256(formatted_message.encode("utf-8")).hexdigest()[:16]
        return f"clarification:{digest}"

    def _normalize_options(self, raw_options: Any) -> list[str]:
        """把工具提供的 options 规范化为可展示字符串值。"""
        options = raw_options
        # 某些模型（如 Qwen3-Max）把数组参数序列化为 JSON 字符串而非原生数组。
        # 反序列化并规范化，使 options 总是 list。
        if isinstance(options, str):
            try:
                options = json.loads(options)
            except (json.JSONDecodeError, TypeError):
                options = [options]
        if options is None:
            return []
        if not isinstance(options, list):
            options = [options]
        return [str(option) for option in options]

    def _build_human_input_payload(self, args: dict[str, Any], *, tool_call_id: str, request_id: str) -> dict[str, Any]:
        """构建结构化 UI 载荷，同时保留 ToolMessage.content 作回退。"""
        options = self._normalize_options(args.get("options", []))
        clarification_type = str(args.get("clarification_type", "missing_info"))
        payload: dict[str, Any] = {
            "version": 1,
            "kind": "human_input_request",
            "source": "ask_clarification",
            "request_id": request_id,
            "clarification_type": clarification_type,
            "question": str(args.get("question") or ""),
            "input_mode": "choice_with_other" if options else "free_text",
        }
        if tool_call_id:
            payload["tool_call_id"] = tool_call_id
        if "context" in args:
            context = args.get("context")
            payload["context"] = None if context is None else str(context)
        if options:
            payload["options"] = [
                {"id": f"option-{index}", "label": option, "value": option}
                for index, option in enumerate(options, 1)
            ]
        return payload

    def _format_clarification_message(self, args: dict) -> str:
        """把澄清参数格式化为用户友好消息。"""
        question = args.get("question", "")
        clarification_type = args.get("clarification_type", "missing_info")
        context = args.get("context")
        options = self._normalize_options(args.get("options", []))
        type_icons = {
            "missing_info": "❓",
            "ambiguous_requirement": "🤔",
            "approach_choice": "🔀",
            "risk_confirmation": "⚠️",
            "suggestion": "💡",
        }
        icon = type_icons.get(clarification_type, "❓")
        message_parts = []
        if context:
            message_parts.append(f"{icon} {context}")
            message_parts.append(f"\n{question}")
        else:
            message_parts.append(f"{icon} {question}")
        if options and len(options) > 0:
            message_parts.append("")
            for i, option in enumerate(options, 1):
                message_parts.append(f"  {i}. {option}")
        return "\n".join(message_parts)

    def _is_disabled(self, request: ToolCallRequest) -> bool:
        """本次 run 是否抑制澄清。

        非交互通道（如 GitHub webhook）在 run context 设 disable_clarification，
        因为澄清会让 run 死胡同--人只通过后续 webhook 投递"回复"，此时 agent 的
        turn 早已结束。设置时不中断；返回 ToolMessage 推动 agent 用最佳判断继续。

        注：这是跨切不变量 1 的纵深防御落点。non_interactive 在 ④建图剥离
        ask_clarification 工具（主防线）；disable_clarification 在本中间件放行
        已调用的 ask_clarification（webhook 通道旁路）。两者覆盖不同通道。
        """
        runtime = getattr(request, "runtime", None)
        context = getattr(runtime, "context", None)
        if not context:
            return False
        return bool(context.get("disable_clarification"))

    def _handle_disabled_clarification(self, request: ToolCallRequest) -> ToolMessage:
        """抑制澄清并告知 agent 继续。

        返回普通 ToolMessage（非 Command(goto=END)），使 agent 循环继续而非结束--
        agent 收到它作为工具结果再次生成，理想地行动而非重问。
        """
        tool_call_id = request.tool_call.get("id", "")
        logger.info("ask_clarification suppressed (disable_clarification set); instructing agent to proceed")
        return ToolMessage(
            id=self._stable_message_id(tool_call_id, "proceed-without-clarification"),
            content=(
                "Clarification is disabled in this context - the human is not present "
                "to answer synchronously. Do not ask for confirmation. Proceed with your "
                "best judgment, carry out the requested action, and state any assumptions "
                "you made in your final response."
            ),
            tool_call_id=tool_call_id,
            name="ask_clarification",
        )

    def _handle_clarification(self, request: ToolCallRequest) -> Command:
        """处理澄清请求，返回中断执行的 command。"""
        args = request.tool_call.get("args", {})
        question = args.get("question", "")
        logger.info("Intercepted clarification request")
        logger.debug("Clarification question: %s", question)
        formatted_message = self._format_clarification_message(args)
        tool_call_id = request.tool_call.get("id", "")
        request_id = self._stable_message_id(tool_call_id, formatted_message)
        human_input_payload = self._build_human_input_payload(args, tool_call_id=tool_call_id, request_id=request_id)
        # 创建带格式化问题的 ToolMessage，加入消息历史
        tool_message = ToolMessage(
            id=request_id,
            content=formatted_message,
            tool_call_id=tool_call_id,
            name="ask_clarification",
            artifact={"human_input": human_input_payload},   # 前端 Human Input Card 载荷
        )
        # 返回 Command：1) 加格式化 tool 消息 2) goto __end__ 中断执行
        # 注：不加额外 AIMessage--前端直接检测并展示 ask_clarification tool 消息
        return Command(
            update={"messages": [tool_message]},
            goto=END,
        )

    @override
    def wrap_tool_call(self, request: ToolCallRequest,
                       handler: Callable[[ToolCallRequest], ToolMessage | Command]) -> ToolMessage | Command:
        """拦截 ask_clarification 工具调用并中断执行（同步版）。"""
        if request.tool_call.get("name") != "ask_clarification":
            return handler(request)                                  # 非澄清：正常执行
        if self._is_disabled(request):
            return self._handle_disabled_clarification(request)      # 注：disable_clarification 通道：转普通 ToolMessage 继续
        return self._handle_clarification(request)                   # 注：默认：Command(goto=END) 中断

    @override
    async def awrap_tool_call(self, request: ToolCallRequest,
                              handler: Callable[[ToolCallRequest], ToolMessage | Command]) -> ToolMessage | Command:
        """拦截 ask_clarification 工具调用并中断执行（异步版）。"""
        if request.tool_call.get("name") != "ask_clarification":
            return await handler(request)
        if self._is_disabled(request):
            return self._handle_disabled_clarification(request)
        return self._handle_clarification(request)
```

---

## 关联

- 装配完整源码（base + lead-only 双段）：[build-middlewares.md](./build-middlewares.md)
- 脊柱 ⑤跳同一份链顺序清单 + 关键片段：[../../../e2e-request-lifecycle/references/code/05-middleware-chain.md](../../../e2e-request-lifecycle/references/code/05-middleware-chain.md)
- DynamicContext + Coalescing 完整源码：`[[system-prompt-template]]` 的 references/code/dynamic-context-and-coalescing.md
- 关联 skill：`[[e2e-request-lifecycle]]`（⑤中间件 链路位置）、`[[system-prompt-template]]`（动态注入与合并）、`[[context-window-management]]`（Summarization + LoopDetection + TokenBudget）、`[[safety-and-guardrails]]`（Guardrail + InputSanitization + SafetyFinishReason）、`[[subagent-delegation]]`（子代理基座）、`[[thread-state-and-reducers]]`（state 字段写权）
