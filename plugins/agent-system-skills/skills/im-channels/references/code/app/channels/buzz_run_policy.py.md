# `app/channels/buzz_run_policy.py`

> 逐字复制的真实源码（13 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Run-policy registration for the Buzz channel (imported for side effect from manager.py)."""

from app.channels.run_policy import CHANNEL_RUN_POLICY, ChannelRunPolicy


def register_policy() -> None:
    # Same-thread follow-ups queue instead of tripping the busy reply (Feishu precedent);
    # the adapter-level pubkey allowlist is the identity gate, so no bound identity needed.
    CHANNEL_RUN_POLICY["buzz"] = ChannelRunPolicy(serialize_thread_runs=True, requires_bound_identity=False)


register_policy()
```
