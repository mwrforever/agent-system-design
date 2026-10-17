# `backend/packages/harness/helix/sandbox/overwrite.py`

> 逐字复制的真实源码（22 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Helpers for ``langgraph.types.Overwrite``-wrapped channel values."""

from langgraph.types import Overwrite


def unwrap_sandbox(sandbox: object) -> tuple[object, bool]:
    """Unwrap an ``Overwrite``-wrapped sandbox channel value, if present.

    Fork-restored checkpoints can deliver the sandbox channel still wrapped in
    ``langgraph.types.Overwrite`` (the rollback restore applies replace-style
    writes through a state-mutation graph in delta checkpoint mode). Reading
    ``sandbox["sandbox_id"]`` or ``sandbox.get("sandbox_id")`` on the wrapper
    itself crashes, so unwrap before use.

    Returns ``(value, fork_restored)``. The wrapped form replays the parent
    thread's sandbox state, so callers must not treat the sandbox as owned by
    this run (e.g. release it).
    """
    if isinstance(sandbox, Overwrite):
        return sandbox.value, True
    return sandbox, False
```
