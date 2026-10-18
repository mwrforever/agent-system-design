# `agents/goal_state.py`

> 逐字复制的真实源码（47 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from __future__ import annotations

from typing import Any, Literal, NotRequired, TypedDict

GoalBlocker = Literal[
    "none",
    "missing_evidence",
    "needs_user_input",
    "run_failed",
    "external_wait",
    "goal_not_met_yet",
]


class GoalEvaluation(TypedDict):
    satisfied: bool
    blocker: GoalBlocker
    reason: str
    evidence_summary: NotRequired[str]
    relied_on_assumption: NotRequired[bool]


class GoalState(TypedDict):
    objective: str
    status: Literal["active"]
    created_at: str
    updated_at: str
    continuation_count: int
    max_continuations: int
    no_progress_count: int
    max_no_progress_continuations: int
    last_evaluation: NotRequired[dict[str, Any]]


class GoalOutcomeState(TypedDict):
    """The latest met goal, written only by the checkpoint write that clears it."""

    status: Literal["achieved"]
    objective: str
    goal_created_at: str
    achieved_at: str
    continuation_count: int
    max_continuations: int
    reason: str
    relied_on_assumption: bool
    reply_message_id: str | None
```
