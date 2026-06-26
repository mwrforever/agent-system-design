# Implementation Notes — Config & Hot-Reload

> `config.yaml` 的加载、缓存、签名失效与"热重载边界"的实现细节。
> 路径以占位形式给出，业务命名抽离。

---

## 一、配置层组件

| 组件 | 位置 | 职责 |
|------|------|------|
| `AppConfig` | `<harness-pkg>/config/app_config.py` | 顶层配置模型，Pydantic v2 严格校验 |
| `AppConfig.from_file()` | 同上 | 读 YAML、解析 `$ENV_VAR`、应用默认值、构建子配置 |
| `AppConfig.resolve_config_path()` | 同上 | 四级路径优先级（参数 > env > project root > legacy） |
| `get_app_config()` | 同上 | 带签名失效的缓存单例 |
| `reload_app_config / reset_app_config / set_app_config` | 同上 | 测试与运维 hook |
| `STARTUP_ONLY_FIELDS` | `<harness-pkg>/config/reload_boundary.py` | 重启边界注册表 |
| `format_field_description()` | 同上 | 把 `startup-only:` 前缀同步进 Pydantic `Field.description` |
| `_drop_null_config_sections` validator | `<harness-pkg>/config/app_config.py` | 把全注释段（YAML 解析为 None）降级为默认值 |
| `ExtensionsConfig` | `<harness-pkg>/config/extensions_config.py` | MCP 服务器 + Skills 启用状态，独立文件管理 |

---

## 二、路径解析与多级 fallback

`resolve_config_path()` 的解析优先级：

1. 显式 `config_path` 参数（找不到立即 `FileNotFoundError`）
2. `DEER_FLOW_CONFIG_PATH` 环境变量
3. 项目根 `config.yaml`（`existing_project_file` 沿调用者向上搜）
4. Legacy fallback：模块所在路径向上 4 层与 5 层（兼容 monorepo 老布局）

任何一级命中即返回，全部 miss 抛 `FileNotFoundError`。`extensions_config.json`
走对称的独立解析路径，环境变量 `DEER_FLOW_EXTENSIONS_CONFIG_PATH`。

---

## 三、缓存键：路径 + 内容签名

模块级单例 `_app_config` + 四个 sentinel 变量：`_app_config_path`、
`_app_config_mtime`、`_app_config_signature`、`_app_config_is_custom`。

`get_app_config()` 的 reload 判定：

```
should_reload = (
    _app_config is None
    or _app_config_path != resolved_path
    or _app_config_signature != current_signature
)
```

`_get_config_signature(path)` 返回 `(mtime, size, sha256_hex)` 三元组。
**为何不仅靠 mtime？** 在对象存储（S3 / GCS Fuse）或 NFS 网络挂载上，
mtime 会"假性陈旧"——文件实际已变但 stat 返回旧时间戳。把 size + 内容
sha256 加入签名，让网关与 langgraph runtime 的 config view 永远一致。

`_app_config_is_custom = True` 标记 `set_app_config()` 注入的实例
（测试或外部注入场景），跳过签名检查避免被磁盘文件覆盖。

`_current_app_config` ContextVar 提供请求级覆盖（运维 / 测试用），
优先级最高，绕过缓存。

---

## 四、热重载边界

**核心原则**：业务字段（model、tool、middleware 配置、prompt template）随请求生效；
**基础设施字段**（database、checkpointer、stream_bridge、sandbox、log_level、
channels、channel_connections、run_events）必须重启进程。

边界在 `reload_boundary.py::STARTUP_ONLY_FIELDS` 集中注册，每条带可读理由：

```
"database":     "init_engine_from_config() 启动期一次，连接池不再重建"
"checkpointer": "make_checkpointer() 绑定 SQLite WAL/busy_timeout 等"
"sandbox":      "get_sandbox_provider() 缓存 _default_sandbox_provider 单例"
"log_level":    "apply_logging_level() 仅启动期跑一次"
"stream_bridge":"make_stream_bridge() 启动期构造单例"
"channels":     "start_channel_service() 启动期一次，IM 客户端不再重建"
...
```

`format_field_description("database", field_doc=...)` 拼出
`"startup-only: <reason>\n\n<field_doc>"` 写进 Pydantic `Field.description`，
IDE 悬停即可看到边界，无需跳源码查表。

drift 测试 `test_reload_boundary.py` 双向校验：

1. 注册表里每个字段在 Pydantic schema 里必须用 `startup-only:` 前缀
2. Schema 里所有用 `startup-only:` 前缀的字段必须在注册表里

任意一侧偷偷添加新字段都会被红：增加新的"重启必备"字段必须显式更新注册表。

**为什么有的子字段是"业务即时生效"，有的整段必须重启**：判定准则是
"启动期是否一次性物化为本地状态"。`models[*].max_tokens` 每次请求都会被
中间件读，改了立刻见效；`database.backend` 在 `init_engine_from_config()`
构建了 SQLAlchemy engine 与连接池，改值后不重建连接池就毫无意义——所以
整段进了 startup-only。

---

## 五、环境变量解析与子配置加载

**`$VAR` 语法**：`resolve_env_variables()` 在加载前递归遍历 config，
凡 str 值以 `$` 开头则查 `os.getenv()`，未设置直接 `ValueError`——
"快速失败"优于"运行时神秘 None"。

**子配置的"单例下发"**：`_apply_singleton_configs()` 把验证后的子配置
压平进对应模块级全局：

- `load_title_config_from_dict(...)`
- `load_summarization_config_from_dict(...)`
- `load_memory_config_from_dict(...)`
- `load_subagents_config_from_dict(...)`
- `load_tool_search_config_from_dict(...)`
- `load_guardrails_config_from_dict(...)`
- ...

这些 `load_*_from_dict` 让中间件不必每次都 `get_app_config().xxx`——
对热路径友好。但代价是要在重载时显式触发 `_apply_singleton_configs()`。

**checkpointer 变更的特例**：detect 到 `previous_checkpointer_config != config.checkpointer`
时显式 `reset_checkpointer()` + `reset_store()`，迫使下一次访问重建。
这是"业务字段"里唯一带额外重置语义的字段，因为 checkpointer 通常被显式
切换（dev memory → prod postgres）但又不一定需要进程重启。

**`ExtensionsConfig` 的两次加载**：`AppConfig.from_file()` 末尾显式
`ExtensionsConfig.from_file()`，把 MCP + Skills 状态合并进主 config 字典。
这意味着 MCP 服务端通过 PUT `/api/mcp/config` 写入文件后，下一次
`get_app_config()` 命中签名失效 → 重新加载 → 合并新 ExtensionsConfig，
无需重启即可让新 MCP 服务对接 Agent。

---

## 六、设计权衡与陷阱

1. **`_drop_null_config_sections` 的存在感**：用户从 example 拷过来后
   只解开少数段，剩余段的 YAML 值是 `None`（被全行注释）。Pydantic 默认
   严格校验会抛 `Input should be a valid list/dict`。`mode="before"` validator
   把 None 整段抹掉，让 default_factory 兜底。代价：必填段（如 `sandbox`）
   失去这层兜底——故意的，没有默认值则必须显式配置。

2. **`config_version` 漂移提醒**：`_check_config_version` 在加载时比较
   用户 config 与 example 的 version，落后则 warn 提示运行
   `make config-upgrade`。不强制阻塞——单字段缺失通常仅触发某 feature 不可用，
   不应让所有用户卡在 boot 上。

3. **缓存失效粒度**：`get_app_config()` 是 module-global 缓存，**进程内**全局。
   多 worker（uvicorn `--workers N`）场景下每个 worker 独立缓存，
   配置文件被改时各 worker 各自触发 reload，看到一致内容（因为 sha256 一致）。
   但**不要**用 `set_app_config()` 做跨 worker 通信，那只影响当前进程。

4. **`extensions_config.json` 独立缓存**：MCP 服务器与 Skills 启用状态走
   独立文件，独立 mtime cache。前端 PUT `/api/mcp/config` 后该缓存被
   下一次访问刷新；与 `config.yaml` 完全解耦——这是为了让运维工具
   可以只动 MCP 配置而不碰主配置。

5. **`peek_current_app_config()` 的用途**：返回当前缓存值但**不**触发 reload，
   供日志/审计场景使用——避免在审计回调里触发 IO 引发递归告警。

6. **测试隔离**：每个测试用 `set_app_config(custom)` 注入，结束 `reset_app_config()`。
   `_app_config_is_custom = True` 标志让自动签名检测跳过，保证测试期内
   配置保持不变。

7. **签名计算的成本**：每次 `get_app_config()` 调用都会 stat + 读完整文件
   计算 sha256，typical config ~10KB 不构成瓶颈，但若把 `config.yaml`
   膨胀到数 MB 就有可观开销。把内嵌的大型 prompt 模板挪到独立文件、
   主 config 只放路径引用，是健康的解耦做法。

8. **`acp_agents` 段的单独验证**：与其他段不同，ACP agent 段在
   `from_file` 末尾走独立的 `_validate_acp_agents` 而非 model_validator。
   理由：`AppConfig` 主模型用 `dict[str, ACPAgentConfig]`，但 Pydantic
   v2 对 dict-of-model 段的错误信息不够人类友好，手动循环让"哪个 agent
   名下的哪个字段错了"更明确。

9. **多 Worker 下的 reload "竞跑"**：不同 Worker 几乎同时检测到 mtime 变化
   触发 reload，重复 IO 完全可接受（sha256 校验一致）。真正麻烦的是
   `_apply_singleton_configs()` 里的 `reset_checkpointer()` / `reset_store()`——
   每个 Worker 独立重置，瞬时连接池抖动可能导致正在跑的 Run 触发
   `_call_store_with_retry` 的退避路径。生产配置变更最好选低峰窗口。

---

[[gateway-runs-and-sse]] · [[middleware-architecture]] · [[multi-user-isolation]] · [[sandbox-providers]] · [[mcp-server-integration]]
