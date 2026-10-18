# `config/knowledge_base_config.py`

> 逐字复制的真实源码（16 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from pydantic import BaseModel, ConfigDict, Field


class KnowledgeBaseConfig(BaseModel):
    """Hot-reloadable Helix knowledge capability settings.

    Provider connection and retrieval options belong to the provider tool
    entry (for example ``tools[].use: ...ragflow...``), not this generic
    capability block.
    """

    model_config = ConfigDict(validate_default=True)

    enabled: bool = Field(default=False)
    scope_selection_enabled: bool = Field(default=False)
```
