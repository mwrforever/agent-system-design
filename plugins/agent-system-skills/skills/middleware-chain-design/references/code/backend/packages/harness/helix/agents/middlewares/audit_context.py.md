# `backend/packages/harness/helix/agents/middlewares/audit_context.py`

> 逐字复制的真实源码（30 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Private runtime-context helpers for narrowly scoped audit recorders."""

from typing import Any

LOOP_DETECTION_RECORDER_CONTEXT_KEY = "__run_loop_detection_recorder"
TOOL_PROMOTION_RECORDER_CONTEXT_KEY = "__run_tool_promotion_recorder"
TOOL_PROGRESS_RECORDER_CONTEXT_KEY = "__run_tool_progress_recorder"


def resolve_audit_recorder(
    context: object,
    *,
    recorder_key: str,
) -> tuple[Any | None, bool, str | None]:
    """Resolve a recorder and trusted lead/subagent attribution.

    Ordinary lead runs own ``__run_journal``. Task-tool subagents receive only
    a server-installed narrow recorder, so its presence is the authority for
    subagent attribution; caller-supplied ``is_subagent`` is never consulted.
    """
    if not isinstance(context, dict):
        return None, False, None

    recorder = context.get(recorder_key)
    if recorder is not None:
        agent_id = context.get("agent_id")
        return recorder, True, agent_id if isinstance(agent_id, str) else None

    return context.get("__run_journal"), False, None
```
