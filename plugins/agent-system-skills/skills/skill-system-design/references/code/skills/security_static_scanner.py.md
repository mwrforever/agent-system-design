# `skills/security_static_scanner.py`

> 逐字复制的真实源码（26 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Compatibility exports for the native SkillScan implementation."""

from helix.skills.skillscan import (
    SecurityFinding as StaticFinding,
)
from helix.skills.skillscan import (
    StaticScanBlockedError,
    StaticScannerError,
    enforce_static_scan,
    format_static_findings,
    scan_archive_preflight,
    scan_skill_dir,
    skill_scan_enabled,
)

__all__ = [
    "StaticFinding",
    "StaticScanBlockedError",
    "StaticScannerError",
    "enforce_static_scan",
    "format_static_findings",
    "scan_archive_preflight",
    "scan_skill_dir",
    "skill_scan_enabled",
]
```
