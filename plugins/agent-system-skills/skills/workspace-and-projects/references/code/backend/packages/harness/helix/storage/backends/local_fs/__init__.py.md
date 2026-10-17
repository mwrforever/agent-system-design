# `backend/packages/harness/helix/storage/backends/local_fs/__init__.py`

> 逐字复制的真实源码（14 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""local_fs backend -- the default blob store (content-addressed files).

Holds the store class (:mod:`local_fs_store`): content-addressed files under
``<root>/<kind>/<sha256[:2]>/<sha256>`` plus a JSON sidecar carrying what the
bytes cannot say, published atomically and verified on read.
"""

from .local_fs_store import LocalFsBlobStore

#: The :class:`~helix.storage.contract.BlobStore` subclass this
#: backend exposes. Discovered by the factory's ``_scan_backends`` drop-in
#: mechanism under the folder name ``local_fs``.
STORE_CLASS = LocalFsBlobStore
```
