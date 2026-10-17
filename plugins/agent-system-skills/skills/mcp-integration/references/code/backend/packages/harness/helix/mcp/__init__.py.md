# `backend/packages/harness/helix/mcp/__init__.py`

> 逐字复制的真实源码（21 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""MCP (Model Context Protocol) integration using langchain-mcp-adapters."""

from .cache import (
    get_cached_mcp_tools,
    initialize_mcp_tools,
    publish_mcp_tools_cache_reset,
    reset_mcp_tools_cache,
)
from .client import build_server_params, build_servers_config
from .tools import get_mcp_tools

__all__ = [
    "build_server_params",
    "build_servers_config",
    "get_mcp_tools",
    "initialize_mcp_tools",
    "get_cached_mcp_tools",
    "publish_mcp_tools_cache_reset",
    "reset_mcp_tools_cache",
]
```
