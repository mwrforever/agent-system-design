# `persistence/user/preferences.py`

> 逐字复制的真实源码（26 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Durable per-user preferences; updates touch only explicitly supplied keys."""

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from helix.persistence.user.model import UserPreferenceRow


class UserPreferencesRepository:
    def __init__(self, sessions):
        self.sessions = sessions

    async def get(self, user_id: str) -> dict:
        async with self.sessions() as session:
            rows = (await session.execute(select(UserPreferenceRow).where(UserPreferenceRow.user_id == user_id))).scalars()
            return {row.key: row.value for row in rows}

    async def patch(self, user_id: str, values: dict) -> None:
        async with self.sessions() as session, session.begin():
            insert = pg_insert if session.bind.dialect.name == "postgresql" else sqlite_insert
            # Consistent key order also avoids opposite-order row-lock cycles.
            for key, value in sorted(values.items()):
                statement = insert(UserPreferenceRow).values(user_id=user_id, key=key, value=value)
                await session.execute(statement.on_conflict_do_update(index_elements=["user_id", "key"], set_={"value": statement.excluded.value}))
```
