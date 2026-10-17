# `backend/packages/harness/helix/persistence/channel_thread_bindings/__init__.py`

> 逐字复制的真实源码（21 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Shared IM chat -> Helix thread bindings (the database successor of ``channels/store.json``)."""

from helix.persistence.channel_thread_bindings.model import (
    BINDING_KEY_LENGTH,
    ChannelThreadBinding,
    ChannelThreadBindingRow,
    binding_key,
    split_binding_key,
)
from helix.persistence.channel_thread_bindings.sql import IMPORT_BATCH_SIZE, SqlChannelThreadBindingRepository

__all__ = [
    "BINDING_KEY_LENGTH",
    "IMPORT_BATCH_SIZE",
    "ChannelThreadBinding",
    "ChannelThreadBindingRow",
    "SqlChannelThreadBindingRepository",
    "binding_key",
    "split_binding_key",
]
```
