# `backend/packages/harness/helix/persistence/models/run_event.py`

> 逐字复制的真实源码（46 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""ORM model for run events."""

from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import JSON, BigInteger, DateTime, Index, String, Text, UniqueConstraint, text
from sqlalchemy.orm import Mapped, mapped_column

from helix.constants import RUN_EVENT_CATEGORY_MAX_LENGTH, RUN_EVENT_TYPE_MAX_LENGTH
from helix.persistence.base import Base


class RunEventRow(Base):
    __tablename__ = "run_events"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    thread_id: Mapped[str] = mapped_column(String(64), nullable=False)
    run_id: Mapped[str] = mapped_column(String(64), nullable=False)
    # Owner of the conversation this event belongs to. Nullable for data
    # created before auth was introduced; populated by auth middleware on
    # new writes and by the boot-time orphan migration on existing rows.
    user_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    event_type: Mapped[str] = mapped_column(String(RUN_EVENT_TYPE_MAX_LENGTH), nullable=False)
    category: Mapped[str] = mapped_column(String(RUN_EVENT_CATEGORY_MAX_LENGTH), nullable=False)
    # Category values and semantics are defined by runtime/events/catalog.py
    content: Mapped[str] = mapped_column(Text, default="")
    event_metadata: Mapped[dict] = mapped_column(JSON, default=dict)
    seq: Mapped[int] = mapped_column(nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))

    __table_args__ = (
        UniqueConstraint("thread_id", "seq", name="uq_events_thread_seq"),
        Index("ix_events_thread_cat_seq", "thread_id", "category", "seq"),
        Index("ix_events_run", "thread_id", "run_id", "seq"),
    )


class RunEventThreadSeqRow(Base):
    """Durable per-thread high-water mark for run-event sequence allocation."""

    __tablename__ = "run_event_thread_seq"

    thread_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0, server_default=text("0"))
```
