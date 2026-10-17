# `backend/packages/harness/helix/persistence/projects/__init__.py`

> 逐字复制的真实源码（9 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Project persistence — ORM models and SQL repositories."""

from __future__ import annotations

from helix.persistence.projects.model import ProjectDocumentRow, ProjectRow
from helix.persistence.projects.sql import ProjectDocumentRepository, ProjectNotAssignableError, ProjectRepository

__all__ = ["ProjectDocumentRepository", "ProjectDocumentRow", "ProjectNotAssignableError", "ProjectRepository", "ProjectRow"]
```
