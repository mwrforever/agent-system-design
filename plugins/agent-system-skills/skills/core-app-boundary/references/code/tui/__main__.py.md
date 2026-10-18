# `tui/__main__.py`

> 逐字复制的真实源码（7 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Allow ``python -m helix.tui`` to launch the workbench."""

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
```
