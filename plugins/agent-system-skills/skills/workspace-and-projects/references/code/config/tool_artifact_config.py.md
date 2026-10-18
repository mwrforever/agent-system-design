# `config/tool_artifact_config.py`

> 逐字复制的真实源码（39 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Configuration for the persistent artifact handle registry (issue #4676)."""

from __future__ import annotations

from pydantic import BaseModel, Field


class ToolArtifactConfig(BaseModel):
    """Config section for tool-artifact capture and handle resolution.

    When enabled, artifact references from tool results are captured into
    ``ThreadState.tool_artifacts`` so they survive context compaction. The model
    references artifacts by short handles (``art_xxxxxxxx``) that are resolved to
    real references at tool-call time.
    """

    enabled: bool = Field(
        default=True,
        description="Enable tool-artifact capture and handle resolution.",
    )
    max_entries: int = Field(
        default=100,
        ge=10,
        le=1000,
        description="Maximum artifact entries retained per thread.",
    )
    detect_refs_in_text: bool = Field(
        default=True,
        description="Conservatively scan free text tool results for sandbox paths and remote file URLs.",
    )
    inject_model_context: bool = Field(
        default=True,
        description="Project available artifact handles into the model request as durable context.",
    )
    resolve_handles_in_args: bool = Field(
        default=True,
        description="Resolve artifact handles found in tool arguments to their real references before execution.",
    )
```
