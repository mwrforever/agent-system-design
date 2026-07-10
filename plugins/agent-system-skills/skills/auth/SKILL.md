---
name: auth
description: 设计生产级 agent 平台的三层认证--Web HttpOnly cookie JWT + 进程内内部 token（scheduler/channels）+ OAuth/OIDC，配 fail-closed 闸门、user_context contextvar 全链路传播、token_version 吊销、CSRF 双提交。给出 AuthMiddleware 等完整真实代码与在端到端链路 ②认证 的位置。当你要加认证/鉴权/内部 token/CSRF/OAuth/per-user 隔离、排查"串用户"或 401/403、做 token 吊销时调用本 skill。
---

## 何时用

- 给 agent 平台加认证/鉴权，或区分"认证（你是谁）"与"授权（你能干啥）"
- 需要进程内内部 token：让 scheduler / IM channels 这类受信后端调用者免走浏览器 cookie 路径
- 加 OAuth/OIDC（Keycloak/Google 等）作为外部身份源，落地为与本地登录同款的 cookie JWT
- 排查"串用户"（per-user 目录落到错的桶）、401/403、token 失效不彻底
- 做 token 吊销（改密即全局登出旧会话）而不维护 token 黑名单
- 加 CSRF 防护，或排查"已登录却发不出 POST"（双提交 cookie 与 session cookie 寿命分叉）
- 新增一条入站路径，需要它汇合到与现有路径相同的 `user_context` contextvar

## 设计方案（为什么这么设计）

### 核心定位：在端到端链路 ②认证 处把"凭证来源"收敛为"一个 user"

本 skill 是脊柱 [[e2e-request-lifecycle]] 的 ②认证 跳的深度。三条入站路径（Web 前端 / IM 钉钉 / 定时任务）的凭证来源各异，但必须在进入 ③路由 之前汇合成同一个 `user` 对象，写入同一个 `user_context` contextvar，此后 ③–⑧ 全链路只读 contextvar、不再关心凭证来源。这是"user_id 全链路隔离"跨切不变量的起点。

### 三层认证并存的理由（为什么不是一个统一凭证）

三条入站路径的**调用方信任级别与传输通道**根本不同，硬塞进单一凭证会引入不可接受的取舍：

1. **Web HttpOnly cookie JWT**--浏览器调用方，**不可信**。凭证经浏览器保管，面临 XSS 偷 token、CSRF 伪造请求两类威胁。故 token 放 `httponly=True` cookie（JS 不可读，防 XSS），`samesite=lax`（防跨站 POST 带 cookie），配 CSRF 双提交（防 CSRF）。JWT 用 HS256 对称签名，载荷含 `sub`(user_id) + `exp` + `ver`(token_version)。

2. **进程内内部 token**--scheduler / IM channels 调用方，**受信**。这些是同进程或同部署的后端服务，不经过浏览器，无 XSS/CSRF 面。用一个进程级共享密钥（`X-Helix-Internal-Token` 头、`HELIX_INTERNAL_AUTH_TOKEN` env）即可。额外提供 `X-Helix-Owner-User-Id` 头：内部调用者标明"我替哪个 IM 用户发的"，使 per-user 目录落到真实 channel 用户而非 `"default"`。该 owner 头**仅在内部 token 校验通过后才生效**--浏览器调用者塞的 owner 头被无视，防伪造身份。

3. **OAuth/OIDC**--外部身份源（Keycloak/Google），**半信**。OIDC 不在每请求闸门里跑：它在前端发起的重定向流里完成（discovery -> 授权 URL -> 回调换码 -> 校验 ID token -> 落库/匹配用户），最后**签发与本地登录同款的 cookie JWT**。此后请求仍走闸门的 cookie 分支。换言之 OAuth 只是"凭证怎么来"的第三条路，闸门与下游不变。

把三者并存而非统一，是因为：浏览器路径需要 cookie 的浏览器安全语义（HttpOnly/SameSite/CSRF）；内部路径需要零往返、零外部依赖的进程内握手；OAuth 需要重定向流与外部 IdP。它们在 `AuthMiddleware` 里按优先级汇合（内部 token > cookie JWT > auth-disabled 合成 admin > 401），各自解析出 `user`，此后无差别。

### fail-closed 原则（默认拒绝）

`AuthMiddleware` 对非公共路径采取**默认拒绝**：三凭证皆无有效者，直接 401 `NOT_AUTHENTICATED`，绝不"无凭证即匿名通过"。这条原则在三个细节上被反复强化：

- 闸门主体：`else` 分支返回 401，无任何"匿名用户"兜底（auth-disabled 合成 admin 是受生产环境硬门保护的本地后门，不算匿名）。
- 严格 JWT 校验：cookie 存在但内容是垃圾字符串时，**当场 401** 而非静默放行。真实源码注释把这条称作关闭"junk cookie bypass"漏洞--否则 `/api/models` 这类非隔离路由会把任意 cookie 形态字符串当认证。
- auth-disabled 后门双重门：`is_auth_disabled()` 要求 `HELIX_AUTH_DISABLED=1` **且**当前非显式生产环境（`HELIX_ENV`/`ENVIRONMENT` 不为 prod）。仅凭 env=1 在生产不开后门。

### user_context contextvar 全链路传播

认证解析出的 `user` 写入 `helix.runtime.user_context` 模块的 `_current_user` ContextVar（名为 `helix_current_user`）。下游经两个入口读它：

- `get_effective_user_id()`--文件系统路径解析用，未设置回退 `DEFAULT_USER_ID`（`"default"`），**永不抛**。
- `resolve_runtime_user_id(runtime)`--工具/中间件用，优先读 `runtime.context["user_id"]`（跨 task/进程边界仍存活的来源），回退 contextvar，再回退 `DEFAULT_USER_ID`。

ContextVar 在 asyncio 下是 **task-local**：每个 FastAPI 请求跑在各自 task，天然隔离。但有两处必须显式处理：

1. **复位**：`set_current_user` 返回 token，`AuthMiddleware.dispatch` 在 `finally` 里 `reset_current_user(token)`。若漏掉 finally，task 复用场景下 contextvar 会串到下一个请求的用户（跨请求串用户）。
2. **跨边界**：`asyncio.create_task` / `asyncio.to_thread` 会继承父 task 上下文（通常即预期）；后台任务**不应**看到前台用户时，用 `contextvars.copy_context()` 取干净副本。`runtime.context["user_id"]` 是为 worker 池/未来跨进程驱动准备的、不依赖 contextvar 的备份信道。

### 角色分离：框架层持有 contextvar，应用层写凭证

`user_context.py` 故意定义在**框架层**（`core/helix/runtime/`），用 `CurrentUser` Protocol（结构化类型，只要 `.id: str`）解耦，使框架层**无需 import 应用层的具体 `User` 类**。`User` 类、JWT、内部 token、OIDC、cookie 设置全在**应用层**（`gateway/gateway/auth/`）。依赖方向单向：应用层写 contextvar，框架层读 contextvar。这是 [[core-app-boundary]] 单向依赖硬规则在认证侧的落点--若在 `core/helix/` 里 import 应用层凭证模块（如 `gateway.internal_auth`），CI 边界测试会拦。

另一层角色分离是**认证 vs 授权**：`AuthMiddleware` 只回答"你是谁"（盖 `request.state.user` + contextvar），`@require_permission(owner_check=True)` 回答"你能干啥"（逐资源 owner 校验，如"用户 A 不能靠猜 URL 读用户 B 的 thread"）。闸门已盖 `request.state.auth = AuthContext(user, permissions)`，使 `@require_permission` 短路掉二次 JWT 解码 + DB 查找。

### token_version 吊销（无需黑名单）

改密即全局登出所有旧会话，靠 JWT 载荷里的 `ver` 字段 + 库中 `User.token_version` 单次比较实现，无需维护 token 黑名单：

- 签发：`create_access_token(user_id, token_version=user.token_version)` 把当前版本号写进 `ver`。
- 吊销：改密路由 `user.token_version += 1` 后 `update_user`，并**重发**带新 `ver` 的 cookie（本会话续上）。
- 校验：`get_current_user_from_request` 解码后比 `user.token_version != payload.ver` -> 401 `TOKEN_INVALID`("Token revoked (password changed)")。

结果：所有持有旧 `ver` 的 token 在下一次请求即被拒；无需黑名单、无需服务端记忆、无需等 TTL 过期。auth-disabled 合成 admin 的 `token_version=0` 不参与此机制（它不签 JWT）。

### CSRF 双提交（与 cookie JWT 正交）

状态变更请求（POST/PUT/DELETE/PATCH）需 CSRF 防护，用 **Double-Submit Cookie**：`csrf_token` cookie（`httponly=False`，JS 可读）与 `X-CSRF-Token` 请求头（前端 JS 从 cookie 读出后塞入）必须常时相等。攻击者站点能让浏览器带上 cookie，但同源策略使其读不到 cookie 值、无法伪造匹配的 header。

两处特殊处理：

- **auth 端点首访**：login/register/initialize 首次调用还没有 CSRF token，豁免双提交，改用 **Origin 校验**（`is_allowed_auth_origin`）防 login CSRF / session fixation--仅同源或显式配置 origin 的 POST 放行。
- **cookie 寿命对齐**：`csrf_token` 的 `max_age` 必须与 `access_token` 一致。真实踩坑：若 csrf 是 session-only、access_token 是持久 cookie，iOS Safari 结束桌面 PWA 时驱逐前者而保留后者，用户"已登录"却发不出任何状态变更请求（403）。

### 关键不变量

1. **fail-closed**：非公共路径无有效凭证 -> 401，无匿名兜底。
2. **优先级固定**：内部 token > cookie JWT > auth-disabled > 401；内部 token 命中时不再看 cookie。
3. **owner 头门控**：`X-Helix-Owner-User-Id` 仅在内部 token 校验通过后生效；浏览器塞的 owner 头被 `get_trusted_internal_owner_user_id` 无视。
4. **contextvar 必复位**：`set_current_user` / `reset_current_user(token)` 必须配对在 try/finally。
5. **token_version 单一吊销锚**：签发写 `ver`、改密 bump、校验比较；无黑名单。
6. **角色分离**：框架层持 contextvar（Protocol 解耦），应用层写凭证；认证（闸门）vs 授权（`@require_permission`）分离。
7. **CSRF 双提交常时比较 + cookie 寿命对齐**：cookie 与 header 必须都在且 `compare_digest` 相等；`csrf_token.max_age` == `access_token.max_age`。

### 在端到端链路中的位置

本 skill 处于 [[e2e-request-lifecycle]] 的 **②认证** 跳：三条入站路径（①入站）的凭证在此汇合成一个 `user`，写入 `user_context` contextvar，交给 ③路由（`RunManager.create_or_reject`）。下游 per-user 目录隔离见 [[multi-user-isolation]]；run 生命周期与 SSE 见 [[gateway-runs-and-sse]]；前端 CSRF/鉴权守卫见 [[frontend-app-design]]。

## 完整真实代码实现

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。原代码注释保留以保真；关键处补中文注解。大文件拆 `references/code/`，本段给文件清单 + 入口片段 + 索引。

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 |
|---|---|
| `gateway/gateway/auth_middleware.py` | `AuthMiddleware`：全局 fail-closed 闸门，`_PUBLIC_PATH_PREFIXES`/`_PUBLIC_EXACT_PATHS` 白名单，三凭证优先级汇合，写 `request.state` + `user_context` contextvar |
| `gateway/gateway/internal_auth.py` | 进程内内部 token：`X-Helix-Internal-Token` 校验、`X-Helix-Owner-User-Id` owner 覆盖、`get_internal_user` 合成用户、`make_safe_user_id` 规范化 |
| `gateway/gateway/auth/jwt.py` | JWT 创建/解析：`create_access_token`（写 `ver`）、`decode_token`（返回 `TokenPayload` 或细粒度 `TokenError`） |
| `gateway/gateway/auth/errors.py` | `AuthErrorCode` / `TokenError` 穷举枚举 + `AuthErrorResponse` 结构化载荷 + `token_error_to_code` 映射 |
| `gateway/gateway/auth/config.py` | `AuthConfig`（`jwt_secret`/`token_expiry_days`/OAuth client）+ `get_auth_config`（env 优先，否则生成并 0600 持久化 `.jwt_secret`） |
| `gateway/gateway/deps.py` | `get_current_user_from_request`：严格解析器，`decode_token` + DB 查 user + **token_version 吊销比较** |
| `gateway/gateway/auth_disabled.py` | 本地/E2E auth-disabled 合成 admin + `AUTH_SOURCE_*` 来源常量 + 生产环境硬门 |
| `gateway/gateway/auth/oidc.py` | `OIDCService`：discovery（issuer 钉死）、授权 URL、换码、ID token 校验（JWKS + nonce）、userinfo（sub 匹配） |
| `gateway/gateway/auth/oidc_state.py` | OIDC state/nonce/PKCE 经签名 cookie 存（5 分钟，无服务端存储，多 worker 无需 Redis） |
| `gateway/gateway/auth/local_provider.py` | `LocalAuthProvider`：邮箱密码校验 + OAuth 用户落库（`create_oauth_user`） |
| `gateway/gateway/routers/auth.py` | 登录/注册/改密/OAuth 回调路由：`_set_session_cookie`、改密 bump `token_version`、OIDC state 常时比较 |
| `gateway/gateway/csrf_middleware.py` | `CSRFMiddleware`：Double-Submit Cookie + auth 端点 Origin 校验 + 代理头受信解析 |
| `core/helix/runtime/user_context.py` | `_current_user` ContextVar + `set/get/reset_current_user` + `get_effective_user_id` + `resolve_runtime_user_id` + `AUTO` sentinel 三态 |

### 入口：AuthMiddleware.dispatch（三凭证汇合 + contextvar 写入）

```python
# gateway/gateway/auth_middleware.py（入口片段；完整源码见 references/code/auth-middleware.md §1）
class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        if _is_public(request.url.path):          # 白名单：health/docs/oauth 起步/callback/webhook 自证签名
            return await call_next(request)

        # ① 内部 token 头（scheduler/channels）：受信，合成内部用户；可选 owner 头覆盖 .id
        internal_user = None
        if is_valid_internal_auth_token(request.headers.get(INTERNAL_AUTH_HEADER_NAME)):
            owner_user_id = request.headers.get(INTERNAL_OWNER_USER_ID_HEADER_NAME)
            internal_user = get_internal_user(owner_user_id=owner_user_id or None)

        auth_source = AUTH_SOURCE_SESSION
        access_token = request.cookies.get("access_token")

        # 三凭证优先级：内部 token > cookie JWT > auth-disabled > 401（fail-closed）
        if internal_user is not None:
            user, auth_source = internal_user, AUTH_SOURCE_INTERNAL
        elif access_token:
            # 严格 JWT 校验：垃圾/过期 token 当场 401，关闭"junk cookie bypass"漏洞
            try:
                user = await get_current_user_from_request(request)
            except HTTPException as exc:
                if not is_auth_disabled():
                    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
                user = get_auth_disabled_user()
                auth_source = AUTH_SOURCE_AUTH_DISABLED
        elif is_auth_disabled():
            user = get_auth_disabled_user()        # 本地/E2E 合成 admin（生产被硬门拒掉）
            auth_source = AUTH_SOURCE_AUTH_DISABLED
        else:
            return JSONResponse(status_code=401, content={"detail": AuthErrorResponse(
                code=AuthErrorCode.NOT_AUTHENTICATED, message="Authentication required").model_dump()})

        request.state.user = user
        request.state.auth_source = auth_source
        request.state.auth = AuthContext(user=user, permissions=_ALL_PERMISSIONS)
        token = set_current_user(user)             # 写 contextvar，全链路隔离的起点
        try:
            return await call_next(request)
        finally:
            reset_current_user(token)              # 必须复位，防 task 复用串用户
```

### 入口：内部 token + user_context（核心骨架）

```python
# gateway/gateway/internal_auth.py（入口片段；完整源码见 references/code/jwt-and-internal-token.md §3）
INTERNAL_AUTH_HEADER_NAME = "X-Helix-Internal-Token"
INTERNAL_OWNER_USER_ID_HEADER_NAME = "X-Helix-Owner-User-Id"
INTERNAL_AUTH_ENV_VAR = "HELIX_INTERNAL_AUTH_TOKEN"

def is_valid_internal_auth_token(token: str | None) -> bool:
    return bool(token) and secrets.compare_digest(token, _INTERNAL_AUTH_TOKEN)   # 常时比较

def get_internal_user(owner_user_id: str | None = None):
    # owner id 经 make_safe_user_id 规范化（仅 [A-Za-z0-9_-]），防路径穿越/跨用户冒充
    effective_id = make_safe_user_id(owner_user_id) if owner_user_id else DEFAULT_USER_ID
    return SimpleNamespace(id=effective_id, system_role="internal")
```

```python
# core/helix/runtime/user_context.py（入口片段；完整源码见 references/code/auth-middleware.md §3）
_current_user: Final[ContextVar[CurrentUser | None]] = ContextVar("helix_current_user", default=None)

def set_current_user(user: CurrentUser) -> Token[CurrentUser | None]:
    return _current_user.set(user)

def reset_current_user(token: Token[CurrentUser | None]) -> None:
    _current_user.reset(token)

def get_effective_user_id() -> str:
    """文件系统路径解析用：未设置回退 DEFAULT_USER_ID，永不抛。"""
    user = _current_user.get()
    return DEFAULT_USER_ID if user is None else str(user.id)
```

### 入口：JWT + token_version 吊销

```python
# gateway/gateway/auth/jwt.py（入口片段；完整源码见 references/code/jwt-and-internal-token.md §1）
class TokenPayload(BaseModel):
    sub: str; exp: datetime; iat: datetime | None = None
    ver: int = 0   # token_version--必须与 User.token_version 一致，否则视为已吊销

def create_access_token(user_id, expires_delta=None, token_version=0) -> str:
    payload = {"sub": user_id, "exp": now + expiry, "iat": now, "ver": token_version}
    return jwt.encode(payload, config.jwt_secret, algorithm="HS256")

# 改密路由吊销闭环（references/code/jwt-and-internal-token.md §2）
user.token_version += 1                          # bump：旧 token 的 ver 立即失配
await provider.update_user(user)
token = create_access_token(str(user.id), token_version=user.token_version)
_set_session_cookie(response, token, request)    # 本会话续上新 ver，其余会话被吊销

# 严格解析器校验（references/code/jwt-and-internal-token.md §2）
if user.token_version != payload.ver:            # 不匹配 -> 已改密，旧 token 失效
    raise HTTPException(401, AuthErrorResponse(
        code=AuthErrorCode.TOKEN_INVALID, message="Token revoked (password changed)").model_dump())
```

### 入口：CSRF 双提交

```python
# gateway/gateway/csrf_middleware.py（入口片段；完整源码见 references/code/csrf.md §1）
class CSRFMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        _is_auth = is_auth_endpoint(request)
        # auth 端点首访：无 token，改用 Origin 校验防 login CSRF
        if should_check_csrf(request) and _is_auth and not is_allowed_auth_origin(request):
            return JSONResponse(403, {"detail": "Cross-site auth request denied."})
        # 非 auth 状态变更：双提交（cookie token == header token）
        if should_check_csrf(request) and not _is_auth:
            cookie_token = request.cookies.get(CSRF_COOKIE_NAME)
            header_token = request.headers.get(CSRF_HEADER_NAME)
            if not cookie_token or not header_token:
                return JSONResponse(403, {"detail": "CSRF token missing. Include X-CSRF-Token header."})
            if not secrets.compare_digest(cookie_token, header_token):
                return JSONResponse(403, {"detail": "CSRF token mismatch."})
        response = await call_next(request)
        # auth 端点建 session 后下发 CSRF cookie，max_age 与 access_token 对齐
        if _is_auth and request.method == "POST":
            response.set_cookie(CSRF_COOKIE_NAME, generate_csrf_token(),
                httponly=False, secure=is_secure_request(request), samesite="strict",
                max_age=get_auth_config().token_expiry_days * 24 * 3600 if is_secure_request(request) else None)
        return response
```

### 索引：references/code/

| 文件 | 内容 |
|---|---|
| [references/code/auth-middleware.md](./references/code/auth-middleware.md) | `AuthMiddleware` 完整源码 + `auth_disabled.py` 合成 admin + `user_context.py` contextvar 全貌（含 `resolve_runtime_user_id` / `AUTO` sentinel 三态） |
| [references/code/jwt-and-internal-token.md](./references/code/jwt-and-internal-token.md) | `config.py`（AuthConfig + 密钥持久化）+ `jwt.py` + `errors.py` + `deps.py` 严格解析器（token_version 吊销）+ 改密 bump 闭环 + `internal_auth.py` + `oidc.py`（OIDCService 全貌）+ `oidc_state.py`（签名 state cookie）+ `local_provider.py`（OAuth 落库） |
| [references/code/csrf.md](./references/code/csrf.md) | `CSRFMiddleware` 完整源码 + `is_allowed_auth_origin`（auth 端点 Origin 校验）+ 代理头受信解析（Forwarded/X-Forwarded-*） |

## 反模式与陷阱

- ❌ **fail-open 误写** -> 把"无 cookie"或"cookie 无效"分支写成放行（如 `user = anonymous` 兜底），或忘了 `else: 401`。后果：未认证请求穿透到 agent。修复：闸门主体 `else` 必须 401；cookie 存在但内容垃圾时调严格解析器当场 401（关闭"junk cookie bypass"，否则 `/api/models` 这类非隔离路由把任意 cookie 字符串当认证）。
- ❌ **内部 token 泄露到前端** -> 把 `X-Helix-Internal-Token` 或 `HELIX_INTERNAL_AUTH_TOKEN` 暴露给浏览器（如写进前端配置、CORS 放行该头）。后果：任意浏览器可伪造内部调用者、绕过 cookie 认证、塞 owner 头冒充任意用户。修复：内部 token 仅进程内/env，永不经 HTTP 返回前端；CORS 不暴露该头。
- ❌ **owner 头不门控** -> 直接读 `X-Helix-Owner-User-Id` 而不先验证内部 token。后果：浏览器塞 owner 头即冒充任意 IM 用户、per-user 目录串桶。修复：`get_trusted_internal_owner_user_id` 先查 `request.state.user.system_role == "internal"`，非内部调用者一律无视 owner 头。
- ❌ **contextvar 未清理致跨请求串用户** -> `set_current_user` 后不在 `finally` 里 `reset_current_user(token)`，或用模块级变量替代 contextvar。后果：asyncio task 复用时上一个请求的用户残留，下一个请求的 per-user 目录落到错的桶。修复：try/finally 配对 set/reset；contextvar 而非模块级变量。
- ❌ **CSRF 双提交不一致** -> `csrf_token` cookie 寿命与 `access_token` 分叉（如 csrf session-only、access_token 持久），或 `httponly=True` 使 JS 读不到。后果：iOS Safari PWA 终止后用户"已登录"却发不出任何 POST（403）；或前端无法塞 `X-CSRF-Token`。修复：`csrf_token` 必须 `httponly=False`（JS 可读）、`max_age` 与 `access_token` 对齐；用 `compare_digest` 常时比较。
- ❌ **OAuth state 不校验** -> 回调不校验 state、或非常时比较、或 state 存服务端却多 worker 无共享。后果：OAuth 回调 CSRF（攻击者诱导受害者绑定攻击者账号）；或计时侧信道；或多 worker 下 state 验证随机失败。修复：state 入签名 cookie（5 分钟、HS256、无服务端存储、多 worker 无需 Redis），`secrets.compare_digest` 常时比较；配 nonce 防 ID token 重放、PKCE 防授权码截获；discovery 的 issuer 必须 RFC 8414 钉死，防流氓 discovery 文档改 `iss` 伪造面。
- ❌ **token 吊销靠黑名单或等 TTL** -> 改密后旧 token 仍有效到 `exp`，或维护内存黑名单（多 worker 不共享）。后果：改密不能即时登出旧会话；或黑名单不一致。修复：用 `token_version` 单次比较（改密 bump、校验比 `ver`），无黑名单、无 TTL 等待。
- ❌ **认证与授权混淆** -> 在 `AuthMiddleware` 里做逐资源 owner 校验，或在路由里重复跑 JWT 解码。后果：闸门臃肿、每请求双倍 DB 查找。修复：闸门只认证（盖 `request.state.user` + `request.state.auth`），逐资源授权归 `@require_permission(owner_check=True)`，后者读 `request.state.auth` 短路。
- ❌ **在 core 层 import 应用层凭证模块** -> `core/helix/` 里 import `gateway.internal_auth`。后果：破坏单向依赖（CI 边界测试拦）。修复：core 只读 contextvar（Protocol 解耦），凭证解析归应用层。

## 落地参考（自测 / 调参 / 调试）

### 调参旋钮

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `token_expiry_days` | `AuthConfig` | JWT TTL，1–30 天默认 7；改密即吊销旧 token 故不必过短 |
| `jwt_secret` / `AUTH_JWT_SECRET` | `config.py` | env 优先；未设则生成并 0600 持久化 `.jwt_secret`（生产应显式设） |
| `_PUBLIC_PATH_PREFIXES` / `_PUBLIC_EXACT_PATHS` | `auth_middleware.py` | 公共路径白名单；新增公开端点必须显式登记，否则 401 |
| `HELIX_INTERNAL_AUTH_TOKEN` | `internal_auth.py` | 进程内共享密钥；多 worker 部署必须显式配，否则各 worker token 不同 |
| `X-Helix-Owner-User-Id` | `internal_auth.py` | IM channel owner 覆盖；仅内部 token 校验通过后生效 |
| `HELIX_AUTH_DISABLED` | `auth_disabled.py` | 本地/E2E 后门；`HELIX_ENV`/`ENVIRONMENT=prod` 时硬性失效 |
| `AUTH_TRUSTED_PROXIES` | `auth.py` 路由 | 信任的代理 CIDR，决定 `X-Real-IP`/`X-Forwarded-*` 是否被采信（限流用） |
| `GATEWAY_CORS_ORIGINS` | `csrf_middleware.py` | 显式浏览器 origin 白名单，影响 auth 端点 Origin 校验 |
| OIDC `nonce_enabled` / PKCE | `oidc_state.py` | nonce 与 PKCE 开关；public 客户端必须开 PKCE |
| `OIDC_STATE_MAX_AGE` | `oidc_state.py` | state cookie 寿命，默认 5 分钟 |
| `csrf_token` cookie `max_age` / `samesite` | `csrf_middleware.py` | 必须与 `access_token` 对齐；`httponly=False`、`samesite="strict"` |

### 关键日志串

- `⚠ AUTH_JWT_SECRET is not set - using an auto-generated secret persisted to .jwt_secret` - 密钥未显式配（生产应消除）
- `<AUTH_DISABLED_ENV_VAR>=1 is active: authentication is bypassed and anonymous requests run as synthetic admin user 'default'. Do not enable this in shared or production deployments.` - auth-disabled 后门开启告警
- `Token revoked (password changed)` - token_version 吊销命中（401 响应 detail）
- `OIDC discovered issuer '...' does not match configured issuer '...'` - discovery issuer 钉死校验失败
- `OIDC state mismatch` / `Missing or expired OIDC state cookie` - OAuth 回调 CSRF 防线命中（403）
- `CSRF token missing. Include X-CSRF-Token header.` / `CSRF token mismatch.` - 双提交校验失败（403）
- `Cross-site auth request denied.` - auth 端点 Origin 校验失败（403）

### 自测方向

- **三凭证路径 user_id 正确**：分别 mock Web（cookie JWT）、mock IM（内部 token + owner 头）、mock 调度（内部 token 无 owner 头），断言 `get_effective_user_id()` 各自解析出正确 user_id；无 owner 头的内部调用落 `"default"`。
- **fail-closed**：非公共路径无任何凭证 -> 401 `NOT_AUTHENTICATED`；cookie 是垃圾字符串 -> 401 `TOKEN_INVALID`（非放行）。
- **contextvar 隔离**：并发两个请求（不同 user），断言各自 `get_effective_user_id()` 互不串；模拟 task 复用，断言 `reset_current_user` 后 contextvar 恢复。
- **owner 头门控**：浏览器调用者（仅 cookie）塞 `X-Helix-Owner-User-Id`，断言被 `get_trusted_internal_owner_user_id` 无视（落 cookie 用户而非 owner）。
- **token_version 吊销**：签发 token -> 改密 bump -> 旧 token 请求 401 `Token revoked (password changed)`；新 token（改密后重发）请求 200。
- **CSRF 双提交**：状态变更请求缺 `X-CSRF-Token` 或 cookie/header 不等 -> 403；GET 豁免；webhook 路径豁免；auth 端点首访走 Origin 校验（跨源 -> 403，同源 -> 200 并下发 csrf cookie）。
- **CSRF 寿命对齐**：断言 `csrf_token` 与 `access_token` 的 `max_age` 相等、`csrf_token` 的 `httponly=False`。
- **OAuth state/nonce**：mock 回调不带 state 或 state 不匹配 -> 403；nonce 不匹配 -> `OIDCValidationError`；discovery issuer 不符 -> `OIDCError`。
- **生产硬门**：`HELIX_AUTH_DISABLED=1` + `HELIX_ENV=prod`，断言 `is_auth_disabled()` 返回 False（后门不开）。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 完整源码：[references/code/auth-middleware.md](./references/code/auth-middleware.md)、[references/code/jwt-and-internal-token.md](./references/code/jwt-and-internal-token.md)、[references/code/csrf.md](./references/code/csrf.md)
- 端到端链路（本 skill 处于 ②认证 跳）：[[e2e-request-lifecycle]]
- per-user 目录隔离（contextvar 的消费侧）：[[multi-user-isolation]]
- run 生命周期与 SSE（③路由 之后）：[[gateway-runs-and-sse]]
- 前端 CSRF/鉴权守卫（`getServerSideUser` 穷尽 switch、CSRF 双路径统一契约）：[[frontend-app-design]]
- 单向依赖（core 持 contextvar、app 写凭证）：[[core-app-boundary]]
- 配置与热重载（`AuthConfig` 解析）：[[config-and-hot-reload]]
