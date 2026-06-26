---
name: config-and-hot-reload
description: 设计 agent 系统的配置体系——AppConfig 签名缓存热重载、STARTUP_ONLY_FIELDS 注册表、反射动态导入（resolve_variable / resolve_class）、$ENV 替换、bootstrap_schema 三分支、版本漂移检测。
---

## 何时用

- 系统有多种"可插拔"组件（模型 / 沙箱 / Guardrail / 追踪 / channel）需要 yaml 配置驱动
- 用户希望改配置不重启就生效（per-run 字段）
- 又有一些字段（DB / checkpointer / 端口）必须重启
- 配置含敏感值（API key）想用环境变量代入
- 从无 schema 升级到带 schema 时需要平滑迁移

## 设计思想

1. **单一 `AppConfig` 数据类**（Pydantic）：所有模块从这里读；不在各处 `os.environ.get`。
2. **签名缓存热重载**：cache 用 `(path, mtime, size, content_digest)` 做 key；文件变了下一次 `get_app_config()` 自动重载，无需重启。
3. **`STARTUP_ONLY_FIELDS` 注册表**：哪些字段改了必须重启，集中声明 + Pydantic field 上加 `description="startup-only: ..."` 双重标注；测试守护防止漂移。
4. **反射动态导入**：`tools[].use = "module.path:variable"` → `resolve_variable()`；`sandbox.use = "module.path:ClassName"` → `resolve_class()`；新组件不改主代码。
5. **`$ENV` 替换**：值以 `$` 开头的字符串解析为环境变量；多环境部署只换 env，配置文件不动。
6. **版本漂移检测**：`config_version` 字段；启动时对比 example 版本，落后则 warn + 提示 `make config-upgrade`。
7. **DB schema bootstrap 三分支**：empty / legacy（有表无 alembic）/ versioned，自动 create_all + stamp + upgrade，**不让用户手动跑 alembic**。

## 实现模板

### AppConfig 骨架

```python
class ModelConfig(BaseModel):
    name: str
    use: str                  # "agent_framework.models.factory:ChatOpenAI"
    supports_thinking: bool = False
    supports_vision: bool = False
    when_thinking_enabled: dict = Field(default_factory=dict)


class AppConfig(BaseModel):
    config_version: int = 0
    log_level: str = Field("INFO", description="startup-only: changing log level requires restart")
    database: DatabaseConfig = Field(..., description="startup-only: database backend")
    models: list[ModelConfig] = Field(default_factory=list)
    sandbox: SandboxConfig = Field(..., description="startup-only: sandbox provider")
    skills: SkillsConfig = ...
    memory: MemoryConfig = ...
    title: TitleConfig = ...
    summarization: SummarizationConfig = ...
    subagents: SubagentsConfig = ...
    guardrails: GuardrailsConfig = ...
    safety_finish_reason: SafetyConfig = ...
    loop_detection: LoopDetectionConfig = ...
    token_budget: TokenBudgetConfig = ...
    tool_search: ToolSearchConfig = ...
    tools: list[ToolEntry] = Field(default_factory=list)
    tool_groups: list[ToolGroupEntry] = Field(default_factory=list)
    tracing: TracingConfig = ...
    channels: ChannelsConfig = Field(..., description="startup-only: IM channel bot credentials")
    # ...

    def get_model_config(self, name: str) -> ModelConfig | None:
        return next((m for m in self.models if m.name == name), None)
```

### 热重载

```python
_app_config_cache: dict[Path, tuple[FileSignature, AppConfig]] = {}
_app_config_lock = threading.Lock()


@dataclass(frozen=True)
class FileSignature:
    path: str
    mtime: float
    size: int
    content_digest: str         # sha1 of content head N KB


def _file_signature(path: Path) -> FileSignature:
    stat = path.stat()
    content = path.read_bytes()
    return FileSignature(str(path), stat.st_mtime, stat.st_size,
                          hashlib.sha1(content[:64_000]).hexdigest())


def get_app_config(*, path: Path | None = None) -> AppConfig:
    cp = path or resolve_config_path()           # explicit > env > cwd > parent
    sig = _file_signature(cp)
    with _app_config_lock:
        cached = _app_config_cache.get(cp)
        if cached and cached[0] == sig:
            return cached[1]
    # 加载（不持锁）
    config = _parse_app_config_file(cp)
    _check_version_drift(config)
    with _app_config_lock:
        _app_config_cache[cp] = (sig, config)
    return config
```

### 反射加载

```python
def resolve_variable(path: str):
    """'module.submodule:variable' → 返回 variable 值."""
    module_path, _, var_name = path.partition(":")
    if not module_path or not var_name:
        raise ValueError(f"Invalid resolve path: {path!r} (expected 'module:variable')")
    try:
        module = importlib.import_module(module_path)
    except ImportError as e:
        # 友好的安装提示
        hint = INSTALL_HINTS.get(module_path.split(".")[0], "")
        raise ImportError(f"{e}. Try: {hint}") if hint else e
    if not hasattr(module, var_name):
        raise AttributeError(f"{module_path!r} has no attribute {var_name!r}")
    return getattr(module, var_name)


def resolve_class(path: str, *, base_class):
    cls = resolve_variable(path)
    if not (isinstance(cls, type) and issubclass(cls, base_class)):
        raise TypeError(f"{path!r} resolved to {cls!r}, expected subclass of {base_class}")
    return cls
```

### `$ENV` 替换

```python
def _resolve_env_in_value(value):
    if isinstance(value, str) and value.startswith("$"):
        return os.environ.get(value[1:], value)
    if isinstance(value, dict):
        return {k: _resolve_env_in_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_resolve_env_in_value(v) for v in value]
    return value


def _parse_app_config_file(path: Path) -> AppConfig:
    raw = yaml.safe_load(path.read_text())
    resolved = _resolve_env_in_value(raw)
    return AppConfig(**resolved)
```

### STARTUP_ONLY_FIELDS 注册表

```python
# config/reload_boundary.py
STARTUP_ONLY_FIELDS: frozenset[str] = frozenset({
    "database", "checkpointer", "run_events", "stream_bridge",
    "sandbox", "log_level", "channels", "channel_connections",
})

def hot_reload_friendly(field_name: str) -> bool:
    return field_name not in STARTUP_ONLY_FIELDS
```

测试守护漂移：

```python
def test_startup_only_fields_match_descriptions():
    """每个 STARTUP_ONLY_FIELDS 字段在 AppConfig 上必须有 'startup-only:' 前缀的 description."""
    for field_name in STARTUP_ONLY_FIELDS:
        field = AppConfig.model_fields.get(field_name)
        assert field is not None, f"Unknown startup-only field: {field_name}"
        assert (field.description or "").startswith("startup-only:")
```

### bootstrap_schema 三分支

```python
async def bootstrap_schema(engine, *, backend: Literal["sqlite", "postgres"]):
    async with engine.begin() as conn:
        has_app_tables = await _has_any(conn, _BASELINE_TABLE_NAMES)
        has_alembic    = await _table_exists(conn, "alembic_version")

        if not has_app_tables and not has_alembic:
            # empty：create_all + stamp head
            await conn.run_sync(Base.metadata.create_all)
            await _alembic_stamp(conn, "head")
        elif has_app_tables and not has_alembic:
            # legacy：先 create_all 补齐 baseline 新表 → stamp 0001 → upgrade head
            await conn.run_sync(lambda c: Base.metadata.create_all(
                c, tables=[t for n, t in Base.metadata.tables.items()
                            if n in _BASELINE_TABLE_NAMES]))
            await _alembic_stamp(conn, "0001_baseline")
            await _alembic_upgrade(conn, "head")
        else:
            # versioned：alembic upgrade head
            await _alembic_upgrade(conn, "head")
```

## 反模式

- ❌ 任意模块直接 `os.environ.get` → 配置散乱、测试难
- ❌ `lru_cache` 缓存 `get_app_config()` 永不失效 → 改配置必须重启
- ❌ 用 mtime 单一信号判断变化 → 网络挂载 / 容器 stat 不更新 → 配置改了不生效
- ❌ STARTUP_ONLY_FIELDS 只写文档不写代码 → 后人加新字段忘记登记
- ❌ 反射加载 try/except 吞 ImportError → 缺包时不知道装啥
- ✅ FileSignature 多因子（mtime + size + content_digest）抗 mtime 不更新
- ✅ 反射 ImportError 拼 install hint（"uv add langchain-google-genai"）
- ✅ alembic 自动跑在 Gateway 启动时；用户从不手动 alembic upgrade

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[harness-app-boundary]] [[packaging-and-deployment]] [[mcp-integration]]
