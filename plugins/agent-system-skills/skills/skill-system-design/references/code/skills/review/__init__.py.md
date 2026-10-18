# `skills/review/__init__.py`

> 逐字复制的真实源码（25 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Deterministic skill review core."""

from helix.skills.review.analyzer import analyze_skill_package
from helix.skills.review.models import (
    DEFAULT_PACKAGE_LIMITS,
    FACTS_SCHEMA_VERSION,
    PACKAGE_SNAPSHOT_SCHEMA_VERSION,
    REPORT_SCHEMA_VERSION,
    PackageLimits,
    stable_json_dumps,
)
from helix.skills.review.readers import LocalDirectoryReader, build_inline_snapshot

__all__ = [
    "DEFAULT_PACKAGE_LIMITS",
    "FACTS_SCHEMA_VERSION",
    "PACKAGE_SNAPSHOT_SCHEMA_VERSION",
    "REPORT_SCHEMA_VERSION",
    "LocalDirectoryReader",
    "PackageLimits",
    "analyze_skill_package",
    "build_inline_snapshot",
    "stable_json_dumps",
]
```
