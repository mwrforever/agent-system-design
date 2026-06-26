# Implementation Notes — agent-graph-factory

> 与 SKILL.md 同步维护。术语对齐通用 LangGraph 栈；不引用任何宿主项目的真实路径。
> 适用范围：基于 `langchain.agents.create_agent` + `langgraph` 的图工厂层。

---

## 1. 组件矩阵

| 通用组件名 | 真实职责 | 关键 API / 签名 |
|---|---|---|
| `make_lead_agent(config)` | LangGraph 图工厂入口；注册在 `langgraph.json` 的 `graphs` 字段，被 LangGraph Server / Studio / Embedded Client 共用 | `def make_lead_agent(config: RunnableConfig) -> CompiledGraph` — **签名固定**，业务参数全部走 `config.configurable` / `config.context` |
| `_get_runtime_config(config)` | 双通道运行时参数合并器 | 合并 `config["configurable"]` 与 `config["context"]`，后者覆盖前者（LangGraph ≥ 1.1 推荐顺序） |
| `_resolve_model_name(req, app_config)` | 模型三段降级解析 | 请求 model > agent 配置 model > 全局默认 model；未知名称只 warning 不抛错 |
| `load_agent_config(agent_name)` | 自定义 agent 元数据装载 | 返回 `AgentConfig(model, skills, tool_groups)`，`is_bootstrap=True` 时跳过 |
| `build_middlewares(config, …)` | 中间件链装配（见 [[middleware-chain-design]]） | 必须接收 `app_config / model_name / agent_name / available_skills / deferred_setup / custom_middlewares` |
| `apply_prompt_template(…)` | 静态系统提示渲染（见 [[system-prompt-template]]） | 输出**纯静态**字符串；动态部分由 `DynamicContextMiddleware` 注入 |
| `get_available_tools(…)` | 工具装配（见 [[tool-assembly-and-policy]]） | 按 `groups / model_name / subagent_enabled / app_config` 过滤 |
| `assemble_deferred_tools(filtered, enabled)` | MCP 工具延迟绑定切分 | 返回 `(final_tools, DeferredToolSetup)`；`DeferredToolSetup.deferred_names` 喂给 `DeferredToolFilterMiddleware` |
| `create_chat_model(name, …, attach_tracing=False)` | 模型工厂；图根模型必须传 `attach_tracing=False` | 见“关键不变量 #1” |
| `build_tracing_callbacks()` | 返回 LangSmith / Langfuse handler 列表 | **必须挂在图根** `config["callbacks"]`，详见 [[observability-tracing]] |
| `create_agent(model, tools, middleware, system_prompt, state_schema)` | LangChain 1.x 图构造器 | `state_schema` 必须是带 reducers 的 `TypedDict`（见 [[thread-state-and-reducers]]） |

### 配置双通道映射

| 字段 | configurable | context | 说明 |
|---|---|---|---|
| `thread_id` | ✓ | ✓ | 两边必须一致 |
| `model_name` / `model` | ✓ | ✓ | 请求覆盖 agent 配置 |
| `thinking_enabled` | ✓ | ✓ | 低版本 LangGraph 只读 `configurable` |
| `reasoning_effort` | ✓ | ✓ | 新增字段优先放 `context` |
| `is_plan_mode` | ✓ | ✓ | LangGraph ≥ 1.1 的 `ToolRuntime` 只看 `context` |
| `subagent_enabled` / `max_concurrent_subagents` | ✓ | ✓ | 默认 3，需透传至 prompt 渲染与 `SubagentLimitMiddleware` |
| `agent_name` | ✓ | ✓ | `validate_agent_name` 强校验，决定 SOUL.md 与 per-agent memory |
| `is_bootstrap` | ✓ | ✓ | 引导模式：只暴露 `setup_agent` 工具与最小 skill 集 |
| `app_config` | ✓ | ✓ | 显式注入 `AppConfig` 优先于全局单例 |

---

## 2. 关键调用时序

### 时序 A：冷启动（首次请求进入图工厂）

```
Client / Server
  └─> make_lead_agent(config)
        ├─ _get_runtime_config(config)            # 合并双通道
        ├─ _resolve_model_name(…)                 # 三段降级 + warning
        ├─ load_agent_config(agent_name)          # 若非 bootstrap
        ├─ _available_skill_names(agent_config, is_bootstrap)
        ├─ config["metadata"].update({...})       # 注入 trace tag
        ├─ config["callbacks"] += build_tracing_callbacks()  # 图根挂载
        ├─ _load_enabled_skills_for_tool_policy(…)
        ├─ get_available_tools(…) + filter_tools_by_skill_allowed_tools(…)
        ├─ assemble_deferred_tools(filtered, enabled=cfg.tool_search.enabled)
        │     → (final_tools, deferred_setup)
        ├─ create_chat_model(name, attach_tracing=False)
        ├─ build_middlewares(config, …, deferred_setup=…)
        ├─ apply_prompt_template(…, deferred_names=setup.deferred_names)
        └─ create_agent(model, tools, middleware, system_prompt, state_schema=ThreadState)
```

### 时序 B：单次消息执行（图根之后）

```
runtime.stream / invoke(graph, state, config)
  └─ before_agent 链（按声明正序）
       └─ DynamicContextMiddleware._inject  → 注入 <current_date> / <memory>
  └─ model 调用
       └─ wrap_model_call 链（**反序**穿越，最先声明者最外层）
           └─ InputSanitization → ToolOutputBudget → … → SystemMessageCoalescing → 真实模型
  └─ after_model 链（**反序**穿越）
       └─ Safety → LoopDetection → SubagentLimit → …
  └─ tools 节点
       └─ wrap_tool_call 链
           └─ Guardrail → SandboxAudit → ToolErrorHandling → 真实工具
  └─ after_agent 链（按声明正序）
```

### 时序 C：状态写回与 reducers

```
node returns dict (或 Command(update=...))
  └─ langgraph 应用 state_schema 上的 reducer：
       messages → add_messages
       sandbox  → merge_sandbox（id 冲突即抛错）
       artifacts → merge_artifacts（去重）
       todos    → merge_todos（最后非 None 覆盖）
       viewed_images → merge_viewed_images（空 dict 表示清空）
       promoted → merge_promoted（按 catalog_hash 分代）
```

---

## 3. 数据契约 / 类型签名

```python
from typing import TypedDict, NotRequired, Annotated, Protocol
from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain_core.runnables import RunnableConfig

# 1) 图工厂入口签名（对外冻结）
def make_lead_agent(config: RunnableConfig): ...

# 2) 中间件构造器签名（embedded client / lead agent 共享）
def build_middlewares(
    config: RunnableConfig,
    model_name: str | None,
    agent_name: str | None = None,
    custom_middlewares: list[AgentMiddleware] | None = None,
    *,
    available_skills: set[str] | None = None,
    app_config: "AppConfig" | None = None,
    deferred_setup: "DeferredToolSetup | None" = None,
) -> list[AgentMiddleware]: ...

# 3) 工具延迟绑定的产物
class DeferredToolSetup(Protocol):
    deferred_names: frozenset[str]
    catalog_hash: str

# 4) 工厂内部解析出的运行时上下文
class RuntimeCtx(TypedDict, total=False):
    thinking_enabled: bool
    reasoning_effort: str | None
    model_name: str | None
    is_plan_mode: bool
    subagent_enabled: bool
    max_concurrent_subagents: int
    is_bootstrap: bool
    agent_name: str | None
    app_config: object | None
```

---

## 4. 关键不变量

1. **图根 tracing 挂载唯一化** — `build_tracing_callbacks()` 仅在工厂内、`create_agent` 之前追加到 `config["callbacks"]`；所有 `create_chat_model` 调用必须 `attach_tracing=False`。违反后果：每条消息双重 span，`session_id` / `user_id` 丢失，Langfuse 看板对账错乱。
2. **`make_lead_agent` 签名永久冻结为 `(config)`** — 业务参数走 `config.configurable / context`。违反后果：LangGraph Server 注册时签名校验失败，图无法被外部 SDK 调起。
3. **`build_middlewares` 是跨模块边界的稳定名称** — Embedded Client 直接 import 该名称。违反后果：重命名 / 改签名会同时打断 Server 与 Client 双路。
4. **`_resolve_model_name` 必须 fallback，不可抛错** — 未知模型只发 warning 后降级。违反后果：旧 thread 历史里残留的已删除模型名会导致整个 thread 不可恢复。
5. **`agent_name` 必须先过 `validate_agent_name`** — 防止注入文件系统路径片段。违反后果：自定义 agent 路由可被诱导读写任意目录。
6. **`is_bootstrap=True` 时 skill 集必须收窄到最小白名单** — 避免引导阶段被任意 skill 提前激活。违反后果：自定义 agent 创建流程不再确定，产物难以复现。
7. **`deferred_setup` 必须同时喂 `build_middlewares` 与 `apply_prompt_template`** — 二者用同一 `catalog_hash` 校对。违反后果：prompt 提示的延迟工具与运行时白名单不一致，模型反复尝试不存在的工具。
8. **`state_schema=ThreadState`** — 不可省略，否则 reducers 不生效。违反后果：状态字段被 LangGraph 当成 `Last-Write-Wins`，artifacts/promoted 等会被静默覆盖。

---

## 5. 常见踩坑

1. **把 `thinking_enabled` 默认值放在工厂外** — 不同入口默认值不一致，行为飘忽。修复：默认值集中在 `_get_runtime_config` 后的 `cfg.get(..., default)` 上。
2. **`create_chat_model` 漏传 `attach_tracing=False`** — 出现双 span。修复：在工厂模块顶部用 `INVARIANT` 注释枚举所有图内模型构造点，新增点必须同步更新。
3. **`config["metadata"]` 直接赋值而非 `update`** — 覆盖了上游 server 注入的 `langfuse_session_id` 等。修复：`if "metadata" not in config: config["metadata"] = {}` 然后 `update`。
4. **`config["callbacks"]` 用 `=` 直接覆盖** — 丢失 LangGraph 自己注册的 streaming 回调。修复：`existing = list(config.get("callbacks") or []); config["callbacks"] = [*existing, *new]`。
5. **`make_lead_agent` 内部抛 `ValueError`** — 工厂异常会被 LangGraph 包装成 `GraphRecursionError` 的子句，难以排查。修复：抛业务异常前 `logger.exception` 一次，并保留原始 message。
6. **`assemble_deferred_tools` 在工具过滤之前调用** — 错把被策略禁掉的 MCP 工具放进 deferred 集，结果 prompt 提示了但无法 promote。修复：永远 `filter → assemble`，顺序不可逆。
7. **`available_skills` 用 `list` 不用 `set`** — 大量 `in` 检查退化为 O(n)；同时 prompt 缓存 key 不稳定。修复：构造时统一 `set()` 或 `frozenset()`。
8. **自定义 agent 模型未通过 `_resolve_model_name`** — 直接传给 `create_chat_model` 导致未知模型即崩溃。修复：所有外部输入模型名都先过一次解析器。
9. **`load_agent_config` 失败时返回 None 但下游未守护** — 触发 `AttributeError: NoneType has no 'tool_groups'`。修复：`agent_config.tool_groups if agent_config else None`。

---

## 6. 调参旋钮 + 调试入口

| 旋钮 | 默认 | 入口 | 说明 |
|---|---|---|---|
| `thinking_enabled` | `True` | `config.configurable` | 模型不支持则自动降级 |
| `reasoning_effort` | `None` | `config.configurable` | 仅对支持的模型有效 |
| `model_name` | `app_config.models[0].name` | `config.configurable.model_name` | 未知名 fallback |
| `is_plan_mode` | `False` | `config.configurable` | 控制 `TodoMiddleware` 启停 |
| `subagent_enabled` | `False` | `config.configurable` | 同步影响 prompt 与 `SubagentLimitMiddleware` |
| `max_concurrent_subagents` | `3` | `config.configurable` | 一次响应内最大 `task` 调用数 |
| `is_bootstrap` | `False` | `config.configurable` | 引导模式开关 |

**关键日志串**（建议在排障时 grep）：

- `Create Agent(<agent_name>) -> thinking_enabled=… model_name=…` — 工厂每次创建都会打这一行，定位“图按什么参数装配”。
- `Model '<name>' not found in config; fallback to default model …` — 模型降级路径。
- `Thinking mode is enabled but model … does not support it; fallback …` — 自动关 thinking。
- `Failed to load skills for allowed-tools policy` — skill 加载失败但允许策略空 → 工具全开，需告警。

**测试方向**（最小用例集）：

- 双通道字段优先级：`configurable.model_name=A`、`context.model_name=B` → 预期使用 B。
- 未知模型降级：`model_name="ghost"` → 调用应成功且返回默认模型工厂结果。
- bootstrap 隔离：`is_bootstrap=True` → 工具集仅含 `setup_agent`；`available_skills` 等于 bootstrap 白名单。
- tracing 唯一性：mock `build_tracing_callbacks`，断言图根 `config["callbacks"]` 包含 handler 且 `create_chat_model` 全部 `attach_tracing=False`。
- 自定义 agent 路由：`agent_name` 含 `..` / 路径分隔符 → 必须被 `validate_agent_name` 拒绝。
- deferred 工具一致性：assemble 后 prompt 中的 `<available-deferred-tools>` 与 `DeferredToolFilterMiddleware` 持有的 `deferred_names` 集合完全相等。

---

相关 skill：[[middleware-chain-design]] · [[thread-state-and-reducers]] · [[system-prompt-template]] · [[tool-assembly-and-policy]] · [[observability-tracing]]
