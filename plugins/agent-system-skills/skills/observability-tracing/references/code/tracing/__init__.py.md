# `tracing/__init__.py`

> 逐字复制的真实源码（11 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from .factory import build_tracing_callbacks
from .metadata import build_langfuse_trace_metadata, inject_langfuse_metadata
from .monocle import setup_monocle_tracing_if_enabled

__all__ = [
    "build_langfuse_trace_metadata",
    "build_tracing_callbacks",
    "inject_langfuse_metadata",
    "setup_monocle_tracing_if_enabled",
]
```
