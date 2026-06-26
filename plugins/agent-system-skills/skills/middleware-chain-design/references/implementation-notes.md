# Implementation Notes — middleware-chain-design

> 适用范围：LangChain ≥ 1.x `AgentMiddleware` 组合的中间件链架构。
> 涉及钩子：`before_agent` / `wrap_model_call` / `after_model` / `wrap_tool_call` / `after_agent`。
> 关联：[[agent-graph-factory]]（装配入口）、[[thread-state-and-reducers]]（状态契约）。

---

## 1. 组件矩阵

| 通用组件名 | 真实职责 | 关键 API / 触发钩子 |
|---|---|---|
| `AgentMiddleware[StateT]` | 中间件基类，定义所有钩子 | 子类按需 override；未 override 的钩子直接透传 |
| `before_agent / abefore_agent` | 进入图前一次性预处理 | 返回 `dict | None`，dict 会以 reducer 形式合并入 state |
| `wrap_model_call / awrap_model_call` | 包裹模型调用 | 接收 `ModelRequest`，返回 `ModelResponse`；**注册顺序 = 由外向内** |
| `after_model / aafter_model` | 模型返回后处理 | LangChain **反序派发**（最后注册者最先执行） |
| `wrap_tool_call / awrap_tool_call` | 包裹单次工具执行 | 处理 `ToolCallRequest`；可短路返回 `ToolMessage` 或 `Command` |
| `after_agent / aafter_agent` | 图退出前钩子 | 用于清理瞬态资源（如 pending warning） |
| 共享 base builder | 输出多 agent 共用的中间件序列 | 通过开关参数控制 uploads / dangling tool patch / vision 等 |
| Lead-only builder | 在 base 之上追加 lead-agent 专属中间件 | 注入 dynamic context / skill activation / title / memory 等 |
| `Command(goto=END, update=…)` | 中间件跳出图的官方机制 | 常见于澄清中间件、`SafetyFinishReason` 强制终止 |

### 典型职责分层

| 层 | 中间件示例 | 必须性 |
|---|---|---|
| 输入清洗 | input sanitization、tool output budget | 始终最外层 |
| 上下文/资源装配 | thread data、uploads、sandbox 创建、dangling tool patch | base 必备 |
| 错误归一化 | LLM error handling、tool error handling | base 必备 |
| 安全/审计 | guardrail、sandbox audit | base 可选 |
| 动态上下文 | dynamic context（日期/记忆）、skill activation | lead 必备 |
| 上下文压缩 | summarization | 可选 |
| 任务编排 | todo list、subagent limit、loop detection | 按 runtime 开关 |
| 计量 | token usage、token budget | 可选 |
| 元信息 | title generation、memory queue、view image | 按模型能力 |
| 协议矫正 | deferred tool filter、system message coalescing、safety finish reason | 必备 |
| 出口拦截 | clarification | **永远最后一个** |

---

## 2. 关键调用时序

### 时序 A：单次消息穿越完整链

```
state, config → graph.invoke
  step 1: before_agent 链（按注册顺序）
            └─ dynamic_context、skill_activation 等返回 partial state
                  → reducer 合并进 state
  step 2: model 节点
            └─ wrap_model_call 链（外→内）
                  input_sanitization → tool_output_budget → … → coalescing
                                                                  → 真实模型
            └─ after_model 链（反序派发：注册晚的先执行）
                  safety_finish_reason → loop_detection → subagent_limit → token_usage → …
  step 3: tools 节点（若有 tool_calls）
            └─ wrap_tool_call 链
                  guardrail → sandbox_audit → tool_error_handling → 真实工具
  step 4: 循环回 step 2 直到无 tool_calls 或被 Command(goto=END) 截停
  step 5: after_agent 链（按注册顺序）
            └─ loop_detection 清理 pending warnings 等
```

### 时序 B：澄清中间件的“最后注册 + 反序优先”

```
模型产出 ask_clarification tool_call
  → 所有 after_model 中间件按反序处理：
       clarification（最后注册 → 反序最先执行）
         └─ 识别到 ask_clarification → 返回 Command(goto=END, update={...})
  → 链路提前退出，永远不会执行后续 tool 节点
```

### 时序 C：错误归一化与 GraphBubbleUp

```
工具函数抛出业务异常
  → wrap_tool_call 链外层（tool_error_handling）catch Exception
      → 转换为 ToolMessage(status="error", content="Error: Tool 'X' failed …")
      → 链路继续，模型在下一轮看到错误消息

工具函数抛出 GraphBubbleUp（LangGraph 控制信号）
  → except GraphBubbleUp: raise          # 必须原样重新抛出
  → 由 LangGraph 处理 interrupt / pause / resume
```

---

## 3. 数据契约 / 类型签名

```python
from typing import Protocol, override
from collections.abc import Awaitable, Callable
from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelRequest, ModelResponse, ModelCallResult
from langchain_core.messages import ToolMessage
from langgraph.prebuilt.tool_node import ToolCallRequest
from langgraph.runtime import Runtime
from langgraph.types import Command
from langgraph.errors import GraphBubbleUp

class MyMiddleware(AgentMiddleware[AgentState]):
    @override
    def before_agent(self, state, runtime: Runtime) -> dict | None: ...

    @override
    async def abefore_agent(self, state, runtime: Runtime) -> dict | None: ...

    @override
    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelCallResult:
        return handler(request)

    @override
    def after_model(self, state, runtime: Runtime) -> dict | None: ...

    @override
    def wrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], ToolMessage | Command],
    ) -> ToolMessage | Command:
        try:
            return handler(request)
        except GraphBubbleUp:
            raise               # 控制信号必须透传
        except Exception as exc:
            return ToolMessage(content=f"Error: {exc}",
                               tool_call_id=request.tool_call["id"],
                               status="error")

# 共享 builder 协议
def build_runtime_middlewares(
    *,
    app_config,
    include_uploads: bool,
    include_dangling_tool_call_patch: bool,
    lazy_init: bool = True,
) -> list[AgentMiddleware]: ...
```

---

## 4. 关键不变量

1. **`wrap_model_call` 注册顺序 = 由外向内** — 注册靠前者最先看到 request。违反后果：输入清洗类中间件被放在尾部，导致 LLM 重试中间件先看到未清洗内容，触发提供商级 4xx。
2. **`after_model` 派发顺序与注册相反** — 注册最后者最先执行。违反后果：澄清/安全类中间件若不放最后，无法抢先短路。
3. **澄清中间件永远是链末** — 它要在所有其他 after_model 后接管控制流。违反后果：tool_call 被其他中间件改写后再触发 `Command(goto=END)`，状态不一致。
4. **`wrap_tool_call` 必须透传 `GraphBubbleUp`** — 否则 interrupt / human-in-the-loop 失效。违反后果：人工确认机制静默失败。
5. **`before_agent` 不得做不可重入的副作用** — checkpoint resume 时会再跑一次。违反后果：每次重启重复扣费、重复创建沙盒。
6. **同一字段只能由一个中间件唯一写** — 多中间件并发写需通过 reducer。违反后果：参考 [[thread-state-and-reducers]] 的字段覆盖问题。
7. **异步钩子必须 offload 阻塞 I/O** — 用 `asyncio.to_thread(...)` + `asyncio.wait_for(timeout)`。违反后果：事件循环被阻塞，并发请求全部停顿。
8. **`wrap_model_call` 不可修改 `state["messages"]`** — 它只能用 `request.override(...)` 改本次请求负载。违反后果：checkpoint 被污染，后续消息历史不可信。
9. **每个中间件应当幂等可重试** — LangGraph 在 superstep 重放时会再次进入。违反后果：日志/计费/告警重复触发。
10. **`after_agent` 仅做清理** — 它在图退出时执行，不能依赖图继续运行。违反后果：清理结果作为 state 更新写回，造成幽灵字段。

---

## 5. 常见踩坑

1. **把澄清中间件放在 token_usage 之前** — `Command(goto=END)` 跳出后 token 计量丢失。修复：澄清固定放末尾，统计中间件放前面。
2. **`wrap_model_call` 里直接修改 `request.messages` 列表** — 引用语义导致后续中间件也看到修改，链路顺序错乱。修复：永远 `request.override(messages=new_list)`。
3. **`before_agent` 做沙盒创建未幂等** — 重放时启动两次容器。修复：先 `state.get("sandbox")` 判存在再创建。
4. **`after_model` 抛异常被吞掉** — 整轮静默失败。修复：所有 `after_model` 实现里 `try/except` 必须 `logger.exception` 后决定是否吞。
5. **同步 hook 里调用 `asyncio.run`** — LangGraph 异步运行时会撞嵌套事件循环。修复：用 `run_in_executor` 或拆成独立线程。
6. **中间件之间用全局变量传状态** — 测试串扰、多 thread 数据交叉。修复：状态走 `ThreadState` 字段或 `runtime.context`。
7. **`wrap_tool_call` 截到 `Command` 返回也去拼装 `ToolMessage`** — `Command` 是控制流，二次包装会破坏 LangGraph 跳转。修复：先 `isinstance(result, ToolMessage)` 再处理。
8. **新增中间件忘记同时给 sync 和 async 版本** — 在 LangGraph 异步路径下被跳过。修复：基类提供成对实现，async 版本默认 `await asyncio.to_thread(self.sync_impl, …)`。
9. **`build_lead_middlewares` 在 builder 之外又追加同名中间件** — 重复执行造成两次写回。修复：builder 输出后用 `set(map(type, mws))` 校验唯一。
10. **依赖中间件相对位置写死索引** — 一旦插入新中间件就错位。修复：通过类名查找 `next(i for i,m in enumerate(mws) if isinstance(m, X))`。

---

## 6. 调参旋钮 + 调试入口

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `lazy_init` | builder 参数 | 沙盒等重型中间件首次使用时初始化 |
| `include_uploads / include_dangling_tool_call_patch` | builder 参数 | 区分 lead vs subagent |
| `safety_finish_reason.enabled` | app config | 是否启用提供商内容过滤防护 |
| `loop_detection.warn_threshold / hard_limit / window_size` | app config | 重复工具调用阈值 |
| `tool_search.enabled` | app config | 是否启用 MCP 工具延迟绑定 |
| `summarization.trigger / keep` | app config | 上下文压缩阈值 |
| `token_budget.enabled` | app config | 每 run 总预算控制 |

**关键日志串**：

- `Tool execution failed (sync): name=… id=…` / `(async)` — `wrap_tool_call` 兜底分支。
- `LoopDetection: hard-stop forcing final answer` — 工具重复触顶。
- `Safety termination detected: finish_reason=…` — 提供商安全策略截断。
- `Summarization: <N> messages → summary tokens=…` — 上下文压缩落地。
- `DynamicContext: midnight crossing detected` — 跨日重注入。
- `Clarification: redirecting to END` — 澄清中断。

**测试方向**：

- 排序契约：mock 三个中间件 A/B/C，断言 `wrap_model_call` 调用顺序 A→B→C，`after_model` 派发 C→B→A。
- 短路：澄清中间件返回 `Command(goto=END)`，断言后续工具节点不被触发。
- 错误归一化：工具函数 `raise ValueError("boom")` → 期望 `ToolMessage(status="error")`，且链路继续。
- `GraphBubbleUp` 透传：工具抛 `GraphBubbleUp` → 必须重新抛出，不能被 except 吞。
- async I/O 不阻塞：注册一个故意 sleep 的 `before_agent`，断言 `abefore_agent` 走 `to_thread`。
- 字段唯一写权：两个中间件都写 `title` → 应通过测试断言只一个生效，或显式 reducer。

---

相关 skill：[[agent-graph-factory]] · [[thread-state-and-reducers]] · [[context-window-management]] · [[safety-and-guardrails]] · [[tool-assembly-and-policy]]
