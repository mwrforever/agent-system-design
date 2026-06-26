---
name: frontend-streaming-protocol
description: 设计前端消费 agent SSE 流——LangGraph SDK 单例 + CSRF cookie 注入、useThreadStream reducer、messages 模式按 id 累积、custom 事件渲染子代理卡片、values 帧消毒 data: image。
---

## 何时用

- 你在写 Next.js / React 前端消费 agent 流
- 前端用 `@langchain/langgraph-sdk` 但还需要 CSRF / 同源策略适配
- 多种事件类型（metadata / values / messages / custom / end）需要并存到同一 thread state
- 想支持断流重连 `Last-Event-ID`

## 设计思想

1. **SDK 客户端单例 + onRequest 注入**：从 cookie 读 `csrf_token`，写到 `X-CSRF-Token` 头；登录 / 登出后 cookie 刷新对 SDK 透明。
2. **`useThreadStream` reducer 分情况合并**：
   - `metadata`：写 `runId / threadId`，触发路由跳转
   - `messages`：按 message.id 累积文本（delta）；tool message 一次性插
   - `values`：覆盖 title / artifacts / todos / uploaded_files
   - `custom`：渲染子代理卡片 / 自定义业务事件
   - `error` / `end`：通知 listener
3. **乐观渲染先行**：用户点发送 → 立刻在前端 push optimisticMessages → SDK SSE 返回后 reconcile。
4. **`messages` 模式按 id dedup**：同一 message id 可能多次出现（每次是 delta），按 id concat；非 ai 消息 (tool / human) 一次性。
5. **`values` 帧消毒**：后端已剥离 `data:` base64 image；前端不再做。
6. **断流重连**：`sessionStorage` 保存当前 run_id；页面重载后 SDK `joinStream(threadId, runId)` 自动续。

## 实现模板

### 客户端单例 + CSRF

```ts
// core/api/api-client.ts
import { Client as LangGraphClient } from "@langchain/langgraph-sdk/client";

function injectCsrfHeader(_url: URL, init: RequestInit): RequestInit {
  if (init.method && /^(GET|HEAD)$/i.test(init.method)) return init;
  const token = readCsrfCookie();
  if (!token) return init;
  const headers = new Headers(init.headers);
  if (!headers.has("X-CSRF-Token")) headers.set("X-CSRF-Token", token);
  return { ...init, headers };
}

function createClient(): LangGraphClient {
  return new LangGraphClient({
    apiUrl: getLangGraphBaseURL(),
    onRequest: injectCsrfHeader,
  });
}

const _clients = new Map<string, LangGraphClient>();
export function getAPIClient(isMock?: boolean): LangGraphClient {
  const key = isMock ? "mock" : "default";
  let c = _clients.get(key);
  if (!c) { c = createClient(); _clients.set(key, c); }
  return c;
}
```

### useThreadStream Hook 骨架

```ts
// core/threads/hooks.ts
export function useThreadStream(opts: ThreadStreamOpts) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [title, setTitle] = useState<string>("");
  const [artifacts, setArtifacts] = useState<string[]>([]);
  const [todos, setTodos] = useState<Todo[]>([]);
  const [streaming, setStreaming] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const submit = useCallback(async (text: string, ctx?: RunContext) => {
    setStreaming(true);
    setError(null);
    // 1) 乐观渲染
    const optimistic: Message = { id: tempId(), type: "human", content: text };
    setMessages((m) => [...m, optimistic]);

    const client = getAPIClient();
    const stream = client.runs.stream(opts.threadId ?? "new", "lead_agent", {
      input: { messages: [{ type: "human", content: text }] },
      streamMode: ["values", "messages-tuple", "custom"],
      context: ctx ?? {},
    });

    try {
      for await (const ev of stream) {
        switch (ev.event) {
          case "metadata":
            opts.onStart?.(ev.data.thread_id, ev.data.run_id);
            persistRunId(ev.data.thread_id, ev.data.run_id);     // sessionStorage
            break;
          case "messages":
            setMessages((cur) => mergeMessageDelta(cur, ev.data));
            break;
          case "values":
            if (ev.data.title) setTitle(ev.data.title);
            if (ev.data.artifacts) setArtifacts(ev.data.artifacts);
            if (ev.data.todos) setTodos(ev.data.todos);
            break;
          case "custom":
            handleCustomEvent(ev.data);     // task_started / running / completed ...
            break;
          case "error":
            setError(new Error(ev.data.message));
            break;
          case "end":
            setStreaming(false);
            opts.onFinish?.();
            return;
        }
      }
    } catch (e) {
      setError(e as Error);
      setStreaming(false);
    }
  }, [opts.threadId]);

  return { messages, title, artifacts, todos, streaming, error, submit };
}
```

### messages 模式按 id 累积

```ts
function mergeMessageDelta(cur: Message[], data: [Chunk, Metadata]): Message[] {
  const [chunk, _meta] = data;
  if (!chunk?.id) return [...cur, chunk as Message];
  const idx = cur.findIndex((m) => m.id === chunk.id);
  if (idx === -1) return [...cur, chunk as Message];
  // delta：按角色合并
  const existing = cur[idx];
  if (existing.type === "ai" && chunk.type === "ai") {
    return [
      ...cur.slice(0, idx),
      { ...existing,
        content: concatContent(existing.content, chunk.content),
        tool_calls: chunk.tool_calls ?? existing.tool_calls,
        usage_metadata: chunk.usage_metadata ?? existing.usage_metadata },
      ...cur.slice(idx + 1),
    ];
  }
  // tool / human 一次性覆盖
  return [...cur.slice(0, idx), chunk as Message, ...cur.slice(idx + 1)];
}
```

### 子代理 custom 事件

```ts
function handleCustomEvent(data: any) {
  if (typeof data?.type !== "string") return;
  if (data.type.startsWith("task_")) {
    upsertSubagentCard({
      taskId: data.task_id,
      status: data.type.replace("task_", "") as SubagentStatus,
      description: data.description,
      message: data.message,                  // task_running 时存增量 AIMessage
      result: data.result,                    // task_completed
      error: data.error,                      // task_failed / cancelled / timed_out
      usage: data.usage,
    });
  }
}
```

### 断流重连

```ts
useEffect(() => {
  const runId = sessionStorage.getItem(`lg:stream:${threadId}`);
  if (!runId) return;
  const stream = getAPIClient().runs.joinStream(threadId, runId);
  consume(stream);   // 同样的 reducer
}, [threadId]);
```

## 反模式

- ❌ 每次渲染都 `new LangGraphClient` → 多 SSE 连接、CSRF cookie 状态不一致
- ❌ `messages` 模式不按 id dedup → 文本被 append N 次
- ❌ 不区分 `messages` delta 与一次性 → 工具消息被重复插入
- ❌ 乐观渲染不和 server message id reconcile → server 返回真实 id 后两条消息并存
- ❌ 用 `Date.now()` 作 optimistic message id → 同毫秒多消息冲突；用 `crypto.randomUUID()` 更稳
- ✅ `sessionStorage` 持久 run_id，刷新页面 `joinStream` 自动续
- ✅ 处理 `409 not active on this worker` 时清理 sessionStorage 避免死循环

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[gateway-runs-and-sse]] [[long-running-and-cancellation]] [[subagent-delegation]]
- LangGraph SDK：https://langchain-ai.github.io/langgraph/cloud/sdk/
