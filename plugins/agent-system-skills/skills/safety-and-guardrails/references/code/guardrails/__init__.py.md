# `guardrails/__init__.py`

> 逐字复制的真实源码（18 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Pre-tool-call authorization middleware."""

from helix.guardrails.builtin import AllowlistProvider
from helix.guardrails.middleware import GuardrailMiddleware
from helix.guardrails.provider import GuardrailDecision, GuardrailProvider, GuardrailReason, GuardrailRequest
from helix.guardrails.typesafe import TypeSafeGuardrailError, TypeSafeGuardrailProvider

__all__ = [
    "AllowlistProvider",
    "GuardrailDecision",
    "GuardrailMiddleware",
    "GuardrailProvider",
    "GuardrailReason",
    "GuardrailRequest",
    "TypeSafeGuardrailError",
    "TypeSafeGuardrailProvider",
]
```
