# `skills/package_paths.py`

> 逐字复制的真实源码（25 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Shared helpers for skill-package relative paths."""

from __future__ import annotations

from pathlib import PurePosixPath


def _parts(path: str | PurePosixPath) -> tuple[str, ...]:
    return PurePosixPath(str(path).replace("\\", "/")).parts


def is_eval_fixture_path(path: str | PurePosixPath) -> bool:
    """Return whether a path is under an eval fixture directory."""
    parts = _parts(path)
    for index, part in enumerate(parts[:-1]):
        if part == "evals" and len(parts) > index + 2 and parts[index + 1] == "fixtures":
            return True
    return False


def is_eval_fixture_skill_md(path: str | PurePosixPath) -> bool:
    """Return whether a path is an eval fixture's nested SKILL.md file."""
    parts = _parts(path)
    return bool(parts) and parts[-1] == "SKILL.md" and is_eval_fixture_path(PurePosixPath(*parts[:-1]))
```
