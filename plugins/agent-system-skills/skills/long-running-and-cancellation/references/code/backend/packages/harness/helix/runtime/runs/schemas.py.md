# `backend/packages/harness/helix/runtime/runs/schemas.py`

> 逐字复制的真实源码（33 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Run status and disconnect mode enums."""

from enum import StrEnum


class ThreadOperationKind(StrEnum):
    """Kind of operation holding exclusive admission for a thread."""

    run = "run"
    checkpoint_write = "checkpoint_write"
    artifact_write = "artifact_write"
    artifact_archive = "artifact_archive"
    branch = "branch"
    delete = "delete"


class RunStatus(StrEnum):
    """Lifecycle status of a single run."""

    pending = "pending"
    running = "running"
    success = "success"
    error = "error"
    timeout = "timeout"
    interrupted = "interrupted"


class DisconnectMode(StrEnum):
    """Behaviour when the SSE consumer disconnects."""

    cancel = "cancel"
    continue_ = "continue"
```
