# 完整源码：REST 四件套（创建校验 + 手动触发 + CRUD + runs）

> 本文件给出调度任务 REST 路由的**完整实现**：`ScheduledTaskCreateRequest` 模型 + `create_scheduled_task`（创建时预演 `next_run_at` 校验）+ `trigger_scheduled_task`（手动触发走 `dispatch_task(trigger="manual")`）+ 其余端点（list/get/patch/pause/resume/delete/runs + thread 维度 list）的设计说明。
>
> 路由层是 `schedules.py` 纯计算（见 [schedules-calc.md](./schedules-calc.md)）的第一个复用点：创建/更新任务时预演 `next_run_at` 校验规格合法 + `once` 在未来 + 满足 `min_once_delay_seconds`，非法直接 422。手动触发则委托 `ScheduledTaskService.dispatch_task`（见 [scheduler-service.md](./scheduler-service.md)），撞在途 run 返回 conflict -> 409。
>
> 真实实现已按匿名化规则映射到中立结构（应用层 `gateway.gateway.*`、框架层 `helix.*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

---

## 1. 创建请求模型

```python
# gateway/gateway/routers/scheduled_tasks.py
from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from helix.config import get_config
from helix.scheduler.schedules import (
    compute_next_run_at,
    normalize_cron_expression,
    validate_timezone,
)


class ScheduledTaskCreateRequest(BaseModel):
    """创建调度任务的请求体。

    schedule_type/schedule_spec/timezone 在路由层经 schedules.py 预演校验：
    时区存在、cron 五字段、once 在未来且满足 min_once_delay_seconds。
    """

    thread_id: str | None = None
    context_mode: str = "fresh_thread_per_run"
    title: str = Field(min_length=1)
    prompt: str = Field(min_length=1)
    schedule_type: str
    schedule_spec: dict[str, Any]
    timezone: str
```

---

## 2. 创建端点：create_scheduled_task（预演 next_run_at 校验）

```python
# gateway/gateway/routers/scheduled_tasks.py
@router.post("/scheduled-tasks")
@require_permission("threads", "write")
async def create_scheduled_task(request: Request, body: ScheduledTaskCreateRequest):
    """创建调度任务。

    校验链：context_mode 合法 -> reuse_thread 需 thread_id 且有访问权 ->
    schedule_type 合法 -> 预演 next_run_at（时区/cron 五字段/once 在未来/
    满足 min_once_delay_seconds）-> 入库。
    """
    config = get_config()
    repo = get_scheduled_task_repo(request)
    user = await get_optional_user_from_request(request)
    if user is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    if body.context_mode not in {"fresh_thread_per_run", "reuse_thread"}:
        raise HTTPException(status_code=422, detail="Unsupported context_mode")
    if body.context_mode == "reuse_thread":
        if not body.thread_id:
            raise HTTPException(status_code=422, detail="reuse_thread requires thread_id")
        if not await thread_store.check_access(body.thread_id, str(user.id), require_existing=True):
            raise HTTPException(status_code=404, detail="Thread not found")
    if body.schedule_type not in {"once", "cron"}:
        raise HTTPException(status_code=422, detail="Unsupported schedule_type")
    # 创建时预演 next_run_at：校验规格合法 + once 在未来 + 满足 min_once_delay_seconds
    schedule_spec = dict(body.schedule_spec)
    try:
        validate_timezone(body.timezone)
        if body.schedule_type == "cron":
            schedule_spec["cron"] = normalize_cron_expression(schedule_spec["cron"])
        next_run_at = compute_next_run_at(body.schedule_type, schedule_spec, body.timezone,
                                          now=datetime.now(UTC))
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    if body.schedule_type == "once" and next_run_at is None:
        raise HTTPException(status_code=422, detail="once schedule must be in the future")
    if body.schedule_type == "once" and next_run_at is not None and \
            (next_run_at - datetime.now(UTC)).total_seconds() < config.scheduler.min_once_delay_seconds:
        raise HTTPException(status_code=422,
            detail=f"once schedule must be at least {config.scheduler.min_once_delay_seconds} seconds in the future")
    return await repo.create(task_id=f"task-{uuid4().hex}", user_id=str(user.id),
                             thread_id=body.thread_id, context_mode=body.context_mode,
                             assistant_id="lead_agent", title=body.title, prompt=body.prompt,
                             schedule_type=body.schedule_type, schedule_spec=schedule_spec,
                             timezone=body.timezone, next_run_at=next_run_at)
```

---

## 3. 手动触发端点：trigger_scheduled_task（走 dispatch_task trigger=manual）

```python
# gateway/gateway/routers/scheduled_tasks.py
@router.post("/scheduled-tasks/{task_id}/trigger")
@require_permission("threads", "write")
async def trigger_scheduled_task(task_id: str, request: Request):
    """手动触发一个调度任务。

    走 ScheduledTaskService.dispatch_task(trigger="manual")。撞在途 run 时
    dispatch_task 返回 outcome=conflict -> 路由层 409（不记 skipped，因为
    本来就没有调度要发生）；launch 失败返回 outcome=failed -> 502。
    """
    repo = get_scheduled_task_repo(request)
    service = get_scheduled_task_service(request)
    user = await get_optional_user_from_request(request)
    if user is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    task = await repo.get(task_id, user_id=str(user.id))
    if task is None:
        raise HTTPException(status_code=404, detail="Scheduled task not found")
    # 手动触发走 dispatch_task(trigger="manual")：撞在途 run 返回 conflict -> 409
    result = await service.dispatch_task(task, now=datetime.now(UTC), trigger="manual")
    if result["outcome"] == "conflict":
        raise HTTPException(status_code=409, detail=result["error"] or "Scheduled task trigger conflicted with an active run")
    if result["outcome"] == "failed":
        raise HTTPException(status_code=502, detail=result["error"] or "Scheduled task trigger failed")
    return {"id": task_id, "triggered": True}
```

---

## 4. 其余端点设计说明

其余端点（list/get/patch/pause/resume/delete/runs + thread 维度 list）均按 per-user scoping（`repo.get(task_id, user_id=str(user.id))`）+ `@require_permission("threads", "read"/"write")` 同构。关键差异点：

- **per-user scoping**：所有端点都按 `user_id` 过滤/鉴权，用户只能看到/操作自己的调度任务。`thread_id` 维度的 list 端点先经 `thread_store.check_access` 校验线程访问权，再返回该线程下的调度任务。
- **`pause`/`resume`/`patch` 前调 `_ensure_task_mutable(task)`**：拒绝对着 `running` 状态任务的改动（409）。`running` 任务正在执行中，改规格/暂停会导致状态不一致。
- **`patch` 改规格后重算 `next_run_at`**：改 `schedule_type`/`schedule_spec`/`timezone` 后，重新预演 `next_run_at` 写回。同时把终态任务（`completed`/`failed`/`cancelled`）**re-arm 为 `enabled`**--否则 `claim_due_tasks` 只认 `enabled` 会沉默不触发（用户改了规格显然想重新调度）。
- **`delete`**：软删除或硬删除任务行（取决于仓储实现）。删除前可检查是否有在途 run（若有则 409 拒绝或先 cancel）。
- **`runs` 端点**：返回某任务的运行历史（`task_run` 行列表），按 `created_at` 倒序，前端 `useScheduledTaskRuns` 15s 轮询消费。

> 关联：创建/patch 校验用的纯计算见 [schedules-calc.md](./schedules-calc.md)；手动触发委托的 dispatch_task 见 [scheduler-service.md](./scheduler-service.md) §2；端到端位置见 [[e2e-request-lifecycle]] ①入站-scheduler。
