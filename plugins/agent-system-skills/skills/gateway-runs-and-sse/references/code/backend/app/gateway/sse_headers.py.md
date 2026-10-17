# `backend/app/gateway/sse_headers.py`

> 逐字复制的真实源码（29 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Response headers shared by every Server-Sent Events endpoint.

``no-transform`` tells compressing proxies (for example the Next.js rewrite
proxy used by ``pnpm start``) not to gzip the body. A compressing proxy has to
buffer a stream before it can emit compressed blocks, so without it SSE frames
reach the browser in bursts instead of as they are produced.
``X-Accel-Buffering: no`` does the same for nginx.
"""

from __future__ import annotations

SSE_CACHE_CONTROL = "no-cache, no-transform"


def sse_response_headers(*, content_location: str | None = None) -> dict[str, str]:
    """Return the headers for an SSE streaming response.

    ``content_location`` is set only by the routes that create a run, so the
    LangGraph SDK can read the run id from it.
    """
    headers = {
        "Cache-Control": SSE_CACHE_CONTROL,
        "Connection": "keep-alive",
        "X-Accel-Buffering": "no",
    }
    if content_location is not None:
        headers["Content-Location"] = content_location
    return headers
```
