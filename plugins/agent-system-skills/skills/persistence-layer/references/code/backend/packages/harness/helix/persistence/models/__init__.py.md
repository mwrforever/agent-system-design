# `backend/packages/harness/helix/persistence/models/__init__.py`

> 逐字复制的真实源码（78 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""ORM model registration entry point.

Importing this module ensures all ORM models are registered with
``Base.metadata`` so Alembic autogenerate detects every table.

The actual ORM classes have moved to entity-specific subpackages:
- ``helix.persistence.thread_meta``
- ``helix.persistence.run``
- ``helix.persistence.feedback``
- ``helix.persistence.user``

``RunEventRow`` remains in ``helix.persistence.models.run_event`` because
its storage implementation lives in ``helix.runtime.events.store.db`` and
there is no matching entity directory.
"""

from helix.persistence.agents.model import AgentRow
from helix.persistence.channel_connections.model import (
    ChannelConnectionRow,
    ChannelConversationRow,
    ChannelCredentialRow,
    ChannelOAuthStateRow,
)
from helix.persistence.channel_leases.model import ChannelLeaseRow
from helix.persistence.channel_thread_bindings.model import ChannelThreadBindingRow
from helix.persistence.feedback.model import FeedbackRow
from helix.persistence.login_throttle.model import LoginThrottleRow
from helix.persistence.managed_subagents.model import ManagedSubagentRow
from helix.persistence.mcp_tasks.model import McpTaskRow
from helix.persistence.models.run_event import RunEventRow, RunEventThreadSeqRow
from helix.persistence.notification_deliveries.model import NotificationDeliveryRow
from helix.persistence.personal_access_tokens.model import PersonalAccessTokenRow
from helix.persistence.projects.model import ProjectDocumentRow, ProjectRow
from helix.persistence.run.model import RunChangeClockRow, RunRow
from helix.persistence.scheduled_task_events.model import ScheduledTaskEventRow
from helix.persistence.scheduled_task_runs.model import ScheduledTaskRunRow
from helix.persistence.scheduled_tasks.model import ScheduledTaskRow
from helix.persistence.subagent_batches.model import SubagentBatchItemRow, SubagentBatchRow
from helix.persistence.thread_meta.model import ThreadMetaRow
from helix.persistence.thread_reads.model import ThreadReadMarkerRow, ThreadReadVersionRow
from helix.persistence.user.im_notifications import ImNotificationPreferenceRow
from helix.persistence.user.model import UserPreferenceRow, UserRow
from helix.persistence.webhook_delivery.model import WebhookDeliveryRow

__all__ = [
    "AgentRow",
    "ChannelConnectionRow",
    "ChannelConversationRow",
    "ChannelCredentialRow",
    "ChannelLeaseRow",
    "ChannelOAuthStateRow",
    "ChannelThreadBindingRow",
    "FeedbackRow",
    "LoginThrottleRow",
    "McpTaskRow",
    "ManagedSubagentRow",
    "NotificationDeliveryRow",
    "PersonalAccessTokenRow",
    "ProjectDocumentRow",
    "ProjectRow",
    "RunEventRow",
    "RunEventThreadSeqRow",
    "RunChangeClockRow",
    "RunRow",
    "ScheduledTaskEventRow",
    "ScheduledTaskRow",
    "ScheduledTaskRunRow",
    "SubagentBatchRow",
    "SubagentBatchItemRow",
    "ThreadMetaRow",
    "ThreadReadMarkerRow",
    "ThreadReadVersionRow",
    "UserPreferenceRow",
    "ImNotificationPreferenceRow",
    "UserRow",
    "WebhookDeliveryRow",
]
```
