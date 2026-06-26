---
name: subagent-delegation
description: 设计主代理→子代理的任务委派——task() 工具协议、双线程池 + 持久 isolated event loop、parent context 穿透、tool_call_id 即 task_id、token 用量归并、防递归。
---

## 何时用

- 主代理需要"并行展开 N 个子任务再综合"（典型：deep research、多角度审查）
- 想让一个长时子任务在主对话视角"折叠成一个工具调用"
- 父子代理之间需要共享 sandbox + 文件状态，但不污染父代理的消息历史
- 想给子代理一个独立的 max_turns 而不影响主对话

## 设计思想

1. **`task()` 是工具，不是图节点**。父代理调 `task(description, prompt, subagent_type)`，看起来就像一次工具调用；内部异步起子代理图。
2. **`tool_call_id == task_id`**：天然可追溯，子代理 token 用量回填到触发它的 AIMessage 时用同一 id 关联。
3. **双线程池 + 持久 isolated event loop**：父跑在 ASGI 主 loop；子代理用专用守护线程的长生命周期 event loop，避免每次起停 loop 的开销与连接重建。
4. **Context 完全穿透**：`sandbox_state / thread_data / user_id / user_role / oauth_* / run_id / trace_id` 一并塞给子代理，guardrail / 审计才能按父运行身份评估。
5. **防递归**：构造子代理工具集时**移除 `task`**——子代理不能再起孙代理。
6. **结构化事件 + ToolMessage 双通道**：通过 `StreamWriter` 推送 `task_started/running/completed/failed/cancelled/timed_out`（前端实时渲染）；同时返回 ToolMessage 给父代理（推理用）。
7. **取消传播**：父任务被取消 → `cancel_event.set()` → 子代理在 `astream` super-step 边界检测后优雅终止。

## 实现模板

### `task` 工具

```python
@tool("task", parse_docstring=True)
async def task_tool(runtime: Runtime, description: str, prompt: str, subagent_type: str,
                    tool_call_id: Annotated[str, InjectedToolCallId]) -> str:
    """Delegate a task to a specialized subagent.

    Args:
        description: 3-5 word task label for display.
        prompt: Full task description for the subagent.
        subagent_type: e.g. "general-purpose" / "bash" / custom name.
    """
    config = get_subagent_config(subagent_type)
    if config is None:
        return f"Error: Unknown subagent_type {subagent_type!r}. Available: {list_available()}"

    # ⭐ Context 全量穿透
    parent_ctx = runtime.context or {}
    sandbox_state = runtime.state.get("sandbox")
    thread_data   = runtime.state.get("thread_data")
    trace_id      = parent_ctx.get("trace_id") or str(uuid.uuid4())[:8]

    # ⭐ subagent_enabled=False → 不传 task 工具 → 防递归
    tools = get_available_tools(model_name=parent_ctx.get("model_name"),
                                groups=parent_ctx.get("tool_groups"),
                                subagent_enabled=False)

    executor = SubagentExecutor(
        config=config, tools=tools,
        sandbox_state=sandbox_state, thread_data=thread_data,
        thread_id=parent_ctx.get("thread_id"), trace_id=trace_id,
        user_id=parent_ctx.get("user_id"), user_role=parent_ctx.get("user_role"),
        oauth_provider=parent_ctx.get("oauth_provider"),
        oauth_id=parent_ctx.get("oauth_id"),
        run_id=parent_ctx.get("run_id"),
    )
    task_id = executor.execute_async(prompt, task_id=tool_call_id)   # ⭐ 复用 tool_call_id
    writer = get_stream_writer()
    writer({"type": "task_started", "task_id": task_id, "description": description})

    last_count = 0
    while True:
        result = get_background_task_result(task_id)
        if result is None:
            return f"Error: task {task_id} disappeared"
        # 推送增量 AIMessage
        for i in range(last_count, len(result.ai_messages)):
            writer({"type": "task_running", "task_id": task_id,
                    "message": result.ai_messages[i],
                    "message_index": i + 1, "total_messages": len(result.ai_messages)})
        last_count = len(result.ai_messages)
        # 终态
        if result.status == SubagentStatus.COMPLETED:
            usage = summarize_usage(result.token_usage_records)
            cache_subagent_usage(tool_call_id, usage)     # TokenUsageMiddleware 据此回填父 AIMessage
            writer({"type": "task_completed", "task_id": task_id,
                    "result": result.result, "usage": usage})
            cleanup_background_task(task_id)
            return f"Task Succeeded. Result: {result.result}"
        if result.status == SubagentStatus.FAILED:
            writer({"type": "task_failed", "task_id": task_id, "error": result.error})
            cleanup_background_task(task_id)
            return f"Task failed. Error: {result.error}"
        # ... cancelled / timed_out 同理
        await asyncio.sleep(5)
```

### 执行器骨架

```python
class SubagentExecutor:
    def execute_async(self, prompt: str, task_id: str) -> str:
        """投递到调度池，调度池决定是否走 isolated loop."""
        result = SubagentResult(task_id=task_id, trace_id=self.trace_id,
                                 status=SubagentStatus.PENDING, started_at=datetime.now())
        _background_tasks[task_id] = result
        _scheduler_pool.submit(self._dispatch, prompt, result)
        return task_id

    def _dispatch(self, prompt, result):
        try:
            asyncio.get_running_loop()
            # 父在 asyncio loop 中 → 投递到 isolated loop
            loop = _ensure_isolated_subagent_loop()
            asyncio.run_coroutine_threadsafe(self._aexecute(prompt, result), loop).result()
        except RuntimeError:
            # 父无 loop → 直接 asyncio.run
            asyncio.run(self._aexecute(prompt, result))

    async def _aexecute(self, prompt, result):
        agent = self._create_agent()          # checkpointer=False
        state = self._build_initial_state(prompt)  # SystemMessage + HumanMessage + 继承 sandbox/thread_data
        run_config = self._build_run_config()      # recursion_limit / callbacks / metadata

        async for chunk in agent.astream(state, config=run_config, context=self._build_context(),
                                          stream_mode="values"):
            if result.cancel_event.is_set():
                result.try_set_terminal(SubagentStatus.CANCELLED, error="Cancelled by user")
                return
            self._collect_ai_messages(chunk, result)
        result.try_set_terminal(SubagentStatus.COMPLETED, result=extract_final_text(chunk),
                                 token_usage_records=self._collector.snapshot_records())
```

### 子代理图构造

```python
def _create_agent(self):
    """checkpointer=False 一次性；system_prompt 拼进初始 SystemMessage；不传 task 工具."""
    return create_agent(
        model=create_chat_model(self.model_name, thinking_enabled=False, attach_tracing=False),
        tools=[t for t in self.tools if t.name != "task"],
        middleware=build_subagent_runtime_middlewares(  # 复用主代理 base，去除 Uploads
            app_config=self.app_config, model_name=self.model_name, lazy_init=True,
        ),
        system_prompt=None,         # 放进初始 SystemMessage，避免多 SystemMessage
        state_schema=ThreadState,
        checkpointer=False,
    )
```

## 反模式

- ❌ 子代理工具集含 `task` → 模型无限嵌套委派
- ❌ 不复用 parent sandbox → 子代理产物在另一目录，父代理 `present_files` 找不到
- ❌ 每次起新 event loop → DB 连接 / HTTP client 反复重建
- ❌ 子代理用父代理的 checkpointer → 子代理 checkpoint 污染父对话
- ❌ 子代理 trace 不挂父 session → Langfuse 上看不出父子关系
- ✅ `tool_call_id` 作 `task_id`，token 用量、状态、trace 全部串得起来
- ✅ 父被取消时 `cancel_event.set()`，子代理在 `astream` 边界优雅终止

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[long-running-and-cancellation]] [[observability-tracing]] [[tool-assembly-and-policy]]
