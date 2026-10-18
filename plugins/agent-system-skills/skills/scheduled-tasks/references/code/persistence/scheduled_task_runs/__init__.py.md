# `persistence/scheduled_task_runs/__init__.py`

> 逐字复制的真实源码（10 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from .model import ScheduledTaskRunRow
from .sql import ActiveScheduledRunConflict, ScheduledTaskAdmissionRejected, ScheduledTaskRunRepository

__all__ = [
    "ActiveScheduledRunConflict",
    "ScheduledTaskAdmissionRejected",
    "ScheduledTaskRunRow",
    "ScheduledTaskRunRepository",
]
```
