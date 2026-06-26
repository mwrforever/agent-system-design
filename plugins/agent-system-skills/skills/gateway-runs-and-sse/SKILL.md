---
name: gateway-runs-and-sse
description: 设计 agent 后端 Gateway——FastAPI lifespan、RunManager / RunStore / StreamBridge 单例、run_agent worker、LangGraph stream_mode 到 SSE 事件名映射、checkpointer + thread_store 协作、wait / regenerate / token-usage 端点。
---

## 何时用

- 你在搭 agent 的 HTTP 后端（FastAPI / Litestar / 类似）
- 需要"LangGraph Platform 兼容"协议让前端 SDK 直接连
- 想把 SSE 流式响应与持久化 RunRecord、Checkpointer 串起来
- 想支持 wait / join / regenerate / cancel / token-usage 等运维端点

## 设计思想

1. **lifespan 装配单例**：用 `@asynccontextmanager` 在 app 启动时拼好 `checkpointer / store / RunManager / RunStore / StreamBridge / RunEventStore`，挂到 `app.state`。
2. **统一服务层 `services.py`**：路由薄；`start_run` / `sse_consumer` / `wait_for_run_completion` 等公共逻辑抽到 services，路由只做参数校验 + 调 service。
3. **stream_mode 映射 1:1**：内部 LangGraph 用 `values / messages / custom / updates`，SSE 事件名直接同名；额外加 `metadata` / `error` / `end` / `__heartbeat__` 几个非 stream_mode 事件。
4. **`messages-tuple` → `messages`**：客户端协议把 LangGraph 的 messages 模式叫 `messages-tuple`，worker 内部转回 `messages`，避免双协议。
5. **wait 也走 bridge**：`POST /wait` 不要 `await record.task`；改成 subscribe `END_SENTINEL`，复用 `on_disconnect` 语义。
6. **regenerate 用 checkpoint 定位**：scan run_events 找到目标 message_id → 找到它之前的 checkpoint → 返回干净 input + checkpoint_id 给前端做"重新生成"。
7. **同源 + CSRF 双 Cookie**：browser 默认同源 nginx；split-origin 用 `GATEWAY_CORS_ORIGINS` 显式 allowlist；状态变更 endpoint 强制 `X-CSRF-Token` 头 + `csrf_token` cookie 校验。

## 实现模板

### lifespan + 路由注册

```python
# gateway/app.py
@asynccontextmanager
async def lifespan(app: FastAPI):
    startup_config = get_app_config()
    apply_logging_level(startup_config.log_level)

    async with langgraph_runtime(app, startup_config):
        logger.info("LangGraph runtime initialised")
        await _ensure_admin_user(app)
        await start_channel_service(startup_config)
        yield
        await stop_channel_service()


def create_app() -> FastAPI:
    app = FastAPI(lifespan=lifespan, ...)
    app.add_middleware(AuthMiddleware)
    app.add_middleware(CSRFMiddleware)
    if (origins := sorted(get_configured_cors_origins())):
        app.add_middleware(CORSMiddleware, allow_origins=origins,
                           allow_credentials=True, allow_methods=["*"], allow_headers=["*"])
    app.include_router(thread_runs.router)  # /api/threads/{tid}/runs/*
    app.include_router(runs.router)         # /api/runs/*  (stateless)
    # ... models / mcp / skills / memory / uploads / threads / artifacts / suggestions ...
    return app


@asynccontextmanager
async def langgraph_runtime(app, config):
    """初始化所有运行时组件并挂到 app.state."""
    app.state.checkpointer = await make_checkpointer(config)
    app.state.store        = await make_store(config)
    app.state.stream_bridge = make_stream_bridge(config)
    app.state.run_event_store = make_run_event_store(config)
    app.state.thread_store    = make_thread_store(config)
    app.state.run_store       = make_run_store(config)
    app.state.run_manager     = RunManager(
        run_store=app.state.run_store,
        thread_store=app.state.thread_store,
        bridge=app.state.stream_bridge,
    )
    try: yield
    finally: ...   # 清理
```

### 路由 + service

```python
# routers/thread_runs.py
@router.post("/{thread_id}/runs/stream")
async def stream_run(thread_id: str, body: RunCreateRequest, request: Request):
    record = await start_run(body, thread_id, request)
    return StreamingResponse(
        sse_consumer(get_stream_bridge(request), record, request, get_run_manager(request)),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.post("/{thread_id}/runs/wait", response_model=dict)
async def wait_run(thread_id: str, body: RunCreateRequest, request: Request):
    record = await start_run(body, thread_id, request)
    completed = await wait_for_run_completion(
        get_stream_bridge(request), record, request, get_run_manager(request)
    )
    if not completed:
        raise HTTPException(499, "Client closed request")
    # 从 checkpoint 取最终 state
    checkpointer = get_checkpointer(request)
    ckpt = await checkpointer.aget_tuple({"configurable": {"thread_id": thread_id, "checkpoint_ns": ""}})
    return serialize_channel_values_for_api(ckpt.checkpoint["channel_values"])


@router.get("/{thread_id}/runs/{run_id}/join")
async def join_stream(thread_id, run_id, request: Request):
    record = await get_run_manager(request).get(run_id)
    if record is None: raise HTTPException(404)
    return StreamingResponse(sse_consumer(get_stream_bridge(request), record,
                                           request, get_run_manager(request)),
                              media_type="text/event-stream")
```

### service：build_run_config + 注入

```python
def build_run_config(thread_id: str, request_config, metadata, *, assistant_id=None):
    """LangGraph >= 0.6 用 context；LangGraph >= 1.1 ToolRuntime.context 不 fallback configurable.

    白名单字段需双写两边.
    """
    config = {"recursion_limit": 100}
    if request_config and "context" in request_config:
        ctx = dict(request_config["context"] or {})
        ctx["thread_id"] = thread_id
        config["context"] = ctx
    else:
        config["configurable"] = {"thread_id": thread_id, **(request_config or {}).get("configurable", {})}

    # 自定义 agent：assistant_id 转 agent_name
    if assistant_id and assistant_id != "lead_agent":
        normalized = assistant_id.lower().replace("_", "-")
        if not re.fullmatch(r"[a-z0-9-]+", normalized):
            raise ValueError(f"Invalid assistant_id {assistant_id!r}")
        for slot in (config.setdefault("configurable", {}),
                     config.setdefault("context", {})):
            slot.setdefault("agent_name", normalized)
    if metadata:
        config.setdefault("metadata", {}).update(metadata)
    return config


def merge_run_context_overrides(config, body_context):
    """白名单字段双写 configurable + context."""
    if not body_context: return
    whitelist = {"model_name", "thinking_enabled", "is_plan_mode", "subagent_enabled",
                 "max_concurrent_subagents", "agent_name", "is_bootstrap", "reasoning_effort"}
    for slot in (config.setdefault("configurable", {}), config.setdefault("context", {})):
        for k in whitelist:
            if k in body_context: slot.setdefault(k, body_context[k])
```

### stream_mode → SSE 事件名

```python
def _lg_mode_to_sse_event(mode: str) -> str:
    """LangGraph 内部 stream_mode → SSE 事件名 1:1."""
    return mode    # values/messages/custom/updates/tasks/checkpoints/debug
```

`messages-tuple` 在 worker 入口处归一化到 `messages`：

```python
def _normalize_stream_modes(requested):
    return ["messages" if m == "messages-tuple" else m for m in requested]
```

## 反模式

- ❌ wait 端点 `await record.task` → 客户端断了 task 还跑，返回 stale checkpoint
- ❌ lifespan 里同步 IO 初始化 checkpointer → uvicorn 启动卡顿
- ❌ 把 `agent_name` 只写 configurable 不写 context → LangGraph 1.1+ 部分中间件拿不到
- ❌ SSE Content-Type 没设 `X-Accel-Buffering: no` → nginx 缓冲整段流，前端只能等结束时一次性收到
- ❌ stream 配 chunked，但每帧不带 `\n\n` 结尾 → 客户端永远等不到下一帧
- ✅ heartbeat 注释 `: heartbeat\n\n` 让中间代理不超时关连接
- ✅ 路由薄，逻辑放 services；同一 service 同时给 IM 通道、嵌入式客户端复用

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[long-running-and-cancellation]] [[frontend-streaming-protocol]] [[multi-user-isolation]]
