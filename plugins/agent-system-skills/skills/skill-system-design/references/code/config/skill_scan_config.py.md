# `config/skill_scan_config.py`

> 逐字复制的真实源码（13 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Configuration for native skill safety scanning."""

from pydantic import BaseModel, Field


class SkillScanConfig(BaseModel):
    """Configuration for deterministic SkillScan analyzers."""

    enabled: bool = Field(
        default=True,
        description="Whether native deterministic SkillScan analyzers run before the LLM skill scanner.",
    )
```
