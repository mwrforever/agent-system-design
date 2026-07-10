---
name: packaging-and-deployment
description: 设计 agent 系统的打包与部署--monorepo + uv workspace + langgraph.json 图注册 + 根 Makefile 全栈编排 + nginx 唯一出口反代 + alembic 启动期自跑 + Docker dev/prod 双模 + 可选 K8s provisioner + 启动序。当你要搭多服务 agent 栈的打包/部署、做 make dev/up 一键拉起、接 LangGraph Studio、处理 SSE 反代缓冲、让数据库迁移对用户透明时调用本 skill。
---

## 何时用

- 项目同时有 Python 后端 + TS 前端 + 反代 + 数据库（多服务协作）
- 想用一条命令拉起整个开发栈（`make dev`）或生产栈（`make up`）
- 生产用 Docker Compose，可选 K8s provisioner 做沙箱
- 想兼容 LangGraph Studio / LangGraph Platform 注册（`langgraph dev` 起 Studio UI）
- 想让数据库 schema 迁移对部署侧透明（用户从不见 `alembic upgrade`）
- SSE 流被 nginx 缓冲导致前端卡死，需要反代配置参考

## 设计方案（为什么这么设计）

### 核心矛盾：多服务协作 vs 一键拉起 + 零运维

一个生产级 agent 栈至少有 4 个协作进程（Gateway API + agent runtime、Next.js 前端、nginx 反代、Redis stream bridge），外加可选的 provisioner 和数据库。开发者期望 `make dev` 一键拉起热重载栈、`make up` 一键部署生产栈；运维期望加列不改部署脚本；前端期望 SSE 流不被反代缓冲；Studio 期望能直接注册图工厂。这些诉求分布在打包、编排、网络、迁移四个维度，必须用一套自洽的不变量统一。

### 解法：分层编排 + 单一出口 + 启动期自洽

1. **Monorepo + uv workspace**：单一 `uv.lock` 跨包；框架包（`core/`，包名 `helix`）作为可发布 workspace 成员，应用层（`gateway/`、`channels/`、`scheduler/`）通过 `[tool.uv.sources] helix = { workspace = true }` 引用。根 `pyproject.toml` 仅占位，工作区声明写在应用层 workspace 根。
2. **双 Makefile**：根 `Makefile` 编排全栈（`dev/start/stop/up/down/docker-start`），per-module Makefile 只管模块本身（`gateway/test/lint/migrate-rev`）。根 Makefile 通过 `scripts/serve.sh` / `scripts/deploy.sh` / `scripts/docker.sh` 路由到三种启动器。
3. **唯一对外入口 = nginx :2026**：浏览器只接触 nginx；`/api/langgraph/*` rewrite 成 `/api/*` 反代到 Gateway 的 LangGraph 兼容端点，其余 `/api/*` 直转 Gateway，`/` 转 Next.js。CORS / Cookie / CSRF 因此同源一致。
4. **langgraph.json 是 Studio + Server 共享入口**：图工厂 + checkpointer + auth 在此一处注册，本地 / 生产 / Studio 三处都拿这份。
5. **alembic 启动期自跑**：Gateway lifespan 调 `bootstrap_schema(engine, backend=...)`，按 empty / legacy / versioned 三分支自动升库。用户从不见 `alembic upgrade`；新加列只写 revision。
6. **Docker dev/prod 严格两份 compose**：dev 用 volume bind mount + `--reload`；prod 用预构镜像。opt-in overlay（DooD 沙箱 / CLI auth）按 config 自动追加。

### 关键不变量（违反则启动失败或行为错乱）

1. **唯一对外入口 = nginx**：多端口直接暴露给浏览器引入 CORS / Cookie / CSRF 三套配置；split-origin 必须显式 `GATEWAY_CORS_ORIGINS` allowlist。
2. **`--workers 1` 默认**：Gateway 内 `RunManager` / `StreamBridge` 是 in-process 单例，多 worker 无 sticky session 时 run cancel / SSE 重连 / IM channel service 跨 worker 错乱。换 Redis stream bridge 后才允许提升，且 multi-worker 强制用 Postgres。
3. **alembic 启动期自跑**：用户从不见 `alembic upgrade`；手动跑会与 `bootstrap_schema` 锁冲突。
4. **nginx SSE 三件套**：`proxy_buffering off` + `X-Accel-Buffering: no` + `proxy_read_timeout 600s`。缺任一则 SSE 整段缓冲或长调用断流。
5. **uv workspace 单锁**：`pip + requirements.txt` 跨环境锁不住；`uv.lock` 是硬约束。
6. **`langgraph.json` 图工厂注册只此一处**：改路径忘改 Studio 注册，CI 没有等价检查。
7. **Docker dev volume mount + reload；prod 镜像 baked**：严格分两份 compose，避免 dev 习惯泄漏到 prod。

### 启动时序（本地 `make dev` 路径）

```python
# 伪代码：serve.sh --dev 的启动序
1. scripts/check.py           # 验证 node/pnpm/uv/Python 版本，缺工具早失败
2. stop_all()                  # 回收 8001/3000/2026 端口（限定本 worktree 进程）
3. config-upgrade.sh           # 合并 config.example.yaml 新字段到 config.yaml
4. uv sync --all-packages      # 装后端依赖（含 workspace 成员 + extras 自动探测）
5. pnpm install                # 装前端依赖
6. run_service Gateway         # uvicorn gateway.gateway.app:app --reload :8001
7. run_service Frontend        # next dev --turbo :3000
8. run_service Nginx           # nginx -c nginx.local.conf :2026
   # 每步用 wait-for-port.sh 等端口就绪才继续；失败则 tail 日志 + cleanup
```

Docker 路径（`make up` -> `deploy.sh`）的差异：step 4-5 换成 `docker compose up --build`，由 `docker-compose.yaml` 编排 redis -> gateway -> frontend -> nginx 的依赖序（`depends_on: redis: condition: service_healthy`）。

### bootstrap_schema 三分支（启动期 schema 自洽）

```python
# 伪代码：bootstrap_schema 在 lifespan 启动期跑，三分支自动选路
async def bootstrap_schema(engine, *, backend):
    async with _bootstrap_lock(engine, backend):        # Postgres: pg_advisory_lock；SQLite: 进程内 asyncio.Lock + 文件锁
        state = reflect(engine)                          # has_alembic_version? has_framework_tables?
        if state == "empty":                             # 空库
            create_all(engine); stamp(head)              # 建全表 + 标记到 head
        elif state == "legacy":                          # 老库（有表无 alembic_version）
            create_all_baseline_only(engine)             # 仅补 baseline 表，不预建后续 revision 的表
            stamp("0001_baseline"); upgrade(head)        # 标记 baseline 再升到 head
        else:                                            # versioned（已有 alembic_version 行）
            upgrade(head)                                # 幂等 no-op 若已在 head
# 用户从不见 alembic 命令；新加列只写 revision，部署侧零操作
```

### nginx path-based 路由（唯一出口）

```nginx
# 伪代码：nginx 把 /api/langgraph/* rewrite 成 /api/* 转 Gateway
location /api/langgraph/ {
    rewrite ^/api/langgraph/(.*) /api/$1 break;          # LangGraph 兼容端点
    proxy_pass http://$gateway_upstream;                 # 变量 + DNS resolver：容器重启换 IP 不挂
    proxy_buffering off; proxy_set_header X-Accel-Buffering no;  # SSE 必须
    proxy_read_timeout 600s;                             # LLM 调用 + 工具回合可能数分钟
}
location /api/ { proxy_pass http://$gateway_upstream; }  # 其余 API 直转 Gateway
location / { proxy_pass http://$frontend_upstream; ... Upgrade $http_upgrade; }  # 前端 + HMR WebSocket
map $http_x_forwarded_proto $forwarded_proto { ... }     # 保留外层 TLS 反代的真实 scheme
```

### 在端到端链路中的位置

本 skill 覆盖的是**启动期 / 部署期**链路（见 [[e2e-request-lifecycle]] 的"请求生命周期"前置阶段）：

- **启动期**：`bootstrap_schema` 把 DB 升到 head -> `langgraph_runtime` 初始化 checkpointer / store / RunManager / StreamBridge -> channel service / scheduled task service 启动。这一段在第一个用户请求到达之前完成；任何一步失败 Gateway 无法 ready。
- **部署期**：`make up` 构建镜像 -> docker compose 按 `depends_on` 拉起 redis -> gateway -> frontend -> nginx -> (可选) provisioner。nginx 是唯一对外端口。
- **请求期**：浏览器 -> nginx:2026 -> (`/api/langgraph/*` rewrite) -> Gateway:8001 -> agent runtime。该段细节见 [[e2e-request-lifecycle]] 与 [[gateway-runs-and-sse]]。

`langgraph.json` 注册的图工厂 `make_lead_agent` 在请求期被 LangGraph runtime 调用；checkpointer 注册路径 `make_checkpointer` 决定 checkpoint 存储后端（SQLite / Postgres / memory），与 `bootstrap_schema` 管理的应用表是两套独立 schema 生命周期（alembic env 的 `include_object` 显式排除 LangGraph 自管表）。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `<repo-root>/Makefile` + `<workspace-root>/Makefile` | 根 Makefile 全栈编排 + per-module Makefile（dev/gateway/test/lint/migrate-rev） | [monorepo-and-uv.md](./references/code/monorepo-and-uv.md) |
| `<workspace-root>/pyproject.toml` + `core/pyproject.toml` | uv workspace 声明 + 框架包（包名 `helix`，console script `helix`）+ 可选 extras（postgres/redis/tui） | [monorepo-and-uv.md](./references/code/monorepo-and-uv.md) |
| `<workspace-root>/langgraph.json` | LangGraph Studio + Server 共享入口：图工厂 + auth + checkpointer 注册 | [monorepo-and-uv.md](./references/code/monorepo-and-uv.md) |
| `<repo-root>/scripts/serve.sh` + `deploy.sh` + `docker/dev-entrypoint.sh` | 三种启动器：本地 dev/prod、Docker prod、Docker dev；含端口回收 / 依赖同步 / uv extras 探测 / uvicorn handoff | [startup-sequence.md](./references/code/startup-sequence.md) |
| `docker/nginx/nginx.conf` + `nginx.local.conf` | nginx path-based 反代：`/api/langgraph/*` rewrite + SSE 三件套 + `X-Forwarded-Proto` map | [nginx-and-docker.md](./references/code/nginx-and-docker.md) |
| `docker/docker-compose.yaml` + `docker-compose-dev.yaml` + `dood.yaml` + `cli-auth.yaml` | prod / dev 严格两份 compose + 两个 opt-in overlay（DooD 沙箱 / CLI auth） | [nginx-and-docker.md](./references/code/nginx-and-docker.md) |
| `backend/Dockerfile` + `docker/provisioner/app.py` | 多阶段构建（builder/dev/runtime）+ K8s provisioner（per-sandbox Pod + NodePort） | [nginx-and-docker.md](./references/code/nginx-and-docker.md) |
| `core/helix/persistence/bootstrap.py` | `bootstrap_schema`：三分支 state machine + Postgres advisory lock / SQLite asyncio.Lock | [alembic-and-lifespan.md](./references/code/alembic-and-lifespan.md) |
| `core/helix/persistence/engine.py` + `migrations/env.py` + `alembic.ini` | `init_engine`：建引擎 -> `bootstrap_schema`；alembic env 的 SQLite busy_timeout 镜像 | [alembic-and-lifespan.md](./references/code/alembic-and-lifespan.md) |
| `gateway/gateway/app.py` + `deps.py` | Gateway lifespan：config -> tiktoken 预热 -> `langgraph_runtime`（内含 `init_engine_from_config` -> `bootstrap_schema`）-> channel/scheduler 启动 | [alembic-and-lifespan.md](./references/code/alembic-and-lifespan.md) |

### 模块入口与索引

**uv workspace + 包名 + console script**（完整源码见 [monorepo-and-uv.md](./references/code/monorepo-and-uv.md)）：
- workspace 根 `pyproject.toml`：`[tool.uv.workspace] members = ["core"]`，`[tool.uv.sources] helix = { workspace = true }`。
- `core/pyproject.toml`：`name = "helix"`，`[project.scripts] helix = "helix.tui.cli:main"`（TTY -> TUI，non-TTY -> help），`[tool.hatch.build.targets.wheel] packages = ["helix"]`。
- 可选 extras：`postgres`（asyncpg + psycopg）、`redis`（stream bridge）、`tui`（textual）、`ollama`、`pymupdf`。Docker 镜像默认装 `redis` extra。
- `langgraph.json`：`graphs.lead_agent = "helix.agents:make_lead_agent"`，`checkpointer.path = "./core/helix/runtime/checkpointer/async_provider.py:make_checkpointer"`，`auth.path = "./gateway/gateway/langgraph_auth.py:auth"`。

**启动器脚本**（完整源码见 [startup-sequence.md](./references/code/startup-sequence.md)）：
- `serve.sh`：本地 dev/prod 启动器。`stop_all()` 用 `_is_framework_pid` + `lsof` 限定回收本 worktree 进程的 8001/3000/2026 端口；`detect_uv_extras.py` 从 config.yaml 探测 extras；`run_service` 用 `wait-for-port.sh` 等就绪。
- `deploy.sh`：Docker prod 启动器。`detect_sandbox_mode()` 从 config.yaml 探测 local/aio/provisioner；aio 模式自动追加 `docker-compose.dood.yaml` overlay；自动生成 `BETTER_AUTH_SECRET` + `HELIX_INTERNAL_AUTH_TOKEN` 持久化到 `HELIX_HOME`。
- `dev-entrypoint.sh`：Docker dev 容器内入口。解析 `UV_EXTRAS` -> `uv sync --all-packages --extra redis` -> 失败重建 `.venv` 重试 -> `exec uvicorn` 替换 shell 成为 PID 1。

**nginx + Docker 编排**（完整源码见 [nginx-and-docker.md](./references/code/nginx-and-docker.md)）：
- `nginx.conf`：`set $gateway_upstream gateway:8001` 变量 + `resolver 127.0.0.11` 容器内 DNS；`map $http_x_forwarded_proto $forwarded_proto` 保留外层 TLS scheme；`/api/langgraph/` rewrite + SSE 三件套；上传 location `client_max_body_size 100M; proxy_request_buffering off`。
- `docker-compose.yaml`（prod）：frontend 多阶段 `target: prod`；gateway `--workers ${GATEWAY_WORKERS:-1}`；redis stream bridge healthcheck；provisioner 可选（provisioner 模式才加入 services 列表）。
- `docker-compose-dev.yaml`（dev）：源码 bind mount + `gateway-venv` volume 保 `.venv` 不被 host 空目录覆盖 + `gateway-uv-cache` volume；frontend `pnpm dev` + `WATCHPACK_POLLING=true`。
- `Dockerfile`：三阶段（builder 带 build-essential / dev 保留工具链 / runtime 精简 ~200MB）；`UV_EXTRAS` build-arg 透传；`redis` extra 始终装。
- `provisioner/app.py`：FastAPI 服务，lifespan 里 `load_kube_config` + `_ensure_namespace`；`POST /api/sandboxes` 创建 Pod + NodePort Service，idempotent。

**alembic + lifespan**（完整源码见 [alembic-and-lifespan.md](./references/code/alembic-and-lifespan.md)）：
- `bootstrap.py`：`_decide_state` 三分支；`_BASELINE_TABLE_NAMES` frozenset 限制 legacy 分支的 `create_all` 范围（防 pre-empt 后续 revision 的 `op.create_table`）；`_PG_LOCK_KEY` 固定 advisory lock key；Postgres `SET LOCAL idle_in_transaction_session_timeout = 0` 防 managed PG 杀 idle-in-txn 释放锁；SQLite `WeakKeyDictionary` per-engine `asyncio.Lock`。
- `engine.py`：`init_engine` 建 engine -> `bootstrap_schema`；SQLite `PRAGMA journal_mode=WAL; busy_timeout=30000` per-connection；Postgres "database does not exist" 时 `_auto_create_postgres_db` 建库重试。
- `env.py`：alembic 自己 spawn 的 engine 也 wire `PRAGMA busy_timeout=30000`；`include_object` 过滤 LangGraph 自管表（checkpoints 等）。
- `app.py` lifespan：`get_app_config()` -> `configure_logging` -> tiktoken 预热（5s timeout）-> `async with langgraph_runtime(app, startup_config)` -> `_ensure_admin_user` -> channel service / scheduled task service 启动。
- `deps.py` `langgraph_runtime`：`_enforce_postgres_for_multi_worker` -> `make_stream_bridge` -> `init_engine_from_config`（含 bootstrap）-> `make_checkpointer` / `make_store` -> repositories -> `RunManager` -> SQLite 下 `reconcile_orphaned_inflight_runs` 恢复。

## 反模式与陷阱

- ❌ **用户启动前手动 `alembic upgrade head`** -> 与 `bootstrap_schema` 的 advisory lock / asyncio.Lock 冲突，或重复 stamp。修复：删掉部署脚本里的迁移步骤，lifespan 自跑。
- ❌ **Docker dev 镜像 baked-in source** -> 改代码 `--reload` 看不到。修复：compose 必须有 `../backend/:/app/backend/` bind mount；`.venv` 用 named volume 保护不被 host 空目录覆盖。
- ❌ **nginx 没设 `proxy_buffering off` / `X-Accel-Buffering: no`** -> SSE 全程缓冲，前端只在 run 结束时一次性收到所有事件。修复：两个 header 都加。
- ❌ **nginx `proxy_read_timeout` 用默认 60s** -> LLM 调用 + 工具回合数分钟，连接被 nginx 断流。修复：`proxy_read_timeout 600s`。
- ❌ **把 Gateway :8001 与 Frontend :3000 直接暴露给浏览器** -> CORS / Cookie / CSRF 三套配置。修复：统一走 nginx :2026 同源；split-origin 需 `GATEWAY_CORS_ORIGINS` 显式 allowlist。
- ❌ **`GATEWAY_WORKERS > 1` 配 SQLite** -> SQLite 跨进程写锁冲突；`_enforce_postgres_for_multi_worker` 会 `SystemExit` 拒绝启动。修复：multi-worker 强制 Postgres。
- ❌ **pip install + requirements.txt 而非 uv lock** -> CI 间漂移。修复：`uv sync` + 提交 `uv.lock`。
- ❌ **`pyproject.toml` 只在子包没有 workspace 根** -> IDE 跨包跳转、ruff/pytest 配置散乱。修复：workspace 根声明 `[tool.uv.workspace]` + `[tool.uv.sources]`。
- ❌ **改了 `langgraph.json` 图工厂路径忘改 Studio 注册** -> 图工厂注册只此一处，CI 无等价检查。修复：改路径时同步测 `langgraph dev`。
- ❌ **`--workers > 1` 无 sticky session** -> run cancel / SSE 重连 / IM channel service 跨 worker 错乱。修复：默认 `--workers 1`；换 Redis stream bridge 后才提升。
- ❌ **`detect_sandbox_mode` 返回 aio 但没挂 docker socket** -> AioSandboxProvider 启容器失败。修复：`deploy.sh` 自动追加 `docker-compose.dood.yaml` overlay。
- ❌ **Postgres advisory lock 被 managed PG 的 `idle_in_transaction_session_timeout` 杀掉** -> 锁静默释放，第二个 Gateway 并发跑 DDL。修复：`SET LOCAL idle_in_transaction_session_timeout = 0` 在 `pg_advisory_lock` 之前执行。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `GATEWAY_WORKERS` | env | uvicorn worker 数；默认 1，>1 强制 Postgres + Redis stream bridge |
| `PORT` | env | nginx 对外端口，默认 2026 |
| `UV_EXTRAS` | env / config.yaml | `detect_uv_extras.py` 自动探测 postgres 等；`--all-packages` 传播到 workspace 成员 |
| `HELIX_HOME` | env | 运行时数据根（DB、threads、uploads、outputs）；Docker 映射到容器工作目录 |
| `HELIX_CONFIG_PATH` / `HELIX_EXTENSIONS_CONFIG_PATH` | env | config.yaml / extensions_config.json 路径；Docker 卷挂只读 |
| `HELIX_STREAM_BRIDGE_REDIS_URL` | env | Redis stream bridge URL；Docker 默认 `redis://redis:6379/0` |
| `HELIX_INTERNAL_AUTH_TOKEN` | env | 多 worker IM channel 共享内部认证 token；`deploy.sh` 自动生成持久化 |
| `database.backend` | config.yaml | memory / sqlite / postgres；决定 bootstrap lock 策略 |
| `sandbox.use` / `sandbox.provisioner_url` | config.yaml | 决定 `detect_sandbox_mode` 返回 local / aio / provisioner |
| `scheduler.enabled` | config.yaml | 是否启动 ScheduledTaskService poller |

**关键日志串**

- `Configuration loaded successfully` - lifespan 第一步，config.yaml 解析成功
- `bootstrap: branch=empty -> create_all + stamp head` / `branch=legacy` / `branch=versioned` - 三分支选路
- `bootstrap: acquired postgres advisory lock key=0x...` / `acquired sqlite in-process lock` - 锁获取
- `bootstrap: complete (backend=...)` - schema 升级完成
- `Persistence engine initialized: backend=...` - engine 就绪
- `LangGraph runtime initialised` - checkpointer / store / RunManager / StreamBridge 就绪
- `Channel service started: ...` / `No IM channels configured or channel service failed to start` - IM 启动
- `tiktoken encoding cache warmed successfully` / `warm-up timed out` - 预热结果
- `Auto-created PostgreSQL database: ...` - Postgres 建库重试

**自测方向**

- **bootstrap 三分支**：空库 -> `create_all` + stamp head；legacy（手动建表无 alembic_version）-> baseline backfill + stamp baseline + upgrade；versioned -> upgrade head 幂等 no-op。
- **并发 bootstrap**：两个协程同时 `bootstrap_schema` 同一 SQLite -> 一个跑、一个等 `asyncio.Lock`；Postgres -> advisory lock 串行。
- **端口回收**：`make dev` 启动后 `make stop` -> 8001/3000/2026 全部释放；sibling worktree 的进程不被误杀（`_is_framework_pid` 限定）。
- **SSE 透传**：`curl -N http://localhost:2026/api/langgraph/threads/{tid}/runs/stream` -> 事件逐条到达（非 run 结束一次性）。
- **Docker dev reload**：`make docker-start` -> 改 Python 文件 -> Gateway `--reload` 重启；改前端 -> HMR 生效。
- **Docker prod baked**：`make up` -> 改源码不重启容器（镜像 baked）。
- **multi-worker gate**：`GATEWAY_WORKERS=2` + `database.backend: sqlite` -> `SystemExit` 拒绝启动。
- **langgraph.json 注册**：`langgraph dev` -> Studio UI 能看到 `lead_agent` 图。
- **overlay 追加**：`sandbox.use: AioSandboxProvider` 无 `provisioner_url` -> `deploy.sh` 追加 `dood.yaml`；local / provisioner 模式不追加。
- **Postgres 建库重试**：drop database -> 启动 -> `_auto_create_postgres_db` 建库 + bootstrap 重试成功。

## 进一步阅读

- uv workspace + pyproject + langgraph.json + Makefile 完整配置：[references/code/monorepo-and-uv.md](./references/code/monorepo-and-uv.md)
- 启动器脚本（serve.sh / deploy.sh / dev-entrypoint.sh）完整源码：[references/code/startup-sequence.md](./references/code/startup-sequence.md)
- nginx + Docker compose + Dockerfile + provisioner 完整配置：[references/code/nginx-and-docker.md](./references/code/nginx-and-docker.md)
- bootstrap + engine + env.py + lifespan 完整源码：[references/code/alembic-and-lifespan.md](./references/code/alembic-and-lifespan.md)
- 关联 skill：[[e2e-request-lifecycle]]（启动期是请求生命周期前置阶段）、[[core-app-boundary]]（workspace 单向依赖边界）、[[config-and-hot-reload]]（config.yaml 解析与热重载边界）、[[gateway-runs-and-sse]]（SSE 流与 RunManager 单例）、[[sandbox-abstraction]]（provisioner / DooD 沙箱模式）
