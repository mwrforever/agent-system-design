# `backend/packages/harness/helix/config/token_usage_config.py`

> 逐字复制的真实源码（8 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from pydantic import BaseModel, Field


class TokenUsageConfig(BaseModel):
    """Configuration for token usage tracking."""

    enabled: bool = Field(default=True, description="Enable token usage tracking middleware")
```
