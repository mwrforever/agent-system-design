---
name: subagent-delegation
description: 子代理委派体系：task 工具与 SubagentExecutor（持久隔离事件循环、独立 ThreadState、父上下文快照注入）、SubagentExecutionCapacity FIFO 准入（max_running/max_queued/reject|queue）、三源注册表（内置 bash/general-purpose + 管理式 + 自定义）、双 ID 关联（provider tool_call_id vs 服务器 execution_id 绝不混用）、SubagentResult 终态契约（token/turn/loop 三种 capped）、确定性验收核验器（文件存在/JSON/CSV 表头/tests_passed 对照 bash 证据）、持久批处理（租约 worker）。当要实现多代理委派、并发限额、后台任务、子代理结果校验时使用。
---

# 子代理委派

## 何时用

- lead agent 委派子任务给隔离子代理（同步等待 / 后台轮询两种模式）
- 委派并发治理（每响应/每 run 上限、排队与拒绝策略）
- 子代理结果的确定性验收（不信任模型自述）
- 大批量同构任务（批处理 worker + 断点续跑）

## 设计方案（为什么这么设计）

### 1. 执行器：隔离事件循环 + 快照注入

`SubagentExecutor.execute(task)` 在**持久隔离事件循环**里跑（:2130）：子代理有自己的 ThreadState、自己的中间件链（`build_subagent_runtime_middlewares`，lead 链的子集，见 [[middleware-chain-design]]）、自己的 recursion limit（`turn_budget.resolve_recursion_limit` 把 max_turns 换算成 LangGraph 递归上限）。父上下文以 `ParentContextSnapshot`（不可变数据快照）注入，**不是共享 state**——父子解耦，父的后续轮次不影响已派发的子任务。

### 2. 容量：FIFO 准入而非信号量

`SubagentExecutionCapacity`（capacity.py:36）：`max_running`（默认 3）/`max_queued`（默认 64）双闸，`admission_policy: reject|queue`。选 FIFO 队列而非信号量阻塞：模型侧拿到的反馈是"排队中"的可观测状态，而非无限期 await。`SubagentRuntime` 是显式依赖容器（start/stop/async with），由 SDK 工厂注入。

### 3. 双 ID 铁律

后台子代理有两个 ID：**provider `tool_call_id`**（与 ToolMessage/SSE 关联）与**服务器 `execution_id`**（生命周期/持久化注册表所有权）。二者绝不混用——混用会把"消息关联"与"任务所有权"耦合，重连/恢复时错乱。

### 4. 终态契约（冻结词表）

`SubagentResult`（executor.py:118）dataclass：status ∈ PENDING/RUNNING/COMPLETED/FAILED/CANCELLED/TIMED_OUT，`stop_reason` ∈ token_capped/turn_capped/loop_capped，`try_set_terminal()` 线程安全一次性置终态（防取消与完成竞争双写）。外显词表由 `contracts/subagent_status_contract.json` 冻结，`status_contract.py` 负责把结果格式化回父线程的 `delegations` 通道（reducer 见 [[thread-state-and-reducers]]）。

### 5. 验收：确定性核验，不信任自述

`acceptance_checks.py`（2253 行）在子代理返回后做**确定性核验**：文件存在/大小、JSON 可解析、CSV 表头匹配、`tests_passed:<command>` 与 bash 执行证据对照（shell 解析、Windows 路径语义）。模型说"完成"不算数，证据才算数——`AcceptanceVerdict` + `report_contract.py` 把核验结论注入子代理的报告契约提示。

### 6. 注册表与批处理

- `registry.py` 三源：内置（bash_agent / general_purpose）+ 管理式（persistence/managed_subagents）+ 自定义；`resolve_subagent_model_name` 子代理模型三段降级。
- `SubagentBatchService`（batch_service.py:77）：持久批 worker（DB 为事实源 + BatchItemLease 租约 + pause/resume/cancel/retry + results.jsonl 导出）——与 [[mcp-integration]] 的长任务、[[scheduled-tasks]] 的调度器同构（"DB 事实源 + 租约恢复 + 幂等 claim"三件套）。

### 7. 工具面

`task_tool.py`（1299 行）绑定 runtime；`batch_task_tool.py` 提交批量。提示词侧的委派指南按并发分形（见 [[system-prompt-template]]）；`SubagentLimitMiddleware` 执行每响应/每 run 上限。

## 实现索引

`references/code/subagents/`（整目录 31 文件）+ 工具/路由/契约：

| 关键文件 | 行数 | 职责 |
|---|---|---|
| `subagents/executor.py` | 2351 | 执行器全流程（隔离循环/建 agent/收据收割/后台任务 API） |
| `subagents/acceptance_checks.py` | 2253 | 确定性验收核验器 |
| `subagents/batch_service.py` | 514 | 持久批 worker |
| `subagents/registry.py` | 243 | 三源注册表 |
| `subagents/status_contract.py` | 334 | 结构化结果契约 |
| `subagents/runtime.py` / `capacity.py` / `context_snapshot.py` / `turn_budget.py` | 174/185/176/138 | 依赖容器/FIFO 准入/父快照/递归换算 |
| `tools/builtins/task_tool.py` | 1299 | task 工具 |
| `tools/builtins/batch_task_tool.py` | 415 | 批量提交 |
| `contracts/subagent_status_contract.json` | 6 | 终态词表 |
| `backend/app/gateway/routers/subagents.py` / `subagent_batches.py` | 239/134 | 管理式子代理 CRUD / 批处理 API |
| 其余（config/report_contract/step_events/token_collector/batch_*） | — | 配置/报告契约/步进事件/记账/租约 |

## 反模式与陷阱

- ❌ 子代理共享父 state → 父轮次污染子执行；快照注入。
- ❌ 用信号量阻塞超限委派 → 模型挂死不可观测；FIFO + 拒绝/排队策略。
- ❌ 两个 ID 混用 → 关联与所有权耦合，恢复错乱。
- ❌ 终态可重写 → 取消/完成竞争双写；try_set_terminal 一次性。
- ❌ 只信子代理自述完成 → 幻觉完成；确定性验收对照 bash 证据。
- ❌ 子代理用 lead 全量链 → 无谓 token 与越权面；用共享基础链构造器。

## 落地参考

**调参旋钮**：`subagents`（注册/模型）、`subagent_runtime.max_running/max_queued/admission_policy`、`subagent_batches`、`max_concurrent_subagents`（提示词分形阈值）。

**自测方向**：并发提交超 max_running 断言排队/拒绝；后台任务取消与完成竞争断言单终态；验收器对"文件不存在却自述完成"判 fail；批处理中断续跑不重跑已完成项。

## 进一步阅读

- [[middleware-chain-design]]（子代理链构造器）、[[thread-state-and-reducers]]（delegations reducer）
- [[scheduled-tasks]] / [[mcp-integration]]（同构的后台 worker 三件套）
