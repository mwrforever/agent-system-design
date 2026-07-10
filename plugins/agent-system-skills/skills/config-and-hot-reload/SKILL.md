---
name: config-and-hot-reload
description: 设计 agent 系统的配置体系与热重载边界--AppConfig 签名缓存（mtime+size+sha256 三元组失效，抗网络挂载 mtime 假性陈旧）、STARTUP_ONLY_FIELDS 注册表（schema 前缀 <-> 注册表双向漂移测试守护）、反射动态导入（resolve_variable/resolve_class + 缺包 uv add 安装提示）、$ENV 变量展开（主配置快速失败 vs 扩展配置静默降级双语义）、extensions_config（MCP+skills 独立文件独立缓存）、配置层级（config.yaml 主配置 + extensions_config.json 扩展合并）。链路位置：启动期配置注入图工厂 / 每请求 get_app_config() 解析。当你要做配置热重载、划分重启边界、加可插拔组件、处理 $ENV 变量、拆分主配置与扩展配置时调用本 skill。
---

## 何时用

- 系统有多种"可插拔"组件（模型 / 沙箱 / Guardrail / 追踪 / 工具 / skills 存储 / MCP 拦截器）需要配置驱动加载
- 用户希望改配置不重启就生效（per-run 字段：models / tools / memory / prompt 模板）
- 又有一些字段（database / checkpointer / sandbox / stream_bridge / channels / log_level）必须重启
- 配置含敏感值（API key / OAuth secret）想用环境变量代入
- 配置拆成两个文件：主配置（config.yaml）+ 扩展配置（extensions_config.json，MCP servers + skills 启用状态）
- 从无 schema 升级到带 schema 时需要平滑迁移（config_version 漂移提醒 + 空段兜底）
- 网络挂载（S3 Fuse / NFS）上 mtime 不更新，单纯靠 mtime 判变化不可靠

## 设计方案（为什么这么设计）

### 核心矛盾：热重载 vs 启动期物化的基础设施单例

网关请求依赖**每次请求**都经 `get_app_config()` 解析 `AppConfig`，所以业务字段（model 配置、tool 白名单、memory 开关、prompt 模板）改了在下一条消息即生效。但有一类字段是**启动期一次性物化为本地单例**的：`init_engine_from_config()` 构建 SQLAlchemy engine 与连接池、`make_checkpointer()` 绑定 SQLite WAL/busy_timeout、`get_sandbox_provider()` 缓存 `_default_sandbox_provider`、`start_channel_service()` 建 IM 客户端。改这些字段的值后不重建单例就毫无意义--所以它们必须重启进程。

### 解法：签名缓存 + 边界注册表

- **签名缓存**：`get_app_config()` 是模块级单例，每次调用 stat + 读完整文件算 `(mtime, size, sha256_hex)` 三元组签名，与缓存签名不等才重载。为何不仅靠 mtime？对象存储 / NFS 网络挂载上 mtime 会"假性陈旧"（文件实际已变但 stat 返回旧时间戳），把 size + 内容 sha256 加入签名让多 worker 的 config view 永远一致。
- **边界注册表**：`STARTUP_ONLY_FIELDS` 把"需重启"字段集中声明，每条带人类可读理由（解释**哪段代码捕获了快照**，而非只说"需重启"）。`format_field_description()` 把 `startup-only: <reason>` 前缀写进 Pydantic `Field(description=...)`，IDE 悬停即可见边界，无需跳源码查表。

```python
# 伪代码：签名缓存 reload 判定
def get_app_config() -> AppConfig:
    if (override := _current_app_config.get()) is not None:  return override   # ContextVar 请求级覆盖，最高优先
    if _app_config is not None and _app_config_is_custom:    return _app_config # set_app_config 注入，跳过签名
    sig = _get_config_signature(resolved_path)               # (mtime, size, sha256)
    should_reload = _app_config is None or _app_config_path != resolved_path or _app_config_signature != sig
    if should_reload:  _load_and_cache_app_config(resolved_path)  # from_file 成功后才写回全局
    return _app_config

# 伪代码：边界注册表双向钉死
STARTUP_ONLY_PREFIX = "startup-only:"
STARTUP_ONLY_FIELDS = {"database": "...", "checkpointer": "...", "sandbox": "...", ...}
def format_field_description(field, field_doc=None):
    return f"{STARTUP_ONLY_PREFIX} {STARTUP_ONLY_FIELDS[field]}\n\n{field_doc}"  # 写进 Field(description=)
# 漂移测试双向：注册表字段 -> schema 必带前缀；schema 带前缀 -> 必在注册表
```

### 关键不变量（违反则热重载失效或边界漂移）

1. **签名三元组缺一不可**：只用 mtime -> 网络挂载上配置改了不生效；只用 sha256 -> 每次读全文件算 hash，大 config 有开销。三元组让 mtime/size 做 fast-path 过滤、sha256 兜底抗假性陈旧。
2. **重载原子性**：`_load_and_cache_app_config` 先调 `from_file`（可能抛 ValidationError），只有成功后才写回 `_app_config` 等全局。失败的 reload 不留半成品、不污染子配置单例。
3. **边界双向漂移**：注册表 <-> schema 任一侧偷加字段都被红。增加新的"需重启"字段必须显式更新注册表；在 schema 里加 `startup-only:` 前缀却不登记也会被 `test_no_appconfig_field_uses_prefix_without_registration` 抓住。
4. **`set_app_config()` 跳过签名**：测试注入的实例标 `_app_config_is_custom=True`，避免被磁盘文件覆盖；ContextVar `_current_app_config` 优先级最高，提供请求级覆盖。
5. **`_drop_null_config_sections`**：YAML 里全注释段被解析为 `None`，Pydantic 严格校验会抛 `Input should be a valid list/dict`。`mode="before"` validator 把 None 整段抹掉让 default_factory 兜底--这是 `cp config.example.yaml config.yaml` 首次运行能跑通的关键。代价：必填段（`sandbox`）失去兜底，故意的。

### $ENV 展开：主配置快速失败 vs 扩展配置静默降级

两套 `resolve_env_variables` 故意不同语义：

```python
# 主配置（AppConfig）：$VAR 未命中 -> ValueError，快速失败
# API key 缺失应在启动期暴露，而非运行时神秘 None
if config.startswith("$"):
    env_value = os.getenv(config[1:])
    if env_value is None:  raise ValueError(...)
    return env_value

# 扩展配置（ExtensionsConfig）：$VAR 未命中 -> 返回空串，静默降级
# 扩展配置整体缺失都不报错；单个 env 未命中也不应让 MCP 加载链崩溃
# 但不能把字面 "$VAR" token 当真实环境值传给 MCP 服务器
if config.startswith("$"):
    return os.getenv(config[1:], "")   # 未命中 -> 空串
```

### 反射动态导入：可插拔组件的统一加载口

`module:variable` 分割 + `import_module` + `getattr` + 类型校验。`ImportError` 时拼出 `uv add <package>` 安装提示（`MODULE_TO_PACKAGE_HINTS` 把 `langchain_google_genai` 映射到 `langchain-google-genai`），缺包时知道装啥而非吞异常。`resolve_class` 在 `resolve_variable` 基础上加 `issubclass` 校验。

```python
# 伪代码：反射加载（完整源码见 startup-only-and-reflective.md §3）
def resolve_variable(path, expected_type=None):
    module_path, var_name = path.rsplit(":", 1)        # "langchain_openai:ChatOpenAI"
    module = import_module(module_path)                 # ImportError -> 拼 "uv add langchain-openai" 提示
    variable = getattr(module, var_name)
    if expected_type and not isinstance(variable, expected_type):  raise ValueError(...)
    return variable

def resolve_class(path, base_class=None):
    cls = resolve_variable(path, expected_type=type)   # 先校验是类
    if base_class and not issubclass(cls, base_class):  raise ValueError(...)  # 再校验子类
    return cls
# 调用点：models[].use / sandbox.use / tools[].use / skills.use / guardrails.provider.use / ...
```

### extensions_config：独立文件、独立缓存

`extensions_config.json`（MCP servers + skills 启用状态）与 `config.yaml` 完全解耦：独立文件、独立路径解析（`HELIX_EXTENSIONS_CONFIG_PATH` env）、独立缓存单例。前端 PUT `/api/mcp/config` 只动扩展配置不碰主配置。合并发生在 `AppConfig.from_file()` 末尾--显式调 `ExtensionsConfig.from_file()` 把结果塞进 `config_data["extensions"]`，故主配置签名失效重载时连带刷新扩展配置。

### 在端到端链路中的位置

配置体系位于**链路位置 ④建图（config 注入图工厂）/ 启动期**。`make_lead_agent` / 图工厂在每次 run 构建时调 `get_app_config()` 拿到最新 `AppConfig`，把 model 配置喂给 `resolve_class` 加载模型、把 tool 白名单喂给工具注册、把 memory/guardrails 配置喂给中间件链。见 [[e2e-request-lifecycle]]：每请求经 `get_app_config()` 解析保证业务字段即时生效；而 `STARTUP_ONLY_FIELDS` 里的基础设施字段在 Gateway lifespan 启动期一次性捕获（engine / checkpointer / sandbox / channel clients），run 期间不重建。调度任务 / 后台运行走同一 `get_app_config()`，但 `context={"non_interactive": True}` 仅对内部认证调用者生效。

### 配置层级与加载管线（伪代码）

```python
# 伪代码：AppConfig.from_file() 十步管线
def from_file(config_path=None):
    path = resolve_config_path(config_path)        # 4 级：param > HELIX_CONFIG_PATH > 项目根 > legacy
    data = yaml.safe_load(path) or {}
    _check_config_version(data, path)              # 落后于 example -> warn（不阻塞）
    data = resolve_env_variables(data)             # $ENV 展开（快速失败）
    _apply_database_defaults(data)                 # sqlite 默认值
    ext = ExtensionsConfig.from_file()             # 独立读 extensions_config.json
    data["extensions"] = ext.model_dump()          # 合并扩展配置
    result = model_validate(data)                  # 触发 _drop_null_config_sections(before) + _build_name_indexes(after)
    if not result.models:  warn("No models configured")
    acp = _validate_acp_agents(data.get("acp_agents", {}))  # 手动循环，dict-of-model 错误信息更友好
    _apply_singleton_configs(result, acp)          # 子配置压平进模块级全局 + checkpointer 特例 reset
    return result
```

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/config/app_config.py` | `AppConfig` 模型 + `from_file()` 加载管线 + `resolve_env_variables()`（快速失败版）+ `_drop_null_config_sections` 空段兜底 + `_apply_singleton_configs` 子配置下发 + `_check_config_version` 漂移提醒 + 签名缓存单例层（`get_app_config` / `reload` / `reset` / `set` / ContextVar push/pop） | [app-config-and-signature.md](./references/code/app-config-and-signature.md) |
| `core/helix/config/runtime_paths.py` | `project_root()` / `runtime_home()` / `existing_project_file()` 共享路径解析（`HELIX_PROJECT_ROOT` / `HELIX_HOME` env，`.helix` 状态目录） | [app-config-and-signature.md](./references/code/app-config-and-signature.md) §4 |
| `core/helix/config/extensions_config.py` | `ExtensionsConfig`（`McpServerConfig` stdio/sse/http + `McpOAuthConfig` + `SkillStateConfig`）+ `resolve_config_path()` 四级路径 + `from_file()` JSON 加载 + `resolve_env_variables()`（静默降级版）+ `get_enabled_mcp_servers` / `is_skill_enabled` + 独立缓存单例 | [env-and-extensions.md](./references/code/env-and-extensions.md) |
| `core/helix/config/reload_boundary.py` | `STARTUP_ONLY_FIELDS` 注册表 + `STARTUP_ONLY_PREFIX` + `format_field_description()` + `is_startup_only_field()` / `iter_startup_only_field_paths()` | [startup-only-and-reflective.md](./references/code/startup-only-and-reflective.md) §1 |
| `tests/test_reload_boundary.py` | 边界漂移双向测试（注册表 <-> schema 前缀） | [startup-only-and-reflective.md](./references/code/startup-only-and-reflective.md) §2 |
| `core/helix/reflection/resolvers.py` | `resolve_variable()` / `resolve_class()` 反射动态导入 + `_build_missing_dependency_hint()` 缺包安装提示 | [startup-only-and-reflective.md](./references/code/startup-only-and-reflective.md) §3 |
| `tests/test_app_config_reload.py` | 签名缓存热重载不变量（mtime / sha256 / 路径切换 / 校验失败原子性 / checkpointer 特例） | [app-config-and-signature.md](./references/code/app-config-and-signature.md) §5 |

### 模块入口与索引

**AppConfig 加载与签名缓存**（完整源码见 [app-config-and-signature.md](./references/code/app-config-and-signature.md) §2-§3）：
- `from_file()`：十步管线（见上方伪代码），末尾合并 `ExtensionsConfig.from_file()`。
- `_drop_null_config_sections`（`mode="before"`）：None 段抹掉让 default 兜底；必填段（`sandbox`）仍报错。
- `_apply_singleton_configs`：`load_*_from_dict` 把子配置压平进模块级全局（热路径友好）；checkpointer 变更特例 `reset_checkpointer()` + `reset_store()`。
- `_build_name_indexes`（`mode="after"`）：`get_model_config` / `get_tool_config` 从 O(n) `next(...)` 变 O(1) dict 查找，重载时同步刷新。
- 签名单例层：`_get_config_signature` 返回 `(mtime, size, sha256)`；`get_app_config` 三级优先（ContextVar > custom > 签名检测）；`peek_current_app_config` 不触发 reload（审计安全）。

**extensions_config 独立体系**（完整源码见 [env-and-extensions.md](./references/code/env-and-extensions.md)）：
- `McpServerConfig._accept_transport_alias`：MCP 规范 `transport` 字段归一为 `type`（`type` 优先），防远程 SSE/HTTP 被误当 stdio。
- `resolve_config_path` 四级路径，缺失返回 `None`（扩展配置可选）；`from_file` 返回空配置而非报错。
- `resolve_env_variables` 静默降级版：未命中返回空串，不把字面 `$VAR` 传给 MCP 服务器。
- `is_skill_enabled`：无显式条目时所有类别（public/custom/legacy）默认启用。
- 独立缓存单例：首次加载后常驻，需显式 `reload_extensions_config()` 或经主配置重载链路刷新。

**热重载边界 + 反射**（完整源码见 [startup-only-and-reflective.md](./references/code/startup-only-and-reflective.md)）：
- `STARTUP_ONLY_FIELDS`：10 条字段 -> 重启理由（database / checkpointer / run_events / stream_bridge / sandbox / log_level / logging / channels / channel_connections / scheduler）。`channels` 不在 schema 内，注册表是其唯一权威位置。
- 漂移测试双向：`test_appconfig_schema_marks_registered_fields_with_prefix`（注册表 -> schema 前缀）+ `test_no_appconfig_field_uses_prefix_without_registration`（schema 前缀 -> 注册表）。
- `resolve_variable` / `resolve_class`：`module:variable` 分割，`ImportError` 拼 `uv add` 提示；调用点见 §4 调用点清单表。

## 反模式与陷阱

- ❌ **用 `lru_cache` 缓存 `get_app_config()`** -> 永不失效，改配置必须重启。修复：手写签名缓存，`(mtime, size, sha256)` 三元组失效。
- ❌ **只用 mtime 判变化** -> S3 Fuse / NFS 网络挂载上 mtime 假性陈旧，配置改了不生效。修复：三元组签名，sha256 兜底。
- ❌ **重载时先写全局再校验** -> ValidationError 留下半成品 `_app_config`，子配置单例被部分更新。修复：`from_file` 成功后才写回全局（原子性）。
- ❌ **STARTUP_ONLY_FIELDS 只写文档不写代码 / 不写漂移测试** -> 后人加新"需重启"字段忘记登记，边界静默漂移。修复：注册表 + 双向漂移测试，schema 前缀 <-> 注册表互相钉死。
- ❌ **反射 `try/except` 吞 `ImportError`** -> 缺包时不知道装啥。修复：`_build_missing_dependency_hint` 拼 `uv add <package>` 提示，`MODULE_TO_PACKAGE_HINTS` 映射 module-root 到包名。
- ❌ **`$ENV` 未命中统一返回 None / 空串** -> 主配置 API key 缺失变成运行时神秘 None（排查地狱），或扩展配置抛错让整个 MCP 链崩溃。修复：双语义--主配置快速失败、扩展配置静默降级。
- ❌ **扩展配置 `$VAR` 未命中原样传字面 token** -> MCP 服务器收到 `"$CLIENT_SECRET"` 当真实密码。修复：未命中返回空串。
- ❌ **`_drop_null_config_sections` 把必填段也兜底** -> `sandbox: null` 静默用默认值，掩盖配置错误。修复：只兜底有 default 的段，`sandbox` 无 default 故意仍报错。
- ❌ **`get_*_config` 用 O(n) `next(...)` 扫描** -> `get_tool_config` 每次社区工具调用跑 2-3 次，热路径慢。修复：`_build_name_indexes` 重建 O(1) dict，重载时刷新。
- ❌ **`format_field_description` 对未注册字段静默返回占位** -> 拼写错误绕过漂移覆盖。修复：未注册抛 `KeyError`，故意暴露。
- ❌ **`set_app_config` 注入后仍跑签名检测** -> 测试期配置被磁盘文件覆盖。修复：`_app_config_is_custom=True` 跳过签名检查。
- ❌ **沙箱 `resolve_class` + 构造在锁内跑** -> 插件代码（含 import、构造器副作用）在非重入锁下执行，死锁 / 长占锁。修复：锁外解析 + 构造，锁内只读 / 写单例；输家 `shutdown()` 孤儿防泄漏。
- ❌ **MCP `transport` 字段不归一** -> 只配了 `transport: sse` 的远程服务器被当 `stdio`（默认值），启动失败。修复：`_accept_transport_alias` 归一，`type` 优先。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `HELIX_CONFIG_PATH` | env | 主配置路径，覆盖项目根 `config.yaml` |
| `HELIX_EXTENSIONS_CONFIG_PATH` | env | 扩展配置路径，覆盖项目根 `extensions_config.json` |
| `HELIX_PROJECT_ROOT` / `HELIX_HOME` | env | 项目根 / 状态目录（`.helix`） |
| `config_version` | config.yaml | 与 `config.example.yaml` 比对，落后 warn `make config-upgrade` |
| `models[].use` / `sandbox.use` / `tools[].use` | config.yaml | 反射加载路径 `module:variable` / `module:Class` |
| `STARTUP_ONLY_FIELDS` | reload_boundary.py | 加新"需重启"字段必须同步登记 + schema 加前缀 |
| `mcpServers[].type` / `transport` | extensions_config.json | MCP 传输类型，`type` 优先于 `transport` |
| `extensions.skills[<name>].enabled` | extensions_config.json | per-skill 启用开关，无条目默认启用 |

**关键日志串**

- `Config file has been modified (mtime: ... -> ...), reloading AppConfig` - mtime 变化触发重载
- `Config file content signature changed, reloading AppConfig` - sha256 变化触发重载（mtime 假性陈旧兜底）
- `Your config.yaml (version N) is outdated - the latest version is M. Run 'make config-upgrade'` - 版本漂移提醒
- `No models are configured in ...` - 模型列表空警告（不阻塞）
- `Could not import module ... Missing dependency '...'. Install it with 'uv add ...'` - 反射缺包提示

**自测方向**

- **mtime 重载**：写 config -> `get_app_config()` -> 改文件 + `os.utime` 抬 mtime -> 再调，断言 `is not initial` 且字段已变。
- **sha256 兜底**：patch `_get_config_mtime` 返回旧值、`_get_config_signature` 返回 `(旧 mtime, 旧 size, 新 sha256)`，断言仍重载。
- **路径切换重载**：切 `HELIX_CONFIG_PATH` env 指向另一文件，断言 `get_app_config()` 返回新实例。
- **校验失败原子性**：写非法 config（`title: False`）触发 ValidationError，断言 `_app_config` 仍是旧实例、子配置单例未变。
- **checkpointer 特例**：移除 `checkpointer` 段 -> 断言 `reset_checkpointer` + `reset_store` 触发、实例重建；保持不变 -> 断言实例复用。
- **边界双向漂移**：注册表每个 schema 内字段带 `startup-only:` 前缀；schema 里带前缀的字段都在注册表；`format_field_description("not_in_registry")` 抛 `KeyError`。
- **空段兜底**：`models: null` / `memory: null` -> 加载成功、回落默认；`sandbox: null` -> 仍 ValidationError。
- **$ENV 双语义**：主配置 `$MISSING_VAR` -> ValueError；扩展配置 `$MISSING_VAR` -> 空串而非字面 token。
- **反射缺包提示**：`resolve_variable("langchain_google_genai:ChatGoogleGenerativeAI")` 在缺包时抛带 `uv add langchain-google-genai` 的 ImportError。
- **MCP transport 归一**：只给 `transport: sse` -> `type` 被设为 `sse`；`type` + `transport` 同给 -> `type` 优先。
- **O(1) 索引**：重名 `models` -> `get_model_config` 返回首条（`setdefault` 语义）；重载后索引刷新。

## 进一步阅读

- AppConfig 模型 + 签名缓存 + 加载管线完整源码：[references/code/app-config-and-signature.md](./references/code/app-config-and-signature.md)
- extensions_config（MCP+Skills）+ $ENV 双语义完整源码：[references/code/env-and-extensions.md](./references/code/env-and-extensions.md)
- 热重载边界注册表 + 漂移测试 + 反射动态导入完整源码：[references/code/startup-only-and-reflective.md](./references/code/startup-only-and-reflective.md)
- 关联 skill：[[e2e-request-lifecycle]]（每请求 get_app_config 解析与 STARTUP_ONLY 启动期捕获的端到端位置）、[[agent-graph-factory]]（图工厂注入 AppConfig）、[[middleware-chain-design]]（子配置单例下发到中间件）、[[mcp-integration]]（extensions_config MCP servers 消费）、[[sandbox-providers]]（resolve_class 加载沙箱 + 冷启动竞争）、[[core-app-boundary]]（config 在 core 层，不反向依赖应用层）
