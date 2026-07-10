# 完整源码：JWT cookie + 进程内内部 token + token_version 吊销 + OAuth/OIDC

> 本文件给出三层认证中**凭证解析与签发**的完整实现：JWT 创建/解析（`jwt.py`）、进程内内部 token（`internal_auth.py`）、token_version 吊销闭环（`deps.py` 严格解析器 + `auth.py` 改密 bump）、以及第三层 OAuth/OIDC（`oidc.py` + `oidc_state.py` + `local_provider.py`）。
>
> SKILL.md「完整真实代码实现」段给了入口片段与索引；此处补全完整源码。
>
> 真实实现已按匿名化规则映射到中立结构（应用层 `gateway.gateway.*`、框架层 `helix.*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

## 0. JWT 配置基座（密钥与 TTL 旋钮）

```python
# gateway/gateway/auth/config.py
"""Helix gateway 的认证配置。"""

import logging
import os
import secrets

from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

_SECRET_FILE = ".jwt_secret"


class AuthConfig(BaseModel):
    """JWT 与认证相关配置。启动期解析一次。

    注意：``users`` 表现位于由 ``helix.persistence.engine`` 管理的共享持久化
    数据库。旧的 ``users_db_path`` 配置键已移除--用户存储像其他表一样经
    ``config.database`` 配置。
    """

    jwt_secret: str = Field(
        ...,
        description="Secret key for JWT signing. MUST be set via AUTH_JWT_SECRET.",
    )
    # token TTL 旋钮：1–30 天，默认 7。改密时旧 token 因 ver 不匹配被吊销，
    # 故 TTL 不必过短；但过长会放大泄露窗口。
    token_expiry_days: int = Field(default=7, ge=1, le=30)
    oauth_github_client_id: str | None = Field(default=None)
    oauth_github_client_secret: str | None = Field(default=None)


_auth_config: AuthConfig | None = None


def _load_or_create_secret() -> str:
    """从 ``{base_dir}/.jwt_secret`` 加载已持久化的 JWT 密钥，否则生成并持久化新密钥。"""
    from helix.config.paths import get_paths

    paths = get_paths()
    secret_file = paths.base_dir / _SECRET_FILE

    try:
        if secret_file.exists():
            secret = secret_file.read_text(encoding="utf-8").strip()
            if secret:
                return secret
    except OSError as exc:
        raise RuntimeError(f"Failed to read JWT secret from {secret_file}. Set AUTH_JWT_SECRET explicitly or fix HELIX_HOME/base directory permissions so the gateway can read its persisted auth secret.") from exc

    # 首启无密钥：生成并 0600 持久化，使会话跨重启存活。
    secret = secrets.token_urlsafe(32)
    try:
        secret_file.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(secret_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(secret)
    except OSError as exc:
        raise RuntimeError(f"Failed to persist JWT secret to {secret_file}. Set AUTH_JWT_SECRET explicitly or fix HELIX_HOME/base directory permissions so the gateway can store a stable auth secret.") from exc
    return secret


def get_auth_config() -> AuthConfig:
    """取全局 AuthConfig 实例。首次调用时从 env 解析。"""
    global _auth_config
    if _auth_config is None:
        from dotenv import load_dotenv

        load_dotenv()
        jwt_secret = os.environ.get("AUTH_JWT_SECRET")
        if not jwt_secret:
            # 未显式配密钥：自动生成并持久化，会话跨重启存活，但生产应显式设 AUTH_JWT_SECRET。
            jwt_secret = _load_or_create_secret()
            os.environ["AUTH_JWT_SECRET"] = jwt_secret
            logger.warning(
                "⚠ AUTH_JWT_SECRET is not set - using an auto-generated secret "
                "persisted to .jwt_secret. Sessions will survive restarts. "
                "For production, add AUTH_JWT_SECRET to your .env file: "
                'python -c "import secrets; print(secrets.token_urlsafe(32))"'
            )
        _auth_config = AuthConfig(jwt_secret=jwt_secret)
    return _auth_config


def set_auth_config(config: AuthConfig) -> None:
    """设置全局 AuthConfig 实例（测试用）。"""
    global _auth_config
    _auth_config = config
```

## 1. JWT 创建与解析（HttpOnly cookie 载荷）

```python
# gateway/gateway/auth/jwt.py
"""JWT token 创建与校验。"""

from datetime import UTC, datetime, timedelta

import jwt
from pydantic import BaseModel

from gateway.gateway.auth.config import get_auth_config
from gateway.gateway.auth.errors import TokenError


class TokenPayload(BaseModel):
    """JWT token 载荷。"""

    sub: str  # user_id
    exp: datetime
    iat: datetime | None = None
    ver: int = 0  # token_version--必须与 User.token_version 一致，否则视为已吊销


def create_access_token(user_id: str, expires_delta: timedelta | None = None, token_version: int = 0) -> str:
    """创建 JWT access token。

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
    # ver 字段是吊销锚点：改密时 User.token_version += 1，旧 token 的 ver 失配即被拒。
    payload = {"sub": user_id, "exp": now + expiry, "iat": now, "ver": token_version}
    return jwt.encode(payload, config.jwt_secret, algorithm="HS256")


def decode_token(token: str) -> TokenPayload | TokenError:
    """解码并校验 JWT token。

    Returns:
        合法则 TokenPayload，否则返回具体 TokenError 变体（不抛异常）。
        细粒度变体由调用方映射成 AuthErrorCode，使前端能区分过期 vs 畸形 vs 签名错。
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

```python
# gateway/gateway/auth/errors.py
"""auth 模块的类型化错误定义。

AuthErrorCode：所有认证失败条件的穷举枚举。
TokenError：JWT 解码失败的穷举枚举。
AuthErrorResponse：HTTP 响应的结构化载荷。
"""

from enum import StrEnum

from pydantic import BaseModel


class AuthErrorCode(StrEnum):
    """认证错误条件的穷举列表。"""

    INVALID_CREDENTIALS = "invalid_credentials"
    TOKEN_EXPIRED = "token_expired"
    TOKEN_INVALID = "token_invalid"
    USER_NOT_FOUND = "user_not_found"
    EMAIL_ALREADY_EXISTS = "email_already_exists"
    PROVIDER_NOT_FOUND = "provider_not_found"
    NOT_AUTHENTICATED = "not_authenticated"
    SYSTEM_ALREADY_INITIALIZED = "system_already_initialized"


class TokenError(StrEnum):
    """JWT 解码失败原因的穷举列表。"""

    EXPIRED = "expired"
    INVALID_SIGNATURE = "invalid_signature"
    MALFORMED = "malformed"


class AuthErrorResponse(BaseModel):
    """结构化错误响应--替代裸 `detail` 字符串。"""

    code: AuthErrorCode
    message: str


def token_error_to_code(err: TokenError) -> AuthErrorCode:
    """TokenError -> AuthErrorCode 的唯一真源。"""
    if err == TokenError.EXPIRED:
        return AuthErrorCode.TOKEN_EXPIRED
    return AuthErrorCode.TOKEN_INVALID
```

## 2. 严格解析器 + token_version 吊销闭环

`AuthMiddleware` 调用的严格解析器在此。它把 `decode_token` 的 `TokenError` 映射成带细粒度码的 `HTTPException`，并执行 **token_version 吊销**：JWT 里的 `ver` 必须等于库中 `User.token_version`，改密后版本号 +1，旧 token 即失配被拒。

```python
# gateway/gateway/deps.py（节选：get_current_user_from_request）
async def get_current_user_from_request(request: Request):
    """从请求 cookie 取当前已认证用户。

    未认证则抛 HTTPException 401。这是 AuthMiddleware 在 cookie 分支调用的
    *严格*解析器--畸形/过期 token 当场 401，而非静默放行。
    """
    state = getattr(request, "state", None)
    state_user = getattr(state, "user", None)
    from gateway.gateway.auth_disabled import AUTH_SOURCE_AUTH_DISABLED, AUTH_SOURCE_INTERNAL, AUTH_SOURCE_SESSION

    # 中间件已盖过 user（三来源之一）-> 直接复用，免得二次解码 + DB 查找。
    if state_user is not None and getattr(state, "auth_source", None) in {
        AUTH_SOURCE_SESSION,
        AUTH_SOURCE_AUTH_DISABLED,
        AUTH_SOURCE_INTERNAL,
    }:
        return state_user

    from gateway.gateway.auth import decode_token
    from gateway.gateway.auth.errors import AuthErrorCode, AuthErrorResponse, TokenError, token_error_to_code

    access_token = request.cookies.get("access_token")
    if not access_token:
        raise HTTPException(
            status_code=401,
            detail=AuthErrorResponse(code=AuthErrorCode.NOT_AUTHENTICATED, message="Not authenticated").model_dump(),
        )

    payload = decode_token(access_token)
    if isinstance(payload, TokenError):
        # 细粒度码透传：前端能区分"过期请重登" vs "token 畸形/被篡改"。
        raise HTTPException(
            status_code=401,
            detail=AuthErrorResponse(code=token_error_to_code(payload), message=f"Token error: {payload.value}").model_dump(),
        )

    provider = get_local_provider()
    user = await provider.get_user(payload.sub)
    if user is None:
        raise HTTPException(
            status_code=401,
            detail=AuthErrorResponse(code=AuthErrorCode.USER_NOT_FOUND, message="User not found").model_dump(),
        )

    # token_version 吊销：ver 不匹配 -> 已改密，旧 token 失效。
    # 这是"改密即全局登出所有旧会话"的实现：无需维护 token 黑名单，单比较即可。
    if user.token_version != payload.ver:
        raise HTTPException(
            status_code=401,
            detail=AuthErrorResponse(code=AuthErrorCode.TOKEN_INVALID, message="Token revoked (password changed)").model_dump(),
        )

    return user


async def get_optional_user_from_request(request: Request):
    """取可选已认证用户。未认证返回 None。"""
    try:
        return await get_current_user_from_request(request)
    except HTTPException:
        return None
```

**改密 bump 版本（吊销的另一半）**--改密时 `token_version += 1` 并重发 cookie，旧 token 立即失配：

```python
# gateway/gateway/routers/auth.py（节选：change-password 的吊销闭环）
# 前置：已校验当前密码、新邮箱唯一性。下面是密码更新 + 版本 bump 段：

    # 更新密码 + bump 版本号：所有持有旧 ver 的 token 在下一次请求被 401 拒掉。
    user.password_hash = await hash_password_async(body.new_password)
    user.token_version += 1

    # 若是 setup 流程，清掉 needs_setup 标记
    if user.needs_setup and body.new_email is not None:
        user.needs_setup = False

    await provider.update_user(user)

    # 用新 token_version 重发 cookie--本会话续上，其余会话被吊销。
    token = create_access_token(str(user.id), token_version=user.token_version)
    _set_session_cookie(response, token, request)

    return MessageResponse(message="Password changed successfully")
```

```python
# gateway/gateway/routers/auth.py（节选：session cookie 设置）
def _set_session_cookie(response: Response, token: str, request: Request) -> None:
    """在响应上设置 access_token HttpOnly cookie。"""
    config = get_auth_config()
    is_https = is_secure_request(request)
    response.set_cookie(
        key="access_token",
        value=token,
        httponly=True,          # JS 不可读--防 XSS 偷 token
        secure=is_https,        # 仅 HTTPS 传输（本地 http 降级）
        samesite="lax",         # 防 CSRF（跨站 POST 不带 cookie）；与 CSRF 双提交正交
        max_age=config.token_expiry_days * 24 * 3600 if is_https else None,
    )
```

## 3. 进程内内部 token（scheduler/channels -> Gateway）

```python
# gateway/gateway/internal_auth.py
"""受信 Gateway 内部调用者的认证。"""

from __future__ import annotations

import os
import secrets
from types import SimpleNamespace
from typing import Any

from helix.config.paths import make_safe_user_id
from helix.runtime.user_context import DEFAULT_USER_ID

# 进程内内部认证头--绝不能出现在浏览器/外部客户端请求里。
INTERNAL_AUTH_HEADER_NAME = "X-Helix-Internal-Token"
# owner 覆盖头：仅内部 token 校验通过后生效，把 per-user 目录指向 IM channel 用户。
INTERNAL_OWNER_USER_ID_HEADER_NAME = "X-Helix-Owner-User-Id"
INTERNAL_AUTH_ENV_VAR = "HELIX_INTERNAL_AUTH_TOKEN"
INTERNAL_SYSTEM_ROLE = "internal"


def _load_internal_auth_token() -> str:
    # 进程级共享密钥：env 显式配，否则每进程随机生成（多 worker 部署必须显式配，
    # 否则各 worker token 不同，内部调用跨 worker 失败）。
    token = os.environ.get(INTERNAL_AUTH_ENV_VAR)
    if token:
        return token
    return secrets.token_urlsafe(32)


_INTERNAL_AUTH_TOKEN = _load_internal_auth_token()


def create_internal_auth_headers(*, owner_user_id: str | None = None) -> dict[str, str]:
    """返回认证受信 Gateway 内部调用所需的 headers。"""
    headers = {INTERNAL_AUTH_HEADER_NAME: _INTERNAL_AUTH_TOKEN}
    if owner_user_id:
        headers[INTERNAL_OWNER_USER_ID_HEADER_NAME] = owner_user_id
    return headers


def is_valid_internal_auth_token(token: str | None) -> bool:
    """token 与本 Gateway worker 的内部 token 匹配则 True。

    用 secrets.compare_digest 常时比较，防计时侧信道。
    """
    return bool(token) and secrets.compare_digest(token, _INTERNAL_AUTH_TOKEN)


def get_internal_user(owner_user_id: str | None = None):
    """返回受信内部 channel 调用用的合成用户。

    提供 *owner_user_id*（从 ``X-Helix-Owner-User-Id`` 头抽取）时，合成用户的
    ``.id`` 承载真实 channel owner 而非 ``DEFAULT_USER_ID``。这保证
    ``get_effective_user_id()`` 与下游文件路径解析（per-user 自定义技能、记忆、
    thread 数据）对 IM channel 消息用对身份，而非回退 ``"default"``。

    owner id 经 :func:`make_safe_user_id` 规范化，使含 ``[A-Za-z0-9_-]`` 之外
    字符的 IM channel id（如带下划线可能被系统当路径分隔的飞书 ``open_id``，
    或 ``-1001234567890`` 这类 Telegram chat id）无法逃出 per-user 存储桶或
    经 header 值把戏（尾斜杠、``..`` 段）冒充别的用户。规范化有损但确定：
    两个不同原始输入永不共享同一 safe id，故跨用户泄漏不可能。
    """
    if owner_user_id:
        effective_id = make_safe_user_id(owner_user_id)
    else:
        effective_id = DEFAULT_USER_ID
    return SimpleNamespace(id=effective_id, system_role=INTERNAL_SYSTEM_ROLE)


def get_trusted_internal_owner_user_id(request: Any) -> str | None:
    """若存在，返回受信内部请求的 owner 覆盖值。

    普通浏览器/API 调用者的该头被忽略。仅当 ``AuthMiddleware`` 已校验内部
    auth token 并把合成内部用户盖到 ``request.state.user`` 后才生效。
    """
    user = getattr(getattr(request, "state", None), "user", None)
    if getattr(user, "system_role", None) != INTERNAL_SYSTEM_ROLE:
        return None  # 非内部调用者：owner 头一律无视，防浏览器伪造 owner

    owner_user_id = request.headers.get(INTERNAL_OWNER_USER_ID_HEADER_NAME)
    if not owner_user_id:
        return None
    owner_user_id = owner_user_id.strip()
    return owner_user_id or None
```

## 4. OAuth/OIDC 第三层（签发 cookie JWT 的外部身份源）

OIDC 不在每请求闸门里--它在前端发起的 `/api/v1/auth/oauth/{provider}` 重定向流里跑完，回调 `/api/v1/auth/callback/{provider}` 校验 state/nonce、换码、校验 ID token、落库或匹配既有用户，最后**签发与本地登录同款的 cookie JWT**。此后请求仍走 `AuthMiddleware` 的 cookie 分支。换言之：OAuth 只是"凭证怎么来"的第三条路，闸门仍是同一个。

```python
# gateway/gateway/auth/oidc.py
"""OIDC（OpenID Connect）认证服务。

提供 provider 无关的 OIDC 操作：discovery、授权 URL 生成、token 交换、
ID token 校验、userinfo 获取。
"""

from __future__ import annotations

import logging
import secrets
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode

import httpx
import jwt
from jwt import PyJWK

logger = logging.getLogger(__name__)

# ── 数据类型 ────────────────────────────────────────────────────────────

OIDC_DISCOVERY_PATH = "/.well-known/openid-configuration"
METADATA_CACHE_TTL = 300  # 5 分钟
JWKS_CACHE_TTL = 300


@dataclass(frozen=True)
class OIDCMetadata:
    """discovery 后解析出的 OIDC provider 元数据。"""

    issuer: str
    authorization_endpoint: str
    token_endpoint: str
    userinfo_endpoint: str | None
    jwks_uri: str


@dataclass(frozen=True)
class OIDCIdentity:
    """从 OIDC provider 响应抽取的归一化身份。"""

    provider: str
    subject: str
    email: str
    email_verified: bool
    name: str | None
    claims: dict[str, Any]


class OIDCError(Exception):
    """OIDC 操作的基错。message 对 API 响应安全。"""


class OIDCProviderError(OIDCError):
    """OIDC provider 返回错误（如 access_denied）。"""


class OIDCValidationError(OIDCError):
    """ID token 校验失败。"""


class OIDCUserInfoMismatch(OIDCError):
    """UserInfo 的 sub 与 ID token 的 sub 不匹配。"""


# ── 服务 ────────────────────────────────────────────────────────────────


class OIDCService:
    """OIDC 认证服务。

    用进程内缓存存 provider 元数据与 JWKS。缓存按 provider 的 ``issuer``
    作 key--不同 provider 各自独立条目。TTL 经构造参数可配。
    """

    def __init__(
        self,
        metadata_cache_ttl: float = METADATA_CACHE_TTL,
        jwks_cache_ttl: float = JWKS_CACHE_TTL,
    ) -> None:
        self._metadata_cache: dict[str, tuple[float, dict[str, Any]]] = {}
        self._jwks_cache: dict[str, tuple[float, dict[str, Any]]] = {}
        self._metadata_ttl = metadata_cache_ttl
        self._jwks_ttl = jwks_cache_ttl
        self._http = httpx.AsyncClient(timeout=httpx.Timeout(15.0))

    async def close(self) -> None:
        """关闭底层 HTTP 客户端。"""
        await self._http.aclose()

    # ── Discovery ──────────────────────────────────────────────────────────

    async def discover(self, issuer: str, overrides: dict[str, str | None] | None = None) -> OIDCMetadata:
        """从 issuer 拉取并缓存 OIDC discovery 元数据。

        ``overrides`` 可含覆盖 discovery 值的端点 URI（如非标准端点的 provider）。
        """
        now = time.time()
        cached = self._metadata_cache.get(issuer)
        if cached and now - cached[0] < self._metadata_ttl:
            return self._metadata_from_dict(cached[1], overrides)

        discovery_url = issuer.rstrip("/") + OIDC_DISCOVERY_PATH
        try:
            resp = await self._http.get(discovery_url)
            resp.raise_for_status()
            data: dict[str, Any] = resp.json()
        except httpx.HTTPStatusError as exc:
            raise OIDCError(f"OIDC discovery failed for issuer {issuer}: HTTP {exc.response.status_code}") from exc
        except httpx.RequestError as exc:
            raise OIDCError(f"OIDC discovery failed for issuer {issuer}: {exc}") from exc

        discovered_issuer = data.get("issuer")
        if not discovered_issuer:
            raise OIDCError(f"OIDC discovery response from {issuer} is missing the issuer field")

        # RFC 8414 §4：discovery 的 issuer 必须等于配置的 issuer。
        # 钉死它，防被篡改/流氓 discovery 文档把接受的 `iss`（进而 ID-token
        # 伪造面）导向攻击者选定的值。
        if discovered_issuer.rstrip("/") != issuer.rstrip("/"):
            raise OIDCError(f"OIDC discovered issuer '{discovered_issuer}' does not match configured issuer '{issuer}'")

        self._metadata_cache[issuer] = (now, data)
        return self._metadata_from_dict(data, overrides)

    def _metadata_from_dict(self, data: dict[str, Any], overrides: dict[str, str | None] | None) -> OIDCMetadata:
        """从 discovery dict 构建 OIDCMetadata，应用端点覆盖。"""
        overrides = overrides or {}
        return OIDCMetadata(
            issuer=data["issuer"],
            authorization_endpoint=overrides.get("authorization_endpoint") or data["authorization_endpoint"],
            token_endpoint=overrides.get("token_endpoint") or data["token_endpoint"],
            userinfo_endpoint=overrides.get("userinfo_endpoint") or data.get("userinfo_endpoint"),
            jwks_uri=overrides.get("jwks_uri") or data["jwks_uri"],
        )

    # ── 授权 URL ──────────────────────────────────────────────────────────

    def build_authorization_url(
        self,
        metadata: OIDCMetadata,
        client_id: str,
        redirect_uri: str,
        scopes: list[str],
        state: str,
        nonce: str | None = None,
        code_challenge: str | None = None,
    ) -> str:
        """为 provider 构建 OIDC 授权 URL。

        返回浏览器应重定向到的 URL。
        """
        params: dict[str, str] = {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "scope": " ".join(scopes),
            "state": state,
        }
        if nonce:
            params["nonce"] = nonce
        if code_challenge:
            params["code_challenge"] = code_challenge
            params["code_challenge_method"] = "S256"

        return f"{metadata.authorization_endpoint}?{urlencode(params)}"

    # ── Token 交换 ─────────────────────────────────────────────────────────

    async def exchange_code(
        self,
        metadata: OIDCMetadata,
        client_id: str,
        client_secret: str | None,
        code: str,
        redirect_uri: str,
        code_verifier: str | None = None,
        auth_method: str = "client_secret_post",
    ) -> dict[str, Any]:
        """在 token 端点用授权码换 token。"""
        data: dict[str, str] = {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri,
            "client_id": client_id,
        }
        if code_verifier:
            data["code_verifier"] = code_verifier

        headers: dict[str, str] = {"Accept": "application/json"}

        if auth_method == "client_secret_basic" and client_secret:
            import base64

            creds = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode("ascii")
            headers["Authorization"] = f"Basic {creds}"
        elif auth_method == "client_secret_post" and client_secret:
            data["client_secret"] = client_secret

        try:
            resp = await self._http.post(metadata.token_endpoint, data=data, headers=headers)
            resp.raise_for_status()
            return resp.json()
        except httpx.HTTPStatusError as exc:
            body = "unknown"
            try:
                body = exc.response.text[:200]
            except Exception:
                pass
            raise OIDCError(f"Token exchange failed: HTTP {exc.response.status_code} - {body}") from exc
        except httpx.RequestError as exc:
            raise OIDCError(f"Token exchange failed: {exc}") from exc

    # ── JWKS 加载 ───────────────────────────────────────────────────────

    async def _load_jwks(self, jwks_uri: str, force_refresh: bool = False) -> dict[str, Any]:
        """从 provider 加载（并缓存）JWKS。

        设 ``force_refresh=True`` 绕过缓存（如 kid 未命中时）。
        """
        now = time.time()
        cached = self._jwks_cache.get(jwks_uri)
        if not force_refresh and cached and now - cached[0] < self._jwks_ttl:
            return cached[1]

        try:
            resp = await self._http.get(jwks_uri)
            resp.raise_for_status()
            data: dict[str, Any] = resp.json()
        except httpx.HTTPStatusError as exc:
            raise OIDCError(f"JWKS fetch failed: HTTP {exc.response.status_code}") from exc
        except httpx.RequestError as exc:
            raise OIDCError(f"JWKS fetch failed: {exc}") from exc

        self._jwks_cache[jwks_uri] = (now, data)
        return data

    async def _resolve_signing_key(
        self,
        jwks_data: dict[str, Any],
        kid: str | None,
        algorithm: str,
        jwks_uri: str,
    ) -> Any | None:
        """在 JWKS 里找匹配 ``kid`` 的签名 key。

        找到返回 key 对象，否则 None。捕获非法 JWK 条目（如算法 key 类型错）
        并告警，使单条坏条目不致让整个校验崩。
        """
        for jwk_dict in jwks_data.get("keys", []):
            if kid and jwk_dict.get("kid") != kid:
                continue
            try:
                jwk = PyJWK(jwk_dict, algorithm=algorithm)
                return jwk.key
            except jwt.PyJWTError as exc:
                logger.warning("Skipping invalid JWK (kid=%s) from %s: %s", kid, jwks_uri, exc)
                if not kid:
                    # token 无 kid--试下一个 key
                    continue
                # 指定了 kid 且这就是那条--立即失败
                raise OIDCValidationError(f"JWK for kid={kid} is invalid: {exc}") from exc
        return None

    # ── ID token 校验 ────────────────────────────────────────────────────────

    async def validate_id_token(
        self,
        metadata: OIDCMetadata,
        client_id: str,
        id_token: str,
        nonce: str | None = None,
    ) -> dict[str, Any]:
        """校验 ID token 并返回其 claims。

        校验项：签名（经 JWKS）、issuer、audience、过期、签发时间、nonce（若有）。
        """
        jwks_data = await self._load_jwks(metadata.jwks_uri)

        # 从 token 的 kid 头解析签名 key
        jwt_header = jwt.get_unverified_header(id_token)
        kid = jwt_header.get("kid")
        alg = jwt_header.get("alg", "RS256")

        allowed_algorithms = ["RS256", "RS384", "RS512", "ES256", "ES384", "ES512"]
        if alg not in allowed_algorithms:
            raise OIDCValidationError(f"ID token uses unsupported algorithm '{alg}'")

        # 解析签名 key，kid 未命中时刷一次 JWKS 以应对 key 轮换
        signing_key = await self._resolve_signing_key(jwks_data, kid, alg, metadata.jwks_uri)
        if signing_key is None:
            jwks_data = await self._load_jwks(metadata.jwks_uri, force_refresh=True)
            signing_key = await self._resolve_signing_key(jwks_data, kid, alg, metadata.jwks_uri)
            if signing_key is None:
                raise OIDCValidationError(f"No matching JWK found for kid={kid} after JWKS refresh")

        try:
            claims = jwt.decode(
                id_token,
                key=signing_key,
                algorithms=allowed_algorithms,
                audience=client_id,
                issuer=metadata.issuer,
                options={
                    "verify_exp": True,
                    "verify_iat": True,
                    "require": ["exp", "iss", "sub", "aud"],
                },
            )
        except jwt.ExpiredSignatureError:
            raise OIDCValidationError("ID token has expired")
        except jwt.InvalidIssuerError:
            raise OIDCValidationError("ID token has an invalid issuer")
        except jwt.InvalidAudienceError:
            raise OIDCValidationError("ID token has an invalid audience")
        except jwt.PyJWTError as exc:
            raise OIDCValidationError(f"ID token validation failed: {exc}") from exc

        # 校验 nonce（防重放）：与授权时发出的 nonce 常时比较
        if nonce is not None:
            token_nonce = claims.get("nonce")
            if not token_nonce:
                raise OIDCValidationError("ID token is missing the nonce claim")
            if not _constant_time_compare(nonce, token_nonce):
                raise OIDCValidationError("ID token nonce does not match")

        return claims

    # ── UserInfo ────────────────────────────────────────────────────────────

    async def fetch_userinfo(self, metadata: OIDCMetadata, access_token: str, expected_sub: str) -> dict[str, Any]:
        """从 UserInfo 端点取 userinfo。

        校验 ``sub`` 与 ``expected_sub``（来自 ID token）匹配，防 userinfo 注入。
        """
        if not metadata.userinfo_endpoint:
            return {}

        headers = {"Authorization": f"Bearer {access_token}"}
        try:
            resp = await self._http.get(metadata.userinfo_endpoint, headers=headers)
            resp.raise_for_status()
            userinfo: dict[str, Any] = resp.json()
        except httpx.HTTPStatusError as exc:
            raise OIDCError(f"UserInfo fetch failed: HTTP {exc.response.status_code}") from exc
        except httpx.RequestError as exc:
            raise OIDCError(f"UserInfo fetch failed: {exc}") from exc

        if userinfo.get("sub") and userinfo["sub"] != expected_sub:
            raise OIDCUserInfoMismatch("UserInfo sub does not match ID token sub")

        return userinfo

    # ── 编排好的回调 ──────────────────────────────────────────────────────

    async def authenticate_callback(
        self,
        provider_id: str,
        metadata: OIDCMetadata,
        client_id: str,
        client_secret: str | None,
        code: str,
        redirect_uri: str,
        code_verifier: str | None = None,
        nonce: str | None = None,
        auth_method: str = "client_secret_post",
    ) -> OIDCIdentity:
        """编排完整 OIDC 回调：token 交换、ID token 校验、userinfo。

        返回归一化的 ``OIDCIdentity``。
        """
        token_response = await self.exchange_code(
            metadata=metadata,
            client_id=client_id,
            client_secret=client_secret,
            code=code,
            redirect_uri=redirect_uri,
            code_verifier=code_verifier,
            auth_method=auth_method,
        )

        id_token = token_response.get("id_token")
        if not id_token:
            raise OIDCError("Token response is missing id_token")

        access_token = token_response.get("access_token", "")

        claims = await self.validate_id_token(
            metadata=metadata,
            client_id=client_id,
            id_token=id_token,
            nonce=nonce,
        )

        # ID token 没给 email/name 时取 userinfo 补
        userinfo: dict[str, Any] = {}
        if metadata.userinfo_endpoint and access_token:
            try:
                userinfo = await self.fetch_userinfo(
                    metadata=metadata,
                    access_token=access_token,
                    expected_sub=claims["sub"],
                )
            except OIDCError as exc:
                logger.warning("OIDC userinfo fetch failed (continuing with ID token): %s", exc)

        # 合并（userinfo 对 email 优先）
        merged = {**claims, **userinfo}

        email = merged.get("email") or ""
        email_verified = merged.get("email_verified") is True

        return OIDCIdentity(
            provider=provider_id,
            subject=claims["sub"],
            email=email,
            email_verified=email_verified,
            name=merged.get("name"),
            claims=merged,
        )


def _constant_time_compare(a: str, b: str) -> bool:
    """常时字符串比较。"""
    return secrets.compare_digest(a, b)
```

### 4a. OIDC state/nonce/PKCE（签名 cookie，无服务端存储）

state 防 OAuth 回调 CSRF，nonce 防 ID token 重放，PKCE 防授权码截获。三者都塞进一个**短时签名 cookie**（5 分钟，HS256 签名），无服务端存储，多 worker 无需 Redis。

```python
# gateway/gateway/auth/oidc_state.py
"""经签名 HttpOnly cookie 管理 OIDC state。

把 OIDC state、nonce、PKCE verifier 存进短时签名 cookie 而非服务端存储。
这保持实现无状态，且无需 Redis 即兼容多 worker 部署。
"""

from __future__ import annotations

import secrets
import time

import jwt
from fastapi import Request, Response
from pydantic import BaseModel, Field

from gateway.gateway.auth.config import get_auth_config
from gateway.gateway.csrf_middleware import is_secure_request

OIDC_STATE_COOKIE_PREFIX = "helix_oidc_state_"
OIDC_STATE_MAX_AGE = 300  # 5 分钟
OIDC_STATE_BYTES = 32
OIDC_NONCE_BYTES = 16
OIDC_CODE_VERIFIER_BYTES = 32


class OIDCStatePayload(BaseModel):
    """签名 OIDC state cookie 内存的载荷。"""

    provider: str = Field(description="OIDC provider ID（必须与 state cookie 匹配）")
    state: str = Field(description="密码学随机 state 值--与 query 参数常时比较")
    nonce: str | None = Field(default=None, description="OIDC nonce，对 ID token nonce claim 校验")
    code_verifier: str | None = Field(default=None, description="PKCE code verifier，token 交换时发")
    next_path: str = Field(default="/workspace", description="认证成功后重定向目标")
    issued_at: float = Field(default_factory=time.time, description="cookie 创建 Unix 时间戳")


def _sign_state_payload(payload: OIDCStatePayload) -> str:
    """用 JWT secret 签名 state 载荷防篡改。"""
    secret = get_auth_config().jwt_secret
    return jwt.encode(payload.model_dump(), secret, algorithm="HS256")


def _verify_state_signed(signed: str, max_age: int = OIDC_STATE_MAX_AGE) -> OIDCStatePayload | None:
    """校验签名 state 载荷并返回，非法/过期返回 None。"""
    secret = get_auth_config().jwt_secret
    try:
        decoded = jwt.decode(signed, secret, algorithms=["HS256"])
        payload = OIDCStatePayload(**decoded)
        if time.time() - payload.issued_at > max_age:
            return None
        return payload
    except jwt.PyJWTError:
        return None


def generate_oidc_state() -> str:
    """生成密码学随机 state 字符串。"""
    return secrets.token_urlsafe(OIDC_STATE_BYTES)


def generate_nonce() -> str:
    """生成 ID token 校验用的 nonce。"""
    return secrets.token_urlsafe(OIDC_NONCE_BYTES)


def generate_code_verifier() -> str:
    """生成 PKCE code verifier（纯随机串）。"""
    return secrets.token_urlsafe(OIDC_CODE_VERIFIER_BYTES)


def compute_code_challenge(verifier: str) -> str:
    """从 verifier 计算 S256 PKCE code challenge。"""
    import hashlib

    return _base64url_encode(hashlib.sha256(verifier.encode("ascii")).digest())


def _base64url_encode(data: bytes) -> str:
    """RFC 7636 与 OIDC 要求的无填充 base64url 编码。"""
    import base64

    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _cookie_name(provider: str) -> str:
    return f"{OIDC_STATE_COOKIE_PREFIX}{provider}"


def set_state_cookie(response: Response, request: Request, payload: OIDCStatePayload) -> None:
    """在响应上设置签名 OIDC state cookie。"""
    signed = _sign_state_payload(payload)
    is_https = is_secure_request(request)
    response.set_cookie(
        key=_cookie_name(payload.provider),
        value=signed,
        httponly=True,
        secure=is_https,
        samesite="lax",
        max_age=OIDC_STATE_MAX_AGE,
        # 限定回调路径，缩小 cookie 暴露面。
        path=f"/api/v1/auth/callback/{payload.provider}",
    )


def get_state_cookie(request: Request, provider: str) -> OIDCStatePayload | None:
    """读并校验指定 provider 的签名 OIDC state cookie。"""
    signed = request.cookies.get(_cookie_name(provider))
    if not signed:
        return None
    return _verify_state_signed(signed)


def delete_state_cookie(response: Response, request: Request, provider: str) -> None:
    """删除 OIDC state cookie。"""
    is_https = is_secure_request(request)
    response.delete_cookie(
        key=_cookie_name(provider),
        secure=is_https,
        samesite="lax",
        path=f"/api/v1/auth/callback/{provider}",
    )
```

回调路由对 state 做常时比较（防 OAuth 回调 CSRF），失败即 403：

```python
# gateway/gateway/routers/auth.py（节选：OIDC 回调的 state 校验）
    if not code or not state:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Missing code or state parameter")

    # ── 校验 state cookie ──────────────────────────────────────────
    state_payload = get_state_cookie(request, provider)
    if not state_payload:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Missing or expired OIDC state cookie")
    # 常时比较防计时侧信道；不匹配即 403（OAuth 回调 CSRF 防线）。
    if not secrets.compare_digest(state_payload.state, state):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="OIDC state mismatch")
    # 后续步骤：exchange_code + validate_id_token(nonce=state_payload.nonce) + 落库 + 签发 cookie JWT
```

## 5. 本地凭证 provider + OAuth 用户落库

`LocalAuthProvider` 既是邮箱密码登录的校验器，也是 OAuth/OIDC 登录后"按 provider+subject 匹配或创建用户"的落库桥。它产出的 `User` 带 `token_version`，被 `create_access_token` 写进 JWT 的 `ver`，闭环回到第 1、2 节的吊销逻辑。

```python
# gateway/gateway/auth/local_provider.py
"""本地邮箱/密码认证 provider。"""

import logging

from gateway.gateway.auth.models import User
from gateway.gateway.auth.password import hash_password_async, needs_rehash, verify_password_async
from gateway.gateway.auth.providers import AuthProvider
from gateway.gateway.auth.repositories.base import UserRepository

logger = logging.getLogger(__name__)


class LocalAuthProvider(AuthProvider):
    """用本地数据库的邮箱/密码认证 provider。"""

    def __init__(self, repository: UserRepository):
        """用 UserRepository 初始化。

        Args:
            repository: UserRepository 实现（SQLite）
        """
        self._repo = repository

    async def authenticate(self, credentials: dict) -> User | None:
        """用邮箱和密码认证。

        Args:
            credentials: 含 'email' 与 'password' 的 dict

        Returns:
            认证成功返回 User，否则 None
        """
        email = credentials.get("email")
        password = credentials.get("password")

        if not email or not password:
            return None

        user = await self._repo.get_user_by_email(email)
        if user is None:
            return None

        if user.password_hash is None:
            # OAuth 用户无本地密码
            return None

        if not await verify_password_async(password, user.password_hash):
            return None

        if needs_rehash(user.password_hash):
            # 机会性升级哈希参数；瞬时 DB 错不能阻断一次本有效的登录。
            try:
                user.password_hash = await hash_password_async(password)
                await self._repo.update_user(user)
            except Exception:
                logger.warning("Failed to rehash password for user %s; login will still succeed", user.email, exc_info=True)

        return user

    async def get_user(self, user_id: str) -> User | None:
        """按 ID 取用户。"""
        return await self._repo.get_user_by_id(user_id)

    async def create_user(self, email: str, password: str | None = None, system_role: str = "user", needs_setup: bool = False) -> User:
        """创建新本地用户。"""
        password_hash = await hash_password_async(password) if password else None
        user = User(
            email=email,
            password_hash=password_hash,
            system_role=system_role,
            needs_setup=needs_setup,
        )
        return await self._repo.create_user(user)

    async def get_user_by_oauth(self, provider: str, oauth_id: str) -> User | None:
        """按 OAuth provider 与 ID 取用户。"""
        return await self._repo.get_user_by_oauth(provider, oauth_id)

    async def count_users(self) -> int:
        """返回已注册用户总数。"""
        return await self._repo.count_users()

    async def count_admin_users(self) -> int:
        """返回 admin 用户数。"""
        return await self._repo.count_admin_users()

    async def update_user(self, user: User) -> User:
        """更新既有用户。"""
        return await self._repo.update_user(user)

    async def get_user_by_email(self, email: str) -> User | None:
        """按邮箱取用户。"""
        return await self._repo.get_user_by_email(email)

    async def create_oauth_user(
        self,
        email: str,
        oauth_provider: str,
        oauth_id: str,
        system_role: str = "user",
    ) -> User:
        """从 OAuth/OIDC 登录创建新用户。

        Args:
            email: OIDC provider 的已验证邮箱
            oauth_provider: Provider ID（如 'keycloak'、'google'）
            oauth_id: ID token 的 subject claim
            system_role: 角色（"admin" 或 "user"）

        Returns:
            创建的 User 实例
        """
        user = User(
            email=email,
            password_hash=None,           # OAuth 用户无本地密码
            system_role=system_role,
            needs_setup=False,
            oauth_provider=oauth_provider,
            oauth_id=oauth_id,
        )
        return await self._repo.create_user(user)
```

> 三层凭证在此汇合到同一套签发/解析机制：本地登录与 OAuth 回调都调 `create_access_token(user_id, token_version=user.token_version)` 签发同款 cookie JWT；内部 token 则在 `AuthMiddleware` 内就地合成用户、不签 JWT。三条路解析出的 `user` 都写进 `user_context` contextvar，下游无差别。`token_version` 是唯一吊销锚点--改密 bump、解析时比较，无需 token 黑名单。
