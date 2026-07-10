---
name: subagent-delegation
description: 设计主代理→子代理的任务委派——task() 工具协议、scheduler 线程池 + 持久 isolated event loop（loop-affine 句柄跨线程 marshal）、tool_call_id 即 task_id、独立图（checkpointer=False）、MAX_CONCURRENT_SUBAGENTS 并发硬上限（SubagentLimitMiddleware 截断超额）、guardrail 三轴（turn/token/loop）+ additive stop_reason（token_capped/turn_capped/loop_capped）。给出完整、未截断的真实代码（执行器/工具/护栏/步骤捕获）。当你要实现主→子委派、排查子代理超时/循环/超额并发、或想读懂 guardrail cap 如何向后兼容地冒泡到主代理时调用本 skill。
---

## 何时用

- 实现"主代理把一个子任务折叠成一次 `task()` 工具调用、后台跑完再回填结果"
- 想让子代理跑在独立图 + 独立事件循环上，与主对话的 checkpointer / 中间件链隔离
- 排查子代理：超时（timeout / polling_timed_out）、撞 max_turns、被 token budget 或 loop detection 截断、单条响应超额 `task` 调用被砍
- 想读懂 guardrail cap 如何以 additive `stop_reason` 冒泡到主代理（而非新增 status 枚举）
- 需要在主代理视角聚合子代理 token 用量、或把子代理 trace 挂到父 thread session

> 本 skill 处于端到端链路的 **⑥执行（子代理委派）** 跳：主代理模型循环驱动 `task()` 工具，工具在后台线程调度子代理图，子代理在持久 isolated event loop 上跑到终态后回填 `ToolMessage`。见 `[[e2e-request-lifecycle]]`。

## 设计方案（为什么这么设计）

### 核心定位：`task()` 是工具，不是图节点

主代理调 `task(description, prompt, subagent_type)`，在模型视角与一次普通工具调用无异；内部异步起子代理图、轮询终态、回填 `ToolMessage`。这样做有三个直接收益：

1. **对主代理模型零认知负担**——它只看到"调一个工具、拿一段文本结果"，不需要知道子代理是另一张图、另一套中间件。
2. **天然可追溯**——`tool_call_id` 复用为 `task_id`，子代理的 token 用量、状态、trace 全部按这同一个 id 关联回触发它的那条 `AIMessage`。
3. **与主图 checkpointer 隔离**——子代理图编译 `checkpointer=False`，不会把一次性任务的中间态写进父线程的 checkpoint 命名空间。

### 双执行基座：scheduler 线程池 + 持久 isolated event loop（而非两个 ThreadPoolExecutor）

> **勘误**：历史描述曾称"双线程池 `_scheduler_pool` + `_execution_pool`"。真实源码只有**一个** `ThreadPoolExecutor`（`_scheduler_pool`，3 workers）；"执行"侧是一个跑在 daemon 线程上的**持久 asyncio event loop**，不是第二个线程池。下面的设计解释为什么必须是这个形态。

子代理图是异步的（`agent.astream(...)`），而 `task()` 工具从主代理的 ASGI 事件循环被调用。直接在主循环上 `await agent.astream(...)` 会阻塞整个 Gateway 的所有并发请求；用 `asyncio.run` 每次起新 loop 又会让 httpx 客户端、MCP 异步会话、DB 连接等 **loop-affine** 资源绑定到一个短命 loop，loop 一关就 `PoolClosed`，下次重建代价巨大。

**解法是两层执行基座：**

- **scheduler 线程池**（`_scheduler_pool = ThreadPoolExecutor(max_workers=3, ...)`）：承担"启动 + 等待终态"的编排。`execute_async()` 把一个 `run_task` 闭包提交进来，线程内设置 `RUNNING` 状态、再向 isolated loop 投递协程、按 `timeout_seconds` 等待 future、超时则 `cancel_event.set()` + `try_set_terminal(TIMED_OUT)`。这一层是纯 Python 编排，很轻，3 个 worker 足够。
- **持久 isolated event loop**（`_isolated_subagent_loop`，daemon 线程 `subagent-persistent-loop`）：真正执行子代理图的长生命周期 asyncio loop。进程级单例，懒启动，`atexit` 注册关闭。所有子代理协程都在它上面跑，共享的 httpx/MCP 客户端绑定到它，永不随单次任务关闭。

**跨线程 marshal 的关键不变量**：scheduler 线程池的线程**不直接 await 协程**，而是用 `asyncio.run_coroutine_threadsafe(coro, isolated_loop)` 把协程投递到 isolated loop，再 `future.result(timeout=...)` 在调度线程阻塞等结果。这一步还必须包在 `parent_context.run(...)` 里——`copy_context()` 抓父 ContextVar 快照（`user_id`、`effective_user_id` 等），`context.run(lambda: run_coroutine_threadsafe(...))` 确保子协程在 isolated loop 上恢复时 ContextVar 不丢。少了 `copy_context()`，IM 多用户场景下子代理 `user_id` 全退化到 `"default"`，文件落错 owner。

**为什么不直接用第二个 ThreadPoolExecutor 跑协程**：`ThreadPoolExecutor` 的线程没有持久的 asyncio loop；`asyncio.run` 会建一个临时 loop 又立即关闭，loop-affine 资源随之报废。持久 loop 必须由 `loop.run_forever()` 在专用线程驱动，这才是"执行侧"的真实形态。换言之：**调度是线程池的活，执行是 event loop 的活**，两者用 `run_coroutine_threadsafe` 桥接。

### 独立图 + `checkpointer=False`：一次性、不 resume

子代理编译 `create_agent(..., checkpointer=False)`：

- **一次性**：子代理是一次任务，跑完即弃，不需要持久化中间 super-step、也不需要 resume。
- **隔离父 checkpointer**：若继承父图的 checkpointer，子代理的中间 checkpoint 会写进父线程的 checkpoint 命名空间，污染父对话历史、且会在 multitask interrupt/rollback 时把子代理的半截产物带进回滚快照。
- `system_prompt=None`——子代理的系统提示词拼进初始 `SystemMessage`（与 skill 内容、deferred 段合并为**单条** `SystemMessage`），避免某些 provider（OpenAI legacy）拒收多条 SystemMessage。

### `tool_call_id == task_id`：把账目、状态、trace 串起来

`task()` 工具签名注入 `tool_call_id: Annotated[str, InjectedToolCallId]`，执行器入口 `executor.execute_async(prompt, task_id=tool_call_id)` 直接复用它做 `task_id`。于是：

- **token 归并**：`task_tool` 缓存 `_subagent_usage_cache[tool_call_id]`，主代理的 `TokenUsageMiddleware` 据此把子代理用量回填到触发它的那条 `AIMessage.usage_metadata`（按消息位置匹配）。
- **结果关联**：`ToolMessage(tool_call_id=tool_call_id, name="task", ...)` 让主代理模型把结果与它的 tool_call 一一配对。
- **trace 挂载**：`langfuse_session_id = 父 thread_id`，子代理 trace 名 `subagent:<name>`，直接挂在父 thread 的 session 卡下。

### 并发硬上限：批次编排 + 超额截断

子代理是重资源（一张图、一整套中间件、可能 max_turns=150）。并发不加约束时，模型一条响应里发 6 个 `task()` 就会同时起 6 张图。系统提示词先做**软约束**：

```
HARD LIMIT: max {N} `task` calls per response. If >{N} sub-tasks,
split into sequential batches of ≤{N}. Synthesize after ALL batches complete.
```

但 prompt 约束不可靠——模型仍会超额。于是 `SubagentLimitMiddleware` 在 `after_model` 做**硬截断**：扫描最后一条 `AIMessage` 的 `tool_calls`，若 `name == "task"` 的调用数超过 `max_concurrent`（默认 `MAX_CONCURRENT_SUBAGENTS = 3`，clamp 到 `[2, 4]`），**只保留前 N 个**，丢弃其余，用 `clone_ai_message_with_tool_calls(msg, truncated)` 重写消息（同 id 触发 LangGraph reducer 替换）。

- 为什么截断而不是排队：排队会让一次工具调用变成串行长链路，模型也看不到排队状态；截断 + prompt 批次指引让模型自己分批，语义清晰。
- 放在 `after_model`（逆序派发的安全/循环之后注册，所以执行更晚）：等 SafetyFinishReason 清掉异常、LoopDetection 修剪完重复 tool_calls 后，截断才在干净输入上做最终裁剪。

### Guardrail 三轴：turn / token / loop，全部"软停"不抛异常

子代理继承主代理的运行时基座中间件，其中三个独立轴都能让 run 提前结束：

| 轴 | 触发点 | 机制 | 是否抛异常 |
|---|---|---|---|
| **turn** | `recursion_limit` == `config.max_turns`（general-purpose=150） | `agent.astream` 抛 `GraphRecursionError` | **抛**（executor 专门 catch） |
| **token** | `TokenBudgetMiddleware`（默认 2,000,000 tokens，0.7 warn，1.0 hard-stop） | hard-stop **剥离**当前 turn 的 `tool_calls`、强制 `finish_reason="stop"` | **不抛**（run 自然完成出最终答案） |
| **loop** | `LoopDetectionMiddleware`（同集合重复调用 warn=3/hard=5，或单工具频率 warn=30/hard=50） | hard-stop 同样剥离 `tool_calls` + 强制收尾 | **不抛** |

**为什么 token / loop 不抛异常而要"软停"**：抛异常会让 run 整个失败、丢弃已产出的可用结果。软停则让模型用已收集到的信息收尾出最终答案——大部分情况下子代理仍能交出有价值的部分成果（`_extract_final_result` 从最后一个 streamed chunk 抽出最后一条 `AIMessage` 文本，走 `message_content_to_text` 统一处理 str / list-of-blocks 两种 content 形态；无文本则返回 `"No response generated"` 哨兵）。

### Additive `stop_reason`：向后兼容地冒泡 cap 原因

三个轴都可能"提前结束但仍有产物"。如何让主代理区分"干净完成"与"被截断但仍可用"？**不加新 status 枚举，加一个 additive 字段 `stop_reason`。**

- **为什么不是新枚举**：新增 `SubagentStatus.MAX_TURNS_REACHED` 会破坏 v1 契约消费者（前端 `subtask-result.ts`、持久化 delegation ledger、`contracts/subagent_status_contract.json`）；可选字段则被旧消费者静默忽略。
- **值域**：`token_capped` / `turn_capped` / `loop_capped`（`SubagentStopReasonValue` Literal，由契约 fixture 跨 Python/TypeScript 钉死）。
- **收集机制（duck-typed）**：每个护栏中间件暴露 `consume_stop_reason(run_id) -> str | None`。执行器在 `_create_agent` 装配完中间件链后，用 `hasattr(m, "consume_stop_reason")` 收集**所有**具此方法的中间件（list，不是 `next(...)`），run 结束后逐个 `consume_stop_reason(self.run_id)`，返回首个非 `None`。这样**新增护栏不需要改执行器**——只要新中间件实现这个方法就自动被收集。
- **状态映射**：`completed + stop_reason=token_capped|turn_capped|loop_capped`（产出了可用结果/部分）；`failed + stop_reason=turn_capped`（`GraphRecursionError` 且无可用的最后一条 AIMessage 文本）。
- **冒泡链路**：`SubagentResult.stop_reason` → `task_tool._task_result_command` → `format_subagent_result_message`（渲染 `Task Succeeded (capped: token budget). Result: ...`）/ `make_subagent_additional_kwargs`（在 `additional_kwargs` 上盖 `subagent_stop_reason` 键，与正常 `subagent_status` 并列）。

### 步骤捕获：`stream_mode="values"` 尾部扫描，多工具调用 turn 不丢

`stream_mode="values"` 每个 super-step 重新 yield 整个 state，意味着同一条尾部消息被反复扫到；更关键的是，一个 super-step 内 LangGraph 的 `ToolNode` 可能一次 append **多条** `ToolMessage`（模型一条 turn 发了多个 tool_call），只看 `messages[-1]` 会丢掉除最后一条以外的所有 tool 输出。`capture_new_step_messages` 用一个 `processed_count` 游标只扫**新增尾部**，`seen_message_ids: set[str]` 按 message `id` 做 O(1) 去重（避免 max_turns=150 深度任务里 O(n²) 扫描堆到 LLM 链路）；message 无 id 时退化到全 dict 比较。

## 完整真实代码实现

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构 `helix.*`，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。大文件拆到 `references/code/`，本节给文件清单 + 入口片段 + 索引。

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/subagents/executor.py` | `SubagentExecutor`：scheduler 线程池 + 持久 isolated event loop、`_aexecute`（跑图 + 步骤捕获 + guardrail `consume_stop_reason` 收集）、`_extract_final_result`、`SubagentResult`（`try_set_terminal` 单次终态写入） |
| `core/helix/subagents/registry.py` | 子代理注册表：`get_subagent_config`（builtin → custom → per-agent override 三层解析）、`get_available_subagent_names` |
| `core/helix/subagents/config.py` | `SubagentConfig`（`max_turns` / `timeout_seconds` / `disallowed_tools` 默认 `["task"]`）、`resolve_subagent_model_name` |
| `core/helix/subagents/step_events.py` | `capture_new_step_messages`（values 尾部扫描 + O(1) 去重）、`build_subagent_step`（步骤载荷裁剪）、`subagent_run_event`（task_* 事件 → RunEvent 映射） |
| `core/helix/subagents/status_contract.py` | `SubagentStatusValue` / `SubagentStopReasonValue` Literal、`format_subagent_result_message`、`make_subagent_additional_kwargs`、`read_subagent_result_metadata`（legacy `max_turns_reached` 归一） |
| `core/helix/subagents/token_collector.py` | `SubagentTokenCollector`：`on_llm_end` 收集 per-LLM-call token 用量（含 prompt-cache hit） |
| `core/helix/tools/builtins/task_tool.py` | `task()` 工具：`tool_call_id=task_id`、后台启动、5s 轮询、SSE 事件、`_task_result_command` 终态回填（含 `stop_reason`）、取消传播 |
| `core/helix/agents/middlewares/subagent_limit_middleware.py` | `SubagentLimitMiddleware`：`after_model` 截断超额 `task` 调用，clamp `[2, 4]` |
| `core/helix/agents/middlewares/token_budget_middleware.py` | `TokenBudgetMiddleware`：per-run token 预算，hard-stop 剥 `tool_calls` + `consume_stop_reason` 盖 `token_capped` |
| `core/helix/agents/middlewares/loop_detection_middleware.py` | `LoopDetectionMiddleware`：重复 tool-call 检测（hash + 频率双轴），hard-stop + `consume_stop_reason` 盖 `loop_capped` |

### 1. `task()` 工具入口（`tool_call_id=task_id` + 轮询 + `stop_reason` 冒泡）

```python
# core/helix/tools/builtins/task_tool.py — 入口签名 + 后台启动 + 终态回填（核心片段）
@tool("task", parse_docstring=True)
async def task_tool(
    runtime: Runtime,
    description: str,
    prompt: str,
    subagent_type: str,
    tool_call_id: Annotated[str, InjectedToolCallId],
) -> str | Command:
    """Delegate a task to a specialized subagent that runs in its own context."""
    # ...解析 config、构造 executor（见 references/code/task-tool-and-stop-reason.md 全文）...
    # ⭐ 复用 tool_call_id 作 task_id：token 用量、状态、trace 全部按这个 id 关联
    task_id = executor.execute_async(prompt, task_id=tool_call_id)

    writer = get_stream_writer()
    writer({"type": "task_started", "task_id": task_id, "description": description})

    # 后端代模型轮询（5s），模型不必自己 poll
    while True:
        result = get_background_task_result(task_id)
        # ...推送 task_running 增量 AIMessage...
        usage = _summarize_usage(getattr(result, "token_usage_records", None))
        if result.status == SubagentStatus.COMPLETED:
            _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
            _report_subagent_usage(runtime, result)   # 回填父 RunJournal
            writer({"type": "task_completed", "task_id": task_id, "result": result.result, "usage": usage})
            cleanup_background_task(task_id)
            # ⭐ stop_reason 透传：被护栏截断但仍产出结果时携带 token_capped/turn_capped/loop_capped
            return _task_result_command(
                tool_call_id=tool_call_id, status="completed",
                result=result.result, stop_reason=result.stop_reason,
            )
        # ... failed / cancelled / timed_out 同理，各自带 stop_reason ...

def _task_result_command(*, tool_call_id, status, result=None, error=None, stop_reason=None) -> Command:
    # 文本里折入 (capped: ...) 提示；additional_kwargs 盖 subagent_status + subagent_stop_reason
    content, metadata_error = format_subagent_result_message(status, result=result, error=error, stop_reason=stop_reason)
    return Command(update={"messages": [ToolMessage(
        content=content, tool_call_id=tool_call_id, name="task",
        additional_kwargs=make_subagent_additional_kwargs(status, result=result, error=metadata_error, stop_reason=stop_reason),
    )]})
```

> `task_tool.py` 全文（含 context 穿透、轮询超时安全网、`asyncio.CancelledError` 取消传播、`_report_subagent_usage`）见 [references/code/task-tool-and-stop-reason.md](./references/code/task-tool-and-stop-reason.md)。`status_contract.py` 全文（`format_subagent_result_message` / `make_subagent_additional_kwargs` / `read_subagent_result_metadata` 的 legacy 归一）同在该文件。

### 2. 执行器：scheduler 线程池 + 持久 isolated loop + cross-thread marshal（核心片段）

```python
# core/helix/subagents/executor.py — 双执行基座（核心片段）
# scheduler 线程池：唯一一个 ThreadPoolExecutor，承担"启动 + 等待终态"编排
_scheduler_pool = ThreadPoolExecutor(max_workers=3, thread_name_prefix="subagent-scheduler-")

# 持久 isolated event loop：进程级单例，daemon 线程驱动，所有子代理协程在此跑
_isolated_subagent_loop: asyncio.AbstractEventLoop | None = None
_isolated_subagent_loop_thread: threading.Thread | None = None
_isolated_subagent_loop_started: threading.Event | None = None
_isolated_subagent_loop_lock = threading.Lock()


def _get_isolated_subagent_loop() -> asyncio.AbstractEventLoop:
    """返回持久 isolated loop；懒启动，daemon 线程 run_forever。"""
    global _isolated_subagent_loop, _isolated_subagent_loop_thread, _isolated_subagent_loop_started
    with _isolated_subagent_loop_lock:
        # ...usable 判定（loop 存在 + 未关闭 + 正在跑 + 线程存活）...
        loop = asyncio.new_event_loop()
        started_event = threading.Event()
        thread = threading.Thread(target=_run_isolated_subagent_loop, args=(loop, started_event),
                                  name="subagent-persistent-loop", daemon=True)
        thread.start()
        if not started_event.wait(timeout=5):    # 等线程进入 run_forever
            ...  # 超时关 loop 抛错
        _isolated_subagent_loop = loop
        return _isolated_subagent_loop


def _submit_to_isolated_loop_in_context(
    context: Context, coro_factory: Callable[[], Coroutine[Any, Any, SubagentResult]],
) -> Future[SubagentResult]:
    """跨线程 marshal：在父 ContextVar 快照里把协程投递到 isolated loop。"""
    return context.run(
        lambda: asyncio.run_coroutine_threadsafe(coro_factory(), _get_isolated_subagent_loop()),
    )


def execute_async(self, task: str, task_id: str | None = None) -> str:
    """非阻塞入口：投到 scheduler 线程池，线程内再 marshal 进 isolated loop。"""
    if task_id is None:
        task_id = str(uuid.uuid4())[:8]
    result = SubagentResult(task_id=task_id, trace_id=self.trace_id, status=SubagentStatus.PENDING)
    with _background_tasks_lock:
        _background_tasks[task_id] = result
    parent_context = copy_context()   # ⭐ 抓父 ContextVar 快照（user_id 等）
    def run_task():
        with _background_tasks_lock:
            _background_tasks[task_id].status = SubagentStatus.RUNNING
            result_holder = _background_tasks[task_id]
        try:
            # scheduler 线程 → isolated loop（不直接 await，run_coroutine_threadsafe 桥接）
            execution_future = _submit_to_isolated_loop_in_context(
                parent_context, lambda: self._aexecute(task, result_holder))
            execution_future.result(timeout=self.config.timeout_seconds)   # 等终态
        except FuturesTimeoutError:
            result_holder.cancel_event.set()    # 协作式取消
            result_holder.try_set_terminal(SubagentStatus.TIMED_OUT,
                error=f"Execution timed out after {self.config.timeout_seconds} seconds")
            execution_future.cancel()
    _scheduler_pool.submit(run_task)
    return task_id
```

> 执行器全文（`_aexecute` 跑图主循环、`_consume_guard_stop_reason` 收集、`GraphRecursionError` 恢复部分结果、`_extract_final_result`、`SubagentResult.try_set_terminal` 单次终态写入锁、`_build_initial_state` 单条 SystemMessage 合并、`_load_skills` 磁盘 IO offload）见 [references/code/executor-and-pools.md](./references/code/executor-and-pools.md)。

### 3. Guardrail `stop_reason` 收集（duck-typed，additive）

```python
# core/helix/subagents/executor.py — guardrail cap 收集（核心片段）
def _create_agent(self, tools=None, *, deferred_setup=None):
    middlewares = build_subagent_runtime_middlewares(...)   # 复用 lead 同款基座
    # ⭐ duck-typed 收集：所有具 consume_stop_reason 的中间件都进来（list，不是 next）
    # 新增护栏无需改执行器——只要中间件实现该方法就自动被收集
    self._stop_reason_middlewares = [m for m in middlewares if hasattr(m, "consume_stop_reason")]
    return create_agent(model=model, tools=tools or self.tools, middleware=middlewares,
                        system_prompt=None, state_schema=ThreadState,
                        checkpointer=False)   # ⭐ 一次性，不 resume，隔离父 checkpointer

def _consume_guard_stop_reason(self) -> str | None:
    """pop 出本次 run 触发的护栏 cap；token_capped / loop_capped，或 None。"""
    for mw in self._stop_reason_middlewares:
        reason = mw.consume_stop_reason(self.run_id)
        if reason is not None:
            return reason
    return None

# _aexecute 末尾（正常完成路径）：
final_result = _extract_final_result(final_state, trace_id=self.trace_id, name=self.config.name)
stop_reason = self._consume_guard_stop_reason()   # 软停不抛，靠这里得知实际被截断
result.try_set_terminal(SubagentStatus.COMPLETED,
    result=final_result, stop_reason=stop_reason, token_usage_records=token_usage_records)

# GraphRecursionError 路径（turn 轴）：优先取护栏原因，否则 turn_capped
except GraphRecursionError:
    stop_reason = self._consume_guard_stop_reason() or "turn_capped"
    if usable_partial is not None:
        result.try_set_terminal(SubagentStatus.COMPLETED, result=usable_partial, stop_reason=stop_reason, ...)
    else:
        result.try_set_terminal(SubagentStatus.FAILED, error=f"Reached max_turns={max_turns}", stop_reason=stop_reason, ...)
```

### 4. 并发上限：`SubagentLimitMiddleware`（短，全文）

```python
# core/helix/agents/middlewares/subagent_limit_middleware.py — 全文
from helix.subagents.executor import MAX_CONCURRENT_SUBAGENTS
MIN_SUBAGENT_LIMIT = 2
MAX_SUBAGENT_LIMIT = 4

def _clamp_subagent_limit(value: int) -> int:
    return max(MIN_SUBAGENT_LIMIT, min(MAX_SUBAGENT_LIMIT, value))

class SubagentLimitMiddleware(AgentMiddleware[AgentState]):
    """单条 AIMessage 内 task 调用超过 max_concurrent 时截断超额。"""
    def __init__(self, max_concurrent: int = MAX_CONCURRENT_SUBAGENTS):
        super().__init__()
        self.max_concurrent = _clamp_subagent_limit(max_concurrent)

    def _truncate_task_calls(self, state: AgentState) -> dict | None:
        messages = state.get("messages", [])
        last_msg = messages[-1] if messages else None
        if getattr(last_msg, "type", None) != "ai":
            return None
        tool_calls = getattr(last_msg, "tool_calls", None)
        if not tool_calls:
            return None
        task_indices = [i for i, tc in enumerate(tool_calls) if tc.get("name") == "task"]
        if len(task_indices) <= self.max_concurrent:
            return None
        # 保留前 N 个，丢弃后面的（同 id 触发 LangGraph reducer 替换）
        indices_to_drop = set(task_indices[self.max_concurrent:])
        truncated = [tc for i, tc in enumerate(tool_calls) if i not in indices_to_drop]
        logger.warning(f"Truncated {len(indices_to_drop)} excess task tool call(s) (limit: {self.max_concurrent})")
        return {"messages": [clone_ai_message_with_tool_calls(last_msg, truncated)]}

    @override
    def after_model(self, state, runtime): return self._truncate_task_calls(state)
    @override
    async def aafter_model(self, state, runtime): return self._truncate_task_calls(state)
```

### 5. 动态时序：一次 `task()` 调用的端到端流转

```
主代理模型循环  ──>  AIMessage(tool_calls=[{name:"task", ...}])
   │                      tool_call_id = T
   │ after_model 链（逆序）：Safety → LoopDetection → ... → SubagentLimit 截断超额 task
   ▼
task_tool(runtime, description, prompt, subagent_type, tool_call_id=T)
   │ execute_async(prompt, task_id=T)          ⭐ tool_call_id 复用为 task_id
   │   └─ _background_tasks[T] = SubagentResult(PENDING)
   │   └─ copy_context() 抓父 ContextVar 快照
   │   └─ _scheduler_pool.submit(run_task)     ── scheduler 线程池（3 workers）
   │         │ run_task:
   │         │   status = RUNNING
   │         │   _submit_to_isolated_loop_in_context(parent_ctx, _aexecute)   ⭐ 跨线程 marshal
   │         │      └─ parent_ctx.run(run_coroutine_threadsafe(coro, isolated_loop))
   │         │   execution_future.result(timeout=timeout_seconds)             调度线程阻塞等
   ▼                              │
轮询循环（task_tool 内, 5s）       │ isolated loop（daemon 线程 subagent-persistent-loop）
   │  get_background_task_result(T)│  _aexecute:
   │  推 task_running SSE ─────────│─>| values chunk → capture_new_step_messages（尾部扫描+O(1)去重）
   │  命中终态？                   │  | check cancel_event（协作式取消，astream 边界）
   │                               │  | 各中间件 after_model（TokenBudget/LoopDetection 软停）
   ▼                               │  v 终态
task_completed/failed/... SSE      │  try_set_terminal(COMPLETED, result, stop_reason, ...)
   │                               │     stop_reason ← _consume_guard_stop_reason()（duck-typed）
   ▼                               │     |  TokenBudget.consume_stop_reason(run_id) → token_capped?
_task_result_command(              │     |  LoopDetection.consume_stop_reason(run_id) → loop_capped?
   status, result, stop_reason)    │
   │ format_subagent_result_message → "Task Succeeded (capped: token budget). Result: ..."
   │ make_subagent_additional_kwargs → {subagent_status, subagent_stop_reason, subagent_result_brief, ...}
   ▼
Command(update={messages:[ToolMessage(tool_call_id=T, name="task", ...)]})  ⭐ 结果按 T 关联回主代理
   │ 主代理 TokenUsageMiddleware 按 tool_call_id=T 把子代理用量回填到触发它的 AIMessage
   ▼ 主代理模型继续下一轮（可综合多个子代理结果）
```

## 反模式与陷阱

- ❌ **第二个 ThreadPoolExecutor 当"执行池"跑协程** → `asyncio.run` 建临时 loop 又关闭，loop-affine 的 httpx/MCP/DB 资源随之报废，`PoolClosed` 频发。修复：执行侧用**持久 isolated event loop**（daemon 线程 `run_forever`），调度线程用 `run_coroutine_threadsafe` marshal。
- ❌ **`copy_context()` 漏抓** → 子代理在 isolated loop 上恢复时 `user_id` 等 ContextVar 全退化到默认值，IM 多用户场景文件落错 owner。修复：`parent_context = copy_context(); parent_context.run(lambda: run_coroutine_threadsafe(...))`。
- ❌ **子代理工具集含 `task`** → 无限嵌套调度池打爆。修复：装配时 `subagent_enabled=False`，且 builtin 在 `disallowed_tools` 显式排除 `task`。
- ❌ **子代理继承父 checkpointer** → 子代理中间态污染父线程 checkpoint ns，rollback 时带进半截产物。修复：`create_agent(..., checkpointer=False)`。
- ❌ **`GraphRecursionError` 当普通异常 catch** → 子代理耗尽 turn 预算时被吞成 generic FAILED，主代理分不清"坏了"还是"超预算"。修复：专门 catch（先于 `except Exception`），恢复最后一条 AIMessage 文本作部分结果，盖 `stop_reason=turn_capped`。
- ❌ **guardrail 软停改成抛异常** → 已产出的可用结果随异常丢弃。修复：hard-stop 剥 `tool_calls` + 强制 `finish_reason="stop"`，让 run 自然完成；executor 靠 `consume_stop_reason` 事后得知。
- ❌ **`consume_stop_reason` 只查一个护栏** → 加新护栏要改执行器。修复：`[m for m in middlewares if hasattr(m, "consume_stop_reason")]` 收集全部，逐个查返回首个非 None（duck-typed，零 import 耦合）。
- ❌ **新增 `MAX_TURNS_REACHED` status 枚举表达截断** → 破坏 v1 契约消费者（前端/ledger/JSON fixture）。修复：additive `stop_reason` 字段，旧消费者静默忽略；`completed + stop_reason=...` 表达"截断但仍可用"。
- ❌ **`stream_mode="values"` 只取 `messages[-1]`** → 多工具调用 turn（模型一次发多个 tool_call）只保留最后一个 ToolMessage，其余 tool 输出全丢。修复：`capture_new_step_messages` 用 `processed_count` 游标扫新增尾部。
- ❌ **无 `seen_message_ids` 去重** → `values` 每个 super-step 重发全量消息，重复扫描把 O(n²) 堆到 max_turns=150 的深度任务。修复：id-keyed `set` 做 O(1) 去重，无 id 时退化到全 dict 比较。
- ❌ **`SubagentLimitMiddleware` 在 `before_model` 截断** → 模型还没发 tool_calls，无东西可砍。修复：`after_model`（模型发完 AIMessage 之后）；注册晚于 Safety/Loop，逆序派发时跑得更晚，在干净输入上裁剪。
- ❌ **`task_tool` 被取消时不等子代理上报 usage** → 父 token 账目缺失。修复：`asyncio.CancelledError` 路径 `await asyncio.shield(_await_subagent_terminal(...))` 等终态再 `_report_subagent_usage`。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 默认 | 说明 |
|---|---|---|---|
| `MAX_CONCURRENT_SUBAGENTS` | `executor.py` | 3 | 单条 AIMessage 内 `task()` 并发硬上限；`SubagentLimitMiddleware` clamp 到 `[2, 4]` |
| `_scheduler_pool` workers | `executor.py` | 3 | 调度并发；调度很轻，瓶颈在 isolated loop 实际执行 |
| `general-purpose.max_turns` | `builtins/general_purpose.py` | 150 | 子代理 `recursion_limit`；深度研究子任务基本不撞 `GraphRecursionError` |
| `subagents.timeout_seconds` | config 全局默认 | 1800（30 min） | 总超时（含轮询）；超时走 `TIMED_OUT` |
| 轮询间隔 | `task_tool.py` | 5s | `await asyncio.sleep(5)` |
| 轮询安全余量 | `task_tool.py` | +60s / 5s = 12 polls | 兜底 `polling_timed_out`：worker 仍非终态 |
| isolated loop 启动超时 | `executor.py` | 5s | `started_event.wait(timeout=5)` |
| `token_budget.max_tokens` | config | 2,000,000 | 子代理 per-run token 预算；0.7 warn，1.0 hard-stop |
| `loop_detection.hard_limit` / `tool_freq_hard_limit` | config | 5 / 50 | 重复 tool-call 集合 / 单工具频率硬停阈值 |

**关键日志串（`trace_id` 串起一次父子链路）**

- `[trace=<8 hex>] SubagentExecutor initialized: <name> with <N> tools` — 工具集装配结果
- `[trace=<8 hex>] Subagent <name> starting async execution with max_turns=150` — 进 astream
- `[trace=<8 hex>] Subagent <name> captured N step message(s); total #M` — 步骤捕获
- `[trace=<8 hex>] Subagent <name> reached max_turns=150 (GraphRecursionError); recovering partial result` — turn 轴触发
- `Token budget hard stop triggered for run <run_id>: <reason> limit exceeded` — token 轴触发（盖 `token_capped`）
- `Loop hard limit reached — forcing stop` / `Tool frequency hard limit reached — forcing stop` — loop 轴触发（盖 `loop_capped`）
- `Truncated N excess task tool call(s) from model response (limit: 3)` — 并发上限截断
- `[trace=<8 hex>] Started background task <task_id> (subagent=..., timeout=1800s, polling_limit=...)` — task_tool 启动
- `[trace=<8 hex>] Task <task_id> status: completed` — 终态流转
- `Timed out starting isolated subagent event loop` — daemon 线程被严重抢占（并发问题排查线索）

**调试入口（子代理失败排查序列）**

1. **看 trace 前缀**：`grep "[trace=<8 hex>]"` 把父子链路日志拉齐。
2. **看终态 `ToolMessage.additional_kwargs`**：`subagent_status` / `subagent_stop_reason` / `subagent_error` 是否就位；`stop_reason` 非空说明被护栏截断（看是哪个轴）。
3. **看 Langfuse session 树**：父 thread 下挂的子代理 trace（名 `subagent:<name>`）是否都已 finalize；未 finalize 说明 `try_set_terminal` 没走到。
4. **看 token 用量**：`token_usage_by_model` 里子代理 token 是否 > 0；为 0 说明 `SubagentTokenCollector` 未注入或 LLM 未被调用就异常。
5. **看 `_background_tasks` 残留**：进程 dump 时应有 stale entries（终态后 `cleanup_background_task` 应清空）；残留 non-terminal 说明 isolated loop 冻结或 scheduler 池满。

**自测方向**

- **`tool_call_id == task_id`**：mock 一个 tool_call_id，断言 `_background_tasks` 键、`_subagent_usage_cache` 键、终端 `ToolMessage.tool_call_id` 全部等于它。
- **checkpointer 隔离**：断言子代理 `create_agent(...).checkpointer == False`；子代理 run 后父线程 checkpoint 命名空间无新增。
- **并发截断**：构造含 5 个 `task` tool_call 的 `AIMessage`，`max_concurrent=3`，断言截断后只剩前 3 个 task 调用；clamp 用例断言 2/4 边界。
- **token 轴软停**：mock `TokenBudgetMiddleware` 触发 hard-stop，断言 run 仍 `COMPLETED` 且 `stop_reason=token_capped`，`tool_calls` 被剥空。
- **loop 轴软停**：mock 重复 tool-call 集，断言 hard-stop 后 `stop_reason=loop_capped`。
- **turn 轴恢复**：mock `GraphRecursionError`，断言最后一条 AIMessage 有文本→`COMPLETED + turn_capped`；无文本→`FAILED + turn_capped`。
- **additive 向后兼容**：旧前端只读 `subagent_status`，忽略 `subagent_stop_reason`，断言卡片仍正常渲染终态。
- **cross-thread marshal**：在 isolated loop 的协程内读 `effective_user_id`，断言等于父 ContextVar 值（非 `"default"`）。
- **步骤捕获完整性**：mock 一个 super-step append 3 条 ToolMessage，断言全部被捕获（不只最后一条）。
- **取消传播**：父 `asyncio.CancelledError` 后，断言子代理 `cancel_event` 被 set、usage 仍上报。

## 进一步阅读

- 执行器全文（pools / isolated loop / `_aexecute` / `SubagentResult`）：[references/code/executor-and-pools.md](./references/code/executor-and-pools.md)
- `task` 工具 + 状态契约全文（`format_subagent_result_message` / `make_subagent_additional_kwargs` / legacy 归一）：[references/code/task-tool-and-stop-reason.md](./references/code/task-tool-and-stop-reason.md)
- 并发上限 + 步骤捕获 + 护栏 `consume_stop_reason` 全文：[references/code/concurrency-and-guards.md](./references/code/concurrency-and-guards.md)
- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 关联 skill：[[e2e-request-lifecycle]]（⑥执行跳定位）、[[middleware-chain-design]]（TokenBudget / LoopDetection 在链上的位置与顺序不变量）、[[context-window-management]]（token 预算与循环检测的完整中间件深度）、[[tool-assembly-and-policy]]（子代理工具集装配 + 白名单 + deferred）、[[long-running-and-cancellation]]（multitask 取消传播 + 回滚）、[[observability-tracing]]（子代理 trace 挂父 session + token 归并）、[[safety-and-guardrails]]（子代理 Guardrail 按父身份做角色感知策略）、[[sandbox-abstraction]]（复用父 sandbox + thread_data）
