# `backend/packages/harness/helix/config/runtime_paths.py`

> 逐字复制的真实源码（42 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Runtime path resolution for standalone harness usage."""

import os
from pathlib import Path


def project_root() -> Path:
    """Return the caller project root for runtime-owned files."""
    if env_root := os.getenv("HELIX_PROJECT_ROOT"):
        root = Path(env_root).resolve()
        if not root.exists():
            raise ValueError(f"HELIX_PROJECT_ROOT is set to '{env_root}', but the resolved path '{root}' does not exist.")
        if not root.is_dir():
            raise ValueError(f"HELIX_PROJECT_ROOT is set to '{env_root}', but the resolved path '{root}' is not a directory.")
        return root
    return Path.cwd().resolve()


def runtime_home() -> Path:
    """Return the writable Helix state directory."""
    if env_home := os.getenv("HELIX_HOME"):
        return Path(env_home).resolve()
    return project_root() / ".helix"


def resolve_path(value: str | os.PathLike[str], *, base: Path | None = None) -> Path:
    """Resolve absolute paths as-is and relative paths against the project root."""
    path = Path(value)
    if not path.is_absolute():
        path = (base or project_root()) / path
    return path.resolve()


def existing_project_file(names: tuple[str, ...]) -> Path | None:
    """Return the first existing named file under the project root."""
    root = project_root()
    for name in names:
        candidate = root / name
        if candidate.is_file():
            return candidate
    return None
```
