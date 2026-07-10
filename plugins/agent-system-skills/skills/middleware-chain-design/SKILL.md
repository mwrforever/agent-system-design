---
name: middleware-chain-design
description: 设计 LangChain agent 的中间件链--base + lead-only 双段装配、hook 嵌套与逆序语义、中断型中间件必须链尾。完整覆盖 29 项链顺序（每项标注 before_agent/before_model/wrap_model_call/after_model/wrap_tool_call/after_model 钩子类型）、build_middlewares 装配（共享基座 1–12 + lead 专用 13–29）、after_model 逆序派发、ClarificationMiddleware 链尾中断。给出完整、未截断的真实代码。当你要加横切关注点、分清主代理与子代理共用哪些中间件、排查 after_model 顺序错乱、或设计 Command(goto=END) 中断型中间件时调用本 skill。
---

## 何时用

- 你在给 agent 加新的横切关注点（日志 / 限流 / 上下文压缩 / 安全审计 / Memory 队列 / 澄清中断…），需要决定它插在链的哪个位置
- 需要分清"哪些中间件主代理与子代理共用（base 段），哪些只属于主代理（lead-only 段）"
- 遇到"我的 `after_model` 中间件被另一个先跑了"或"中断后计量丢失"这类顺序错乱
- 想拦截 tool 调用而非真正执行（`Command(goto=END)` 中断模式），需要确认它必须链尾
- 排查 `wrap_model_call` 洋葱模型里某中间件看不到消毒后消息 / 看到未过滤工具 schema
- 新增中间件，需要确认它相对 InputSanitization / ToolErrorHandling / Clarification 的位置约束

## 设计方案（为什么这么设计）

### 核心矛盾：29 个中间件，lead 全用 vs 子代理只用一部分

生产 agent 的中间件链有 29 项，职责从输入消毒、资源装配、错误归一化，一直到动态上下文注入、上下文压缩、任务编排、计量、协议矫正、出口拦截。lead agent（主代理）需要全套；子代理（`task()` 委派的轻量执行体）只需要其中一部分--它不需要 Title、Memory、SkillActivation、Clarification 这些 lead 专属的上下文/编排/中断职责，但需要与 lead 一致的安全防护（LoopDetection / TokenBudget / SafetyFinishReason，防退化子代理烧穿 token）。

若用一个巨型 builder 一把装配，子代理会被迫跑 lead 专属中间件：浪费 token、数据污染（子代理不该写记忆/起标题）、还会挂上不该有的 `ClarificationMiddleware`（子代理禁 `ask_clarification`，无中断需求）。若每个 agent 各写一份 builder，29 项的顺序约束要在多处复制，顺序 drift 必然发生。

### 解法：base + lead-only 两段装配

把链拆成两段，靠两个 builder 函数组装：

- **base 段**（`build_lead_runtime_middlewares` / `build_subagent_runtime_middlewares` -> 共享核心 `_build_runtime_middlewares`）：装 1–12。lead 与子代理都复用，差异仅在 `include_uploads` 开关（lead 注入 Uploads，子代理不注入）。职责是输入消毒、thread/沙箱资源装配、错误归一化、工具执行审计--这些是任何 agent 都需要的运行时基座。
- **lead-only 段**（`build_middlewares`）：在 base 之上续装 13–29。职责是动态上下文注入、技能激活、摘要、任务编排、计量、协议矫正、出口拦截。子代理不走这段，它有自己的镜像防护续装（ViewImage / DeferredToolFilter / LoopDetection / TokenBudget / SafetyFinishReason）。

**复用 vs 特化的权衡**：base 段最大化复用（一个 `_build_runtime_middlewares` 两个入口），保证 1–12 的顺序约束只在一处定义；lead-only 段集中特化（lead 独有的 17 项只在 `build_middlewares` 出现），子代理不会被污染。子代理的防护续装是 lead 链尾段的**子集镜像**（同样的 LoopDetection / TokenBudget / Safety，但不含 Clarification）。

### after_model 逆序：LIFO 出口包裹

LangChain `AgentMiddleware` 的钩子派发有三种语义：

- `before_agent` / `before_model` / `after_agent`：**正序**（链表第 1 项先跑）。
- `wrap_model_call` / `wrap_tool_call`：**洋葱模型**（链表第 1 项是最外层，包裹所有内层；第 N 项是最内层，最贴近真实模型/工具）。
- `after_model`：**逆序**（最后注册的最先跑）。

`after_model` 逆序不是 bug 而是 LIFO 出口包裹的设计：模型返回后，处理链像洋葱的"剥皮"一样从最内层（最后注册）开始往外剥。这与 `wrap_model_call` 的"从外到内包裹"形成对称--入口从外到内、出口从内到外，整个模型调用被中间件链对称地夹住。

**实操推论**：`SafetyFinishReasonMiddleware` 必须注册在 `LoopDetectionMiddleware` **之后**（链表中更靠后），因为逆序派发使 Safety 先跑、清空安全终止的 tool_calls，Loop 再对清理后的消息计数。若反序，Loop 会先对带截断 tool_calls 的消息计数，触发误报。源码 docstring 明确要求 "register after LoopDetection"。

### 中断型必须链尾：ClarificationMiddleware

`ClarificationMiddleware`（第 29 项）拦截 `ask_clarification` 工具调用，返回 `Command(goto=END)` 中断 run，等用户回复。它是**中断型**中间件--一旦触发，图直接跳到 END，不再执行后续节点。

**为何必须链尾**：若 Clarification 不在链尾，排在它后面的中间件（如 TokenBudget 计量、SafetyFinishReason 清理）的 `after_model` / `after_agent` 钩子会在 `Command(goto=END)` 中断后**错过**--图已跳走，它们的钩子不再被调用。后果是计量丢失（token 用量统计不全）、状态不一致（安全终止的 tool_calls 未清理就落 checkpoint）。

源码用注释硬约束：`# ClarificationMiddleware should always be last`，并在 `return middlewares` 前最后 append。这是整个链顺序的最高优先级不变量。

**纵深防御**：ClarificationMiddleware 还读 `runtime.context["disable_clarification"]` 决定是中断还是放行。这是跨切不变量 1（`non_interactive` 剥离 `ask_clarification`）的纵深防线--`non_interactive` 在 ④建图剥离工具（主防线，调度通道），`disable_clarification` 在本中间件放行已调用的工具（webhook 通道旁路），两者覆盖不同通道，都防"无人值守时卡在中断态"。

### 29 项链顺序设计理由：职责分层

链顺序按职责从外到内、从入口到出口分层：

1. **输入消毒层**（1–2）：InputSanitization 最外层 `wrap_model_call`，所有内层（含 LLM 重试）见消毒后消息；ToolOutputBudget 限工具输出体积。
2. **资源装配层**（3–5）：ThreadData 建 per-thread 目录（user_id 隔离）-> Uploads 注入新文件（仅 lead）-> Sandbox 申请沙箱。顺序硬约束：ThreadData 必须在 Sandbox 之前（Sandbox 读 thread_id）。
3. **错误归一化层**（6–7）：DanglingToolCall 补占位 ToolMessage -> LLMErrorHandling 归一化模型失败。
4. **安全/审计层**（8–11）：Guardrail 工具调用前授权 -> SandboxAudit 审计 -> ReadBeforeWrite 写前必读门 -> ToolProgress 工具停滞守卫。顺序硬约束：ToolProgress 必须在 ToolErrorHandling 之外（index 更小，`wrap_tool_call` 链包住 stamping），构建时 `isinstance` 断言守护。
5. **工具错误归一化**（12）：ToolErrorHandling 工具异常转 ToolMessage，盖 `helix_tool_meta`。
6. **动态上下文层**（13–15）：DynamicContext 注入日期/记忆 -> SkillActivation `/skill-name` 激活 -> DurableContext 捕获 task 委派防被摘要压掉。
7. **压缩/编排层**（16–18）：Summarization 压缩 -> TodoList plan mode 追踪 -> TokenUsage 计量。
8. **元信息层**（19–21）：Title 起标题 -> Memory 排队异步记忆 -> ViewImage 视觉模型注入图像。顺序硬约束：Title 在 Memory 之前。
9. **协议矫正层**（22–23）：DeferredToolFilter 隐藏延迟工具 schema -> SystemMessageCoalescing 合并 SystemMessage。顺序硬约束：Coalescing 在 DeferredToolFilter 之后（合并发生在 schema 已过滤、模型调用前最后一刻）。
10. **计量/检测层**（24–26）：SubagentLimit 截断超额 task -> LoopDetection 检测循环 -> TokenBudget 每 run 上限。
11. **出口拦截层**（27–29）：custom 自定义注入点 -> SafetyFinishReason 安全终止抑制 -> Clarification 链尾中断。

### 在端到端链路中的位置

本 skill 处于端到端链路的 **⑤中间件**（见 [[e2e-request-lifecycle]]）：

- 上游 ④建图：`make_lead_agent` 在装配主体里调 `build_middlewares(config, ...)` 构造 29 项链（见 [[agent-graph-factory]] 的 `_make_lead_agent`），随后 `create_agent` 一次绑定模型 + 工具 + 中间件链 + 静态 prompt。
- 下游 ⑥执行：图构造完后，worker 给图挂 checkpointer + store，再 `astream` 驱动中间件链与工具循环--`before_agent` 正序预处理 -> `wrap_model_call` 洋葱包裹模型 -> `after_model` 逆序处理输出 -> `wrap_tool_call` 洋葱包裹工具 -> 循环直到无 tool_calls 或被 `Command(goto=END)` 截停。

跨切不变量 1（`non_interactive` 剥离 `ask_clarification`）的纵深防线落在本 skill 的链尾 `ClarificationMiddleware`：主防线在 ④建图剥离工具，本中间件读 `disable_clarification` 放行已调用工具（webhook 通道旁路）。

## 完整真实代码实现

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/agents/middlewares/tool_error_handling_middleware.py` | `_build_runtime_middlewares`（共享基座核心，base 1–12）+ `build_lead_runtime_middlewares`（lead 基座入口）+ `build_subagent_runtime_middlewares`（子代理基座入口）+ `ToolErrorHandlingMiddleware`（第 12 项） |
| `core/helix/agents/lead/agent.py` | `build_middlewares`（lead 专用，续装 13–29）+ `_create_summarization_middleware` / `_create_todo_list_middleware` 构造器 |
| `core/helix/agents/middlewares/dynamic_context_middleware.py` | 第 13 项：注入日期/记忆 `<system-reminder>`（完整源码见 [[system-prompt-template]]） |
| `core/helix/agents/middlewares/system_message_coalescing_middleware.py` | 第 23 项：合并所有 SystemMessage 为首条（完整源码见 [[system-prompt-template]]） |
| `core/helix/agents/middlewares/deferred_tool_filter_middleware.py` | 第 22 项：延迟 MCP 工具，tool_search 提升前隐藏 schema |
| `core/helix/agents/middlewares/clarification_middleware.py` | 第 29 项（链尾）：拦截 `ask_clarification`，`Command(goto=END)` 中断 |

> 脊柱 ⑤跳的 [references/code/05-middleware-chain.md](../e2e-request-lifecycle/references/code/05-middleware-chain.md) 已给同一份链顺序清单 + 关键中间件片段；本 skill 补 hook 类型标注 + 共享基座含子代理变体的完整装配 + 设计深度。两处代码一致，本 skill 为中间件链视角的权威源。

### 1. 29 项链顺序清单（含 hook 类型标注）

`?` 标注的是 config/runtime 条件可选。段标注：`base` = 共享基座（lead + 子代理复用），`lead` = lead 专用续装。hook 标注该中间件 override 的 LangChain `AgentMiddleware` 钩子。

| # | 中间件 | hook 类型 | 段 | 条件 | 顺序约束理由 |
|---|---|---|---|---|---|
| 1 | InputSanitization | `wrap_model_call` | base | 始终 | 最外层，所有内层见消毒后消息 |
| 2 | ToolOutputBudget | `wrap_model_call`, `wrap_tool_call` | base | 始终 | 工具输出体积上限 |
| 3 | ThreadData | `before_agent` | base | 始终 | 建 per-thread 目录；必须在 Sandbox 前（Sandbox 读 thread_id） |
| 4 | Uploads | `before_agent` | base* | `include_uploads` | 注入新上传文件（仅 lead） |
| 5 | Sandbox | `before_agent`, `after_agent`, `wrap_tool_call` | base | 始终 | 申请沙箱，存 sandbox_id 到 state |
| 6 | DanglingToolCall | `wrap_model_call` | base | `include_dangling` | 为缺响应的 tool_call 注入占位 ToolMessage |
| 7 | LLMErrorHandling | `wrap_model_call` | base | 始终 | 归一化模型调用失败为可恢复错误 |
| 8 | Guardrail | `wrap_tool_call` | base? | `guardrails.enabled` | 工具调用前授权（可插拔 GuardrailProvider） |
| 9 | SandboxAudit | `wrap_tool_call` | base | 始终 | 审计沙箱 shell/file 操作 |
| 10 | ReadBeforeWrite | `wrap_tool_call` | base? | `read_before_write.enabled` | 写前必读门（content hash 校验） |
| 11 | ToolProgress | `before_agent`, `wrap_tool_call`, `wrap_model_call` | base? | `tool_progress.enabled` | 必须在 ToolErrorHandling 之外（index 更小），`isinstance` 断言守护 |
| 12 | ToolErrorHandling | `wrap_tool_call` | base | 始终 | 工具异常转 ToolMessage，盖 `helix_tool_meta` |
| 13 | DynamicContext | `before_agent` | lead | 始终 | 注入日期/记忆 `<system-reminder>`（见 [[system-prompt-template]]） |
| 14 | SkillActivation | `wrap_model_call` | lead | 始终 | `/skill-name` 显式激活，注入 SKILL.md |
| 15 | DurableContext | `before_model`, `after_model`, `wrap_model_call` | lead | 始终 | 捕获 task 委派 + 技能引用，防被摘要压掉 |
| 16 | Summarization | `before_model` | lead? | 配置驱动 | 上下文压缩；应靠前，在其他处理前压缩 |
| 17 | TodoList | `before_model`, `before_agent`, `after_model`, `wrap_model_call`, `after_agent` | lead? | `is_plan_mode` | plan mode 任务追踪 |
| 18 | TokenUsage | `after_model` | lead? | `token_usage.enabled` | 记录 token 用量 |
| 19 | Title | `after_model` | lead | 始终 | 首轮交换后自动起标题；在 Memory 前 |
| 20 | Memory | `after_agent` | lead | 始终 | 排队异步记忆更新（在 Title 之后） |
| 21 | ViewImage | `before_model` | lead? | `model.supports_vision` | 视觉模型注入 base64 图像 |
| 22 | DeferredToolFilter | `wrap_model_call`, `wrap_tool_call` | lead? | `deferred_setup` | 延迟 MCP 工具，tool_search 提升前隐藏 schema |
| 23 | SystemMessageCoalescing | `wrap_model_call` | lead | 始终 | 合并所有 SystemMessage 为首条；在 DeferredToolFilter 后 |
| 24 | SubagentLimit | `after_model` | lead? | `subagent_enabled` | 截断超额 task 调用，强制并发上限 |
| 25 | LoopDetection | `before_agent`, `after_model`, `after_agent`, `wrap_model_call` | lead? | `loop_detection.enabled` | 检测重复 tool-call 循环并硬停；Safety 须注册其后 |
| 26 | TokenBudget | `before_agent`, `after_agent`, `after_model`, `wrap_model_call` | lead? | `token_budget.enabled` | 每 run token 上限 |
| 27 | [custom] | user-defined | lead | `custom_middlewares` | 自定义中间件注入点（Clarification 前、Safety 后） |
| 28 | SafetyFinishReason | `after_model` | lead? | `safety_finish_reason.enabled` | provider 安全终止时抑制工具；注册在 Loop 后（逆序 after_model 先跑） |
| 29 | Clarification | `wrap_tool_call` | lead | 始终 | **链尾**：拦截 ask_clarification，`Command(goto=END)` 中断 |

> `base*` = base 段但仅 lead 打开（`include_uploads=True`）；子代理 `include_uploads=False` 跳过。子代理基座 `build_subagent_runtime_middlewares` 不挂 13–23 与 29，续装 ViewImage/Deferred/Loop/TokenBudget/Safety 镜像防护。

### 2. build_middlewares 装配（lead-only 续装 13–29）

`build_middlewares` 先调 `build_lead_runtime_middlewares` 拿到 1–12 基座，再续装 13–29。顺序约束注释（原样保留）枚举了每项的相对位置理由。完整装配源码（含共享基座 `_build_runtime_middlewares` / `build_lead_runtime_middlewares` / `build_subagent_runtime_middlewares` + 构造器辅助函数）见 [references/code/build-middlewares.md](./references/code/build-middlewares.md)。

```python
# core/helix/agents/lead/agent.py
# 顺序约束注释（原样保留）：
# ThreadDataMiddleware must be before SandboxMiddleware to ensure thread_id is available
# UploadsMiddleware should be after ThreadDataMiddleware to access thread_id
# DanglingToolCallMiddleware patches missing ToolMessages before model sees the history
# SummarizationMiddleware should be early to reduce context before other processing
# TodoListMiddleware should be before ClarificationMiddleware to allow todo management
# TitleMiddleware generates title after first exchange
# MemoryMiddleware queues conversation for memory update (after TitleMiddleware)
# ViewImageMiddleware should be before ClarificationMiddleware to inject image details before LLM
# ToolErrorHandlingMiddleware should be before ClarificationMiddleware to convert tool exceptions to ToolMessages
# ClarificationMiddleware should be last to intercept clarification requests after model calls
def build_middlewares(
    config: RunnableConfig,
    model_name: str | None,
    agent_name: str | None = None,
    custom_middlewares: list[AgentMiddleware] | None = None,
    *,
    available_skills: set[str] | None = None,
    app_config: AppConfig | None = None,
    deferred_setup=None,
    user_id: str | None = None,
):
    """按运行时配置构建 lead-agent 中间件链。

    lead agent 全套中间件组合的公共入口。make_lead_agent 与嵌入式 HelixClient
    （需相同链的 lead-agent 变体）都用它。保持名字稳定：跨模块边界 import，
    重命名/改签名会波及 client.py。
    """
    resolved_app_config = app_config or get_app_config()
    middlewares = build_lead_runtime_middlewares(app_config=resolved_app_config, lazy_init=True)  # 1-12 共享基座

    # 始终把当前日期（可选记忆）作为 <system-reminder> 注入首条 HumanMessage，
    # 使系统提示词保持纯静态以最大化 prefix-cache 复用。
    from helix.agents.middlewares.dynamic_context_middleware import DynamicContextMiddleware
    middlewares.append(DynamicContextMiddleware(agent_name=agent_name, app_config=resolved_app_config))  # 13

    # 用户以 /skill-name 开启 turn 时确定性地加载完整 SKILL.md。使基础系统提示词
    # 仅含元数据，显式用户激活优先于模型侧相关性猜测。
    from helix.agents.middlewares.skill_activation_middleware import SkillActivationMiddleware
    middlewares.append(SkillActivationMiddleware(available_skills=available_skills,
                                                app_config=resolved_app_config, user_id=user_id))  # 14

    # 摘要可能压缩掉已完成的 task 委派与加载的 skill 文件前先捕获它们，
    # 再把持久上下文通道（summary + ledger + skills）注入模型调用。
    from helix.agents.middlewares.durable_context_middleware import DurableContextMiddleware
    middlewares.append(DurableContextMiddleware(
        skills_container_path=resolved_app_config.skills.container_path,
        skill_file_read_tool_names=resolved_app_config.summarization.skill_file_read_tool_names,
    ))                                                                    # 15

    summarization_middleware = _create_summarization_middleware(app_config=resolved_app_config)
    if summarization_middleware is not None:
        middlewares.append(summarization_middleware)                       # 16?

    cfg = _get_runtime_config(config)
    is_plan_mode = cfg.get("is_plan_mode", False)
    todo_list_middleware = _create_todo_list_middleware(is_plan_mode)
    if todo_list_middleware is not None:
        middlewares.append(todo_list_middleware)                           # 17?

    if resolved_app_config.token_usage.enabled:
        middlewares.append(TokenUsageMiddleware())                        # 18?

    middlewares.append(TitleMiddleware(app_config=resolved_app_config))    # 19
    middlewares.append(MemoryMiddleware(agent_name=agent_name, memory_config=resolved_app_config.memory))  # 20

    model_config = resolved_app_config.get_model_config(model_name) if model_name else None
    if model_config is not None and model_config.supports_vision:
        middlewares.append(ViewImageMiddleware())                         # 21?

    if deferred_setup is not None and deferred_setup.deferred_names:
        from helix.agents.middlewares.deferred_tool_filter_middleware import DeferredToolFilterMiddleware
        middlewares.append(DeferredToolFilterMiddleware(deferred_setup.deferred_names,
                                                        deferred_setup.catalog_hash))  # 22?

    # 请求到达 provider 前把每条 SystemMessage 合并为单一首条。严格后端
    # （vLLM、SGLang、Qwen、Anthropic）拒绝非首条 SystemMessage。
    from helix.agents.middlewares.system_message_coalescing_middleware import SystemMessageCoalescingMiddleware
    middlewares.append(SystemMessageCoalescingMiddleware())                # 23

    subagent_enabled = cfg.get("subagent_enabled", False)
    if subagent_enabled:
        max_concurrent_subagents = cfg.get("max_concurrent_subagents", 3)
        middlewares.append(SubagentLimitMiddleware(max_concurrent=max_concurrent_subagents))  # 24?

    loop_detection_config = resolved_app_config.loop_detection
    if loop_detection_config.enabled:
        middlewares.append(LoopDetectionMiddleware.from_config(loop_detection_config))  # 25?

    token_budget_config = resolved_app_config.token_budget
    if token_budget_config.enabled:
        from helix.agents.middlewares.token_budget_middleware import TokenBudgetMiddleware
        middlewares.append(TokenBudgetMiddleware.from_config(token_budget_config))  # 26?

    # 在 ClarificationMiddleware 前注入自定义中间件
    if custom_middlewares:
        middlewares.extend(custom_middlewares)                            # 27

    # SafetyFinishReasonMiddleware 注册在自定义中间件之后，使 LangChain 逆序 after_model
    # 分派先跑 Safety；清空的 tool_calls 再流经 Loop/Subagent 计量而不触发额外告警。
    safety_config = resolved_app_config.safety_finish_reason
    if safety_config.enabled:
        middlewares.append(SafetyFinishReasonMiddleware.from_config(safety_config))  # 28?

    # ClarificationMiddleware should always be last
    middlewares.append(ClarificationMiddleware())                          # 29 - 链尾硬约束
    return middlewares
```

### 3. 共享基座入口（base 段 1–12，lead 与子代理分叉）

`build_lead_runtime_middlewares` 与 `build_subagent_runtime_middlewares` 都委托给 `_build_runtime_middlewares`，靠 `include_uploads` 开关区分。基座按三层组装：外层 `wrap_model_call` 包装（Layer 1）-> `before_agent` 线程级钩子（Layer 2）-> 后处理 append-only 尾部（Layer 3），拼成 1–12。完整源码（含 `build_subagent_runtime_middlewares` 子代理变体的镜像防护续装）见 [references/code/build-middlewares.md](./references/code/build-middlewares.md)。

```python
# core/helix/agents/middlewares/tool_error_handling_middleware.py
def build_lead_runtime_middlewares(*, app_config: AppConfig, lazy_init: bool = True) -> list[AgentMiddleware]:
    """lead agent 运行时在 lead 专用中间件之前共享的中间件。"""
    return _build_runtime_middlewares(
        app_config=app_config,
        include_uploads=True,                 # 注：lead 才注入 uploads；子代理 include_uploads=False
        include_dangling_tool_call_patch=True,
        lazy_init=lazy_init,
    )
```

`_build_runtime_middlewares` 内部的三层组装 + `ToolProgress` 外于 `ToolErrorHandling` 的 `isinstance` 断言守护，见 [references/code/build-middlewares.md](./references/code/build-middlewares.md) 第 1 节。

### 4. 链尾 ClarificationMiddleware（中断型不变量）

链尾中间件拦截 `ask_clarification`，返回 `Command(goto=END)` 中断 run。`_is_disabled` 读 `runtime.context["disable_clarification"]` 决定中断还是放行（跨切不变量 1 的纵深防线）。完整源码见 [references/code/chain-order.md](./references/code/chain-order.md) 第 4.4 节与脊柱 05-middleware-chain.md。

```python
# core/helix/agents/middlewares/clarification_middleware.py - 链尾（第 29 项，必须最后）
@override
def wrap_tool_call(self, request: ToolCallRequest, handler) -> ToolMessage | Command:
    if request.tool_call.get("name") != "ask_clarification":
        return handler(request)                                  # 非澄清：正常执行
    if self._is_disabled(request):
        return self._handle_disabled_clarification(request)      # disable_clarification 通道：转普通 ToolMessage 继续
    return self._handle_clarification(request)                   # 默认：Command(goto=END) 中断

def _handle_clarification(self, request: ToolCallRequest) -> Command:
    args = request.tool_call.get("args", {})
    formatted_message = self._format_clarification_message(args)
    tool_call_id = request.tool_call.get("id", "")
    request_id = self._stable_message_id(tool_call_id, formatted_message)
    human_input_payload = self._build_human_input_payload(args, tool_call_id=tool_call_id, request_id=request_id)
    tool_message = ToolMessage(id=request_id, content=formatted_message,
        tool_call_id=tool_call_id, name="ask_clarification",
        artifact={"human_input": human_input_payload})   # 前端 Human Input Card 载荷
    return Command(update={"messages": [tool_message]}, goto=END)   # 中断 run，等用户回复
```

### 5. 动态时序（一次 turn 穿越完整链）

```
state, config -> graph.astream
  step 1: before_agent 链（正序：1->29）
           3 ThreadData -> 4 Uploads -> 5 Sandbox -> 13 DynamicContext -> 25 LoopDetection? -> ...
                 -> 返回 partial state，reducer 合并入 state
  step 2: model 节点
           wrap_model_call 链（洋葱，外->内：1->29）
             1 InputSanitization -> 2 ToolOutputBudget -> ... -> 23 Coalescing -> 25 Loop? -> 26 TokenBudget?
                                                                      -> 真实模型
           after_model 链（逆序：29->1，最后注册的最先跑）
             28 SafetyFinishReason? -> 25 LoopDetection? -> 24 SubagentLimit? -> 19 Title -> 18 TokenUsage? -> ...
  step 3: tools 节点（若有 tool_calls）
           wrap_tool_call 链（洋葱，外->内：1->29）
             2 ToolOutputBudget -> 5 Sandbox -> 8 Guardrail? -> 9 SandboxAudit -> 12 ToolErrorHandling
                 -> ... -> 22 DeferredToolFilter? -> 29 Clarification（链尾，可能 Command(goto=END)）
  step 4: 循环回 step 2 直到无 tool_calls 或被 Command(goto=END) 截停
  step 5: after_agent 链（正序：1->29）
           5 Sandbox -> 17 TodoList? -> 20 Memory -> 25 LoopDetection? -> 26 TokenBudget?
```

### references 索引

- [references/code/build-middlewares.md](./references/code/build-middlewares.md) -- 完整装配源码：共享基座 `_build_runtime_middlewares` / `build_lead_runtime_middlewares` / `build_subagent_runtime_middlewares`（base 段，含子代理变体）+ lead 专用 `build_middlewares`（13–29）+ `_create_summarization_middleware` / `_create_todo_list_middleware` 构造器
- [references/code/chain-order.md](./references/code/chain-order.md) -- 29 项链顺序清单（含 hook 类型标注）+ 钩子执行序框架规则 + 顺序不变量 + 关键中间件入口片段（DynamicContext / SystemMessageCoalescing / DeferredToolFilter / ClarificationMiddleware 链尾完整）

## 反模式与陷阱

- ❌ **中断型中间件不放链尾** -> `ClarificationMiddleware` 返回 `Command(goto=END)` 后，排它后面的 `after_model`（TokenBudget 计量、SafetyFinishReason 清理）错过，计量丢失 + 状态不一致。修复：中断型固定链尾，源码注释 `# ClarificationMiddleware should always be last`。
- ❌ **SafetyFinishReason 注册在 LoopDetection 之前** -> 逆序 `after_model` 派发使 Loop 先跑，对带截断 tool_calls 的消息计数触发误报。修复：Safety 必须注册在 Loop 之后（链表中更靠后），docstring 要求 "register after LoopDetection"。
- ❌ **ToolProgress 在 ToolErrorHandling 之后**（index 更大）-> ToolProgress 的 `wrap_tool_call` 链不再包住 stamping 步骤，读到未盖 `helix_tool_meta` 的结果。修复：ToolProgress 必须在外（index 更小），构建时 `isinstance` 断言反序 `raise RuntimeError`。
- ❌ **InputSanitization 不在最外层** -> LLM 重试中间件先看到未消毒内容，触发提供商级 4xx。修复：InputSanitization 固定 `outer_wrappers` 首位。
- ❌ **ThreadData 在 Sandbox 之后** -> SandboxMiddleware 的 `before_agent` 读不到 thread_id，沙箱目录落错位置。修复：ThreadData 必须在 Sandbox 之前。
- ❌ **没有 base / lead 分层，子代理也跑 Title/Memory/Clarification** -> 浪费 token + 数据污染（子代理写记忆/起标题）+ 挂上不该有的中断中间件。修复：base 段共享（`_build_runtime_middlewares`），lead-only 段集中特化；子代理走 `build_subagent_runtime_middlewares` 续装镜像防护。
- ❌ **`wrap_model_call` 里直接修改 `request.messages` 列表** -> 引用语义导致后续中间件也看到修改，链路顺序错乱；且污染 checkpoint。修复：永远 `request.override(messages=new_list)`（见 SystemMessageCoalescing 的 `_maybe_coalesce`）。
- ❌ **`wrap_tool_call` 截到 `Command` 返回还去拼装 `ToolMessage`** -> `Command` 是控制流，二次包装破坏 LangGraph 跳转。修复：先 `isinstance(result, ToolMessage)` 再处理。
- ❌ **`wrap_tool_call` 不透传 `GraphBubbleUp`** -> interrupt / human-in-the-loop 静默失败。修复：`except GraphBubbleUp: raise` 原样重抛。
- ❌ **`before_agent` 做不可重入副作用**（如无条件建沙箱）-> checkpoint resume 时再跑一次，重复扣费/重复建容器。修复：先 `state.get("sandbox")` 判存在再创建。
- ❌ **同步 hook 里调 `asyncio.run`** -> LangGraph 异步运行时撞嵌套事件循环。修复：用 `asyncio.to_thread` + 有界 `wait_for(timeout)`（见 DynamicContext 的 `abefore_agent`）。
- ❌ **可选中间件不通过 `app_config.<feature>.enabled` 闸门** -> 升级时找不到开关，行为不可控。修复：统一 `app_config.<feature>.enabled` 门控。
- ❌ **依赖中间件相对位置写死索引** -> 插入新中间件就错位。修复：通过 `isinstance` 查找（`next(i for i,m in enumerate(mws) if isinstance(m, X))`）。
- ❌ **`build_middlewares` 在 builder 之外又追加同名中间件** -> 重复执行造成两次写回。修复：builder 输出后用 `set(map(type, mws))` 校验唯一。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `lazy_init` | builder 参数 | 沙箱等重型中间件首次使用时初始化（非模块加载期） |
| `include_uploads` | `_build_runtime_middlewares` 开关 | lead `True` / 子代理 `False`，区分 4 Uploads |
| `include_dangling_tool_call_patch` | `_build_runtime_middlewares` 开关 | 6 DanglingToolCall 补占位（lead + 子代理都 `True`） |
| `guardrails.enabled` | app config | 8 Guardrail 工具调用前授权 |
| `read_before_write.enabled` | app config | 10 ReadBeforeWrite 写前必读门 |
| `tool_progress.enabled` | app config | 11 ToolProgress 工具停滞守卫 |
| `summarization` | 配置驱动 | 16 Summarization 上下文压缩 |
| `is_plan_mode` | runtime config | 17 TodoList plan mode 追踪 |
| `token_usage.enabled` | app config | 18 TokenUsage 记录用量 |
| `model.supports_vision` | app config | 21 ViewImage 视觉模型注入 |
| `tool_search.enabled` + `deferred_setup` | app config + 构建时 | 22 DeferredToolFilter 延迟工具 |
| `subagent_enabled` / `max_concurrent_subagents` | runtime config | 24 SubagentLimit 并发上限 |
| `loop_detection.enabled` / `warn_threshold` / `hard_limit` / `window_size` | app config | 25 LoopDetection 重复工具调用阈值 |
| `token_budget.enabled` | app config | 26 TokenBudget 每 run 总预算 |
| `safety_finish_reason.enabled` | app config | 28 SafetyFinishReason provider 内容过滤防护 |
| `custom_middlewares` | `build_middlewares` 入参 | 27 自定义中间件注入点 |

**关键日志串**（排障时 grep）

- `Filtered %d deferred tool schema(s) from model binding` -- 22 DeferredToolFilter 过滤延迟工具
- `Tool execution failed (sync): name=%s id=%s` / `(async)` -- 12 ToolErrorHandling 兜底分支
- `tool_progress: helix_tool_meta missing for non-exempt tool %s - verify ToolProgressMiddleware is outer of ToolErrorHandlingMiddleware` -- 11 顺序断言运行时告警
- `Loop hard limit reached - forcing stop` -- 25 工具重复触顶
- `Repetitive tool calls detected - injecting warning` -- 25 工具重复预警
- `Provider safety termination detected - suppressed %d tool call(s)` -- 28 提供商安全策略截断
- `Intercepted clarification request` -- 29 澄清中断
- `ask_clarification suppressed (disable_clarification set); instructing agent to proceed` -- 29 webhook 通道放行
- `DynamicContextMiddleware: injecting full reminder (has_memory=%s) into first HumanMessage id=%r` -- 13 首轮注入
- `DynamicContextMiddleware: midnight crossing detected - injected date update before current turn` -- 13 跨午夜校正
- `DynamicContextMiddleware: injection timed out (%.1fs); skipping memory/date injection for this turn` -- 13 超时降级
- `ToolProgressMiddleware must be outer (index …) of ToolErrorHandlingMiddleware (index …) - check middleware append order` -- 构建时顺序断言硬失败

**自测方向**

- **排序契约**：mock 三个中间件 A/B/C，断言 `wrap_model_call` 调用顺序 A->B->C（洋葱外->内），`after_model` 派发 C->B->A（逆序）。
- **链顺序确定性**：相同入参 5 次 `build_middlewares`，断言产出相同顺序链（条件项按 config 开关稳定出现/缺失）。
- **链尾中断**：`ask_clarification` tool_call -> `ClarificationMiddleware` 返回 `Command(goto=END)`，断言后续工具节点不被触发；`disable_clarification=True` -> 返回普通 `ToolMessage`，run 继续。
- **Safety 先于 Loop**：构造安全终止 + 循环 tool_calls 的 AIMessage，断言 `after_model` 逆序派发使 Safety 先清空 tool_calls，Loop 对清理后消息计数（不误报）。
- **ToolProgress 外于 ToolErrorHandling**：反序 append -> 构建时 `raise RuntimeError`；正序 -> ToolProgress 读到盖了 `helix_tool_meta` 的结果。
- **base 段复用**：`build_lead_runtime_middlewares` 含 Uploads（index 4），`build_subagent_runtime_middlewares` 不含 Uploads；两者 1–12 其余项一致。
- **子代理不挂 Clarification**：`build_subagent_runtime_middlewares` 产出不含 `ClarificationMiddleware` 实例。
- **错误归一化**：工具函数 `raise ValueError("boom")` -> 期望 `ToolMessage(status="error")`，链路继续。
- **`GraphBubbleUp` 透传**：工具抛 `GraphBubbleUp` -> 必须重抛，不能被 except 吞。
- **async IO 不阻塞**：注册一个故意 sleep 的 `before_agent`，断言 `abefore_agent` 走 `to_thread` + 有界超时降级返回 None。
- **字段唯一写权**：两个中间件都写 `title` -> 应通过测试断言只一个生效，或显式 reducer。

## 进一步阅读

- 完整装配源码（base + lead-only 双段 + 子代理变体 + 构造器）：[references/code/build-middlewares.md](./references/code/build-middlewares.md)
- 29 项链顺序清单（含 hook 类型）+ 顺序不变量 + 关键中间件片段：[references/code/chain-order.md](./references/code/chain-order.md)
- 脊柱 ⑤跳同一份链顺序清单 + 关键片段：[../e2e-request-lifecycle/references/code/05-middleware-chain.md](../e2e-request-lifecycle/references/code/05-middleware-chain.md)
- 关联 skill：[[e2e-request-lifecycle]]（⑤中间件 链路位置）、[[agent-graph-factory]]（build_middlewares 在 make_lead_agent 里调用）、[[system-prompt-template]]（DynamicContext + SystemMessageCoalescing 完整源码）、[[context-window-management]]（Summarization + LoopDetection + TokenBudget）、[[safety-and-guardrails]]（Guardrail + InputSanitization + SafetyFinishReason）、[[subagent-delegation]]（子代理基座 + 镜像防护）、[[thread-state-and-reducers]]（state 字段写权 + reducer）、[[tool-assembly-and-policy]]（deferred_setup 与工具装配同源）
- LangChain 中间件文档：https://python.langchain.com/docs/concepts/middleware
