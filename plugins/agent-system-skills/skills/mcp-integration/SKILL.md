---
name: mcp-integration
description: MCP 多 server 集成全链路：三种 transport（stdio/sse/http）参数构建与 header 合法性校验、stdio 子进程工作区隔离（pin 到线程目录 + 前后快照 + 路径回写）、配置指纹驱动的增量 reconciliation 缓存、MCPSessionPool 长连接会话池、OAuth 令牌管理与运行时上下文 header 拦截器、per-user 个人 MCP（admin 门禁 + 公网过滤）、MCP Tasks 长任务租赁运行时（DB 事实源 + 租约 + 轮询 worker）、业务插件能力目录。当要接 MCP server、排查"工具不出现/进程泄漏/凭据解析/长任务卡死"时使用。
---

# MCP 集成

## 何时用

- 接入/管理多个 MCP server（stdio 子进程、远程 http/sse）
- MCP 工具的缓存与热更新（改配置不重启）
- 个人（per-user）MCP 与安全边界
- 远程长任务（submit/status/cancel 工具三元组）的租赁运行时

## 设计方案（为什么这么设计）

### 1. 参数构建：先校验后建连

`build_server_params`（client.py:12）：stdio 需要 `command/args[/cwd/env]`；sse/http 需要 `url[/headers]`。header 值先过 `illegal_header_value_reason` 拒绝——非法 header 在 h11 层炸出的异常会**带出凭据原文**。env 凭据用 `$VAR` 语法在配置加载期解析（错误信息脱敏，见 [[config-and-hot-reload]]）。

### 2. stdio 进程隔离：pin 工作区 + 快照

stdio 子进程默认能看到宿主 CWD。`_prepare_stdio_workspace`（tools.py:217）把子进程 pin 到线程工作目录 + 0700 临时目录，调用前后做文件快照（`_snapshot/_changed_workspace_files`），结果文本里的本地路径**重写回虚拟路径**——MCP server 不经沙箱工具体系，必须自带隔离。

### 3. 缓存：指纹 + 增量 reconciliation

`initialize_mcp_tools`（cache.py:895）条件变量防并发初始化；配置快照 + stdio 指纹 + `_AppliedMcpRevision` 支撑**按 server 粒度**的增量对账：改一个 server 只重连一个，其余会话/工具缓存原样复用。`get_cached_mcp_tools` 是零成本快路径——**从未初始化的进程不做任何发现**（延迟加载），冷进程不因 MCP 拖慢启动。

### 4. 会话池

`MCPSessionPool`（session_pool.py:183）：每 server 绑定连接指纹，断线检测（`_is_mcp_transport_disconnect`）后按指纹失效重建；工具调用经池复用长连接，而非每调用起一个子进程。每个 MCP server 独立进程、独立 env、独立开关。

### 5. 个人 MCP 与网络边界

per-user 配置文件（`user_config.py` 文件签名缓存）+ `requires_admin` 门禁（个人 server 默认仅 admin 可配）+ `personal_network.py`：个人配置里的公网地址强制走专用 httpx client factory（仅放行公网地址）——防内网 SSRF。同名工具冲突时弃个人保全局（见 [[tool-assembly-and-policy]]）。

### 6. MCP Tasks：长任务不出 agent 循环

远程 server 的慢任务（报表、爬取）若同步等待会占死 agent。`extensions_config.json → mcpServers[].task_toolsets`（submit/status/cancel 三元组）把这类 server 对接 `McpTaskService`（app/mcp_tasks/service.py，1566 行）：**Agent 只看到 submit**，任务落到 DB；后台 worker 租约 claim → 轮询远端 → 结果落库（≤64KiB）/通知重试/死信；取消走围栏。DB 是事实源，worker 崩溃可恢复（与调度器/批处理同构三件套：DB 事实源 + 租约 + 幂等 claim）。

### 7. OAuth 与上下文 header

`OAuthTokenManager` + 拦截器组装（interceptors.py）：server 声明的 OAuth 流程与运行时上下文注入 header（`context_headers.py`：thread_id/user_id 注入 MCP 请求头）在会话层统一挂。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `mcp/tools.py` | 1494 | 发现/包装/路径重写/stdio 工作区/池化工具构造 |
| `mcp/cache.py` | 1407 | 指纹缓存/增量 reconciliation/延迟加载 |
| `mcp/session_pool.py` | 1062 | 会话池/断线重建 |
| `mcp/task_tool_caller.py` | 401 | 长任务工具调用面 |
| `mcp/oauth.py` | 309 | OAuth 令牌管理 |
| `mcp/lifecycle.py` | 207 | 生命周期账本（Ledger/Delta） |
| `mcp/context_headers.py` / `headers.py` / `interceptors.py` | 207/103/94 | 上下文注入/头校验/拦截器 |
| `mcp/client.py` / `config_normalization.py` | 86/46 | 参数构建/配置归一 |
| `mcp/user_config.py` / `user_tools.py` / `user_scoped_auth.py` / `personal_access.py` / `personal_network.py` | 77/61/150/46/62 | 个人 MCP 全套 |
| `mcp/tasks/`（models/ordinary/runtime/driver） | 565 | 任务模型与运行时驱动 |
| `capabilities/`（catalog/business/runtime） | — | 业务插件目录与独立业务 server 进程 |
| `backend/app/mcp_tasks/service.py` | 1566 | 租赁 worker（claim/poll/cancel/notify/死信） |
| `backend/app/gateway/routers/mcp.py` / `personal_mcp.py` / `mcp_tasks.py` | 1731/—/218 | 配置与任务 API |

（以上路径前缀 `references/code/backend/packages/harness/helix/`）

## 反模式与陷阱

- ❌ 每次工具调用新起 stdio 进程 → 进程风暴；会话池。
- ❌ 改一个 server 全量重连 → 抖动放大；按 server 粒度 reconciliation。
- ❌ header 值不校验直接传 → 底层异常泄凭据；先拒非法值。
- ❌ 个人 server 无网络过滤 → 内网 SSRF；公网专用 client factory。
- ❌ 长任务同步等待 → agent 循环被占死；task_toolsets + 租赁 worker。
- ❌ 冷启动即全量发现 → 启动慢；延迟加载 + 零成本快路径。

## 落地参考

**调参旋钮**：`extensions_config.json → mcpServers`（transport/headers/$VAR/tool_name_prefix/session_init_timeout/tool_call_timeout/routing/task_toolsets）；`mcp_tasks`（poll 5s/lease 120s/max_concurrent_polls 8/backoff 300s/result 64KiB）。

**自测方向**：改单 server 配置断言仅该 server 重连；杀池进程后断线重建；个人 server 配内网地址被拒；长任务 worker 中断后租约恢复继续轮询；MCP 工具名冲突弃个人。

## 进一步阅读

- [[tool-assembly-and-policy]]（MCP 工具并入装配管线）、[[config-and-hot-reload]]（extensions_config 原子写回）
- [[scheduled-tasks]] / [[subagent-delegation]]（同构后台 worker 模式）
