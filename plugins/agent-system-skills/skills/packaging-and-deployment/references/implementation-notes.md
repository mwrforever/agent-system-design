# Implementation Notes — packaging-and-deployment

## 1. Monorepo 拓扑：uv workspace + pnpm + 双 Makefile

整个仓库是一个**两栈三层**的 monorepo：

```
<repo-root>/
├── Makefile                  ← 全栈编排（dev / start / stop / up / down）
├── pyproject.toml            ← 顶层占位项目（仅声明根标记 + python 版本下限）
├── uv.lock                   ← 全工作区单一锁文件，提交到 git
├── packages/harness/         ← uv workspace 成员之一（可发布的框架包）
│   └── pyproject.toml        ← name = "<framework-pkg>"; [project.scripts] 在这里
├── <app-pkg>/                ← 应用层（不发布）
│   ├── pyproject.toml        ← [tool.uv] / [tool.uv.workspace] 在此一处声明
│   ├── Makefile              ← 后端模块内命令（dev / gateway / test / lint / migrate-rev）
│   └── tests/
├── frontend/                 ← Next.js
│   ├── package.json
│   ├── pnpm-workspace.yaml
│   ├── pnpm-lock.yaml
│   └── Makefile-less，靠 pnpm scripts
├── docker/                   ← 三套 compose + nginx 配置 + provisioner
│   ├── docker-compose.yaml             ← prod
│   ├── docker-compose-dev.yaml         ← dev（与 prod 是独立两份）
│   ├── docker-compose.cli-auth.yaml    ← 可选覆盖：挂载 ~/.claude / ~/.codex
│   ├── docker-compose.dood.yaml        ← 可选覆盖：DooD 沙箱模式挂 docker.sock
│   └── nginx/nginx.conf
├── scripts/                  ← serve.sh / docker.sh / deploy.sh / setup_wizard.py / doctor.py
├── langgraph.json            ← LangGraph Studio + Server 注册入口
└── extensions_config.json    ← MCP servers + skills 运行时开关
```

**uv workspace 关键点**：`[tool.uv.workspace] members = ["packages/harness"]` 写在
`<app-pkg>/pyproject.toml` 里（不是根），让 `cd <app-pkg> && uv sync` 一次性把 harness 源码
作为可编辑依赖装好，`<app-pkg>` 通过 `[tool.uv.sources] <framework-pkg> = { workspace = true }`
明确引用。一份 `uv.lock` 跨包，IDE 跳转、ruff 配置、pytest 配置都集中在 `<app-pkg>/pyproject.toml`。

## 2. 启动模式矩阵：四组路径，一个入口

对外永远只有一个端口（nginx 2026），但启动器有四种：

| 模式 | 入口命令 | 行为 |
|------|---------|------|
| Local dev（前台） | `make dev` → `scripts/serve.sh --dev` | uvicorn `--reload` + `next dev --turbo` + nginx |
| Local dev（daemon） | `make dev-daemon` | 同上但后台 |
| Local prod（本机） | `make start` | uvicorn 无 reload + `next build && next start` + nginx |
| Docker dev | `make docker-start` → `scripts/docker.sh start` | volume mount + reload + 三容器 |
| Docker prod | `make up` → `scripts/deploy.sh` | 镜像 baked + 三容器 |

`scripts/check.py` 在 `make dev / start` 前先跑，验证 node / pnpm / uv / Python 版本——避免
环境缺工具时一路报到 nginx 才发现。Windows 友好：根 Makefile 通过
`call scripts\run-with-git-bash.cmd` 把 shell 脚本路由到 Git Bash。

`make migrate-rev MSG="..."` 调 `scripts/_autogen_revision.py`，建一份临时 SQLite 跑到 head，
再 diff 当前 ORM 模型生成 alembic revision；**生产路径不暴露 `alembic upgrade`**——
Gateway 在 lifespan 里调 `bootstrap_schema(engine, backend=...)` 自动升库，用户从不手跑。

## 3. nginx：唯一出口 + SSE 友好

`<repo-root>/docker/nginx/nginx.conf` 用 path-based routing，把 `/api/langgraph/*` rewrite 成
`/api/*` 转给 Gateway 的 LangGraph 兼容端点，其它 `/api/*` 直转 Gateway，剩下走 frontend：

```nginx
location /api/langgraph/ {
    rewrite ^/api/langgraph/(.*) /api/$1 break;
    proxy_pass http://$gateway_upstream;
    proxy_http_version 1.1;
    proxy_set_header Connection '';
    proxy_set_header X-Accel-Buffering no;       # ⭐ SSE 必须
    proxy_set_header X-Forwarded-Proto $forwarded_proto;
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    chunked_transfer_encoding on;
}
```

不变量：

- `proxy_buffering off` + `X-Accel-Buffering: no`：SSE 不被 nginx 整段缓冲。
- `proxy_read_timeout 600s`：单次 LLM 调用 + 工具回合可能数分钟，默认 60s 会断流。
- `set $gateway_upstream gateway:8001` 用变量 + DNS resolver：容器重启换 IP 不挂。
- `map $http_x_forwarded_proto $forwarded_proto`：当外层还有 TLS 反代（Cloudflare / Traefik
  等）时保留真实 scheme；缺这条 Gateway 会把 HTTPS 浏览器流量当 HTTP 拒掉登录 POST。
- 上传 location `client_max_body_size 100M; proxy_request_buffering off;`：大文件不落盘
  buffer 直传 Gateway。

## 4. Docker 编排：dev/prod 严格分两份 + opt-in overlay

- **prod (`docker-compose.yaml`)**：frontend 走 `target: prod` 多阶段构建；Gateway 卷挂
  config.yaml / extensions_config.json / skills 只读，挂 `${DEER_FLOW_HOME}` 可写；网络
  `<network>` 内部互联，外部仅暴露 `${PORT:-2026}` 一个端口。
- **dev (`docker-compose-dev.yaml`)**：源码 bind mount 进容器，uvicorn `--reload`、Next.js
  dev server；K8s provisioner 走 `${REPO_ROOT_VAR}/skills` 与 `.../threads` 的 HostPath。
- **opt-in overlay**：`docker-compose.dood.yaml` 加挂 `${DOCKER_SOCKET_VAR}` 启用 DooD
  沙箱；`docker-compose.cli-auth.yaml` 在用 Claude / Codex CLI 当模型时才挂 `~/.claude` /
  `~/.codex`。两个 overlay 默认**不**生效，由 `scripts/deploy.sh` 根据 `config.yaml` 的
  sandbox 模式自动追加 `-f` 参数。

Gateway 的关键编排约束：

```yaml
command: sh -c "... uvicorn <app-pkg>.gateway.app:app --workers ${GATEWAY_WORKERS:-1}"
```

`--workers 1` 是有意默认：Gateway 内部 `RunManager` / `StreamBridge` 是 in-process 单例，
**多 worker 没有 sticky session 时 run cancel / SSE 重连 / IM channel service 全会跨 worker 错乱**——
直到换上共享 stream bridge（如 Redis 后端）才允许提升。

## 5. 启动期 schema 自洽：bootstrap_schema 三分支

`bootstrap_schema(engine, *, backend)` 在 Gateway lifespan 启动期间跑，三分支自动选路：

| 状态 | 行为 |
|------|------|
| 空库（无任何业务表） | `create_all` + `alembic stamp head` |
| 老库（有业务表无 `alembic_version`） | `create_all`（仅 baseline 表）+ `stamp 0001_baseline` + `upgrade head` |
| 已有版本（`alembic_version` 行存在） | `alembic upgrade head` |

并发安全：Postgres 用 `pg_advisory_lock`，SQLite 用进程内 `asyncio.Lock` + 文件锁
（`PRAGMA busy_timeout`），同进程不会双跑、多进程并发也只有一个赢家。这就是为什么生产
**multi-instance 强制用 Postgres**——SQLite 跨进程是 best-effort。

这条管线保证「**用户从不见 `alembic upgrade` 命令**」：模型加列只需在 `migrations/versions/`
塞一份 revision，部署侧零操作。`langgraph.json` 是 Studio / Server 共享入口（图工厂 +
checkpointer 注册），生产 / 本地 / Studio 三处都拿这份。

## 6. 关键不变量、踩坑与调试入口

不变量：

1. **唯一对外入口 = nginx**：CORS / Cookie / CSRF 一致；split-origin 必须显式 allowlist。
2. **alembic 启动期自跑**：用户从不见 `alembic upgrade`；新加列只写 revision。
3. **Docker dev volume mount + reload；prod 镜像 baked**：严格分两份 compose。
4. **`langgraph.json` 是 Studio + Server 共享入口**：图工厂注册只此一处。
5. **uv workspace**：根项目仅占位，工作区配置写在 app 包内；同一 `uv.lock` 跨包。
6. **`--workers 1`**：除非把 `RunManager` / `StreamBridge` 换成共享后端，永远不要调。

踩坑：

1. **手动 `alembic upgrade`**：在 Gateway 启动前跑，会与 `bootstrap_schema` 锁冲突。
2. **Docker dev 镜像 baked**：代码改了 reload 看不到——检查 compose 是否真有 bind mount。
3. **nginx 没 `proxy_buffering off`**：SSE 整段缓冲到 chunk 大小才下发，前端看似卡死。
4. **多端口直接暴露给浏览器**（绕过 nginx）：CORS / Cookie / CSRF 三套；想要也要显式
   `GATEWAY_CORS_ORIGINS` allowlist。
5. **pip + requirements.txt**：跨环境锁不住；统一用 `uv` + `uv.lock` 是硬约束。
6. **`pyproject.toml` 只在子包没有根**：IDE 跳转、ruff、pytest 配置散乱；根至少占位。
7. **改了 `langgraph.json` 路径忘改 Studio 注册**：图工厂只此一处，CI 没有等价检查。

调试入口：

- `make doctor` —— 检查工具链 / 配置完整性 / `config.yaml` 必要字段。
- `docker logs <gateway>` 看 lifespan 三段日志：`Configuration loaded successfully` →
  `Schema bootstrap complete` → `LangGraph runtime initialised` → `Channel service started`。
- `curl http://localhost:8001/health` 看 Gateway 是否真起来；nginx 转发后再
  `curl http://localhost:2026/api/health`。
- `<repo-root>/<runtime-data-dir>/` 是运行时数据根（数据库、threads、uploads、outputs），改
  路径靠应用约定的 `*_HOME` 环境变量；Docker prod 里映射到容器内的 `<app-pkg>` 工作目录。

[[harness-app-boundary]] [[config-and-hot-reload]] [[gateway-runs-and-sse]] [[persistence-and-migrations]] [[sandbox-virtual-paths]]
