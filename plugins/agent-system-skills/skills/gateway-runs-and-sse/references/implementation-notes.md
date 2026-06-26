# Implementation Notes — Gateway Runs & SSE

> 网关侧 Run 生命周期与 SSE 协议的实现细节。本文聚焦"为什么这样实现"，
> 路径以占位形式给出，业务命名抽离。

---

## 一、组件地图

| 组件 | 位置 | 职责 |
|------|------|------|
| `RunManager` | `<harness-pkg>/runtime/runs/manager.py` | 内存 Run 注册表 + 可选 RunStore 持久化 |
| `RunRecord` | 同上 | 单次 Run 的可变态（status、task、abort_event、token 累计） |
| `run_agent()` | `<harness-pkg>/runtime/runs/worker.py` | 后台 asyncio.Task，驱动 graph.astream → StreamBridge |
| `StreamBridge` | `<harness-pkg>/runtime/stream_bridge/base.py` | 解耦 Producer（worker）↔ Consumer（SSE 端点）的事件桥 |
| `MemoryStreamBridge` | `<harness-pkg>/runtime/stream_bridge/memory.py` | 按 run_id 维护事件 ring buffer，支持 Last-Event-ID 重放 |
| `RunEventStore` | `<harness-pkg>/runtime/events/store/base.py` | 持久化事件流（message + trace 两类） |
| `RunJournal` | `<harness-pkg>/runtime/journal.py` | LangChain CallbackHandler，捕获 token usage / lifecycle 写入 EventStore |
| `RunStore` | `<harness-pkg>/runtime/runs/store/` | 持久化 Run 元数据（status、token、message_count） |

路由层：`<app-pkg>/gateway/routers/` 下的 `runs.py`（无 thread）/ `thread_runs.py`（thread-scoped），
仅做 HTTP 适配，业务逻辑全部下沉到 `<app-pkg>/gateway/services.py`。

---

## 二、Run 生命周期与并发策略

`RunManager.create_or_reject()` 在同一把 asyncio.Lock 内完成 in-flight 检查 + 插入，
消除 TOCTOU。`multitask_strategy` 三态：

- `reject`：发现 pending/running 抛 `ConflictError`
- `interrupt`：保留 checkpoint，cancel 旧 task
- `rollback`：恢复 pre-run checkpoint 快照，旧 task 标记为 error

`cancel()` 是幂等的——已 `interrupted` 返回 True，其他终态返回 False。
Worker 在 `astream` 循环里每次轮询 `record.abort_event.is_set()`，命中即跳出，
在 finally 里根据 `abort_action` 选择 `set_status(interrupted)` 或 rollback。

`shutdown(timeout=5.0)` 在进程退出前 drain in-flight Run：先 `cancel()` 触发 Worker
的 abort 分支，再 `asyncio.wait(tasks, timeout)`，让仍能完成的 Run 写完最后一个 checkpoint
后再关 checkpointer 连接池，否则 langgraph 内部任务的 `finally: await aput(...)`
会撞到已关闭的连接池抛出无法捕获的异常。Drain 期间只对**未自然结束**的 Run
标 `interrupted`——自己跑完的 Run 保留 success 终态，避免 blanket overwrite。

`reconcile_orphaned_inflight_runs()` 在 SQLite 后端重启后调用：所有持久化为
pending/running 但本进程无 task 的行被标记为 error，避免 UI 显示永久"运行中"。

**有界持久化重试**：`_call_store_with_retry()` 对 SQLite `database is locked` /
`SQLITE_BUSY` / `SQLITE_LOCKED` 做指数退避（默认 5 次，0.05s→1.0s）。它专门
解开 SQLAlchemy 包装层、`exc.__cause__`、`exc.__context__` 链，避免被嵌套
异常吃掉真正的可重试信号。永久错误（schema 不匹配、磁盘满）直接上抛。

---

## 三、SSE 协议格式

帧格式严格遵循 LangGraph Platform 线协议，前端 `useStream` Hook 才能开箱即用：

```
event: <name>\n
data: <json>\n
id: <event_id>\n
\n
```

事件 ID 采用 `<ts_millis>-<seq>` 形式（见 `MemoryStreamBridge._next_id`），
`seq` 在 Run 内单调递增、等于事件绝对 offset。客户端断线重连时通过
`Last-Event-ID` 头传回，桥侧用 O(1) 算术定位回放起点：
`local_index = seq - stream.start_offset`，越界或被 ring buffer 淘汰则
退化为"从最早保留事件重放"。

`stream_mode` 列表 → LangGraph `astream(stream_mode=[...])` 的映射：

- `messages-tuple` → LangGraph 的 `messages`
- `events` → 跳过（需要 `astream_events`，与 `values` 不兼容）
- 其他 1:1 透传

单 mode 时 `astream` 产出 raw chunk；多 mode 或 subgraph 时产出 `(mode, chunk)` 元组，
由 `_unpack_stream_item` 统一拆包。每帧通过 `serialize(chunk, mode=...)`
脱敏后调用 `bridge.publish(run_id, sse_event, payload)`。

**心跳与代理超时**：bridge 在 `heartbeat_interval` 秒（默认 15s）无事件时 yield
`HEARTBEAT_SENTINEL`，SSE 层译成 `: heartbeat\n\n` 注释帧——浏览器无视、
反代不算"空闲"，绕过 Nginx 60s / 云负载均衡的 timeout。响应头同时下发
`X-Accel-Buffering: no` 让 Nginx 不缓冲、`Cache-Control: no-cache` 让中间
节点不缓存。

**`Content-Location` 头**：stateless `/api/runs/stream` 自动建临时 thread，
通过响应头 `Content-Location: /api/threads/{tid}/runs/{rid}` 告诉客户端
最终落点，方便后续 polling / cancel / regenerate 使用 thread-scoped 端点。

---

## 四、断线策略与 `on_disconnect`

请求体 `on_disconnect` 决定客户端断开 SSE 后 Run 的命运：

- `cancel`（默认）：HTTP 连接关闭立即触发 `RunManager.cancel(run_id)`
- `continue`：Run 后台继续跑完，结果可通过 `runs/{rid}/messages` 或重连 `runs/{rid}/join` 拉取

`POST /wait`（无论 thread-scoped 还是无 thread）调用 `wait_for_run_completion()`
而非裸 `await record.task`——后者无法感知 HTTP disconnect，导致客户端早已断开但
worker 仍在烧 token。前者通过订阅 bridge 的 END_SENTINEL 配合 disconnect 检测
正确触发取消。

心跳：bridge 在 `heartbeat_interval` 秒（默认 15s）无事件时 yield `HEARTBEAT_SENTINEL`，
SSE 层译成 `: heartbeat\n\n` 注释帧，绕过反代/负载均衡的空闲超时。

**`Last-Event-ID` 与 `join` 端点的配合**：浏览器原生 EventSource 自动断线重连
时携带 `Last-Event-ID`，但若客户端主动关闭并隔了好几秒才回来（页面刷新），
EventSource 实例已销毁，浏览器不会自动重发——这时必须显式调
`GET /runs/{rid}/join?last_event_id=<id>` 重建连接，由前端管理这段 id。

---

## 五、持久化与重连

Run 元数据双写：内存 `_runs` + 可选 `RunStore`（SQL 或 memory）。
内存命中优先，store 仅做历史 hydration。`_call_store_with_retry()` 对 SQLite
`database is locked` / `SQLITE_BUSY` 做有界指数退避（默认 5 次，0.05s→1.0s），
保护 status 收尾不被瞬时锁竞争挤掉，但永久错误仍上抛。

**索引一致性不变量**：`_runs_by_thread` 是按线程聚合的二级索引，必须与
`_runs` 在同一把 lock 下"同步变更，不在中间 await"。`_thread_records_locked()`
依赖这条不变量做 O(per-thread) 查找，避免每次都扫描所有进程内 Run。
`record := self._runs.get(run_id)` 的过滤是"防御性而非对账"——能丢掉索引里
残留但 `_runs` 已删的 id，但反向漏注册的 Run 会被静默跳过。

EventStore 写入分两类（`category`）：

- `message` —— 前端展示用（用户输入、AI 最终回复、tool result）
- `trace` —— 调试/审计用（token usage 快照、lifecycle、middleware 审计）

`trace` 类按 `max_trace_content`（默认 10KB）截断，metadata 加
`content_truncated=true` 与 `original_byte_length`，DB 不被巨型 prompt 撑爆。
非 str 内容 JSON 序列化后回读时按 `metadata.content_is_json` flag 反序列化。

`seq` 在线程内严格递增。Postgres 用 `pg_advisory_lock` 串行化 writer
（不能对 `MAX()` 加 `FOR UPDATE`），其他方言走行锁。

Run 完成 60s 后触发 `bridge.cleanup(run_id, delay=60)` 释放 ring buffer，
给迟到的重连留窗口；Run 记录本身 300s 后从 `_runs` 摘除。`store-only` 标记的
Run 已经从内存摘除，只能从持久化层重建为只读 RunRecord——这类 Run 在
list_by_thread 里依然可见，但调用 `cancel()` 会返回 409（本进程无 task 可控）。

---

## 六、设计权衡与陷阱

1. **不暴露 `events` mode**：开源 LangGraph JS API Server 通过 checkpoint callback
   同时产出 values + events，Python 公开 API 没有这层，强行混用会丢 `values` 快照。
   worker 检测到 `events` 在请求列表里只记一条 info 日志，不报错。

2. **rollback 快照在启动期捕获**：`run_agent` 入口处 `aget_tuple()` 拿当前 checkpoint
   做深拷贝。如果捕获失败（`snapshot_capture_failed=True`），后续 rollback 请求
   退化为"删整个线程"，避免恢复半成品状态。

3. **store-only 记录的可见性悖论**：list_by_thread 把 store 行 hydrate 成只读 RunRecord
   塞回结果，但 `cancel()` 找不到本地 task 时返回 409——历史可读，但不可控。

4. **runtime context 写入路径**：`_build_runtime_context()` 永远以 `thread_id`/`run_id`
   作为强制键，调用方 `config['context']` 仅能通过 `setdefault` 补充，
   保护框架不变量。LangGraph 1.1+ 通过 `__pregel_runtime` 把 context merge 进 ToolRuntime。

5. **`finish_reason=content_filter` 防护**：Worker 扫每个 chunk 找
   `additional_kwargs.error_fallback` 标记，命中后将 Run 终态判定为
   `error` 而非 `success`，错误信息从 metadata 的 `error_detail` / `error_reason` 提取。
   扫描走快路径——`values` chunk 只看顶层 `messages` 列表，`updates` chunk 才做深递归。

6. **runtime context 的 setdefault 语义**：调用方 `config['context']` 可携带
   `agent_name` 等扩展键，但 `thread_id`/`run_id` 永远以 Worker 注入的值为准。
   `_install_runtime_context()` 用 `setdefault` 合并，让 LangGraph 1.1+ 的
   `parent_runtime.merge(...)` 看到一致的强制键。Tracing 元数据（langfuse
   `session_id` / `user_id` / `trace_name` / `tags`）同样走 `setdefault`，
   外部覆盖优先于自动生成。

7. **`store-only` Run 的 cancel 死区**：list_by_thread 把 store 行 hydrate
   成只读 RunRecord 塞回结果，但 `cancel()` 找不到本地 task 时返回 409——
   历史可读，但跨 Worker 不可控。生产环境多 Worker 部署时这条限制必须
   反馈到 UI 文案，否则用户会困惑"为什么这个 Run 取消不掉"。

---

[[frontend-streaming-protocol]] · [[multi-user-isolation]] · [[config-and-hot-reload]] · [[thread-meta-and-history]] · [[checkpointer-and-state]]
