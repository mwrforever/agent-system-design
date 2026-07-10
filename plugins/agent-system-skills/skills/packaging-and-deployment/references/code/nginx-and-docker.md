# 完整源码：nginx 反代 + Docker 编排 + Dockerfile + provisioner

> 本文件给出网络层与容器编排层的**完整真实配置**：`nginx.conf`（Docker path-based 反代）、`nginx.local.conf`（本地 dev 变体差异）、`docker-compose.yaml`（prod）、`docker-compose-dev.yaml`（dev）、两个 opt-in overlay（DooD / CLI auth）、`backend/Dockerfile`（多阶段构建）、`docker/provisioner/app.py`（K8s 沙箱 provisioner）。
>
> 真实实现已按匿名化规则映射到中立结构（env 前缀 `HELIX_*`、容器/网络名 `helix-*`、uvicorn 入口 `gateway.gateway.app:app`、运行时数据目录 `.helix`），去除一切项目字样。原代码注释保留以保真。

## 1. docker/nginx/nginx.conf（Docker 反代，唯一对外出口）

path-based routing，唯一对外端口 2026。`/api/langgraph/*` rewrite 成 `/api/*` 转 Gateway 的 LangGraph 兼容端点；其余 `/api/*` 直转 Gateway；`/` 转 Next.js。SSE 三件套（`proxy_buffering off` + `X-Accel-Buffering: no` + `proxy_read_timeout 600s`）。`set $gateway_upstream gateway:8001` 用变量 + DNS resolver（`resolver 127.0.0.11 valid=10s`）让容器重启换 IP 不挂。`map $http_x_forwarded_proto $forwarded_proto` 保留外层 TLS 反代的真实 scheme（防 HTTPS 流量被当 HTTP 拒登录 POST）。上传 location `client_max_body_size 100M; proxy_request_buffering off`。provisioner location 用变量解析（容器未跑时 nginx 也能启动）。

```nginx
# docker/nginx/nginx.conf
events {
    worker_connections 1024;
}
pid /tmp/nginx.pid;
http {
    # Basic settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Logging
    access_log /dev/stdout;
    error_log /dev/stderr;

    # Docker internal DNS (for resolving k3s hostname)
    resolver 127.0.0.11 valid=10s ipv6=off;

    # Preserve an upstream proxy's X-Forwarded-Proto so the Gateway sees the real
    # client scheme when the framework's nginx runs BEHIND another TLS-terminating
    # reverse proxy (e.g. Pangolin/Traefik, Cloudflare, Caddy). Without this the
    # Gateway treats HTTPS browser traffic as HTTP and rejects the login POST with
    # 403 "Cross-site auth request denied" (Origin scheme mismatch), and also drops
    # the Secure flag / max-age on session cookies. Falls back to $scheme when nginx
    # is itself the TLS edge (standalone `make dev` / Docker), so default
    # deployments are unchanged.
    map $http_x_forwarded_proto $forwarded_proto {
        default    $scheme;
        "~*^https" https;
    }

    # ── Main server (path-based routing) ─────────────────────────────────
    server {
        listen 2026 default_server;
        listen [::]:2026 default_server;
        server_name _;

        # Resolve Docker service names at request time to avoid stale upstream
        # IPs when containers restart and receive new addresses.
        set $gateway_upstream gateway:8001;
        set $frontend_upstream frontend:3000;

        # Default proxy settings for all locations (streaming/SSE support)
        proxy_buffering off;
        proxy_cache off;

        # Keep the unified nginx endpoint same-origin by default. When split
        # frontend/backend or port-forwarded deployments need browser CORS,
        # configure the Gateway allowlist with GATEWAY_CORS_ORIGINS so CORS and
        # CSRF origin checks stay aligned instead of approving every origin at
        # the proxy layer.

        # LangGraph-compatible API routes served by Gateway.
        # Rewrites /api/langgraph/* to /api/* before proxying to Gateway.
        location /api/langgraph/ {
            rewrite ^/api/langgraph/(.*) /api/$1 break;
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;

            # Headers
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;
            proxy_set_header Connection '';

            # SSE/Streaming support
            proxy_set_header X-Accel-Buffering no;

            # Timeouts for long-running requests
            proxy_connect_timeout 600s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;

            # Chunked transfer encoding
            chunked_transfer_encoding on;
        }

        # Custom API: Models endpoint
        location /api/models {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # Custom API: Memory endpoint
        location /api/memory {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # Custom API: MCP configuration endpoint
        location /api/mcp {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # Custom API: Skills configuration endpoint
        location /api/skills {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # Custom API: Agents endpoint
        location /api/agents {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # Custom API: Uploads endpoint
        location ~ ^/api/threads/[^/]+/uploads {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

            # Large file upload support
            client_max_body_size 100M;
            proxy_request_buffering off;

            # Disable response buffering to avoid permission errors
        }

        # Custom API: Other endpoints under /api/threads
        location ~ ^/api/threads {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # API Documentation: Swagger UI
        location /docs {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # API Documentation: ReDoc
        location /redoc {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # API Documentation: OpenAPI Schema
        location /openapi.json {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # Health check endpoint (gateway)
        location /health {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # ── Provisioner API (sandbox management) ────────────────────────
        # Use a variable so nginx resolves provisioner at request time (not startup).
        # This allows nginx to start even when provisioner container is not running.
        location /api/sandboxes {
            set $provisioner_upstream provisioner:8002;
            proxy_pass http://$provisioner_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

        }

        # Catch-all for /api/ routes not covered above (e.g. /api/v1/auth/*).
        # More specific prefix and regex locations above still take precedence.
        location /api/ {
            proxy_pass http://$gateway_upstream;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;

            # Disable buffering to avoid permission errors when nginx
            # runs as a non-root user (e.g. local development).
        }

        # All other requests go to frontend
        location / {
            proxy_pass http://$frontend_upstream;
            proxy_http_version 1.1;

            # Headers
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $forwarded_proto;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_cache_bypass $http_upgrade;

            # Timeouts
            proxy_connect_timeout 600s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;
        }
    }
}
```

## 2. docker/nginx/nginx.local.conf（本地 dev 变体差异）

本地 `make dev` 用这份（`serve.sh` 里 `nginx -c nginx.local.conf`）。与 Docker 版的核心差异：(a) 用 `upstream gateway { server 127.0.0.1:8001; }` 静态上游（本地无容器 DNS 解析需求）；(b) 每个 location 都加 `proxy_buffering off; proxy_cache off;`，因本地 nginx 以非 root 跑，默认 `proxy_temp_path` 指向系统目录会 `Permission denied` 导致 `ERR_INCOMPLETE_CHUNKED_ENCODING` / `ChunkLoadError`；(c) 无 `map $http_x_forwarded_proto`（本地无外层 TLS 反代，直接用 `$scheme`）；(d) `/api/docs` 与 `/api/redoc` 加 `/api` 前缀（本地前端代理需要）。下面只列差异块，其余 location 与 Docker 版一致。

```nginx
# docker/nginx/nginx.local.conf（差异块）
error_log logs/nginx-error.log warn;
events {
    worker_connections 1024;
}
pid logs/nginx.pid;
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    access_log logs/nginx-access.log;
    error_log logs/nginx-error.log;

    # Upstream servers (using 127.0.0.1 for local development)
    upstream gateway {
        server 127.0.0.1:8001;
    }
    upstream frontend {
        server 127.0.0.1:3000;
    }

    server {
        listen 2026;
        listen [::]:2026;
        server_name _;

        # 每个 location 都带 proxy_buffering off; proxy_cache off;
        # （非 root 本地 dev 避免 proxy_temp_path 权限错误）
        location /api/langgraph/ {
            rewrite ^/api/langgraph/(.*) /api/$1 break;
            proxy_pass http://gateway;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Connection '';
            proxy_buffering off;
            proxy_cache off;
            proxy_set_header X-Accel-Buffering no;
            proxy_connect_timeout 600s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;
            chunked_transfer_encoding on;
        }

        # ... 其余 /api/* location 结构相同，均带 proxy_buffering off; proxy_cache off;
        # 上传 location 额外带 client_max_body_size 100M; proxy_request_buffering off;

        # /api/ catch-all 额外带 proxy_pass_header Set-Cookie（auth cookie 透传）
        location /api/ {
            proxy_pass http://gateway;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_pass_header Set-Cookie;
            proxy_buffering off;
            proxy_cache off;
        }

        # 前端 location：proxy_buffering off + proxy_request_buffering off
        # 避免 Next.js 静态 chunk 走 proxy_temp_path 权限错误
        location / {
            proxy_pass http://frontend;
            proxy_http_version 1.1;
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection 'upgrade';
            proxy_cache_bypass $http_upgrade;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_connect_timeout 600s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;
        }
    }
}
```

## 3. docker/docker-compose.yaml（prod）

生产编排。redis stream bridge（healthcheck）-> nginx -> frontend（多阶段 `target: prod`）-> gateway（`--workers ${GATEWAY_WORKERS:-1}`）-> provisioner（可选）。Gateway 卷挂 config.yaml / extensions_config.json / skills 只读，挂 `HELIX_HOME` 可写。网络 `helix` 内部互联，外部仅暴露 `${PORT:-2026}` 一个端口。

```yaml
# docker/docker-compose.yaml
# Usage: make up
#
# Services:
#   - nginx:       Reverse proxy (port 2026, configurable via PORT env var)
#   - frontend:    Next.js production server
#   - gateway:     FastAPI Gateway API + agent runtime
#   - redis:       Redis Streams backend for cross-worker SSE stream bridge
#   - provisioner: (optional) Sandbox provisioner for Kubernetes mode
#
# Key environment variables (set via environment/.env or scripts/deploy.sh):
#   HELIX_PROJECT_ROOT           - project root for relative runtime paths
#   HELIX_HOME                   - runtime data dir, default .helix under $HELIX_PROJECT_ROOT (or cwd)
#   HELIX_CONFIG_PATH            - path to config.yaml
#   HELIX_EXTENSIONS_CONFIG_PATH - path to extensions_config.json
#   HELIX_SKILLS_PATH            - skills dir, default $HELIX_PROJECT_ROOT/skills
#   HELIX_DOCKER_SOCKET          - Docker socket path for aio/DooD mode, default /var/run/docker.sock (used only by the opt-in docker-compose.dood.yaml overlay)
#   HELIX_REPO_ROOT              - repo root (used for skills host path in DooD)
#   BETTER_AUTH_SECRET           - required for frontend auth/session security
#   HELIX_INTERNAL_AUTH_TOKEN    - shared internal Gateway auth token for multi-worker IM channels
#
# LangSmith tracing is disabled by default (LANGSMITH_TRACING=false).
# Set LANGSMITH_TRACING=true and LANGSMITH_API_KEY in .env to enable it.
#
# Access: http://localhost:${PORT:-2026}

services:
  # ── Redis Stream Bridge ────────────────────────────────────────────────────
  redis:
    image: redis:7-alpine
    container_name: helix-redis
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks:
      - helix
    restart: unless-stopped

  # ── Reverse Proxy ──────────────────────────────────────────────────────────
  nginx:
    image: nginx:alpine
    container_name: helix-nginx
    ports:
      - "${PORT:-2026}:2026"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf.template:ro
    command: >
      sh -c "cp /etc/nginx/nginx.conf.template /etc/nginx/nginx.conf
      && nginx -g 'daemon off;'"
    depends_on:
      - frontend
      - gateway
    networks:
      - helix
    restart: unless-stopped

  # ── Frontend: Next.js Production ───────────────────────────────────────────
  frontend:
    build:
      context: ../
      dockerfile: frontend/Dockerfile
      target: prod
      args:
        PNPM_STORE_PATH: ${PNPM_STORE_PATH:-/root/.local/share/pnpm/store}
        NPM_REGISTRY: ${NPM_REGISTRY:-}
    container_name: helix-frontend
    environment:
      - BETTER_AUTH_SECRET=${BETTER_AUTH_SECRET}
      - HELIX_INTERNAL_GATEWAY_BASE_URL=http://gateway:8001
    env_file:
      - ../frontend/.env
    networks:
      - helix
    restart: unless-stopped

  # ── Gateway API ────────────────────────────────────────────────────────────
  gateway:
    build:
      context: ../
      dockerfile: backend/Dockerfile
      args:
        APT_MIRROR: ${APT_MIRROR:-}
        UV_IMAGE: ${UV_IMAGE:-ghcr.io/astral-sh/uv:0.7.20}
        UV_INDEX_URL: ${UV_INDEX_URL:-https://pypi.org/simple}
        UV_EXTRAS: ${UV_EXTRAS:-}
    container_name: helix-gateway
    # Gateway hosts the agent runtime with in-process RunManager + StreamBridge
    # singletons -- run state lives in this worker's memory. Default to a single
    # worker: the Redis stream bridge solves cross-worker SSE delivery and
    # reconnect, but run cancel, request dedup, and per-worker IM channel
    # services remain worker-local. Override GATEWAY_WORKERS only when the
    # Redis stream bridge is enabled and those limitations are acceptable.
    command: sh -c "cd backend && PYTHONPATH=. uv run uvicorn gateway.gateway.app:app --host 0.0.0.0 --port 8001 --workers ${GATEWAY_WORKERS:-1}"
    volumes:
      - ${HELIX_CONFIG_PATH}:/app/backend/config.yaml:ro
      - ${HELIX_EXTENSIONS_CONFIG_PATH}:/app/backend/extensions_config.json:ro
      - ../skills:/app/skills:ro
      - ${HELIX_HOME}:/app/backend/.helix
      # DooD: the host Docker socket is NOT mounted by default. It is added only
      # for aio (pure-DooD) sandbox mode via the opt-in docker-compose.dood.yaml
      # overlay (appended by scripts/deploy.sh).

      # CLI auth dirs (Claude Code / Codex) are NOT mounted by default: they
      # expose the entire ~/.claude and ~/.codex (history, projects, global
      # config, credentials) into the container. Mount them only when you use
      # the Claude/Codex CLI login as a model provider or ACP agent, via the
      # opt-in docker-compose.cli-auth.yaml overlay. Prefer an env token
      # (CLAUDE_CODE_OAUTH_TOKEN).

    working_dir: /app
    environment:
      - CI=true
      - HELIX_PROJECT_ROOT=/app
      - HELIX_HOME=/app/backend/.helix
      - HELIX_CONFIG_PATH=/app/backend/config.yaml
      - HELIX_EXTENSIONS_CONFIG_PATH=/app/backend/extensions_config.json
      - HELIX_STREAM_BRIDGE_REDIS_URL=${HELIX_STREAM_BRIDGE_REDIS_URL:-redis://redis:6379/0}
      - HELIX_CHANNELS_LANGGRAPH_URL=${HELIX_CHANNELS_LANGGRAPH_URL:-http://gateway:8001/api}
      - HELIX_CHANNELS_GATEWAY_URL=${HELIX_CHANNELS_GATEWAY_URL:-http://gateway:8001}
      - HELIX_INTERNAL_AUTH_TOKEN=${HELIX_INTERNAL_AUTH_TOKEN}
      # DooD path/network translation
      - HELIX_HOST_BASE_DIR=${HELIX_HOME}
      - HELIX_HOST_SKILLS_PATH=${HELIX_REPO_ROOT}/skills
      - HELIX_SANDBOX_HOST=host.docker.internal
      # Proxy values (HTTP_PROXY/HTTPS_PROXY/ALL_PROXY) are inherited from ../.env via env_file.
      # Only NO_PROXY is declared here so internal service hostnames are always exempt from the proxy.
      - NO_PROXY=${NO_PROXY:-}${NO_PROXY:+,}localhost,127.0.0.1,::1,gateway,frontend,nginx,provisioner,host.docker.internal
      - no_proxy=${no_proxy:-}${no_proxy:+,}localhost,127.0.0.1,::1,gateway,frontend,nginx,provisioner,host.docker.internal
    env_file:
      - ../.env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      redis:
        condition: service_healthy
    networks:
      - helix
    restart: unless-stopped

  # ── Sandbox Provisioner (optional, Kubernetes mode) ────────────────────────
  provisioner:
    build:
      context: ./provisioner
      dockerfile: Dockerfile
      args:
        APT_MIRROR: ${APT_MIRROR:-}
        PIP_INDEX_URL: ${PIP_INDEX_URL:-}
    container_name: helix-provisioner
    volumes:
      - ~/.kube/config:/root/.kube/config:ro
    environment:
      - K8S_NAMESPACE=helix
      - SANDBOX_IMAGE=enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:latest
      - SKILLS_HOST_PATH=${HELIX_REPO_ROOT}/skills
      - THREADS_HOST_PATH=${HELIX_HOME}/threads
      - HELIX_HOST_BASE_DIR=${HELIX_HOME}
      - KUBECONFIG_PATH=/root/.kube/config
      - NODE_HOST=host.docker.internal
      - K8S_API_SERVER=https://host.docker.internal:26443
    env_file:
      - ../.env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - helix
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8002/health"]
      interval: 10s
      timeout: 5s
      retries: 6
volumes:
  redis-data:

networks:
  helix:
    driver: bridge
```

## 4. docker/docker-compose-dev.yaml（dev）

开发编排。源码 bind mount（`../backend/:/app/backend/`）+ `gateway-venv` named volume 保护 `.venv` 不被 host 空目录覆盖 + `gateway-uv-cache` named volume（macOS/Docker Desktop 下 uv 在共享目录无法建符号链接）。frontend `pnpm dev` + `WATCHPACK_POLLING=true`。gateway 用 `dev-entrypoint.sh` 启动（UV_EXTRAS 解析 + `uv sync --all-packages` + uvicorn handoff）。

```yaml
# docker/docker-compose-dev.yaml
# Usage: docker-compose -f docker-compose-dev.yaml up --build
#
# Services:
#   - nginx: Reverse proxy (port 2026)
#   - frontend: Frontend Next.js dev server (port 3000)
#   - gateway: Backend Gateway API + agent runtime (port 8001)
#   - redis: Redis Streams backend for cross-worker SSE stream bridge
#   - provisioner (optional): Sandbox provisioner (creates Pods in host Kubernetes)
#
# Prerequisites:
#   - Kubernetes cluster + kubeconfig are only required when using provisioner mode.
#
# Access: http://localhost:2026

services:
  # ── Redis Stream Bridge ────────────────────────────────────────────────
  redis:
    image: redis:7-alpine
    container_name: helix-redis
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks:
      - helix-dev
    restart: unless-stopped

  # ── Sandbox Provisioner ────────────────────────────────────────────────
  # Manages per-sandbox Pod + Service lifecycle in the host Kubernetes
  # cluster via the K8s API.
  # Backend accesses sandboxes directly via host.docker.internal:{NodePort}.
  provisioner:
    build:
      context: ./provisioner
      dockerfile: Dockerfile
      args:
        APT_MIRROR: ${APT_MIRROR:-}
    container_name: helix-provisioner
    volumes:
      - ~/.kube/config:/root/.kube/config:ro
    environment:
      - K8S_NAMESPACE=helix
      - SANDBOX_IMAGE=enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:latest
      # Host paths for K8s HostPath volumes (must be absolute paths accessible by K8s node)
      # On Docker Desktop/OrbStack, use your actual host paths like /Users/username/...
      # Set these in your shell before running docker-compose:
      #   export HELIX_ROOT=/absolute/path/to/repo
      - SKILLS_HOST_PATH=${HELIX_ROOT}/skills
      - THREADS_HOST_PATH=${HELIX_ROOT}/backend/.helix/threads
      # Per-user data base directory for user-scoped skill mounts
      - HELIX_HOST_BASE_DIR=${HELIX_ROOT}/backend/.helix
      # Production: use PVC instead of hostPath to avoid data loss on node failure.
      # When set, hostPath vars above are ignored for the corresponding volume.
      # USERDATA_PVC_NAME uses subPath (helix/users/{user_id}/threads/{thread_id}/user-data) automatically.
      # - SKILLS_PVC_NAME=helix-skills-pvc
      # - USERDATA_PVC_NAME=helix-userdata-pvc
      - KUBECONFIG_PATH=/root/.kube/config
      - NODE_HOST=host.docker.internal
      # Override K8S API server URL since kubeconfig uses 127.0.0.1
      # which is unreachable from inside the container
      - K8S_API_SERVER=https://host.docker.internal:26443
    env_file:
      - ../.env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - helix-dev
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8002/health"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 15s

  # ── Reverse Proxy ──────────────────────────────────────────────────────
  # Routes API traffic to gateway and (optionally) provisioner.
  nginx:
    image: nginx:alpine
    container_name: helix-nginx
    ports:
      - "2026:2026"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf.template:ro
    command:
      - sh
      - -c
      - |
        set -e
        cp /etc/nginx/nginx.conf.template /etc/nginx/nginx.conf
        test -e /proc/net/if_inet6 || sed -i '/^[[:space:]]*listen[[:space:]]\+\[::\]:2026;/d' /etc/nginx/nginx.conf
        exec nginx -g 'daemon off;'
    depends_on:
      - frontend
      - gateway
    networks:
      - helix-dev
    restart: unless-stopped

  # Frontend - Next.js Development Server
  frontend:
    build:
      context: ../
      dockerfile: frontend/Dockerfile
      target: dev
      args:
        PNPM_STORE_PATH: ${PNPM_STORE_PATH:-/root/.local/share/pnpm/store}
        NPM_REGISTRY: ${NPM_REGISTRY:-}
    container_name: helix-frontend
    command: sh -c "cd frontend && pnpm run dev > /app/logs/frontend.log 2>&1"
    volumes:
      - ../frontend/src:/app/frontend/src
      - ../frontend/public:/app/frontend/public
      - ../frontend/next.config.js:/app/frontend/next.config.js:ro
      - ../logs:/app/logs
      # Mount pnpm store for caching
      - ${PNPM_STORE_PATH:-~/.local/share/pnpm/store}:/root/.local/share/pnpm/store
    working_dir: /app
    environment:
      - NODE_ENV=development
      - WATCHPACK_POLLING=true
      - CI=true
      - HELIX_INTERNAL_GATEWAY_BASE_URL=http://gateway:8001
    env_file:
      - ../frontend/.env
    networks:
      - helix-dev
    restart: unless-stopped

  # Backend - Gateway API
  gateway:
    build:
      context: ../
      dockerfile: backend/Dockerfile
      target: dev
      args:
        APT_MIRROR: ${APT_MIRROR:-}
        UV_IMAGE: ${UV_IMAGE:-ghcr.io/astral-sh/uv:0.7.20}
        UV_INDEX_URL: ${UV_INDEX_URL:-https://pypi.org/simple}
    container_name: helix-gateway
    # Startup logic lives in docker/dev-entrypoint.sh - UV_EXTRAS validation,
    # `uv sync --all-packages`, .venv self-heal, and uvicorn handoff. Keeps
    # this file readable and lets the script be linted (shellcheck-clean).
    command: ["sh", "/usr/local/bin/dev-entrypoint.sh"]
    volumes:
      # Mount the dev entrypoint as a read-only file so edits to the script
      # take effect on `make docker-restart` without requiring an image rebuild.
      - ./dev-entrypoint.sh:/usr/local/bin/dev-entrypoint.sh:ro
      - ../backend/:/app/backend/
      # Preserve the .venv built during Docker image build - mounting the full backend/
      # directory above would otherwise shadow it with the (empty) host directory.
      - gateway-venv:/app/backend/.venv
      # Mount the project directory instead of its mutable config files individually.
      # Host editors commonly replace files on save; a directory bind keeps those
      # replacements visible inside Docker Desktop/WSL containers.
      - ../:/app/project
      - ../skills:/app/skills
      - ../logs:/app/logs
      # Use a Docker-managed uv cache volume instead of a host bind mount.
      # On macOS/Docker Desktop, uv may fail to create symlinks inside shared
      # host directories, which causes startup-time `uv sync` to crash.
      - gateway-uv-cache:/root/.cache/uv
      # DooD: the host Docker socket is NOT mounted by default. It is added only
      # for aio (pure-DooD) sandbox mode via the opt-in docker-compose.dood.yaml
      # overlay (appended by scripts/docker.sh).

      # CLI auth dirs (Claude Code / Codex) are NOT mounted by default: they
      # expose the entire ~/.claude and ~/.codex (history, projects, global
      # config, credentials) into the container. Mount them only when you use
      # the Claude/Codex CLI login as a model provider or ACP agent, via the
      # opt-in docker-compose.cli-auth.yaml overlay. Prefer an env token
      # (CLAUDE_CODE_OAUTH_TOKEN).
    working_dir: /app
    environment:
      - CI=true
      - HELIX_PROJECT_ROOT=/app
      - HELIX_HOME=/app/backend/.helix
      - HELIX_CONFIG_PATH=/app/project/config.yaml
      - HELIX_EXTENSIONS_CONFIG_PATH=/app/project/extensions_config.json
      - HELIX_STREAM_BRIDGE_REDIS_URL=${HELIX_STREAM_BRIDGE_REDIS_URL:-redis://redis:6379/0}
      - HELIX_CHANNELS_LANGGRAPH_URL=${HELIX_CHANNELS_LANGGRAPH_URL:-http://gateway:8001/api}
      - HELIX_CHANNELS_GATEWAY_URL=${HELIX_CHANNELS_GATEWAY_URL:-http://gateway:8001}
      - HELIX_INTERNAL_AUTH_TOKEN=${HELIX_INTERNAL_AUTH_TOKEN:-}
      - HELIX_HOST_BASE_DIR=${HELIX_ROOT}/backend/.helix
      - HELIX_HOST_SKILLS_PATH=${HELIX_ROOT}/skills
      - HELIX_SANDBOX_HOST=host.docker.internal
      # Proxy values (HTTP_PROXY/HTTPS_PROXY/ALL_PROXY) are inherited from ../.env via env_file.
      # Only NO_PROXY is declared here so internal service hostnames are always exempt from the proxy.
      - NO_PROXY=${NO_PROXY:-}${NO_PROXY:+,}localhost,127.0.0.1,::1,gateway,frontend,nginx,provisioner,host.docker.internal
      - no_proxy=${no_proxy:-}${no_proxy:+,}localhost,127.0.0.1,::1,gateway,frontend,nginx,provisioner,host.docker.internal
    env_file:
      - ../.env
    extra_hosts:
      # For Linux: map host.docker.internal to host gateway
      - "host.docker.internal:host-gateway"
    depends_on:
      redis:
        condition: service_healthy
    networks:
      - helix-dev
    restart: unless-stopped

volumes:
  # Persist .venv across container restarts so dependencies installed during
  # image build are not shadowed by the host backend/ directory mount.
  gateway-venv:
  gateway-uv-cache:
  redis-data:

networks:
  helix-dev:
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.200.0/24
```

## 5. docker/docker-compose.dood.yaml（DooD overlay，opt-in）

Docker-out-of-Docker overlay。挂 host Docker socket 进 gateway 容器，让 AioSandboxProvider（pure-Docker 模式，无 `provisioner_url`）能通过 host Docker daemon 起 per-thread 沙箱容器。`scripts/deploy.sh` / `scripts/docker.sh` 仅在 `detect_sandbox_mode()` 返回 `"aio"` 时自动追加此 overlay。默认（local / provisioner 模式）不加载。

```yaml
# docker/docker-compose.dood.yaml
# Mounts the host Docker socket into the gateway container so that
# AioSandboxProvider running in pure-Docker mode - config.yaml:
#   sandbox.use: helix.community.aio_sandbox:AioSandboxProvider
# with NO provisioner_url - can start per-thread sandbox containers via the
# host Docker daemon.
#
# SECURITY: the host Docker socket grants the gateway container
# root-equivalent control of the host. Only load this overlay when you have
# explicitly chosen aio (DooD) sandbox mode and accept that trade-off. The
# default LocalSandboxProvider and the provisioner/Kubernetes mode do NOT need
# it and never load this file.
#
# scripts/deploy.sh and scripts/docker.sh append this overlay automatically
# only when detect_sandbox_mode() returns "aio". Manual use:
#   docker compose -f docker-compose.yaml -f docker-compose.dood.yaml up -d
#
# Compatible with both docker-compose.yaml (prod) and docker-compose-dev.yaml
# (dev): both define a `gateway` service, and Compose merges this volume entry
# onto it. HELIX_DOCKER_SOCKET defaults to /var/run/docker.sock.
services:
  gateway:
    volumes:
      - ${HELIX_DOCKER_SOCKET:-/var/run/docker.sock}:/var/run/docker.sock
```

## 6. docker/docker-compose.cli-auth.yaml（CLI auth overlay，opt-in）

挂 host Claude Code / Codex CLI 配置目录进 gateway，让 CLI 模型 provider 能复用 CLI 订阅登录、ACP agent 能在容器内跑 CLI。安全风险：暴露整个 `~/.claude` / `~/.codex`（会话历史、凭据）只读进容器。默认不加载；优先用 env token（`CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_AUTH_TOKEN`）。

```yaml
# docker/docker-compose.cli-auth.yaml
# Bind-mounts the host Claude Code / Codex CLI config dirs into the gateway so:
#   - ClaudeChatModel / Codex model providers can reuse the CLI subscription
#     login (~/.claude/.credentials.json, ~/.codex/auth.json), and
#   - ACP agents (acp_agents in config.yaml) that run the claude/codex CLI
#     inside the container can read their config.
#
# SECURITY: these mounts expose the ENTIRE ~/.claude and ~/.codex dirs
# (conversation history, projects, global config, long-lived credentials) into
# the gateway container, read-only. A gateway compromise leaks all of it. That
# is why they are NOT mounted by default.
#
# Prefer passing only a token via env instead (no directory exposure):
#   CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_AUTH_TOKEN for Claude, CODEX_AUTH_PATH
#   for a single Codex auth file.
# Use this overlay only when you need the full CLI config (e.g. ACP adapters
# that run the CLI in-container and read more than just the credential file).
#
# Manual use (works with both prod and dev compose):
#   docker compose -f docker-compose.yaml -f docker-compose.cli-auth.yaml up -d
services:
  gateway:
    volumes:
      - type: bind
        source: ${HOME:?HOME must be set}/.claude
        target: /root/.claude
        read_only: true
        bind:
          create_host_path: true
      - type: bind
        source: ${HOME:?HOME must be set}/.codex
        target: /root/.codex
        read_only: true
        bind:
          create_host_path: true
```

## 7. backend/Dockerfile（多阶段构建）

三阶段：Stage 1 builder（build-essential 编译原生扩展 + Node.js + uv sync）；Stage 2 dev（保留工具链，启动时 `uv sync`）；Stage 3 runtime（精简 ~200MB，无编译器，仅 Node.js runtime 供 npx MCP server 用）。`UV_EXTRAS` build-arg 透传可选依赖；`redis` extra 始终装（Docker Compose 默认 stream bridge 走 Redis）。UTF-8 locale 防 UnicodeEncodeError。

```dockerfile
# backend/Dockerfile - multi-stage build
# Stage 1 (builder): compiles native Python extensions with build-essential
# Stage 2 (dev):     retains toolchain for dev containers (uv sync at startup)
# Stage 3 (runtime): clean image without compiler toolchain for production

# UV source image (override for restricted networks that cannot reach ghcr.io)
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.7.20
FROM ${UV_IMAGE} AS uv-source

# ── Stage 1: Builder ──────────────────────────────────────────────────────────
FROM python:3.12-slim-bookworm AS builder

ARG NODE_MAJOR=22
ARG APT_MIRROR
ARG UV_INDEX_URL
# Optional extras to install (e.g. "postgres" for PostgreSQL support)
# Usage: docker build --build-arg UV_EXTRAS=postgres,discord ...
ARG UV_EXTRAS

# Optionally override apt mirror for restricted networks (e.g. APT_MIRROR=mirrors.aliyun.com)
RUN if [ -n "${APT_MIRROR}" ]; then \
      sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources 2>/dev/null || true; \
      sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list 2>/dev/null || true; \
    fi

# Install build tools + Node.js (build-essential needed for native Python extensions)
RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    gnupg \
    ca-certificates \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install uv (source image overridable via UV_IMAGE build arg)
COPY --from=uv-source /uv /uvx /usr/local/bin/

# Set working directory
WORKDIR /app

# Copy backend source code
COPY backend ./backend

# Install dependencies with cache mount
# `redis` is always installed because Docker Compose defaults the stream bridge
# to Redis (HELIX_STREAM_BRIDGE_REDIS_URL); it is an optional extra elsewhere
# so slim non-Docker installs do not pull it.
# When UV_EXTRAS is set (comma- or whitespace-separated), installs optional dependencies.
RUN --mount=type=cache,target=/root/.cache/uv \
    sh -c 'cd backend && \
    set -f; \
    extras_flags=""; \
    for extra in $(printf "%s" "$UV_EXTRAS" | tr "," " "); do \
        case "$extra" in \
            [!A-Za-z]* | *[!A-Za-z0-9_-]*) \
                echo "UV_EXTRAS entry $extra is invalid (must match [A-Za-z][A-Za-z0-9_-]*)" >&2; \
                exit 1; \
                ;; \
        esac; \
        extras_flags="$extras_flags --extra $extra"; \
    done; \
    UV_INDEX_URL=${UV_INDEX_URL:-https://pypi.org/simple} uv sync --extra redis $extras_flags'

# UTF-8 locale prevents UnicodeEncodeError on Chinese/emoji content in minimal
# containers where locale configuration may be missing and the default encoding is not UTF-8.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PYTHONIOENCODING=utf-8

# ── Stage 2: Dev ──────────────────────────────────────────────────────────────
# Retains compiler toolchain from builder so startup-time `uv sync` can build
# source distributions in development containers.
FROM builder AS dev

# Install Docker CLI (for DooD: allows starting sandbox containers via host Docker socket)
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker

EXPOSE 8001

CMD ["sh", "-c", "cd backend && PYTHONPATH=. uv run uvicorn gateway.gateway.app:app --host 0.0.0.0 --port 8001"]

# ── Stage 3: Runtime ──────────────────────────────────────────────────────────
# Clean image without build-essential - reduces size (~200 MB) and attack surface.
FROM python:3.12-slim-bookworm

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PYTHONIOENCODING=utf-8

# Copy Node.js runtime from builder (provides npx for MCP servers)
COPY --from=builder /usr/bin/node /usr/bin/node
COPY --from=builder /usr/lib/node_modules /usr/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/bin/npx

# Install Docker CLI (for DooD: allows starting sandbox containers via host Docker socket)
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker

# Install uv (source image overridable via UV_IMAGE build arg)
COPY --from=uv-source /uv /uvx /usr/local/bin/

# Set working directory
WORKDIR /app

# Copy backend with pre-built virtualenv from builder
COPY --from=builder /app/backend ./backend

# Expose Gateway API port.
EXPOSE 8001

# Default command (can be overridden in docker-compose)
CMD ["sh", "-c", "cd backend && PYTHONPATH=. uv run --no-sync uvicorn gateway.gateway.app:app --host 0.0.0.0 --port 8001"]
```

## 8. docker/provisioner/app.py（K8s 沙箱 provisioner）

FastAPI 服务，per-sandbox Pod + NodePort Service 生命周期管理。lifespan 里 `load_kube_config`（先试挂载的 kubeconfig，回退 in-cluster config）+ `_ensure_namespace`。`POST /api/sandboxes` 建 Pod + Service（idempotent，已存在则返回现状）。skills 三路挂载（public / per-user custom / legacy）镜像 `LocalSandboxProvider` 的 hostPath 布局。PVC 模式回退单卷挂载。

```python
"""Helix Sandbox Provisioner Service.

Dynamically creates and manages per-sandbox Pods in Kubernetes.
Each ``sandbox_id`` gets its own Pod + NodePort Service.  The backend
accesses sandboxes directly via ``{NODE_HOST}:{NodePort}``.

The provisioner connects to the host machine's Kubernetes cluster via a
mounted kubeconfig (``~/.kube/config``).  Sandbox Pods run on the host
K8s and are accessed by the backend via ``{NODE_HOST}:{NodePort}``.

Endpoints:
    POST   /api/sandboxes              - Create a sandbox Pod + Service
    DELETE /api/sandboxes/{sandbox_id} - Destroy a sandbox Pod + Service
    GET    /api/sandboxes/{sandbox_id} - Get sandbox status & URL
    GET    /api/sandboxes              - List all sandboxes
    GET    /health                     - Provisioner health check

Architecture (docker-compose-dev):
    ┌────────────┐  HTTP  ┌─────────────┐  K8s API  ┌──────────────┐
    │ remote     │ ─────▸ │ provisioner │ ────────▸ │  host K8s    │
    │ _backend   │        │ :8002       │           │  API server  │
    └────────────┘        └─────────────┘           └──────┬───────┘
                                                           │ creates
                          ┌─────────────┐           ┌──────▼───────┐
                          │   backend   │ ────────▸ │   sandbox    │
                          │             │  direct   │   Pod(s)     │
                          └─────────────┘ NodePort  └──────────────┘
"""

from __future__ import annotations

import logging
import os
import re
import time
from contextlib import asynccontextmanager

import urllib3
from fastapi import FastAPI, HTTPException
from kubernetes import client as k8s_client
from kubernetes import config as k8s_config
from kubernetes.client.rest import ApiException
from pydantic import BaseModel, Field

# Suppress only the InsecureRequestWarning from urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)-5.5s] %(name)s: %(message)s",
)

# ── Configuration (all tuneable via environment variables) ───────────────

K8S_NAMESPACE = os.environ.get("K8S_NAMESPACE", "helix")
SANDBOX_IMAGE = os.environ.get(
    "SANDBOX_IMAGE",
    "enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:latest",
)
SKILLS_HOST_PATH = os.environ.get("SKILLS_HOST_PATH", "/skills")
THREADS_HOST_PATH = os.environ.get("THREADS_HOST_PATH", "/.helix/threads")
HELIX_HOST_BASE_DIR = os.environ.get("HELIX_HOST_BASE_DIR", "/.helix")
SKILLS_PVC_NAME = os.environ.get("SKILLS_PVC_NAME", "")
USERDATA_PVC_NAME = os.environ.get("USERDATA_PVC_NAME", "")
SANDBOX_CONTAINER_PORT_RAW = os.environ.get("SANDBOX_CONTAINER_PORT", "8080")
try:
    SANDBOX_CONTAINER_PORT = int(SANDBOX_CONTAINER_PORT_RAW)
except ValueError as exc:
    raise RuntimeError(
        f"Invalid SANDBOX_CONTAINER_PORT={SANDBOX_CONTAINER_PORT_RAW!r}; expected an integer TCP port"
    ) from exc
if not (1 <= SANDBOX_CONTAINER_PORT <= 65535):
    raise RuntimeError(
        f"Invalid SANDBOX_CONTAINER_PORT={SANDBOX_CONTAINER_PORT}; expected a value in [1, 65535]"
    )
SAFE_THREAD_ID_PATTERN = r"^[A-Za-z0-9_\-]+$"
SAFE_USER_ID_PATTERN = r"^[A-Za-z0-9_\-]+$"
DEFAULT_USER_ID = "default"

# Path to the kubeconfig *inside* the provisioner container.
# Typically the host's ~/.kube/config is mounted here.
KUBECONFIG_PATH = os.environ.get("KUBECONFIG_PATH", "/root/.kube/config")

# The hostname / IP that the *backend container* uses to reach NodePort
# services on the host Kubernetes node.  On Docker Desktop for macOS this
# is ``host.docker.internal``; on Linux it may be the host's LAN IP.
NODE_HOST = os.environ.get("NODE_HOST", "host.docker.internal")


def join_host_path(base: str, *parts: str) -> str:
    """Join host filesystem path segments while preserving native style."""
    if not parts:
        return base

    if re.match(r"^[A-Za-z]:[\\/]", base) or base.startswith("\\\\") or "\\" in base:
        from pathlib import PureWindowsPath

        result = PureWindowsPath(base)
        for part in parts:
            result /= part
        return str(result)

    from pathlib import Path

    result = Path(base)
    for part in parts:
        result /= part
    return str(result)


# ── K8s client setup ────────────────────────────────────────────────────

core_v1: k8s_client.CoreV1Api | None = None


def _init_k8s_client() -> k8s_client.CoreV1Api:
    """Load kubeconfig from the mounted host config and return a CoreV1Api.

    Tries the mounted kubeconfig first, then falls back to in-cluster
    config (useful if the provisioner itself runs inside K8s).
    """
    if os.path.exists(KUBECONFIG_PATH):
        if os.path.isdir(KUBECONFIG_PATH):
            raise RuntimeError(
                f"KUBECONFIG_PATH points to a directory, expected a file: {KUBECONFIG_PATH}"
            )
        try:
            k8s_config.load_kube_config(config_file=KUBECONFIG_PATH)
            logger.info(f"Loaded kubeconfig from {KUBECONFIG_PATH}")
        except Exception as exc:
            raise RuntimeError(
                f"Failed to load kubeconfig from {KUBECONFIG_PATH}: {exc}"
            ) from exc
    else:
        logger.warning(
            f"Kubeconfig not found at {KUBECONFIG_PATH}; trying in-cluster config"
        )
        try:
            k8s_config.load_incluster_config()
        except Exception as exc:
            raise RuntimeError(
                "Failed to initialize Kubernetes client. "
                f"No kubeconfig at {KUBECONFIG_PATH}, and in-cluster config is unavailable: {exc}"
            ) from exc

    # When connecting from inside Docker to the host's K8s API, the
    # kubeconfig may reference ``localhost`` or ``127.0.0.1``.  We
    # optionally rewrite the server address so it reaches the host.
    k8s_api_server = os.environ.get("K8S_API_SERVER")
    if k8s_api_server:
        configuration = k8s_client.Configuration.get_default_copy()
        configuration.host = k8s_api_server
        # Self-signed certs are common for local clusters
        configuration.verify_ssl = False
        api_client = k8s_client.ApiClient(configuration)
        return k8s_client.CoreV1Api(api_client)

    return k8s_client.CoreV1Api()


def _wait_for_kubeconfig(timeout: int = 30) -> None:
    """Wait for kubeconfig file if configured, then continue with fallback support."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(KUBECONFIG_PATH):
            if os.path.isfile(KUBECONFIG_PATH):
                logger.info(f"Found kubeconfig file at {KUBECONFIG_PATH}")
                return
            if os.path.isdir(KUBECONFIG_PATH):
                raise RuntimeError(
                    "Kubeconfig path is a directory. "
                    f"Please mount a kubeconfig file at {KUBECONFIG_PATH}."
                )
            raise RuntimeError(
                f"Kubeconfig path exists but is not a regular file: {KUBECONFIG_PATH}"
            )
        logger.info(f"Waiting for kubeconfig at {KUBECONFIG_PATH} …")
        time.sleep(2)
    logger.warning(
        f"Kubeconfig not found at {KUBECONFIG_PATH} after {timeout}s; "
        "will attempt in-cluster Kubernetes config"
    )


def _ensure_namespace() -> None:
    """Create the K8s namespace if it does not yet exist."""
    try:
        core_v1.read_namespace(K8S_NAMESPACE)
        logger.info(f"Namespace '{K8S_NAMESPACE}' already exists")
    except ApiException as exc:
        if exc.status == 404:
            ns = k8s_client.V1Namespace(
                metadata=k8s_client.V1ObjectMeta(
                    name=K8S_NAMESPACE,
                    labels={
                        "app.kubernetes.io/name": "helix",
                        "app.kubernetes.io/component": "sandbox",
                    },
                )
            )
            core_v1.create_namespace(ns)
            logger.info(f"Created namespace '{K8S_NAMESPACE}'")
        else:
            raise


# ── FastAPI lifespan ─────────────────────────────────────────────────────


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global core_v1
    _wait_for_kubeconfig()
    core_v1 = _init_k8s_client()
    _ensure_namespace()
    logger.info("Provisioner is ready (using host Kubernetes)")
    yield


app = FastAPI(title="Helix Sandbox Provisioner", lifespan=lifespan)


# ── Request / Response models ───────────────────────────────────────────


class CreateSandboxRequest(BaseModel):
    sandbox_id: str
    thread_id: str = Field(pattern=SAFE_THREAD_ID_PATTERN)
    user_id: str = Field(default=DEFAULT_USER_ID, pattern=SAFE_USER_ID_PATTERN)
    include_legacy_skills: bool = False


class SandboxResponse(BaseModel):
    sandbox_id: str
    sandbox_url: str  # Direct access URL, e.g. http://host.docker.internal:{NodePort}
    status: str


# ── K8s resource helpers ─────────────────────────────────────────────────


def _pod_name(sandbox_id: str) -> str:
    return f"sandbox-{sandbox_id}"


def _svc_name(sandbox_id: str) -> str:
    return f"sandbox-{sandbox_id}-svc"


def _sandbox_url(node_port: int) -> str:
    """Build the sandbox URL using the configured NODE_HOST."""
    return f"http://{NODE_HOST}:{node_port}"

def _build_volumes(
    thread_id: str,
    user_id: str = DEFAULT_USER_ID,
    *,
    include_legacy_skills: bool = False,
) -> list[k8s_client.V1Volume]:
    """Build volume list: PVC when configured, otherwise hostPath.

    Skills are split into public, per-user custom, and legacy (global-custom)
    volumes so that ``/mnt/skills/{public,custom,legacy}/`` paths resolve
    correctly inside the sandbox - matching the hostPath layout produced by
    ``LocalSandboxProvider`` and ``AioSandboxProvider``.
    """
    volumes: list[k8s_client.V1Volume] = []

    # ── Skills volumes ────────────────────────────────────────────────

    if SKILLS_PVC_NAME:
        # PVC mode: three-way subPath not yet supported; fall back to
        # single-volume mount for backward compatibility.
        logger.warning(
            "SKILLS_PVC_NAME is set - three-way skills layout is not "
            "supported in PVC mode yet; falling back to single /mnt/skills mount"
        )
        volumes.append(
            k8s_client.V1Volume(
                name="skills",
                persistent_volume_claim=k8s_client.V1PersistentVolumeClaimVolumeSource(
                    claim_name=SKILLS_PVC_NAME,
                    read_only=True,
                ),
            )
        )
    else:
        # hostPath mode: three-way layout
        public_path = join_host_path(SKILLS_HOST_PATH, "public")
        volumes.append(
            k8s_client.V1Volume(
                name="skills-public",
                host_path=k8s_client.V1HostPathVolumeSource(
                    path=public_path,
                    type="Directory",
                ),
            )
        )

        user_custom_path = join_host_path(
            HELIX_HOST_BASE_DIR, "users", user_id, "skills", "custom",
        )
        volumes.append(
            k8s_client.V1Volume(
                name="skills-custom",
                host_path=k8s_client.V1HostPathVolumeSource(
                    path=user_custom_path,
                    type="DirectoryOrCreate",
                ),
            )
        )

        if include_legacy_skills:
            legacy_path = join_host_path(SKILLS_HOST_PATH, "custom")
            volumes.append(
                k8s_client.V1Volume(
                    name="skills-legacy",
                    host_path=k8s_client.V1HostPathVolumeSource(
                        path=legacy_path,
                        type="Directory",
                    ),
                )
            )

    # ── User-data volume ──────────────────────────────────────────────

    if USERDATA_PVC_NAME:
        userdata_vol = k8s_client.V1Volume(
            name="user-data",
            persistent_volume_claim=k8s_client.V1PersistentVolumeClaimVolumeSource(
                claim_name=USERDATA_PVC_NAME,
            ),
        )
    else:
        userdata_vol = k8s_client.V1Volume(
            name="user-data",
            host_path=k8s_client.V1HostPathVolumeSource(
                path=join_host_path(THREADS_HOST_PATH, thread_id, "user-data"),
                type="DirectoryOrCreate",
            ),
        )

    volumes.append(userdata_vol)
    return volumes


def _build_volume_mounts(
    thread_id: str,
    user_id: str = DEFAULT_USER_ID,
    *,
    include_legacy_skills: bool = False,
) -> list[k8s_client.V1VolumeMount]:
    """Build volume mount list, mirroring three-way skills layout."""
    mounts: list[k8s_client.V1VolumeMount] = []

    if SKILLS_PVC_NAME:
        mounts.append(
            k8s_client.V1VolumeMount(
                name="skills",
                mount_path="/mnt/skills",
                read_only=True,
            )
        )
    else:
        mounts.extend(
            [
                k8s_client.V1VolumeMount(
                    name="skills-public",
                    mount_path="/mnt/skills/public",
                    read_only=True,
                ),
                k8s_client.V1VolumeMount(
                    name="skills-custom",
                    mount_path="/mnt/skills/custom",
                    read_only=True,
                ),
            ]
        )
        if include_legacy_skills:
            mounts.append(
                k8s_client.V1VolumeMount(
                    name="skills-legacy",
                    mount_path="/mnt/skills/legacy",
                    read_only=True,
                )
            )

    userdata_mount = k8s_client.V1VolumeMount(
        name="user-data",
        mount_path="/mnt/user-data",
        read_only=False,
    )
    if USERDATA_PVC_NAME:
        userdata_mount.sub_path = (
            f"helix/users/{user_id}/threads/{thread_id}/user-data"
        )
    mounts.append(userdata_mount)

    return mounts


def _build_pod(
    sandbox_id: str,
    thread_id: str,
    user_id: str = DEFAULT_USER_ID,
    *,
    include_legacy_skills: bool = False,
) -> k8s_client.V1Pod:
    """Construct a Pod manifest for a single sandbox."""
    return k8s_client.V1Pod(
        metadata=k8s_client.V1ObjectMeta(
            name=_pod_name(sandbox_id),
            namespace=K8S_NAMESPACE,
            labels={
                "app": "helix-sandbox",
                "sandbox-id": sandbox_id,
                "app.kubernetes.io/name": "helix",
                "app.kubernetes.io/component": "sandbox",
            },
        ),
        spec=k8s_client.V1PodSpec(
            containers=[
                k8s_client.V1Container(
                    name="sandbox",
                    image=SANDBOX_IMAGE,
                    image_pull_policy="IfNotPresent",
                    ports=[
                        k8s_client.V1ContainerPort(
                            name="http",
                            container_port=SANDBOX_CONTAINER_PORT,
                            protocol="TCP",
                        )
                    ],
                    readiness_probe=k8s_client.V1Probe(
                        http_get=k8s_client.V1HTTPGetAction(
                            path="/v1/sandbox",
                            port=SANDBOX_CONTAINER_PORT,
                        ),
                        initial_delay_seconds=5,
                        period_seconds=5,
                        timeout_seconds=3,
                        failure_threshold=3,
                    ),
                    liveness_probe=k8s_client.V1Probe(
                        http_get=k8s_client.V1HTTPGetAction(
                            path="/v1/sandbox",
                            port=SANDBOX_CONTAINER_PORT,
                        ),
                        initial_delay_seconds=10,
                        period_seconds=10,
                        timeout_seconds=3,
                        failure_threshold=3,
                    ),
                    resources=k8s_client.V1ResourceRequirements(
                        requests={
                            "cpu": "100m",
                            "memory": "256Mi",
                            "ephemeral-storage": "500Mi",
                        },
                        limits={
                            "cpu": "1000m",
                            "memory": "1Gi",
                            "ephemeral-storage": "500Mi",
                        },
                    ),
                    volume_mounts=_build_volume_mounts(
                        thread_id,
                        user_id=user_id,
                        include_legacy_skills=include_legacy_skills,
                    ),
                    security_context=k8s_client.V1SecurityContext(
                        privileged=False,
                        allow_privilege_escalation=True,
                    ),
                )
            ],
            volumes=_build_volumes(
                thread_id,
                user_id=user_id,
                include_legacy_skills=include_legacy_skills,
            ),
            restart_policy="Always",
        ),
    )


def _build_service(sandbox_id: str) -> k8s_client.V1Service:
    """Construct a NodePort Service manifest (port auto-allocated by K8s)."""
    return k8s_client.V1Service(
        metadata=k8s_client.V1ObjectMeta(
            name=_svc_name(sandbox_id),
            namespace=K8S_NAMESPACE,
            labels={
                "app": "helix-sandbox",
                "sandbox-id": sandbox_id,
                "app.kubernetes.io/name": "helix",
                "app.kubernetes.io/component": "sandbox",
            },
        ),
        spec=k8s_client.V1ServiceSpec(
            type="NodePort",
            ports=[
                k8s_client.V1ServicePort(
                    name="http",
                    port=SANDBOX_CONTAINER_PORT,
                    target_port=SANDBOX_CONTAINER_PORT,
                    protocol="TCP",
                    # nodePort omitted -> K8s auto-allocates from the range
                )
            ],
            selector={
                "sandbox-id": sandbox_id,
            },
        ),
    )


def _get_node_port(sandbox_id: str) -> int | None:
    """Read the K8s-allocated NodePort from the Service."""
    try:
        svc = core_v1.read_namespaced_service(_svc_name(sandbox_id), K8S_NAMESPACE)
        for port in svc.spec.ports or []:
            if port.name == "http":
                return port.node_port
    except ApiException:
        pass
    return None


def _get_pod_phase(sandbox_id: str) -> str:
    """Return the Pod phase (Pending / Running / Succeeded / Failed / Unknown)."""
    try:
        pod = core_v1.read_namespaced_pod(_pod_name(sandbox_id), K8S_NAMESPACE)
        return pod.status.phase or "Unknown"
    except ApiException:
        return "NotFound"


# ── API endpoints ────────────────────────────────────────────────────────


@app.get("/health")
async def health():
    """Provisioner health check."""
    return {"status": "ok"}


@app.post("/api/sandboxes", response_model=SandboxResponse)
def create_sandbox(req: CreateSandboxRequest):
    """Create a sandbox Pod + NodePort Service for *sandbox_id*.

    If the sandbox already exists, returns the existing information
    (idempotent).
    """
    sandbox_id = req.sandbox_id
    thread_id = req.thread_id
    user_id = req.user_id
    include_legacy_skills = req.include_legacy_skills

    logger.info(
        "Received request to create sandbox '%s' for thread '%s' user '%s' include_legacy_skills=%s",
        sandbox_id,
        thread_id,
        user_id,
        include_legacy_skills,
    )

    # ── Fast path: sandbox already exists ────────────────────────────
    existing_port = _get_node_port(sandbox_id)
    if existing_port:
        return SandboxResponse(
            sandbox_id=sandbox_id,
            sandbox_url=_sandbox_url(existing_port),
            status=_get_pod_phase(sandbox_id),
        )

    # ── Create Pod ───────────────────────────────────────────────────
    try:
        core_v1.create_namespaced_pod(
            K8S_NAMESPACE,
            _build_pod(
                sandbox_id,
                thread_id,
                user_id=user_id,
                include_legacy_skills=include_legacy_skills,
            ),
        )
        logger.info(f"Created Pod {_pod_name(sandbox_id)}")
    except ApiException as exc:
        if exc.status != 409:  # 409 = AlreadyExists
            raise HTTPException(
                status_code=500, detail=f"Pod creation failed: {exc.reason}"
            )

    # ── Create Service ───────────────────────────────────────────────
    try:
        core_v1.create_namespaced_service(K8S_NAMESPACE, _build_service(sandbox_id))
        logger.info(f"Created Service {_svc_name(sandbox_id)}")
    except ApiException as exc:
        if exc.status != 409:
            # Roll back the Pod on failure
            try:
                core_v1.delete_namespaced_pod(_pod_name(sandbox_id), K8S_NAMESPACE)
            except ApiException:
                pass
            raise HTTPException(
                status_code=500, detail=f"Service creation failed: {exc.reason}"
            )

    # ── Read the auto-allocated NodePort ─────────────────────────────
    node_port: int | None = None
    for _ in range(20):
        node_port = _get_node_port(sandbox_id)
        if node_port:
            break
        time.sleep(0.5)

    if not node_port:
        raise HTTPException(
            status_code=500, detail="NodePort was not allocated in time"
        )

    return SandboxResponse(
        sandbox_id=sandbox_id,
        sandbox_url=_sandbox_url(node_port),
        status=_get_pod_phase(sandbox_id),
    )


@app.delete("/api/sandboxes/{sandbox_id}")
def destroy_sandbox(sandbox_id: str):
    """Destroy a sandbox Pod + Service."""
    errors: list[str] = []

    # Delete Service
    try:
        core_v1.delete_namespaced_service(_svc_name(sandbox_id), K8S_NAMESPACE)
        logger.info(f"Deleted Service {_svc_name(sandbox_id)}")
    except ApiException as exc:
        if exc.status != 404:
            errors.append(f"service: {exc.reason}")

    # Delete Pod
    try:
        core_v1.delete_namespaced_pod(_pod_name(sandbox_id), K8S_NAMESPACE)
        logger.info(f"Deleted Pod {_pod_name(sandbox_id)}")
    except ApiException as exc:
        if exc.status != 404:
            errors.append(f"pod: {exc.reason}")

    if errors:
        raise HTTPException(
            status_code=500, detail=f"Partial cleanup: {', '.join(errors)}"
        )

    return {"ok": True, "sandbox_id": sandbox_id}


@app.get("/api/sandboxes/{sandbox_id}", response_model=SandboxResponse)
def get_sandbox(sandbox_id: str):
    """Return current status and URL for a sandbox."""
    node_port = _get_node_port(sandbox_id)
    if not node_port:
        raise HTTPException(status_code=404, detail=f"Sandbox '{sandbox_id}' not found")

    return SandboxResponse(
        sandbox_id=sandbox_id,
        sandbox_url=_sandbox_url(node_port),
        status=_get_pod_phase(sandbox_id),
    )


@app.get("/api/sandboxes")
def list_sandboxes():
    """List every sandbox currently managed in the namespace."""
    try:
        services = core_v1.list_namespaced_service(
            K8S_NAMESPACE,
            label_selector="app=helix-sandbox",
        )
    except ApiException as exc:
        raise HTTPException(
            status_code=500, detail=f"Failed to list services: {exc.reason}"
        )

    sandboxes: list[SandboxResponse] = []
    for svc in services.items:
        sid = (svc.metadata.labels or {}).get("sandbox-id")
        if not sid:
            continue
        node_port = None
        for port in svc.spec.ports or []:
            if port.name == "http":
                node_port = port.node_port
                break
        if node_port:
            sandboxes.append(
                SandboxResponse(
                    sandbox_id=sid,
                    sandbox_url=_sandbox_url(node_port),
                    status=_get_pod_phase(sid),
                )
            )

    return {"sandboxes": sandboxes, "count": len(sandboxes)}
```
