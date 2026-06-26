# Implementation Notes — Frontend Streaming Protocol

> 前端如何与网关的 SSE 协议对接：`stream_mode` 协商、消息去重、断线重连、
> 增量消息合并的客户端实现细节。路径以占位形式给出。
>
> 这里聚焦"客户端如何对接服务端 SSE 协议"——服务端协议本身、ring buffer、
> RunStore 等下沉细节参考 [[gateway-runs-and-sse]]。

---

## 一、协议层组件

| 组件 | 位置 | 职责 |
|------|------|------|
| `useStream` | 第三方 SDK `@langchain/langgraph-sdk/react` | 订阅 SSE，维护 messages/values/run_id 状态 |
| `sanitizeRunStreamOptions` | `<repo-root>/frontend/.../api/stream-mode.ts` | 提交前过滤客户端请求的 `streamMode` |
| `warnUnsupportedStreamModes` | 同上 | 仅警告一次被丢弃的 mode（去重 Set） |
| `useThreadStream` | `<repo-root>/frontend/.../threads/hooks.ts` | 业务封装：拼接 messages、调度 mutation、捕获 onFinish |
| `dedupeMessagesByIdentity` | 同上 | UI 展示侧去重，按 `tool_call_id` 或 `message.id` 取 last 出现位置 |

整体 data flow：用户输入 → `useThreadStream.send()` → langgraph-sdk
`runs.stream()` 发 SSE 请求 → useStream 内部 EventSource 订阅 →
按 event name 分发到 `messages` / `values` / `updates` 内部 channel →
React 组件订阅这些 channel 渲染。各 channel 之间通过 LangGraph 的
checkpoint 状态保持一致。

---

## 二、`stream_mode` 协商与白名单

前端维护与网关对齐的 mode 白名单：

```
values | messages | messages-tuple | updates | events
| debug | tasks | checkpoints | custom
```

`sanitizeRunStreamOptions(options)` 在每次发请求前：

1. 取出 `options.streamMode`（可能是 string 或 string[]）
2. 通过 `SUPPORTED_RUN_STREAM_MODES` Set 过滤
3. 被过滤掉的 mode 走 `warnUnsupportedStreamModes()` ——
   用模块级 `warnedUnsupportedStreamModes` Set 保证同名只警告一次，
   防止用户在控制台被刷屏
4. 返回过滤后的 options；若全员合法直接 return 原对象（避免无谓 alloc）

**注意**：`events` 在白名单里，但网关侧 Worker 会跳过它（依赖 `astream_events`
与 `values` 不兼容）。前端不主动剔除，靠 Worker 静默丢弃 + 日志记录即可。
这是一种"宽进严出"——客户端 SDK 升级了想跑 `events` 不会立刻爆掉。

**默认请求 mode**：业务 hook 默认请求 `["values", "messages-tuple"]`——
前者拿全量 state 快照（title、artifacts、todos），后者拿增量 token delta。
两者合起来等价于 "一边渲染流式文本，一边维护非消息字段"。客户端不主动请求
`updates` 是因为大多数 middleware update 不影响 UI，按需在特定场景开启。

---

## 三、消息身份与 UI 去重

LangGraph 的 messages 流以增量形式投递：同一条 AI message 的多次 token 增量
共享一个 `message.id`；tool result 则带 `tool_call_id`。前端用统一的
identity 函数：

```ts
function messageIdentity(m): string | undefined {
  if (m.tool_call_id) return `tool:${m.tool_call_id}`;
  if (m.id)          return `message:${m.id}`;
  return undefined;  // 无身份不参与去重
}
```

`dedupeMessagesByIdentity` 的关键决策：**保留 last index**。
SDK 把每次 token delta 视作新 entry 追加进数组，仅展示最后一份即等价于
拼接完整文本。隐藏消息（`isHiddenFromUIMessage`）仅参与 identity 追踪不参与展示，
所以维护两套 Map：`lastIndexByIdentity`（含 hidden）和
`lastVisibleIndexByIdentity`（仅 visible）。

**这是 UI 展示规约，不是 LangChain 通用契约。**承担独立 tracing/task
语义的隐藏消息应使用独立 id 或独立 stream/state channel，不要依赖
"被同 identity 的可见消息覆盖"的副作用。

**tool call vs tool result 的身份对齐**：tool result 用 `tool_call_id` 做
identity，对应的 tool call 用 message id。这两个不在同一个命名空间里，
所以一个 tool 的 call + result 会作为**两条**保留下来——展示层把它们
按 `tool_call_id` 关联，渲染为"折叠 tool block"。

---

## 四、状态合成：messages + values + updates

useStream 内部维护三类 channel：

- **messages-tuple**：增量 token delta，按 id 聚合后 rebuild 完整文本
- **values**：full state snapshot，title/artifacts/todos 从这里取
- **updates**：节点产出，前端只关注少数 middleware（如 `SummarizationMiddleware.before_model`）
  来判断是否触发了摘要

业务 hook `useThreadStream` 在 useStream 之上做：

1. 把 `state.messages` 喂给 `dedupeMessagesByIdentity` 再渲染
2. 监听 `values.title` 同步到 thread metadata
3. 监听 summarization update key 触发 toast 提示"会话已摘要"
4. `onFinish` 回调拿到最终 state，触发 token-usage refetch（TanStack Query 失效）

避免重复展示的另一道防线：Worker 在 values chunk 里**不**回放 messages
channel 已经投递过的 AI text——后端 serializer 显式剔除，否则用户会看到回答闪两次。

**TanStack Query 缓存策略**：`thread-token-usage` / `thread-list` / 单条
`thread-state` 各自独立 key。`onFinish` 触发的 invalidate 范围要精确——
broad invalidate 会把所有线程的 token-usage 重 fetch，对侧边栏数十条
线程的部署不友好。建议 key 形如 `['thread-token-usage', threadId]`
并只 invalidate 单线程粒度。

---

## 五、重连与 `Last-Event-ID`

SSE 客户端原生支持 `Last-Event-ID` 头：连接断开后浏览器自动重连时
带上上一帧的 `id:` 字段值。网关侧 `MemoryStreamBridge._resolve_start_offset()`
解析格式 `<ts>-<seq>`，提取 seq 后用 O(1) 算术回放：

```
local_index = seq - stream.start_offset
if 0 <= local_index < len(events) and events[local_index].id == last_event_id:
    return start_offset + local_index + 1
# 否则降级为从最早保留事件重放
```

前端不需要写 reconnect 逻辑——`useStream` 内部由 EventSource API 处理。
但需要在 `useEffect` 卸载时调用 `useStream.stop()`，否则路由切换后
后台 task 仍在烧 token（除非用户显式选了 `on_disconnect: "continue"`）。

`/api/threads/{tid}/runs/{rid}/join` 端点允许冷重连：丢失整个 EventSource
连接（例如刷新页面）后，前端用 thread/run id 重新订阅，bridge 的 ring buffer
仍持有过去 60s 的事件，可补齐丢失片段。超出 ring buffer 的事件只能从
EventStore 的 `/messages` 与 `/events` REST 端点分页拉取。

**ring buffer 容量边界**：默认 `queue_maxsize=256` 条事件。token 增量频繁
（Qwen-72B 在思考模式下每秒可推 30+ delta），意味着 ~8s 推理后就会
开始淘汰最旧事件。这是"快连接重放"窗口，不是"长时间离线后追回"窗口。
长时间离线后回来的客户端需要主动调 `/runs/{rid}/messages` 拉持久化端点。

---

## 六、客户端常见坑

1. **streamMode 必须能正确编码**：传 string `"messages"` 会被 SDK 包成数组，
   但 `messages-tuple` 这种带后缀的别名只在 array 形态下被网关识别。

2. **去重不能跨 thread**：identity 仅在单条 thread 内有效。切换 thread
   要清空 `lastIndexByIdentity`，否则同 id 的旧消息会被错误地视作"新版本"。

3. **`turn_duration` 的保留**：`additional_kwargs.turn_duration` 是 Worker
   在最后一帧写入的——dedupe 取 last index 时正好保留这个字段，
   切勿改成 first index。

4. **EventSource 单连接限制**：浏览器对同一 origin 同时打开的 EventSource
   有数量限制（Chrome 6 个），多 tab 同时跑 Run 会卡。生产建议
   `on_disconnect: "continue"` + 主动 polling 而非保持长连接。

5. **错误帧的 UI 表达**：Worker 抛异常时发 `event: error` 帧，但 SSE 协议
   层面这只是一个 named event，浏览器不会触发 EventSource 的 `error` handler
   （那个 handler 只在连接级故障时触发）。前端必须在 `on()` listener
   里显式监听 `"error"` event name。

6. **token usage 与 `onFinish` 的时序**：Worker 把 token 累计写在
   stream 的最后一帧 metadata 里，但 `onFinish` 触发时机是
   `END_SENTINEL` 到达——两者之间存在 microtask 边界。前端如果在 `onFinish`
   里立刻访问 `state.messages` 的最新 token usage，可能拿到 stale 值。
   保险做法：`onFinish` 内只触发 `queryClient.invalidateQueries(['thread-token-usage', threadId])`，
   让 TanStack Query 自己 refetch 持久化端点。

7. **错乱 dedupe 的征兆**：若你看到同一段 AI 回复在 UI 上闪两次（再被覆盖），
   通常是 messages-tuple delta 与 values snapshot 都把同一条 message 投递了。
   服务端应当只在一种 mode 投递；客户端去重无法补救这个问题——
   identity 相同时取 last index 是把"晚到"的当真实，如果晚到的是 values
   snapshot 而 values 的 message 是较旧版本，就会"倒退"。

---

[[gateway-runs-and-sse]] · [[checkpointer-and-state]] · [[thread-meta-and-history]] · [[upload-pipeline]] · [[token-usage-tracking]]
