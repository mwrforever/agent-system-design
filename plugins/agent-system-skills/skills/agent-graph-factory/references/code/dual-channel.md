# configurable × context 双通道协议

> 与 [SKILL.md](../../SKILL.md) 同步。本文件收录双通道协议的完整代码：gateway 边界的字段写入/抹除（`gateway/gateway/services.py`）+ worker 把 `context` 落成 `runtime.context` / `configurable["__pregel_runtime"]`（`core/helix/runtime/runs/worker.py`）+ 工厂侧的合并读取（`core/helix/agents/lead/agent.py`）。代码为真实实现（已按插件匿名化规则映射到自定结构）。真实代码的原注释保留以保真；关键处补中文注解。

---

## 协议总览

LangGraph 的 `RunnableConfig` 有两个承载运行时参数的字典。字段如何在二者间分配，由 gateway 边界的三组 frozenset 精确管控：

| frozenset | 含字段 | 写入策略 | 为什么 |
|---|---|---|---|
| `_CONTEXT_CONFIGURABLE_KEYS` | `model_name` / `mode` / `thinking_enabled` / `reasoning_effort` / `is_plan_mode` / `subagent_enabled` / `max_concurrent_subagents` / `agent_name` / `is_bootstrap` | **双写** `configurable` + `context` | agent 整形字段；旧消费者只读 `configurable`，新 `ToolRuntime.context` 只读 `context`（LangGraph >= 1.1 移除 fallback），故白名单字段两边都写 |
| `_CONTEXT_INTERNAL_CALLER_KEYS` | `non_interactive` | 仅内部调用者可写；非内部调用者塞的被 `strip_internal_context_keys` 抹除 | 防客户端伪造无人值守（跨切不变量 1，见 [[e2e-request-lifecycle]]） |
| `_CONTEXT_RUNTIME_ONLY_KEYS` | `github_token` / `disable_clarification` | **只写 `context`**，永不进 `configurable` | `configurable` 进 checkpoint；密钥/运行时旗标不得持久化 |

`user_id` 与 `channel_user_id` 也只进 `context`（用 `setdefault`，服务端认证 id 优先于客户端塞的）。

---

## 1. gateway 边界：三组字段 frozenset

```python
# gateway/gateway/services.py

# LangGraph >=1.1.9 不再让 ``ToolRuntime.context`` 对 ``setup_agent`` 这类消费者
# fallback 到 ``configurable``。白名单字段必须双写两边。
_CONTEXT_CONFIGURABLE_KEYS: frozenset[str] = frozenset(
    {
        "model_name",
        "mode",
        "thinking_enabled",
        "reasoning_effort",
        "is_plan_mode",
        "subagent_enabled",
        "max_concurrent_subagents",
        "agent_name",
        "is_bootstrap",
    }
)

# 仅内部认证调用者（scheduler 路径）接纳的 key。
# ``non_interactive`` 从 lead-agent 工具集剥离 ``ask_clarification``；
# 任意 HTTP/IM 客户端不得能强制自主执行。
_CONTEXT_INTERNAL_CALLER_KEYS: frozenset[str] = frozenset({"non_interactive"})

# 仅从 ``body.context`` 转发到 ``config['context']``（成为 ``ToolRuntime.context`` /
# ``runtime.context`` 的运行时 context），绝不进 ``config['configurable']``。
# 这些被工具与中间件从 ``runtime.context`` 读取，没有理由进 ``configurable`` --
# 而 ``configurable`` 会被持久化到 checkpoint，所以把 ``github_token`` 这类短命
# 安装令牌挡在 checkpoint store 之外。
#
#   ``github_token``         - GitHub channel 铸造的 app 安装令牌；bash 工具把它
#                              暴露为 ``GH_TOKEN``/``GITHUB_TOKEN``，使 ``gh`` 与
#                              ``git`` 以 bot 身份推送，而非宿主用户。
#   ``disable_clarification`` - 为非交互通道（GitHub webhook）设置，使
#                              ClarificationMiddleware 继续执行而非让 run 死胡同。
_CONTEXT_RUNTIME_ONLY_KEYS: frozenset[str] = frozenset({"github_token", "disable_clarification"})
```

---

## 2. gateway 边界：合并与抹除函数

```python
# gateway/gateway/services.py

def strip_internal_context_keys(config: dict[str, Any]) -> None:
    """抹除非内部调用者塞进 run config 的内部专用 key。

    仅靠 :func:`merge_run_context_overrides` 的门控不够：
    ``build_run_config`` 会逐字复制客户端塞的 ``body.config['context']`` /
    ``body.config['configurable']``，所以同样的 key 必须在 config 组装后
    从两个 section 都清掉。
    """
    for section in ("context", "configurable"):
        value = config.get(section)
        if isinstance(value, dict):
            for key in _CONTEXT_INTERNAL_CALLER_KEYS:
                value.pop(key, None)


def merge_run_context_overrides(config: dict[str, Any], context: Mapping[str, Any] | None, *, internal: bool = False) -> None:
    """把 ``body.context`` 的白名单 key 合并进 ``config['configurable']`` 与 ``config['context']``。

    使其对旧 configurable 读取者与 LangGraph ``ToolRuntime.context`` 消费者
    （如 ``setup_agent`` 工具 -- 见 issue #2677）都可见。

    ``user_id`` 刻意也传播进 ``config['context']``（除白名单 key 外），使非 web
    调用者（如 IM 通道）在 ``body.context`` 供给的身份能留在 ``ToolRuntime.context``。
    用 ``setdefault`` 合并，使 :func:`inject_authenticated_user_context` 盖章的
    服务端认证 id 永远优先于客户端塞的。

    :data:`_CONTEXT_INTERNAL_CALLER_KEYS` 仅在 internal=True 时接纳；
    否则从客户端请求中丢弃。

    第二组 key（``_CONTEXT_RUNTIME_ONLY_KEYS`` -- 如 ``github_token``、
    ``disable_clarification``）只转发进 ``config['context']``，绝不进
    ``configurable``。这些是工具与中间件从 ``runtime.context`` 读取的密钥 /
    运行时旗标；挡在 ``configurable`` 外避免短命令牌被持久化进 checkpoint store。
    """
    if not context:
        return
    configurable = config.setdefault("configurable", {})
    runtime_context = config.setdefault("context", {})
    keys = _CONTEXT_CONFIGURABLE_KEYS | _CONTEXT_INTERNAL_CALLER_KEYS if internal else _CONTEXT_CONFIGURABLE_KEYS
    for key in keys:
        if key in context:
            if isinstance(configurable, dict):
                configurable.setdefault(key, context[key])
            if isinstance(runtime_context, dict):
                runtime_context.setdefault(key, context[key])
    # context-only key（密钥 / 运行时旗标）只落 ``config['context']`` --
    # 绝不 ``configurable``（会被 checkpoint 持久化）。
    for key in _CONTEXT_RUNTIME_ONLY_KEYS:
        if key in context and isinstance(runtime_context, dict):
            runtime_context.setdefault(key, context[key])
    if "user_id" in context and isinstance(runtime_context, dict):
        runtime_context.setdefault("user_id", context["user_id"])
    # IM 通道的原始平台用户 id（Feishu open_id、Slack Uxxx、...）遵循与 user_id
    # 相同的 runtime-context-only 规则：工具可读，但绝不进 ``configurable``
    #（与 thread 一起 checkpoint）。
    if "channel_user_id" in context and isinstance(runtime_context, dict):
        runtime_context.setdefault("channel_user_id", context["channel_user_id"])
```

### 调用点（start_run 内）

`merge_run_context_overrides` 的 `internal` 参数由请求的认证来源决定。`AUTH_SOURCE_INTERNAL` 标记内部认证调用者（scheduler / channels 路径），来自 gateway 认证模块。

```python
# gateway/gateway/services.py - start_run 内的调用点
# ``context`` 字段是 langgraph-compat 层的自定义扩展，承载 agent 配置
#（model_name、thinking_enabled 等）。只转发 agent 相关 key；未知 key（如
# thread_id）被忽略。
# AUTH_SOURCE_INTERNAL：内部认证调用者标记（scheduler/channels 路径），来自 gateway 认证模块
is_internal_caller = getattr(getattr(request, "state", None), "auth_source", None) == AUTH_SOURCE_INTERNAL
merge_run_context_overrides(config, getattr(body, "context", None), internal=is_internal_caller)
if not is_internal_caller:
    # ``body.config`` 是自由格式，被 ``build_run_config`` 逐字复制；
    # 清掉混进那里的内部专用 key。
    strip_internal_context_keys(config)
internal_owner_user = await resolve_trusted_internal_owner_for_attribution(request, owner_user_id)
inject_authenticated_user_context(config, request, internal_owner_user=internal_owner_user)
```

> scheduler 桥接路径（`launch_scheduled_thread_run`）合成一个内部认证请求并塞入 `context={"non_interactive": True}`，以 `AUTH_SOURCE_INTERNAL` 标记调用者为内部，使 `merge_run_context_overrides(..., internal=True)` 接纳该 key。完整桥接代码见 [[e2e-request-lifecycle]] ①入站 / [[scheduled-tasks]]。

---

## 3. worker 落地：把 context 装进 runtime.context

worker 在调 `agent_factory(config)` 前，先把 `config["context"]` 装进一个 `Runtime` 对象并塞到 `configurable["__pregel_runtime"]`。这是 LangGraph 1.1+ 让中间件与工具经 `ToolRuntime.context` 读到运行时数据的机制（`langgraph.pregel.main` 里 `parent_runtime.merge(...)` 会取它）。

```python
# core/helix/runtime/runs/worker.py

def _build_runtime_context(
    thread_id: str,
    run_id: str,
    caller_context: Any | None,
    app_config: AppConfig | None = None,
) -> dict[str, Any]:
    """构建成为本次 run 的 ``ToolRuntime.context`` 的字典。

    永远含 ``thread_id`` 与 ``run_id``。调用方 ``config['context']`` 的额外 key
    （如 bootstrap 流程的 ``agent_name`` -- issue #2677）被合并进来，但永不覆盖
    ``thread_id``/``run_id``。解析后的 ``AppConfig`` 由 worker 加入，使工具无需
    ambient 全局查找即可消费。

    langgraph 1.1+ 把它经存放在 ``config['configurable']['__pregel_runtime']`` 的
    父 runtime 暴露为 ``runtime.context`` -- 见 ``langgraph.pregel.main`` 里
    ``parent_runtime.merge(...)`` 的调用。
    """
    runtime_ctx: dict[str, Any] = {"thread_id": thread_id, "run_id": run_id}
    if isinstance(caller_context, dict):
        for key, value in caller_context.items():
            runtime_ctx.setdefault(key, value)
    if app_config is not None:
        runtime_ctx["app_config"] = app_config
    return runtime_ctx


def _install_runtime_context(config: dict, runtime_context: dict[str, Any]) -> None:
    """把 runtime_context 装进 config['context']（已存在则补全，否则整体写入）。

    若 config['context'] 已是 dict（gateway 边界已写入），用 setdefault 补 thread_id /
    run_id / trace key / app_config，不覆盖已有值；否则整体写入一份拷贝。
    """
    existing_context = config.get("context")
    if isinstance(existing_context, dict):
        existing_context.setdefault("thread_id", runtime_context["thread_id"])
        existing_context.setdefault("run_id", runtime_context["run_id"])
        if HELIX_TRACE_METADATA_KEY in runtime_context:
            existing_context.setdefault(HELIX_TRACE_METADATA_KEY, runtime_context[HELIX_TRACE_METADATA_KEY])
        if "app_config" in runtime_context:
            existing_context["app_config"] = runtime_context["app_config"]
        return

    config["context"] = dict(runtime_context)
```

### 调用点（run_agent 内，建图之前）

worker 把 `context` 落定后，构造 `Runtime` 并塞进 `configurable["__pregel_runtime"]`，然后才调 `agent_factory(config)`。注意 `app_config` 经 `context` 流入工厂（不是工厂 kwarg）：`make_lead_agent(config)` 的签名是 `(config)`，内部从合并后的 cfg 读 `app_config`，兜底 `get_app_config()`。`_agent_factory_supports_app_config` 探针只对**其他**接受 `app_config` kwarg 的工厂生效。

```python
# core/helix/runtime/runs/worker.py - run_agent 内，建图之前
from langchain_core.runnables import RunnableConfig
from langgraph.runtime import Runtime

# 注入 runtime context，使中间件与工具（经 ToolRuntime.context）能访问 thread 级数据。
# langgraph-cli 自动做这事；我们这里手动做，因为经 ``agent.astream(config=...)``
# 驱动图时没传官方 ``context=`` 参数。
runtime_ctx = _build_runtime_context(thread_id, run_id, config.get("context"), ctx.app_config)
incoming_metadata = config.get("metadata") if isinstance(config.get("metadata"), dict) else {}
helix_trace_id = normalize_trace_id(incoming_metadata.get(HELIX_TRACE_METADATA_KEY)) or get_current_trace_id()
if helix_trace_id:
    runtime_ctx[HELIX_TRACE_METADATA_KEY] = helix_trace_id
# 把 run 作用域的 journal 暴露在一个哨兵 key 下，使中间件能写审计事件
#（如 SafetyFinishReasonMiddleware 记录被抑制的工具调用）。双下划线前缀标记它为
# runtime 内部通道；用户代码不得依赖该 key 名。
if journal is not None:
    runtime_ctx["__run_journal"] = journal
_install_runtime_context(config, runtime_ctx)
runtime = Runtime(context=cast(Any, runtime_ctx), store=store)
config.setdefault("configurable", {})["__pregel_runtime"] = runtime

# 注入 RunJournal 作为 LangChain callback handler。
# on_llm_end 捕获 token 用量；on_chain_start/end 捕获生命周期。
if journal is not None:
    config.setdefault("callbacks", []).append(journal)

# 注入 Langfuse trace-attribute metadata，使 langchain CallbackHandler 能把
# session_id / user_id / trace_name / tags 提升到根 trace。与 ``HelixClient.stream``
# 共享 helper，使两个入口保持同步；调用方提供的 metadata 经 helper 内 setdefault 优先。
inject_langfuse_metadata(
    config,
    thread_id=thread_id,
    user_id=resolve_runtime_user_id(runtime),
    assistant_id=record.assistant_id,
    model_name=record.model_name,
    environment=os.environ.get("HELIX_ENV") or os.environ.get("ENVIRONMENT"),
    helix_trace_id=helix_trace_id,
)

# 在 runtime context 安装后解析，使 context/configurable 反映本次 run 实际执行的 agent 名。
config.setdefault("run_name", resolve_root_run_name(config, record.assistant_id))
initial_runnable_config = RunnableConfig(**config)

# 探针：agent_factory 是否接受 app_config kwarg（make_lead_agent 签名是 (config)，不接受；
# 其他工厂可能接受）。接受则传，否则只传 config。
if ctx.app_config is not None and _agent_factory_supports_app_config(agent_factory):
    agent = agent_factory(config=initial_runnable_config, app_config=ctx.app_config)
else:
    agent = agent_factory(config=initial_runnable_config)
```

> `_agent_factory_supports_app_config` 用 `inspect.signature` 探测工厂是否含 `app_config` 参数，结果经 `lru_cache(maxsize=128)` 缓存（不可哈希的 callable 实例回退到直接检查）。

---

## 4. 工厂侧：双通道合并读取

工厂读取侧把两通道合并成一个视图（`context` 后写覆盖 `configurable`）。这是 `make_lead_agent` / `_make_lead_agent` 的第一步（见 [SKILL.md](../../SKILL.md) 第 2 节）：

```python
# core/helix/agents/lead/agent.py - 工厂读取侧的统一视图
def _get_runtime_config(config: RunnableConfig) -> dict:
    """合并 configurable 与 context（context 后写覆盖）。"""
    cfg = dict(config.get("configurable", {}) or {})
    context = config.get("context", {}) or {}
    if isinstance(context, dict):
        cfg.update(context)
    return cfg
```

工厂从合并后的 `cfg` 读所有 per-run 参数：`user_id` / `thinking_enabled` / `model_name` / `is_plan_mode` / `subagent_enabled` / `is_bootstrap` / `non_interactive` / `agent_name` / `channel_name` / `app_config`。`non_interactive` 经此读出后剥离 `ask_clarification`；`channel_name` 经此读出后判定 webhook 扣留 `update_agent`。

---

## 5. 字段流向一图

```
client body.context
  │  {model_name, thinking_enabled, agent_name, non_interactive?, user_id?, github_token?, ...}
  │
  ├─ merge_run_context_overrides(config, body.context, internal=is_internal_caller)
  │     ├─ _CONTEXT_CONFIGURABLE_KEYS  -> 双写 configurable + context（setdefault）
  │     ├─ _CONTEXT_INTERNAL_CALLER_KEYS（仅 internal）-> 双写；非 internal 不写
  │     ├─ _CONTEXT_RUNTIME_ONLY_KEYS  -> 只写 context（永不 configurable）
  │     ├─ user_id / channel_user_id   -> 只写 context（setdefault，服务端 id 优先）
  │     └─ 非 internal 调用者：strip_internal_context_keys 再从两个 section 抹掉 non_interactive
  │
  ├─ worker._build_runtime_context(thread_id, run_id, config["context"], app_config)
  │     -> runtime_ctx = {thread_id, run_id, +调用方context键(setdefault), app_config, [trace_id], [__run_journal]}
  ├─ worker._install_runtime_context(config, runtime_ctx)
  │     -> config["context"] 补全 / 落定
  ├─ config["configurable"]["__pregel_runtime"] = Runtime(context=runtime_ctx, store=store)
  │
  └─ agent_factory(config=RunnableConfig(**config))   # make_lead_agent
        └─ _get_runtime_config(config)  # configurable ∪ context（context 覆盖）
              -> 工厂读 user_id / model_name / non_interactive / channel_name / app_config ...
```

---

相关 skill：[[e2e-request-lifecycle]]（跨切不变量 1 non_interactive 的端到端穿越）、[[auth]]（AUTH_SOURCE_INTERNAL + 内部 token + owner 头）、[[multi-user-isolation]]（user_id / channel_user_id 的 per-user 目录落地）、[[scheduled-tasks]]（non_interactive 起点）、[[observability-tracing]]（HELIX_TRACE_METADATA_KEY + Langfuse metadata 注入）
