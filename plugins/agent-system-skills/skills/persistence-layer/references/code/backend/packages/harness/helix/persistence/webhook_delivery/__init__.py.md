# `backend/packages/harness/helix/persistence/webhook_delivery/__init__.py`

> 逐字复制的真实源码（6 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Shared inbound webhook dedupe table (issue #4120).

ORM model only; row writes/reads go through raw SQL in
``app.channels.dedupe_store.PostgresInboundDedupeStore``.
"""
```
