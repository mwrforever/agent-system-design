---
name: scheduled-tasks
description: 设计生产级 agent 平台的定时/后台任务机制--ScheduledTaskService poller + lease 并发限流 + cron/once 纯计算 + non_interactive 剥离 ask_clarification 完整链路 + overlap_policy + 崩溃恢复（stuck once / stale active）+ 前端任务页面。给出完整真实代码与在端到端链路 ①入站-scheduler 的位置。当你要加定时/cron/后台任务、做无人值守 run、排查任务重复执行或卡死、调 lease/overlap/poll 旋钮时调用本 skill。
---

## 何时用

- 给 agent 平台加定时任务（cron 周期）/ 单次任务（once 定时）/ 无人值守后台 run
- 需要 poller 认领到期任务，且多实例部署要防"同一任务被重复执行"
- 调度 run 无人盯屏，要保证它不会因调 `ask_clarification` 而永久卡死
- 排查任务"重复执行""卡 running 永不终态""once 任务崩溃后不触发"
- 调 lease TTL / poll 间隔 / overlap_policy / max_concurrent_runs 旋钮
- 给调度任务做前端管理页（CRUD + 暂停/恢复/手动触发 + 运行历史）

## 设计方案（为什么这么设计）

### 核心定位：在端到端链路 ①入站-scheduler 处把"时间到了"变成"一次 run"

本 skill 是脊柱 [[e2e-request-lifecycle]] 的 ①入站 跳的第三条路径（Web / IM / 定时任务）的深度。`ScheduledTaskService` 是个 poller：周期性认领到期任务，经 `launch_scheduled_thread_run` 桥接进与 HTTP/IM 路径**完全相同**的 run 生命周期（②认证 -> ③路由 -> ④建图直到 ⑧渲染）。三条入站路径在 ②认证处汇合（调度路径用内部合成用户 + `AUTH_SOURCE_INTERNAL`），此后 ③–⑧ 无差别。

调度路径的特殊性全在"无人盯屏"：没有用户在另一端等回复。这催生了本 skill 的两个核心设计--**non_interactive 剥离 ask_clarification**（跨切不变量 1）与**崩溃恢复**（进程死掉后任务不能永久卡住）。

### poller + lease 并发限流（为什么不用队列/不用锁）

调度触发用 **poller 轮询 DB** 而非消息队列，原因：调度任务本身存在 DB 里（前端可 CRUD），poller 只是"到期检查 + 认领"，引入 MQ 会双写（DB 是事实源、MQ 是触发源）增加一致性问题。多实例部署时，多个 poller 同时扫到期任务，用 **lease + lease_owner** 做乐观并发控制：

- `claim_due_tasks(now, lease_owner, lease_seconds, limit)` 是仓储层**原子认领**：一条 SQL 里 `UPDATE 任务行 SET lease_owner=?, lease_expires_at=now+lease WHERE lease_expires_at < now AND status='enabled'`，只返回被本实例抢到的行。DB 行锁保证多实例并发抢同一任务时只有一个命中。
- `lease_owner = "{hostname}:{uuid4().hex}"` 进程级唯一。lease TTL 内即使本实例崩溃，其他实例也不抢（等 `lease_expires_at` 过期）；代价是崩溃后接管有延迟（最多 `lease_seconds`），换取"不会重复执行"的强保证。

`max_concurrent_runs` 是**全局在途上限**，不是单轮认领数：长 run 跨轮累积，每轮先算 `budget = max_concurrent_runs - count_active_runs()`，只认领预算内的任务。这让它成为真正的全局硬上限，而非每轮都认领满导致在途无限堆积。

```python
# 伪代码：单轮认领 = 算剩余预算 -> claim -> 逐个 dispatch
async def run_once(now):
    budget = max_concurrent_runs - count_active_runs()   # 全局在途上限 - 当前在途
    if budget <= 0: return
    for task in claim_due_tasks(now, lease_owner, lease_seconds, limit=budget):
        await dispatch_task(task, now, trigger="scheduled")
```

### cron/once 纯计算分离（为什么单独一个模块）

`schedules.py` 是**纯函数、无副作用**模块：`next_run_at(schedule_type, schedule_spec, timezone_name, *, now) -> datetime | None`，不碰 DB、不认领任务。它与 poller 刻意分离，因为计算要在三处复用：

1. **路由层**（创建/更新任务时）：预演一次 `next_run_at` 校验规格合法（时区存在、cron 五字段）+ `once` 在未来 + 满足 `min_once_delay_seconds`，非法直接 422。
2. **poller 层**（认领后）：推算下一轮 `next_run_at` 写回任务行（cron 继续、once 已消费）。
3. **前端**（`cron.ts`）：本地 `describeSchedule` 预演展示，不依赖后端往返。

三处用**同一个** `next_run_at`，保证"创建时算的未来时刻"与"poller 算的"一致，不会出现任务永远不触发或提前触发。纯函数还意味着单测无需 mock 任何 IO。

### non_interactive 剥离 ask_clarification 完整链路（跨切不变量 1）

这是本 skill 最核心的设计。调度 run 无人盯屏，若 lead agent 调了 `ask_clarification`，`ClarificationMiddleware` 会 `Command(goto=END)` 中断 run 等用户回复--但调度通道没有"用户回复下一轮"的语义，run 会永久卡在 END，占用 `multitask_strategy="reject"` 的在途名额，且产出用户永远看不到的悬空澄清卡。需求是：**调度 run 必须不能调 `ask_clarification`**；同时**普通客户端不得能伪造"无人值守"**绕过澄清。

解法是**三道防线串联**（完整链路见 [references/code/non-interactive-stripping.md](./references/code/non-interactive-stripping.md)）：

1. **①调度入口注入**：`launch_scheduled_thread_run` 合成内部认证请求（`auth_source=AUTH_SOURCE_INTERNAL`）并塞 `context={"non_interactive": True}`。这是载荷的起点。
2. **②认证 + ③路由按身份接纳/抹除**：`merge_run_context_overrides(config, body.context, internal=is_internal_caller)` 仅对内部调用者把 `non_interactive` 纳入合并集合（写进 `configurable` + `context`）；`strip_internal_context_keys(config)` 对非内部调用者**无条件**从 `context`/`configurable` 两节抹除该 key。双层防御：merge 不接纳 + 装配后扫描抹除。
3. **④建图过滤**：`_make_lead_agent` 读 `non_interactive`，把 `ask_clarification` 从工具列表剥离（`_NON_INTERACTIVE_DISABLED_TOOL_NAMES = frozenset({"ask_clarification"})`）。直接不让模型"看见"该工具的 schema，比让模型调用后再拦截更省一次 LLM 往返、更确定。

```python
# 伪代码：三道防线串联（任一失守其余兜底）
# ① 调度入口：合成内部认证 + 注入 non_interactive
launch_scheduled_thread_run(context={"non_interactive": True}, auth_source=AUTH_SOURCE_INTERNAL)
# ② 认证分流：内部接纳 / 非内部抹除（双层防御）
if is_internal_caller: merge_run_context_overrides(config, body.context, internal=True)
else: strip_internal_context_keys(config)    # 无条件扫 context + configurable 两节
# ④ 建图过滤：读 non_interactive -> 剥离 ask_clarification
if cfg.get("non_interactive"): filtered = [t for t in filtered if t.name not in DISABLED_TOOLS]
```

白名单而非黑名单：`_CONTEXT_INTERNAL_CALLER_KEYS` 是显式白名单（目前仅 `non_interactive`），客户端能塞的 key 默认全部被当不可信。这把"哪些 key 可信"从"客户端说了算"翻转为"服务端说了算"。

纵深防御：即便 `ask_clarification` 没被剥离（如 GitHub webhook 通道走 `disable_clarification` 标志），`ClarificationMiddleware._is_disabled` 会读 `runtime.context.get("disable_clarification")`，命中则返回普通 `ToolMessage` 让 agent 继续跑而非 `Command(goto=END)`。两套机制覆盖不同通道，目标一致。

### overlap_policy（上一轮还在跑怎么办）

`overlap_policy="skip"`（当前唯一实现）：上一轮 run 还在途时，这一轮到期直接跳过（记 `skipped` occurrence），不抢占。两道检查：

1. **显式 `has_active_runs` 检查**（`dispatch_task` 开头）：对 `fresh_thread_per_run` 模式必须显式查--每次新线程，同线程 `multitask_strategy="reject"` 的 `ConflictError` 永远不会触发。在建本 dispatch 的 run 行之前查，否则把自己算进在途。
2. **launch 时 `ConflictError` 兜底**（`dispatch_task` except 分支）：`reuse_thread` 模式撞同线程在途 run，`_is_overlap_conflict` 识别后走 `_finalize_skip`。

`once` 任务被 skip 意味着唯一一次执行丢失，置 `failed` 并记 `last_error`；`cron` 任务继续 `enabled` 等下一轮。手动 trigger 撞在途 run 直接 409 拒绝（不记 skipped，因为本来就没调度要发生）。

```python
# 伪代码：dispatch_task 状态机骨架（完整见 references/code/scheduler-service.md §2）
async def dispatch_task(task, now, trigger):
    if overlap_policy == "skip" and has_active_runs(task.id):
        if trigger == "manual": return conflict          # 路由层 409
        skip_error = "skipped: previous run still active"
    create run 行(queued)
    if skip_error: return _finalize_skip(...)            # run 行 skipped + once->failed / cron->enabled
    try:
        result = launch_run(...)                         # -> launch_scheduled_thread_run
        next_at = next_run_at(...)                       # 推算下一轮（cron 继续 / once 已消费）
        task_status = "running" if once else ("paused" if manual&paused else "enabled")
        update_status(run, "running", protect_terminal=True)
        update_after_launch(task, task_status, next_at, protect_terminal=True)
        return launched
    except ConflictError if overlap skip: return _finalize_skip(...)   # launch 撞在途 -> skip
    except: update_status(run, "failed"); update_after_launch(task, _task_status_for_failure, ...)
```

### 崩溃恢复（进程死掉后任务不能永久卡住）

进程崩溃时，正在跑的调度 run 会在 DB 里留下两类"悬空"记录：run 行卡在 `running`/`queued`，once 任务行卡在 `running`（本应由已死的完成回调终结）。`start()` 在起 poller 主循环前做两步清扫，且都容错（失败只记日志不阻塞启动）：

- `mark_stale_active_runs`：run 行级，把上一进程遗留的 active run 行标 `interrupted`（error 文案为 `"interrupted: gateway restarted before the run reached a terminal state"`）。
- `cancel_stuck_once_tasks`：任务行级，把卡 `running` 的 once 任务行翻转。这是 `dispatch_task` 里"once 任务 launch 时置 `running` 不置 `completed`"决策的配套--若 launch 时就置 `completed`，崩溃后任务会卡 `completed` 永远不会再被认领（`claim_due_tasks` 只认 `enabled`）。

```python
# 伪代码：崩溃恢复两步（容错，失败只记日志不阻塞启动）
async def start():
    mark_stale_active_runs(error="interrupted: gateway restarted ...")   # 清遗留 active run 行
    cancel_stuck_once_tasks(error="interrupted: ...")                    # 清卡 running 的 once 任务行
    create_task(_run_loop())
```

`protect_terminal=True` 防 race：快速失败的 run 可能在 `dispatch_task` 的写回之前就到达 `handle_run_completion` 并把行终态化，`protect_terminal` 告诉仓储层"若行已是终态则不覆盖"。

### 关键不变量

1. **lease 互斥**：`claim_due_tasks` 原子认领 + `lease_owner` 唯一标识，多实例不重复执行同一任务。
2. **max_concurrent_runs 全局上限**：每轮算剩余预算，长 run 跨轮不超限。
3. **non_interactive 仅内部调用者生效**：三道防线（注入 + 门控接纳 + 抹除 + 建图剥离），客户端伪造无效。
4. **once 任务 launch 置 running 不置 completed**：等 `handle_run_completion` 真实终态；崩溃后 `cancel_stuck_once_tasks` 翻转。
5. **cron/once 纯计算无副作用**：路由/poller/前端三处复用同一 `next_run_at`。
6. **overlap skip 双检查**：`has_active_runs` 显式查 + launch `ConflictError` 兜底。

### 在端到端链路中的位置

本 skill 处于 [[e2e-request-lifecycle]] 的 **①入站** 跳（定时任务路径：`ScheduledTaskService poll -> launch_scheduled_thread_run -> start_run`），并 owning **跨切不变量 1**（non_interactive 剥离 ask_clarification）的入口与完整链路。调度路径在 ②认证处用内部合成用户汇合，此后 ③–⑧ 与 Web/IM 路径无差别。run 生命周期见 [[gateway-runs-and-sse]]；认证内部 token 见 [[auth]]；ask_clarification 中断语义见 [[system-prompt-template]]。

## 实现索引

> 约定：SKILL.md 只放设计架构思路 + 伪代码 + references 模块索引。**完整真实源码**在 `references/code/` 各模块文件（按独立功能模块细分），由下表建立索引。

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `scheduler/scheduler/service.py` | `ScheduledTaskService`：poller 主循环、lease 并发限流、cron/once 认领、overlap_policy、`dispatch_task`/`handle_run_completion`、崩溃恢复 | [scheduler-service.md](./references/code/scheduler-service.md) |
| `core/helix/scheduler/schedules.py` | `next_run_at`/`validate_timezone`/`normalize_cron_expression`：纯计算 cron/once 下次触发，无副作用 | [schedules-calc.md](./references/code/schedules-calc.md) |
| `gateway/gateway/services.py` | `launch_scheduled_thread_run`（桥接 + 注入 non_interactive）+ `merge_run_context_overrides`/`strip_internal_context_keys`/`_CONTEXT_INTERNAL_CALLER_KEYS`（白名单接纳 + 抹除） | [non-interactive-stripping.md](./references/code/non-interactive-stripping.md) |
| `core/helix/agents/lead/agent.py` | `_NON_INTERACTIVE_DISABLED_TOOL_NAMES` + `_make_lead_agent` 过滤分支（建图剥离 ask_clarification） | [non-interactive-stripping.md](./references/code/non-interactive-stripping.md) §5 |
| `core/helix/config/scheduler_config.py` | `SchedulerConfig`：enabled/poll_interval/lease_seconds/max_concurrent_runs/min_once_delay（restart-required） | [scheduler-service.md](./references/code/scheduler-service.md) §1 |
| `gateway/gateway/routers/scheduled_tasks.py` | REST 四件套：list/create/get/patch + pause/resume/trigger/delete + runs + thread 维度 list | [rest-router.md](./references/code/rest-router.md) |
| `frontend/src/core/scheduled-tasks/types.ts` | `ScheduledTask`/`ScheduledTaskRun` 类型契约 | [frontend-task-page.md](./references/code/frontend-task-page.md) §1 |
| `frontend/src/core/scheduled-tasks/api.ts` | REST 客户端：fetch/create/update/pause/resume/trigger/delete + runs | [frontend-task-page.md](./references/code/frontend-task-page.md) §2 |
| `frontend/src/core/scheduled-tasks/hooks.ts` | React Query hooks：useScheduledTasks/useCreateScheduledTask/useTriggerScheduledTask 等 | [frontend-task-page.md](./references/code/frontend-task-page.md) §3 |
| `frontend/src/core/scheduled-tasks/cron.ts` | 前端 cron 预设/解析/描述纯函数（与后端 `schedules.py` 对应的本地预演） | [frontend-task-page.md](./references/code/frontend-task-page.md) §4 |
| `frontend/src/app/workspace/scheduled-tasks/page.tsx` | 任务管理页：创建表单 + 列表 + 详情 + 运行历史 | [frontend-task-page.md](./references/code/frontend-task-page.md) §5 |

### 模块索引（references/code/）

| 文件 | 内容 |
|---|---|
| [scheduler-service.md](./references/code/scheduler-service.md) | `ScheduledTaskService` 完整源码（`run_once`/`dispatch_task`/`_finalize_skip`/`handle_run_completion`/`start`/`stop`/`_run_loop`）+ `SchedulerConfig` + lease/overlap/崩溃恢复/protect_terminal 设计点详解 + 生命周期时序 |
| [non-interactive-stripping.md](./references/code/non-interactive-stripping.md) | non_interactive 剥离完整链路：`launch_scheduled_thread_run` + `_CONTEXT_INTERNAL_CALLER_KEYS`/`strip_internal_context_keys`/`merge_run_context_overrides` + `start_run` 分流段 + worker `_build_runtime_context` + `_make_lead_agent` 过滤 + `disable_clarification` webhook 旁路 |
| [schedules-calc.md](./references/code/schedules-calc.md) | `schedules.py` 完整源码（`next_run_at`/`validate_timezone`/`normalize_cron_expression`）+ 纯函数设计要点 + 三处复用点 + 与 poller 的边界 |
| [rest-router.md](./references/code/rest-router.md) | REST 四件套完整源码：`ScheduledTaskCreateRequest` + `create_scheduled_task`（创建校验）+ `trigger_scheduled_task`（手动触发）+ 其余端点设计说明 |
| [frontend-task-page.md](./references/code/frontend-task-page.md) | 前端完整源码：`types.ts`（类型契约）+ `api.ts`（REST 客户端）+ `hooks.ts`（React Query hooks）+ `cron.ts`（cron 预设/解析纯函数）+ `page.tsx`（任务管理页结构） |

## 反模式与陷阱

- ❌ **poller 无 lease 致重复执行** -> 多实例部署时两个 poller 同时扫到同一到期任务，都 launch 一遍，任务重复执行（side effect 翻倍、cron 任务跑两次）。修复：`claim_due_tasks` 原子认领 + `lease_owner` 唯一标识 + `lease_expires_at` TTL，DB 行锁保证只一个实例抢到。
- ❌ **max_concurrent_runs 当单轮认领数** -> 每轮 `limit=max_concurrent_runs` 认领满，长 run 跨轮累积，在途 run 无限堆积超上限。修复：每轮先算 `budget = max_concurrent_runs - count_active_runs()`，只认领预算内。
- ❌ **non_interactive key 被客户端伪造** -> 普通 HTTP 客户端塞 `context={"non_interactive": True}` 强制 agent 跳过澄清、自主执行高风险动作（bash 删文件、update_agent 改 SOUL.md）。修复：三道防线--入口 `AUTH_SOURCE_INTERNAL` 标记 + `merge_run_context_overrides(internal=is_internal_caller)` 门控接纳 + `strip_internal_context_keys` 无条件抹除两节。
- ❌ **只靠建图剥离、漏了认证门控** -> 建图阶段漏读 `non_interactive`（如重构 `_get_runtime_config` 忘了叠 context），调度 run 调 `ask_clarification` -> `Command(goto=END)` -> 永久卡死 -> 占 `multitask_strategy="reject"` 在途名额 -> 同线程后续调度全 `ConflictError` -> cron 堆积。修复：三道防线串联，任一失守其余兜底。
- ❌ **cron 计算带副作用** -> 在 `next_run_at` 里写 DB/发请求/认领任务，导致路由校验路径（创建时预演）误触发副作用。修复：`schedules.py` 纯函数无副作用，认领归 poller 的 `claim_due_tasks`。
- ❌ **once 任务 launch 时置 completed** -> launch 后 run 失败或进程崩溃，任务卡 `completed` 永远不再被认领（`claim_due_tasks` 只认 enabled）。修复：launch 时置 `running`，等 `handle_run_completion` 真实终态；崩溃后 `cancel_stuck_once_tasks` 翻转。
- ❌ **overlap skip 只靠 ConflictError** -> `fresh_thread_per_run` 模式每次新线程，同线程 `ConflictError` 永远不触发，overlap 检查失效，任务并发跑。修复：`dispatch_task` 开头显式 `has_active_runs` 检查（在建本 dispatch run 行之前查）。
- ❌ **崩溃后不清扫 active run 行** -> 进程重启后上一进程遗留的 `running` run 行永远卡着，`count_active_runs` 把它们算进预算，新任务永远认领不到。修复：`start()` 里 `mark_stale_active_runs` + `cancel_stuck_once_tasks` 两步清扫。
- ❌ **protect_terminal 漏设** -> 快速失败的 run 在 `dispatch_task` 写回前就到 `handle_run_completion` 终态化，dispatch 的非终态写回冲掉终态，状态不一致。修复：`update_status`/`update_after_launch` 带 `protect_terminal=True`。
- ❌ **overlap_policy 选错** -> 调度任务本应 skip（上一轮没跑完就跳过这轮），却用了"抢占"语义，导致长 run 被反复打断。当前实现只有 `skip`（cron 周期任务的设计意图是"尽量跑、跑重叠就丢一次"）。若需要"排队"或"抢占"语义，须在 service 层显式实现并测覆盖。
- ❌ **改 SchedulerConfig 不重启** -> poller 在启动时读一次配置构造 service，改 `poll_interval_seconds`/`lease_seconds`/`max_concurrent_runs` 后不重启进程，poller 仍用旧值。修复：这些字段 restart-required，改后重启 Gateway。

## 落地参考（自测 / 调参 / 调试）

### 调参旋钮

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `scheduler.enabled` | `SchedulerConfig` | 默认 False；True 时 Gateway 启动才构造 poller 并 `start()` |
| `poll_interval_seconds` | `SchedulerConfig` | poller 主循环间隔，1–300s 默认 5；过短空轮询压 DB，过长 once 延迟触发 |
| `lease_seconds` | `SchedulerConfig` | lease TTL，5–3600s 默认 120；须 > 最长单 run 耗时（防重复认领），但太长则崩溃后接管延迟 |
| `max_concurrent_runs` | `SchedulerConfig` | 全局在途上限，1–32 默认 3；长 run 跨轮不超限 |
| `min_once_delay_seconds` | `SchedulerConfig` | once 任务最小提前量，1–86400s 默认 60；防"创建即过期" |
| `overlap_policy` | 任务行字段 | 当前唯一实现 `"skip"`；上一轮在途则跳过这轮 |
| `context_mode` | 任务行字段 | `fresh_thread_per_run`（每次新线程）/ `reuse_thread`（固定线程） |

### 关键日志串

- `Scheduled task poll failed; retrying next interval` - poller 单轮异常（非致命，下一轮重试；瞬时 DB 错误如 SQLite "database is locked"）
- `Marked %d stale scheduled task run(s) as interrupted after restart` - 崩溃恢复：清扫遗留 active run 行
- `Cancelled %d stuck once task(s) after restart` - 崩溃恢复：翻转卡 running 的 once 任务行
- `Failed to sweep stale scheduled task runs at startup` / `Failed to reconcile stuck once tasks at startup` - 崩溃恢复清扫失败（非阻塞，只记日志）
- `Create Agent(%s) -> thinking_enabled: %s, reasoning_effort: %s, model_name: %s, is_plan_mode: %s, subagent_enabled: %s, max_concurrent_subagents: %s` - ④建图（验证 non_interactive 是否影响工具集，查此 run 的工具列表）

### 自测方向

- **lease 互斥**：mock 两个 `ScheduledTaskService` 实例（不同 `lease_owner`）同时 `run_once`，断言同一到期任务只被一个实例认领；`claim_due_tasks` 的 `WHERE lease_expires_at < now` 行为。
- **max_concurrent_runs 全局上限**：mock `count_active_runs` 返回 = 上限，断言 `run_once` 直接 return 不认领；返回 < 上限时断言 `claim_due_tasks(limit=budget)` 用的是剩余预算。
- **cron 下次触发**：喂入 `(schedule_type, schedule_spec, timezone, now)`，断言 `next_run_at` 返回值（cron 跨时区/跨日/周几；once 未来返回时刻、过去返回 None）。纯函数无需 mock IO。
- **once 最小提前量**：创建 `once` 任务 `run_at` 在 `min_once_delay_seconds` 内 -> 422；刚好满足 -> 201。
- **overlap skip 互斥**：mock `has_active_runs` 返回 True，`dispatch_task(trigger="scheduled")` 断言走 `_finalize_skip`（outcome=skipped）；`trigger="manual"` 断言返回 conflict（路由层 409）。
- **non_interactive 剥离一致性**：mock `launch_scheduled_thread_run` 起 run，断言 `_make_lead_agent` 产出的 `final_tools` 不含 `ask_clarification`、`runtime.context["non_interactive"] is True`；普通 HTTP 客户端塞 `context={"non_interactive": True}`，断言 `ask_clarification` 仍在工具集、`config["context"]/["configurable"]` 中该 key 被 `strip_internal_context_keys` 抹除。
- **崩溃恢复**：mock DB 有 `running` run 行 + `running` once 任务行，调 `start()`，断言 `mark_stale_active_runs` 把 run 行标 interrupted、`cancel_stuck_once_tasks` 把 once 任务行翻转。
- **once 状态机**：`dispatch_task` once 任务 launch 后断言任务行 `status="running"`（非 completed）；`handle_run_completion(success)` 后断言 `completed`；`handle_run_completion(interrupted)` 后断言 `cancelled`。
- **protect_terminal**：mock `handle_run_completion` 在 `dispatch_task` 写回前触发，断言 `update_status(protect_terminal=True)` 不覆盖终态。
- **poller 容错**：mock `run_once` 抛异常，断言 `_run_loop` 不退出、记 `Scheduled task poll failed` 日志、下一轮继续。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 完整源码：[references/code/scheduler-service.md](./references/code/scheduler-service.md)、[references/code/non-interactive-stripping.md](./references/code/non-interactive-stripping.md)、[references/code/schedules-calc.md](./references/code/schedules-calc.md)、[references/code/rest-router.md](./references/code/rest-router.md)、[references/code/frontend-task-page.md](./references/code/frontend-task-page.md)
- 端到端链路（本 skill 处于 ①入站-scheduler 跳 + 跨切不变量 1 入口）：[[e2e-request-lifecycle]]
- 跨切不变量 1 完整推导：[../e2e-request-lifecycle/references/cross-cutting-invariants.md](../e2e-request-lifecycle/references/cross-cutting-invariants.md)
- run 生命周期（start_run -> run_agent，调度路径此后与 HTTP/IM 无差别）：[[gateway-runs-and-sse]]
- 内部认证 token + owner 头（调度路径的凭证来源）：[[auth]]
- ask_clarification 中断语义 + ClarificationMiddleware：[[system-prompt-template]]
- 前端任务页 / REST 四件套设计系统：[[frontend-app-design]]
- 配置与热重载（SchedulerConfig restart-required 字段）：[[config-and-hot-reload]]
