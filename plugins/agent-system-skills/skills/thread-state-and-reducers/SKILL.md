---
name: thread-state-and-reducers
description: LangGraph ThreadState 的通道与 reducer 设计：AgentState 之上的 18 个扩展通道（sandbox/artifacts/delegations/skill_context/todos/goal…）、11 个自定义 reducer 解决并发写冲突（merge_sandbox 冲突检测、merge_delegations 追加账本、merge_promoted 分代）、DeltaThreadState 用 DeltaChannel 做 full/delta 双模式检查点、CheckpointStateAccessor 直读检查点通道、goal 状态机与 task_continuity。当要给图状态加字段、设计并发安全的 state 通道、做增量检查点/历史回放、或排查"字段被静默覆盖"时使用。
---

# ThreadState 与 Reducer 设计

## 何时用

- 给 agent 状态加新字段（尤其会被工具/中间件/子代理并发写的）
- 设计 full/delta 双模式检查点与历史回放
- goal（目标达成循环）或任务连续性（task continuity）机制
- 排查"state 字段偶发丢失/被覆盖"（Last-Write-Wins 退化）

## 设计方案（为什么这么设计）

### 1. 每个并发写字段都必须有 reducer

LangGraph 默认通道是 Last-Write-Wins。一次 step 里工具结果、中间件、子代理回调同时写同一字段时，后写静默吃掉先写。`ThreadState`（thread_state.py:371）为 18 个扩展通道各配语义化 reducer：

- `merge_sandbox`：沙箱 id 冲突**检测**——同 step 出现两个不同 sandbox_id 是隔离 bug，宁可报错不可静默择一
- `merge_delegations`：委派账本按 key 追加/更新，子代理状态回填不丢兄弟条目
- `merge_tool_artifacts` / `merge_promoted`（分代）/ `merge_viewed_images` / `merge_skill_context` 等：各按业务语义合并

省略 `state_schema=ThreadState`（用裸 `AgentState`）等于把这些通道全部退回 LWW——这是装配期硬约束（见 [[agent-graph-factory]]）。

### 2. DeltaThreadState：同一状态两种检查点形态

`DeltaThreadState`（:490）把 messages 通道换成 `DeltaChannel`：full 模式存全量、delta 模式只存增量。`get_thread_state_schema(mode, snapshot_frequency)`（:512）按检查点模式返回对应 schema；`normalize_middleware_state_schemas()`（:550）保证中间件声明的 state schema 与主 schema 归一。进程级模式由 `freeze_checkpoint_channel_mode` 冻结（fail-closed，见 [[long-running-and-cancellation]]）。

### 3. 检查点直读与安全变更

工具/服务不能随便 `update_state`：`CheckpointStateAccessor` + `build_state_mutation_graph`（checkpoint_state.py:37/113）提供"在检查点通道上读写"的受控面，把变更包成一次微型图执行，走完整 reducer 合并——绕过 reducer 的直写是状态损坏的主要来源。`checkpoint_patches.py` 修 import-time saver 的已知缺陷。

### 4. goal 状态机与任务连续性

- `goal_state.py`：goal 完成度状态枚举与归约（配合 runtime/goal.py 的评估循环，见 [[scheduled-tasks]]）
- `task_continuity/`（archive/state/tools）：跨 run 的任务档案——上一次 run 的未竟事项写入 state，下一次 run 自动接续
- 契约 `thread_goal_contract.json` 冻结 goal 通道外显词表（stand_down_reason_codes、goal_outcome、history head 投影），前端与调度器共译

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/harness/helix/agents/thread_state.py` | 563 | ThreadState/DeltaThreadState/全部 reducer/schema 工厂 |
| `references/code/backend/packages/harness/helix/agents/goal_state.py` | 46 | goal 状态枚举与归约 |
| `references/code/backend/packages/harness/helix/agents/task_continuity/archive.py` | 245 | 跨 run 任务档案 |
| `references/code/backend/packages/harness/helix/agents/task_continuity/state.py` | 103 | 连续性通道 |
| `references/code/backend/packages/harness/helix/agents/task_continuity/tools.py` | 166 | 连续性工具 |
| `references/code/backend/packages/harness/helix/runtime/checkpoint_state.py` | 219 | 检查点访问器与变更图 |
| `references/code/backend/packages/harness/helix/checkpoint_patches.py` | 125 | saver 缺陷修补 |
| `references/code/contracts/thread_goal_contract.json` | 44 | goal 外显契约 |

## 反模式与陷阱

- ❌ 新字段用默认通道且被两处并发写 → LWW 静默丢数据；写 reducer。
- ❌ 服务侧直接改检查点 blob → 绕过 reducer；走 CheckpointStateAccessor。
- ❌ full/delta 模式混进程 → 互读损坏；模式进程级冻结 + fail-closed 门。
- ❌ 把大对象塞 state 每步全量重写 → 检查点膨胀；用增量通道或外部存储 + state 只放引用。

## 落地参考

**自测方向**：并发写同字段的合并断言（构造双 update 同 step）；delta 模式下历史重放等价 full；goal 状态经 reducer 归约后的外显值符合契约词表。

## 进一步阅读

- [[agent-graph-factory]]（state_schema 传递）、[[long-running-and-cancellation]]（检查点存储与 delta 恢复）
- [[scheduled-tasks]]（goal 评估循环的另一半：runtime/goal.py）
