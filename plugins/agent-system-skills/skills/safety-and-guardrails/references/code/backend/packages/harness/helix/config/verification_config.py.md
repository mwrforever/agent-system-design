# `backend/packages/harness/helix/config/verification_config.py`

> 逐字复制的真实源码（27 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Configuration for the subagent result-verification layers."""

from typing import Literal

from pydantic import BaseModel, Field


class VerificationConfig(BaseModel):
    """Receipt ledger, acceptance checklist, and selective judge settings."""

    receipts_enabled: bool = Field(
        default=True,
        description="Stamp deterministic tool receipts on every tool result",
    )
    receipts_render_mode: Literal["always", "delegation_only"] = Field(
        default="delegation_only",
        description="Receipt-ledger rendering for the lead chain; subagent chains always render (citations are produced there). 'delegation_only' renders only while processing subagent results",
    )
    judge_enabled: bool = Field(
        default=False,
        description="Run a one-shot small-model review of completed subagent results that carry acceptance criteria",
    )
    judge_model_name: str | None = Field(
        default=None,
        description="Model for the selective judge; falls back to the parent model when unset",
    )
```
