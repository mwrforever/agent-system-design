---
name: agent-graph-factory
description: LangGraph agent 的图工厂与装配设计：make_lead_agent（LangGraph Server ABI，每 run 重建）、assemble_lead_agent 装配主体（模型解析→授权→工具→中间件→提示词→create_agent 一次绑定）、configurable×context 双通道协议、create_helix_agent SDK 纯参数工厂与 RuntimeFeatures/@Next/@Prev 锚点、装配描述符（可比较 hash 投影）、bootstrap 与 webhook 特殊分支。当要写 graph factory、规范双通道字段、排查"工具/中间件拿不到 context 值"、"tracing session_id 丢失"、"装配不一致"时使用。
---

# 图工厂与 Agent 装配

## 何时用

- 写 `make_xxx_agent(config: RunnableConfig)` 这类 LangGraph 图工厂，或决定"图该单例缓存还是每 run 重建"
- 规范 `configurable` × `context` 双通道字段写法；排查中间件/工具拿不到 `non_interactive`/`user_id`/`agent_name`
- 需要 SDK 层纯参数装配（`RuntimeFeatures` + `@Next`/`@Prev` 声明式定位）而非 config 驱动
- 排查 tracing `session_id` 丢失、token 双倍计费（callback 挂错位置）
- 为自定义 agent（SOUL.md / tool_groups）或 webhook 通道做装配裁剪

## 设计方案（为什么这么设计）

### 1. 每 run 重建，工厂无状态

模型、工具集、中间件链、系统提示词都随请求漂移：不同 `model_name`/`agent_name`/`is_plan_mode`/`is_bootstrap`、per-user 技能白名单、`non_interactive` 剥离 `ask_clarification`、webhook 通道扣留 `update_agent`。缓存编译结果会让同一进程跨用户共享这些差异，破坏隔离。

冷启动开销靠两层抵消，而非缓存图：
- **prefix cache**：系统提示词是纯静态模板，跨用户字节级一致（见 [[system-prompt-template]]）
- **工厂内只读派生量缓存**：技能签名 LRU、延迟工具 catalog hash 等——缓存的是派生数据，不是图

### 2. 装配主体（`assemble_lead_agent` → `_assemble_lead_agent`）

固定顺序一次绑定：合并双通道 cfg → 解析 user_id（config 注入优先，contextvar 兜底）→ 三段降级解析模型（请求 > agent 配置 > 全局默认；未知名仅 warning 降级，不抛错——旧 thread 历史里的已删除模型名不能让 thread 不可恢复）→ 注入 trace metadata（update 不覆盖）→ **tracing callbacks 挂图根 `config["callbacks"]` 并追加不覆盖** → 加载技能 → 装配工具（`get_available_tools` → 技能白名单过滤 → `apply_tool_authorization` → `non_interactive` 剥离 → `assemble_deferred_tools` 延迟切分 → 追加 `describe_skill`）→ `build_middlewares` 组链 → `apply_prompt_template` 渲染静态提示词 → `create_agent(model, tools, middleware, system_prompt, state_schema=ThreadState)`。

工具步骤与提示词步骤共享同一份 `deferred_setup.deferred_names`——否则 prompt 宣告的工具与运行时白名单不一致，模型会反复调用不存在的工具。

装配产物是冻结 dataclass `LeadAgentAssembly(graph, descriptor, effective_model)`；消费方一律经 `unwrap_agent_graph()` 解包，不直接摸图。

### 3. 双通道分离（`configurable` vs `context`）

| 通道 | 生命周期 | 进 checkpoint | 典型字段 |
|---|---|---|---|
| `configurable` | 启动期定型 | **是** | model_name / agent_name / is_bootstrap / is_plan_mode / thinking_enabled |
| `context` | 每 run 变化 | 否 | thread_id / run_id / user_id / non_interactive / github_token / channel_name |

网关侧三组 frozenset 精确管控（`gateway/services.py:726/744/803`）：整形字段双写两通道；`non_interactive`/`interaction_mode` 仅内部调用方；`github_token`/`disable_clarification`/`channel_name` 只写 `context`。worker 在调工厂前把 `context` 安装为 `runtime.context`。工厂侧 `_get_runtime_config` 合并两通道成统一读取视图（context 覆盖 configurable）。

### 4. tracing 挂图根不变量

模块顶部 `INVARIANT` 注释（agent.py 第 3 行起）规定：`build_tracing_callbacks()` 只在工厂内、`create_agent` 之前追加到 `config["callbacks"]`；图内所有 `create_chat_model(...)` 必须 `attach_tracing=False`。挂错到模型上会产生双重 span、`langfuse_session_id` 提升失败、token 双倍计费。新增建模点必须同步更新该注释。

### 5. checkpoint 模式冻结

`freeze_checkpoint_channel_mode("full"|"delta")` 进程级冻结检查点通道模式，`ensure_checkpoint_mode_compatible` 做 fail-closed 兼容门——混模式进程直接拒绝，避免 delta/full 检查点互读损坏。

### 6. 两个特殊分支

- **bootstrap**（`is_bootstrap=True`）：技能集收窄到 `{"bootstrap"}`，只暴露 `setup_agent`（无 `update_agent`），保证自定义 agent 尚不存在时创建流程确定可复现。
- **webhook 扣留 `update_agent`**：`_WEBHOOK_CHANNELS = {"github"}`。webhook 提示来自任意外部评论者，暴露该工具等于让评论者永久改写 agent 的 tool_groups/SOUL.md/model。

### 7. SDK 纯参数工厂（`create_helix_agent`）

不读 config、不吃 RunnableConfig，只收参数（model/tools/system_prompt/middleware/features）。`RuntimeFeatures` 是三态 feature flag（`True` 内置默认 / `False` 禁用 / 自定义 `AgentMiddleware` 实例替换），`@Next(anchor)`/`@Prev(anchor)` 让外部中间件声明相对定位，`_insert_extra` 迭代解析锚点。装配精简 18 项链（lead 链是另一套全量装配，见 [[middleware-chain-design]]），供子代理/测试/SDK 复用。两个工厂互不委托。

### 8. 装配描述符

`assembly_descriptor.py` 把装配结果投影为**可比较的 hash 描述符**（不拷贝对象），用于诊断"同一配置为何装配出不同 agent"与缓存 key。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/agents/lead_agent/agent.py` | 1445 | make_lead_agent / assemble_lead_agent / build_middlewares / _get_runtime_config / INVARIANT 注释 |
| `references/code/agents/factory.py` | 547 | create_helix_agent / _assemble_from_features / _insert_extra 锚点解析 |
| `references/code/agents/features.py` | 70 | RuntimeFeatures + Next/Prev 装饰器（纯数据类） |
| `references/code/agents/assembly_descriptor.py` | 508 | 装配描述符投影 |
| `references/code/agents/interaction_policy.py` | 182 | 交互策略（澄清/确认门） |
| `references/code/agents/human_input.py` | 125 | 人类输入处理 |
| `references/code/agents/__init__.py` | 50 | make_lead_agent 懒注册 + 技能缓存预热 |
| `references/code/app/gateway/routers/agents.py` | 844 | 自定义 agent CRUD/版本导入导出 |
| `references/code/app/gateway/routers/assistants_compat.py` | 152 | LangGraph assistants 兼容面 |
| `references/code/langgraph.json` | — | 图注册入口 |

## 反模式与陷阱

- ❌ 缓存编译图当单例 → 跨用户共享 sandbox/model/技能集；per-run 决策（non_interactive 剥离、webhook 扣留）失效
- ❌ 只读一个通道 → 工具/中间件拿不到值（新版 LangGraph 移除了 context→configurable fallback）
- ❌ 密钥/运行时旗标写进 `configurable` → 随 checkpoint 持久化
- ❌ `config["callbacks"]=` / `config["metadata"]=` 直接赋值 → 覆盖上游注入；必须追加/update
- ❌ `_resolve_model_name` 对未知名抛错 → 旧 thread 不可恢复；降级 + warning
- ❌ `assemble_deferred_tools` 先于技能白名单过滤 → 被禁工具进延迟集，prompt 骗模型
- ❌ `state_schema` 用裸 `AgentState` → sandbox/artifacts/delegations 通道退化为 Last-Write-Wins（见 [[thread-state-and-reducers]]）
- ❌ `agent_name` 不过 `validate_agent_name` → 路径穿越可读写任意目录

## 落地参考

**调参旋钮**：`model_name`/`thinking_enabled`/`reasoning_effort`（configurable+context 双写）；`is_plan_mode`、`subagent_enabled`、`max_concurrent_subagents`(默认3)、`is_bootstrap`、`agent_name`；`non_interactive`（context，仅内部调用方）；`channel_name`（context，触发 webhook 扣留）。

**调试日志串**：`Create Agent(<name>) -> thinking_enabled: ... model_name: ...`（每次装配必打）；`Model '...' not found in config; fallback`（降级路径）。

**自测方向**：同参多次装配断言工具集/链序/prompt 字节级一致；`configurable.model_name=A`+`context.model_name=B` → 用 B；bootstrap 断言工具集只含 setup_agent；`channel_name="github"` 断言无 `update_agent`；mock tracing 断言 callbacks 追加且所有 `create_chat_model` 带 `attach_tracing=False`。

## 进一步阅读

- [[middleware-chain-design]]（build_middlewares 的全量链）、[[system-prompt-template]]、[[thread-state-and-reducers]]
- [[e2e-request-lifecycle]]（④建图 在链路中的位置）、[[observability-tracing]]（挂图根不变量另一面）
- 深读 `agent.py` 顶部 INVARIANT 注释块与 `build_middlewares` 源码
