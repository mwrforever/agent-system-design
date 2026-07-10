# ⑤ 中间件链完整源码

> 本文件是脊柱 `SKILL.md` 第⑤跳"中间件"的深度展开。脊柱只给链顺序清单 + 链尾片段；此处给 29 项链的装配逻辑（`build_lead_runtime_middlewares` + `build_middlewares`）+ 关键中间件真实片段（DynamicContext、SystemMessageCoalescing、DeferredToolFilter、ClarificationMiddleware）+ 顺序不变量。
>
> 代码已按插件匿名化规则映射到自定结构（`helix.*`），去除一切项目字样；原代码注释保真，中文注解以"注："或行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱）、`[[middleware-chain-design]]`（29 项链每项深度）、`[[system-prompt-template]]`（DynamicContext + Coalescing 完整源码）、`cross-cutting-invariants.md` 不变量 1（ClarificationMiddleware 是 `non_interactive`/`disable_clarification` 的纵深防御落点）。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `core/helix/agents/lead/agent.py` | `build_middlewares`：lead 专用，续装 13–29 |
| `core/helix/agents/middlewares/tool_error_handling_middleware.py` | `_build_runtime_middlewares` + `build_lead_runtime_middlewares`：共享基座，装 1–12 |
| `core/helix/agents/middlewares/dynamic_context_middleware.py` | 第 13 项：注入日期/记忆 `<system-reminder>` |
| `core/helix/agents/middlewares/system_message_coalescing_middleware.py` | 第 23 项：合并所有 SystemMessage 为首条 |
| `core/helix/agents/middlewares/deferred_tool_filter_middleware.py` | 第 22 项：延迟 MCP 工具，tool_search 提升前隐藏 schema |
| `core/helix/agents/middlewares/clarification_middleware.py` | 第 29 项（链尾）：拦截 `ask_clarification`，`Command(goto=END)` 中断 |

> DynamicContext 与 SystemMessageCoalescing 的**完整源码**已交付于 `[[system-prompt-template]]` skill 的 `references/code/dynamic-context-and-coalescing.md`。本文件给入口签名 + 与链顺序相关的关键片段，不重复完整实现。

---

## 1. 29 项链顺序清单

链跨两个函数组装：`build_lead_runtime_middlewares`（共享基座，子代理也复用大部分）装 1–12；`build_middlewares`（lead 专用）续装 13–29。`?` 标注的是 config/runtime 条件可选。

```
共享基座 build_lead_runtime_middlewares（子代理经 build_subagent_runtime_middlewares 复用大部分）：
 1  InputSanitization           - 最外层 wrap_model_call，所有内层（含 LLM 重试）见消毒后消息
 2  ToolOutputBudget            - 工具输出体积上限
 3  ThreadData                  - 建 per-thread 目录（user_id 隔离，跨切不变量 2）
 4  Uploads                     - 注入新上传文件（仅 lead，include_uploads=True）
 5  Sandbox                     - 申请沙箱，存 sandbox_id 到 state
 6  DanglingToolCall            - 为缺响应的 tool_call 注入占位 ToolMessage
 7  LLMErrorHandling            - 归一化模型调用失败为可恢复错误
 8  Guardrail?                  - 工具调用前授权（可插拔 GuardrailProvider）
 9  SandboxAudit                - 审计沙箱 shell/file 操作
10  ReadBeforeWrite?            - 写前必读门（content hash 校验）
11  ToolProgress?               - 工具停滞状态机守卫
12  ToolErrorHandling           - 工具异常转 ToolMessage，盖 helix_tool_meta 元数据

lead 专用 build_middlewares（agent.py）续装：
13  DynamicContext              - 注入日期/记忆 <system-reminder>（见 [[system-prompt-template]]）
14  SkillActivation             - /skill-name 显式激活，注入 SKILL.md
15  DurableContext              - 捕获 task 委派 + 技能引用，防被摘要压掉
16  Summarization?              - 上下文压缩
17  TodoList?                   - plan mode 任务追踪
18  TokenUsage?                 - 记录 token 用量
19  Title                       - 首轮交换后自动起标题
20  Memory                      - 排队异步记忆更新
21  ViewImage?                  - 视觉模型注入 base64 图像
22  DeferredToolFilter?         - 延迟 MCP 工具，tool_search 提升前隐藏 schema
23  SystemMessageCoalescing     - 合并所有 SystemMessage 为一条首条（provider 兜底）
24  SubagentLimit?              - 截断超额 task 调用，强制并发上限
25  LoopDetection?              - 检测重复 tool-call 循环并硬停
26  TokenBudget?                - 每 run token 上限
27  [custom]                    - 自定义中间件注入点
28  SafetyFinishReason?         - provider 安全终止时抑制工具执行
29  Clarification               - 链尾：拦截 ask_clarification，Command(goto=END) 中断
```

**顺序不变量**（LangChain 中间件框架规则）：
- `before_model` / `before_agent` 钩子按链表**正序**执行（第 1 项先跑）。
- `after_model` / `after_agent` 钩子按链表**逆序**执行（第 29 项先跑）。
- `wrap_model_call` / `wrap_tool_call` 是洋葱模型：链表第 1 项是**最外层**，包裹所有内层；第 N 项是最内层。
- **中断型中间件必须最后**：`ClarificationMiddleware` 返回 `Command(goto=END)` 中断 run，若它不在链尾，后面的中间件（TokenBudget 计量、SafetyFinishReason 清理）会在中断后错过 after 钩子，状态不一致。源码注释强约束：`# ClarificationMiddleware should always be last`。
- **ToolProgress 必须在 ToolErrorHandling 之外**（index 更小）：ToolProgress 的 `wrap_tool_call` 链要包住 ToolErrorHandling 的 `helix_tool_meta` stamping 步骤，否则 ToolProgress 读到未盖 meta 的结果。装配时有运行时断言守护。

---

## 2. 共享基座 `_build_runtime_middlewares` / `build_lead_runtime_middlewares`（1–12 完整）

```python
# core/helix/agents/middlewares/tool_error_handling_middleware.py
def _build_runtime_middlewares(
    *, app_config: AppConfig, include_uploads: bool,
    include_dangling_tool_call_patch: bool, lazy_init: bool = True,
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

## 3. lead 专用 `build_middlewares`（13–29 完整）

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

> 注：`build_middlewares` 也被嵌入式 `HelixClient`（lead-agent 变体）复用，需相同链。`agent_name` / `user_id` 透传保证 per-agent 记忆与 per-user skill 加载一致。`_create_summarization_middleware` / `_create_todo_list_middleware` 是本文件内工厂（配置驱动返回实例或 None）。

---

## 4. 关键中间件片段

### 4.1 DynamicContextMiddleware（第 13 项）入口

> 完整源码见 `[[system-prompt-template]]` 的 `references/code/dynamic-context-and-coalescing.md`。此处给入口签名 + 与链顺序相关的关键不变量。

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

### 4.2 SystemMessageCoalescingMiddleware（第 23 项）入口

> 完整源码见 `[[system-prompt-template]]` 的 `references/code/dynamic-context-and-coalescing.md`。

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

### 4.3 DeferredToolFilterMiddleware（第 22 项，完整）

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

### 4.4 ClarificationMiddleware（第 29 项，链尾，完整）

> 这是跨切不变量 1 的纵深防御落点：即便 `ask_clarification` 未被 `non_interactive` 剥离（如 webhook 通道走 `disable_clarification`），本中间件读 `runtime.context["disable_clarification"]` 决定是中断还是放行。

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

## 关键不变量与测试锚点

1. **链顺序确定性**：相同 `config` + `app_config` 入参，`build_middlewares` 产出相同顺序链（条件项按 config 开关稳定出现/缺失）。
2. **Clarification 必须最后**：`# ClarificationMiddleware should always be last` 注释 + 装配在 `return middlewares` 前最后 append。中断型若非链尾，TokenBudget/SafetyFinishReason 的 after 钩子错过。
3. **ToolProgress 外于 ToolErrorHandling**：构建时 `isinstance` 断言守护 index 顺序，反序 `raise RuntimeError`。
4. **InputSanitization 最外层**：在 `outer_wrappers` 首位，所有内层（含 LLM 重试）见消毒后消息。
5. **before_model 正序 / after_model 逆序**：框架规则，改链顺序时两方向都要验证。
6. **non_interactive 主防线在 ④建图**（剥离工具），**disable_clarification 纵深在本中间件**（放行已调用）：两通道独立，覆盖"无人值守不卡死"。
7. **Coalescing 不动 checkpoint**：`wrap_model_call` 经 `request.override(...)` 产新请求，`state["messages"]` 不变。
8. **阻塞 IO 卸载**：DynamicContext 的 `abefore_agent` 用 `asyncio.to_thread` + 有界超时，超时降级返回 None。

> 关联：`[[middleware-chain-design]]`（29 项链每项深度 + 顺序不变量）、`[[system-prompt-template]]`（DynamicContext + Coalescing 完整源码）、`[[context-window-management]]`（Summarization + LoopDetection + TokenBudget）、`[[safety-and-guardrails]]`（Guardrail + InputSanitization + SafetyFinishReason）、`cross-cutting-invariants.md` 不变量 1。
