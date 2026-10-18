# `agents/memory/signals/__init__.py`

> 逐字复制的真实源码（62 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Jev memory signal classification: reinforcement / weakening hints over one batch.

The classifier is a *hint* source and, in one narrow case (pre-screen ``enforce``
× classifier ``hints``), a **veto** over a skip. It never decides extraction, never
drives deletion, and never participates in the reinforcement evidence gate.

The memory-layer coordinator in this package owns request combination and the
combined cache; each adapter keeps its own cache when the sides are not combined.

See ``backend/docs/MEMORY_IMPROVEMENTS.md`` and ``agents/memory/AGENTS.md``.
"""

from helix.agents.memory.signals.contract import (
    COMBINE_ALWAYS,
    COMBINE_AUTO,
    COMBINE_NEVER,
    COMBINES,
    CONFIGURATION_SOURCE,
    LABEL_CORRECTION,
    LABEL_REINFORCEMENT,
    LABELS,
    MODE_HINTS,
    MODE_OFF,
    MODE_SHADOW,
    MODES,
    MemorySignalDecision,
    MemorySignalProvider,
    MemorySignalRequest,
    direction_labels,
    resolve_memory_signal_classifier,
)
from helix.agents.memory.signals.coordinator import (
    MemoryBatchContext,
    MemoryBatchVerdict,
    MemorySignalCoordinator,
    build_memory_judge,
)

__all__ = [
    "COMBINE_ALWAYS",
    "COMBINE_AUTO",
    "COMBINE_NEVER",
    "COMBINES",
    "CONFIGURATION_SOURCE",
    "LABEL_CORRECTION",
    "LABEL_REINFORCEMENT",
    "LABELS",
    "MODE_HINTS",
    "MODE_OFF",
    "MODE_SHADOW",
    "MODES",
    "MemoryBatchContext",
    "MemoryBatchVerdict",
    "MemorySignalCoordinator",
    "MemorySignalDecision",
    "MemorySignalProvider",
    "MemorySignalRequest",
    "build_memory_judge",
    "direction_labels",
    "resolve_memory_signal_classifier",
]
```
