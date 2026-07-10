# 完整源码：启动器脚本（serve.sh / deploy.sh / dev-entrypoint.sh）

> 本文件给出三种启动器的**完整真实源码**：`serve.sh`（本地 dev/prod）、`deploy.sh`（Docker prod）、`dev-entrypoint.sh`（Docker dev 容器内入口）。覆盖启动序、端口回收、依赖同步、uv extras 探测、sandbox 模式探测、uvicorn handoff。
>
> 真实实现已按匿名化规则映射到中立结构（env 前缀 `HELIX_*`、uvicorn 入口 `gateway.gateway.app:app`、运行时数据目录 `.helix`），去除一切项目字样。原代码注释保留以保真。

## 1. scripts/serve.sh（本地 dev/prod 启动器）

统一服务启动器。`--dev` 走 uvicorn `--reload` + `next dev` + nginx；`--prod` 走 uvicorn 无 reload + `next build && next start` + nginx；`--daemon` 后台。`stop_all()` 用 `_is_framework_pid` + `lsof` 限定回收本 worktree 进程的 8001/3000/2026 端口（sibling worktree 的进程不被误杀）。`detect_uv_extras.py` 从 config.yaml 探测 extras（如 postgres），`--all-packages` 传播到 workspace 成员。`run_service` 用 `wait-for-port.sh` 等端口就绪才继续。

```bash
#!/usr/bin/env bash
#
# serve.sh - Unified service launcher
#
# Usage:
#   ./scripts/serve.sh [--dev|--prod] [--daemon] [--stop|--restart]
#
# Modes:
#   --dev       Development mode with hot-reload (default)
#   --prod      Production mode, pre-built frontend, no hot-reload
#   --daemon    Run all services in background (nohup), exit after startup
#
# Actions:
#   --skip-install  Skip dependency installation (faster restart)
#   --stop      Stop all running services and exit
#   --restart   Stop all services, then start with the given mode flags
#
# Examples:
#   ./scripts/serve.sh --dev                 # Gateway dev, hot reload
#   ./scripts/serve.sh --prod                # Gateway prod
#   ./scripts/serve.sh --dev --daemon        # Gateway dev, background
#   ./scripts/serve.sh --stop                # Stop all services
#   ./scripts/serve.sh --restart --dev       # Restart dev services
#
# Must be run from the repo root directory.

set -e

REPO_ROOT="$(builtin cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd -P)"
cd "$REPO_ROOT"

# ── Load .env ────────────────────────────────────────────────────────────────

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

_pick_python() {
    local candidate
    for candidate in python3 python py; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info.major >= 3 else 1)' >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────

DEV_MODE=true
DAEMON_MODE=false
SKIP_INSTALL=false
ACTION="start"   # start | stop | restart

for arg in "$@"; do
    case "$arg" in
        --dev)     DEV_MODE=true ;;
        --prod)    DEV_MODE=false ;;
        --daemon)  DAEMON_MODE=true ;;
        --skip-install) SKIP_INSTALL=true ;;
        --stop)    ACTION="stop" ;;
        --restart) ACTION="restart" ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--dev|--prod] [--daemon] [--skip-install] [--stop|--restart]"
            exit 1
            ;;
    esac
done

# ── Stop helper ──────────────────────────────────────────────────────────────

# Every worktree (the main checkout + each linked worktree) hardcodes
# the same dev ports (8001/3000/2026), so a service started from ANY of them
# must be reclaimable from here - otherwise `make stop`/`make dev` in this
# worktree can neither kill nor take over a port held by a sibling worktree.
# HELIX_ROOTS is that set of roots; processes living outside all of them
# (e.g. an unrelated project on port 3000) are still never touched.
# Sorted most-specific-first (longest path first): a linked worktree lives
# under the main checkout, so both roots are substrings of its files - checking
# the deeper root first attributes a reclaimed port to the right worktree.
HELIX_ROOTS="$(
    {
        printf '%s\n' "$REPO_ROOT"
        git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null |
            awk '/^worktree /{print $2}'
    } | awk 'NF && !seen[$0]++ {print length($0)"\t"$0}' | sort -rn | sed 's/^[0-9]*\t//'
)"

# True if PID has an open file/cwd under any worktree root. The
# trailing slash keeps a sibling dir like ".../helix-notes" from matching
# the ".../helix" root.
_is_framework_pid() {
    local pid=$1 files root

    # Daemon children inherit HELIX_DAEMON_ROOT from run_service. Checking
    # it (Linux only - macOS has no /proc) identifies processes like
    # next-server that lsof misses, so the name/port reaps in stop_all can
    # claim them.
    if [ -r "/proc/$pid/environ" ] &&
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -Fxq "HELIX_DAEMON_ROOT=$REPO_ROOT"; then
        return 0
    fi

    files=$(lsof -b -w -p "$pid" 2>/dev/null) || return 1
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        case "$files" in
            *"$root"/*) return 0 ;;
        esac
    done <<< "$HELIX_ROOTS"
    return 1
}

# Report ports about to be reclaimed from a *different* worktree, so stopping
# (or starting, which stops first) isn't silently killing someone else's run.
_report_reclaimed_ports() {
    local port pid files root owner
    for port in 8001 3000 2026; do
        for pid in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null); do
            _is_framework_pid "$pid" || continue
            files=$(lsof -b -w -p "$pid" 2>/dev/null)
            case "$files" in *"$REPO_ROOT"/*) continue ;; esac  # this worktree - normal
            owner=""
            while IFS= read -r root; do
                [ -n "$root" ] || continue
                case "$files" in *"$root"/*) owner="$root"; break ;; esac
            done <<< "$HELIX_ROOTS"
            echo "  ↻ Reclaiming port $port from another worktree: ${owner:-?}"
            break
        done
    done
}

_kill_repo_processes() {
    local pattern=$1
    local pid
    local pids=""

    while IFS= read -r pid; do
        if [ -n "$pid" ] && _is_framework_pid "$pid"; then
            case " $pids " in
                *" $pid "*) ;;
                *) pids="$pids $pid" ;;
            esac
        fi
    done < <(pgrep -f "$pattern" 2>/dev/null || true)

    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
    fi
}

_kill_repo_port() {
    local port=$1
    local pid
    local pids=""

    while IFS= read -r pid; do
        if [ -n "$pid" ] && _is_framework_pid "$pid"; then
            case " $pids " in
                *" $pid "*) ;;
                *) pids="$pids $pid" ;;
            esac
        fi
    done < <(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)

    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null || true
    fi
}

_is_port_listening() {
    local port=$1

    if command -v lsof >/dev/null 2>&1; then
        if lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "( sport = :$port )" 2>/dev/null | tail -n +2 | grep -q .; then
            return 0
        fi
    fi

    if command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])${port}$"; then
            return 0
        fi
    fi

    return 1
}

_is_repo_nginx_pid() {
    local pid=$1
    local command
    local args

    command=$(ps -p "$pid" -o comm= 2>/dev/null) || return 1
    # nginx rewrites argv[0] for master/worker processes. On macOS,
    # `ps -o comm=` can report that rewritten form instead of the binary name.
    case "$command" in
        nginx|*/nginx|nginx:*) ;;
        *) return 1 ;;
    esac

    args=$(ps -p "$pid" -o args= 2>/dev/null) || return 1
    local root
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        case "$args" in
            *"$root"/docker/nginx/nginx.local.conf*|*"$root"/*) return 0 ;;
        esac
    done <<< "$HELIX_ROOTS"

    _is_framework_pid "$pid"
}

_kill_repo_nginx() {
    local pid
    local pids=""

    if [ -f "$REPO_ROOT/logs/nginx.pid" ]; then
        read -r pid < "$REPO_ROOT/logs/nginx.pid" || true
        if [ -n "$pid" ] && _is_repo_nginx_pid "$pid"; then
            pids="$pids $pid"
        fi
    fi

    while IFS= read -r pid; do
        if [ -n "$pid" ] && _is_repo_nginx_pid "$pid"; then
            case " $pids " in
                *" $pid "*) ;;
                *) pids="$pids $pid" ;;
            esac
        fi
    done < <(pgrep -f nginx 2>/dev/null || true)

    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null || true
    fi
}

stop_all() {
    echo "Stopping all services..."
    _report_reclaimed_ports
    _kill_repo_processes "uvicorn gateway.gateway.app:app"
    _kill_repo_processes "next dev"
    _kill_repo_processes "next start"
    _kill_repo_processes "next-server"
    nginx -c "$REPO_ROOT/docker/nginx/nginx.local.conf" -p "$REPO_ROOT" -s quit 2>/dev/null || true
    sleep 1
    _kill_repo_nginx
    # Force-kill any survivors still holding the service ports. 2026 is included
    # so a lingering nginx (or any framework process) that _kill_repo_nginx did
    # not match by name still gets reclaimed - otherwise `make dev` fails its
    # nginx port preflight.
    _kill_repo_port 8001
    _kill_repo_port 3000
    _kill_repo_port 2026
    ./scripts/cleanup-containers.sh helix-sandbox 2>/dev/null || true
    echo "✓ All services stopped"
}

# ── Action routing ───────────────────────────────────────────────────────────

if [ "$ACTION" = "stop" ]; then
    stop_all
    exit 0
fi

ALREADY_STOPPED=false
if [ "$ACTION" = "restart" ]; then
    stop_all
    sleep 1
    ALREADY_STOPPED=true
fi

# Mode label for banner
if $DEV_MODE; then
    MODE_LABEL="DEV (Gateway runtime, hot-reload enabled)"
else
    MODE_LABEL="PROD (Gateway runtime, optimized)"
fi

if $DAEMON_MODE; then
    MODE_LABEL="$MODE_LABEL [daemon]"
fi

# Frontend command
if $DEV_MODE; then
    FRONTEND_CMD="pnpm run dev"
else
    if ! PYTHON_BIN="$(_pick_python)"; then
        echo "Python is required to generate BETTER_AUTH_SECRET."
        exit 1
    fi
    FRONTEND_CMD="env BETTER_AUTH_SECRET=$($PYTHON_BIN -c 'import secrets; print(secrets.token_hex(16))') pnpm run preview"
fi

# Runtime path defaults. Local `make dev` launches Gateway from the workspace
# root, so pin framework-owned state to the expected runtime directory and
# create it before uvicorn builds its reload exclude filter.
if [ -z "$HELIX_PROJECT_ROOT" ]; then
    export HELIX_PROJECT_ROOT="$REPO_ROOT"
fi

BACKEND_RUNTIME_HOME="$REPO_ROOT/backend/.helix"
if [ -z "$HELIX_HOME" ]; then
    export HELIX_HOME="$BACKEND_RUNTIME_HOME"
fi

# `backend/sandbox` is excluded from uvicorn's reload watcher below. uvicorn only
# excludes an absolute path directly when it already exists as a directory;
# otherwise it globs the pattern, and Python 3.12's pathlib rejects absolute glob
# patterns with NotImplementedError, crashing `make dev` on a fresh checkout.
# Creating it here keeps every absolute exclude on the is_dir path.
mkdir -p "$HELIX_HOME" "$BACKEND_RUNTIME_HOME" "$REPO_ROOT/backend/sandbox"
HELIX_HOME="$(cd "$HELIX_HOME" && pwd -P)"
BACKEND_RUNTIME_HOME="$(cd "$BACKEND_RUNTIME_HOME" && pwd -P)"
export HELIX_HOME

# Extra flags for uvicorn
if $DEV_MODE && ! $DAEMON_MODE; then
    GATEWAY_EXTRA_FLAGS="--reload --reload-include='*.yaml' --reload-include='.env' --reload-exclude='*.pyc' --reload-exclude='__pycache__' --reload-exclude='$REPO_ROOT/backend/sandbox' --reload-exclude='$HELIX_HOME' --reload-exclude='$BACKEND_RUNTIME_HOME'"
else
    GATEWAY_EXTRA_FLAGS=""
fi

# ── Stop existing services (skip if restart already did it) ──────────────────

if ! $ALREADY_STOPPED; then
    stop_all
    sleep 1
fi

# ── Config check ─────────────────────────────────────────────────────────────

if ! { \
        [ -n "$HELIX_CONFIG_PATH" ] && [ -f "$HELIX_CONFIG_PATH" ] || \
        [ -f backend/config.yaml ] || \
        [ -f config.yaml ]; \
    }; then
    echo "✗ No config file found."
    echo "  Run 'make setup' (recommended) or 'make config' to generate config.yaml."
    exit 1
fi

"$REPO_ROOT/scripts/config-upgrade.sh"

# ── Install dependencies ────────────────────────────────────────────────────

# Pick a runnable Python for the extras detector. On Windows/Git Bash,
# `python3` can resolve to the Microsoft Store alias in WindowsApps, which is
# present on PATH but not executable from Bash.
DETECT_PYTHON="$(_pick_python || true)"

# Resolve uv extras (postgres, etc.) from UV_EXTRAS or config.yaml so that
# `uv sync` does not wipe out optional dependencies on every restart. See
# scripts/detect_uv_extras.py for context. The detector
# whitelists extra names against `^[A-Za-z][A-Za-z0-9_-]*$`, so the unquoted
# splat below only sees valid uv argument tokens.
#
# Stderr is intentionally NOT redirected so the user sees:
#   - whitelist warnings (e.g. "ignoring invalid UV_EXTRAS entry ';'");
#   - detector crashes (e.g. unexpected Python error).
# `|| true` keeps `set -e` from killing dev startup on a detector failure;
# the result is just an empty UV_EXTRAS_FLAGS, which means "no extras".
UV_EXTRAS_FLAGS=""
if [ -n "$DETECT_PYTHON" ]; then
    UV_EXTRAS_FLAGS=$("$DETECT_PYTHON" "$REPO_ROOT/scripts/detect_uv_extras.py" || { echo "[serve.sh] detect_uv_extras.py failed (exit $?) - proceeding without extras" >&2; echo ""; })
fi

if ! $SKIP_INSTALL; then
    echo "Syncing dependencies..."
    if [ -n "$UV_EXTRAS_FLAGS" ]; then
        echo "  • uv extras: $UV_EXTRAS_FLAGS"
    fi
    # `--all-packages` propagates extras into workspace members (the framework
    # package in particular). Required for postgres extras.
    # Intentionally unquoted to splat multiple `--extra X` pairs.
    (cd backend && uv sync --quiet --all-packages $UV_EXTRAS_FLAGS) || { echo "✗ Backend dependency install failed"; exit 1; }
    (cd frontend && pnpm install --silent) || { echo "✗ Frontend dependency install failed"; exit 1; }
    echo "✓ Dependencies synced"
else
    echo "⏩ Skipping dependency install (--skip-install)"
fi

# ── Banner ───────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "  Starting Helix"
echo "=========================================="
echo ""
echo "  Mode: $MODE_LABEL"
echo ""
echo "  Services:"
echo "    Gateway     -> localhost:8001  (REST API + agent runtime)"
echo "    Frontend    -> localhost:3000  (Next.js)"
echo "    Nginx       -> localhost:2026  (reverse proxy)"
echo ""

# ── Cleanup handler ──────────────────────────────────────────────────────────

cleanup() {
    local status="${1:-0}"
    trap - INT TERM
    echo ""
    stop_all
    exit "$status"
}

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# ── Helper: start a service ──────────────────────────────────────────────────

# run_service NAME COMMAND PORT TIMEOUT
# In daemon mode, wraps with nohup. Waits for port to be ready.
run_service() {
    local name="$1" cmd="$2" port="$3" timeout="$4"

    if _is_port_listening "$port"; then
        echo "✗ $name cannot start because port $port is already in use."
        echo "  If it belongs to this worktree, run 'make stop'; otherwise free the port manually."
        cleanup 1
    fi

    echo "Starting $name..."
    if $DAEMON_MODE; then
        # Tag the daemon so every descendant (pnpm -> next -> next-server)
        # carries HELIX_DAEMON_ROOT in its environment, letting
        # _is_framework_pid recognize it at stop time.
        nohup env HELIX_DAEMON_ROOT="$REPO_ROOT" sh -c "$cmd" > /dev/null 2>&1 &
    else
        sh -c "$cmd" &
    fi

    ./scripts/wait-for-port.sh "$port" "$timeout" "$name" || {
        local logfile="logs/$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-').log"
        echo "✗ $name failed to start."
        [ -f "$logfile" ] && tail -20 "$logfile"
        cleanup 1
    }
    echo "✓ $name started on localhost:$port"
}

# ── Start services ───────────────────────────────────────────────────────────

mkdir -p logs
mkdir -p temp/client_body_temp temp/proxy_temp temp/fastcgi_temp temp/uwsgi_temp temp/scgi_temp

# 1. Gateway API
run_service "Gateway" \
    "cd backend && PYTHONPATH=. uv run uvicorn gateway.gateway.app:app --host 0.0.0.0 --port 8001 $GATEWAY_EXTRA_FLAGS > ../logs/gateway.log 2>&1" \
    8001 30

# 2. Frontend
run_service "Frontend" \
    "cd frontend && $FRONTEND_CMD > ../logs/frontend.log 2>&1" \
    3000 120

# 3. Nginx
run_service "Nginx" \
    "nginx -g 'daemon off;' -c '$REPO_ROOT/docker/nginx/nginx.local.conf' -p '$REPO_ROOT' > logs/nginx.log 2>&1" \
    2026 10

# ── Ready ────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "  ✓ Helix is running!  [$MODE_LABEL]"
echo "=========================================="
echo ""
echo "  🌐 http://localhost:2026"
echo ""
echo "  Routing: Frontend -> Nginx -> Gateway"
echo "  API:     /api/langgraph/*  ->  Gateway agent runtime"
echo "           /api/*              ->  Gateway REST API (8001)"
echo ""
echo "  📋 Logs: logs/{gateway,frontend,nginx}.log"
echo ""

if $DAEMON_MODE; then
    echo "  🛑 Stop: make stop"
    # Detach - trap is no longer needed
    trap - INT TERM
else
    echo "  Press Ctrl+C to stop all services"
    wait
fi
```

## 2. scripts/deploy.sh（Docker prod 启动器）

Docker 生产部署启动器。`detect_sandbox_mode()` 从 config.yaml 探测 local / aio / provisioner 三种沙箱模式；aio 模式自动追加 `docker-compose.dood.yaml` overlay 挂 docker.sock。自动生成 `BETTER_AUTH_SECRET` + `HELIX_INTERNAL_AUTH_TOKEN` 持久化到 `HELIX_HOME`，让 auth session / 内部认证 token 跨容器重启存活。`UV_EXTRAS` 从 config.yaml 自动探测，转成 build-arg 透传给 Dockerfile。

```bash
#!/usr/bin/env bash
#
# deploy.sh - Build, start, or stop production services
#
# Commands:
#   deploy.sh                    - build + start
#   deploy.sh build              - build all images (mode-agnostic)
#   deploy.sh start              - start from pre-built images
#   deploy.sh down               - stop and remove containers
#
# Sandbox mode (local / aio / provisioner) is auto-detected from config.yaml.
#
# Examples:
#   deploy.sh                    # build + start
#   deploy.sh build              # build all images
#   deploy.sh start              # start pre-built images
#   deploy.sh down               # stop and remove containers
#
# Must be run from the repo root directory.

set -e

case "${1:-}" in
    build|start|down)
        CMD="$1"
        if [ -n "${2:-}" ]; then
            echo "Unknown argument: $2"
            echo "Usage: deploy.sh [build|start|down]"
            exit 1
        fi
        ;;
    "")
        CMD=""
        ;;
    *)
        echo "Unknown argument: $1"
        echo "Usage: deploy.sh [build|start|down]"
        exit 1
        ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/.env"
DOCKER_DIR="$REPO_ROOT/docker"
if [ -f "$ENV_FILE" ]; then
    COMPOSE_CMD=(docker compose --env-file "$ENV_FILE" -p helix -f "$DOCKER_DIR/docker-compose.yaml")
else
    COMPOSE_CMD=(docker compose -p helix -f "$DOCKER_DIR/docker-compose.yaml")
fi

load_uv_extras_from_dotenv() {
    local line=""
    local value=""

    [ -f "$ENV_FILE" ] || return 0
    [ -z "${UV_EXTRAS+x}" ] || return 0

    line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?UV_EXTRAS[[:space:]]*=' "$ENV_FILE" | tail -n 1 || true)"
    [ -n "$line" ] || return 0

    value="${line#*=}"
    value="${value%$'\r'}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\") value="${value#\'}"; value="${value%\'}" ;;
    esac
    export UV_EXTRAS="$value"
}

load_uv_extras_from_dotenv

# ── Colors ────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── HELIX_HOME ────────────────────────────────────────────────────────────────

if [ -z "$HELIX_HOME" ]; then
    export HELIX_HOME="$REPO_ROOT/backend/.helix"
fi
echo -e "${BLUE}HELIX_HOME=$HELIX_HOME${NC}"
mkdir -p "$HELIX_HOME"

# ── HELIX_REPO_ROOT (for skills host path in DooD) ───────────────────────────

export HELIX_REPO_ROOT="$REPO_ROOT"

# ── config.yaml ───────────────────────────────────────────────────────────────

if [ -z "$HELIX_CONFIG_PATH" ]; then
    export HELIX_CONFIG_PATH="$REPO_ROOT/config.yaml"
fi

if  [ "$CMD" != "down" ] && [ ! -f "$HELIX_CONFIG_PATH" ]; then
    # Try to seed from repo (config.example.yaml is the canonical template)
    if [ -f "$REPO_ROOT/config.example.yaml" ]; then
        cp "$REPO_ROOT/config.example.yaml" "$HELIX_CONFIG_PATH"
        echo -e "${GREEN}✓ Seeded config.example.yaml -> $HELIX_CONFIG_PATH${NC}"
        echo -e "${YELLOW}⚠ config.yaml was seeded from the example template.${NC}"
        echo "  Run 'make setup' to generate a minimal config, or edit $HELIX_CONFIG_PATH manually before use."
    else
        echo -e "${RED}✗ No config.yaml found.${NC}"
        echo "  Run 'make setup' from the repo root (recommended),"
        echo "  or 'make config' for the full template, then set the required model API keys."
        exit 1
    fi
else
    echo -e "${GREEN}✓ config.yaml: $HELIX_CONFIG_PATH${NC}"
fi

# ── extensions_config.json ───────────────────────────────────────────────────

if [ -z "$HELIX_EXTENSIONS_CONFIG_PATH" ]; then
    export HELIX_EXTENSIONS_CONFIG_PATH="$REPO_ROOT/extensions_config.json"
fi

if [ ! -f "$HELIX_EXTENSIONS_CONFIG_PATH" ]; then
    if [ -f "$REPO_ROOT/extensions_config.json" ]; then
        cp "$REPO_ROOT/extensions_config.json" "$HELIX_EXTENSIONS_CONFIG_PATH"
        echo -e "${GREEN}✓ Seeded extensions_config.json -> $HELIX_EXTENSIONS_CONFIG_PATH${NC}"
    else
        # Create a minimal empty config so the gateway doesn't fail on startup
        echo '{"mcpServers":{},"skills":{}}' > "$HELIX_EXTENSIONS_CONFIG_PATH"
        echo -e "${YELLOW}⚠ extensions_config.json not found, created empty config at $HELIX_EXTENSIONS_CONFIG_PATH${NC}"
    fi
else
    echo -e "${GREEN}✓ extensions_config.json: $HELIX_EXTENSIONS_CONFIG_PATH${NC}"
fi


# ── BETTER_AUTH_SECRET ───────────────────────────────────────────────────────
# Required by Next.js in production. Generated once and persisted so auth
# sessions survive container restarts.

_secret_file="$HELIX_HOME/.better-auth-secret"
if [ -z "$BETTER_AUTH_SECRET" ]; then
    if [ -f "$_secret_file" ]; then
        export BETTER_AUTH_SECRET
        BETTER_AUTH_SECRET="$(cat "$_secret_file")"
        echo -e "${GREEN}✓ BETTER_AUTH_SECRET loaded from $_secret_file${NC}"
    else
        export BETTER_AUTH_SECRET
        if command -v python3 > /dev/null 2>&1 && \
            BETTER_AUTH_SECRET="$(python3 -c 'import sys; sys.version_info >= (3, 6) or sys.exit(1); import secrets; print(secrets.token_hex(32))' 2>/dev/null)"; then
            true
        elif command -v python > /dev/null 2>&1 && \
            BETTER_AUTH_SECRET="$(python -c 'import sys; sys.version_info >= (3, 6) or sys.exit(1); import secrets; print(secrets.token_hex(32))' 2>/dev/null)"; then
            true
        elif command -v openssl > /dev/null 2>&1 && \
            BETTER_AUTH_SECRET="$(openssl rand -hex 32)"; then
            true
        else
            echo -e "${RED}✗ Cannot generate BETTER_AUTH_SECRET: python3, python, and openssl are all unavailable.${NC}" >&2
            echo -e "${RED}  Set BETTER_AUTH_SECRET manually before running make up.${NC}" >&2
            exit 1
        fi
        echo "$BETTER_AUTH_SECRET" > "$_secret_file"
        chmod 600 "$_secret_file"
        echo -e "${GREEN}✓ BETTER_AUTH_SECRET generated -> $_secret_file${NC}"
    fi
fi

# ── HELIX_INTERNAL_AUTH_TOKEN ────────────────────────────────────────────────
# Shared by all Gateway workers so channel workers can call internal Gateway
# APIs even when the request is handled by a different Uvicorn worker.

_internal_auth_token_file="$HELIX_HOME/.internal-auth-token"
if  [ "$CMD" != "down" ] && [ -z "$HELIX_INTERNAL_AUTH_TOKEN" ]; then
    if [ -f "$_internal_auth_token_file" ]; then
        export HELIX_INTERNAL_AUTH_TOKEN
        HELIX_INTERNAL_AUTH_TOKEN="$(cat "$_internal_auth_token_file")"
        echo -e "${GREEN}✓ HELIX_INTERNAL_AUTH_TOKEN loaded from $_internal_auth_token_file${NC}"
    else
        export HELIX_INTERNAL_AUTH_TOKEN
        if command -v python3 > /dev/null 2>&1 && \
            HELIX_INTERNAL_AUTH_TOKEN="$(python3 -c 'import sys; sys.version_info >= (3, 6) or sys.exit(1); import secrets; print(secrets.token_urlsafe(32))' 2>/dev/null)"; then
            true
        elif command -v python > /dev/null 2>&1 && \
            HELIX_INTERNAL_AUTH_TOKEN="$(python -c 'import sys; sys.version_info >= (3, 6) or sys.exit(1); import secrets; print(secrets.token_urlsafe(32))' 2>/dev/null)"; then
            true
        elif command -v openssl > /dev/null 2>&1 && \
            HELIX_INTERNAL_AUTH_TOKEN="$(openssl rand -hex 32)"; then
            true
        else
            echo -e "${RED}✗ Cannot generate HELIX_INTERNAL_AUTH_TOKEN: python3, python, and openssl are all unavailable.${NC}" >&2
            echo -e "${RED}  Set HELIX_INTERNAL_AUTH_TOKEN manually before running make up.${NC}" >&2
            exit 1
        fi
        echo "$HELIX_INTERNAL_AUTH_TOKEN" > "$_internal_auth_token_file"
        chmod 600 "$_internal_auth_token_file"
        echo -e "${GREEN}✓ HELIX_INTERNAL_AUTH_TOKEN generated -> $_internal_auth_token_file${NC}"
    fi
fi

# ── UV_EXTRAS auto-detection ─────────────────────────────────────────────────
# The production Dockerfile accepts UV_EXTRAS as a single build-arg token and
# adds the --extra prefix itself. Convert the detector's uv flag string
# ("--extra postgres --extra discord") to a comma-joined name token.

if [ "$CMD" != "down" ] && [ -z "$UV_EXTRAS" ]; then
    _detect_python=""
    for _python in python3 python; do
        if command -v "$_python" >/dev/null 2>&1 && \
            "$_python" -c 'import sys; sys.version_info >= (3, 6) or sys.exit(1)' >/dev/null 2>&1; then
            _detect_python="$_python"
            break
        fi
    done
fi

if [ "$CMD" != "down" ] && [ -z "$UV_EXTRAS" ] && [ -n "$_detect_python" ]; then
    _uv_extras_flags="$("$_detect_python" "$REPO_ROOT/scripts/detect_uv_extras.py" 2>/dev/null || true)"
    _uv_extras=""
    set -- $_uv_extras_flags
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--extra" ] && [ "$#" -gt 1 ]; then
            if [ -z "$_uv_extras" ]; then
                _uv_extras="$2"
            else
                _uv_extras="$_uv_extras,$2"
            fi
            shift 2
        else
            shift
        fi
    done
    if [ -n "$_uv_extras" ]; then
        export UV_EXTRAS="$_uv_extras"
        echo -e "${GREEN}✓ Auto-detected UV_EXTRAS=${UV_EXTRAS} from config.yaml${NC}"
    fi
fi

# ── detect_sandbox_mode ───────────────────────────────────────────────────────

detect_sandbox_mode() {
    local sandbox_use=""
    local provisioner_url=""

    [ -f "$HELIX_CONFIG_PATH" ] || { echo "local"; return; }

    sandbox_use=$(awk '
        /^[[:space:]]*sandbox:[[:space:]]*$/ { in_sandbox=1; next }
        in_sandbox && /^[^[:space:]#]/ { in_sandbox=0 }
        in_sandbox && /^[[:space:]]*use:[[:space:]]*/ {
            line=$0; sub(/^[[:space:]]*use:[[:space:]]*/, "", line); print line; exit
        }
    ' "$HELIX_CONFIG_PATH")

    provisioner_url=$(awk '
        /^[[:space:]]*sandbox:[[:space:]]*$/ { in_sandbox=1; next }
        in_sandbox && /^[^[:space:]#]/ { in_sandbox=0 }
        in_sandbox && /^[[:space:]]*provisioner_url:[[:space:]]*/ {
            line=$0; sub(/^[[:space:]]*provisioner_url:[[:space:]]*/, "", line); print line; exit
        }
    ' "$HELIX_CONFIG_PATH")

    if [[ "$sandbox_use" == *"helix.community.aio_sandbox:AioSandboxProvider"* ]]; then
        if [ -n "$provisioner_url" ]; then
            echo "provisioner"
        else
            echo "aio"
        fi
    else
        echo "local"
    fi
}

# ── down ──────────────────────────────────────────────────────────────────────

if [ "$CMD" = "down" ]; then
    # Set minimal env var defaults so docker compose can parse the file without
    # warning about unset variables that appear in volume specs.
    export HELIX_HOME="${HELIX_HOME:-$REPO_ROOT/backend/.helix}"
    export HELIX_CONFIG_PATH="${HELIX_CONFIG_PATH:-$HELIX_HOME/config.yaml}"
    export HELIX_EXTENSIONS_CONFIG_PATH="${HELIX_EXTENSIONS_CONFIG_PATH:-$HELIX_HOME/extensions_config.json}"
    export HELIX_REPO_ROOT="${HELIX_REPO_ROOT:-$REPO_ROOT}"
    export BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-placeholder}"
    export HELIX_INTERNAL_AUTH_TOKEN="${HELIX_INTERNAL_AUTH_TOKEN:-placeholder}"
    "${COMPOSE_CMD[@]}" down
    exit 0
fi

# ── build ────────────────────────────────────────────────────────────────────
# Build produces mode-agnostic images. No sandbox detection needed.

if [ "$CMD" = "build" ]; then
    echo "=========================================="
    echo "  Helix - Building Images"
    echo "=========================================="
    echo ""

    "${COMPOSE_CMD[@]}" build

    echo ""
    echo "=========================================="
    echo "  ✓ Images built successfully"
    echo "=========================================="
    echo ""
    echo "  Next: deploy.sh start"
    echo ""
    exit 0
fi

# ── Banner ────────────────────────────────────────────────────────────────────

echo "=========================================="
echo "  Helix Production Deployment"
echo "=========================================="
echo ""

# ── Detect runtime configuration ────────────────────────────────────────────
# Only needed for start / up - determines whether provisioner is launched.

sandbox_mode="$(detect_sandbox_mode)"
echo -e "${BLUE}Sandbox mode: $sandbox_mode${NC}"

echo -e "${BLUE}Runtime: Gateway embedded agent runtime${NC}"

services="redis frontend gateway nginx"

if [ "$sandbox_mode" = "provisioner" ]; then
    services="$services provisioner"
fi

# ── HELIX_DOCKER_SOCKET (aio / pure-DooD mode only) ──────────────────────────
# Only aio mode (AioSandboxProvider without provisioner_url) needs the host
# Docker socket. It is mounted via the opt-in docker-compose.dood.yaml overlay,
# appended here, so the default (local) and provisioner modes never expose the
# host daemon. Mounting the socket = root-equivalent host control; see SECURITY.md.

if [ -z "$HELIX_DOCKER_SOCKET" ]; then
    export HELIX_DOCKER_SOCKET="/var/run/docker.sock"
fi

if [ "$sandbox_mode" = "aio" ]; then
    if [ ! -S "$HELIX_DOCKER_SOCKET" ]; then
        echo -e "${RED}⚠ Docker socket not found at $HELIX_DOCKER_SOCKET${NC}"
        echo "  AioSandboxProvider (DooD) will not work."
        exit 1
    fi
    echo -e "${GREEN}✓ Docker socket: $HELIX_DOCKER_SOCKET${NC}"
    echo -e "${YELLOW}  Mounting host Docker socket into gateway (DooD = host root-equivalent). See SECURITY.md.${NC}"
    COMPOSE_CMD+=(-f "$DOCKER_DIR/docker-compose.dood.yaml")
fi

echo ""

# ── Start / Up ───────────────────────────────────────────────────────────────

if [ "$CMD" = "start" ]; then
    echo "Starting containers (no rebuild)..."
    echo ""
    # shellcheck disable=SC2086
    "${COMPOSE_CMD[@]}" up -d --remove-orphans $services
else
    # Default: build + start
    echo "Building images and starting containers..."
    echo ""
    # shellcheck disable=SC2086
    "${COMPOSE_CMD[@]}" up --build -d --remove-orphans $services
fi

echo ""
echo "=========================================="
echo "  Helix is running!"
echo "=========================================="
echo ""
echo "  🌐 Application: http://localhost:${PORT:-2026}"
echo "  📡 API Gateway: http://localhost:${PORT:-2026}/api/*"
echo "  🤖 Runtime:     Gateway embedded"
echo "  API:            /api/langgraph/* -> Gateway"
echo ""
echo "  Manage:"
echo "    make down        - stop and remove containers"
echo "    make docker-logs - view logs"
echo ""
```

## 3. docker/dev-entrypoint.sh（Docker dev 容器内入口）

Docker dev 容器内入口脚本。从 `docker-compose-dev.yaml` 的 inline `command:` 提取（保持可 lint）。职责：(1) 从 `UV_EXTRAS` 解析 `--extra X` flags 并校验；(2) `uv sync --all-packages` 传播 extras 到 workspace 成员；(3) 自愈：首次 sync 失败重建 `.venv` 重试；(4) `exec uvicorn` 替换 shell 成为 PID 1。锚定 `/bin/sh`（非 bash）因 alpine 基镜像可能无 bash。

```sh
#!/usr/bin/env sh
#
# Gateway dev entrypoint - runs inside the docker-compose-dev gateway
# container. Extracted from docker/docker-compose-dev.yaml's inline `command:`.
#
# Responsibilities:
#   1. Resolve `--extra X` flags from UV_EXTRAS (comma- or whitespace-separated,
#      mirroring scripts/detect_uv_extras.py for parity with local `make dev`).
#   2. Validate each extra against [A-Za-z][A-Za-z0-9_-]* so a stray shell
#      metacharacter in `.env` cannot reach `uv sync`.
#   3. `uv sync --all-packages` so workspace member extras (the framework
#      package's postgres extra in particular) are installed.
#   4. Self-heal: if the first sync fails, recreate .venv and retry once.
#   5. Hand off to uvicorn with reload, replacing this shell so uvicorn becomes
#      PID 1 inside the container.
#
# Anchored at /bin/sh (not bash) since alpine-based base images may not ship
# bash. Uses POSIX-only constructs throughout.

set -e

# `--print-extras` is a dry-run hook: parse + validate UV_EXTRAS, print the
# resulting `--extra X` flags to stdout, and exit. Used by the unit test and
# useful for ad-hoc debugging.
PRINT_EXTRAS_ONLY=0
if [ "${1:-}" = "--print-extras" ]; then
    PRINT_EXTRAS_ONLY=1
fi

# Mirror the legacy command's behavior: redirect both stdout and stderr to the
# host-mounted log file (../logs/gateway.log -> /app/logs/gateway.log). Skip
# the redirect under --print-extras so the test runner can capture stdout.
if [ "$PRINT_EXTRAS_ONLY" = "0" ]; then
    exec >/app/logs/gateway.log 2>&1
fi

# ── Resolve extras ──────────────────────────────────────────────────────────

EXTRAS_FLAGS=""
if [ -n "${UV_EXTRAS:-}" ]; then
    # Normalize comma -> space, then split on whitespace via the unquoted `for`.
    for raw in $(printf '%s' "$UV_EXTRAS" | tr ',' ' '); do
        [ -z "$raw" ] && continue
        # Reject anything that does not look like an identifier.
        # Two patterns: leading non-letter, or any non-[A-Za-z0-9_-] character.
        case "$raw" in
            [!A-Za-z]* | *[!A-Za-z0-9_-]*)
                echo "[startup] UV_EXTRAS entry '$raw' is invalid (must match [A-Za-z][A-Za-z0-9_-]*) - aborting" >&2
                exit 1
                ;;
        esac
        EXTRAS_FLAGS="$EXTRAS_FLAGS --extra $raw"
    done
fi

if [ "$PRINT_EXTRAS_ONLY" = "1" ]; then
    # Trim leading space for tidier output, then exit.
    printf '%s\n' "${EXTRAS_FLAGS# }"
    exit 0
fi

if [ -n "$EXTRAS_FLAGS" ]; then
    echo "[startup] uv extras:$EXTRAS_FLAGS"
fi

# Keep runtime-owned files out of uvicorn's reload watcher. Each excluded path
# must exist before uvicorn starts so watchfiles treats it as an excluded
# directory, not as a plain glob pattern - on Python 3.12, globbing an absolute
# pattern raises NotImplementedError and crashes startup. That
# means `sandbox` must be created here too, not just `.helix`.
: "${HELIX_HOME:=/app/backend/.helix}"
export HELIX_HOME
mkdir -p "$HELIX_HOME" /app/backend/.helix /app/backend/sandbox

# ── Sync dependencies (with self-heal) ──────────────────────────────────────

cd /app/backend

# `--all-packages` propagates extras into workspace members.
# `--extra redis` is always installed because docker-compose-dev defaults the
# stream bridge to Redis (HELIX_STREAM_BRIDGE_REDIS_URL); redis is an
# optional extra elsewhere. It is kept out of EXTRAS_FLAGS so the --print-extras
# contract (UV_EXTRAS-derived flags only) stays unchanged.
# `$EXTRAS_FLAGS` intentionally unquoted so each `--extra X` becomes its own arg.
# shellcheck disable=SC2086 # word-splitting is intentional here
if ! uv sync --all-packages --extra redis $EXTRAS_FLAGS; then
    echo "[startup] uv sync failed; recreating .venv and retrying once"
    uv venv --allow-existing .venv
    # shellcheck disable=SC2086
    uv sync --all-packages --extra redis $EXTRAS_FLAGS
fi

# ── Hand off to uvicorn ─────────────────────────────────────────────────────

PYTHONPATH=. exec uv run uvicorn gateway.gateway.app:app \
    --host 0.0.0.0 --port 8001 \
    --reload \
    --reload-include='*.yaml' \
    --reload-include='.env' \
    --reload-exclude=/app/backend/sandbox \
    --reload-exclude="$HELIX_HOME" \
    --reload-exclude=/app/backend/.helix
```
