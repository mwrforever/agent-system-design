# `backend/packages/harness/helix/agents/memory/__init__.py`

> 逐字复制的真实源码（36 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Pluggable memory for Helix.

The shared, backend-agnostic core: the :class:`MemoryManager` contract, the
:func:`get_memory_manager` singleton factory, and :func:`reset_memory_manager`.
Backends live under :mod:`backends` (each self-contained, exposing
``MANAGER_CLASS``); the default HelixMem backend's functional modules live in
``backends/helixmem/core/``. Swap backend = drop a ``backends/<name>/`` folder +
set ``MemoryConfig.manager_class`` -- nothing else in helix changes.

HelixMem-private symbols (``format_memory_for_injection``, ``get_memory_data``,
``MemoryUpdater``, ``FileMemoryStorage``, ...) are NOT re-exported here -- import
them directly from ``helix.agents.memory.backends.helixmem.helixmem.core.*``.
"""

from helix.agents.memory.manager import (
    MemoryConflictError,
    MemoryCorruptionError,
    MemoryManager,
    MemoryManagerError,
    MemoryReadError,
    get_memory_manager,
    memory_read_failures_are_fatal,
    reset_memory_manager,
)

__all__ = [
    "MemoryManager",
    "MemoryManagerError",
    "MemoryReadError",
    "MemoryConflictError",
    "MemoryCorruptionError",
    "get_memory_manager",
    "memory_read_failures_are_fatal",
    "reset_memory_manager",
]
```
