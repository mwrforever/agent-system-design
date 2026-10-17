# `backend/packages/harness/helix/agents/memory/backends/mem0/__init__.py`

> 逐字复制的真实源码（10 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""mem0 memory backend -- HTTP client against the mem0 Platform API.

Drop-in contract: folder name == backend name == ``manager_class: mem0``.
"""

from .mem0_manager import Mem0Manager

#: Discovered by the factory's ``_scan_backends`` under the folder name ``mem0``.
MANAGER_CLASS = Mem0Manager
```
