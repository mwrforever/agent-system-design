# `backend/app/gateway/auth/providers.py`

> 逐字复制的真实源码（25 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Auth provider abstraction."""

from abc import ABC, abstractmethod


class AuthProvider(ABC):
    """Abstract base class for authentication providers."""

    @abstractmethod
    async def authenticate(self, credentials: dict) -> "User | None":
        """Authenticate user with given credentials.

        Returns User if authentication succeeds, None otherwise.
        """
        raise NotImplementedError

    @abstractmethod
    async def get_user(self, user_id: str) -> "User | None":
        """Retrieve user by ID."""
        raise NotImplementedError


# Import User at runtime to avoid circular imports
from app.gateway.auth.models import User  # noqa: E402
```
