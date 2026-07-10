# 完整源码：热重载边界注册表 + 反射动态导入

> 本文件给出两部分完整实现：(1) `core/helix/config/reload_boundary.py` -- `STARTUP_ONLY_FIELDS` 注册表（字段路径 -> 人类可读重启理由）、`STARTUP_ONLY_PREFIX` 标准前缀、`format_field_description()` 把前缀同步进 Pydantic `Field.description`、`is_startup_only_field()` / `iter_startup_only_field_paths()`，以及 `tests/test_reload_boundary.py` 的**双向漂移测试**；(2) `core/helix/reflection/resolvers.py` -- `resolve_variable()` / `resolve_class()` 反射动态导入 + `_build_missing_dependency_hint()` 缺包安装提示。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`、logger 层级 `helix`/`gateway`、trace id `helix_trace_id`），去除一切项目字样。原代码注释保留以保真。

## §1 热重载边界注册表（reload_boundary.py）

```python
# core/helix/config/reload_boundary.py
"""配置热重载边界的唯一事实源。

issue #3144：网关请求依赖每次请求都经 ``get_app_config()`` 解析 ``AppConfig``，
故 per-run 字段在下一条消息即生效、无需重启网关。本模块列出的字段是网关在
启动期**一次性捕获**的基础设施子集--engine、单例、IM 客户端、日志 handler--
因此改它们需要重启进程。

注册表覆盖两类条目：

- 顶层 ``AppConfig`` 字段（``database``、``checkpointer``、``run_events``、
  ``stream_bridge``、``sandbox``、``log_level``、``logging``、
  ``channel_connections``、``scheduler``）。对这类字段，
  :func:`format_field_description` 产出标准化的 ``"startup-only: ..."`` 前缀，
  写进对应 Pydantic ``Field(description=...)``，使边界在 IDE 悬停时直接可见。
- 顶层 ``config.yaml`` 段但**不在** ``AppConfig`` schema 内（``channels``）。
  这类无法在 schema 层标准化，注册表是它们唯一的权威位置。

任何未来的"需重启"扫描器--运维工具、lint hook、文档生成器--都应基于本注册表
驱动，而非重新解析散文。
"""

from __future__ import annotations

from collections.abc import Iterator

#: 每个需重启字段 description 的标准前缀。``test_reload_boundary`` 双向强制：
#: 注册表里的字段必须在 schema 里用此前缀；schema 里用此前缀的字段必须在注册表里。
STARTUP_ONLY_PREFIX = "startup-only:"


#: 需重启字段路径 -> 人类可读理由。
#:
#: 理由文本会出现在 ``Field(description=...)`` 里，故必须解释**哪段代码捕获了
#: 快照**--而不仅仅是"该字段需重启"--让改值的运维知道该重启哪个子系统。
STARTUP_ONLY_FIELDS: dict[str, str] = {
    "database": ("init_engine_from_config() runs once during langgraph_runtime() startup; the SQLAlchemy engine holds the connection pool and is not rebuilt on config.yaml edits."),
    "checkpointer": ("make_checkpointer() binds the persistent checkpointer once at startup, including SQLite WAL / busy_timeout settings."),
    "run_events": ("make_run_event_store() picks the memory- vs SQL-backed implementation at startup and is frozen onto app.state.run_events_config to stay paired with the underlying event store."),
    "stream_bridge": ("make_stream_bridge() constructs the stream-bridge singleton once during startup."),
    "sandbox": ("get_sandbox_provider() caches the provider singleton (``_default_sandbox_provider``); a different ``sandbox.use`` class path only takes effect on next process start."),
    "log_level": (
        "apply_logging_level() runs only during Gateway startup; it sets the helix/gateway logger levels and may lower root handler thresholds so configured messages can propagate. A freshly reloaded AppConfig does not retrigger it."
    ),
    "logging": (
        "configure_logging() runs only during Gateway startup; it installs/removes the trace-context filter and the enhanced formatter on root handlers, "
        "and TraceMiddleware captures logging.enhance.enabled once at startup so response X-Trace-Id headers, log trace_id fields, and Langfuse "
        "helix_trace_id stay coherent. A freshly reloaded AppConfig does not retrigger any of this."
    ),
    # 不在 AppConfig Pydantic schema 内--channel 凭证由 ``start_channel_service()``
    # 在 lifespan 启动期一次性消费，config.yaml 改动不会重建活跃 channel 客户端。
    "channels": ("start_channel_service() is invoked once during startup; the live IM channel clients (Feishu, Slack, Telegram, DingTalk) are not rebuilt when channels.* changes."),
    "channel_connections": (
        "start_channel_service() wires the connection repository and channel workers once at startup, and the channel-connections router caches the merged provider config on app.state; channel_connections.* edits need a restart."
    ),
    "scheduler": (
        "ScheduledTaskService is constructed and started once during Gateway lifespan startup; enabled, poll_interval_seconds, lease_seconds, "
        "and max_concurrent_runs are captured into the service instance and the background poller task is not rebuilt on config.yaml edits."
    ),
}


def iter_startup_only_field_paths() -> Iterator[str]:
    """产出每个已注册的需重启字段路径。"""
    return iter(STARTUP_ONLY_FIELDS)


def is_startup_only_field(field_path: str) -> bool:
    """*field_path* 已注册为需重启时返回 ``True``。

    只接受顶层路径（``"database"``、``"sandbox"`` 等）；``"database.url"`` 这类
    嵌套 key 不在此建模，因为边界是按段而非按叶子。
    """
    return field_path in STARTUP_ONLY_FIELDS


def format_field_description(field_path: str, *, field_doc: str | None = None) -> str:
    """为已注册字段构建标准化 description。

    在 ``AppConfig`` 的 ``Field(description=...)`` 内使用，使 IDE 悬停文本与
    注册表一致，且漂移测试能把一侧钉住另一侧。

    Args:
        field_path: 已注册的顶层字段路径（如 ``"log_level"``）。
        field_doc: 字段本身的可选人类面向描述（允许值、语义等）。提供时追加在
            ``startup-only:`` 标记块之后、以空行分隔，使 IDE 悬停同时显示重启
            理由与字段常规文档。组合时保持标记为机器可读工具旋转的首 token，
            同时恢复 ``Field(description=)`` 在注册表接管前承载的散文。

    Raises:
        KeyError: *field_path* 未注册时。这是故意的--静默返回占位符会让拼写
            错误绕过漂移覆盖。
    """
    reason = STARTUP_ONLY_FIELDS[field_path]
    header = f"{STARTUP_ONLY_PREFIX} {reason}"
    if field_doc is None:
        return header
    return f"{header}\n\n{field_doc.strip()}"
```

## §2 边界漂移测试（双向校验，test_reload_boundary.py）

> 注册表与 Pydantic schema 双向钉死：注册表里每个 schema 内字段必须带 `startup-only:` 前缀；schema 里带前缀的字段必须在注册表里。任一侧偷加字段都会被红。完整测试文件含 9 个用例，以下给出钉住双向不变量的核心几个。

```python
# tests/test_reload_boundary.py（节选）
from __future__ import annotations

import pytest

from helix.config.app_config import AppConfig
from helix.config.reload_boundary import (
    STARTUP_ONLY_FIELDS,
    STARTUP_ONLY_PREFIX,
    format_field_description,
    is_startup_only_field,
    iter_startup_only_field_paths,
)


def test_registry_has_a_reason_for_every_field():
    """每个注册表条目必须解释*为什么*该字段需重启。

    理由文本会出现在 IDE 悬停与 AppConfig schema description 里，空/占位值
    会让这层意义失效。
    """
    for field_path, reason in STARTUP_ONLY_FIELDS.items():
        assert reason.strip(), f"empty reason for {field_path}"
        assert len(reason) > 20, f"reason for {field_path} too short to be useful: {reason!r}"


def test_is_startup_only_field_recognises_registered_fields():
    """成员判定 helper 接受每个已注册字段路径。"""
    for field_path in STARTUP_ONLY_FIELDS:
        assert is_startup_only_field(field_path)
    assert not is_startup_only_field("memory")  # 可热重载
    assert not is_startup_only_field("models")
    assert not is_startup_only_field("nonexistent_field")


def test_format_field_description_rejects_unknown_field():
    """未注册字段抛 KeyError（而非静默占位），让拼写错误被漂移覆盖抓住。"""
    with pytest.raises(KeyError):
        format_field_description("not_in_registry")


def test_format_field_description_appends_optional_field_doc():
    """组合器把 startup-only 标记与字段自身的人类面向文档拼在一起。

    原 ``Field(description=)`` 曾文档化允许值（如 ``log_level`` 列了
    ``debug/info/warning/error``）；注册表接管不能丢这些。组合输出保持标记为
    首 token 让机器可读工具仍能旋转，然后空行后追加散文。
    """
    text = format_field_description("log_level", field_doc="Logging level (debug/info/warning/error).")
    assert text.startswith(STARTUP_ONLY_PREFIX)
    assert STARTUP_ONLY_FIELDS["log_level"] in text
    assert "debug/info/warning/error" in text


def test_appconfig_schema_marks_registered_fields_with_prefix():
    """注册表里每个对应顶层 AppConfig 字段的条目，其 Pydantic
    ``Field(description=...)`` 必须带标准化 ``startup-only:`` 前缀。
    这是 IDE 悬停依赖的契约。
    """
    schema_fields = AppConfig.model_fields
    for field_path in STARTUP_ONLY_FIELDS:
        if field_path not in schema_fields:
            # 某些条目（如 ``channels``）不在 AppConfig schema 内。注册表仍拥有
            # 它们，但 schema 前缀断言不适用。
            continue
        description = schema_fields[field_path].description or ""
        assert description.startswith(STARTUP_ONLY_PREFIX), f"AppConfig.{field_path} should have Field(description=) starting with {STARTUP_ONLY_PREFIX!r}, got {description!r}"


def test_no_appconfig_field_uses_prefix_without_registration():
    """反向漂移检查：若未来 schema 编辑给新字段加了 ``startup-only:`` 前缀，
    注册表必须列出它。

    这抓住"在 schema 里标了需重启但忘了更新注册表"的静默漂移--而注册表正是
    运维侧扫描器与文档消费的来源。
    """
    for name, info in AppConfig.model_fields.items():
        description = info.description or ""
        if not description.startswith(STARTUP_ONLY_PREFIX):
            continue
        assert name in STARTUP_ONLY_FIELDS, f"AppConfig.{name} schema description starts with {STARTUP_ONLY_PREFIX!r} but the field is not listed in reload_boundary.STARTUP_ONLY_FIELDS - update the registry."


def test_pydantic_field_descriptions_are_introspectable_at_runtime():
    """``AppConfig.model_fields[name].description`` 是 IDE 悬停的来源。

    若这个读取某天失效（如 Pydantic 弃用、schema 替换），issue #3144 承诺的
    IDE 悬停保证会静默退化。钉住它。
    """
    assert "database" in AppConfig.model_fields
    description = AppConfig.model_fields["database"].description
    assert description is not None
    assert description.startswith(STARTUP_ONLY_PREFIX)
```

## §3 反射动态导入（reflection/resolvers.py）

> `resolve_variable()` / `resolve_class()` 是可插拔组件的统一加载口：`models[].use = "langchain_openai:ChatOpenAI"` -> `resolve_class()`；`tools[].use = "helix.tools.builtins.web_search:web_search"` -> `resolve_variable()`；`sandbox.use` / `guardrails.provider.use` / `safety_finish_reason.detectors[].use` / MCP 拦截器 / skills 存储后端同理。`module:variable` 分割 + `import_module` + `getattr` + 类型校验；`ImportError` 时拼出可执行的 `uv add <package>` 安装提示。

```python
# core/helix/reflection/resolvers.py
from importlib import import_module

# 已知集成包的 module-root -> pip/uv 包名映射，用于拼装缺包安装提示。
# 即使 ImportError 由传递依赖触发（如 google），也优先给 provider 包提示。
MODULE_TO_PACKAGE_HINTS = {
    "langchain_google_genai": "langchain-google-genai",
    "langchain_anthropic": "langchain-anthropic",
    "langchain_openai": "langchain-openai",
    "langchain_deepseek": "langchain-deepseek",
}


def _build_missing_dependency_hint(module_path: str, err: ImportError) -> str:
    """模块导入失败时构建可执行的安装提示。"""
    module_root = module_path.split(".", 1)[0]
    missing_module = getattr(err, "name", None) or module_root

    # 对已知集成，即使 ImportError 由传递依赖触发也优先给 provider 包提示。
    package_name = MODULE_TO_PACKAGE_HINTS.get(module_root)
    if package_name is None:
        package_name = MODULE_TO_PACKAGE_HINTS.get(missing_module, missing_module.replace("_", "-"))

    return f"Missing dependency '{missing_module}'. Install it with `uv add {package_name}` (or `pip install {package_name}`), then restart Helix."


def resolve_variable[T](
    variable_path: str,
    expected_type: type[T] | tuple[type, ...] | None = None,
) -> T:
    """从路径解析一个变量。

    Args:
        variable_path: 变量路径（如 "parent_package_name.sub_package_name.module_name:variable_name"）。
        expected_type: 可选的类型或类型元组，用于校验解析出的变量。
            提供时用 isinstance() 检查变量是否为期望类型（的实例）。

    Returns:
        解析出的变量。

    Raises:
        ImportError: 模块路径非法或属性不存在。缺包时附带 ``uv add`` 安装提示。
        ValueError: 解析出的变量未通过类型校验。
    """
    try:
        module_path, variable_name = variable_path.rsplit(":", 1)
    except ValueError as err:
        raise ImportError(f"{variable_path} doesn't look like a variable path. Example: parent_package_name.sub_package_name.module_name:variable_name") from err

    try:
        module = import_module(module_path)
    except ImportError as err:
        module_root = module_path.split(".", 1)[0]
        err_name = getattr(err, "name", None)
        if isinstance(err, ModuleNotFoundError) or err_name == module_root:
            hint = _build_missing_dependency_hint(module_path, err)
            raise ImportError(f"Could not import module {module_path}. {hint}") from err
        # 非缺模块的失败保留原始 ImportError 消息。
        raise ImportError(f"Error importing module {module_path}: {err}") from err

    try:
        variable = getattr(module, variable_name)
    except AttributeError as err:
        raise ImportError(f"Module {module_path} does not define a {variable_name} attribute/class") from err

    # 类型校验
    if expected_type is not None:
        if not isinstance(variable, expected_type):
            type_name = expected_type.__name__ if isinstance(expected_type, type) else " or ".join(t.__name__ for t in expected_type)
            raise ValueError(f"{variable_path} is not an instance of {type_name}, got {type(variable).__name__}")

    return variable


def resolve_class[T](class_path: str, base_class: type[T] | None = None) -> type[T]:
    """从模块路径和类名解析一个类。

    Args:
        class_path: 类路径（如 "langchain_openai:ChatOpenAI"）。
        base_class: 基类，校验解析出的类是否为其子类。

    Returns:
        解析出的类。

    Raises:
        ImportError: 模块路径非法或属性不存在。
        ValueError: 解析出的对象不是类，或不是 base_class 的子类。
    """
    model_class = resolve_variable(class_path, expected_type=type)

    if not isinstance(model_class, type):
        raise ValueError(f"{class_path} is not a valid class")

    if base_class is not None and not issubclass(model_class, base_class):
        raise ValueError(f"{class_path} is not a subclass of {base_class.__name__}")

    return model_class
```

## §4 反射调用点（可插拔组件清单）

> 以下调用点均经 `resolve_variable()` / `resolve_class()` 加载，新组件不改主代码、只改配置里的 `use` 字段。反射在**冷启动**时跑一次（沙箱 / 存储后端）或**每次 agent 构建时**跑（模型 / 工具），结果由各子系统的单例缓存持有，不重复 import。

| 调用点 | 解析函数 | base_class / expected_type | 配置字段 |
|---|---|---|---|
| 模型工厂 | `resolve_class(model_config.use, BaseChatModel)` | `BaseChatModel` | `models[].use` |
| 沙箱 provider | `resolve_class(config.sandbox.use, SandboxProvider)` | `SandboxProvider` | `sandbox.use` |
| 内置工具加载 | `resolve_variable(cfg.use, BaseTool)` | `BaseTool` | `tools[].use` |
| Skills 存储后端 | `resolve_class(skills_config.use, SkillStorage)` | `SkillStorage` | `skills.use` |
| Guardrail provider | `resolve_variable(guardrails_config.provider.use)` | -- | `guardrails.provider.use` |
| Safety finish_reason 探测器 | `resolve_variable(entry.use)` | -- | `safety_finish_reason.detectors[].use` |
| MCP 工具拦截器 | `resolve_variable(interceptor_path)` | -- | MCP server 配置 |

> **沙箱 provider 冷启动竞争**（`get_sandbox_provider()`）：`resolve_class` + 构造器在锁外跑（插件代码不能在非重入锁下执行）；构造可能与他人竞争，输家在锁内取赢家实例、并 `shutdown()` 自己建的孤儿（带副作用的构造器如 AioSandboxProvider 会起 idle-checker 线程，不拆会泄漏）。
