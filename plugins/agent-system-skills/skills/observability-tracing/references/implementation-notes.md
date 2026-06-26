# Implementation Notes — observability-tracing

## 1. 模块拓扑：两个文件 + 一个 callback

可观测层按职责被切成三块，相互之间只通过函数签名通信，没有共享状态：

```
<harness-pkg>/tracing/
├── factory.py    ← build_tracing_callbacks()：按 env 实例化外部 handler
└── metadata.py   ← build_langfuse_trace_metadata() / inject_langfuse_metadata()
<harness-pkg>/runtime/
└── journal.py    ← RunJournal（LangChain BaseCallbackHandler 子类，写本地 EventStore）
```

`factory.py` 只关心「**给我一个 callbacks 列表**」，里面同时容纳 LangSmith `LangChainTracer`
和 Langfuse v4 的 `langchain.CallbackHandler`；`metadata.py` 只关心「**怎么把 trace 属性塞进
`RunnableConfig.metadata`**」；`RunJournal` 是项目自己的 callback handler，吃同一组生命周期事件
然后写本地 SQL，它跟外部 tracer 是**并列**的——三者都挂在同一个 `config["callbacks"]` 列表里，
由 LangGraph 派发，互不感知。

判断一个变更属于哪一层很直接：「**外部 SaaS 显示有问题**」改 `factory.py` / `metadata.py`，
「**本地 token 计费 / run.events 表对不上**」改 `journal.py`。

## 2. 启用判定：双开关 + 显式校验

`build_tracing_callbacks()` 流程是 `validate_enabled_tracing_providers()` →
`get_enabled_tracing_providers()` → 按 provider 逐个 try/except 起 handler，任一 provider 初始化
失败直接 `raise RuntimeError(...)` 而不是吞掉——目的是「**配了凭证就必须连得上**」，避免线上
trace 静默丢失。环境变量对应表：

| 变量 | 行为 |
|------|------|
| `LANGSMITH_TRACING=true` + `LANGSMITH_API_KEY` + `LANGSMITH_PROJECT` | 启用 LangSmith |
| `LANGFUSE_TRACING=true` + `LANGFUSE_PUBLIC_KEY` + `LANGFUSE_SECRET_KEY` + `LANGFUSE_HOST` | 启用 Langfuse |
| 两个 `*_TRACING` 都关 | 返回 `[]`，零开销 |
| `DEER_FLOW_ENV` / `ENVIRONMENT` | 仅影响 Langfuse `langfuse_tags` 里的 `env:<value>` |

Langfuse v4 的关键细节：`Langfuse(...)` 单例先初始化 SDK，然后构造
`LangfuseCallbackHandler(public_key=...)`——v4 的 handler 不再吃 secret，凭证走 SDK 单例。

## 3. 挂载点：必须在图根（the only invariant that matters）

**铁律**：tracing callback 永远挂在 graph invocation 的 `config["callbacks"]` 上，而不是 model 上。
原因有两个：

- Langfuse v4 的 `_parse_langfuse_trace_attributes` 只在 `on_chain_start(parent_run_id=None)`
  的那一帧才会从 `config.metadata` 里抓 `langfuse_session_id / langfuse_user_id /
  langfuse_trace_name / langfuse_tags` 并落到 root trace 上；挂在 model 上时 chain_start 看不到
  callbacks，session 就丢了。
- 一个 run 内部模型可能被多个中间件（摘要、生成标题、记忆抽取）独立调用，model-level 挂载会
  让每次 model 调用都成为独立 root trace，父子关系一同消失。

所以入口处（worker、嵌入式 client、subagent 执行器）三处都按同一模式拼装：

```python
config.setdefault("callbacks", []).extend(build_tracing_callbacks())
inject_langfuse_metadata(
    config,
    thread_id=thread_id,
    user_id=user_id,
    assistant_id=assistant_id or "lead-agent",
    model_name=model_name,
    environment=environment,
)
```

`inject_langfuse_metadata` 用 `setdefault` 合并，**上游显式传入的 `langfuse_session_id` 永远赢**——
前端如果想把多个 thread 归到同一个 Langfuse session 可以通过这个旁路覆盖。

## 4. Trace 命名约定与子代理归并

- 主代理 trace name 默认 `lead-agent`，可由 `assistant_id`（Gateway 里就是 RunRecord 字段）覆盖。
- 子代理 trace name **必须**走归一化函数：`name.strip().lower().replace("_", "-")` →
  `subagent:<normalized>`。这样 `general-purpose` / `General_Purpose` / `general_purpose` 三种
  写法在 Langfuse Sessions 里聚合为同一条曲线。
- 子代理把父 `thread_id` 当 `langfuse_session_id`，子代理执行器在 `task` 工具触发的瞬间
  从 `runtime.context` 里抓 `user_id` 当 `langfuse_user_id`——延迟解析就晚了，子代理的执行线程
  与请求 contextvar 不在同一栈帧。

`langfuse_tags` 用 `env:<env>` + `model:<name>`，两维度都允许在 UI 侧做 filter。

补充：**`langfuse_user_id` 在无认证模式下回落到 `DEFAULT_USER_ID`**——这是有意的，否则
Langfuse 的 Users 页面会全空。无认证部署里所有流量都归到这一个常量用户，运维想要按真实
租户拆分必须先开认证。同样地，`langfuse_session_id = None` 是允许的（无 thread 上下文的
一次性调用），Langfuse 会把这条 trace 当独立 trace 处理而非 session 一部分。

## 5. RunJournal：本地审计 + token 计费

`RunJournal(BaseCallbackHandler)` 与外部 tracer 同列挂在 `config["callbacks"]` 里，但它的产物
写到自己的 `RunEventStore`（SQL 表 `run_events`，按 `run_id / thread_id` 分组）和 `RunRow` 字段。
关键设计点：

- **不订阅 `on_llm_new_token`**：只在 `on_llm_end` 落事件，避免高频写。
- **`on_chat_model_start` 是 prompt 落库点**：而不是 `on_chain_start`（每个节点都触发，且
  消息可能已被 checkpoint trim 压扁）；这里抓到的 prompts 是完整结构化形态，也是 run.input
  里第一条 human message 的来源。
- **dedup 三件套**：`_counted_llm_run_ids` / `_counted_external_source_ids` /
  `_counted_message_llm_run_ids`——LangChain 有时会对同一 LLM run 触发多次 end，子代理回流的
  token 又会带 `source_id`，三个集合分别防三类重复。
- **caller-bucket**：tags 里的 `lead_agent / subagent:<name> / middleware:<name>` 决定 token 计入
  `lead_agent_tokens / subagent_tokens / middleware_tokens` 哪个桶；`token_usage_by_model` 同时
  按真实生产模型而非 lead model 累计（修正了「子代理用 Claude、lead 用 GPT」的归类错配）。
- **`last_ai_message` 只保留 lead 主答**：`_record_message_summary` 显式过滤
  `caller is None or caller == "lead_agent"`——中间件子调（摘要、标题、记忆抽取）
  与子代理输出都不会覆盖 `RunRow.last_ai_message`，列表页看到的永远是用户视角的最终答案。
- **flush 必须在 worker `finally`**：异常路径也要把 buffer 写出去，否则故障 run 的 events
  会丢——这是「run.events 表对不上」最常见的原因。`_pending_flush_tasks: set` 保留所有
  正在写的 task 强引用，防止 asyncio GC 半途砍断。
- **子代理用量回流**：`TokenUsageMiddleware._apply` 在 `aafter_model` 里通过
  `pop_cached_subagent_usage(tool_call_id)` 把子代理累计回填到**派发它的那条 AIMessage**
  的 `usage_metadata`，多并发任务在同一帧合并；并发匹配靠的是 `tool_call_id`，**不能**用
  「ToolMessage 前一条 = AIMessage」这种位置假设。

## 6. 常见踩坑与调试入口

踩坑：

1. callback 挂在 `create_chat_model` 上：双倍 trace + Langfuse session_id 丢失。新增任何
   in-graph LLM 调用（摘要、标题、记忆）都要走 `create_chat_model(..., attach_tracing=False)`，
   把挂载留给图根。
2. Subagent 自造 `langfuse_trace_name` 不带 `subagent:` 前缀：父子关系散开，Sessions 列表里
   出现一堆裸 model 名。
3. `RunJournal` 同步写 DB：会阻塞 ASGI 事件循环，必须用 `asyncio.create_task` 提交
   `_flush_async`，且把 task 加入 `_pending_flush_tasks` 防止被 GC。
4. 把 token 用量按 message 索引归并（`messages[-2]`）：并发 task 工具调用时永远只有最后一条
   AIMessage 收到合并，前面的丢。正确做法是 `tool_call_id → dispatch AIMessage` 反查。
5. `flush` 漏 `finally`：异常时事件丢失；同时 run row 也要在 `finally` 走
   `update_run_completion` 把 token 字段刷出去。

调试入口：

- `RunJournal.get_completion_data()` 返回 `total_input_tokens / total_output_tokens /
  total_tokens / llm_call_count / lead_agent_tokens / subagent_tokens / middleware_tokens /
  token_usage_by_model`，与 `RunRow.update_run_completion` 字段一一对应。
- Langfuse UI 用 `session = <thread_id>` 过滤可以一眼看父子；LangSmith 用 project + thread
  metadata 同理。
- `tags=["middleware:summarize"]` / `["middleware:title"]` / `["middleware:memory_update"]`
  区分中间件子 LLM 调用，进 `middleware_tokens` 桶。
- 运行时数据根下的 `run_events` SQL 表里按 `run_id` 升序读，能看到
  `run.start` → `llm_request` → `llm_response` → ... → `run.end` 的完整时间线。

[[gateway-runs-and-sse]] [[subagent-delegation]] [[agent-graph-factory]] [[token-budgets-and-usage]] [[config-and-hot-reload]]
