# sandbox-abstraction · implementation-notes

Sandbox 抽象层把 **"工具能在哪里跑文件/命令"** 解耦成可替换的 Provider 实现：本地 Host 直接走宿主文件系统（不安全但低延迟），容器化 Provider 走隔离的执行环境（Docker / 远端 provisioner）。本文聚焦抽象边界、Provider 单例、VirtualPath 体系、Provider 与中间件的协作时序，以及把它落地时最容易踩的坑。

## 一、组件矩阵

| 组件 | 角色 | 关键关注点 |
|---|---|---|
| `Sandbox` (ABC) | 抽象的执行/IO 接口 | 必须暴露 `execute_command / read_file / write_file / list_dir / glob / grep / download_file / update_file`；返回类型固定，方便上层统一处理 |
| `SandboxProvider` (ABC) | 生命周期管理（acquire / get / release / reset） | `acquire_async` 默认走 `asyncio.to_thread(acquire, ...)`；`uses_thread_data_mounts` / `needs_upload_permission_adjustment` 是能力旗标 |
| `get_sandbox_provider()` 单例 | 进程级 Provider 缓存 | 双检锁 + plugin code 必须跑在锁外，否则任意 plugin 的 `__init__` 都能死锁 |
| `LocalSandbox` 实例 | 直接操作宿主 FS 的 `Sandbox` 实现 | 通过 `PathMapping` 列表把 VirtualPath 翻译成宿主路径；保留 `_agent_written_paths` 用于 read 反向重写 |
| `LocalSandboxProvider` | LRU 缓存 + 每线程实例 | `(user_id, thread_id)` 为键；`OrderedDict` + `threading.Lock` 实现 LRU 驱逐 |
| `PathMapping` (frozen dataclass) | 单条 VirtualPath ↔ 宿主路径映射 | 字段：`container_path / local_path / read_only`；只读 mount 由它判定 |
| 容器化 Provider | 隔离执行（Docker / 远端） | `acquire` 是阻塞 IO，必须只在 `acquire_async` 里 `to_thread`；要懂得识别"已被外部杀死的实例" |
| `file_operation_lock` 模块 | 同 sandbox 同 path 的写串行化 | `WeakValueDictionary` + guard lock，按 `(sandbox.id, path)` 取锁 |
| `SandboxMiddleware` | 在 graph 调度层钉死 sandbox 生命周期 | `lazy_init=True` 时由首次 tool call 触发；`wrap_tool_call` 用 `Command(update=...)` 把懒分配结果写回 state |
| `security.uses_local_sandbox_provider` | Provider 类型判定 | 用 `use:` 字段的多个 marker 字符串匹配，而不是 `isinstance` |
| `is_local_sandbox(runtime)` | 工具运行期判断 | 同时接受 `sandbox_id == "local"` 和 `sandbox_id.startswith("local:")` |

## 二、关键调用时序

### 启动期：Provider 单例装配

```text
首次 get_sandbox_provider()
  ├─ 在 _provider_lock 内做 fast-path 读，命中即返回
  └─ miss：
       ├─ 锁外：resolve_class(config.sandbox.use, SandboxProvider) → 反射加载
       ├─ 锁外：cls(**kwargs)  # 可能启动后台线程（idle checker / health check 等）
       └─ 锁内：CAS 安装；输掉竞争的实例如果有 shutdown() 则要立刻 shutdown，避免线程泄漏
```

### 运行期：tool call 第一次触发 sandbox（lazy_init）

```text
LLM → AIMessage(tool_calls=[bash(...)])
ToolNode → handler(request)
  └─ ensure_sandbox_initialized(runtime)            # 同步入口
       ├─ 读 runtime.state["sandbox"] → 已有 sandbox_id 则 provider.get(...) 直接返回
       ├─ 否则从 runtime.context / runtime.config.configurable 拿 thread_id
       ├─ provider.acquire(thread_id, user_id=...) → 返回 "local:{uid}:{tid}" 或容器 id
       ├─ runtime.state["sandbox"] = {"sandbox_id": ...}  # 本次 tool 内可见，但 graph 不会自动持久化
       └─ provider.get(sandbox_id) → Sandbox 实例
SandboxMiddleware.wrap_tool_call
  ├─ 调 handler 前后分别读 state 的 sandbox_id
  └─ 若前 None 后 Some → Command(update={"sandbox": {"sandbox_id": ...}, "messages": [...]})
       把懒分配结果写回 graph state，让后续步骤可见
```

### `_acp_agent_async` / async tool 路径

```text
_run_sync_tool_after_async_sandbox_init(func, runtime, *args)
  ├─ await ensure_sandbox_initialized_async(runtime)  # provider.acquire_async → to_thread
  └─ await asyncio.to_thread(func, runtime, *args)    # 把同步 tool body 也甩到 worker
```

### 退出期：release / reset / shutdown

```text
SandboxMiddleware.after_agent / aafter_agent
  └─ provider.release(sandbox_id)   # 容器化 Provider 真正销毁；本地 Provider no-op，保留 LRU
应用关闭
  └─ shutdown_sandbox_provider() → 锁外调 provider.shutdown()
```

### 配置切换（reset 触发）

```text
operator 修改 config.sandbox.mounts
  → reset_sandbox_provider()        # 锁内置 None；锁外调旧 provider.reset()
  → 下次 get_sandbox_provider() 重新 resolve_class + 构造一个新 Provider
  → 新 Provider 调 _setup_path_mappings() 看到新 mounts
注意：reset 不杀容器（容器化 Provider 上是孤儿）；要彻底清要走 shutdown_sandbox_provider()
```

### `acquire` 在容器化 Provider 上的"复用 vs 新建"决策树

```text
acquire(thread_id=t, user_id=u)
  ├─ 进程内 active 缓存 hit?
  │     ├─ 是 → backend health check(container_id)
  │     │       ├─ alive    → 复用
  │     │       ├─ dead     → 从缓存剔除，落到 "未命中" 分支
  │     │       └─ unknown  → 视为 alive（保守），避免抖动误杀
  │     └─ 否 → 下一步
  ├─ warm pool 有空闲实例?
  │     ├─ 是 → 改名 / rebind 后返回
  │     └─ 否 → 真正创建
  └─ 写回 active 缓存，返回新 id
```

## 三、数据契约

### `Sandbox` 接口
- `execute_command(command: str) -> str`：合并 stdout/stderr，附加 `Exit Code: N`（非 0）；不抛 `CalledProcessError`
- `read_file(path) -> str`：UTF-8；二进制 / 非文本必须抛 `UnicodeDecodeError`；找不到必须抛 `FileNotFoundError`
- `download_file(path) -> bytes`：必须做路径白名单校验，违例抛 `PermissionError`，文件过大抛 `OSError(EFBIG)`
- `write_file(path, content, append=False)`：自动建目录；只读 mount 抛 `OSError(EROFS)`
- `glob / grep`：返回 `(matches, truncated_bool)`；matches 已反向解析回 VirtualPath
- `update_file(path, content: bytes)`：二进制写入版本，同样受只读 mount 控制

### `SandboxProvider` 接口
- `acquire(thread_id=None, *, user_id=None) -> str`：返回 sandbox_id；同 `(user_id, thread_id)` 调用必须返回同一 id（容器化场景里要复用同一容器实例）
- `acquire_async(...)`：默认走 `to_thread(acquire, ...)`；容器化 Provider 可以自己重写为真正异步
- `get(sandbox_id) -> Sandbox | None`：找不到返回 None，**不要抛**；外层会按 None 处理为"已被释放"
- `release(sandbox_id)`：本地 Provider 一般是 no-op；容器化 Provider 真正销毁
- `reset()`：清进程内缓存但不杀容器（用于配置切换/测试）
- `shutdown()`（可选）：真正释放外部资源

### `PathMapping`
```python
@dataclass(frozen=True)
class PathMapping:
    container_path: str   # 例如 /mnt/user-data/workspace
    local_path: str       # 解析到的宿主路径
    read_only: bool = False
```

### sandbox_id 编码
- 通用本地单例：`"local"`
- 每线程本地实例：`"local:{user_id}:{thread_id}"`
- 容器化：由 Provider 自行定义，但必须自描述（建议带前缀），便于 `is_local_sandbox` 之类的判定函数扩展

### Provider 能力旗标
| 旗标 | 默认 | 语义 |
|---|---|---|
| `uses_thread_data_mounts: bool` | False | True 表示 `/mnt/user-data/{...}` 走 per-thread 物理挂载（本地 Provider 自建目录；容器化 Provider 通过 bind mount 生效） |
| `needs_upload_permission_adjustment: bool` | True | 上传中间件是否需要为新写入的文件调整权限位（容器化 Provider 通常需要 chown，本地 Provider 一般不需要） |

### Runtime 上的 sandbox 状态
```python
state["sandbox"] = {"sandbox_id": "<id>"}
runtime.context["sandbox_id"] = "<id>"   # 中间件 after_agent 用的镜像
```
两份必须一致；`ensure_sandbox_initialized` 在 lazy 路径同时写两份。

## 四、不变量

1. **Provider 单例锁分离**：`_provider_lock` 只保护引用替换；任何 plugin 回调（`__init__` / `reset` / `shutdown` / `resolve_class`）必须在锁外执行，否则插件代码可以单 import 死锁整个进程。
2. **CAS 安装时丢失者必须 shutdown**：构造完一个 Provider 后发现已有别人安装，要立刻 `shutdown()` 自己刚 new 出来的实例，否则容器化 Provider 的后台线程/容器会泄漏。
3. **LRU 驱逐线程安全**：本地 Provider 的 `OrderedDict` 读写都在锁内；锁外做 `ensure_thread_dirs` 这类 IO，再回锁内 re-check（处理并发 acquire 同 thread）。
4. **`acquire_async` 必须是非阻塞**：默认实现是 `to_thread(acquire)`；如果一个新 Provider 写了真正异步的 acquire，要小心 **不要** 把 `acquire_async` 委托回 `acquire`，否则又把阻塞带回事件循环。
5. **sandbox 在多轮里复用**：`SandboxMiddleware.after_agent` 调 `release`，但本地 Provider 的 release 是 no-op；容器化 Provider 决定是否真销毁。LRU 缓存让"同一 thread 后续轮次仍能命中同一实例"成为默认行为。
6. **lazy_init 结果必须写回 state**：仅靠 `runtime.state["sandbox"] = {...}` 不会被 LangGraph reducer 写入 checkpointer；`wrap_tool_call` 必须把首次 lazy 获取的 `sandbox_id` 用 `Command(update=...)` 持久化。
7. **`is_local_sandbox` 双形态**：判断时必须 `id == "local" or id.startswith("local:")`，否则在某些路径下漏判会让 host-bash 校验等绕开。
8. **`get` 返回 None 不是 acquire 重试触发器**：上层 `sandbox_from_runtime` 看到 `get(...) is None` 该抛 `SandboxNotFoundError`，绝不暗地重新 acquire（会让一个被外部杀死的容器以新身份悄悄回来，状态不对齐）。
9. **`PathMapping.read_only` 是写禁用的唯一来源**：上层不要再叠一层"按 container_path 字符串判定"的只读策略，否则规则两条都得维护。
10. **保留 VirtualPath 前缀不可被自定义 mount 覆盖**：`/mnt/user-data`、`/mnt/skills`、`/mnt/acp-workspace` 必须在 `_setup_path_mappings` 中校验冲突；冲突的 mount 直接拒绝并 warn，而不是覆盖。
11. **Provider 旗标 `uses_thread_data_mounts` / `needs_upload_permission_adjustment` 是装配开关**：例如 `LocalSandboxProvider.uses_thread_data_mounts = True` 暗示中间件不需要额外建目录，但仍需创建 user-data 目录；容器化 Provider 通常反过来。读取这些旗标的中间件必须沿着同一份事实判断分支。

## 五、常见踩坑

- **把 plugin code 跑在 `_provider_lock` 里**：任何 plugin 的 `__init__` 都能死锁整个 Gateway 进程。锁只能管引用替换。
- **`acquire_async` 直接 `await self.acquire(...)`**：`acquire` 是阻塞的，会拖住事件循环。除非 Provider 自己写了真异步，否则一定要 `to_thread`。
- **共享单例 LocalSandbox**：早期实现"全进程一个 LocalSandbox" 直接破坏 `/mnt/user-data` 的 per-thread 语义。要么实例化 per-thread，要么干脆不提供 user-data 抽象。
- **LRU 驱逐时丢失 `_agent_written_paths`**：被驱逐的线程下次 read_file 会失去反向重写能力，但不会出错；只是宿主真实路径泄露到模型上下文。
- **CAS 失败实例不 shutdown**：容器化 Provider 通常在 `__init__` 启 idle checker / health daemon，输掉竞争忘记 shutdown 会留孤儿线程，长期积累出资源耗尽。
- **`provider.get()` 用了缓存却没和后端 backend 校验**：容器被外部杀掉时，缓存里仍指向死容器；正确做法是 acquire/reuse 时调用一次 backend health check，dead 才丢弃，unknown 不丢（避免把临时网络抖动当成死亡）。
- **VirtualPath 解析忘记长前缀优先**：`/mnt/user-data` 和 `/mnt/user-data/workspace` 共存时，按字典序匹配会让 workspace 永远走不到精细映射；必须按 `container_path` 长度倒序。
- **`read_only` 判定漏看嵌套 mount**：嵌套挂载时按最长 `local_path` 前缀选最具体的 mapping，否则父级被标 RO 会覆盖子级的可写性。
- **TOCTOU**：`download_file` 用 `getsize` 检查大小后再读，文件期间可能增长——容器内是可接受的，宿主裸 mount 不行（攻击者可竞态）。
- **`acquire(None)` 与 `acquire(thread_id)` 混用**：前者复用 generic singleton，没有 `/mnt/user-data` 映射；如果中间件以为自己拿到了 per-thread sandbox 实际是 generic，会写入完全错误的目录。
- **`reset()` 后不重建 path mapping**：`reset` 清空 `_thread_sandboxes` 与 `_generic_sandbox`，但 `_path_mappings`（构造期一次性算出的）通常保留——修改 `sandbox.mounts` 后只 reset 不重建 Provider，新挂载不会生效。要么重建 Provider，要么让 `reset` 主动重跑 `_setup_path_mappings`。
- **acquire 的 `user_id=None` 兜底**：本地 Provider 会调 `get_effective_user_id()` 回退到 `"default"`；测试里忘了设 user_context 会把所有线程数据集中到一个目录，看起来"一切正常"，实际多用户隔离已经失效。

## 六、调参旋钮 + 调试入口

### 配置旋钮
- `sandbox.use`：Provider 类引用，决定整体行为
- `sandbox.allow_host_bash`：本地 Provider 上是否允许 host-bash 工具装配
- `sandbox.mounts[]`：自定义 mount，受保留前缀冲突检查
- `sandbox.bash_output_max_chars / ls_output_max_chars / read_file_output_max_chars`：工具输出截断阈值
- 本地 Provider 构造参数 `max_cached_threads`（默认 256）：LRU 容量
- 容器化 Provider 自定义参数（image / cpu_quota / mem_quota / idle_ttl / warm_pool_size 等）

### 运行期参数
- `SandboxMiddleware(lazy_init=...)`：决定在 `before_agent` 还是 `wrap_tool_call` 内触发 acquire
- `runtime.context["thread_id"]` / `runtime.config["configurable"]["thread_id"]`：lazy 路径必须能从其中之一拿到
- `runtime.context["user_id"]`：影响 per-thread 路径解析

### 调试入口
1. `Acquiring sandbox <id>` / `Releasing sandbox <id>` 日志：核对生命周期是否对称（容器化 Provider 上 acquire/release 不配对就是资源泄漏）
2. `Evicting LocalSandbox cache entry for user/thread ...` 日志：本地 LRU 命中容量上限的迹象
3. `provider.get(sandbox_id)` 返回 None 但 `state.sandbox.sandbox_id` 非空 → 容器被外部杀掉/Provider reset 过
4. 在测试里强制 `set_sandbox_provider(fake_provider)`：跳过反射加载链路，专测中间件 + 工具
5. 在 `acquire`/`release` 处加 `traceback.extract_stack()` 摘要日志：可以快速定位"谁触发了 acquire"
6. 用 `provider.reset()` 而不是重启进程来强制 reload mount 配置；本地 Provider 的 reset 会清空 `_thread_sandboxes`
7. 写一条 smoke：`acquire(thread_id=t1, user_id=u1)` 与 `acquire(thread_id=t1, user_id=u2)` 必须返回不同 id（不同用户隔离）
8. 在 `_setup_path_mappings` 处加 debug：mount host_path 不存在时输出"在 docker 模式下要 bind-mount 进容器"提示，避免静默忽略
9. 容器化 Provider 上加 acquire/reuse 路径与 backend health-check 结果配对日志，区分 dead vs unknown

### 相关 skill
- [[sandbox-tools-and-safety]]
- [[multi-user-isolation]]
- [[middleware-chain-design]]
- [[tool-assembly-and-policy]]
- [[thread-state-and-reducers]]
