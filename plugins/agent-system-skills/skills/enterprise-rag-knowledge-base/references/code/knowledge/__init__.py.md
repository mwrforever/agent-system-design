# `knowledge/__init__.py`

> 逐字复制的真实源码（33 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Read-only knowledge contracts with optional catalog and filter capabilities."""

from .contract import (
    KnowledgeCapabilities,
    KnowledgeRequestContext,
    KnowledgeSource,
    RetrievalCatalogItem,
    RetrievalCatalogPage,
    RetrievalCatalogProvider,
    RetrievalDocumentsProvider,
    RetrievalHit,
    RetrievalProvider,
    RetrievalResult,
    ScopedRetrievalProvider,
)
from .sources import format_result, sources_from_messages

__all__ = [
    "KnowledgeCapabilities",
    "KnowledgeRequestContext",
    "KnowledgeSource",
    "RetrievalCatalogItem",
    "RetrievalCatalogPage",
    "RetrievalCatalogProvider",
    "RetrievalDocumentsProvider",
    "RetrievalHit",
    "RetrievalProvider",
    "RetrievalResult",
    "ScopedRetrievalProvider",
    "format_result",
    "sources_from_messages",
]
```
