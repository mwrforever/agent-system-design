# 完整源码：extensions_config（MCP + Skills）+ $ENV 展开双语义

> 本文件给出 `core/helix/config/extensions_config.py` 的**完整实现**：`ExtensionsConfig` 模型、`McpServerConfig`（stdio/sse/http 三种传输）、`McpOAuthConfig`（HTTP/SSE 的 OAuth token 注入）、`SkillStateConfig`、`resolve_config_path()` 四级路径解析（独立于主 config.yaml）、`from_file()` JSON 加载、`resolve_env_variables()` 静默降级版 `$ENV` 展开、`get_enabled_mcp_servers()` / `is_skill_enabled()` 查询，以及独立缓存单例层。
>
> **$ENV 双语义**是本模块的核心设计点：主配置 `AppConfig.resolve_env_variables()` 对未命中环境变量**快速失败**（抛 `ValueError`），而扩展配置 `ExtensionsConfig.resolve_env_variables()` 对未命中**静默降级**为空串。原因与取舍见 SKILL.md 设计方案段。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`、env 前缀 `HELIX_*`），去除一切项目字样。原代码注释保留以保真。

## §1 ExtensionsConfig 模型：MCP server + Skills 状态

```python
# core/helix/config/extensions_config.py
"""MCP 服务器与 Skills 的统一扩展配置。"""

import json
import os
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from helix.config.runtime_paths import existing_project_file


class McpOAuthConfig(BaseModel):
    """单个 MCP 服务器的 OAuth 配置（HTTP/SSE 传输）。"""

    enabled: bool = Field(default=True, description="Whether OAuth token injection is enabled")
    token_url: str = Field(description="OAuth token endpoint URL")
    grant_type: Literal["client_credentials", "refresh_token"] = Field(
        default="client_credentials",
        description="OAuth grant type",
    )
    client_id: str | None = Field(default=None, description="OAuth client ID")
    client_secret: str | None = Field(default=None, description="OAuth client secret")
    refresh_token: str | None = Field(default=None, description="OAuth refresh token (for refresh_token grant)")
    scope: str | None = Field(default=None, description="OAuth scope")
    audience: str | None = Field(default=None, description="OAuth audience (provider-specific)")
    token_field: str = Field(default="access_token", description="Field name containing access token in token response")
    token_type_field: str = Field(default="token_type", description="Field name containing token type in token response")
    expires_in_field: str = Field(default="expires_in", description="Field name containing expiry (seconds) in token response")
    default_token_type: str = Field(default="Bearer", description="Default token type when missing in token response")
    refresh_skew_seconds: int = Field(default=60, description="Refresh token this many seconds before expiry")
    extra_token_params: dict[str, str] = Field(default_factory=dict, description="Additional form params sent to token endpoint")
    model_config = ConfigDict(extra="allow")


class McpServerConfig(BaseModel):
    """单个 MCP 服务器的配置。"""

    enabled: bool = Field(default=True, description="Whether this MCP server is enabled")
    type: str = Field(default="stdio", description="Transport type: 'stdio', 'sse', or 'http'")
    command: str | None = Field(default=None, description="Command to execute to start the MCP server (for stdio type)")
    args: list[str] = Field(default_factory=list, description="Arguments to pass to the command (for stdio type)")
    env: dict[str, str] = Field(default_factory=dict, description="Environment variables for the MCP server")
    url: str | None = Field(default=None, description="URL of the MCP server (for sse or http type)")
    headers: dict[str, str] = Field(default_factory=dict, description="HTTP headers to send (for sse or http type)")
    oauth: McpOAuthConfig | None = Field(default=None, description="OAuth configuration (for sse or http type)")
    description: str = Field(default="", description="Human-readable description of what this MCP server provides")
    tool_call_timeout: float | None = Field(
        default=None,
        description="Timeout in seconds for individual stdio MCP tool calls. HTTP/SSE servers use transport-level timeouts. None means no timeout.",
    )
    model_config = ConfigDict(extra="allow")

    @model_validator(mode="before")
    @classmethod
    def _accept_transport_alias(cls, data: Any) -> Any:
        """把 MCP 规范的 ``transport`` 字段当作 ``type`` 的别名。

        官方 MCP 配置 schema 用 ``transport`` 指示传输机制
        (``stdio``/``sse``/``http``)。早期版本只认 ``type``，导致只用
        ``transport`` 配置的远程 SSE/HTTP 服务器被错误当作 ``stdio``（默认值）。
        本 validator 把两者归一，``type`` 与 ``transport`` 同时给时 ``type`` 优先。
        """
        if isinstance(data, dict):
            transport = data.get("transport")
            if transport and not data.get("type"):
                data = {**data, "type": transport}
        return data


class SkillStateConfig(BaseModel):
    """单个 skill 的启用状态。"""

    enabled: bool = Field(default=True, description="Whether this skill is enabled")


class ExtensionsConfig(BaseModel):
    """MCP 服务器与 Skills 的统一配置。"""

    mcp_servers: dict[str, McpServerConfig] = Field(
        default_factory=dict,
        description="Map of MCP server name to configuration",
        alias="mcpServers",
    )
    skills: dict[str, SkillStateConfig] = Field(
        default_factory=dict,
        description="Map of skill name to state configuration",
    )
    model_config = ConfigDict(extra="allow", populate_by_name=True)
```

## §2 扩展配置路径解析与加载（独立文件、独立缓存）

```python
# core/helix/config/extensions_config.py
    # --- 以下为 ExtensionsConfig 的类方法 ---

    @classmethod
    def resolve_config_path(cls, config_path: str | None = None) -> Path | None:
        """解析扩展配置文件路径。

        优先级：
        1. 显式传入的 ``config_path`` 参数。
        2. ``HELIX_EXTENSIONS_CONFIG_PATH`` 环境变量。
        3. 调用方项目根下的 ``extensions_config.json``，其次 legacy ``mcp_config.json``。
        4. legacy backend / 仓库根默认位置（monorepo 兼容）。
        5. 都没找到返回 None（扩展配置是可选的）。

        与主 config.yaml 的 resolve_config_path 对称，但扩展配置缺失不报错--
        返回 None 让 from_file 产出空配置。
        """
        if config_path:
            path = Path(config_path)
            if not path.exists():
                raise FileNotFoundError(f"Extensions config file specified by param `config_path` not found at {path}")
            return path
        elif os.getenv("HELIX_EXTENSIONS_CONFIG_PATH"):
            path = Path(os.getenv("HELIX_EXTENSIONS_CONFIG_PATH"))
            if not path.exists():
                raise FileNotFoundError(f"Extensions config file specified by environment variable `HELIX_EXTENSIONS_CONFIG_PATH` not found at {path}")
            return path
        else:
            project_config = existing_project_file(("extensions_config.json", "mcp_config.json"))
            if project_config is not None:
                return project_config

            legacy_root = Path(__file__).resolve().parents[4]
            repo_root = legacy_root.parent
            for path in (
                legacy_root / "extensions_config.json",
                repo_root / "extensions_config.json",
                legacy_root / "mcp_config.json",
                repo_root / "mcp_config.json",
            ):
                if path.exists():
                    return path

            # 扩展配置可选，没找到返回 None
            return None

    @classmethod
    def from_file(cls, config_path: str | None = None) -> "ExtensionsConfig":
        """从 JSON 文件加载扩展配置。

        文件没找到时返回空配置（mcp_servers={}、skills={}），不报错--扩展
        配置是可选的。JSON 解析失败抛 ValueError；其他异常包成 RuntimeError。
        """
        resolved_path = cls.resolve_config_path(config_path)
        if resolved_path is None:
            # 扩展配置文件没找到 -> 返回空配置
            return cls(mcp_servers={}, skills={})

        try:
            with open(resolved_path, encoding="utf-8") as f:
                config_data = json.load(f)
            config_data = cls.resolve_env_variables(config_data)
            return cls.model_validate(config_data)
        except json.JSONDecodeError as e:
            raise ValueError(f"Extensions config file at {resolved_path} is not valid JSON: {e}") from e
        except Exception as e:
            raise RuntimeError(f"Failed to load extensions config from {resolved_path}: {e}") from e
```

## §3 $ENV 展开：扩展配置静默降级版

```python
# core/helix/config/extensions_config.py
    @classmethod
    def resolve_env_variables(cls, config: Any) -> Any:
        """递归解析配置中的环境变量（扩展配置语义）。

        与主配置 AppConfig.resolve_env_variables 的关键差异：未命中时**不抛
        ValueError**，而是返回空串。理由：扩展配置是可选的，下游消费者
        （如 MCP 服务器）不应收到字面 ``$VAR`` token 当作真实环境值；但扩展
        配置整体缺失都不报错，单个 env 未命中也不应让整个 MCP 加载链崩溃。
        主配置则相反--API key 缺失应在启动期快速失败，而非运行时神秘 None。
        """
        if isinstance(config, str):
            if not config.startswith("$"):
                return config
            env_value = os.getenv(config[1:])
            if env_value is None:
                # 未命中占位符 -> 存空串，让下游（如 MCP 服务器）不收到字面
                # ``$VAR`` token 当作真实环境值。
                return ""
            return env_value

        if isinstance(config, dict):
            return {key: cls.resolve_env_variables(value) for key, value in config.items()}

        if isinstance(config, list):
            return [cls.resolve_env_variables(item) for item in config]

        if isinstance(config, tuple):
            return tuple(cls.resolve_env_variables(item) for item in config)

        return config
```

> **对比：主配置快速失败版**（见 [app-config-and-signature.md](./app-config-and-signature.md) §2 `resolve_env_variables`）：
> ```python
> # 主配置：未命中直接抛 ValueError，快速失败
> if config.startswith("$"):
>     env_value = os.getenv(config[1:])
>     if env_value is None:
>         raise ValueError(f"Environment variable {config[1:]} not found for config value {config}")
>     return env_value
> ```

## §4 扩展配置查询

```python
# core/helix/config/extensions_config.py
    def get_enabled_mcp_servers(self) -> dict[str, McpServerConfig]:
        """只取 enabled 的 MCP 服务器。"""
        return {name: config for name, config in self.mcp_servers.items() if config.enabled}

    def is_skill_enabled(self, skill_name: str, skill_category: str) -> bool:
        """检查某 skill 是否启用。

        所有 skill 类别（public、custom、legacy）都尊重 extensions_config 的
        enabled/disabled 状态。无显式条目时默认启用。
        """
        skill_config = self.skills.get(skill_name)
        if skill_config is None:
            # 所有类别默认启用
            return skill_category in ("public", "custom", "legacy")
        return skill_config.enabled
```

## §5 扩展配置独立缓存单例层

> `extensions_config.json` 走与 `config.yaml` **完全独立**的缓存单例。前端 PUT `/api/mcp/config` 写入文件后，下一次 `get_extensions_config()`... 注意：扩展配置单例是**首次加载后常驻**（`if _extensions_config is None`），不像主配置那样每次访问都做签名检测。要让 MCP/skills 改动生效，需显式调 `reload_extensions_config()` 或经主配置 `get_app_config()` 重载链路（`AppConfig.from_file()` 末尾会调 `ExtensionsConfig.from_file()` 重新合并）。

```python
# core/helix/config/extensions_config.py
_extensions_config: ExtensionsConfig | None = None


def get_extensions_config() -> ExtensionsConfig:
    """取扩展配置实例。

    返回缓存的单例。用 ``reload_extensions_config()`` 从文件重载，或
    ``reset_extensions_config()`` 清缓存。
    """
    global _extensions_config
    if _extensions_config is None:
        _extensions_config = ExtensionsConfig.from_file()
    return _extensions_config


def reload_extensions_config(config_path: str | None = None) -> ExtensionsConfig:
    """从文件重载扩展配置并更新缓存实例。

    当扩展配置文件被修改、想不重启就生效时有用。
    """
    global _extensions_config
    _extensions_config = ExtensionsConfig.from_file(config_path)
    return _extensions_config


def reset_extensions_config() -> None:
    """清空缓存的扩展配置实例。

    下次 ``get_extensions_config()`` 会从文件重载。用于测试或在多套配置间切换。
    """
    global _extensions_config
    _extensions_config = None


def set_extensions_config(config: ExtensionsConfig) -> None:
    """注入自定义扩展配置实例（测试用）。"""
    global _extensions_config
    _extensions_config = config
```

## §6 配置层级合并时序（config.yaml + extensions_config.json）

> `AppConfig.from_file()` 末尾显式调 `ExtensionsConfig.from_file()`，把 MCP + Skills 状态合并进主 config 字典。这意味着 MCP 服务端通过 PUT `/api/mcp/config` 写入文件后，下一次 `get_app_config()` 命中主配置签名失效 -> 重新加载 -> `from_file` 重新调 `ExtensionsConfig.from_file()` -> 合并新 ExtensionsConfig，无需重启即可让新 MCP 服务对接 Agent。完整 `from_file` 管线见 [app-config-and-signature.md](./app-config-and-signature.md) §2。

```python
# AppConfig.from_file() 末尾的合并步骤（伪代码，完整源码见 app-config-and-signature.md §2）
extensions_config = ExtensionsConfig.from_file()        # 独立读 extensions_config.json
config_data["extensions"] = extensions_config.model_dump()  # 合并进主 config 字典
result = cls.model_validate(config_data)                # Pydantic 校验 -> result.extensions 即 ExtensionsConfig
```
