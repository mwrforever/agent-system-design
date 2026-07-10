---
name: agent-graph-factory
description: 当需要为 LangGraph agent 设计"每个 run 调一次的图工厂"时使用。完整覆盖 RunnableConfig 双通道协议（configurable × context：启动期定型 vs 每 run 变化）、make_lead_agent 工厂的真实装配流程（模型三段降级 + 工具白名单过滤 + non_interactive 剥离 + 中间件链 + 静态 prompt 一次绑定）、图特性 RuntimeFeatures（声明式 feature flag + @Next/@Prev 定位）、tracing 挂图根不变量、bootstrap/webhook 分支。给出完整、未截断的真实代码。当你要写 graph factory、规范双通道字段、排查"工具/中间件拿不到 context 值"、定位 tracing session_id 丢失时调用本 skill。
---

## 何时用

- 你在写 `make_xxx_agent(config: RunnableConfig) -> CompiledGraph` 这种 LangGraph 图工厂
- 需要确认图是**每 run 重建**而非单例缓存，以及为什么这么做
- 升级 LangGraph >= 1.1 后 `ToolRuntime.context` 不再 fallback 到 `configurable`，要规范双通道字段写法
- 排查"中间件 / 工具拿不到 `non_interactive` / `user_id` / `agent_name`"这类 context 丢失问题
- 排查 tracing `session_id` / `user_id` 丢失或 token 双倍计费（callback 挂错位置）
- 要用 SDK 层纯参数工厂（`RuntimeFeatures` + `@Next`/`@Prev`）声明式装配 agent，而非 config 驱动

## 设计方案（为什么这么设计）

### 核心矛盾：图该单例缓存，还是每 run 重建？

生产 agent 的模型、工具集、中间件链、系统提示词都要**随请求漂移**：不同的 `model_name` / `agent_name` / `subagent_enabled` / `is_plan_mode` / `is_bootstrap`、per-user 的技能白名单、`non_interactive` 剥离 `ask_clarification`、webhook 通道扣留 `update_agent`。一个单例图无法反映这些差异--若缓存编译结果，同一进程跨用户会共享 sandbox / model / 技能集，破坏隔离。

**决策：每 run 调一次 `make_lead_agent(config)`，重新拼装一个全新 `CompiledGraph`。** 工厂本身**无状态**（不写全局、不缓存图），所有 per-run 状态只经 `config` 流入。

冷启动开销由两层抵消，不需要靠缓存图来省：
- **prefix cache**：系统提示词是纯静态字符串（`apply_prompt_template` 不读运行时变量），跨用户、跨会话字节级一致，持续命中（见 [[system-prompt-template]]）。
- **工厂内局部 cache**：技能签名 LRU、延迟工具 catalog hash、`_agent_factory_supports_app_config` 签名探针 lru_cache--这些缓存的是**只读派生量**，不是图本身。

> 关键不变量：工厂只做"读 cfg -> 解析 -> 拼装 -> return"，**无副作用**（唯一的副作用是把 tracing metadata / callbacks 注入 `config`，这正是 tracing 不变量本身，见下文）。

### configurable × context 双通道分离

LangGraph 的 `RunnableConfig` 有两个承载运行时参数的字典：`configurable` 与 `context`。它们语义不同，**不能混用**：

| 通道 | 生命周期 | 是否进 checkpoint | 典型字段 | 谁读它 |
|---|---|---|---|---|
| `configurable` | **启动期定型**（run 创建时写入，整个 run 稳定） | **是**（持久化到 checkpoint） | `model_name` / `thinking_enabled` / `agent_name` / `is_bootstrap` / `subagent_enabled` / `is_plan_mode` | 旧版只读 `configurable` 的消费者、LangGraph 内部（checkpoint_ns / checkpoint_id） |
| `context` | **每 run 变化**（每次调用都可能不同） | **否**（不持久化） | `thread_id` / `run_id` / `user_id` / `non_interactive` / `channel_user_id` / `github_token` | `ToolRuntime.context` / `runtime.context`（中间件、工具经此读取） |

**为什么分两通道？** 历史原因 + 安全原因：
1. **历史**：LangGraph < 1.1 时 `ToolRuntime.context` 会 fallback 到 `configurable`，所以旧代码只写 `configurable` 也能被工具读到。LangGraph >= 1.1 移除了该 fallback（`setup_agent` 等工具开始拿不到值，issue #2677），于是**白名单字段必须双写两边**。
2. **安全**：`configurable` 会被写进 checkpoint 持久化。短命密钥（`github_token`）、运行时旗标（`disable_clarification`）**绝不能进 `configurable`**，否则会被写进 checkpoint store。所以这类字段只写 `context`。

gateway 边界用三组 frozenset 精确管控字段流向（见 `references/code/dual-channel.md`）：

- `_CONTEXT_CONFIGURABLE_KEYS` -- agent 整形字段（`model_name` / `thinking_enabled` / `agent_name` / `is_bootstrap` / `subagent_enabled` / `max_concurrent_subagents` / `is_plan_mode` / `reasoning_effort` / `mode`）：**双写** `configurable` + `context`（兼容旧消费者 + 新 `ToolRuntime.context`）。
- `_CONTEXT_INTERNAL_CALLER_KEYS`（`non_interactive`）-- 仅内部认证调用者（scheduler / channels）可塞；非内部调用者塞的会被 `strip_internal_context_keys` 抹除（防客户端伪造无人值守）。
- `_CONTEXT_RUNTIME_ONLY_KEYS`（`github_token` / `disable_clarification`）-- **只写 `context`**，永不进 `configurable`（防密钥落 checkpoint）。

工厂侧的 `_get_runtime_config(config)` 把两通道合并成一个视图（`context` 后写覆盖 `configurable`），让工厂读到一个统一字典--但合并只发生在工厂**读取**时，写入仍由 gateway / worker 各自精确控制。

### 装配时机：九步一次绑定

工厂把"读 cfg -> 解析 -> 拼装 -> 一次绑定"压成一条直线，顺序固定：

1. **合并双通道** -> `cfg = _get_runtime_config(config)`
2. **解析 user_id**（`cfg["user_id"]` -> `get_effective_user_id()` contextvar 兜底）-- per-user 技能加载用
3. **解析模型**（请求 `model_name` -> agent 配置 model -> 全局默认；未知名只 warning 不抛错，降级到默认）
4. **注入 tracing callbacks 到图根** `config["callbacks"]`（不是挂模型上）-- 见 tracing 不变量
5. **加载技能**用于工具策略（`_load_enabled_skills_for_tool_policy`，按 `available_skills` 白名单过滤）
6. **装配工具**：`get_available_tools` -> `filter_tools_by_skill_allowed_tools`（白名单）-> `non_interactive` 剥离 `ask_clarification` -> `assemble_deferred_tools`（延迟 MCP 切分）-> 追加 `describe_skill`
7. **构造中间件链** `build_middlewares(config, ...)`（29 项链，见 [[middleware-chain-design]]）
8. **渲染静态系统提示词** `apply_prompt_template(...)`（纯静态，吃 prefix cache）
9. **一次绑定** `create_agent(model=, tools=, middleware=, system_prompt=, state_schema=ThreadState)`

第 6-8 步共享同一份 `deferred_setup` / `skill_names`：`deferred_names` 同时喂给 `build_middlewares`（构造 `DeferredToolFilterMiddleware`）和 `apply_prompt_template`（渲染延迟工具提示段），二者用同一 `catalog_hash` 校对--否则 prompt 提示的工具与运行时白名单不一致，模型反复尝试不存在的工具。

### tracing 挂图根不变量

`build_tracing_callbacks()`（Langfuse / LangSmith）**只在工厂内、`create_agent` 之前**追加到 `config["callbacks"]`。所有 `create_chat_model(...)` 调用**必须** `attach_tracing=False`。

原因：Langfuse handler 靠 `on_chain_start(parent_run_id=None)` 触发 `propagate_attributes`，把 `config["metadata"]` 里的 `langfuse_session_id` / `langfuse_user_id` 提升到 trace。若 callback 挂在模型上，模型是嵌套 observation，handler 会 strip 掉 `langfuse_*` key--结果是每条消息双重 span + session_id/user_id 丢失 + 看板对账错乱。

模块顶部用 `INVARIANT` 注释枚举了所有图内 `create_chat_model` 调用点（bootstrap agent / 默认 agent / 摘要中间件 / TitleMiddleware 异步路径），新增点必须同步加 `attach_tracing=False` 并更新该注释。

### bootstrap 与 webhook 两个特殊分支

`_make_lead_agent` 有两个条件分支：

- **bootstrap 分支**（`is_bootstrap=True`）：首次创建自定义 agent 时走。技能集收窄到 `{"bootstrap"}`，只暴露 `setup_agent` 工具（无 `update_agent`），prompt 用最小集。保证 agent 自身配置还不存在时创建流程确定、可复现。
- **webhook 扣留 `update_agent`**：`_WEBHOOK_CHANNELS = {"github"}`。webhook 提示来自任意外部评论者（任何能在 repo 上 @bot 的人），若暴露 `update_agent`，评论者可改 agent 的 `tool_groups` / SOUL.md / model 且永久生效。所以 webhook 通道扣留该工具；bootstrap 与直接调用不带 `channel_name`，`update_agent` 仍可用。

### 图特性（RuntimeFeatures）：SDK 层声明式装配

`make_lead_agent` 是 **config 驱动的生产工厂**（注册在 `langgraph.json`，被 LangGraph Server / Studio / 嵌入式客户端共用）。其下还有一层 **SDK 纯参数工厂** `create_helix_agent`：不读 config 文件、不吃 `RunnableConfig`，只收普通 Python 参数（model / tools / system_prompt / middleware / features）。

`RuntimeFeatures` 是声明式 feature flag dataclass，每个特性接受三态：
- `True` -- 用内置默认中间件
- `False` -- 禁用
- `AgentMiddleware` 实例 -- 用这个自定义实现替换

`summarization` / `guardrail` 没有内置默认（需要 model 参数 / 无内置实现），只接受 `False` 或自定义实例。`@Next(anchor)` / `@Prev(anchor)` 装饰器让外部中间件声明相对定位，`_insert_extra` 用迭代算法解析锚点（支持外部间互锚）。

两个工厂都最终调 `langchain.agents.create_agent`，但**互不委托**：`make_lead_agent` 用 `build_middlewares` 装配全量 29 项链；`create_helix_agent` 用 `_assemble_from_features` 装配精简 14 项链。前者是产品入口，后者是编程式入口（子代理、测试、SDK 用）。

### 在端到端链路中的位置

本 skill 处于端到端链路的 **④建图**（见 [[e2e-request-lifecycle]]）：

- 上游 ③路由：`RunManager.create_or_reject` 原子注册 run 后起 worker，worker 在调 `agent_factory(config)` 前**先把 `context` 落进 `runtime.context` + `configurable["__pregel_runtime"]`**（worker 的 `_build_runtime_context` / `_install_runtime_context`，见 `references/code/dual-channel.md`），然后才调 `make_lead_agent(config)`。
- 下游 ⑤中间件 / ⑥执行：图构造完后，worker 给图挂 checkpointer + store，再 `astream` 驱动中间件链与工具循环。

跨切不变量 1（`non_interactive` 剥离 `ask_clarification`）的**落点就在本 skill**：gateway 边界 `merge_run_context_overrides` 仅对内部调用者接纳该 key，`strip_internal_context_keys` 无条件抹除非内部调用者塞的；工厂读 `non_interactive` 后把 `ask_clarification` 从工具列表剔除（`_NON_INTERACTIVE_DISABLED_TOOL_NAMES`）。

## 完整真实代码实现

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/agents/lead/agent.py` | `make_lead_agent` 图工厂入口 + `_make_lead_agent` 装配主体 + `build_middlewares` 中间件链装配 + `_get_runtime_config` 双通道合并 + `_resolve_model_name` 三段降级 |
| `core/helix/agents/factory.py` | `create_helix_agent` SDK 纯参数工厂 + `_assemble_from_features` feature 驱动装配 + `_insert_extra` @Next/@Prev 锚点解析 |
| `core/helix/agents/features.py` | `RuntimeFeatures` 声明式 feature flag + `Next` / `Prev` 定位装饰器（纯数据类，无 IO） |
| `core/helix/agents/__init__.py` | `make_lead_agent` 懒注册 + 技能缓存预热（LangGraph 解析 `helix.agents:make_lead_agent` 的入口） |
| `core/helix/agents/thread_state.py` | `ThreadState`（`AgentState` 子类，带 reducers）-- `state_schema` 必须传它 |
| `gateway/gateway/services.py` | `merge_run_context_overrides` / `strip_internal_context_keys` + 三组字段 frozenset（双通道写入/抹除的网关侧落地） |
| `core/helix/runtime/runs/worker.py` | `_build_runtime_context` / `_install_runtime_context`（把 `context` 落成 `runtime.context` + `configurable["__pregel_runtime"]`） |

### 1. 图工厂入口（每 run 一次，签名冻结）

```python
# core/helix/agents/lead/agent.py - LangGraph graph factory；每 run 调一次
from langchain.agents import create_agent
from langchain_core.runnables import RunnableConfig

from helix.agents.lead_agent.prompt import apply_prompt_template
from helix.agents.thread_state import ThreadState
from helix.config.agents_config import load_agent_config, validate_agent_name
from helix.config.app_config import AppConfig, get_app_config
from helix.models import create_chat_model
from helix.skills.tool_policy import SKILL_LOADING_TOOL_NAMES, filter_tools_by_skill_allowed_tools
from helix.tracing import build_tracing_callbacks

_BOOTSTRAP_SKILL_NAMES = {"bootstrap"}
# 无人值守（non_interactive）run 必须剥离的工具：ask_clarification 会 Command(goto=END) 中断等回复，
# 无人盯屏时会永久卡死。跨切不变量 1 的落点（见 [[e2e-request-lifecycle]]）。
_NON_INTERACTIVE_DISABLED_TOOL_NAMES = frozenset({"ask_clarification"})

# 入站消息来自不受信任外部评论者的通道（任何能在 repo 上 @bot 的人）。这类 run 的 context
# 对 update_agent 这类管理形工具不安全。channel_name 由 ChannelManager._resolve_run_params 塞进 run_context。
_WEBHOOK_CHANNELS: frozenset[str] = frozenset({"github"})


def make_lead_agent(config: RunnableConfig):
    """LangGraph graph factory; keep the signature compatible with LangGraph Server.

    签名永久冻结为 (config) -- 业务参数全部走 config["configurable"] / config["context"]。
    改签名会让 LangGraph Server 注册时签名校验失败，图无法被外部 SDK 调起。
    """
    runtime_config = _get_runtime_config(config)
    runtime_app_config = runtime_config.get("app_config")
    return _make_lead_agent(config, app_config=runtime_app_config or get_app_config())
```

### 2. 双通道合并器 + 模型三段降级

```python
# core/helix/agents/lead/agent.py
def _get_runtime_config(config: RunnableConfig) -> dict:
    """合并 configurable 与 context（context 后写覆盖）。

    工厂读取侧的统一视图：configurable（启动期定型、进 checkpoint）与 context（每 run 变化、
    不进 checkpoint）在 gateway 边界被精确双写/单写（见 references/code/dual-channel.md），
    这里合并成一个字典供工厂消费。context 覆盖 configurable，符合 LangGraph >= 1.1 的推荐顺序。
    """
    cfg = dict(config.get("configurable", {}) or {})
    context = config.get("context", {}) or {}
    if isinstance(context, dict):
        cfg.update(context)
    return cfg


def _resolve_model_name(requested_model_name: str | None = None, *, app_config: AppConfig | None = None) -> str:
    """三段降级解析模型名：请求显式 model > agent 配置 model > 全局默认。

    未知名只发 warning 后降级到默认，不抛错 -- 旧 thread 历史里残留的已删除模型名不能让整个
    thread 不可恢复。无任何模型配置时才抛 ValueError。
    """
    app_config = app_config or get_app_config()
    default_model_name = app_config.models[0].name if app_config.models else None
    if default_model_name is None:
        raise ValueError("No chat models are configured. Please configure at least one model in config.yaml.")

    if requested_model_name and app_config.get_model_config(requested_model_name):
        return requested_model_name

    if requested_model_name and requested_model_name != default_model_name:
        logger.warning(f"Model '{requested_model_name}' not found in config; fallback to default model '{default_model_name}'.")
    return default_model_name
```

### 3. 装配主体（完整，含 bootstrap / webhook 两个分支）

```python
# core/helix/agents/lead/agent.py - 每 run 一次的装配主体
def _make_lead_agent(config: RunnableConfig, *, app_config: AppConfig):
    # 惰性 import 避免循环依赖（tools -> builtins -> tool_search 链在模块加载期会回环）
    from helix.tools import get_available_tools
    from helix.tools.builtins import setup_agent, update_agent
    from helix.tools.builtins.tool_search import assemble_deferred_tools

    cfg = _get_runtime_config(config)
    resolved_app_config = app_config

    # user_id 解析：优先 configurable/context 注入，兜底 runtime contextvar（无认证模式落 default 桶）。
    # user_id 用于 per-user 技能加载（见 [[multi-user-isolation]]）。
    from helix.runtime.user_context import get_effective_user_id

    runtime_user_id = cfg.get("user_id")
    resolved_user_id = str(runtime_user_id) if runtime_user_id else get_effective_user_id()

    thinking_enabled = cfg.get("thinking_enabled", True)
    reasoning_effort = cfg.get("reasoning_effort", None)
    requested_model_name: str | None = cfg.get("model_name") or cfg.get("model")
    is_plan_mode = cfg.get("is_plan_mode", False)
    subagent_enabled = cfg.get("subagent_enabled", False)
    max_concurrent_subagents = cfg.get("max_concurrent_subagents", 3)
    is_bootstrap = cfg.get("is_bootstrap", False)
    non_interactive = bool(cfg.get("non_interactive", False))
    agent_name = validate_agent_name(cfg.get("agent_name"))  # 强校验，防注入文件系统路径片段

    agent_config = load_agent_config(agent_name) if not is_bootstrap else None
    available_skills = _available_skill_names(agent_config, is_bootstrap)
    # 自定义 agent 配置里的 model（若有），否则 None 让 _resolve_model_name 选默认
    agent_model_name = agent_config.model if agent_config and agent_config.model else None

    # 最终模型解析：请求 -> agent 配置 -> 全局默认，未知名降级不抛错
    model_name = _resolve_model_name(requested_model_name or agent_model_name, app_config=resolved_app_config)

    model_config = resolved_app_config.get_model_config(model_name)

    if model_config is None:
        raise ValueError("No chat model could be resolved. Please configure at least one model in config.yaml or provide a valid 'model_name'/'model' in the request.")
    if thinking_enabled and not model_config.supports_thinking:
        logger.warning(f"Thinking mode is enabled but model '{model_name}' does not support it; fallback to non-thinking mode.")
        thinking_enabled = False

    logger.info(
        "Create Agent(%s) -> thinking_enabled: %s, reasoning_effort: %s, model_name: %s, is_plan_mode: %s, subagent_enabled: %s, max_concurrent_subagents: %s",
        agent_name or "default",
        thinking_enabled,
        reasoning_effort,
        model_name,
        is_plan_mode,
        subagent_enabled,
        max_concurrent_subagents,
    )

    # 注入 run metadata 供 LangSmith trace tagging（用 update 不覆盖，保住上游注入的 langfuse_session_id 等）
    if "metadata" not in config:
        config["metadata"] = {}

    config["metadata"].update(
        {
            "agent_name": agent_name or "default",
            "model_name": model_name or "default",
            "thinking_enabled": thinking_enabled,
            "reasoning_effort": reasoning_effort,
            "is_plan_mode": is_plan_mode,
            "subagent_enabled": subagent_enabled,
            "tool_groups": agent_config.tool_groups if agent_config else None,
            "available_skills": sorted(available_skills) if available_skills is not None else None,
        }
    )

    # ★ tracing callbacks 挂在图调用根（config["callbacks"]），不挂模型上。
    # 这样一次 LangGraph run 产出一条 trace，所有 node/LLM/tool 调用都是子 span；
    # 且 Langfuse handler 能看到 on_chain_start(parent_run_id=None)，真正把
    # langfuse_session_id / langfuse_user_id 从 config["metadata"] 提升到 trace。
    # 若挂在模型上，模型是嵌套 observation，handler 会 strip 掉 langfuse_* key。
    tracing_callbacks = build_tracing_callbacks()
    if tracing_callbacks:
        existing = config.get("callbacks") or []
        if not isinstance(existing, list):
            existing = list(existing)
        config["callbacks"] = [*existing, *tracing_callbacks]  # 追加，不覆盖（保住 LangGraph 自己注册的流式回调）

    skills_for_tool_policy = _load_enabled_skills_for_tool_policy(available_skills, app_config=resolved_app_config, user_id=resolved_user_id)

    # 技能延迟发现（describe_skill）：由 skills.deferred_discovery 控制，独立于 tool_search.enabled
    from helix.skills.describe import build_skill_search_setup

    skill_search_enabled = resolved_app_config.skills.deferred_discovery
    container_base_path = resolved_app_config.skills.container_path

    if is_bootstrap:
        # 引导 agent：首次创建自定义 agent 时走。技能集故意收窄到 {"bootstrap"}，
        # 保证 agent 自身配置还不存在时创建流程确定、可复现。
        bootstrap_skills = [s for s in skills_for_tool_policy if s.name in _BOOTSTRAP_SKILL_NAMES]
        skill_setup = build_skill_search_setup(
            bootstrap_skills,
            enabled=skill_search_enabled,
            container_base_path=container_base_path,
        )
        raw_tools = get_available_tools(model_name=model_name, subagent_enabled=subagent_enabled, app_config=resolved_app_config) + [setup_agent]
        filtered = filter_tools_by_skill_allowed_tools(raw_tools, skills_for_tool_policy, always_allowed_tool_names=SKILL_LOADING_TOOL_NAMES)
        if non_interactive:
            # 无人值守：剥离 ask_clarification（跨切不变量 1）
            filtered = [tool for tool in filtered if tool.name not in _NON_INTERACTIVE_DISABLED_TOOL_NAMES]
        final_tools, setup = assemble_deferred_tools(filtered, enabled=resolved_app_config.tool_search.enabled)
        if skill_setup.describe_skill_tool:
            final_tools.append(skill_setup.describe_skill_tool)
        return create_agent(
            model=create_chat_model(name=model_name, thinking_enabled=thinking_enabled, app_config=resolved_app_config, attach_tracing=False),
            tools=final_tools,
            middleware=build_middlewares(
                config,
                model_name=model_name,
                available_skills=set(_BOOTSTRAP_SKILL_NAMES),
                app_config=resolved_app_config,
                deferred_setup=setup,
                user_id=resolved_user_id,
            ),
            system_prompt=apply_prompt_template(
                subagent_enabled=subagent_enabled,
                max_concurrent_subagents=max_concurrent_subagents,
                available_skills=set(_BOOTSTRAP_SKILL_NAMES),
                app_config=resolved_app_config,
                deferred_names=setup.deferred_names,
                user_id=resolved_user_id,
                skill_names=skill_setup.skill_names or None,
            ),
            state_schema=ThreadState,
        )

    # 自定义 agent 可经 update_agent 改自己的 SOUL.md / config；默认 agent（无 agent_name）看不到该工具。
    skill_setup = build_skill_search_setup(
        skills_for_tool_policy,
        enabled=skill_search_enabled,
        container_base_path=container_base_path,
    )
    #
    # webhook 通道（当前仅 github）扣留 update_agent：webhook 提示来自任意外部评论者 --
    # 任何能在配置的 repo 上发帖且 @bot 的人都过触发门。暴露该工具会让评论者能改 agent 的
    # tool_groups / SOUL.md / model，且改动对后续每次 run 永久生效。自变更只该出现在
    # 操作者信任的面（chat UI、HTTP API），不该出现在 webhook 扇出里。
    #
    # channel_name 由 ChannelManager._resolve_run_params 塞进 run_context；bootstrap 与直接
    # 调用不带它，所以 update_agent 在那些路径仍可用。
    channel_name = cfg.get("channel_name")
    is_webhook_channel = channel_name in _WEBHOOK_CHANNELS
    extra_tools = [update_agent] if agent_name and not is_webhook_channel else []
    # 默认 lead agent（行为不变）
    raw_tools = get_available_tools(model_name=model_name, groups=agent_config.tool_groups if agent_config else None, subagent_enabled=subagent_enabled, app_config=resolved_app_config)
    filtered = filter_tools_by_skill_allowed_tools(raw_tools + extra_tools, skills_for_tool_policy, always_allowed_tool_names=SKILL_LOADING_TOOL_NAMES)
    if non_interactive:
        # 无人值守：剥离 ask_clarification（跨切不变量 1）
        filtered = [tool for tool in filtered if tool.name not in _NON_INTERACTIVE_DISABLED_TOOL_NAMES]
    final_tools, setup = assemble_deferred_tools(filtered, enabled=resolved_app_config.tool_search.enabled)
    if skill_setup.describe_skill_tool:
        final_tools.append(skill_setup.describe_skill_tool)
    return create_agent(
        model=create_chat_model(name=model_name, thinking_enabled=thinking_enabled, reasoning_effort=reasoning_effort, app_config=resolved_app_config, attach_tracing=False),
        tools=final_tools,
        middleware=build_middlewares(
            config,
            model_name=model_name,
            agent_name=agent_name,
            available_skills=available_skills,
            app_config=resolved_app_config,
            deferred_setup=setup,
            user_id=resolved_user_id,
        ),
        system_prompt=apply_prompt_template(
            subagent_enabled=subagent_enabled,
            max_concurrent_subagents=max_concurrent_subagents,
            agent_name=agent_name,
            available_skills=available_skills,
            app_config=resolved_app_config,
            deferred_names=setup.deferred_names,
            user_id=resolved_user_id,
            skill_names=skill_setup.skill_names or None,
        ),
        state_schema=ThreadState,
    )
```

> `build_middlewares`（29 项链装配，含 `DynamicContextMiddleware` / `SkillActivationMiddleware` / `SystemMessageCoalescingMiddleware` / 链尾 `ClarificationMiddleware` 等）的**完整源码**见 [references/code/make-lead-agent.md](./references/code/make-lead-agent.md)。其装配顺序与每项条件门见 [[middleware-chain-design]]。

### 4. 注册到 langgraph.json

```json
{
  "graphs": {
    "lead_agent": "helix.agents:make_lead_agent"
  }
}
```

`helix.agents:make_lead_agent` 经 `core/helix/agents/__init__.py` 的 `__getattr__` 懒解析：LangGraph 解析该入口时才触发 import 与技能缓存预热（`prime_enabled_skills_cache`），避免轻量子模块 import 时拉进整条 tool/subagent 依赖图。完整懒注册见 [references/code/make-lead-agent.md](./references/code/make-lead-agent.md)。

### 5. 动态时序（一次 run 的装配 + 执行）

```
worker.run_agent(record, config, agent_factory=make_lead_agent)
  │
  ├─ _build_runtime_context(thread_id, run_id, config["context"], app_config)
  │     -> runtime_ctx = {thread_id, run_id, +调用方context键, app_config}
  ├─ _install_runtime_context(config, runtime_ctx)
  │     -> config["context"] 落定；configurable["__pregel_runtime"] = Runtime(context=runtime_ctx)
  ├─ agent_factory(config=RunnableConfig(**config))   # 每 run 一次建图
  │     └─ make_lead_agent -> _make_lead_agent:
  │          ├─ _get_runtime_config(config)            # 双通道合并
  │          ├─ _resolve_model_name(...)               # 三段降级 + warning
  │          ├─ config["metadata"].update({...})       # trace tag（update 不覆盖）
  │          ├─ config["callbacks"] += tracing         # 图根挂载
  │          ├─ get_available_tools + filter + non_interactive 剥离 + assemble_deferred
  │          ├─ build_middlewares(...)                 # 29 项链
  │          ├─ apply_prompt_template(...)             # 纯静态 prompt
  │          └─ create_agent(model, tools, middleware, system_prompt, state_schema=ThreadState)
  ├─ agent.checkpointer = checkpointer; agent.store = store
  └─ agent.astream(input, config, stream_mode=lg_modes)  # -> ⑤中间件 -> ⑥执行 -> ⑦流式
```

### references 索引

- [references/code/make-lead-agent.md](./references/code/make-lead-agent.md) -- `build_middlewares` 完整源码（29 项链装配 + `_create_todo_list_middleware` / `_create_summarization_middleware` / `_available_skill_names` / `_load_enabled_skills_for_tool_policy` 辅助函数 + `__init__.py` 懒注册）
- [references/code/graph-factory.md](./references/code/graph-factory.md) -- `create_helix_agent` SDK 纯参数工厂 + `_assemble_from_features` feature 驱动装配 + `_insert_extra` @Next/@Prev 锚点解析 + `RuntimeFeatures` / `Next` / `Prev`
- [references/code/dual-channel.md](./references/code/dual-channel.md) -- configurable × context 双通道协议完整代码（gateway 三组 frozenset + `merge_run_context_overrides` / `strip_internal_context_keys` + worker `_build_runtime_context` / `_install_runtime_context` + 调用点）

## 反模式与陷阱

- ❌ **缓存编译结果当单例** -> 同一进程跨用户共享 sandbox / model / 技能集，破坏隔离；且 `non_interactive` 剥离、webhook 扣留 `update_agent` 这类 per-run 决策无法生效。修复：工厂每 run 重建，靠 prefix cache + 工厂内只读派生量缓存抵消冷启动，不缓存图。
- ❌ **只读 `configurable` 不读 `context`**（或反之）-> LangGraph >= 1.1 移除了 `ToolRuntime.context` 对 `configurable` 的 fallback，只读一边的工具/中间件拿不到值（`setup_agent` 拿不到 `agent_name`，issue #2677）。修复：`_get_runtime_config` 合并两通道；gateway 侧白名单字段双写。
- ❌ **把密钥 / 运行时旗标写进 `configurable`** -> `configurable` 进 checkpoint，`github_token` 这类短命密钥会被持久化到 checkpoint store。修复：密钥与运行时旗标只写 `context`（`_CONTEXT_RUNTIME_ONLY_KEYS`）。
- ❌ **tracing callback 挂在 `create_chat_model` 上而非图根** -> 每条消息双重 span + Langfuse `session_id` / `user_id` 丢失 + token 双倍计费。修复：callback 只在工厂内追加到 `config["callbacks"]`；所有图内 `create_chat_model` 必须 `attach_tracing=False`（模块顶部 INVARIANT 注释枚举所有调用点）。
- ❌ **`config["callbacks"] = tracing_callbacks` 直接覆盖** -> 丢掉 LangGraph 自己注册的流式回调。修复：`existing = list(config.get("callbacks") or []); config["callbacks"] = [*existing, *tracing_callbacks]`。
- ❌ **`config["metadata"] = {...}` 直接赋值** -> 覆盖上游 server 注入的 `langfuse_session_id` 等。修复：`if "metadata" not in config: config["metadata"] = {}` 然后 `update`。
- ❌ **`_resolve_model_name` 对未知名抛 `ValueError`** -> 旧 thread 历史里残留的已删除模型名会让整个 thread 不可恢复；工厂异常还会被 LangGraph 包装成 `GraphRecursionError` 子句，难排查。修复：未知名只 warning + 降级到默认。
- ❌ **`assemble_deferred_tools` 在 `filter_tools_by_skill_allowed_tools` 之前调用** -> 把被策略禁掉的 MCP 工具放进 deferred 集，prompt 提示了但运行时无法 promote。修复：永远 `filter -> assemble`，顺序不可逆。
- ❌ **`deferred_setup` 只喂 `build_middlewares` 不喂 `apply_prompt_template`**（或反之）-> prompt 提示的延迟工具与运行时 `DeferredToolFilterMiddleware` 白名单不一致，模型反复尝试不存在的工具。修复：二者用同一 `setup.deferred_names` / `catalog_hash`。
- ❌ **`agent_name` 不过 `validate_agent_name`** -> 自定义 agent 路由可被诱导读写任意目录（路径穿越）。修复：所有外部输入的 `agent_name` 先过校验器。
- ❌ **`is_bootstrap=True` 时 skill 集不收窄** -> 引导阶段被任意 skill 提前激活，自定义 agent 创建流程不再确定。修复：bootstrap 锁定 `_BOOTSTRAP_SKILL_NAMES`。
- ❌ **webhook 通道暴露 `update_agent`** -> 任意外部评论者可改 agent 配置且永久生效。修复：`_WEBHOOK_CHANNELS` 通道扣留该工具。
- ❌ **`state_schema` 省略或用裸 `AgentState`** -> `sandbox` / `artifacts` / `promoted` 等字段被当成 Last-Write-Wins 静默覆盖（`merge_sandbox` 冲突检测、`merge_promoted` 分代都不生效）。修复：`state_schema=ThreadState`。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 默认 | 通道 | 说明 |
|---|---|---|---|
| `thinking_enabled` | `True` | configurable + context | 模型不支持则自动降级（warning） |
| `reasoning_effort` | `None` | configurable + context | 仅对支持的模型有效 |
| `model_name` / `model` | `app_config.models[0].name` | configurable + context | 请求覆盖 agent 配置；未知名 fallback |
| `is_plan_mode` | `False` | configurable + context | 控制 `TodoMiddleware` 启停 |
| `subagent_enabled` | `False` | configurable + context | 同步影响 prompt 子代理段 + `SubagentLimitMiddleware` |
| `max_concurrent_subagents` | `3` | configurable + context | 一次响应内最大 `task` 调用数 |
| `is_bootstrap` | `False` | configurable + context | 引导模式：只暴露 `setup_agent` + 最小 skill 集 |
| `agent_name` | `None` | configurable + context | 决定 SOUL.md / per-agent memory / `update_agent` 可见性 |
| `non_interactive` | `False` | context（仅内部调用者） | 剥离 `ask_clarification`；客户端塞入被抹除 |
| `channel_name` | `None` | context | webhook 通道（`github`）扣留 `update_agent` |
| `user_id` | contextvar 兜底 | context | per-user 技能加载 + 文件系统桶 |
| `app_config` | `get_app_config()` | context | 显式注入优先于全局单例 |

**关键日志串**（排障时 grep）

- `Create Agent(<agent_name>) -> thinking_enabled: ... model_name: ... is_plan_mode: ... subagent_enabled: ...` -- 工厂每次创建都打这一行，定位"图按什么参数装配"
- `Model '<name>' not found in config; fallback to default model ...` -- 模型降级路径
- `Thinking mode is enabled but model ... does not support it; fallback ...` -- 自动关 thinking
- `Failed to load skills for allowed-tools policy` -- skill 加载失败（会抛，需告警）
- `Conflicting sandbox state updates: ... != ...` -- 同一 step 两个不同 sandbox_id（隔离 bug）

**自测方向**

- **每 run 重建确定性**：相同入参 5 次 `make_lead_agent`，断言工具集 + 中间件链顺序 + system_prompt 字节级相等。
- **双通道字段优先级**：`configurable.model_name=A`、`context.model_name=B` -> 预期使用 B（context 覆盖）。
- **未知模型降级**：`model_name="ghost"` -> 调用成功且返回默认模型工厂结果（不抛错）。
- **bootstrap 隔离**：`is_bootstrap=True` -> 工具集含 `setup_agent`、不含 `update_agent`；`available_skills == {"bootstrap"}`。
- **webhook 扣留**：`channel_name="github"` + `agent_name="custom"` -> 工具集不含 `update_agent`；`channel_name=None` 同 agent -> 含 `update_agent`。
- **non_interactive 剥离**：`non_interactive=True` -> `ask_clarification` 不在工具集；HTTP 客户端塞 `context={"non_interactive": True}` -> 经 `strip_internal_context_keys` 后仍含 `ask_clarification`（被抹除）；scheduler 路径 -> 不含。
- **tracing 唯一性**：mock `build_tracing_callbacks`，断言图根 `config["callbacks"]` 含 handler 且所有 `create_chat_model` 调用 `attach_tracing=False`；断言 `config["callbacks"]` 追加而非覆盖。
- **deferred 一致性**：assemble 后 prompt 中的延迟工具名集合 == `DeferredToolFilterMiddleware` 持有的 `deferred_names` 集合。
- **agent_name 路径安全**：`agent_name` 含 `..` / 路径分隔符 -> 被 `validate_agent_name` 拒绝。
- **state_schema**：断言图的 `sandbox` / `artifacts` / `promoted` 通道挂了对应 reducer（非 Last-Write-Wins）。

## 进一步阅读

- `build_middlewares` 完整源码 + 辅助函数 + 懒注册：[references/code/make-lead-agent.md](./references/code/make-lead-agent.md)
- `create_helix_agent` SDK 工厂 + `RuntimeFeatures` + `@Next`/`@Prev`：[references/code/graph-factory.md](./references/code/graph-factory.md)
- configurable × context 双通道协议完整代码：[references/code/dual-channel.md](./references/code/dual-channel.md)
- 关联 skill：[[e2e-request-lifecycle]]（④建图 在链路中的位置）、[[system-prompt-template]]（静态 prompt 渲染时机 + prefix cache）、[[middleware-chain-design]]（29 项链装配顺序）、[[tool-assembly-and-policy]]（工具装配 + 白名单 + 延迟切分）、[[thread-state-and-reducers]]（`ThreadState` reducers）、[[observability-tracing]]（tracing 挂图根不变量）、[[multi-user-isolation]]（user_id 全链路隔离）、[[scheduled-tasks]]（non_interactive 起点）
- LangGraph context 文档：https://langchain-ai.github.io/langgraph/
