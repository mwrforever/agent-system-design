---
name: long-running-and-cancellation
description: 长运行 run 的生命周期管理：RunManager 状态机（create_or_reject 原子注册/租约心跳/孤儿回收 reconcile_orphaned_inflight_runs/优雅 shutdown）、run_agent worker 3556 行（取消围栏/回滚点捕获/delta 检查点线性化恢复/goal 评估续跑/事件转换）、StreamBridge 内存+Redis 双实现（Last-Event-ID 重连/心跳哨兵）、checkpointer 工厂（Sqlite/Postgres + CachedHistorySaver delta 穿透缓存 + checkpoint_cache redis 后端）、full/delta 模式进程级冻结 fail-closed、AsyncKeyedLockTable。当要实现后台 run 服务、可靠取消、断线续流、多实例租约，或排查"run 卡死/孤儿/恢复错乱"时使用。
---

# 长运行与取消

## 何时用

- 实现"run 在后台跑、HTTP 只是观察窗"的服务架构
- 可靠取消（用户取消/超时/关停）与终态竞争
- 断线重连补流、多实例 run 所有权
- 检查点 full/delta 双模式与历史缓存

## 设计方案（为什么这么设计）

### 1. RunManager：注册、租约、回收三件事

`runtime/runs/manager.py`（2690 行，类在 :286）：
- `create_or_reject`：原子注册（幂等；同 thread 活跃 run 冲突 → `ConflictError`）**先于** worker 启动——崩溃窗口内 run 状态有据可查
- 租约心跳 `start_heartbeat`（run_ownership: lease 30s + 时钟偏移预算）：多实例下 run 的所有权凭证，心跳停即过期
- `reconcile_orphaned_inflight_runs`：启动/定期把"无主 in-flight"收敛为终态——孤儿 run 是重连与对账的最大毒源
- 优雅 shutdown：等待终态化或标记中断（CancelOutcome 区分用户取消/超时/关停）

### 2. worker：一个函数跑完整个 run

`run_agent()`（worker.py:922，3556 行）：安装 runtime context → 建图 → 挂 checkpointer/store → astream 驱动 → 事件转换发布 bridge。四件硬事：
- **取消围栏**：协作式取消检查点，终态一次性落定（防"取消后事件还在发"）
- **回滚点捕获** `_capture_rollback_point`：可恢复的执行位置
- **delta 检查点线性化恢复** `_linearize_delta_checkpoint_resume`：delta 历史重放成线性序列
- **goal 评估续跑**：未达 goal 且预算内自动续（见 [[scheduled-tasks]]）

### 3. StreamBridge：生产者/消费者解耦

抽象 `StreamBridge`（base.py:57，`StreamEvent`/`StreamGap`/心跳哨兵）+ `MemoryStreamBridge`（单进程）+ `RedisStreamBridge`（跨副本 SSE，`make_stream_bridge` 工厂按配置选）。消费者凭 `Last-Event-ID` 从桥/事件存储补缺口——连接是短暂的，流是持久的。

### 4. 检查点体系

- `make_checkpointer`（async_provider.py:220）：Sqlite/Postgres
- `CachedHistorySaver`（cached_saver.py:74）：只读穿透的 delta 历史缓存；条目不可变故免失效
- `checkpoint_cache/`：缓存后端契约（memory/redis）
- `checkpoint_mode.py`：**进程级** full/delta 冻结 + `ensure_checkpoint_mode_compatible` fail-closed——混模式互读即损坏

### 5. 键级锁

`AsyncKeyedLockTable`：thread 级互斥（同一 thread 的 run/compaction 不并发）——数据库约束之外的进程内第二道闸。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/harness/helix/runtime/runs/manager.py` | 2690 | RunManager 状态机 |
| `references/code/backend/packages/harness/helix/runtime/runs/worker.py` | 3556 | run_agent 执行主体 |
| `references/code/backend/packages/harness/helix/runtime/runs/{schemas,naming,stream_cleanup}.py` + `cancellation.py` | 32/16/111/63 | 状态/命名/清理/取消 |
| `references/code/backend/packages/harness/helix/runtime/runs/store/{base,memory}.py` | 523+608 | run 存储契约 |
| `references/code/backend/packages/harness/helix/runtime/stream_bridge/{base,memory,redis,async_provider}.py` | 127/192/432/102 | 流桥 |
| `references/code/backend/packages/harness/helix/runtime/checkpointer/{provider,async_provider,cached_saver,thread_spans}.py` | 286/257/349/97 | 检查点 |
| `references/code/backend/packages/harness/helix/runtime/checkpoint_cache/**` | ~416 | 历史缓存 |
| `references/code/backend/packages/harness/helix/runtime/{checkpoint_mode,keyed_lock}.py` | 146/147 | 模式冻结/键锁 |
| `references/code/backend/packages/harness/helix/config/{checkpointer,stream_bridge,run_ownership}_config.py` | 76/96/47 | 配置 |

## 反模式与陷阱

- ❌ 先起 worker 后注册 run → 崩溃窗口孤儿；原子注册在前。
- ❌ 取消直接杀任务 → 终态竞争双写；协作围栏 + CancelOutcome。
- ❌ 连接断开杀 run → 用户刷新丢工作；bridge 解耦 + 重连补流。
- ❌ 多实例无租约 → 双副本同跑一个 run；心跳租约 + 过期回收。
- ❌ full/delta 混进程互读 → 检查点损坏；进程级冻结 fail-closed。
- ❌ 内存事件存储跑多实例 → 副本间流不可见；Redis bridge + db 事件。

## 落地参考

**调参旋钮**：`run_ownership`（lease 30s/heartbeat/时钟偏移）、`checkpointer`（后端/模式）、`stream_bridge`（memory/redis）、`database.checkpoint_channel_mode`（full|delta + delta 缓存）。

**自测方向**：杀 worker 进程 → 孤儿回收收敛终态；心跳停止 → 租约过期他副本可接管；取消与完成同时到达 → 单终态；Redis bridge 跨副本重连不丢事件（seq 对账）；delta 模式历史重放等价 full。

## 进一步阅读

- [[gateway-runs-and-sse]]（HTTP/SSE 出口侧）、[[thread-state-and-reducers]]（delta 通道的 state 侧）
- [[scheduled-tasks]] / [[mcp-integration]]（同构租约 worker）、[[observability-tracing]]（事件存储）
