---
name: e2e-request-lifecycle
description: 端到端脊柱--通览 agent 平台一次请求的完整生命周期（入站->认证->路由->建图->中间件->执行->流式->渲染），含 Web 前端 / IM（钉钉）/ 定时任务三条入站路径与 3 个跨切不变量（non_interactive 剥离 ask_clarification、user_id 全链路隔离、StreamBridge×checkpointer×回滚）。每跳给入口伪代码 + organ 指向 + references 索引。当你想通览整个系统、排查跨子系统问题、或定位一次请求在某跳的行为时调用本 skill。
---

## 何时用

- 想通览整个 agent 平台、看清一次请求端到端怎么流转
- 排查"跨子系统"的问题（症状在渲染、根因在认证；症状在工具、根因在建图）
- 新增一条入站路径，需要确认它与已有路径共用 ②–⑧ 后段
- 评审某个改动是否波及 3 个跨切不变量之一
- 给新人 / AI 讲解整体架构--本 skill 是地图，organ skill 是深度

> 单看任一 organ skill 只见一隅；本脊柱给全链路地图，把每个 organ 钉在它该在的那一跳上。

## 设计方案（为什么这么设计）

### 核心矛盾：链路孤岛

Agent 平台被拆成 28 个 organ skill（运行时 / 工具执行 / 多代理 / 用户态 / 服务化 / 跨切 / 知识库 / 平台维度），每个 organ 深挖一个子系统。但**没有任何单个 organ 能回答"一次请求是怎么从浏览器走到渲染的"**--这条链横穿 7 个以上的 organ。于是出现"链路孤岛"：每个局部都对，拼不起来。

**解法：一条贯通叙事。** 本脊柱用一次真实请求走完 8 跳，每跳只给**入口伪代码 + organ 指向 + references 索引**（地图级粒度）。脊柱不重复 organ 的深度，只回答"这一跳在哪、把球交给谁"。完整源码归 `references/code/` 各跳模块文件。

### 8 跳链路架构图

```
①入站  ┬─ Web 前端 -> useStream(SDK) -> /api/langgraph/*/runs/stream（nginx 重写）
       ├─ IM(钉钉) -> dingtalk-stream 出站长连接 -> MessageBus -> ChannelManager -> client.runs.wait
       └─ 定时任务 -> ScheduledTaskService poll -> launch_scheduled_thread_run -> start_run
②认证   AuthMiddleware(fail-closed)：JWT cookie(Web) / 内部 token 头(scheduler+channels) / OAuth -> user_context contextvar
③路由   gateway router -> RunManager.create_or_reject -> worker(run_agent) + checkpointer
④建图   make_lead_agent(每 run 一次)：apply_prompt_template(静态) + 装配工具 + build_middlewares
⑤中间件 before_model 正序 / after_model 逆序：动态注入 -> SystemMessage 合并 -> 上下文窗 -> 延迟工具过滤 -> 护栏 -> Clarification(末尾)
⑥执行   lead agent loop：模型 -> 工具调用 -> 沙箱(虚拟路径) / task() 子代理 / mcp / skills
⑦流式   stream_mode 映射 -> SSE 事件 -> StreamBridge（Last-Event-ID 续传）
⑧渲染   ┬─ 前端 useStream 回调 -> 乐观合并(mergeMessages) -> markdown 渲染
        └─ IM channel send（钉钉 AI Card 流式 patch / sampleMarkdown 回退）
```

### 关键不变量：三条入站路径共用 ②–⑧ 后段

Web、IM、定时任务三条入站路径在 ② 认证处汇合（三种凭证各自解析出 `user`，写入同一个 `user_context` contextvar），此后 ③–⑧ 完全一致。

```python
# 伪代码：三路径在 ②认证汇合到同一 contextvar，此后 ③–⑧ 无感
# ① Web:    JWT cookie -> get_current_user_from_request -> user
# ① IM:     内部 token 头 + owner 头 -> get_internal_user(owner) -> user
# ① 调度:   合成内部用户 -> get_internal_user() -> user
# ②认证：三路汇合
token = set_current_user(user)      # 写 contextvar（跨切不变量 2）
try:  return await call_next(request)   # ③–⑧ 只读 contextvar，不再关心凭证来源
finally:  reset_current_user(token)
```

这意味着：改 ②–⑧ 任一跳，**必须同时验证三条入站路径**都未回归。三条路径的差异只在于"凭证怎么来"和"渲染回哪里"：Web 走 JWT cookie + 前端 markdown；IM 走内部 token 头 + 平台消息回退；定时任务走内部合成用户 + 无渲染（无人值守）。

### 3 个跨切不变量（概要，完整推导见 references/cross-cutting-invariants.md）

有些约束**不属于任何单跳**，而是横跨多跳的协议。它们是系统正确性的支柱，单看任一 organ 会漏。

| # | 不变量 | 横穿跳 | 一句话 |
|---|---|---|---|
| 1 | non_interactive 剥离 ask_clarification | ①②③④ | 调度注入 `non_interactive` -> 建图剥离该工具；该 key 仅内部认证生效，客户端塞入被抹除 |
| 2 | user_id 全链路隔离 | ②③④⑤⑥ | 认证解析 -> per-user 目录（uploads/workspace/outputs/memory/agents） |
| 3 | StreamBridge × checkpointer × 回滚 | ③⑦+取消 | Last-Event-ID 续传 + pre-run checkpoint 回滚（长任务取消） |

### 在端到端链路中的位置

本 skill **就是**端到端链路本身。所有 organ skill 以 `[[e2e-request-lifecycle]]` 反向引用本脊柱，标记自己处于哪一跳；本脊柱则正向引用每个 organ，把深度交还。

## 实现索引

### 8 跳清单（每跳一行 + organ 指向 + references 索引）

| 跳 | 入口 | organ 指向 | references/code 模块 |
|---|---|---|---|
| ①入站 | Web `useStream` / IM `dingtalk-stream`+`MessageBus` / 调度 `ScheduledTaskService` poll | `[[gateway-runs-and-sse]]` `[[frontend-app-design]]` `[[im-channels]]` `[[scheduled-tasks]]` | [01-inbound-paths.md](./references/code/01-inbound-paths.md) |
| ②认证 | `AuthMiddleware.dispatch`（fail-closed） | `[[auth]]` `[[multi-user-isolation]]` | [02-auth-gate.md](./references/code/02-auth-gate.md) |
| ③路由 | `stream_run` 端点 -> `RunManager.create_or_reject` -> `run_agent` | `[[gateway-runs-and-sse]]` `[[long-running-and-cancellation]]` | [03-routing-and-run-manager.md](./references/code/03-routing-and-run-manager.md) |
| ④建图 | `make_lead_agent`（每 run 一次） | `[[agent-graph-factory]]` `[[system-prompt-template]]` `[[tool-assembly-and-policy]]` | [04-graph-factory.md](./references/code/04-graph-factory.md) |
| ⑤中间件 | `build_middlewares`（29 项链） | `[[middleware-chain-design]]` `[[context-window-management]]` `[[safety-and-guardrails]]` | [05-middleware-chain.md](./references/code/05-middleware-chain.md) |
| ⑥执行 | lead agent loop -> `get_available_tools` + 沙箱 + `task()` | `[[tool-assembly-and-policy]]` `[[sandbox-abstraction]]` `[[subagent-delegation]]` `[[mcp-integration]]` | [06-execution-tools.md](./references/code/06-execution-tools.md) |
| ⑦流式 | `_lg_mode_to_sse_event` -> `bridge.publish` | `[[gateway-runs-and-sse]]` `[[frontend-streaming-protocol]]` | [07-streaming-and-resume.md](./references/code/07-streaming-and-resume.md) |
| ⑧渲染 | 前端 `mergeMessages` / IM AI Card patch | `[[frontend-streaming-protocol]]` `[[frontend-app-design]]` `[[im-channels]]` | [08-rendering.md](./references/code/08-rendering.md) |

### 每跳入口伪代码

**① 入站（三条路径）**

```python
# 伪代码：三路径入口（完整源码见 references/code/01-inbound-paths.md）
# Web:   useStream(SDK) -> /api/langgraph/*/runs/stream（nginx 重写）-> SSE
# IM:    dingtalk_stream 出站长连接回调 -> MessageBus.publish_inbound -> ChannelManager._dispatch_loop
#        -> client.runs.wait(headers=内部认证 owner 头)
# 调度:  ScheduledTaskService.run_once -> claim_due_tasks(lease 并发限流) -> launch_scheduled_thread_run
#        -> start_run(context={"non_interactive": True})   # 跨切不变量 1 起点
```

**② 认证（三凭证汇合）**

```python
# 伪代码：AuthMiddleware fail-closed（完整源码见 references/code/02-auth-gate.md）
if is_valid_internal_auth_token(头):  user = get_internal_user(owner)      # IM/调度：内部 token + owner 头
elif cookie:  user = await get_current_user_from_request(request)          # Web：JWT 严格校验
elif is_auth_disabled():  user = get_auth_disabled_user()                 # 本地/E2E 合成 admin
else:  return 401                                                          # fail-closed
request.state.user = user;  token = set_current_user(user)                 # 写 contextvar（跨切不变量 2）
# owner 头仅在内部 token 校验通过后生效；浏览器塞的 owner 头被忽略
```

**③ 路由（原子注册 + pre-run 快照）**

```python
# 伪代码：SSE 端点 -> RunManager -> worker（完整源码见 references/code/03-routing-and-run-manager.md）
@require_permission("runs","create", owner_check=True, require_existing=True)  # per-resource owner 校验
async def stream_run(...):  record = await start_run(body, thread_id, request)
# RunManager.create_or_reject: 持锁消除 TOCTOU；multitask=reject 抛 ConflictError / interrupt|rollback 设 abort_action
# worker: 运行前快照 pre_run_checkpoint_id（跨切不变量 3 回滚锚点）-> astream -> publish 到 bridge
# 终结: abort_action=="rollback" -> _rollback_to_pre_run_checkpoint 写新 checkpoint 载 pre-run 状态
```

**④ 建图（每 run 一次的 graph factory）**

```python
# 伪代码：make_lead_agent（完整源码见 references/code/04-graph-factory.md）
def _make_lead_agent(config, *, app_config):
    cfg = _get_runtime_config(config)   # 合并 configurable + context
    non_interactive = bool(cfg.get("non_interactive"))
    filtered = filter_tools_by_skill_allowed_tools(get_available_tools(...) + extra, skills)
    if non_interactive:  filtered = [t for t in filtered if t.name not in _NON_INTERACTIVE_DISABLED_TOOL_NAMES]  # 跨切不变量 1 落点
    final_tools, setup = assemble_deferred_tools(filtered)
    return create_agent(model=..., tools=final_tools, middleware=build_middlewares(...),
                        system_prompt=apply_prompt_template(...), state_schema=ThreadState)
# 防御：strip_internal_context_keys 抹除非内部调用者塞的 non_interactive（白名单 + 双层防御）
```

**⑤ 中间件（29 项链）**

```python
# 伪代码：build_middlewares 续装 13–29（完整源码见 references/code/05-middleware-chain.md）
# 共享基座 build_lead_runtime_middlewares 装 1–12（InputSanitization 最外层 -> ... -> ToolErrorHandling）
# lead 专用续装 13–29：DynamicContext(13) -> SkillActivation(14) -> ... -> SystemMessageCoalescing(23) -> ... -> Clarification(29 链尾)
# before_model 正序 / after_model 逆序 / wrap_model_call+wrap_tool_call 洋葱模型（第1项最外层）
# 顺序不变量：Clarification 必须最后（中断型）；ToolProgress 外于 ToolErrorHandling（构建时断言守护）
```

**⑥ 执行（工具调用循环）**

```python
# 伪代码：lead agent loop 驱动工具（完整源码见 references/code/06-execution-tools.md）
# get_available_tools: config 定义(bash/read_file) + builtin(present_files/ask_clarification) + MCP + ACP
# 沙箱: bash_tool 做 /mnt/user-data/* -> 物理路径映射（最长前缀优先），输出 mask 还原虚拟路径
# task(): execute_async 立即返回 task_id，后台独立图(checkpointer=False)+独立隔离事件循环，copy_context 继承 user_id
```

**⑦ 流式（stream_mode 映射 + StreamBridge）**

```python
# 伪代码：worker publish + bridge subscribe（完整源码见 references/code/07-streaming-and-resume.md）
# lg_modes: messages-tuple->messages, events 跳过, 无合法模式默认 values; _lg_mode_to_sse_event 1:1 映射
# bridge.publish(run_id, sse_event, chunk) -> 事件 id = {ts}-{seq}（seq=绝对偏移）
# sse_consumer: subscribe(last_event_id=Last-Event-ID 头) -> _resolve_start_offset 用 seq 做 O(1) 算术定位
# buffer 有界(256)：溢出驱逐最旧+start_offset 前移；陈旧/驱逐/伪造 id 降级从最早保留事件重放
```

**⑧ 渲染（前端合并 + IM AI Card）**

```python
# 伪代码：前端三路合并 + IM 卡片流式（完整源码见 references/code/08-rendering.md）
# 前端 mergeMessages: 历史 + 实时流 + 乐观消息，从尾扫描找重叠后缀切掉再拼接，dedupeMessagesByIdentity 兜底
# 钉钉: _stream_update_card(out_track_id, content, finished=is_finalize) -> PUT /v1.0/card/streaming 原地更新同一卡片
#        卡片流失败仅最终消息回退 sampleMarkdown（中间不回退避免刷屏）
```

### 3 跨切不变量概要（完整推导见 [references/cross-cutting-invariants.md](./references/cross-cutting-invariants.md)）

**1. non_interactive 剥离 ask_clarification（无人值守不卡死）**

定时任务 / 后台 run 无人盯屏，若模型调 `ask_clarification`，run 会 `Command(goto=END)` 中断等回复，永远卡住。三道防线串联：①调度 `launch_scheduled_thread_run` 注入 `context={"non_interactive": True}` + `AUTH_SOURCE_INTERNAL` 标记 -> ②③ `merge_run_context_overrides(internal=True)` 仅对内部调用者接纳该 key，`strip_internal_context_keys` 无条件抹除客户端塞入的 -> ④建图 `_make_lead_agent` 把 `ask_clarification` 从工具列表剥离。纵深防御：webhook 通道走 `disable_clarification`，`ClarificationMiddleware._is_disabled` 放行已调用。指向：`[[scheduled-tasks]]` `[[system-prompt-template]]`

**2. user_id 全链路隔离（per-user 目录）**

② 认证解析出的 `user` 写入 `user_context` contextvar，③–⑧ 全靠 `get_effective_user_id()` 读它定位文件系统桶：`data/helix/users/{user_id}/threads/{thread_id}/user-data/{workspace,uploads,outputs}`、`memory.json`、自定义 `agents/`。三路径 `user_id` 来源不同但汇合到同一 contextvar：Web=JWT 用户；IM=内部 token + owner 头（`make_safe_user_id` 规范化防路径穿越）；调度=内部合成用户。无认证回退 `"default"`。owner 头仅在内部 token 校验通过后生效。跨边界用 `resolve_runtime_user_id` 三级回退（runtime.context > contextvar > DEFAULT_USER_ID）。指向：`[[auth]]` `[[multi-user-isolation]]`

**3. StreamBridge × checkpointer × 回滚（断流续传 + 长任务取消）**

续传：每个 SSE 事件带 `id={ts}-{seq}`（⑦StreamBridge），客户端断线后用 `Last-Event-ID` 重连，`subscribe(last_event_id=...)` 用 `seq` 做 O(1) 算术定位，从断点续发（buffer 有界，旧事件驱逐后从最早保留事件重放）。回滚：③ worker 运行前快照最新 checkpoint（`pre_run_checkpoint_id`）；若 run 被 `multitask_strategy="rollback"` 取消或 `CancelledError`，`_rollback_to_pre_run_checkpoint` 在 checkpointer 上写一个新 checkpoint 标记（新 id/ts，旧 channel_values），把线程状态恢复到 run 开始前。两套机制独立但协作：续传保"看到的事件流不丢"，回滚保"取消后状态干净"。指向：`[[gateway-runs-and-sse]]` `[[long-running-and-cancellation]]`

## 反模式与陷阱

- ❌ **只看单个 organ 不通览链路** -> 改一个中间件不知道它影响 ⑥执行 与 ⑧渲染；改认证不知道它波及所有 per-user 目录。修复：改任何一跳前先读本脊柱定位它在链上的位置与跨切不变量。
- ❌ **改一条入站路径不验证另两条共用后段** -> 例如给 Web 加了个 context key 期望建图读它，但忘了 IM/scheduler 路径没塞这个 key，三条路径行为分叉。修复：改 ②–⑧ 任一跳，用"mock 三条入站路径断言 ②–⑧ 一致"的自测（见落地参考）。
- ❌ **忽略 3 个跨切不变量** -> 典型：新增一个"可中断"的工具但没考虑 `non_interactive` 剥离，导致调度 run 卡死；或新通道忘了带 owner 头，文件落到 `"default"` 桶串用户；或新流式端点没接 StreamBridge 的 `Last-Event-ID`，长任务断流后无法续传。修复：改动落到这三条任一覆盖面时，读 `references/cross-cutting-invariants.md`。
- ❌ **在 core 层 import 应用层** -> 例如在 `core/helix/` 里 `from gateway.internal_auth import ...`，破坏单向依赖边界（CI 边界测试会拦）。修复：core 只读 contextvar，凭证解析归应用层。
- ❌ **把品牌字样写进 skill** -> 匿名化漏项（项目品牌词及其大小写/连字符变体）。修复：按 CONVENTIONS §3 映射表统一替换，落地后跑 §6 验证命令须 CLEAN。
- ❌ **用伪代码 / `...` 截断写 references** -> 失去"真实落地参考"价值。修复：references/code/ 放完整真实源码；SKILL.md 伪代码忠实反映真实链路入口签名 + 核心逻辑。

## 落地参考（调试入口 / 自测方向）

**调试入口（沿链路追一条请求）**

| 现象 | 看哪里 |
|---|---|
| 请求没到 agent | ② `AuthMiddleware.dispatch` 是否 401；nginx 是否正确重写 `/api/langgraph/*` |
| run 卡住不流 | ③ `RunManager.create_or_reject` 是否 `ConflictError`（thread 已有在途 run） |
| 模型不调工具 / 调错工具 | ④ `_make_lead_agent` 的工具过滤 + `non_interactive` 剥离分支；⑤ `DeferredToolFilter` 是否误藏 |
| 工具执行行为怪 | ⑥ `bash_tool` 的虚拟路径映射；沙箱 provider 是否拿到对的 thread 目录 |
| SSE 断流后丢事件 | ⑦ StreamBridge 的 `_resolve_start_offset`；客户端是否带 `Last-Event-ID` |
| 取消后状态没回滚 | ③ worker 的 `_rollback_to_pre_run_checkpoint`；`multitask_strategy` 是否 `"rollback"` |
| IM 消息归属错用户 | ② owner 头是否生效（`get_trusted_internal_owner_user_id`）；`make_safe_user_id` 规范化 |

**关键日志串（trace_id 串起一次请求）**

- `Run created: run_id=... thread_id=...` - ③ 注册 run
- `Run %s: streaming with modes %s (requested: %s)` - ⑦ stream_mode 落定
- `[Manager] received inbound: channel=..., chat_id=..., type=...` - ① IM 入站
- `Scheduled task poll failed; retrying next interval` - ① 调度轮询异常（不致命）
- `Run %s rolled back to pre-run checkpoint %s` - ③ 回滚生效
- `last_event_id=%s not found in retained buffer; replaying from earliest retained event` - ⑦ 续传降级
- `DynamicContextMiddleware: injecting full reminder ...` - ⑤ 中间件链运转

**端到端自测方向**

- **三条入站路径一致性**：分别用 mock Web（JWT cookie）、mock IM（内部 token + owner 头）、mock 调度（`launch_scheduled_thread_run`）发起同一条 prompt，断言 ②–⑧ 的可观察输出一致（同一 user_id 桶、同一工具集、同一 SSE 事件序列）。
- **跨切不变量 1**：HTTP 客户端塞 `context={"non_interactive": True}`，断言 `ask_clarification` **仍在**工具集（被抹除）；调度路径断言 `ask_clarification` **不在**工具集。
- **跨切不变量 2**：两个不同 owner 头的 IM 消息，断言落到不同 user_id 桶；无 owner 头落 `"default"`。
- **跨切不变量 3**：发起一个长 run，中途断 SSE，用 `Last-Event-ID` 重连，断言续传无丢；`multitask_strategy="rollback"` 取消后，断言 checkpointer 回到 run 前 checkpoint（无半截 messages）。
- **链路冒烟**：`make_lead_agent` 对相同入参产出确定性工具集 + 中间件链顺序。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 跨切不变量完整推导：[./references/cross-cutting-invariants.md](./references/cross-cutting-invariants.md)
- 各跳真实源码深读：[./references/code/](./references/code/)（01 入站 / 02 认证 / 03 路由 / 04 建图 / 05 中间件 / 06 执行 / 07 流式 / 08 渲染）
- 入口元 skill：[[using-agent-system-design]]
- 8 跳对应的 organ skill：
  - ①入站：[[gateway-runs-and-sse]]、[[frontend-app-design]]、[[im-channels]]、[[scheduled-tasks]]
  - ②认证：[[auth]]、[[multi-user-isolation]]
  - ③路由：[[gateway-runs-and-sse]]、[[long-running-and-cancellation]]
  - ④建图：[[agent-graph-factory]]、[[system-prompt-template]]、[[tool-assembly-and-policy]]
  - ⑤中间件：[[middleware-chain-design]]、[[context-window-management]]、[[safety-and-guardrails]]
  - ⑥执行：[[sandbox-abstraction]]、[[sandbox-tools-and-safety]]、[[subagent-delegation]]、[[mcp-integration]]
  - ⑦流式：[[frontend-streaming-protocol]]、[[gateway-runs-and-sse]]
  - ⑧渲染：[[frontend-streaming-protocol]]、[[frontend-app-design]]、[[im-channels]]
- 跨切支撑：[[observability-tracing]]（trace_id 归并）、[[core-app-boundary]]（core↔app 单向依赖）、[[config-and-hot-reload]]（每 run 配置解析）
