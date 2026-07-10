# 完整源码：non_interactive 剥离 ask_clarification 完整链路

> 本文件给出**跨切不变量 1**（non_interactive 剥离 ask_clarification）的完整真实代码链路：调度入口注入 -> 内部认证白名单接纳 -> 客户端 key 抹除 -> 建图过滤。
>
> SKILL.md「完整真实代码实现」段给了 `launch_scheduled_thread_run` 入口片段与索引；此处补全完整链路的每一段源码与所有边界处理。
>
> 真实实现已按匿名化规则映射到中立结构（应用层 `gateway.gateway.*`、框架层 `helix.*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

---

## 链路总览

```
① 调度入口 launch_scheduled_thread_run
   └─ 合成内部认证请求（auth_source=INTERNAL）+ context={"non_interactive": True}
       │
② start_run 内：按 auth_source 分流
   ├─ is_internal_caller = (auth_source == INTERNAL)
   ├─ merge_run_context_overrides(config, body.context, internal=is_internal_caller)
   │     └─ internal=True 才把 non_interactive 纳入合并集合（写进 configurable + context）
   └─ if not is_internal_caller: strip_internal_context_keys(config)
         └─ 无条件从 context/configurable 两节抹除 non_interactive（防客户端伪造）
             │
③ worker：_build_runtime_context 把 config["context"] 装进 runtime.context
   └─ runtime.context["non_interactive"] = True（跨 contextvar 边界存活）
       │
④ 建图 _make_lead_agent：读 non_interactive -> 剥离 ask_clarification
   └─ filtered = [t for t in filtered if t.name not in _NON_INTERACTIVE_DISABLED_TOOL_NAMES]
```

三道防线串联：①入口注入 + 标记内部 -> ②认证按身份接纳/抹除 -> ③建图按标志剥离。任何一道失守，其余仍兜底。

---

## 1. 调度入口：launch_scheduled_thread_run（注入 non_interactive + 合成内部认证）

```python
# gateway/gateway/services.py
async def launch_scheduled_thread_run(
    *,
    thread_id: str,
    assistant_id: str | None,
    prompt: str,
    request: Request | None = None,
    app: Any | None = None,
    owner_user_id: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """桥接调度器 -> run 生命周期。

    合成一个最小请求对象，模拟内部认证调用者（scheduler 是受信后端，不走浏览器
    cookie），然后调 start_run 走与 HTTP 路径完全相同的 run 创建链路。这是跨切
    不变量 1 的起点：context={"non_interactive": True} 在此注入，并以
    AUTH_SOURCE_INTERNAL 标记调用者身份，下游 merge_run_context_overrides
    (internal=True) 才会接纳它。
    """
    if request is None:
        if app is None:
            raise ValueError("launch_scheduled_thread_run requires request or app")
        # 合成内部认证请求：
        # - headers 带 owner 头（让 per-user 目录落到任务属主而非 "default"）
        # - state.user = get_internal_user()（合成内部用户，system_role="internal"）
        # - state.auth_source = AUTH_SOURCE_INTERNAL（②认证标记：受信任内部调用者）
        #   下游 merge_run_context_overrides(internal=True) 才会接纳 non_interactive；
        #   否则 strip_internal_context_keys 会把它抹除（见第 3 节）。
        request = SimpleNamespace(
            app=app,
            headers=({INTERNAL_OWNER_USER_ID_HEADER_NAME: owner_user_id} if owner_user_id else {}),
            state=SimpleNamespace(
                user=get_internal_user(),
                auth_source=AUTH_SOURCE_INTERNAL,
            ),
            cookies={},
        )
    # SimpleNamespace 顶替 HTTP 路径解析出的 Pydantic run-request body。
    # start_run 若新增直接读取的 body.* 字段，须在此同步补字段，否则调度路径会失配。
    body = SimpleNamespace(
        assistant_id=assistant_id,
        input={"messages": [{"role": "user", "content": prompt}]},
        command=None,
        metadata=metadata or {},
        config=None,
        # non_interactive=True 是跨切不变量 1 的载荷；user_id 镜像 IM 通道的写法，
        # 让无 ContextVar 回退的运行时消费者（如 user-scoped 护栏 provider）看到属主。
        # inject_authenticated_user_context 对内部用户会跳过，故这里显式塞 user_id。
        context=({"non_interactive": True, "user_id": owner_user_id} if owner_user_id else {"non_interactive": True}),
        webhook=None,
        checkpoint_id=None,
        checkpoint=None,
        interrupt_before=None,
        interrupt_after=None,
        stream_mode=None,
        stream_subgraphs=False,
        stream_resumable=None,
        on_disconnect="continue",
        on_completion="keep",
        multitask_strategy="reject",
        after_seconds=None,
        if_not_exists="reject",
        feedback_keys=None,
    )
    record = await start_run(body, thread_id, request)
    return {"run_id": record.run_id, "thread_id": record.thread_id}
```

> `on_disconnect="continue"`：调度 run 无人盯屏，客户端"断连"语义不适用--断的只是内部合成请求，run 必须继续跑完。`multitask_strategy="reject"`：同线程已有在途 run 时直接冲突，不抢占（调度场景由 overlap_policy 在 service 层处理，不靠 multitask）。

---

## 2. 白名单 + 抹除实现（_CONTEXT_INTERNAL_CALLER_KEYS / strip_internal_context_keys / merge_run_context_overrides）

```python
# gateway/gateway/services.py

# body.context 中被 langgraph-compat 层转发进 run config 的白名单 key。
# 这些值必须同时写进 configurable（兼容 legacy _get_runtime_config 读者）与
# context（LangGraph >=1.1.9 后 ToolRuntime.context 不再回退 configurable）。
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

# 仅内部认证调用者（调度路径）生效的 context key。
# non_interactive 会在 ④建图剥离 ask_clarification；任意 HTTP/IM 客户端不得能
# 强制自主执行。
_CONTEXT_INTERNAL_CALLER_KEYS: frozenset[str] = frozenset({"non_interactive"})

# 仅写进 config['context']（成为 ToolRuntime.context / runtime.context）、
# 永不写进 configurable 的 key。configurable 会被 checkpoint 持久化，故短命
# token / runtime flag 必须留在 context 节避免落盘。
#   github_token        - GitHub channel 签发的 App installation token；bash 工具
#                         暴露为 GH_TOKEN/GITHUB_TOKEN，让 gh/git 以 bot 身份 push。
#   disable_clarification - 为非交互通道（GitHub webhook）设，让 ClarificationMiddleware
#                         proceed 而非 dead-end run（webhook 通道的旁路，见第 5 节）。
_CONTEXT_RUNTIME_ONLY_KEYS: frozenset[str] = frozenset({"github_token", "disable_clarification"})


def strip_internal_context_keys(config: dict[str, Any]) -> None:
    """抹除非内部调用者走私进 run config 的内部专用 key。

    单靠 merge_run_context_overrides 的 internal 门控还不够：
    build_run_config 会把客户端 body.config['context']/body.config['configurable']
    原样拷贝进 config，所以装配完成后必须再从这两节里把同样的 key 扫掉。
    双层防御：merge 不接纳 + 装配后扫描抹除。
    """
    for section in ("context", "configurable"):
        value = config.get(section)
        if isinstance(value, dict):
            for key in _CONTEXT_INTERNAL_CALLER_KEYS:
                value.pop(key, None)


def merge_run_context_overrides(config: dict[str, Any], context: Mapping[str, Any] | None, *, internal: bool = False) -> None:
    """把 body.context 的白名单 key 合并进 config['configurable'] 与 config['context']。

    使它们对 legacy configurable 读者与 LangGraph ToolRuntime.context 消费者
    （如 setup_agent 工具）都可见。

    internal=True 时额外接纳 _CONTEXT_INTERNAL_CALLER_KEYS（non_interactive）；
    internal=False 时这些 key 不在合并集合里，且会被随后的 strip_internal_context_keys
    从原样拷贝的 body.config 里抹除--双层防御。

    user_id 同样走 runtime-context-only 规则：工具可读，但不进 configurable
    （不随 thread checkpoint 持久化），且用 setdefault 使服务端认证态 stamp 的
    id 永远覆盖客户端塞的值。
    """
    if not context:
        return
    configurable = config.setdefault("configurable", {})
    runtime_context = config.setdefault("context", {})
    # 内部调用者才把 non_interactive 纳入合并集合
    keys = _CONTEXT_CONFIGURABLE_KEYS | _CONTEXT_INTERNAL_CALLER_KEYS if internal else _CONTEXT_CONFIGURABLE_KEYS
    for key in keys:
        if key in context:
            if isinstance(configurable, dict):
                configurable.setdefault(key, context[key])
            if isinstance(runtime_context, dict):
                runtime_context.setdefault(key, context[key])
    # Context-only key（secrets / runtime flag）只进 context 节，不进 configurable
    for key in _CONTEXT_RUNTIME_ONLY_KEYS:
        if key in context and isinstance(runtime_context, dict):
            runtime_context.setdefault(key, context[key])
    if "user_id" in context and isinstance(runtime_context, dict):
        runtime_context.setdefault("user_id", context["user_id"])
    # IM 通道的原始平台 user id（飞书 open_id、Slack Uxxx 等）同 user_id 规则
    if "channel_user_id" in context and isinstance(runtime_context, dict):
        runtime_context.setdefault("channel_user_id", context["channel_user_id"])
```

---

## 3. start_run 内的分流调用（按 auth_source 决定接纳/抹除）

```python
# gateway/gateway/services.py - start_run 内与不变量 1 相关的分流段
# （start_run 完整实现见 [[gateway-runs-and-sse]]；此处只摘 merge/strip/inject 三行
#   判定 + 它们的上下文，展示 non_interactive 如何穿越这一跳）

        # 此前已做 owner 解析、create_or_reject、build_run_config、
        # apply_checkpoint_to_run_config 等步骤，与本不变量无关，完整见 [[gateway-runs-and-sse]]。

        # 把框架特定的 context override 合并进 configurable 与 context。
        # context 字段是 langgraph-compat 层的自定义扩展，承载 agent 配置
        # （model_name、thinking_enabled 等）。仅 agent 相关 key 被转发；
        # 未知 key（如 thread_id）被忽略。
        is_internal_caller = getattr(getattr(request, "state", None), "auth_source", None) == AUTH_SOURCE_INTERNAL
        merge_run_context_overrides(config, getattr(body, "context", None), internal=is_internal_caller)
        if not is_internal_caller:
            # body.config 是 free-form、被 build_run_config 原样拷贝的；
            # 客户端可能把 non_interactive 塞进 config['context']/config['configurable']
            # 伪造无人值守。内部调用者已经经 merge 接纳；非内部调用者在此无条件抹除两节里的该 key。
            strip_internal_context_keys(config)
        internal_owner_user = await resolve_trusted_internal_owner_for_attribution(request, owner_user_id)
        inject_authenticated_user_context(config, request, internal_owner_user=internal_owner_user)

        # 此后起 run_agent worker，与本不变量无关，完整见 [[gateway-runs-and-sse]]。
```

> `inject_authenticated_user_context` 对内部用户（`system_role == "internal"`）会跳过 user_id stamp（内部用户的 user_id 由 merge 阶段的 `body.context` 决定），故 `launch_scheduled_thread_run` 必须在 `body.context` 里显式塞 `user_id`。这正是调度入口写 `context={"non_interactive": True, "user_id": owner_user_id}` 的原因。

---

## 4. worker 装载 runtime.context（跨 contextvar 边界存活）

```python
# core/helix/runtime/runs/worker.py - _build_runtime_context（run_agent 完整源码见 [[gateway-runs-and-sse]]）
# 把 config['context']（含 non_interactive）装进 runtime.context，成为 ToolRuntime.context。
# 这一步使 non_interactive 能穿越 contextvar 可能丢失的边界（后台 worker、不
# copy_context 的池、未来跨进程驱动）。

def _build_runtime_context(thread_id: str, run_id: str, caller_context: Any | None,
                           app_config: AppConfig | None = None) -> dict[str, Any]:
    """构造成为 ToolRuntime.context 的字典。永远含 thread_id/run_id；
    调用者 config['context'] 的额外 key（含 non_interactive）以 setdefault 合入，
    永不覆盖 thread_id/run_id。"""
    runtime_ctx: dict[str, Any] = {"thread_id": thread_id, "run_id": run_id}
    if isinstance(caller_context, dict):
        for key, value in caller_context.items():
            runtime_ctx.setdefault(key, value)
    if app_config is not None:
        runtime_ctx["app_config"] = app_config
    return runtime_ctx

# run_agent 内调用（摘）：
runtime_ctx = _build_runtime_context(thread_id, run_id, config.get("context"), ctx.app_config)
_install_runtime_context(config, runtime_ctx)
runtime = Runtime(context=cast(Any, runtime_ctx), store=store)
config.setdefault("configurable", {})["__pregel_runtime"] = runtime  # LangGraph 1.1+ 经此读取 runtime.context
```

---

## 5. 建图过滤：_make_lead_agent 读 non_interactive 剥离 ask_clarification

```python
# core/helix/agents/lead/agent.py
# 无人值守（调度 / 后台 run）时从工具列表剥离的 builtin 工具名。
# ask_clarification 会 Command(goto=END) 中断 run 等用户回复，无人盯屏会永久卡死。
# frozenset 便于未来扩展更多无人值守禁用工具。
_NON_INTERACTIVE_DISABLED_TOOL_NAMES = frozenset({"ask_clarification"})


def _get_runtime_config(config: RunnableConfig) -> dict:
    """合并 legacy configurable 与 LangGraph runtime context。

    non_interactive 由 start_run 合进 config['context']，这里把 context 叠到 cfg 上，
    使 _make_lead_agent 能像读 configurable 一样读到它。
    """
    cfg = dict(config.get("configurable", {}) or {})
    context = config.get("context", {}) or {}
    if isinstance(context, dict):
        cfg.update(context)
    return cfg


def _make_lead_agent(config: RunnableConfig, *, app_config: AppConfig):
    """LangGraph graph factory，每 run 调一次。

    本函数完整实现见 [[agent-graph-factory]]；此处只摘与跨切不变量 1 相关的
    几行：读 non_interactive -> 工具装配 -> 剥离 ask_clarification。
    其间还有 user_id 解析、model_name 解析、metadata/tracing 注入、
    skills_for_tool_policy 加载等，均与本不变量无关。
    """
    # 懒加载避免循环依赖
    from helix.tools import get_available_tools
    from helix.tools.builtins.tool_search import assemble_deferred_tools

    cfg = _get_runtime_config(config)
    # 其间还有 resolved_app_config、resolved_user_id、model_name、agent_config 等解析，
    # 均与本不变量无关，完整见源文件。
    non_interactive = bool(cfg.get("non_interactive", False))   # 读 non_interactive 标志

    # 其间还有 skills_for_tool_policy、skill_setup 等加载，均与本不变量无关。

    # 工具装配：builtins + sandbox + mcp + skills + task，再过技能白名单
    raw_tools = get_available_tools(model_name=model_name,
                                    groups=agent_config.tool_groups if agent_config else None,
                                    subagent_enabled=subagent_enabled, app_config=resolved_app_config)
    filtered = filter_tools_by_skill_allowed_tools(raw_tools + extra_tools, skills_for_tool_policy,
                                                   always_allowed_tool_names=SKILL_LOADING_TOOL_NAMES)
    if non_interactive:
        # 无人值守：从工具列表剥离 ask_clarification（跨切不变量 1 的落点）
        filtered = [tool for tool in filtered if tool.name not in _NON_INTERACTIVE_DISABLED_TOOL_NAMES]
    final_tools, setup = assemble_deferred_tools(filtered, enabled=resolved_app_config.tool_search.enabled)

    # 其后 create_agent 一次绑定模型 + 中间件链 + 静态系统提示词，完整见 [[agent-graph-factory]]。
```

> `ask_clarification` 是**内置 builtin 工具**（与 `present_files` 同列 `BUILTIN_TOOLS`），故在 `filter_tools_by_skill_allowed_tools` 之后、`assemble_deferred_tools` 之前的过滤能稳定命中它。直接不让模型"看见" `ask_clarification` 的 schema，比让模型调用后再拦截更省一次 LLM 往返、更确定。

---

## 6. 纵深防御：webhook 通道的 disable_clarification 旁路

即便 `ask_clarification` 没被剥离（如 GitHub webhook 通道走的是另一条 `disable_clarification` 标志而非 `non_interactive`），`ClarificationMiddleware._is_disabled` 会读 `runtime.context.get("disable_clarification")`，命中则不 `Command(goto=END)`，而是返回一条普通 `ToolMessage` 让 agent 继续跑。

`disable_clarification` 同样是 runtime-only key（`_CONTEXT_RUNTIME_ONLY_KEYS`），不进 `configurable`、不进 checkpoint。两套机制覆盖不同通道，但目标一致：无人值守不卡死。

```python
# core/helix/agents/middlewares/clarification_middleware.py（链尾中间件，完整见 [[middleware-chain-design]]）
@override
def wrap_tool_call(self, request: ToolCallRequest, handler) -> ToolMessage | Command:
    if request.tool_call.get("name") != "ask_clarification":
        return handler(request)                                  # 非澄清：正常执行
    if self._is_disabled(request):
        return self._handle_disabled_clarification(request)      # non_interactive/disable_clarification 通道：转普通 ToolMessage 继续
    return self._handle_clarification(request)                   # 交互通道：Command(goto=END) 中断
```

---

## 为什么是三道防线而非单点

1. **单靠建图剥离**：客户端伪造 `non_interactive` 就能强制 agent 自主执行（跳过澄清做高风险动作）。
2. **单靠认证门控**：建图阶段一旦漏读 `non_interactive` 就会卡死调度 run。
3. **三道串联**：①入口注入 + 标记内部 -> ②认证按身份接纳/抹除 -> ③建图按标志剥离。任何一道失守，其余仍兜底。

白名单而非黑名单：`_CONTEXT_INTERNAL_CALLER_KEYS` 是显式白名单（目前仅 `non_interactive`），新增内部专用 key 必须显式登记。客户端能塞的 key 默认全部被当不可信，`strip_internal_context_keys` 无条件扫两节。这把"哪些 key 可信"从"客户端说了算"翻转为"服务端说了算"。

> 关联：poller 全貌见 [scheduler-service.md](./scheduler-service.md)；cron/once 纯计算见 [schedules-calc.md](./schedules-calc.md)；跨切不变量 1 完整推导见脊柱 [references/cross-cutting-invariants.md](../../e2e-request-lifecycle/references/cross-cutting-invariants.md)；端到端位置见 [[e2e-request-lifecycle]]。
