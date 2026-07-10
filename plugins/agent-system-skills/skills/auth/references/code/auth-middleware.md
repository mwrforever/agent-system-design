# 完整源码：fail-closed 认证闸门 + contextvar 全链路传播

> 本文件给出认证闸门的**完整实现**：全局 `AuthMiddleware`（fail-closed + 三凭证汇合 + 写 `user_context`）、本地/E2E 的 auth-disabled 合成 admin（`auth_disabled.py`）、以及承载全链路 `user_id` 的 contextvar（`user_context.py`）。
>
> SKILL.md「完整真实代码实现」段给了入口片段与索引；此处补全完整源码与所有边界处理。
>
> 真实实现已按匿名化规则映射到中立结构（应用层 `gateway.gateway.*`、框架层 `helix.*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

## 1. AuthMiddleware（全局 fail-closed 闸门）

```python
# gateway/gateway/auth_middleware.py
"""全局认证中间件——fail-closed 安全网。

对非公共路径上的未认证请求返回 401。当请求通过 cookie 校验后，
把 JWT payload 解析成真实 ``User`` 对象，同时盖到 ``request.state.user``
和 ``helix.runtime.user_context`` contextvar 上，使仓储层的 owner
过滤能经由 sentinel 模式自动生效。

细粒度权限校验仍留在 authz.py 的装饰器里（认证≠授权）。
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

# 永不需要认证的路径前缀（公共路径白名单）。
_PUBLIC_PATH_PREFIXES: tuple[str, ...] = (
    "/health",
    "/docs",
    "/redoc",
    "/openapi.json",
    "/api/v1/auth/oauth/",
    "/api/v1/auth/callback/",
    # 入站 webhook 经 provider 专属签名自证身份（如 GitHub X-Hub-Signature-256），
    # 不走 session cookie。
    "/api/webhooks/",
)

# 精确匹配的公共 auth 路径（登录/注册/状态查询）。
# /api/v1/auth/me、/api/v1/auth/change-password 等**不**在此列（需认证）。
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

    非公共路径的两阶段校验：

    1. cookie 存在性——缺失返回 401 NOT_AUTHENTICATED
    2. 经 ``get_current_user_from_request`` 做 JWT 校验——token 缺失/畸形/过期，
       或签名用户不存在/已过期，返回 401 TOKEN_INVALID

    成功后盖 ``request.state.user`` 与 ``helix.runtime.user_context``
    contextvar，使仓储层 owner 过滤自动生效，无需每个路由挂 ``@require_auth``。
    需逐资源授权的路由（如"用户 A 不能靠猜 URL 读用户 B 的 thread"）应额外用
    ``@require_permission(..., owner_check=True)`` 显式强制——但认证本身在此全部完成。
    """

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        # 公共路径直接放行（health/docs/oauth 起步/callback/webhook 自证签名）。
        if _is_public(request.url.path):
            return await call_next(request)

        # —— 三凭证汇合：① 内部 token 头（scheduler/channels）——
        internal_user = None
        if is_valid_internal_auth_token(request.headers.get(INTERNAL_AUTH_HEADER_NAME)):
            # 从受信头里抽 channel owner user id。存在时，合成内部用户的 .id
            # 承载真实 owner 身份，使 get_effective_user_id() 与 per-user 文件路径
            # （自定义技能/记忆/thread 数据）落到 IM channel 用户，而非回退 "default"。
            from gateway.gateway.internal_auth import INTERNAL_OWNER_USER_ID_HEADER_NAME

            owner_user_id = request.headers.get(INTERNAL_OWNER_USER_ID_HEADER_NAME)
            if owner_user_id:
                owner_user_id = owner_user_id.strip()
            internal_user = get_internal_user(owner_user_id=owner_user_id or None)

        auth_source = AUTH_SOURCE_SESSION
        access_token = request.cookies.get("access_token")

        # 非公共路径：按优先级解析凭证。内部 token 优先于 cookie 优先于 auth-disabled。
        if internal_user is not None:
            user = internal_user
            auth_source = AUTH_SOURCE_INTERNAL
        elif access_token:
            # 严格 JWT 校验：畸形/过期 token 当场 401，而非静默放行。
            # 关闭"垃圾 cookie 绕过"漏洞（AUTH_TEST_PLAN test 7.5.8）：
            # 否则 /api/models 这类非隔离路由会把任意 cookie 形态字符串当认证。
            #
            # 调*严格*解析器，使细粒度错误码（token_expired / token_invalid /
            # user_not_found …）从 AuthErrorCode 透传，而非被压成一个泛化码。
            # BaseHTTPMiddleware 不让 HTTPException 上浮，故在此捕获并渲染成 JSONResponse。
            from gateway.gateway.deps import get_current_user_from_request

            try:
                user = await get_current_user_from_request(request)
            except HTTPException as exc:
                if not is_auth_disabled():
                    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
                # auth-disabled 模式下，即便 cookie 无效也降级为合成 admin（仅本地/E2E）。
                user = get_auth_disabled_user()
                auth_source = AUTH_SOURCE_AUTH_DISABLED
        elif is_auth_disabled():
            # 无 cookie 且 auth-disabled 开启：合成 admin（生产环境被硬性拒掉，见 auth_disabled.py）。
            user = get_auth_disabled_user()
            auth_source = AUTH_SOURCE_AUTH_DISABLED
        else:
            # fail-closed：三凭证皆无 -> 401。绝不允许"无凭证即匿名通过"。
            return JSONResponse(
                status_code=401,
                content={
                    "detail": AuthErrorResponse(
                        code=AuthErrorCode.NOT_AUTHENTICATED,
                        message="Authentication required",
                    ).model_dump()
                },
            )

        # 同时盖 request.state.user（供 contextvar 模式）与 request.state.auth
        # （使 @require_permission 的 "auth is None" 分支短路，免得每请求再跑一遍
        # JWT 解码 + DB 查找的整条流水线二次执行）。
        request.state.user = user
        request.state.auth_source = auth_source
        request.state.auth = AuthContext(user=user, permissions=_ALL_PERMISSIONS)
        # 写 contextvar：此后 ③–⑧ 全链路靠 get_effective_user_id() 读它定位 per-user 目录。
        token = set_current_user(user)
        try:
            return await call_next(request)
        finally:
            # 必须在 finally 复位：否则 contextvar 在 asyncio task 复用/中间件共享 task
            # 场景下会串到下一个请求的用户（跨请求串用户）。token 保证恢复到调用前状态。
            reset_current_user(token)
```

## 2. auth-disabled 合成 admin（本地/E2E 专用）

```python
# gateway/gateway/auth_disabled.py
"""本地/E2E auth-disabled 模式的共享辅助。

注意：auth-disabled 在显式声明的生产环境下被硬性拒绝（is_auth_disabled() 返回 False），
即使环境变量被误设为 1。这是 fail-closed 在"开发后门"上的延伸——后门不能开到生产。
"""

from __future__ import annotations

import logging
import os
from types import SimpleNamespace

from helix.runtime.user_context import DEFAULT_USER_ID

AUTH_DISABLED_ENV_VAR = "HELIX_AUTH_DISABLED"
AUTH_DISABLED_USER_ID = DEFAULT_USER_ID  # 合成 admin 落到 "default" 桶
AUTH_DISABLED_USER_EMAIL = "default@test.local"

# 认证来源标记——区分 session / internal / auth_disabled，供下游（如 change-password
# 禁用、non_interactive 接纳判定）按来源分流。
AUTH_SOURCE_SESSION = "session"
AUTH_SOURCE_INTERNAL = "internal"
AUTH_SOURCE_AUTH_DISABLED = "auth_disabled"

# 显式生产环境标识：任一命中即视为生产，auth-disabled 后门失效。
_PRODUCTION_ENV_VARS: tuple[str, ...] = ("HELIX_ENV", "ENVIRONMENT")
_PRODUCTION_ENV_VALUES: frozenset[str] = frozenset({"prod", "production"})

logger = logging.getLogger(__name__)


def is_explicit_production_environment() -> bool:
    return any(os.environ.get(name, "").strip().lower() in _PRODUCTION_ENV_VALUES for name in _PRODUCTION_ENV_VARS)


def is_auth_disabled_requested() -> bool:
    return os.environ.get(AUTH_DISABLED_ENV_VAR) == "1"


def is_auth_disabled() -> bool:
    # 双重门：必须显式请求 1 **且**当前不是显式生产环境。
    # 仅凭 env=1 在生产不开后门——防止误配把认证整条卸掉。
    return is_auth_disabled_requested() and not is_explicit_production_environment()


def warn_if_auth_disabled_enabled() -> None:
    if not is_auth_disabled():
        return

    logger.warning(
        "%s=1 is active: authentication is bypassed and anonymous requests run as synthetic admin user %r. Do not enable this in shared or production deployments.",
        AUTH_DISABLED_ENV_VAR,
        AUTH_DISABLED_USER_ID,
    )


def get_auth_disabled_user():
    # 合成 admin：system_role="admin" + token_version=0。
    # 结构上满足 CurrentUser 协议（有 .id: str），故可直接喂给 set_current_user。
    return SimpleNamespace(
        id=AUTH_DISABLED_USER_ID,
        email=AUTH_DISABLED_USER_EMAIL,
        password_hash=None,
        system_role="admin",
        needs_setup=False,
        token_version=0,
        oauth_provider=None,
    )
```

## 3. user_context contextvar（框架层，全链路 user_id 载体）

```python
# core/helix/runtime/user_context.py
"""请求级用户上下文，用于基于用户的授权。

本模块持有一个 :class:`~contextvars.ContextVar`，由 gateway 的 auth
中间件在认证成功后设置。仓储方法经 sentinel 默认参数读 contextvar，
使路由免于 ``user_id`` 样板代码。

仓储 ``user_id`` 参数的三态语义（消费侧在 ``helix.persistence.*``）：

- ``_AUTO``（模块私有 sentinel，默认）：从 contextvar 读；未设置则抛
  :class:`RuntimeError`。
- 显式 ``str``：用给定值，覆盖 contextvar。
- 显式 ``None``：不加 WHERE 子句——仅迁移脚本与管理 CLI 故意绕过隔离时用。

依赖方向
--------------------
``persistence``（下层）读本模块；``gateway.auth``（上层）写本模块。
``CurrentUser`` 在此定义为 :class:`typing.Protocol`，使 ``persistence``
无需从 ``gateway.auth.models`` 导入具体 ``User`` 类。任何带 ``.id: str``
属性的对象结构上即满足该协议。

asyncio 语义
-----------------
``ContextVar`` 在 asyncio 下是 task-local，而非 thread-local。每个 FastAPI
请求跑在各自 task 里，故上下文天然隔离。``asyncio.create_task`` 与
``asyncio.to_thread`` 继承父 task 的上下文，通常即预期行为；若后台任务
**不应**看到前台用户，用 ``contextvars.copy_context()`` 取一份干净副本。
"""

from __future__ import annotations

from contextvars import ContextVar, Token
from typing import Final, Protocol, runtime_checkable


@runtime_checkable
class CurrentUser(Protocol):
    """当前已认证用户的结构类型。

    任何带 ``.id: str`` 属性的对象即满足此协议。
    具体实现位于 ``gateway.gateway.auth.models.User``。
    """

    id: str


# contextvar 名为 helix_current_user：框架层中性命名。
# 中间件写、仓储/工具读——这是 user_id 全链路传播的唯一信道。
_current_user: Final[ContextVar[CurrentUser | None]] = ContextVar("helix_current_user", default=None)


def set_current_user(user: CurrentUser) -> Token[CurrentUser | None]:
    """为本 async task 设置当前用户。

    返回 reset token，应在 ``finally`` 块里传给 :func:`reset_current_user`
    以恢复先前上下文。
    """
    return _current_user.set(user)


def reset_current_user(token: Token[CurrentUser | None]) -> None:
    """把上下文恢复到 ``token`` 捕获时的状态。"""
    _current_user.reset(token)


def get_current_user() -> CurrentUser | None:
    """返回当前用户，未设置则 ``None``。

    任意上下文均可安全调用。用于可无用户进行的路径（迁移脚本、公共端点）。
    """
    return _current_user.get()


def require_current_user() -> CurrentUser:
    """返回当前用户，否则抛 :class:`RuntimeError`。

    供**必须**在请求认证上下文之外不得调用的仓储代码使用。错误信息措辞
    便于调用方据堆栈定位违规代码路径。
    """
    user = _current_user.get()
    if user is None:
        raise RuntimeError("repository accessed without user context")
    return user


# ---------------------------------------------------------------------------
# Effective user_id 辅助（文件系统隔离）
# ---------------------------------------------------------------------------

DEFAULT_USER_ID: Final[str] = "default"


def get_effective_user_id() -> str:
    """返回当前用户 id 字符串，未设置则回退 DEFAULT_USER_ID。

    与 :func:`require_current_user` 不同，此函数永不抛——专为文件系统路径
    解析设计，那里始终需要一个合法的 user 桶。
    """
    user = _current_user.get()
    if user is None:
        return DEFAULT_USER_ID
    return str(user.id)


def resolve_runtime_user_id(runtime: object | None) -> str:
    """工具/中间件有效 user_id 的唯一真源。

    解析顺序（权威性从高到低）：
      1. ``runtime.context["user_id"]``——由 gateway 的
         ``inject_authenticated_user_context`` 从 auth 校验过的
         ``request.state.user`` 注入。这是唯一能在 contextvar 可能丢失的
         边界（请求 task 之外调度的后台任务、不 copy_context 的 worker 池、
         未来跨进程驱动）存活下来的来源。
      2. ``_current_user`` ContextVar——由 auth 中间件在请求入口设置。
         对 task 内工作可靠；被 ``asyncio`` 子任务与
         ``ContextThreadPoolExecutor`` 复制。
      3. ``DEFAULT_USER_ID``——最后兜底，使未认证的 CLI/迁移/测试路径不抛错。

    持久化用户作用域状态（自定义 agent、记忆、上传）的工具**必须**调本函数
    而非直接 ``get_effective_user_id()``，以享受 ``setup_agent`` 已依赖的
    runtime.context 信道。
    """
    context = getattr(runtime, "context", None)
    if isinstance(context, dict):
        ctx_user_id = context.get("user_id")
        if ctx_user_id:
            return str(ctx_user_id)
    return get_effective_user_id()


# ---------------------------------------------------------------------------
# 基于 sentinel 的 user_id 解析
# ---------------------------------------------------------------------------
#
# 仓储方法接受 ``user_id`` keyword-only 参数，默认 ``AUTO``。
# 三种取值驱动不同行为；见 :func:`resolve_user_id` 文档。


class _AutoSentinel:
    """单例标记，意为"从 contextvar 解析 user_id"。"""

    _instance: _AutoSentinel | None = None

    def __new__(cls) -> _AutoSentinel:
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:
        return "<AUTO>"


AUTO: Final[_AutoSentinel] = _AutoSentinel()


def resolve_user_id(
    value: str | None | _AutoSentinel,
    *,
    method_name: str = "repository method",
) -> str | None:
    """解析传给仓储方法的 user_id 参数。

    三态语义：

    - :data:`AUTO`（默认）：从 contextvar 读；无用户上下文则抛
      :class:`RuntimeError`。请求级调用的常见情形。
    - 显式 ``str``：原样使用，覆盖任何 contextvar 值。用于测试与管理覆盖流。
    - 显式 ``None``：不过滤——仓储应跳过 user_id WHERE 子句。仅迁移脚本
      与 CLI 工具故意绕过隔离时保留。
    """
    if isinstance(value, _AutoSentinel):
        user = _current_user.get()
        if user is None:
            raise RuntimeError(f"{method_name} called with user_id=AUTO but no user context is set; pass an explicit user_id, set the contextvar via auth middleware, or opt out with user_id=None for migration/CLI paths.")
        # 在边界处强制 ``str``：``User.id`` 对 API 面类型化为 ``UUID``，
        # 但持久化层把 ``user_id`` 存为 ``String(64)``，aiosqlite 无法把
        # 原始 UUID 对象绑定到 VARCHAR 列（"type 'UUID' is not supported"）。
        # 在此遵循文档化的返回类型，而非把类型变更波及每个调用方。
        return str(user.id)
    return value
```

> 三个文件串成「闸门 → 合成用户 → contextvar」一条线：`AuthMiddleware` 按三凭证优先级解析出 `user`，盖到 `request.state` 与 `user_context` contextvar，下游 ③–⑧ 全靠 `get_effective_user_id()` / `resolve_runtime_user_id()` 读它定位 per-user 目录。`auth_disabled` 是受生产环境硬门保护的本地后门。`user_context` 故意定义在框架层（`core/helix/runtime/`），用 `Protocol` 解耦，使框架层无需 import 应用层 `User` 类——这是 [[core-app-boundary]] 单向依赖在认证侧的落点。
