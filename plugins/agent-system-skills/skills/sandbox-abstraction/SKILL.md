---
name: sandbox-abstraction
description: 设计 agent 的沙箱抽象层——虚拟路径契约（/mnt/user-data/* 到物理隔离）、Sandbox / SandboxProvider 抽象（acquire/get/release 生命周期 + 异步 acquire）、per-thread LRU 实例缓存、env_policy（消毒平台凭证防泄漏进 skill 子进程）、多实现可插拔（local / Docker AIO / Boxlite micro-VM）。讲抽象与生命周期，不重复 bash/read/write/str_replace 工具与并发锁（归 sandbox-tools-and-safety）。当你想设计沙箱隔离边界、加新 provider 实现、排查虚拟路径映射/跨用户隔离/凭证泄漏、或定位沙箱在端到端链路⑥执行的位置时调用本 skill。
---

## 何时用

- 要让 agent 执行 shell 命令、读写文件，且需要隔离边界（local / Docker / micro-VM 可切换）
- 要加一个新的沙箱 provider 实现（如远端 K8s、新 micro-VM 后端），需要遵循什么契约
- 排查"模型看到的路径"与"文件实际落在哪里"不一致（虚拟路径映射问题）
- 排查跨用户 / 跨线程文件串桶（隔离失效）
- 排查平台凭证（`OPENAI_API_KEY` 等）是否泄漏进 skill 子进程（env_policy）
- 想理解沙箱在端到端链路中的位置（⑥执行），或它与沙箱工具/并发锁的边界

> 本 skill 讲沙箱**抽象与生命周期**（Sandbox 接口、Provider 模式、LRU、env_policy、虚拟路径契约、多实现入口）。具体的 bash / read_file / write_file / str_replace 工具实现、并发文件锁、read-before-write 门在 `[[sandbox-tools-and-safety]]` 讲——本 skill 引用不重复。

## 设计方案（为什么这么设计）

### 核心矛盾：模型看统一路径，底层拓扑各异

agent 的工具（bash / read_file / write_file）必须能在不同执行后端上跑：开发期跑本地宿主文件系统（低延迟、零部署），生产期跑 Docker 容器或 micro-VM（隔离边界）。但模型生成的脚本/命令里会硬编码路径——如果模型看到的是宿主真实路径（`/home/user/.agent-framework/users/u_42/threads/t_xx/user-data/workspace/app.py`），一旦换到 Docker 后端，该路径在容器内根本不存在，脚本立刻 broken。

**解法：虚拟路径契约。** 模型永远只看到一套稳定的虚拟路径，底层是本地目录还是容器 volume 不暴露：

| 模型看到的虚拟路径 | 物理落点（per-thread） |
|---|---|
| `/mnt/user-data/workspace/` | `users/{user_id}/threads/{thread_id}/user-data/workspace/` |
| `/mnt/user-data/uploads/` | `users/{user_id}/threads/{thread_id}/user-data/uploads/` |
| `/mnt/user-data/outputs/` | `users/{user_id}/threads/{thread_id}/user-data/outputs/` |
| `/mnt/acp-workspace/` | `users/{user_id}/threads/{thread_id}/acp-workspace/` |
| `/mnt/skills/{public,custom,legacy}/` | 公共 / per-user custom / legacy skills 目录 |

`VIRTUAL_PATH_PREFIX = "/mnt/user-data"` 是这条契约的常量锚点。各实现各自把虚拟路径映射到物理：

- **LocalSandbox**：持 `PathMapping(container_path, local_path, read_only)` 列表，命令/内容进入时正向翻译（虚拟→物理），输出返回时反向翻译（物理→虚拟）。模型永远不接触宿主真实路径。
- **AioSandbox（Docker）**：把 thread 目录 bind-mount 进容器**同名虚拟路径**，故容器内 `/mnt/user-data/...` 原生存在——零翻译。仍保留翻译层做 defense-in-depth。
- **Boxlite（micro-VM）**：同理通过 mount 把虚拟路径暴露进 micro-VM。

### Provider 抽象：生命周期与执行正交

`Sandbox`（管执行/IO：`execute_command` / `read_file` / `write_file` / `list_dir` / `glob` / `grep` / `download_file` / `update_file`）与 `SandboxProvider`（管生命周期：`acquire` / `acquire_async` / `get` / `release` / `reset`）正交分离。为何分开：

1. **创建昂贵，执行廉价。** Docker 容器启动、K8s pod 调度、micro-VM boot 都是秒级阻塞操作；而 `execute_command` 只是往已就绪的环境发一条命令。生命周期必须能跨 turn 复用（同 thread 后续 turn 命中同一实例），而非每次工具调用都新建/销毁。
2. **`acquire` 幂等。** 同一 `(user_id, thread_id)` 多次调用返回同一 `sandbox_id`——首个调用创建，后续命中缓存。这让 `ensure_sandbox_initialized` 可以无副作用地在每个工具调用开头跑。
3. **`acquire_async` 默认 `to_thread(acquire)`。** 大多数 provider 暴露同步生命周期 API（Docker/provisioner 操作是阻塞的）。异步运行时（agent 的事件循环）必须把阻塞操作甩到 worker 线程，否则会饿死所有并发 HTTP handler（鉴权、SSE 心跳）。
4. **`release` 对本地是 no-op。** 跨 turn 复用比反复创建划算；资源在 LRU 淘汰或进程退出时回收。容器化 provider 决定是否真销毁（通常放进 warm pool 等下次复用）。
5. **`get` 返回 `Sandbox | None`，绝不抛。** 找不到（容器被外部杀死、provider reset 过）返回 `None`，上层按 `None` 处理为"已被释放"，**绝不暗地重新 acquire**——否则一个被杀的容器会以新身份悄悄回来，状态不对齐。

### per-thread LRU：为何按 thread 隔离 + 为何有上限

**为何按 `(user_id, thread_id)` 隔离**：文件系统隔离的基本单位是 thread——不同 thread 的 workspace/uploads/outputs 必须互不可见，否则跨 thread 文件串桶。`acquire(thread_id, user_id=...)` 产出的 `LocalSandbox` 实例的 `path_mappings` 只把虚拟路径映射到**该 thread** 的宿主目录。

**为何 LRU + 上限（默认 256）**：长跑 gateway 进程中 `thread_id` 数量无界（每个对话一个 thread）。若不加上限，缓存实例无限增长直到撑爆内存。LRU 策略使频繁触碰的 thread 存活；被淘汰的 thread 下次 `acquire` 重建沙箱，代价仅是丢失 `_agent_written_paths`（`read_file` 回退到无反向解析，与全新 run 同行为——优雅降级，不出错）。

**并发安全**：`OrderedDict[(user_id, thread_id), LocalSandbox]` + 一把 `threading.Lock`。锁内做 fast-path 命中检查；锁外做文件系统 IO（`ensure_thread_dirs` 建目录）；回锁内 re-check 后插入——避免并发 acquire 同一 thread 时重复建目录/重复构造实例。

### env_policy：为何消毒平台凭证

skill 脚本作为沙箱子进程运行，默认继承 Gateway 进程的整个 `os.environ`——其中含平台凭证（`OPENAI_API_KEY`、tracing 密钥、社区 provider 密钥）。若不擦除，任何 request-scoped secret 注入都形同虚设：脚本可直接读继承的平台密钥，把平台凭证写进自己的输出或外发。

**解法：`build_sandbox_env(injected)` 默认擦除。** 从 `os.environ` 里擦掉 secret-looking 名（`*KEY*` / `*SECRET*` / `*TOKEN*` / `*PASSWORD*` / `*PASSWD*` / `*CREDENTIAL*` / `*DSN*` + 连接串黑名单 `DATABASE_URL` / `REDIS_URL` / `GH_PAT` 等），再叠加注入的 request-scoped secrets。注入值即使名匹配 blocked pattern 也获胜（注入是上游授权的——skill 声明 + 值来自 request 而非宿主环境）。良性变量（`PATH` / `HOME` / `LANG` / `VIRTUAL_ENV` 等）不含 secret token，保留。**默认擦除，安全优先**——而非默认放行。

### 多实现可插拔：同一契约，递增隔离边界

`config.sandbox.use` 经 `resolve_class` 解析到具体 Provider 类。三种实现共享 `Sandbox` / `SandboxProvider` 契约，隔离边界递增：

| 实现 | 隔离边界 | 虚拟路径映射 | warm pool |
|---|---|---|---|
| `LocalSandboxProvider` | 宿主文件系统（**非安全边界**，host bash 默认禁用） | `PathMapping` 路径翻译 | per-thread LRU（256） |
| `AioSandboxProvider` | Docker 容器 | bind-mount 同名虚拟路径（零翻译） | 共享 `WarmPoolLifecycleMixin` |
| `BoxliteProvider` | micro-VM | mount 进 micro-VM | 共享 `WarmPoolLifecycleMixin`，loop-affine |

两个能力旗标让中间件按 provider 类型分流：`uses_thread_data_mounts`（provider 是否自建 per-thread 目录）与 `needs_upload_permission_adjustment`（上传后是否需 chown）。

### 与 `[[sandbox-tools-and-safety]]` 的边界

| 本 skill（抽象 + 生命周期） | `[[sandbox-tools-and-safety]]`（工具 + 安全） |
|---|---|
| `Sandbox` / `SandboxProvider` 抽象接口 | `bash` / `read_file` / `write_file` / `str_replace` / `ls` 工具实现 |
| 虚拟路径契约（`/mnt/user-data/*`） | `replace_virtual_path` / `replace_virtual_paths_in_command` 正向翻译 |
| per-thread LRU + path_mappings | `mask_local_paths_in_output` 反向遮蔽宿主路径 |
| `env_policy.build_sandbox_env` | bash 工具读注入集合并传 `execute_command(env=...)` |
| Provider 单例 + `acquire_async` | `file_operation_lock` 并发文件锁（`(sandbox.id, path)` 串行化） |
| acquire/get/release/reset/shutdown 生命周期 | read-before-write 门（content hash 校验） |

### 在端到端链路中的位置：⑥执行

本 skill 处于 `[[e2e-request-lifecycle]]` 的 **⑥执行** 跳。`SandboxMiddleware`（中间件链第 5 项，共享基座）在首次 tool call 时 lazy acquire 沙箱并把 `sandbox_id` 存进 state；工具（bash / read_file / write_file）调 `ensure_sandbox_initialized` 拿沙箱实例，经虚拟路径在隔离环境里执行。

```text
⑤中间件第 5项 SandboxMiddleware（lazy_init=True）
  └─ wrap_tool_call：首次 tool call 时 ensure_sandbox_initialized
       └─ provider.acquire_async(thread_id, user_id=...) → sandbox_id
       └─ Command(update={"sandbox": {"sandbox_id": ...}}) 写回 state
⑥执行 lead agent loop
  └─ bash_tool / read_file / write_file → ensure_sandbox_initialized(runtime)
       └─ provider.get(sandbox_id) → Sandbox 实例
       └─ sandbox.execute_command(...)（env_policy 消毒 + 虚拟路径翻译）
```

## 完整真实代码实现

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。大文件（完整 `LocalSandboxProvider`、`LocalSandbox` 路径翻译核心、`env_policy.py` 全文、`SandboxMiddleware` 接线）拆到 `references/code/`，本节给文件清单 + 入口片段 + 索引。

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/sandbox/sandbox.py` | `Sandbox` 抽象基类（8 方法 + `id`）+ `_validate_extra_env` env-var 名校验 |
| `core/helix/sandbox/sandbox_provider.py` | `SandboxProvider` 抽象 + 进程级单例（双检锁 + plugin code 跑锁外） |
| `core/helix/sandbox/env_policy.py` | `build_sandbox_env` + `is_blocked_env_name`：消毒 `os.environ` 的 secret-looking 名 |
| `core/helix/sandbox/local/local_sandbox.py` | `PathMapping` + `LocalSandbox`：路径翻译核心 + execute_command + read/write_file |
| `core/helix/sandbox/local/local_sandbox_provider.py` | `LocalSandboxProvider`：静态 + per-thread mappings + LRU + acquire/get/release |
| `core/helix/sandbox/middleware.py` | `SandboxMiddleware`：lazy_init acquire + `wrap_tool_call` 把 sandbox_id 写回 state |
| `core/helix/sandbox/tools.py` | `ensure_sandbox_initialized` / `ensure_sandbox_initialized_async` + `is_local_sandbox` |
| `core/helix/sandbox/security.py` | `uses_local_sandbox_provider`：config 字符串匹配判定 provider 类型 |
| `core/helix/community/aio_sandbox/` | `AioSandboxProvider`（Docker bind-mount，零翻译） |
| `core/helix/community/boxlite/` | `BoxliteProvider`（micro-VM，loop-affine） |

### 1. Sandbox 抽象接口（入口片段）

`Sandbox` 是所有沙箱实现的统一接口。工具层只依赖这 8 个方法 + `id` 属性，不感知底层拓扑。`execute_command` 的 `env` 参数是 request-scoped secret 注入通道（键必须过 `_validate_extra_env` POSIX 名校验）。

```python
# core/helix/sandbox/sandbox.py
class Sandbox(ABC):
    """Abstract base class for sandbox environments"""

    _id: str

    def __init__(self, id: str):
        self._id = id

    @property
    def id(self) -> str:
        return self._id

    @abstractmethod
    def execute_command(self, command: str, env: dict[str, str] | None = None,
                        timeout: float | None = None) -> str: ...

    @abstractmethod
    def read_file(self, path: str) -> str: ...

    @abstractmethod
    def write_file(self, path: str, content: str, append: bool = False) -> None: ...

    @abstractmethod
    def list_dir(self, path: str, max_depth=2) -> list[str]: ...

    @abstractmethod
    def glob(self, path: str, pattern: str, *, include_dirs: bool = False,
             max_results: int = 200) -> tuple[list[str], bool]: ...

    @abstractmethod
    def grep(self, path: str, pattern: str, *, glob: str | None = None,
             literal: bool = False, case_sensitive: bool = False,
             max_results: int = 100) -> tuple[list[GrepMatch], bool]: ...

    @abstractmethod
    def download_file(self, path: str) -> bytes: ...

    @abstractmethod
    def update_file(self, path: str, content: bytes) -> None: ...
```

> 完整 `Sandbox` ABC（含全部 docstring + `env`/`timeout` 语义 + 异常契约）与 `_validate_extra_env` 见 [references/code/sandbox-interface.md](./references/code/sandbox-interface.md)。

### 2. SandboxProvider 抽象 + 单例（入口片段）

`SandboxProvider` 管生命周期，与 `Sandbox` 正交。`acquire` 幂等返回 `sandbox_id`；`acquire_async` 默认 `to_thread` 避免阻塞事件循环；`get` 返回 `Sandbox | None`（绝不抛）；`release` 对本地是 no-op。

```python
# core/helix/sandbox/sandbox_provider.py
class SandboxProvider(ABC):
    """Abstract base class for sandbox providers"""

    uses_thread_data_mounts: bool = False
    needs_upload_permission_adjustment: bool = True

    @abstractmethod
    def acquire(self, thread_id: str | None = None, *, user_id: str | None = None) -> str: ...

    async def acquire_async(self, thread_id: str | None = None, *, user_id: str | None = None) -> str:
        # 阻塞 acquire 甩到 worker 线程，不拖住事件循环
        return await asyncio.to_thread(self.acquire, thread_id, user_id=user_id)

    @abstractmethod
    def get(self, sandbox_id: str) -> Sandbox | None: ...

    @abstractmethod
    def release(self, sandbox_id: str) -> None: ...

    def reset(self) -> None: ...
```

进程级单例 `get_sandbox_provider()` 用双检锁：fast-path 锁内读 → miss 时锁外 resolve + 构造（plugin code 跑锁外防死锁）→ 锁内 CAS 安装。输掉竞争的实例若有 `shutdown()` 立即拆除，防孤儿线程/容器泄漏。

> 完整单例（`get_sandbox_provider` / `reset_sandbox_provider` / `shutdown_sandbox_provider` / `set_sandbox_provider` + `_provider_lock` 注释）见 [references/code/provider-and-lru.md](./references/code/provider-and-lru.md) §1。

### 3. LocalSandboxProvider：per-thread LRU + path_mappings（入口片段）

```python
# core/helix/sandbox/local/local_sandbox_provider.py
_USER_DATA_VIRTUAL_PREFIX = "/mnt/user-data"
_ACP_WORKSPACE_VIRTUAL_PREFIX = "/mnt/acp-workspace"
DEFAULT_MAX_CACHED_THREAD_SANDBOXES = 256

class LocalSandboxProvider(SandboxProvider):
    uses_thread_data_mounts = True
    needs_upload_permission_adjustment = False

    def __init__(self, max_cached_threads: int = DEFAULT_MAX_CACHED_THREAD_SANDBOXES):
        self._path_mappings = self._setup_path_mappings()       # 静态：public skills + 自定义 mounts
        self._generic_sandbox: LocalSandbox | None = None       # 遗留 singleton（id "local"）
        self._thread_sandboxes: OrderedDict[tuple[str, str], LocalSandbox] = OrderedDict()
        self._max_cached_threads = max_cached_threads
        self._lock = threading.Lock()

    def acquire(self, thread_id: str | None = None, *, user_id: str | None = None) -> str:
        if thread_id is None:
            # 无 thread 上下文：返回 generic singleton（id "local"）
            ...
        effective_user_id = self._effective_acquire_user_id(user_id)
        key = self._thread_key(thread_id, effective_user_id)
        with self._lock:                                        # fast-path 命中
            cached = self._thread_sandboxes.get(key)
            if cached is not None:
                self._thread_sandboxes.move_to_end(key)         # LRU 提升
                return cached.id
        # 锁外建 per-thread mappings（碰文件系统：ensure_thread_dirs）
        new_mappings = list(self._path_mappings) + self._build_thread_path_mappings(thread_id, user_id=effective_user_id)
        with self._lock:                                        # re-check + insert
            ...
            return cached.id                                    # "local:{user_id}:{thread_id}"

    def release(self, sandbox_id: str) -> None:
        pass   # no-op：跨 turn 复用；LRU 淘汰或 reset 时才清
```

`_build_thread_path_mappings` 把虚拟路径映射到该 thread 的宿主目录：

```python
    @staticmethod
    def _build_thread_path_mappings(thread_id: str, *, user_id: str | None = None) -> list[PathMapping]:
        paths = get_paths()
        effective_user_id = LocalSandboxProvider._effective_acquire_user_id(user_id)
        paths.ensure_thread_dirs(thread_id, user_id=effective_user_id)
        return [
            PathMapping("/mnt/user-data", str(paths.sandbox_user_data_dir(...)), read_only=False),
            PathMapping("/mnt/user-data/workspace", str(paths.sandbox_work_dir(...)), read_only=False),
            PathMapping("/mnt/user-data/uploads", str(paths.sandbox_uploads_dir(...)), read_only=False),
            PathMapping("/mnt/user-data/outputs", str(paths.sandbox_outputs_dir(...)), read_only=False),
            PathMapping("/mnt/acp-workspace", str(paths.acp_workspace_dir(...)), read_only=False),
            # + per-user custom skills（只读）+ legacy skills（条件只读）
        ]
```

> 完整 `LocalSandboxProvider`（静态/动态 mappings、LRU 驱逐、acquire/get/release/reset/shutdown）+ `PathMapping` + `LocalSandbox` 路径翻译核心（cached_property 正向/反向解析 + execute_command + read/write_file）见 [references/code/provider-and-lru.md](./references/code/provider-and-lru.md) §2-§4。

### 4. env_policy（入口片段）

```python
# core/helix/sandbox/env_policy.py
_SECRET_NAME_PATTERNS = ("*KEY*", "*SECRET*", "*TOKEN*", "*PASSWORD*", "*PASSWD*", "*CREDENTIAL*", "*DSN*")
_BLOCKED_EXACT_NAMES = frozenset({"DATABASE_URL", "REDIS_URL", "MONGODB_URI", "GH_PAT", "GITHUB_PAT", ...})

def build_sandbox_env(injected: dict[str, str] | None = None) -> dict[str, str]:
    # 继承 os.environ 减去 secret-looking 名，再叠加注入的 request-scoped secrets
    env = {k: v for k, v in os.environ.items() if not is_blocked_env_name(k)}
    if injected:
        env.update(injected)    # 注入值获胜，即使名匹配 blocked pattern
    return env
```

> 完整 `env_policy.py` + 多实现入口片段（AioSandboxProvider / BoxliteProvider / E2BSandboxProvider）+ `SandboxMiddleware` 生命周期接线见 [references/code/env-policy.md](./references/code/env-policy.md)。

## 反模式与陷阱

- ❌ **把宿主机绝对路径直接传给模型** → 模型把它写进生成的脚本 → 部署到 Docker 立刻 broken（容器内该路径不存在）。修复：模型只看 `/mnt/user-data/*` 虚拟路径；实现内部翻译。
- ❌ **`acquire()` 同步阻塞跑在事件循环上** → ASGI event loop 卡住（Docker/provisioner 操作是秒级阻塞）。修复：异步路径用 `provider.acquire_async()`（默认 `to_thread`），不要直接 `await acquire()`。
- ❌ **`acquire_async` 直接 `await self.acquire(...)`** → 把阻塞带回事件循环。修复：除非 provider 自己写了真异步 acquire，否则 `acquire_async` 必须委托 `to_thread(acquire)`。
- ❌ **把 plugin code（`__init__`/`reset`/`shutdown`/`resolve_class`）跑在 `_provider_lock` 里** → 任意 plugin 的 `__init__` 都能死锁整个 Gateway 进程（非可重入锁 + plugin 可能重入生命周期函数）。修复：锁只管引用替换，plugin 回调一律锁外执行。
- ❌ **CAS 失败的 provider 实例不 shutdown** → 容器化 provider 通常在 `__init__` 启 idle checker / health daemon，输掉安装竞争忘记 shutdown 会留孤儿线程/容器，长期积累资源耗尽（#3721）。修复：构造后发现已有人安装，立刻 `shutdown()` 自己刚 new 的实例。
- ❌ **共享单例 LocalSandbox** → 早期"全进程一个 LocalSandbox"破坏 `/mnt/user-data` 的 per-thread 语义——所有 thread 读写同一宿主目录，跨 thread 文件串桶。修复：per-thread 实例化（`local:{user_id}:{thread_id}`）。
- ❌ **VirtualPath 解析忘记长前缀优先** → `/mnt/user-data` 和 `/mnt/user-data/workspace` 共存时，按字典序匹配会让 workspace 永远走不到精细映射。修复：按 `container_path` 长度倒序匹配。
- ❌ **`acquire(None)` 与 `acquire(thread_id)` 混用** → 前者复用 generic singleton（无 `/mnt/user-data` 映射），后者 per-thread。中间件以为拿到了 per-thread sandbox 实际是 generic，会写入完全错误的目录。修复：中间件始终带 `thread_id`。
- ❌ **不擦除 `os.environ` 的平台凭证** → skill 子进程继承 `OPENAI_API_KEY` 等，request-scoped secret 注入形同虚设。修复：`execute_command` 始终经 `build_sandbox_env(env)` 构造环境，默认擦除 secret-looking 名。
- ❌ **`provider.get()` 返回 None 时暗地重新 acquire** → 一个被外部杀死的容器以新身份悄悄回来，状态不对齐。修复：`get` 返回 None 时上层抛 `SandboxNotFoundError`，绝不重新 acquire。
- ❌ **LRU 无上限** → 长跑进程 thread_id 无界增长，缓存撑爆内存。修复：默认 256 上限，LRU 淘汰最久未用。
- ❌ **provider 假定 `user_id` 永远在 ContextVar** → Timer 线程 / 后台 worker 拿不到 contextvar。修复：`acquire` 显式接受 `user_id=` 参数；ContextVar 仅作 fallback（同 `[[memory-system-design]]` 的同款坑）。

## 落地参考（调参旋钮 / 调试日志串 / 自测方向）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `sandbox.use` | `config.yaml` | Provider 类引用（`helix.sandbox.local:LocalSandboxProvider` / `helix.community.aio_sandbox:AioSandboxProvider` / `helix.community.boxlite:BoxliteProvider`） |
| `sandbox.mounts[]` | `config.yaml` | 自定义 mount（受保留前缀冲突检查：`/mnt/user-data`、`/mnt/skills/*`、`/mnt/acp-workspace` 不可覆盖） |
| `sandbox.allow_host_bash` | `config.yaml` | 本地 provider 上是否允许 host-bash（默认 false——非安全边界） |
| `sandbox.bash_command_timeout` | `config.yaml` | 单条 bash 命令墙钟超时（默认 600s） |
| `sandbox.idle_timeout` | `config.yaml` | 容器化 provider 的 warm-pool 空闲超时（默认 600s；0 禁用） |
| `sandbox.replicas` | `config.yaml` | 容器化 provider 的最大并发沙箱数（LRU 驱逐超限） |
| `max_cached_threads` | `LocalSandboxProvider(__init__)` | 本地 provider 的 per-thread LRU 上限（默认 256） |
| `SandboxMiddleware(lazy_init=...)` | 中间件构造 | `True`（默认）= 首次 tool call 触发 acquire；`False` = before_agent 急切 acquire |

**关键日志串**

- `Acquiring sandbox <id>` / `Releasing sandbox <id>` — 中间件生命周期（容器化 provider 上 acquire/release 不配对 = 资源泄漏）
- `Assigned sandbox <id> to thread <thread_id>` — 急切初始化路径（lazy_init=False）
- `Evicting LocalSandbox cache entry for user/thread <uid>/<tid> (cap=256)` — 本地 LRU 命中容量上限
- `sandbox.mounts entry ... ignored: host_path ... does not exist` — Docker 模式下 mount 的 host_path 未 bind-mount 进容器
- `Mount container_path conflicts with reserved prefix, skipping` — 自定义 mount 与保留虚拟前缀冲突
- `Could not setup per-thread custom/legacy skills mount` — per-user skills 挂载失败（不致命，降级为无该 mount）

**调试入口**

| 现象 | 看哪里 |
|---|---|
| 模型生成的脚本在 Docker 里 broken | 虚拟路径映射：脚本是否用了宿主真实路径而非 `/mnt/user-data/*` |
| 工具执行行为怪 / 文件落错目录 | `acquire` 是否拿到对的 `thread_id` + `user_id`；`_build_thread_path_mappings` 的物理路径解析 |
| 跨 thread 文件串桶 | sandbox_id 是否含对的 `(user_id, thread_id)`；是否误用了 generic singleton（`acquire(None)`） |
| 平台凭证泄漏进 skill | `build_sandbox_env` 是否生效；`execute_command` 是否始终经它构造 env |
| 容器化 provider acquire 慢 / 卡 | `acquire_async` 是否走了 `to_thread`；warm pool health check 是否把 unknown 误判为 dead |
| LRU 频繁淘汰活跃 thread | `get()` 是否在工具调用时做了 `move_to_end`（提升活跃 thread） |
| mount 配置改了不生效 | 是否只 `reset` 未重建 provider（`_setup_path_mappings` 仅构造期算一次） |

**自测方向**

- **per-thread 隔离**：`acquire(thread_id=t1, user_id=u1)` 与 `acquire(thread_id=t1, user_id=u2)` 返回不同 sandbox_id；两者的 `_build_thread_path_mappings` 解析到不同宿主目录。
- **LRU 幂等 + 驱逐**：同 `(u, t)` 两次 acquire 返回同一 id；超 `max_cached_threads` 后最久未用条目被淘汰（日志确认）；淘汰后重新 acquire 重建实例（`_agent_written_paths` 丢失但 read_file 不报错）。
- **虚拟路径契约**：write_file 写 `/mnt/user-data/workspace/app.py`，文件实际落到 `users/{uid}/threads/{tid}/user-data/workspace/app.py`；read_file 读回时内容里的宿主路径被反向解析回 `/mnt/user-data/...`。
- **env_policy 消毒**：`build_sandbox_env({"MY_TOKEN": "v"})` 的结果不含 `OPENAI_API_KEY` 等继承的 secret-looking 名；注入的 `MY_TOKEN` 在结果里；注入值覆盖同名宿主变量。
- **provider 单例竞争**：两线程并发 `get_sandbox_provider()`，只构造一个实例；输掉竞争的实例被 `shutdown()`。
- **get 不重 acquire**：`provider.get("killed-id")` 返回 None（不抛、不重新 acquire）；上层抛 `SandboxNotFoundError`。
- **保留前缀冲突**：`sandbox.mounts` 里配 `/mnt/user-data/custom`，被拒绝并告警（不覆盖保留前缀）。
- **acquire_async 非阻塞**：容器化 provider 的 `acquire_async` 不阻塞事件循环（mock 慢 acquire，断言并发 HTTP handler 不饿死）。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 代码附件：
  - [references/code/sandbox-interface.md](./references/code/sandbox-interface.md)：`Sandbox` ABC 完整 + `_validate_extra_env`
  - [references/code/provider-and-lru.md](./references/code/provider-and-lru.md)：`SandboxProvider` + 单例 + `LocalSandboxProvider` 完整 + `PathMapping` + `LocalSandbox` 路径翻译核心
  - [references/code/env-policy.md](./references/code/env-policy.md)：`env_policy.py` 完整 + 多实现入口（AIO / Boxlite / E2B）+ `SandboxMiddleware` 接线
- 关联 skill：
  - `[[e2e-request-lifecycle]]`：本 skill 处于⑥执行跳；SandboxMiddleware 是中间件链第 5 项
  - `[[sandbox-tools-and-safety]]`：bash / read_file / write_file / str_replace 工具实现 + 并发文件锁 + read-before-write 门（本 skill 讲抽象与生命周期，不重复工具细节）
  - `[[multi-user-isolation]]`：`(user_id, thread_id)` 物理目录隔离（本 skill 的 path_mappings 依赖该隔离方案）
  - `[[middleware-chain-design]]`：SandboxMiddleware 在 29 项链中的位置（共享基座第 5 项，lazy_init）
  - `[[tool-assembly-and-policy]]`：工具装配（沙箱工具从 config 加载 + 白名单过滤）
  - `[[memory-system-design]]`：同款 ContextVar 跨线程坑（Timer 线程拿不到 user_id）
  - `[[core-app-boundary]]`：`core/helix/`（框架层，含沙箱抽象）不得 import 应用层
