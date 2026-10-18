# `authz/__init__.py`

> 逐字复制的真实源码（58 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Pluggable fine-grained authorization (resource-level RBAC and beyond)."""

from helix.authz.adapter import GuardrailAuthorizationAdapter
from helix.authz.enforcement import filter_resources_by_authorization, filter_tools_by_authorization
from helix.authz.plugin_authz import (
    PluginAuthorizationError,
    aenforce_plugin_action,
    aenforce_plugin_management,
    afilter_plugin_management,
    afilter_plugin_pages,
    enforce_plugin_action,
    enforce_plugin_management,
)
from helix.authz.plugin_targets import (
    MANAGEMENT_READ_PART,
    MANAGEMENT_WRITE_PART,
    plugin_action_target,
    plugin_management_target,
    plugin_page_target,
)
from helix.authz.principal import build_principal_from_context, normalize_authz_attributes
from helix.authz.provider import AuthorizationProvider, AuthzDecision, AuthzReason, AuthzRequest, Principal
from helix.authz.rbac import RbacAuthorizationProvider
from helix.authz.runtime import resolve_authorization_provider
from helix.authz.sandbox_authz import authorize_sandbox_execution
from helix.authz.skill_filter import filter_available_skills_by_authorization
from helix.authz.tool_filter import apply_tool_authorization

__all__ = [
    "AuthzDecision",
    "AuthzReason",
    "AuthzRequest",
    "AuthorizationProvider",
    "GuardrailAuthorizationAdapter",
    "MANAGEMENT_READ_PART",
    "MANAGEMENT_WRITE_PART",
    "PluginAuthorizationError",
    "Principal",
    "RbacAuthorizationProvider",
    "aenforce_plugin_action",
    "aenforce_plugin_management",
    "afilter_plugin_management",
    "afilter_plugin_pages",
    "apply_tool_authorization",
    "authorize_sandbox_execution",
    "build_principal_from_context",
    "enforce_plugin_action",
    "enforce_plugin_management",
    "filter_available_skills_by_authorization",
    "filter_resources_by_authorization",
    "filter_tools_by_authorization",
    "normalize_authz_attributes",
    "plugin_action_target",
    "plugin_management_target",
    "plugin_page_target",
    "resolve_authorization_provider",
]
```
