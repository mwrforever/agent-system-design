# `backend/packages/harness/helix/config/run_events_config.py`

> 逐字复制的真实源码（43 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Run event storage configuration.

Controls where run events (messages + execution traces) are persisted.

Backends:
- memory: In-memory storage, data lost on restart. Suitable for
  development and testing.
- db: SQL database via SQLAlchemy ORM. Provides full query capability.
  Suitable for production deployments.
- jsonl: Append-only JSONL files. Lightweight alternative for
  single-node deployments that need persistence without a database.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, ValidationInfo, field_validator

from helix.config._boolean_guards import reject_boolean


class RunEventsConfig(BaseModel):
    backend: Literal["memory", "db", "jsonl"] = Field(
        default="memory",
        description="Storage backend for run events. 'memory' for development (no persistence), 'db' for production (SQL queries), 'jsonl' for lightweight single-node persistence.",
    )
    max_trace_content: int = Field(
        default=10240,
        ge=1,
        description="Maximum trace content size in bytes before truncation (db backend only).",
    )

    @field_validator("max_trace_content", mode="before")
    @classmethod
    def _reject_boolean_max_trace_content(cls, value: object, info: ValidationInfo) -> object:
        return reject_boolean(value, info, kind="an integer")

    track_token_usage: bool = Field(
        default=True,
        description="Whether RunJournal should accumulate token counts to RunRow.",
    )
```
