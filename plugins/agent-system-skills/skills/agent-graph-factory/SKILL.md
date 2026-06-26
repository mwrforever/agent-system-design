---
name: agent-graph-factory
description: 当需要为 LangGraph agent 设计"每个 run 调一次的图工厂"时使用。覆盖 RunnableConfig 双通道协议（configurable × context）、运行时参数解析、模型/工具/中间件惰性装配、bootstrap 与普通分支切换。
---

## 何时用

- 你在写 `make_xxx_agent(config) -> CompiledGraph` 这种工厂函数
- 需要在 **每次** run 时根据请求动态选择模型、工具组、子代理开关
- 想支持同一个图入口承载多个"风格"（默认 / 自定义 agent / bootstrap）
- 升级 LangGraph >= 1.1 后 `ToolRuntime.context` 不再 fallback 到 `configurable`，需要规范双通道协议

## 设计思想

1. **图是 per-run 构造的，不是单例**。`make_lead_agent(config)` 每次都重新拼装，让模型 / 工具集随请求漂移；冷启动开销由 prefix cache + 工厂内 cache 抵消。
2. **`configurable` 和 `context` 双通道**：LangGraph 0.6+ 引入 `context`，1.1+ `ToolRuntime.context` 不再 fallback `configurable`。**白名单字段要双写两边**，否则中间件 / 工具拿不到值。
3. **模型解析三段式**：请求显式 model > agent 配置 model > 全局默认；未知名优雅降级到默认 + warning。
4. **bootstrap 分支**：首次创建自定义 agent 时绑定特殊工具（`setup_agent`），收紧 skill 白名单，避免在 agent 自身配置不存在时陷入半成品状态。
5. **Tracing 必须挂在图根**：`config["callbacks"]`，不能挂模型上（否则 Langfuse 看不到 `parent_run_id=None`，session_id 丢失）。

## 实现模板

```python
# agents/your_agent.py
from langchain.agents import create_agent
from langchain_core.runnables import RunnableConfig

_DEFAULT_ASSISTANT_ID = "lead_agent"
_BOOTSTRAP_SKILL_NAMES = {"bootstrap"}


def _get_runtime_config(config: RunnableConfig) -> dict:
    """合并 configurable 与 context（context 后写覆盖）。"""
    cfg = dict(config.get("configurable", {}) or {})
    ctx = config.get("context", {}) or {}
    if isinstance(ctx, dict):
        cfg.update(ctx)
    return cfg


def _resolve_model_name(requested: str | None, app_config) -> str:
    default = app_config.models[0].name if app_config.models else None
    if default is None:
        raise ValueError("No models configured.")
    if requested and app_config.get_model_config(requested):
        return requested
    if requested and requested != default:
        logger.warning("Model %r not in allowlist; fallback to %s", requested, default)
    return default


def make_lead_agent(config: RunnableConfig):
    """LangGraph Studio / Gateway 注册的图工厂。签名固定，勿改。"""
    cfg = _get_runtime_config(config)
    app_config = cfg.get("app_config") or get_app_config()

    thinking_enabled = cfg.get("thinking_enabled", True)
    is_plan_mode    = cfg.get("is_plan_mode", False)
    subagent_enabled = cfg.get("subagent_enabled", False)
    is_bootstrap    = cfg.get("is_bootstrap", False)
    agent_name      = validate_agent_name(cfg.get("agent_name"))

    agent_config = load_agent_config(agent_name) if not is_bootstrap else None
    available_skills = _BOOTSTRAP_SKILL_NAMES if is_bootstrap else (
        set(agent_config.skills) if agent_config and agent_config.skills else None
    )

    model_name = _resolve_model_name(cfg.get("model_name"), app_config)
    model_config = app_config.get_model_config(model_name)
    if thinking_enabled and not model_config.supports_thinking:
        thinking_enabled = False

    # ⭐ Tracing 挂在图根
    config.setdefault("metadata", {}).update({
        "agent_name": agent_name or "default", "model_name": model_name,
        "thinking_enabled": thinking_enabled, "is_plan_mode": is_plan_mode,
    })
    tracing_callbacks = build_tracing_callbacks()
    if tracing_callbacks:
        config["callbacks"] = [*(config.get("callbacks") or []), *tracing_callbacks]

    # 工具：config 定义 + 内置 + MCP + subagent
    raw_tools = get_available_tools(
        model_name=model_name,
        groups=agent_config.tool_groups if agent_config else None,
        subagent_enabled=subagent_enabled,
        app_config=app_config,
    )
    if is_bootstrap:
        raw_tools = raw_tools + [setup_agent_tool]
    elif agent_name:
        raw_tools = raw_tools + [update_agent_tool]

    # skill 白名单过滤 → deferred promote 切分
    filtered = filter_tools_by_skill_allowed_tools(raw_tools, load_enabled_skills(available_skills))
    final_tools, deferred_setup = assemble_deferred_tools(
        filtered, enabled=app_config.tool_search.enabled,
    )

    return create_agent(
        model=create_chat_model(model_name, thinking_enabled, attach_tracing=False),
        tools=final_tools,
        middleware=build_middlewares(
            config, model_name=model_name, agent_name=agent_name,
            available_skills=available_skills, app_config=app_config,
            deferred_setup=deferred_setup,
        ),
        system_prompt=apply_prompt_template(
            subagent_enabled=subagent_enabled, agent_name=agent_name,
            available_skills=available_skills, app_config=app_config,
            deferred_names=deferred_setup.deferred_names,
        ),
        state_schema=ThreadState,
    )
```

注册到 `langgraph.json`：

```json
{
  "graphs": {
    "lead_agent": "./agents/your_agent.py:make_lead_agent"
  }
}
```

## 反模式

- ❌ `make_xxx_agent()` 缓存编译结果当单例 → 同一进程跨用户共享 sandbox / model，破坏隔离
- ❌ 只读 `configurable` 不读 `context`（LangGraph 1.1+ 部分中间件拿不到值）
- ❌ Tracing callback 挂在 `create_chat_model` 上而非图根 → Langfuse `session_id` 丢失，双倍 token 计费
- ❌ 在工厂里抛 `ValueError("model not found")` → 应该 fallback 默认 + warning，避免 PR 改 config 时整站 500
- ✅ 工厂只做"读 cfg → 解析 → 拼装 → return"，无副作用；副作用都在中间件里

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[thread-state-and-reducers]] [[middleware-chain-design]] [[system-prompt-template]] [[tool-assembly-and-policy]] [[observability-tracing]]
- LangGraph 上下文文档：https://langchain-ai.github.io/langgraph/
