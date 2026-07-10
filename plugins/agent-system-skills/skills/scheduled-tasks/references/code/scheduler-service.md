# 完整源码：ScheduledTaskService（poller + lease 并发限流 + 认领 + 崩溃恢复）

> 本文件给出调度服务的**完整实现**：`ScheduledTaskService`（poller 主循环、lease 并发限流、cron/once 认领、overlap_policy、崩溃恢复）+ `SchedulerConfig`（含 restart-required 字段）。
>
> SKILL.md「完整真实代码实现」段给了 `run_once`/`dispatch_task` 入口片段与索引；此处补全完整源码与所有边界处理（`_finalize_skip`、`handle_run_completion`、`start`/`stop` 生命周期、`cancel_stuck_once_tasks`/`mark_stale_active_runs` 崩溃恢复调用）。
>
> 真实实现已按匿名化规则映射到中立结构（应用层 `scheduler.scheduler.*`、框架层 `helix.*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

---

## 1. SchedulerConfig（配置 + restart-required 字段）

```python
# core/helix/config/scheduler_config.py
from pydantic import BaseModel, Field


class SchedulerConfig(BaseModel):
    """调度器配置。

    所有字段改动都需要重启进程生效（poller 在启动时读一次配置构造 service），
    不支持热重载--与 run 级配置（model_name 等）不同，后者每 run 解析。
    """

    enabled: bool = Field(default=False)
    # poller 主循环间隔。过短则空轮询压 DB；过长则 once 任务延迟触发。
    poll_interval_seconds: int = Field(default=5, ge=1, le=300)
    # lease TTL：claim 后任务被本实例独占的时长。到期前未完成则可被其他实例抢。
    # 必须 > 最长单 run 耗时，否则长 run 会被重复认领；但太长则实例崩溃后任务
    # 要等 TTL 过期才能被其他实例接管。
    lease_seconds: int = Field(default=120, ge=5, le=3600)
    # 全局在途调度 run 上限（不是单轮认领数）。长 run 跨轮累积，每轮只认领剩余预算。
    max_concurrent_runs: int = Field(default=3, ge=1, le=32)
    # once 任务最小提前量：创建时 run_at 必须至少在未来这么秒，避免"创建即过期"。
    min_once_delay_seconds: int = Field(default=60, ge=1, le=86400)
```

> `enabled=False` 默认关闭。`config.yaml -> scheduler.enabled=true` 时 Gateway 启动才构造 `ScheduledTaskService` 并 `start()`。改 `poll_interval_seconds`/`lease_seconds`/`max_concurrent_runs` 需重启进程（poller 不热重载）。

---

## 2. ScheduledTaskService 完整源码

```python
# scheduler/scheduler/service.py
from __future__ import annotations

import asyncio
import logging
import socket
import uuid
from datetime import UTC, datetime
from typing import Any, Literal

from fastapi import HTTPException

from helix.runtime import ConflictError, RunRecord
from helix.scheduler.schedules import next_run_at

logger = logging.getLogger(__name__)


class ScheduledTaskService:
    """调度任务 poller 服务。

    职责：周期性认领到期任务（lease 防多实例并发抢同一任务）、交给
    ``launch_run`` 桥接进 run 生命周期、收尾 run 完成状态、崩溃恢复。
    非线程安全：单实例单事件循环驱动；多实例部署靠 lease + lease_owner 互斥。
    """

    def __init__(
        self,
        *,
        task_repo,
        task_run_repo,
        launch_run,
        poll_interval_seconds: int,
        lease_seconds: int,
        max_concurrent_runs: int,
    ) -> None:
        self._task_repo = task_repo
        self._task_run_repo = task_run_repo
        self._launch_run = launch_run
        self._poll_interval_seconds = poll_interval_seconds
        self._lease_seconds = lease_seconds
        self._max_concurrent_runs = max_concurrent_runs
        # lease_owner 唯一标识本 poller 实例：hostname + 随机 hex。
        # claim 时写入任务行；多实例并发抢同一任务时只有 lease 持有者能推进，
        # 其余实例的 claim 因 lease 未到期而被仓储层拒掉。
        self._lease_owner = f"{socket.gethostname()}:{uuid.uuid4().hex}"
        self._task: asyncio.Task | None = None
        self._stop = asyncio.Event()

    async def run_once(self, *, now: datetime) -> None:
        """单轮认领：算预算 -> claim 到期任务 -> 逐个 dispatch。

        ``max_concurrent_runs`` 是全局在途上限，不是单轮认领批大小：
        长 run 会跨轮累积，每轮只认领剩余预算内的任务，避免超限。
        """
        active = await self._task_run_repo.count_active_runs()
        budget = self._max_concurrent_runs - active
        if budget <= 0:
            return
        claimed = await self._task_repo.claim_due_tasks(
            now=now,
            lease_owner=self._lease_owner,
            lease_seconds=self._lease_seconds,
            limit=budget,
        )
        for task in claimed:
            await self.dispatch_task(task, now=now, trigger="scheduled")

    @staticmethod
    def _is_overlap_conflict(exc: Exception) -> bool:
        """判断异常是否为"同线程已有在途 run"的 overlap 冲突。

        ConflictError 是框架层 run 注册冲突；HTTPException 409 是路由层
        trigger 端点的冲突响应。两者都视为 overlap。
        """
        if isinstance(exc, ConflictError):
            return True
        return isinstance(exc, HTTPException) and exc.status_code == 409

    @staticmethod
    def _task_status_for_failure(task: dict[str, Any], *, trigger: str) -> str:
        """dispatch 失败后任务应置什么状态。

        手动触发失败不得消费任务的调度未来：一个 run_at 仍在未来的 once
        任务若被翻成 failed，就再也不会被认领。故手动触发失败时保留原状态。
        """
        if trigger == "manual":
            return task.get("status") or "enabled"
        if task["schedule_type"] == "once":
            return "failed"
        return "enabled"

    @staticmethod
    def _task_status_for_skip(task: dict[str, Any]) -> str:
        """overlap skip 后任务应置什么状态。

        once 任务的唯一一次执行因 overlap 被跳过，"completed" 会谎称执行过，
        故置 failed；cron 任务继续 enabled 等下一轮。
        """
        if task["schedule_type"] == "once":
            return "failed"
        return "enabled"

    async def dispatch_task(
        self,
        task: dict[str, Any],
        *,
        now: datetime,
        trigger: str,
    ) -> dict[str, Any]:
        """认领后分发一个任务：建 run 行 -> launch_run -> 推进状态。

        trigger="scheduled" 由 poller 调；trigger="manual" 由路由 trigger 端点调。
        overlap_policy="skip" 时，若任务已有在途 run，scheduled 跳过、manual 拒绝。
        """
        execution_thread_id = task.get("thread_id")
        if task.get("context_mode") == "fresh_thread_per_run" or not execution_thread_id:
            execution_thread_id = str(uuid.uuid4())
        # overlap skip 检查对 fresh-thread run 也必须生效：fresh-thread 每次新线程，
        # 同线程 multitask ConflictError 永远不会触发，故必须显式查 has_active_runs。
        # 在建本 dispatch 自己的 run 行之前查，否则 run 行会把自己算成在途。
        # 手动触发撞在途 run 直接拒绝（路由层 409），不记为 skipped occurrence--
        # 因为本来就没有调度要发生。
        skip_error: str | None = None
        if task.get("overlap_policy", "skip") == "skip" and await self._task_run_repo.has_active_runs(task["id"]):
            if trigger == "manual":
                return {
                    "outcome": "conflict",
                    "task_run_id": None,
                    "run_id": None,
                    "thread_id": execution_thread_id,
                    "error": "task already has an active run",
                }
            skip_error = "skipped: a previous run of this task is still active"
        task_run_id = f"task-run-{uuid.uuid4().hex}"
        await self._task_run_repo.create(
            run_record_id=task_run_id,
            task_id=task["id"],
            thread_id=execution_thread_id,
            scheduled_for=now,
            trigger=trigger,
            status="queued",
        )
        if skip_error is not None:
            return await self._finalize_skip(task, task_run_id=task_run_id, thread_id=execution_thread_id, now=now, error=skip_error)
        try:
            result = await self._launch_run(
                thread_id=execution_thread_id,
                assistant_id=task.get("assistant_id"),
                prompt=task["prompt"],
                owner_user_id=task.get("user_id"),
                metadata={
                    "scheduled_task_id": task["id"],
                    "scheduled_task_run_id": task_run_id,
                    "scheduled_trigger": trigger,
                },
            )
            next_at = next_run_at(
                task["schedule_type"],
                task["schedule_spec"],
                task["timezone"],
                now=now,
            )
            if task["schedule_type"] == "once":
                # once 任务保持 "running" 直到 handle_run_completion 看到真实终态；
                # launch 时就声明 "completed" 会在 run 失败或进程崩溃时卡住
                # （启动时的崩溃恢复是 cancel_stuck_once_tasks）。
                task_status = "running"
            elif trigger == "manual" and task.get("status") == "paused":
                task_status = "paused"
            else:
                task_status = "enabled"
            await self._task_run_repo.update_status(
                task_run_id,
                status="running",
                run_id=result["run_id"],
                started_at=now,
                # 快速失败的 run 可能在本次写回前就到达 handle_run_completion；
                # protect_terminal=True 确保不覆盖它的终态。
                protect_terminal=True,
            )
            await self._task_repo.update_after_launch(
                task["id"],
                status=task_status,
                next_run_at=next_at,
                last_run_at=now,
                last_run_id=result["run_id"],
                last_thread_id=result["thread_id"],
                last_error=None,
                increment_run_count=True,
                # 同上 race：快速失败 run 的完成回调可能已终结 once 任务。
                protect_terminal=True,
            )
            return {
                "outcome": "launched",
                "task_run_id": task_run_id,
                "run_id": result["run_id"],
                "thread_id": result["thread_id"],
                "error": None,
            }
        except Exception as exc:
            next_at = next_run_at(
                task["schedule_type"],
                task["schedule_spec"],
                task["timezone"],
                now=now,
            )
            if self._is_overlap_conflict(exc) and trigger == "scheduled" and task.get("overlap_policy", "skip") == "skip":
                # launch 时撞 ConflictError（同线程已有在途 run）且策略 skip：记为 skipped
                return await self._finalize_skip(task, task_run_id=task_run_id, thread_id=execution_thread_id, now=now, error=str(exc))

            task_status = self._task_status_for_failure(task, trigger=trigger)
            await self._task_run_repo.update_status(
                task_run_id,
                status="failed",
                error=str(exc),
                started_at=now,
                finished_at=now,
            )
            await self._task_repo.update_after_launch(
                task["id"],
                status=task_status,
                next_run_at=next_at,
                last_run_at=now,
                last_run_id=None,
                last_thread_id=execution_thread_id,
                last_error=str(exc),
                increment_run_count=False,
            )
            return {
                "outcome": "conflict" if self._is_overlap_conflict(exc) else "failed",
                "task_run_id": task_run_id,
                "run_id": None,
                "thread_id": execution_thread_id,
                "error": str(exc),
            }

    async def _finalize_skip(
        self,
        task: dict[str, Any],
        *,
        task_run_id: str,
        thread_id: str,
        now: datetime,
        error: str,
    ) -> dict[str, Any]:
        """把一次 dispatch 记为 skipped：run 行置 skipped，任务行推进 next_run_at。

        对 cron 任务这是常态（上一轮还在跑，这一轮跳过）；对 once 任务这意味着
        唯一一次执行丢失，置 failed 并记 last_error。
        """
        next_at = next_run_at(
            task["schedule_type"],
            task["schedule_spec"],
            task["timezone"],
            now=now,
        )
        await self._task_run_repo.update_status(
            task_run_id,
            status="skipped",
            error=error,
            started_at=now,
            finished_at=now,
        )
        await self._task_repo.update_after_launch(
            task["id"],
            status=self._task_status_for_skip(task),
            next_run_at=next_at,
            last_run_at=task.get("last_run_at"),
            last_run_id=task.get("last_run_id"),
            last_thread_id=task.get("last_thread_id"),
            last_error=error if task["schedule_type"] == "once" else None,
            increment_run_count=False,
        )
        return {
            "outcome": "skipped",
            "task_run_id": task_run_id,
            "run_id": None,
            "thread_id": thread_id,
            "error": error,
        }

    async def handle_run_completion(self, record: RunRecord) -> None:
        """run 终态回调：把 run 结果同步回 task_run 行与 task 行。

        由 run 生命周期在 run 到达终态时调用。metadata 里带 scheduled_task_id
        /scheduled_task_run_id 的才是调度 run；普通 run 直接 return。
        once 任务在此时消费（completed/cancelled/failed），cron 任务只更新 last_error。
        """
        metadata = record.metadata or {}
        task_id = metadata.get("scheduled_task_id")
        task_run_id = metadata.get("scheduled_task_run_id")
        user_id = record.user_id
        if not isinstance(task_id, str) or not isinstance(task_run_id, str) or not user_id:
            return

        terminal_status: Literal["success", "failed", "interrupted"] | None
        if record.status.value == "success":
            terminal_status = "success"
            error = None
        elif record.status.value == "interrupted":
            # interrupted 不同于 failed：中断（用户取消、同线程 takeover）不带错误，
            # 不是执行失败。
            terminal_status = "interrupted"
            error = record.error or "run was interrupted before completion"
        elif record.status.value in {"error", "timeout"}:
            terminal_status = "failed"
            error = record.error
        else:
            terminal_status = None
            error = record.error
        if terminal_status is None:
            return

        await self._task_run_repo.update_status(
            task_run_id,
            status=terminal_status,
            run_id=record.run_id,
            error=error,
            finished_at=datetime.now(UTC),
        )

        task = await self._task_repo.get(task_id, user_id=user_id)
        if task is None:
            return

        updates: dict[str, Any] = {"last_error": error}
        if task["schedule_type"] == "once":
            # once 任务的唯一一次执行无论成功失败都已消费（run 已 launch，re-arm
            # 有重复副作用风险），但中断结为 "cancelled" 而非 "failed"。
            if terminal_status == "success":
                updates["status"] = "completed"
            elif terminal_status == "interrupted":
                updates["status"] = "cancelled"
            else:
                updates["status"] = "failed"
        await self._task_repo.update(task_id, user_id=user_id, updates=updates)

    async def start(self) -> None:
        """启动 poller：先做崩溃恢复清扫，再起主循环 task。

        崩溃恢复两步：
        1. mark_stale_active_runs：把上一进程遗留的 active run 行标 interrupted
           （进程重启前未到终态的 run）。
        2. cancel_stuck_once_tasks：把卡在 "running" 的 once 任务行翻转--
           它们本应由（已死的）完成回调终结，现在永远等不到了。
        两步都容错：失败只记日志，不阻塞启动。
        """
        if self._task is not None:
            return
        restart_error = "interrupted: gateway restarted before the run reached a terminal state"
        try:
            stale = await self._task_run_repo.mark_stale_active_runs(error=restart_error)
            if stale:
                logger.warning("Marked %d stale scheduled task run(s) as interrupted after restart", stale)
        except Exception:
            logger.exception("Failed to sweep stale scheduled task runs at startup")
        try:
            # 上面的 run 行只是一半：已 launch 的 once 任务停在 "running" 直到
            # （已死的）完成回调终结它，故还要对父任务行做对账。
            stuck = await self._task_repo.cancel_stuck_once_tasks(error=restart_error)
            if stuck:
                logger.warning("Cancelled %d stuck once task(s) after restart", stuck)
        except Exception:
            logger.exception("Failed to reconcile stuck once tasks at startup")
        self._stop.clear()
        self._task = asyncio.create_task(self._run_loop())

    async def stop(self) -> None:
        """停止 poller：设 stop 事件，等主循环 task 退出。"""
        if self._task is None:
            return
        self._stop.set()
        await self._task
        self._task = None

    async def _run_loop(self) -> None:
        """poller 主循环：每 poll_interval_seconds 跑一次 run_once。

        单轮异常不杀循环：瞬时 DB 错误（如 SQLite "database is locked"）
        只记日志，下一轮重试，避免 poller 在进程剩余生命里停摆。
        """
        while not self._stop.is_set():
            try:
                await self.run_once(now=datetime.now(UTC))
            except Exception:
                logger.exception("Scheduled task poll failed; retrying next interval")
            try:
                await asyncio.wait_for(
                    self._stop.wait(),
                    timeout=self._poll_interval_seconds,
                )
            except TimeoutError:
                continue
```

---

## 3. 关键设计点详解

### 3.1 lease 并发限流（多实例不重复执行）

`claim_due_tasks(now, lease_owner, lease_seconds, limit)` 是仓储层的原子认领：它把到期且 `status='enabled'` 的任务行，在一条 SQL 里更新 `lease_owner` + `lease_expires_at = now + lease_seconds`，只返回被本实例抢到的行。多实例并发抢同一任务时，DB 行锁保证只有一个 UPDATE 命中（条件 `lease_expires_at < now AND status='enabled'`），其余实例的 claim 拿不到该行。

`lease_owner = "{hostname}:{uuid4().hex}"` 在构造时生成，进程级唯一。lease TTL 内即使本实例崩溃，其他实例也不会抢（要等 `lease_expires_at` 过期）；这换取了"不会重复执行"的强保证，代价是崩溃后接管有延迟（最多 `lease_seconds`）。

### 3.2 max_concurrent_runs 是全局在途上限，不是单轮认领数

```python
active = await self._task_run_repo.count_active_runs()
budget = self._max_concurrent_runs - active
if budget <= 0:
    return
claimed = await self._task_repo.claim_due_tasks(
    now=now, lease_owner=self._lease_owner,
    lease_seconds=self._lease_seconds, limit=budget)
```

长 run（如跑几十分钟的 cron 任务）会跨多个 poll 周期仍处于 active。若 `limit` 固定为 `max_concurrent_runs`，每轮都会认领满，在途 run 会无限堆积超过上限。故每轮先算"剩余预算 = 上限 - 当前在途"，只认领预算内的任务。这让 `max_concurrent_runs` 成为真正的全局硬上限。

### 3.3 overlap_policy（skip 模式的双重检查）

`overlap_policy="skip"` 时，"上一轮还在跑就跳过这一轮"有两道检查：

1. **显式 `has_active_runs` 检查**（dispatch_task 开头）：对 `fresh_thread_per_run` 模式必须显式查，因为每次新线程，同线程 `multitask_strategy="reject"` 的 `ConflictError` 永远不会触发。在建本 dispatch 的 run 行之前查，否则把自己算进在途。
2. **launch 时 `ConflictError` 兜底**（dispatch_task except 分支）：`reuse_thread` 模式下，若 launch 撞同线程在途 run，`_is_overlap_conflict` 识别后走 `_finalize_skip`。

手动 trigger 撞在途 run 不记 skipped（直接 409 拒绝），因为本来就没有调度要发生。

### 3.4 once 任务的状态机与崩溃恢复

once 任务有特殊状态流转：launch 时置 `running`（不置 `completed`），等 `handle_run_completion` 看到真实终态才终态化。这是为了防"launch 后 run 失败或进程崩溃时任务卡 completed"。

崩溃恢复两步互补：
- `mark_stale_active_runs`：run 行级。上一进程遗留的 active run 行（status=running/queued）标 interrupted。
- `cancel_stuck_once_tasks`：任务行级。卡在 `running` 的 once 任务行翻转（它本应由已死的完成回调终结）。

两步都在 `start()` 里跑，且容错（失败只记日志不阻塞启动）。

### 3.5 protect_terminal 防 race

`update_status(task_run_id, status="running", protect_terminal=True)` 与 `update_after_launch(task_id, protect_terminal=True)`：快速失败的 run 可能在 dispatch_task 的写回之前就到达 `handle_run_completion` 并把 run 行/任务行终态化。`protect_terminal=True` 告诉仓储层"若行已是终态则不覆盖"，避免 dispatch 的非终态写回冲掉终态。

---

## 4. 生命周期时序

```
start()
  ├─ mark_stale_active_runs()        # 崩溃恢复：清遗留 active run 行
  ├─ cancel_stuck_once_tasks()       # 崩溃恢复：清卡住的 once 任务行
  └─ create_task(_run_loop)
        └─ while not stop:
              ├─ run_once(now)        # 算预算 -> claim -> dispatch
              │     └─ dispatch_task()
              │           ├─ has_active_runs 查 overlap
              │           ├─ create run 行 (queued)
              │           ├─ _launch_run() -> launch_scheduled_thread_run()  # 见 non-interactive-stripping.md
              │           ├─ update_status(running, protect_terminal)
              │           └─ update_after_launch(next_run_at, protect_terminal)
              └─ wait_for(stop, timeout=poll_interval)

handle_run_completion(record)         # run 终态时由 run 生命周期回调
  ├─ update_status(task_run, terminal)
  └─ update(task, once->completed/cancelled/failed)
```

> 关联：`_launch_run` 桥接进 run 生命周期 + non_interactive 注入见 [non-interactive-stripping.md](./non-interactive-stripping.md)；cron/once 纯计算见 [schedules-calc.md](./schedules-calc.md)；端到端位置见 [[e2e-request-lifecycle]] ①入站-scheduler。
