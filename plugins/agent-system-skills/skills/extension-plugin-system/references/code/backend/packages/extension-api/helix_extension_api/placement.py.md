# `backend/packages/extension-api/helix_extension_api/placement.py`

> 逐字复制的真实源码（71 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Where an extension's middleware sits in the host's middleware stack.

Placement is declared as a *semantic guarantee* ("I need to observe the raw
tool return") rather than as a structural position ("put me in layer 3"). A
middleware occupies one index in the list, but that index only has meaning on
the hook chain it actually implements — so "outermost" means different things
on the model axis and the tool axis. Declaring by axis-and-end removes that
ambiguity and keeps the host free to restructure its stack.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Flag, StrEnum, auto
from typing import Any

from helix_extension_api.contracts import HostPolicySnapshot


class Placement(StrEnum):
    MODEL_LOGICAL = "model_logical"
    """Model axis, outer end. Guarantee: outer of retry and error handling.
    Fires once per logical decision regardless of how many times the host
    retries underneath."""

    MODEL_PHYSICAL = "model_physical"
    """Model axis, inner end. Guarantee: inner of every request-transforming
    middleware. Fires once per physical provider call; retries re-enter it."""

    TOOL_VISIBLE = "tool_visible"
    """Tool axis, outer end. Guarantee: outer of truncation, sanitization and
    error wrapping. Observes what the model finally sees."""

    TOOL_RAW = "tool_raw"
    """Tool axis, inner end. Guarantee: adjacent to the real callable
    boundary. Observes the tool's raw return before any processing."""

    STANDARD = "standard"
    """No before/after-processing requirement. Relative order against other
    STANDARD contributors is not guaranteed."""


class AgentScope(Flag):
    LEAD = auto()
    SUBAGENT = auto()
    BOTH = LEAD | SUBAGENT


@dataclass(frozen=True)
class AgentBuildContext:
    """What an extension may know while deciding what to contribute."""

    scope: AgentScope
    agent_name: str | None = None
    model_name: str | None = None
    policy: HostPolicySnapshot = field(default_factory=HostPolicySnapshot)


@dataclass(frozen=True)
class MiddlewarePlacement:
    """One middleware plus where it needs to sit.

    ``middleware`` is typed ``Any`` rather than ``AgentMiddleware`` so this
    module stays import-light; the host validates the type at injection time.
    """

    middleware: Any
    placement: Placement
    scope: AgentScope = AgentScope.BOTH
    order: int = 0
```
