---
name: long-running-and-cancellation
description: 设计 agent 的长任务通道——后台 asyncio.Task + StreamBridge + Last-Event-ID 重连 + multitask 策略 + pre-run checkpoint 回滚 + on_disconnect 语义。
---

## 何时用

- agent run 可能跑几分钟（deep research / 大量工具）
- 用户网络抖动 / 切页面 / 关浏览器后想能续看
- 同一 thread 同时收到多个新消息（如何处理冲突）
- 用户主动点"停止"想立刻终止 + 回滚到发起前的状态

## 设计思想

1. **HTTP 处理函数与 agent 任务解耦**：HTTP 只负责"创建 RunRecord + spawn asyncio.Task + SSE 订阅 StreamBridge"，agent 在后台任务里独立跑。
2. **StreamBridge 是单一事实源**：worker 产生事件 publish 到 bridge；HTTP 端只是 bridge 的 subscriber。可以有 0 个 / 多个订阅者。
3. **断流重连用 `Last-Event-ID`**：每个 SSE 帧带递增 id；客户端断了之后 `GET /join?last_event_id=...` 从下一个 id 继续。
4. **multitask 策略**：用户在 run 进行中又发了一条新消息时怎么办——`reject`（拒绝新）/ `interrupt`（中断当前继续新）/ `rollback`（中断 + 回滚状态）/ `enqueue`（排队）。
5. **pre-run checkpoint snapshot**：worker 在 run 开始前 snapshot 当前 checkpoint；rollback 时把它**整体 + pending_writes** 写回。
6. **`on_disconnect`**：客户端 SSE 断开后是 `cancel`（默认）还是 `continue`（继续跑供后续 `/join`）。

## 实现模板

### Worker 主体

```python
# runtime/runs/worker.py
async def run_agent(bridge: StreamBridge, run_mgr: RunManager, record: RunRecord, *,
                   ctx: RunContext, agent_factory, graph_input, config,
                   stream_modes=None):
    run_id, thread_id = record.run_id, record.thread_id
    pre_run_snapshot = None
    try:
        await run_mgr.set_status(run_id, RunStatus.running)

        # ⭐ snapshot pre-run checkpoint 给 rollback 用
        if ctx.checkpointer:
            ckpt = await ctx.checkpointer.aget_tuple(
                {"configurable": {"thread_id": thread_id, "checkpoint_ns": ""}}
            )
            if ckpt:
                pre_run_snapshot = {
                    "checkpoint": copy.deepcopy(ckpt.checkpoint),
                    "metadata":   copy.deepcopy(ckpt.metadata),
                    "pending_writes": copy.deepcopy(getattr(ckpt, "pending_writes", []) or []),
                    "checkpoint_id": ckpt.config["configurable"]["checkpoint_id"],
                }

        # 立刻让前端知道 run_id / thread_id
        await bridge.publish(run_id, "metadata", {"run_id": run_id, "thread_id": thread_id})

        # 构造 agent
        agent = agent_factory(config=RunnableConfig(**config))
        if ctx.checkpointer: agent.checkpointer = ctx.checkpointer

        # 流式推送
        lg_modes = _normalize_stream_modes(stream_modes or ["values"])
        async for chunk in agent.astream(graph_input, config=RunnableConfig(**config),
                                         stream_mode=lg_modes):
            if record.abort_event.is_set():
                break
            if isinstance(chunk, tuple):
                mode, payload = chunk
            else:
                mode, payload = lg_modes[0], chunk
            await bridge.publish(run_id, _lg_mode_to_sse_event(mode),
                                  serialize(payload, mode=mode))

        # 终态处理
        if record.abort_event.is_set() and record.abort_action == "rollback":
            await run_mgr.set_status(run_id, RunStatus.error, error="Rolled back")
            await _rollback_to_pre_run_checkpoint(ctx.checkpointer, thread_id,
                                                   pre_run_snapshot)
        elif record.abort_event.is_set():
            await run_mgr.set_status(run_id, RunStatus.interrupted)
        else:
            await run_mgr.set_status(run_id, RunStatus.success)

    except Exception as exc:
        logger.exception("Run %s failed", run_id)
        await run_mgr.set_status(run_id, RunStatus.error, error=str(exc))
        await bridge.publish(run_id, "error",
                              {"message": str(exc), "name": type(exc).__name__})
    finally:
        await bridge.publish_end(run_id)
        asyncio.create_task(bridge.cleanup(run_id, delay=60))
```

### StreamBridge 接口

```python
@dataclass(frozen=True)
class StreamEvent:
    id: str        # 单调递增；前端 Last-Event-ID
    event: str     # metadata / values / messages / custom / error / end
    data: Any

class StreamBridge(ABC):
    @abstractmethod
    async def publish(self, run_id: str, event: str, data: Any) -> None: ...
    @abstractmethod
    async def publish_end(self, run_id: str) -> None: ...
    @abstractmethod
    def subscribe(self, run_id: str, *, last_event_id: str | None = None,
                  heartbeat_interval: float = 15.0) -> AsyncIterator[StreamEvent]: ...
    @abstractmethod
    async def cleanup(self, run_id: str, *, delay: float = 0) -> None: ...
```

### HTTP 端：start_run + SSE consumer

```python
@router.post("/{thread_id}/runs/stream")
async def stream_run(thread_id: str, body: RunCreateRequest, request: Request):
    record = await start_run(body, thread_id, request)
    return StreamingResponse(
        sse_consumer(get_stream_bridge(request), record, request, get_run_manager(request)),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


async def sse_consumer(bridge, record, request, run_mgr):
    last = request.headers.get("Last-Event-ID")
    try:
        async for entry in bridge.subscribe(record.run_id, last_event_id=last):
            if await request.is_disconnected(): break
            if entry is HEARTBEAT_SENTINEL: yield ": heartbeat\n\n"; continue
            if entry is END_SENTINEL:
                yield format_sse("end", None, event_id=entry.id); return
            yield format_sse(entry.event, entry.data, event_id=entry.id)
    finally:
        if record.status in (RunStatus.pending, RunStatus.running) \
                and record.on_disconnect == DisconnectMode.cancel:
            await run_mgr.cancel(record.run_id)
```

### 重连端点

```python
@router.get("/{thread_id}/runs/{run_id}/join")
async def join_stream(thread_id: str, run_id: str, request: Request):
    bridge = get_stream_bridge(request)
    record = await get_run_manager(request).get(run_id)
    if record is None:
        raise HTTPException(404)
    return StreamingResponse(sse_consumer(bridge, record, request, get_run_manager(request)),
                              media_type="text/event-stream")
```

### multitask 策略实现

```python
async def create_or_reject(self, thread_id, assistant_id, *,
                           multitask_strategy: str, ...) -> RunRecord:
    existing = self._active_run_for_thread(thread_id)
    if existing is None:
        return await self._create_new(...)
    if multitask_strategy == "reject":
        raise ConflictError(f"Thread {thread_id} has active run {existing.run_id}")
    if multitask_strategy in ("interrupt", "rollback"):
        existing.abort_action = "interrupt" if multitask_strategy == "interrupt" else "rollback"
        existing.abort_event.set()
        await existing.task    # 等待终止 + 回滚
        return await self._create_new(...)
    if multitask_strategy == "enqueue":
        return await self._enqueue_after(existing, ...)
```

## 反模式

- ❌ HTTP handler 内 `await run_agent(...)` 直接跑 → 客户端断了任务也死
- ❌ 不发心跳 → nginx / 浏览器 60s 静默后关 SSE
- ❌ rollback 只删 checkpoint 不写回 snapshot → 用户看到完全空白对话
- ❌ `Last-Event-ID` 服务端不识别 → 重连后从头送一遍，前端去重过滤死循环
- ❌ wait 端点直接 `await record.task` → 不响应 `on_disconnect`，stale checkpoint 当成功返回
- ✅ `wait_for_run_completion` 也通过 bridge subscribe `END_SENTINEL`，复用 disconnect 语义
- ✅ Bridge 在 cleanup 前留 60s 延迟，给慢客户端续上

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[gateway-runs-and-sse]] [[frontend-streaming-protocol]] [[subagent-delegation]]
