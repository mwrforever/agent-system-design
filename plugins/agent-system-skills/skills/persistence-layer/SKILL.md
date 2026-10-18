---
name: persistence-layer
description: SQL 持久层设计：SQLAlchemy 2.0 async 引擎引导（自动建 PG 库）、bootstrap_schema Alembic 多态引导（fresh/legacy/stamped 三态识别 + PG advisory lock / SQLite asyncio.Lock 防并发迁移）、json_compat 跨方言 JSON 过滤（SQLite json_extract / PG @>）、18 个领域仓库模式（run 租约判定/计划任务配额与单活跃/MCP 任务幂等/渠道凭据加密 ChannelCredentialCipher/项目文档）、44 个 Alembic 迁移的组织方式。当要给 agent 平台设计持久层、多实例迁移安全、跨 SQLite/Postgres 兼容查询时使用。
---

# 持久层

## 何时用

- 设计 async SQL 持久层（引擎/会话/迁移引导）
- 多实例同时启动的迁移并发安全
- 同一套查询跑 SQLite（dev）与 Postgres（prod）
- 领域仓库模式（租约/配额/幂等/加密凭据）

## 设计方案（为什么这么设计）

### 1. 引擎与引导分两层

`engine.py::init_engine`（292 行）：连接串解析 + **自动创建 PG 库**（首次部署免手工建库）+ 会话工厂。`bootstrap.py::bootstrap_schema`（732 行）：三态识别——fresh（全新建库直接 stamp）/ legacy（无 alembic 版本表的历史库）/ stamped（正常迁移）；并发防护用 **PG advisory lock / SQLite asyncio.Lock**——多副本同时启动只有一个跑迁移，其余等待。迁移目录 44 个版本（0001 基线 → 渐进演进），`env.py` + `_helpers.py` 处理异步引擎与筛选。

### 2. JSON 过滤的方言抽象

`json_compat.py::json_match(column, key, value)`（235 行）：同一语义在 SQLite 用 `json_extract`、PG 用 `@>`。仓库层只调 json_match——**方言差异不许漏进业务仓库**（本地 sqlite 开发与生产 PG 行为一致是底线）。

### 3. 18 个领域仓库：一个模式，各自专注

每个域 `{model(表), sql(仓库), base(抽象)}` 三件套，仓库方法即业务语义：

| 仓库 | 特色机制 |
|---|---|
| `run/sql.py`（965） | 租约判定 `_lease_expired_or_null`（run 所有权的心跳侧 DB 面） |
| `scheduled_tasks/sql.py`（1021） | 配额 `ScheduledTaskQuotaExceeded`、活跃任务变更冲突 |
| `scheduled_task_runs/sql.py`（1134） | **单活跃约束** + finalization/projection 配套 |
| `mcp_tasks/sql.py`（1002） | thread incarnation 锁、幂等去重（长任务三件套的 DB 面） |
| `channel_connections/sql.py`（616） | `ChannelCredentialCipher` 渠道凭据加密存储 |
| `projects/sql.py`（761） | 项目/文档双仓库 |
| `agents/`（四件） | 文件 + SQL 双态（自定义 agent 的 DB/文件混合存储） |
| `login_throttle` / `personal_access_tokens` / `feedback` / `notification_deliveries` / `channel_leases` / `channel_thread_bindings` / `webhook_delivery` / `thread_meta` / `thread_reads` / `user` / `managed_subagents` / `subagent_batches` / `scheduled_task_events` | 各域 CRUD + 专属约束 |

### 4. 约束优先于应用锁

能下推到数据库的并发语义（唯一约束、单活跃约束、条件更新）**不**用应用层锁实现——应用锁只做进程内键级互斥（`AsyncKeyedLockTable`，见 [[long-running-and-cancellation]]）。数据库约束在多实例/崩溃下依然成立。

## 实现索引

`references/code/persistence/`（73 文件 1.2 万行）：`base/engine/bootstrap/json_compat/postgres_schema` + `models/` + 18 个域目录 + `migrations/{env,_env_filters,_helpers}.py`。配置：`config/database_config.py`（340 行，sqlite/postgres/channel dedupe 表/checkpoint 模式/delta 缓存）+ `config/postgres_schema.py`。

## 反模式与陷阱

- ❌ 迁移无并发锁 → 多副本首次启动互踩；advisory lock。
- ❌ JSON 查询写方言分支散落各仓库 → 行为漂移；json_match 统一。
- ❌ 应用锁替代 DB 约束 → 崩溃窗口失守；约束下推。
- ❌ 凭据明文列 → 泄库即泄凭证；ChannelCredentialCipher。
- ❌ legacy 库直接跑迁移 → 版本表错乱；三态识别。

## 落地参考

**自测方向**：两进程并发 bootstrap 只出一个迁移者；sqlite/pg 双后端同一仓库测试通过；单活跃约束并发插入只成功一次；凭据 cipher 往返；legacy 库升级路径。

## 进一步阅读

- [[long-running-and-cancellation]]（租约/检查点消费的仓库）、[[scheduled-tasks]]、[[mcp-integration]]（三件套的业务侧）
- [[config-and-hot-reload]]（database 配置段）
