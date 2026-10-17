# `backend/packages/harness/helix/persistence/thread_meta/__init__.py`

> 逐字复制的真实源码（46 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Thread metadata persistence — ORM, abstract store, and concrete implementations."""

from __future__ import annotations

from typing import TYPE_CHECKING

from helix.persistence.thread_meta.base import PROJECT_FILTER_UNSET, THREAD_ARCHIVED_METADATA_KEY, THREAD_PINNED_METADATA_KEY, THREAD_PROJECT_METADATA_KEY, InvalidMetadataFilterError, ThreadMetaStore, ThreadOwnershipConflictError
from helix.persistence.thread_meta.memory import MemoryThreadMetaStore
from helix.persistence.thread_meta.model import ThreadMetaRow
from helix.persistence.thread_meta.sql import ThreadMetaRepository

if TYPE_CHECKING:
    from langgraph.store.base import BaseStore
    from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

__all__ = [
    "InvalidMetadataFilterError",
    "MemoryThreadMetaStore",
    "PROJECT_FILTER_UNSET",
    "THREAD_PINNED_METADATA_KEY",
    "THREAD_ARCHIVED_METADATA_KEY",
    "THREAD_PINNED_METADATA_KEY",
    "THREAD_PROJECT_METADATA_KEY",
    "ThreadMetaRepository",
    "ThreadMetaRow",
    "ThreadMetaStore",
    "ThreadOwnershipConflictError",
    "make_thread_store",
]


def make_thread_store(
    session_factory: async_sessionmaker[AsyncSession] | None,
    store: BaseStore | None = None,
) -> ThreadMetaStore:
    """Create the appropriate ThreadMetaStore based on available backends.

    Returns a SQL-backed repository when a session factory is available,
    otherwise falls back to the in-memory LangGraph Store implementation.
    """
    if session_factory is not None:
        return ThreadMetaRepository(session_factory)
    if store is None:
        raise ValueError("make_thread_store requires either a session_factory (SQL) or a store (memory)")
    return MemoryThreadMetaStore(store)
```
