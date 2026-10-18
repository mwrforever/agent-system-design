# `persistence/user/__init__.py`

> 逐字复制的真实源码（13 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""User storage subpackage.

Holds the ORM model for the ``users`` table. The concrete repository
implementation (``SQLiteUserRepository``) lives in the app layer
(``app.gateway.auth.repositories.sqlite``) because it converts
between the ORM row and the auth module's pydantic ``User`` class.
This keeps the harness package free of any dependency on app code.
"""

from helix.persistence.user.model import UserRow

__all__ = ["UserRow"]
```
