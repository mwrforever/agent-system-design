# `storage/backends/__init__.py`

> 逐字复制的真实源码（14 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Pluggable blob store backends.

Each subpackage is a self-contained backend that exposes
``STORE_CLASS`` (a :class:`~helix.storage.contract.BlobStore`
subclass) in its ``__init__``. The drop-in contract: folder name ==
backend name == ``BlobStorageConfig.backend`` value.

Add a new backend by dropping a new folder here and setting
``blob_storage.backend: <name>`` -- no other helix code changes.
The depth (layout, publish rules, portability, dotted-path escape hatch)
is owned by ``../AGENTS.md``; the retention/GC interaction lives in
``docs/blob-storage.md``.
"""
```
