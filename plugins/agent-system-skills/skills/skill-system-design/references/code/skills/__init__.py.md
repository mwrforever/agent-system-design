# `skills/__init__.py`

> 逐字复制的真实源码（24 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from __future__ import annotations

from .catalog import SkillCatalog
from .describe import SkillSearchSetup, build_describe_skill_tool, build_skill_search_setup
from .installer import SkillAlreadyExistsError, SkillSecurityScanError
from .storage import LocalSkillStorage, SkillStorage, get_or_new_skill_storage
from .types import Skill
from .validation import ALLOWED_FRONTMATTER_PROPERTIES, _validate_skill_frontmatter

__all__ = [
    "Skill",
    "SkillCatalog",
    "SkillSearchSetup",
    "build_describe_skill_tool",
    "build_skill_search_setup",
    "ALLOWED_FRONTMATTER_PROPERTIES",
    "_validate_skill_frontmatter",
    "SkillAlreadyExistsError",
    "SkillSecurityScanError",
    "SkillStorage",
    "LocalSkillStorage",
    "get_or_new_skill_storage",
]
```
