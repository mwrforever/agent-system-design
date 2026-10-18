# `persistence/channel_leases/__init__.py`

> 逐字复制的真实源码（21 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Per-provider IM transport leader lease shared by every Gateway instance (``channels.leader_lease``)."""

from helix.persistence.channel_leases.model import (
    CHANNEL_LEASE_OWNER_LENGTH,
    CHANNEL_LEASE_PROVIDER_LENGTH,
    ChannelLeaseGrant,
    ChannelLeaseRow,
    ChannelLeaseState,
)
from helix.persistence.channel_leases.sql import SqlChannelLeaseRepository, db_now

__all__ = [
    "CHANNEL_LEASE_OWNER_LENGTH",
    "CHANNEL_LEASE_PROVIDER_LENGTH",
    "ChannelLeaseGrant",
    "ChannelLeaseRow",
    "ChannelLeaseState",
    "SqlChannelLeaseRepository",
    "db_now",
]
```
