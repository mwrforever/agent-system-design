# ② 认证闸门完整源码

> 本文件是脊柱 `SKILL.md` 第②跳"认证"的深度展开。脊柱只给入口片段；此处给 `AuthMiddleware`、`internal_auth`、`auth/jwt`、`runtime/user_context` 的完整真实源码（匿名化后 + 中文注解）。
>
> 代码已按插件匿名化规则映射到自定结构（`gateway.*` / `helix.*`），去除一切项目字样；原代码注释保真，中文注解以"注："或行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱）、`[[auth]]`（三层认证深度）、`[[multi-user-isolation]]`（per-user 目录）、`cross-cutting-invariants.md` 不变量 2。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `gateway/gateway/auth_middleware.py` | 全局 fail-closed 认证中间件：三种凭证汇合到 contextvar |
| `gateway/gateway/internal_auth.py` | 进程内内部认证（scheduler/channels -> Gateway）：token 校验 + owner 头规范化 |
| `gateway/gateway/auth/jwt.py` | Web 路径 JWT：签发 + 校验（含 token_version 吊销） |
| `core/helix/runtime/user_context.py` | 承载全链路 user_id 的 contextvar + 三级回退解析 |

---

## 1. `gateway/gateway/auth_middleware.py`（完整）

```python
"""全局认证中间件 - fail-closed 安全网。

拒绝未认证请求访问非公共路径（401）。cookie 校验通过时，把 JWT payload
解析成真实 User 对象，盖到 request.state.user 与 helix.runtime.user_context
contextvar 上，使 repository 层的属主过滤经哨兵模式自动生效。

细粒度权限检查仍由 authz.py 的装饰器负责。
"""

from collections.abc import Callable

from fastapi import HTTPException, Request, Response
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp

from gateway.gateway.auth.errors import AuthErrorCode, AuthErrorResponse
from gateway.gateway.auth_disabled import (
    AUTH_SOURCE_AUTH_DISABLED,
    AUTH_SOURCE_INTERNAL,
    AUTH_SOURCE_SESSION,
    get_auth_disabled_user,
    is_auth_disabled,
)
from gateway.gateway.authz import _ALL_PERMISSIONS, AuthContext
from gateway.gateway.internal_auth import INTERNAL_AUTH_HEADER_NAME, get_internal_user, is_valid_internal_auth_token
from helix.runtime.user_context import reset_current_user, set_current_user

# 永不需要认证的路径前缀。
_PUBLIC_PATH_PREFIXES: tuple[str, ...] = (
    "/health",
    "/docs",
    "/redoc",
    "/openapi.json",
    "/api/v1/auth/oauth/",
    "/api/v1/auth/callback/",
    # 入站 webhook 经 provider 专属签名认证（如 GitHub 的 X-Hub-Signature-256），不靠 session cookie。
    "/api/webhooks/",
)

# 精确的公共 auth 路径（登录/注册/状态检查）。
# /api/v1/auth/me、/api/v1/auth/change-password 等不是公共路径。
_PUBLIC_EXACT_PATHS: frozenset[str] = frozenset(
    {
        "/api/v1/auth/login/local",
        "/api/v1/auth/register",
        "/api/v1/auth/logout",
        "/api/v1/auth/setup-status",
        "/api/v1/auth/initialize",
        "/api/v1/auth/providers",
    }
)


def _is_public(path: str) -> bool:
    stripped = path.rstrip("/")
    if stripped in _PUBLIC_EXACT_PATHS:
        return True
    return any(path.startswith(prefix) for prefix in _PUBLIC_PATH_PREFIXES)


class AuthMiddleware(BaseHTTPMiddleware):
    """严格认证闸门：无有效 session 即拒绝。

    非公共路径两阶段检查：
    1. cookie 存在性 - 缺则 401 NOT_AUTHENTICATED
    2. 经 get_optional_user_from_request 做 JWT 校验 - token 缺失/畸形/过期，
       或签名用户不存在/已 stale，均 401 TOKEN_INVALID

    成功后盖 request.state.user 与 helix.runtime.user_context contextvar，
    使 repository 属主过滤在下游自动生效，无需每个路由加 @require_auth。
    需 per-resource 授权的路由（如"用户 A 不能靠猜 URL 读用户 B 的 thread"）
    额外用 @require_permission(..., owner_check=True) 显式强制--但认证本身在此全权处理。
    """

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        # 注：公共路径直接放行（健康检查、文档、OAuth 回调、webhook 签名认证路径）
        if _is_public(request.url.path):
            return await call_next(request)

        internal_user = None
        if is_valid_internal_auth_token(request.headers.get(INTERNAL_AUTH_HEADER_NAME)):
            # 从受信任头抽取通道属主 user id。
            # 存在时，合成内部 user 的 .id 承载真实属主身份，使 get_effective_user_id()
            # 与 per-user 文件系统路径（自定义 skill、记忆、thread 数据）解析到 IM 通道用户，
            # 而非回退到 "default"。
            from gateway.gateway.internal_auth import INTERNAL_OWNER_USER_ID_HEADER_NAME

            owner_user_id = request.headers.get(INTERNAL_OWNER_USER_ID_HEADER_NAME)
            if owner_user_id:
                owner_user_id = owner_user_id.strip()
            # 注：owner 头经 make_safe_user_id 规范化（防路径穿越/跨用户冒充），见 internal_auth.py
            internal_user = get_internal_user(owner_user_id=owner_user_id or None)

        auth_source = AUTH_SOURCE_SESSION
        access_token = request.cookies.get("access_token")

        # 非公共路径：需要 session cookie
        if internal_user is not None:
            # 注：内部调用者（scheduler/channels）合成内部用户，跳过 JWT 校验
            user = internal_user
            auth_source = AUTH_SOURCE_INTERNAL
        elif access_token:
            # 严格 JWT 校验：畸形/过期 token 在此 401，而非静默放行。
            # 这关闭"垃圾 cookie 绕过"漏洞（AUTH_TEST_PLAN test 7.5.8）：
            # 否则 /api/models 这类非隔离路由会接受任何 cookie 形状的字符串当认证。
            #
            # 调严格解析器，使细粒度错误码（token_expired/token_invalid/user_not_found...）
            # 从 AuthErrorCode 透传，而非压成一个通用码。BaseHTTPMiddleware 不让
            # HTTPException 冒泡，故在此 catch 并渲染为 JSONResponse。
            from gateway.gateway.deps import get_current_user_from_request

            try:
                user = await get_current_user_from_request(request)
            except HTTPException as exc:
                if not is_auth_disabled():
                    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
                # 注：auth-disabled 模式下即使 JWT 失败也降级为合成 admin（本地/E2E）
                user = get_auth_disabled_user()
                auth_source = AUTH_SOURCE_AUTH_DISABLED
        elif is_auth_disabled():
            # 注：无认证模式（本地开发/E2E）合成 admin 用户
            user = get_auth_disabled_user()
            auth_source = AUTH_SOURCE_AUTH_DISABLED
        else:
            # 注：fail-closed：无任何有效凭证 -> 401
            return JSONResponse(
                status_code=401,
                content={
                    "detail": AuthErrorResponse(
                        code=AuthErrorCode.NOT_AUTHENTICATED,
                        message="Authentication required",
                    ).model_dump()
                },
            )

        # 同时盖 request.state.user（contextvar 模式用）和 request.state.auth
        # （使 @require_permission 的 "auth is None" 分支短路，而非每请求再跑一遍
        # JWT-decode + DB-lookup 流水线）。
        request.state.user = user
        request.state.auth_source = auth_source
        request.state.auth = AuthContext(user=user, permissions=_ALL_PERMISSIONS)
        # 注：写 contextvar--此后 ③–⑧ 全靠它读 user_id（跨切不变量 2）
        token = set_current_user(user)
        try:
            return await call_next(request)
        finally:
            # 注：请求结束恢复 contextvar，防跨请求泄漏（asyncio task-local）
            reset_current_user(token)
```

---

## 2. `gateway/gateway/internal_auth.py`（完整）

```python
"""受信任 Gateway 内部调用者的认证。"""

from __future__ import annotations

import os
import secrets
from types import SimpleNamespace
from typing import Any

from helix.config.paths import make_safe_user_id
from helix.runtime.user_context import DEFAULT_USER_ID

INTERNAL_AUTH_HEADER_NAME = "X-Helix-Internal-Token"
INTERNAL_OWNER_USER_ID_HEADER_NAME = "X-Helix-Owner-User-Id"
INTERNAL_AUTH_ENV_VAR = "HELIX_INTERNAL_AUTH_TOKEN"
INTERNAL_SYSTEM_ROLE = "internal"


def _load_internal_auth_token() -> str:
    """启动时加载内部令牌：env 有则用 env，否则生成一个随机令牌（进程内自洽）。"""
    token = os.environ.get(INTERNAL_AUTH_ENV_VAR)
    if token:
        return token
    return secrets.token_urlsafe(32)


_INTERNAL_AUTH_TOKEN = _load_internal_auth_token()


def create_internal_auth_headers(*, owner_user_id: str | None = None) -> dict[str, str]:
    """返回认证受信任 Gateway 内部调用的头。channels/scheduler 用它标明所属用户。"""
    headers = {INTERNAL_AUTH_HEADER_NAME: _INTERNAL_AUTH_TOKEN}
    if owner_user_id:
        headers[INTERNAL_OWNER_USER_ID_HEADER_NAME] = owner_user_id
    return headers


def is_valid_internal_auth_token(token: str | None) -> bool:
    """token 与本 Gateway worker 的内部令牌匹配则 True。常量时间比较防时序侧信道。"""
    return bool(token) and secrets.compare_digest(token, _INTERNAL_AUTH_TOKEN)


def get_internal_user(owner_user_id: str | None = None):
    """返回受信任内部通道调用者用的合成 user。

    owner_user_id（从 X-Helix-Owner-User-Id 头取出）非空时，合成 user 的 .id
    承载真实通道属主而非 DEFAULT_USER_ID。这保证 get_effective_user_id() 与下游
    文件系统路径解析（per-user 自定义 skill、记忆、thread 数据）对 IM 通道消息
    用正确身份，而非回退到 "default"。

    owner id 经 make_safe_user_id 规范化：IM 通道 id（飞书 open_id 带 ou_ 前缀和
    被系统当路径分隔的下划线、Telegram 负数 chat id 等）含 [A-Za-z0-9_-] 以外字符，
    规范化后无法逃逸 per-user 存储桶或经头值技巧（尾斜杠、.. 段）冒充其他用户。
    规范化有损但确定：两个不同原始输入永不共享 safe id，故跨用户泄漏不可能。
    """
    if owner_user_id:
        effective_id = make_safe_user_id(owner_user_id)
    else:
        effective_id = DEFAULT_USER_ID
    return SimpleNamespace(id=effective_id, system_role=INTERNAL_SYSTEM_ROLE)


def get_trusted_internal_owner_user_id(request: Any) -> str | None:
    """返回受信任内部请求的 owner 覆盖值（若有）。

    普通浏览器/API 调用者塞的头被忽略。仅在 AuthMiddleware 校验内部 token 并把
    合成内部 user 盖到 request.state.user 上之后才生效。这是防冒充的关键门控。
    """
    user = getattr(getattr(request, "state", None), "user", None)
    if getattr(user, "system_role", None) != INTERNAL_SYSTEM_ROLE:
        return None

    owner_user_id = request.headers.get(INTERNAL_OWNER_USER_ID_HEADER_NAME)
    if not owner_user_id:
        return None
    owner_user_id = owner_user_id.strip()
    return owner_user_id or None
```

---

## 3. `gateway/gateway/auth/jwt.py`（关键片段）

> Web 路径凭证：HttpOnly cookie 里的 JWT。`token_version` 字段实现"改密码/登出后吊销旧 token"。

```python
"""JWT 令牌签发与校验。"""

from datetime import UTC, datetime, timedelta

import jwt
from pydantic import BaseModel

from gateway.gateway.auth.config import get_auth_config
from gateway.gateway.auth.errors import TokenError


class TokenPayload(BaseModel):
    """JWT token payload。"""
    sub: str  # user_id
    exp: datetime
    iat: datetime | None = None
    ver: int = 0  # token_version - 必须匹配 User.token_version（改密/登出后递增使旧 token 失效）


def create_access_token(user_id: str, expires_delta: timedelta | None = None, token_version: int = 0) -> str:
    """签发 JWT access token。

    Args:
        user_id: 用户 UUID 字符串
        expires_delta: 可选自定义过期，默认 7 天
        token_version: 用户当前 token_version，用于吊销

    Returns:
        编码后的 JWT 字符串
    """
    config = get_auth_config()
    expiry = expires_delta or timedelta(days=config.token_expiry_days)

    now = datetime.now(UTC)
    payload = {"sub": user_id, "exp": now + expiry, "iat": now, "ver": token_version}
    return jwt.encode(payload, config.jwt_secret, algorithm="HS256")


def decode_token(token: str) -> TokenPayload | TokenError:
    """解码并校验 JWT token。

    Returns:
        合法返回 TokenPayload，否则返回具体 TokenError 变体（供 AuthErrorCode 透传细粒度错误码）。
    """
    config = get_auth_config()
    try:
        payload = jwt.decode(token, config.jwt_secret, algorithms=["HS256"])
        return TokenPayload(**payload)
    except jwt.ExpiredSignatureError:
        return TokenError.EXPIRED
    except jwt.InvalidSignatureError:
        return TokenError.INVALID_SIGNATURE
    except jwt.PyJWTError:
        return TokenError.MALFORMED
```

> 注：`get_current_user_from_request`（`gateway/gateway/deps.py`，未完整展开）在 `decode_token` 之上还做：cookie 提取 -> `decode_token` -> 按 `sub` 查 DB User -> 校验 `ver == User.token_version`（不匹配返回 `TOKEN_INVALID`，实现吊销）-> 返回 `User` 或抛 `HTTPException`。`token_version` 不匹配是吊销的唯一来源，故改密/登出后递增 `User.token_version` 即让所有旧 cookie 失效。

---

## 4. `core/helix/runtime/user_context.py`（关键片段）

> 承载全链路 user_id 的 contextvar。`persistence`（下层）读它，`gateway.auth`（上层）写它。`CurrentUser` 是 `Protocol`，使 `persistence` 不必 import 具体 `User` 类。

```python
"""请求级 user 上下文，用于基于用户的授权。

本模块持有一个 ContextVar，由 gateway 的认证中间件在成功认证后设置。
repository 方法经哨兵默认参数读 contextvar，使路由免于 user_id 样板代码。

repository user_id 参数的三态语义（消费侧在 helix.persistence.*）：
- _AUTO（模块私有哨兵，默认）：从 contextvar 读；未设置抛 RuntimeError。
- 显式 str：用提供的值，覆盖 contextvar。
- 显式 None：无 WHERE 子句--仅迁移脚本和管理 CLI 用，故意绕过隔离。

依赖方向
--------
persistence（下层）读本模块；gateway.auth（上层）写它。CurrentUser 在此定义为
typing.Protocol，使 persistence 永不需要从 gateway.auth.models import 具体 User 类。
任何有 .id: str 属性的对象结构上满足该协议。

asyncio 语义
------------
ContextVar 在 asyncio 下是 task-local，非 thread-local。每个 FastAPI 请求跑在
自己的 task 里，故上下文天然隔离。asyncio.create_task 与 asyncio.to_thread 继承
父 task 的上下文，通常符合预期；若后台任务必须看不到前台 user，用
contextvars.copy_context() 取一份干净副本。
"""

from __future__ import annotations

from contextvars import ContextVar, Token
from typing import Final, Protocol, runtime_checkable


@runtime_checkable
class CurrentUser(Protocol):
    """当前认证用户的结构类型。任何有 .id: str 属性的对象满足。具体实现在 gateway.gateway.auth.models.User。"""
    id: str


_current_user: Final[ContextVar[CurrentUser | None]] = ContextVar("helix_current_user", default=None)


def set_current_user(user: CurrentUser) -> Token[CurrentUser | None]:
    """为本 async task 设当前 user。返回 reset token，应在 finally 里传给 reset_current_user 恢复。"""
    return _current_user.set(user)


def reset_current_user(token: Token[CurrentUser | None]) -> None:
    """恢复到 token 捕获的上下文状态。"""
    _current_user.reset(token)


def get_current_user() -> CurrentUser | None:
    """返回当前 user，未设置返回 None。任何上下文都安全可调（迁移脚本、公共端点等无 user 也能继续）。"""
    return _current_user.get()


def require_current_user() -> CurrentUser:
    """返回当前 user，未设置抛 RuntimeError。供必须在请求认证上下文外不可调用的 repository 代码用。"""
    user = _current_user.get()
    if user is None:
        raise RuntimeError("repository accessed without user context")
    return user


# ---------------------------------------------------------------------------
# 有效 user_id 辅助（文件系统隔离）
# ---------------------------------------------------------------------------

DEFAULT_USER_ID: Final[str] = "default"


def get_effective_user_id() -> str:
    """返回当前 user.id 字符串，未设置返回 DEFAULT_USER_ID。永不抛异常--
    文件系统路径解析永远需要一个有效 user 桶。无认证模式落 "default" 桶。"""
    user = _current_user.get()
    if user is None:
        return DEFAULT_USER_ID
    return str(user.id)


def resolve_runtime_user_id(runtime: object | None) -> str:
    """工具/中间件有效 user_id 的单一事实源。解析顺序（权威性从高到低）：
      1. runtime.context['user_id']--由 gateway 的 inject_authenticated_user_context
         从认证态 request.state.user 钉入。这是唯一能穿越 contextvar 可能丢失的边界
         （请求任务外调度的工作者、不 copy_context 的池、未来跨进程驱动）的来源。
      2. _current_user ContextVar--由认证中间件在请求入口设。对任务内工作可靠；
         asyncio 子任务与 ContextThreadPoolExecutor 会拷贝它。
      3. DEFAULT_USER_ID--最后兜底，让无认证的 CLI/迁移/测试路径不抛错。
    持久化用户态文件的工具（自定义 agent、记忆、uploads）必须调它，而非直接
    get_effective_user_id()，以受益于 setup_agent 已依赖的 runtime.context 通道。"""
    context = getattr(runtime, "context", None)
    if isinstance(context, dict):
        ctx_user_id = context.get("user_id")
        if ctx_user_id:
            return str(ctx_user_id)
    return get_effective_user_id()
```

> 注：`resolve_user_id`（哨兵三态解析，repository 消费侧）与本文件认证链路同源，完整实现见 `core/helix/runtime/user_context.py`。它把 `AUTO`/显式 `str`/显式 `None` 映射为"读 contextvar"/"用给定值"/"无 WHERE 子句"，是 SQL 仓库属主过滤的入口。

---

## 关键不变量与测试锚点

1. **fail-closed**：非公共路径无任何有效凭证一律 401；`is_auth_disabled()` 为 True 时才降级合成 admin（仅本地/E2E）。
2. **三凭证汇合**：内部 token 头（`AUTH_SOURCE_INTERNAL`）/ JWT cookie（`AUTH_SOURCE_SESSION`）/ auth-disabled（`AUTH_SOURCE_AUTH_DISABLED`）三者优先级固定（内部 token > cookie > disabled > 401），最终都盖到同一 contextvar。
3. **owner 头门控**：`get_trusted_internal_owner_user_id` 先验 `system_role == "internal"`，浏览器塞的 owner 头被忽略（跨切不变量 2 防冒充）。
4. **owner id 规范化**：`make_safe_user_id` 把 IM 通道 id 规范化到 `[A-Za-z0-9_-]` + SHA-256 摘要后缀，防路径穿越与碰撞。
5. **token_version 吊销**：JWT 的 `ver` 必须匹配 `User.token_version`，改密/登出递增即使所有旧 cookie 失效。
6. **常量时间比较**：`is_valid_internal_auth_token` 用 `secrets.compare_digest`，防时序侧信道。
7. **contextvar 恢复**：`set_current_user` / `reset_current_user` 配对在 `try/finally`，防跨请求泄漏。
8. **跨边界 user_id**：`resolve_runtime_user_id` 三级回退（runtime.context > contextvar > DEFAULT_USER_ID），后台工具不因 contextvar 丢失而落错桶。

> 关联：`[[auth]]`（CSRF Double-Submit Cookie、OAuth/OIDC、token_version 吊销深度）、`[[multi-user-isolation]]`（per-user 目录布局与 `_validate_user_id` 防穿越）、`cross-cutting-invariants.md` 不变量 2、`references/code/05-middleware-chain.md`（ThreadDataMiddleware 读 contextvar 建 per-user 目录）。
