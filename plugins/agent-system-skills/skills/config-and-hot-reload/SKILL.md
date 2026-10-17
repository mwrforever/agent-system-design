---
name: config-and-hot-reload
description: 配置系统设计：AppConfig 单根（约 60 个子配置节）、get_app_config 内容签名惰性热重载（path+mtime+sha256 四元组比对，防并发写竞态）、reload_boundary 声明哪些字段改了必须重启、SharedResetMarker 跨 Gateway 副本缓存失效（随机 generation 原子写 + 按 user_id 作用域）、extensions_config.json HTTP 可写扩展配置（原子写回 + 读锁 + EBUSY 降级）、secret 文件与凭据密钥、60+ 子配置文件全景。当要做配置中心/热更新/多副本配置同步，或排查"改了配置不生效/生效了一半"时使用。
---

# 配置与热重载

## 何时用

- 设计大型配置体系（几十个配置节如何组织）
- 运行期改配置：哪些能热更、哪些必须重启
- 多副本部署下的配置缓存同步
- HTTP 可写配置与操作员只读配置的边界

## 设计方案（为什么这么设计）

### 1. 单根 + 分文件

`AppConfig`（app_config.py:223）是唯一根：`models/tools/skills/subagents/sandbox/authorization/guardrails/...` 约 60 个子节，每节一个独立文件（`*_config.py`），根做组合与校验。`from_file` → `_from_yaml_text` 读一次并对**所读字节**签名（防止读到一半文件被改的竞态）。

### 2. 惰性热重载：调用时比对，不 watch

`get_app_config()`（:788）每次调用比对 `(path, mtime, sha256 内容签名, extensions 单例身份)` 四元组，变化才 `_load_and_cache_app_config`。**不用文件 watch**：watch 在容器/网络盘上不可靠，惰性比对零依赖且天然抗抖。mtime 变了但内容没变（touch）不触发重载——内容签名说了算。另有 `reload_app_config` 强制重载、`push/pop_current_app_config` 请求级 contextvar 覆写（测试与嵌入场景）。

### 3. 重启边界显式声明

`reload_boundary.py::iter_startup_only_field_paths`：哪些字段（如数据库后端、流桥类型）改动需重启才生效。**宁可显式列出，不做"静默半生效"**——热更了一半的配置是最难排查的状态。

### 4. 跨副本失效：SharedResetMarker

多 Gateway 副本各自有配置派生缓存（技能清单、模型列表）。`shared_reset_marker.py`（316 行）：任意副本写配置/技能后 `publish_skills_cache_reset` → 共享路径下原子写一个随机 generation 标记；其他副本惰性比对签名，发现标记变化即失效本地缓存。支持按 `user_id` 作用域（只失效该用户的缓存）。这是"没有消息总线的多副本"最简可靠解。

### 5. 两份配置文件，两种信任级

- `config.yaml`（3607 行示例）：模型/工具/沙箱/调度等**操作员控制**；含 `plugins:`（第三方代码 import，绝不开 API 写——见 [[extension-plugin-system]] 安全边界）。
- `extensions_config.json`：MCP servers + 技能清单，**API 可写**（用户经前端管理 MCP/技能），原子写回（临时文件替换 + 写锁 + EBUSY 降级重试）。代码 import 面与数据配置面分离。

### 6. 机密

`secret_file.py` / `credentials_key.py`：机密走独立文件与密钥派生；`$VAR` 形式的 env 引用在配置加载期解析且错误信息脱敏（见 [[mcp-integration]]）。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/harness/helix/config/app_config.py` | 920 | 配置根 + 热重载 |
| `references/code/backend/packages/harness/helix/config/extensions_config.py` | 1044 | HTTP 可写扩展配置 |
| `references/code/backend/packages/harness/helix/config/shared_reset_marker.py` | 316 | 跨副本失效 |
| `references/code/backend/packages/harness/helix/config/paths.py` | 556 | 路径派生（另见 [[multi-user-isolation]]） |
| `references/code/backend/packages/harness/helix/config/reload_boundary.py` | 171 | 重启边界 |
| `references/code/backend/packages/harness/helix/config/{secret_file,credentials_key,file_signature,plugin_settings,runtime_paths,_boolean_guards}.py` | — | 机密/签名/杂项 |
| `references/code/config.example.yaml` | 3607 | 全量配置样例（每个配置段的权威文档） |
| `references/code/extensions_config.example.json` | 95 | MCP/技能/拦截器样例 |

其余约 50 个子配置文件按域归属各 skill（sandbox_config → 沙箱；memory_config → 记忆；……），`config.example.yaml` 内含全部段落注释。

## 反模式与陷阱

- ❌ 文件 watch 驱动重载 → 容器/NFS 不可靠；惰性内容签名比对。
- ❌ 只比 mtime → touch 触发无谓重载、同 mtime 改内容漏 reload；加 sha256。
- ❌ 读写锁期间进程崩溃 → 半写文件；临时文件 + 原子替换。
- ❌ API 可写 plugins 代码清单 → 提权 RCE 面；代码 import 面只留操作员配置。
- ❌ 热更启动期字段（数据库/流桥） → 半生效状态；reload_boundary 显式拒绝。

## 落地参考

**自测方向**：改 config.yaml 后下一次 `get_app_config` 即见新值；touch 不触发；写坏 YAML 报错不落缓存；副本 A 发布技能缓存重置后副本 B 首次取数即失效；并发读 + 原子写无撕裂。

**调试日志串**：配置重载日志（path + 签名变化）、startup-only 字段命中拒绝。

## 进一步阅读

- [[system-prompt-template]]（技能缓存三层中的 SharedResetMarker 消费侧）
- [[extension-plugin-system]]（plugins: 信任边界）、[[mcp-integration]]（extensions_config 写回方）
