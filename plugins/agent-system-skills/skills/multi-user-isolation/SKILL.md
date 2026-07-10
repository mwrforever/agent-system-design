---
name: multi-user-isolation
description: 设计 agent 系统的多用户隔离--get_effective_user_id 三级解析链 + per-user 物理目录（uploads/workspace/outputs/memory/agents）+ 内部 Token + X-Owner-User-Id 头 + owner 检查（防枚举）+ orphan 迁移（default 桶 -> 真实 user）+ user_context contextvar 全链路传播。链路位置 ②认证（跨切不变量 2：user_id 全链路隔离）。当你要做 per-user 分桶、加 owner 校验、排查"串用户"或 per-user 目录落错桶、从无认证升级到带认证做数据迁移时调用本 skill。
---

## 何时用

- agent 系统服务多个用户（公司内部 / 公网 / SaaS），要 memory / sandbox / uploads / agents 严格按用户分桶
- 排查"串用户"（per-user 目录落到错的桶 / 一律落到 default 桶）
- 接入 IM 通道（飞书 / Slack / Telegram），平台 user_id 与系统 user_id 需解耦
- 想从"无认证 -> 启用认证"平滑升级，旧 default 桶数据迁移到真实 user
- 加内部 Token + owner 头，让 channel worker / scheduler 代表用户发起请求
- 给 thread / run 路由加 owner 校验，防 thread_id 枚举攻击

## 设计方案（为什么这么设计）

### 核心定位：跨切不变量 2 的"隔离执行层"

[[e2e-request-lifecycle]] 定义 3 个跨切不变量，其中**不变量 2：user_id 全链路隔离**要求 ②认证 解析出的 user_id 在 ③–⑧ 全链路驱动 per-user 资源分桶。本 skill 是该不变量的**执行层**--[[auth]] 负责"凭证来源 -> 一个 user"（②认证 的前半跳），本 skill 负责"这个 user 如何落到物理目录、如何防越权、如何迁移遗留数据"。

**与 [[auth]] 的边界**：auth 讲**认证**（你是谁、cookie / JWT / 内部 Token 怎么解析、contextvar 怎么写、token 吊销、CSRF）；本 skill 讲**隔离**（同一个 user_id 如何分桶到 uploads / workspace / outputs / memory / agents、owner 检查如何防枚举、orphan 如何迁移）。两者共享 `user_context` contextvar 与 `set_current_user` 入口，但职责不重叠。

### 核心矛盾：单点解析 vs 跨边界丢失

业务代码需要"一个函数拿到当前 user_id"用于路径分桶；但 `ContextVar` 是 **task-local**（非 thread-local），跨三类边界会丢失：

1. 请求返回后的后台工具执行（worker pool 不 `copy_context`）
2. 子线程 / Timer（不继承 asyncio task context）
3. 跨进程（未来 driver）

### 解法：三级解析链 + 三态 sentinel

```python
# 伪代码：get_effective_user_id 用于文件系统分桶（永不抛，总有桶）
def get_effective_user_id() -> str:
    user = _current_user.get()                          # task-local contextvar
    return str(user.id) if user else DEFAULT_USER_ID    # "default" 兜底

# resolve_runtime_user_id 用于工具 / 中间件（跨边界权威）
def resolve_runtime_user_id(runtime) -> str:
    ctx = getattr(runtime, "context", None) or {}
    if isinstance(ctx, dict) and ctx.get("user_id"):    # 1) runtime.context（跨边界存活）
        return str(ctx["user_id"])
    return get_effective_user_id()                      # 2) contextvar -> 3) "default" 兜底

# resolve_user_id 用于 repository（三态 sentinel）
def resolve_user_id(value, *, method_name):
    if isinstance(value, _AutoSentinel):                # AUTO（默认）：读 contextvar，无则抛 RuntimeError
        return str(require_current_user().id)
    return value                                        # 显式 str 覆盖；显式 None 绕过过滤（迁移专用）
```

**分工**：文件系统路径用 `get_effective_user_id()`（永不抛，总有桶）；repository 用 `resolve_user_id(AUTO)`（无 user 抛错，防止静默泄漏）；工具 / 中间件用 `resolve_runtime_user_id(runtime)`（优先 `runtime.context["user_id"]`，跨边界存活）。

### 关键不变量（违反则串用户或泄漏）

1. **user_id 全链路隔离**（跨切不变量 2）：②认证 写 contextvar -> ③路由 owner 检查 -> ④建图 -> ⑤中间件（ThreadDataMiddleware 按 user_id 建目录）-> ⑥执行（工具按 user_id 读写）-> ⑦流式。任何一跳读到的 user_id 必须一致。
2. **`runtime.context["user_id"]` 优先于 contextvar**：后台工具执行时 contextvar 可能已丢，`inject_authenticated_user_context` 在请求期把 user_id 盖章进 `config["context"]`，worker 透传到 `ToolRuntime.context`，工具必须读这条而非 contextvar。
3. **user_id 消毒后才进路径**：外部 id（IM `open_id` / Telegram 负数 chat id）含 `_` `/` 等路径危险字符，`make_safe_user_id` 限定 `[A-Za-z0-9_-]` 并加 digest 后缀防碰撞。
4. **owner 检查返回 404 而非 403**：不存在 / 不属于自己一律 404，隐藏存在性差异，防枚举。
5. **内部 owner 头仅在 `INTERNAL_SYSTEM_ROLE` 下生效**：泄漏的内部 Token 不能授予跨用户线程访问；header 仅在 AuthMiddleware 校验内部 Token 后信任。
6. **orphan（NULL user_id）行宽松、缺行分语义、异主严格 404**：`check_access` 对 NULL owner / 缺行（读语义）返回 True（向后兼容遗留数据），仅异主返回 False；destructive 路由用 `require_existing=True` 让缺行也拒。

### per-user 目录模板

```python
# 伪代码：单一 Paths 类算所有 user-scoped 路径，改一处全链路跟
# {base_dir}/users/{user_id}/
#   ├── memory.json
#   ├── agents/{name}/{config.yaml, SOUL.md, memory.json}
#   ├── skills/custom/{name}/
#   └── threads/{thread_id}/user-data/{workspace,uploads,outputs}   # 挂载为 /mnt/user-data/
def thread_dir(thread_id, user_id=None):
    if user_id is not None:
        return base_dir / "users" / _validate_user_id(user_id) / "threads" / _validate_thread_id(thread_id)
    return base_dir / "threads" / _validate_thread_id(thread_id)     # 遗留布局（迁移前）
```

`ThreadDataMiddleware` 在 `before_agent` 调 `get_effective_user_id()` 拿 user_id -> `Paths.sandbox_work_dir(thread_id, user_id=...)` 算三个目录 -> 懒初始化只算路径、按需 `mkdir`。base_dir 解析优先级：构造参数 -> `HELIX_HOME` env -> `{project_root}/.helix`。

### IM 通道：内部 Token + owner 头（②认证 的 IM 入站路径）

```python
# 伪代码：channel worker 代表 owner 发请求
def _owner_headers(msg):
    owner = _effective_owner_user_id(msg)       # 已绑定 -> connection owner；未绑定 -> 平台 user_id
    return create_internal_auth_headers(owner_user_id=owner)
    # -> {"X-Helix-Internal-Token": <token>, "X-Helix-Owner-User-Id": owner}

# AuthMiddleware 侧：校验内部 Token 后，synthetic user.id = make_safe_user_id(owner)
# -> get_effective_user_id() 返回 owner -> per-user 目录正确分桶（不落 default）
```

`_channel_storage_user_id` 是 IM 入站的**单一真相源**：run 身份与文件暂存桶用同一 helper，避免"agent 读 `users/{safe}/...` 但文件落到 `users/default/...`"（dispatcher task 的 contextvar 未设 -> default 兜底）。该 helper 与 `_owner_headers` 有意不同：前者是进程内、已消毒、文件系统面向的 id；后者发原始 owner id 让 gateway 重新解析。

### owner 检查在端到端链路中的位置（②认证 -> ③路由）

`@require_permission("threads", "read", owner_check=True)` 装饰器在 ③路由 层校验 path 参数 `thread_id`；stateless run 端点（thread_id 在 body 不在 path，装饰器拿不到）在 `start_run` 内显式 `check_access`。两处都支持内部 owner 头二次校验：首检失败 + `INTERNAL_SYSTEM_ROLE` -> 用 `X-Helix-Owner-User-Id` 头的 owner 再查一次（channel worker 代表 owner），而非绕过检查。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/runtime/user_context.py` | contextvar + `get_effective_user_id` / `set_current_user` / `resolve_runtime_user_id` / `AUTO` 三态 sentinel / `CurrentUser` Protocol | [user-context.md](./references/code/user-context.md) |
| `core/helix/config/paths.py` + `core/helix/config/runtime_paths.py` + `core/helix/agents/middlewares/thread_data_middleware.py` | per-user 目录模板 + `make_safe_user_id` 消毒 + base_dir 解析 + ThreadDataMiddleware 建目录 | [thread-data-and-paths.md](./references/code/thread-data-and-paths.md) |
| `gateway/gateway/internal_auth.py` + `gateway/gateway/authz.py` + `gateway/gateway/auth_middleware.py` + `core/helix/persistence/thread_meta/sql.py` + `gateway/gateway/services.py` | 内部 Token + owner 头 + owner 检查装饰器 + `check_access` 三态语义 + AuthMiddleware 写 contextvar + `inject_authenticated_user_context` | [owner-check-and-internal-auth.md](./references/code/owner-check-and-internal-auth.md) |
| `scripts/migrate_user_isolation.py` | 一次性迁移：遗留 threads / agents / skills / memory -> per-user 布局，无主数据归 `--user-id`（默认 default） | [orphan-migration.md](./references/code/orphan-migration.md) |

### 模块入口与索引

**user_context（contextvar 基座）**（完整源码见 [user-context.md](./references/code/user-context.md)）：
- `_current_user: ContextVar` task-local；`set_current_user` 返回 token，`finally` 里 `reset_current_user` 复位。
- `get_effective_user_id()`：文件系统分桶用，永不抛，无 user 返 `"default"`。
- `resolve_runtime_user_id(runtime)`：工具 / 中间件用，优先 `runtime.context["user_id"]`（跨边界存活）-> contextvar -> `"default"`。
- `resolve_user_id(value)` + `AUTO` sentinel：repository 用，三态（AUTO 读 contextvar 无则抛 / 显式 str 覆盖 / 显式 None 绕过）。
- `CurrentUser` Protocol（结构类型，`.id: str`）：persistence 层不 import 具体 User 类，避免框架层反向依赖应用层。

**文件系统隔离**（完整源码见 [thread-data-and-paths.md](./references/code/thread-data-and-paths.md)）：
- `Paths.user_dir / user_memory_file / user_agents_dir / user_agent_dir / user_skills_dir / user_custom_skills_dir / thread_dir / sandbox_work_dir / sandbox_uploads_dir / sandbox_outputs_dir`：全 per-user。
- `make_safe_user_id(raw)`：unsafe 字符替换为 `-`，加 SHA-256 digest 后缀防碰撞；`prepare_user_dir_for_raw_id` 检测旧 SHA-1 桶并 rename 迁移。
- `_validate_user_id` / `_validate_thread_id`：正则 `^[A-Za-z0-9_-]+$` 防 `..` 越权。
- `ThreadDataMiddleware.before_agent`：`get_effective_user_id()` -> 算三目录 -> 懒初始化只算路径 / 急初始化 `mkdir` + `chmod 0o777`（沙箱容器不同 UID 可写）。
- `runtime_home()`：base_dir 解析，`HELIX_HOME` env -> `{project_root}/.helix`。

**owner 检查 + 内部 Token**（完整源码见 [owner-check-and-internal-auth.md](./references/code/owner-check-and-internal-auth.md)）：
- `AuthMiddleware.dispatch`：校验内部 Token / cookie JWT / auth-disabled -> `request.state.user` + `set_current_user(user)` 写 contextvar，`finally` `reset_current_user` 复位。
- `get_internal_user(owner_user_id)`：synthetic user，`.id = make_safe_user_id(owner)`，`system_role="internal"`；无 owner 则 `.id = "default"`。
- `get_trusted_internal_owner_user_id(request)`：仅 `system_role==internal` 时信任 `X-Helix-Owner-User-Id` 头。
- `require_permission(..., owner_check=True, require_existing=?)`：`check_access` 失败 + internal 角色 -> 用 owner 头二次校验；仍失败 -> 404。
- `ThreadMetaRepository.check_access`：缺行返 `not require_existing`；NULL user_id 返 True（遗留共享）；异主返 False。
- `inject_authenticated_user_context`：请求期把 user_id 盖章进 `config["context"]`（`setdefault` 让服务端认证 id 覆盖客户端传入），worker 透传，工具跨边界可读。

**orphan 迁移**（完整源码见 [orphan-migration.md](./references/code/orphan-migration.md)）：
- `migrate_thread_dirs`：查 `threads_meta` 建 `thread_id -> user_id` owner_map，遗留 `threads/{id}/` -> `users/{owner}/threads/{id}/`，冲突移 `migration-conflicts/`。
- `migrate_agents` / `migrate_skills` / `migrate_memory`：遗留全局 agents / skills / memory.json -> `users/{user_id}/...`，默认 `--user-id default`。
- 幂等：再跑无遗留目录即 no-op；空遗留目录清理；无主线程归 default 并告警。

## 反模式与陷阱

- ❌ 子线程 / Timer / worker 直接 `get_effective_user_id()` -> contextvar 不可见，串到 default 桶。修复：用 `resolve_runtime_user_id(runtime)` 读 `runtime.context["user_id"]`（由 `inject_authenticated_user_context` 预盖）。
- ❌ 路由不做 owner 检查，依赖 thread_id 不可枚举 -> ID 泄露后任意用户跨读。修复：`@require_permission(owner_check=True)`；stateless run 端点在 `start_run` 内显式 `check_access`。
- ❌ 物理目录用 `f"data/{user_id}/..."`，user_id 未消毒 -> `../../etc/passwd` 越权。修复：`make_safe_user_id` + `_validate_user_id` 正则限定。
- ❌ 内部 owner 头任何路径都信 -> 内网横向时被滥用。修复：仅 `INTERNAL_SYSTEM_ROLE` 下信任（AuthMiddleware 先校验内部 Token）。
- ❌ thread 不存在返 403（vs 不属于自己）-> 攻击者枚举存在的 thread_id。修复：一律 404。
- ❌ IM channel run 身份与文件暂存桶用不同 helper -> agent 读 `users/{safe}/...` 但文件落 `users/default/...`（dispatcher contextvar 未设）。修复：`_channel_storage_user_id` 单一真相源。
- ❌ `check_access` 对缺行 strict-allow -> 已删线程被另一用户 re-target（delete 幂等跨用户漏洞）。修复：destructive 路由用 `require_existing=True`。
- ❌ repository `user_id=AUTO` 在无 contextvar 的迁移脚本里调用 -> 抛 RuntimeError。修复：迁移脚本传 `user_id=None` 显式绕过。
- ❌ `make_safe_user_id` 换 digest 算法（SHA-1 -> SHA-256）不迁移旧桶 -> 同一用户两份目录。修复：`prepare_user_dir_for_raw_id` 检测旧桶并 rename。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `DEFAULT_USER_ID` | `user_context.py` 常量 `"default"` | 无 user 兜底桶；迁移脚本 `--user-id` 默认值 |
| `HELIX_INTERNAL_AUTH_TOKEN` | env | 内部 Token；未设则进程启动生成随机 token（`secrets.token_urlsafe(32)`） |
| `HELIX_HOME` / `HELIX_HOST_BASE_DIR` / `HELIX_PROJECT_ROOT` | env | base_dir / Docker 挂载宿主路径 / 项目根 |
| `ThreadDataMiddleware(lazy_init=...)` | factory 构造 | True 只算路径（默认）；False 急建目录 |
| `require_permission(require_existing=...)` | 装饰器参数 | False 缺行宽松（读）；True 缺行拒（删 / 改） |
| `_SAFE_USER_ID_DIGEST_HEX_LEN` | `paths.py` 常量 `16` | `make_safe_user_id` 防碰撞 digest 后缀长度 |

**关键日志串**

- `Migrated thread %s -> user %s` - orphan 线程迁移成功
- `Conflict for thread %s: moved to %s` - 迁移冲突（目标已存在）
- `%d thread(s) had no owner and were assigned to 'default'` - 无主线程归 default
- `Migrated legacy unsafe-id user directory to the current digest format` - SHA-1 -> SHA-256 桶迁移
- `Thread %s not found` - owner 检查失败（404，防枚举）
- `repository accessed without user context` - AUTO 但无 contextvar（RuntimeError）

**自测方向**

- **三级解析**：mock contextvar 未设，`get_effective_user_id()` 返 `"default"`；`resolve_user_id(AUTO)` 抛 RuntimeError；`resolve_runtime_user_id(runtime)` 读 `runtime.context["user_id"]` 优先于 contextvar。
- **per-user 分桶**：mock 两个 user_id，断言 `sandbox_work_dir(uid_a, tid)` != `sandbox_work_dir(uid_b, tid)`，且都在 `users/{uid}/threads/{tid}/` 下。
- **路径越权**：`user_id="../../etc"` -> `_validate_user_id` 抛 ValueError；`make_safe_user_id("ou_abc/def")` 产出 `[A-Za-z0-9_-]` 字符集且两次调用稳定。
- **owner 防枚举**：异主 thread `GET /threads/{tid}` 返 404；缺行（遗留）读返 200 但 `DELETE` 返 404（`require_existing=True`）；NULL owner 行任意用户可读。
- **内部 owner 头**：无内部 Token 的请求带 `X-Helix-Owner-User-Id` -> 头被忽略（`get_trusted_internal_owner_user_id` 返 None）；有内部 Token -> `get_effective_user_id()` 返 `make_safe_user_id(owner)`。
- **orphan 迁移幂等**：跑两次，第二次无遗留目录 -> no-op；冲突目录移到 `migration-conflicts/`；无主线程归 default。
- **IM 单一真相源**：channel run 的 `runtime.context["user_id"]` == 文件暂存桶 user_id（都来自 `_channel_storage_user_id`），不出现 default 串桶。

## 进一步阅读

- 完整源码：[references/code/user-context.md](./references/code/user-context.md) / [thread-data-and-paths.md](./references/code/thread-data-and-paths.md) / [owner-check-and-internal-auth.md](./references/code/owner-check-and-internal-auth.md) / [orphan-migration.md](./references/code/orphan-migration.md)
- 关联 skill：[[auth]]（②认证 前半跳：凭证 -> user，contextvar 写入入口），[[e2e-request-lifecycle]]（跨切不变量 2 全链路推导），[[memory-system-design]]（per-user `memory.json`），[[sandbox-abstraction]]（per-user `/mnt/user-data` 挂载），[[im-channels]]（IM 入站 owner 解析与 `_channel_storage_user_id`），[[gateway-runs-and-sse]]（`start_run` owner 检查），[[skill-system-design]]（per-user custom skills 目录）
