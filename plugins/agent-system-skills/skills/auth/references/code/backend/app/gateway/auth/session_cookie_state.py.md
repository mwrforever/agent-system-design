# `backend/app/gateway/auth/session_cookie_state.py`

> 逐字复制的真实源码（7 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Request-state keys shared by session and CSRF cookie handling."""

SESSION_COOKIE_ISSUED_STATE_ATTR = "helix_session_cookie_issued"
SESSION_COOKIE_MAX_AGE_STATE_ATTR = "helix_session_cookie_max_age"
SESSION_COOKIE_SECURE_STATE_ATTR = "helix_session_cookie_secure"
SKIP_AUTH_CSRF_COOKIE_STATE_ATTR = "helix_skip_auth_csrf_cookie"
```
