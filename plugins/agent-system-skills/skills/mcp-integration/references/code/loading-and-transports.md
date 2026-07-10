# Loading & Transports 完整源码

> 本文件是 `mcp-integration` SKILL.md 的代码附件，收录 lazy+mtime 缓存、多传输构造、OAuth token 管理、extensions_config schema 的**完整真实源码**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

## 文件清单

| 自定路径 | 内容 |
|---|---|
| `core/helix/mcp/cache.py` | lazy + mtime 缓存全貌 |
| `core/helix/mcp/client.py` | 多传输归一 + 失败隔离 |
| `core/helix/mcp/oauth.py` | OAuth token 管理 + interceptor |
| `core/helix/config/extensions_config.py` | MCP server / OAuth config schema + 直读磁盘 + env 解析 |

---

## 1. cache.py -- lazy + mtime 缓存全貌

```python
# core/helix/mcp/cache.py
"""Cache for MCP tools to avoid repeated loading."""

import asyncio
import logging
import os

from langchain_core.tools import BaseTool

logger = logging.getLogger(__name__)

_mcp_tools_cache: list[BaseTool] | None = None
_cache_initialized = False
_initialization_lock = asyncio.Lock()
_config_mtime: float | None = None  # 跟踪 extensions_config.json 的 mtime


def _get_config_mtime() -> float | None:
    """获取 extensions 配置文件的修改时间。

    Returns:
        修改时间（float），文件不存在返回 None。
    """
    from helix.config.extensions_config import ExtensionsConfig

    config_path = ExtensionsConfig.resolve_config_path()
    if config_path and config_path.exists():
        return os.path.getmtime(config_path)
    return None


def _is_cache_stale() -> bool:
    """检查缓存是否因配置文件变更而过期。

    Returns:
        True 表示应失效重载，False 表示不过期。
    """
    global _config_mtime

    if not _cache_initialized:
        return False  # 尚未初始化，不算过期

    current_mtime = _get_config_mtime()

    # 当前或缓存的 mtime 取不到（文件缺失/不可读）-> 假设不过期，不 churn 缓存
    if _config_mtime is None or current_mtime is None:
        return False

    # 配置文件自缓存后被修改 -> 过期
    if current_mtime > _config_mtime:
        logger.info(f"MCP config file has been modified (mtime: {_config_mtime} -> {current_mtime}), cache is stale")
        return True

    return False


async def initialize_mcp_tools() -> list[BaseTool]:
    """初始化并缓存 MCP 工具。应用启动时调一次。

    Returns:
        所有启用 MCP server 的 LangChain 工具列表。
    """
    global _mcp_tools_cache, _cache_initialized, _config_mtime

    async with _initialization_lock:
        if _cache_initialized:
            logger.info("MCP tools already initialized")
            return _mcp_tools_cache or []

        from helix.mcp.tools import get_mcp_tools

        logger.info("Initializing MCP tools...")
        _mcp_tools_cache = await get_mcp_tools()
        _cache_initialized = True
        _config_mtime = _get_config_mtime()  # 记录配置文件 mtime
        logger.info(f"MCP tools initialized: {len(_mcp_tools_cache)} tool(s) loaded (config mtime: {_config_mtime})")

        return _mcp_tools_cache


def get_cached_mcp_tools() -> list[BaseTool]:
    """获取缓存的 MCP 工具（lazy 初始化 + mtime 失效）。

    未初始化时自动初始化，确保 FastAPI 与 LangGraph Studio 两种上下文都可用。
    同时检查配置文件自上次初始化后是否被修改，是则重新初始化--这是
    Gateway API（独立进程）改配置后运行时热感知的通道。

    Returns:
        缓存的 MCP 工具列表。
    """
    global _cache_initialized

    # 配置文件变更 -> 缓存过期 -> 重置待重载
    if _is_cache_stale():
        logger.info("MCP cache is stale, resetting for re-initialization...")
        reset_mcp_tools_cache()

    if not _cache_initialized:
        logger.info("MCP tools not initialized, performing lazy initialization...")
        try:
            # 尝试在当前事件循环初始化
            loop = asyncio.get_event_loop()
            if loop.is_running():
                # 已在运行的循环里（如 LangGraph Studio），不能嵌套 asyncio.run，
                # 提交到 worker 线程跑 asyncio.run
                import concurrent.futures

                with concurrent.futures.ThreadPoolExecutor() as executor:
                    future = executor.submit(asyncio.run, initialize_mcp_tools())
                    future.result()
            else:
                # 无运行循环，用当前循环
                loop.run_until_complete(initialize_mcp_tools())
        except RuntimeError:
            # 无事件循环，创建一个
            try:
                asyncio.run(initialize_mcp_tools())
            except Exception:
                logger.exception("Failed to lazy-initialize MCP tools")
                return []
        except Exception:
            logger.exception("Failed to lazy-initialize MCP tools")
            return []

    return _mcp_tools_cache or []


def reset_mcp_tools_cache() -> None:
    """重置 MCP 工具缓存（测试或重载用）。

    同时关闭所有持久 MCP session--schema 已从 catalog 消失的工具不能继续持有
    到其 server 的 open session。close_all_sync 按 owning loop 分叉关闭策略：
      * 属于当前运行 loop 的 session 只 signal（其 owner task 在 loop 恢复控制后跑 __aexit__，
        这正确且不泄漏，因为 loop 保持着 task 存活）
      * 其他线程 loop 的 session 确定性 teardown
      * idle/已关 loop 被处理或跳过
    这里刻意不同步等当前运行 loop 完成 teardown：那是自死锁（loop 只能在本 sync
    调用返还控制后跑 teardown）。
    """
    global _mcp_tools_cache, _cache_initialized, _config_mtime
    _mcp_tools_cache = None
    _cache_initialized = False
    _config_mtime = None

    # 关闭持久 session--下次 get_mcp_tools() 调用会按（可能更新的）连接配置重建
    try:
        from helix.mcp.session_pool import get_session_pool

        get_session_pool().close_all_sync()
    except Exception:
        logger.debug("Could not close MCP session pool on cache reset", exc_info=True)

    from helix.mcp.session_pool import reset_session_pool

    reset_session_pool()
    logger.info("MCP tools cache reset")
```

---

## 2. client.py -- 多传输归一 + 失败隔离

```python
# core/helix/mcp/client.py
"""MCP client using langchain-mcp-adapters."""

import logging
from typing import Any

from helix.config.extensions_config import ExtensionsConfig, McpServerConfig

logger = logging.getLogger(__name__)


def build_server_params(server_name: str, config: McpServerConfig) -> dict[str, Any]:
    """为 MultiServerMCPClient 构造单 server 参数（传输归一）。

    Args:
        server_name: MCP server 名。
        config: 单 server 配置。

    Returns:
        langchain-mcp-adapters 的 server 参数字典。

    Raises:
        ValueError: 传输类型不支持，或必填字段缺失（stdio 缺 command / sse/http 缺 url）。
    """
    transport_type = config.type or "stdio"
    params: dict[str, Any] = {"transport": transport_type}

    if transport_type == "stdio":
        if not config.command:
            raise ValueError(f"MCP server '{server_name}' with stdio transport requires 'command' field")
        params["command"] = config.command
        params["args"] = config.args
        # 有 env 时加入
        if config.env:
            params["env"] = config.env
    elif transport_type in ("sse", "http"):
        if not config.url:
            raise ValueError(f"MCP server '{server_name}' with {transport_type} transport requires 'url' field")
        params["url"] = config.url
        # 有 headers 时加入
        if config.headers:
            params["headers"] = config.headers
    else:
        raise ValueError(f"MCP server '{server_name}' has unsupported transport type: {transport_type}")

    return params


def build_servers_config(extensions_config: ExtensionsConfig) -> dict[str, dict[str, Any]]:
    """为 MultiServerMCPClient 构造全量 server 配置。

    Args:
        extensions_config: 含所有 MCP server 的 extensions 配置。

    Returns:
        server 名 -> 参数 的字典。单 server 构造失败不影响其他。
    """
    enabled_servers = extensions_config.get_enabled_mcp_servers()

    if not enabled_servers:
        logger.info("No enabled MCP servers found")
        return {}

    servers_config = {}
    for server_name, server_config in enabled_servers.items():
        try:
            servers_config[server_name] = build_server_params(server_name, server_config)
            logger.info(f"Configured MCP server: {server_name}")
        except Exception as e:
            # 单 server 配置失败：记日志跳过，不 blackhole 整个 catalog
            logger.error(f"Failed to configure MCP server '{server_name}': {e}")

    return servers_config
```

---

## 3. oauth.py -- OAuth token 管理 + interceptor 全貌

```python
# core/helix/mcp/oauth.py
"""OAuth token support for MCP HTTP/SSE servers."""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from helix.config.extensions_config import ExtensionsConfig, McpOAuthConfig

logger = logging.getLogger(__name__)


@dataclass
class _OAuthToken:
    """缓存的 OAuth token。"""

    access_token: str
    token_type: str
    expires_at: datetime


class OAuthTokenManager:
    """为 MCP server 获取/缓存/刷新 OAuth token。

    per-server asyncio.Lock 收敛并发刷新；token 在 expires_at - refresh_skew_seconds
    前即视为"将过期"并主动刷新，避免调用途中 token 过期 401。响应字段名可配置，
    兼容非标准 provider。
    """

    def __init__(self, oauth_by_server: dict[str, McpOAuthConfig]):
        self._oauth_by_server = oauth_by_server
        self._tokens: dict[str, _OAuthToken] = {}
        self._locks: dict[str, asyncio.Lock] = {name: asyncio.Lock() for name in oauth_by_server}

    @classmethod
    def from_extensions_config(cls, extensions_config: ExtensionsConfig) -> OAuthTokenManager:
        oauth_by_server: dict[str, McpOAuthConfig] = {}
        for server_name, server_config in extensions_config.get_enabled_mcp_servers().items():
            if server_config.oauth and server_config.oauth.enabled:
                oauth_by_server[server_name] = server_config.oauth
        return cls(oauth_by_server)

    def has_oauth_servers(self) -> bool:
        return bool(self._oauth_by_server)

    def oauth_server_names(self) -> list[str]:
        return list(self._oauth_by_server.keys())

    async def get_authorization_header(self, server_name: str) -> str | None:
        """获取 Authorization 头值。无 OAuth 配置返回 None。

        双检锁：先无锁读缓存，将过期则加锁再读一次（防 stampede），仍将过期才刷新。
        """
        oauth = self._oauth_by_server.get(server_name)
        if not oauth:
            return None

        token = self._tokens.get(server_name)
        if token and not self._is_expiring(token, oauth):
            return f"{token.token_type} {token.access_token}"

        lock = self._locks[server_name]
        async with lock:
            token = self._tokens.get(server_name)
            if token and not self._is_expiring(token, oauth):
                return f"{token.token_type} {token.access_token}"

            fresh = await self._fetch_token(oauth)
            self._tokens[server_name] = fresh
            logger.info(f"Refreshed OAuth access token for MCP server: {server_name}")
            return f"{fresh.token_type} {fresh.access_token}"

    @staticmethod
    def _is_expiring(token: _OAuthToken, oauth: McpOAuthConfig) -> bool:
        """token 在 refresh_skew_seconds 内将过期 -> True（主动刷新，非被动）。"""
        now = datetime.now(UTC)
        return token.expires_at <= now + timedelta(seconds=max(oauth.refresh_skew_seconds, 0))

    async def _fetch_token(self, oauth: McpOAuthConfig) -> _OAuthToken:
        """向 token endpoint 请求新 token。支持 client_credentials / refresh_token 双 grant。"""
        import httpx  # pyright: ignore[reportMissingImports]

        data: dict[str, str] = {
            "grant_type": oauth.grant_type,
            **oauth.extra_token_params,
        }

        if oauth.scope:
            data["scope"] = oauth.scope
        if oauth.audience:
            data["audience"] = oauth.audience

        if oauth.grant_type == "client_credentials":
            if not oauth.client_id or not oauth.client_secret:
                raise ValueError("OAuth client_credentials requires client_id and client_secret")
            data["client_id"] = oauth.client_id
            data["client_secret"] = oauth.client_secret
        elif oauth.grant_type == "refresh_token":
            if not oauth.refresh_token:
                raise ValueError("OAuth refresh_token grant requires refresh_token")
            data["refresh_token"] = oauth.refresh_token
            if oauth.client_id:
                data["client_id"] = oauth.client_id
            if oauth.client_secret:
                data["client_secret"] = oauth.client_secret
        else:
            raise ValueError(f"Unsupported OAuth grant type: {oauth.grant_type}")

        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.post(oauth.token_url, data=data)
            response.raise_for_status()
            payload = response.json()

        # 响应字段名可配置，兼容非标准 provider
        access_token = payload.get(oauth.token_field)
        if not access_token:
            raise ValueError(f"OAuth token response missing '{oauth.token_field}'")

        token_type = str(payload.get(oauth.token_type_field, oauth.default_token_type) or oauth.default_token_type)

        # expires_in 防御性解析：非整数回退 1h
        expires_in_raw = payload.get(oauth.expires_in_field, 3600)
        try:
            expires_in = int(expires_in_raw)
        except (TypeError, ValueError):
            expires_in = 3600

        expires_at = datetime.now(UTC) + timedelta(seconds=max(expires_in, 1))
        return _OAuthToken(access_token=access_token, token_type=token_type, expires_at=expires_at)


def build_oauth_tool_interceptor(extensions_config: ExtensionsConfig) -> Any | None:
    """构造工具调用 interceptor：每次出站工具调用前注入 OAuth Authorization 头。

    无 OAuth server 返回 None（不套 interceptor 链）。
    """
    token_manager = OAuthTokenManager.from_extensions_config(extensions_config)
    if not token_manager.has_oauth_servers():
        return None

    async def oauth_interceptor(request: Any, handler: Any) -> Any:
        header = await token_manager.get_authorization_header(request.server_name)
        if not header:
            return await handler(request)

        updated_headers = dict(request.headers or {})
        updated_headers["Authorization"] = header
        return await handler(request.override(headers=updated_headers))

    return oauth_interceptor


async def get_initial_oauth_headers(extensions_config: ExtensionsConfig) -> dict[str, str]:
    """获取建连初始 OAuth 头（sse/http 传输打开 session 时需要 Authorization）。"""
    token_manager = OAuthTokenManager.from_extensions_config(extensions_config)
    if not token_manager.has_oauth_servers():
        return {}

    headers: dict[str, str] = {}
    for server_name in token_manager.oauth_server_names():
        headers[server_name] = await token_manager.get_authorization_header(server_name) or ""

    return {name: value for name, value in headers.items() if value}
```

---

## 4. extensions_config.py -- config schema + 直读磁盘 + env 解析

```python
# core/helix/config/extensions_config.py（MCP 相关 schema + 关键方法）
"""Unified extensions configuration for MCP servers and skills."""

import json
import os
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from helix.config.runtime_paths import existing_project_file


class McpOAuthConfig(BaseModel):
    """OAuth configuration for an MCP server (HTTP/SSE transports)."""

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
    """Configuration for a single MCP server."""

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
        """接受 MCP 规范的 ``transport`` 字段作为 ``type`` 的别名。

        官方 MCP 配置 schema 用 ``transport`` 指示传输机制（stdio/sse/http）。早期版本
        只认 ``type``，导致仅配 ``transport`` 的远程 SSE/HTTP server 被误当 stdio（默认值）。
        本 validator 归一两者，两者都给时 ``type`` 优先。
        """
        if isinstance(data, dict):
            transport = data.get("transport")
            if transport and not data.get("type"):
                data = {**data, "type": transport}
        return data


class SkillStateConfig(BaseModel):
    """Configuration for a single skill's state."""

    enabled: bool = Field(default=True, description="Whether this skill is enabled")


class ExtensionsConfig(BaseModel):
    """Unified configuration for MCP servers and skills."""

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

    @classmethod
    def resolve_config_path(cls, config_path: str | None = None) -> Path | None:
        """解析 extensions 配置文件路径。

        优先级：
        1. 提供的 config_path 参数。
        2. HELIX_EXTENSIONS_CONFIG_PATH 环境变量。
        3. 搜索 caller project root 的 extensions_config.json，再 mcp_config.json。
        4. 向后兼容：搜索 legacy backend/repository-root 默认。
        5. 找不到返回 None（extensions 是可选的）。

        Returns:
            配置文件路径，找不到返回 None。
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

            backend_dir = Path(__file__).resolve().parents[4]
            repo_root = backend_dir.parent
            for path in (
                backend_dir / "extensions_config.json",
                repo_root / "extensions_config.json",
                backend_dir / "mcp_config.json",
                repo_root / "mcp_config.json",
            ):
                if path.exists():
                    return path

            # extensions 可选，找不到返回 None
            return None

    @classmethod
    def from_file(cls, config_path: str | None = None) -> "ExtensionsConfig":
        """从 JSON 文件加载 extensions 配置。

        直读磁盘（非缓存单例），确保 Gateway API（独立进程）写入的最新配置被读到。
        """
        resolved_path = cls.resolve_config_path(config_path)
        if resolved_path is None:
            # 找不到配置文件返回空配置
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

    @classmethod
    def resolve_env_variables(cls, config: Any) -> Any:
        """递归解析配置里的环境变量。

        用 os.getenv 解析。例：$OPENAI_API_KEY。
        未解析的占位符存空串，避免下游（如 MCP server）收到字面 "$VAR" token 作为实际值。
        """
        if isinstance(config, str):
            if not config.startswith("$"):
                return config
            env_value = os.getenv(config[1:])
            if env_value is None:
                # 未解析占位符 -> 存空串，不让字面 "$VAR" 传下去
                return ""
            return env_value

        if isinstance(config, dict):
            return {key: cls.resolve_env_variables(value) for key, value in config.items()}

        if isinstance(config, list):
            return [cls.resolve_env_variables(item) for item in config]

        if isinstance(config, tuple):
            return tuple(cls.resolve_env_variables(item) for item in config)

        return config

    def get_enabled_mcp_servers(self) -> dict[str, McpServerConfig]:
        """仅返回启用的 MCP server。"""
        return {name: config for name, config in self.mcp_servers.items() if config.enabled}

    def is_skill_enabled(self, skill_name: str, skill_category: str) -> bool:
        """检查 skill 是否启用。

        所有 skill 类别（public/custom/legacy）都遵从 extensions_config 的 enabled/disabled。
        无显式条目时默认启用。
        """
        skill_config = self.skills.get(skill_name)
        if skill_config is None:
            return skill_category in ("public", "custom", "legacy")
        return skill_config.enabled


_extensions_config: ExtensionsConfig | None = None


def get_extensions_config() -> ExtensionsConfig:
    """获取 extensions config 缓存单例。

    注意：MCP 工具装载用 ExtensionsConfig.from_file() 直读磁盘，不用本缓存单例，
    以确保跨进程感知。
    """
    global _extensions_config
    if _extensions_config is None:
        _extensions_config = ExtensionsConfig.from_file()
    return _extensions_config


def reload_extensions_config(config_path: str | None = None) -> ExtensionsConfig:
    """从文件重载 extensions config 并更新缓存实例。"""
    global _extensions_config
    _extensions_config = ExtensionsConfig.from_file(config_path)
    return _extensions_config


def reset_extensions_config() -> None:
    """清空缓存单例，下次 get_extensions_config() 重载。"""
    global _extensions_config
    _extensions_config = None


def set_extensions_config(config: ExtensionsConfig) -> None:
    """注入自定义 extensions config（测试用）。"""
    global _extensions_config
    _extensions_config = config
```

### extensions_config.json 配置示例

```json
{
  "mcpServers": {
    "filesystem": {
      "enabled": true,
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/mnt/user-data/workspace"],
      "tool_call_timeout": 30
    },
    "playwright": {
      "enabled": true,
      "transport": "stdio",
      "command": "npx",
      "args": ["-y", "@executeautomation/playwright-mcp-server"]
    },
    "github": {
      "enabled": true,
      "type": "http",
      "url": "https://api.example.com/mcp",
      "headers": {"X-Client": "agent_framework"},
      "oauth": {
        "token_url": "https://auth.example.com/token",
        "grant_type": "client_credentials",
        "client_id": "$GH_CLIENT_ID",
        "client_secret": "$GH_CLIENT_SECRET",
        "scope": "repo",
        "refresh_skew_seconds": 120
      }
    }
  },
  "mcpInterceptors": ["mypkg.mcp.audit:build_audit_interceptor"]
}
```
