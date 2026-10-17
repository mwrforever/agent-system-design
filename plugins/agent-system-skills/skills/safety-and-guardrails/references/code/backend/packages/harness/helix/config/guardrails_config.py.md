# `backend/packages/harness/helix/config/guardrails_config.py`

> 逐字复制的真实源码（49 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Configuration for pre-tool-call authorization."""

from pydantic import BaseModel, Field


class GuardrailProviderConfig(BaseModel):
    """Configuration for a guardrail provider."""

    use: str = Field(description="Class path (e.g. 'helix.guardrails.builtin:AllowlistProvider')")
    config: dict = Field(default_factory=dict, description="Provider-specific settings passed as kwargs")


class GuardrailsConfig(BaseModel):
    """Configuration for pre-tool-call authorization.

    When enabled, every tool call passes through the configured provider
    before execution. The provider receives tool name, arguments, and the
    agent's passport reference, and returns an allow/deny decision.
    """

    enabled: bool = Field(default=False, description="Enable guardrail middleware")
    fail_closed: bool = Field(default=True, description="Block tool calls if provider errors")
    passport: str | None = Field(default=None, description="OAP passport path or hosted agent ID")
    provider: GuardrailProviderConfig | None = Field(default=None, description="Guardrail provider configuration")


_guardrails_config: GuardrailsConfig | None = None


def get_guardrails_config() -> GuardrailsConfig:
    """Get the guardrails config, returning defaults if not loaded."""
    global _guardrails_config
    if _guardrails_config is None:
        _guardrails_config = GuardrailsConfig()
    return _guardrails_config


def load_guardrails_config_from_dict(data: dict) -> GuardrailsConfig:
    """Load guardrails config from a dict (called during AppConfig loading)."""
    global _guardrails_config
    _guardrails_config = GuardrailsConfig.model_validate(data)
    return _guardrails_config


def reset_guardrails_config() -> None:
    """Reset the cached config instance. Used in tests to prevent singleton leaks."""
    global _guardrails_config
    _guardrails_config = None
```
