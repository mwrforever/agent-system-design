# `backend/packages/harness/helix/persistence/__init__.py`

> 逐字复制的真实源码（14 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Helix application persistence layer (SQLAlchemy 2.0 async ORM).

This module manages Helix's own application data -- runs metadata,
thread ownership, cron jobs, users. It is completely separate from
LangGraph's checkpointer, which manages graph execution state.

Usage:
    from helix.persistence import init_engine, close_engine, get_session_factory
"""

from helix.persistence.engine import close_engine, get_engine, get_session_factory, init_engine

__all__ = ["close_engine", "get_engine", "get_session_factory", "init_engine"]
```
