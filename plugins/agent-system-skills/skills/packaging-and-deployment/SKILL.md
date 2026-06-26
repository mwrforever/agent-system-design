---
name: packaging-and-deployment
description: 设计 agent 系统的打包与部署——monorepo + uv + langgraph.json + 根 Makefile 编排 + nginx 反代 + alembic 启动自跑 + Docker dev/prod 双模 + 可选 K8s provisioner。
---

## 何时用

- 项目同时有 Python 后端 + TS 前端 + 反代 + 数据库（多服务协作）
- 想用一条命令拉起整个开发栈（`make dev`）
- 生产用 Docker Compose 或 K8s
- 想兼容 LangGraph Studio / LangGraph Platform 注册

## 设计思想

1. **Monorepo + 根 Makefile 编排**：根 `Makefile` 编排"全栈"操作（`dev/start/stop/up/down/docker-start/...`），子目录 `Makefile` 只关心模块本身。
2. **Python 用 `uv`**：单一 `pyproject.toml`，子包通过 `packages/<name>/pyproject.toml` 工作空间方式被引用；锁文件 `uv.lock` 提交。
3. **LangGraph Studio 兼容**：根目录或 `<repo-root>/langgraph.json` 注册 graph 入口；这样既能 `make dev` 自跑，也能 `langgraph dev` 启 Studio UI。
4. **唯一对外入口 = nginx :2026**：浏览器只接触 nginx；nginx 把 `/api/langgraph/*` rewrite 成 `/api/*` 反代到 Gateway；其他 `/` 反代到 Next.js。
5. **alembic 启动自动跑**：Gateway 进程启动时调 `bootstrap_schema()`，按 empty / legacy / versioned 三分支自处理。用户从不手动 `alembic upgrade`。
6. **Docker dev 与 prod 分两份 compose**：dev 用 volume mount + reload；prod 用预构镜像。
7. **可选模式靠 env / config 触发**：K8s provisioner、AIO Docker 沙箱、Langfuse 等都是 opt-in，主路径不依赖。

## 实现模板

### 根 Makefile

```makefile
# Makefile
.PHONY: help check install dev start stop docker-start docker-stop up down

help:                            ## 列出可用 target
	@awk -F':.*##' '/^[a-z][a-zA-Z0-9_-]*:.*##/{printf "  %-20s %s\n", $$1, $$2}' Makefile

check:                           ## 检查 node / pnpm / uv 等工具
	@./scripts/check.sh

config:                          ## 从 example 拷出本地 config
	@./scripts/configure.sh

install: check                   ## 安装前后端依赖
	cd backend  && make install
	cd frontend && pnpm install
	pre-commit install || true

dev:                             ## 起 nginx + gateway + frontend (hot-reload)
	./scripts/serve.sh --dev

dev-daemon:
	./scripts/serve.sh --dev --daemon

start:                           ## 生产 local
	./scripts/serve.sh --prod

stop:
	./scripts/serve.sh --stop

docker-start:                    ## Docker dev (compose up)
	./scripts/docker.sh start

docker-stop:
	./scripts/docker.sh stop

up:                              ## Docker prod (deploy)
	./scripts/deploy.sh

down:
	./scripts/deploy.sh down
```

### `langgraph.json`

```json
{
  "dependencies": ["."],
  "graphs": {
    "lead_agent": "./packages/harness/agent_framework/agents/lead_agent/agent.py:make_lead_agent"
  },
  "env": ".env"
}
```

### 后端 `pyproject.toml` 骨架

```toml
[project]
name = "agent_framework-backend"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
  "agent-harness",                  # 工作空间内引用
  "fastapi>=0.110",
  "uvicorn[standard]>=0.30",
  "langgraph>=1.1",
  "langchain>=1.1",
  # ...
]

[tool.uv.sources]
agent-harness = { workspace = true }

[tool.uv.workspace]
members = ["packages/*"]

[tool.ruff]
line-length = 240
target-version = "py312"
```

### nginx 反代

```nginx
# docker/nginx.conf
upstream gateway   { server gateway:8001; }
upstream frontend  { server frontend:3000; }

server {
    listen 2026;

    # /api/langgraph/* → Gateway，rewrite 掉前缀
    location /api/langgraph/ {
        rewrite ^/api/langgraph/(.*)$ /api/$1 break;
        proxy_pass http://gateway;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;                # SSE 关键
        proxy_read_timeout 1d;
    }

    # 其他 /api/* → Gateway
    location /api/ {
        proxy_pass http://gateway;
        proxy_http_version 1.1;
    }

    # 其他 → Next.js
    location / {
        proxy_pass http://frontend;
        proxy_http_version 1.1;
        proxy_set_header Connection "upgrade";
        proxy_set_header Upgrade $http_upgrade;     # HMR / WebSocket
    }
}
```

### Docker Compose (dev)

```yaml
# docker/docker-compose.dev.yaml
services:
  nginx:
    image: nginx:alpine
    ports: ["2026:2026"]
    volumes: [./docker/nginx.conf:/etc/nginx/conf.d/default.conf:ro]
    depends_on: [gateway, frontend]

  gateway:
    build: { context: ../backend, dockerfile: Dockerfile }
    command: uvicorn app.gateway.app:app --host 0.0.0.0 --port 8001 --reload
    volumes:
      - ../backend:/app
      - ../skills:/app/skills
      - ../config.yaml:/app/config.yaml
      - ../extensions_config.json:/app/extensions_config.json
      - ../.agent-framework:/app/.agent-framework
    environment:
      - PYTHONPATH=/app
      - AGENT_FRAMEWORK_ENV=dev

  frontend:
    build: { context: ../frontend, dockerfile: Dockerfile, target: dev }
    command: pnpm dev
    volumes: [../frontend:/app, /app/node_modules]
    environment:
      - NEXT_PUBLIC_LANGGRAPH_BASE_URL=
      - NEXT_PUBLIC_BACKEND_BASE_URL=
```

### Gateway 启动期 alembic

```python
# harness/persistence/engine.py
async def init_engine(config: DatabaseConfig):
    engine = create_async_engine(config.dsn, ...)
    await bootstrap_schema(engine, backend=config.backend)   # ⭐ 自动 alembic upgrade
    return engine


# app/gateway/deps.py
@asynccontextmanager
async def langgraph_runtime(app, startup_config):
    engine = await init_engine(startup_config.database)
    app.state.engine = engine
    ...
```

### 控制台脚本（harness 可独立）

```toml
# packages/harness/pyproject.toml
[project.scripts]
agent_framework = "agent_framework.tui.cli:main"      # TTY → TUI; non-TTY → help
```

## 反模式

- ❌ 用户启动前手动 `alembic upgrade head` → 升级时漏跑导致 schema drift
- ❌ Docker dev 镜像 baked-in source → 改代码不重启不生效；应当 volume mount + reload
- ❌ nginx 没设 `proxy_buffering off` → SSE 全程缓冲，前端只在结束时一次性收到所有事件
- ❌ 把 Gateway 与 Frontend 暴露各自的端口给浏览器 → CORS / Cookie / CSRF 多套配置；统一走 nginx 才一致
- ❌ pip install + requirements.txt 而非 uv lock → CI 间漂移
- ❌ `pyproject.toml` 在子包，根没有 workspace → IDE 跨包跳转、ruff 配置散乱
- ✅ Gateway lifespan 里 bootstrap，用户从不见 alembic 命令
- ✅ Docker dev 与 prod 严格两份 compose，避免 dev 习惯泄漏到 prod

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[config-and-hot-reload]] [[harness-app-boundary]] [[gateway-runs-and-sse]]
