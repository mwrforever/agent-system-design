---
name: e2e-request-lifecycle
description: 一次 agent 请求的端到端全链路脊柱：nginx 入口 → Gateway 鉴权/CSRF → threads-runs 路由 → RunManager 原子注册 → 后台 worker 建图执行 → StreamBridge SSE 事件流 → 前端归一化渲染。当需要理解"消息发出去之后到底发生了什么"、设计新平台的请求链路、排查"事件丢失/顺序错乱/run 卡死/上下文没传到工具"这类跨层问题时使用。做任何运行时核心改动（图工厂/中间件/工具）前先读本 skill 定位改动在链路中的位置。
---

# 端到端请求生命周期（脊柱 skill）

本 skill 是整套系统的**主链路地图**：其余 32 个 skill 都挂在这条链的某一步上。

## 何时用

- 新人式问题："一条消息从浏览器发出到看到回复，中间经过什么？"
- 设计新平台需要一条参考链路
- 跨层排障：事件丢失、顺序错乱、run 状态不一致、`context` 值没到达工具/中间件
- 评估"我该改哪一层"：路由层 / 编排层 / 执行层 / 流式层

## 设计方案（为什么这么设计）

### 链路八步

```
① 入口    nginx :2026 —— /api/langgraph/* 重写为 Gateway /api/*（SSE：proxy_buffering off）
② 鉴权    AuthMiddleware（JWT/OIDC/PAT 解析 → AuthContext）→ CSRFMiddleware（Double Submit）
③ 路由    POST /api/threads/{id}/runs/stream → routers/thread_runs.py
④ 编排    services.start_run()：normalize_input → merge_run_context_overrides（信任边界）
          → RunManager.create_or_reject（原子注册 + 租约心跳）→ 起后台 worker
⑤ 执行    run_agent()（runtime/runs/worker.py）：安装 runtime context → assemble_lead_agent(config)
          建图（每 run 一次）→ 挂 checkpointer/store → astream 驱动中间件链与工具循环
⑥ 流式    worker 把 LangGraph 流事件转换为 SSE 事件发布到 StreamBridge（Redis/内存）
⑦ 出口    sse_consumer 订阅 bridge，format_sse 逐条下发；Last-Event-ID 断线重连
⑧ 前端    useThreadStream 归一化（messages/values/task_*/artifact 增量）→ TanStack Query 状态
```

### 关键决策与不变量

1. **run 注册先于执行且原子**：`RunManager.create_or_reject` 在起 worker 前把 run 记录落库（幂等、冲突拒绝 `ConflictError`），保证"一个 thread 同时最多一个活跃 run"这类约束在崩溃/重启后仍可被 `reconcile_orphaned_inflight_runs` 收敛。
2. **执行与 HTTP 解耦**：worker 在后台任务里跑，SSE 端点只是 StreamBridge 的消费者。连接断开不杀 run；重连凭 `Last-Event-ID` 补齐缺口（StreamGap 心跳哨兵 + gap 事件）。
3. **run-context 信任边界**（安全核心）：客户端可写 `body.context` 与自由形 `body.config` 两个面。网关用三组 frozenset 管控字段流向（`services.py`）：
   - `_CONTEXT_CONFIGURABLE_KEYS`：agent 整形字段（model_name/thinking_enabled/agent_name/is_bootstrap/subagent_enabled/is_plan_mode 等）→ **双写** `configurable` + `context`
   - `_CONTEXT_INTERNAL_CALLER_KEYS`（`non_interactive`/`interaction_mode`）：仅内部认证调用方（scheduler/IM 渠道）可塞，外部塞入被 `strip_internal_context_keys` 抹除——防客户端伪造"无人值守"
   - `_CONTEXT_RUNTIME_ONLY_KEYS`（`github_token`/`disable_clarification`/`channel_name`）：只写 `context`，永不进会被 checkpoint 持久化的 `configurable`
   身份与沙箱生命周期字段无条件清除并从鉴权态重盖。
4. **每 run 重建图**：模型/工具/中间件随请求漂移，工厂不缓存编译结果（详见 [[agent-graph-factory]]）。
5. **事件流契约冻结**：SSE 事件名/载荷由 `contracts/run_event_stream_contract.json` 固化（8 类 category、seq 按 thread 严格递增、终态以 RunRow.status 为准），前后端与 IM 渠道共同消费，避免私改协议。
6. **来源标记**：每个 run/thread 带 `helix_origin`（extension/github/im_channel/mcp_notification/schedule），非交互来源的 run 会剥 `ask_clarification` 并受限上下文。

### 在链路中的位置（skill 映射）

| 链路步 | 深入 skill |
|---|---|
| ① | [[packaging-and-deployment]]（nginx 配置逐字复制件） |
| ② | [[auth]] |
| ③④⑦ | [[gateway-runs-and-sse]] |
| ④租约/⑥桥 | [[long-running-and-cancellation]] |
| ⑤建图 | [[agent-graph-factory]] → [[middleware-chain-design]] → [[tool-assembly-and-policy]] |
| ⑥事件定义 | [[observability-tracing]]（journal/events store） |
| ⑧ | [[frontend-streaming-protocol]] |
| 非交互入口 | [[scheduled-tasks]] / [[im-channels]] / [[extension-plugin-system]] |

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/app/gateway/app.py` | 1467 | FastAPI 装配：lifespan（引擎/检查点/渠道/调度器启动）、中间件栈、路由挂载 |
| `references/code/langgraph.json` | — | `lead_agent: helix.agents:make_lead_agent` 图注册 |
| `references/code/contracts/thread_origin_contract.json` | 12 | run/thread 来源标记词表 |
| `references/code/docker/nginx/nginx.conf` | 383 | 入口路由/SSE 缓冲关闭/大小限制 |

链上其余核心文件（services.py 2804 行、deps.py 1337 行、worker.py 3556 行、manager.py 2690 行、事件契约 491 行）逐字复制于相邻 skill 的 references，按上表"skill 映射"取用，不重复存放。

## 反模式与陷阱

- ❌ 在 SSE 端点里同步执行 agent —— 连接断开即杀死 run，且无法重连补流。正确：worker + StreamBridge 解耦。
- ❌ 客户端可写 `context` 直通 agent —— `non_interactive`/`github_token` 会被伪造。正确：网关侧 frozenset 白名单双写/抹除。
- ❌ 把短命密钥写进 `configurable` —— 会随 checkpoint 持久化落盘。正确：只写 `context`。
- ❌ 先起 worker 再注册 run —— 崩溃窗口产生孤儿 run，重连与对账失据。正确：`create_or_reject` 原子注册在前。
- ❌ 私改 SSE 事件名 —— 前端/IM/契约测试三方同时破。正确：事件面以 `run_event_stream_contract.json` 为准，legacy 别名在契约内声明。
- ❌ nginx 未关 `proxy_buffering` —— SSE 被缓冲到超时，前端表现为"卡住再一次性吐出"。

## 落地参考

**自测方向**
- 断开 SSE 再带 `Last-Event-ID` 重连：事件不丢不重（seq 严格递增可断言）
- 同 thread 并发第二个 run：被 `create_or_reject` 拒绝（409/ConflictError）
- 杀 worker 进程后重启：`reconcile_orphaned_inflight_runs` 把 in-flight run 收敛为终态
- 外部调用方塞 `context.non_interactive=true`：经 `strip_internal_context_keys` 后不生效；scheduler 内部调用生效

**调试日志串**：`Create Agent(`（工厂装配参数）、`run.end`/`run.error` 事件、`StreamGap`、`reconcile` 相关孤儿回收日志。

## 进一步阅读

- [[gateway-runs-and-sse]]（④⑦ 的全部源码）、[[long-running-and-cancellation]]（租约/取消/恢复全量实现）
- [[agent-graph-factory]]（⑤ 建图细节）、[[frontend-streaming-protocol]]（⑧ 消费端）
- 深读：`references/code/app/gateway/app.py` 的 lifespan 装配顺序
