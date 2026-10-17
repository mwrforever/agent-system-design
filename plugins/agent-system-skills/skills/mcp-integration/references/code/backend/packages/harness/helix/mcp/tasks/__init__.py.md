# `backend/packages/harness/helix/mcp/tasks/__init__.py`

> 逐字复制的真实源码（33 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from helix.mcp.tasks.driver import McpTaskDriver, McpTaskDriverRegistry
from helix.mcp.tasks.models import (
    ATTENTION_TASK_STATUSES,
    POLLABLE_TASK_STATUSES,
    TERMINAL_TASK_STATUSES,
    TaskReference,
    TaskSnapshot,
    TaskStatus,
    TaskSubmission,
    TaskSubmitRequest,
)
from helix.mcp.tasks.ordinary import (
    ORDINARY_MCP_TASK_DRIVER,
    McpTaskProtocolError,
    OrdinaryMcpTaskDriver,
)

__all__ = [
    "ATTENTION_TASK_STATUSES",
    "McpTaskDriver",
    "McpTaskDriverRegistry",
    "POLLABLE_TASK_STATUSES",
    "TERMINAL_TASK_STATUSES",
    "TaskReference",
    "TaskSnapshot",
    "TaskStatus",
    "TaskSubmission",
    "TaskSubmitRequest",
    "ORDINARY_MCP_TASK_DRIVER",
    "McpTaskProtocolError",
    "OrdinaryMcpTaskDriver",
]
```
