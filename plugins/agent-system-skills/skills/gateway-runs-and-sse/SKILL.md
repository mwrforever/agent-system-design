---
name: gateway-runs-and-sse
description: 设计 agent 后端 Gateway 的 Run 生命周期与 SSE 流式--RunManager 注册表（create/get/list/cancel + multitask 抢占）、run_agent worker（stream_mode 映射 + checkpointer 协作 + 隐式 goal 续跑 + 标题/线程状态同步）、LangGraph Platform 兼容 SSE 协议（useStream 直连 + Content-Location + 心跳）、路由薄服务厚（start_run/sse_consumer/wait_for_run_completion 同源复用 IM 通道与嵌入式客户端）。当你要实现 LangGraph Platform 兼容的 runs API、排查 stream_mode 到 SSE 事件名映射、调 run config 的 configurable/context 双写、或理解 worker 与 checkpointer 的协作时序时调用本 skill。
---

## 何时用

- 你在搭 agent 的 HTTP 后端（FastAPI / Litestar / 类似），要兼容 LangGraph Platform runs API 协议让前端 `useStream` 直连
- 想把 SSE 流式响应与 RunManager 注册表、checkpointer 串成一个完整 run 生命周期
- 要理解 `stream_mode` 列表（`values` / `messages-tuple` / `updates` / `custom` ...）如何映射到 SSE 事件名
- 要排查 run config 的 `configurable` vs `context` 双写、`agent_name` 路由、`recursion_limit` 钳位
- 想看 worker 如何与 checkpointer 协作（pre-run 快照、runtime context 注入、goal 续跑、标题同步）
- 想支持 create / stream / wait / join / cancel / list / get / regenerate 端点

> cancel/rollback 深度、on_disconnect 断连策略、wait_for_run_completion 的 stale 防护、孤儿 run 恢复、shutdown drain 的完整机制见 [[long-running-and-cancellation]]。本 skill 聚焦"请求如何变成 run、run 如何流式回传"的管道视图。

## 设计方案（为什么这么设计）

### 核心矛盾：LangGraph Platform 协议兼容 vs 框架内部 stream_mode

前端用 `@langchain/langgraph-sdk` 的 `useStream` Hook 消费 SSE，它期待固定的事件名（`metadata` / `values` / `messages` / `updates` / `custom` / `error` / `end`）和固定的帧格式。但 agent 内部跑的是 LangGraph 的 `graph.astream(stream_mode=[...])`，它的 mode 名与 SSE 事件名**几乎但不完全**一致（`messages-tuple` vs `messages`、`events` 不可用）。Gateway 必须在两者之间做一层忠实映射，既不丢语义又不破坏 SDK 契约。

### 解法：路由薄 + 服务厚 + worker 驱动

三层各司其职：

- **路由层**（`thread_runs.py`）：只做 HTTP 适配--参数校验 + 权限装饰器 + 调 service + 包 `StreamingResponse`。无业务逻辑。
- **服务层**（`services.py`）：`start_run` / `sse_consumer` / `wait_for_run_completion` / `build_run_config` / `normalize_stream_modes` / `format_sse` 等公共逻辑。同一 service 同时给 HTTP 路由、IM 通道、嵌入式客户端复用，避免三处各写一遍 run 生命周期。
- **worker**（`run_agent`）：后台 `asyncio.Task` 驱动 `graph.astream`，每 chunk 经 `serialize` 脱敏后 `bridge.publish` 到 StreamBridge。

```python
# 伪代码：三层协作
@router.post("/{thread_id}/runs/stream")            # 路由层（薄）
async def stream_run(thread_id, body, request):
    record = await start_run(body, thread_id, request)           # 服务层
    return StreamingResponse(sse_consumer(bridge, record, ...),  # 服务层
        media_type="text/event-stream",
        headers={"X-Accel-Buffering": "no",
                 "Content-Location": f"/api/threads/{thread_id}/runs/{record.run_id}"})

async def start_run(body, thread_id, request):       # 服务层（厚）
    record = await run_mgr.create_or_reject(thread_id, ..., multitask_strategy=body.multitask_strategy)
    config = build_run_config(thread_id, body.config, body.metadata, assistant_id=body.assistant_id)
    merge_run_context_overrides(config, body.context, internal=is_internal_caller)
    record.task = asyncio.create_task(run_agent(bridge, run_mgr, record, ctx=run_ctx, ...))
    return record

async def run_agent(bridge, run_manager, record, *, ctx, agent_factory, ...):  # worker（后台 task）
    await run_manager.set_status(run_id, RunStatus.running)
    async for chunk in agent.astream(graph_input, config=config, stream_mode=lg_modes):
        if record.abort_event.is_set(): break
        await bridge.publish(run_id, _lg_mode_to_sse_event(mode), serialize(chunk, mode=mode))
    # 终态 + finally 收尾（见 [[long-running-and-cancellation]]）
```

### stream_mode 映射：1:1 + 两处归一化

LangGraph `astream` 的合法 mode：`values` / `updates` / `checkpoints` / `tasks` / `debug` / `messages` / `custom`。SSE 事件名与之 **1:1 同名**（`_lg_mode_to_sse_event(mode) -> mode`），无需翻译表。两处归一化：

```python
# 伪代码：stream_mode 归一化
# 1. 服务层：客户端可能传 str 或 list，归一为 list
def normalize_stream_modes(raw) -> list[str]:
    if raw is None: return ["values"]
    if isinstance(raw, str): return [raw]
    return raw or ["values"]

# 2. worker 入口：messages-tuple -> messages；events 跳过
_VALID_LG_MODES = {"values","updates","checkpoints","tasks","debug","messages","custom"}
lg_modes = []
for m in requested_modes:
    if m == "messages-tuple": lg_modes.append("messages")   # 客户端协议名 -> LangGraph 内部名
    elif m == "events": continue                            # 需 astream_events，与 values 不兼容
    elif m in _VALID_LG_MODES: lg_modes.append(m)
# 单 mode: astream 产 raw chunk；多 mode/subgraph: 产 (mode, chunk) 元组，_unpack_stream_item 拆包
```

**为何 `events` 被跳过**：开源 LangGraph JS API Server 通过内部 checkpoint callback 同时产出 `values` + `events`，Python 公开 API 没有这层。强行混用 `astream_events` 与 `astream(values)` 会丢 `values` 全量快照。worker 检测到 `events` 在请求列表里只记一条 info 日志，不报错。

### run config 双写：configurable + context（LangGraph 0.6 / 1.1 过渡期）

LangGraph >= 0.6 引入 `context` 作为传递线程级数据的推荐方式，且**拒绝同时含 `configurable` 和 `context` 的请求**。LangGraph >= 1.1.9 的 `ToolRuntime.context` 不再 fallback 到 `configurable`。但历史消费者仍读 `configurable`。解法：**白名单字段双写两边**。

```python
# 伪代码：build_run_config + merge_run_context_overrides
def build_run_config(thread_id, request_config, metadata, *, assistant_id=None):
    config = {"recursion_limit": 100}            # 默认值，后续钳位
    if request_config and "context" in request_config:
        # 剥离 __ 前缀内部键（调用方不可播种框架私有运行时通道）
        context = {k:v for k,v in request_config["context"].items() if not k.startswith("__")}
        context["thread_id"] = thread_id
        config["context"] = context
        config["configurable"] = {"thread_id": thread_id}   # checkpointer 仍按 configurable.thread_id 寻址
    else:
        config["configurable"] = {"thread_id": thread_id, **request_config.get("configurable", {})}
    if "recursion_limit" in request_config:                 # 钳位防 DoS
        config["recursion_limit"] = _clamp_recursion_limit(request_config["recursion_limit"], max_limit)
    if assistant_id and assistant_id != "lead_agent":        # assistant_id -> agent_name 路由（双写）
        normalized = re.fullmatch(r"[a-z0-9-]+", assistant_id.lower().replace("_","-"))
        config["configurable"]["agent_name"] = config["context"]["agent_name"] = normalized
    return config

# 白名单双写：model_name / thinking_enabled / agent_name / ... 同时进 configurable + context
_CONTEXT_CONFIGURABLE_KEYS = frozenset({"model_name","mode","thinking_enabled","reasoning_effort",
    "is_plan_mode","subagent_enabled","max_concurrent_subagents","agent_name","is_bootstrap"})
_CONTEXT_INTERNAL_CALLER_KEYS = frozenset({"non_interactive"})     # 仅内部认证调用者（scheduler 路径）
_CONTEXT_RUNTIME_ONLY_KEYS = frozenset({"github_token","disable_clarification"})  # 仅进 context 不落盘
```

**为何 `github_token` 只进 `context`**：`configurable` 会被 checkpointer 持久化到 checkpoint store。短期的 GitHub App installation token 落盘是安全风险。`context` 是运行时通道，不落盘，secrets 走这里。

**为何剥 `__` 前缀键**：`__slash_skill_secret_source` 等是框架私有运行时通道。调用方塞入可伪造内部状态（绕过 skill enabled/allowlist 门），必须剥离。

### checkpointer 协作（worker 视角）

worker 与 checkpointer 的四个协作点：

1. **pre-run 快照**（回滚锚点）：`run_agent` 入口 `checkpointer.aget_tuple(...)` 拿最新 checkpoint，`copy.deepcopy` 冻结成不可变快照。深拷贝必须--run 期间 checkpointer 持续写新 checkpoint，浅拷贝会被污染。快照失败降级（`snapshot_capture_failed=True`），rollback 时跳过不卡 run。深度机制见 [[long-running-and-cancellation]]。
2. **runtime context 注入**：`_build_runtime_context` 以 `thread_id`/`run_id` 为强制键，调用方 `config['context']` 仅 `setdefault` 补充。LangGraph 1.1+ 经 `__pregel_runtime` 把 context merge 进 `ToolRuntime.context`，中间件/工具由此读到线程级数据。
3. **goal 续跑**（隐式多轮）：run 的可见 turn 跑完后，worker 读 checkpoint 里的 `goal` 状态，若仍 `active` 且未达上限，evaluator 评估是否满意；不满意则构造隐藏的 goal continuation message 再跑一轮。整个过程对客户端透明（同一 run_id，事件流不断）。goal 写入经 `goal_thread_lock` 串行化 + `expected_checkpoint_id` 乐观锁，racing 的用户消息或 `/goal clear` 会让 evaluator stand down。
4. **标题 / 线程状态同步**：worker `finally` 从 checkpoint 读 `channel_values.title` 同步到 `thread_store.display_name`；按 run 终态把 `threads_meta.status` 刷成 `idle`（success）或对应终态。

### multitask 策略（create_or_reject 持锁消除 TOCTOU）

`RunManager.create_or_reject` 在同一把 `asyncio.Lock` 内完成"检查在途 + 插入新 run + 抢占旧 run"，规避分立 `has_inflight` + `create` 的竞争窗口。三策略：

| 策略 | 行为 | checkpoint |
|---|---|---|
| `reject`（默认） | thread 已有 pending/running/finalizing -> `ConflictError` -> 409 | - |
| `interrupt` | abort 旧 run，新 run 接续 | 保留旧 run 中途 checkpoint |
| `rollback` | abort 旧 run，新 run 从干净状态开始 | 回滚到 pre-run checkpoint |

`cancel()` 是幂等的--已 `interrupted` 返回 `True`，其他终态返回 `False`。`abort_action` 必须先于 `abort_event` 设置（rollback/interrupt 共用同一 event，靠 action 区分）。cancel/rollback 的完整机制（协作式取消、pre-run 快照恢复、`CancelledError` 同路径）见 [[long-running-and-cancellation]]。

### SSE 协议格式（LangGraph Platform 兼容）

```python
# 伪代码：SSE 帧格式（useStream Hook 开箱即用的前提）
def format_sse(event, data, *, event_id=None) -> str:
    payload = json.dumps(data, default=str, ensure_ascii=False)
    parts = [f"event: {event}", f"data: {payload}"]
    if event_id: parts.append(f"id: {event_id}")
    parts.append(""); parts.append("")   # 空行 + 帧分隔
    return "\n".join(parts)
```

- **心跳**：bridge 在 `heartbeat_interval`（默认 15s）无事件时 yield `HEARTBEAT_SENTINEL`，SSE 层译成 `: heartbeat\n\n` 注释帧--浏览器无视、反代不算"空闲"，绕过 nginx 60s / 云 LB 超时。
- **响应头**：`X-Accel-Buffering: no`（nginx 不缓冲）+ `Cache-Control: no-cache` + `Content-Location: /api/threads/{tid}/runs/{rid}`（SDK 用贪婪正则提取 run_id）。
- **`END_SENTINEL`**：worker `finally` 末尾 `bridge.publish_end(run_id)` -> `subscribe` yield `END_SENTINEL` -> `sse_consumer` 发 `end` 帧收尾。跨进程经 Redis `{"kind":"end"}` round-trip。

### 关键不变量（违反则协议崩塌或行为错乱）

1. **路由薄服务厚**：路由只做 HTTP 适配；run 生命周期逻辑全在 services，IM 通道 / 嵌入式客户端复用同一 service。
2. **stream_mode 1:1 同名**：`_lg_mode_to_sse_event` 是恒等映射；归一化只在入口（`messages-tuple` -> `messages`、`events` 跳过）。
3. **白名单字段双写 configurable + context**：LangGraph 0.6 拒绝同传、1.1 不 fallback，双写保证两类消费者都能读到。
4. **secrets 只进 context 不进 configurable**：`configurable` 被 checkpoint 持久化，token 落盘是安全风险。
5. **`__` 前缀键剥离**：调用方不可播种框架私有运行时通道（skill secret-binding / active-secret / journal）。
6. **`recursion_limit` 钳位**：客户端值不得直信，钳到 `AppConfig.max_recursion_limit`（默认 1000）防 DoS。
7. **pre-run 快照深拷贝**：浅拷贝会被 run 期间新 checkpoint 污染，rollback 读到脏状态。
8. **二级索引原子**：`_runs` 与 `_runs_by_thread` 同一把 `_lock` 内串行写入，无 `await` 跨越。
9. **`agent_name` 双写**：custom agent 的名字同时进 `configurable` 和 `context`，否则 `make_lead_agent` 读不到、静默跑成默认 agent。

### 在端到端链路中的位置

本 skill 处于端到端链路的 **③路由 + ⑦流式**（见 [[e2e-request-lifecycle]]）：③路由 `start_run` -> `RunManager.create_or_reject`（multitask 策略）-> `build_run_config`（双写 + 钳位）-> spawn `run_agent` worker -> ⑦worker `astream` 流循环 `publish` -> StreamBridge -> `sse_consumer` 订阅 -> SSE 帧。本 skill 是"请求如何变成 run、run 如何流式回传"的管道视图；run 的"长任务化、取消回滚、断连续传"深度见 [[long-running-and-cancellation]]。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/runtime/runs/schemas.py` | `RunStatus` / `DisconnectMode` 枚举 | [run-manager.md](./references/code/run-manager.md) |
| `core/helix/runtime/runs/manager.py` | `RunRecord` + `RunManager`（注册表 + create/get/list + create_or_reject multitask + cancel + 状态机 + 持久化重试）+ `ConflictError` / `UnsupportedStrategyError` | [run-manager.md](./references/code/run-manager.md) |
| `core/helix/runtime/runs/worker.py` | `run_agent`（流循环 + stream_mode 映射 + checkpointer 协作 + goal 续跑 + 标题同步）+ `_lg_mode_to_sse_event` + `_unpack_stream_item` + `_SubagentEventBuffer` | [run-agent-worker.md](./references/code/run-agent-worker.md) |
| `gateway/gateway/services.py` | `start_run` + `build_run_config` + `merge_run_context_overrides` + `normalize_stream_modes` + `normalize_input` + `format_sse` + `sse_consumer` + `wait_for_run_completion` | [gateway-services.md](./references/code/gateway-services.md) |
| `gateway/gateway/routers/thread_runs.py` | create/stream/wait/join/cancel/list/get/regenerate/messages/events/token-usage 端点 | [gateway-endpoints.md](./references/code/gateway-endpoints.md) |

### 模块入口与索引

**RunManager 注册表**（完整源码见 [run-manager.md](./references/code/run-manager.md)）：
- `create` / `create_or_reject`：建 pending run + 持久化；`create_or_reject` 持锁跨"检查在途 + 插入 + 抢占"，消除 TOCTOU。`_persist_new_run_to_store` 失败则 `finally` 回滚内存记录（run 可见性边界：内存可见前提是 store 行已存在）。
- `get` / `list_by_thread`：内存优先，store hydration 兜底；`list_by_thread` 合并内存 + store 去重后按 `created_at` 逆序截断 `limit`。
- `cancel`：幂等（已 interrupted 返回 True）；设 `abort_action` + `abort_event` + `task.cancel()`，不持锁做 IO（回滚留给 worker 终结路径）。
- `set_status` / `update_run_progress` / `update_run_completion` / `update_model_name`：状态机 + token/消息快照持久化；`update_run_progress` 守卫 `status == running` 防终态后污染。
- `_thread_records_locked`：经 `_runs_by_thread` 二级索引 O(per-thread) 查找，免全表扫描。
- `_call_store_with_retry`：SQLite `database is locked` / `SQLITE_BUSY` / `SQLITE_LOCKED` 有界指数退避（默认 5 次 50ms->1s），解 `__cause__`/`__context__`/`orig` 链；永久错误上抛。
- `reconcile_orphaned_inflight_runs` / `shutdown`：见 [[long-running-and-cancellation]]。

**run_agent worker**（完整源码见 [run-agent-worker.md](./references/code/run-agent-worker.md)）：
- 流循环 `_stream_once`：单 mode `astream` 产 raw chunk；多 mode/subgraph 产 `(mode, chunk)` 元组，`_unpack_stream_item` 拆包。每 chunk 检查 `abort_event` -> break，`_lg_mode_to_sse_event(mode)` 映射后 `bridge.publish`。
- `_lg_mode_to_sse_event`：恒等映射（`mode -> mode`）；`messages-tuple` 在入口归一化为 `messages`，`events` 跳过。
- checkpointer 协作：pre-run 快照 `deepcopy`（回滚锚点）；runtime context `_build_runtime_context` + `_install_runtime_context` 注入 `__pregel_runtime`；`finally` 标题同步 + 线程状态同步。
- goal 续跑：`_prepare_goal_continuation_input` 读 checkpoint goal，evaluator 评估，不满意构造隐藏 continuation message 再跑一轮；`goal_thread_lock` + `expected_checkpoint_id` 乐观锁防 racing。
- `_SubagentEventBuffer`：subagent `task_*` 事件批量持久化（`FLUSH_THRESHOLD=25` / 终态 eager flush），免 per-step `put()` 串行化锁。
- `_extract_llm_error_fallback_message`：扫 chunk 找 `helix_error_fallback` 标记，命中则 run 终态判 `error`；`values` chunk 只扫顶层 `messages`（快路径），`updates` chunk 深递归。
- rollback / `CancelledError` 同路径 / `publish_end` finally：见 [[long-running-and-cancellation]]。

**Gateway 服务层**（完整源码见 [gateway-services.md](./references/code/gateway-services.md)）：
- `start_run`：`create_or_reject`（multitask）-> thread_meta upsert -> `build_run_config` -> `apply_checkpoint_to_run_config` -> `merge_run_context_overrides` -> `strip_internal_context_keys`（非内部调用者）-> `inject_authenticated_user_context` -> `asyncio.create_task(run_agent(...))`。thread ownership 校验在 run 创建前（stateless 端点 path param 不够）。
- `build_run_config`：`configurable` / `context` 分叉（LangGraph 0.6 兼容）+ `recursion_limit` 钳位 + `assistant_id` -> `agent_name` 路由 + `__` 前缀键剥离。
- `merge_run_context_overrides`：白名单双写 configurable + context；`_CONTEXT_INTERNAL_CALLER_KEYS`（`non_interactive`）仅内部调用者；`_CONTEXT_RUNTIME_ONLY_KEYS`（`github_token` / `disable_clarification`）仅进 context。
- `normalize_input`：dict -> message 经 `convert_to_messages`（保 `additional_kwargs` / `id` / 非 human 角色），畸形 entry 抛 400 而非 500。
- `format_sse` / `sse_consumer` / `wait_for_run_completion`：SSE 帧格式 + on_disconnect finally + END_SENTINEL 收尾。`wait_for_run_completion` 不 `await record.task`（issue #3265，见 [[long-running-and-cancellation]]）。

**HTTP 端点**（完整源码见 [gateway-endpoints.md](./references/code/gateway-endpoints.md)）：
- `POST /{tid}/runs` / `POST /{tid}/runs/stream` / `POST /{tid}/runs/wait`：create / create+stream / create+block。
- `GET /{tid}/runs` / `GET /{tid}/runs/{rid}`：list / get。
- `POST /{tid}/runs/{rid}/cancel`：cancel（`action=interrupt|rollback`，`wait=true` 阻塞到停）。
- `GET /{tid}/runs/{rid}/join` / `GET|POST /{tid}/runs/{rid}/stream`：重连 / cancel-then-stream（SDK `joinStream` + stop 按钮）。
- `POST /{tid}/runs/regenerate/prepare`：scan run_events 定位 message_id -> 找前置 checkpoint -> 返回干净 input + checkpoint_id。
- `GET /{tid}/messages` / `GET /{tid}/runs/{rid}/messages` / `GET /{tid}/runs/{rid}/events` / `GET /{tid}/token-usage`：消息 / 事件 / token 聚合。

## 反模式与陷阱

- ❌ **路由层写业务逻辑** -> IM 通道 / 嵌入式客户端各写一遍 run 生命周期，三处分叉。修复：逻辑下沉 services，路由只做 HTTP 适配。
- ❌ **`agent_name` 只写 `configurable` 不写 `context`** -> LangGraph 1.1+ `ToolRuntime.context` 不 fallback，`setup_agent` 等工具读不到 -> 静默跑成默认 agent。修复：白名单字段双写两边。
- ❌ **`github_token` 写进 `configurable`** -> `configurable` 被 checkpointer 持久化，短期 installation token 落盘。修复：secrets 只进 `context`（`_CONTEXT_RUNTIME_ONLY_KEYS`）。
- ❌ **不剥 `__` 前缀键** -> 调用方伪造 `__slash_skill_secret_source` 绕过 skill enabled/allowlist 门。修复：`build_run_config` 剥离 `__` 前缀键。
- ❌ **直信客户端 `recursion_limit`** -> 单 run 跑无界 super-step，runaway LLM 成本 / DoS。修复：`_clamp_recursion_limit` 钳到 `AppConfig.max_recursion_limit`。
- ❌ **`events` mode 强行混用 `astream_events` + `astream(values)`** -> 丢 `values` 全量快照。修复：`events` 跳过 + 记 info 日志。
- ❌ **pre-run 快照浅拷贝** -> run 期间新 checkpoint 污染快照，rollback 读脏状态。修复：`copy.deepcopy` checkpoint/metadata/pending_writes。
- ❌ **SSE 没设 `X-Accel-Buffering: no`** -> nginx 缓冲整段流，前端只能等结束一次性收到。修复：响应头显式 `X-Accel-Buffering: no` + `Cache-Control: no-cache`。
- ❌ **不发心跳** -> nginx / 浏览器 60s 静默关 SSE。修复：`heartbeat_interval=15.0` 无事件 yield `HEARTBEAT_SENTINEL` -> `: heartbeat\n\n`。
- ❌ **`normalize_input` 手搓只转 content** -> `additional_kwargs`（上传文件元数据）/ `id` / 非 human 角色丢失。修复：`convert_to_messages` 保完整 message 结构。
- ❌ **`update_run_progress` 终态后还写** -> token 累计污染已 success/error 的快照。修复：`should_persist = record.status == RunStatus.running` 守卫。
- ❌ **二级索引 `_runs_by_thread` 与 `_runs` 跨 `await` 变更** -> 索引与主表不一致，`_thread_records_locked` 漏注册的 run 被静默跳过。修复：同一把 `_lock` 内串行写，无 `await` 跨越。
- ❌ **`_persist_new_run_to_store` 失败不回滚内存记录** -> run 在内存可见但 store 无行（可见性边界泄漏）。修复：`finally` 检 `persisted` 未 True 则 pop + unindex。
- ❌ **stateless 端点不校验 thread ownership** -> `@require_permission(owner_check=True)` 从 path param 解析，stateless 端点 thread_id 在 body，绕过校验 -> 跨用户起 run。修复：`start_run` 内 `thread_store.check_access` 前置。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 默认 | 说明 |
|---|---|---|---|
| `multitask_strategy` | `RunCreateRequest` | `"reject"` | 同 thread 已有活跃 run：reject(409)/interrupt(保留 ckpt)/rollback(回滚) |
| `on_disconnect` | `RunCreateRequest` | `"cancel"` | 客户端断 -> cancel task；`continue` 留后台跑供 `/join` |
| `stream_mode` | `RunCreateRequest` | `["values"]` | 请求的 mode 列表；`messages-tuple` 归一为 `messages`，`events` 跳过 |
| `stream_subgraphs` | `RunCreateRequest` | `false` | 是否含子图事件（影响 astream 产元组 vs raw） |
| `recursion_limit` | run config | 100 | 主代理 super-step 上限（钳到 `max_recursion_limit`） |
| `max_recursion_limit` | `AppConfig` | 1000 | 客户端 `recursion_limit` 的钳位上限 |
| `heartbeat_interval` | `bridge.subscribe` | 15s | 无事件心跳间隔（防 nginx/浏览器 60s 静默关） |
| `PersistenceRetryPolicy` | `RunManager` | 5 次 / 50ms->1s | SQLite 锁重试（仅 `SQLITE_BUSY/LOCKED`） |
| `REGENERATE_HISTORY_SCAN_LIMIT` | `thread_runs.py` | 200 | regenerate 扫描 run_events / checkpoints 的上限 |

**关键日志串**

- `Run created: run_id=%s thread_id=%s` - 注册 run
- `Run %s -> %s` - 每次 `set_status`（状态机）
- `Run %s: streaming with modes %s (requested: %s)` - stream_mode 落定（归一化后 vs 请求）
- `Run %s: 'events' stream_mode not supported in gateway ... Skipping.` - events 跳过
- `build_run_config: clamped client recursion_limit %r -> %d (max %d)` - 钳位生效
- `build_run_config: client sent both 'context' and 'configurable'; preferring 'context'` - 双传告警
- `Run %s model_name=%s` - 模型名更新（agent 解析后可能与请求不同）
- `Run %s continuing thread %s for active goal (%d/%d)` - goal 续跑
- `Transient persistence failure during %s for run %s (attempt %d/%d); retrying` - store 背压重试

**自测方向**

- **stream_mode 映射**：请求 `["values","messages-tuple"]`，断言 worker `lg_modes == ["values","messages"]`；请求含 `"events"` 断言被跳过且记 info。
- **单/多 mode 拆包**：单 mode 断言 `astream` 产 raw chunk；多 mode 断言产 `(mode, chunk)` 元组且 `_unpack_stream_item` 正确拆包。
- **双写一致性**：`build_run_config` 后断言白名单字段同时在 `configurable` 和 `context`；`agent_name` 两边一致。
- **secrets 不落盘**：`body.context` 含 `github_token`，断言只进 `config["context"]` 不进 `config["configurable"]`。
- **`__` 键剥离**：`body.config["context"]` 含 `{"__slash_skill_secret_source": "..."}`，断言被剥离。
- **recursion_limit 钳位**：客户端传 `recursion_limit=99999`，断言被钳到 `max_recursion_limit`；传非整数/bool/负数断言回退默认 100。
- **multitask reject**：thread 已有在途 run，`multitask_strategy="reject"` 断言 409；`interrupt` 断言旧 run 被 cancel、新 run 起。
- **cancel 幂等**：已 `interrupted` 的 run 再 `cancel` 返回 True；已 `success/error` 返回 False。
- **二级索引一致**：并发 `create` 多个同 thread run，断言 `_runs_by_thread` 与 `_runs` 一致、`list_by_thread` 无漏。
- **store 持久化回滚**：mock `_persist_new_run_to_store` 抛异常，断言内存记录被 pop + unindex（run 不可见）。
- **normalize_input 保结构**：含 `additional_kwargs` + 非 human 角色的 message，断言经 `normalize_input` 后 `additional_kwargs` / `id` / 角色不丢；畸形 entry 抛 400。
- **goal 续跑**：mock checkpoint goal active + evaluator 不满意，断言 worker 跑第二轮；goal satisfied 断言不续跑。
- **标题同步**：run 跑完后 checkpoint `channel_values.title` 有值，断言 `thread_store.display_name` 被更新。
- **SSE 帧**：`format_sse("values", {...}, event_id="123")` 断言帧含 `event: values\ndata: ...\nid: 123\n\n`。
- **regenerate 定位**：给定 message_id，断言 `_prepare_regenerate_payload` 返回前置 checkpoint + 干净 human message + target_run_id。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- RunManager 注册表 + schemas 完整源码：[references/code/run-manager.md](./references/code/run-manager.md)
- run_agent worker + stream_mode 映射 + checkpointer 协作完整源码：[references/code/run-agent-worker.md](./references/code/run-agent-worker.md)
- Gateway 服务层（start_run / build_run_config / sse_consumer / wait_for_run_completion）完整源码：[references/code/gateway-services.md](./references/code/gateway-services.md)
- HTTP 端点（create/stream/wait/join/cancel/list/get/regenerate）完整源码：[references/code/gateway-endpoints.md](./references/code/gateway-endpoints.md)
- 关联 skill：[[e2e-request-lifecycle]]（脊柱 ③路由 + ⑦流式）、[[long-running-and-cancellation]]（cancel/rollback/on_disconnect/wait/孤儿恢复/shutdown 深度）、[[frontend-streaming-protocol]]（useStream 消费 + SSE schema）、[[multi-user-isolation]]（thread ownership 校验）、[[config-and-hot-reload]]（AppConfig / max_recursion_limit）、[[thread-state-and-reducers]]（checkpoint 寻址与 channel_values）、[[subagent-delegation]]（`_SubagentEventBuffer` 批量持久化上游）
