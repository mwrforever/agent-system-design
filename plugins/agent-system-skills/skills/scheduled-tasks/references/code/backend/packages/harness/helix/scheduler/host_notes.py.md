# `backend/packages/harness/helix/scheduler/host_notes.py`

> 逐字复制的真实源码（19 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Host-written scheduled-run error notes.

The scheduler writes these values to ``scheduled_task_runs.error`` (and, for
some, ``scheduled_tasks.last_error``). The tasks page translates them instead
of showing the raw English, so ``contracts/scheduled_goal_notes_contract.json``
pins every value under ``host_run_errors``. Changing one needs a frontend
change in the same pull request; existing rows keep the old value.
"""

from typing import Final

RUN_ERROR_RESTARTED: Final[str] = "interrupted: gateway restarted before the run reached a terminal state"
RUN_ERROR_LEASE_LOST: Final[str] = "interrupted: the owning gateway stopped renewing its run lease"
RUN_ERROR_QUEUE_TIMEOUT: Final[str] = "scheduled task queue wait timeout exceeded"
RUN_ERROR_PAUSED_WHILE_QUEUED: Final[str] = "scheduled task was paused while queued"
RUN_ERROR_DELETED_WHILE_QUEUED: Final[str] = "scheduled task was deleted while queued"
RUN_ERROR_END_REACHED: Final[str] = "schedule end condition reached"
RUN_ERROR_INTERRUPTED: Final[str] = "run was interrupted before completion"
```
