# `persistence/notification_deliveries/__init__.py`

> 逐字复制的真实源码（10 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Scheduled-task notification delivery outbox persistence (issue #4254)."""

from helix.persistence.notification_deliveries.model import NotificationDeliveryRow
from helix.persistence.notification_deliveries.sql import NotificationDeliveryRepository

__all__ = [
    "NotificationDeliveryRepository",
    "NotificationDeliveryRow",
]
```
