---
name: scheduled-tasks
description: 定时任务全链路：schedules 纯计算（cron/once/interval + DST 回拨歧义处理）、ScheduledTaskService 后台轮询器（单活跃约束 uq_scheduled_task_run_active + 并发预算 + 队列准入 + 到期回收 + 多实例租约恢复）、非交互 run 语义（non_interactive 剥 ask_clarification）、goal 目标循环（evaluate_goal_completion/should_continue_goal）、通知投递 outbox 重试 + 多语言文本渲染 + 出站脱敏、前端 cron 解析/格式化与 goal-outcome 语义、配额与错误码契约。当要做 agent 定时任务/周期研究/目标达成自动续跑，或排查"任务没触发/重复触发/时区错"时使用。
---

# 定时任务

## 何时用

- agent 平台的定时/周期任务（每天早报、定时研究、目标驱动循环）
- cron 时区与 DST 边界
- 非交互 run 的语义（没有人盯屏时 agent 行为如何收敛）
- 定时结果经 IM 渠道通知（含失败重试）

## 设计方案（为什么这么设计）

### 1. 计算是纯函数，服务是纯轮询

`scheduler/schedules.py::next_run_at`（107 行）：cron（croniter）/ once（naive 视为声明时区墙上时间统一转 UTC，过期返回 None）/ interval（上限 30 天）。**DST 回拨**对"固定时刻"表达式（分/时无通配）跳过 fold=1 的重复触发。无 IO、无状态——计算可单测到极致。

`ScheduledTaskService`（app/scheduler/service.py，1288 行）：`_run_loop` 固定间隔轮询（默认 5s，异常不杀循环）→ 扫到期 occurrence → 准入（数据库**单活跃约束** `uq_scheduled_task_run_active` + `max_concurrent_runs` 预算 + 每用户配额）→ 经 Gateway 正常 run 路径启动（`launch_scheduled_thread_run`）。**调度器只决定 when，不另造执行路径**。

### 2. 队列、回收与多实例

- `_launch_queued_occurrence` / `_drain_queue`：预算满时排队，超时（queue_timeout）失效
- `_expire_waiting_runs`：等待态超时回收
- `_reconcile_active_state` + 租约（lease 120s）：多实例下任务实例漂移后恢复
- `handle_run_completion`：run 终态回调 → 触发通知投递与 goal 评估

### 3. 非交互语义

调度触发的 run 以内部调用方身份携带 `non_interactive`：剥 `ask_clarification`（防永久卡死）、走无人值守交互策略（见 [[e2e-request-lifecycle]] 信任边界与 [[agent-graph-factory]] 工具裁剪）。

### 4. goal 循环

`runtime/goal.py`（869 行）：线程可设 `/goal` 完成条件；run 结束时 `evaluate_goal_completion` 判定，未达成且可续 → `make_goal_continuation_message` 自动续跑（预算内）。`thread_goal_contract.json` + `scheduled_goal_notes_contract.json` 冻结 goal 状态与终止化词表（unmet ≠ 执行失败）。

### 5. 通知投递

`notification_delivery.py`（446 行）：outbox 模式重试（投递失败重排，死信有界）；`notification_text.py`（359 行）：多语言渲染 + **出站脱敏**（`redact_egress_text`——发给 IM 的文本先脱敏）。渠道能力查静态表（见 [[im-channels]]）。

### 6. 持久化与 API

`scheduled_tasks` / `scheduled_task_runs` / `scheduled_task_events` 三组仓库（配额 `ScheduledTaskQuotaExceeded`、活跃变更冲突、租约活性）；路由：preview-cron / CRUD / pause/resume/trigger / runs / 事件查询；前端 `cron.ts`（695 行）解析格式化、`goal-outcome.ts` 语义映射。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/scheduler/schedules.py` + `stop_rule.py` + `runtime.py` | 107/37/31 | 纯计算/停止条件/能力开关 |
| `references/code/app/scheduler/service.py` | 1288 | 轮询器 |
| `references/code/app/scheduler/{notification_delivery,notification_text}.py` | 446/359 | 投递/文本 |
| `references/code/runtime/goal.py` | 869 | goal 评估循环 |
| `references/code/persistence/scheduled_tasks/sql.py` | 1021 | 任务仓库（配额/租约） |
| `references/code/persistence/scheduled_task_runs/sql.py` | 1134 | 运行仓库（单活跃约束） |
| `references/code/tools/scheduled_tasks.py` | 185 | schedule_task/stop 工具 |
| `references/code/app/gateway/routers/scheduled_tasks.py` + `scheduled_task_access.py` + `scheduled_task_validation.py` + `scheduled_task_errors.py` | 513/688/375/136 | API/访问控制/校验/错误码 |
| `references/code/contracts/{scheduled_goal_notes,scheduled_task_errors,thread_goal}_contract.json` | 44/56/44 | 冻结词表 |
| `references/code/frontend/core/scheduled-tasks/{cron,goal-outcome,events}.ts` | 695/244/484 | 前端语义 |

## 反模式与陷阱

- ❌ 调度器自己起线程跑 agent → 第二条执行路径失控；走 Gateway run 路径。
- ❌ 只靠进程内锁防重复触发 → 多实例重复执行；DB 单活跃约束 + 租约。
- ❌ naive 时间直接当 UTC → 时区错位；按声明时区墙上时间转换。
- ❌ 定时 run 暴露 ask_clarification → 无人值守永久卡死；non_interactive。
- ❌ 通知直接发原文 → 内部路径/敏感信息出站；redact_egress_text。
- ❌ unmet 当失败渲染 → 用户误判任务坏了；契约区分语义。

## 落地参考

**调参旋钮**：`scheduler.enabled/tool_enabled/multi_instance/poll_interval/max_concurrent_runs/per_user 配额/queue_timeout/recursion_limit(1000)`。

**自测方向**：DST 回拨夜固定时刻任务只触发一次；并发预算满时排队并最终执行或超时失效；多实例同时轮询同一任务只执行一次；goal 未达自动续跑且预算耗尽停止并标 unmet；通知失败重试后进死信。

## 进一步阅读

- [[e2e-request-lifecycle]]（非交互 run 信任边界）、[[im-channels]]（通知渠道能力表）
- [[subagent-delegation]] / [[mcp-integration]]（同构"DB 事实源+租约+幂等 claim"worker 三件套）
