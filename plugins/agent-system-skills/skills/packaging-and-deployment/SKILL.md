---
name: packaging-and-deployment
description: 部署与交付体系：Docker Compose 服务拓扑（nginx 2026 唯一入口 + gateway 8001 + frontend 3000 + provisioner 8002，loopback 默认绑定与 BIND_HOST 约定）、nginx SSE/WebSocket/上传三段专用配置、K8s Helm chart（gateway/frontend/nginx/provisioner/postgres/redis/ingress，优雅停机与 PDB）、Provisioner 沙箱供给器（每沙箱一 Pod+Service）、多实例部署要求（postgres + 心跳 + db 事件 + Redis 流桥）、开发/生产/DooD overlay 组合。当要容器化 agent 平台、设计反向代理 SSE 通道、K8s 交付或多实例扩缩容时使用。
---

# 打包与部署

## 何时用

- 把 agent 平台容器化（单机 compose 或 K8s）
- nginx 承载 SSE/WebSocket/大文件上传的反代配置
- 多实例（多 Gateway 副本）扩容的前置条件
- 沙箱供给器（provisioner）模式

## 设计方案（为什么这么设计）

### 1. 拓扑：一个入口，内部互联

```
nginx :2026（唯一发布端口，默认 127.0.0.1 绑定）
 ├─ /api/langgraph/* → gateway:8001/api/*（重写）
 ├─ /api/*           → gateway:8001
 ├─ /api/sandboxes/* → provisioner:8002（可选）
 └─ /*               → frontend:3000
redis（内部）  gateway（内部）  frontend（内部）  provisioner（可选，内部）
```

**为什么 loopback 默认**：agent 会执行任意命令——裸 `"${PORT}:2026"`（0.0.0.0）被 CI 检查拒绝；对外暴露必须显式 `BIND_HOST`。gateway 的 8001 永不发布。

### 2. nginx 的三段专项配置

`nginx.conf`（383 行模板）：
- SSE：`proxy_buffering off` + `X-Accel-Buffering no` + 600s 三超时（读写/空闲）
- WebSocket：`/api/threads/*/browser/stream` upgrade 头
- 上传：普通 20M、技能包安装 101M（略大于后端限制，让后端语义生效）
- loopback 归一 301（127.0.0.1 → localhost，cookie 同域）；保留上游 X-Forwarded-Proto
`nginx.local.conf` 为本地直跑变体（显式 listen 127.0.0.1）。

### 3. compose 家族

`docker-compose.yaml`（生产，gateway healthcheck `/health/ready`、GATEWAY_WORKERS）、`-dev`（源码挂载 + provisioner 默认参与）、`-dood`（挂宿主 docker socket 的 overlay）、`-cli-auth`、`-openviking`（沙箱服务 overlay）。overlay 组合而非复制文件——差异面最小化。

### 4. Helm：compose 语义的 K8s 翻译

`deploy/helm/`（42 文件）：gateway/frontend/nginx/provisioner 四工作负载 + postgres/redis（内嵌或外接开关 `external`）+ ingress + PVC（home）+ 技能 ConfigMap。关键值：`gateway.multiInstance`、`uvicornGracefulShutdownSeconds:10` + `terminationGracePeriodSeconds:90`（run 收尾窗口）、PDB、内联 `config:`/`extensionsConfig:` 整份配置进 ConfigMap。

### 5. Provisioner：K8s 沙箱供给

`docker/provisioner/app.py`（1457 行）：`POST/GET/DELETE /api/sandboxes` + `/presence` + `/health`——**每沙箱一个 Pod + Service**（强隔离，资源可回收）；provisioner 自身无状态可多副本。

### 6. 多实例前置（启动时校验拒绝）

多 Gateway 副本要求：Postgres（非 sqlite）+ run_ownership 心跳租约 + `run_events` db 后端 + Redis StreamBridge——四件缺一即拒绝启动（见 [[long-running-and-cancellation]] 与 [[config-and-hot-reload]]）。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/docker/docker-compose.yaml` + `-dev/-dood/-cli-auth/-openviking` | 263+286+26+36+42 | 服务编排 |
| `references/code/docker/nginx/nginx.conf` + `nginx.local.conf` | 383+421 | 反代 |
| `references/code/docker/provisioner/app.py` | 1457 | 沙箱供给器 |
| `references/code/docker/dev-entrypoint.sh` | — | 开发入口 |
| `references/code/deploy/helm/**`（Chart/values/22 模板） | — | K8s 交付 |
| `references/code/Makefile` + `backend/pyproject.toml` + `frontend/Dockerfile` | — | 构建 |
| `references/code/backend/packages/harness/helix/config/deployment_config.py` | 107 | 多实例声明配置 |

## 反模式与陷阱

- ❌ 裸端口发布（无 BIND_HOST） → agent 执行面暴露公网；CI 拒绝。
- ❌ nginx 默认缓冲跑 SSE → 卡流；三段专项配置。
- ❌ 上传限制反代小于后端 → 413 语义错位；反代略大。
- ❌ 多实例只加副本数 → 数据竞争；四件套先就位。
- ❌ terminationGracePeriod 与 run 时长不匹配 → 滚更杀 run；90s 窗口 + 优雅停机。
- ❌ postgres/redis 双实例内嵌还互不感知 → 状态分裂；单一写实例或外接。

## 落地参考

**自测方向**：compose 默认绑定断言全部 loopback；SSE 经 nginx 长连接 >60s 不断；101M 技能包可传；helm 模板渲染多实例配置完整；provisioner 建删沙箱 Pod 生命周期。

## 进一步阅读

- [[e2e-request-lifecycle]]（入口路由在链路中的位置）、[[long-running-and-cancellation]]（多实例四件套的运行时含义）
- [[sandbox-abstraction]]（provisioner 供给的沙箱被谁消费）
