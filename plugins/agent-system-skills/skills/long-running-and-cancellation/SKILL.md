---
name: long-running-and-cancellation
description: 设计 agent 的长任务通道--后台 asyncio.Task + StreamBridge 解耦（worker 生产 / SSE 消费，0/多订阅者）、Last-Event-ID 续传（{ts}-{seq} O(1) 定位 + retained-buffer + 降级重放）、multitask_strategy（reject/interrupt/rollback，abort_action 协作式取消 + 持锁消除 TOCTOU）、pre-run checkpoint 快照 + cancel 回滚（写新 checkpoint 标记载 pre-run channel_values + pending_writes）、on_disconnect（cancel 真断连取消后台 run / continue 留后台跑，store_only 跨 worker 例外）、wait_for_run_completion 复用 bridge END_SENTINEL（不 await record.task，issue #3265）、孤儿 run 启动恢复（reconcile_orphaned_inflight_runs + publish_end 收尾）、shutdown drain（issue #3373）。给出完整、未截断的真实代码（RunManager 运行态机 / worker 快照回滚 / StreamBridge 续传契约 / on_disconnect+wait / 孤儿恢复）。当你要实现长任务后台化、SSE 断流重连、取消回滚、并发新消息抢占，或排查半截 checkpoint / 孤儿 run / wait 返回 stale 状态时调用本 skill。
---

## 何时用

- agent run 可能跑几分钟（deep research / 大量工具调用 / 长 `pip install`），不能占着 HTTP 连接
- 用户网络抖动 / 切页面 / 关浏览器后想能续看，或后台继续跑完
- 同一 thread 同时收到多个新消息（如何处理在途 run 冲突）
- 用户主动点"停止"想立刻终止 + 回滚到发起前的状态（不留下半截产物）
- `/wait` 端点返回了半截 checkpoint 把未完成的 run 伪装成正常完成（issue #3265）
- 进程重启后 UI 永久显示一坨"活跃 run"（孤儿 inflight）
- shutdown 时 checkpointer 池先关、worker 还在写触发 `PoolClosed`（issue #3373）

> 本 skill 处于端到端链路的 **⑦流式 + 取消回滚** 跳，并承载**跨切不变量 3**（StreamBridge × checkpointer × 回滚）的深度。见 `[[e2e-request-lifecycle]]`。

## 设计方案（为什么这么设计）

### 核心矛盾：长任务生命周期 vs HTTP 请求生命周期

agent run 动辄几分钟，而 HTTP/SSE 连接脆弱（用户关标签页、手机切后台、nginx 60s 静默、代理超时）。若把 run 绑在请求生命周期上，连接一断 run 就死，前面算的全丢。反过来，若 run 在后台跑但客户端无法续看，长任务对用户就是黑盒。再加一层：用户中途改主意要点"停止"，且停止后不能留下半截 checkpoint 污染对话。这三件事--**后台化、续看、干净取消**--构成长任务通道的核心矛盾。

### 解耦：后台 asyncio.Task + StreamBridge（单一事实源）

**后台 `asyncio.Task`**：HTTP handler 只做三件事--`RunManager.create_or_reject(...)` 建 `RunRecord` + `asyncio.create_task(run_agent(...))` spawn 后台 task + `sse_consumer` 订阅 bridge。agent 在后台 task 里独立跑，与 HTTP 连接**无引用关系**：客户端断了，task 不死；task 跑完，客户端可能早已走。`record.task` 句柄只在本进程内存里有效（这是 `store_only` 跨 worker 例外存在的根因）。

**`StreamBridge` 是单一事实源**：worker 是生产者（`publish`），HTTP SSE 端点是消费者（`subscribe`）。bridge 解耦二者，于是可以有 **0 个订阅者**（后台 run 无人看，`on_disconnect=continue`，跑完结果落 checkpoint）或**多个订阅者**（管理端 + 用户端同时看同一个 run）。事件流不存放在 HTTP 连接里，而存放在 bridge 的 per-run retained-buffer 里。

**为何不直接 `await agent.astream(...)` 在 handler 里**：客户端断了 task 也死（`CancelledError` 上抛），根本无法实现"客户端断了后台仍跑"。后台 task 是长任务的物理前提。

### Last-Event-ID 续传：`{ts}-{seq}` + retained-buffer

客户端断线后重连，要能从断点续看，不能从头送一遍（前端去重过滤死循环）。SSE 协议自带 `Last-Event-ID` 请求头，问题是服务端怎么**高效定位**断点。

**`{ts}-{seq}` 事件 id**：每个事件 id = `{ts}-{seq}`，`seq` 是 per-run 单调递增的**绝对偏移**（从 0 起）。续传时 `_resolve_start_offset` 用 `seq - start_offset` 算术 **O(1) 定位**，无需线性扫描 buffer。`ts` 前缀只给人读调试用。校验 `events[local_index].id == last_event_id` 保证陈旧/驱逐/伪造/他 run 的 id 不被误信，**降级**到"从最早保留事件重放"。

**为何不用 UUID**：UUID 无序，续传只能线性扫描 buffer，长任务 buffer 大时每个重连客户端都全扫，SSE 吞吐塌陷。`seq` 是绝对偏移，算术定位 O(1)。

**retained-buffer 有界**：长任务事件无限增长会撑爆内存。`queue_maxsize=256` 驱逐最旧事件、`start_offset` 跟进。重连客户端要么命中未驱逐段（O(1) 续传），要么从最早保留事件重放（降级、不丢已驱逐之外的）。订阅者落后驱逐速度时也降级恢复。

**Redis 跨进程续传**：多 worker 部署用 `RedisStreamBridge`（`supports_cross_process=True`）。每个 run 一个 Redis Stream，`Last-Event-ID` 直接做 `XREAD` 起点（Redis Stream id 本身单调递增，无需 `{ts}-{seq}` 解析）；`XREAD ... BLOCK` 既阻塞读又当心跳。

### multitask_strategy：interrupt vs rollback（为何两种）

用户在 run 进行中又发了一条新消息时，怎么办？四种策略里实现了三种（`enqueue` 未实现，传入抛 `UnsupportedStrategyError` -> 501）：

| 策略 | 行为 | checkpoint |
|---|---|---|
| `reject`（默认） | thread 已有 pending/running/finalizing run -> `ConflictError` -> 409 | - |
| `interrupt` | abort 旧 run，新 run 接续 | **保留**旧 run 中途 checkpoint |
| `rollback` | abort 旧 run，新 run 从干净状态开始 | **回滚**到 pre-run checkpoint |

**为何要 interrupt 和 rollback 两种**：语义不同。
- `interrupt` 是"暂停"：旧 run 已经产出的部分结果（几条消息、一些工具产物）用户可能想保留，只是要插队说新的。interrupt 保留 checkpoint，下次 resume 还能接着旧 run 的进度。
- `rollback` 是"撤回"：旧 run 跑偏了 / 用户改主意要重来，半截产物不要了。rollback 把线程状态恢复到旧 run 开始**之前**，用户看不到半截产物。

**`abort_action` 协作式取消**：`cancel()` 和 `create_or_reject()` 都**只设状态、不做 IO 重活**--设 `record.abort_action = multitask_strategy` + `record.abort_event.set()` + `record.task.cancel()`，不持锁做 checkpointer IO（持锁做 IO 会阻塞 run 注册锁 -> 同 thread 后续 `create_or_reject` 全阻塞 -> 系统僵）。worker 终结路径（正常 abort 退出 / `asyncio.CancelledError`）才读 `abort_action` 决定走 `_rollback_to_pre_run_checkpoint` 还是仅 `set_status(interrupted)`。这把"取消决策"与"状态恢复"解耦，且让回滚在 worker 的 `finally` 语义内执行（保证一定触发）。

**`abort_action` 必须先于 `abort_event` 设置**：rollback / interrupt 共用同一个 `abort_event`，靠 action 字段区分；顺序反了 worker 看到 event 但读到旧 action（默认 `"interrupt"`），rollback 请求被当 interrupt 处理 -> checkpoint 保留半截状态 -> 取消无效。

**TOCTOU 消除**：`create_or_reject` 持 `_lock` 跨"检查在途 + 插入新 run + 抢占旧 run"，规避分立 `has_inflight` + `create` 的竞争窗口（否则两个并发新消息都看到"无在途"然后都创建，thread 上同时跑两个 run）。

### pre-run checkpoint 快照 + cancel 回滚

rollback 要把线程状态恢复到**旧 run 开始之前**，但 run 期间 checkpointer 持续写新 checkpoint。解法：

1. **运行前快照**：worker `run_agent` 开头，`checkpointer.aget_tuple(...)` 拿最新 checkpoint，`copy.deepcopy` checkpoint/metadata/pending_writes 冻结成不可变快照（`pre_run_snapshot` + `pre_run_checkpoint_id`）。深拷贝是必须的--浅拷贝会让回滚读到被本 run 污染后的状态。
2. **回滚写"新 checkpoint"而非删旧**：`_rollback_to_pre_run_checkpoint` 用 `empty_checkpoint()` 产**新 id/ts**，载 pre-run `channel_values`，`aput` 写入。不覆盖旧 checkpoint--DB-backed saver（Postgres/Sqlite blob 按 `channel_versions` 键存）覆盖旧 id 会版本冲突。写新 checkpoint 是 LangGraph checkpointer 协议支持的标准恢复方式：线程最新 checkpoint 自然指向 pre-run 状态，历史 checkpoint 仍在（可审计）。
3. **pending_writes 恢复**：按 `task_id` 分组 `aput_writes`，使未完成写也回 pre-run。
4. **空线程 rollback**：`pre_run_snapshot is None`（run 前线程为空）直接 `adelete_thread`，回到空状态。
5. **快照失败降级**：`snapshot_capture_failed=True` 时 rollback 跳过并记 warn，不抛错卡住 run--run 不该因回滚失败而卡死。

**`CancelledError` 与正常 abort 同路径**：`task.cancel()` 触发 `asyncio.CancelledError`，worker 的 `except asyncio.CancelledError` 块与正常 abort 退出走**同一套** rollback/interrupt 分支（都读 `record.abort_action`）。两条路径一致保证取消语义统一。

### on_disconnect：cancel vs continue（真断连取消 vs 留 stale）

客户端 SSE 断开后，后台 run 怎么办？两种语义：

- `cancel`（默认）：客户端断 + run 仍 pending/running + 本 worker 拥有（`not store_only`）-> `run_mgr.cancel(run_id)` 中止后台任务。适用于"用户关了页面就不跑了"。
- `continue`：让任务继续后台跑，事件丢弃；后续可经 `/join` 续看。适用于"后台跑完结果落 checkpoint，用户回头再看"（调度任务 / IM 通道用 `on_disconnect=continue`）。

**`store_only` 例外**：跨 worker 反水化的 record（gateway A 创建的 run，gateway B 经 `RunStore` 拉到），本 worker 无 task/abort 状态，`cancel` 会 409。`sse_consumer` / `wait_for_run_completion` 的 `finally` 对 `store_only` 跳过 `cancel()`，只对本 worker 实际拥有的 run 生效。

**`wait_for_run_completion` 复用同语义（issue #3265）**：旧 `/wait` 直接 `await record.task`，客户端/代理超时（长 `pip install`）时 handler 吞 `CancelledError` 并序列化恰巧存在的 checkpoint -> 半截 run 伪装成正常完成。修复：`wait_for_run_completion` 消费与 `sse_consumer` 相同的 bridge，心跳 sentinel 保证每 `heartbeat_interval` 唤醒一次 poll `is_disconnected()`；真断连且 `on_disconnect=cancel` 时取消后台 run，返回 `False`；路由层在 `completed=False` 时**跳过 checkpoint 序列化**，只回 `{"status":..., "error":...}`，杜绝返回 stale checkpoint。

### 孤儿 run 恢复：启动 `reconcile_orphaned_inflight_runs` + `END_SENTINEL`

gateway run 是**进程局部**的：asyncio task/abort_event 在内存，run 行在 `RunStore` 持久。进程崩溃 / kill -9 / OOM 重启后，store 里残留的 `pending/running` 行不可能还有本地 worker--UI 会永久显示一坨"活跃 run"。

**启动恢复三步**（仅 `database.backend == "sqlite"` 单进程路径）：
1. `RunManager.reconcile_orphaned_inflight_runs`：把 store 里残留 `pending/running` 行刷成 `error`（本进程无 task 接管）。
2. `_publish_recovered_run_stream_end`：对每条恢复 run，若 bridge 还有保留流（`stream_exists`），`publish_end` 发 `END_SENTINEL` 让挂着的订阅者收尾，再 `cleanup(delay=60)`。
3. `_mark_latest_recovered_threads_error`：仅当被恢复 run 是该 thread 的**最新** run 时，才把 `threads_meta.status` 标 `error`（避免旧 run 恢复误盖一个已正常完成的新 run 的线程状态）。

**为何仅 SQLite 单进程**：多 pod 部署需要 worker ownership/liveness 才能安全 reaper，否则会把别的 pod 还在跑的 run 误判孤儿。故此路径显式 gate 在 `backend == "sqlite"`。

**`END_SENTINEL` 的角色**：worker `finally` 末尾 `bridge.publish_end(run_id)` 让 `subscribe` yield `END_SENTINEL`，`sse_consumer` / `wait_for_run_completion` 才能收尾。孤儿恢复时也用 `publish_end` 给残留流补发 `END_SENTINEL`。`END_SENTINEL` 是"run 不再产事件"的统一信号，跨进程经 Redis `{"kind":"end"}` round-trip。

### TTL 是泄漏安全网，不是超时

`RedisStreamBridge` 的 `stream_ttl_seconds=86400` 给 Redis Stream 一个兜底过期，防 worker 崩溃没跑 `cleanup` 时流永久残留。它**不**是 run 的执行超时--run 能跑多久由模型/工具自身决定（`recursion_limit` / 工具 timeout / token budget 各管各的），TTL 只管事件流残留清理。同理 `RunManager.cleanup(delay=300)` 是内存 RunRecord 的清理延迟，bridge `cleanup(delay=60)` 是事件流的清理延迟，两者都是"给慢客户端留时间"的安全网。

### 关键不变量（违反则长任务通道崩塌）

1. **HTTP 与 agent task 解耦**：HTTP 只建 record + spawn task + 订阅 bridge；客户端断不影响 task 自身。
2. **`abort_action` 先于 `abort_event` 设置**；`cancel` / `create_or_reject` 不持锁做 IO，回滚留给 worker 终结路径。
3. **pre-run 快照深拷贝**；快照失败降级跳过 rollback，不卡 run。
4. **rollback 写新 checkpoint 标记**（新 id/ts），不覆盖旧；恢复 pending_writes。
5. **`/wait` 不 `await record.task`**：走 bridge `END_SENTINEL`，`completed=False` 跳过 checkpoint 序列化。
6. **`on_disconnect` finally 对 `store_only` 跳过**：跨 worker record 本地无 task，cancel 会 409。
7. **`Last-Event-ID` 服务端识别**：`{ts}-{seq}` O(1) 定位 + id 校验降级重放。
8. **二级索引原子**：`_runs` 与 `_runs_by_thread` 同一把 `_lock` 内串行写入，无 `await` 跨越。
9. **shutdown drain**：先 abort 全部在途、bounded `wait`；自跑完的保留真实终态，超时的 `interrupted`；持久化在预算内 bounded（issue #3373）。
10. **孤儿恢复仅 SQLite**：`reconcile_orphaned_inflight_runs` + `publish_end` 收尾 + 线程 error 标记（仅最新 run）。

### 在端到端链路中的位置

本 skill 处于端到端链路的 **⑦流式 + 取消回滚**（见 `[[e2e-request-lifecycle]]`）：③路由 `start_run` -> `RunManager.create_or_reject`（multitask 策略）-> spawn `run_agent` worker（pre-run 快照 + 流式 publish）-> ⑦StreamBridge（Last-Event-ID 续传）-> `sse_consumer`（on_disconnect finally）。本 skill 同时是**跨切不变量 3**（StreamBridge × checkpointer × 回滚）的深度归档：续传保"看到的事件流不丢"（bridge buffer），回滚保"取消后 checkpointer 状态干净"（pre-run 快照）。两套机制独立但协作：一个 run 被回滚后，bridge 的事件流仍可被已连接客户端消费完（`publish_end` 在 finally），新客户端重连会看到回滚后的干净状态（checkpoint 已恢复）。

## 完整真实代码实现

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构 `helix.*` / `gateway.*`，去除项目字样）。原代码注释保真；关键处补中文注解。大文件拆 `references/code/`，本节给文件清单 + 入口片段 + 索引。

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | 深读 |
|---|---|---|
| `core/helix/runtime/runs/schemas.py` | `RunStatus` / `DisconnectMode` 枚举 | `references/code/run-manager.md` |
| `core/helix/runtime/runs/manager.py` | `RunRecord` + `RunManager`（状态机 + multitask + cancel + 孤儿恢复 + shutdown drain）+ `ConflictError` / `UnsupportedStrategyError` + `PersistenceRetryPolicy` | `references/code/run-manager.md` |
| `core/helix/runtime/runs/worker.py` | `run_agent`（pre-run 快照 + 流循环 + 终结 rollback + finally 收尾）+ `_rollback_to_pre_run_checkpoint` + `_SubagentEventBuffer` | `references/code/worker-checkpoint-rollback.md` |
| `core/helix/runtime/stream_bridge/base.py` | `StreamBridge` 抽象契约 + `StreamEvent` + `END_SENTINEL` / `HEARTBEAT_SENTINEL` | `references/code/stream-bridge-resume.md` |
| `core/helix/runtime/stream_bridge/memory.py` | `MemoryStreamBridge`：`{ts}-{seq}` O(1) 续传 + 有界 buffer | `references/code/stream-bridge-resume.md` |
| `core/helix/runtime/stream_bridge/redis.py` | `RedisStreamBridge`：跨进程续传 + `END_SENTINEL` round-trip + `stream_exists` | `references/code/stream-bridge-resume.md` |
| `gateway/gateway/services.py` | `sse_consumer`（on_disconnect finally）+ `wait_for_run_completion` + `format_sse` | `references/code/stream-bridge-resume.md` |
| `gateway/gateway/deps.py` | lifespan 孤儿恢复接线 + `_drain_inflight_runs` + `get_stream_bridge` / `get_run_manager` | `references/code/stream-bridge-resume.md` |
| `gateway/gateway/routers/thread_runs.py` | `join_run` / `stream_existing_run` / `cancel_run`（重连 + 取消面） | `references/code/stream-bridge-resume.md` |

### 1. RunManager 运行态机 + multitask + cancel（入口片段）

```python
# core/helix/runtime/runs/manager.py - cancel：设 abort_action + abort_event，cancel 任务（不持锁做 IO）
async def cancel(self, run_id: str, *, action: str = "interrupt") -> bool:
    async with self._lock:
        record = self._runs.get(run_id)
        if record is None:
            return False
        if record.status == RunStatus.interrupted:
            return True  # 幂等--已在本 worker 取消
        if record.status not in (RunStatus.pending, RunStatus.running):
            return False
        record.abort_action = action          # worker 终结时读它决定是否回滚
        record.abort_event.set()              # 协作式取消信号
        task_active = record.task is not None and not record.task.done()
        record.finalizing = task_active
        if task_active:
            record.task.cancel()              # 触发 asyncio.CancelledError
        record.status = RunStatus.interrupted
        record.updated_at = _now_iso()
    await self._persist_status(record, RunStatus.interrupted)
    logger.info("Run %s cancelled (action=%s)", run_id, action)
    return True
```

```python
# core/helix/runtime/runs/manager.py - create_or_reject：持锁消除 TOCTOU，multitask 抢占设 abort_action
async def create_or_reject(self, thread_id, assistant_id=None, *, on_disconnect=DisconnectMode.cancel,
        metadata=None, kwargs=None, multitask_strategy="reject", model_name=None, user_id=None) -> RunRecord:
    run_id = str(uuid.uuid4()); now = _now_iso()
    _supported_strategies = ("reject", "interrupt", "rollback")
    interrupted_records: list[RunRecord] = []
    async with self._lock:   # 持锁跨"检查 + 插入"，消除 TOCTOU
        if multitask_strategy not in _supported_strategies:
            raise UnsupportedStrategyError(
                f"Multitask strategy '{multitask_strategy}' is not yet supported. "
                f"Supported strategies: {', '.join(_supported_strategies)}")
        inflight = [r for r in self._thread_records_locked(thread_id)
                    if r.status in (RunStatus.pending, RunStatus.running) or r.finalizing]
        if multitask_strategy == "reject" and inflight:
            raise ConflictError(f"Thread {thread_id} already has an active run")
        record = RunRecord(run_id=run_id, thread_id=thread_id, assistant_id=assistant_id,
            status=RunStatus.pending, on_disconnect=on_disconnect, multitask_strategy=multitask_strategy,
            metadata=metadata or {}, kwargs=kwargs or {}, user_id=user_id,
            created_at=now, updated_at=now, model_name=model_name)
        self._runs[run_id] = record
        self._index_run_locked(record)
        # _persist_new_run_to_store 失败则 finally 回滚内存记录（完整见 run-manager.md）
        if multitask_strategy in ("interrupt", "rollback") and inflight:
            for r in inflight:
                if r.finalizing:
                    continue
                r.abort_action = multitask_strategy   # 新 run 抢占时，旧 run 按 strategy 终结
                r.abort_event.set()
                task_active = r.task is not None and not r.task.done()
                r.finalizing = task_active
                if task_active:
                    r.task.cancel()
                r.status = RunStatus.interrupted
                r.updated_at = now
                interrupted_records.append(r)
    for interrupted_record in interrupted_records:
        await self._persist_status(interrupted_record, RunStatus.interrupted)
    return record
```

> 完整 `RunManager`（`create` / `get` / `list_by_thread` / `set_status` / `wait_for_prior_finalizing` / `has_later_started_run` / `reconcile_orphaned_inflight_runs` / `shutdown` / `cleanup` + `RunRecord` dataclass + `PersistenceRetryPolicy` + 异常类）见 [references/code/run-manager.md](./references/code/run-manager.md)。

### 2. worker pre-run 快照 + rollback 触发（入口片段）

```python
# core/helix/runtime/runs/worker.py - run_agent 开头：pre-run checkpoint 快照（回滚锚点）
pre_run_checkpoint_id: str | None = None
pre_run_snapshot: dict[str, Any] | None = None
snapshot_capture_failed = False
if checkpointer is not None:
    try:
        config_for_check = {"configurable": {"thread_id": thread_id, "checkpoint_ns": ""}}
        ckpt_tuple = await checkpointer.aget_tuple(config_for_check)
        if ckpt_tuple is not None:
            ckpt_config = getattr(ckpt_tuple, "config", {}).get("configurable", {})
            pre_run_checkpoint_id = ckpt_config.get("checkpoint_id")
            # 深拷贝：run 期间 checkpointer 会写新 checkpoint，必须冻结不可变快照
            pre_run_snapshot = {
                "checkpoint_ns": ckpt_config.get("checkpoint_ns", ""),
                "checkpoint": copy.deepcopy(getattr(ckpt_tuple, "checkpoint", {})),
                "metadata": copy.deepcopy(getattr(ckpt_tuple, "metadata", {})),
                "pending_writes": copy.deepcopy(getattr(ckpt_tuple, "pending_writes", []) or []),
            }
    except Exception:
        snapshot_capture_failed = True
        logger.warning("Could not capture pre-run checkpoint snapshot for run %s", run_id, exc_info=True)
```

```python
# core/helix/runtime/runs/worker.py - 终结路径：abort_event 或 CancelledError 触发 rollback
if record.abort_event.is_set():
    await run_manager.set_finalizing(run_id, True)
    action = record.abort_action
    if action == "rollback":
        await run_manager.set_status(run_id, RunStatus.error, error="Rolled back by user")
        try:
            await _rollback_to_pre_run_checkpoint(
                checkpointer=checkpointer, thread_id=thread_id, run_id=run_id,
                pre_run_checkpoint_id=pre_run_checkpoint_id, pre_run_snapshot=pre_run_snapshot,
                snapshot_capture_failed=snapshot_capture_failed)
            logger.info("Run %s rolled back to pre-run checkpoint %s", run_id, pre_run_checkpoint_id)
        except Exception:
            logger.warning("Failed to rollback checkpoint for run %s", run_id, exc_info=True)
    else:
        await run_manager.set_status(run_id, RunStatus.interrupted)   # interrupt：保留 checkpoint
# finally 末尾：
        await bridge.publish_end(run_id)                  # 任何路径都发 END_SENTINEL
        asyncio.create_task(bridge.cleanup(run_id, delay=60))
```

> 完整 `run_agent`（含流循环 `_stream_once` 协作取消、`except asyncio.CancelledError` 同路径 rollback、finally 收尾）、`_rollback_to_pre_run_checkpoint`（写新 checkpoint 标记 + pending_writes 恢复）、`_SubagentEventBuffer`、`_collect_pre_existing_message_ids` 见 [references/code/worker-checkpoint-rollback.md](./references/code/worker-checkpoint-rollback.md)。

### 3. StreamBridge 续传契约（入口片段）

```python
# core/helix/runtime/stream_bridge/base.py - 抽象契约
HEARTBEAT_SENTINEL = StreamEvent(id="", event="__heartbeat__", data=None)
END_SENTINEL = StreamEvent(id="", event="__end__", data=None)

class StreamBridge(abc.ABC):
    supports_cross_process: bool = False
    async def publish(self, run_id: str, event: str, data: Any) -> None: ...
    async def publish_end(self, run_id: str) -> None: ...   # 信号：run 不再产事件 -> subscribe yield END_SENTINEL
    def subscribe(self, run_id, *, last_event_id=None, heartbeat_interval=15.0) -> AsyncIterator[StreamEvent]: ...
    async def cleanup(self, run_id: str, *, delay: float = 0) -> None: ...
```

```python
# core/helix/runtime/stream_bridge/memory.py - O(1) 续传定位
def _next_id(self, run_id: str) -> str:
    self._counters[run_id] = self._counters.get(run_id, 0) + 1
    return f"{int(time.time()*1000)}-{self._counters[run_id]-1}"   # {ts}-{seq}，seq=绝对偏移

def _resolve_start_offset(self, stream, last_event_id):
    if last_event_id is None:
        return stream.start_offset
    seq = self._parse_event_seq(last_event_id)
    if seq is not None:
        local_index = seq - stream.start_offset        # O(1) 算术定位
        if 0 <= local_index < len(stream.events) and stream.events[local_index].id == last_event_id:
            return stream.start_offset + local_index + 1   # 命中：从该事件之后续发
    # 过期/伪造/他 run 的 id：从最早保留事件重放（buffer 有界，旧事件会被驱逐）
    return stream.start_offset
```

> 完整 `StreamBridge` 契约、`MemoryStreamBridge`、`RedisStreamBridge`（跨进程 + `END_SENTINEL` round-trip + `stream_exists`）见 [references/code/stream-bridge-resume.md](./references/code/stream-bridge-resume.md)（`MemoryStreamBridge` 完整 `publish`/`subscribe` 循环亦见脊柱 `references/code/07-streaming-and-resume.md`）。

### 4. on_disconnect + wait_for_run_completion（入口片段）

```python
# gateway/gateway/services.py - sse_consumer：finally 实现 on_disconnect 语义
async def sse_consumer(bridge, record, request, run_mgr):
    last_event_id = request.headers.get("Last-Event-ID")
    if await _terminal_record_stream_missing(bridge, record):
        yield format_sse("end", None); return
    try:
        async for entry in bridge.subscribe(record.run_id, last_event_id=last_event_id):
            if await request.is_disconnected():
                break
            if entry is HEARTBEAT_SENTINEL:
                yield ": heartbeat\n\n"; continue
            if entry is END_SENTINEL:
                yield format_sse("end", None, event_id=entry.id or None); return
            yield format_sse(entry.event, entry.data, event_id=entry.id or None)
    finally:
        # store_only 跨 worker record 本地无 task，cancel 会 409 -> 跳过
        if not record.store_only and record.status in (RunStatus.pending, RunStatus.running):
            if record.on_disconnect == DisconnectMode.cancel:
                await run_mgr.cancel(record.run_id)
```

```python
# gateway/gateway/services.py - wait_for_run_completion：不 await record.task，走 bridge END_SENTINEL
async def wait_for_run_completion(bridge, record, request, run_mgr) -> bool:
    completed = False
    if await _terminal_record_stream_missing(bridge, record):
        return True
    try:
        async for entry in bridge.subscribe(record.run_id):
            if entry is END_SENTINEL:
                completed = True; return True
            if entry is HEARTBEAT_SENTINEL and await _terminal_record_stream_missing(bridge, record):
                completed = True; return True
            if await request.is_disconnected():
                break
        return completed
    finally:
        if not completed and record.status in (RunStatus.pending, RunStatus.running):
            if record.on_disconnect == DisconnectMode.cancel:
                await run_mgr.cancel(record.run_id)
```

> 完整 `format_sse` / `_terminal_record_stream_missing` / `wait_for_run_completion`（含 issue #3265 docstring）+ 重连/取消端点（`join_run` / `stream_existing_run` / `cancel_run`）见 [references/code/stream-bridge-resume.md](./references/code/stream-bridge-resume.md)。

### 5. 孤儿 run 恢复（入口片段）

```python
# gateway/gateway/deps.py - lifespan 内（仅 SQLite 单进程路径）
app.state.run_manager = RunManager(store=app.state.run_store)
if getattr(config.database, "backend", None) == "sqlite":
    recovered_runs = await app.state.run_manager.reconcile_orphaned_inflight_runs(
        error="Gateway restarted before this run reached a durable final state.",
        before=now_iso())
    await _publish_recovered_run_stream_end(app.state.stream_bridge, recovered_runs, cleanup_delay=60.0)
    await _mark_latest_recovered_threads_error(app.state.run_manager, app.state.thread_store, recovered_runs)
```

> 完整 `reconcile_orphaned_inflight_runs`（见 `run-manager.md`）+ `_publish_recovered_run_stream_end` / `_mark_latest_recovered_threads_error` + shutdown drain `_drain_inflight_runs` 见 [references/code/stream-bridge-resume.md](./references/code/stream-bridge-resume.md)。

### 动态时序：一次长任务的生命周期

```
HTTP POST /runs/stream
  └─ start_run
       ├─ RunManager.create_or_reject(multitask_strategy)   # 持锁消除 TOCTOU；reject->409 / interrupt+rollback 抢占旧 run
       ├─ asyncio.create_task(run_agent(...))               # 后台 task（客户端断不死）
       └─ sse_consumer                                       # 订阅 bridge（Last-Event-ID 续传）
            └─ bridge.subscribe(last_event_id=...)           # O(1) 续传定位

run_agent (后台 task):
  ├─ wait_for_prior_finalizing                               # 等同 thread 旧 run 的 finalizing 清理完
  ├─ set_status(running)
  ├─ pre-run checkpoint 快照 (deepcopy)                       # 回滚锚点
  ├─ bridge.publish("metadata", {run_id, thread_id})
  ├─ agent.astream(...) 流循环:
  │    └─ 每 chunk: 检查 abort_event -> break / publish(sse_event, chunk)
  ├─ 终结: abort_event?
  │    ├─ rollback: set_status(error) + _rollback_to_pre_run_checkpoint (写新 checkpoint 标记)
  │    ├─ interrupt: set_status(interrupted) (保留 checkpoint)
  │    └─ success: set_status(success)
  └─ finally: subagent_events.flush + journal.flush + publish_end + cleanup(delay=60)

客户端断连:
  sse_consumer finally:
    └─ on_disconnect==cancel && not store_only && 仍 pending/running -> run_mgr.cancel(run_id)

重连: GET /runs/{run_id}/join (带 Last-Event-ID)
  └─ sse_consumer -> bridge.subscribe(last_event_id) 从断点续发

进程重启:
  ├─ reconcile_orphaned_inflight_runs (store 残留 pending/running -> error)
  ├─ _publish_recovered_run_stream_end (残留流发 END_SENTINEL + cleanup)
  └─ _mark_latest_recovered_threads_error (仅最新 run 的线程标 error)

shutdown:
  └─ _drain_inflight_runs -> RunManager.shutdown(timeout=5)
       ├─ abort 全部在途 + asyncio.wait(timeout)
       ├─ 自跑完的保留真实终态；超时的 interrupted
       └─ 持久化在预算内 bounded
```

## 反模式与陷阱

- ❌ **HTTP handler 内 `await run_agent(...)` 直接跑** -> 客户端断了 task 也死，根本无法"客户端断了后台仍跑"。修复：`asyncio.create_task` 后台化 + bridge 解耦。
- ❌ **`/wait` 端点直接 `await record.task`** -> 客户端/代理超时时 handler 吞 `CancelledError`，序列化恰巧存在的 checkpoint，把半截 run 伪装成正常完成（issue #3265）。修复：`wait_for_run_completion` 走 bridge `END_SENTINEL`，`completed=False` 跳过 checkpoint 序列化。
- ❌ **rollback 只删 checkpoint 不写回 snapshot** -> 用户看到完全空白对话历史。修复：`_rollback_to_pre_run_checkpoint` 写新 checkpoint 标记（新 id/ts）载 pre-run `channel_values` + 恢复 pending_writes。
- ❌ **rollback 覆盖旧 checkpoint** -> DB-backed saver 按 `channel_versions` 键存 blob，覆盖旧 id 版本冲突报错，回滚失败 -> 半截 messages 留 checkpoint。修复：`empty_checkpoint()` 产新 id/ts 写新 checkpoint。
- ❌ **pre-run 快照浅拷贝** -> run 期间 checkpointer 写新 checkpoint 污染快照，回滚读到被污染状态 -> 回滚无效。修复：`copy.deepcopy` checkpoint/metadata/pending_writes。
- ❌ **`abort_action` 在 `abort_event` 之后设置** -> worker 看到 event 但读到旧 action（默认 `"interrupt"`），rollback 请求被当 interrupt -> checkpoint 保留半截状态。修复：`cancel()` / `create_or_reject()` 先设 `abort_action` 再 `abort_event.set()`。
- ❌ **`cancel()` 持锁做 checkpointer IO（回滚在锁内）** -> IO 阻塞 run 注册锁 -> 同 thread 后续 `create_or_reject` 全阻塞 -> 系统僵。修复：`cancel` 只设状态 + `task.cancel()`，回滚留给 worker 终结路径在 finally 做。
- ❌ **`Last-Event-ID` 服务端不识别** -> 重连后从头送一遍，前端去重死循环 / 卡顿。修复：`{ts}-{seq}` 的 `seq` 做 O(1) 算术定位 + id 校验降级重放。
- ❌ **buffer 无界** -> 长任务（subagent `max_turns=150` 产数百事件）内存撑爆 OOM。修复：`queue_maxsize=256` 驱逐最旧 + `start_offset` 前移。
- ❌ **不发心跳** -> nginx / 浏览器 60s 静默关 SSE，体验上"消息突然没了"。修复：`heartbeat_interval=15.0` 无事件 yield `HEARTBEAT_SENTINEL` -> `: heartbeat\n\n`。
- ❌ **`bridge.cleanup(delay=0)`** -> 慢客户端来不及订阅 / 重连，永远连不上。修复：`cleanup(delay=60)`（bridge）/ `cleanup(delay=300)`（RunManager 记录）。
- ❌ **`on_disconnect=cancel` 对 `store_only` record 调 `cancel`** -> 跨 worker record 本地无 task，`cancel` 返回 False / 端点 409。修复：`sse_consumer` / `wait_for_run_completion` 的 `finally` 对 `store_only` 跳过。
- ❌ **多进程部署用 `MemoryStreamBridge` 还想 `/join` 跨 worker** -> `store_only` record + `not supports_cross_process` -> join 409。修复：多 worker 用 `RedisStreamBridge`（`supports_cross_process=True`）。
- ❌ **进程重启不 reconcile 孤儿** -> 历史 UI 永远显示一坨"活跃 run"。修复：启动 `reconcile_orphaned_inflight_runs`（仅 SQLite 单进程）。
- ❌ **shutdown 不 drain inflight** -> checkpointer 池先关、worker 还在写，langgraph 内部 task 的 `finally: await checkpointer.aput(...)` 撞关闭的 pool，`PoolClosed` 不在 worker 调用栈 -> 不可捕获 -> `asyncio.run()` shutdown 抛未处理异常（issue #3373）。修复：`_drain_inflight_runs` 在 checkpointer 关闭前 bounded drain。
- ❌ **shutdown drain 把自跑完的 run 也覆盖成 `interrupted`** -> 丢失真实终态。修复：`task not in pending and not task.cancelled()` 分支保留 run 自设的 `success`/`error`。
- ❌ **`update_run_progress` 在终态后还在写** -> token 累计污染已 success/error 的快照。修复：`should_persist = record.status == RunStatus.running` 守卫。

## 落地参考（自测 / 调参 / 调试）

### 调参旋钮

| 旋钮 | 来源 | 默认 | 说明 |
|---|---|---|---|
| `on_disconnect` | `RunCreateRequest` | `"cancel"` | 客户端断 -> cancel task；`"continue"` 让后台继续跑供 `/join` |
| `multitask_strategy` | `RunCreateRequest` | `"reject"` | 同 thread 已有活跃 run：`reject`(409) / `interrupt`(保留 ckpt) / `rollback`(回滚) |
| `heartbeat_interval` | `bridge.subscribe` | 15s | 无事件心跳间隔（防 nginx/浏览器 60s 静默关） |
| `bridge.cleanup` delay | worker finally | 60s | END 帧后 bridge 保留多久（给慢客户端续上） |
| `RunManager.cleanup` delay | - | 300s | 内存 RunRecord 清理延迟（给慢端点拉历史） |
| `queue_maxsize` | `MemoryStreamBridge` / `RedisStreamBridge` | 256 | retained-buffer 上限（溢出驱逐最旧） |
| `stream_ttl_seconds` | `RedisStreamBridge` | 86400 | Redis Stream 兜底过期（泄漏安全网，非 run 超时） |
| `recovered_stream_cleanup_delay_seconds` | stream_bridge config | 60.0 | 孤儿恢复流的 cleanup 延迟 |
| `PersistenceRetryPolicy` | `RunManager` | 5 次 / 50ms->1s | SQLite 锁重试（仅 `SQLITE_BUSY/LOCKED`） |
| `shutdown` timeout | `RunManager` / `_RUN_DRAIN_TIMEOUT_SECONDS` | 5s | inflight 优雅 drain 预算 |
| `recursion_limit` | run config | 100 | 主代理 super-step 上限（非 run 超时） |

### 关键日志串

- `Run created: run_id=... thread_id=...` - 注册 run
- `Run %s -> %s` - 每次 `set_status` 一行（状态机）
- `Run %s cancelled (action=%s)` - `cancel` 生效（action=interrupt/rollback）
- `Run %s: streaming with modes %s (requested: %s)` - stream_mode 落定
- `Run %s abort requested - stopping` - 流循环检测到 abort
- `Run %s rolled back to pre-run checkpoint %s` - rollback 生效
- `Run %s was cancelled and rolled back` - CancelledError 路径 rollback
- `Could not capture pre-run checkpoint snapshot for run %s` - 快照失败（rollback 将降级）
- `Run %s rollback skipped: pre-run checkpoint snapshot capture failed` - 快照失败降级
- `last_event_id=%s not found in retained buffer; replaying from earliest retained event` - 续传降级
- `subscriber for run %s fell behind retained buffer; resuming from offset %s` - 订阅者落后驱逐速度降级
- `Recovered %d orphaned inflight run(s) as error` - 启动孤儿恢复
- `Drained %d in-flight run(s) on shutdown (%d settled within %.1fs)` - shutdown drain
- `Run drain exceeded %.1fs on shutdown; %d run task(s) still active and may race checkpointer teardown` - drain 超时（issue #3373 风险）
- `Transient persistence failure during %s for run %s (attempt %d/%d); retrying` - store 背压重试

### 调试入口

| 现象 | 看哪里 |
|---|---|
| run 卡住不流 | `RunManager.create_or_reject` 是否 `ConflictError`（thread 已有在途）；`wait_for_prior_finalizing` 是否在等旧 run 清理 |
| SSE 断流后丢事件 | `MemoryStreamBridge._resolve_start_offset`；客户端是否带 `Last-Event-ID`；`queue_maxsize` 是否太小导致驱逐 |
| 取消后状态没回滚 | worker `_rollback_to_pre_run_checkpoint`；`multitask_strategy` 是否 `"rollback"`；`abort_action` 是否先于 `abort_event` 设置；`snapshot_capture_failed` 是否 True |
| `/wait` 返回半截 checkpoint | 是否用了 `wait_for_run_completion`（而非 `await record.task`）；`completed=False` 是否跳过序列化 |
| 进程重启后 UI 显示活跃 run | `reconcile_orphaned_inflight_runs` 是否跑（仅 SQLite）；`_mark_latest_recovered_threads_error` 是否仅标最新 run |
| shutdown 抛 `PoolClosed` | `_drain_inflight_runs` 是否在 checkpointer 关闭前跑；`shutdown(timeout)` 是否够长 |
| 跨 worker `/join` 409 | bridge 是否 `supports_cross_process=True`（Redis）；`store_only` record 的 join 守卫 |

### 自测方向

- **后台化**：发起 run，中途断 SSE，断言后台 task 仍跑（`on_disconnect=continue`）或被 cancel（`on_disconnect=cancel`）。
- **续传 O(1) 命中**：起 run，发若干事件后断 SSE，用 `Last-Event-ID` 重连，断言从该事件之后续发、无丢无重放；`_resolve_start_offset` 返回 `start_offset + local_index + 1`。
- **buffer 驱逐降级**：发超过 `queue_maxsize` 个事件后重连（`Last-Event-ID` 指向已驱逐事件），断言降级到从最早保留事件重放、记 warn。
- **rollback 恢复 pre-run**：起改了 workspace/写了 messages 的 run，`cancel(action="rollback")`，断言 checkpointer 最新 checkpoint 的 `channel_values.messages` 等于 run 前、无半截产物；`Run %s rolled back` 日志出现。
- **interrupt 保留 checkpoint**：`cancel(action="interrupt")`，断言 checkpoint 保留 run 中途状态、run 状态 `interrupted`。
- **multitask 抢占 rollback**：thread 已有在途 run，新 run 以 `multitask_strategy="rollback"` 创建，断言旧 run 被 `abort_action="rollback"` 终结并回滚、新 run 正常起。
- **快照失败降级**：mock `checkpointer.aget_tuple` 抛异常，断言 `snapshot_capture_failed=True`、rollback 时跳过并记 warn、run 不卡死。
- **CancelledError 路径**：`task.cancel()` 触发 `asyncio.CancelledError`，`abort_action="rollback"` 时断言走 rollback 分支。
- **wait 不返回 stale**：mock 客户端 `is_disconnected()=True`，断言 `wait_for_run_completion` 返回 `False`、路由跳过 checkpoint 序列化。
- **store_only 不 cancel**：跨 worker record，断言 `sse_consumer` finally 跳过 `cancel`。
- **孤儿恢复**：store 里造一条 `running` 行，重启，断言被刷成 `error`、线程标 error（仅当是最新 run）、流发 `END_SENTINEL`。
- **shutdown drain**：起若干在途 run，触发 shutdown，断言自跑完的保留真实终态、超时的 `interrupted`、无 `PoolClosed`。
- **cancel 幂等**：已 `interrupted` 的 run 再次 `cancel` 返回 `True`；已 `success/error` 返回 `False`。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 完整 RunManager 运行态机 + multitask + cancel + 孤儿恢复 + shutdown：[references/code/run-manager.md](./references/code/run-manager.md)
- 完整 worker pre-run 快照 + rollback + _SubagentEventBuffer：[references/code/worker-checkpoint-rollback.md](./references/code/worker-checkpoint-rollback.md)
- 完整 StreamBridge 续传契约 + on_disconnect/wait + 孤儿流收尾 + 重连/取消端点：[references/code/stream-bridge-resume.md](./references/code/stream-bridge-resume.md)
- 关联 skill：[[e2e-request-lifecycle]]（脊柱 ⑦流式 + 跨切不变量 3）、[[gateway-runs-and-sse]]（lifespan 装配 + RunManager/StreamBridge 单例 + 创建端点 + Redis bridge 全貌）、[[frontend-streaming-protocol]]（`useStream` 消费 + `Last-Event-ID` 重连 + SSE schema）、[[subagent-delegation]]（子代理 `_SubagentEventBuffer` 批量持久化的上游）、[[scheduled-tasks]]（`on_disconnect=continue` 无人值守 run）、[[observability-tracing]]（run_id 与 trace 1:1 对齐）
