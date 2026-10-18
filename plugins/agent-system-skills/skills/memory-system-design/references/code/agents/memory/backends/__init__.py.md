# `agents/memory/backends/__init__.py`

> 逐字复制的真实源码（11 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Pluggable memory backends.

Each subpackage is a self-contained backend that exposes
``MANAGER_CLASS`` (a :class:`~helix.agents.memory.manager.MemoryManager`
subclass) in its ``__init__``. The drop-in contract: folder name ==
backend name == ``MemoryConfig.manager_class`` value.

Add a new backend by dropping a new folder here and setting
``manager_class: <name>`` -- no other helix code changes.
"""
```
