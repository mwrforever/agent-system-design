---
name: observability-tracing
description: 设计 agent 系统的可观测性链路--LangSmith/Langfuse 回调必须挂在图根、Langfuse trace-attribute metadata 注入、subagent trace 归并到父 session、RunJournal 持久化与 token 用量回填、OTLP/OTEL 透传关系。覆盖"trace 挂在模型上导致 session_id 丢失""subagent trace 飘成独立 session""token 用量记到错 AIMessage"等真实踩坑。当你要接 LangSmith/Langfuse、排查 trace 上 session_id/user_id 丢失、让子代理 trace 归并父对话、持久化 run 事件用于审计/计费、回填 subagent token 用量时调用本 skill。
---

## 何时用

- 想用 LangSmith / Langfuse 看 agent 的 trace 树，且要看到 `session_id` / `user_id` 正确挂在根 trace 上
- 子代理（subagent）调用希望和父对话归在同一 Langfuse Session，而非飘成独立 trace
- 想持久化"每个 run 用了多少 token、调了哪些工具、出过什么错"用于审计 / 计费 / 进度展示
- Trace 上 `session_id` / `user_id` 不见了，或同一 run 出现两份重复 trace
- 想把 subagent 的 token 用量准确回填到派发它的那条 AIMessage 的 `usage_metadata`

## 设计方案（为什么这么设计）

### 核心矛盾：trace 挂哪里，决定 metadata 能否生效

Langfuse v4 的 `langchain.CallbackHandler` 只在 `on_chain_start(parent_run_id=None)`（即根调用）触发 `propagate_attributes`，把 `RunnableConfig.metadata` 里以 `langfuse_` 开头的 key（`langfuse_session_id` / `langfuse_user_id` / `langfuse_trace_name` / `langfuse_tags`）提升到根 trace 属性。若把回调挂在 `create_chat_model(...)` 上，模型成了**嵌套 observation**，`langfuse_*` key 被剥离，`session_id` / `user_id` 永远到不了 trace；同时同一 run 会出两份重复 span（一份根在图、一份根在模型）。

### 解法：回调挂图根 + `attach_tracing=False` 不变量

- **挂载点**：在图工厂（`_make_lead_agent`）与 run worker 两条入口，把 `build_tracing_callbacks()` 的结果 append 到 `config["callbacks"]` 根。模型工厂 `create_chat_model` 默认 `attach_tracing=True`（给 standalone 调用方如 `MemoryUpdater` 用），**所有 in-graph 调用方**必须显式传 `attach_tracing=False`。
- **不变量守护**：当前 4 个 in-graph 模型构造点（bootstrap agent / default agent / Summarization 中间件 / Title 中间件）+ subagent 工厂，全部传 `False`。新增 in-graph `create_chat_model` 必须补传该 flag，并用 CI fixture 跨文件守护防漂移。

```python
# 伪代码：图根挂载（make_lead_agent 装配阶段，链路 ④建图）
def _make_lead_agent(config, *, app_config):
    ...
    # ⭐ 回调挂在 config["callbacks"] 根，使 Langfuse 看到 on_chain_start(parent_run_id=None)
    tracing_callbacks = build_tracing_callbacks()
    if tracing_callbacks:
        existing = config.get("callbacks") or []
        config["callbacks"] = [*existing, *tracing_callbacks]
    # in-graph 模型必须 attach_tracing=False，否则重复 span + langfuse_* 被剥离
    return create_agent(model=create_chat_model(..., attach_tracing=False), ...)

# 模型工厂的不变量（standalone 默认 True，in-graph 必须 False）
def create_chat_model(name, *, attach_tracing=True, ...):
    model = resolve_class(cfg.use)(**cfg.model_dump_for_init())
    if attach_tracing:
        model = model.with_config(callbacks=build_tracing_callbacks())  # 仅 standalone
    return model
```

### metadata 注入：`setdefault` 让上游赢

`inject_langfuse_metadata(config, thread_id=..., user_id=..., assistant_id=..., model_name=..., environment=...)` 把 Langfuse trace-attribute 写进 `config["metadata"]`。关键约定：

- `langfuse_session_id` = `thread_id`（LangGraph 线程 -> Langfuse Session）
- `langfuse_user_id` = `user_id`，缺省回退 `DEFAULT_USER_ID`（`"default"`），使无认证模式下 Langfuse Users 页仍可用
- `langfuse_trace_name` = `assistant_id`，缺省 `"lead-agent"`
- `langfuse_tags` = `[f"env:{environment}", f"model:{model_name}"]`（非空才写）
- 额外注入 `helix_trace_id`（请求级关联 id，见下文 OTEL 段）到 metadata，供跨系统关联
- **`setdefault` 语义**：上游（如前端）已设的 `langfuse_session_id` 不被覆盖
- **no-op 守护**：Langfuse 不在 `enabled_providers` 时返回 `{}`，调用方可无条件 merge，不影响 LangSmith-only 部署

该 helper 由 run worker 与嵌入式 `HelixClient.stream` **共享**，两条入口不会漂移。

### subagent 归并父 session -- 在端到端链路中的位置

subagent 执行复用**父** `thread_id` 作为 `langfuse_session_id`，`trace_name` 改为 `subagent:<normalized_name>`，天然形成父子 trace 树。同时把父的 `helix_trace_id` 透传进 subagent 的 metadata 与 runtime context，使跨层关联一致。

```python
# 伪代码：subagent 归父（链路 ⑥执行 内的 subagent delegation，见 [[subagent-delegation]]）
async def _aexecute(self, task, result_holder):
    run_config = {"recursion_limit": ..., "callbacks": [collector], "tags": [f"subagent:{name}"]}
    # ⭐ 父 thread_id 当 session_id；trace_name = subagent:<name>
    inject_langfuse_metadata(run_config,
        thread_id=self.thread_id,            # 父 thread -> 同一 Langfuse Session
        user_id=self.user_id,                # 父 user
        assistant_id=f"subagent:{normalize(name)}",
        model_name=self.model_name, environment=...,
        helix_trace_id=self.helix_trace_id)  # 请求级关联 id 透传
    run_config["callbacks"].extend(build_tracing_callbacks())  # 同样挂图根
    # 模型同样 attach_tracing=False（在 _create_agent 里）
    async for chunk in agent.astream(state, config=run_config, context={...,"is_subagent":True}):
        ...
```

**关键联动**（见 [[e2e-request-lifecycle]]）：subagent 的 `create_chat_model(..., attach_tracing=False)` 与 lead agent 同源；subagent 的 `recursion_limit` = `max_turns`，触发 `GraphRecursionError` 时走 `turn_capped` stop_reason 通道（不破坏 trace 树）。

### RunJournal：LangChain callback -> 异步落库

`RunJournal(BaseCallbackHandler)` 也挂到 `config["callbacks"]`，监听 LangChain 事件，标准化为 `RunEvent` 记录后异步刷到 `RunEventStore`（SQL/JSONL/memory 可插拔）。

- `on_chain_start(parent_run_id=None)` 发 `run.start` trace 事件；`on_chain_end`（root）发 `run.end`；`on_chain_error` 发 `run.error`
- `on_chat_model_start` 捕获结构化 prompt（OpenAI 格式）+ 抽首条 HumanMessage 作 run.input（比 `on_chain_start` 可靠：只在实际 LLM 调用触发、内容不被 checkpoint 裁剪压缩）
- `on_llm_end` 发 `llm.ai.response`（OpenAI completion 格式）+ 累加 token 用量
- `on_tool_end` 持久化 ToolMessage 结果
- **caller 分桶**：通过 `tags` 识别调用方（`lead_agent` / `subagent:<name>` / `middleware:<name>`），token 按 caller 分桶累加（`lead_agent_tokens` / `subagent_tokens` / `middleware_tokens`）
- **token 去重**：LangChain 可能对同一 `run_id` 多次触发 `on_llm_end`，用 `_counted_llm_run_ids` / `_counted_external_source_ids` 去重，避免双计
- **缓冲异步刷**：`_flush_sync` 在有 event loop 时 `create_task` 异步刷，`flush_threshold=20` 触发批量；失败回退 buffer 重试。worker 的 `finally` 调 `await journal.flush()` 落库剩余

```python
# 伪代码：RunJournal 事件流与 token 累加
def on_llm_end(self, response, *, run_id, tags, **_):
    for gen in response.generations: msg = gen.message
    usage = msg.usage_metadata or {}
    caller = self._identify_caller(tags)           # lead_agent / subagent:* / middleware:*
    self._put(event_type="llm.ai.response", content=msg.model_dump(),
              metadata={"caller": caller, "usage": usage, "latency_ms": ...})
    if total_tokens > 0 and rid not in self._counted_llm_run_ids:
        self._counted_llm_run_ids.add(rid)         # 去重
        累加到 _total_* 与 caller 分桶 + _tokens_by_model
        self._schedule_progress_flush()            # 节流上报进度

async def flush(self):  # worker finally 调用
    await gather(*self._pending_flush_tasks)       # 等待在途
    while self._buffer: 批量 await self._store.put_batch(batch)
```

### token 用量回填：subagent -> 父 Journal -> 派发 AIMessage

subagent 在隔离 loop 执行，其 LLM 调用的 token 由 `SubagentTokenCollector`（轻量 callback）按 `source_run_id` 去重收集。执行完后两条回填路径：

1. **总量回填到父 RunJournal**：`task_tool` 通过 `_find_usage_recorder(runtime)` 在 `config["callbacks"]` 里找到父 `RunJournal`，调 `record_external_llm_usage_records(records)`（按 `source_run_id` 去重），使父 run 的 `subagent_tokens` 桶 + 总量准确。
2. **按 `tool_call_id` 回填到派发 AIMessage**：`task_tool` 把 subagent 用量缓存进 `_subagent_usage_cache[tool_call_id]`；父图的 `TokenUsageMiddleware.after_model` 检测到 ToolMessage 时，`pop_cached_subagent_usage(tool_call_id)` 取出，**向前搜索**含该 `tool_call_id` 的 AIMessage，把用量 merge 进它的 `usage_metadata`（多次并发 task 调用合并到同一条 dispatch AIMessage）。

```python
# 伪代码：token 回填到派发 AIMessage（TokenUsageMiddleware.after_model）
def _apply(self, state):
    msgs = state["messages"]
    idx = len(msgs) - 2
    while idx >= 0:                                  # 向前扫连续 ToolMessage
        tool_msg = msgs[idx]
        if not isinstance(tool_msg, ToolMessage) or not tool_msg.tool_call_id: break
        subagent_usage = pop_cached_subagent_usage(tool_msg.tool_call_id)
        if subagent_usage:
            dispatch_idx = idx - 1
            while dispatch_idx >= 0:                 # 找含该 tool_call_id 的 AIMessage
                candidate = msgs[dispatch_idx]
                if isinstance(candidate, AIMessage) and _has_tool_call(candidate, tool_msg.tool_call_id):
                    merged = {**prev_usage, 累加 subagent_usage 的 input/output/total}
                    state_updates[dispatch_idx] = candidate.model_copy(update={"usage_metadata": merged})
                    break
                dispatch_idx -= 1
        idx -= 1
    return {"messages": [state_updates[i] for i in sorted(state_updates)]} or None
```

### OTEL：OTLP 透传 + 请求级关联 id

- **Langfuse v4 OTLP-native**：Langfuse v4 SDK 基于 OpenTelemetry，trace 经 OTLP 导出。本系统的可观测性链路通过 Langfuse `CallbackHandler` 接入，**OTEL 是 Langfuse 的传输底座**（透传关系），tracing 模块本身不直接用 `opentelemetry` SDK 做手动 span 插桩。
- **请求级关联 id**（OTEL 风格的跨层关联）：`trace_context.py` 维护一个请求级 `ContextVar` trace id（`X-Trace-Id` HTTP 头来源），经 `normalize_trace_id` 做 header 安全校验（仅可打印 ASCII 0x20-0x7E，防 latin-1 编码炸响应头 / C1 控制符被中间代理剥离）。该 id 注入 Langfuse metadata（`helix_trace_id` key）并透传给 subagent，使同一请求的 lead trace + subagent trace + Langfuse trace 在跨系统检索时可关联。
- 该 id **独立于** Langfuse 自己的 trace id 与 run id。

### 链路位置（[[e2e-request-lifecycle]]）

| 阶段 | 本 skill 的动作 |
|---|---|
| ④建图（`make_lead_agent`） | `build_tracing_callbacks()` 挂 `config["callbacks"]` 根；in-graph `create_chat_model(attach_tracing=False)` |
| ⑥执行（run worker） | `inject_langfuse_metadata(config, ...)` 注入 trace 属性；`RunJournal` 挂 callbacks；`astream` 驱动 |
| subagent delegation | subagent 复用父 `thread_id` 作 `langfuse_session_id`，`trace_name=subagent:<name>`，透传 `helix_trace_id` |

边界：tracing 模块在 `core`（框架层），不依赖 `gateway` / `channels` / `scheduler`（应用层）。`inject_langfuse_metadata` 被 run worker（应用层驱动）与 `HelixClient`（嵌入式）共享调用，见 [[core-app-boundary]]。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/tracing/factory.py` | `build_tracing_callbacks()`：按 `enabled_providers` 构造 LangSmith `LangChainTracer` + Langfuse `CallbackHandler` | [tracing-setup.md](./references/code/tracing-setup.md) §1 |
| `core/helix/config/tracing_config.py` | `TracingConfig` / `LangSmithTracingConfig` / `LangfuseTracingConfig`：env 驱动的 provider 配置 + `is_configured`/`validate` | [tracing-setup.md](./references/code/tracing-setup.md) §2 |
| `core/helix/trace_context.py` | 请求级 trace id `ContextVar` + `normalize_trace_id` header 安全校验 + `HELIX_TRACE_METADATA_KEY` | [tracing-setup.md](./references/code/tracing-setup.md) §3 |
| `core/helix/tracing/metadata.py` | `build_langfuse_trace_metadata()` / `inject_langfuse_metadata()`：trace-attribute 构造与 merge（`setdefault` 上游赢） | [metadata-and-subagent.md](./references/code/metadata-and-subagent.md) §1 |
| `core/helix/subagents/executor.py` | `SubagentExecutor._aexecute`：subagent 回调挂图根 + `inject_langfuse_metadata` 归父 session + `helix_trace_id` 透传 | [metadata-and-subagent.md](./references/code/metadata-and-subagent.md) §2 |
| `core/helix/subagents/token_collector.py` | `SubagentTokenCollector`：subagent 内 token 用量按 `source_run_id` 去重收集 | [metadata-and-subagent.md](./references/code/metadata-and-subagent.md) §3 |
| `core/helix/runtime/journal.py` | `RunJournal`：LangChain callback -> 缓冲异步落 `RunEventStore` + caller 分桶 token 累加 + 进度节流上报 | [run-journal.md](./references/code/run-journal.md) |
| `core/helix/agents/middlewares/token_usage_middleware.py` | `TokenUsageMiddleware.after_model`：按 `tool_call_id` pop 缓存用量，回填派发 AIMessage `usage_metadata` | [token-usage-backfill.md](./references/code/token-usage-backfill.md) §1 |
| `core/helix/tools/builtins/task_tool.py` | `_subagent_usage_cache` + `_report_subagent_usage`：subagent 用量缓存 + 上报父 Journal | [token-usage-backfill.md](./references/code/token-usage-backfill.md) §2 |
| `core/helix/agents/lead/agent.py` | `_make_lead_agent`：图根挂载 tracing callbacks 的权威位置（`build_tracing_callbacks()` block） | 见 [[agent-graph-factory]] |
| `core/helix/models/factory.py` | `create_chat_model(attach_tracing=...)`：standalone 默认 True，in-graph 必须 False | 见 [[agent-graph-factory]] |

### 模块入口与索引

**回调构造**（完整源码见 [tracing-setup.md](./references/code/tracing-setup.md) §1）：`build_tracing_callbacks()` 先 `validate_enabled_tracing_providers()`（显式开启但缺凭证则抛错），再按 `get_enabled_tracing_providers()` 顺序构造。LangSmith 用 `LangChainTracer(project_name=...)`；Langfuse v4 先 `Langfuse(secret_key=..., public_key=..., host=...)` 初始化 client 单例，再 `LangfuseCallbackHandler(public_key=...)` 附着到该 client。初始化失败包装成 `RuntimeError`。

**provider 配置**（见 [tracing-setup.md](./references/code/tracing-setup.md) §2）：`get_tracing_config()` 线程安全单例（双检锁 + `threading.Lock`）。`enabled_providers` 要求 `is_configured`（开启 + 凭证齐全）；`explicitly_enabled_providers` 仅看 `enabled` flag（用于 validate 报缺凭证）。LangSmith 兼容 `LANGSMITH_*` / `LANGCHAIN_*` 两组 env；Langfuse host 兼容 `LANGFUSE_BASE_URL`。`reset_tracing_config()` 供测试重建。

**请求级关联 id**（见 [tracing-setup.md](./references/code/tracing-setup.md) §3）：`normalize_trace_id` 拒绝非可打印 ASCII / 超 512 字符 / C0/C1 控制符（Starlette latin-1 编码 + nginx/envoy/cloudfront 中间代理兼容）。`request_trace_context` / `ensure_trace_context` 上下文管理器绑定 `ContextVar`，`ensure` 版本继承当前 trace 或新建。

**metadata 注入**（见 [metadata-and-subagent.md](./references/code/metadata-and-subagent.md) §1）：`build_langfuse_trace_metadata` 在 Langfuse 未启用时返回 `{}`；`inject_langfuse_metadata` 用 `setdefault` 逐 key merge（`merged_metadata.setdefault(key, value)`），上游值不被覆盖。`helix_trace_id` 缺省回退 `get_current_trace_id()`。

**subagent 归父**（见 [metadata-and-subagent.md](./references/code/metadata-and-subagent.md) §2）：`_aexecute` 构造 `run_config` 时先放 `[collector]` 与 `tags=[subagent:<name>]`，再 `extend(build_tracing_callbacks())`，再 `inject_langfuse_metadata(run_config, thread_id=self.thread_id, assistant_id=f"subagent:{normalized}", helix_trace_id=self.helix_trace_id)`。name 归一化 `strip().lower().replace("_","-")` 与 lead-agent 命名同形。`context["is_subagent"]=True` + 透传 `user_role`/`oauth_*`/`run_id` 使 guardrail 归因到父 run。

**subagent token 收集**（见 [metadata-and-subagent.md](./references/code/metadata-and-subagent.md) §3）：`SubagentTokenCollector.on_llm_end` 按 `run_id` 去重，从 `gen.message.usage_metadata` 抽 input/output/total + `input_token_details.cache_read`（prompt-cache 命中）+ `response_metadata.model_name`（按真实模型分桶，非 lead 的 resolved model）。`snapshot_records()` 返回副本。

**RunJournal**（完整源码见 [run-journal.md](./references/code/run-journal.md)）：`on_chain_start(parent_run_id=None)` 发 `run.start`；`on_chat_model_start` 抽首条 HumanMessage（`_should_persist_human_input_message` 排除 `summary` 名 + `hide_from_ui` 控制）；`on_llm_end` 发 `llm.ai.response` + token 累加（按 `caller` 分桶 + `_tokens_by_model` per-model + `cache_read_tokens` 稀疏 key）；`on_tool_end` 持久化 ToolMessage / `Command` update messages；`_reconcile_final_tool_messages` 兜底 `ask_clarification` 等需对账的 ToolMessage。`_flush_sync` 有 event loop 时 `create_task`，在途任务存在则跳过（避免多任务并发写同一 SQLite）；`flush()` 等待在途 + 批量刷剩余。`get_completion_data()` 返回总量 + 分桶 + per-model + `last_ai_message` / `first_human_message`。`record_external_llm_usage_records` 按 `source_run_id` 去重接收 subagent 上报。`record_middleware` 供中间件写状态变更审计事件。

**token 回填**（见 [token-usage-backfill.md](./references/code/token-usage-backfill.md)）：`task_tool._cache_subagent_usage(tool_call_id, usage)` 缓存（受 `token_usage.enabled` 开关）；`_report_subagent_usage(runtime, result)` 通过 `_find_usage_recorder` 在 callbacks 里找父 Journal（兼容 `None` / `list` / `BaseCallbackManager` 三种 shape）调 `record_external_llm_usage_records`，`usage_reported` 守护只报一次。`TokenUsageMiddleware._apply` 向前扫连续 ToolMessage，`pop_cached_subagent_usage` 取用量，再向前找含该 `tool_call_id` 的 AIMessage，`model_copy(update={"usage_metadata": merged})` 累加（多次并发 task 合并到同一 dispatch AIMessage）。

## 反模式与陷阱

- ❌ **tracing callback 挂在 `create_chat_model(...)` 上** -> 同一 run 出两份重复 trace + Langfuse `session_id`/`user_id` 丢失（模型成嵌套 observation，`langfuse_*` key 被剥离）。修复：回调挂 `config["callbacks"]` 图根，in-graph 模型传 `attach_tracing=False`。
- ❌ **任何 in-graph `create_chat_model` 漏传 `attach_tracing=False`** -> 同上。4 个现站点 + subagent 工厂必须全传；新增站点不传即漂移。修复：CI fixture 跨文件守护 `attach_tracing=False` 断言。
- ❌ **subagent 自己生成 `trace_name` 不带 `subagent:` 前缀，或用自己新生成的 thread_id 当 session_id** -> Langfuse 上看不出父子，subagent trace 飘成独立 session。修复：复用父 `thread_id` 作 `langfuse_session_id`，`trace_name=subagent:<normalized_name>`。
- ❌ **`inject_langfuse_metadata` 用 `md[key]=value` 直接覆盖** -> 上游（前端）设的 `langfuse_session_id` 被覆盖，跨端不一致。修复：`setdefault` 逐 key merge，上游赢。
- ❌ **`inject_langfuse_metadata` 在 Langfuse 未启用时不返回** -> LangSmith-only 部署被污染。修复：未启用时 `build_langfuse_trace_metadata` 返回 `{}`，调用方无条件 merge 不影响其他 tracer。
- ❌ **RunJournal 同步写 DB** -> ASGI event loop 阻塞，token usage 写延迟，并发写同一 SQLite 报锁。修复：`_flush_sync` 有 loop 时 `create_task` 异步刷，在途任务存在则跳过；`flush_threshold=20` 批量。
- ❌ **token 用量直接写 AIMessage 但不通过 `tool_call_id` 关联** -> subagent 用量记到错 AIMessage（或丢）。修复：`_subagent_usage_cache[tool_call_id]` 缓存 + `TokenUsageMiddleware` 向前搜含该 id 的 AIMessage 回填。
- ❌ **`on_llm_end` 不按 `run_id` 去重** -> LangChain 对同一 response 多次触发 callback，token 双计。修复：`_counted_llm_run_ids` / `_counted_external_source_ids` 去重集合。
- ❌ **`_find_usage_recorder` 只认 `list` shape** -> async tool run 下 `config["callbacks"]` 是 `BaseCallbackManager`（不可迭代），找不到 Journal，subagent 用量静默丢失。修复：先 `isinstance(callbacks, BaseCallbackManager)` 时 unwrap `.handlers`。
- ❌ **`normalize_trace_id` 不校验字符范围** -> 含 C1 控制符或 >0xFF 码点的 trace id 经 Starlette latin-1 编码炸响应头（500），或被 nginx/envoy/cloudfront 剥离。修复：仅放行可打印 ASCII 0x20-0x7E + 长度上限 512。
- ❌ **subagent 用量上报不守护 `usage_reported`** -> 超时/取消路径重复上报，双计。修复：`_report_subagent_usage` 入口 `if getattr(result, "usage_reported", True): return`。
- ✅ `attach_tracing` bool 写成 CI fixture 跨文件守护（防漂移）
- ✅ Journal 用 in-memory buffer，`finally` 阶段 `await flush()` 落库；失败回退 buffer 重试

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `LANGSMITH_TRACING` / `LANGCHAIN_TRACING_V2` | env | LangSmith 开关（兼容两组 env） |
| `LANGSMITH_API_KEY` / `LANGCHAIN_API_KEY` | env | LangSmith 凭证 |
| `LANGSMITH_PROJECT` / `LANGCHAIN_PROJECT` | env | LangSmith 项目名（缺省 `"helix"`） |
| `LANGFUSE_TRACING` | env | Langfuse 开关 |
| `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` / `LANGFUSE_BASE_URL` | env | Langfuse 凭证 + host |
| `HELIX_ENV` / `ENVIRONMENT` | env | 部署环境，进 `langfuse_tags` 的 `env:` 前缀 |
| `token_usage.enabled` | app config | subagent 用量缓存开关（关闭则不回填 AIMessage） |
| `run_events.track_token_usage` | run events config | RunJournal 是否累加 token |
| `journal.flush_threshold` | 构造参数 | 批量刷阈值（缺省 20） |
| `journal.progress_flush_interval` | 构造参数 | 进度上报节流间隔（缺省 5.0s） |

**关键日志串**

- `Tracing attached to model '<name>' with providers=<n>` - standalone 模型挂 tracing（`attach_tracing=True` 路径）
- `Failed to flush <n> events for run <run_id> - returning to buffer` - Journal 异步刷失败回退 buffer
- `Journal flush task failed: <exc>` - flush task 异常
- `No usage recorder found in runtime callbacks - subagent token usage not recorded` - `_find_usage_recorder` 未找到父 Journal（callbacks shape 不匹配）
- `Failed to report subagent token usage` - `record_external_llm_usage_records` 抛异常（不阻塞主流程）
- `on_llm_end <run_id>: tags=<...>` - token 累加诊断（debug 级）
- `on_chat_model_start <run_id>: tags=... num_batches=... message_counts=...` - prompt 捕获诊断
- `Tool start for node <run_id>, tool_call_id=..., tags=...` - 工具调用 trace
- `Failed to persist progress snapshot for run <run_id>` - 进度上报失败（不阻塞）
- `[trace=<trace_id>] Subagent <name> ...` - subagent 执行全链路（含 trace_id 关联）

**自测方向**

- **图根挂载**：mock `build_tracing_callbacks` 返回非空，断言 `_make_lead_agent` 把回调 append 到 `config["callbacks"]` 根而非模型实例。
- **attach_tracing 不变量**：遍历所有 in-graph `create_chat_model` 调用点，断言 `attach_tracing=False`（CI fixture）。
- **metadata 注入**：开启 Langfuse，`inject_langfuse_metadata(config, thread_id="t1", user_id="u1")` 后断言 `config["metadata"]["langfuse_session_id"]=="t1"`、`langfuse_user_id=="u1"`、`langfuse_trace_name`/`langfuse_tags` 正确；上游预设的 `langfuse_session_id` 不被覆盖。
- **Langfuse 未启用 no-op**：关闭 Langfuse，`inject_langfuse_metadata` 不改 `config["metadata"]`（返回 `{}`）。
- **subagent 归父**：mock subagent 执行，断言 `inject_langfuse_metadata` 收到 `thread_id=父thread`、`assistant_id="subagent:<name>"`、`helix_trace_id=父trace`；name 归一化（`_` -> `-`、小写）。
- **token 去重**：对同一 `run_id` 触发两次 `on_llm_end`，断言 token 只累加一次（`_counted_llm_run_ids` 命中）。
- **caller 分桶**：分别发 `tags=["lead_agent"]` / `["subagent:x"]` / `["middleware:y"]` 的 `on_llm_end`，断言 `lead_agent_tokens` / `subagent_tokens` / `middleware_tokens` 分桶正确。
- **subagent 用量回填 Journal**：subagent 完成后 `task_tool._report_subagent_usage` 调 `record_external_llm_usage_records`，断言父 Journal `_subagent_tokens` 增加、`usage_reported=True`；二次调用不双计。
- **`_find_usage_recorder` 多 shape**：构造 `callbacks=None` / `list` / `BaseCallbackManager`（unwrap `.handlers`）/ 单 handler 对象，断言只有前两种 + Manager 能找到 recorder。
- **token 回填 AIMessage**：构造 `messages=[AIMessage(tool_calls=[{id:"tc1"}]), ToolMessage(tool_call_id="tc1")]`，缓存 `tc1` 用量，断言 `after_model` 把用量 merge 进该 AIMessage 的 `usage_metadata`；多次并发 task 合并到同一 AIMessage。
- **trace_id header 安全**：`normalize_trace_id` 对含 C1 控制符 / >0xFF 码点 / 超长 / C0 控制符的输入返回 `None`；可打印 ASCII 通过。
- **Journal 异步刷**：构造 `flush_threshold=2`，发 3 个事件，断言触发一次 `_flush_sync`（`create_task`）；`flush()` 后 buffer 空。
- **进度节流**：连续多次 `on_llm_end`，断言 `_schedule_progress_flush` 在 `progress_flush_interval` 内只上报一次（dirty 标记延后）。
- **per-model 分桶**：mock `response_metadata.model_name` 不同值，断言 `_tokens_by_model` 按 model 分桶 + `cache_read_tokens` 稀疏 key 只在非零时写。

## 进一步阅读

- 回调构造 + provider 配置 + 请求级关联 id 完整源码：[references/code/tracing-setup.md](./references/code/tracing-setup.md)
- metadata 注入 + subagent 归父 + subagent token 收集完整源码：[references/code/metadata-and-subagent.md](./references/code/metadata-and-subagent.md)
- RunJournal 完整源码：[references/code/run-journal.md](./references/code/run-journal.md)
- token 用量回填（middleware + task_tool 缓存）完整源码：[references/code/token-usage-backfill.md](./references/code/token-usage-backfill.md)
- 关联 skill：[[agent-graph-factory]]（图根挂载位置 + `attach_tracing=False` 不变量）、[[subagent-delegation]]（subagent 归父 session + token 收集）、[[gateway-runs-and-sse]]（run worker 挂 Journal + metadata 注入）、[[e2e-request-lifecycle]]（建图/执行/subagent 链路位置）、[[core-app-boundary]]（tracing 在 core 层的边界）
- Langfuse v4 langchain integration 与 sessions：https://langfuse.com/docs/observability/features/sessions
- Langfuse v4 OTLP / OpenTelemetry 导出：https://langfuse.com/docs/opentelemetry/overview
