# ③ 路由与 RunManager 完整源码

> 本文件是脊柱 `SKILL.md` 第③跳"路由"的深度展开。脊柱只给入口片段；此处给 Gateway SSE 端点、`RunManager.create_or_reject`（原子注册 run + multitask 策略）、worker 运行前快照 + 取消/rollback 终结路径的真实源码片段。
>
> 代码已按插件匿名化规则映射到自定结构（`gateway.*` / `core/helix.*`），去除一切项目字样；原代码注释保真，中文注解以"注："或行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱）、`[[gateway-runs-and-sse]]`（RunManager/run_agent/checkpointer 全貌）、`[[long-running-and-cancellation]]`（multitask 策略 + 回滚深度）、`cross-cutting-invariants.md` 不变量 3（worker pre-run 快照是回滚锚点）。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `gateway/gateway/routers/thread_runs.py` | SSE 流端点：per-resource owner 校验 + start_run + StreamingResponse |
| `core/helix/runtime/runs/manager.py` | `RunManager.create_or_reject`：原子注册 run + multitask 策略 + abort_action 协作 |
| `core/helix/runtime/runs/worker.py` | `run_agent`：运行前快照 + 终结 rollback（跨切不变量 3 核心） |

> worker 的 stream_mode 映射 + publish 循环 + `_rollback_to_pre_run_checkpoint` 完整实现见 `references/code/07-streaming-and-resume.md`；本文件只摘与路由/注册/终结相关的片段。

---

## 1. `gateway/gateway/routers/thread_runs.py` - SSE 流端点

> Gateway 的 SSE 端点先做 per-resource owner 校验（`@require_permission(owner_check=True)`），再调 `start_run` -> `RunManager.create_or_reject` -> 起 worker 跑 `run_agent`。

```python
# gateway/gateway/routers/thread_runs.py - SSE 流端点
@router.post("/{thread_id}/runs/stream")
@require_permission("runs", "create", owner_check=True, require_existing=True)
async def stream_run(thread_id: str, body: RunCreateRequest, request: Request) -> StreamingResponse:
    bridge = get_stream_bridge(request)
    run_mgr = get_run_manager(request)
    record = await start_run(body, thread_id, request)
    return StreamingResponse(
        sse_consumer(bridge, record, request, run_mgr),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                 "X-Accel-Buffering": "no",
                 # LangGraph Platform 在此 header 带运行元数据，SDK 用它抽 run id
                 "Content-Location": f"/api/threads/{thread_id}/runs/{record.run_id}"})
```

> 注：`@require_permission(..., owner_check=True)` 做 per-resource owner 校验--用户 A 不能靠猜 URL 读/写用户 B 的 thread。`require_existing=True` 要求 thread 必须已存在（不接受凭空创建）。

---

## 2. `core/helix/runtime/runs/manager.py` - 原子注册 run，处理 multitask 策略

> `create_or_reject` 持锁跨"检查 + 插入"，消除分立 `has_inflight` + `create` 的 TOCTOU 竞争。multitask 策略决定已有在途 run 时新 run 怎么办。

```python
# core/helix/runtime/runs/manager.py - 原子注册 run，处理 multitask 策略
async def create_or_reject(self, thread_id, assistant_id=None, *, on_disconnect=DisconnectMode.cancel,
        metadata=None, kwargs=None, multitask_strategy="reject", model_name=None, user_id=None) -> RunRecord:
    run_id = str(uuid.uuid4()); now = _now_iso()
    async with self._lock:   # 持锁消除 has_inflight + create 的 TOCTOU 竞争
        inflight = [r for r in self._thread_records_locked(thread_id)
                    if r.status in (RunStatus.pending, RunStatus.running) or r.finalizing]
        if multitask_strategy == "reject" and inflight:
            raise ConflictError(f"Thread {thread_id} already has an active run")
        if multitask_strategy in ("interrupt", "rollback") and inflight:
            for r in inflight:
                r.abort_action = multitask_strategy   # worker 终结时读它决定是否回滚
                r.abort_event.set()
                if r.task is not None and not r.task.done():
                    r.task.cancel()
                r.status = RunStatus.interrupted
        record = RunRecord(run_id=run_id, thread_id=thread_id, ...)
        self._runs[run_id] = record
        await self._persist_new_run_to_store(record)
    return record
```

> 注：`abort_action` 默认 `"interrupt"`（保留 checkpoint）；`multitask_strategy="rollback"` 把它改 `"rollback"`，worker 终结路径读它决定走 `_rollback_to_pre_run_checkpoint` 还是仅 `set_status(interrupted)`。`cancel()` 与 `create_or_reject` 都只设 `abort_action` + `abort_event`（不持锁做 IO），worker 终结时才执行回滚--把"取消决策"与"状态恢复"解耦。

---

## 3. `core/helix/runtime/runs/worker.py` - 运行前快照 + 取消/rollback 时恢复

> worker 在运行前**快照最新 checkpoint**，这是跨切不变量 3 的回滚锚点。若 run 被 `multitask_strategy="rollback"` 取消或 `asyncio.CancelledError`，`_rollback_to_pre_run_checkpoint` 在 checkpointer 上写一个新 checkpoint 标记（新 id/ts，旧 channel_values），把线程状态恢复到 run 开始前。

```python
# core/helix/runtime/runs/worker.py - 运行前快照 + 取消/rollback 时恢复（跨切不变量 3 的核心）
# 运行前：快照最新 checkpoint，供回滚恢复
if checkpointer is not None:
    ckpt_tuple = await checkpointer.aget_tuple(
        {"configurable": {"thread_id": thread_id, "checkpoint_ns": ""}})
    if ckpt_tuple is not None:
        pre_run_checkpoint_id = ckpt_tuple.config.get("configurable", {}).get("checkpoint_id")
        pre_run_snapshot = {"checkpoint_ns": ..., "checkpoint": copy.deepcopy(ckpt_tuple.checkpoint),
                            "metadata": copy.deepcopy(ckpt_tuple.metadata),
                            "pending_writes": copy.deepcopy(ckpt_tuple.pending_writes or [])}

# 终结路径：abort_action == "rollback" 时把 checkpointer 写回运行前快照
if record.abort_event.is_set():
    action = record.abort_action
    if action == "rollback":
        await run_manager.set_status(run_id, RunStatus.error, error="Rolled back by user")
        await _rollback_to_pre_run_checkpoint(
            checkpointer=checkpointer, thread_id=thread_id, run_id=run_id,
            pre_run_checkpoint_id=pre_run_checkpoint_id, pre_run_snapshot=pre_run_snapshot,
            snapshot_capture_failed=snapshot_capture_failed)
```

> 注：快照用 `copy.deepcopy` 冻结 checkpoint/metadata/pending_writes--run 期间 checkpointer 会写新 checkpoint，浅拷贝会让回滚读到被本 run 污染后的状态。`snapshot_capture_failed=True` 时 rollback 跳过并记 warn，不抛错卡住 run。`_rollback_to_pre_run_checkpoint` 完整实现（含 pending_writes 恢复、新 checkpoint 标记）见 `references/code/07-streaming-and-resume.md`。

---

## 关键不变量与测试锚点

1. **per-resource owner 校验**：`@require_permission(owner_check=True)` 在路由层拦截跨用户访问（防用户 A 靠猜 URL 读用户 B 的 thread）。
2. **原子注册**：`create_or_reject` 持锁跨"检查 + 插入"，消除 TOCTOU 竞争。
3. **multitask 策略**：`reject`（抛 ConflictError）/ `interrupt`（保留 checkpoint）/ `rollback`（回滚到 pre-run）。后两者对在途 run 设 `abort_action` + `abort_event`，worker 终结时读它决定。
4. **pre-run 快照深拷贝**：`copy.deepcopy` 冻结快照，防 run 期间 checkpointer 写新 checkpoint 污染。
5. **快照失败降级**：`snapshot_capture_failed=True` 时 rollback 跳过，不抛错卡住 run。
6. **abort_action 解耦**：`cancel()` / `create_or_reject` 只设标志（不持锁做 IO），worker 终结路径才执行回滚。

> 关联：`[[gateway-runs-and-sse]]`（RunManager/run_agent/checkpointer 全貌）、`[[long-running-and-cancellation]]`（multitask 策略 + 回滚深度）、`references/code/07-streaming-and-resume.md`（worker publish 循环 + `_rollback_to_pre_run_checkpoint` 完整实现 + `RunManager.cancel` 完整）、`cross-cutting-invariants.md` 不变量 3。
