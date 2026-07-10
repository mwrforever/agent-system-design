# 完整源码：owner 检查 + 内部 Token + contextvar 写入

> 本文件给出运行时 owner 鉴权与内部 Token 边界的**完整实现**：`gateway/gateway/internal_auth.py`（内部 Token + owner 头 + synthetic user）、`gateway/gateway/auth_middleware.py`（AuthMiddleware 写 contextvar）、`gateway/gateway/authz.py`（`require_permission` owner 检查装饰器）、`core/helix/persistence/thread_meta/sql.py`（`check_access` 三态语义）、`gateway/gateway/services.py` 的 owner 检查与 context 注入节选。这是跨切不变量 2 在 ②认证 -> ③路由 的执行点。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*` / `gateway.*`），去除一切项目字样。原代码注释保留以保真。`services.py` 仅收录与隔离相关的函数（完整未截断），非隔离逻辑省略。

---

## §1 internal_auth.py（内部 Token + owner 头）

```python
# gateway/gateway/internal_auth.py
"""Authentication for trusted Gateway internal callers."""

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
    token = os.environ.get(INTERNAL_AUTH_ENV_VAR)
    if token:
        return token
    return secrets.token_urlsafe(32)


_INTERNAL_AUTH_TOKEN = _load_internal_auth_token()


def create_internal_auth_headers(*, owner_user_id: str | None = None) -> dict[str, str]:
    """Return headers that authenticate trusted Gateway internal calls."""
    headers = {INTERNAL_AUTH_HEADER_NAME: _INTERNAL_AUTH_TOKEN}
    if owner_user_id:
        headers[INTERNAL_OWNER_USER_ID_HEADER_NAME] = owner_user_id
    return headers


def is_valid_internal_auth_token(token: str | None) -> bool:
    """Return True when *token* matches this Gateway worker's internal token."""
    return bool(token) and secrets.compare_digest(token, _INTERNAL_AUTH_TOKEN)


def get_internal_user(owner_user_id: str | None = None):
    """Return the synthetic user used for trusted internal channel calls.

    When *owner_user_id* is provided (extracted from the
    ``X-Helix-Owner-User-Id`` header), the synthetic user's ``.id``
    carries the actual channel owner instead of ``DEFAULT_USER_ID``.
    This ensures that ``get_effective_user_id()`` and downstream
    filesystem-path resolution (per-user custom skills, memory, thread
    data) use the correct identity for IM channel messages instead of
    falling back to ``"default"``.

    The owner id is normalized through :func:`make_safe_user_id` so that
    IM channel ids containing characters outside ``[A-Za-z0-9_-]`` (e.g.
    Feishu ``open_id`` prefixed with ``ou_`` and containing underscores
    that the rest of the system may treat as path separators, or
    Telegram chat ids like ``-1001234567890``) cannot be used to escape
    the per-user storage bucket or impersonate a different user via
    header value tricks (e.g. trailing slashes, ``..`` segments). The
    normalization is lossy but deterministic: two distinct raw inputs
    never share a safe id, so cross-user bleed is impossible.
    """
    if owner_user_id:
        effective_id = make_safe_user_id(owner_user_id)
    else:
        effective_id = DEFAULT_USER_ID
    return SimpleNamespace(id=effective_id, system_role=INTERNAL_SYSTEM_ROLE)


def get_trusted_internal_owner_user_id(request: Any) -> str | None:
    """Return the owner override for a trusted internal request, if present.

    The header is ignored for normal browser/API callers. It is only honored
    after ``AuthMiddleware`` has validated the internal auth token and stamped
    the synthetic internal user onto ``request.state.user``.
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

## §2 auth_middleware.py（AuthMiddleware 写 contextvar）

```python
# gateway/gateway/auth_middleware.py
"""Global authentication middleware - fail-closed safety net.

Rejects unauthenticated requests to non-public paths with 401. When a
request passes the cookie check, resolves the JWT payload to a real
``User`` object and stamps it into both ``request.state.user`` and the
``helix.runtime.user_context`` contextvar so that repository-layer
owner filtering works automatically via the sentinel pattern.

Fine-grained permission checks remain in authz.py decorators.
"""

from collections.abc import Callable

from fastapi import HTTPException, Request, Response
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp

from gateway.auth.errors import AuthErrorCode, AuthErrorResponse
from gateway.auth_disabled import (
    AUTH_SOURCE_AUTH_DISABLED,
    AUTH_SOURCE_INTERNAL,
    AUTH_SOURCE_SESSION,
    get_auth_disabled_user,
    is_auth_disabled,
)
from gateway.authz import _ALL_PERMISSIONS, AuthContext
from gateway.internal_auth import INTERNAL_AUTH_HEADER_NAME, get_internal_user, is_valid_internal_auth_token
from helix.runtime.user_context import reset_current_user, set_current_user

# Paths that never require authentication.
_PUBLIC_PATH_PREFIXES: tuple[str, ...] = (
    "/health",
    "/docs",
    "/redoc",
    "/openapi.json",
    "/api/v1/auth/oauth/",
    "/api/v1/auth/callback/",
    # Inbound webhooks authenticate themselves via provider-specific signatures
    # (e.g. GitHub's X-Hub-Signature-256), not session cookies.
    "/api/webhooks/",
)

# Exact auth paths that are public (login/register/status check).
# /api/v1/auth/me, /api/v1/auth/change-password etc. are NOT public.
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
    """Strict auth gate: reject requests without a valid session.

    Two-stage check for non-public paths:

    1. Cookie presence - return 401 NOT_AUTHENTICATED if missing
    2. JWT validation via ``get_optional_user_from_request`` - return 401
       TOKEN_INVALID if the token is absent, malformed, expired, or the
       signed user does not exist / is stale

    On success, stamps ``request.state.user`` and the
    ``helix.runtime.user_context`` contextvar so that repository-layer
    owner filters work downstream without every route needing a
    ``@require_auth`` decorator. Routes that need per-resource
    authorization (e.g. "user A cannot read user B's thread by guessing
    the URL") should additionally use ``@require_permission(...,
    owner_check=True)`` for explicit enforcement - but authentication
    itself is fully handled here.
    """

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        if _is_public(request.url.path):
            return await call_next(request)

        internal_user = None
        if is_valid_internal_auth_token(request.headers.get(INTERNAL_AUTH_HEADER_NAME)):
            # Extract the channel owner user ID from the trusted header.
            # When present, the synthetic internal user carries the actual
            # owner identity so that get_effective_user_id() and per-user
            # filesystem paths (custom skills, memory, thread data) resolve
            # to the IM channel user instead of falling back to "default".
            from gateway.internal_auth import INTERNAL_OWNER_USER_ID_HEADER_NAME

            owner_user_id = request.headers.get(INTERNAL_OWNER_USER_ID_HEADER_NAME)
            if owner_user_id:
                owner_user_id = owner_user_id.strip()
            internal_user = get_internal_user(owner_user_id=owner_user_id or None)

        auth_source = AUTH_SOURCE_SESSION
        access_token = request.cookies.get("access_token")

        # Non-public path: require session cookie
        if internal_user is not None:
            user = internal_user
            auth_source = AUTH_SOURCE_INTERNAL
        elif access_token:
            # Strict JWT validation: reject junk/expired tokens with 401
            # right here instead of silently passing through. This closes
            # the "junk cookie bypass" gap: without this, non-isolation
            # routes like /api/models would accept any cookie-shaped
            # string as authentication.
            #
            # We call the *strict* resolver so that fine-grained error
            # codes (token_expired, token_invalid, user_not_found, ...)
            # propagate from AuthErrorCode, not get flattened into one
            # generic code. BaseHTTPMiddleware doesn't let HTTPException
            # bubble up, so we catch and render it as JSONResponse here.
            from gateway.deps import get_current_user_from_request

            try:
                user = await get_current_user_from_request(request)
            except HTTPException as exc:
                if not is_auth_disabled():
                    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
                user = get_auth_disabled_user()
                auth_source = AUTH_SOURCE_AUTH_DISABLED
        elif is_auth_disabled():
            user = get_auth_disabled_user()
            auth_source = AUTH_SOURCE_AUTH_DISABLED
        else:
            return JSONResponse(
                status_code=401,
                content={
                    "detail": AuthErrorResponse(
                        code=AuthErrorCode.NOT_AUTHENTICATED,
                        message="Authentication required",
                    ).model_dump()
                },
            )

        # Stamp both request.state.user (for the contextvar pattern)
        # and request.state.auth (so @require_permission's "auth is
        # None" branch short-circuits instead of running the entire
        # JWT-decode + DB-lookup pipeline a second time per request).
        request.state.user = user
        request.state.auth_source = auth_source
        request.state.auth = AuthContext(user=user, permissions=_ALL_PERMISSIONS)
        token = set_current_user(user)
        try:
            return await call_next(request)
        finally:
            reset_current_user(token)
```

---

## §3 authz.py（require_permission owner 检查装饰器）

```python
# gateway/gateway/authz.py
"""Authorization decorators and context for Helix.

Inspired by LangGraph Auth system.

**Usage:**

1. Use ``@require_auth`` on routes that need authentication
2. Use ``@require_permission("resource", "action", filter_key=...)`` for permission checks
3. The decorator chain processes from bottom to top

**Example:**

    @router.get("/{thread_id}")
    @require_auth
    @require_permission("threads", "read", owner_check=True)
    async def get_thread(thread_id: str, request: Request):
        # User is authenticated and has threads:read permission
        ...

**Permission Model:**

- threads:read   - View thread
- threads:write  - Create/update thread
- threads:delete - Delete thread
- runs:create   - Run agent
- runs:read     - View run
- runs:cancel   - Cancel run
"""

from __future__ import annotations

import functools
import inspect
from collections.abc import Callable
from types import SimpleNamespace
from typing import TYPE_CHECKING, Any, ParamSpec, TypeVar

from fastapi import HTTPException, Request

if TYPE_CHECKING:
    from gateway.auth.models import User

P = ParamSpec("P")
T = TypeVar("T")


# Permission constants
class Permissions:
    """Permission constants for resource:action format."""

    # Threads
    THREADS_READ = "threads:read"
    THREADS_WRITE = "threads:write"
    THREADS_DELETE = "threads:delete"

    # Runs
    RUNS_CREATE = "runs:create"
    RUNS_READ = "runs:read"
    RUNS_CANCEL = "runs:cancel"


class AuthContext:
    """Authentication context for the current request.

    Stored in request.state.auth after require_auth decoration.

    Attributes:
        user: The authenticated user, or None if anonymous
        permissions: List of permission strings (e.g. "threads:read")
    """

    __slots__ = ("user", "permissions")

    def __init__(self, user: User | None = None, permissions: list[str] | None = None):
        self.user = user
        self.permissions = permissions or []

    @property
    def is_authenticated(self) -> bool:
        """Check if user is authenticated."""
        return self.user is not None

    def has_permission(self, resource: str, action: str) -> bool:
        """Check if context has permission for resource:action.

        Args:
            resource: Resource name (e.g. "threads")
            action: Action name (e.g. "read")

        Returns:
            True if user has permission
        """
        permission = f"{resource}:{action}"
        return permission in self.permissions

    def require_user(self) -> User:
        """Get user or raise 401.

        Raises:
            HTTPException 401 if not authenticated
        """
        if not self.user:
            raise HTTPException(status_code=401, detail="Authentication required")
        return self.user


def get_auth_context(request: Request) -> AuthContext | None:
    """Get AuthContext from request state."""
    return getattr(request.state, "auth", None)


_ALL_PERMISSIONS: list[str] = [
    Permissions.THREADS_READ,
    Permissions.THREADS_WRITE,
    Permissions.THREADS_DELETE,
    Permissions.RUNS_CREATE,
    Permissions.RUNS_READ,
    Permissions.RUNS_CANCEL,
]


def _make_test_request_stub() -> Any:
    """Create a minimal request-like object for direct unit calls.

    Used when decorated route handlers are invoked without FastAPI's
    request injection. Includes fields accessed by auth helpers.
    """
    return SimpleNamespace(state=SimpleNamespace(), cookies={}, _helix_test_bypass_auth=True)


async def _authenticate(request: Request) -> AuthContext:
    """Authenticate request and return AuthContext.

    Delegates to deps.get_optional_user_from_request() for the JWT->User pipeline.
    Returns AuthContext with user=None for anonymous requests.
    """
    from gateway.deps import get_optional_user_from_request

    user = await get_optional_user_from_request(request)
    if user is None:
        return AuthContext(user=None, permissions=[])

    # In future, permissions could be stored in user record
    return AuthContext(user=user, permissions=_ALL_PERMISSIONS)


def require_auth[**P, T](func: Callable[P, T]) -> Callable[P, T]:
    """Decorator that authenticates the request and enforces authentication.

    Independently raises HTTP 401 for unauthenticated requests, regardless of
    whether ``AuthMiddleware`` is present in the ASGI stack. Sets the resolved
    ``AuthContext`` on ``request.state.auth`` for downstream handlers.

    Must be placed ABOVE other decorators (executes after them).

    Usage:
        @router.get("/{thread_id}")
        @require_auth  # Bottom decorator (executes first after permission check)
        @require_permission("threads", "read")
        async def get_thread(thread_id: str, request: Request):
            auth: AuthContext = request.state.auth
            ...

    Raises:
        HTTPException: 401 if the request is unauthenticated.
        ValueError: If 'request' parameter is missing.
    """

    @functools.wraps(func)
    async def wrapper(*args: Any, **kwargs: Any) -> Any:
        request = kwargs.get("request")
        if request is None:
            # Unit tests may call decorated handlers directly without a
            # FastAPI Request object. Inject a minimal request stub when
            # the wrapped function declares `request`.
            if "request" in inspect.signature(func).parameters:
                kwargs["request"] = _make_test_request_stub()
            else:
                raise ValueError("require_auth decorator requires 'request' parameter")
            request = kwargs["request"]

        if getattr(request, "_helix_test_bypass_auth", False):
            return await func(*args, **kwargs)

        # Authenticate and set context
        auth_context = await _authenticate(request)
        request.state.auth = auth_context

        if not auth_context.is_authenticated:
            raise HTTPException(status_code=401, detail="Authentication required")

        return await func(*args, **kwargs)

    return wrapper


def require_permission(
    resource: str,
    action: str,
    owner_check: bool = False,
    require_existing: bool = False,
) -> Callable[[Callable[P, T]], Callable[P, T]]:
    """Decorator that checks permission for resource:action.

    Must be used AFTER @require_auth.

    Args:
        resource: Resource name (e.g. "threads", "runs")
        action: Action name (e.g. "read", "write", "delete")
        owner_check: If True, validates that the current user owns the resource.
                     Requires 'thread_id' path parameter and performs ownership check.
        require_existing: Only meaningful with ``owner_check=True``. If True, a
                          missing ``threads_meta`` row counts as a denial (404)
                          instead of "untracked legacy thread, allow". Use on
                          **destructive / mutating** routes (DELETE, PATCH,
                          state-update) so a deleted thread can't be re-targeted
                          by another user via the missing-row code path.

    Usage:
        # Read-style: legacy untracked threads are allowed
        @require_permission("threads", "read", owner_check=True)
        async def get_thread(thread_id: str, request: Request):
            ...

        # Destructive: thread row MUST exist and be owned by caller
        @require_permission("threads", "delete", owner_check=True, require_existing=True)
        async def delete_thread(thread_id: str, request: Request):
            ...

    Raises:
        HTTPException 401: If authentication required but user is anonymous
        HTTPException 403: If user lacks permission
        HTTPException 404: If owner_check=True but user doesn't own the thread
        ValueError: If owner_check=True but 'thread_id' parameter is missing
    """

    def decorator(func: Callable[P, T]) -> Callable[P, T]:
        @functools.wraps(func)
        async def wrapper(*args: Any, **kwargs: Any) -> Any:
            request = kwargs.get("request")
            if request is None:
                # Unit tests may call decorated route handlers directly without
                # constructing a FastAPI Request object. Inject a minimal stub
                # when the wrapped function declares `request`.
                if "request" in inspect.signature(func).parameters:
                    kwargs["request"] = _make_test_request_stub()
                else:
                    return await func(*args, **kwargs)
                request = kwargs["request"]

            if getattr(request, "_helix_test_bypass_auth", False):
                return await func(*args, **kwargs)

            auth: AuthContext = getattr(request.state, "auth", None)
            if auth is None:
                auth = await _authenticate(request)
                request.state.auth = auth

            if not auth.is_authenticated:
                raise HTTPException(status_code=401, detail="Authentication required")

            # Check permission
            if not auth.has_permission(resource, action):
                raise HTTPException(
                    status_code=403,
                    detail=f"Permission denied: {resource}:{action}",
                )

            # Owner check for thread-specific resources.
            #
            # 2.0-rc moved thread metadata into the SQL persistence layer
            # (``threads_meta`` table). We verify ownership via
            # ``ThreadMetaStore.check_access``: it returns True for
            # missing rows (untracked legacy thread) and for rows whose
            # ``user_id`` is NULL (shared / pre-auth data), so this is
            # strict-deny rather than strict-allow - only an *existing*
            # row with a *different* user_id triggers 404.
            if owner_check:
                from gateway.internal_auth import INTERNAL_OWNER_USER_ID_HEADER_NAME, INTERNAL_SYSTEM_ROLE

                thread_id = kwargs.get("thread_id")
                if thread_id is None:
                    raise ValueError("require_permission with owner_check=True requires 'thread_id' parameter")

                from gateway.deps import get_thread_store

                thread_store = get_thread_store(request)
                allowed = await thread_store.check_access(
                    thread_id,
                    str(auth.user.id),
                    require_existing=require_existing,
                )
                if not allowed and getattr(auth.user, "system_role", None) == INTERNAL_SYSTEM_ROLE:
                    # Trusted internal callers (channel workers) also act for
                    # the connection owner carried in X-Helix-Owner-User-Id.
                    # Scope the check to that owner instead of bypassing it; a
                    # leaked internal token must not grant cross-user thread
                    # access. The header is honored only after ``auth`` proved
                    # the caller holds the internal token (mirrors
                    # get_trusted_internal_owner_user_id, which keys off the
                    # middleware-stamped ``request.state.user``).
                    header_owner = (request.headers.get(INTERNAL_OWNER_USER_ID_HEADER_NAME) or "").strip()
                    if header_owner:
                        allowed = await thread_store.check_access(
                            thread_id,
                            header_owner,
                            require_existing=require_existing,
                        )
                if not allowed:
                    raise HTTPException(
                        status_code=404,
                        detail=f"Thread {thread_id} not found",
                    )

            return await func(*args, **kwargs)

        return wrapper

    return decorator
```

---

## §4 thread_meta/sql.py（check_access 三态语义）

> 完整源码（`ThreadMetaRepository` 全部方法）。`check_access` 是 owner 检查的核心：缺行 / NULL owner / 异主 三态分语义。

```python
# core/helix/persistence/thread_meta/sql.py
"""SQLAlchemy-backed thread metadata repository."""

from __future__ import annotations

import logging
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from helix.persistence.json_compat import json_match
from helix.persistence.thread_meta.base import InvalidMetadataFilterError, ThreadMetaStore
from helix.persistence.thread_meta.model import ThreadMetaRow
from helix.runtime.user_context import AUTO, _AutoSentinel, resolve_user_id
from helix.utils.time import coerce_iso

logger = logging.getLogger(__name__)


class ThreadMetaRepository(ThreadMetaStore):
    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self._sf = session_factory

    @staticmethod
    def _row_to_dict(row: ThreadMetaRow) -> dict[str, Any]:
        d = row.to_dict()
        d["metadata"] = d.pop("metadata_json", None) or {}
        for key in ("created_at", "updated_at"):
            val = d.get(key)
            if isinstance(val, datetime):
                # SQLite drops tzinfo despite ``DateTime(timezone=True)``;
                # ``coerce_iso`` normalizes naive values as UTC so the wire format always carries tz.
                d[key] = coerce_iso(val)
        return d

    async def create(
        self,
        thread_id: str,
        *,
        assistant_id: str | None = None,
        user_id: str | None | _AutoSentinel = AUTO,
        display_name: str | None = None,
        metadata: dict | None = None,
    ) -> dict:
        # Auto-resolve user_id from contextvar when AUTO; explicit None
        # creates an orphan row (used by migration scripts).
        resolved_user_id = resolve_user_id(user_id, method_name="ThreadMetaRepository.create")
        now = datetime.now(UTC)
        row = ThreadMetaRow(
            thread_id=thread_id,
            assistant_id=assistant_id,
            user_id=resolved_user_id,
            display_name=display_name,
            metadata_json=metadata or {},
            created_at=now,
            updated_at=now,
        )
        async with self._sf() as session:
            session.add(row)
            await session.commit()
            await session.refresh(row)
            return self._row_to_dict(row)

    async def get(
        self,
        thread_id: str,
        *,
        user_id: str | None | _AutoSentinel = AUTO,
    ) -> dict | None:
        resolved_user_id = resolve_user_id(user_id, method_name="ThreadMetaRepository.get")
        async with self._sf() as session:
            row = await session.get(ThreadMetaRow, thread_id)
            if row is None:
                return None
            # Enforce owner filter unless explicitly bypassed (user_id=None).
            if resolved_user_id is not None and row.user_id != resolved_user_id:
                return None
            return self._row_to_dict(row)

    async def check_access(self, thread_id: str, user_id: str, *, require_existing: bool = False) -> bool:
        """Check if ``user_id`` has access to ``thread_id``.

        Two modes - one row, two distinct semantics depending on what
        the caller is about to do:

        - ``require_existing=False`` (default, permissive):
          Returns True for: row missing (untracked legacy thread),
          ``row.user_id`` is None (shared / pre-auth data),
          or ``row.user_id == user_id``. Use for **read-style**
          decorators where treating an untracked thread as accessible
          preserves backward-compat.

        - ``require_existing=True`` (strict):
          Returns True **only** when the row exists AND
          (``row.user_id == user_id`` OR ``row.user_id is None``).
          Use for **destructive / mutating** decorators (DELETE, PATCH,
          state-update) so a thread that has *already been deleted*
          cannot be re-targeted by any caller - closing the
          delete-idempotence cross-user gap where the row vanishing
          made every other user appear to "own" it.
        """
        async with self._sf() as session:
            row = await session.get(ThreadMetaRow, thread_id)
            if row is None:
                return not require_existing
            if row.user_id is None:
                return True
            return row.user_id == user_id

    async def search(
        self,
        *,
        metadata: dict[str, Any] | None = None,
        status: str | None = None,
        limit: int = 100,
        offset: int = 0,
        user_id: str | None | _AutoSentinel = AUTO,
    ) -> list[dict[str, Any]]:
        """Search threads with optional metadata and status filters.

        Owner filter is enforced by default: caller must be in a user
        context. Pass ``user_id=None`` to bypass (migration/CLI).
        """
        resolved_user_id = resolve_user_id(user_id, method_name="ThreadMetaRepository.search")
        stmt = select(ThreadMetaRow).order_by(ThreadMetaRow.updated_at.desc(), ThreadMetaRow.thread_id.desc())
        if resolved_user_id is not None:
            stmt = stmt.where(ThreadMetaRow.user_id == resolved_user_id)
        if status:
            stmt = stmt.where(ThreadMetaRow.status == status)

        if metadata:
            applied = 0
            for key, value in metadata.items():
                try:
                    stmt = stmt.where(json_match(ThreadMetaRow.metadata_json, key, value))
                    applied += 1
                except (ValueError, TypeError) as exc:
                    logger.warning("Skipping metadata filter key %s: %s", ascii(key), exc)
            if applied == 0:
                # Comma-separated plain string (no list repr / nested
                # quoting) so the 400 detail surfaced by the Gateway is
                # easy for clients to read. Sorted for determinism.
                rejected_keys = ", ".join(sorted(str(k) for k in metadata))
                raise InvalidMetadataFilterError(f"All metadata filter keys were rejected as unsafe: {rejected_keys}")

        stmt = stmt.limit(limit).offset(offset)
        async with self._sf() as session:
            result = await session.execute(stmt)
            return [self._row_to_dict(r) for r in result.scalars()]

    async def _check_ownership(self, session: AsyncSession, thread_id: str, resolved_user_id: str | None) -> bool:
        """Return True if the row exists and is owned (or filter bypassed)."""
        if resolved_user_id is None:
            return True  # explicit bypass
        row = await session.get(ThreadMetaRow, thread_id)
        return row is not None and row.user_id == resolved_user_id

    async def update_display_name(
        self,
        thread_id: str,
        display_name: str,
        *,
        user_id: str | None | _AutoSentinel = AUTO,
    ) -> None:
        """Update the display_name (title) for a thread."""
        resolved_user_id = resolve_user_id(user_id, method_name="ThreadMetaRepository.update_display_name")
        async with self._sf() as session:
            if not await self._check_ownership(session, thread_id, resolved_user_id):
                return
            await session.execute(update(ThreadMetaRow).where(ThreadMetaRow.thread_id == thread_id).values(display_name=display_name, updated_at=datetime.now(UTC)))
            await session.commit()

    async def update_status(
        self,
        thread_id: str,
        status: str,
        *,
        user_id: str | None | _AutoSentinel = AUTO,
    ) -> None:
        resolved_user_id = resolve_user_id(user_id, method_name="ThreadMetaRepository.update_status")
        async with self._sf() as session:
            if not await self._check_ownership(session, thread_id, resolved_user_id):
                return
            await session.execute(update(ThreadMetaRow).where(ThreadMetaRow.thread_id == thread_id).values(status=status, updated_at=datetime.now(UTC)))
            await session.commit()

    async def update_metadata(
        self,
        thread_id: str,
        metadata: dict,
        *,
        user_id: str | None | _AutoSentinel = AUTO,
    ) -> None:
        """Merge ``metadata`` into ``metadata_json``.

        Read-modify-write inside a single session/transaction so concurrent
        callers see consistent state. No-op if the row does not exist or
        the user_id check fails.
        """
        resolved_user_id = resolve_user_id(user_id, method_name="ThreadMetaRepository.update_metadata")
        async with self._sf() as session:
            row = await session.get(ThreadMetaRow, thread_id)
            if row is None:
                return
            if resolved_user_id is not None and row.user_id != resolved_user_id:
                return
            merged = dict(row.metadata_json or {})
            merged.update(metadata)
            row.metadata_json = merged
            row.updated_at = datetime.now(UTC)
            await session.commit()

    async def update_owner(
        self,
        thread_id: str,
        owner_user_id: str,
        *,
        user_id: str | None | _AutoSentinel = AUTO,
    ) -> None:
        """Move a thread metadata row to ``owner_user_id``."""
        resolved_user_id = resolve_user_id(user_id, method_name="ThreadMetaRepository.update_owner")
        async with self._sf() as session:
            if not await self._check_ownership(session, thread_id, resolved_user_id):
                return
            await session.execute(update(ThreadMetaRow).where(ThreadMetaRow.thread_id == thread_id).values(user_id=owner_user_id, updated_at=datetime.now(UTC)))
            await session.commit()

    async def delete(
        self,
        thread_id: str,
        *,
        user_id: str | None | _AutoSentinel = AUTO,
    ) -> None:
        resolved_user_id = resolve_user_id(user_id, method_name="ThreadMetaRepository.delete")
        async with self._sf() as session:
            row = await session.get(ThreadMetaRow, thread_id)
            if row is None:
                return
            if resolved_user_id is not None and row.user_id != resolved_user_id:
                return
            await session.delete(row)
            await session.commit()
```

---

## §5 services.py（owner 检查 + context 注入节选）

> `gateway/gateway/services.py` 的隔离相关函数节选（完整未截断，非隔离逻辑省略）：`merge_run_context_overrides`（user_id 透传到 runtime context）、`inject_authenticated_user_context`（请求期盖章 user_id）、`start_run` 的 owner 检查段（stateless run 端点防跨用户）。

```python
# gateway/gateway/services.py（节选：隔离相关函数）
from types import SimpleNamespace
from typing import Any, Mapping

from fastapi import HTTPException, Request

from gateway.deps import get_run_context, ...
from gateway.internal_auth import (
    INTERNAL_SYSTEM_ROLE,
    get_trusted_internal_owner_user_id,
)
from helix.runtime.user_context import reset_current_user, set_current_user


def merge_run_context_overrides(config: dict[str, Any], context: Mapping[str, Any] | None, *, internal: bool = False) -> None:
    """Merge whitelisted keys from ``body.context`` into both ``config['configurable']``
    and ``config['context']`` so they are visible to legacy configurable readers and
    to LangGraph ``ToolRuntime.context`` consumers.

    ``user_id`` is intentionally propagated into ``config['context']`` in addition to
    the whitelisted keys, so non-web callers (e.g. IM channels) that supply identity in
    ``body.context`` keep it on ``ToolRuntime.context``. It is merged with
    ``setdefault`` so a server-authenticated id stamped by
    :func:`inject_authenticated_user_context` always wins over the client-supplied one.
    """
    if not context:
        return
    configurable = config.setdefault("configurable", {})
    runtime_context = config.setdefault("context", {})
    keys = _CONTEXT_CONFIGURABLE_KEYS | _CONTEXT_INTERNAL_CALLER_KEYS if internal else _CONTEXT_CONFIGURABLE_KEYS
    for key in keys:
        if key in context:
            if isinstance(configurable, dict):
                configurable.setdefault(key, context[key])
            if isinstance(runtime_context, dict):
                runtime_context.setdefault(key, context[key])
    # Context-only keys (secrets / runtime flags) land in ``config['context']``
    # only - never ``configurable`` (which is persisted in checkpoints).
    for key in _CONTEXT_RUNTIME_ONLY_KEYS:
        if key in context and isinstance(runtime_context, dict):
            runtime_context.setdefault(key, context[key])
    if "user_id" in context and isinstance(runtime_context, dict):
        runtime_context.setdefault("user_id", context["user_id"])
    # The raw platform user id from IM channels (Feishu open_id, Slack Uxxx, ...)
    # follows the same runtime-context-only rule as user_id: tools may read it,
    # but it never enters ``configurable`` (checkpointed with the thread).
    if "channel_user_id" in context and isinstance(runtime_context, dict):
        runtime_context.setdefault("channel_user_id", context["channel_user_id"])


def inject_authenticated_user_context(
    config: dict[str, Any],
    request: Request,
    *,
    internal_owner_user: Any | None = None,
) -> None:
    """Stamp the authenticated user into the run context for background tools.

    Tool execution may happen after the request handler has returned, so tools
    that persist user-scoped files should not rely only on ambient ContextVars.
    The value comes from server-side auth state, never from client context.
    """

    user = getattr(request.state, "user", None)
    user_id = getattr(user, "id", None)
    if user_id is None:
        return

    if getattr(user, "system_role", None) == INTERNAL_SYSTEM_ROLE:
        runtime_context = config.setdefault("context", {})
        if not isinstance(runtime_context, dict):
            return
        if internal_owner_user is None:
            runtime_context.pop("user_role", None)
            runtime_context.pop("oauth_provider", None)
            runtime_context.pop("oauth_id", None)
            return
        owner_user_id = getattr(internal_owner_user, "id", None)
        if owner_user_id is not None:
            runtime_context["user_id"] = str(owner_user_id)
        runtime_context["user_role"] = getattr(internal_owner_user, "system_role", None)
        runtime_context["oauth_provider"] = getattr(internal_owner_user, "oauth_provider", None)
        runtime_context["oauth_id"] = getattr(internal_owner_user, "oauth_id", None)
        return

    runtime_context = config.setdefault("context", {})
    if isinstance(runtime_context, dict):
        runtime_context["user_id"] = str(user_id)
        runtime_context["user_role"] = getattr(user, "system_role", None)
        runtime_context["oauth_provider"] = getattr(user, "oauth_provider", None)
        runtime_context["oauth_id"] = getattr(user, "oauth_id", None)


# --- start_run 内的 owner 检查段（stateless run 端点防跨用户） ---
#
# stateless run 端点携带 thread_id 在请求 *body*，因此
# @require_permission(owner_check=True) 装饰器（从 path 参数解析
# ownership）无法保护它们。这里在任何 run 创建之前强制执行 thread
# ownership，使得一个用户无法在另一个用户的 thread 上启动 run（或
# 读取 /wait checkpoint state）。缺行（自动创建的临时 thread）和
# NULL-owner 行（共享 / 认证前数据）通过 check_access 保持可访问；
# 仅已被另一用户拥有的 thread 以 404 拒绝，匹配 thread_runs.py 的
# 防枚举行为。内部 channel run 代表 X-Helix-Owner-User-Id 携带的
# connection owner 行事，因此被 scope 到该 owner 而非绕过检查——
# 泄漏的内部 token 绝不能授予跨用户 thread 访问。
async def _start_run_owner_check(request: Request, thread_id: str) -> None:
    owner_user_id = get_trusted_internal_owner_user_id(request)
    user = getattr(request.state, "user", None)
    if user is not None:
        run_ctx = get_run_context(request)
        allowed = await run_ctx.thread_store.check_access(thread_id, str(user.id))
        if not allowed and owner_user_id and getattr(user, "system_role", None) == INTERNAL_SYSTEM_ROLE:
            # Channel workers may also act for the connection owner named in
            # the trusted header (e.g. claiming a legacy default-owned channel
            # thread for its real owner).
            allowed = await run_ctx.thread_store.check_access(thread_id, owner_user_id)
        if not allowed:
            raise HTTPException(status_code=404, detail=f"Thread {thread_id} not found")

    # 把 owner 盖章进 contextvar，供后续 create_or_reject / upsert thread_meta 使用
    owner_context_token = set_current_user(SimpleNamespace(id=owner_user_id)) if owner_user_id else None
    try:
        ...  # 创建 run、upsert thread_meta（见 gateway-runs-and-sse）
    finally:
        if owner_context_token is not None:
            reset_current_user(owner_context_token)
```
