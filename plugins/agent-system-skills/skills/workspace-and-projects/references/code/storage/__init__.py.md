# `storage/__init__.py`

> 逐字复制的真实源码（35 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Content-addressed blob store (issue #4189, item 2).

See ``contract.py`` for the interface and ``AGENTS.md`` for how to add a
backend. Nothing in helix writes here until ``blob_storage.enabled`` is
True and a producer has been migrated to the store.
"""

from helix.storage.contract import (
    BlobNotConfiguredError,
    BlobNotFoundError,
    BlobReadError,
    BlobRef,
    BlobStore,
    BlobStoreError,
    BlobWriteError,
    is_valid_blob_kind,
    validate_blob_kind,
)
from helix.storage.manager import get_blob_store, get_blob_store_if_enabled, reset_blob_store

__all__ = [
    "BlobNotFoundError",
    "BlobNotConfiguredError",
    "BlobReadError",
    "BlobRef",
    "BlobStore",
    "BlobStoreError",
    "BlobWriteError",
    "get_blob_store",
    "get_blob_store_if_enabled",
    "is_valid_blob_kind",
    "reset_blob_store",
    "validate_blob_kind",
]
```
