# 完整源码：cron/once 下次触发纯计算

> 本文件给出调度计算的**完整实现**：`schedules.py`。它是**纯函数、无副作用**模块--只做"给定调度规格 + 当前时刻，算出下次触发时刻"，不碰数据库、不认领任务、不发起 run。
>
> 纯计算与 poller（`scheduler/scheduler/service.py`，见 [scheduler-service.md](./scheduler-service.md)）刻意分离：计算可在路由层（创建/更新任务时校验规格合法、预演 `next_run_at`）、poller 层（认领后推算下一轮）、前端（`cron.ts` 本地预演）三处复用，且单测无需 mock 任何 IO。
>
> 真实实现已按匿名化规则映射到中立结构（框架层 `helix.*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

---

## 设计要点：为什么是纯函数

1. **无副作用**：`next_run_at` 只读入参、只返回 `datetime | None`，不写 DB、不调外部服务。这让它在路由校验路径（创建任务前预演一次，确认规格合法且 `once` 在未来）与 poller 推进路径（认领后算下一轮 `next_run_at`）复用同一份逻辑，行为必然一致。
2. **`once` 返回 `None` 表示已过期**：单次任务的 `run_at` 若已过去，`next_run_at` 返回 `None`。调用方（路由层）据此拒绝创建"已过期的 once"，poller 的 `claim_due_tasks` 也不会再认领它。
3. **时区显式化**：`run_at` 若是 naive datetime（无 tzinfo），按"任务声明时区的墙上时间"解释（与 cron 一致）；cron 在任务时区本地算下次，再转回 UTC 返回。所有返回值都是 aware datetime。
4. **cron 五字段强校验**：`normalize_cron_expression` 拆分后必须恰好 5 段，否则 `ValueError`。这把"用户随手填的 cron"在入口处规整，poller 与路由拿到的永远是规范化后的表达式。

---

## 完整源码

```python
# core/helix/scheduler/schedules.py
from __future__ import annotations

from datetime import UTC, datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from croniter import croniter


def validate_timezone(timezone_name: str) -> str:
    """校验时区名合法（IANA 时区），非法抛 ValueError。

    在路由创建/更新任务时调用，把"未知时区"挡在入库前，而不是等 poller
    认领时才崩。返回原值便于链式调用。
    """
    try:
        ZoneInfo(timezone_name)
    except ZoneInfoNotFoundError as exc:
        raise ValueError(f"Unknown timezone: {timezone_name}") from exc
    return timezone_name


def normalize_cron_expression(expr: str) -> str:
    """规整 cron 表达式：按空白拆分、丢弃空段、必须恰好 5 字段。

    5 字段标准 cron（分 时 日 月 周）。段数不对抛 ValueError，让路由层
    返回 422 而非把畸形表达式存进库。
    """
    parts = [part for part in expr.split() if part]
    if len(parts) != 5:
        raise ValueError("Cron expression must contain exactly 5 fields")
    return " ".join(parts)


def next_run_at(
    schedule_type: str,
    schedule_spec: dict[str, object],
    timezone_name: str,
    *,
    now: datetime,
) -> datetime | None:
    """计算下次触发时刻（纯函数，无副作用）。

    参数：
      schedule_type: "once" 或 "cron"（其余抛 ValueError）。
      schedule_spec: 调度规格--
        once: {"run_at": "<ISO 8601 字符串>"}（naive 视为任务时区墙上时间）。
        cron: {"cron": "<5 字段 cron>"}。
      timezone_name: IANA 时区名（如 "Asia/Shanghai"），先经 validate_timezone。
      now: 当前时刻；naive 时补 UTC。

    返回：
      aware datetime（下次触发时刻）；once 且 run_at 已过去时返回 None
      （表示这一次不会再触发）。
    """
    validate_timezone(timezone_name)
    if now.tzinfo is None:
        now = now.replace(tzinfo=UTC)

    if schedule_type == "once":
        run_at_raw = schedule_spec.get("run_at")
        if not isinstance(run_at_raw, str):
            raise ValueError("once schedule requires run_at")
        run_at = datetime.fromisoformat(run_at_raw)
        if run_at.tzinfo is None:
            # naive run_at 表示"任务声明时区的墙上时间"，与 cron 的解释方式一致
            run_at = run_at.replace(tzinfo=ZoneInfo(timezone_name))
        # 已过去的 once：返回 None，调用方据此判定"不会再触发"
        return run_at if run_at > now else None

    if schedule_type == "cron":
        cron_expr = normalize_cron_expression(str(schedule_spec.get("cron", "")))
        zone = ZoneInfo(timezone_name)
        local_now = now.astimezone(zone)
        next_local = croniter(cron_expr, local_now).get_next(datetime)
        if next_local.tzinfo is None:
            next_local = next_local.replace(tzinfo=zone)
        # 统一以 UTC 返回，poller 与路由都用 UTC 比较
        return next_local.astimezone(UTC)

    raise ValueError(f"Unsupported schedule_type: {schedule_type}")
```

---

## 复用点

| 调用方 | 用途 | 行为 |
|---|---|---|
| 路由 `create_scheduled_task` | 创建前预演：校验规格合法 + `once` 在未来 + 满足 `min_once_delay_seconds` | 预演 `None` 或太近 -> 422 拒绝 |
| 路由 `update_scheduled_task` | 改规格后重算 `next_run_at`，并把终态任务（completed/failed/cancelled）re-arm 为 enabled | 见路由四件套 |
| `ScheduledTaskService.dispatch_task` | 认领并发起 run 后，推算下一轮 `next_run_at` 写回任务行 | once 任务此时不再推进 `next_run_at`（它已被消费） |
| `ScheduledTaskService._finalize_skip` | overlap skip 后推算下一轮，避免 skip 掉这一次就永久停摆 | cron 继续、once 标 failed |
| 前端 `cron.ts` | 本地预演/描述调度（`describeSchedule`），不依赖后端往返 | 仅展示用，不参与调度决策 |

---

## 与 poller 的边界

`schedules.py` **只算时刻**，不决定"该不该认领"。"该不该认领"由 `claim_due_tasks`（仓储层，`now >= next_run_at AND status='enabled'`）+ lease 并发限流决定。这层分离保证：

- 计算逻辑可独立单测（喂入 `(schedule_type, schedule_spec, timezone, now)`，断言返回值），无需起 DB。
- poller 的认领条件改了（如加 lease、加 `max_concurrent_runs` 预算），计算逻辑不变。
- 路由层的"创建时校验"与 poller 的"认领后推进"用**同一个** `next_run_at`，不会出现"创建时算的未来时刻"与"poller 算的不一致"导致任务永远不触发或提前触发。

> 关联：poller 全貌见 [scheduler-service.md](./scheduler-service.md)；non_interactive 剥离链路见 [non-interactive-stripping.md](./non-interactive-stripping.md)；端到端位置见 [[e2e-request-lifecycle]] ①入站-scheduler。
