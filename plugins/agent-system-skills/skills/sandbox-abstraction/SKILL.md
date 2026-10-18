---
name: sandbox-abstraction
description: 沙箱抽象层设计：SandboxProvider/Sandbox 双 ABC + 双检锁单例生命周期、虚拟路径↔宿主路径映射（/mnt/user-data 三挂载 + /mnt/skills 投影）、SandboxLeaseManager 租约与 teardown 串行化、acquire 全局串行化、LocalSandboxProvider（LRU 线程沙箱缓存）与生产级 AioSandboxProvider（跨进程文件锁所有权/孤儿回收/暖池/网络策略）、env 白名单注入。当要设计代码执行沙箱抽象、多 provider 切换、排查"沙箱串号/泄漏/并发 acquire 死锁"时使用。
---

# 沙箱抽象与 Provider

## 何时用

- 设计 agent 代码执行的沙箱抽象（本地直跑 vs 容器隔离统一接口）
- 虚拟路径映射与线程级隔离挂载
- 沙箱生命周期（获取/复用/回收/租约）与并发控制
- 多实例部署下的沙箱所有权与孤儿回收

## 设计方案（为什么这么设计）

### 1. 双 ABC + 单例 provider

- `SandboxProvider(ABC)`（sandbox_provider.py:15）：`acquire(thread_id, *, user_id) -> sandbox_id` / `get` / `release`；类属性声明能力（`uses_thread_data_mounts` / `supports_agent_skill_isolation`）；默认实现含 `get_scoped`（身份归属校验——B 的代码不能拿 A 的沙箱）与网络审批钩子（trusted-proxy 决策事件）。
- `Sandbox(ABC)`（sandbox.py:44）：`execute` / `read_file` / `write_file` / `list_dir`…
- provider 由 `config.sandbox.use` 经反射加载；`get_sandbox_provider()` **双检锁单例**，初始化失败者负责 shutdown 回收——半初始化的单例是最难查的脏状态。

### 2. 虚拟路径映射是安全边界

agent 看到的永远是 `/mnt/user-data/{workspace,uploads,outputs}` 与 `/mnt/skills`；宿主真实路径只在 provider 内部解析。`PathMapping(container_path, local_path, read_only)` + `ResolvedPath` 是映射核心——模型输出的路径要回写为虚拟路径（输出脱敏见 [[sandbox-tools-and-safety]]），宿主路径泄漏等于撕毁隔离。

### 3. 租约与串行化

`SandboxLeaseManager`（lease.py:170）管理 acquire/get/release 的并发租约；teardown 串行化保证"最后一个使用者释放后才真正销毁"。`acquire_serialization.py` 在**全局层面**把 acquire 串行化——多请求同时给同一线程建沙箱会产生两个容器互不知晓（merge_sandbox 冲突检测是最后防线，见 [[thread-state-and-reducers]]）。

### 4. 两个 Provider 实现

- **LocalSandboxProvider**（dev）：`_build_thread_path_mappings` 为线程挂工作区 + skills projection；LRU 缓存线程沙箱（上限淘汰）。LocalSandbox 每命令独立 `subprocess.run([shell, "-c", ...])`，**无持久 shell**（状态泄漏面最小），`_BoundedPipeCapture` 有界捕获防爆内存。
- **AioSandboxProvider**（生产，community/）：确定性 sandbox_id（thread+user 派生，重启可复找）、**跨进程文件锁所有权**、孤儿回收 `_reconcile_orphans`、暖池（WarmPoolLifecycleMixin 预热降低首命令延迟）、per-thread 挂载、网络策略事件消费；后端分 local_backend / remote_backend。

### 5. 环境变量白名单

`env_policy.py::build_sandbox_env`：沙箱内 env 是**注入制**而非继承制——只注入白名单键，屏蔽宿主敏感 env（凭证、代理）。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/sandbox/sandbox_provider.py` | 293 | Provider ABC + 双检锁单例 |
| `references/code/sandbox/sandbox.py` | 267 | Sandbox ABC |
| `references/code/sandbox/lease.py` | 801 | 租约管理 |
| `references/code/sandbox/acquire_serialization.py` | 223 | acquire 全局串行化 |
| `references/code/sandbox/middleware.py` | 673 | SandboxMiddleware（链上获取/网络审批） |
| `references/code/sandbox/env_policy.py` | 120 | env 注入/屏蔽 |
| `references/code/sandbox/path_patterns.py` | 153 | 输出路径掩码正则 |
| `references/code/sandbox/local/local_sandbox.py` | 1135 | LocalSandbox + PathMapping |
| `references/code/sandbox/local/local_sandbox_provider.py` | 607 | 线程挂载 + LRU 缓存 |
| `references/code/community/aio_sandbox/aio_sandbox_provider.py` | 2934 | 生产 provider（所有权/孤儿/暖池/网络） |
| `references/code/community/warm_pool_lifecycle.py` | 129 | 暖池混入 |
| `references/code/config/sandbox_config.py` | 347 | provider 选择/超时/host-bash 开关 |
| 其余（exceptions/identity/security/remote_*/download 等 14 个） | — | 辅助契约 |

社区另有 boxlite / e2b / opensandbox / tenki 等 provider，模式同构（SKILL 不复制，按需读源仓库同目录）。

## 反模式与陷阱

- ❌ acquire 不串行化 → 同线程双沙箱；靠 merge_sandbox 检测兜底不如源头防。
- ❌ 沙箱 env 直接继承宿主 → 凭证泄漏进模型可读面。
- ❌ release 即销毁 → 还有 in-flight 命令；租约计数归零才 teardown。
- ❌ 生产用 LocalProvider → 直连宿主执行；仅 dev 允许（`allow_host_bash` 独立开关且默认关）。
- ❌ provider 初始化失败不清场 → 半初始化单例；失败者 shutdown。

## 落地参考

**调参旋钮**：`sandbox.use`（类路径）、`sandbox.allow_host_bash`、命令超时、provisioner 模式（K8s，见 [[packaging-and-deployment]]）。

**自测方向**：同 thread 并发 acquire 断言单沙箱；user A 获取后 user B `get_scoped` 拒绝；杀 provider 进程后重启 `_reconcile_orphans` 收敛；env 断言只含白名单。

## 进一步阅读

- [[sandbox-tools-and-safety]]（在沙箱上跑的 bash/文件工具与路径安全）
- [[multi-user-isolation]]（user_id 如何流入沙箱桶）、[[middleware-chain-design]]（SandboxMiddleware 位置）
