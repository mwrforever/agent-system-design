# `backend/packages/harness/helix/skills/skillscan/__init__.py`

> 逐字复制的真实源码（34 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Native deterministic safety scanner for Helix skills."""

from helix.skills.skillscan.models import (
    FindingSeverity,
    RuleSpec,
    ScanResult,
    SecurityFinding,
    StaticScanBlockedError,
    StaticScannerError,
)
from helix.skills.skillscan.orchestrator import (
    RULES,
    enforce_static_scan,
    format_static_findings,
    scan_archive_preflight,
    scan_skill_dir,
    skill_scan_enabled,
)

__all__ = [
    "RULES",
    "FindingSeverity",
    "RuleSpec",
    "ScanResult",
    "SecurityFinding",
    "StaticScanBlockedError",
    "StaticScannerError",
    "enforce_static_scan",
    "format_static_findings",
    "scan_archive_preflight",
    "scan_skill_dir",
    "skill_scan_enabled",
]
```
