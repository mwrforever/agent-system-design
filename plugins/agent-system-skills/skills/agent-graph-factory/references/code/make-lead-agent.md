# make-lead-agent 完整源码

> 与 [SKILL.md](../../SKILL.md) 同步。本文件收录 `core/helix/agents/lead/agent.py` 的完整中间件链装配 + 辅助函数 + `core/helix/agents/__init__.py` 的懒注册。代码为真实实现（已按插件匿名化规则映射到自定结构）。真实代码的原注释保留以保真；关键处补中文注解。

---

## 1. 中间件链装配（build_middlewares，29 项链）

`build_middlewares` 是跨模块边界的稳定名称：`make_lead_agent` 与嵌入式 `HelixClient`（一个需要相同链的 lead-agent 变体）都 import 它。重命名 / 改签名会同时打断 Server 与 Client 双路。

```python
# core/helix/agents/lead/agent.py

# ThreadDataMiddleware 必须在 SandboxMiddleware 之前，确保 thread_id 可用
# UploadsMiddleware 应在 ThreadDataMiddleware 之后，以访问 thread_id
# DanglingToolCallMiddleware 在模型看到历史前补缺响应的 ToolMessage
# SummarizationMiddleware 应靠前，在其他处理前压缩上下文
# TodoListMiddleware 应在 ClarificationMiddleware 之前，允许 todo 管理
# TitleMiddleware 在首轮交换后生成标题
# MemoryMiddleware 排队异步记忆更新（在 TitleMiddleware 之后）
# ViewImageMiddleware 应在 ClarificationMiddleware 之前，在 LLM 前注入图像详情
# ToolErrorHandlingMiddleware 应在 ClarificationMiddleware 之前，把工具异常转 ToolMessage
# ClarificationMiddleware 必须永远最后，在模型调用后拦截澄清请求
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
    """基于运行时配置装配 lead-agent 中间件链。

    lead agent 全量中间件组合的公共入口。被 ``make_lead_agent`` 与嵌入式
    ``HelixClient``（需要相同链的 lead-agent 变体）共用。保持该名称稳定：它跨模块
    边界被 import，重命名 / 改签名会波及 ``client.py``。

    Args:
        config: 含 is_plan_mode 等 configurable 选项的运行时配置。
        model_name: 解析后的运行时模型名；门控纯视觉中间件。
        agent_name: 若提供，MemoryMiddleware 用 per-agent 记忆存储。
        custom_middlewares: 可选的自定义中间件列表，注入链中。
        app_config: 显式 AppConfig；缺省回退 ``get_app_config()``。
        deferred_setup: 可选的延迟 MCP 工具 setup，在 ``tool_search`` 启用时
            挂载 ``DeferredToolFilterMiddleware``。
        user_id: 用于 user 作用域技能加载的有效用户 ID。透传给
            ``SkillActivationMiddleware`` 以解析 per-user 自定义技能。

    Returns:
        中间件实例列表。
    """
    resolved_app_config = app_config or get_app_config()
    # 共享基座（1-12）：子代理也复用大部分。lazy_init=True 延迟重资源初始化到首次调用。
    middlewares = build_lead_runtime_middlewares(app_config=resolved_app_config, lazy_init=True)

    # 注入当前日期（可选记忆）为 <system-reminder> 到第一条 HumanMessage，
    # 保持系统提示词纯静态以复用 prefix cache（见 [[system-prompt-template]]）。
    from helix.agents.middlewares.dynamic_context_middleware import DynamicContextMiddleware

    middlewares.append(DynamicContextMiddleware(agent_name=agent_name, app_config=resolved_app_config))

    # 用户以 /skill-name 开头时确定性地加载完整 SKILL.md。基础系统提示词只放元数据，
    # 显式用户激活优先于模型侧的相关性猜测。
    from helix.agents.middlewares.skill_activation_middleware import SkillActivationMiddleware

    middlewares.append(SkillActivationMiddleware(available_skills=available_skills, app_config=resolved_app_config, user_id=user_id))

    # 在摘要压缩前捕获已完成的 task 委派与已加载技能文件，然后把持久上下文通道
    # （summary + ledger + skills）注入模型调用。
    from helix.agents.middlewares.durable_context_middleware import DurableContextMiddleware

    middlewares.append(
        DurableContextMiddleware(
            skills_container_path=resolved_app_config.skills.container_path,
            skill_file_read_tool_names=resolved_app_config.summarization.skill_file_read_tool_names,
        )
    )

    # 摘要中间件（若启用）
    summarization_middleware = _create_summarization_middleware(app_config=resolved_app_config)
    if summarization_middleware is not None:
        middlewares.append(summarization_middleware)

    # TodoList 中间件（若 plan mode 启用）
    cfg = _get_runtime_config(config)
    is_plan_mode = cfg.get("is_plan_mode", False)
    todo_list_middleware = _create_todo_list_middleware(is_plan_mode)
    if todo_list_middleware is not None:
        middlewares.append(todo_list_middleware)

    # TokenUsageMiddleware（若 token_usage 追踪启用）
    if resolved_app_config.token_usage.enabled:
        middlewares.append(TokenUsageMiddleware())

    # TitleMiddleware（首轮交换后自动起标题）
    middlewares.append(TitleMiddleware(app_config=resolved_app_config))

    # MemoryMiddleware（在 TitleMiddleware 之后，排队异步记忆更新）
    middlewares.append(MemoryMiddleware(agent_name=agent_name, memory_config=resolved_app_config.memory))

    # ViewImageMiddleware 仅当当前模型支持视觉时挂载。
    # 用 make_lead_agent 解析后的运行时 model_name，避免 stale config 值。
    model_config = resolved_app_config.get_model_config(model_name) if model_name else None
    if model_config is not None and model_config.supports_vision:
        middlewares.append(ViewImageMiddleware())

    # 在 tool_search 提升延迟工具前，从模型绑定隐藏其 schema。
    # deferred 集 + catalog hash 来自构建时 setup（工具策略过滤后组装）；提升从图状态读。
    if deferred_setup is not None and deferred_setup.deferred_names:
        from helix.agents.middlewares.deferred_tool_filter_middleware import DeferredToolFilterMiddleware

        middlewares.append(DeferredToolFilterMiddleware(deferred_setup.deferred_names, deferred_setup.catalog_hash))

    # 在请求到达 provider 前把所有 SystemMessage 合并为一条首条。
    # 严格后端（vLLM、SGLang、Qwen、Anthropic）拒绝非首条 SystemMessage。
    from helix.agents.middlewares.system_message_coalescing_middleware import SystemMessageCoalescingMiddleware

    middlewares.append(SystemMessageCoalescingMiddleware())

    # SubagentLimitMiddleware 截断超额并行 task 调用
    subagent_enabled = cfg.get("subagent_enabled", False)
    if subagent_enabled:
        max_concurrent_subagents = cfg.get("max_concurrent_subagents", 3)
        middlewares.append(SubagentLimitMiddleware(max_concurrent=max_concurrent_subagents))

    # LoopDetectionMiddleware 检测并打断重复 tool-call 循环
    loop_detection_config = resolved_app_config.loop_detection
    if loop_detection_config.enabled:
        middlewares.append(LoopDetectionMiddleware.from_config(loop_detection_config))

    # TokenBudgetMiddleware 每 run token 上限
    token_budget_config = resolved_app_config.token_budget
    if token_budget_config.enabled:
        from helix.agents.middlewares.token_budget_middleware import TokenBudgetMiddleware

        middlewares.append(TokenBudgetMiddleware.from_config(token_budget_config))

    # 在 ClarificationMiddleware 前注入自定义中间件
    if custom_middlewares:
        middlewares.extend(custom_middlewares)

    # SafetyFinishReasonMiddleware 在 provider 安全终止响应时抑制工具执行。
    # 注册在自定义中间件之后，使 LangChain 的逆序 after_model 派发先跑 Safety；
    # 清空的 tool_calls 再流经 Loop/Subagent 计数而不触发额外告警。
    safety_config = resolved_app_config.safety_finish_reason
    if safety_config.enabled:
        middlewares.append(SafetyFinishReasonMiddleware.from_config(safety_config))

    # ClarificationMiddleware 必须永远最后
    middlewares.append(ClarificationMiddleware())
    return middlewares
```

---

## 2. 辅助函数

### 摘要与 Todo 中间件构造器

```python
# core/helix/agents/lead/agent.py

def _create_summarization_middleware(*, app_config: AppConfig | None = None) -> HelixSummarizationMiddleware | None:
    """从配置创建并配置摘要中间件。"""
    return create_summarization_middleware(app_config=app_config)


def _create_todo_list_middleware(is_plan_mode: bool) -> TodoMiddleware | None:
    """创建并配置 TodoList 中间件。

    Args:
        is_plan_mode: 是否启用带 TodoList 中间件的 plan mode。

    Returns:
        若 plan mode 启用返回 TodoMiddleware 实例，否则 None。
    """
    if not is_plan_mode:
        return None

    # 匹配 Helix 风格的自定义提示词
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
- Don't be afraid to revise the todo list as you learn more

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
3. **User explicitly requests todo list**: When the user directly asks you to track tasks
4. **Multiple tasks**: When users provide a list of things to be done
5. **Dynamic planning**: When the plan may need updates based on intermediate results

## When NOT to Use

Skip this tool when:
1. The task is straightforward and takes less than 3 steps
2. The task is trivial and tracking provides no benefit
3. The task is purely conversational or informational
4. It's clear what needs to be done and you can just do it

## How to Use

1. **Starting a task**: Mark a task as `in_progress` BEFORE beginning work
2. **Completing a task**: Mark a task as `completed` IMMEDIATELY after finishing
3. **Updating the list**: Add new tasks, remove irrelevant ones, or update descriptions as needed
4. **Multiple updates**: You can make several updates at once (e.g., complete one task and start the next)

## Task States

- `pending`: Task not yet started
- `in_progress`: Currently working on (can have multiple if tasks can run in parallel)
- `completed`: Task finished successfully

## Task Completion Requirements

**CRITICAL: Only mark a task as completed when you have FULLY accomplished it.**

Never mark a task as completed when:
- There are unresolved issues or errors
- Work is partial or incomplete
- You encountered blockers preventing completion
- You couldn't find necessary resources or dependencies
- Quality standards haven't been met

If blocked, keep the task as `in_progress` and create a new task describing what needs to be resolved.

## Best Practices

- Create specific, actionable items
- Break complex tasks into smaller, manageable steps
- Use clear, descriptive task names
- Update task status in real-time as you work
- Mark todos complete IMMEDIATELY after finishing (don't batch)
- Remove tasks that are no longer relevant
- **IMPORTANT**: When you write the todo list, mark your first task(s) as `in_progress` immediately
- **IMPORTANT**: Unless all tasks are completed, always have at least one task `in_progress` to show progress

Being proactive with task management demonstrates thoroughness and ensures all requirements are completed successfully.

**Remember**: If you only need a few tool calls to complete a task and it's clear what to do, it's better to just do the task directly and NOT use this tool at all.
"""

    return TodoMiddleware(system_prompt=system_prompt, tool_description=tool_description)
```

### 技能名解析与工具策略加载

```python
# core/helix/agents/lead/agent.py

def _available_skill_names(agent_config, is_bootstrap: bool) -> set[str] | None:
    """解析本次 run 的技能白名单。

    - bootstrap：锁定 {"bootstrap"}，保证引导流程确定。
    - 自定义 agent 且配置了 skills：返回配置的技能集。
    - 否则 None（不过滤，全量技能可用）。
    """
    if is_bootstrap:
        return set(_BOOTSTRAP_SKILL_NAMES)
    if agent_config and agent_config.skills is not None:
        return set(agent_config.skills)
    return None


def _load_enabled_skills_for_tool_policy(available_skills: set[str] | None, *, app_config: AppConfig, user_id: str | None = None) -> list[Skill]:
    """加载已启用技能用于工具策略过滤。

    先从 app_config + user_id 加载全量已启用技能（per-user 自定义技能），
    再按 available_skills 白名单过滤。available_skills 为 None 时返回全量。
    """
    try:
        from helix.agents.lead_agent.prompt import get_enabled_skills_for_config

        skills = get_enabled_skills_for_config(app_config, user_id=user_id)
    except Exception:
        logger.exception("Failed to load skills for allowed-tools policy")
        raise

    if available_skills is None:
        return skills
    return [skill for skill in skills if skill.name in available_skills]
```

---

## 3. 模块顶部 tracing 不变量注释

`core/helix/agents/lead/agent.py` 模块 docstring 用 INVARIANT 注释枚举所有图内 `create_chat_model` 调用点，强制新增点必须 `attach_tracing=False`：

```python
# core/helix/agents/lead/agent.py - 模块顶部 docstring
"""Lead agent factory.

INVARIANT - tracing callback placement
======================================

Tracing callbacks (Langfuse, LangSmith) are attached at the **graph
invocation root** in :func:`_make_lead_agent` (see the
``build_tracing_callbacks()`` block that appends to ``config["callbacks"]``).
Every ``create_chat_model(...)`` call inside this module - and inside any
middleware reachable from this graph (e.g. ``TitleMiddleware``) - MUST pass
``attach_tracing=False``.

Forgetting that flag emits duplicate spans (one rooted at the graph, one at
the model) AND prevents the Langfuse handler's ``propagate_attributes``
path from firing, so ``session_id`` / ``user_id`` never reach the trace.
The four current sites are: bootstrap agent, default agent, summarization
middleware, and the async path inside ``TitleMiddleware``. Any new in-graph
``create_chat_model`` call must add to this list and pass the flag.
"""
```

---

## 4. langgraph.json 入口的懒注册

`langgraph.json` 注册 `"lead_agent": "helix.agents:make_lead_agent"`。LangGraph 解析该入口字符串时触发 `core/helix/agents/__init__.py` 的 `__getattr__`，惰性 import `make_lead_agent` 并预热技能缓存。这样轻量子模块 import 不会拉进整条 tool/subagent 依赖图。

```python
# core/helix/agents/__init__.py
from .features import Next, Prev, RuntimeFeatures

__all__ = [
    "create_helix_agent",
    "RuntimeFeatures",
    "Next",
    "Prev",
    "make_lead_agent",
    "SandboxState",
    "ThreadState",
]


def __getattr__(name: str):
    if name == "create_helix_agent":
        from .factory import create_helix_agent

        globals()[name] = create_helix_agent
        return create_helix_agent
    if name == "make_lead_agent":
        from .lead_agent import make_lead_agent
        from .lead_agent.prompt import prime_enabled_skills_cache

        # LangGraph 解析 helix.agents:make_lead_agent 时注册图。在这个显式入口
        # 预热缓存，而非包 import 时，这样轻量子模块可以不拉进整条
        # tool/subagent 图就被 import。
        prime_enabled_skills_cache()
        globals()[name] = make_lead_agent
        return make_lead_agent
    if name in {"SandboxState", "ThreadState"}:
        from .thread_state import SandboxState, ThreadState

        exports = {"SandboxState": SandboxState, "ThreadState": ThreadState}
        globals().update(exports)
        return exports[name]
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
```

---

相关 skill：[[middleware-chain-design]]（29 项链每项深度 + 顺序不变量）、[[system-prompt-template]]（DynamicContext + SystemMessageCoalescing）、[[tool-assembly-and-policy]]（filter + assemble_deferred）、[[observability-tracing]]（tracing 挂图根）
