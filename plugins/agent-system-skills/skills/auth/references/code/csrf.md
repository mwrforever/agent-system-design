# 完整源码：CSRF Double-Submit Cookie

> 本文件给出 CSRF 防护的**完整实现**：`CSRFMiddleware`（Double-Submit Cookie 模式）+ auth 端点的 Origin 校验（首访无 token 时的登录 CSRF 防线）+ 代理头解析的受信来源。
>
> SKILL.md「完整真实代码实现」段给了入口片段与索引；此处补全完整源码。
>
> 真实实现已按匿名化规则映射到中立结构（应用层 `gateway.gateway.*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

## 1. CSRFMiddleware（Double-Submit Cookie + auth Origin 校验）

```python
# gateway/gateway/csrf_middleware.py
"""FastAPI 的 CSRF 防护中间件。

依 RFC-001：状态变更操作需 CSRF 防护。
"""

import os
import secrets
from collections.abc import Awaitable, Callable
from urllib.parse import urlsplit

from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp

from gateway.gateway.auth.config import get_auth_config
from gateway.gateway.auth_disabled import is_auth_disabled

CSRF_COOKIE_NAME = "csrf_token"
CSRF_HEADER_NAME = "X-CSRF-Token"
CSRF_TOKEN_LENGTH = 64  # bytes


def is_secure_request(request: Request) -> bool:
    """检测原始客户端请求是否走 HTTPS。"""
    return _request_scheme(request) == "https"


def generate_csrf_token() -> str:
    """生成安全随机 CSRF token。"""
    return secrets.token_urlsafe(CSRF_TOKEN_LENGTH)


def should_check_csrf(request: Request) -> bool:
    """判断请求是否需 CSRF 校验。

    CSRF 仅对状态变更方法（POST/PUT/DELETE/PATCH）校验。
    GET/HEAD/OPTIONS/TRACE 依 RFC 7231 豁免。
    """
    if request.method not in ("POST", "PUT", "DELETE", "PATCH"):
        return False

    # auth-disabled 模式下不校验 CSRF（本地/E2E 便利；生产被 is_auth_disabled 拒掉）。
    if is_auth_disabled():
        return False

    path = request.url.path.rstrip("/")
    # 豁免 /api/v1/auth/me
    if path == "/api/v1/auth/me":
        return False
    # 入站 webhook 经 provider 专属签名自证身份，不走双提交 cookie。
    if request.url.path.startswith("/api/webhooks/"):
        return False
    return True


# auth 端点豁免集：首访无 CSRF token，但仍受 Origin 校验保护（见 is_allowed_auth_origin）。
_AUTH_EXEMPT_PATHS: frozenset[str] = frozenset(
    {
        "/api/v1/auth/login/local",
        "/api/v1/auth/logout",
        "/api/v1/auth/register",
        "/api/v1/auth/initialize",
    }
)


def is_auth_endpoint(request: Request) -> bool:
    """检查请求是否打向 auth 端点。

    auth 端点首次调用无需 CSRF token（还没有 token）。
    """
    return request.url.path.rstrip("/") in _AUTH_EXEMPT_PATHS


def _host_with_optional_port(hostname: str, port: int | None, scheme: str) -> str:
    """返回规范化的 host[:port]，省略默认端口。"""
    host = hostname.lower()
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"

    if port is None or (scheme == "http" and port == 80) or (scheme == "https" and port == 443):
        return host
    return f"{host}:{port}"


def _normalize_origin(origin: str) -> str | None:
    """返回规范化的 scheme://host[:port] origin，非法输入返回 None。"""
    try:
        parsed = urlsplit(origin.strip())
        port = parsed.port
    except ValueError:
        return None

    scheme = parsed.scheme.lower()
    if scheme not in {"http", "https"} or not parsed.hostname:
        return None

    # 浏览器 Origin 只有 scheme/host/port。拒绝 URL 形态或带凭据的值。
    if parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
        return None

    return f"{scheme}://{_host_with_optional_port(parsed.hostname, port, scheme)}"


def _configured_cors_origins() -> set[str]:
    """返回显式配置的、可调 auth 路由的浏览器 origin。"""
    origins = set()
    for raw_origin in os.environ.get("GATEWAY_CORS_ORIGINS", "").split(","):
        origin = raw_origin.strip()
        if not origin or origin == "*":
            continue
        normalized = _normalize_origin(origin)
        if normalized:
            origins.add(normalized)
    return origins


def get_configured_cors_origins() -> set[str]:
    """返回 GATEWAY_CORS_ORIGINS 规范化的显式浏览器 origin。"""
    return _configured_cors_origins()


def _first_header_value(value: str | None) -> str | None:
    """从逗号分隔的代理头取第一个值。"""
    if not value:
        return None
    first = value.split(",", 1)[0].strip()
    return first or None


def _forwarded_param(request: Request, name: str) -> str | None:
    """从首个 RFC 7239 Forwarded 头条目抽参数。"""
    forwarded = _first_header_value(request.headers.get("forwarded"))
    if not forwarded:
        return None

    for part in forwarded.split(";"):
        key, sep, value = part.strip().partition("=")
        if sep and key.lower() == name:
            return value.strip().strip('"') or None
    return None


def _request_scheme(request: Request) -> str:
    """从受信代理头解析原始请求 scheme。"""
    scheme = _forwarded_param(request, "proto") or _first_header_value(request.headers.get("x-forwarded-proto")) or request.url.scheme
    return scheme.lower()


def _request_origin(request: Request) -> str | None:
    """构建浏览器目标 URL 的 origin。"""
    scheme = _request_scheme(request)
    host = _forwarded_param(request, "host") or _first_header_value(request.headers.get("x-forwarded-host")) or request.headers.get("host") or request.url.netloc

    forwarded_port = _first_header_value(request.headers.get("x-forwarded-port"))
    if forwarded_port and ":" not in host.rsplit("]", 1)[-1]:
        host = f"{host}:{forwarded_port}"

    return _normalize_origin(f"{scheme}://{host}")


def is_allowed_auth_origin(request: Request) -> bool:
    """仅允许同源或显式配置 origin 的 auth POST。

    login/register/initialize 豁免双提交 token（首访浏览器还没有 CSRF token），
    但它们会建 session cookie，故带敌意 Origin 头的浏览器请求必须拒，防
    login CSRF / session fixation。无 Origin 头的请求放行，为 curl/移动端
    这类非浏览器客户端。
    """
    origin = request.headers.get("origin")
    if not origin:
        return True

    normalized_origin = _normalize_origin(origin)
    if normalized_origin is None:
        return False

    request_origin = _request_origin(request)
    return normalized_origin in _configured_cors_origins() or (request_origin is not None and normalized_origin == request_origin)


class CSRFMiddleware(BaseHTTPMiddleware):
    """用 Double Submit Cookie 模式实现 CSRF 防护的中间件。"""

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(self, request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        _is_auth = is_auth_endpoint(request)

        # auth 端点：无双提交 token（首访没有），改用 Origin 校验防 login CSRF。
        if should_check_csrf(request) and _is_auth and not is_allowed_auth_origin(request):
            return JSONResponse(
                status_code=403,
                content={"detail": "Cross-site auth request denied."},
            )

        # 非 auth 状态变更请求：双提交校验（cookie token == header token）。
        if should_check_csrf(request) and not _is_auth:
            cookie_token = request.cookies.get(CSRF_COOKIE_NAME)
            header_token = request.headers.get(CSRF_HEADER_NAME)

            # 双提交：cookie 与 header 必须都在。
            if not cookie_token or not header_token:
                return JSONResponse(
                    status_code=403,
                    content={"detail": "CSRF token missing. Include X-CSRF-Token header."},
                )

            # 常时比较防计时侧信道；不匹配即 403。
            if not secrets.compare_digest(cookie_token, header_token):
                return JSONResponse(
                    status_code=403,
                    content={"detail": "CSRF token mismatch."},
                )

        response = await call_next(request)

        # auth 端点建 session 后，同步下发 CSRF cookie（双提交的 cookie 半边）。
        if _is_auth and request.method == "POST":
            csrf_token = generate_csrf_token()
            is_https = is_secure_request(request)
            response.set_cookie(
                key=CSRF_COOKIE_NAME,
                value=csrf_token,
                httponly=False,  # 双提交模式必须 JS 可读，前端读它放 X-CSRF-Token 头
                secure=is_https,
                samesite="strict",
                # 与 access_token cookie 同寿命（见 auth.py::_set_session_cookie），
                # 使双提交对永不分叉。若 csrf_token 是 session-only，iOS Safari
                # 结束桌面 PWA 时会驱逐它，而持久 access_token 还在--用户"已登录"
                # 却发不出任何状态变更请求（403 "CSRF token missing"）。
                max_age=get_auth_config().token_expiry_days * 24 * 3600 if is_https else None,
            )

        return response


def get_csrf_token(request: Request) -> str | None:
    """从当前请求 cookie 取 CSRF token。

    SSR 需把 token 嵌进 form 或 header 时有用。
    """
    return request.cookies.get(CSRF_COOKIE_NAME)
```

> 双提交的核心不变量：`csrf_token` cookie（JS 可读、`httponly=False`）与 `X-CSRF-Token` 请求头（前端 JS 从 cookie 读出后塞入）必须**常时相等**。攻击者站点虽能让浏览器带上 cookie，但同源策略使其读不到 cookie 值、无法伪造匹配的 header，故状态变更请求被拒。`access_token` cookie 是 `httponly=True`（JS 不可读、防 XSS 偷），与 `csrf_token`（JS 可读）正交分工：前者保"你是谁"，后者保"请求是你自愿发的"。两者 `max_age` 必须对齐，否则会出现"登录态在但发不出请求"的死锁（见上面 samesite/max_age 注释的真实踩坑）。
