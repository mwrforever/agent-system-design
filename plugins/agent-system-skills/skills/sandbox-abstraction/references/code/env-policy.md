# env-policy · 环境消毒 + 多实现入口

> 本文件是 `sandbox-abstraction` skill 的代码附件，给出 `env_policy.py`（平台凭证消毒）的**完整真实源码**、多实现（AIO / Boxlite / E2B）入口片段，以及 `SandboxMiddleware` 生命周期接线（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

## 自定路径映射

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/sandbox/env_policy.py` | `build_sandbox_env` + `is_blocked_env_name`：消毒 `os.environ` 的 secret-looking 名 |
| `core/helix/sandbox/middleware.py` | `SandboxMiddleware`：lazy_init acquire + `wrap_tool_call` 把 sandbox_id 写回 state |
| `core/helix/community/aio_sandbox/aio_sandbox_provider.py` | `AioSandboxProvider`（Docker bind-mount，零翻译） |
| `core/helix/community/boxlite/provider.py` | `BoxliteProvider`（micro-VM，loop-affine） |
| `core/helix/community/e2b_sandbox/e2b_sandbox_provider.py` | `E2BSandboxProvider`（远端） |

---

## 1. env_policy.py（平台凭证消毒，完整）

Skill 脚本作为沙箱子进程运行。默认子进程继承 Gateway 进程的整个 `os.environ`，其中含平台凭证（`OPENAI_API_KEY`、tracing 密钥、社区 provider 密钥……）。这使得任何 request-scoped secret 注入毫无意义：脚本可直接读那些继承的平台密钥。本模块在 request-scoped secrets 叠加之前，从继承环境中擦除 secret-looking 变量。

模式集镜像同类产品的 `*KEY*/*SECRET*/*TOKEN*` 默认排除与固定 provider 黑名单；本平台**默认擦除**——安全优先。

```python
# core/helix/sandbox/env_policy.py
"""Environment-variable policy for sandbox command execution (issue #3861).

Skill scripts run as sandbox subprocesses. By default a subprocess inherits the
Gateway process entire os.environ — which holds platform credentials
(OPENAI_API_KEY, tracing keys, community-provider keys, ...). That makes any
scoped request-secret injection pointless: a script could simply read those
inherited platform secrets. This module scrubs secret-looking variables from the
inherited environment before request-scoped secrets are layered on top.

The pattern set mirrors the industry *KEY*/*SECRET*/*TOKEN* default excludes
and the fixed provider blocklist; unlike some tools (which default the exclude
*off*), the platform scrubs by default — security first.
"""

from __future__ import annotations

import fnmatch
import os

# secret-looking 变量名的大小写不敏感通配模式。对大写的变量名匹配。良性
# 系统变量（PATH、HOME、SHELL、LANG、PWD、TMPDIR、VIRTUAL_ENV、
# PYTHONPATH……）不含这些 token，故被保留。
_SECRET_NAME_PATTERNS: tuple[str, ...] = (
    "*KEY*",
    "*SECRET*",
    "*TOKEN*",
    "*PASSWORD*",
    "*PASSWD*",
    "*CREDENTIAL*",
    "*DSN*",  # data source name — 几乎总是带密码的连接串
)

# 连接串 / 带凭证变量名：不含 KEY/SECRET/TOKEN/DSN 子串但通常内嵌密码
# （例如 postgresql://user:pw@host/db）。刻意不用 *URL* 通配——它会擦
# 掉 skill 可能合法读取的良性 service URL。确实需要其中之一的 skill 必须
# 通过 required-secrets 声明（调用方随后通过 context.secrets 供给，且注入
# 获胜）。
_BLOCKED_EXACT_NAMES: frozenset[str] = frozenset(
    {
        "DATABASE_URL",
        "DATABASE_URI",
        "REDIS_URL",
        "MONGODB_URI",
        "MONGO_URL",
        "AMQP_URL",
        "RABBITMQ_URL",
        "POSTGRES_URL",
        "POSTGRESQL_URL",
        "MYSQL_URL",
        "CLICKHOUSE_URL",
        "CONNECTION_STRING",
        "CONN_STR",
        "GH_PAT",
        "GITHUB_PAT",
    }
)


def is_blocked_env_name(name: str) -> bool:
    """Return True if ``name`` looks like a credential that must not be inherited
    by a sandbox subprocess."""
    upper = name.upper()
    if upper in _BLOCKED_EXACT_NAMES:
        return True
    return any(fnmatch.fnmatchcase(upper, pattern) for pattern in _SECRET_NAME_PATTERNS)


def build_sandbox_env(injected: dict[str, str] | None = None) -> dict[str, str]:
    """Build the environment dict for a sandbox subprocess.

    Inherits os.environ minus any secret-looking variables, then layers the
    explicitly injected request-scoped secrets on top. An injected secret wins
    even if its name matches a blocked pattern, because injection is authorized
    upstream (the skill declared it and the value came from the request, not from
    the host environment).
    """
    env = {key: value for key, value in os.environ.items() if not is_blocked_env_name(key)}
    if injected:
        env.update(injected)
    return env
```

### 为何默认擦除而非默认放行

| 设计选择 | 理由 |
|---|---|
| 默认擦除 `*KEY*/*SECRET*/*TOKEN*/*PASSWORD*/*CREDENTIAL*/*DSN*` | 平台凭证（`OPENAI_API_KEY` 等）若泄漏进 skill 子进程，request-scoped secret 注入就形同虚设——脚本可直接读宿主密钥 |
| 连接串黑名单（`DATABASE_URL` / `REDIS_URL` / `GH_PAT` 等） | 这些名不含 KEY/SECRET token 但常内嵌密码；`*URL*` 通配太宽（会误伤良性 service URL），故用精确名单 |
| 注入的 secret 即使名匹配 blocked pattern 也获胜 | 注入是上游授权的（skill 声明 + 值来自 request 而非宿主环境），所以调用方值覆盖宿主值 |
| 保留 `PATH/HOME/SHELL/LANG/PWD/TMPDIR/VIRTUAL_ENV/PYTHONPATH` | 不含 secret token，脚本正常运行需要它们 |

---

## 2. 多实现入口（同一契约，不同隔离边界）

`config.sandbox.use` 经 `resolve_class` 解析到具体 Provider 类。三种实现共享 `Sandbox` / `SandboxProvider` 契约，隔离边界递增：宿主文件系统 → Docker 容器 → micro-VM。

### LocalSandboxProvider（宿主文件系统，路径翻译）

`uses_thread_data_mounts = True` —— provider 自建 per-thread 目录并把虚拟路径翻译到宿主路径。**不是安全沙箱边界**（host bash 可访问整个宿主文件系统），故默认禁用 host bash（`sandbox.allow_host_bash` 控制）。见上方 §4 完整实现。

### AioSandboxProvider（Docker bind-mount，零翻译）

容器化 provider 把 thread 目录 bind-mount 进容器**同名虚拟路径**，故 AIO 沙箱原生接受 `/mnt/user-data/...`——零翻译。`WarmPoolLifecycleMixin` 提供共享 warm-pool 生命周期（idle reaper、oldest-warm 驱逐、replica 计数）。

```python
# core/helix/community/aio_sandbox/aio_sandbox_provider.py
class AioSandboxProvider(WarmPoolLifecycleMixin[SandboxInfo], SandboxProvider):
    """Sandbox provider that manages containers running the AIO sandbox.

    Architecture:
        This provider composes a SandboxBackend (how to provision), enabling:
        - Local Docker/Apple Container mode (auto-start containers)
        - Remote/K8s mode (connect to pre-existing sandbox URL)

    Configuration options in config.yaml under sandbox:
        use: helix.community.aio_sandbox:AioSandboxProvider
        image: <container image>
        port: 8080                      # Base port for local containers
        container_prefix: helix-sandbox
        idle_timeout: 600               # Idle timeout in seconds (0 to disable)
        replicas: 3                     # Max concurrent sandbox containers (LRU eviction when exceeded)
        mounts:                         # Volume mounts for local containers
          - host_path: /path/on/host
            container_path: /path/in/container
            read_only: false
        environment:                    # Environment variables for containers
          NODE_ENV: production
          API_KEY: $MY_API_KEY
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._sandboxes: dict[str, AioSandbox] = {}  # sandbox_id -> AioSandbox instance
        self._sandbox_infos: dict[str, SandboxInfo] = {}  # sandbox_id -> SandboxInfo (for destroy)
        self._thread_sandboxes: dict[tuple[str, str], str] = {}  # (user_id, thread_id) -> sandbox_id
        self._thread_locks: dict[tuple[str, str], threading.Lock] = {}  # per-thread in-process lock
        self._last_activity: dict[str, float] = {}  # sandbox_id -> last activity timestamp
        # warm pool：已 release 但容器仍运行的沙箱。sandbox_id ->
        # (SandboxInfo, release_timestamp)。容器可快速回收（无冷启动）或在
        # replicas 容量耗尽时销毁。
        self._warm_pool: dict[str, tuple[SandboxInfo, float]] = {}
        self._shutdown_called = False
        self._idle_checker_stop = threading.Event()
        self._idle_checker_thread: threading.Thread | None = None

        self._config = self._load_config()
        self._backend: SandboxBackend = self._create_backend()

        atexit.register(self.shutdown)
        self._register_signal_handlers()
        self._reconcile_orphans()       # 回收上一进程遗留的孤儿容器
        if self._config.get("idle_timeout", DEFAULT_IDLE_TIMEOUT) > 0:
            self._start_idle_checker()

    @property
    def uses_thread_data_mounts(self) -> bool:
        """Whether thread workspace/uploads/outputs are visible via mounts.

        Local container backends bind-mount the thread data directories, so files
        written by the gateway are already visible when the sandbox starts.
        Remote backends may require explicit file sync.
        """
        return isinstance(self._backend, LocalContainerBackend)
```

**acquire 复用 vs 新建决策树**（容器化 provider 通用）：

```text
acquire(thread_id=t, user_id=u)
  ├─ 进程内 active 缓存 hit?
  │     ├─ 是 → backend health check(container_id)
  │     │       ├─ alive    → 复用
  │     │       ├─ dead     → 从缓存剔除，落到 "未命中" 分支
  │     │       └─ unknown  → 视为 alive（保守），避免抖动误杀
  │     └─ 否 → 下一步
  ├─ warm pool 有空闲实例?
  │     ├─ 是 → rebind 后返回
  │     └─ 否 → 真正创建
  └─ 写回 active 缓存，返回新 id
```

### BoxliteProvider（micro-VM，loop-affine）

BoxLite handles 是 loop-affine（绑定到创建它的事件循环），故 provider 在 daemon 线程上持有一个私有 asyncio 事件循环；同步 `Sandbox` 调用经 `run_coroutine_threadsafe` marshal 到该循环。Box 按 `user_id:thread_id` 确定性命名，每次 agent turn 后释放进 warm pool，只被同一 user/thread 回收。

```python
# core/helix/community/boxlite/provider.py
class BoxliteProvider(WarmPoolLifecycleMixin[BoxliteBox], SandboxProvider):
    """Run each sandbox as a BoxLite micro-VM."""

    uses_thread_data_mounts = False
    needs_upload_permission_adjustment = True
    _idle_checker_thread_name = "boxlite-idle-reaper"

    @staticmethod
    def _sandbox_id(thread_id: str, user_id: str) -> str:
        """Deterministic sandbox ID from user/thread scope.

        含 user_id，使一个用户的 box 不能被同 thread_id 的另一用户 thread
        回收。
        """
        return hashlib.sha256(f"{user_id}:{thread_id}".encode()).hexdigest()[:8]

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._boxes: dict[str, BoxliteBox] = {}
        self._thread_boxes: dict[tuple[str, str], str] = {}
        self._warm_pool: dict[str, tuple[BoxliteBox, float]] = {}
        self._acquire_locks: dict[str, threading.Lock] = {}
        self._idle_checker_stop = threading.Event()
        self._idle_checker_thread: threading.Thread | None = None
        self._shutdown_called = False
        self._config = self._load_config()
        self._loop = _EventLoopThread()   # 私有事件循环（BoxLite handles loop-affine）
        atexit.register(self.shutdown)
        self._reconcile_orphans()
        self._start_idle_checker()
```

### E2BSandboxProvider（远端，SDK 转发）

```python
# core/helix/community/e2b_sandbox/e2b_sandbox_provider.py
class E2BSandboxProvider(SandboxProvider):
    """远端 E2B 沙箱 provider。env 经 SDK 的 envs 字段转发（无 shell 拼接）。"""
    # 完整实现见源文件；生命周期同契约：acquire 返回远端 sandbox_id，
    # get 返回 E2BSandbox 实例，release 销毁远端沙箱。
```

### 共享 warm-pool 生命周期

社区沙箱 provider（AIO / Boxlite）共享 `WarmPoolLifecycleMixin`：提供 `DEFAULT_IDLE_TIMEOUT=600`、`IDLE_CHECK_INTERVAL=60`、`DEFAULT_REPLICAS=3`、idle-checker 循环、warm-pool 过期、oldest-warm 驱逐、replica 计数、软上限日志。Provider 各自负责 active 注册表、创建/发现、健康检查与销毁钩子（`_destroy_warm_entry`）：AIO 经其 backend 销毁 `SandboxInfo`；Boxlite 关闭 loop-affine 的 `BoxliteBox` handle。

---

## 3. SandboxMiddleware（生命周期接线，链序第 5 项）

`SandboxMiddleware` 是中间件链第 5 项（共享基座），把沙箱生命周期钉进 graph 调度层。`lazy_init=True`（默认）时不在 `before_agent` 急切 acquire，而是延迟到首次 tool call——`wrap_tool_call` diff 前后 state 的 `sandbox_id`，首次 lazy 获取时用 `Command(update=...)` 把 `sandbox_id` 持久化进 graph state（`runtime.state["sandbox"]` 的直接 mutation 不会被 LangGraph reducer 写进 checkpointer）。

```python
# core/helix/sandbox/middleware.py
class SandboxMiddleware(AgentMiddleware[SandboxMiddlewareState]):
    """Create a sandbox environment and assign it to an agent.

    Lifecycle Management:
    - With lazy_init=True (default): Sandbox is acquired on first tool call
    - With lazy_init=False: Sandbox is acquired on first agent invocation (before_agent)
    - Sandbox is reused across multiple turns within the same thread
    - Sandbox is NOT released after each agent call to avoid wasteful recreation
    - Cleanup happens at application shutdown via SandboxProvider.shutdown()
    """

    state_schema = SandboxMiddlewareState

    def __init__(self, lazy_init: bool = True):
        """Initialize sandbox middleware.

        Args:
            lazy_init: If True, defer sandbox acquisition until first tool call.
                      If False, acquire sandbox eagerly in before_agent().
                      Default is True for optimal performance.
        """
        super().__init__()
        self._lazy_init = lazy_init

    def _acquire_sandbox(self, thread_id: str, *, user_id: str) -> str:
        provider = get_sandbox_provider()
        sandbox_id = provider.acquire(thread_id, user_id=user_id)
        logger.info(f"Acquiring sandbox {sandbox_id}")
        return sandbox_id

    async def _acquire_sandbox_async(self, thread_id: str, *, user_id: str) -> str:
        provider = get_sandbox_provider()
        # 异步路径：acquire_async 默认 to_thread(acquire)，使 Docker/provisioner
        # 的阻塞操作跑在 worker 线程而非事件循环。
        sandbox_id = await provider.acquire_async(thread_id, user_id=user_id)
        logger.info(f"Acquiring sandbox {sandbox_id}")
        return sandbox_id

    async def _release_sandbox_async(self, sandbox_id: str) -> None:
        await asyncio.to_thread(get_sandbox_provider().release, sandbox_id)
```

### wrap_tool_call：lazy_init 结果写回 state

`ensure_sandbox_initialized`（tools.py）在 lazy 路径直接写 `runtime.state["sandbox"]`，但该 mutation 是 tool-invocation-local 的，不被 LangGraph channel reducer 拾取——后续 graph step 与下游消费者（`ToolOutputBudgetMiddleware`、子代理 `task_tool`）看不到 sandbox_id。`wrap_tool_call` 通过 diff 前后 state 检测首次 lazy 获取，并用 `Command(update=...)` 发出正式 state 更新。

```python
    @staticmethod
    def _read_sandbox_id_from_state(state: object) -> str | None:
        if not isinstance(state, dict):
            return None
        sandbox_state = state.get("sandbox")
        if not isinstance(sandbox_state, dict):
            return None
        sandbox_id = sandbox_state.get("sandbox_id")
        return sandbox_id if isinstance(sandbox_id, str) else None

    @staticmethod
    def _attach_sandbox_update(result: ToolMessage | Command, sandbox_id: str) -> ToolMessage | Command:
        """Wrap or merge result so that sandbox.sandbox_id is persisted.

        - ToolMessage -> Command(update={"sandbox": ..., "messages": [msg]})
        - Command with dict update -> merge "sandbox" key, 保留既有字段
          （messages、goto、graph、resume……）。
        - Command with non-dict / None update -> 不动，避免未知 update 形状
          的静默数据丢失。
        """
        sandbox_update = {"sandbox": {"sandbox_id": sandbox_id}}

        if isinstance(result, ToolMessage):
            return Command(update={**sandbox_update, "messages": [result]})

        existing_update = result.update
        if isinstance(existing_update, dict):
            merged_update = {**existing_update, **sandbox_update}
            return dc_replace(result, update=merged_update)
        return result

    @override
    async def awrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], Awaitable[ToolMessage | Command]],
    ) -> ToolMessage | Command:
        prev_sandbox_id = self._read_sandbox_id_from_request(request)
        result = await handler(request)
        if prev_sandbox_id is not None:
            return result
        curr_sandbox_id = self._read_sandbox_id_from_request(request)
        if curr_sandbox_id is None:
            return result
        return self._attach_sandbox_update(result, curr_sandbox_id)
```

### ensure_sandbox_initialized（工具侧 lazy 入口）

工具（bash / read_file / write_file）调本函数获取沙箱实例。首次调用从 provider acquire 并写 `runtime.state["sandbox"]`；后续调用直接返回缓存实例。

```python
# core/helix/sandbox/tools.py
async def ensure_sandbox_initialized_async(runtime: Runtime | None = None) -> Sandbox:
    """ensure_sandbox_initialized 的异步对应，保持 lazy 沙箱获取在异步
    provider 钩子上，使 AIO 沙箱启动与就绪轮询不在异步工具执行中回退到
    同步 provider.acquire()。"""
    if runtime is None or runtime.state is None:
        raise SandboxRuntimeError("Tool runtime not available")

    sandbox_state = runtime.state.get("sandbox")
    if sandbox_state is not None:
        sandbox_id = sandbox_state.get("sandbox_id")
        if sandbox_id is not None:
            sandbox = get_sandbox_provider().get(sandbox_id)
            if sandbox is not None:
                if runtime.context is not None:
                    runtime.context["sandbox_id"] = sandbox_id
                return sandbox

    thread_id = runtime.context.get("thread_id") if runtime.context else None
    if thread_id is None:
        thread_id = runtime.config.get("configurable", {}).get("thread_id") if runtime.config else None
    if thread_id is None:
        raise SandboxRuntimeError("Thread ID not available in runtime context")

    provider = get_sandbox_provider()
    sandbox_id = await provider.acquire_async(thread_id, user_id=resolve_runtime_user_id(runtime))

    runtime.state["sandbox"] = {"sandbox_id": sandbox_id}

    sandbox = provider.get(sandbox_id)
    if sandbox is None:
        raise SandboxNotFoundError("Sandbox not found after acquisition", sandbox_id=sandbox_id)

    if runtime.context is not None:
        runtime.context["sandbox_id"] = sandbox_id
    return sandbox
```

### 运行期时序（lazy_init，一次 tool call 触发）

```text
LLM → AIMessage(tool_calls=[bash(...)])
ToolNode → handler(request)
  └─ ensure_sandbox_initialized(runtime)
       ├─ 读 runtime.state["sandbox"] → 已有 sandbox_id 则 provider.get(...) 直接返回
       ├─ 否则从 runtime.context / runtime.config.configurable 拿 thread_id
       ├─ provider.acquire_async(thread_id, user_id=...)
       │     └─ acquire_async 默认 to_thread(acquire) → 不阻塞事件循环
       │        ├─ LocalSandboxProvider：LRU 命中或新建 local:{uid}:{tid}
       │        └─ AioSandboxProvider：active/warm 命中或新建容器（health check）
       ├─ runtime.state["sandbox"] = {"sandbox_id": ...}  # 本 tool 内可见
       └─ provider.get(sandbox_id) → Sandbox 实例
SandboxMiddleware.awrap_tool_call
  ├─ handler 前后分别读 state 的 sandbox_id
  └─ 前 None 后 Some → Command(update={"sandbox": {"sandbox_id": ...}, "messages": [...]})
       把 lazy 分配结果写回 graph state，让后续步骤可见
```
