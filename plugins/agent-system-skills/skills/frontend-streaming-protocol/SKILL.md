---
name: frontend-streaming-protocol
description: 设计前端消费 agent SSE 流的协议层--SSE 事件 schema（metadata/values/messages/updates/custom/error/end）、useStream 回调映射、messages-tuple 按 id 累积与 UI 去重（last-index + turn_duration 保真）、custom 事件渲染子代理卡（task_started/running/completed/failed/cancelled/timed_out + llm_retry）、Last-Event-ID 断流重连（ring buffer + 终态短路）、SDK 单例 client + onRequest CSRF 双提交注入。给出设计架构 + 伪代码 + references/code 模块索引（完整真实源码在 references），及在端到端链路 ⑧渲染-Web 的位置。当你要对接 agent SSE 流、排查"消息重复/丢失/闪烁"、做断流重连、调 custom 事件渲染、查 CSRF 403 时调用本 skill。
---

## 何时用

- 你在 Next.js / React 前端对接 agent 的 SSE 流式协议（事件类型 / payload / 重连）
- 想弄清 `useStream`(SDK) 的回调（onCreated/onUpdateEvent/onCustomEvent/onError/onFinish）各自对应哪个 SSE 事件
- 排查"同一段 AI 回复闪两次""工具消息重复插入""切换 thread 串消息""刷新后消息丢失/卡在 loading"
- 要渲染子代理 `task_*` custom 事件卡片，或处理 `llm_retry` toast
- 做断流重连：`Last-Event-ID` 续传 / `joinStream` 冷重连 / 终态 run 短路防阻塞
- 查"已登录却发不出 POST"（CSRF 双提交 cookie 与 header 不一致 -> 403）
- 想看清 SSE 协议级细节，而非整体前端应用架构（后者归 [[frontend-app-design]]）

> 本 skill 讲**SSE 协议级细节**；整体应用骨架（App Router / SSR 鉴权 / 三路乐观合并架构 / scheduled-tasks / 设计系统）归 [[frontend-app-design]]，两者互补不重复。

## 设计方案（为什么这么设计）

### 核心定位：在端到端链路 ⑧渲染-Web 把"SSE 事件流"还原成"用户看到的对话"

本 skill 是脊柱 [[e2e-request-lifecycle]] 的 ⑧渲染 跳的**协议层深度**。前序 ⑦StreamBridge publish 的 SSE 事件流（`metadata` / `values` / `messages` / `updates` / `custom` / `error` / `end`）经 LangGraph SDK 的 `useStream` hook 解码，由 `useThreadStream` 做 UI 侧 reducer 合并，再交 markdown 渲染。本 skill 聚焦"SDK 事件 -> message 累积 / custom 渲染 / 重连 / CSRF 注入"的协议级映射；三路乐观合并的整体架构（历史 + 实时流 + 乐观 + 摘要救援）归 [[frontend-app-design]]。

### SSE 事件 schema（事件类型 + payload 结构）

gateway 的 `format_sse(event, data, event_id)` 按 LangGraph Platform 线格式产出帧：`event:` -> `data:` -> `id:`（可选）-> 空行。`useStream` 内部 EventSource 解码后按 event name 分发到回调。事件类型与 payload：

| SSE 事件 | payload 结构 | useStream 回调 / 状态 | 说明 |
|---|---|---|---|
| `metadata` | `{run_id, thread_id}` | `onCreated(meta)` | run 启动首发；`useStream` 需 run_id + thread_id 才能订阅 |
| `values` | 全量 state 快照 `{title, messages, artifacts, todos, ...}` | `thread.values` / `thread.messages` | LangGraph `stream_mode="values"` 每 super-step 重发全量 |
| `messages` | `[chunk, metadata]` 元组 | `thread.messages`（SDK 按 id 累积） | 客户端请求时叫 `messages-tuple`，worker 内部转回 `messages`；chunk 是增量 delta |
| `updates` | `{node_name: writes}` | `onUpdateEvent(data)` | 节点产出；前端只关注少数 middleware（如摘要） |
| `custom` | 自定义 payload（`{type, task_id, ...}`） | `onCustomEvent(event)` | `get_stream_writer()` 发的子代理 / 重试事件 |
| `error` | error payload | `onError(error)` | run 异常；SSE named event，非连接级故障 |
| `end` | `null` | `onFinish(state)` | `END_SENTINEL` 到达，run 终态 |
| `: heartbeat` | SSE 注释行 | （SDK 透传，保连接） | 15s 无事件时发，防代理超时断连 |

**`messages-tuple` -> `messages` 协议别名**：客户端 SDK 请求 `streamMode: ["values", "messages-tuple"]`，gateway worker 的 `_lg_mode_to_sse_event` 把 LangGraph 内部 `"messages"` 模式产出的 `(chunk, metadata)` 元组以 SSE 事件名 `"messages"` 投递。别名只在 array 形态下被网关识别。

**`events` mode 静默丢弃**：前端白名单含 `events`，但 worker 跳过它（依赖 `astream_events` 与 `values` 不兼容）。前端不主动剔除，靠 worker 静默丢弃 + 日志，"宽进严出"。

### `useStream` 回调映射（SDK 抽象原始 SSE）

`@langchain/langgraph-sdk/react` 的 `useStream` 内部维护 EventSource，按 event name 分发到 channel，再把还原后的状态暴露给业务 hook。业务侧不直接碰 `data:` 行，只实现回调：

```ts
// 伪代码：useStream 回调与 SSE 事件的对应
useStream<AgentThreadState>({
  client: getAPIClient(isMock),        // 单例，见下文
  assistantId: "lead_agent",
  threadId, reconnectOnMount: true,     // mount 时靠 Last-Event-ID 续传
  fetchStateHistory: { limit: 1 },      // 拉最新 1 个 state 快照防空白
  onCreated(meta):         对应 metadata 事件 -> 写 run_id/thread_id + 乐观插 search 缓存
  onUpdateEvent(data):     对应 updates 事件 -> 摘要救援 + title 同步缓存
  onCustomEvent(event):    对应 custom 事件 -> task_running 累积 step / llm_retry toast
  onError(error):          对应 error 事件 -> 清乐观 + toast
  onFinish(state):         对应 end 事件 -> 失效缓存 + token-usage baseline 快照
})
// thread.messages（SDK external store）已按 message id 拼好 messages-tuple delta
// thread.values 拿全量 state 快照（title / artifacts / todos）
```

### `messages-tuple` 按 id 累积与 UI 去重（last-index + turn_duration 保真）

LangGraph 的 messages 流以增量投递：同一 AI message 的多次 token delta 共享一个 `message.id`；tool result 带 `tool_call_id`。SDK internal store 按 id 拼接 delta 成完整文本。但**展示侧**还需去重--`stream_mode="values"` 每 super-step 重发全量 messages，同一 message 会出现多次（每次是当时的完整快照）。

`messageIdentity` 统一身份函数：`tool:{tool_call_id}`（tool result）/ `message:{id}`（其余）/ `undefined`（无身份不参与去重）。`dedupeMessagesByIdentity` 保留 **last index**：SDK 把每次 delta / 快照视作新 entry 追加，仅展示最后一份即等价于最新完整版。

```ts
// 伪代码：UI 去重保留 last index，turn_duration 回填
function dedupeMessagesByIdentity(messages): Message[] {
  // 1) 两套 Map：lastIndexByIdentity（含 hidden）+ lastVisibleIndexByIdentity（仅 visible）
  //    hidden 消息（hide_from_ui / 控制消息名 / <slash_skill_activation> 空壳）参与追踪但不展示
  // 2) 同时记录 preservedTurnDurations：identity -> turn_duration（Worker 末帧写入）
  // 3) filter：identity 消息只保留 lastVisible（无 visible 则 lastTotal）；无 identity 全留
  // 4) map：存活副本若缺 turn_duration 但 identity 有记录 -> 回填（防时长统计丢）
}
```

**关键决策：保留 last 而非 first**。`additional_kwargs.turn_duration` 是 Worker 在最后一帧写入的；取 last index 正好保留它。tool call（`message:{id}`）与 tool result（`tool:{tool_call_id}`）不在同一命名空间，一个 tool 的 call + result 作为**两条**保留，展示层按 `tool_call_id` 关联渲染为折叠 tool block。

**这是 UI 展示规约，不是 LangChain 通用契约**。承担独立 tracing/task 语义的隐藏消息应使用独立 id 或独立 stream/state channel，不要依赖"被同 identity 可见消息覆盖"的副作用。

### `custom` 事件渲染子代理卡 + llm_retry toast

子代理经 `get_stream_writer()` 发 `task_*` custom 事件，前端 `onCustomEvent` 按 `type` 分发：

| custom 事件 type | payload 关键字段 | 前端处理 |
|---|---|---|
| `task_started` | `{task_id, description}` | 建子代理卡（status=in_progress） |
| `task_running` | `{task_id, message, message_index}` | `updateSubtask`：`latestMessage` 覆盖 + `steps` **累积**（`messageToStep` 归一化，不覆盖） |
| `task_completed` | `{task_id, result, usage}` | 卡 status=completed + result |
| `task_failed` | `{task_id, error, usage}` | 卡 status=failed + error |
| `task_cancelled` | `{task_id, error, usage}` | 卡 status=failed + error |
| `task_timed_out` | `{task_id, error?, usage}` | 卡 status=failed + error |
| `llm_retry` | `{attempt, max_attempts, wait_ms, message}` | `toast(message)` 提示重试 |

**`task_running` 累积而非覆盖**（#3779）：旧实现只保 `latestMessage`，子代理跑的工具步骤闪过即失、刷新全丢。现 `steps` 数组按 `message_index` 追加（`messageToStep` 把 raw AIMessage/ToolMessage 归一为 `SubtaskStep`：`kind:"ai"` 带 `tool_calls` / `kind:"tool"` 带 `tool_name`）。历史回放时 `eventsToSteps` 从持久化 `subagent.step` run-event 拉同形状步骤，`mergeSteps` 按 `message_index` 去重合并。

### `values` 帧消毒：后端职责，前端不重复

`values` 帧携带全量 state（含 messages），可能含 `data:` base64 image。**消毒在后端 serializer 做**（剥离 base64），前端不再二次处理。前端只消费已消毒的 `thread.values`。`INTERNAL_MARKER_TAGS`（`uploaded_files` / `slash_skill_activation` / `system-reminder` / `memory` / `current_date`）由 `stripInternalMarkers` 在导出路径剥离，作为 `hide_from_ui` 之外的纵深防御；UI 渲染路径用更窄的 `stripUploadedFilesTag` 避免误剥用户合法输入的 meta 讨论内容。

### Last-Event-ID 断流重连（ring buffer + 终态短路）

SSE 客户端原生支持 `Last-Event-ID`：连接断开后浏览器自动重连带上一帧 `id:` 值。gateway `MemoryStreamBridge._resolve_start_offset` 解析 `{ts}-{seq}` 格式，`seq` 等于事件在 run 内的绝对偏移，O(1) 算术定位回放起点：

```python
# 伪代码：ring buffer + Last-Event-ID O(1) 回放
local_index = seq - stream.start_offset
if 0 <= local_index < len(events) and events[local_index].id == last_event_id:
    return start_offset + local_index + 1    # 从下一帧续
# 否则降级：从最早保留事件重放
```

前端**不写 reconnect 逻辑**--`useStream` 内部 EventSource 处理。但需在 `useEffect` 卸载时调 `thread.stop()`，否则路由切换后后台 task 仍烧 token。冷重连（刷新页面丢失 EventSource）走 `joinStream(threadId, runId)`，bridge ring buffer 仍持过去事件可补齐。

**终态短路**（防阻塞）：`joinStream` 到已达终态（success/error/timeout/interrupted）的 run，要么 409，要么 bridge 被 reaped（60s）后永远阻塞在排空条件变量上 -> `isLoading` 卡 true。`createCompatibleClient` patch `joinStream`：先 `shouldSkipReconnect`（`client.runs.get` 查 status），终态则 `clearReconnectRun` + return，让 `onSuccess` 跑、`isLoading` 翻回 false。`interrupted` 在本系统只由用户 stop 写入（resumable human-in-the-loop 用 `Command(goto=END)` 结束为 `success`），故无东西可流。

**ring buffer 容量边界**：默认 `queue_maxsize=256`。token 增量频繁（思考模式每秒 30+ delta），~8s 推理后开始淘汰最旧事件。这是"快连接重放"窗口，非"长时间离线追回"窗口--长时间离线后需主动调 `/runs/{rid}/messages` 拉持久化端点。

### CSRF 双提交 cookie（onRequest 注入 + 双路径对称）

Web 路径凭证是 HttpOnly cookie JWT，前端不持 token。CSRF 靠 Double-Submit Cookie：`csrf_token` cookie（JS 可读）+ `X-CSRF-Token` header（出站注入），gateway `CSRFMiddleware` 用 `secrets.compare_digest` 校验常时相等。

**SDK 路径注入**：`createCompatibleClient` 的 `onRequest: injectCsrfHeader` 钩子在每次出站 fetch 前跑。`isStateChangingMethod(method)`（POST/PUT/DELETE/PATCH）时从 `document.cookie` 实时读 `csrf_token`，塞 `X-CSRF-Token`。**逐请求读 cookie** 而非构造时烘焙进 `defaultHeaders`--登录/登出/改密 cookie 轮转对 SDK 透明。

**直接 REST 路径注入**：`fetcher.ts:fetch` 包装函数对非 SDK 端点（`/api/scheduled-tasks/*`、`/runs/regenerate/prepare` 等）做同样注入 + `credentials:"include"` + 401 跳登录。

**双路径共享一份事实源**：`readCsrfCookie()` + `STATE_CHANGING_METHODS = new Set(["POST","PUT","DELETE","PATCH"])` 两路径共享，与 gateway `should_check_csrf` 逐字对齐（GET/HEAD/OPTIONS/TRACE 豁免）。任一路径漏注入即 403。

### SDK 单例 client（Map 缓存 + 方法 patch）

`getAPIClient(isMock?)` 用 `Map<cacheKey, LangGraphClient>` 做进程内单例（`"default"` / `"mock"` 两个 key）。首次 `createCompatibleClient` 构造并 patch 三个方法：

- `runs.stream`：包 `sanitizeRunStreamOptions`（丢 SDK 不支持的 stream mode，如 `events`）
- `runs.cancel`：吞终态 409（`isRunNotCancellableError`）-> no-op + `clearReconnectRun`
- `runs.joinStream`：终态短路（`shouldSkipReconnect`）+ 吞 inactive 409（`isInactiveRunStreamError`）-> `clearReconnectRun`

单例保证全 app 同一 thread 只有一条 SSE，避免每次渲染 `new Client` 致连接泄漏、cookie 快照不一致、patch 逻辑分叉。

### 关键不变量（违反则消息错乱 / 连接泄漏 / 403）

1. **client 单例**：`getAPIClient` 的 `Map` 缓存保证不重复构造，全 app 同一 thread 一条 SSE。
2. **CSRF 双路径对称**：SDK `onRequest` 与 `fetcher.ts:fetch` 共享 `readCsrfCookie` + `STATE_CHANGING_METHODS`，任一漏注入即 403。
3. **messages 去重保留 last index**：`turn_duration` 在末帧，取 last 才保真；取 first 会丢时长统计。
4. **tool call 与 tool result 不同命名空间**：`message:{id}` vs `tool:{tool_call_id}`，一个 tool 的 call+result 是两条，展示层按 `tool_call_id` 关联。
5. **hidden 消息参与 identity 追踪但不展示**：控制消息（`summary` / `loop_warning` 等）不参与重叠裁剪。
6. **custom 事件 `task_running` 累积 steps 而非覆盖**：覆盖会丢工具步骤历史。
7. **`joinStream` 终态短路**：不短路会永远阻塞排空条件变量，`isLoading` 卡 true。
8. **`values` 消毒在后端**：前端不二次处理 base64 image。

### 在端到端链路中的位置 + 与 frontend-app-design 互补边界

本 skill 处于 [[e2e-request-lifecycle]] 的 **⑧渲染-Web** 跳的协议层。⑦StreamBridge publish 的 SSE 事件（见 [[gateway-runs-and-sse]]）经 `useStream` 解码 -> `useThreadStream` reducer -> 渲染。CSRF 双提交与 [[auth]] 的 `CSRFMiddleware` 对称。

| 维度 | 本 skill（frontend-streaming-protocol） | [[frontend-app-design]] |
|---|---|---|
| 粒度 | SSE 协议级细节 | 整体应用骨架 |
| 流式 | 事件 schema / messages 按 id 累积 / custom 渲染 / Last-Event-ID / CSRF 注入 | 三路乐观合并**整体**架构 + 摘要救援缓冲 |
| 鉴权 | CSRF 双提交 cookie + header 注入机制 | SSR 守卫穷尽 switch + CSRF 双路径对称 |
| 路由/布局 | 不涉及 | App Router + provider 栈 |
| scheduled-tasks | 不涉及 | REST 四件套 |

两 skill 在"流式聊天接入"处交叉：本 skill 给 SDK 事件 -> message 累积的协议级映射，frontend-app-design 给 `useThreadStream` 的整体 reducer 架构。改流式渲染时两 skill 都读。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `frontend/src/core/threads/hooks.ts` | `useThreadStream`：`useStream` 回调映射 + `messageIdentity` + `dedupeMessagesByIdentity` + `mergeMessages` + `onCustomEvent`（task_running 累积 / llm_retry toast） | [use-thread-stream.md](./references/code/use-thread-stream.md) §1 |
| `frontend/src/core/tasks/{types,steps}.ts` | `SubtaskStep` / `Subtask` 类型 + `messageToStep`（raw message -> step 归一化）+ `eventsToSteps` + `mergeSteps` | [use-thread-stream.md](./references/code/use-thread-stream.md) §2 |
| `frontend/src/core/messages/utils.ts` | `isHiddenFromUIMessage` + `HIDDEN_CONTROL_MESSAGE_NAMES` + `INTERNAL_MARKER_TAGS`（去重 / 消毒边界） | [use-thread-stream.md](./references/code/use-thread-stream.md) §3 |
| `frontend/src/core/api/api-client.ts` | SDK 单例 client：`getAPIClient` + `createCompatibleClient` + `injectCsrfHeader`（onRequest CSRF）+ `runs.stream/cancel/joinStream` patch + 终态短路 + static-mode 降级 | [singleton-client.md](./references/code/singleton-client.md) §1 |
| `frontend/src/core/api/stream-mode.ts` | `sanitizeRunStreamOptions`：丢弃 SDK 不支持的 stream mode + 去重警告 | [singleton-client.md](./references/code/singleton-client.md) §2 |
| `frontend/src/core/api/fetcher.ts` | 直接 REST 路径 CSRF：`readCsrfCookie` + `isStateChangingMethod` + `STATE_CHANGING_METHODS` + `fetch` 包装 | [singleton-client.md](./references/code/singleton-client.md) §3 |
| `core/helix/runtime/stream_bridge/{base,memory}.py` | `StreamEvent` dataclass + `END_SENTINEL`/`HEARTBEAT_SENTINEL` + `MemoryStreamBridge`（ring buffer + `Last-Event-ID` O(1) 回放） | [sse-event-schema.md](./references/code/sse-event-schema.md) §1 |
| `gateway/gateway/services.py` | `format_sse`（线格式）+ `sse_consumer`（Last-Event-ID -> bridge.subscribe） | [sse-event-schema.md](./references/code/sse-event-schema.md) §2 |
| `core/helix/runtime/runs/worker.py` | `_lg_mode_to_sse_event`（messages-tuple -> messages）+ `metadata` 首发 + `events` 跳过 | [sse-event-schema.md](./references/code/sse-event-schema.md) §3 |
| `core/helix/tools/builtins/task_tool.py` | `get_stream_writer()` 发 `task_started/running/completed/failed/cancelled/timed_out` | [sse-event-schema.md](./references/code/sse-event-schema.md) §4 |
| `core/helix/agents/middlewares/llm_error_handling_middleware.py` | `get_stream_writer()` 发 `llm_retry` | [sse-event-schema.md](./references/code/sse-event-schema.md) §4 |

### 模块入口与索引

**SSE 事件 schema 完整源码**（见 [sse-event-schema.md](./references/code/sse-event-schema.md)）：
- §1 `StreamEvent` / sentinels / `MemoryStreamBridge`：ring buffer（`queue_maxsize=256`）+ `_resolve_start_offset`（`{ts}-{seq}` O(1) 回放）+ `subscribe`（heartbeat 15s + END_SENTINEL）
- §2 `format_sse`：`event:` -> `data:` -> `id:` -> 空行，匹配 LangGraph Platform 线格式；`sse_consumer` 读 `Last-Event-ID` 头
- §3 `_lg_mode_to_sse_event`：LG 内部 mode 1:1 映射 SSE 事件名（`messages` 保持 `messages`）；`messages-tuple` 在 worker 转 `messages`
- §4 custom 事件 payload：`task_started/running/completed/failed/cancelled/timed_out`（task_tool）+ `llm_retry`（llm_error_handling_middleware）

**useThreadStream reducer 完整源码**（见 [use-thread-stream.md](./references/code/use-thread-stream.md)）：
- §1 `useThreadStream`：`useStream` 回调映射（onCreated/onUpdateEvent/onCustomEvent/onError/onFinish）+ `messageIdentity` + `dedupeMessagesByIdentity`（last-index + turn_duration 保真）+ `mergeMessages`（重叠裁剪）
- §2 `SubtaskStep` / `messageToStep` / `eventsToSteps` / `mergeSteps`：custom 事件 -> step 归一化与累积
- §3 `isHiddenFromUIMessage` / `HIDDEN_CONTROL_MESSAGE_NAMES` / `INTERNAL_MARKER_TAGS`：去重与消毒边界

**SDK 单例 client + CSRF 完整源码**（见 [singleton-client.md](./references/code/singleton-client.md)）：
- §1 `api-client.ts`：`getAPIClient`（Map 单例）+ `createCompatibleClient`（onRequest CSRF + runs.stream/cancel/joinStream patch + 终态短路 + static-mode 降级）
- §2 `stream-mode.ts`：`sanitizeRunStreamOptions` + `warnUnsupportedStreamModes`（去重警告 Set）
- §3 `fetcher.ts`：`readCsrfCookie` + `isStateChangingMethod` + `STATE_CHANGING_METHODS` + `fetch` 包装（CSRF + credentials + 401 跳登录）

## 反模式与陷阱

- ❌ **手写 SSE 而非用 SDK** -> 自己 `new EventSource` 解析 `data:` 行。后果：丢 `messages-tuple` 按 id 累积、丢 `Last-Event-ID` 续传、丢 `onCreated`/`onCustomEvent` 回调、CSRF 注入没处挂。修复：用 `@langchain/langgraph-sdk/react` 的 `useStream`，`client` 传 `getAPIClient()`。
- ❌ **`messages` 去重取 first index** -> `turn_duration` 在末帧写入，取 first 丢时长统计。修复：`dedupeMessagesByIdentity` 保留 last index + `preservedTurnDurations` 回填。
- ❌ **tool call 与 tool result 当同 identity 去重** -> 用 `message.id` 统一去重会把 tool result 当成 tool call 的"新版本"覆盖。修复：tool result 用 `tool:{tool_call_id}`，tool call 用 `message:{id}`，两命名空间各自 last。
- ❌ **`task_running` 覆盖 latestMessage 而不累积 steps** -> 子代理跑的工具步骤闪过即失、刷新全丢（#3779）。修复：`updateSubtask` 的 `steps` 数组按 `message_index` 追加（`messageToStep` 归一化），`latestMessage` 单独覆盖。
- ❌ **`joinStream` 不短路终态 run** -> 重连到已 success/error/timeout/interrupted 的 run，bridge 被 reaped 后永远阻塞排空条件变量，`isLoading` 卡 true，刷新后第一条消息发不出。修复：`shouldSkipReconnect`（`runs.get` 查 status）+ `TERMINAL_RUN_STATUSES` 短路 + `clearReconnectRun`。
- ❌ **`runs.cancel` 不吞终态 409** -> stop 点击落在后端已翻 success 但 SSE 未排空的窗口，409 冒泡为未处理 rejection。修复：`isRunNotCancellableError` 吞 409 no-op + `clearReconnectRun`（仅当 key 仍匹配此 runId 才删）。
- ❌ **每次渲染 `new LangGraphClient`** -> 多 SSE 连接、cookie 快照不一致、patch 逻辑各一份。修复：`getAPIClient` 的 `Map<cacheKey, Client>` 单例。
- ❌ **CSRF 双路径契约不一致** -> SDK 路径用 `onRequest` 注入，REST 路径用裸 `globalThis.fetch` 漏注入。后果：聊天页正常，scheduled-tasks / regenerate-prepare 页 403。修复：所有非 SDK REST 走 `fetcher.ts:fetch`；`readCsrfCookie` + `STATE_CHANGING_METHODS` 双路径共享。
- ❌ **构造时烘焙 CSRF 进 `defaultHeaders`** -> 登录/登出/改密后 cookie 轮转，header 还是旧值 -> 403。修复：`onRequest` 逐请求读 `document.cookie`。
- ❌ **hidden 消息参与重叠裁剪** -> `summary` / `loop_warning` 等控制消息被当可见消息裁剪，丢失追踪。修复：`lastVisibleIndexByIdentity` 仅含 visible；hidden 仅进 `lastIndexByIdentity`。
- ❌ **`streamMode` 传 string 而非 array** -> `messages-tuple` 带后缀别名只在 array 形态被网关识别，string 形态被丢。修复：`streamMode: ["values", "messages-tuple"]`。
- ❌ **错误帧只靠 EventSource `error` handler** -> `event: error` 是 SSE named event，浏览器不触发连接级 `error` handler（那个只在连接故障触发）。修复：`onError` 回调显式监听。
- ❌ **`onFinish` 里直接读 `state.messages` 的 token usage** -> `END_SENTINEL` 到达与末帧 metadata 写入间有 microtask 边界，可能 stale。修复：`onFinish` 内只 `invalidateQueries(['thread-token-usage', threadId])` 让 TanStack Query refetch 持久化端点。

## 落地参考（自测 / 调参 / 调试）

### 调参旋钮

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `reconnectOnMount` | `useStream` 参数 | mount 时是否靠 `Last-Event-ID` 续传上次未完成 run |
| `fetchStateHistory: { limit: 1 }` | `useStream` 参数 | mount 时拉最新 1 个 state 快照防空白 |
| `streamSubgraphs: true` | `thread.submit` 选项 | 流子图事件（子代理 `task_running` custom 依赖它） |
| `streamResumable: true` | `thread.submit` 选项 | 启用 `Last-Event-ID` 续传（与 [[gateway-runs-and-sse]] StreamBridge 对应） |
| `recursion_limit: 1000` | `thread.submit` config | 单 run 最大图步数 |
| `queue_maxsize: 256` | `MemoryStreamBridge` | ring buffer 容量；token 频繁时 ~8s 开始淘汰 |
| `heartbeat_interval: 15.0` | `StreamBridge.subscribe` | 无事件时发 heartbeat 防代理超时 |
| `TERMINAL_RUN_STATUSES` | `api-client.ts` | 终态集合（success/error/timeout/interrupted），`joinStream` 短路 |
| `SUPPORTED_RUN_STREAM_MODES` | `stream-mode.ts` | 前端白名单（values/messages/messages-tuple/updates/events/debug/tasks/checkpoints/custom） |
| `SUBAGENT_STEP_MAX_CHARS: 8192` | `step_events.py` | 单步 text / tool args / result 截断上限 |
| `NEXT_PUBLIC_LANGGRAPH_BASE_URL` | `env.js` | SDK baseURL；未设则 `window.location.origin` + nginx 重写 |

### 关键日志串

- `Creating API client with base URL: ...` - 单例 client 首次构造（应只 default/mock 各一次）
- `[helix] Dropped unsupported LangGraph stream mode(s): ...` - `sanitizeRunStreamOptions` 丢弃不支持 mode（如 `events`）
- `Run {runId} returned has_more without message seq values; leaving it pending for retry.` - 历史分页解析异常
- `last_event_id=%s not found in retained buffer; replaying from earliest retained event` - ring buffer 已淘汰，降级全量重放
- `subscriber for run %s fell behind retained buffer; resuming from offset %s` - 订阅者落后于 ring buffer 起点日志
- `[trace=%s] Task %s status: ...` - 子代理 task 轮询状态
- `Failed to emit llm_retry event` - llm_retry 发送失败（debug 级，不阻塞）

### 自测方向

- **messages 去重 last-index**：mock `[m1, m2(delta1), m2(delta2), m3]`，断言 `dedupeMessagesByIdentity` 保留 m2 的最后一份；m2 末帧带 `turn_duration`，断言存活副本有该字段。
- **tool call + result 两命名空间**：mock `[ai_msg(id=A, tool_calls=[{id=T}]), tool_msg(tool_call_id=T)]`，断言两条都保留（`message:A` + `tool:T`），不互相覆盖。
- **hidden 不参与裁剪**：mock `[hidden_msg(id=A, name="summary"), visible_msg(id=A)]`，断言 visible 保留、hidden 不参与 lastVisible 裁剪。
- **custom 事件 task_running 累积**：mock 连续两个 `task_running`（不同 `message_index`），断言 `steps` 数组长度 2 而非 1；`latestMessage` 是最后一条。
- **task_completed 落卡**：mock `task_completed`，断言卡 status=completed + result 写入。
- **llm_retry toast**：mock `llm_retry`，断言 `toast(message)` 调用。
- **joinStream 终态短路**：mock `runs.get` 返回 `status:"success"`，断言 `joinStream` 立即 return + `clearReconnectRun` 调用 + 不调 `originalJoinStream`。
- **cancel 吞终态 409**：mock `runs.cancel` 抛 `HTTP 409: ... is not cancellable (status: success)`，断言不冒泡 + `clearReconnectRun`；mock sibling 分支（"not active on this worker and cannot be cancelled"）断言**冒泡**（真实失败）。
- **CSRF 双路径对称**：SDK 路径 `thread.submit` -> 断言 `X-CSRF-Token` 在 header；REST 路径 `fetcher.ts:fetch` POST -> 同；GET -> 断言 header 不在。
- **逐请求读 cookie**：mock 登录后 `csrf_token` 变化，断言同一 client 实例下次请求带新 token（不重建 client）。
- **sanitizeRunStreamOptions**：传 `streamMode:["values","events","bogus"]`，断言输出只剩 `["values"]` + 控制台 warn 一次（去重 Set）。
- **ring buffer 回放**：mock `Last-Event-ID` = 某 seq，断言 `_resolve_start_offset` 返回 seq+1；mock 已淘汰的旧 id，断言降级 `start_offset`。
- **单例**：多次 `getAPIClient()` 断言同一引用；`getAPIClient(true)` 与 `getAPIClient()` 不同引用。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 完整源码：[references/code/sse-event-schema.md](./references/code/sse-event-schema.md)、[references/code/use-thread-stream.md](./references/code/use-thread-stream.md)、[references/code/singleton-client.md](./references/code/singleton-client.md)
- 端到端链路（本 skill 处于 ⑧渲染-Web 跳）：[[e2e-request-lifecycle]]
- 整体前端应用骨架（App Router / SSR 鉴权 / 三路乐观合并架构 / scheduled-tasks / 设计系统）：[[frontend-app-design]]
- run 生命周期与 SSE 服务端（RunManager + run_agent + StreamBridge + ring buffer）：[[gateway-runs-and-sse]]
- 长运行与取消（joinStream / cancel / on_disconnect / 终态语义）：[[long-running-and-cancellation]]
- 子代理委派（task 工具 + step 持久化 + 并发）：[[subagent-delegation]]
- 三层认证 + CSRF 双提交 gateway 侧（`AuthMiddleware` / `CSRFMiddleware`）：[[auth]]
- LangGraph SDK：https://langchain-ai.github.io/langgraph/cloud/sdk/
