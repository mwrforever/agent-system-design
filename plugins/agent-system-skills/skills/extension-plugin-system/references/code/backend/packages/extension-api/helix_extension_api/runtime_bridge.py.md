# `backend/packages/extension-api/helix_extension_api/runtime_bridge.py`

> 逐字复制的真实源码（26 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Bridge between LangGraph's runtime context and the task-scoped store.

Middlewares run inside the agent graph and can only reach host state through
``request.runtime``. The host installs the task store under a host-owned key;
extensions read it through this helper and keep their own objects *inside* the
store, so two extensions cannot collide on a runtime-context key.
"""

from __future__ import annotations

from collections.abc import Mapping

from helix_extension_api.state import ExtensionData

#: Host-owned key. Extensions must not write to the runtime context directly.
EXTENSION_TASK_STORE_KEY = "__helix_extension_task_store"


def task_store_from_runtime(runtime: object) -> ExtensionData | None:
    """Return the task-scoped store, or None when there is no live task."""
    context = getattr(runtime, "context", None)
    if not isinstance(context, Mapping):
        return None
    store = context.get(EXTENSION_TASK_STORE_KEY)
    return store if isinstance(store, ExtensionData) else None
```
