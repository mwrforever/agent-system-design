# `backend/packages/harness/helix/projects/__init__.py`

> 逐字复制的真实源码（26 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Project runtime integration — run-start pinned context and request rendering."""

from __future__ import annotations

from helix.projects.context import (
    PROJECT_CONTEXT_MESSAGE_ID_PREFIX,
    PROJECT_CONTEXT_MESSAGE_MARKER,
    build_project_context_message,
    is_project_context_message,
    pinned_project_snapshot,
    project_context_insertion_index,
    render_project_block,
    resolve_project_context,
)

__all__ = [
    "PROJECT_CONTEXT_MESSAGE_ID_PREFIX",
    "PROJECT_CONTEXT_MESSAGE_MARKER",
    "build_project_context_message",
    "is_project_context_message",
    "pinned_project_snapshot",
    "project_context_insertion_index",
    "render_project_block",
    "resolve_project_context",
]
```
