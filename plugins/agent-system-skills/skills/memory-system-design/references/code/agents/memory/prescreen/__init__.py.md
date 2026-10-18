# `agents/memory/prescreen/__init__.py`

> 逐字复制的真实源码（39 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Memory capture pre-screening: a pluggable, off-by-default cost gate.

The hook lives in the host (this package + the HelixMem updater that calls it),
not in an extension: the extension API's only memory touchpoint is a read-only
post-hoc observer and its contributions are fail-open, which is the wrong shape
for a switch that can affect writes (design §2.6).

See ``backend/docs/MEMORY_IMPROVEMENTS.md`` for the modes and the gates that
must pass before ``enforce``, and ``agents/memory/AGENTS.md`` for the invariants.
"""

from helix.agents.memory.prescreen.contract import (
    CONFIGURATION_SOURCE,
    MODE_ENFORCE,
    MODE_OFF,
    MODE_SHADOW,
    MODES,
    VERDICT_EXTRACT,
    VERDICT_SKIP,
    MemoryPrescreenDecision,
    MemoryPrescreenProvider,
    MemoryPrescreenRequest,
    resolve_memory_prescreen,
)

__all__ = [
    "CONFIGURATION_SOURCE",
    "MODE_ENFORCE",
    "MODE_OFF",
    "MODE_SHADOW",
    "MODES",
    "VERDICT_EXTRACT",
    "VERDICT_SKIP",
    "MemoryPrescreenDecision",
    "MemoryPrescreenProvider",
    "MemoryPrescreenRequest",
    "resolve_memory_prescreen",
]
```
