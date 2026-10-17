# `backend/packages/harness/helix/config/skill_evolution_config.py`

> 逐字复制的真实源码（19 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from pydantic import BaseModel, Field


class SkillEvolutionConfig(BaseModel):
    """Configuration for agent-managed skill evolution."""

    enabled: bool = Field(
        default=False,
        description="Whether the agent can create and modify skills under skills/custom.",
    )
    moderation_model_name: str | None = Field(
        default=None,
        description="Optional model name for skill security moderation. Defaults to the primary chat model.",
    )
    security_fail_closed: bool = Field(
        default=True,
        description=("When the moderation model is unavailable, block skill writes if True (fail-closed). If False, non-executable content is allowed with a warning while executable content is still blocked."),
    )
```
