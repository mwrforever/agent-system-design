# `skills/permissions.py`

> 逐字复制的真实源码（35 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Filesystem permission helpers for installed skill trees."""

import stat
from pathlib import Path


def make_skill_path_sandbox_readable(path: Path) -> None:
    if path.is_symlink():
        return
    mode = stat.S_IMODE(path.stat().st_mode)
    without_sandbox_write = mode & ~(stat.S_IWGRP | stat.S_IWOTH)
    if path.is_dir():
        path.chmod(without_sandbox_write | 0o555)
    elif path.is_file():
        path.chmod(without_sandbox_write | 0o444)


def make_skill_tree_sandbox_readable(target: Path) -> None:
    make_skill_path_sandbox_readable(target)
    for path in target.rglob("*"):
        make_skill_path_sandbox_readable(path)


def make_skill_written_path_sandbox_readable(skill_root: Path, target: Path) -> None:
    resolved_root = skill_root.resolve()
    resolved_target = target.resolve()
    resolved_target.relative_to(resolved_root)

    make_skill_path_sandbox_readable(resolved_root)
    current = resolved_root
    for part in resolved_target.parent.relative_to(resolved_root).parts:
        current = current / part
        make_skill_path_sandbox_readable(current)
    make_skill_path_sandbox_readable(resolved_target)
```
