# 完整源码：Monorepo + uv workspace + langgraph.json + Makefile

> 本文件给出打包与编排层的**完整真实配置**：根占位 `pyproject.toml`、workspace 根 `pyproject.toml`（uv workspace 声明）、框架包 `core/pyproject.toml`（包名 `helix`、console script、可选 extras）、`langgraph.json`（Studio + Server 共享入口）、根 `Makefile`（全栈编排）、per-module `Makefile`（dev/gateway/test/lint/migrate-rev）。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`、env 前缀 `HELIX_*`、uvicorn 入口 `gateway.gateway.app:app`），去除一切项目字样。原代码注释保留以保真。

## 1. 根占位 pyproject.toml

仓库根的 `pyproject.toml` 仅占位：声明项目名 + Python 版本下限，无依赖。真正的工作区配置在 workspace 根（应用层）。

```toml
# <repo-root>/pyproject.toml
[project]
name = "helix"
version = "0.1.0"
requires-python = ">=3.14"
dependencies = []
```

## 2. Workspace 根 pyproject.toml

应用层 workspace 根（对应自定结构的 `<workspace-root>/pyproject.toml`）。`[tool.uv.workspace] members = ["core"]` 声明框架包为 workspace 成员；`[tool.uv.sources] helix = { workspace = true }` 让应用层以可编辑方式引用框架包源码。一份 `uv.lock` 跨包，IDE 跳转、ruff、pytest 配置集中在此。

```toml
# <workspace-root>/pyproject.toml
[project]
name = "helix-gateway"
version = "2.1.0"
description = "LangGraph-based AI agent system with sandbox execution capabilities"
readme = "README.md"
requires-python = ">=3.12"
dependencies = [
    "helix",
    "fastapi>=0.115.0",
    "httpx>=0.28.0",
    "python-multipart>=0.0.31",
    "sse-starlette>=2.1.0",
    "uvicorn[standard]>=0.34.0",
    "lark-oapi>=1.4.0",
    "slack-sdk>=3.33.0",
    "python-telegram-bot>=21.0",
    "langgraph-sdk>=0.1.51",
    "markdown-to-mrkdwn>=0.3.1",
    "wecom-aibot-python-sdk>=0.1.6",
    "dingtalk-stream>=0.24.3",
    "bcrypt>=4.0.0",
    "pyjwt>=2.13.0",
    "email-validator>=2.0.0",
    "e2b-code-interpreter>=2.8.1",
]

[project.optional-dependencies]
postgres = ["helix[postgres]"]
redis = ["helix[redis]"]
discord = ["discord.py>=2.7.0"]

[dependency-groups]
dev = [
    "blockbuster>=1.5.26,<1.6",
    "prompt-toolkit>=3.0.0",
    "pytest>=9.0.3",
    "pytest-asyncio>=1.3.0",
    "ruff>=0.14.11",
    # redis 是可选运行时 extra（helix[redis]）；固定在 dev group 以便
    # stream-bridge 测试总能 import/演练 redis bridge，不强制生产安装带上它。
    "redis>=5.0.0",
    # TUI 运行时依赖（也声明为 helix[tui] extra）；保留在 dev group
    # 以便终端 workbench 可在本地 / CI 运行与测试。
    "textual>=0.80",
]

[tool.pytest.ini_options]
markers = [
    "no_auto_user: disable the conftest autouse contextvar fixture for this test",
    "allow_blocking_io: opt out of the strict Blockbuster gate in tests/blocking_io/",
    "integration: tests that require an external service (e.g. Redis); skipped when unavailable",
]

[tool.uv]
index-url = "https://pypi.org/simple"

[tool.uv.workspace]
members = ["core"]

[tool.uv.sources]
helix = { workspace = true }
```

## 3. 框架包 core/pyproject.toml

可发布的框架包（对应自定结构 `core/pyproject.toml`，真实侧是 workspace 成员）。包名 `helix`，console script `helix`（TTY -> TUI，non-TTY -> help）。可选 extras 控制按需依赖：`postgres`、`redis`（stream bridge）、`tui`（textual）等。Docker 镜像默认装 `redis` extra（因 Docker Compose 默认 stream bridge 走 Redis）。

```toml
# core/pyproject.toml
[project]
name = "helix"
version = "2.1.0"
description = "Helix agent harness framework"
requires-python = ">=3.12"
dependencies = [
    "agent-client-protocol>=0.4.0",
    "agent-sandbox>=0.0.19",
    "croniter>=6.0.0",
    "dotenv>=0.9.9",
    "exa-py>=1.0.0",
    "httpx>=0.28.0",
    "kubernetes>=30.0.0",
    "langchain>=1.2.15",
    "langchain-anthropic>=1.4.1",
    "langchain-deepseek>=1.0.1",
    "langchain-mcp-adapters>=0.2.2",
    "langchain-openai>=1.2.1",
    "langfuse>=3.4.1",
    "langgraph>=1.1.9",
    "langgraph-api>=0.8.1",
    "langgraph-cli>=0.4.24",
    "langgraph-runtime-inmem>=0.28.0",
    "markdownify>=1.2.2",
    "markitdown[all,xlsx]>=0.0.1a2",
    "pydantic>=2.12.5",
    "pyyaml>=6.0.3",
    "readabilipy>=0.3.0",
    "tavily-python>=0.7.17",
    "firecrawl-py>=1.15.0",
    "tiktoken>=0.8.0",
    "ddgs>=9.10.0",
    "duckdb>=1.4.4",
    "langchain-google-genai>=4.2.1",
    "langgraph-checkpoint-sqlite>=3.0.3",
    "langgraph-sdk>=0.1.51",
    "sqlalchemy[asyncio]>=2.0,<3.0",
    "aiosqlite>=0.19",
    "alembic>=1.13",
    "cryptography>=48.0.1",
    "e2b-code-interpreter>=2.8.0",
]

[project.scripts]
helix = "helix.tui.cli:main"

[project.optional-dependencies]
# 终端 workbench（TUI）。保持可选让核心安装精简；
# `helix` console script 在 textual 缺失时降级为 headless help。
tui = ["textual>=0.80"]
# GroundRoute 无需额外包（httpx 已是核心依赖）。这个空 extra 存在是为了让
# 文档化的 `uv add 'helix[groundroute]'` 安装命令能解析，不报 "unknown extra"。
groundroute = []
ollama = ["langchain-ollama>=0.3.0"]
postgres = [
    "asyncpg>=0.29",
    "langgraph-checkpoint-postgres>=3.0.5",
    "psycopg[binary]>=3.3.3",
    "psycopg-pool>=3.3.0",
]
# 跨进程 SSE stream bridge（stream_bridge.type: redis）。可选以避免
# 单进程 / memory-bridge 安装拉入 redis。Docker 镜像始终装此 extra，
# 因 Docker 默认走 redis bridge。
redis = ["redis>=5.0.0"]
pymupdf = ["pymupdf4llm>=0.0.17"]
boxlite = ["boxlite>=0.9.7"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["helix"]
```

## 4. langgraph.json

LangGraph Studio + Server 共享入口（对应自定结构 `<workspace-root>/langgraph.json`）。图工厂 `make_lead_agent`、auth handler `auth`、checkpointer 工厂 `make_checkpointer` 在此一处注册。本地 / 生产 / Studio 三处都拿这份。`dependencies: ["."]` 指向 workspace 根（含 `pyproject.toml` + `uv.lock`）。

```json
{
  "$schema": "https://langgra.ph/schema.json",
  "python_version": "3.12",
  "dependencies": [
    "."
  ],
  "env": ".env",
  "graphs": {
    "lead_agent": "helix.agents:make_lead_agent"
  },
  "auth": {
    "path": "./gateway/gateway/langgraph_auth.py:auth"
  },
  "checkpointer": {
    "path": "./core/helix/runtime/checkpointer/async_provider.py:make_checkpointer"
  }
}
```

## 5. 根 Makefile（全栈编排）

根 `Makefile` 编排"全栈"操作：`dev/start/stop/up/down/docker-start/...`。通过 `scripts/serve.sh` / `scripts/deploy.sh` / `scripts/docker.sh` 路由到三种启动器。Windows 友好：通过 `call scripts\run-with-git-bash.cmd` 把 shell 脚本路由到 Git Bash。`BACKEND_UV_RUN = cd backend && uv run` 让 setup/doctor/support-bundle 在 workspace 根跑 uv。

```makefile
# <repo-root>/Makefile

.PHONY: help config config-upgrade check install setup doctor support-bundle detect-thread-boundaries detect-blocking-io dev dev-daemon start start-daemon nginx stop up down clean docker-init docker-start docker-stop docker-logs docker-logs-frontend docker-logs-gateway docker-logs-redis

BASH ?= bash
BACKEND_UV_RUN = cd backend && uv run

# Detect OS for Windows compatibility
ifeq ($(OS),Windows_NT)
    SHELL := cmd.exe
    PYTHON ?= python
    # Run repo shell scripts through Git Bash when Make is launched from cmd.exe / PowerShell.
    RUN_WITH_GIT_BASH = call scripts\run-with-git-bash.cmd
else
    PYTHON ?= python3
    RUN_WITH_GIT_BASH =
endif

help:
	@echo "Helix Development Commands:"
	@echo "  make setup           - Interactive setup wizard (recommended for new users)"
	@echo "  make doctor          - Check configuration and system requirements"
	@echo "  make support-bundle  - Create a redacted issue summary, AI draft, and evidence bundle"
	@echo "  make config          - Generate local config files (aborts if config already exists)"
	@echo "  make config-upgrade  - Merge new fields from config.example.yaml into config.yaml"
	@echo "  make check           - Check if all required tools are installed"
	@echo "  make detect-thread-boundaries - Inventory async/thread boundary points"
	@echo "  make detect-blocking-io        - Inventory blocking IO that may block the backend event loop"
	@echo "  make install         - Install all dependencies (frontend + backend + pre-commit hooks)"
	@echo "  make setup-sandbox   - Pre-pull sandbox container image (recommended)"
	@echo "  make dev             - Start all services in development mode (with hot-reloading)"
	@echo "  make dev-daemon      - Start dev services in background (daemon mode)"
	@echo "  make start           - Start all services in production mode (optimized, no hot-reloading)"
	@echo "  make start-daemon    - Start prod services in background (daemon mode)"
	@echo "  make nginx           - Start nginx alone in the foreground (local dev config)"
	@echo "  make stop            - Stop all running services"
	@echo "  make clean           - Clean up processes and temporary files"
	@echo ""
	@echo "Docker Production Commands:"
	@echo "  make up              - Build and start production Docker services (localhost:2026)"
	@echo "  make down            - Stop and remove production Docker containers"
	@echo ""
	@echo "Docker Development Commands:"
	@echo "  make docker-init     - Pull the sandbox image"
	@echo "  make docker-start    - Start Docker services (mode-aware from config.yaml, localhost:2026)"
	@echo "  make docker-stop     - Stop Docker development services"
	@echo "  make docker-logs     - View Docker development logs"
	@echo "  make docker-logs-frontend - View Docker frontend logs"
	@echo "  make docker-logs-gateway - View Docker gateway logs"
	@echo "  make docker-logs-redis - View Docker Redis logs"

## Setup & Diagnosis
setup:
	@$(BACKEND_UV_RUN) python ../scripts/setup_wizard.py

doctor:
	@$(BACKEND_UV_RUN) python ../scripts/doctor.py

support-bundle:
	@$(BACKEND_UV_RUN) python ../scripts/support_bundle.py --include-doctor

detect-thread-boundaries:
	@$(PYTHON) ./scripts/detect_thread_boundaries.py

detect-blocking-io:
	@$(MAKE) -C backend detect-blocking-io

config:
	@$(PYTHON) ./scripts/configure.py

config-upgrade:
	@$(RUN_WITH_GIT_BASH) ./scripts/config-upgrade.sh

# Check required tools
check:
	@$(PYTHON) ./scripts/check.py

# Install all dependencies
install:
	@echo "Installing backend dependencies..."
	@cd backend && uv sync
	@echo "Installing frontend dependencies..."
	@cd frontend && pnpm install
	@echo "Installing pre-commit hooks..."
	@uv tool install pre-commit
	@pre-commit install --overwrite
	@echo "✓ All dependencies installed"
	@echo ""
	@echo "=========================================="
	@echo "  Optional: Pre-pull Sandbox Image"
	@echo "=========================================="
	@echo ""
	@echo "If you plan to use Docker/Container-based sandbox, you can pre-pull the image:"
	@echo "  make setup-sandbox"
	@echo ""

# Pre-pull sandbox Docker image (optional but recommended)
setup-sandbox:
	@$(RUN_WITH_GIT_BASH) ./scripts/setup-sandbox.sh

# Start all services in development mode (with hot-reloading)
dev:
	@$(PYTHON) ./scripts/check.py
	@$(RUN_WITH_GIT_BASH) ./scripts/serve.sh --dev

# Start all services in production mode (with optimizations)
start:
	@$(PYTHON) ./scripts/check.py
	@$(RUN_WITH_GIT_BASH) ./scripts/serve.sh --prod

# Start all services in daemon mode (background)
dev-daemon:
	@$(PYTHON) ./scripts/check.py
	@$(RUN_WITH_GIT_BASH) ./scripts/serve.sh --dev --daemon

# Start prod services in daemon mode (background)
start-daemon:
	@$(PYTHON) ./scripts/check.py
	@$(RUN_WITH_GIT_BASH) ./scripts/serve.sh --prod --daemon

# Start nginx alone in the foreground with the local dev config
nginx:
	@$(RUN_WITH_GIT_BASH) ./scripts/nginx.sh

# Stop all services
stop:
	@$(RUN_WITH_GIT_BASH) ./scripts/serve.sh --stop

# Clean up
clean: stop
	@echo "Cleaning up..."
	@-rm -rf backend/.helix 2>/dev/null || true
	@-rm -rf logs/*.log 2>/dev/null || true
	@echo "✓ Cleanup complete"

# ==========================================
# Docker Development Commands
# ==========================================

# Initialize Docker containers and install dependencies
docker-init:
	@$(RUN_WITH_GIT_BASH) ./scripts/docker.sh init

# Start Docker development environment
docker-start:
	@$(RUN_WITH_GIT_BASH) ./scripts/docker.sh start

# Stop Docker development environment
docker-stop:
	@$(RUN_WITH_GIT_BASH) ./scripts/docker.sh stop

# View Docker development logs
docker-logs:
	@$(RUN_WITH_GIT_BASH) ./scripts/docker.sh logs

# View Docker development logs
docker-logs-frontend:
	@$(RUN_WITH_GIT_BASH) ./scripts/docker.sh logs --frontend
docker-logs-gateway:
	@$(RUN_WITH_GIT_BASH) ./scripts/docker.sh logs --gateway
docker-logs-redis:
	@$(RUN_WITH_GIT_BASH) ./scripts/docker.sh logs --redis

# ==========================================
# Production Docker Commands
# ==========================================

# Build and start production services
up:
	@$(RUN_WITH_GIT_BASH) ./scripts/deploy.sh

# Stop and remove production containers
down:
	@$(RUN_WITH_GIT_BASH) ./scripts/deploy.sh down
```

## 6. Per-module Makefile（workspace 根）

workspace 根的 per-module `Makefile`（对应自定结构 `<workspace-root>/Makefile`）。只管模块本身：`dev`（uvicorn --reload）、`gateway`（uvicorn 无 reload）、`test`、`lint`、`format`、`migrate-rev`。**生产路径不暴露 `alembic upgrade`**--Gateway 在 lifespan 里调 `bootstrap_schema` 自动升库，用户从不手跑。`migrate-rev` 调 `scripts/_autogen_revision.py`，建临时 SQLite 跑到 head 再 diff 当前 ORM 模型生成 revision。

```makefile
# <workspace-root>/Makefile
install:
	uv sync

dev:
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run uvicorn gateway.gateway.app:app --host 0.0.0.0 --port 8001 --reload

gateway:
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run uvicorn gateway.gateway.app:app --host 0.0.0.0 --port 8001

test:
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run pytest tests/ -v

test-blocking-io:
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run pytest tests/blocking_io -q --tb=short

lint:
	uvx ruff check .
	uvx ruff format --check .

format:
	uvx ruff check . --fix && uvx ruff format .

detect-blocking-io:
	@PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run python ../scripts/detect_blocking_io_static.py --output ../.helix/blocking-io-findings.json

# Generate a new alembic revision by autogenerating the diff against the live
# ORM models. Usage: make migrate-rev MSG="add foo column to runs"
# The Gateway runs `alembic upgrade head` automatically at startup via
# `bootstrap_schema`, so there is intentionally no `migrate` / `migrate-stamp`
# target -- the single execution path keeps ops mistakes off the table.
# The script builds a fresh temp SQLite at head, then diffs the live models
# against it, so a clean checkout does NOT need a pre-existing ./data/helix.db.
migrate-rev:
	@if [ -z "$(MSG)" ]; then echo 'usage: make migrate-rev MSG="describe the change"'; exit 1; fi
	PYTHONPATH=. PYTHONIOENCODING=utf-8 PYTHONUTF8=1 uv run python scripts/_autogen_revision.py "$(MSG)"
```
