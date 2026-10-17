---
name: frontend-streaming-protocol
description: 前端流式订阅与 SSE 归一化：getAPIClient SDK 单例（CSRF 注入 + runs.stream/joinStream/cancel 三个补丁：创建禁重试/终态短路/吞 409）、useThreadStream 4039 行核心 hook（onUpdateEvent 增量归约 title/artifacts/goal、onCustomEvent task_* 子任务时间线、stream_replay_gap 重置）、断线重连（sessionStorage 流位置 + 活跃 run 重加入预算 + lastEventId 续流 + 最多 5 次 gap 恢复）、乐观消息与渲染合并账本（80ms 合并/LocalTurnAnchor 顺序恢复）、消息分组与工件流式渲染组件。当要做聊天流式 UI、排查"消息乱序/丢失/重复、重连丢流、乐观消息不消失"时使用。
---

# 前端流式协议

## 何时用

- 实现聊天界面的流式订阅（SSE/SDK 流）
- 断线重连与缺口恢复
- 乐观消息与服务器消息的顺序合并
- 子任务进度（task_* 自定义事件）时间线渲染

## 设计方案（为什么这么设计）

### 1. 客户端单例 + 三个针对性补丁

`core/api/api-client.ts`（649 行）：`getAPIClient()` Map 单例（default/mock 两键），浏览器走同源 `/api/langgraph`，SSR 兜底本地网关；`onRequest` 注入 CSRF 头（与 fetcher 共用 `readCsrfCookie`）。对 LangGraph SDK 打三个补丁：
- `runs.stream`：**创建 run 的请求禁重试**（`maxRetries:0`，防重复创建 run），GET 恢复请求保留重试
- `runs.joinStream`：终态短路（`TERMINAL_RUN_STATUSES`），join 前先注入 values 水合帧
- `runs.cancel`：吞终态 409（取消竞态不是错误）

### 2. useThreadStream：一个 hook 吃下全部流面

`core/threads/hooks.ts:1928`（4039 行）包 SDK `useStream`（`assistantId: "lead_agent"`、`reconnectOnMount`、`fetchStateHistory:{limit:1}`、`throttle:true` 同 tick 合并）：
- `onUpdateEvent` → `reduceThreadStateUpdates`（stream-state.ts）：增量合并 `title`/`artifacts`（mergeArtifacts）/`tool_artifacts`/goal 状态，并处理摘要中间件的 transient 消息
- `onCustomEvent` → `task_running`/`task_*` 进子任务 store（steps 时间线）；`stream_replay_gap` 重置全部流式缓冲；`llm_retry` 提示
- `onCreated` → 乐观线程缓存 upsert；`onError/onFinish` → 失效历史/用量缓存

**为什么不用 subgraph 流**：web 前端不请求 `stream_subgraphs`，子任务进度走根命名空间 `task_*` 自定义事件——协议面更小更稳。

### 3. 重连与缺口恢复

- 流位置存 sessionStorage（`lg:stream:<threadId>`）；重挂载 `reconnectOnMount`
- 活跃 run 重加入预算 `MAX_ACTIVE_RUN_REJOIN_ATTEMPTS`，退避 [1s,2s]
- gap 事件 → `recoverStreamReplayGaps`（最多 5 次）→ `threads.getState` 重载持久值 → 带 `lastEventId` 续流；恢复失败抛 `StreamReplayGapError` 交上层 UI

### 4. 顺序：乐观消息 + 渲染合并账本

乐观消息先上屏；`LocalTurnAnchor` 本地回合锚 + `restoreLocalTurnMessageOrder`/`mergeRenderedMessageLedger`（message-order.ts 453 行纯函数）在服务器消息到达后**确定性重排**；渲染层 `STREAM_RENDER_COALESCE_MS=80` 合并同帧更新。分页契约：51 行取 50+哨兵，仅第 0 页轮询（与后端镜像，见 [[gateway-runs-and-sse]]）。

### 5. 渲染组件

`message-list.tsx`（1699）虚拟列表调度、`message-group.tsx`（1327）分组、`virtual-message-list.tsx`（342）、`subtask-card.tsx`（301）；`core/messages/utils.ts`（1358）负责内容抽取/分组/流元数据/内部标记剥离；`core/tasks/*` 子任务上下文与更新归并；`core/citations/sources.ts` 解析 v1 证据信封（见 [[enterprise-rag-knowledge-base]]）。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/frontend/src/core/api/api-client.ts` | 649 | SDK 单例 + 三补丁 |
| `references/code/frontend/src/core/api/fetcher.ts` + `errors.ts` + `stream-mode.ts` | 139/124/112 | 通用 fetch（CSRF/401）/错误面/流模式 |
| `references/code/frontend/src/core/threads/hooks.ts` | 4039 | useThreadStream 等全部流 hook |
| `references/code/frontend/src/core/threads/stream-state.ts` | 173 | 增量归约 |
| `references/code/frontend/src/core/threads/message-order.ts` | 453 | 顺序恢复纯函数 |
| `references/code/frontend/src/core/threads/{activity,api,types,token-usage,utils,origin}.ts` | 411/242/127/47/180/125 | 会话域 |
| `references/code/frontend/src/core/messages/{utils,human-input,usage-model,usage,derived-state}.ts` | 1358/588/440/156/225 | 消息域 |
| `references/code/frontend/src/core/tasks/**`（9 文件） | 1011 | 子任务时间线 |
| `references/code/frontend/src/core/citations/sources.ts` | 265 | 证据解析 |
| `references/code/frontend/src/components/workspace/messages/*.tsx`（5 组件） | 1699+1327+838+342+301 | 渲染组件 |
| `references/code/frontend/src/core/streamdown/{preprocess,plugins}.ts` | 390+269 | Markdown 流式预处理 |

## 反模式与陷阱

- ❌ 创建 run 的请求允许重试 → 网络抖动重复建 run；maxRetries:0。
- ❌ 重连从头发流 → 重复渲染；lastEventId + seq 续流。
- ❌ 乐观消息靠时间戳排序 → 服务器回包乱序；回合锚 + 账本确定性重排。
- ❌ gap 无限恢复 → 死循环；5 次上限 + 上抛。
- ❌ 每帧全量重渲 → 掉帧；80ms 渲染合并 + 虚拟列表。
- ❌ 前端请求 subgraph 流 → 协议面膨胀；根命名空间 task_*。

## 落地参考

**自测方向**：断网 10s 重连后消息不丢不重（seq 对账）；乐观消息在服务器到达后被替换且顺序正确；终态后 join 立即返回；gap 注入后 5 次内恢复；虚拟列表万级消息滚动 60fps。

**调试**：`lg:stream:` sessionStorage、gap 恢复计数日志、渲染合并计数。

## 进一步阅读

- [[gateway-runs-and-sse]]（对端事件契约）、[[context-window-management]]（transient 摘要消息的前端归约）
- [[frontend-app-design]]（页面与 composer 侧）
