# 跨切不变量完整推导

> 本文件是脊柱 `SKILL.md` 第"跨切不变量（必读）"段的深度展开。脊柱只给概要；此处给出 3 个不变量各自的**问题 -> 真实代码链路 -> 为什么这样设计 -> 违反后果 -> 测试锚点**完整推导。
>
> 代码已按插件匿名化规则映射到自定结构（`helix.*` / `gateway.*` / `channels.*` / `scheduler.*`），去除一切项目字样；原代码注释保真。每段链路给出的文件路径是自定结构路径，对应真实实现可由 `CONVENTIONS.md §3` 映射表反查。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱）、`[[scheduled-tasks]]`、`[[auth]]`、`[[multi-user-isolation]]`、`[[gateway-runs-and-sse]]`、`[[long-running-and-cancellation]]`。

---

## 不变量 1：`non_interactive` 剥离 `ask_clarification`（无人值守不卡死）

### 问题

定时任务、后台 run、IM webhook 这类入站路径**无人盯屏**。若 lead agent 在无人值守 run 里调用了 `ask_clarification` 工具，`ClarificationMiddleware` 会返回 `Command(goto=END)` 中断 run、把一个 Human Input Card 抛给前端等用户回复。但调度/webhook 通道没有"用户回复下一轮"的语义——run 会停在 END，永远卡住，占用线程、占用 `multitask_strategy="reject"` 的在途名额，且产出一个用户永远看不到的悬空澄清卡。

需求：**无人值守 run 必须不能调 `ask_clarification`**；同时**普通 HTTP/IM 客户端不得能伪造"无人值守"**绕过澄清（否则恶意客户端可强制 agent 自主执行不该自主执行的动作）。

### 真实代码链路

链路横穿 ①入站（调度）-> ②认证 -> ③路由 -> ④建图 四跳，靠"内部调用者白名单 + 工具剥离 + 防御性抹除"三道防线串联。

**第一道：调度入口注入 `non_interactive` 并标记内部调用者。**

```python
# scheduler/scheduler/service.py - poller 认领到期任务（lease 并发限流），交给 launch_run
class ScheduledTaskService:
    def __init__(self, *, task_repo, task_run_repo, launch_run, poll_interval_seconds,
                 lease_seconds, max_concurrent_runs) -> None:
        self._launch_run = launch_run
        self._lease_seconds = lease_seconds
        # max_concurrent_runs 是全局在途上限，不是单轮认领数：长任务会跨轮累积，
        # 每轮只认领剩余预算内的任务，避免超限。
        self._max_concurrent_runs = max_concurrent_runs
        # lease_owner 唯一标识本 poller 实例，claim 时写入；到期前可续约，
        # 多实例并发抢同一任务时只有 lease 持有者能推进。
        self._lease_owner = f"{socket.gethostname()}:{uuid.uuid4().hex}"

    async def run_once(self, *, now: datetime) -> None:
        active = await self._task_run_repo.count_active_runs()
        budget = self._max_concurrent_runs - active
        if budget <= 0:
            return
        claimed = await self._task_repo.claim_due_tasks(
            now=now, lease_owner=self._lease_owner,
            lease_seconds=self._lease_seconds, limit=budget)
        for task in claimed:
            await self.dispatch_task(task, now=now, trigger="scheduled")
```

```python
# gateway/gateway/services.py - 桥接调度器 -> run 生命周期（合成内部认证请求 + non_interactive）
async def launch_scheduled_thread_run(
    *, thread_id: str, assistant_id: str | None, prompt: str,
    request: Request | None = None, app: Any | None = None,
    owner_user_id: str | None = None, metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if request is None:
        if app is None:
            raise ValueError("launch_scheduled_thread_run requires request or app")
        # 合成一个最小请求对象，模拟内部认证调用者：
        # - headers 带 owner 头（让 per-user 目录落到任务属主而非 "default"）
        # - state.user = get_internal_user()（合成内部用户，system_role="internal"）
        # - state.auth_source = AUTH_SOURCE_INTERNAL（②认证标记：这是受信任内部调用者）
        #   下游 merge_run_context_overrides(internal=True) 才会接纳 non_interactive；
        #   否则 strip_internal_context_keys 会把它抹除（见第三道防线）。
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
        # non_interactive=True 是本不变量的载荷；user_id 镜像 IM 通道的写法，
        # 让无 ContextVar 回退的运行时消费者（如 user-scoped 护栏 provider）看到属主。
        # inject_authenticated_user_context 对内部用户会跳过，故这里显式塞 user_id。
        context=({"non_interactive": True, "user_id": owner_user_id} if owner_user_id
                 else {"non_interactive": True}),
        webhook=None,
        multitask_strategy="reject", on_disconnect="continue", on_completion="keep",
        if_not_exists="reject",
        checkpoint_id=None, checkpoint=None,
        interrupt_before=None, interrupt_after=None,
        stream_mode=None, stream_subgraphs=False, stream_resumable=None,
        after_seconds=None, feedback_keys=None,
    )
    record = await start_run(body, thread_id, request)
    return {"run_id": record.run_id, "thread_id": record.thread_id}
```

> 说明：上面 `body` 是 `launch_scheduled_thread_run` 合成的完整 run-request 体（字段与 HTTP 路径的 Pydantic 模型一一对应）。本不变量关注的是 `context={"non_interactive": True}` 这条载荷怎么穿越各跳且不被伪造；其余字段是默认值，不参与本不变量逻辑。

**第二道：②认证 + ③路由按调用者身份决定是否接纳 `non_interactive`。**

```python
# gateway/gateway/services.py - start_run 内：按 auth_source 分流，再防御性抹除
# （start_run 完整源码见 references/code/05-middleware-chain.md 同目录的脊柱 ③路由段，
#   这里只摘与本不变量相关的三行判定 + 抹除调用）
is_internal_caller = getattr(getattr(request, "state", None), "auth_source", None) == AUTH_SOURCE_INTERNAL
merge_run_context_overrides(config, getattr(body, "context", None), internal=is_internal_caller)
if not is_internal_caller:
    # body.config 是 free-form、被 build_run_config 原样拷贝的；
    # 客户端可能把 non_interactive 塞进 config['context']/config['configurable'] 伪造无人值守。
    # 内部调用者已经经 merge 接纳；非内部调用者在此无条件抹除两节里的该 key。
    strip_internal_context_keys(config)
```

```python
# gateway/gateway/services.py - 白名单与抹除的实现
# 仅内部认证调用者（调度路径）生效的 context key。
# non_interactive 会在 ④建图剥离 ask_clarification；任意 HTTP/IM 客户端不得能强制自主执行。
_CONTEXT_INTERNAL_CALLER_KEYS: frozenset[str] = frozenset({"non_interactive"})

def strip_internal_context_keys(config: dict[str, Any]) -> None:
    """抹除非内部调用者走私进 run config 的内部专用 key。

    单靠 merge_run_context_overrides 的 internal 门控还不够：
    build_run_config 会把客户端 body.config['context']/body.config['configurable']
    原样拷贝进 config，所以装配完成后必须再从这两节里把同样的 key 扫掉。
    """
    for section in ("context", "configurable"):
        value = config.get(section)
        if isinstance(value, dict):
            for key in _CONTEXT_INTERNAL_CALLER_KEYS:
                value.pop(key, None)

def merge_run_context_overrides(config: dict[str, Any], context: Mapping[str, Any] | None,
                                *, internal: bool = False) -> None:
    """把 body.context 的白名单 key 合并进 config['configurable'] 与 config['context']。

    internal=True 时额外接纳 _CONTEXT_INTERNAL_CALLER_KEYS（non_interactive）；
    internal=False 时这些 key 不在合并集合里，且会被随后的 strip_internal_context_keys
    从原样拷贝的 body.config 里抹除——双层防御。
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
    # 仅 context 节的 key（secrets / runtime flag）--不进 configurable（会被 checkpoint 持久化）
    for key in _CONTEXT_RUNTIME_ONLY_KEYS:
        if key in context and isinstance(runtime_context, dict):
            runtime_context.setdefault(key, context[key])
    # user_id 同样走 runtime-context-only 规则：工具可读，但不进 configurable（不随 thread checkpoint）
    if "user_id" in context and isinstance(runtime_context, dict):
        runtime_context.setdefault("user_id", context["user_id"])
    # IM 通道的原始平台 user id（飞书 open_id、Slack Uxxx 等）同 user_id 规则
    if "channel_user_id" in context and isinstance(runtime_context, dict):
        runtime_context.setdefault("channel_user_id", context["channel_user_id"])
```

**第三道：worker 把 `config["context"]` 装进 `runtime.context`，④建图读它剥离工具。**

```python
# core/helix/runtime/runs/worker.py - 把 config['context']（含 non_interactive）装进 runtime.context
# （run_agent 完整源码见 references/code/07-streaming-and-resume.md；这里摘 context 装载段）
runtime_ctx = _build_runtime_context(thread_id, run_id, config.get("context"), ctx.app_config)
_install_runtime_context(config, runtime_ctx)
runtime = Runtime(context=cast(Any, runtime_ctx), store=store)
config.setdefault("configurable", {})["__pregel_runtime"] = runtime  # LangGraph 1.1+ 经此读取 runtime.context

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
```

```python
# core/helix/agents/lead/agent.py - ④建图：读 non_interactive，剥离 ask_clarification
_NON_INTERACTIVE_DISABLED_TOOL_NAMES = frozenset({"ask_clarification"})

def _get_runtime_config(config: RunnableConfig) -> dict:
    """合并 legacy configurable 与 LangGraph runtime context。

    non_interactive 由 start_run 合进 config['context']，这里把 context 叠到 cfg 上，
    使 _make_lead_agent 能像读 configurable 一样读到它。"""
    cfg = dict(config.get("configurable", {}) or {})
    context = config.get("context", {}) or {}
    if isinstance(context, dict):
        cfg.update(context)
    return cfg

def _make_lead_agent(config: RunnableConfig, *, app_config: AppConfig):
    # 注：本函数完整实现见 references/code/05-middleware-chain.md 同源文件与脊柱 ④建图段。
    # 此处只摘与不变量 1 相关的几行：读 non_interactive -> 工具装配 -> 剥离 ask_clarification。
    cfg = _get_runtime_config(config)
    resolved_app_config = app_config
    # 其间还有 user_id 解析、model_name 解析、metadata/tracing 注入、skills_for_tool_policy 加载等，
    # 均与本不变量无关，完整见源文件。
    non_interactive = bool(cfg.get("non_interactive", False))   # 读 non_interactive 标志
    # 工具装配：builtins + sandbox + mcp + skills + task，再过技能白名单
    raw_tools = get_available_tools(model_name=model_name,
                                    groups=agent_config.tool_groups if agent_config else None,
                                    subagent_enabled=subagent_enabled, app_config=resolved_app_config)
    filtered = filter_tools_by_skill_allowed_tools(raw_tools + extra_tools, skills_for_tool_policy,
                                                   always_allowed_tool_names=SKILL_LOADING_TOOL_NAMES)
    if non_interactive:
        # 无人值守：从工具列表剥离 ask_clarification（本不变量的落点）
        filtered = [tool for tool in filtered if tool.name not in _NON_INTERACTIVE_DISABLED_TOOL_NAMES]
    final_tools, setup = assemble_deferred_tools(filtered, enabled=resolved_app_config.tool_search.enabled)
    # 一次绑定：模型 + 中间件链 + 静态系统提示词（完整 create_agent 入参见源文件）
    return create_agent(
        model=create_chat_model(name=model_name, thinking_enabled=thinking_enabled,
                                reasoning_effort=reasoning_effort, app_config=resolved_app_config,
                                attach_tracing=False),
        tools=final_tools,
        middleware=build_middlewares(config, model_name=model_name, agent_name=agent_name,
                                     available_skills=available_skills, app_config=resolved_app_config,
                                     deferred_setup=setup, user_id=resolved_user_id),
        system_prompt=apply_prompt_template(subagent_enabled=subagent_enabled, agent_name=agent_name,
                                            available_skills=available_skills, app_config=resolved_app_config,
                                            deferred_names=setup.deferred_names, user_id=resolved_user_id),
        state_schema=ThreadState,
    )
```

> 注：`ask_clarification` 是**内置 builtin 工具**（与 `present_files` 同列 `BUILTIN_TOOLS`），所以在 `filter_tools_by_skill_allowed_tools` 之后、`assemble_deferred_tools` 之前的过滤能稳定命中它。`_NON_INTERACTIVE_DISABLED_TOOL_NAMES` 是 `frozenset`，便于未来扩展更多无人值守禁用工具。

**纵深防御（webhook 通道的旁路）：** 即便 `ask_clarification` 没被剥离（如 GitHub webhook 通道走的是另一条 `disable_clarification` 标志而非 `non_interactive`），`ClarificationMiddleware._is_disabled` 会读 `runtime.context.get("disable_clarification")`，命中则不 `Command(goto=END)`，而是返回一条普通 `ToolMessage` 让 agent 继续跑（见 `references/code/05-middleware-chain.md`）。`disable_clarification` 同样是 runtime-only key（`_CONTEXT_RUNTIME_ONLY_KEYS`），不进 `configurable`、不进 checkpoint。两套机制覆盖不同通道，但目标一致：无人值守不卡死。

### 为什么这样设计

1. **三道防线串联，而非单点信任。** 单靠建图剥离，客户端伪造 `non_interactive` 就能强制 agent 自主执行；单靠认证门控，建图阶段一旦漏读就会卡死调度。三道各自独立、层层收窄：①入口注入 + 标记内部 -> ②认证按身份接纳/抹除 -> ③建图按标志剥离。任何一道失守，其余仍能兜底。
2. **白名单而非黑名单。** `_CONTEXT_INTERNAL_CALLER_KEYS` 是显式白名单（目前仅 `non_interactive`），新增内部专用 key 必须显式登记。客户端能塞的 key 默认全部被当作不可信，`strip_internal_context_keys` 无条件扫两节。这把"哪些 key 可信"从"客户端说了算"翻转为"服务端说了算"。
3. **`non_interactive` 走 runtime context，不走 `configurable`。** `configurable` 会被持久化进 checkpoint；`non_interactive` 是 per-run 标志，不该跨 run 留存。`merge_run_context_overrides` 把它同时写进 `configurable` 与 `context`（兼容 legacy configurable 读者），但建图只读 `context` 叠加结果，且 run 结束后该标志不随 checkpoint 复活。
4. **工具剥离优先于中间件兜底。** 直接不让模型"看见" `ask_clarification` 的 schema，比让模型调用后再拦截更省一次 LLM 往返、更确定。中间件兜底（`disable_clarification`）是为 webhook 这类无法改工具集的通道准备的第二选择。

### 违反后果

- **漏剥离 `ask_clarification`**：调度 run 调用澄清 -> `Command(goto=END)` -> run 停在 interrupted/ended，占用 `multitask_strategy="reject"` 在途名额 -> 同线程后续调度全部 `ConflictError` -> 任务永久卡死、cron 堆积。
- **客户端能伪造 `non_interactive`**：恶意 HTTP 客户端塞 `context={"non_interactive": True}` 强制 agent 跳过澄清、自主执行高风险动作（如 `bash` 删文件、`update_agent` 改 SOUL.md），把"人在回路"约束架空。
- **`non_interactive` 误进 `configurable` 且被 checkpoint**：下一次同线程 run 复活该标志，普通交互 run 也被误判为无人值守、剥离澄清，用户体验回归。

### 测试锚点

1. **调度路径剥离**：mock `launch_scheduled_thread_run` 起一个 run，断言 `_make_lead_agent` 产出的 `final_tools` 中**不含** `ask_clarification`；`runtime.context["non_interactive"] is True`。
2. **HTTP 客户端伪造无效**：用普通（非内部 token）HTTP 客户端发 `context={"non_interactive": True}`，断言进入 `_make_lead_agent` 时 `cfg.get("non_interactive")` 为 falsy、`ask_clarification` **仍在**工具集；且 `config["context"]` / `config["configurable"]` 中 `non_interactive` 已被 `strip_internal_context_keys` 抹除。
3. **IM 通道（内部 token）**：带内部 token + owner 头的 IM 消息默认**不**设 `non_interactive`（`launch_scheduled_thread_run` 才设），故 `ask_clarification` 仍在；但 webhook 通道设 `disable_clarification` 时，`ClarificationMiddleware._is_disabled` 返回 True，`ask_clarification` 调用返回 proceed ToolMessage 而非 `Command(goto=END)`。
4. **白名单回归**：新增一个内部专用 key 到 `_CONTEXT_INTERNAL_CALLER_KEYS`，断言非内部调用者的该 key 被抹除、内部调用者被接纳（防回归门）。

---

## 不变量 2：`user_id` 全链路隔离（per-user 目录）

### 问题

多用户共享同一个 Gateway 进程。每个用户的 thread 数据（workspace/uploads/outputs）、记忆（`memory.json`）、自定义 agent、自定义 skill 必须严格按 `user_id` 隔离——用户 A 绝不能读到用户 B 的文件、不能把自己的 run 跑到 B 的桶里。三条入站路径的 `user_id` 来源不同（Web=JWT 用户、IM=内部 token+owner 头、调度=合成内部用户），但必须在 ②认证处汇合到**同一个** contextvar，此后 ③–⑧ 全靠读它定位文件系统桶，不再关心凭证来源。

同时要防两类攻击：①IM 通道的 owner 头若含路径穿越字符（`..`/`/`）会逃逸 per-user 桶；②浏览器调用者塞 owner 头冒充他人。

### 真实代码链路

链路横穿 ②认证 -> ③路由 -> ④建图 -> ⑤中间件（ThreadData）-> ⑥执行（工具路径解析）。

**②认证：三种凭证汇合到一个 contextvar。**

```python
# gateway/gateway/auth_middleware.py - 全局 fail-closed 闸门（完整源码见 references/code/02-auth-gate.md）
class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        if _is_public(request.url.path):
            return await call_next(request)

        internal_user = None
        if is_valid_internal_auth_token(request.headers.get(INTERNAL_AUTH_HEADER_NAME)):
            # 受信任内部调用者（scheduler/channels）：合成内部用户；
            # 可选 owner 头覆盖 .id，使 per-user 目录落到 IM 通道用户而非 "default"。
            owner_user_id = request.headers.get(INTERNAL_OWNER_USER_ID_HEADER_NAME)
            if owner_user_id:
                owner_user_id = owner_user_id.strip()
            internal_user = get_internal_user(owner_user_id=owner_user_id or None)

        auth_source = AUTH_SOURCE_SESSION
        access_token = request.cookies.get("access_token")
        if internal_user is not None:
            user = internal_user
            auth_source = AUTH_SOURCE_INTERNAL
        elif access_token:
            user = await get_current_user_from_request(request)   # 严格 JWT 校验
        elif is_auth_disabled():
            user = get_auth_disabled_user()                       # 本地/E2E 合成 admin
            auth_source = AUTH_SOURCE_AUTH_DISABLED
        else:
            # fail-closed：无任何有效凭证 -> 401 NOT_AUTHENTICATED
            return JSONResponse(status_code=401, content={
                "detail": AuthErrorResponse(
                    code=AuthErrorCode.NOT_AUTHENTICATED,
                    message="Authentication required",
                ).model_dump()
            })

        request.state.user = user
        request.state.auth_source = auth_source
        # 关键：把 user 写入 contextvar。此后 ③–⑧ 只读它，不再关心凭证来源。
        token = set_current_user(user)
        try:
            return await call_next(request)
        finally:
            reset_current_user(token)   # 请求结束恢复，防跨请求泄漏
```

```python
# gateway/gateway/internal_auth.py - 内部 token 校验 + owner 头规范化（防路径穿越）
INTERNAL_AUTH_HEADER_NAME = "X-Helix-Internal-Token"
INTERNAL_OWNER_USER_ID_HEADER_NAME = "X-Helix-Owner-User-Id"
INTERNAL_AUTH_ENV_VAR = "HELIX_INTERNAL_AUTH_TOKEN"
INTERNAL_SYSTEM_ROLE = "internal"

def is_valid_internal_auth_token(token: str | None) -> bool:
    """常量时间比较，防时序侧信道。token 来自本 worker 启动时加载/生成的内部令牌。"""
    return bool(token) and secrets.compare_digest(token, _INTERNAL_AUTH_TOKEN)

def get_internal_user(owner_user_id: str | None = None):
    """合成受信任内部通道调用者用的 user。

    owner_user_id（从 X-Helix-Owner-User-Id 头取出）非空时，合成 user 的 .id 承载
    真实通道属主而非 DEFAULT_USER_ID。owner id 经 make_safe_user_id 规范化：
    IM 通道 id（飞书 open_id 带 ou_ 前缀和下划线、Telegram 负数 chat id 等）含
    [A-Za-z0-9_-] 以外字符，规范化后无法逃逸 per-user 存储桶或经头值技巧
    （尾斜杠、.. 段）冒充其他用户。规范化有损但确定：两个不同原始输入永不共享 safe id。"""
    if owner_user_id:
        effective_id = make_safe_user_id(owner_user_id)
    else:
        effective_id = DEFAULT_USER_ID
    return SimpleNamespace(id=effective_id, system_role=INTERNAL_SYSTEM_ROLE)

def get_trusted_internal_owner_user_id(request: Any) -> str | None:
    """仅当 AuthMiddleware 已校验内部 token 并盖了内部 user 时，才返回 owner 覆盖值。

    普通浏览器/API 调用者塞的 owner 头被忽略——这是防冒充的关键：owner 头只在
    内部 token 校验通过后才生效。"""
    user = getattr(getattr(request, "state", None), "user", None)
    if getattr(user, "system_role", None) != INTERNAL_SYSTEM_ROLE:
        return None
    owner_user_id = request.headers.get(INTERNAL_OWNER_USER_ID_HEADER_NAME)
    if not owner_user_id:
        return None
    owner_user_id = owner_user_id.strip()
    return owner_user_id or None
```

**③路由 + ④建图：把 user_id 钉进 run context（contextvar 跨任务边界会丢，故显式 stamp）。**

```python
# gateway/gateway/services.py - start_run 内：owner 解析 + run 级 contextvar + context stamp
# 注：start_run 完整实现见脊柱 ③路由段；此处只摘与不变量 2 相关的 owner 解析 + context stamp 行。
owner_user_id = get_trusted_internal_owner_user_id(request)
# per-resource owner 校验：thread 归属检查（防跨用户访问），完整见源文件
owner_context_token = set_current_user(SimpleNamespace(id=owner_user_id)) if owner_user_id else None
try:
    # 其间有 create_or_reject、build_run_config、apply_checkpoint_to_run_config 等步骤，与本不变量无关
    is_internal_caller = getattr(getattr(request, "state", None), "auth_source", None) == AUTH_SOURCE_INTERNAL
    merge_run_context_overrides(config, getattr(body, "context", None), internal=is_internal_caller)
    if not is_internal_caller:
        strip_internal_context_keys(config)
    internal_owner_user = await resolve_trusted_internal_owner_for_attribution(request, owner_user_id)
    inject_authenticated_user_context(config, request, internal_owner_user=internal_owner_user)
    # 其后起 run_agent worker，与本不变量无关
finally:
    if owner_context_token is not None:
        reset_current_user(owner_context_token)

def inject_authenticated_user_context(config: dict[str, Any], request: Request, *,
                                      internal_owner_user: Any | None = None) -> None:
    """把认证 user 钉进 run context，供后台工具使用。

    工具执行可能在请求 handler 返回之后发生，故持久化用户态文件的工具不能只靠
    ambient ContextVar。值来自服务端认证态，绝不来自客户端 context。"""
    user = getattr(request.state, "user", None)
    user_id = getattr(user, "id", None)
    if user_id is None:
        return
    if getattr(user, "system_role", None) == INTERNAL_SYSTEM_ROLE:
        runtime_context = config.setdefault("context", {})
        if not isinstance(runtime_context, dict):
            return
        if internal_owner_user is None:
            # 纯内部调用（无 owner 解析）：清掉 role/oauth，user_id 由 merge 阶段的 body.context 决定
            runtime_context.pop("user_role", None)
            runtime_context.pop("oauth_provider", None)
            runtime_context.pop("oauth_id", None)
            return
        # 内部 + owner：把 owner 的真实身份 stamp 进 context（覆盖 body.context 的 user_id）
        owner_user_id = getattr(internal_owner_user, "id", None)
        if owner_user_id is not None:
            runtime_context["user_id"] = str(owner_user_id)
        runtime_context["user_role"] = getattr(internal_owner_user, "system_role", None)
        runtime_context["oauth_provider"] = getattr(internal_owner_user, "oauth_provider", None)
        runtime_context["oauth_id"] = getattr(internal_owner_user, "oauth_id", None)
        return
    # Web 用户：直接 stamp JWT 解析出的 user_id
    runtime_context = config.setdefault("context", {})
    if isinstance(runtime_context, dict):
        runtime_context["user_id"] = str(user_id)
        runtime_context["user_role"] = getattr(user, "system_role", None)
        runtime_context["oauth_provider"] = getattr(user, "oauth_provider", None)
        runtime_context["oauth_id"] = getattr(user, "oauth_id", None)
```

**user_id 解析的单一事实源（跨 contextvar 边界）。**

```python
# core/helix/runtime/user_context.py - contextvar + 三级回退解析
_current_user: Final[ContextVar[CurrentUser | None]] = ContextVar("helix_current_user", default=None)

DEFAULT_USER_ID: Final[str] = "default"

def set_current_user(user: CurrentUser) -> Token[CurrentUser | None]:
    return _current_user.set(user)

def reset_current_user(token: Token[CurrentUser | None]) -> None:
    _current_user.reset(token)

def get_effective_user_id() -> str:
    """返回当前 user.id 字符串，未设置回退 DEFAULT_USER_ID。永不抛异常——
    文件系统路径解析永远需要一个有效 user 桶。"""
    user = _current_user.get()
    if user is None:
        return DEFAULT_USER_ID
    return str(user.id)

def resolve_runtime_user_id(runtime: object | None) -> str:
    """工具/中间件有效 user_id 的单一事实源。解析顺序（权威性从高到低）：
      1. runtime.context['user_id']——由 gateway 的 inject_authenticated_user_context
         从认证态 request.state.user 钉入。这是唯一能穿越 contextvar 可能丢失的边界
         （请求任务外调度的工作者、不 copy_context 的池、未来跨进程驱动）的来源。
      2. _current_user ContextVar——由认证中间件在请求入口设。对任务内工作可靠；
         asyncio 子任务与 ContextThreadPoolExecutor 会拷贝它。
      3. DEFAULT_USER_ID——最后兜底，让无认证的 CLI/迁移/测试路径不抛错。
    持久化用户态文件的工具（自定义 agent、记忆、uploads）必须调它，而非直接 get_effective_user_id。"""
    context = getattr(runtime, "context", None)
    if isinstance(context, dict):
        ctx_user_id = context.get("user_id")
        if ctx_user_id:
            return str(ctx_user_id)
    return get_effective_user_id()
```

**⑤中间件 + ⑥执行：按 user_id 定位 per-user 目录。**

```python
# core/helix/agents/middlewares/thread_data_middleware.py - 建 per-thread 目录（user_id 隔离）
class ThreadDataMiddleware(AgentMiddleware[ThreadDataMiddlewareState]):
    """为每次 thread 执行创建 thread 数据目录：
      {base_dir}/users/{user_id}/threads/{thread_id}/user-data/{workspace,uploads,outputs}
    （无 user_id 时回退 legacy 布局 {base_dir}/threads/{thread_id}/...）"""
    @override
    def before_agent(self, state: ThreadDataMiddlewareState, runtime: Runtime) -> dict | None:
        context = runtime.context or {}
        thread_id = context.get("thread_id")
        if thread_id is None:
            config = get_config()
            thread_id = config.get("configurable", {}).get("thread_id")
        if thread_id is None:
            raise ValueError("Thread ID is required in runtime context or config.configurable")
        # 读 contextvar 拿 user_id（run_agent 已把 runtime.context['user_id'] 与 contextvar 对齐）
        user_id = get_effective_user_id()
        if self._lazy_init:
            paths = self._get_thread_paths(thread_id, user_id=user_id)
        else:
            paths = self._create_thread_directories(thread_id, user_id=user_id)
        # 其间还把 run_id/timestamp 盖到末条 HumanMessage 的 additional_kwargs，与本不变量无关
        return {"thread_data": {**paths}, "messages": messages}

    def _get_thread_paths(self, thread_id: str, user_id: str | None = None) -> dict[str, str]:
        return {
            "workspace_path": str(self._paths.sandbox_work_dir(thread_id, user_id=user_id)),
            "uploads_path": str(self._paths.sandbox_uploads_dir(thread_id, user_id=user_id)),
            "outputs_path": str(self._paths.sandbox_outputs_dir(thread_id, user_id=user_id)),
        }
```

```python
# core/helix/config/paths.py - per-user 目录布局的权威定义
def make_safe_user_id(raw: str) -> str:
    """把外部身份规范化进 user-id 字符集 [A-Za-z0-9_-]。
    IM 通道 id 含 _validate_user_id 拒绝的字符；已安全的 id 原样通过；
    有损的 id 加短摘要后缀，使两个不同输入永不共享存储桶。"""
    if not raw:
        raise ValueError("user_id must be a non-empty string.")
    sanitized = _UNSAFE_USER_ID_CHAR_RE.sub("-", raw)
    if sanitized == raw:
        return raw
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:_SAFE_USER_ID_DIGEST_HEX_LEN]
    return f"{sanitized}-{digest}"

class Paths:
    def user_dir(self, user_id: str) -> Path:
        """{base_dir}/users/{user_id}/（user_id 经 _validate_user_id 防穿越）"""
        return self.base_dir / "users" / _validate_user_id(user_id)

    def user_memory_file(self, user_id: str) -> Path:
        """per-user 记忆：{base_dir}/users/{user_id}/memory.json"""
        return self.user_dir(user_id) / "memory.json"

    def user_agents_dir(self, user_id: str) -> Path:
        """per-user 自定义 agent 根：{base_dir}/users/{user_id}/agents/"""
        return self.user_dir(user_id) / "agents"

    def user_agent_memory_file(self, user_id: str, agent_name: str) -> Path:
        """per-user per-agent 记忆：{base_dir}/users/{user_id}/agents/{name}/memory.json"""
        return self.user_agent_dir(user_id, agent_name) / "memory.json"

    def user_custom_skills_dir(self, user_id: str) -> Path:
        """per-user 自定义 skill：{base_dir}/users/{user_id}/skills/custom/"""
        return self.user_skills_dir(user_id) / "custom"

    def thread_dir(self, thread_id: str, *, user_id: str | None = None) -> Path:
        """thread 数据宿主路径。user_id 提供时：{base_dir}/users/{user_id}/threads/{thread_id}/；
        否则 legacy：{base_dir}/threads/{thread_id}/。含 user-data/ 子目录，沙箱内挂载到 /mnt/user-data/。"""
        if user_id is not None:
            return self.user_dir(user_id) / "threads" / _validate_thread_id(thread_id)
        return self.base_dir / "threads" / _validate_thread_id(thread_id)

    def sandbox_work_dir(self, thread_id: str, *, user_id: str | None = None) -> Path:
        """宿主：{base_dir}/threads/{thread_id}/user-data/workspace/（user_id 时落到 users/{user_id}/threads/...）；
        沙箱内：/mnt/user-data/workspace/"""
        return self.thread_dir(thread_id, user_id=user_id) / "user-data" / "workspace"
    # sandbox_uploads_dir / sandbox_outputs_dir 同构
```

> 沙箱工具（`bash`/`read_file`/`str_replace`）的虚拟路径映射 `/mnt/user-data/{workspace,uploads,outputs}/*` -> 物理路径，正是落到上述 per-user 目录（详见 `[[sandbox-abstraction]]`、`[[sandbox-tools-and-safety]]`）。模型只看到虚拟路径，物理隔离由 `ThreadDataMiddleware` 建立的 `thread_data` 状态 + `Paths` 解析保证。

### 为什么这样设计

1. **②认证汇合到单一 contextvar，③–⑧ 只读它。** 三条入站路径凭证来源不同，但汇合后下游无感。这让"加一条新入站路径"只需在 ②认证补一种凭证解析，③–⑧ 零改动。反过来，改 ③–⑧ 任一跳只需验证"读到的 user_id 正确"，不必关心来源。
2. **owner 头仅在内部 token 校验通过后生效。** `get_trusted_internal_owner_user_id` 先查 `request.state.user.system_role == "internal"`，浏览器调用者塞的 owner 头直接被忽略。这把"谁能指定 owner"从"任何调用者"收窄到"已通过内部 token 认证的调度/通道调用者"。
3. **`make_safe_user_id` 规范化防穿越 + 防碰撞。** IM 通道 id 可能含 `/`/`..`/`_` 等字符，不规范化会逃逸 per-user 桶或冒充他人。规范化有损但确定：不同输入加 SHA-256 摘要后缀，永不碰撞。
4. **`resolve_runtime_user_id` 三级回退。** contextvar 是 asyncio task-local，跨任务/跨进程边界会丢。`runtime.context["user_id"]` 是 ③路由显式 stamp 的、能穿越边界的来源，作为第一权威；contextvar 第二；`DEFAULT_USER_ID` 兜底。这保证后台工具（可能在请求 handler 返回后执行）也能拿到对的 user_id。
5. **目录布局 `users/{user_id}/threads/{thread_id}/user-data/{...}`。** user_id 在外层、thread_id 在内层，使"列某用户所有 thread""清理某用户全部数据"是单目录操作；user_data 统一子目录名让沙箱挂载点稳定（`/mnt/user-data/`）。

### 违反后果

- **owner 头对浏览器生效**：用户 A 塞 `X-Helix-Owner-User-Id: <B的id>` 头，run 跑到 B 的桶，A 能写 B 的 workspace、读 B 的 uploads —— 跨用户数据泄漏 + 冒充。
- **owner id 不规范化**：IM 通道 id 含 `../` -> 物理路径逃逸 per-user 桶 -> 写到其他用户目录或系统目录；含 `_` 被当路径分隔符 -> 落到错误桶。
- **工具只读 contextvar 不读 runtime.context**：后台工具在请求任务外执行时 contextvar 丢失 -> `get_effective_user_id()` 回退 `"default"` -> 所有后台产物落到 default 桶串用户。
- **per-user 目录布局错位**（thread_id 在外、user_id 在内）：删某用户数据要遍历所有 thread 目录，清理操作 O(线程数) 而非 O(1)。

### 测试锚点

1. **owner 头隔离**：两条 IM 消息带不同 owner 头（均配内部 token），断言 `ThreadDataMiddleware` 建的 `workspace_path` 落到不同 `users/{user_id}/threads/...` 桶；无 owner 头落 `"default"`。
2. **浏览器伪造 owner 无效**：普通浏览器调用者（无内部 token）带 `X-Helix-Owner-User-Id` 头，断言 `get_trusted_internal_owner_user_id` 返回 `None`、run 落到 JWT 用户自己的桶。
3. **owner id 规范化**：构造含 `/`/`..`/`_` 的 owner id，断言 `make_safe_user_id` 输出仅含 `[A-Za-z0-9_-]`，且 `_validate_user_id` 不抛异常；两个不同原始 id 产出的 safe id 不同。
4. **跨边界 user_id**：在请求 handler 返回后执行的后台工具里调 `resolve_runtime_user_id(runtime)`，断言返回 ③路由 stamp 的 `runtime.context["user_id"]` 而非 `"default"`（模拟 contextvar 丢失场景）。
5. **无认证回退**：无认证模式（`is_auth_disabled()`）下 `get_effective_user_id()` 返回 `"default"`，所有数据落 default 桶不抛异常。

---

## 不变量 3：StreamBridge × checkpointer × 回滚（断流续传 + 长任务取消）

### 问题

长任务 SSE 有两个独立但必须协作的正确性问题：
1. **断流续传**：客户端网络抖动、刷新页面、SSE 连接被代理掐断，都可能导致事件丢失。重连后必须从断点续发，不能丢事件、不能重放已确认事件。
2. **长任务取消 + 回滚**：用户对一个跑了很久、改了一堆文件/状态的 run 点"取消"。若只是停 worker，checkpointer 里已经写了半截 messages 和中间状态，用户会看到"半截产物"。需要把线程状态**回滚到 run 开始前**，让用户看不到这次取消 run 的任何痕迹。

两套机制独立（续传管"事件流"、回滚管"checkpoint 状态"），但都依赖 run 生命周期里的同一个锚点。

### 真实代码链路

链路横穿 ③路由（RunManager + worker 快照）-> ⑦流式（StreamBridge publish/subscribe）-> 取消路径（rollback）。

**worker 运行前快照最新 checkpoint（回滚锚点）。**

```python
# core/helix/runtime/runs/worker.py - run_agent 开头：快照 pre-run checkpoint（完整源码见 references/code/07-streaming-and-resume.md）
async def run_agent(bridge, run_manager, record, *, ctx, agent_factory, graph_input, config,
                    stream_modes=None, stream_subgraphs=False, interrupt_before=None, interrupt_after=None) -> None:
    checkpointer = ctx.checkpointer
    run_id, thread_id = record.run_id, record.thread_id
    requested_modes: set[str] = set(stream_modes or ["values"])
    pre_run_checkpoint_id: str | None = None
    pre_run_snapshot: dict[str, Any] | None = None
    snapshot_capture_failed = False
    # 其间还有 pre_existing_message_ids、journal、workspace 快照等初始化，与本不变量无关
    try:
        # mark running、journal 初始化等步骤省略，完整见 references/code/07-streaming-and-resume.md
        # 运行前快照最新 checkpoint，供 rollback 恢复（本不变量回滚锚点）
        if checkpointer is not None:
            try:
                config_for_check = {"configurable": {"thread_id": thread_id, "checkpoint_ns": ""}}
                ckpt_tuple = await checkpointer.aget_tuple(config_for_check)
                if ckpt_tuple is not None:
                    ckpt_config = getattr(ckpt_tuple, "config", {}).get("configurable", {})
                    pre_run_checkpoint_id = ckpt_config.get("checkpoint_id")
                    # 深拷贝 checkpoint/metadata/pending_writes：run 期间 checkpointer 会写新 checkpoint，
                    # 必须冻结一份不可变快照，否则回滚时读到的是被本 run 污染后的状态。
                    pre_run_snapshot = {
                        "checkpoint_ns": ckpt_config.get("checkpoint_ns", ""),
                        "checkpoint": copy.deepcopy(getattr(ckpt_tuple, "checkpoint", {})),
                        "metadata": copy.deepcopy(getattr(ckpt_tuple, "metadata", {})),
                        "pending_writes": copy.deepcopy(getattr(ckpt_tuple, "pending_writes", []) or []),
                    }
            except Exception:
                snapshot_capture_failed = True   # 快照失败：rollback 时降级跳过，不抛错卡住 run
                logger.warning("Could not capture pre-run checkpoint snapshot for run %s", run_id, exc_info=True)
        # 其后建图、装 runtime context、起 astream 流式，完整见 references/code/07-streaming-and-resume.md
```

**⑦流式：stream_mode 映射 + publish 到 bridge（事件 id = `{ts}-{seq}`）。**

```python
# core/helix/runtime/runs/worker.py - stream_mode 映射 + publish
_VALID_LG_MODES = {"values", "updates", "checkpoints", "tasks", "debug", "messages", "custom"}

# 把客户端请求的 SSE 模式映射成 LangGraph astream 模式
lg_modes: list[str] = []
for m in requested_modes:
    if m == "messages-tuple":   # SDK 的 messages-tuple -> LG 的 messages
        lg_modes.append("messages")
    elif m == "events":         # 不是合法 astream 模式（需 astream_events + checkpoint 回调），跳过
        continue
    elif m in _VALID_LG_MODES:
        lg_modes.append(m)
if not lg_modes:
    lg_modes = ["values"]       # 客户端没给合法模式时默认 values

def _lg_mode_to_sse_event(mode: str) -> str:
    """LangGraph stream_mode 名 1:1 映射成 SSE 事件名。messages 保持 messages。"""
    return mode

# 单模式无 subgraphs：astream 产裸 chunk；多模式/subgraphs：产 (mode, chunk) 元组
async for item in agent.astream(input_payload, config=stream_config,
                                stream_mode=lg_modes, subgraphs=stream_subgraphs):
    if record.abort_event.is_set():       # 协作式取消：检测到 abort 立即停
        break
    mode, chunk = _unpack_stream_item(item, lg_modes, stream_subgraphs)
    if mode is None:
        continue
    sse_event = _lg_mode_to_sse_event(mode)
    await bridge.publish(run_id, sse_event, serialize(chunk, mode=mode))   # publish 到 bridge
```

```python
# core/helix/runtime/stream_bridge/memory.py - 内存实现：O(1) 续传定位 + 有界 buffer
class MemoryStreamBridge(StreamBridge):
    """per-run 内存事件日志。事件按有界时间窗保留，迟到的订阅者和重连客户端
    可从 Last-Event-ID 重放 buffer 内事件。"""
    def __init__(self, *, queue_maxsize: int = 256) -> None:
        self._maxsize = queue_maxsize
        self._streams: dict[str, _RunStream] = {}
        self._counters: dict[str, int] = {}

    def _next_id(self, run_id: str) -> str:
        # 事件 id = {ts}-{seq}；seq 是 per-run 单调递增的绝对偏移
        self._counters[run_id] = self._counters.get(run_id, 0) + 1
        ts = int(time.time() * 1000)
        seq = self._counters[run_id] - 1
        return f"{ts}-{seq}"

    @staticmethod
    def _parse_event_seq(event_id: str) -> int | None:
        """从 {ts}-{seq} id 抽 per-run seq。seq 由 _next_id 每事件 +1，
        故等于事件在 run 内的绝对偏移。格式不符返回 None。"""
        _, sep, seq_text = event_id.rpartition("-")
        if not sep:
            return None
        try:
            return int(seq_text)
        except ValueError:
            return None

    def _resolve_start_offset(self, stream: _RunStream, last_event_id: str | None) -> int:
        if last_event_id is None:
            return stream.start_offset
        # 事件 id 内嵌单调 seq == 绝对偏移，故用算术 O(1) 定位而非线性扫描 buffer。
        # 在算出的索引处再校验 id：陈旧/驱逐/伪造/他 run 的 id 仍降级到"从最早保留事件重放"。
        seq = self._parse_event_seq(last_event_id)
        if seq is not None:
            local_index = seq - stream.start_offset
            if 0 <= local_index < len(stream.events) and stream.events[local_index].id == last_event_id:
                return stream.start_offset + local_index + 1   # 命中：从该事件之后续发
        # 过期（已被驱逐出有界 buffer）/伪造/他 run 的 id：从最早保留事件重放
        if stream.events:
            logger.warning("last_event_id=%s not found in retained buffer; replaying from earliest retained event",
                           last_event_id)
        return stream.start_offset

    async def publish(self, run_id: str, event: str, data: Any) -> None:
        stream = self._get_or_create_stream(run_id)
        entry = StreamEvent(id=self._next_id(run_id), event=event, data=data)
        async with stream.condition:
            stream.events.append(entry)
            if len(stream.events) > self._maxsize:   # 有界 buffer：溢出驱逐最旧，start_offset 前移
                overflow = len(stream.events) - self._maxsize
                del stream.events[:overflow]
                stream.start_offset += overflow
            stream.condition.notify_all()

    async def subscribe(self, run_id: str, *, last_event_id: str | None = None,
                        heartbeat_interval: float = 15.0) -> AsyncIterator[StreamEvent]:
        stream = self._get_or_create_stream(run_id)
        async with stream.condition:
            next_offset = self._resolve_start_offset(stream, last_event_id)   # 续传定位
        while True:
            async with stream.condition:
                # 订阅者落后于 buffer 驱逐速度：从最早保留事件恢复（降级，不丢已驱逐的）
                if next_offset < stream.start_offset:
                    logger.warning("subscriber for run %s fell behind retained buffer; resuming from offset %s",
                                   run_id, stream.start_offset)
                    next_offset = stream.start_offset
                local_index = next_offset - stream.start_offset
                if 0 <= local_index < len(stream.events):
                    entry = stream.events[local_index]
                    next_offset += 1
                elif stream.ended:
                    entry = END_SENTINEL
                else:
                    try:
                        await asyncio.wait_for(stream.condition.wait(), timeout=heartbeat_interval)
                    except TimeoutError:
                        entry = HEARTBEAT_SENTINEL   # 心跳：保活，防代理掐空闲连接
                    else:
                        continue
            if entry is END_SENTINEL:
                yield END_SENTINEL
                return
            yield entry
```

**③路由 SSE 端点：用 `Last-Event-ID` 重连。**

```python
# gateway/gateway/services.py - sse_consumer：从 bridge subscribe，带 Last-Event-ID 续传
async def sse_consumer(bridge, record, request, run_mgr):
    last_event_id = request.headers.get("Last-Event-ID")   # 客户端重连时带回最后收到的事件 id
    if await _terminal_record_stream_missing(bridge, record):
        yield format_sse("end", None)
        return
    try:
        async for entry in bridge.subscribe(record.run_id, last_event_id=last_event_id):   # 续传定位
            if await request.is_disconnected():
                break
            if entry is HEARTBEAT_SENTINEL:
                # 心跳分支：检查终态记录是否已流失，完整见源文件
                continue
            # 其余 entry 经 format_sse 格式化为 SSE 帧并 yield，完整见源文件
    finally:
        # on_disconnect 语义：cancel -> 中止后台任务；continue -> 任务继续，事件丢弃。完整见源文件
        pass
```

**取消 + 回滚：`multitask_strategy` 协作 + worker 终结路径恢复快照。**

```python
# core/helix/runtime/runs/manager.py - cancel：设 abort_action，触发 abort_event，cancel 任务
async def cancel(self, run_id: str, *, action: str = "interrupt") -> bool:
    """请求取消一个 run。action="interrupt" 保留 checkpoint，"rollback" 回滚到 pre-run。
    设 abort_event（带 action 原因）并 cancel asyncio 任务。已 interrupted 则幂等返回 True。"""
    async with self._lock:
        record = self._runs.get(run_id)
        if record is None:
            return False
        if record.status == RunStatus.interrupted:
            return True
        if record.status not in (RunStatus.pending, RunStatus.running):
            return False
        record.abort_action = action          # worker 终结时读它决定是否回滚
        record.abort_event.set()              # 协作式取消信号
        task_active = record.task is not None and not record.task.done()
        record.finalizing = task_active
        if task_active:
            record.task.cancel()              # 触发 asyncio.CancelledError
        record.status = RunStatus.interrupted
    await self._persist_status(record, RunStatus.interrupted)
    return True

# create_or_reject 中：multitask_strategy in ("interrupt","rollback") 时，对在途 run 同样设 abort_action
if multitask_strategy in ("interrupt", "rollback") and inflight:
    for r in inflight:
        if r.finalizing:
            continue
        r.abort_action = multitask_strategy   # 新 run 抢占时，旧 run 按 strategy 终结
        r.abort_event.set()
        task_active = r.task is not None and not r.task.done()
        r.finalizing = task_active
        if task_active:
            r.task.cancel()
        r.status = RunStatus.interrupted
```

```python
# core/helix/runtime/runs/worker.py - 终结路径：abort_event 或 CancelledError 触发 rollback
# （run_agent 的状态收尾段；完整源码见 references/code/07-streaming-and-resume.md）

# 正常终结：astream 循环因 abort_event 退出
if record.abort_event.is_set():
    await run_manager.set_finalizing(run_id, True)
    action = record.abort_action
    if action == "rollback":
        await run_manager.set_status(run_id, RunStatus.error, error="Rolled back by user")
        try:
            await _rollback_to_pre_run_checkpoint(
                checkpointer=checkpointer, thread_id=thread_id, run_id=run_id,
                pre_run_checkpoint_id=pre_run_checkpoint_id,
                pre_run_snapshot=pre_run_snapshot,
                snapshot_capture_failed=snapshot_capture_failed)
            logger.info("Run %s rolled back to pre-run checkpoint %s", run_id, pre_run_checkpoint_id)
        except Exception:
            logger.warning("Failed to rollback checkpoint for run %s", run_id, exc_info=True)
    else:
        await run_manager.set_status(run_id, RunStatus.interrupted)   # interrupt：保留 checkpoint

# 异常终结：task.cancel() 触发 asyncio.CancelledError
except asyncio.CancelledError:
    await run_manager.set_finalizing(run_id, True)
    action = record.abort_action
    if action == "rollback":
        await run_manager.set_status(run_id, RunStatus.error, error="Rolled back by user")
        try:
            await _rollback_to_pre_run_checkpoint(
                checkpointer=checkpointer, thread_id=thread_id, run_id=run_id,
                pre_run_checkpoint_id=pre_run_checkpoint_id,
                pre_run_snapshot=pre_run_snapshot,
                snapshot_capture_failed=snapshot_capture_failed)
            logger.info("Run %s was cancelled and rolled back", run_id)
        except Exception:
            logger.warning("Run %s cancellation rollback failed", run_id, exc_info=True)
    else:
        await run_manager.set_status(run_id, RunStatus.interrupted)
        logger.info("Run %s was cancelled", run_id)
```

```python
# core/helix/runtime/runs/worker.py - 回滚实现：在 checkpointer 上写一个新 checkpoint 标记，载入 pre-run 状态
async def _rollback_to_pre_run_checkpoint(*, checkpointer, thread_id, run_id,
                                          pre_run_checkpoint_id, pre_run_snapshot,
                                          snapshot_capture_failed) -> None:
    """把线程状态恢复到 run 开始前快照的 checkpoint。"""
    if checkpointer is None:
        logger.info("Run %s rollback requested but no checkpointer is configured", run_id)
        return
    if snapshot_capture_failed:
        # 快照捕获失败：跳过回滚（不抛错卡住 run），记 warn
        logger.warning("Run %s rollback skipped: pre-run checkpoint snapshot capture failed", run_id)
        return
    if pre_run_snapshot is None:
        # run 前线程为空：直接删整个线程，回到空状态
        await _call_checkpointer_method(checkpointer, "adelete_thread", "delete_thread", thread_id)
        logger.info("Run %s rollback reset thread %s to empty state", run_id, thread_id)
        return

    checkpoint = pre_run_snapshot.get("checkpoint")
    if not isinstance(checkpoint, dict):
        logger.warning("Run %s rollback skipped: invalid pre-run checkpoint snapshot", run_id)
        return
    checkpoint_to_restore = checkpoint
    if checkpoint_to_restore.get("id") is None and pre_run_checkpoint_id is not None:
        checkpoint_to_restore = {**checkpoint_to_restore, "id": pre_run_checkpoint_id}
    if checkpoint_to_restore.get("id") is None:
        logger.warning("Run %s rollback skipped: pre-run checkpoint has no checkpoint id", run_id)
        return
    # 新 id/ts 标记：回滚不是覆盖旧 checkpoint，而是写一个"新的"checkpoint，
    # 其 channel_values = pre-run 快照内容。新 id/ts 保证 DB-backed saver
    # （Postgres/Sqlite blob 按 channel_versions 键存）能正确写入新版本。
    restore_marker = _new_checkpoint_marker()   # empty_checkpoint() 产新 id/ts
    checkpoint_to_restore = {
        **checkpoint_to_restore,
        "id": restore_marker["id"],
        "ts": restore_marker["ts"],
    }
    metadata_to_restore = pre_run_snapshot.get("metadata", {})
    if not isinstance(metadata_to_restore, dict):
        metadata_to_restore = {}
    raw_checkpoint_ns = pre_run_snapshot.get("checkpoint_ns")
    checkpoint_ns = raw_checkpoint_ns if isinstance(raw_checkpoint_ns, str) else ""

    channel_versions = checkpoint_to_restore.get("channel_versions")
    new_versions = dict(channel_versions) if isinstance(channel_versions, dict) else {}

    restore_config = {"configurable": {"thread_id": thread_id, "checkpoint_ns": checkpoint_ns}}
    # aput 写入恢复后的 checkpoint：线程最新 checkpoint 指向 pre-run 状态
    restored_config = await _call_checkpointer_method(
        checkpointer, "aput", "put",
        restore_config, checkpoint_to_restore,
        metadata_to_restore if isinstance(metadata_to_restore, dict) else {},
        new_versions)
    # 其后恢复 pending_writes：按 task_id 分组 aput_writes。完整实现见 references/code/07-streaming-and-resume.md

def _new_checkpoint_marker() -> dict[str, str]:
    marker = empty_checkpoint()
    return {"id": marker["id"], "ts": marker["ts"]}
```

### 为什么这样设计

1. **续传用 `{ts}-{seq}` 而非 UUID。** `seq` 是 per-run 单调递增的绝对偏移，`_resolve_start_offset` 用 `seq - start_offset` 算术 O(1) 定位，无需线性扫描 buffer。`ts` 前缀给人读调试用。校验 `stream.events[local_index].id == last_event_id` 保证陈旧/驱逐/伪造/他 run 的 id 不被误信，降级到"从最早保留事件重放"。
2. **buffer 有界 + start_offset 前移。** 长任务事件无限增长会撑爆内存。`queue_maxsize=256` 驱逐最旧事件、`start_offset` 跟进，使重连客户端要么命中未驱逐段（O(1) 续传），要么从最早保留事件重放（降级、不丢已驱逐之外的）。订阅者落后驱逐速度时也降级恢复。
3. **回滚写"新 checkpoint"而非删旧。** DB-backed saver 按 `channel_versions` 键存 blob，覆盖旧 checkpoint 会版本冲突。写一个新 id/ts 的 checkpoint、载入 pre-run `channel_values`，是 LangGraph checkpointer 协议支持的标准恢复方式——线程最新 checkpoint 自然指向 pre-run 状态，历史 checkpoint 仍在（可审计）。
4. **快照深拷贝 + `snapshot_capture_failed` 降级。** run 期间 checkpointer 持续写新 checkpoint，浅拷贝会让回滚读到被污染的状态。深拷贝冻结快照。若快照捕获本身失败（如 checkpointer 临时不可用），rollback 跳过而非抛错——run 不该因回滚失败而卡死，记 warn 即可。
5. **`abort_action` 是 per-run 状态、worker 终结时读。** `cancel()` 和 `create_or_reject` 都只设 `abort_action` + `abort_event`，不直接做回滚（持锁做 IO 会阻塞 run 注册）。worker 终结路径（正常 abort 退出 / `CancelledError`）才读 `abort_action` 决定回滚或 interrupt。这把"取消决策"与"状态恢复"解耦，且让回滚在 worker 的 finally 语义内执行（保证一定触发）。
6. **续传与回滚独立但协作。** 续传保"客户端看到的事件流不丢"（bridge buffer），回滚保"取消后 checkpointer 状态干净"（pre-run 快照）。两者锚点不同：续传锚点是事件 `seq`，回滚锚点是 `pre_run_checkpoint_id`。一个 run 被回滚后，bridge 的事件流仍可被已连接客户端消费完（publish_end 在 finally），新客户端重连会看到回滚后的空状态（checkpoint 已恢复）。

### 违反后果

- **续传不用 `seq`、改线性扫描**：长任务 buffer 大时重连定位 O(n)，每个重连客户端都全扫，SSE 吞吐塌陷。
- **buffer 无界**：长任务（subagent `max_turns=150` 产数百事件）内存撑爆，OOM。
- **回滚覆盖旧 checkpoint**：DB-backed saver 版本冲突报错，回滚失败 -> 半截 messages 留在 checkpoint -> 用户看到取消 run 的残骸。
- **快照浅拷贝**：回滚读到 run 污染后的状态 -> 回滚无效。
- **`abort_action` 不读、直接 interrupt**：rollback 请求被当 interrupt 处理 -> checkpoint 保留半截状态 -> 取消无效。
- **回滚在 `cancel()` 持锁内做**：IO 阻塞 run 注册锁 -> 同线程后续 `create_or_reject` 全部阻塞 -> 系统僵。

### 测试锚点

1. **续传 O(1) 命中**：起一个 run，发若干事件后断 SSE，用 `Last-Event-ID` 重连，断言续传从该事件之后续发、无丢无重放；`_resolve_start_offset` 返回 `start_offset + local_index + 1`。
2. **buffer 驱逐降级**：发超过 `queue_maxsize` 个事件后重连（`Last-Event-ID` 指向已驱逐事件），断言降级到从最早保留事件重放、记 warn。
3. **rollback 恢复 pre-run**：起一个改了 workspace/写了 messages 的 run，`cancel(action="rollback")`，断言 checkpointer 最新 checkpoint 的 `channel_values.messages` 等于 run 前、无半截产物；`Run %s rolled back to pre-run checkpoint` 日志出现。
4. **interrupt 保留 checkpoint**：`cancel(action="interrupt")`，断言 checkpoint 保留 run 中途状态、run 状态 `interrupted`。
5. **multitask 抢占 rollback**：thread 已有在途 run，新 run 以 `multitask_strategy="rollback"` 创建，断言旧 run 被 `abort_action="rollback"` 终结并回滚、新 run 正常起。
6. **快照失败降级**：mock `checkpointer.aget_tuple` 抛异常，断言 `snapshot_capture_failed=True`、rollback 时跳过并记 warn、run 不卡死。
7. **CancelledError 路径**：`task.cancel()` 触发 `asyncio.CancelledError`，`abort_action="rollback"` 时断言走 rollback 分支。

---

## 三不变量总览表

| 不变量 | 锚点 key/对象 | 横穿跳 | 防伪造机制 | 失败降级 |
|---|---|---|---|---|
| 1 non_interactive 剥离 ask_clarification | `context["non_interactive"]` + `_NON_INTERACTIVE_DISABLED_TOOL_NAMES` | ①②③④ | `_CONTEXT_INTERNAL_CALLER_KEYS` 白名单 + `strip_internal_context_keys` 抹除 + `auth_source=INTERNAL` 门控 | ClarificationMiddleware `disable_clarification` 旁路（webhook 通道） |
| 2 user_id 全链路隔离 | `_current_user` contextvar + `runtime.context["user_id"]` | ②③④⑤⑥ | owner 头仅内部 token 后生效 + `make_safe_user_id` 规范化 + `_validate_user_id` 防穿越 | `resolve_runtime_user_id` 三级回退到 `DEFAULT_USER_ID` |
| 3 StreamBridge×checkpointer×回滚 | 事件 `{ts}-{seq}` + `pre_run_checkpoint_id`/`pre_run_snapshot` | ③⑦+取消 | id 校验防伪造/他 run | buffer 驱逐降级重放；`snapshot_capture_failed` 跳过回滚 |

> 关联 skill：`[[e2e-request-lifecycle]]`（脊柱地图）、`[[scheduled-tasks]]`（不变量 1 入口）、`[[auth]]`+`[[multi-user-isolation]]`（不变量 2）、`[[gateway-runs-and-sse]]`+`[[long-running-and-cancellation]]`（不变量 3）。各跳完整源码见 `references/code/02-auth-gate.md`、`references/code/05-middleware-chain.md`、`references/code/07-streaming-and-resume.md`。
