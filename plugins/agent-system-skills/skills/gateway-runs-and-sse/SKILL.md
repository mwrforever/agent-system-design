---
name: gateway-runs-and-sse
description: Gateway 服务装配与 threads/runs API 全量源码：app.py lifespan 启动链（引擎/检查点/记忆预热/渠道/调度器）、deps.py 运行时单例装配与多 worker 安全门、services.py 2804 行运行编排（start_run/normalize_input/信任边界/sse_consumer/wait_for_run_completion/format_sse）、threads/thread_runs 路由的全部端点（分支/重生成/搜索/压缩/goal/消息分页/工件打包）、SSE 事件流契约（491 行冻结 JSON）。当要实现 LangGraph 兼容的 threads/runs 服务面、SSE 流式 API 设计、排查 run 生命周期 HTTP 语义时使用。
---

# Gateway 运行时与 SSE

## 何时用

- 实现（或对接）LangGraph 兼容的 threads/runs REST + SSE API
- 大型 FastAPI 应用的 lifespan 装配设计
- SSE 流式端点：格式化、心跳、Last-Event-ID
- 会话分支/重生成/压缩/goal 等 thread 级操作的语义

## 设计方案（为什么这么设计）

### 1. 装配三层：app → deps → services

- `app.py::create_app` + `lifespan`（1467 行）：中间件栈 `AuthMiddleware → CSRFMiddleware → CORSMiddleware → TraceMiddleware`，末尾挂扩展贡献路由；lifespan 按序启动：投影确保 → tracing → 记忆预热（warm retrieval + tiktoken）→ 上传暂存清理 → **`deps.langgraph_runtime()`**（唯一运行时装配点）→ 管理员确保 → 回收站清扫 → 调度器/MCP 任务/子代理批服务 → 渠道服务。
- `deps.py::langgraph_runtime`（1337 行）：多 worker 安全门（多 worker 强制 postgres + 凭据密钥校验）→ `make_stream_bridge` → `init_engine_from_config` → `make_checkpointer` → `make_store` → `make_run_event_store` → 各仓库挂 `app.state` → RunManager。
- `services.py`（2804 行）：HTTP 与执行之间的编排层——`normalize_input`（消息/附件/goal 规范化）、`build_run_config`、`merge_run_context_overrides`/`strip_internal_context_keys`（信任边界，见 [[e2e-request-lifecycle]]）、`start_run`、`sse_consumer` + `format_sse`、`wait_for_run_completion`（同步等待面给渠道/调度器）。

**为什么这样分**：路由层只做参数与身份；services 不碰 FastAPI 对象（可被调度器/渠道/扩展复用）；deps 是单例装配的唯一入口——散落的单例初始化是启动顺序 bug 之源。

### 2. runs 语义：stream 与 wait 双面

- `POST /threads/{id}/runs/stream`：创建 run + SSE 流（`stream_subgraphs` 时子图事件以 `values|<ns>` 命名空间发布，不冒充根帧）
- `POST /threads/{id}/runs/wait`：阻塞至终态（给非交互调用方）
- `POST /runs/{rid}/cancel`：取消；`GET /runs/{rid}/join`：加入进行中 run 的流
- 消息/事件分页端点带 51 行取 50 + 哨兵的约定（前端镜像实现，见 [[frontend-streaming-protocol]]）

### 3. SSE 出口

`sse_consumer` 订阅 StreamBridge → `format_sse` 逐条下发（事件名/seq/JSON data），心跳哨兵保活；断线凭 `Last-Event-ID` 从事件存储补齐缺口。事件面（名字/category/seq 语义/known_gaps）由 491 行冻结契约定义——**契约里的 known_gaps 段同样重要**（如"终态以 RunRow.status 为准"），它防止消费者对未承诺的性质做假设。

### 4. thread 级操作端点族

threads.py（2057 行）：创建/搜索/移动/分支（branches）/标记已读/goal 读写/compact/state 读写/history 分页；thread_runs.py（1903 行）：regenerate/edit-regenerate 预处理（从指定消息重跑）、run 列表与分页、工件归档下载、token 用量查询。附件上传（uploads.py）与工件（artifacts.py，SHA-256 原子替换 + Range 断点）在 [[workspace-and-projects]]。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/app/gateway/app.py` | 1467 | 应用与 lifespan |
| `references/code/app/gateway/deps.py` | 1337 | 运行时单例装配 + 多 worker 门 |
| `references/code/app/gateway/services.py` | 2804 | 运行编排 + SSE 消费 + 信任边界 |
| `references/code/app/gateway/routers/thread_runs.py` | 1903 | runs 全端点 |
| `references/code/app/gateway/routers/threads.py` | 2057 | threads 全端点 |
| `references/code/app/gateway/routers/runs.py` | 150 | 无 thread 上下文的 runs 面 |
| `references/code/app/gateway/{run_models,health,sse_headers,langgraph_studio,conversation_access,conversation_reader}.py` | 178/418/28/185/326/191 | 模型/健康检查/SSE 头/Studio 兼容/会话访问 |
| `references/code/app/gateway/routers/{console,features,capabilities,thread_activity,suggestions,input_polish}.py` | 549/163/51/120/154/107 | 平台面路由 |
| `references/code/runtime/{stream_modes,converters,serialization}.py` | 47/136/148 | 流模式/事件转换/序列化 |
| `references/code/contracts/run_event_stream_contract.json` | 491 | 事件流冻结契约 |

## 反模式与陷阱

- ❌ 路由里直接调运行时 → 调度器/渠道无法复用；编排进 services。
- ❌ 单例装配散落多文件 → 启动顺序竞态；只走 deps。
- ❌ 多 worker + sqlite → 数据竞争；启动门强制 postgres。
- ❌ 子图事件冒充根帧 → 前端丢父线程视图；`values|<ns>` 命名空间。
- ❌ SSE 依赖 nginx 默认缓冲 → 卡流；`proxy_buffering off`（见 [[e2e-request-lifecycle]]）。
- ❌ 私扩事件字段不带版本 → 消费方破；契约 + known_gaps。

## 落地参考

**自测方向**：stream 与 wait 对同一 run 终态一致；`Last-Event-ID` 重连补齐；cancel 幂等（终态后 cancel 返回 409 语义）；regenerate 产生新 run 且原消息保留；分页哨兵语义。

**调试**：`format_sse` 事件名 + seq 日志、lifespan 启动序日志。

## 进一步阅读

- [[e2e-request-lifecycle]]（本 skill 是其④⑦步的源码全文）、[[long-running-and-cancellation]]（RunManager/worker/bridge 实现）
- [[frontend-streaming-protocol]]（消费端归一化）
