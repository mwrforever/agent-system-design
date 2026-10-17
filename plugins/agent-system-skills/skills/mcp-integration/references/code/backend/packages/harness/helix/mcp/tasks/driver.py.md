# `backend/packages/harness/helix/mcp/tasks/driver.py`

> 逐字复制的真实源码（37 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from __future__ import annotations

from typing import Protocol

from helix.mcp.tasks.models import TaskReference, TaskSnapshot, TaskSubmission, TaskSubmitRequest


class McpTaskDriver(Protocol):
    """Transport/protocol adapter used by the protocol-neutral task runtime."""

    async def submit(self, request: TaskSubmitRequest) -> TaskSubmission: ...

    async def get_status(self, task: TaskReference) -> TaskSnapshot: ...

    async def cancel(self, task: TaskReference) -> TaskSnapshot: ...


class McpTaskDriverRegistry:
    """Process-local driver catalog wired at Gateway startup."""

    def __init__(self) -> None:
        self._drivers: dict[str, McpTaskDriver] = {}

    def register(self, name: str, driver: McpTaskDriver) -> None:
        normalized = name.strip()
        if not normalized:
            raise ValueError("driver name must not be empty")
        if normalized in self._drivers:
            raise ValueError(f"MCP task driver {normalized!r} is already registered")
        self._drivers[normalized] = driver

    def get(self, name: str) -> McpTaskDriver | None:
        return self._drivers.get(name)

    def names(self) -> tuple[str, ...]:
        return tuple(sorted(self._drivers))
```
