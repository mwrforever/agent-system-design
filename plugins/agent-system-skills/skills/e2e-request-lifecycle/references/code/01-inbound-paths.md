# ① 入站三条路径完整源码

> 本文件是脊柱 `SKILL.md` 第①跳"入站"的深度展开。脊柱只给三条路径的入口伪代码 + organ 指向；此处给 Web 前端 / IM（钉钉）/ 定时任务三条入站路径的真实源码片段（匿名化后 + 中文注解）。
>
> 代码已按插件匿名化规则映射到自定结构（`frontend.*` / `core/helix.*` / `channels.*` / `scheduler.*` / `gateway.*`），去除一切项目字样；原代码注释保真，中文注解以"注："或行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱）、`[[gateway-runs-and-sse]]`（RunManager + run_agent worker）、`[[frontend-app-design]]`（Next.js 集成）、`[[frontend-streaming-protocol]]`（SSE schema）、`[[im-channels]]`（MessageBus/ChannelManager/钉钉长连接与 AI Card）、`[[scheduled-tasks]]`（poller + lease + cron/once）、`[[auth]]`（内部 token + owner 头）。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `frontend/src/core/threads/hooks.ts` | Web 前端：`useThreadStream` 消费 LangGraph SSE 流 + 乐观合并 |
| `core/helix/runtime/runs/worker.py` | 后台执行 agent run：装 runtime context + 驱动 astream + publish 到 bridge |
| `channels/channels/dingtalk.py` | 钉钉：`dingtalk-stream` 出站长连接回调 -> MessageBus + AI Card 流式渲染 |
| `channels/channels/message_bus.py` | 异步 pub/sub：入站走队列，出站走回调 |
| `channels/channels/manager.py` | dispatcher：从 bus 取入站 -> 调 run client（带内部认证 owner 头） |
| `scheduler/scheduler/service.py` | `ScheduledTaskService` poller：认领到期任务（lease 并发限流） |
| `gateway/gateway/services.py` | `launch_scheduled_thread_run`：桥接调度器 -> run 生命周期（内部认证 + non_interactive） |

---

## 1. Web 前端路径

> React 端用 LangGraph SDK 的 `useStream` hook 消费 SSE；Gateway 端的 `run_agent` worker 把图的事件流 publish 到 `StreamBridge`。前端与后端经 nginx 代理：`/api/langgraph/*` -> Gateway 原生 `/api/*`。

### 1.1 `frontend/src/core/threads/hooks.ts` - 消费 LangGraph SSE 流并乐观合并

```typescript
// frontend/src/core/threads/hooks.ts - 消费 LangGraph SSE 流并乐观合并
export function useThreadStream({ threadId, context, isMock, onSend, onStart, onFinish, onToolEnd }: ThreadStreamOptions) {
  const thread = useStream<AgentThreadState>({
    client: getAPIClient(isMock),       // baseURL 默认 /api/langgraph（经 nginx 代理到 Gateway）
    assistantId: "lead_agent",
    threadId,
    reconnectOnMount: true,             // 断线重连，靠 Last-Event-ID 续传（见跨切不变量 3）
    fetchStateHistory: { limit: 1 },
    onUpdateEvent(data) { /* values 快照：摘要救援、标题缓存 */ },
    onCustomEvent(event) { /* 子代理 task_running 等自定义事件 */ },
    onFinish(state) { listeners.current.onFinish?.(state.values); },
    onError(error) { /* 清乐观消息、toast、刷 token 用量 */ },
  });
  // 三路合并：历史 + 实时流 + 乐观消息（见 ⑧渲染 references/code/08-rendering.md）
  const mergedMessages = mergeMessages(effectiveHistory, persistedMessages, visibleOptimisticMessages);
}
```

### 1.2 `core/helix/runtime/runs/worker.py` - 后台执行 agent run，把事件发到 bridge

```python
# core/helix/runtime/runs/worker.py - 后台执行一个 agent run，把事件发到 bridge
async def run_agent(
    bridge: StreamBridge, run_manager: RunManager, record: RunRecord, *,
    ctx: RunContext, agent_factory: Any, graph_input: dict, config: dict,
    stream_modes: list[str] | None = None, stream_subgraphs: bool = False,
    interrupt_before: list[str] | Literal["*"] | None = None,
    interrupt_after: list[str] | Literal["*"] | None = None,
) -> None:
    checkpointer = ctx.checkpointer
    run_id, thread_id = record.run_id, record.thread_id

    # 把 config["context"]（含 non_interactive、user_id、channel_user_id、secrets）
    # 装进 runtime.context，供中间件/工具经 ToolRuntime.context 读取
    runtime_ctx = _build_runtime_context(thread_id, run_id, config.get("context"), ctx.app_config)
    _install_runtime_context(config, runtime_ctx)
    runtime = Runtime(context=runtime_ctx, store=ctx.store)
    config.setdefault("configurable", {})["__pregel_runtime"] = runtime

    # 用 astream 驱动图，每个 chunk 经 _lg_mode_to_sse_event 映射成 SSE 事件名后 publish（见 ⑦）
    async for item in agent.astream(input_payload, config=stream_config,
                                    stream_mode=lg_modes, subgraphs=stream_subgraphs):
        if record.abort_event.is_set():
            break
        mode, chunk = _unpack_stream_item(item, lg_modes, stream_subgraphs)
        sse_event = _lg_mode_to_sse_event(mode)
        await bridge.publish(run_id, sse_event, serialize(chunk, mode=mode))
```

> **指向**：`[[gateway-runs-and-sse]]`（RunManager + run_agent worker 全貌）、`[[frontend-app-design]]`（Next.js 集成）、`[[frontend-streaming-protocol]]`（SSE schema）。worker 的 pre-run 快照 + 终结 rollback 完整源码见 `references/code/07-streaming-and-resume.md`。

---

## 2. IM（钉钉）路径

> 钉钉用 `dingtalk-stream` 的**出站长连接**（非 webhook）接消息：SDK 回调把入站消息塞进 `MessageBus`；`ChannelManager` 的 dispatcher 从 bus 取消息，调 `client.runs.wait`，并以**内部认证头**（owner 头）标明所属用户。

### 2.1 `channels/channels/dingtalk.py` - dingtalk-stream 出站长连接回调 -> MessageBus

```python
# channels/channels/dingtalk.py - dingtalk-stream 出站长连接回调 -> MessageBus
async def process(self, callback: Any) -> tuple[int, str]:
    import dingtalk_stream
    incoming_message = dingtalk_stream.ChatbotMessage.from_dict(callback.data)
    self._channel._on_chatbot_message(incoming_message)
    return dingtalk_stream.AckMessage.STATUS_OK, "OK"

def _on_chatbot_message(self, message: Any) -> None:
    text = self._extract_text(message)
    if not text:
        return
    inbound = self._make_inbound(chat_id=chat_id, user_id=sender_staff_id, text=text,
                                 msg_type=msg_type, thread_ts=msg_id, metadata={...})
    inbound.topic_id = topic_id
    # 钉钉 SDK 回调跑在独立线程，跨线程把入站消息扔回主事件循环 -> MessageBus
    asyncio.run_coroutine_threadsafe(self._prepare_inbound(chat_id, inbound), self._main_loop)

async def _prepare_inbound(self, chat_id: str, inbound: InboundMessage) -> None:
    inbound = await self._attach_connection_identity(inbound)
    await self._send_running_reply(chat_id, inbound)   # 先发"运行中"卡片占位
    await self.bus.publish_inbound(inbound)
```

### 2.2 `channels/channels/message_bus.py` - 异步 pub/sub：入站走队列，出站走回调

```python
# channels/channels/message_bus.py - 异步 pub/sub：入站走队列，出站走回调
class MessageBus:
    def __init__(self) -> None:
        self._inbound_queue: asyncio.Queue[InboundMessage] = asyncio.Queue()
        self._outbound_listeners: list[OutboundCallback] = []

    async def publish_inbound(self, msg: InboundMessage) -> None:
        await self._inbound_queue.put(msg)

    async def get_inbound(self) -> InboundMessage:
        return await self._inbound_queue.get()

    async def publish_outbound(self, msg: OutboundMessage) -> None:
        for callback in self._outbound_listeners:
            await callback(msg)
```

### 2.3 `channels/channels/manager.py` - dispatcher：从 bus 取入站，调 run client，带内部认证 owner 头

```python
# channels/channels/manager.py - dispatcher：从 bus 取入站，调 run client，带内部认证 owner 头
async def _dispatch_loop(self) -> None:
    while self._running:
        try:
            msg = await asyncio.wait_for(self.bus.get_inbound(), timeout=1.0)
        except TimeoutError:
            continue
        if self._is_duplicate_inbound(msg):
            continue
        task = asyncio.create_task(self._handle_message(msg))

async def _handle_chat(self, msg: InboundMessage, extra_context=None, *, bound_identity_checked=False) -> None:
    client = self._get_client()
    thread_id, _ = await self._get_or_create_thread(client, msg)
    assistant_id, run_config, run_context = self._resolve_run_params(msg, thread_id)
    run_kwargs = {"input": {"messages": [human_message]}, "config": run_config,
                  "context": run_context, "multitask_strategy": "reject"}
    if owner_headers := _owner_headers(msg):
        run_kwargs["headers"] = owner_headers     # 内部认证头（见 ②认证）
    result = await client.runs.wait(thread_id, assistant_id, **run_kwargs)

def _owner_headers(msg: InboundMessage) -> dict[str, str] | None:
    owner_user_id = _effective_owner_user_id(msg)
    if not owner_user_id:
        return None
    return create_internal_auth_headers(owner_user_id=owner_user_id)
```

> **指向**：`[[im-channels]]`（MessageBus/ChannelManager/钉钉长连接与 AI Card 渲染差异）、`[[auth]]`（内部 token + owner 头深度）。钉钉 AI Card 流式渲染见 `references/code/08-rendering.md`。

---

## 3. 定时任务路径

> `ScheduledTaskService` 是个 poller：每轮认领到期任务（lease 防多实例并发抢同一个任务，`max_concurrent_runs` 限全局在途上限），交给 `launch_scheduled_thread_run` 桥接进 run 生命周期。该桥接函数是**跨切不变量 1 的起点**：它合成一个内部认证请求并塞入 `context={"non_interactive": True}`。

### 3.1 `scheduler/scheduler/service.py` - poller：认领到期任务（lease 并发限流），交给 launch_run

```python
# scheduler/scheduler/service.py - poller：认领到期任务（lease 并发限流），交给 launch_run
class ScheduledTaskService:
    def __init__(self, *, task_repo, task_run_repo, launch_run, poll_interval_seconds,
                 lease_seconds, max_concurrent_runs) -> None:
        self._launch_run = launch_run
        self._lease_seconds = lease_seconds
        self._max_concurrent_runs = max_concurrent_runs
        self._lease_owner = f"{socket.gethostname()}:{uuid.uuid4().hex}"

    async def run_once(self, *, now: datetime) -> None:
        # max_concurrent_runs 是全局在途上限，不是单轮认领数
        active = await self._task_run_repo.count_active_runs()
        budget = self._max_concurrent_runs - active
        if budget <= 0:
            return
        claimed = await self._task_repo.claim_due_tasks(
            now=now, lease_owner=self._lease_owner,
            lease_seconds=self._lease_seconds, limit=budget)
        for task in claimed:
            await self.dispatch_task(task, now=now, trigger="scheduled")

    async def _run_loop(self) -> None:
        while not self._stop.is_set():
            try:
                await self.run_once(now=datetime.now(UTC))
            except Exception:
                logger.exception("Scheduled task poll failed; retrying next interval")
            await asyncio.wait_for(self._stop.wait(), timeout=self._poll_interval_seconds)
```

### 3.2 `gateway/gateway/services.py` - 桥接调度器 -> run 生命周期（内部认证 + non_interactive）

```python
# gateway/gateway/services.py - 桥接调度器 -> run 生命周期（内部认证 + non_interactive）
async def launch_scheduled_thread_run(*, thread_id, assistant_id, prompt, request=None, app=None,
                                      owner_user_id=None, metadata=None) -> dict[str, Any]:
    if request is None:
        request = SimpleNamespace(
            app=app,
            headers=({INTERNAL_OWNER_USER_ID_HEADER_NAME: owner_user_id} if owner_user_id else {}),
            # 合成内部用户 + AUTH_SOURCE_INTERNAL -> 下游 merge_run_context_overrides(internal=True)
            # 才会接纳 non_interactive（否则被 strip_internal_context_keys 抹除，见跨切不变量 1）
            state=SimpleNamespace(user=get_internal_user(), auth_source=AUTH_SOURCE_INTERNAL),
            cookies={})
    body = SimpleNamespace(
        assistant_id=assistant_id,
        input={"messages": [{"role": "user", "content": prompt}]},
        context=({"non_interactive": True, "user_id": owner_user_id} if owner_user_id
                 else {"non_interactive": True}),
        multitask_strategy="reject", on_disconnect="continue", on_completion="keep",
        if_not_exists="reject")
    record = await start_run(body, thread_id, request)
    return {"run_id": record.run_id, "thread_id": record.thread_id}
```

> **指向**：`[[scheduled-tasks]]`（poller + lease + cron/once + 恢复）、`[[gateway-runs-and-sse]]`（start_run -> run_agent）。跨切不变量 1 完整推导见 `references/cross-cutting-invariants.md`。

---

## 关键不变量与测试锚点

1. **三路径在 ②认证汇合**：Web 走 JWT cookie；IM 走内部 token 头 + owner 头；调度走合成内部用户。三者汇合到同一 `user_context` contextvar，此后 ③–⑧ 一致（跨切不变量 2）。
2. **IM 跨线程投递**：钉钉 SDK 回调跑在独立线程，用 `asyncio.run_coroutine_threadsafe` 扔回主事件循环的 `MessageBus`，避免阻塞 SDK 长连接。
3. **去重**：`_is_duplicate_inbound` 防同一消息被重复处理（IM 平台可能重投）。
4. **调度 lease 并发限流**：`lease_owner` 唯一标识 poller 实例，`max_concurrent_runs` 是全局在途上限（非单轮认领数），`budget` 限制每轮认领量。
5. **调度内部认证**：`launch_scheduled_thread_run` 合成 `AUTH_SOURCE_INTERNAL` 标记，使下游接纳 `non_interactive`（跨切不变量 1 的第一道防线）。
6. **Web 断线重连**：`reconnectOnMount: true` + `Last-Event-ID` 续传（跨切不变量 3）。

> 关联：`[[gateway-runs-and-sse]]`、`[[frontend-app-design]]`、`[[frontend-streaming-protocol]]`、`[[im-channels]]`、`[[scheduled-tasks]]`、`[[auth]]`、`cross-cutting-invariants.md`（不变量 1/2/3 均与入站路径相关）。
