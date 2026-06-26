---
name: observability-tracing
description: 设计 agent 系统的可观测性——LangSmith / Langfuse 必须挂在图根的不变量、metadata 注入到 trace、subagent 归并到父 session、RunJournal + RunEventStore 持久化、token 用量回填。
---

## 何时用

- 想用 LangSmith / Langfuse 看 agent 的 trace 树
- 子代理调用希望和父对话归在同一 session
- 想持久化"每个 run 用了多少 token、调了哪些工具、出过什么错"用于审计 / 计费
- Trace 上 `session_id` / `user_id` 不见了，找不到原因

## 设计思想

1. **Tracing callback 挂在图根**：`config["callbacks"] = [*existing, *handlers]`，**不要**挂在 `create_chat_model`。Langfuse 必须看到 `on_chain_start(parent_run_id=None)` 才会把 `langfuse_session_id` / `langfuse_user_id` 升到 root trace 上。
2. **`attach_tracing=False` 是不变量**：所有 in-graph 的 `create_chat_model(...)` 都必须传——包括子代理、Title 中间件、Summarization 子调用。
3. **元数据注入 `config["metadata"]`**：Langfuse 的 langchain handler 会把以 `langfuse_` 开头的 key 提升到 trace 属性；约定字段 `langfuse_session_id` = thread_id, `langfuse_user_id` = user_id, `langfuse_trace_name`, `langfuse_tags`。
4. **subagent 归并父 session**：子代理 run 复用父的 `langfuse_session_id` = `parent_thread_id`，trace_name 改为 `subagent:<name>`——天然父子树。
5. **`RunJournal` 是 LangChain callback handler**：挂到 `config["callbacks"]`，监听 `on_llm_end / on_chain_start/end / on_tool_*` 等事件，buffer 后异步刷到 `RunEventStore`（SQL）。
6. **Token 用量回填**：子代理执行完后，`task_tool` 把 token 用量缓存到 `tool_call_id → usage`；父代理的 `TokenUsageMiddleware` 在收到 ToolMessage 时按 `tool_call_id` 找到对应 AIMessage 把用量写到 `usage_metadata.subagent_tokens`。

## 实现模板

### 工厂

```python
# tracing/factory.py
def build_tracing_callbacks() -> list[BaseCallbackHandler]:
    handlers: list = []
    if os.environ.get("LANGSMITH_TRACING") in ("true", "1"):
        handlers.append(LangChainTracer(project_name=os.environ.get("LANGSMITH_PROJECT")))
    if os.environ.get("LANGFUSE_TRACING") in ("true", "1"):
        from langfuse.langchain import CallbackHandler as LfHandler
        handlers.append(LfHandler())
    return handlers


def inject_langfuse_metadata(config: dict, *, thread_id: str | None,
                              user_id: str | None, assistant_id: str | None,
                              model_name: str | None, environment: str | None):
    if os.environ.get("LANGFUSE_TRACING") not in ("true", "1"):
        return                          # LangSmith-only deployments 不影响
    md = config.setdefault("metadata", {})
    md.setdefault("langfuse_session_id", thread_id)
    md.setdefault("langfuse_user_id", user_id or DEFAULT_USER_ID)
    md.setdefault("langfuse_trace_name", assistant_id or "lead-agent")
    tags = []
    if environment: tags.append(f"env:{environment}")
    if model_name:  tags.append(f"model:{model_name}")
    if tags: md.setdefault("langfuse_tags", tags)
```

### 图根挂载（worker）

```python
async def run_agent(bridge, run_mgr, record, *, ctx, agent_factory, graph_input, config, ...):
    # ⭐ 必须在 graph 调用前挂在 config 根
    inject_langfuse_metadata(config, thread_id=record.thread_id,
                              user_id=get_effective_user_id(),
                              assistant_id=record.assistant_id,
                              model_name=record.model_name,
                              environment=os.environ.get("AGENT_FRAMEWORK_ENV"))
    tracing_callbacks = build_tracing_callbacks()
    if tracing_callbacks:
        existing = list(config.get("callbacks") or [])
        config["callbacks"] = [*existing, *tracing_callbacks]

    # 同时挂 RunJournal（自定义 callback）
    journal = RunJournal(run_id=record.run_id, thread_id=record.thread_id,
                          event_store=ctx.event_store,
                          progress_reporter=lambda snapshot:
                              run_mgr.update_run_progress(record.run_id, **snapshot))
    config.setdefault("callbacks", []).append(journal)
    runtime_ctx["__run_journal"] = journal       # 让中间件能写自定义审计事件

    agent = agent_factory(config=RunnableConfig(**config))
    # ⭐ 这里的 create_chat_model 已经在 agent 工厂里用了 attach_tracing=False
    async for chunk in agent.astream(graph_input, config=RunnableConfig(**config),
                                      stream_mode=lg_modes):
        ...
```

### 模型工厂的不变量

```python
def create_chat_model(name: str, *, thinking_enabled: bool = True,
                     attach_tracing: bool = True, app_config=None, ...):
    """attach_tracing 默认 True 给"standalone"用（如 MemoryUpdater）.

    in-graph 调用方（lead/subagent 工厂、Summarization、Title 中间件）必须传 False，
    避免双倍 trace 与 langfuse 属性丢失.
    """
    cfg = (app_config or get_app_config()).get_model_config(name)
    model = resolve_class(cfg.use, base_class=BaseChatModel)(**cfg.model_dump_for_init())
    if attach_tracing:
        model = model.with_config(callbacks=build_tracing_callbacks())
    return model
```

### Subagent 归并父 session

```python
# subagents/executor.py
async def _aexecute(self, prompt, result):
    run_config: RunnableConfig = {
        "recursion_limit": self.config.max_turns,
        "callbacks": [SubagentTokenCollector(caller=f"subagent:{self.config.name}")],
        "tags": [f"subagent:{self.config.name}"],
    }
    # ⭐ 父 thread_id 当 session_id；trace_name = subagent:<name>
    inject_langfuse_metadata(run_config,
                              thread_id=self.thread_id,             # 父 thread
                              user_id=self.user_id,                 # 父 user
                              assistant_id=f"subagent:{normalize(self.config.name)}",
                              model_name=self.model_name,
                              environment=os.environ.get("AGENT_FRAMEWORK_ENV"))
    run_config["callbacks"].extend(build_tracing_callbacks())
    ...
```

### RunJournal（持久化）

```python
class RunJournal(BaseCallbackHandler):
    """LangChain callback → buffered async write to RunEventStore."""
    def __init__(self, *, run_id, thread_id, event_store,
                 progress_reporter=None, track_token_usage=True):
        self.run_id, self.thread_id = run_id, thread_id
        self.store = event_store
        self.report = progress_reporter
        self._buffer: list[dict] = []
        self._usage_records: list[dict] = []

    def on_llm_end(self, response, *, run_id, parent_run_id=None, **_):
        usage = _extract_usage(response)
        if usage:
            self._usage_records.append(usage)
            if self.report:
                self.report({"total_input_tokens": sum(r["input_tokens"] for r in self._usage_records),
                             "total_output_tokens": sum(r["output_tokens"] for r in self._usage_records),
                             "llm_call_count": len(self._usage_records)})
        self._buffer.append({"event_type": "llm.ai.response", "data": serialize(response)})

    def record_event(self, event_type: str, data: dict):
        self._buffer.append({"event_type": event_type, "data": data})

    def record_external_llm_usage_records(self, records: list[dict]):
        """Subagent 通过 callback chain 上报回父 RunJournal."""
        self._usage_records.extend(records)

    async def flush(self):
        if not self._buffer: return
        await self.store.write_many(run_id=self.run_id, thread_id=self.thread_id,
                                     events=self._buffer)
        self._buffer.clear()

    def get_completion_data(self) -> dict:
        return {
            "total_input_tokens": sum(r["input_tokens"] for r in self._usage_records),
            "total_output_tokens": sum(r["output_tokens"] for r in self._usage_records),
            "llm_call_count": len(self._usage_records),
            "lead_agent_tokens": sum(r["total_tokens"] for r in self._usage_records
                                      if r.get("caller", "").startswith("lead")),
            "subagent_tokens":   sum(r["total_tokens"] for r in self._usage_records
                                      if r.get("caller", "").startswith("subagent:")),
        }
```

## 反模式

- ❌ Tracing callback 挂在 `create_chat_model(...)` 上 → 同一 run 出两份 trace + Langfuse `session_id` 丢失
- ❌ 任何 in-graph `create_chat_model` 漏传 `attach_tracing=False` → 同上
- ❌ Subagent 自己生成 trace_name 不带 `subagent:` 前缀 → Langfuse 上看不出父子
- ❌ RunJournal 同步写 DB → ASGI event loop 阻塞，token usage 写延迟
- ❌ token 用量直接写 AIMessage 但不通过 `tool_call_id` 关联 → subagent 用量记到错 AIMessage
- ✅ `attach_tracing` 这个 bool 写成 fixture 在测试里跨文件守护（CI 防漂移）
- ✅ Journal 用 in-memory buffer，`finally` 阶段 flush 落库

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[gateway-runs-and-sse]] [[subagent-delegation]] [[agent-graph-factory]]
- Langfuse v4 langchain integration 文档
