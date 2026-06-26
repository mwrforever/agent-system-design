# Implementation Notes — subagent-delegation

> 本文档总结 Subagent 子代理委派子系统的实现细节、执行模型、关键不变量与典型踩坑。
> 占位路径：`<harness-pkg>/subagents/`、`<harness-pkg>/agents/middlewares/`。

## 一、组件拓扑

子代理子系统由四层组件协作完成"父代理向子代理委派任务"的端到端流程：

| 层 | 组件 | 职责 |
|----|------|------|
| 接口层 | `task` 工具 | LLM 可见的委派入口；签名 `(description, prompt, subagent_type, tool_call_id)` |
| 注册层 | `SubagentRegistry` + `get_subagent_config(name)` | 按名解析 `SubagentConfig`；内建 `general-purpose`、`bash` |
| 执行层 | `SubagentExecutor` | 真正的执行引擎；负责 build agent / 流式 astream / token 收集 |
| 容器层 | `SubagentResult` | 单次执行的可观察容器；`status / result / error / ai_messages / token_usage_records / cancel_event` |

`task` 工具的 `subagent_type` 在 LLM 视角是个枚举，由注册表实时填充——operator 增加自定义子代理只要注册一份新的 `SubagentConfig` 即可。`description` 字段是给人看的简短说明（写入 ToolMessage 起始行），`prompt` 才是真正进入子代理的任务文本。`tool_call_id` 与子代理执行结果通过 `task_id == tool_call_id` 一一对应，token 用量回填时按这个 id 找触发它的 AIMessage。

进程级共享状态集中在三处：

| 全局对象 | 用途 |
|----------|------|
| `_background_tasks: dict[task_id → SubagentResult]` | 父代理轮询的来源；`task_tool` 拿 task_id 来回拉取状态 |
| `_scheduler_pool` (`ThreadPoolExecutor(max_workers=3)`) | 调度池：把"启动 + 等待终态"包装成 thread 任务投递给 isolated loop |
| `_isolated_subagent_loop` (持久 daemon thread + asyncio loop) | 长生命周期 event loop，避免每次 spawn/close 时反复重建 DB/HTTP 连接 |

`_background_tasks` 由 `_background_tasks_lock` 保护；任何读写都必须持锁，避免父轮询线程和 worker 线程竞态污染状态。Isolated loop 的启停由 `_isolated_subagent_loop_lock` 守护，启动时 `started_event.wait(timeout=5)` 等线程进入 `loop.run_forever()` 才认定可用；关闭走 `atexit.register(_shutdown_isolated_subagent_loop)`，进程退出时 `call_soon_threadsafe(loop.stop) + thread.join(1) + loop.close()`，三步都成功才真正释放。

子代理图的中间件由 `build_subagent_runtime_middlewares(app_config, model_name, lazy_init, deferred_setup)` 装配，复用 lead 同款 base，再追加视觉、deferred-tool、safety、guardrail 等条件项（详见 [[middleware-chain-design]]）。子代理上下文一律 `lazy_init=True`，因为父已经初始化好 sandbox / uploads / thread_data，子无需重做。

## 二、SubagentConfig 字段与默认

`SubagentConfig` 是注册项的不可变描述，决定子代理的能力边界与运行时上限：

| 字段 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `name` | `str` | — | 注册名（`general-purpose / bash / ...`），LLM 选择 `subagent_type` 用 |
| `description` | `str` | — | 拼进父系统提示词的"可用子代理"段，用于引导 LLM 选择 |
| `system_prompt` | `str` | — | 拼进子代理初始 `SystemMessage` |
| `tools` | `list[str] \| None` | `None` | 工具名白名单（`None` = 继承父工具集） |
| `disallowed_tools` | `list[str] \| None` | `None` | 黑名单；内建 general-purpose 默认 `["task", "ask_clarification", "present_files"]` |
| `skills` | `list[str] \| None` | `None` | skill 白名单（`None` = 加载所有 enabled；`[]` = 不加载） |
| `model` | `str \| "inherit"` | `"inherit"` | 子代理模型；`"inherit"` 走 `resolve_subagent_model_name` 回退到父模型 |
| `max_turns` | `int` | 150 | `recursion_limit`，super-step 上限 |
| `timeout_seconds` | `int` | 1800 | 总超时（含轮询窗口） |

工具集装配链路：父全量工具 → `_filter_tools(allowed, disallowed)` → `_apply_skill_allowed_tools(skills)` → `assemble_deferred_tools(enabled)` → 追加 `tool_search` → 注入 `<available-deferred-tools>` 段（与 lead 同源，详见 [[tool-assembly-and-policy]]）。

注意：`tool_search` 自身**不**走 `tools / disallowed_tools` 名级别过滤。它的可见目录已经经过策略过滤，所以名级别允许 / 拒绝即便有冲突也不会被绕过——这与 lead 的处理一致。`skills` 字段的语义和 lead 也保持对齐：`None` 全量、`[]` 空集、显式列表则做白名单交集；列表里的 skill 还会被 `filter_tools_by_skill_allowed_tools` 进一步收窄工具集。

Skill 加载本身走 `asyncio.to_thread(storage.load_skills, enabled_only=True)`，避免在 ASGI event loop 上做磁盘 I/O；每条 skill 的 `SKILL.md` 内容会被包装成 `<skill name="...">...</skill>` 段落拼进 system 拼接列表，最终合并为单条 `SystemMessage`——这是因为某些 provider（如 OpenAI legacy）拒收多 SystemMessage。

## 三、执行模型与事件协议

`_aexecute(task, result_holder)` 是真正的协程主体，运行在 isolated loop 上：

1. **预检 cancel**：进入 `astream` 前先检查 `result.cancel_event.is_set()`，命中则直接 `try_set_terminal(CANCELLED)`。
2. **初始 state**：`_build_initial_state` 合并 `system_prompt` + skill 内容 + deferred 段到单条 `SystemMessage`（避免多 system 报错），再追加 `HumanMessage(task)`，并把父 `sandbox / thread_data` 透传。
3. **运行 graph**：`agent.astream(state, config=run_config, context=context, stream_mode="values")`。
   - `recursion_limit = config.max_turns`；
   - `callbacks` 注入 `SubagentTokenCollector` + tracing；
   - `context` 全量穿透 `user_id / user_role / oauth_provider / oauth_id / run_id / thread_id / app_config / is_subagent=True`。
4. **增量 AIMessage 收集**：每个 chunk 取末尾消息，若是新 `AIMessage` 则按 `id` 去重后追加到 `result.ai_messages`（id 缺失退化到全 dict 比较；`seen_message_ids` 保证 O(1)）。
5. **终态写入**：最后一条 `AIMessage.content`（str / list-of-blocks 两种）抽出 text → `try_set_terminal(COMPLETED, result=..., token_usage_records=...)`。异常路径走 `FAILED`，timeout 由调度层走 `TIMED_OUT`。

`stream_mode="values"` 每个 super-step 重新 yield 整个 state，意味着同一条尾部 AIMessage 会被反复扫到；用 `seen_message_ids: set[str]` 按 message `id` 做 O(1) 去重，避免在 `max_turns=150` 深度研究任务里把 O(n²) 扫描堆到 LLM 链路上。当 message 没有 `id`（部分老 provider）时退化到全 dict 比较。

`execute()` 和 `execute_async()` 入口的差异：

- `execute(task)` 同步阻塞调用：若已在 event loop 内（父是 async），通过 `asyncio.run_coroutine_threadsafe(...)` 把协程投递给 isolated loop，再 `future.result(timeout=config.timeout_seconds)` 等待；若不在 loop 内（脚本场景），直接 `asyncio.run(_aexecute(...))`。
- `execute_async(task, task_id)` 非阻塞：先把 `SubagentResult(status=PENDING)` 写进 `_background_tasks`，再用 `_scheduler_pool.submit(run_task)` 委派给 scheduler；scheduler 内部走同样的 isolated loop 路径，timeout 命中后 `cancel_event.set() + future.cancel() + try_set_terminal(TIMED_OUT)`。`task_tool` 拿 task_id 走轮询。

两条路径都用 `copy_context()` 抓父 ContextVar 快照（含 `effective_user_id` 等），再 `context.run(lambda: asyncio.run_coroutine_threadsafe(...))` 在 isolated loop 上执行，保证 user_id 等 ContextVar 不丢。

终态 `AIMessage.content` 抽 text 的处理细节：

- `str` → 直接当结果；
- `list[dict|str]` → 顺序遍历，连续 `str` 段先合并、再以 text block 边界做换行 join；空列表退化到 `"No text content in response"`；
- 没有任何 `AIMessage`（罕见，模型只发了 tool_calls 就被 hard-stop） → fallback 取最后一条任意 message 的 content；仍为空则返回 `"No response generated"`。

`task_tool` 端按 5s 轮询拉取 `_background_tasks[task_id]`，通过 `StreamWriter` 向上游 SSE 通道推送结构化事件：

```jsonc
{ "type": "task_started",   "task_id": "...", "description": "..." }
{ "type": "task_running",   "task_id": "...", "message": {...},
  "message_index": 1, "total_messages": 1 }
{ "type": "task_completed", "task_id": "...", "result": "...", "usage": {...} }
{ "type": "task_failed",    "task_id": "...", "error": "...", "usage": {...} }
{ "type": "task_cancelled", "task_id": "...", "error": "Cancelled by user", "usage": {...} }
{ "type": "task_timed_out", "task_id": "...", "error": "...", "usage": {...} }
```

终端 ToolMessage 还会在 `additional_kwargs` 里盖一份结构化状态：`subagent_status: completed/failed/cancelled/timed_out/polling_timed_out`（+ 可选 `subagent_error`），前端据此驱动 subtask 卡片生命周期，不再依赖文本前缀解析（详见 [[frontend-streaming-protocol]]）。状态值由 `extract_subagent_status` 按 ToolMessage.content 前缀映射，前缀表按最具体优先排序（"Task polling timed out" 在 "Task timed out" 之前；"Task failed." 在 "Error" 之前），避免子串误判。

状态语义：

- `completed`：正常完成；
- `failed`：异常或 LLM 显式失败，error 字段附在 `subagent_error`；
- `cancelled`：父代理主动取消（multitask interrupt / rollback / 用户取消）；
- `timed_out`：执行总时长超过 `timeout_seconds`，调度层 `future.cancel()` 并写终态；
- `polling_timed_out`：父轮询窗口（`timeout_seconds + 60s` 余量）耗尽但 worker 仍非终态，作为"看不见"的安全网，通常说明 isolated loop 被冻结，运维要查日志。

## 四、关键不变量

1. **`tool_call_id == task_id`**：天然可追溯。token 用量按 `tool_call_id` 回填到触发它的 AIMessage，账目和消息位置一致。
2. **子代理工具集强制移除 `task`**：内建 general-purpose 在 `disallowed_tools` 中显式排除，防止 N 层嵌套递归打爆调度池。
3. **复用父 sandbox + thread_data**：子代理写出的文件父代理能直接 `present_files`，避免跨沙箱文件复制（详见 [[sandbox-abstraction]]）。
4. **`checkpointer=False`**：子代理是一次性任务，不需要持久化中间态；继承父 checkpointer 会污染父线程的检查点 ns。
5. **Context 全量穿透**：`user_id / user_role / oauth_provider / oauth_id / run_id` 必须透传给子代理，让 Guardrail 按父运行身份做角色感知策略（详见 [[safety-and-guardrails]]）。
6. **取消传播双层**：父 `record.abort_event.set()` → `task_tool` 监听 → 子 `result.cancel_event.set()` → `astream` 边界检测后 `try_set_terminal(CANCELLED)`；只在 chunk 边界响应，长 tool 调用本身不会被切断。
7. **`try_set_terminal` 单次写入**：后台 timeout、执行 worker、cancel 路径会竞态写终态；首个 terminal 写入胜出，晚到的写入静默丢弃，避免账目被覆盖。锁是 `result._state_lock`，进入临界区先校验 `status.is_terminal`，已终态直接返回 `False`。
8. **Trace 名归一**：`assistant_id = f"subagent:{name.lower().replace('_','-')}"`，确保 Langfuse session 视图里子代理 trace 直接挂在父 thread 下（详见 [[observability-tracing]]）。
9. **状态枚举与协议一致**：`SubagentStatus`（执行侧）→ `SUBAGENT_STATUS_VALUES`（前端契约）映射稳定。终端 `ToolMessage.content` 的前缀（如 `"Task Succeeded. Result:"`、`"Task timed out"`、`"Task polling timed out"`、`"Task failed."`、`"Task cancelled by user"`、`"Error"`）通过 `extract_subagent_status` 在 `ToolErrorHandlingMiddleware` 盖戳到 `additional_kwargs.subagent_status`，前端不再做字符串前缀解析。


## 五、调参旋钮与典型踩坑

| 字段 | 默认 | 说明 |
|------|------|------|
| `MAX_CONCURRENT_SUBAGENTS` | 3 | 单条 AIMessage 内允许的 `task()` 并发数；`SubagentLimitMiddleware` 在 `after_model` 截断超额调用并 `clone_ai_message_with_tool_calls` 重写消息 |
| `_scheduler_pool` workers | 3 | 调度并发；调度本身极轻，瓶颈在 isolated loop 的实际执行 |
| `general-purpose.max_turns` | 150 | 默认子代理 recursion，深度研究子任务到这个上限基本不撞 `GraphRecursionError` |
| `general-purpose.timeout_seconds` | 1800 | 30 min；含轮询 |
| 轮询间隔 | 5s | `task_tool` 端 `await asyncio.sleep(5)` |
| 轮询超时安全余量 | +60s / 5 = 12 polls | 兜底用，结果还在跑就走 `polling_timed_out` |
| isolated loop 启动超时 | 5s | `started_event.wait(timeout=5)`；超时则关 loop 抛错 |

`SubagentLimitMiddleware` 的并发上限 clamp 到 `[MIN_SUBAGENT_LIMIT=2, MAX_SUBAGENT_LIMIT=4]`：低于 2 没什么意义，高于 4 调度池会成为瓶颈，且子代理内存占用线性放大。截断时按 tool_call 在 AIMessage 里出现的 index 排序，**保留前 N 个**，丢弃后面的；丢弃用 `clone_ai_message_with_tool_calls(msg, truncated)` 重写消息（同 id 触发 LangGraph reducer 替换）。

`SubagentLimitMiddleware` 同时实现 `after_model` 和 `aafter_model`，sync / async 图都生效。它放在 `LoopDetection` / `SafetyFinishReason` 之**后**注册，因此在 after_model 派发顺序里跑得**比 Safety / Loop 都晚**——这意味着 Safety 已经清掉异常消息、Loop 已经修剪重复 tool_calls 之后，截断才在干净的输入上做最终裁剪。

子代理与父代理共享的运维端口：

- 父图 `MemoryMiddleware` 不在子图里——子代理写的对话不进入父用户的长程记忆，避免任务级 prompt 污染用户 profile（详见 [[memory-system-design]]）。
- 父图 `UploadsMiddleware` 也不在子图里——子代理走父已经解析好的 `thread_data.uploaded_files`，不重复扫盘。
- 父图 `TodoListMiddleware`（plan mode）不会下放给子代理：plan mode 的 `write_todos` 工具是父代理面向用户的进度卡，子代理写自己的 todo 会污染父进度。
- 父图 `TitleMiddleware`、`DanglingToolCallMiddleware` 也只在父图，原因同上。

常见踩坑：

1. **子代理工具集含 `task`** → 无限嵌套调度池打爆。`get_available_tools(..., subagent_enabled=False)` 用于装配子代理工具集。
2. **不复用父 sandbox** → 子代理产物落在另一个沙箱目录，`present_files` 找不到。
3. **每次新建 event loop** → 共享 httpx / DB 池绑定到短命 loop，回收时 `PoolClosed`。用持久 isolated loop 避免。
4. **子代理 trace 不挂父 session** → Langfuse 看不出父子关系。`langfuse_session_id = 父 thread_id`，`langfuse_trace_name = "subagent:<name>"`。
5. **父任务被 cancel 时不等子代理上报 usage** → token 账目缺失。`try_set_terminal` 即使在 CANCELLED 路径也带 `token_usage_records=collector.snapshot_records()`。
6. **缺少 `is_subagent=True` context 标记** → Guardrail 无法区分父子身份，无法应用"子代理禁用某些工具"的差异策略。
7. **没有 `copy_context()` 抓 ContextVar** → 子 ContextVar 全部退化到默认值，`user_id` 在 isolated loop 上变成 `"default"`，IM Channel / 多用户隔离场景下文件全落到错的 owner（详见 [[multi-user-isolation]]）。
8. **使用 lead 同款 ContextVar 但绑死在子 loop** → 子 loop 结束后 ContextVar 不回滚，污染父的下一轮调度；正确做法是 `context.run(lambda: asyncio.run_coroutine_threadsafe(...))`。
9. **`config.skills` 写法不当** → `None` ≠ `[]`。`None` 是"加载所有 enabled"，`[]` 是"完全不加载 skill"，混用会让子代理拿不到任何 skill 上下文。


## 六、调试入口

调试子代理失败时的固定排查序列：

1. **看 trace 前缀**：`grep "trace=<8 hex>"` 把整条父子链路日志拉齐。
2. **看 `_background_tasks` 残留**：父代理生命周期内拿到了 task_id 却轮询不到终态，通常是 isolated loop 卡死或 `_scheduler_pool` 满。
3. **看 Langfuse session 树**：父 thread 下挂的子 trace 是否都已经 finalize；没 finalize 说明子代理 `try_set_terminal` 没走到，多半是异常被 finally 之外的代码截了。
4. **看终态 ToolMessage `additional_kwargs`**：`subagent_status / subagent_error` 是否就位；缺失说明 ToolErrorHandlingMiddleware 没盖戳，前端会回退到字符串前缀解析。
5. **看 token 用量**：`token_usage_by_model` 里 `subagent_tokens` 是否大于 0；为 0 说明子图 `SubagentTokenCollector` 没有被注入或者 LLM 完全没被调用就异常结束。

- 日志前缀 `[trace=<8 hex>] Subagent <name> ...`，`trace_id` 来自父 metadata，跨进程也能串起来。父执行器 `__init__` 阶段就打 `SubagentExecutor initialized: <name> with <N> tools`，便于确认工具集装配结果。
- `_background_tasks` 在内存里；进程 dump 时检查是否有 stale entries（终态后 `cleanup_background_task` 应清空）。
- Langfuse session 视图：子代理 trace 直接挂在父 thread 下，名字带 `subagent:` 前缀。
- 状态机迁移：`SubagentStatus` enum + `is_terminal` property；非终态 → 终态发生在 `try_set_terminal` 内，单点可断点。
- `request_cancel_background_task(task_id)` 用于运维侧手工干预；只 set `cancel_event`，真正生效在下一个 astream 边界。
- `cleanup_background_task(task_id)` 仅清理终态条目（看 `is_terminal` 或 `completed_at` 非空），避免和仍在写入的 worker 竞态。运维侧若发现内存里残留 non-terminal entry，先看日志确认 worker 是否已经丢失。
- 子代理 token 账目最终通过 `SubagentTokenCollector.snapshot_records()` 汇总，挂在 `result.token_usage_records` 上，触发它的父 AIMessage 通过 `tool_call_id` 回填，单次 run 的总账目由 `TokenUsageMiddleware` 合并（详见 [[observability-tracing]]）。
- 终端 ToolMessage 的 `additional_kwargs` 里盖有 `subagent_status` + 可选 `subagent_error`，前端订阅订阅 messages-tuple 时即可立刻渲染卡片终态。
- isolated loop 启动失败日志：`Timed out starting isolated subagent event loop`；通常说明启动线程被严重抢占或 daemon thread 被冻结，是排查并发问题的关键线索。
- 取消传播链断点：父 `RunManager.cancel()` → `record.abort_event.set()` → `task_tool` 监听 → 子 `result.cancel_event.set()` → 下一个 `astream` 边界 → `try_set_terminal(CANCELLED)`。链路任意一环卡住都会让子代理超时而非取消，调试时分别在五个点打断点最快定位。
- 子代理 LLM 的 `attach_tracing=False`：tracing callback 通过 graph-level `run_config["callbacks"]` 注入，避免和模型层 attach 双重计数。看到 Langfuse 上 LLM span 数翻倍，先查这个开关。

## 相关 skill

- [[long-running-and-cancellation]]
- [[middleware-chain-design]]
- [[tool-assembly-and-policy]]
- [[observability-tracing]]
- [[safety-and-guardrails]]
