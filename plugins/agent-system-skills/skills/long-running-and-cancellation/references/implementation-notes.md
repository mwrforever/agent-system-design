# Implementation Notes — long-running-and-cancellation

> 本文档总结长跑 Run 的运行时模型、状态机、SSE 帧契约、取消传播与一致性边界。
> 占位路径：`<harness-pkg>/runtime/runs/`、`<harness-pkg>/runtime/events/`。

## 一、组件拓扑

长跑子系统围绕"一次会话 = 一个 Run"展开，由"控制面 + 数据面"两类组件组合而成：

| 类别 | 组件 | 职责 |
|------|------|------|
| 控制面 | `RunManager` | 单进程注册表 + 可选 `RunStore` 持久化；负责 create / status / cancel / multitask 策略原子化 |
| 控制面 | `RunRecord` | 单 run 的运行时状态（`task / abort_event / on_disconnect / abort_action / status / token_*`） |
| 控制面 | `RunStatus` | enum：`pending / running / success / interrupted / error / timeout` |
| 控制面 | `DisconnectMode` | enum：`cancel`（默认，客户端断则取消）/ `continue_`（继续跑后台） |
| 持久化 | `RunStore` (抽象) | `put / get / list_by_thread / update_status / update_run_completion / update_run_progress / list_inflight` |
| 持久化 | `RunJournal` + `RunEventStore` | 单 run 的事件流持久化（LLM end / 中间件审计 / completion 字段） |
| 数据面 | `StreamBridge` | 解耦"worker 产事件 ↔ SSE 订阅者"；多订阅、断流重连、心跳 |
| 数据面 | `StreamEvent(id, event, data)` | 单帧 SSE；`id` 单调递增供 `Last-Event-ID` 续传 |
| 入口 | `run_agent(bridge, run_mgr, record, ctx, ...)` | 后台 asyncio task 主体；driver run 生命周期 |
| 入口 | `wait_for_run_completion(...)` / SSE consumer | HTTP 端订阅 bridge 生成 SSE 帧或阻塞拿终态 |
| 回滚 | `_rollback_to_pre_run_checkpoint(...)` | `abort_action="rollback"` 时把 checkpoint 写回 pre-run snapshot |

`RunRecord` 字段（节选关键项）：

| 字段 | 说明 |
|------|------|
| `run_id / thread_id / assistant_id` | 标识；`run_id` 由 server-side UUID 生成 |
| `status` | 当前 `RunStatus` |
| `on_disconnect` | `cancel / continue_`；HTTP 端 SSE 断流时的行为 |
| `multitask_strategy` | `reject / interrupt / rollback / enqueue` |
| `metadata / kwargs` | 透传给 worker 的自定义键 |
| `user_id` | 多用户隔离；TUI / 单用户模式可为 None |
| `task / abort_event` | asyncio 句柄；只在本进程内有效 |
| `abort_action` | `interrupt / rollback`，决定 cancel 后清理路径 |
| `error / model_name` | 终态错误文案与解析后的模型名 |
| `total_input_tokens / total_output_tokens / total_tokens / llm_call_count / lead_agent_tokens / subagent_tokens / middleware_tokens / token_usage_by_model` | 用量账目；`update_run_completion` 落盘 |
| `message_count / last_ai_message / first_human_message` | 历史回放便利字段 |
| `store_only` | True = 这条 record 仅从 store 反水化、本进程没有 task，cancellation API 会 409 |

`store_only` 字段在跨进程拓扑下尤其重要：网关 A 创建的 run、网关 B 通过 RunStore 拉到的 record 是 `store_only=True`，B 的 cancel API 看到这条 record 时返回 409（业务上是 "this worker cannot stop a run owned by another worker"），而不是装作能取消。

## 二、Run 状态机与多任务策略

一个 Run 的生命周期严格走 `pending → running → {success | error | interrupted}`。终态都是吸收态。

```
                 create()
                    │
                    ▼
  ┌──────────┐  set_status(running)  ┌──────────┐
  │ pending  │───────────────────────▶ │ running  │
  └──────────┘                        └────┬─────┘
        │                                  │
        │      abort_event.set()           │ 正常完成
        │      task.cancel()               │
        ▼                                  ▼
  ┌──────────────┐                  ┌──────────┐
  │ interrupted  │◀─── cancel() ────│ success  │
  └──────────────┘                  └──────────┘
                                          │
                                       异常路径
                                          ▼
                                    ┌──────────┐
                                    │  error   │
                                    └──────────┘
```

multitask 策略在 `create_or_reject(thread_id, multitask_strategy=...)` 内原子化决策（锁内同时检查 + 插入，规避 TOCTOU）：

| 策略 | 行为 |
|------|------|
| `reject`（默认） | 已有 pending/running → 抛 `ConflictError` → HTTP 409 |
| `interrupt` | abort 所有 inflight；新 run 接续；保留 checkpoint |
| `rollback` | abort + 回滚到 pre-run checkpoint snapshot；新 run 从干净状态开始 |
| `enqueue` | 排队执行（按 store 顺序） |

`abort_event` 是 cancel 与 multitask `interrupt`/`rollback` 的共享开关，`abort_action` 字段决定 worker 终止后走 `set_status(interrupted)` 还是 `_rollback_to_pre_run_checkpoint`。

## 三、SSE 帧格式与 StreamBridge

SSE 帧严格遵循 W3C 文本协议，每个事件三行 + 空行分隔：

```
event: <name>
data: <json>
id: <monotonic-id>

```

事件名 1:1 对应 LangGraph `stream_mode` (`values / updates / messages-tuple / custom / checkpoints / tasks / debug`)，再加 framework 帧 `metadata / error / end / __heartbeat__`。`messages` 在 LangGraph 内部模式名是 `messages`，对外 SSE 客户端显式订阅时写作 `messages-tuple`（详见 [[gateway-runs-and-sse]]）。

worker 内部维护一张 LangGraph mode → SSE event 的映射表（`_lg_mode_to_sse_event`）：当前是 1:1 直传。请求里 `events` 是合法 stream_mode 名但在 gateway 内不被支持（需要 `astream_events()`，与 `values` 互斥），worker 会安静跳过并记一条 info 日志。

`StreamBridge` 的关键保证：

- **多订阅**：单 run 可被多个 HTTP 连接同时订阅（管理端 + 用户端）；
- **断流重连**：`subscribe(last_event_id=...)` 从下一帧开始重放；客户端去重靠 `id`；
- **心跳**：无事件 15s 自动发 `__heartbeat__` 防 nginx/浏览器 60s 静默关闭；
- **延迟清理**：`bridge.cleanup(run_id, delay=60)`，END 后保留 60s 供慢客户端续上。

worker 端通过 `bridge.publish(run_id, event, data)` 投递；`run_agent` 在 try/except/finally 整圈包裹保证无论成功失败异常都会 `publish_end(run_id)`，避免 SSE 流挂死。`finally` 块还做三件事：

1. flush `RunJournal`（中间件审计 + LLM 用量事件），并 `update_run_completion` 把汇总字段（`token_usage_by_model / message_count / last_ai_message / first_human_message`）写回 `RunStore`；
2. 从 checkpoint `channel_values.title` 取最新 thread title 同步到 `threads_meta.display_name`；
3. 把 `threads_meta.status` 从 `running` 推到 `idle` 或 run 的终态名。

三件事都吞掉了自己的异常（非致命），优先保证 `publish_end` 一定发出。

## 四、关键不变量

1. **HTTP handler 与 agent 任务解耦**：HTTP 只负责"创建 RunRecord + spawn 后台 task + 订阅 bridge"。客户端断不影响 task 自身。
2. **`POST /wait` 也走 bridge 订阅 END**：不要 `await record.task`，否则 `on_disconnect=cancel` 时客户端断了 task 还在跑、返回 stale checkpoint。
3. **rollback 完整写回 pre-run snapshot**：包含 `checkpoint / metadata / pending_writes`，缺一项就 thread 状态分裂。回滚还生成一枚新的 `checkpoint_id` 标记，避免和原 id 冲突。
4. **`abort_action` 在 abort_event 之前设置**：rollback / interrupt 分支共用同一个 `abort_event`，靠 action 字段区分；顺序反了 worker 看到 event 但读到旧 action。
5. **`Last-Event-ID` 服务端识别**：客户端重连 header 带 `Last-Event-ID`；服务端从下一帧开始重放。客户端配合 id 去重，避免重连后从头收一遍触发死循环。
6. **创建可见性边界**：`RunManager._persist_new_run_to_store` 创建失败会回滚内存记录，杜绝"内存有但 store 没有"的脏状态。状态更新走 `update_status` 是 best-effort（捕获日志），但创建是 fail-hard。
7. **持久化重试**：`_call_store_with_retry` 对 SQLite `database is locked / busy` 类瞬时错做指数退避（默认 5 次，50ms → 1s 上限），其他错误立即抛出，不掩盖永久故障。重试判定会递归检查 `__cause__ / __context__ / orig`（SQLAlchemy 包裹后的 sqlite3 异常），避免漏判。
8. **优雅停机有预算**：`RunManager.shutdown(timeout=5.0)` 先 abort 全部 inflight、`asyncio.wait(tasks, timeout=...)`，让走得动的 run 自然 flush checkpoint；超时的才打 `interrupted`。状态持久化也在剩余预算内 `wait_for`，避免 store 卡 shutdown。drain 中"自己跑完了"的 run 保留真实终态（success / error），不被 shutdown 路径覆盖成 `interrupted`。
9. **孤儿 inflight 回收**：进程重启后 `reconcile_orphaned_inflight_runs(error=...)` 把 store 里 pending/running 但本地无 task 的行刷成 `error`，避免 UI 永久显示活跃 run。
10. **二级索引保持原子**：`_runs` 与 `_runs_by_thread` 的写入在同一把 `_lock` 内串行进行（无 `await` 跨越），所以任何持锁读取都能看到一致视图。索引存在的意义是把 per-thread 查询从 O(in-memory runs) 降到 O(runs-in-thread)。
11. **cancel 幂等**：已 `interrupted` 的 run 再次 `cancel` 返回 `True`（成功，no-op）；已 `success / error` 的返回 `False`（无法再取消）。这条让前端"重复点取消按钮"不致 500。


## 五、调参旋钮与典型踩坑

| 字段 | 默认 | 说明 |
|------|------|------|
| `on_disconnect` | `"cancel"` | 客户端断 → cancel task；可选 `"continue"` 让后台继续跑 |
| `heartbeat_interval` | 15s | StreamBridge 无事件时心跳间隔 |
| `bridge.cleanup` delay | 60s | END 帧发出后 bridge 保留多久 |
| `recursion_limit` | 100 | 主代理 super-step 上限（子代理默认 150） |
| `PersistenceRetryPolicy` | 5 次 / 50ms→1s | SQLite 锁重试 |
| `shutdown timeout` | 5s | inflight 优雅 drain 预算 |
| `multitask_strategy` | `"reject"` | 同 thread 已有活跃 run 时的行为 |
| `cleanup` delay (RunManager) | 300s | 内存 RunRecord 清理延迟，给慢端点留时间拉历史 |

`PersistenceRetryPolicy` 内部参数：

```python
@dataclass(frozen=True)
class PersistenceRetryPolicy:
    max_attempts: int = 5
    initial_delay: float = 0.05
    max_delay: float = 1.0
    backoff_factor: float = 2.0
```

重试只覆盖 SQLite 锁竞争类瞬时错误（`SQLITE_BUSY / SQLITE_LOCKED` 或消息含 `database is locked / busy`）；普通业务错和模式不匹配立即抛出。判定时会沿 `__cause__ / __context__ / orig` 递归走，确保 SQLAlchemy `DBAPIError` 包裹的 sqlite3 异常也能识别。

常见踩坑：

1. **HTTP handler 内直接 `await run_agent(...)`** → 客户端断 task 也死，根本无法实现"客户端断了后台仍跑"。
2. **不发心跳** → nginx / 浏览器 60s 静默关 SSE，体验上看就是"消息突然没了"。
3. **rollback 只删 checkpoint 不写回 snapshot** → 用户看到完全空白对话历史。
4. **`Last-Event-ID` 服务端不识别** → 重连后从头送一遍，前端就算去重也会卡顿；正确做法是 bridge 端按 id 跳过已发送帧。
5. **wait 端点直接 `await record.task`** → 不响应 `on_disconnect`，客户端断了仍回 stale checkpoint。
6. **`bridge.cleanup(delay=0)`** → 慢客户端来不及订阅，永远连不上。
7. **shutdown 不做 inflight drain** → checkpointer 池先关、worker 还在写，触发 `PoolClosed` 异常 + 数据丢失。
8. **进程重启后不 reconcile 孤儿** → 历史 UI 永远显示一坨"活跃 run"。
9. **`create()` 与 `_index_run_locked()` 顺序乱** → 索引和 `_runs` 状态不一致；高并发 `list_by_thread()` 可能漏 run。同一把锁内无 `await` 跨越是关键。
10. **`update_run_progress` 在终态后还在写** → `should_persist = record.status == RunStatus.running` 是必须的守卫，否则 token 累计会污染已经 success/error 的快照。
11. **`agent_factory` 不接受 `app_config` 参数** → worker 自动用 `_agent_factory_supports_app_config()`（带 lru_cache）回退到不传该参数的形式，避免硬绑定。如果发现 app_config 没有传到 agent，先确认 factory 签名里有这个参数。


## 六、调试入口

- 状态机日志：`logger.info("Run %s -> %s", run_id, status.value)`；每次 `set_status` 一行。
- LangSmith / Langfuse trace 的 `run_name` 与 `RunRecord.run_id` 1:1 对齐；trace 名字由 `resolve_root_run_name(config, assistant_id)` 决定：优先 `context.agent_name` / `configurable.agent_name`，回退 `assistant_id`，再回退 `"lead_agent"`。
- `RunStore` SQL 表按 `created_at DESC` 排序就是历史回放；`list_inflight(before=...)` 是孤儿巡检入口。
- `RunJournal` 事件类型：LLM `on_llm_end`、`middleware:safety_termination`、`middleware:skill_activation` 等；事后审计走这里。`update_run_completion` 写完的字段包括 `total_input_tokens / total_output_tokens / total_tokens / llm_call_count / lead_agent_tokens / subagent_tokens / middleware_tokens / token_usage_by_model / message_count / last_ai_message / first_human_message / error`。
- `_call_store_with_retry` 失败日志带 `attempt N/M`，看到这种日志说明 store 在背压。
- `bridge.publish_end(run_id)` 在 try/except/finally 的 finally 块里发出，所以任何路径下都能看到 `end` 帧；若客户端没有收到 `end`，先查 worker 是否在 publish 之前死锁了。
- 错误 fallback 检测：worker 扫描 streamed chunks 里 `additional_kwargs.error_fallback` 标记，命中后 run 终态被强制设为 `error`，error 文案优先取 `error_detail` → `error_reason` → content 前 2000 字。
- LangGraph 的 `events` mode 在 gateway 不支持（与 `values` 互斥）；请求里出现会被静默跳过并记一条 info 日志，不影响其他 mode。


## 相关 skill

- [[gateway-runs-and-sse]]
- [[frontend-streaming-protocol]]
- [[subagent-delegation]]
- [[observability-tracing]]
- [[safety-and-guardrails]]
