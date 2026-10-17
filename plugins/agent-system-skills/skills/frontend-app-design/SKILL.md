---
name: frontend-app-design
description: Next.js 16/React 19 聊天应用架构：App Router 路由体系（workspace 守卫/chats/自定义 agent 聊天/scheduled-tasks/showcase 只读演示/artifacts 独立查看器）、SSR 鉴权 exhaustive-switch 守卫与 (auth) 登录/首启向导、core 领域层组织（30+ 域的 api/hooks/types 分层）、i18n（类型即契约）、设置同步、3778 行 composer 巨石（@提及//goal//compact/附件/模型选择）、领域 API 层（项目/技能/记忆/MCP/渠道/上传/回收站）。当要搭建 agent 聊天前端、组织大型 Next.js core 层、做 SSR 鉴权与页面守卫时使用。
---

# 前端应用架构

## 何时用

- 搭建/重构 agent 聊天前端（App Router 组织、页面守卫）
- 前端领域层怎么分（core vs components）
- SSR 鉴权、首启向导、多语言
- 聊天 composer 的功能集成（提及/命令/附件/模型切换）

## 设计方案（为什么这么设计）

### 1. core 与 components 硬分离

`core/`（243 文件 3.8 万行）是**全部领域逻辑**：每域 `api.ts`（HTTP）/ `hooks.ts`（TanStack Query）/ `types.ts` 三件套，可独立测试（`tests/unit` 镜像目录）。`components/` 只消费 core。换来的是：换 UI 库不动业务、域逻辑单测无需 DOM。

### 2. SSR 鉴权守卫：exhaustive switch

`core/auth/server.ts::getServerSideUser()` 服务端直连内部网关 `/api/v1/auth/me`（zod 校验，产出 tag 化 `AuthResult`）。各受护 layout 对 tag 做 **exhaustive switch**：`unauthenticated` → 重定向登录（不渲染 children）、`system_setup_required` → /setup、其余放行。新态编译期必改守卫——不会漏处理。

### 3. 路由面

- `/workspace/chats/[thread_id]` 主聊天（壳 + chat-page 组件）
- `/workspace/agents/[agent_name]/chats/[thread_id]` 自定义 agent 独立聊天
- `/workspace/scheduled-tasks`（407 行纯组合层）、projects、capabilities、trash、extensions 页面
- `/showcase/[thread_id]` 白名单只读演示；`/artifacts/view` 独立工件查看器
- `(auth)/login`、`(auth)/setup`（首启向导）、`auth/callback`
- `next.config.js` rewrites：无外部 base URL 时 `/api/langgraph/*` → 内部网关 `/api/*`（dev 直连；Docker/Helm 由 nginx 承担同一改写）

### 4. i18n 与设置

- i18n：`types.ts`（2037 行）**类型即契约**——locale key 增删在类型层报错；en-US/zh-CN 双语言包；cookie 持久化
- settings：本地 store + 用户偏好服务端同步（preferences-sync）

### 5. composer 巨石

`components/workspace/input-box.tsx`（3778 行）：@提及（技能/子代理，16 个 skill id 上限契约）、斜杠命令（/goal /compact）、附件上传与校验、模型选择/收藏、输入法组合态。集中一处是因为这些能力共享同一个输入缓冲与键盘协议——拆散会造成状态机割裂。

### 6. 领域 API 层样例

projects（610 行 api + hooks + composer-attach）、skills、memory（导入/导出/条目 CRUD）、mcp、channels（连接轮询 connect-poll）、uploads（前端校验 file-validation）、trash、capabilities、features（feature flag）、knowledge（scope 选择）、sidecar、background-tasks、subagent-batches、workspace-changes。模式统一：`api.ts` 用 [[frontend-streaming-protocol]] 的 fetcher（带 CSRF/401 处理）。

## 实现索引

`references/code/frontend/`（145 文件 2.1 万行）：`AGENTS.md`（431 行行为契约）、`next.config.js`、`package.json`、`src/app/**` 全部路由页、`src/core/{auth,i18n,settings,projects,agents,channels,mcp,memory,skills,uploads,trash,capabilities,features,integrations,lark,knowledge,sidecar,background-tasks,subagent-batches,subagents,workspace-changes,notification,artifacts}/**`、`components/workspace/{input-box,workspace-container,todo-list,goal-status}.tsx`、`chats/{chat-page,chat-box}.tsx`。

| 关键文件 | 行数 | 说明 |
|---|---|---|
| `frontend/AGENTS.md` | 431 | 全部行为契约（分页语义/归档标志/CSRF 三面/mention 契约…） |
| `src/components/workspace/input-box.tsx` | 3778 | composer |
| `src/app/(auth)/login/page.tsx` + `setup/page.tsx` | 384+349 | 登录/首启 |
| `src/core/auth/{server,AuthProvider,types}` | 111+245+135 | SSR 鉴权三件套 |
| `src/core/i18n/types.ts` | 2037 | 类型即契约 |

`ui/` 与 `ai-elements/` 为 registry 生成目录（Shadcn/Vercel AI SDK），**不得手改**——未复制进语料。

## 反模式与陷阱

- ❌ 领域逻辑写进组件 → 不可测；进 core。
- ❌ 守卫只判 `if (!user)` → 新 auth 态漏处理；exhaustive switch。
- ❌ 改 `ui/`/`ai-elements/` 生成目录 → 升级即冲掉。
- ❌ 前端自拼网关 URL → 跨环境断裂；rewrites/nginx 统一改写。
- ❌ 上传只信后端校验 → 大文件白传；前端 file-validation 先拦。

## 落地参考

**自测方向**：未登录访问 workspace 全部子路由重定向；setup 未完成访问登录后跳 /setup；i18n 删 key 类型报错；composer 提及超 16 个被截断。

## 进一步阅读

- [[frontend-streaming-protocol]]（聊天流的另一半：订阅与归一化）
- [[auth]]（被 SSR 直连的 /me 面）、[[workspace-and-projects]]（artifacts 后端）
