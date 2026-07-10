# ④ 建图（graph factory）完整源码

> 本文件是脊柱 `SKILL.md` 第④跳"建图"的深度展开。脊柱只给入口片段；此处给 `make_lead_agent`/`_make_lead_agent`（每 run 一次的图工厂）+ `strip_internal_context_keys`（防御性抹除内部专用 key）的真实源码片段。
>
> 代码已按插件匿名化规则映射到自定结构（`core/helix.*` / `gateway.*`），去除一切项目字样；原代码注释保真，中文注解以"注："或行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱）、`[[agent-graph-factory]]`（每 run 建图深度）、`[[system-prompt-template]]`（静态提示词 + 动态注入）、`[[tool-assembly-and-policy]]`（工具装配 + 白名单）、`cross-cutting-invariants.md` 不变量 1（`non_interactive` 剥离 `ask_clarification` 的落点）。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `core/helix/agents/lead/agent.py` | `make_lead_agent`/`_make_lead_agent`：LangGraph graph factory，每 run 调一次 |
| `gateway/gateway/services.py` | `strip_internal_context_keys`：抹除非内部调用者走私的内部专用 key |

> `build_middlewares` 的完整实现见 `references/code/05-middleware-chain.md`；`apply_prompt_template` 完整实现见 `[[system-prompt-template]]` skill。本文件只摘建图入口 + 工具装配 + non_interactive 剥离 + 防御性抹除片段。

---

## 1. `core/helix/agents/lead/agent.py` - 每 run 一次的图工厂

> `make_lead_agent` 是 LangGraph graph factory，**每 run 调一次**：渲染静态系统提示词（`apply_prompt_template`，吃 prefix cache）+ 装配工具（`get_available_tools` + 技能白名单过滤 + 延迟工具）+ 构造中间件链（`build_middlewares`），最后 `create_agent` 一次性绑定。`non_interactive` 在这里剥离 `ask_clarification`（跨切不变量 1 的落点）。

```python
# core/helix/agents/lead/agent.py - 每 run 一次的图工厂
_NON_INTERACTIVE_DISABLED_TOOL_NAMES = frozenset({"ask_clarification"})

def make_lead_agent(config: RunnableConfig):
    """LangGraph graph factory; keep the signature compatible with LangGraph Server."""
    return _make_lead_agent(config, app_config=...)

def _make_lead_agent(config: RunnableConfig, *, app_config: AppConfig):
    cfg = _get_runtime_config(config)
    non_interactive = bool(cfg.get("non_interactive", False))
    resolved_user_id = str(cfg.get("user_id") or get_effective_user_id())

    # 工具装配：builtins + sandbox + mcp + skills + task
    raw_tools = get_available_tools(model_name=model_name, subagent_enabled=subagent_enabled, app_config=...)
    filtered = filter_tools_by_skill_allowed_tools(raw_tools + extra_tools, skills_for_tool_policy,
                                                   always_allowed_tool_names=SKILL_LOADING_TOOL_NAMES)
    if non_interactive:   # 无人值守：剥离 ask_clarification（跨切不变量 1）
        filtered = [t for t in filtered if t.name not in _NON_INTERACTIVE_DISABLED_TOOL_NAMES]
    final_tools, setup = assemble_deferred_tools(filtered, enabled=resolved_app_config.tool_search.enabled)

    # 一次绑定：模型 + 中间件链 + 静态系统提示词
    return create_agent(
        model=create_chat_model(name=model_name, thinking_enabled=thinking_enabled, ...),
        tools=final_tools,
        middleware=build_middlewares(config, model_name=model_name, agent_name=agent_name,
                                     available_skills=available_skills, app_config=resolved_app_config,
                                     deferred_setup=setup, user_id=resolved_user_id),
        system_prompt=apply_prompt_template(subagent_enabled=subagent_enabled, agent_name=agent_name,
                                            available_skills=available_skills, deferred_names=setup.deferred_names,
                                            user_id=resolved_user_id),
        state_schema=ThreadState)
```

> 注：`_get_runtime_config` 合并 legacy `configurable` 与 LangGraph runtime `context`，使 `_make_lead_agent` 能像读 `configurable` 一样读到 `non_interactive`（由 `start_run` 合进 `config['context']`）。`ask_clarification` 是 builtin 工具（与 `present_files` 同列 `BUILTIN_TOOLS`），故在 `filter_tools_by_skill_allowed_tools` 之后、`assemble_deferred_tools` 之前的过滤能稳定命中。

---

## 2. `gateway/gateway/services.py` - 防御性抹除：非内部调用者塞的 non_interactive 一律丢弃

> 这是跨切不变量 1 的第二道防线。`merge_run_context_overrides(..., internal=True)` 仅对内部调用者接纳 `non_interactive`；`strip_internal_context_keys` 无条件从客户端塞入的 `context`/`configurable` 抹除它（防客户端伪造无人值守）。

```python
# gateway/gateway/services.py - 防御性抹除：非内部调用者塞的 non_interactive 一律丢弃
_CONTEXT_INTERNAL_CALLER_KEYS: frozenset[str] = frozenset({"non_interactive"})

def strip_internal_context_keys(config: dict[str, Any]) -> None:
    """Drop internal-only keys a non-internal caller smuggled into the run config."""
    for section in ("context", "configurable"):
        value = config.get(section)
        if isinstance(value, dict):
            for key in _CONTEXT_INTERNAL_CALLER_KEYS:
                value.pop(key, None)
```

> 注：`_CONTEXT_INTERNAL_CALLER_KEYS` 是显式白名单（目前仅 `non_interactive`），新增内部专用 key 必须显式登记。`build_run_config` 会把客户端 `body.config['context']`/`body.config['configurable']` 原样拷贝进 `config`，故装配完成后必须再从这两节扫掉--单靠 `merge_run_context_overrides` 的 `internal` 门控还不够（双层防御）。完整 `merge_run_context_overrides` + `strip_internal_context_keys` + `launch_scheduled_thread_run` 见 `references/cross-cutting-invariants.md` 不变量 1。

---

## 关键不变量与测试锚点

1. **每 run 建图**：`make_lead_agent` 是 graph factory，每 run 调一次--工具集/中间件链/系统提示词按当前 run 的 config + app_config 实时装配，不跨 run 复用。
2. **non_interactive 剥离**（跨切不变量 1 落点）：`non_interactive=True` 时从工具列表剥离 `ask_clarification`，使无人值守 run 绝不调澄清。
3. **工具装配顺序**：`get_available_tools`（聚集四类）-> `filter_tools_by_skill_allowed_tools`（技能白名单）-> `non_interactive` 剥离 -> `assemble_deferred_tools`（延迟工具）。
4. **白名单防伪造**：`_CONTEXT_INTERNAL_CALLER_KEYS` 是显式白名单；非内部调用者的 `non_interactive` 被 `strip_internal_context_keys` 无条件抹除。
5. **确定性**：相同入参（config + app_config）产出相同工具集 + 中间件链 + 系统提示词。

> 关联：`[[agent-graph-factory]]`（每 run 建图深度）、`[[system-prompt-template]]`（`apply_prompt_template` 完整源码）、`[[tool-assembly-and-policy]]`（工具装配 + MCP + 白名单）、`references/code/05-middleware-chain.md`（`build_middlewares` 完整）、`references/cross-cutting-invariants.md` 不变量 1。
