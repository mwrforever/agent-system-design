---
name: auth
description: Gateway 认证全家桶：AuthMiddleware 统一入口、多源认证（本地账密 bcrypt + OIDC OAuth PKCE/state/nonce + PAT Bearer（SHA-256 摘要 + scope 限路由）+ JWT 签发校验）、登录节流（内存/SQL 双后端）、会话 cookie 策略、CSRF Double Submit、内部服务间令牌（X-Helix-Internal-Token，仅进程内回环）、首启 setup 向导与管理员保护（LastAdminRemainsError）、LangGraph 平台兼容鉴权。当要设计多租户 agent 平台的登录/令牌/防 CSRF/防爆破，或排查 401/403/CSRF 失败时使用。
---

# 认证体系

## 何时用

- 设计多用户平台的登录（账密 / SSO / 令牌三轨）
- CSRF、登录节流、会话 cookie 策略
- 服务间内部认证（scheduler/渠道回环调 Gateway）
- 首次启动引导（setup）与管理员自锁保护

## 设计方案（为什么这么设计）

### 1. 认证面只有一扇门

`AuthMiddleware`（auth_middleware.py:70）统一解析请求身份 → `AuthContext`；下游路由只见依赖注入的身份，不做各自为政的解析。OIDC/本地/PAT 是**凭证来源**的差异，不是三套鉴权。

### 2. 四种凭证

| 凭证 | 实现 | 要点 |
|---|---|---|
| 本地账密 | `password.py`（bcrypt）+ `local_provider.py` + SQLite 用户库 | 注册/改密/禁用 |
| OIDC SSO | `oidc.py`（441 行）+ `oidc_state.py` | PKCE + nonce + state cookie 全套；user_provisioning 自动开号 |
| PAT | `pat.py`（246 行） | Bearer `dfp_…`，库存 SHA-256 摘要（原文不落库）；scope 限 threads/runs/projects 路由面 |
| JWT | `jwt.py` | 签发/校验 access token；会话 cookie 策略（HttpOnly 等）由 `session_cookie.py` 集中管理 |

仓储抽象 `UserRepository(ABC)`（repositories/base.py:184）+ SQLite 实现（438 行）——`LastAdminRemainsError` 防止把最后一个管理员删/禁成锁死系统。

### 3. CSRF：Double Submit

`csrf_middleware.py`（288 行）：写方法（POST/PUT/DELETE/PATCH）要求 `X-CSRF-Token` 与 `csrf_token` cookie 匹配 + `is_allowed_auth_origin` 同源校验。前端两侧共用 `readCsrfCookie`（见 [[frontend-streaming-protocol]] fetcher）。PAT 请求走独立放行面。

### 4. 内部令牌：进程内服务间信任

`internal_auth.py`（86 行）：`create_internal_auth_headers()` 产 `X-Helix-Internal-Token`，供 scheduler、IM 渠道 worker **经 HTTP 回环**调 Gateway 时标记"内部调用方"——这正是 run-context 信任边界的入口（`non_interactive` 只对内部调用方生效，见 [[e2e-request-lifecycle]]）。令牌仅在进程内派生，不接受外部提交。

### 5. 节流与首启

- `login_throttle.py` + `persistence/login_throttle`（内存/SQL 双后端）：爆破防护，多实例部署用 SQL 共享计数。
- `routers/auth.py` 的 `/setup-status` + `/initialize`：首启向导；`reset_admin.py` 运维兜底。
- `langgraph_auth.py`：LangGraph 平台兼容层（Studio principal 特判 + owner 过滤），外部 SDK 客户端无需改造即可接上本网关。
- 显式关闭鉴权的 `auth_disabled.py` 只服务单机演示，前端配套 static user。

## 实现索引

`references/code/backend/app/gateway/`：

| 文件 | 行数 | 职责 |
|---|---|---|
| `auth_middleware.py` | 231 | 统一认证入口 |
| `auth/oidc.py` + `oidc_state.py` | 441+122 | SSO 全套 |
| `auth/pat.py` | 246 | PAT |
| `auth/repositories/sqlite.py` + `base.py` | 438+184 | 用户仓储 |
| `auth/local_provider.py` / `password.py` / `jwt.py` / `session_cookie.py` | 157/81/55/110 | 本地登录/哈希/令牌/cookie |
| `auth/login_throttle.py` / `user_provisioning.py` / `reset_admin.py` | 121/120/91 | 节流/开号/兜底 |
| `csrf_middleware.py` | 288 | Double Submit |
| `internal_auth.py` | 86 | 内部令牌 |
| `langgraph_auth.py` / `auth_disabled.py` | 349/58 | 平台兼容/免认证模式 |
| `routers/auth.py` | 1161 | 登录/登出/改密/PAT/OIDC 回调/setup |
| `routers/admin_users.py` / `user_preferences.py` / `im_notification_preferences.py` | 119/69/49 | 用户管理面 |

## 反模式与陷阱

- ❌ PAT 原文落库 → 泄库即泄凭证；只存 SHA-256 摘要。
- ❌ OIDC 缺 state/nonce → CSRF/重放；全套走 oidc_state。
- ❌ 内部令牌从请求参数接受 → 外部可伪造"内部调用方"抹除 non_interactive 边界；仅进程内派生。
- ❌ 节流只做内存 → 多实例下爆破分散命中；SQL 后端共享。
- ❌ 删除接口不保护最后管理员 → 系统锁死；LastAdminRemainsError。
- ❌ 写接口只依赖同源 cookie 无 CSRF token → 浏览器侧可被跨站写。

## 落地参考

**自测方向**：错误密码连续 N 次后节流生效且跨实例（SQL 后端）；PAT scope 外路由 403；OIDC state 不匹配拒绝；CSRF token 缺失写请求 403；前端 401 → /login 重定向带 next。

**调试**：`AuthContext` 构造日志、节流触发日志、CSRF 拒绝日志。

## 进一步阅读

- [[safety-and-guardrails]]（认证之后的授权）、[[e2e-request-lifecycle]]（②鉴权步）
- [[frontend-app-design]]（SSR 鉴权守卫与登录页）
