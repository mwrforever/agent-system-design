# 完整源码：SSR 鉴权守卫 + CSRF 双路径对称契约

> 本文件给出 `frontend/src/app/layout.tsx`（root layout）+ `frontend/src/app/workspace/layout.tsx`（workspace 鉴权守卫穷尽 switch）+ `frontend/src/core/auth/server.ts`（`getServerSideUser`）+ `frontend/src/core/auth/types.ts`（`AuthResult` tagged union）+ `frontend/src/core/auth/gateway-config.ts` + `frontend/src/core/auth/auth-disabled-user.ts` + `frontend/src/core/auth/static-user.ts` + `frontend/src/app/(auth)/layout.tsx`（穷尽 switch）+ `frontend/src/core/api/fetcher.ts`（CSRF 前端侧）+ `gateway/gateway/csrf_middleware.py`（对称契约的另半边）的**完整实现**。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*` / env 前缀 `HELIX_*` / 内部头 `X-Helix-Internal-Token`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

## §0 App Router 布局入口（root layout + workspace layout）

```tsx
// frontend/src/app/layout.tsx
import "katex/dist/katex.min.css";
import "@/styles/globals.css";

import { type Metadata } from "next";

import { ThemeProvider } from "@/components/theme-provider";
import { I18nProvider } from "@/core/i18n/context";
import { detectLocaleServer } from "@/core/i18n/server";

export const metadata: Metadata = {
  title: "Helix",
  description: "A LangChain-based framework for building super agents.",
};

export default async function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const locale = await detectLocaleServer();
  return (
    <html lang={locale} suppressContentEditableWarning suppressHydrationWarning>
      <body>
        <ThemeProvider attribute="class" enableSystem disableTransitionOnChange>
          <I18nProvider initialLocale={locale}>{children}</I18nProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
```

```tsx
// frontend/src/app/workspace/layout.tsx
import { redirect } from "next/navigation";

import { GatewayOfflineFallback } from "@/components/workspace/gateway-offline-fallback";
import { AuthProvider } from "@/core/auth/AuthProvider";
import { getServerSideUser } from "@/core/auth/server";
import { assertNever } from "@/core/auth/types";

import { WorkspaceContent } from "./workspace-content";

export const dynamic = "force-dynamic";   // 鉴权结果每请求不同，强制动态防缓存串用户

export default async function WorkspaceLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const result = await getServerSideUser();

  switch (result.tag) {
    case "authenticated":
      return (
        <AuthProvider initialUser={result.user}>
          <WorkspaceContent>{children}</WorkspaceContent>
        </AuthProvider>
      );
    case "needs_setup":
      redirect("/setup");
    case "system_setup_required":
      redirect("/setup");
    case "unauthenticated":
      redirect("/login");
    case "gateway_unavailable":
      // 渲染 fallback 保留 AuthProvider，让用户能登出/重试（而非跳登录踢走已登录用户）
      return (
        <GatewayOfflineFallback>
          <WorkspaceContent gatewayUnavailable>{children}</WorkspaceContent>
        </GatewayOfflineFallback>
      );
    case "config_error":
      throw new Error(result.message);   // 让 Next.js error boundary 接管
    default:
      assertNever(result);               // TS 强制穷尽：新增 tag 不更新 switch 编译失败
  }
}
```

## §1 AuthResult tagged union（auth/types.ts）

```ts
// frontend/src/core/auth/types.ts
import { z } from "zod";

// ── User schema（单一事实源）──────────────────────────────────

export const userSchema = z.object({
  id: z.string(),
  email: z.string().email(),
  system_role: z.enum(["admin", "user"]),
  needs_setup: z.boolean().optional().default(false),
  oauth_provider: z.string().nullable().optional().default(null),
});

export type User = Omit<z.infer<typeof userSchema>, "oauth_provider"> & {
  oauth_provider?: string | null;
};

// ── SSR auth result（tagged union）────────────────────────────

export type AuthResult =
  | { tag: "authenticated"; user: User }
  | { tag: "needs_setup"; user: User }
  | { tag: "system_setup_required" }
  | { tag: "unauthenticated" }
  | { tag: "gateway_unavailable" }
  | { tag: "config_error"; message: string };

// 穷尽 switch 的兜底：新增 tag 不更新 switch -> TS 编译失败
export function assertNever(x: never): never {
  throw new Error(`Unexpected auth result: ${JSON.stringify(x)}`);
}

export function buildLoginUrl(returnPath: string): string {
  return `/login?next=${encodeURIComponent(returnPath)}`;
}

// ── 后端错误响应解析 ───────────────────────────────────────────

const AUTH_ERROR_CODES = [
  "invalid_credentials",
  "token_expired",
  "token_invalid",
  "user_not_found",
  "email_already_exists",
  "provider_not_found",
  "not_authenticated",
  "system_already_initialized",
] as const;

export type AuthErrorCode = (typeof AUTH_ERROR_CODES)[number];

export interface AuthErrorResponse {
  code: AuthErrorCode;
  message: string;
}

const AuthErrorSchema = z.object({
  code: z.enum(AUTH_ERROR_CODES),
  message: z.string(),
});

const ErrorDetailSchema = z.object({
  msg: z.string(),
  type: z.enum(["value_error"]),
  loc: z.array(z.string()),
});

export function parseAuthError(data: unknown): AuthErrorResponse {
  // 先试顶层 {code, message}
  const parsed = AuthErrorSchema.safeParse(data);
  if (parsed.success) return parsed.data;

  // 解 FastAPI 的 {detail: {code, message}} 信封
  if (typeof data === "object" && data !== null && "detail" in data) {
    const detail = (data as Record<string, unknown>).detail;
    const nested = AuthErrorSchema.safeParse(detail);
    if (nested.success) return nested.data;
    // 遗留 string-detail 响应
    if (typeof detail === "string") {
      return { code: "invalid_credentials", message: detail };
    } else if (Array.isArray(detail)) {
      // 处理 error detail 列表（如 Pydantic 校验）
      const firstDetail = detail[0];
      if (typeof firstDetail === "object" && firstDetail !== null) {
        const errorDetail = ErrorDetailSchema.safeParse(firstDetail);
        if (errorDetail.success) {
          return { code: "invalid_credentials", message: errorDetail.data.msg };
        }
      }
    } else if (typeof detail === "object" && detail !== null) {
      const errorDetail = ErrorDetailSchema.safeParse(detail);
      if (errorDetail.success) {
        return { code: "invalid_credentials", message: errorDetail.data.msg };
      }
    }
  }

  return { code: "invalid_credentials", message: "Authentication failed" };
}
```

## §2 getServerSideUser（auth/server.ts）

```ts
// frontend/src/core/auth/server.ts
import { cookies } from "next/headers";

import { isStaticWebsiteOnly } from "../static-mode";

import { AUTH_DISABLED_USER, isAuthDisabledMode } from "./auth-disabled-user";
import { getGatewayConfig } from "./gateway-config";
import { STATIC_WEBSITE_USER } from "./static-user";
import { type AuthResult, userSchema } from "./types";

const SSR_AUTH_TIMEOUT_MS = 5_000;

/**
 * 用请求的 cookies 从 gateway 拉已认证用户。返回 tagged AuthResult --
 * 调用方用穷举 switch，无 try/catch。
 */
export async function getServerSideUser(): Promise<AuthResult> {
  if (isStaticWebsiteOnly()) {
    return {
      tag: "authenticated",
      user: STATIC_WEBSITE_USER,
    };
  }

  if (isAuthDisabledMode()) {
    return {
      tag: "authenticated",
      user: AUTH_DISABLED_USER,
    };
  }

  const cookieStore = await cookies();
  const sessionCookie = cookieStore.get("access_token");

  let internalGatewayUrl: string;
  try {
    internalGatewayUrl = getGatewayConfig().internalGatewayUrl;
  } catch (err) {
    return { tag: "config_error", message: String(err) };
  }

  if (!sessionCookie) {
    // 无 session -- 检查系统是否已初始化。
    const setupController = new AbortController();
    const setupTimeout = setTimeout(
      () => setupController.abort(),
      SSR_AUTH_TIMEOUT_MS,
    );
    try {
      const setupRes = await fetch(
        `${internalGatewayUrl}/api/v1/auth/setup-status`,
        {
          cache: "no-store",
          signal: setupController.signal,
        },
      );
      clearTimeout(setupTimeout);
      if (setupRes.ok) {
        const setupData = (await setupRes.json()) as { needs_setup?: boolean };
        if (setupData.needs_setup) {
          return { tag: "system_setup_required" };
        }
      }
    } catch {
      clearTimeout(setupTimeout);
      // setup-status 不可达/超时 -> 回退 unauthenticated。
    }
    return { tag: "unauthenticated" };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), SSR_AUTH_TIMEOUT_MS);

  try {
    const res = await fetch(`${internalGatewayUrl}/api/v1/auth/me`, {
      headers: { Cookie: `access_token=${sessionCookie.value}` },
      cache: "no-store",                        // 鉴权结果每请求不同，禁缓存
      signal: controller.signal,
    });
    clearTimeout(timeout); // 立即清，覆盖所有响应分支

    if (res.ok) {
      const parsed = userSchema.safeParse(await res.json());
      if (!parsed.success) {
        console.error("[SSR auth] Malformed /auth/me response:", parsed.error);
        return { tag: "gateway_unavailable" };
      }
      if (parsed.data.needs_setup) {
        return { tag: "needs_setup", user: parsed.data };
      }
      return { tag: "authenticated", user: parsed.data };
    }
    if (res.status === 401 || res.status === 403) {
      return { tag: "unauthenticated" };
    }
    console.error(`[SSR auth] /api/v1/auth/me responded ${res.status}`);
    return { tag: "gateway_unavailable" };     // 区分于 unauthenticated：网关抖动不踢登录
  } catch (err) {
    clearTimeout(timeout);
    console.error("[SSR auth] Failed to reach gateway:", err);
    return { tag: "gateway_unavailable" };
  }
}
```

## §3 gateway 配置 + auth-disabled 合成用户 + 静态站用户

```ts
// frontend/src/core/auth/gateway-config.ts
import { z } from "zod";

const gatewayConfigSchema = z.object({
  internalGatewayUrl: z.string().url(),        // SSR 直连 gateway 的内部 URL（绕 nginx）
  trustedOrigins: z.array(z.string()).min(1),
});

export type GatewayConfig = z.infer<typeof gatewayConfigSchema>;

let _cached: GatewayConfig | null = null;

export function getGatewayConfig(): GatewayConfig {
  if (_cached) return _cached;

  const rawUrl = process.env.HELIX_INTERNAL_GATEWAY_BASE_URL?.trim();
  const internalGatewayUrl =
    rawUrl && rawUrl.length > 0
      ? rawUrl.replace(/\/+$/, "")
      : "http://127.0.0.1:8001";

  const rawOrigins = process.env.HELIX_TRUSTED_ORIGINS?.trim();
  const trustedOrigins = rawOrigins
    ? rawOrigins
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
    : ["http://localhost:3000"];

  _cached = gatewayConfigSchema.parse({ internalGatewayUrl, trustedOrigins });
  return _cached;
}
```

```ts
// frontend/src/core/auth/auth-disabled-user.ts
import type { User } from "./types";

// 本地/E2E auth-disabled 模式的合成 admin（生产环境硬门拒掉）
export const AUTH_DISABLED_USER: User = {
  id: "default",
  email: "default@test.local",
  system_role: "admin",
  needs_setup: false,
  oauth_provider: null,
};

const PRODUCTION_ENV_VALUES = new Set(["prod", "production"]);

function isExplicitProductionEnvironment() {
  return ["HELIX_ENV", "ENVIRONMENT"].some((name) =>
    PRODUCTION_ENV_VALUES.has((process.env[name] ?? "").trim().toLowerCase()),
  );
}

// auth-disabled 双重门：HELIX_AUTH_DISABLED=1 且非显式生产环境
export function isAuthDisabledMode() {
  return (
    process.env.HELIX_AUTH_DISABLED === "1" &&
    !isExplicitProductionEnvironment()
  );
}
```

```ts
// frontend/src/core/auth/static-user.ts
import type { User } from "./types";

// 纯静态站模式（NEXT_PUBLIC_STATIC_WEBSITE_ONLY=true）的合成用户
export const STATIC_WEBSITE_USER: User = {
  id: "static-website-user",
  email: "static@example.local",
  system_role: "admin",
  needs_setup: false,
  oauth_provider: null,
};
```

## §3a (auth)/layout.tsx 穷尽 switch（登录/注册/setup 页守卫）

```tsx
// frontend/src/app/(auth)/layout.tsx
import { redirect } from "next/navigation";
import { type ReactNode } from "react";

import { GatewayOfflineFallback } from "@/components/workspace/gateway-offline-fallback";
import { AuthProvider } from "@/core/auth/AuthProvider";
import { getServerSideUser } from "@/core/auth/server";
import { assertNever } from "@/core/auth/types";

export const dynamic = "force-dynamic";

export default async function AuthLayout({
  children,
}: {
  children: ReactNode;
}) {
  const result = await getServerSideUser();

  switch (result.tag) {
    case "authenticated":
      redirect("/workspace");                    // 已登录用户访问登录页 -> 跳走
    case "needs_setup":
      // 允许访问 setup 页
      return <AuthProvider initialUser={result.user}>{children}</AuthProvider>;
    case "system_setup_required":
    case "unauthenticated":
      return <AuthProvider initialUser={null}>{children}</AuthProvider>;
    case "gateway_unavailable":
      // auth 页自身无 banner，故此处渲染一个。fallback 的 AuthProvider 替代先前
      // 把用户锁在裸 HTML 里、无登出/重试能力的分支。
      return (
        <GatewayOfflineFallback renderBanner>
          <div className="flex h-screen flex-col items-center justify-center gap-4">
            <p className="text-muted-foreground">
              Service temporarily unavailable.
            </p>
          </div>
        </GatewayOfflineFallback>
      );
    case "config_error":
      throw new Error(result.message);
    default:
      assertNever(result);
  }
}
```

## §4 CSRF 前端侧（api/fetcher.ts）

```ts
// frontend/src/core/api/fetcher.ts
import { buildLoginUrl } from "@/core/auth/types";

/** gateway CSRFMiddleware 检查的方法。 */
export type StateChangingMethod = "POST" | "PUT" | "DELETE" | "PATCH";

export const STATE_CHANGING_METHODS: ReadonlySet<StateChangingMethod> = new Set(
  ["POST", "PUT", "DELETE", "PATCH"],
);

/** gateway should_check_csrf 决策的镜像。 */
export function isStateChangingMethod(method: string): boolean {
  return (STATE_CHANGING_METHODS as ReadonlySet<string>).has(
    method.toUpperCase(),
  );
}

const CSRF_COOKIE_PREFIX = "csrf_token=";

/**
 * 读 gateway 在登录时下发的 csrf_token cookie。
 *
 * SSR-safe：document undefined 时返回 null，故同一 helper 可从 server component
 * import 无需 guard。
 *
 * 用 String.split 而非 regex 绕开 ESLint 的 prefer-regexp-exec 规则；cookie 值
 * 的 `; ` 分隔符由 gateway 设置（非浏览器），格式稳定。
 */
export function readCsrfCookie(): string | null {
  if (typeof document === "undefined") return null;
  for (const pair of document.cookie.split("; ")) {
    if (pair.startsWith(CSRF_COOKIE_PREFIX)) {
      return decodeURIComponent(pair.slice(CSRF_COOKIE_PREFIX.length));
    }
  }
  return null;
}

/**
 * 带 credentials 与自动 CSRF 的 fetch。
 *
 * 每个业务 API 调用都需的两个集中契约：
 *
 * 1. ``credentials: "include"`` -> 跨-origin SSR 路由请求带 HttpOnly access_token cookie。
 * 2. 状态变更方法（POST/PUT/DELETE/PATCH）的 ``X-CSRF-Token`` 头，从 ``csrf_token`` cookie
 *    回显。gateway 的 CSRFMiddleware 强制 Double Submit Cookie 比较，缺 header 返回
 *    403 -- 静默破坏每个用裸 ``fetch()`` 而非此 wrapper 的调用点。
 *
 * 401 自动跳 ``/login``。调用方提供的 header 保留；helper 仅在 header 不存在时 ADD
 * CSRF header，故显式 override 优先。
 */
export async function fetch(
  input: RequestInfo | string,
  init?: RequestInit,
): Promise<Response> {
  const url = typeof input === "string" ? input : input.url;

  // 状态变更方法注入 CSRF。GET/HEAD/OPTIONS/TRACE 跳过，与 gateway should_check_csrf 逐字对齐。
  let headers = init?.headers;
  if (isStateChangingMethod(init?.method ?? "GET")) {
    const token = readCsrfCookie();
    if (token) {
      // 新 Headers 实例，不 mutate 调用方提供的对象。
      const merged = new Headers(headers);
      if (!merged.has("X-CSRF-Token")) {
        merged.set("X-CSRF-Token", token);
      }
      headers = merged;
    }
  }

  const res = await globalThis.fetch(url, {
    ...init,
    headers,
    credentials: "include",
  });

  if (res.status === 401) {
    window.location.href = buildLoginUrl(window.location.pathname);
    throw new Error("Unauthorized");
  }

  return res;
}

/**
 * 为 CSRF 保护的请求构造 header。
 *
 * 新代码**优先用 fetchWithAuth** -- 它在状态变更方法上自动注入 header。此 helper
 * 供需手动组合 header 的遗留调用点（如 next/server route handler 里自建 Headers）。
 *
 * 按 RFC-001：Double Submit Cookie 模式。
 */
export function getCsrfHeaders(): HeadersInit {
  const token = readCsrfCookie();
  return token ? { "X-CSRF-Token": token } : {};
}
```

## §5 gateway 侧 CSRFMiddleware（对称契约的另半边）

> 本节是 gateway 侧 `CSRFMiddleware` 完整源码，展示与前端 `fetcher.ts` + `api-client.ts:onRequest` 对称的契约。gateway 侧的完整认证上下文（`AuthMiddleware` / `user_context` / 内部 token）见 [[auth]]。

```python
# gateway/gateway/csrf_middleware.py
"""FastAPI 的 CSRF 保护中间件。

按 RFC-001：状态变更操作需 CSRF 防护。
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
    """检测原始客户端请求是否经 HTTPS。"""
    return _request_scheme(request) == "https"


def generate_csrf_token() -> str:
    """生成安全随机 CSRF token。"""
    return secrets.token_urlsafe(CSRF_TOKEN_LENGTH)


def should_check_csrf(request: Request) -> bool:
    """决定请求是否需 CSRF 校验。

    CSRF 只查状态变更方法（POST/PUT/DELETE/PATCH）。GET/HEAD/OPTIONS/TRACE 按
    RFC 7231 豁免。前端 STATE_CHANGING_METHODS 与此逐字对齐。
    """
    if request.method not in ("POST", "PUT", "DELETE", "PATCH"):
        return False

    if is_auth_disabled():
        return False

    path = request.url.path.rstrip("/")
    # 豁免 /api/v1/auth/me 端点
    if path == "/api/v1/auth/me":
        return False
    # 入站 webhook 经 provider 专属签名自证（如 GitHub X-Hub-Signature-256），
    # 不走 CSRF 双提交 cookie。
    if request.url.path.startswith("/api/webhooks/"):
        return False
    return True


_AUTH_EXEMPT_PATHS: frozenset[str] = frozenset(
    {
        "/api/v1/auth/login/local",
        "/api/v1/auth/logout",
        "/api/v1/auth/register",
        "/api/v1/auth/initialize",
    }
)


def is_auth_endpoint(request: Request) -> bool:
    """检查请求是否打到 auth 端点。

    auth 端点首次调用无需 CSRF 校验（无 token）。
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

    # 浏览器 Origin 只有 scheme/host/port。拒绝 URL 形或带凭证值。
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
    """从 RFC 7239 Forwarded 头首条目取参数。"""
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
    """构造浏览器目标的 URL origin。"""
    scheme = _request_scheme(request)
    host = _forwarded_param(request, "host") or _first_header_value(request.headers.get("x-forwarded-host")) or request.headers.get("host") or request.url.netloc

    forwarded_port = _first_header_value(request.headers.get("x-forwarded-port"))
    if forwarded_port and ":" not in host.rsplit("]", 1)[-1]:
        host = f"{host}:{forwarded_port}"

    return _normalize_origin(f"{scheme}://{host}")


def is_allowed_auth_origin(request: Request) -> bool:
    """auth POST 仅允许同源或显式配置 origin。

    login/register/initialize 豁免双提交 token（首次浏览器客户端无 CSRF token）。
    但它们仍创建 session cookie，故带恶意 Origin 头的浏览器请求必须拒绝，防 login CSRF /
    session fixation。无 Origin 的请求放行（curl/移动集成等非浏览器客户端）。
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
    """Double Submit Cookie 模式的 CSRF 保护中间件。"""

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(self, request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        _is_auth = is_auth_endpoint(request)

        # auth 端点首访：无 token，改用 Origin 校验防 login CSRF
        if should_check_csrf(request) and _is_auth and not is_allowed_auth_origin(request):
            return JSONResponse(
                status_code=403,
                content={"detail": "Cross-site auth request denied."},
            )

        # 非 auth 状态变更：双提交（cookie token == header token，常时比较）
        if should_check_csrf(request) and not _is_auth:
            cookie_token = request.cookies.get(CSRF_COOKIE_NAME)
            header_token = request.headers.get(CSRF_HEADER_NAME)

            if not cookie_token or not header_token:
                return JSONResponse(
                    status_code=403,
                    content={"detail": "CSRF token missing. Include X-CSRF-Token header."},
                )

            if not secrets.compare_digest(cookie_token, header_token):
                return JSONResponse(
                    status_code=403,
                    content={"detail": "CSRF token mismatch."},
                )

        response = await call_next(request)

        # 建 session 的 auth 端点同时下发 CSRF cookie
        if _is_auth and request.method == "POST":
            # 为 session 生成新 CSRF token
            csrf_token = generate_csrf_token()
            is_https = is_secure_request(request)
            response.set_cookie(
                key=CSRF_COOKIE_NAME,
                value=csrf_token,
                httponly=False,  # Double Submit Cookie 模式必须 JS 可读
                secure=is_https,
                samesite="strict",
                # 与 access_token cookie 寿命对齐（auth.py::_set_session_cookie），
                # 双提交对永不分叉。session-only csrf_token 会被 iOS Safari 终止桌面
                # PWA 时驱逐，而持久 access_token 存活 -- 用户"已登录"却发不出任何
                # 状态变更请求（403 "CSRF token missing"）。
                max_age=get_auth_config().token_expiry_days * 24 * 3600 if is_https else None,
            )

        return response


def get_csrf_token(request: Request) -> str | None:
    """从当前请求 cookie 取 CSRF token。

    服务端渲染需在 form 或 header 嵌 token 时用。
    """
    return request.cookies.get(CSRF_COOKIE_NAME)
```

### §5a 对称契约对照表

| 维度 | 前端（`fetcher.ts` + `api-client.ts`） | gateway（`csrf_middleware.py`） |
|---|---|---|
| 状态变更方法集合 | `STATE_CHANGING_METHODS = {POST,PUT,DELETE,PATCH}` | `should_check_csrf`: `request.method not in ("POST","PUT","DELETE","PATCH")` |
| 判定方法 | `isStateChangingMethod(method)` | `should_check_csrf(request)` |
| cookie 名 | `CSRF_COOKIE_PREFIX = "csrf_token="` | `CSRF_COOKIE_NAME = "csrf_token"` |
| header 名 | `"X-CSRF-Token"` | `CSRF_HEADER_NAME = "X-CSRF-Token"` |
| token 读取 | `readCsrfCookie()` 逐请求读 `document.cookie` | `request.cookies.get(CSRF_COOKIE_NAME)` |
| 注入点 1（SDK） | `createCompatibleClient` 的 `onRequest: injectCsrfHeader` | n/a（gateway 是校验方） |
| 注入点 2（REST） | `fetcher.ts:fetch` 包装 | n/a |
| 校验 | n/a（前端是注入方） | `secrets.compare_digest(cookie_token, header_token)` 常时比较 |
| 缺 token | n/a | 403 `"CSRF token missing. Include X-CSRF-Token header."` |
| 不匹配 | n/a | 403 `"CSRF token mismatch."` |
| cookie 下发 | n/a（gateway 管） | auth 端点 POST 响应 `set_cookie`，`httponly=False`、`max_age` 与 `access_token` 对齐 |
| auth 端点首访豁免 | n/a | 改用 `is_allowed_auth_origin` Origin 校验防 login CSRF |
| webhook 豁免 | n/a | `request.url.path.startswith("/api/webhooks/")` 豁免（provider 签名自证） |

**关键不变量**：前端两注入路径（SDK `onRequest` + `fetcher.fetch`）共享 `readCsrfCookie` + `STATE_CHANGING_METHODS` 一份事实源；gateway 的 `should_check_csrf` 与前端的 `STATE_CHANGING_METHODS` 逐字对齐。任一侧改方法集合或 cookie/header 名，另一侧必须同步，否则状态变更请求 403。
