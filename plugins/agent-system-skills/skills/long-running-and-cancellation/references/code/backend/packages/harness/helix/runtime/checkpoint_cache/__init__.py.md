# `backend/packages/harness/helix/runtime/checkpoint_cache/__init__.py`

> 逐字复制的真实源码（20 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Checkpoint delta-history cache backends (delta mode only)."""

from helix.runtime.checkpoint_cache.base import (
    CACHE_FORMAT_VERSION,
    CheckpointCacheStats,
    CheckpointHistoryCache,
    SyncCheckpointHistoryCache,
    make_history_key,
)
from helix.runtime.checkpoint_cache.memory import MemoryCheckpointHistoryCache

__all__ = [
    "CACHE_FORMAT_VERSION",
    "CheckpointCacheStats",
    "CheckpointHistoryCache",
    "MemoryCheckpointHistoryCache",
    "SyncCheckpointHistoryCache",
    "make_history_key",
]
```
