---
name: frontend-app-design
description: 设计生产级 agent 平台的 Next.js 前端--App Router 布局、useStream(SDK) 单例 client + onRequest CSRF 注入、useThreadStream reducer 三路乐观合并（历史 + 实时流 + 乐观）、SSR 鉴权守卫 getServerSideUser 穷尽 switch、CSRF 双路径与 gateway 对称契约、scheduled-tasks REST 四件套（api/types/hooks/page + TanStack Query）、i18n/主题/Shadcn 设计系统。给出设计架构 + 入口伪代码 + references/code 模块索引（完整真实源码在 references），及在端到端链路 ⑧渲染-Web 的位置。当你要搭/重构 agent 前端、做 SSR 鉴权分支、接入流式聊天、做定时任务管理页、调设计系统时调用本 skill。
---

## 何时用

- 搭一个 Next.js agent 前端，或重构现有前端的应用骨架（路由 / 布局 / provider 层）
- 做 SSR 鉴权守卫：服务端组件里判断"已登录 / 未登录 / 需初始化 / 网关不可达"，并穷举分支
- 接入流式聊天：用 LangGraph SDK 的 `useStream` 消费 SSE，把历史 + 实时流 + 乐观消息三路合并成单一消息列表
- 做定时任务管理页（CRUD + 暂停/恢复/手动触发 + 运行历史），需要 REST 四件套（api / types / hooks / page）
- 排查"已登录却发不出 POST"（CSRF 双提交前后端契约不一致）、"刷新页面后消息丢失/重复"、"切换 thread 串状态"
- 调 i18n / 主题 / 设计系统（Shadcn + AI-elements）
- 想看清前端整体应用结构，而不只是 SSE 协议细节

> 本 skill 讲**整体应用**；SSE 事件 schema、`messages-tuple` 按 id 累积、`custom` 事件渲染子代理卡的协议级细节归 [[frontend-streaming-protocol]]，两者互补不重复。

## 设计方案（为什么这么设计）

### 核心定位：在端到端链路 ⑧渲染-Web 处把"SSE 事件流"变成"用户看到的对话"

本 skill 是脊柱 [[e2e-request-lifecycle]] 的 ⑧渲染 跳的 Web 侧深度。前序 ①入站（Web 路径）经 nginx 重写 `/api/langgraph/*` 到 Gateway，②认证 下发 HttpOnly `access_token` cookie + JS 可读的 `csrf_token` cookie，③–⑦ 在后端跑完 run 并经 StreamBridge publish SSE 事件。本跳把 ⑦ 的 SSE 事件流喂给 LangGraph SDK 的 `useStream` hook，由 `useThreadStream` 做**三路乐观合并**，再交给 markdown 渲染器呈现。

Web 路径的凭证是 **HttpOnly cookie JWT**（见 [[auth]]），前端不持有 token、不操心 token 刷新--CSRF 防护靠 Double-Submit Cookie（`csrf_token` cookie + `X-CSRF-Token` header）。这一安全模型决定了本 skill 的多个设计决策。

### App Router 选型（而非 Pages Router）

用 Next.js **App Router**（`app/` 目录）而非 Pages Router，原因：

1. **Server Components 做鉴权守卫**：`app/workspace/layout.tsx` 是 async server component，在渲染前 `await getServerSideUser()`，根据 `AuthResult.tag` 穷举分支（`redirect` / 渲染 fallback / 抛错）。客户端拿到的是"已鉴权后的 HTML"，无登录态闪烁。Pages Router 的 `getServerSideProps` 也能做，但 App Router 把 server/client 组件边界下沉到组件级，鉴权守卫与 UI 渲染可在同一棵树里协作。
2. **嵌套 layout 复用 provider 栈**：根 `layout.tsx` 装 `ThemeProvider` + `I18nProvider`；`workspace/layout.tsx` 装鉴权守卫 + `WorkspaceContent`（`QueryClientProvider` + `SidebarProvider` + `Toaster`）；`chats/[thread_id]/layout.tsx` 装 `ChatProviders`（`SubtasksProvider` + `ArtifactsProvider` + `PromptInputProvider`）。每层 layout 只装该层需要的 provider，路由切换时上层 provider 不卸载。
3. **`export const dynamic = "force-dynamic"`**：鉴权布局强制动态渲染，不被 Next.js 静态化缓存（鉴权结果每请求不同，缓存会串用户）。
4. **`generateStaticParams` + static-mode 降级**：`chats/[thread_id]/layout.tsx` 在 `NEXT_PUBLIC_STATIC_WEBSITE_ONLY=true` 时为 demo thread 生成静态参数，否则返回空数组走动态。同一套代码既跑动态鉴权部署，又能 `next build` 成纯静态站。

### `useStream`(SDK) + 单例 client（为什么不让组件直接 `new Client`）

LangGraph SDK 的 `Client`（`@langchain/langgraph-sdk/client`）持 baseURL、`onRequest` 拦截器、被 patch 过的 `runs.stream` / `runs.cancel` / `runs.joinStream` 方法。若每次渲染 `new Client`，会：

- 每个组件实例各开一条 SSE 连接，thread 切换时旧连接不释放，连接泄漏；
- `onRequest` 注入的 CSRF header 读取的 cookie 快照不一致（登录/登出后 cookie 轮转）；
- 对 `runs.stream` 的 `sanitizeRunStreamOptions` 包装、对 `runs.cancel` 的 409 吞掉逻辑、对 `runs.joinStream` 的终态短路逻辑各有一份，行为分叉。

故 `getAPIClient(isMock?)` 用 `Map<cacheKey, Client>` 做进程内单例：`"default"` 与 `"mock"` 两个 key，首次调用 `createCompatibleClient` 构造并 patch，之后命中缓存。`useStream` 的 `client` 参数传 `getAPIClient(isMock)`，保证全 app 同一 thread 只有一条 SSE。

**`onRequest` 注入 CSRF**：SDK 的 `onRequest(url, init)` 钩子在每次出站 fetch 前跑。`injectCsrfHeader` 在 `isStateChangingMethod(init.method)`（POST/PUT/DELETE/PATCH）时从 `document.cookie` 实时读 `csrf_token`，塞 `X-CSRF-Token` 头。**逐请求读 cookie** 而非构造时烘焙进 `defaultHeaders`，是为了让登录/登出/改密后的 cookie 轮转对 SDK 透明--无需重建 client。

### `useThreadStream` reducer 三路乐观合并

`useStream` 把 SSE 事件还原成 `thread.messages`（SDK 外部 store，按 message id 拼接 `messages-tuple` delta）。但**仅有 `thread.messages` 不够**：

1. **历史消息**来自另一条 REST 信道（`useThreadHistory` -> `GET /api/threads/{tid}/runs/{rid}/messages`，分页 + 按 run 聚合），不进 SDK 的 external store。reason：历史是"已归档"的快照，SDK store 只管"当前 live run"。
2. **乐观消息**是用户点发送后立即 push 的本地消息（`opt-human-{ts}` / `opt-ai-{ts}`），在 server 真实 message id 到达前填充 UI，避免"点发送后空白几百毫秒"。
3. **摘要救援缓冲**（`pendingArchivedMessagesRef`）：上下文摘要中间件会 `RemoveMessage(ALL)` 删掉所有 live 消息再重发保留尾部，`onUpdateEvent` 把被删消息异步归档进历史。但 SDK external store（live）与 React state（历史）落在不同调度上，render 可能观测到"摘要后 live 已缩但历史 setState 还没提交"的窗口，被删消息两边都没有。同步缓冲在这个窗口里托住它们。

三路合并由纯函数 `mergeMessages(historyMessages, threadMessages, optimisticMessages)` 完成：

- 重叠判定：历史的**连续后缀**与线程消息的**最旧部分**重叠（最新历史 == 最旧线程），从尾扫描缩 `cutoff`，命中即缩、不命中即停。
- 去重：`dedupeMessagesByIdentity` 按 `messageIdentity`（`tool:{tool_call_id}` / `message:{id}`）保留最后一条可见副本；隐藏消息（`hide_from_ui` / 控制消息名 / `<slash_skill_activation>` 空壳）不参与重叠裁剪（它们是 UI 控制消息，不是可观测记录）。
- `turn_duration` 保真：被裁剪的历史消息若带 `additional_kwargs.turn_duration`，合并后回填到存活副本，防时长统计丢。

**乐观消息清理时机**：不能在 server message 一到就清--`messages-tuple` 的 AI delta 可能先于 `values` 帧的 input human message 到达，过早清会让用户输入闪烁消失。故 `useEffect` 监听 `humanMessageCount`：仅当 server 的 human message 计数 **超过** 发送前快照的计数（`prevHumanMsgCountRef`）才清乐观消息。带 `hide_from_ui` 的乐观消息（Human Input Card 回复）不参与此门控。

### SSR 鉴权守卫 `getServerSideUser` 穷尽 switch

`getServerSideUser()` 返回 **tagged union** `AuthResult`，6 个 tag：`authenticated` / `needs_setup` / `system_setup_required` / `unauthenticated` / `gateway_unavailable` / `config_error`。调用方（`workspace/layout.tsx`、`(auth)/layout.tsx`）用 `switch (result.tag)` 穷举，`default: assertNever(result)` 让 TS 编译器强制穷尽--新增一个 tag 不更新 switch 会编译失败。

为什么用 tagged union 而非 try/catch：

- **无异常控制流**：每个分支都是显式返回值，调用方一眼看清所有可能。try/catch 会让"网关超时""cookie 无效""配置错"全混进 catch，分支语义模糊。
- **`gateway_unavailable` 与 `unauthenticated` 必须区分**：前者渲染 `GatewayOfflineFallback`（保留 AuthProvider，让用户能登出/重试）；后者 `redirect("/login")`。若混成"都 401 -> 跳登录"，网关抖动时已登录用户被误踢到登录页。
- **`needs_setup` / `system_setup_required` 区分**：前者 gateway 已就绪但需建管理员（`/setup` 可访问）；后者 gateway 未初始化（无 session cookie 时探 `/api/v1/auth/setup-status` 得知），同样 redirect `/setup` 但语义不同。
- **`config_error` 抛错**：`getGatewayConfig()` 解析 env 失败（如 `HELIX_INTERNAL_GATEWAY_BASE_URL` 不是合法 URL）直接 `throw new Error(result.message)`，让 Next.js 的 error boundary 接管，而非静默渲染坏页。

SSR 调 `/api/v1/auth/me` 时带 `SSR_AUTH_TIMEOUT_MS = 5000` 的 `AbortController` 超时，且 `cache: "no-store"` 防鉴权结果被缓存。无 session cookie 时先探 `/api/v1/auth/setup-status` 判断系统是否已初始化（未初始化 -> `system_setup_required`，已初始化但无 cookie -> `unauthenticated`）。

### CSRF 双提交与 gateway 对称契约

gateway 的 `CSRFMiddleware`（见 [[auth]]）对状态变更请求（POST/PUT/DELETE/PATCH）要求 `csrf_token` cookie 与 `X-CSRF-Token` header **常时相等**（`secrets.compare_digest`）。前端有**两条出站路径**必须对称地注入这个 header，否则任一路径漏注入都会 403：

1. **SDK 路径**（`useStream` -> `client.runs.stream` / `threads.update` / `runs.cancel`）：经 `createCompatibleClient` 的 `onRequest: injectCsrfHeader` 注入。
2. **直接 REST 路径**（`fetcher.ts:fetch`，用于 `/api/scheduled-tasks/*`、`/api/threads/*/runs/regenerate/prepare`、`/api/threads/*/scheduled-tasks` 等非 SDK 端点）：经 `fetch` 包装函数注入。

两路径**共享** `readCsrfCookie()` 与 `isStateChangingMethod()` / `STATE_CHANGING_METHODS`，所以"哪些方法要注入"与"cookie 怎么读"只有一份事实源。`STATE_CHANGING_METHODS = new Set(["POST","PUT","DELETE","PATCH"])` 与 gateway 的 `should_check_csrf`（`request.method not in ("POST","PUT","DELETE","PATCH")`）逐字对齐--GET/HEAD/OPTIONS/TRACE 豁免。

**对称契约的踩坑**：若 SDK 路径注入而 REST 路径不注入（或反过来），用 `fetch()` 直调 REST 的页面（如 scheduled-tasks）会 403，而聊天页（SDK 路径）正常，排查极困难。故 `fetcher.ts:fetch` 是所有非 SDK REST 调用的**唯一入口**，禁止裸 `globalThis.fetch` 调业务端点。同时它还做 `credentials: "include"`（跨-origin SSR 路由时带 HttpOnly cookie）与 401 自动跳 `/login?next={path}`。

### scheduled-tasks REST 四件套（api / types / hooks / page）

定时任务管理页是 [[scheduled-tasks]] 的前端侧。四件套分层：

| 层 | 文件 | 职责 |
|---|---|---|
| types | `core/scheduled-tasks/types.ts` | `ScheduledTask` / `ScheduledTaskRun` 纯类型（status / schedule_type / context_mode 枚举），与 gateway 响应体 1:1 |
| api | `core/scheduled-tasks/api.ts` | `fetchScheduledTasks` / `createScheduledTask` / `pauseScheduledTask` / `triggerScheduledTask` / `deleteScheduledTask` / `fetchScheduledTaskRuns` 等，全走 `fetcher.ts:fetch`（自动 CSRF），`throwGatewayApiError` 归一化错误 |
| hooks | `core/scheduled-tasks/hooks.ts` | TanStack Query 封装：`useScheduledTasks`（`refetchInterval: 15000` 轮询）、`useCreateScheduledTask` 等 mutation（`onSuccess` 失效缓存 + `onError` toast） |
| page | `app/workspace/scheduled-tasks/page.tsx` | 表单 + 列表 + 详情 + 运行历史 + 删除确认 Dialog |

关键设计：

- **轮询而非 SSE**：`useScheduledTasks` 与 `useScheduledTaskRuns` 用 `refetchInterval: 15000` + `refetchIntervalInBackground: false`。任务列表是低频变更的 CRUD 视图，SSE 过度设计；15s 轮询够用且后台 tab 不轮询省资源。
- **mutation 后失效缓存**：`onSuccess` 里 `invalidateQueries({ queryKey: ["scheduled-tasks"] })` + `["scheduled-tasks","thread"]` + `["scheduled-tasks","runs",taskId]`，保证创建/暂停/触发/删除后列表与运行历史立刻刷新。
- **乐观更新选择**：创建/删除走"mutation 成功后失效重取"而非乐观更新，因为任务行有 `next_run_at` / `last_run_at` / `status` 等服务端计算字段，乐观更新无法准确预填。触发（trigger）走失效重取 + 额外失效 runs 查询。
- **表单状态本地化**：page 组件用多个 `useState` 管理创建表单与编辑表单（title / prompt / schedule / contextMode），不进 TanStack Query（表单是临时输入态，不是服务端缓存）。`key={createNonce}` 在 recipe 应用与提交成功后重建 schedule 输入组件以重置内部状态。
- **`?thread_id=` 过滤**：page 读 `useSearchParams().get("thread_id")`，有则用 `useThreadScheduledTasks(threadId)` 只看该 thread 的任务，否则 `useScheduledTasks()` 看全部。同一 page 组件复用两种数据源。

### i18n / 主题 / 设计系统

- **i18n**：SSR `detectLocaleServer()`（`next/headers` 的 `cookies()` 读 `locale` cookie）传给根 `I18nProvider` 的 `initialLocale`，`<html lang={locale}>` 在首屏 HTML 即正确。`SUPPORTED_LOCALES = ["en-US","zh-CN"]`，`normalizeLocale` 把 `zh*` 归一为 `zh-CN`，其余回退 `en-US`。客户端 `useI18n` hook 在 mount 时从 cookie 同步 + 浏览器语言探测，`changeLocale` 同时写 React state 与 cookie。翻译表是纯对象（`translations[locale]`），不引 i18next 等重框架。
- **主题**：`next-themes` 的 `ThemeProvider`（`attribute="class"` + `enableSystem` + `disableTransitionOnChange`）。`ThemeProvider` 包装层在 pathname === `/"` 时 `forcedTheme="dark"`（落地页强制暗色），其余路径随系统。`<html suppressHydrationWarning>` 防 next-themes 注入 class 时的 hydration 警告。
- **设计系统**：Shadcn/ui（`components/ui/button` / `dialog` / `input` / `textarea` / `sidebar`）+ 自建 AI-elements（`components/ai-elements/`：`prompt-input` / `message` / `reasoning` / `task` / `artifact` / `canvas` / `streamdown` 等）。`cn` 工具（`lib/utils`）合并 Tailwind class。`Toaster`（sonner）在 `WorkspaceContent` 挂载，全局 toast。

### 与 `frontend-streaming-protocol` 的互补边界

| 维度 | 本 skill（frontend-app-design） | `frontend-streaming-protocol` |
|---|---|---|
| 粒度 | 整体应用骨架 | SSE 协议级细节 |
| 路由/布局 | App Router 嵌套 layout + provider 栈 | 不涉及 |
| 鉴权 | SSR 守卫穷尽 switch + CSRF 双路径对称 | 不涉及 |
| 流式 | 三路乐观合并的**整体**架构 + 摘要救援缓冲 | `messages-tuple` 按 id 累积、`custom` 事件渲染子代理卡、`values` 帧消毒、`Last-Event-ID` 重连的**协议**细节 |
| scheduled-tasks | REST 四件套完整 | 不涉及 |
| 设计系统 | i18n / 主题 / Shadcn | 不涉及 |

两 skill 在"流式聊天接入"处交叉：本 skill 给 `useThreadStream` 的整体 reducer 架构（三路合并 + 乐观 + 摘要救援），`frontend-streaming-protocol` 给 SDK 事件 -> message 累积的协议级映射。改流式渲染时两 skill 都读。

### 关键不变量

1. **client 单例**：全 app 同一 thread 只有一条 SSE，`getAPIClient` 的 `Map` 缓存保证不重复构造。
2. **CSRF 双路径对称**：SDK `onRequest` 与 `fetcher.ts:fetch` 共享 `readCsrfCookie` + `STATE_CHANGING_METHODS`，任一路径漏注入即 403。
3. **SSR 守卫穷尽**：`AuthResult` tagged union + `assertNever`，新增 tag 不更新 switch 编译失败。
4. **`gateway_unavailable` 与 `unauthenticated` 必须区分**：前者渲染 fallback 保留登出能力，后者跳登录。
5. **三路合并纯函数**：`mergeMessages` 无副作用，重叠裁剪只动可见消息的连续后缀，隐藏消息不参与。
6. **乐观消息清理等 server human message**：`humanMessageCount > prevHumanMsgCountRef` 才清，防 input 闪烁。
7. **scheduled-tasks 走失效重取而非乐观更新**：服务端计算字段（`next_run_at` / `status`）无法乐观预填。
8. **`force-dynamic`**：鉴权布局不被静态化，防缓存串用户。

### 在端到端链路中的位置

本 skill 处于 [[e2e-request-lifecycle]] 的 **⑧渲染-Web** 跳：消费 ⑦StreamBridge publish 的 SSE 事件，经 `useStream` -> `useThreadStream` 三路合并 -> markdown 渲染。Web 路径的入站凭证（②认证 的 HttpOnly cookie JWT）与 CSRF 双提交（与 [[auth]] 的 `CSRFMiddleware` 对称）是本 skill 安全模型的输入。scheduled-tasks 页面是 [[scheduled-tasks]] 的前端侧。SSE 协议级细节归 [[frontend-streaming-protocol]]。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code |
|---|---|---|
| `frontend/src/app/layout.tsx` | 根 layout：`ThemeProvider` + `I18nProvider`，SSR 探测 locale | [ssr-auth-and-csrf.md](./references/code/ssr-auth-and-csrf.md) §0 |
| `frontend/src/app/workspace/layout.tsx` | workspace layout：`getServerSideUser` 穷尽 switch + `force-dynamic` | [ssr-auth-and-csrf.md](./references/code/ssr-auth-and-csrf.md) §0 |
| `frontend/src/app/(auth)/layout.tsx` | auth layout：登录/注册/setup 页守卫（已登录跳走） | [ssr-auth-and-csrf.md](./references/code/ssr-auth-and-csrf.md) §3a |
| `frontend/src/core/auth/{server,types,gateway-config,auth-disabled-user,static-user}.ts` | `getServerSideUser` + `AuthResult` tagged union + `assertNever` + gateway 配置 + auth-disabled 合成 admin + 静态站用户 | [ssr-auth-and-csrf.md](./references/code/ssr-auth-and-csrf.md) §1-§3 |
| `frontend/src/core/api/api-client.ts` | SDK 单例 client：`getAPIClient` + `onRequest` CSRF + `runs.stream/cancel/joinStream` patch + static-mode 降级 | [streaming-hooks.md](./references/code/streaming-hooks.md) §1 |
| `frontend/src/core/api/stream-mode.ts` | `sanitizeRunStreamOptions`：丢弃 SDK 不支持的 stream mode | [streaming-hooks.md](./references/code/streaming-hooks.md) §1a |
| `frontend/src/core/api/fetcher.ts` | 直接 REST 路径：`fetch` 包装（CSRF + `credentials:include` + 401 跳登录）+ `readCsrfCookie` | [ssr-auth-and-csrf.md](./references/code/ssr-auth-and-csrf.md) §4 |
| `frontend/src/core/threads/hooks.ts` | `useThreadStream`：`useStream` + 三路乐观合并 + 摘要救援 + regenerate + `useThreadHistory` 分页 + `useInfiniteThreads` 等 | [streaming-hooks.md](./references/code/streaming-hooks.md) §2 |
| `frontend/src/core/scheduled-tasks/{types,api,hooks}.ts` | REST 四件套前三件 | [scheduled-tasks-ui.md](./references/code/scheduled-tasks-ui.md) §1-§3 |
| `frontend/src/app/workspace/scheduled-tasks/page.tsx` | scheduled-tasks page 组件 | [scheduled-tasks-ui.md](./references/code/scheduled-tasks-ui.md) §4 |
| `gateway/gateway/csrf_middleware.py` | gateway 侧 CSRF 双提交（对称契约另半边，见 [[auth]]） | [ssr-auth-and-csrf.md](./references/code/ssr-auth-and-csrf.md) §5 |

### 入口伪代码（完整源码见 references/code/）

**SSR 鉴权守卫（workspace layout 穷尽 switch）**：

```tsx
// 伪代码：force-dynamic + 穷尽 switch + assertNever 强制编译期穷尽
export const dynamic = "force-dynamic";
export default async function WorkspaceLayout({ children }) {
  switch ((await getServerSideUser()).tag) {
    "authenticated":         渲染 AuthProvider + WorkspaceContent
    "needs_setup":           redirect("/setup")
    "system_setup_required": redirect("/setup")
    "unauthenticated":       redirect("/login")
    "gateway_unavailable":   渲染 GatewayOfflineFallback（保留 AuthProvider 让用户登出/重试，而非跳登录踢走已登录用户）
    "config_error":          throw Error(result.message)   // error boundary 接管
    default:                 assertNever(result)            // 新增 tag 不更新 switch -> 编译失败
  }
}
```

**SDK 单例 client + CSRF 注入**：

```ts
// 伪代码：Map 单例 + onRequest 逐请求读 cookie（cookie 轮转对 SDK 透明）
getAPIClient(isMock):  _clients[key] ?? createCompatibleClient(isMock)   // key = "default" | "mock"
// onRequest 钩子：状态变更方法(POST/PUT/DELETE/PATCH)时从实时 csrf_token cookie 铸 X-CSRF-Token
//   （逐请求读，与 fetcher.ts 共享 readCsrfCookie / STATE_CHANGING_METHODS，登录/登出/改密 cookie 轮转透明）
// createCompatibleClient 还 patch：
//   runs.stream（丢 SDK 不支持的 mode）/ runs.cancel（吞终态 409 no-op）/ runs.joinStream（短路终态重连防阻塞）
//   static-mode 降级时走 createStaticClient（threads.search/get/getState 走 demo 数据，runs.stream 空生成器）
```

**useThreadStream 三路合并**：

```ts
// 伪代码：历史（含摘要救援覆盖）+ 实时流（剔除 superseded）+ 乐观 三路纯函数合并
useStream({ client: getAPIClient(isMock), threadId, reconnectOnMount: true, fetchStateHistory:{limit:1},
  onCreated:        乐观插入 search/infinite 缓存,
  onUpdateEvent:    摘要救援 -> 同步缓冲 pendingArchivedMessagesRef + appendMessages 异步归档进历史,
  onCustomEvent:    task_running 累积 step（不覆盖）/ llm_retry toast,
  onError:          清乐观 + toast.error,  onFinish: 失效 search/infinite 缓存 })
effectiveHistory = (rescueBuffer 非空 && pendingArchiveThreadIdRef === threadId)
  ? resolvePreservedHistory(visibleHistory, rescueBuffer) : visibleHistory
mergedMessages = mergeMessages(effectiveHistory, persistedMessages, visibleOptimisticMessages)
// 乐观清理：等 humanMessageCount > prevHumanMsgCountRef 才清，防 messages-tuple 的 AI delta 先于 values 帧 human 到达时 input 闪烁
// sendMessage：in-flight guard + 乐观消息(opt-human/opt-ai) + 文件上传(uploading->uploaded 状态机) + thread.submit(context 装配 thinking/plan/subagent/reasoning)
// regenerateMessage：经 /runs/regenerate/prepare 拿 checkpoint + target_run_id 再 thread.submit
```

**CSRF 直接 REST 路径（fetcher.ts）**：

```ts
// 伪代码：与 SDK onRequest 共享 readCsrfCookie + STATE_CHANGING_METHODS（一份事实源，gateway should_check_csrf 逐字对齐）
fetch(input, init):
  if isStateChangingMethod(init.method):  从 readCsrfCookie() 铸 X-CSRF-Token（仅在 header 不存在时 ADD）
  res = globalThis.fetch(url, { ...init, headers, credentials: "include" })   // 跨-origin SSR 路由带 HttpOnly cookie
  if res.status === 401:  window.location.href = buildLoginUrl(window.location.pathname)   // 自动跳登录
  return res
```

**scheduled-tasks 四件套结构**：

```ts
// 伪代码：types（枚举）-> api（fetcher.ts:fetch 自动 CSRF）-> hooks（TanStack Query）-> page
useScheduledTasks()           // refetchInterval: 15000, refetchIntervalInBackground: false
useScheduledTaskRuns(taskId)  // 同样 15s 轮询
useCreateScheduledTask()      // onSuccess: invalidateQueries(["scheduled-tasks"])
useTriggerScheduledTask()     // 额外失效 ["scheduled-tasks","runs",taskId]，让运行历史立刻刷新
// page: useSearchParams().get("thread_id") -> useThreadScheduledTasks vs useScheduledTasks 二选一
//       mutation 全走"成功后失效重取"（非乐观更新），因 next_run_at/status 是服务端计算字段
```

### references/code/ 模块索引

| 文件 | 内容 |
|---|---|
| [streaming-hooks.md](./references/code/streaming-hooks.md) | §1 SDK 单例 client（`createCompatibleClient` + `TERMINAL_RUN_STATUSES` + `isRunConflictError` + `shouldSkipReconnect` + `clearReconnectRun` + static-mode `createStaticClient`）+ §1a `sanitizeRunStreamOptions` + §2 `useThreadStream` 完整源码（`mergeMessages` / `dedupeMessagesByIdentity` / `messageIdentity` / `resolvePreservedHistory` / `pruneConfirmedArchivedMessages` / `computeSummarizationMovedMessages` / `sendMessage` 文件上传闭环 / `regenerateMessage` / `useThreadHistory` 分页 / `useInfiniteThreads` / `useDeleteThread` 等） |
| [ssr-auth-and-csrf.md](./references/code/ssr-auth-and-csrf.md) | §0 root + workspace layout + §1 `AuthResult` tagged union + `userSchema` + `assertNever` + §2 `getServerSideUser` + §3 `gateway-config` + `auth-disabled-user` + `static-user` + §3a `(auth)/layout.tsx` + §4 CSRF 前端侧 `fetcher.ts` + `getCsrfHeaders` + §5 gateway `CSRFMiddleware` + §5a 对称契约对照表 |
| [scheduled-tasks-ui.md](./references/code/scheduled-tasks-ui.md) | §1 `types.ts` + §2 `api.ts`（9 个函数）+ §3 `hooks.ts`（8 个 hook）+ §4 `page.tsx`（表单 + 列表 + 详情 + 运行历史 + 删除确认 Dialog） |

## 反模式与陷阱

- ❌ **手写 SSE 而非用 SDK** -> 自己 `new EventSource('/api/langgraph/*/runs/stream')` 解析 `data:` 行。后果：丢 `messages-tuple` 按 id 累积、丢 `Last-Event-ID` 续传、丢 `onCreated`/`onUpdateEvent` 回调、CSRF 注入没处挂。修复：用 `@langchain/langgraph-sdk/react` 的 `useStream`，`client` 传 `getAPIClient()`。
- ❌ **SSR 守卫 switch 不穷尽** -> 用 `if (result.tag === "authenticated") { // 渲染 } else { redirect("/login") }`，把 `gateway_unavailable` / `needs_setup` / `config_error` 全混进 else 跳登录。后果：网关抖动时已登录用户被误踢登录页；需初始化的系统跳登录而非 setup。修复：tagged union + `switch` 穷举 + `default: assertNever(result)`，让 TS 强制每个 tag 都有分支。
- ❌ **CSRF 双路径契约不一致** -> SDK 路径用 `onRequest` 注入，但 scheduled-tasks 的 REST 调用用裸 `globalThis.fetch` 漏注入。后果：聊天页正常，scheduled-tasks 页所有 POST 403 "CSRF token missing"，排查极困难。修复：所有非 SDK REST 调用必须走 `fetcher.ts:fetch`；`readCsrfCookie` + `STATE_CHANGING_METHODS` 双路径共享一份。
- ❌ **client 非单例致多连接** -> 组件里 `new LangGraphClient(...)` 每次渲染新建。后果：thread 切换旧 SSE 不释放、连接泄漏、cookie 快照不一致、`runs.cancel` 的 409 吞掉逻辑各一份。修复：`getAPIClient` 用 `Map<cacheKey, Client>` 单例。
- ❌ **乐观消息过早清理** -> server 的第一条 AI delta 一到就清乐观 human。后果：`messages-tuple` 的 AI delta 先于 `values` 帧的 input human message 到达时，用户输入闪烁消失。修复：等 `humanMessageCount > prevHumanMsgCountRef`（server human 已到）才清。
- ❌ **摘要救援消息丢失** -> 上下文摘要中间件 `RemoveMessage(ALL)` 后，仅靠 `appendMessages` 异步归档进历史，不设同步缓冲。后果：render 窗口期（live 已缩、历史 setState 未提交）被删消息两边都没有，对话中段消失。修复：`pendingArchivedMessagesRef` 同步缓冲，`resolvePreservedHistory` 在合并时覆盖，`pruneConfirmedArchivedMessages` 在历史吸收后释放。
- ❌ **`gateway_unavailable` 当 `unauthenticated` 处理** -> 网关超时/500 也 `redirect("/login")`。后果：已登录用户在网关抖动时被踢登录页，且登录页可能也因网关抖动进不去，死锁。修复：`gateway_unavailable` 渲染 `GatewayOfflineFallback`（保留 AuthProvider 让用户能登出/重试）。
- ❌ **scheduled-tasks 用乐观更新** -> 创建/暂停后本地预填 `next_run_at` / `status`。后果：这些是服务端计算字段（cron 推算、poller 状态机），乐观预填不准，UI 与后端分叉。修复：mutation `onSuccess` 失效缓存重取（`invalidateQueries`），让服务端权威值回流。
- ❌ **scheduled-tasks 缺轮询** -> 任务列表只在挂载时拉一次。后果：后台 run 完成后 `last_run_at` / `status` 不更新，用户需手动刷新。修复：`refetchInterval: 15000` + `refetchIntervalInBackground: false`（后台 tab 省资源）。
- ❌ **鉴权布局被静态化** -> `layout.tsx` 不标 `export const dynamic = "force-dynamic"`。后果：Next.js 缓存鉴权结果 HTML，第二个用户看到第一个用户的鉴权态（串用户）。修复：鉴权布局强制 `force-dynamic`。
- ❌ **`csrf_token` cookie 寿命与 `access_token` 分叉** -> 前端不管 cookie 下发（gateway 管），但若前端有设置 cookie 的代码（如手动 `document.cookie = "csrf_token=..."`）把 csrf 设成 session-only 而 access_token 持久。后果：iOS Safari PWA 终止后 csrf 被驱逐、access_token 存活，用户"已登录"却发不出任何 POST（403）。修复：cookie 下发归 gateway，`csrf_token.max_age` 与 `access_token` 对齐（见 [[auth]]）。

## 落地参考（自测 / 调参 / 调试）

### 调参旋钮

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `reconnectOnMount` | `useStream` 参数 | 组件 mount 时是否重连上次未完成的 run；靠 `Last-Event-ID` 续传 |
| `fetchStateHistory: { limit: 1 }` | `useStream` 参数 | mount 时拉取最新 1 个 state 快照（防 thread 切换时空白） |
| `streamSubgraphs: true` | `thread.submit` 选项 | 流子图事件（子代理 `task_running` custom 事件依赖它） |
| `streamResumable: true` | `thread.submit` 选项 | 启用 `Last-Event-ID` 续传（与 [[gateway-runs-and-sse]] 的 StreamBridge 对应） |
| `recursion_limit: 1000` | `thread.submit` config | 单 run 最大图步数上限 |
| `SSR_AUTH_TIMEOUT_MS = 5000` | `auth/server.ts` | SSR 调 `/auth/me` 的超时；过短->抖动即 fallback，过长->首屏卡 |
| `refetchInterval: 15000` | `scheduled-tasks/hooks.ts` | 任务列表/运行历史轮询间隔；后台 tab 不轮询 |
| `STOP_THREAD_FINALIZATION_REFETCH_DELAY_MS = 1500` | `threads/hooks.ts` | 停止 run 后延迟失效缓存（等后端 finalization 落库） |
| `NEXT_PUBLIC_LANGGRAPH_BASE_URL` / `NEXT_PUBLIC_BACKEND_BASE_URL` | `env.js` | SDK 与 REST 的 baseURL；未设则用 `window.location.origin` + nginx 重写 |
| `HELIX_INTERNAL_GATEWAY_BASE_URL` | `auth/gateway-config.ts` | SSR 直连 gateway 的内部 URL（默认 `http://127.0.0.1:8001`，绕 nginx） |
| `HELIX_TRUSTED_ORIGINS` | `auth/gateway-config.ts` | 显式浏览器 origin 白名单 |
| `HELIX_AUTH_DISABLED` / `HELIX_ENV` | `auth/auth-disabled-user.ts` | 本地/E2E auth-disabled 合成 admin；生产环境硬门拒掉 |
| `NEXT_PUBLIC_STATIC_WEBSITE_ONLY` | `env.js` | 纯静态站模式，降级为 demo 数据 + `createStaticClient` |
| `forcedTheme` / `attribute` | `theme-provider.tsx` | 落地页强制暗色；class 策略 + `disableTransitionOnChange` |

### 关键日志串

- `Creating API client with base URL: ...` - 单例 client 首次构造（应只出现 default/mock 各一次）
- `env.NEXT_PUBLIC_LANGGRAPH_BASE_URL ...` - baseURL 解析（排查 SDK 走错地址）
- `[helix] Dropped unsupported LangGraph stream mode(s): ...` - `sanitizeRunStreamOptions` 丢弃不支持 mode（如 `events`）
- `[SSR auth] Malformed /auth/me response: ...` - gateway 返回的 user 不符 `userSchema`（gateway 前后端类型分叉）
- `[SSR auth] /api/v1/auth/me responded {status}` - gateway 非 401/403 的异常状态
- `[SSR auth] Failed to reach gateway: ...` - SSR 连不上 gateway（超时/网络）-> `gateway_unavailable`
- `Run {runId} returned has_more without message seq values; leaving it pending for retry.` - 历史分页解析异常，留待重试
- `Failed to load thread history.` - `useThreadHistory` 加载失败 toast

### 自测方向

- **client 单例**：渲染多个使用 `useThreadStream` 的组件，断言 `getAPIClient` 只构造一次（`console.log` 计数）；切换 thread 后旧 SSE 连接被复用而非新建。
- **三路合并**：mock 历史 `[m1, m2]`、实时流 `[m2, m3]`（m2 重叠）、乐观 `[opt1]`，断言合并结果为 `[m1, m2, m3, opt1]` 无重复；m2 的 `turn_duration` 被保留。
- **乐观消息清理时机**：发送后立即断言乐观 human 存在；mock `messages-tuple` AI delta 先到，断言乐观 human **仍在**；mock `values` 帧 human message 到达（`humanMessageCount` 增），断言乐观 **被清**。
- **摘要救援**：mock `onUpdateEvent` 收到 `SummarizationMiddleware.before_model` 更新（含 RemoveMessage + 保留尾部），断言被删消息在同步缓冲里、合并结果不丢；mock 历史 setState 提交后，断言缓冲被 `pruneConfirmedArchivedMessages` 释放。
- **SSR 鉴权穷尽**：mock `getServerSideUser` 返回 6 个 tag 各一次，断言 `workspace/layout.tsx` 每个分支行为正确（authenticated 渲染、needs_setup/system_setup_required redirect /setup、unauthenticated redirect /login、gateway_unavailable 渲染 fallback、config_error throw）；新增一个 tag（如 `{ tag: "maintenance" }`）断言 TS 编译失败（`assertNever` 强制穷尽）。
- **CSRF 双路径对称**：用 `globalThis.fetch` 直接调 `/api/scheduled-tasks` POST -> 403；改用 `fetcher.ts:fetch` -> 200（header 注入）；SDK 路径 `thread.submit` -> 200（`onRequest` 注入）；GET 请求不塞 header（断言 `X-CSRF-Token` 不在）。
- **`gateway_unavailable` vs `unauthenticated`**：mock `/auth/me` 返回 500 -> `gateway_unavailable` -> 断言渲染 `GatewayOfflineFallback` 且 AuthProvider 挂载（用户能登出）；mock 返回 401 -> `unauthenticated` -> 断言 `redirect("/login")`。
- **scheduled-tasks CRUD**：创建任务 -> 断言列表缓存失效并重取；暂停/恢复 -> 状态字段更新；手动触发 -> runs 查询额外失效；删除 -> 列表移除；`?thread_id=` 查询参数 -> 只显示该 thread 任务。
- **轮询**：挂载 scheduled-tasks 页，断言每 15s 重取；切到后台 tab，断言停止轮询。
- **thread 切换不串状态**：在 thread A 发送中途切到 thread B，断言 A 的乐观消息不在 B 显示（`optimisticThreadId === currentViewThreadId` 门控）；切回 A 仍正确。
- **static-mode 降级**：`NEXT_PUBLIC_STATIC_WEBSITE_ONLY=true`，断言 `getAPIClient` 返回 `createStaticClient`（threads.search/get/getState 走 demo 数据，runs.stream 空生成器）。
- **`force-dynamic`**：构建产物里断言 `workspace/layout.tsx` 不进静态预渲染（`dynamic = "force-dynamic"`）。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 完整源码：[references/code/streaming-hooks.md](./references/code/streaming-hooks.md)、[references/code/ssr-auth-and-csrf.md](./references/code/ssr-auth-and-csrf.md)、[references/code/scheduled-tasks-ui.md](./references/code/scheduled-tasks-ui.md)
- 端到端链路（本 skill 处于 ⑧渲染-Web 跳）：[[e2e-request-lifecycle]]
- SSE 协议级细节（`messages-tuple` 按 id 累积、`custom` 事件渲染子代理卡、`values` 帧消毒、`Last-Event-ID` 重连）：[[frontend-streaming-protocol]]
- 三层认证 + CSRF 双提交 gateway 侧（`AuthMiddleware` / `CSRFMiddleware` / `user_context` contextvar）：[[auth]]
- scheduled-tasks 后端（`ScheduledTaskService` poller + lease + cron/once + non_interactive 剥离 + 崩溃恢复）：[[scheduled-tasks]]
- run 生命周期与 SSE（RunManager + run_agent + StreamBridge）：[[gateway-runs-and-sse]]
- 多用户隔离（per-user 目录，user_id 全链路隔离跨切不变量）：[[multi-user-isolation]]
- LangGraph SDK：https://langchain-ai.github.io/langgraph/cloud/sdk/
