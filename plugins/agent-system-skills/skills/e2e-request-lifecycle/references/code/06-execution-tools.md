# ⑥ 执行（工具调用）完整源码

> 本文件是脊柱 `SKILL.md` 第⑥跳"执行"的深度展开。脊柱只给入口片段；此处给工具分类聚集（`get_available_tools`）、沙箱虚拟路径映射（`bash_tool` + `replace_virtual_path`）、子代理 `task()` 委派（独立图 + 独立隔离事件循环）的真实源码片段。
>
> 代码已按插件匿名化规则映射到自定结构（`core/helix.*`），去除一切项目字样；原代码注释保真，中文注解以"注："或行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱）、`[[tool-assembly-and-policy]]`（工具装配 + MCP + 白名单）、`[[sandbox-abstraction]]`（沙箱 provider + 虚拟路径契约）、`[[sandbox-tools-and-safety]]`（bash/read_file/str_replace + 并发文件锁）、`[[subagent-delegation]]`（task() + 并行 + token/loop 上限）。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `core/helix/tools/tools.py` | `get_available_tools`：分类聚集工具（config 定义 + builtin + MCP + ACP） |
| `core/helix/sandbox/tools.py` | `bash_tool` + `replace_virtual_path`：虚拟路径 ↔ 物理路径映射 |
| `core/helix/subagents/executor.py` | `task()` 委派：独立图（checkpointer=False）+ 独立隔离事件循环 |

---

## 1. `core/helix/tools/tools.py` - 分类聚集工具

> lead agent 的模型循环驱动工具调用。工具分四类聚集：config 定义（含沙箱 bash/read_file）、builtin（present_files + ask_clarification，subagent 时加 task）、MCP、ACP 外部代理。

```python
# core/helix/tools/tools.py - 分类聚集工具
def get_available_tools(groups=None, include_mcp=True, model_name=None, subagent_enabled=False, *, app_config=None):
    config = app_config or get_app_config()
    tool_configs = [t for t in config.tools if groups is None or t.group in groups]
    loaded_tools = [resolve_variable(cfg.use, BaseTool) for cfg in tool_configs]   # ① config 定义（含沙箱 bash/read_file）
    builtin_tools = BUILTIN_TOOLS.copy()                                          # present_files + ask_clarification
    if subagent_enabled:
        builtin_tools.extend(SUBAGENT_TOOLS)                                      # task
    mcp_tools = get_cached_mcp_tools() if include_mcp else []                     # ② MCP
    acp_tools = [...]                                                             # ③ ACP 外部代理
    return [_ensure_sync_invocable_tool(t) for t in loaded_tools + builtin_tools + mcp_tools + acp_tools]
```

> 注：`_ensure_sync_invocable_tool` 保证所有工具同步可调（async 工具包一层适配器）。MCP 工具经 `get_cached_mcp_tools` 缓存，避免每 run 重新发现。

---

## 2. `core/helix/sandbox/tools.py` - bash 工具，虚拟路径 ↔ 物理路径映射

> 沙箱工具做**虚拟路径 ↔ 物理路径**映射：模型只看到 `/mnt/user-data/{workspace,uploads,outputs}/*`，物理路径由 `ThreadDataMiddleware` 建立的 per-user 目录决定（跨切不变量 2）。

```python
# core/helix/sandbox/tools.py - bash 工具，虚拟路径 ↔ 物理路径映射
@tool("bash", parse_docstring=True)
def bash_tool(runtime: Runtime, description: str, command: str) -> str:
    sandbox = ensure_sandbox_initialized(runtime)       # 从 runtime.state 取 sandbox_id 或新申请
    thread_data = get_thread_data(runtime)
    command = replace_virtual_paths_in_command(command, thread_data)   # /mnt/user-data/... -> 物理路径
    command = _apply_cwd_prefix(command, thread_data)
    output = sandbox.execute_command(command, env=injected_env, timeout=command_timeout)
    return _truncate_bash_output(mask_local_paths_in_output(output, thread_data), max_chars)

def replace_virtual_path(path: str, thread_data: ThreadDataState | None) -> str:
    """映射：/mnt/user-data/{workspace,uploads,outputs}/* -> 线程物理目录/*（最长前缀优先）。"""
    mappings = _thread_virtual_to_actual_mappings(thread_data)
    for virtual_base, actual_base in sorted(mappings.items(), key=lambda i: len(i[0]), reverse=True):
        if path.startswith(f"{virtual_base}/"):
            return _join_path_preserving_style(actual_base, path[len(virtual_base):].lstrip("/"))
    return path
```

> 注：`mask_local_paths_in_output` 把输出里的物理路径还原成虚拟路径，使模型始终只看到虚拟路径（物理隔离对模型透明）。`replace_virtual_paths_in_command` 处理命令行里的路径（含 `cd`、重定向等）。最长前缀优先保证嵌套挂载点正确解析。

---

## 3. `core/helix/subagents/executor.py` - task() 委派，独立图 + 独立隔离事件循环

> `task()` 委派子代理跑在**独立图 + 独立事件循环**上：子代理用 `checkpointer=False`（一次性，不持久化），不共享父图线程；`execute_async` 立即返回 `task_id`，在后台线程池跑。

```python
# core/helix/subagents/executor.py - task() 委派，独立图(checkpointer=False) + 独立隔离事件循环
async def _aexecute(self, task: str, result_holder=None) -> SubagentResult:
    state, final_tools, deferred_setup = await self._build_initial_state(task)
    agent = self._create_agent(final_tools, deferred_setup=deferred_setup)  # checkpointer=False，一次性
    run_config = {"recursion_limit": self.config.max_turns,
                  "callbacks": [collector, *build_tracing_callbacks()]}
    if self.thread_id:
        run_config["configurable"] = {"thread_id": self.thread_id}
    async for chunk in agent.astream(state, config=run_config, context=context, stream_mode="values"):
        if result.cancel_event.is_set():      # 协作式取消
            return result
        # 捕获每步（AIMessage + ToolMessage），多工具调用 turn 也不丢
        capture_new_step_messages(chunk.get("messages", []), ai_messages, seen_message_ids, processed_message_count)
    return result

def execute_async(self, task: str, task_id: str | None = None) -> str:
    """task 工具调用的入口：立即返回 task_id，在后台线程池跑。"""
    task_id = task_id or str(uuid.uuid4())[:8]
    result = SubagentResult(task_id=task_id, status=SubagentStatus.PENDING)
    _background_tasks[task_id] = result
    parent_context = copy_context()
    # 提交到独立隔离事件循环（不共享父图线程）
    _submit_to_isolated_loop_in_context(parent_context, lambda: self._aexecute(task, result_holder))
    return task_id
```

> 注：子代理 `checkpointer=False` 意味着子代理状态不进 checkpoint，只把最终结果（`SubagentResult`）回传父图。`copy_context()` 拷贝父 contextvar（含 user_id），使子代理继承父的 per-user 隔离。`_submit_to_isolated_loop_in_context` 用独立事件循环避免与父图的 astream 循环互相阻塞。协作式取消经 `result.cancel_event` -- 父图取消子代理时 set 它，子代理在下一个 chunk 检查点退出。

---

## 关键不变量与测试锚点

1. **四类工具聚集**：config 定义 + builtin + MCP + ACP，经 `_ensure_sync_invocable_tool` 统一为同步可调。
2. **虚拟路径透明**：模型只看 `/mnt/user-data/*`，物理路径由 per-user 目录决定（跨切不变量 2）；输出也经 `mask_local_paths_in_output` 还原虚拟路径。
3. **最长前缀优先**：嵌套挂载点（workspace 内含 uploads 子目录等）按最长前缀匹配，避免短前缀误匹配。
4. **子代理独立图**：`checkpointer=False`（不持久化子代理状态），独立事件循环（不阻塞父图），`copy_context` 继承 user_id 隔离。
5. **协作式取消**：`result.cancel_event` 在 chunk 检查点检测，子代理不强制中断。
6. **多工具 turn 不丢**：`capture_new_step_messages` 用 `seen_message_ids` 去重，多工具调用 turn 也不丢 AIMessage + ToolMessage。

> 关联：`[[tool-assembly-and-policy]]`（工具装配 + MCP + 白名单）、`[[sandbox-abstraction]]`（沙箱 provider + 虚拟路径契约）、`[[sandbox-tools-and-safety]]`（bash/read_file/str_replace + 并发文件锁）、`[[subagent-delegation]]`（task() + 并行 + token/loop 上限）、`[[mcp-integration]]`（MCP 多 server 集成）。
