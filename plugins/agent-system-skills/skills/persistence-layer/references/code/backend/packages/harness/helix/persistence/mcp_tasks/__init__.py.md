# `backend/packages/harness/helix/persistence/mcp_tasks/__init__.py`

> 逐字复制的真实源码（14 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from helix.persistence.mcp_tasks.model import McpTaskRow
from helix.persistence.mcp_tasks.sql import (
    DuplicateMcpRemoteTaskError,
    McpTaskRepository,
    McpTaskThreadMismatchError,
)

__all__ = [
    "DuplicateMcpRemoteTaskError",
    "McpTaskRepository",
    "McpTaskRow",
    "McpTaskThreadMismatchError",
]
```
