---
name: multi-user-isolation
description: 设计 agent 系统的多用户隔离——get_effective_user_id 解析链、per-user 物理目录、内部 Token 转发、owner 检查、IM 通道 X-Owner-User-Id 头、orphan 数据迁移。
---

## 何时用

- agent 系统要服务多个用户（公司内部 / 公网 / SaaS）
- 想让 memory / sandbox / uploads / agents 严格按用户分桶
- 接入 IM 通道（飞书 / Slack）时，平台 user_id 与系统 user_id 需要解耦
- 想从"无认证 → 启用认证"平滑升级（已有数据迁移到 admin）

## 设计思想

1. **单一函数 `get_effective_user_id()` + ContextVar**：HTTP 中间件 / IM dispatcher 写入 contextvar；业务代码统一从 contextvar 读；fallback 到 `DEFAULT_USER_ID = "default"`。
2. **资源路径模板**：所有 user-scoped 资源用同一函数算路径——`{base}/users/{user_id}/{kind}/{thread_id}/...`。改一次路径所有调用点跟着改。
3. **ContextVar 边界小心**：子线程 / Timer 不继承 contextvar（Python 行为）；这些地方**显式传 user_id 参数**，由调用者在 contextvar 还可见时 capture。
4. **IM 通道带 owner 头**：内部 Token 认证的请求带 `X-Owner-User-Id` → 让 channel worker 代表用户发起请求；普通 browser 请求依赖标准 session cookie。
5. **owner check 前置**：所有 thread/run 路由先做 `thread_store.check_access(thread_id, user_id)`；不存在 / 不属于当前用户 → 一律 404，避免枚举攻击。
6. **单一活跃 owner**：IM 平台外部账号绑定时，最新 bind 赢；老 owner 的 active 行被自动 revoke（partial unique index 守护）。
7. **orphan 迁移**：升级到带认证时，扫 store 找无 user_id 的旧 thread → 全部迁给首个 admin。

## 实现模板

### user_id 解析链

```python
# runtime/user_context.py
DEFAULT_USER_ID = "default"
_current_user: ContextVar["User | None"] = ContextVar("_current_user", default=None)


def get_effective_user_id() -> str:
    """业务代码统一入口."""
    user = _current_user.get()
    if user is None:
        return DEFAULT_USER_ID
    return str(user.id)


def set_current_user(user) -> ContextVar:
    return _current_user.set(user)


def reset_current_user(token):
    _current_user.reset(token)


def resolve_runtime_user_id(runtime) -> str:
    """子线程 / 工具内：优先 runtime.context['user_id'] → contextvar → default."""
    if runtime is None: return DEFAULT_USER_ID
    ctx = runtime.context or {}
    if isinstance(ctx, dict) and ctx.get("user_id"):
        return str(ctx["user_id"])
    return get_effective_user_id()
```

### AuthMiddleware：解析后注入 contextvar

```python
class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        # 1) 解析 session cookie / JWT / 内部 Token
        user = await self._authenticate(request)
        if user is None and not is_public_path(request.url.path):
            return JSONResponse({"detail": "Unauthorized"}, status_code=401)
        request.state.user = user
        token = set_current_user(user) if user else None
        try:
            return await call_next(request)
        finally:
            if token: reset_current_user(token)
```

### 路由内 owner 检查

```python
async def start_run(body, thread_id, request):
    user = getattr(request.state, "user", None)
    if user is not None:
        allowed = await run_ctx.thread_store.check_access(thread_id, str(user.id))
        owner_id = get_trusted_internal_owner_user_id(request)    # IM 通道头
        if not allowed and owner_id and user.system_role == INTERNAL_SYSTEM_ROLE:
            # IM 通道也可代表 owner 通过校验
            allowed = await run_ctx.thread_store.check_access(thread_id, owner_id)
        if not allowed:
            raise HTTPException(404, f"Thread {thread_id} not found")  # ⭐ 不要返回 403
    # ... 创建 run
```

### IM 通道：内部 Token + owner 头

```python
# channels/manager.py
async def _handle_chat(self, msg: InboundMessage):
    owner_user_id = self._channel_storage_user_id(msg)   # 已绑定 → connection owner / 未绑定 → channel user_id
    async with self._client_for_owner(owner_user_id) as client:
        # 内部 SDK 客户端：携带内部 token + X-Owner-User-Id 头
        thread = await client.threads.get_or_create(_thread_key_for(msg))
        async for ev in client.runs.stream(thread.thread_id, "lead_agent",
                                            input={"messages": [...]}):
            ...
```

```python
# gateway/internal_auth.py
def get_trusted_internal_owner_user_id(request) -> str | None:
    """仅当请求通过内部 Token 认证后才信任此头部."""
    user = getattr(request.state, "user", None)
    if not user or user.system_role != INTERNAL_SYSTEM_ROLE:
        return None
    return request.headers.get("X-Owner-User-Id")
```

### 物理目录模板

```python
# config/paths.py
def base_dir() -> Path: return Path(".agent-framework")

def user_dir(user_id: str) -> Path:
    return base_dir() / "users" / make_safe_user_id(user_id)

def thread_workspace(user_id: str, thread_id: str) -> Path:
    return user_dir(user_id) / "threads" / thread_id / "user-data" / "workspace"

def memory_file(user_id: str, agent_name: str | None = None) -> Path:
    if agent_name:
        return user_dir(user_id) / "agents" / agent_name / "memory.json"
    return user_dir(user_id) / "memory.json"


def make_safe_user_id(raw: str) -> str:
    """路径安全：禁止 / .. , 限定字符集."""
    return re.sub(r"[^a-zA-Z0-9_-]", "_", raw)[:64]
```

### Orphan 迁移

```python
async def _migrate_orphaned_threads(store, admin_user_id: str) -> int:
    migrated = 0
    async for item in _iter_store_items(store, ("threads",)):  # cursor 分页
        metadata = item.value.get("metadata", {})
        if not metadata.get("user_id"):
            metadata["user_id"] = admin_user_id
            item.value["metadata"] = metadata
            await store.aput(("threads",), item.key, item.value)
            migrated += 1
    return migrated
```

## 反模式

- ❌ 子线程 / Timer 直接 `get_effective_user_id()` → ContextVar 不可见，全部串到 default 用户
- ❌ 路由不做 owner check，依赖 thread_id 不可枚举 → ID 泄露后任意用户跨读
- ❌ 物理目录用 `f"data/{user_id}/..."`，user_id 未消毒 → `../../etc/passwd` 越权
- ❌ 内部 Token 头任何路径都信 → 内网横向时被滥用；必须先校验 INTERNAL_SYSTEM_ROLE
- ❌ thread 不存在返回 403（vs 用户不属于自己）→ 攻击者可枚举存在的 thread_id
- ✅ Make_safe_user_id 限定字符集 + 长度
- ✅ 一律 404 隐藏存在性差异

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[memory-system-design]] [[sandbox-abstraction]] [[gateway-runs-and-sse]]
