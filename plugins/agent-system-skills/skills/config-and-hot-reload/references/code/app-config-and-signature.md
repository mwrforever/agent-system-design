# 完整源码：AppConfig 模型 + 签名缓存热重载

> 本文件给出 `core/helix/config/app_config.py` 的**完整实现**：`AppConfig` Pydantic 模型、`from_file()` 加载管线、`resolve_env_variables()` `$ENV` 展开、`_drop_null_config_sections` 空段兜底、`_apply_singleton_configs` 子配置下发、`_check_config_version` 版本漂移提醒，以及模块级签名缓存单例层（`get_app_config()` / `reload_app_config()` / `reset_app_config()` / `set_app_config()` / ContextVar push/pop）。共享路径解析 `runtime_paths.py` 一并给出。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`、env 前缀 `HELIX_*`、状态目录 `.helix`），去除一切项目字样。原代码注释保留以保真。

## §1 模块导入与常量

```python
# core/helix/config/app_config.py
import hashlib
import logging
import os
from collections.abc import Mapping
from contextvars import ContextVar
from pathlib import Path
from typing import Any, Literal, Self

import yaml
from dotenv import load_dotenv
from pydantic import BaseModel, ConfigDict, Field, PrivateAttr, model_validator

from helix.config.acp_config import ACPAgentConfig, load_acp_config_from_dict
from helix.config.agents_api_config import AgentsApiConfig, load_agents_api_config_from_dict
from helix.config.auth_config import AuthAppConfig
from helix.config.channel_connections_config import ChannelConnectionsConfig
from helix.config.checkpointer_config import CheckpointerConfig, load_checkpointer_config_from_dict
from helix.config.database_config import DatabaseConfig
from helix.config.extensions_config import ExtensionsConfig
from helix.config.guardrails_config import GuardrailsConfig, load_guardrails_config_from_dict
from helix.config.input_polish_config import InputPolishConfig
from helix.config.loop_detection_config import LoopDetectionConfig
from helix.config.memory_config import MemoryConfig, load_memory_config_from_dict
from helix.config.model_config import ModelConfig
from helix.config.read_before_write_config import ReadBeforeWriteConfig
from helix.config.reload_boundary import format_field_description
from helix.config.run_events_config import RunEventsConfig
from helix.config.runtime_paths import existing_project_file
from helix.config.safety_finish_reason_config import SafetyFinishReasonConfig
from helix.config.sandbox_config import SandboxConfig
from helix.config.scheduler_config import SchedulerConfig
from helix.config.skill_evolution_config import SkillEvolutionConfig
from helix.config.skill_scan_config import SkillScanConfig
from helix.config.skills_config import SkillsConfig
from helix.config.stream_bridge_config import StreamBridgeConfig, load_stream_bridge_config_from_dict
from helix.config.subagents_config import SubagentsAppConfig, load_subagents_config_from_dict
from helix.config.suggestions_config import SuggestionsConfig
from helix.config.summarization_config import SummarizationConfig, load_summarization_config_from_dict
from helix.config.title_config import TitleConfig, load_title_config_from_dict
from helix.config.token_budget_config import TokenBudgetConfig
from helix.config.token_usage_config import TokenUsageConfig
from helix.config.tool_config import ToolConfig, ToolGroupConfig
from helix.config.tool_output_config import ToolOutputConfig
from helix.config.tool_progress_config import ToolProgressConfig
from helix.config.tool_search_config import ToolSearchConfig, load_tool_search_config_from_dict

load_dotenv()

logger = logging.getLogger(__name__)


# database 段缺省时的默认值：sqlite 后端 + 状态目录下的 data 子目录。
CONFIG_FILE_DATABASE_DEFAULTS = {
    "backend": "sqlite",
    "sqlite_dir": ".helix/data",
}


class CircuitBreakerConfig(BaseModel):
    """LLM 熔断器配置。"""

    failure_threshold: int = Field(default=5, description="Number of consecutive failures before tripping the circuit")
    recovery_timeout_sec: int = Field(default=60, description="Time in seconds before attempting to recover the circuit")


class LoggingEnhanceConfig(BaseModel):
    """请求 trace 日志增强设置。"""

    enabled: bool = Field(default=False, description="Enable request-level trace ids in Gateway response headers and log records.")
    format: Literal["text", "json"] = Field(default="text", description="Enhanced log output format.")


class LoggingConfig(BaseModel):
    """日志配置。"""

    enhance: LoggingEnhanceConfig = Field(default_factory=LoggingEnhanceConfig, description="Request trace correlation logging settings.")


def is_trace_correlation_enabled(config: Any) -> bool:
    """当 *config* 上设置了 ``logging.enhance.enabled`` 时返回 ``True``。

    请求 trace 关联门控的唯一事实源，由 Gateway ``TraceMiddleware`` 与嵌入式
    ``HelixClient`` 共享，使两个入口对何时发射 ``helix_trace_id``（Langfuse
    元数据）、何时绑定请求级 trace id 不致漂移。接受任何经由 ``getattr`` 链
    暴露 ``logging.enhance.enabled`` 的对象（``AppConfig``、``SimpleNamespace``
    fixture 等）；缺失的中间属性静默降级为 ``False``。
    """
    logging_config = getattr(config, "logging", None)
    enhance = getattr(logging_config, "enhance", None)
    return bool(getattr(enhance, "enabled", False))


def _legacy_config_candidates() -> tuple[Path, ...]:
    """返回源码树里的 config.yaml 候选位置，用于 monorepo 兼容。"""
    legacy_root = Path(__file__).resolve().parents[4]
    repo_root = legacy_root.parent
    return (legacy_root / "config.yaml", repo_root / "config.yaml")


def logging_level_from_config(name: str | None) -> int:
    """把 ``config.yaml`` 的 ``log_level`` 字符串映射为 :mod:`logging` 级别常量。"""
    mapping = logging.getLevelNamesMapping()
    return mapping.get((name or "info").strip().upper(), logging.INFO)


def apply_logging_level(name: str | None) -> None:
    """把 *name* 解析为日志级别并应用到 ``helix``/``gateway`` logger 层级。

    只改 ``helix`` 与 ``gateway`` logger 级别，不影响第三方库（uvicorn、
    sqlalchemy 等）的冗余度。Root handler 级别只降不升，使配置 logger 的
    消息能传播出去，同时保留可能为第三方日志故意设高的 handler 阈值。
    """
    level = logging_level_from_config(name)
    for logger_name in ("helix", "gateway"):
        logging.getLogger(logger_name).setLevel(level)
    for handler in logging.root.handlers:
        if level < handler.level:
            handler.setLevel(level)
```

## §2 AppConfig 模型：字段 + validators + 加载管线

```python
# core/helix/config/app_config.py
class AppConfig(BaseModel):
    """Helix 应用的顶层配置。"""

    log_level: str = Field(
        default="info",
        description=format_field_description(
            "log_level",
            field_doc="Logging level for helix and gateway modules (debug/info/warning/error); third-party libraries are not affected.",
        ),
    )
    logging: LoggingConfig = Field(
        default_factory=LoggingConfig,
        description=format_field_description(
            "logging",
            field_doc="Structured logging and request trace correlation settings.",
        ),
    )
    token_usage: TokenUsageConfig = Field(default_factory=TokenUsageConfig, description="Token usage tracking configuration")
    token_budget: TokenBudgetConfig = Field(default_factory=TokenBudgetConfig, description="Token Budget tracking and limits configuration.")
    max_recursion_limit: int = Field(
        default=1000,
        ge=1,
        description="Hard server-side ceiling for a client-supplied run recursion_limit. Client values above this are clamped; prevents runaway LangGraph super-steps (LLM cost / DoS).",
    )
    models: list[ModelConfig] = Field(default_factory=list, description="Available models")
    sandbox: SandboxConfig = Field(
        description=format_field_description(
            "sandbox",
            field_doc="Sandbox provider configuration (local filesystem or Docker-based aio sandbox).",
        ),
    )
    tools: list[ToolConfig] = Field(default_factory=list, description="Available tools")
    tool_groups: list[ToolGroupConfig] = Field(default_factory=list, description="Available tool groups")
    skills: SkillsConfig = Field(default_factory=SkillsConfig, description="Skills configuration")
    skill_scan: SkillScanConfig = Field(default_factory=SkillScanConfig, description="Native deterministic skill safety scanning configuration")
    skill_evolution: SkillEvolutionConfig = Field(default_factory=SkillEvolutionConfig, description="Agent-managed skill evolution configuration")
    extensions: ExtensionsConfig = Field(default_factory=ExtensionsConfig, description="Extensions configuration (MCP servers and skills state)")
    tool_output: ToolOutputConfig = Field(default_factory=ToolOutputConfig, description="Tool output budget protection configuration")
    tool_search: ToolSearchConfig = Field(default_factory=ToolSearchConfig, description="Tool search / deferred loading configuration")
    title: TitleConfig = Field(default_factory=TitleConfig, description="Automatic title generation configuration")
    summarization: SummarizationConfig = Field(default_factory=SummarizationConfig, description="Conversation summarization configuration")
    memory: MemoryConfig = Field(default_factory=MemoryConfig, description="Memory subsystem configuration")
    agents_api: AgentsApiConfig = Field(default_factory=AgentsApiConfig, description="Custom-agent management API configuration")
    acp_agents: dict[str, ACPAgentConfig] = Field(default_factory=dict, description="ACP-compatible agent configuration")
    subagents: SubagentsAppConfig = Field(default_factory=SubagentsAppConfig, description="Subagent runtime configuration")
    guardrails: GuardrailsConfig = Field(default_factory=GuardrailsConfig, description="Guardrail middleware configuration")
    input_polish: InputPolishConfig = Field(default_factory=InputPolishConfig, description="Pre-send input polishing configuration.")
    suggestions: SuggestionsConfig = Field(default_factory=SuggestionsConfig, description="Follow-up suggestions configuration.")
    circuit_breaker: CircuitBreakerConfig = Field(default_factory=CircuitBreakerConfig, description="LLM circuit breaker configuration")
    channel_connections: ChannelConnectionsConfig = Field(
        default_factory=ChannelConnectionsConfig,
        description=format_field_description(
            "channel_connections",
            field_doc="User-facing IM channel connection configuration.",
        ),
    )
    loop_detection: LoopDetectionConfig = Field(default_factory=LoopDetectionConfig, description="Loop detection middleware configuration")
    tool_progress: ToolProgressConfig = Field(default_factory=ToolProgressConfig, description="Tool progress state machine middleware configuration")
    read_before_write: ReadBeforeWriteConfig = Field(default_factory=ReadBeforeWriteConfig, description="Read-before-write file gate middleware configuration")
    safety_finish_reason: SafetyFinishReasonConfig = Field(default_factory=SafetyFinishReasonConfig, description="Provider safety-filter finish_reason interception middleware configuration")
    auth: AuthAppConfig = Field(default_factory=AuthAppConfig, description="Authentication configuration (local + OIDC SSO)")
    model_config = ConfigDict(extra="allow")
    database: DatabaseConfig = Field(
        default_factory=DatabaseConfig,
        description=format_field_description(
            "database",
            field_doc="Unified database backend for run/feedback metadata (memory, sqlite, or postgres).",
        ),
    )
    run_events: RunEventsConfig = Field(
        default_factory=RunEventsConfig,
        description=format_field_description(
            "run_events",
            field_doc="Run-event store backend (memory for dev, db for production queries, jsonl for lightweight single-node persistence).",
        ),
    )
    scheduler: SchedulerConfig = Field(
        default_factory=SchedulerConfig,
        description=format_field_description(
            "scheduler",
            field_doc="Scheduled task runtime configuration (background poller for one-time and cron agent runs).",
        ),
    )
    checkpointer: CheckpointerConfig | None = Field(
        default=None,
        description=format_field_description(
            "checkpointer",
            field_doc="LangGraph state-persistence checkpointer configuration.",
        ),
    )
    stream_bridge: StreamBridgeConfig | None = Field(
        default=None,
        description=format_field_description(
            "stream_bridge",
            field_doc="Stream bridge connecting agent workers to SSE endpoints.",
        ),
    )

    # name -> config 查找表，验证后由 ``_build_name_indexes`` 重建。
    # 使 ``get_model_config`` / ``get_tool_config`` / ``get_tool_group_config``
    # 从 O(n) ``next(...)`` 扫描变为 O(1)。PrivateAttr 不参与序列化。
    _models_by_name: dict[str, ModelConfig] = PrivateAttr(default_factory=dict)
    _tools_by_name: dict[str, ToolConfig] = PrivateAttr(default_factory=dict)
    _tool_groups_by_name: dict[str, ToolGroupConfig] = PrivateAttr(default_factory=dict)

    @model_validator(mode="before")
    @classmethod
    def _drop_null_config_sections(cls, data: Any) -> Any:
        """把"存在但值为 None"的配置段当作缺失，让其默认值生效。

        把顶层 YAML key 下全部条目注释掉（例如 ``models:``（list）或
        ``memory:``（object），正如 ``config.example.yaml`` 全程 shipped 的
        样子）会让 PyYAML 把该值解析为 ``None``。没有这层兜底，文档化的
        ``cp config.example.yaml config.yaml`` 首次运行流程会因该段抛出
        ``Input should be a valid list`` / ``valid dictionary`` 的 pydantic
        错误而崩溃。

        丢掉 ``None`` 让每个字段回落到默认值：list 段经 ``default_factory=list``
        变 ``[]``，object 段拿到其默认配置。这把早期只处理 list 的逻辑推广
        到每个定义了默认值的段。``database`` 段独立，仍由 ``from_file`` 里的
        ``_apply_database_defaults`` 负责（施加超出 null 强转的具体默认值）。
        无默认值的必填段（``sandbox``）在 null 时仍故意报错--没有可回落的值。
        """
        if isinstance(data, dict):
            return {key: value for key, value in data.items() if value is not None}
        return data

    @classmethod
    def resolve_config_path(cls, config_path: str | None = None) -> Path:
        """解析配置文件路径。

        优先级：
        1. 显式传入的 ``config_path`` 参数。
        2. ``HELIX_CONFIG_PATH`` 环境变量。
        3. 调用方项目根下的 ``config.yaml``。
        4. 兜底：legacy backend / 仓库根默认位置（monorepo 兼容）。
        """
        if config_path:
            path = Path(config_path)
            if not Path.exists(path):
                raise FileNotFoundError(f"Config file specified by param `config_path` not found at {path}")
            return path
        elif os.getenv("HELIX_CONFIG_PATH"):
            path = Path(os.getenv("HELIX_CONFIG_PATH"))
            if not Path.exists(path):
                raise FileNotFoundError(f"Config file specified by environment variable `HELIX_CONFIG_PATH` not found at {path}")
            return path
        else:
            project_config = existing_project_file(("config.yaml",))
            if project_config is not None:
                return project_config

            for path in _legacy_config_candidates():
                if path.exists():
                    return path
            raise FileNotFoundError("`config.yaml` file not found in the project root or legacy backend/repository root locations")

    @classmethod
    def from_file(cls, config_path: str | None = None) -> Self:
        """从 YAML 文件加载配置。

        Args:
            config_path: 配置文件路径。

        Returns:
            AppConfig: 加载后的配置。
        """
        resolved_path = cls.resolve_config_path(config_path)
        with open(resolved_path, encoding="utf-8") as f:
            config_data = yaml.safe_load(f) or {}

        # 处理前先检查配置版本
        cls._check_config_version(config_data, resolved_path)

        config_data = cls.resolve_env_variables(config_data)
        cls._apply_database_defaults(config_data)

        # 单独加载扩展配置（它在另一个文件里）
        extensions_config = ExtensionsConfig.from_file()
        config_data["extensions"] = extensions_config.model_dump()

        result = cls.model_validate(config_data)
        if not result.models:
            logger.warning(
                "No models are configured in %s. Add at least one entry under `models:` (see the commented examples in config.example.yaml) or run `make setup`.",
                resolved_path,
            )
        acp_agents = cls._validate_acp_agents(config_data.get("acp_agents", {}))
        cls._apply_singleton_configs(result, acp_agents)
        return result

    @classmethod
    def _validate_acp_agents(
        cls,
        config_data: Mapping[str, Mapping[str, object]] | None,
    ) -> dict[str, ACPAgentConfig]:
        if config_data is None:
            config_data = {}
        return {name: ACPAgentConfig(**cfg) for name, cfg in config_data.items()}

    @classmethod
    def _apply_singleton_configs(cls, config: Self, acp_agents: dict[str, ACPAgentConfig]) -> None:
        """把验证后的子配置压平进对应模块级全局单例。

        这些 ``load_*_from_dict`` 让中间件无需每次 ``get_app_config().xxx``--
        对热路径友好。代价是重载时必须显式触发本方法。

        checkpointer 变更特例：检测到 ``previous_checkpointer_config !=
        config.checkpointer`` 时显式 ``reset_checkpointer()`` +
        ``reset_store()``，迫使下一次访问重建。这是"业务字段"里唯一带额外
        重置语义的字段，因为 checkpointer 常被显式切换（dev memory -> prod
        postgres）但不一定需要进程重启。import 局部化以避免循环：两个 provider
        都 import get_app_config。
        """
        from helix.config.checkpointer_config import get_checkpointer_config

        previous_checkpointer_config = get_checkpointer_config()

        load_title_config_from_dict(config.title.model_dump())
        load_summarization_config_from_dict(config.summarization.model_dump())
        load_memory_config_from_dict(config.memory.model_dump())
        load_agents_api_config_from_dict(config.agents_api.model_dump())
        load_subagents_config_from_dict(config.subagents.model_dump())
        load_tool_search_config_from_dict(config.tool_search.model_dump())
        load_guardrails_config_from_dict(config.guardrails.model_dump())
        load_checkpointer_config_from_dict(config.checkpointer.model_dump() if config.checkpointer is not None else None)
        load_stream_bridge_config_from_dict(config.stream_bridge.model_dump() if config.stream_bridge is not None else None)
        load_acp_config_from_dict({name: agent.model_dump() for name, agent in acp_agents.items()})

        if previous_checkpointer_config != config.checkpointer:
            # 这两个运行时单例的后端由 checkpointer 配置派生。
            # import 局部化以避免循环：两个 provider 都 import get_app_config。
            from helix.runtime.checkpointer import reset_checkpointer
            from helix.runtime.store import reset_store

            reset_checkpointer()
            reset_store()

    @classmethod
    def _apply_database_defaults(cls, config_data: dict[str, Any]) -> None:
        """当 database 段缺失时施加 config.yaml 的持久化默认值。"""
        database_config = config_data.get("database")
        if database_config is None:
            database_config = {}
            config_data["database"] = database_config
        if not isinstance(database_config, dict):
            return
        for key, value in CONFIG_FILE_DATABASE_DEFAULTS.items():
            database_config.setdefault(key, value)

    @classmethod
    def _check_config_version(cls, config_data: dict, config_path: Path) -> None:
        """检查用户的 config.yaml 是否落后于 config.example.yaml。

        用户 config_version 低于 example 时发 warning。缺失 config_version
        视为版本 0（前版本化时代）。不强制阻塞--单字段缺失通常只触发某 feature
        不可用，不应让所有用户卡在 boot 上。
        """
        try:
            user_version = int(config_data.get("config_version", 0))
        except (TypeError, ValueError):
            user_version = 0

        # 在 config.yaml 所在目录及其父目录向上搜 config.example.yaml
        example_path = None
        search_dir = config_path.parent
        for _ in range(5):  # 最多向上搜 5 层
            candidate = search_dir / "config.example.yaml"
            if candidate.exists():
                example_path = candidate
                break
            parent = search_dir.parent
            if parent == search_dir:
                break
            search_dir = parent
        if example_path is None:
            return

        try:
            with open(example_path, encoding="utf-8") as f:
                example_data = yaml.safe_load(f)
            raw = example_data.get("config_version", 0) if example_data else 0
            try:
                example_version = int(raw)
            except (TypeError, ValueError):
                example_version = 0
        except Exception:
            return

        if user_version < example_version:
            logger.warning(
                "Your config.yaml (version %d) is outdated - the latest version is %d. Run `make config-upgrade` to merge new fields into your config.",
                user_version,
                example_version,
            )

    @classmethod
    def resolve_env_variables(cls, config: Any) -> Any:
        """递归解析配置中的环境变量。

        环境变量用 ``os.getenv`` 解析。例：``$OPENAI_API_KEY``。

        主配置语义：以 ``$`` 开头的字符串若 ``os.getenv`` 未命中则直接抛
        ``ValueError``--快速失败优于运行时神秘 None。扩展配置（ExtensionsConfig）
        走另一套静默降级语义，见 env-and-extensions.md。
        """
        if isinstance(config, str):
            if config.startswith("$"):
                env_value = os.getenv(config[1:])
                if env_value is None:
                    raise ValueError(f"Environment variable {config[1:]} not found for config value {config}")
                return env_value
            return config
        elif isinstance(config, dict):
            return {k: cls.resolve_env_variables(v) for k, v in config.items()}
        elif isinstance(config, list):
            return [cls.resolve_env_variables(item) for item in config]
        return config

    @model_validator(mode="after")
    def _build_name_indexes(self) -> "AppConfig":
        """为 O(1) 的 ``get_*_config`` 构建 name -> config 查找表。

        ``get_tool_config`` 每次社区工具调用（如 web_search）跑 2-3 次，
        ``get_model_config`` 每次 agent 构建跑数次，所以早期 O(n) ``next(...)``
        扫描坐在热路径上。在此重建，使配置重载（构造新 ``AppConfig``）时同步
        刷新。``setdefault`` 在重名时保留首条，保持早期 ``next(...)`` 首匹配语义。
        """
        models_by_name: dict[str, ModelConfig] = {}
        for model in self.models:
            models_by_name.setdefault(model.name, model)
        tools_by_name: dict[str, ToolConfig] = {}
        for tool in self.tools:
            tools_by_name.setdefault(tool.name, tool)
        tool_groups_by_name: dict[str, ToolGroupConfig] = {}
        for group in self.tool_groups:
            tool_groups_by_name.setdefault(group.name, group)
        self._models_by_name = models_by_name
        self._tools_by_name = tools_by_name
        self._tool_groups_by_name = tool_groups_by_name
        return self

    def get_model_config(self, name: str) -> ModelConfig | None:
        """按 name 取 model 配置，找不到返回 None。"""
        return self._models_by_name.get(name)

    def get_tool_config(self, name: str) -> ToolConfig | None:
        """按 name 取 tool 配置，找不到返回 None。"""
        return self._tools_by_name.get(name)

    def get_tool_group_config(self, name: str) -> ToolGroupConfig | None:
        """按 name 取 tool group 配置，找不到返回 None。"""
        return self._tool_groups_by_name.get(name)
```

## §3 签名缓存单例层（mtime + size + sha256 三元组失效）

```python
# core/helix/config/app_config.py
# 兼容单例层：为尚未迁移到显式 ``AppConfig`` 透传的代码路径保留。
# 新的组合根应优先构造一次 ``AppConfig`` 并直接下传。
_app_config: AppConfig | None = None
_app_config_path: Path | None = None
_app_config_mtime: float | None = None
_ConfigSignature = tuple[float | None, int | None, str | None]
_app_config_signature: _ConfigSignature | None = None
_app_config_is_custom = False
_current_app_config: ContextVar[AppConfig | None] = ContextVar("helix_current_app_config", default=None)
_current_app_config_stack: ContextVar[tuple[AppConfig | None, ...]] = ContextVar("helix_current_app_config_stack", default=())


def _get_config_mtime(config_path: Path) -> float | None:
    """若配置文件存在则返回其修改时间。"""
    try:
        return config_path.stat().st_mtime
    except OSError:
        return None


def _get_config_signature(config_path: Path) -> _ConfigSignature | None:
    """取配置文件的缓存元数据，含内容摘要。

    返回 ``(mtime, size, sha256_hex)`` 三元组。为何不仅靠 mtime？在对象存储
    （S3 / GCS Fuse）或 NFS 网络挂载上，mtime 会"假性陈旧"--文件实际已变但
    stat 返回旧时间戳。把 size + 内容 sha256 加入签名，让网关与 langgraph
    runtime 的 config view 永远一致。
    """
    try:
        stat_result = config_path.stat()
    except OSError:
        return None

    digest = hashlib.sha256()
    try:
        with config_path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return (stat_result.st_mtime, stat_result.st_size, None)

    return (stat_result.st_mtime, stat_result.st_size, digest.hexdigest())


def _load_and_cache_app_config(config_path: str | None = None) -> AppConfig:
    """从磁盘加载配置并刷新缓存元数据。"""
    global _app_config, _app_config_path, _app_config_mtime, _app_config_signature, _app_config_is_custom

    resolved_path = AppConfig.resolve_config_path(config_path)
    _app_config = AppConfig.from_file(str(resolved_path))
    _app_config_path = resolved_path
    _app_config_mtime = _get_config_mtime(resolved_path)
    _app_config_signature = _get_config_signature(resolved_path)
    _app_config_is_custom = False
    return _app_config


def get_app_config() -> AppConfig:
    """取 Helix 配置实例。

    返回缓存的单例，并在底层配置文件路径或内容签名变化时自动重载。
    用 ``reload_app_config()`` 强制重载，或 ``reset_app_config()`` 清缓存。

    reload 判定：``_app_config is None or _app_config_path != resolved_path
    or _app_config_signature != current_signature``。``_app_config_is_custom``
    标记 ``set_app_config()`` 注入的实例（测试 / 外部注入），跳过签名检查避免
    被磁盘文件覆盖。``_current_app_config`` ContextVar 提供请求级覆盖（运维 /
    测试用），优先级最高，绕过缓存。
    """
    global _app_config, _app_config_path, _app_config_mtime, _app_config_signature

    runtime_override = _current_app_config.get()
    if runtime_override is not None:
        return runtime_override

    if _app_config is not None and _app_config_is_custom:
        return _app_config

    resolved_path = AppConfig.resolve_config_path()
    current_mtime = _get_config_mtime(resolved_path)
    current_signature = _get_config_signature(resolved_path)

    should_reload = _app_config is None or _app_config_path != resolved_path or _app_config_signature != current_signature
    if should_reload:
        if _app_config_path == resolved_path and _app_config_mtime is not None and current_mtime is not None and _app_config_mtime != current_mtime:
            logger.info(
                "Config file has been modified (mtime: %s -> %s), reloading AppConfig",
                _app_config_mtime,
                current_mtime,
            )
        elif _app_config_path == resolved_path and _app_config_signature != current_signature:
            logger.info("Config file content signature changed, reloading AppConfig")
        _load_and_cache_app_config(str(resolved_path))
    return _app_config


def reload_app_config(config_path: str | None = None) -> AppConfig:
    """从文件重载配置并更新缓存实例。

    当配置文件被修改、想不重启就生效时有用。
    """
    return _load_and_cache_app_config(config_path)


def reset_app_config() -> None:
    """清空缓存的单例实例。

    下次 ``get_app_config()`` 会从文件重载。用于测试或在多套配置间切换。
    """
    global _app_config, _app_config_path, _app_config_mtime, _app_config_signature, _app_config_is_custom
    _app_config = None
    _app_config_path = None
    _app_config_mtime = None
    _app_config_signature = None
    _app_config_is_custom = False


def set_app_config(config: AppConfig) -> None:
    """注入自定义配置实例（测试用）。

    ``_app_config_is_custom = True`` 让自动签名检测跳过，保证测试期内配置
    保持不变。
    """
    global _app_config, _app_config_path, _app_config_mtime, _app_config_signature, _app_config_is_custom
    _app_config = config
    _app_config_path = None
    _app_config_mtime = None
    _app_config_signature = None
    _app_config_is_custom = True


def peek_current_app_config() -> AppConfig | None:
    """返回当前生效的运行时级 AppConfig 覆盖（若有）。

    不触发 reload，供日志/审计场景使用--避免在审计回调里触发 IO 引发递归告警。
    """
    return _current_app_config.get()


def push_current_app_config(config: AppConfig) -> None:
    """为当前执行上下文压入一个运行时级 AppConfig 覆盖。"""
    stack = _current_app_config_stack.get()
    _current_app_config_stack.set(stack + (_current_app_config.get(),))
    _current_app_config.set(config)


def pop_current_app_config() -> None:
    """弹出当前执行上下文最新的运行时级 AppConfig 覆盖。"""
    stack = _current_app_config_stack.get()
    if not stack:
        _current_app_config.set(None)
        return
    previous = stack[-1]
    _current_app_config_stack.set(stack[:-1])
    _current_app_config.set(previous)
```

## §4 共享路径解析（runtime_paths.py）

> `resolve_config_path()` 与 `ExtensionsConfig.resolve_config_path()` 都依赖 `existing_project_file()`，后者基于 `project_root()` / `runtime_home()`。env 前缀统一为 `HELIX_*`，状态目录 `.helix`。

```python
# core/helix/config/runtime_paths.py
"""独立 core 框架使用场景下的运行时路径解析。"""

import os
from pathlib import Path


def project_root() -> Path:
    """返回调用方项目根（运行时自有文件的归宿）。"""
    if env_root := os.getenv("HELIX_PROJECT_ROOT"):
        root = Path(env_root).resolve()
        if not root.exists():
            raise ValueError(f"HELIX_PROJECT_ROOT is set to '{env_root}', but the resolved path '{root}' does not exist.")
        if not root.is_dir():
            raise ValueError(f"HELIX_PROJECT_ROOT is set to '{env_root}', but the resolved path '{root}' is not a directory.")
        return root
    return Path.cwd().resolve()


def runtime_home() -> Path:
    """返回可写的 Helix 状态目录。"""
    if env_home := os.getenv("HELIX_HOME"):
        return Path(env_home).resolve()
    return project_root() / ".helix"


def resolve_path(value: str | os.PathLike[str], *, base: Path | None = None) -> Path:
    """绝对路径原样解析，相对路径基于项目根解析。"""
    path = Path(value)
    if not path.is_absolute():
        path = (base or project_root()) / path
    return path.resolve()


def existing_project_file(names: tuple[str, ...]) -> Path | None:
    """返回项目根下第一个存在的具名文件。"""
    root = project_root()
    for name in names:
        candidate = root / name
        if candidate.is_file():
            return candidate
    return None
```

## §5 关键热重载测试（签名失效不变量）

> 以下测试取自 `tests/test_app_config_reload.py`，钉住签名缓存的四条不变量：(1) mtime 变化触发重载；(2) mtime/size 假性陈旧时 sha256 内容摘要仍能触发重载；(3) 配置路径切换触发重载；(4) 重载校验失败时不污染已有单例（原子性）。

```python
# tests/test_app_config_reload.py（节选）
import json
import os
from pathlib import Path

import pytest
import yaml
from pydantic import ValidationError

import helix.config.app_config as app_config_module
from helix.config.app_config import AppConfig, get_app_config, reset_app_config
from helix.config.checkpointer_config import get_checkpointer_config, load_checkpointer_config_from_dict
from helix.runtime.checkpointer import get_checkpointer, reset_checkpointer
from helix.runtime.store import get_store, reset_store
# ... 其余 load_*_from_dict / get_*_config 导入省略，见真实测试文件


def _write_config(path: Path, *, model_name: str, supports_thinking: bool) -> None:
    path.write_text(
        yaml.safe_dump(
            {
                "sandbox": {"use": "helix.sandbox.local:LocalSandboxProvider"},
                "models": [
                    {
                        "name": model_name,
                        "use": "langchain_openai:ChatOpenAI",
                        "model": "gpt-test",
                        "supports_thinking": supports_thinking,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )


def _write_extensions_config(path: Path) -> None:
    path.write_text(json.dumps({"mcpServers": {}, "skills": {}}), encoding="utf-8")


def test_get_app_config_reloads_when_file_changes(tmp_path, monkeypatch):
    """mtime 变化 -> 下一次 get_app_config() 自动重载，返回新实例。"""
    config_path = tmp_path / "config.yaml"
    extensions_path = tmp_path / "extensions_config.json"
    _write_extensions_config(extensions_path)
    _write_config(config_path, model_name="first-model", supports_thinking=False)

    monkeypatch.setenv("HELIX_CONFIG_PATH", str(config_path))
    monkeypatch.setenv("HELIX_EXTENSIONS_CONFIG_PATH", str(extensions_path))
    reset_app_config()

    try:
        initial = get_app_config()
        assert initial.models[0].supports_thinking is False

        _write_config(config_path, model_name="first-model", supports_thinking=True)
        next_mtime = config_path.stat().st_mtime + 5
        os.utime(config_path, (next_mtime, next_mtime))

        reloaded = get_app_config()
        assert reloaded.models[0].supports_thinking is True
        assert reloaded is not initial
    finally:
        reset_app_config()


def test_get_app_config_reloads_when_content_digest_changes_without_metadata(tmp_path, monkeypatch):
    """mtime 与 size 假性陈旧时，sha256 内容摘要仍触发重载。

    模拟网络挂载 stat 不更新：patch _get_config_mtime 返回旧 mtime、
    _get_config_signature 返回 (旧 mtime, 旧 size, 新 sha256)。should_reload
    因签名三元组不等而成立 -> 重载拿到 model-b。
    """
    config_path = tmp_path / "config.yaml"
    extensions_path = tmp_path / "extensions_config.json"
    _write_extensions_config(extensions_path)
    _write_config(config_path, model_name="model-a", supports_thinking=False)

    monkeypatch.setenv("HELIX_CONFIG_PATH", str(config_path))
    monkeypatch.setenv("HELIX_EXTENSIONS_CONFIG_PATH", str(extensions_path))
    _reset_config_singletons()

    try:
        initial = get_app_config()
        initial_mtime = app_config_module._app_config_mtime
        initial_signature = app_config_module._app_config_signature
        assert initial.models[0].name == "model-a"
        assert initial_signature is not None

        _write_config(config_path, model_name="model-b", supports_thinking=False)

        real_get_config_signature = app_config_module._get_config_signature

        def stale_metadata_signature(path: Path):
            current_signature = real_get_config_signature(path)
            assert current_signature is not None
            return (initial_signature[0], initial_signature[1], current_signature[2])

        monkeypatch.setattr(app_config_module, "_get_config_mtime", lambda _path: initial_mtime)
        monkeypatch.setattr(app_config_module, "_get_config_signature", stale_metadata_signature)

        reloaded = get_app_config()
        assert reloaded.models[0].name == "model-b"
        assert reloaded is not initial
        assert app_config_module._app_config_signature is not None
        assert app_config_module._app_config_signature[:2] == initial_signature[:2]
        assert app_config_module._app_config_signature[2] != initial_signature[2]
    finally:
        _reset_config_singletons()


def test_get_app_config_reloads_when_config_path_changes(tmp_path, monkeypatch):
    """解析到的配置路径变化（env 切换）-> 触发重载，返回新实例。"""
    config_a = tmp_path / "config-a.yaml"
    config_b = tmp_path / "config-b.yaml"
    extensions_path = tmp_path / "extensions_config.json"
    _write_extensions_config(extensions_path)
    _write_config(config_a, model_name="model-a", supports_thinking=False)
    _write_config(config_b, model_name="model-b", supports_thinking=True)

    monkeypatch.setenv("HELIX_EXTENSIONS_CONFIG_PATH", str(extensions_path))
    monkeypatch.setenv("HELIX_CONFIG_PATH", str(config_a))
    reset_app_config()

    try:
        first = get_app_config()
        assert first.models[0].name == "model-a"

        monkeypatch.setenv("HELIX_CONFIG_PATH", str(config_b))
        second = get_app_config()
        assert second.models[0].name == "model-b"
        assert second is not first
    finally:
        reset_app_config()


def test_get_app_config_does_not_mutate_singletons_when_reload_validation_fails(tmp_path, monkeypatch):
    """重载时校验失败（ValidationError）-> 已缓存的旧实例与子配置单例不被污染。

    原子性不变量：_load_and_cache_app_config 先调 from_file（可能抛），只有
    成功后才写回 _app_config 等全局；故失败的 reload 不会留下半成品。
    """
    config_path = tmp_path / "config.yaml"
    extensions_path = tmp_path / "extensions_config.json"
    _write_extensions_config(extensions_path)
    _write_config_with_sections(
        config_path,
        {
            "title": {"enabled": False},
            "tool_search": {"enabled": True},
            "checkpointer": {"type": "memory"},
        },
    )

    monkeypatch.setenv("HELIX_CONFIG_PATH", str(config_path))
    monkeypatch.setenv("HELIX_EXTENSIONS_CONFIG_PATH", str(extensions_path))
    _reset_config_singletons()

    try:
        previous_app_config = get_app_config()
        initial_checkpointer = get_checkpointer()
        initial_store = get_store()

        # title: False / tool_search: False 非法（应为 dict），触发 ValidationError
        _write_config_with_sections(
            config_path,
            {
                "title": False,
                "tool_search": False,
                "checkpointer": {"type": "memory"},
            },
        )
        next_mtime = config_path.stat().st_mtime + 5
        os.utime(config_path, (next_mtime, next_mtime))

        with pytest.raises(ValidationError):
            get_app_config()

        assert app_config_module._app_config is previous_app_config
        assert get_title_config().enabled is False
        assert get_tool_search_config().enabled is True
        assert get_checkpointer_config() is not None
        assert get_checkpointer() is initial_checkpointer
        assert get_store() is initial_store
    finally:
        _reset_config_singletons()


def test_get_app_config_resets_persistence_runtime_singletons_when_checkpointer_removed(tmp_path, monkeypatch):
    """checkpointer 段被移除 -> _apply_singleton_configs 检测到变化 ->
    reset_checkpointer() + reset_store()，下一次访问重建。"""
    config_path = tmp_path / "config.yaml"
    extensions_path = tmp_path / "extensions_config.json"
    _write_extensions_config(extensions_path)
    _write_config_with_sections(config_path, {"checkpointer": {"type": "memory"}})

    monkeypatch.setenv("HELIX_CONFIG_PATH", str(config_path))
    monkeypatch.setenv("HELIX_EXTENSIONS_CONFIG_PATH", str(extensions_path))
    reset_checkpointer()
    reset_store()
    reset_app_config()

    try:
        get_app_config()
        initial_checkpointer = get_checkpointer()
        initial_store = get_store()

        _write_config_with_sections(config_path)
        next_mtime = config_path.stat().st_mtime + 5
        os.utime(config_path, (next_mtime, next_mtime))

        get_app_config()

        assert get_checkpointer_config() is None
        assert get_checkpointer() is not initial_checkpointer
        assert get_store() is not initial_store
    finally:
        _reset_config_singletons()


def test_get_app_config_keeps_persistence_runtime_singletons_when_checkpointer_unchanged(tmp_path, monkeypatch):
    """checkpointer 段不变（只改其他段）-> 不触发 reset_checkpointer/reset_store，
    复用已有实例。这是 checkpointer 特例的"不变则不动"另一半。"""
    config_path = tmp_path / "config.yaml"
    extensions_path = tmp_path / "extensions_config.json"
    _write_extensions_config(extensions_path)
    _write_config_with_sections(
        config_path,
        {
            "title": {"enabled": False},
            "checkpointer": {"type": "memory"},
        },
    )

    monkeypatch.setenv("HELIX_CONFIG_PATH", str(config_path))
    monkeypatch.setenv("HELIX_EXTENSIONS_CONFIG_PATH", str(extensions_path))
    _reset_config_singletons()

    try:
        get_app_config()
        initial_checkpointer = get_checkpointer()
        initial_store = get_store()

        _write_config_with_sections(
            config_path,
            {
                "title": {"enabled": True},
                "checkpointer": {"type": "memory"},
            },
        )
        next_mtime = config_path.stat().st_mtime + 5
        os.utime(config_path, (next_mtime, next_mtime))

        get_app_config()

        assert get_checkpointer() is initial_checkpointer
        assert get_store() is initial_store
    finally:
        _reset_config_singletons()
```
