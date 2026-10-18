# `agents/memory/backends/helixmem/__init__.py`

> 逐字复制的真实源码（15 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""HelixMem backend -- the default memory manager (self-contained).

Holds its own manager class (:mod:`helix_mem`) plus a ``core/`` folder with
the five functional modules (storage / queue / updater / prompt /
message_processing). All HelixMem-private logic lives here; the shared
package top only carries the contract + factory + thin entry points.
"""

from .helix_mem import HelixMem

#: The :class:`~helix.agents.memory.manager.MemoryManager` subclass this
#: backend exposes. Discovered by the factory's ``_scan_backends`` drop-in
#: mechanism under the folder name ``helixmem``.
MANAGER_CLASS = HelixMem
```
