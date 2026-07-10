# 中间件链装配完整源码（base + lead-only 双段）

> 与 [SKILL.md](../../SKILL.md) 同步。本文件是 `middleware-chain-design` skill 的深度代码落点：收录**共享基座**（`_build_runtime_middlewares` / `build_lead_runtime_middlewares` / `build_subagent_runtime_middlewares`，base 段，子代理也复用）+ **lead 专用**（`build_middlewares`，续装 13–29）+ 构造器辅助函数的完整真实源码。
>
> 代码为真实实现（已按插件匿名化规则映射到自定结构 `helix.*`，去除一切项目字样）。真实代码的原注释保留以保真；关键处补中文注解（以"注："或行内 `#` 标注）。
>
> 关联：
> - `[[e2e-request-lifecycle]]` 脊柱 ⑤跳的 [references/code/05-middleware-chain.md](../../../e2e-request-lifecycle/references/code/05-middleware-chain.md) 已给同一份链顺序清单 + 关键中间件片段；本文件补齐**共享基座含子代理变体**的完整装配，并把两段装配合并为单一权威源。
> - `[[agent-graph-factory]]` 的 [references/code/make-lead-agent.md](../../../agent-graph-factory/references/code/make-lead-agent.md) 含同一份 `build_middlewares` lead-only body（因 `build_middlewares` 住在 `agent.py`，与图工厂同文件）；本文件为中间件链视角的权威展开，两处代码一致。
> - hook 类型标注（`before_agent` / `before_model` / `wrap_model_call` / `after_model` / `wrap_tool_call` / `after_agent`）见 [chain-order.md](./chain-order.md)。

---

## 文件清单

| 自定结构路径 | 真实职责 |
|---|---|
| `core/helix/agents/middlewares/tool_error_handling_middleware.py` | `_build_runtime_middlewares`（共享基座核心）+ `build_lead_runtime_middlewares`（lead 基座入口）+ `build_subagent_runtime_middlewares`（子代理基座入口）+ `ToolErrorHandlingMiddleware`（第 12 项） |
| `core/helix/agents/lead/agent.py` | `build_middlewares`（lead 专用，续装 13–29）+ `_create_summarization_middleware` / `_create_todo_list_middleware` 构造器 |
| `core/helix/agents/middlewares/clarification_middleware.py` | 第 29 项（链尾）：`ClarificationMiddleware` 拦截 `ask_clarification`，`Command(goto=END)` 中断（完整源码见 [chain-order.md](./chain-order.md) 与脊柱 05-middleware-chain.md） |
| `core/helix/agents/middlewares/dynamic_context_middleware.py` | 第 13 项：注入日期/记忆 `<system-reminder>`（完整源码见 `[[system-prompt-template]]` 的 references/code/dynamic-context-and-coalescing.md） |
| `core/helix/agents/middlewares/system_message_coalescing_middleware.py` | 第 23 项：合并所有 SystemMessage 为首条（完整源码见 `[[system-prompt-template]]`） |

---

## 1. 共享基座 `_build_runtime_middlewares`（base 段 1–12 完整）

`_build_runtime_middlewares` 是 base 段的核心：lead 与子代理都调它，靠 `include_uploads` / `include_dangling_tool_call_patch` 两个开关区分。它把中间件按**三层**组装：外层 `wrap_model_call` 包装（Layer 1）-> `before_agent` 线程级钩子（Layer 2）-> 后处理 append-only 尾部（Layer 3），最后 `[*outer_wrappers, *thread_hooks, *tail]` 拼成 1–12 序列。

```python
# core/helix/agents/middlewares/tool_error_handling_middleware.py
def _build_runtime_middlewares(
    *,
    app_config: AppConfig,
    include_uploads: bool,
    include_dangling_tool_call_patch: bool,
    lazy_init: bool = True,
) -> list[AgentMiddleware]:
    """构建 agent 执行的共享基座中间件。"""
    from helix.agents.middlewares.input_sanitization_middleware import InputSanitizationMiddleware
    from helix.agents.middlewares.llm_error_handling_middleware import LLMErrorHandlingMiddleware
    from helix.agents.middlewares.thread_data_middleware import ThreadDataMiddleware
    from helix.agents.middlewares.tool_output_budget_middleware import ToolOutputBudgetMiddleware
    from helix.sandbox.middleware import SandboxMiddleware

    # Layer 1 - 最外层 wrap_model_call 包装（外->内列出）。
    # InputSanitizationMiddleware 在最前，成为最外层包装--消毒后的消息是每个内层中间件看到的。
    outer_wrappers: list[AgentMiddleware] = [
        InputSanitizationMiddleware(),                                    # 1
        ToolOutputBudgetMiddleware.from_app_config(app_config),           # 2
    ]

    # Layer 2 - 读/标注 thread 级数据的 before_agent 钩子。
    thread_hooks: list[AgentMiddleware] = [
        ThreadDataMiddleware(lazy_init=lazy_init),                        # 3
    ]
    if include_uploads:
        from helix.agents.middlewares.uploads_middleware import UploadsMiddleware
        thread_hooks.append(UploadsMiddleware())                          # 4（仅 lead）
    thread_hooks.append(SandboxMiddleware(lazy_init=lazy_init))           # 5

    # Layer 3 - 后处理 append-only 中间件。
    tail: list[AgentMiddleware] = []
    if include_dangling_tool_call_patch:
        from helix.agents.middlewares.dangling_tool_call_middleware import DanglingToolCallMiddleware
        tail.append(DanglingToolCallMiddleware())                         # 6
    tail.append(LLMErrorHandlingMiddleware(app_config=app_config))        # 7

    # Guardrail 中间件（若配置）
    guardrails_config = app_config.guardrails
    if guardrails_config.enabled and guardrails_config.provider:
        import inspect
        from helix.guardrails.middleware import GuardrailMiddleware
        from helix.reflection import resolve_variable

        provider_cls = resolve_variable(guardrails_config.provider.use)
        provider_kwargs = dict(guardrails_config.provider.config) if guardrails_config.provider.config else {}
        # 若 provider 接受则传 framework hint（如用于配置发现）。内置 provider 如 AllowlistProvider
        # 不需要，故仅在构造器接受 'framework' 或 '**kwargs' 时注入。
        if "framework" not in provider_kwargs:
            try:
                sig = inspect.signature(provider_cls.__init__)
                if "framework" in sig.parameters or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
                    provider_kwargs["framework"] = "helix"               # 注：品牌已匿名化
            except (ValueError, TypeError):
                pass
        provider = provider_cls(**provider_kwargs)
        tail.append(GuardrailMiddleware(provider, fail_closed=guardrails_config.fail_closed,
                                        passport=guardrails_config.passport))  # 8?

    from helix.agents.middlewares.sandbox_audit_middleware import SandboxAuditMiddleware
    tail.append(SandboxAuditMiddleware())                                 # 9

    # ReadBeforeWriteMiddleware 是最外层写门：阻断对模型尚未读（当前版本）的文件的写。
    # 必须在 ToolProgress 与 ToolErrorHandling 之外，使被阻断的写立即返回、不消耗 ToolProgress 槽。
    # 中间件在被阻断的 ToolMessage 上盖 helix_tool_meta，使下游收到格式良好的结果。
    if app_config.read_before_write.enabled:
        from helix.agents.middlewares.read_before_write_middleware import ReadBeforeWriteMiddleware
        tail.append(ReadBeforeWriteMiddleware())                          # 10?

    # ToolProgressMiddleware 必须在外（index 更小），使其 wrap_tool_call 处理链包住
    # ToolErrorHandlingMiddleware（内层），后者在每个结果上盖 helix_tool_meta 后
    # ToolProgressMiddleware 才在 _update_state_from_result 里读它。
    # 框架规则：链表第一项 = 最外层（types.py: "compose with first in list as outermost layer"）。
    tool_progress_config = app_config.tool_progress
    _ToolProgressMiddleware = None
    if tool_progress_config.enabled:
        from helix.agents.middlewares.tool_progress_middleware import ToolProgressMiddleware as _ToolProgressMiddleware
        tail.append(_ToolProgressMiddleware.from_config(tool_progress_config))  # 11?

    tail.append(ToolErrorHandlingMiddleware(app_config=app_config))        # 12

    middlewares = [*outer_wrappers, *thread_hooks, *tail]

    # 守卫：ToolProgressMiddleware（外）必须在 ToolErrorHandlingMiddleware（内）之前，
    # 使其 wrap_tool_call 链包住 stamping 步骤。若未来插入反序，构建时硬失败而非运行时静默 no-op。
    # 用 isinstance（非 type().__name__）覆盖子类与重命名。
    if _ToolProgressMiddleware is not None:
        _progress_idx = next((i for i, m in enumerate(middlewares) if isinstance(m, _ToolProgressMiddleware)), None)
        _error_idx = next((i for i, m in enumerate(middlewares) if isinstance(m, ToolErrorHandlingMiddleware)), None)
        if _progress_idx is not None and _error_idx is not None and _progress_idx > _error_idx:
            raise RuntimeError(f"ToolProgressMiddleware must be outer (index {_progress_idx}) of ToolErrorHandlingMiddleware (index {_error_idx}) - check middleware append order")

    return middlewares


def build_lead_runtime_middlewares(*, app_config: AppConfig, lazy_init: bool = True) -> list[AgentMiddleware]:
    """lead agent 运行时在 lead 专用中间件之前共享的中间件。"""
    return _build_runtime_middlewares(
        app_config=app_config,
        include_uploads=True,                 # 注：lead 才注入 uploads；子代理 include_uploads=False
        include_dangling_tool_call_patch=True,
        lazy_init=lazy_init,
    )
```

---

## 2. 子代理基座 `build_subagent_runtime_middlewares`（base 段的子代理变体）

子代理复用 base 段的 1–12（`include_uploads=False`，不注入 Uploads），再按子代理特性续装与 lead 镜像的防护中间件（ViewImage / DeferredToolFilter / LoopDetection / TokenBudget / SafetyFinishReason）。**子代理不挂 lead 专用的 13–23**（DynamicContext / SkillActivation / DurableContext / Summarization / Todo / TokenUsage / Title / Memory / SystemMessageCoalescing 等）--这些是 lead 的上下文/编排职责，子代理跑成本敏感、不需要。

```python
# core/helix/agents/middlewares/tool_error_handling_middleware.py
def build_subagent_runtime_middlewares(
    *,
    app_config: AppConfig | None = None,
    model_name: str | None = None,
    lazy_init: bool = True,
    deferred_setup: "DeferredToolSetup | None" = None,
    agent_name: str | None = None,
) -> list[AgentMiddleware]:
    """Middlewares shared by subagent runtime before subagent-only middlewares."""
    if app_config is None:
        from helix.config import get_app_config
        app_config = get_app_config()

    # 子代理复用 base 段 1-12，但不注入 uploads（include_uploads=False）
    middlewares = _build_runtime_middlewares(
        app_config=app_config,
        include_uploads=False,
        include_dangling_tool_call_patch=True,
        lazy_init=lazy_init,
    )

    if model_name is None and app_config.models:
        model_name = app_config.models[0].name

    model_config = app_config.get_model_config(model_name) if model_name else None
    if model_config is not None and model_config.supports_vision:
        from helix.agents.middlewares.view_image_middleware import ViewImageMiddleware
        middlewares.append(ViewImageMiddleware())

    # 隐藏延迟（MCP）工具 schema，直到 tool_search 提升它们。与 lead 同一接线。
    # 延迟集 + catalog hash 来自构建时 setup（工具策略过滤后组装）；提升从图状态读。
    # 空/None setup（延迟禁用或无 MCP 工具存活）是纯 no-op。
    if deferred_setup is not None and deferred_setup.deferred_names:
        from helix.agents.middlewares.deferred_tool_filter_middleware import DeferredToolFilterMiddleware
        middlewares.append(DeferredToolFilterMiddleware(deferred_setup.deferred_names, deferred_setup.catalog_hash))

    # LoopDetectionMiddleware - 子代理今日不继承 lead 的失控防护（见 #3875）：无 loop detection
    # 时一个退化子代理工具循环会不受检地跑到 max_turns，每轮重发增长的上下文
    # （报告中的 4.4M token 烧穿）。镜像 lead 链使循环被检测并打断。子代理禁用 task，
    # 故只有工具循环启发式会触发--无递归委派路径会误报。
    # 注册在 SafetyFinishReasonMiddleware 之前（链表中更靠前）。
    # LangChain 以**逆序**注册顺序派发 after_model 钩子，故下方 append 的
    # SafetyFinishReasonMiddleware 先执行，剥离安全终止的 tool_calls；LoopDetectionMiddleware
    # 再对清理后的消息计数。这是 SafetyFinishReasonMiddleware docstring 要求的位置
    # （"register after LoopDetection"），并镜像 lead 链（lead_agent/agent.py）。
    loop_detection_config = app_config.loop_detection
    if loop_detection_config.enabled:
        from helix.agents.middlewares.loop_detection_middleware import LoopDetectionMiddleware
        middlewares.append(LoopDetectionMiddleware.from_config(loop_detection_config))

    # TokenBudgetMiddleware - 子代理今日不继承 lead 的成本兜底（#3875 Phase 2）：
    # 退化子代理可在 max_turns/timeout 介入前烧穿病态 token 量（报告中的 4.4M run）。
    # 镜像 lead 链使每 run 预算硬停介入。subagents.token_budget 默认启用；
    # per-agent 覆盖经 subagents.agents.<name>.token_budget。硬停不抛异常--
    # 它剥离 tool_calls 使 run 以最终答案完成--executor 读 consume_stop_reason
    # 标记完成结果为 token_capped 供 lead 可见。状态以 run_id 为键，每个 task run
    # 构建新中间件实例（见 executor._create_agent），故并行子代理不会交叉污染，
    # 即使它们在 context 共享父 thread_id/run_id。
    token_budget_config = app_config.subagents.get_token_budget_for(agent_name) if agent_name is not None else app_config.subagents.token_budget
    if token_budget_config.enabled:
        from helix.agents.middlewares.token_budget_middleware import TokenBudgetMiddleware
        middlewares.append(TokenBudgetMiddleware.from_config(token_budget_config))

    # 与 lead 相同的 provider 安全终止防护 - 子代理同样暴露于 finish_reason=content_filter
    # （等）返回的截断 tool_calls，坏调用会经 task 工具结果传播回 lead agent。
    safety_config = app_config.safety_finish_reason
    if safety_config.enabled:
        from helix.agents.middlewares.safety_finish_reason_middleware import SafetyFinishReasonMiddleware
        middlewares.append(SafetyFinishReasonMiddleware.from_config(safety_config))

    return middlewares
```

> **两段对比**：lead 走 `build_lead_runtime_middlewares`（1–12，含 Uploads）-> `build_middlewares`（13–29，含 DynamicContext/SkillActivation/Summarization/Title/Memory/Coalescing/Clarification 链尾）；子代理走 `build_subagent_runtime_middlewares`（1–12，不含 Uploads）-> 镜像防护（ViewImage/Deferred/Loop/TokenBudget/Safety）。子代理**不挂** ClarificationMiddleware（子代理不允许 `ask_clarification`，无中断需求）。

---

## 3. lead 专用 `build_middlewares`（lead-only 13–29 完整）

`build_middlewares` 先调 `build_lead_runtime_middlewares` 拿到 1–12 基座，再续装 13–29。顺序约束注释（原样保留）枚举了每项的相对位置理由。`build_middlewares` 是跨模块边界的稳定名称：`make_lead_agent` 与嵌入式 `HelixClient`（需要相同链的 lead-agent 变体）都 import 它，重命名/改签名会波及 `client.py`。

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

    Args:
        config: 含 is_plan_mode 等 configurable 选项的运行时配置。
        model_name: 解析后的运行时模型名；门控视觉专用中间件。
        agent_name: 提供时 MemoryMiddleware 用 per-agent 记忆存储。
        custom_middlewares: 可选自定义中间件列表，注入链中。
        app_config: 显式 AppConfig；缺省回退 get_app_config()。
        deferred_setup: 可选延迟 MCP 工具 setup，tool_search 启用时挂 DeferredToolFilterMiddleware。
        user_id: 用户级 skill 加载的有效 user ID。透传给 SkillActivationMiddleware 解析 per-user 自定义 skill。

    Returns:
        中间件实例列表。
    """
    resolved_app_config = app_config or get_app_config()
    middlewares = build_lead_runtime_middlewares(app_config=resolved_app_config, lazy_init=True)  # 1-12

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

    # 启用则加摘要中间件
    summarization_middleware = _create_summarization_middleware(app_config=resolved_app_config)
    if summarization_middleware is not None:
        middlewares.append(summarization_middleware)                       # 16?

    # plan mode 启用则加 TodoList 中间件
    cfg = _get_runtime_config(config)
    is_plan_mode = cfg.get("is_plan_mode", False)
    todo_list_middleware = _create_todo_list_middleware(is_plan_mode)
    if todo_list_middleware is not None:
        middlewares.append(todo_list_middleware)                           # 17?

    # token_usage 跟踪启用则加
    if resolved_app_config.token_usage.enabled:
        middlewares.append(TokenUsageMiddleware())                        # 18?

    # Title 中间件（首轮交换后起标题）
    middlewares.append(TitleMiddleware(app_config=resolved_app_config))    # 19

    # Memory 中间件（在 Title 之后，排队异步记忆更新）
    middlewares.append(MemoryMiddleware(agent_name=agent_name, memory_config=resolved_app_config.memory))  # 20

    # 仅当前模型支持视觉时加 ViewImageMiddleware。
    # 用 make_lead_agent 解析后的运行时 model_name，避免 stale config 值。
    model_config = resolved_app_config.get_model_config(model_name) if model_name else None
    if model_config is not None and model_config.supports_vision:
        middlewares.append(ViewImageMiddleware())                         # 21?

    # tool_search 提升前隐藏延迟工具 schema。延迟集合 + catalog hash 来自构建时
    # setup（工具策略过滤后装配）；提升状态从 graph state 读。
    if deferred_setup is not None and deferred_setup.deferred_names:
        from helix.agents.middlewares.deferred_tool_filter_middleware import DeferredToolFilterMiddleware
        middlewares.append(DeferredToolFilterMiddleware(deferred_setup.deferred_names,
                                                        deferred_setup.catalog_hash))  # 22?

    # 请求到达 provider 前把每条 SystemMessage 合并为单一首条。严格后端
    # （vLLM、SGLang、Qwen、Anthropic）拒绝非首条 SystemMessage。见 system_message_coalescing_middleware.py。
    from helix.agents.middlewares.system_message_coalescing_middleware import SystemMessageCoalescingMiddleware
    middlewares.append(SystemMessageCoalescingMiddleware())                # 23

    # SubagentLimitMiddleware 截断超额并行 task 调用
    subagent_enabled = cfg.get("subagent_enabled", False)
    if subagent_enabled:
        max_concurrent_subagents = cfg.get("max_concurrent_subagents", 3)
        middlewares.append(SubagentLimitMiddleware(max_concurrent=max_concurrent_subagents))  # 24?

    # LoopDetectionMiddleware - 检测并打断重复 tool call 循环
    loop_detection_config = resolved_app_config.loop_detection
    if loop_detection_config.enabled:
        middlewares.append(LoopDetectionMiddleware.from_config(loop_detection_config))  # 25?

    # TokenBudgetMiddleware - 强制 per-run token 上限
    token_budget_config = resolved_app_config.token_budget
    if token_budget_config.enabled:
        from helix.agents.middlewares.token_budget_middleware import TokenBudgetMiddleware
        middlewares.append(TokenBudgetMiddleware.from_config(token_budget_config))  # 26?

    # 在 ClarificationMiddleware 前注入自定义中间件
    if custom_middlewares:
        middlewares.extend(custom_middlewares)                            # 27

    # SafetyFinishReasonMiddleware - provider 安全终止响应时抑制工具执行。
    # 注册在自定义中间件之后，使 LangChain 逆序 after_model 分派先跑 Safety；
    # 清空的 tool_calls 再流经 Loop/Subagent 计量而不触发额外告警。
    # 见 safety_finish_reason_middleware.py docstring。
    safety_config = resolved_app_config.safety_finish_reason
    if safety_config.enabled:
        middlewares.append(SafetyFinishReasonMiddleware.from_config(safety_config))  # 28?

    # ClarificationMiddleware should always be last
    middlewares.append(ClarificationMiddleware())                          # 29 - 注：链尾硬约束
    return middlewares
```

---

## 4. 构造器辅助函数

`_create_summarization_middleware` 与 `_create_todo_list_middleware` 是 `agent.py` 内的配置驱动工厂：返回实例或 `None`（`None` 时 `build_middlewares` 跳过 append）。

```python
# core/helix/agents/lead/agent.py
def _create_summarization_middleware(*, app_config: AppConfig | None = None) -> HelixSummarizationMiddleware | None:
    """从配置创建并配置摘要中间件。"""
    return create_summarization_middleware(app_config=app_config)


def _create_todo_list_middleware(is_plan_mode: bool) -> TodoMiddleware | None:
    """创建并配置 TodoList 中间件。

    Args:
        is_plan_mode: 是否启用 plan mode（带 TodoList 中间件）。

    Returns:
        plan mode 启用时返回 TodoMiddleware 实例，否则 None。
    """
    if not is_plan_mode:
        return None

    # 自定义提示词，匹配产品风格
    system_prompt = """
<todo_list_system>
You have access to the `write_todos` tool to help you manage and track complex multi-step objectives.

**CRITICAL RULES:**
- Mark todos as completed IMMEDIATELY after finishing each step - do NOT batch completions
- Keep EXACTLY ONE task as `in_progress` at any time (unless tasks can run in parallel)
- Update the todo list in REAL-TIME as you work - this gives users visibility into your progress
- DO NOT use this tool for simple tasks (< 3 steps) - just complete them directly

**When to Use:**
This tool is designed for complex objectives that require systematic tracking:
- Complex multi-step tasks requiring 3+ distinct steps
- Non-trivial tasks needing careful planning and execution
- User explicitly requests a todo list
- User provides multiple tasks (numbered or comma-separated list)
- The plan may need revisions based on intermediate results

**When NOT to Use:**
- Single, straightforward tasks
- Trivial tasks (< 3 steps)
- Purely conversational or informational requests
- Simple tool calls where the approach is obvious

**Best Practices:**
- Break down complex tasks into smaller, actionable steps
- Use clear, descriptive task names
- Remove tasks that become irrelevant
- Add new tasks discovered during implementation
- Don't be afraid to revise the todo list as you learn

**Task Management:**
Writing todos takes time and tokens - use it when helpful for managing complex problems, not for simple requests.
</todo_list_system>
"""

    tool_description = """Use this tool to create and manage a structured task list for complex work sessions.

**IMPORTANT: Only use this tool for complex tasks (3+ steps). For simple requests, just do the work directly.**

## When to Use

Use this tool in these scenarios:
1. **Complex multi-step tasks**: When a task requires 3 or more distinct steps or actions
2. **Non-trivial tasks**: Tasks requiring careful planning or multiple operations
3. **User explicitly requests todo list**: When the user directly asks you to track
4. **Multiple tasks**: When users provide a list of things
5. **Dynamic planning**: When the plan may need updates based on intermediate results

## When NOT to Use

Skip this tool when:
1. The task is straightforward and takes less than 3 steps
2. The task is trivial and tracking provides no benefit
3. The task is purely conversational or informational
4. It's clear what needs to be done and you can just do it

## How to Use

1. **Starting a task**: Mark it as `in_progress` BEFORE beginning work
2. **Completing a task**: Mark it as `completed` IMMEDIATELY after finishing
3. **Updating the list**: Add new tasks, remove irrelevant ones, or update descriptions as needed
4. **Multiple updates**: You can make several updates at once (e.g., complete one and start the next)

## Task States

- `pending`: Task not yet started
- `in_progress`: Currently working on (can have multiple if tasks run in parallel)
- `completed`: Task finished successfully

## Task Completion Requirements

**CRITICAL: Only mark a task as completed when you have FULLY accomplished it.**

Never mark a task as completed if:
- There are unresolved issues or errors
- Work is partial or incomplete
- You encountered blockers preventing completion
- You couldn't find necessary resources or dependencies
- Quality standards haven't been met

If blocked, keep it as `in_progress` and create a new task describing what needs to be resolved.

## Best Practices

- Create specific, actionable items
- Break complex tasks into smaller, manageable steps
- Use clear, descriptive task names
- Update task status in real-time as you work
- Mark tasks complete IMMEDIATELY after finishing (don't batch)
- Remove tasks that are no longer relevant
- **IMPORTANT**: When you write the todo list, mark your first task(s) as `in_progress` immediately
- **IMPORTANT**: Unless all tasks are completed, always have at least one task `in_progress` to show progress

Being proactive with task management demonstrates thoroughness and ensures all requirements are completed successfully.

**Remember**: If you only need a few tool calls to complete a task and it's clear what to do, it's better to just do the task directly and NOT use this tool at all.
"""

    return TodoMiddleware(system_prompt=system_prompt, tool_description=tool_description)
```

> 注：`HelixSummarizationMiddleware`（真实类名含品牌前缀，已按 CONVENTIONS §3 映射为 `Helix` 前缀）与 `create_summarization_middleware` 来自 `helix.agents.middlewares.summarization_middleware`。`TodoMiddleware` 来自 `helix.agents.middlewares.todo_middleware`。

---

## 关键不变量与测试锚点

1. **链顺序确定性**：相同 `config` + `app_config` 入参，`build_middlewares` 产出相同顺序链（条件项按 config 开关稳定出现/缺失）。
2. **Clarification 必须最后**：`# ClarificationMiddleware should always be last` 注释 + 装配在 `return middlewares` 前最后 append。中断型若非链尾，TokenBudget/SafetyFinishReason 的 after 钩子错过。
3. **ToolProgress 外于 ToolErrorHandling**：构建时 `isinstance` 断言守护 index 顺序，反序 `raise RuntimeError`。
4. **InputSanitization 最外层**：在 `outer_wrappers` 首位，所有内层（含 LLM 重试）见消毒后消息。
5. **before_model 正序 / after_model 逆序**：框架规则，改链顺序时两方向都要验证。
6. **base 段复用**：lead（`include_uploads=True`）与子代理（`include_uploads=False`）共享 `_build_runtime_middlewares`，差异仅在开关 + 续装段。
7. **子代理不挂 Clarification**：`build_subagent_runtime_middlewares` 不 append `ClarificationMiddleware`（子代理禁 `ask_clarification`，无中断需求）。
8. **Safety 注册在 Loop 之后**：LangChain 逆序 after_model 派发使 Safety 先跑、清空 tool_calls，Loop 再对清理后消息计数（`safety_finish_reason_middleware.py` docstring 要求）。

> 关联：`[[e2e-request-lifecycle]]`（⑤中间件 在链路中的位置）、`[[system-prompt-template]]`（DynamicContext + Coalescing 完整源码）、`[[context-window-management]]`（Summarization + LoopDetection + TokenBudget）、`[[safety-and-guardrails]]`（Guardrail + InputSanitization + SafetyFinishReason）、`[[subagent-delegation]]`（子代理基座 + 镜像防护）。
