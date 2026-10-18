# `app/gateway/auth/__init__.py`

> 逐字复制的真实源码（43 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Authentication module for Helix.

This module provides:
- JWT-based authentication
- Provider Factory pattern for extensible auth methods
- UserRepository interface for storage backends (SQLite)
"""

from app.gateway.auth.config import AuthConfig, get_auth_config, set_auth_config
from app.gateway.auth.errors import AuthErrorCode, AuthErrorResponse, TokenError
from app.gateway.auth.jwt import TokenPayload, create_access_token, decode_token
from app.gateway.auth.local_provider import LocalAuthProvider
from app.gateway.auth.models import User, UserResponse
from app.gateway.auth.password import hash_password, verify_password
from app.gateway.auth.providers import AuthProvider
from app.gateway.auth.repositories.base import UserRepository

__all__ = [
    # Config
    "AuthConfig",
    "get_auth_config",
    "set_auth_config",
    # Errors
    "AuthErrorCode",
    "AuthErrorResponse",
    "TokenError",
    # JWT
    "TokenPayload",
    "create_access_token",
    "decode_token",
    # Password
    "hash_password",
    "verify_password",
    # Models
    "User",
    "UserResponse",
    # Providers
    "AuthProvider",
    "LocalAuthProvider",
    # Repository
    "UserRepository",
]
```
