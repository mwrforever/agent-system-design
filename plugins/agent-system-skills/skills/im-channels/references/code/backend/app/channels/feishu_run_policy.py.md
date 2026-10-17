# `backend/app/channels/feishu_run_policy.py`

> 逐字复制的真实源码（16 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Per-run policy registration for the Feishu channel."""

from __future__ import annotations

from app.channels.run_policy import CHANNEL_RUN_POLICY, ChannelRunPolicy


def register_policy() -> None:
    """Register Feishu's queue-same-thread behavior in the shared policy map."""
    CHANNEL_RUN_POLICY["feishu"] = ChannelRunPolicy(
        serialize_thread_runs=True,
    )


register_policy()
```
