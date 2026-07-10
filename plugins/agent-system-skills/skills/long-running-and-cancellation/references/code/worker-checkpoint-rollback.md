# worker pre-run 快照 + cancel rollback 完整源码

> 本文件是 `long-running-and-cancellation` skill 的深度代码分节：`run_agent` 后台 worker 的 pre-run checkpoint 快照捕获、流循环协作式取消、终结路径 rollback/interrupt、`_SubagentEventBuffer` 批量持久化、`_rollback_to_pre_run_checkpoint` 写新 checkpoint 标记载 pre-run channel_values 的**完整真实源码**。
>
> 代码已按插件匿名化规则映射到自定结构（`helix.*` / `gateway.*`），去除一切项目字样；原代码注释保真，中文注解以行内 `#` 标注。
>
> 关联：`[[e2e-request-lifecycle]]`（脊柱 ③路由 + ⑦流式 + 跨切不变量 3）、`run-manager.md`（`cancel` / `create_or_reject` 设 `abort_action` 的协作侧）、`stream-bridge-resume.md`（bridge `publish_end` / `cleanup`）。回滚函数 `_rollback_to_pre_run_checkpoint` 的同等深度亦见脊柱 `references/code/07-streaming-and-resume.md`；本 skill 作为长任务/取消的深度归档，完整保留。

---

## 文件清单

| 自定结构路径 | 职责 |
|---|---|
| `core/helix/runtime/runs/worker.py` | `run_agent`：pre-run 快照 + stream_mode 映射 + publish + 终结 rollback；`_rollback_to_pre_run_checkpoint`；`_SubagentEventBuffer`；`_collect_pre_existing_message_ids` |

---

## 1. stream_mode 映射 + 解包

```python
# core/helix/runtime/runs/worker.py
# LangGraph graph.astream() 的合法 stream_mode 值。
# 注："events" 不在其中--gateway 不支持 events 模式（需 astream_events + checkpoint 回调，
# 无法同时产 values 快照）。
_VALID_LG_MODES = {"values", "updates", "checkpoints", "tasks", "debug", "messages", "custom"}


def _lg_mode_to_sse_event(mode: str) -> str:
    """Map LangGraph internal stream_mode name to SSE event name.

    LangGraph's ``astream(stream_mode="messages")`` produces message
    tuples.  The SSE protocol calls this ``messages-tuple`` when the
    client explicitly requests it, but the default SSE event name used
    by LangGraph Platform is simply ``"messages"``.
    """
    # All LG modes map 1:1 to SSE event names - "messages" stays "messages"
    return mode


def _unpack_stream_item(
    item: Any,
    lg_modes: list[str],
    stream_subgraphs: bool,
) -> tuple[str | None, Any]:
    """Unpack a multi-mode or subgraph stream item into (mode, chunk).

    Returns ``(None, None)`` if the item cannot be parsed.
    """
    if stream_subgraphs:
        if isinstance(item, tuple) and len(item) == 3:
            _ns, mode, chunk = item
            return str(mode), chunk
        if isinstance(item, tuple) and len(item) == 2:
            mode, chunk = item
            return str(mode), chunk
        return None, None

    if isinstance(item, tuple) and len(item) == 2:
        mode, chunk = item
        return str(mode), chunk

    # Fallback: single-element output from first mode
    return lg_modes[0] if lg_modes else None, item
```

---

## 2. `_SubagentEventBuffer`（长子代理 step 事件批量持久化）

```python
# core/helix/runtime/runs/worker.py
class _SubagentEventBuffer:
    """Buffer subagent ``task_*`` step events and flush them in one locked batch (#3779).

    The live SSE bridge already forwards these events for real-time display; this
    additionally writes them so the subtask card's step history survives a reload.

    ``RunEventStore.put`` is documented as a low-frequency path - on Postgres each
    call opens its own transaction and takes a per-thread advisory lock. A deep
    subagent (``general-purpose`` runs up to ``max_turns=150``) emits hundreds of
    ``task_running`` steps on the hot stream loop, so persisting each with
    ``put()`` would serialize against the run's own message-batch writer. This
    accumulates recognized subagent events and writes them with ``put_batch``,
    which acquires the lock once per batch, honoring the store's contract.

    Best-effort: a missing store (run_events not configured) or an unrecognized
    chunk is a no-op, flush failures are logged but never propagate into the
    stream loop, and terminal ``subagent.end`` events flush eagerly so a completed
    subagent's step history is durable promptly rather than only at run end.
    """

    #: Flush once this many events are buffered, bounding memory and reload lag on
    #: a single deep subagent without paying a per-step lock.
    FLUSH_THRESHOLD = 25

    def __init__(self, event_store: Any | None, thread_id: str, run_id: str) -> None:
        self._event_store = event_store
        self._thread_id = thread_id
        self._run_id = run_id
        self._pending: list[dict[str, Any]] = []

    async def add(self, chunk: Any) -> None:
        """Buffer one custom stream chunk; flush on a terminal event or threshold."""
        if self._event_store is None:
            return
        # Lazy import: importing helix.subagents at module load triggers its
        # package __init__ (executor -> agents -> tools -> task_tool), which imports
        # back from helix.subagents and deadlocks at gateway startup. Deferring
        # it to call time (after all modules are loaded) breaks that cycle.
        from helix.subagents.step_events import subagent_run_event

        record = subagent_run_event(chunk)
        if record is None:
            return
        self._pending.append({"thread_id": self._thread_id, "run_id": self._run_id, **record})
        if record["event_type"] == "subagent.end" or len(self._pending) >= self.FLUSH_THRESHOLD:
            await self.flush()

    async def flush(self) -> None:
        """Persist buffered events in one ``put_batch`` call; swallow store errors."""
        if self._event_store is None or not self._pending:
            return
        batch = self._pending
        self._pending = []
        try:
            await self._event_store.put_batch(batch)
        except Exception:
            logger.warning("Run %s: failed to persist %d subagent step event(s)", self._run_id, len(batch), exc_info=True)
```

> 长任务里子代理可能跑 `max_turns=150` 产数百 step 事件。逐个 `put()` 会与 run 自己的 message-batch writer 抢同一把 per-thread advisory lock。`_SubagentEventBuffer` 累积到 25 或遇 `subagent.end` 才 `put_batch` 一次拿锁，且在 `run_agent` 的 `finally` 里兜底 flush，保证 abort/异常路径的 step 也落盘。

---

## 3. `_collect_pre_existing_message_ids` + `_message_id`（pre-run 历史消息 id 收集）

```python
# core/helix/runtime/runs/worker.py
def _message_id(obj: Any) -> str | None:
    """Best-effort extraction of a stable message id from a message-like object."""
    msg_id = getattr(obj, "id", None)
    if isinstance(msg_id, str) and msg_id:
        return msg_id
    if isinstance(obj, dict):
        raw = obj.get("id")
        if isinstance(raw, str) and raw:
            return raw
    return None


def _collect_pre_existing_message_ids(snapshot: dict[str, Any] | None) -> set[str]:
    """Pull stable message ids out of a pre-run checkpoint snapshot.

    Used by :func:`run_agent` to mask stale ``helix_error_fallback`` markers
    on history messages so they don't trip the current run's failure path. A
    missing or malformed snapshot yields an empty set (best-effort - we
    intentionally never raise from this helper).
    """
    if not isinstance(snapshot, dict):
        return set()
    checkpoint = snapshot.get("checkpoint")
    if not isinstance(checkpoint, dict):
        return set()
    channel_values = checkpoint.get("channel_values")
    if not isinstance(channel_values, dict):
        return set()
    messages = channel_values.get("messages")
    if not isinstance(messages, (list, tuple)):
        return set()
    ids: set[str] = set()
    for msg in messages:
        msg_id = _message_id(msg)
        if msg_id is not None:
            ids.add(msg_id)
    return ids
```

> **为何要 pre-existing ids**：LangGraph 在 `stream_mode="values"` 会把**整段历史消息**回放进每个 chunk。若历史里有一条带 `helix_error_fallback` 标记的旧消息（上一轮 run 留下），不屏蔽的话本轮每个 chunk 都会被判为 error，把一个早已解决的旧 fallback 错误地传播到当前 run。`pre_existing_message_ids` 收集 pre-run 快照里的消息 id，流循环据此跳过历史标记。

---

## 4. `run_agent`（完整：pre-run 快照 + 流循环协作取消 + 终结 rollback + finally 收尾）

```python
# core/helix/runtime/runs/worker.py
async def run_agent(
    bridge: StreamBridge,
    run_manager: RunManager,
    record: RunRecord,
    *,
    ctx: RunContext,
    agent_factory: Any,
    graph_input: dict,
    config: dict,
    stream_modes: list[str] | None = None,
    stream_subgraphs: bool = False,
    interrupt_before: list[str] | Literal["*"] | None = None,
    interrupt_after: list[str] | Literal["*"] | None = None,
) -> None:
    """Execute an agent in the background, publishing events to *bridge*."""

    # Unpack infrastructure dependencies from RunContext.
    checkpointer = ctx.checkpointer
    store = ctx.store
    event_store = ctx.event_store
    run_events_config = ctx.run_events_config
    thread_store = ctx.thread_store

    run_id = record.run_id
    thread_id = record.thread_id
    requested_modes: set[str] = set(stream_modes or ["values"])
    pre_run_checkpoint_id: str | None = None
    pre_run_snapshot: dict[str, Any] | None = None
    pre_run_workspace_snapshot: WorkspaceSnapshot | None = None
    workspace_changes_user_id: str | None = None
    snapshot_capture_failed = False
    llm_error_fallback_message: str | None = None
    # Message ids checkpointed *before* this run started. The stream loop uses
    # this set to mask out ``helix_error_fallback`` markers that belong to
    # earlier runs on the same thread - without it, one stale fallback in
    # history would mark every subsequent run on this thread as ``error``.
    pre_existing_message_ids: set[str] = set()

    journal = None
    # Buffers subagent step events for batched persistence (#3779); assigned once
    # streaming starts and flushed in the finally block. Pre-bound to None so the
    # finally is safe even if an exception fires before streaming begins.
    subagent_events: _SubagentEventBuffer | None = None

    # Track whether "events" was requested but skipped
    if "events" in requested_modes:
        logger.info(
            "Run %s: 'events' stream_mode not supported in gateway (requires astream_events + checkpoint callbacks). Skipping.",
            run_id,
        )

    try:
        await run_manager.wait_for_prior_finalizing(thread_id, run_id)

        # Initialize RunJournal + write human_message event.
        # These are inside the try block so any exception (e.g. a DB
        # error writing the event) flows through the except/finally
        # path that publishes an "end" event to the SSE bridge -
        # otherwise a failure here would leave the stream hanging
        # with no terminator.
        if event_store is not None:
            from helix.runtime.journal import RunJournal

            journal = RunJournal(
                run_id=run_id,
                thread_id=thread_id,
                event_store=event_store,
                track_token_usage=getattr(run_events_config, "track_token_usage", True),
                progress_reporter=lambda snapshot: run_manager.update_run_progress(run_id, **snapshot),
            )

        # 1. Mark running
        await run_manager.set_status(run_id, RunStatus.running)

        if event_store is not None:
            workspace_changes_user_id = get_effective_user_id()
            try:
                pre_run_workspace_snapshot = await capture_workspace_snapshot(
                    thread_id,
                    user_id=workspace_changes_user_id,
                )
            except Exception:
                logger.warning("Could not capture pre-run workspace snapshot for run %s", run_id, exc_info=True)

        # Snapshot the latest pre-run checkpoint so rollback can restore it.
        # —— 跨切不变量 3 的回滚锚点：深拷贝 checkpoint/metadata/pending_writes，冻结成不可变快照 ——
        if checkpointer is not None:
            try:
                config_for_check = {"configurable": {"thread_id": thread_id, "checkpoint_ns": ""}}
                ckpt_tuple = await checkpointer.aget_tuple(config_for_check)
                if ckpt_tuple is not None:
                    ckpt_config = getattr(ckpt_tuple, "config", {}).get("configurable", {})
                    pre_run_checkpoint_id = ckpt_config.get("checkpoint_id")
                    pre_run_snapshot = {
                        "checkpoint_ns": ckpt_config.get("checkpoint_ns", ""),
                        "checkpoint": copy.deepcopy(getattr(ckpt_tuple, "checkpoint", {})),
                        "metadata": copy.deepcopy(getattr(ckpt_tuple, "metadata", {})),
                        "pending_writes": copy.deepcopy(getattr(ckpt_tuple, "pending_writes", []) or []),
                    }
                    pre_existing_message_ids = _collect_pre_existing_message_ids(pre_run_snapshot)
            except Exception:
                snapshot_capture_failed = True   # 快照失败：rollback 时降级跳过，不抛错卡住 run
                logger.warning("Could not capture pre-run checkpoint snapshot for run %s", run_id, exc_info=True)

        # 2. Publish metadata - useStream needs both run_id AND thread_id
        await bridge.publish(
            run_id,
            "metadata",
            {
                "run_id": run_id,
                "thread_id": thread_id,
            },
        )

        # 3. Build the agent
        from langchain_core.runnables import RunnableConfig
        from langgraph.runtime import Runtime

        # Inject runtime context so middlewares and tools (via ToolRuntime.context) can
        # access thread-level data. langgraph-cli does this automatically; we must do it
        # manually here because we drive the graph through ``agent.astream(config=...)``
        # without passing the official ``context=`` parameter.
        runtime_ctx = _build_runtime_context(thread_id, run_id, config.get("context"), ctx.app_config)
        incoming_metadata = config.get("metadata") if isinstance(config.get("metadata"), dict) else {}
        helix_trace_id = normalize_trace_id(incoming_metadata.get(HELIX_TRACE_METADATA_KEY)) or get_current_trace_id()
        if helix_trace_id:
            runtime_ctx[HELIX_TRACE_METADATA_KEY] = helix_trace_id
        # Expose the run-scoped journal under a sentinel key so middleware can
        # write audit events (e.g. SafetyFinishReasonMiddleware recording
        # suppressed tool calls). Double-underscore prefix marks it as a
        # runtime-internal channel; user code must not depend on the key name.
        if journal is not None:
            runtime_ctx["__run_journal"] = journal
        _install_runtime_context(config, runtime_ctx)
        runtime = Runtime(context=cast(Any, runtime_ctx), store=store)
        config.setdefault("configurable", {})["__pregel_runtime"] = runtime

        # Inject RunJournal as a LangChain callback handler.
        # on_llm_end captures token usage; on_chain_start/end captures lifecycle.
        if journal is not None:
            config.setdefault("callbacks", []).append(journal)

        # Inject Langfuse trace-attribute metadata so the langchain CallbackHandler
        # can lift session_id / user_id / trace_name / tags onto the root trace.
        # Shared helper with the embedded client's ``stream`` so both entry points stay
        # in sync; caller-provided metadata wins via setdefault inside the helper.
        inject_langfuse_metadata(
            config,
            thread_id=thread_id,
            user_id=resolve_runtime_user_id(runtime),
            assistant_id=record.assistant_id,
            model_name=record.model_name,
            environment=os.environ.get("HELIX_ENV") or os.environ.get("ENVIRONMENT"),
            helix_trace_id=helix_trace_id,
        )

        # Resolve after runtime context installation so context/configurable reflect
        # the agent name that this run will actually execute.
        config.setdefault("run_name", resolve_root_run_name(config, record.assistant_id))
        initial_runnable_config = RunnableConfig(**config)

        def _continuation_runnable_config() -> RunnableConfig:
            continuation_config = dict(config)
            configurable = dict(continuation_config.get("configurable", {}) or {})
            configurable["checkpoint_ns"] = ""
            configurable.pop("checkpoint_id", None)
            configurable.pop("checkpoint_map", None)
            continuation_config["configurable"] = configurable
            return RunnableConfig(**continuation_config)

        if ctx.app_config is not None and _agent_factory_supports_app_config(agent_factory):
            agent = agent_factory(config=initial_runnable_config, app_config=ctx.app_config)
        else:
            agent = agent_factory(config=initial_runnable_config)

        # Capture the effective (resolved) model name from the agent's metadata.
        # _resolve_model_name in agent.py may return the default model if the
        # requested name is not in the allowlist - this update ensures the
        # persisted model_name reflects the actual model used.
        if record.model_name is not None:
            resolved = getattr(agent, "metadata", {}) or {}
            if isinstance(resolved, dict):
                effective = resolved.get("model_name")
                if effective and effective != record.model_name:
                    await run_manager.update_model_name(record.run_id, effective)

        # 4. Attach checkpointer and store
        if checkpointer is not None:
            agent.checkpointer = checkpointer
        if store is not None:
            agent.store = store

        # 5. Set interrupt nodes
        if interrupt_before:
            agent.interrupt_before_nodes = interrupt_before
        if interrupt_after:
            agent.interrupt_after_nodes = interrupt_after

        # 6. Build LangGraph stream_mode list
        #    "events" is NOT a valid astream mode - skip it
        #    "messages-tuple" maps to LangGraph's "messages" mode
        lg_modes: list[str] = []
        for m in requested_modes:
            if m == "messages-tuple":
                lg_modes.append("messages")
            elif m == "events":
                # Skipped - see log above
                continue
            elif m in _VALID_LG_MODES:
                lg_modes.append(m)
        if not lg_modes:
            lg_modes = ["values"]

        # Deduplicate while preserving order
        seen: set[str] = set()
        deduped: list[str] = []
        for m in lg_modes:
            if m not in seen:
                seen.add(m)
                deduped.append(m)
        lg_modes = deduped

        logger.info("Run %s: streaming with modes %s (requested: %s)", run_id, lg_modes, requested_modes)

        # Buffer subagent step events and persist them in batches (#3779) instead
        # of one low-frequency put() per step on the hot stream loop. Flushed in
        # the finally block so buffered steps survive abort/exception paths too.
        subagent_events = _SubagentEventBuffer(event_store, thread_id, run_id)

        goal_evaluator_model: Any | None = None

        def _get_goal_evaluator_model() -> Any:
            nonlocal goal_evaluator_model
            if goal_evaluator_model is None:
                goal_evaluator_model = create_goal_evaluator_model(
                    model_name=record.model_name,
                    app_config=ctx.app_config,
                )
            return goal_evaluator_model

        async def _stream_once(input_payload: Any, stream_config: RunnableConfig) -> None:
            nonlocal llm_error_fallback_message
            if len(lg_modes) == 1 and not stream_subgraphs:
                # Single mode, no subgraphs: astream yields raw chunks
                single_mode = lg_modes[0]
                async for chunk in agent.astream(input_payload, config=stream_config, stream_mode=single_mode):
                    if record.abort_event.is_set():                 # 协作式取消：检测到 abort 立即停
                        logger.info("Run %s abort requested - stopping", run_id)
                        break
                    llm_error_fallback_message = llm_error_fallback_message or _extract_llm_error_fallback_message(chunk, pre_existing_message_ids)
                    sse_event = _lg_mode_to_sse_event(single_mode)
                    await bridge.publish(run_id, sse_event, serialize(chunk, mode=single_mode))
                    if single_mode == "custom":
                        await subagent_events.add(chunk)
                return
            # Multiple modes or subgraphs: astream yields tuples
            async for item in agent.astream(
                input_payload,
                config=stream_config,
                stream_mode=lg_modes,
                subgraphs=stream_subgraphs,
            ):
                if record.abort_event.is_set():
                    logger.info("Run %s abort requested - stopping", run_id)
                    break

                mode, chunk = _unpack_stream_item(item, lg_modes, stream_subgraphs)
                if mode is None:
                    continue

                llm_error_fallback_message = llm_error_fallback_message or _extract_llm_error_fallback_message(chunk, pre_existing_message_ids)
                sse_event = _lg_mode_to_sse_event(mode)
                await bridge.publish(run_id, sse_event, serialize(chunk, mode=mode))
                if mode == "custom":
                    await subagent_events.add(chunk)

        # 7. Stream the requested turn, then optionally continue hidden goal turns.
        await _stream_once(graph_input, initial_runnable_config)
        while not record.abort_event.is_set() and not llm_error_fallback_message and (journal is None or not journal.had_llm_error_fallback):
            continuation_input = await _prepare_goal_continuation_input(
                bridge=bridge,
                checkpointer=checkpointer,
                thread_id=thread_id,
                run_id=run_id,
                model_name=record.model_name,
                app_config=ctx.app_config,
                evaluator_model_factory=_get_goal_evaluator_model,
                abort_event=record.abort_event,
            )
            if continuation_input is None or record.abort_event.is_set():
                break
            await _stream_once(continuation_input, _continuation_runnable_config())

        # 8. Final status
        if record.abort_event.is_set():
            await run_manager.set_finalizing(run_id, True)
            action = record.abort_action
            if action == "rollback":
                await run_manager.set_status(run_id, RunStatus.error, error="Rolled back by user")
                try:
                    await _rollback_to_pre_run_checkpoint(
                        checkpointer=checkpointer,
                        thread_id=thread_id,
                        run_id=run_id,
                        pre_run_checkpoint_id=pre_run_checkpoint_id,
                        pre_run_snapshot=pre_run_snapshot,
                        snapshot_capture_failed=snapshot_capture_failed,
                    )
                    logger.info("Run %s rolled back to pre-run checkpoint %s", run_id, pre_run_checkpoint_id)
                except Exception:
                    logger.warning("Failed to rollback checkpoint for run %s", run_id, exc_info=True)
            else:
                await run_manager.set_status(run_id, RunStatus.interrupted)
        elif llm_error_fallback_message or (journal is not None and journal.had_llm_error_fallback):
            error_msg = llm_error_fallback_message
            if error_msg is None and journal is not None:
                error_msg = journal.llm_error_fallback_message
            error_msg = error_msg or "LLM provider failed after retries"
            await run_manager.set_status(run_id, RunStatus.error, error=error_msg)
        else:
            await run_manager.set_status(run_id, RunStatus.success)

    except asyncio.CancelledError:
        # task.cancel() 触发：同样按 abort_action 决定回滚或 interrupt
        await run_manager.set_finalizing(run_id, True)
        action = record.abort_action
        if action == "rollback":
            await run_manager.set_status(run_id, RunStatus.error, error="Rolled back by user")
            try:
                await _rollback_to_pre_run_checkpoint(
                    checkpointer=checkpointer,
                    thread_id=thread_id,
                    run_id=run_id,
                    pre_run_checkpoint_id=pre_run_checkpoint_id,
                    pre_run_snapshot=pre_run_snapshot,
                    snapshot_capture_failed=snapshot_capture_failed,
                )
                logger.info("Run %s was cancelled and rolled back", run_id)
            except Exception:
                logger.warning("Run %s cancellation rollback failed", run_id, exc_info=True)
        else:
            await run_manager.set_status(run_id, RunStatus.interrupted)
            logger.info("Run %s was cancelled", run_id)

    except Exception as exc:
        error_msg = f"{exc}"
        logger.exception("Run %s failed: %s", run_id, error_msg)
        await run_manager.set_status(run_id, RunStatus.error, error=error_msg)
        await bridge.publish(
            run_id,
            "error",
            {
                "message": error_msg,
                "name": type(exc).__name__,
            },
        )

    finally:
        # Persist any subagent step events still buffered (#3779) - including on
        # abort/exception paths, where the stream loop broke before its own flush.
        if subagent_events is not None:
            await subagent_events.flush()

        if event_store is not None and pre_run_workspace_snapshot is not None:
            try:
                await record_workspace_changes(
                    event_store,
                    thread_id,
                    run_id,
                    pre_run_workspace_snapshot,
                    user_id=workspace_changes_user_id,
                )
            except Exception:
                logger.warning("Failed to record workspace changes for run %s", run_id, exc_info=True)

        # Flush any buffered journal events and persist completion data
        if journal is not None:
            try:
                await journal.flush()
            except Exception:
                logger.warning("Failed to flush journal for run %s", run_id, exc_info=True)

            try:
                # Persist token usage + convenience fields to RunStore
                completion = journal.get_completion_data()
                await run_manager.update_run_completion(run_id, status=record.status.value, **completion)
            except Exception:
                logger.warning("Failed to persist run completion for %s (non-fatal)", run_id, exc_info=True)

        if checkpointer is not None and record.status == RunStatus.interrupted:
            try:
                await run_manager.wait_for_prior_finalizing(thread_id, run_id)
                if not await run_manager.has_later_started_run(thread_id, run_id):
                    await _ensure_interrupted_title(checkpointer=checkpointer, thread_id=thread_id, app_config=ctx.app_config, graph_input=graph_input)
            except Exception:
                logger.debug("Failed to generate interrupted title for thread %s (non-fatal)", thread_id)

        # Sync title from checkpoint to threads_meta.display_name
        if checkpointer is not None and thread_store is not None:
            try:
                ckpt_config = {"configurable": {"thread_id": thread_id, "checkpoint_ns": ""}}
                ckpt_tuple = await checkpointer.aget_tuple(ckpt_config)
                if ckpt_tuple is not None:
                    ckpt = getattr(ckpt_tuple, "checkpoint", {}) or {}
                    title = ckpt.get("channel_values", {}).get("title")
                    if title:
                        await thread_store.update_display_name(thread_id, title)
            except Exception:
                logger.debug("Failed to sync title for thread %s (non-fatal)", thread_id)

        # Update threads_meta status based on run outcome
        if thread_store is not None:
            try:
                final_status = "idle" if record.status == RunStatus.success else record.status.value
                await thread_store.update_status(thread_id, final_status)
            except Exception:
                logger.debug("Failed to update thread_meta status for %s (non-fatal)", thread_id)

        if ctx.on_run_completed is not None:
            try:
                await ctx.on_run_completed(record)
            except Exception:
                logger.warning("Run completion hook failed for %s (non-fatal)", run_id, exc_info=True)
        if record.finalizing:
            await run_manager.set_finalizing(run_id, False)

        # —— finally 末尾两行：保证任何路径都 publish_end + 延迟清理 ——
        await bridge.publish_end(run_id)
        asyncio.create_task(bridge.cleanup(run_id, delay=60))
```

> **run_agent 与长任务通道的三个关键点**：
> 1. **pre-run 快照深拷贝**：`copy.deepcopy` checkpoint/metadata/pending_writes。run 期间 checkpointer 持续写新 checkpoint，浅拷贝会让回滚读到被本 run 污染后的状态。快照捕获失败设 `snapshot_capture_failed=True`，rollback 时降级跳过而非抛错卡住 run。
> 2. **协作式取消**：流循环每 chunk 检查 `record.abort_event.is_set()`，命中即 `break`。`cancel()` / `create_or_reject` 只设 `abort_event`+`abort_action`+`task.cancel()`，不持锁做 IO；worker 在终结路径读 `abort_action` 决定 rollback 或 interrupt。`asyncio.CancelledError` 路径与正常 abort 退出走**同一套** rollback/interrupt 分支。
> 3. **finally 一定 `publish_end`**：无论 success/error/cancel/exception，`finally` 末尾 `bridge.publish_end(run_id)` 让 bridge `subscribe` yield `END_SENTINEL`，`sse_consumer` / `wait_for_run_completion` 才能收尾；`cleanup(delay=60)` 给迟到订阅者排空机会。

---

## 5. `_rollback_to_pre_run_checkpoint` + `_new_checkpoint_marker`（完整）

```python
# core/helix/runtime/runs/worker.py
async def _rollback_to_pre_run_checkpoint(
    *,
    checkpointer: Any,
    thread_id: str,
    run_id: str,
    pre_run_checkpoint_id: str | None,
    pre_run_snapshot: dict[str, Any] | None,
    snapshot_capture_failed: bool,
) -> None:
    """Restore thread state to the checkpoint snapshot captured before run start."""
    if checkpointer is None:
        logger.info("Run %s rollback requested but no checkpointer is configured", run_id)
        return

    if snapshot_capture_failed:
        # 快照捕获失败：跳过回滚（不抛错卡住 run），记 warn
        logger.warning("Run %s rollback skipped: pre-run checkpoint snapshot capture failed", run_id)
        return

    if pre_run_snapshot is None:
        # run 前线程为空：直接删整个线程，回到空状态
        await _call_checkpointer_method(checkpointer, "adelete_thread", "delete_thread", thread_id)
        logger.info("Run %s rollback reset thread %s to empty state", run_id, thread_id)
        return

    checkpoint_to_restore = None
    metadata_to_restore: dict[str, Any] = {}
    checkpoint_ns = ""
    checkpoint = pre_run_snapshot.get("checkpoint")
    if not isinstance(checkpoint, dict):
        logger.warning("Run %s rollback skipped: invalid pre-run checkpoint snapshot", run_id)
        return
    checkpoint_to_restore = checkpoint
    if checkpoint_to_restore.get("id") is None and pre_run_checkpoint_id is not None:
        checkpoint_to_restore = {**checkpoint_to_restore, "id": pre_run_checkpoint_id}
    if checkpoint_to_restore.get("id") is None:
        logger.warning("Run %s rollback skipped: pre-run checkpoint has no checkpoint id", run_id)
        return
    # 新 id/ts 标记：回滚不是覆盖旧 checkpoint，而是写一个"新的"checkpoint，
    # 其 channel_values = pre-run 快照内容。新 id/ts 保证 DB-backed saver
    # （Postgres/Sqlite blob 按 channel_versions 键存）能正确写入新版本。
    restore_marker = _new_checkpoint_marker()   # empty_checkpoint() 产新 id/ts
    checkpoint_to_restore = {
        **checkpoint_to_restore,
        "id": restore_marker["id"],
        "ts": restore_marker["ts"],
    }
    metadata = pre_run_snapshot.get("metadata", {})
    metadata_to_restore = metadata if isinstance(metadata, dict) else {}
    raw_checkpoint_ns = pre_run_snapshot.get("checkpoint_ns")
    checkpoint_ns = raw_checkpoint_ns if isinstance(raw_checkpoint_ns, str) else ""

    channel_versions = checkpoint_to_restore.get("channel_versions")
    new_versions = dict(channel_versions) if isinstance(channel_versions, dict) else {}

    restore_config = {"configurable": {"thread_id": thread_id, "checkpoint_ns": checkpoint_ns}}
    # aput 写入恢复后的 checkpoint：线程最新 checkpoint 指向 pre-run 状态
    restored_config = await _call_checkpointer_method(
        checkpointer,
        "aput",
        "put",
        restore_config,
        checkpoint_to_restore,
        metadata_to_restore if isinstance(metadata_to_restore, dict) else {},
        new_versions,
    )
    if not isinstance(restored_config, dict):
        raise RuntimeError(f"Run {run_id} rollback restore returned invalid config: expected dict")
    restored_configurable = restored_config.get("configurable", {})
    if not isinstance(restored_configurable, dict):
        raise RuntimeError(f"Run {run_id} rollback restore returned invalid config payload")
    restored_checkpoint_id = restored_configurable.get("checkpoint_id")
    if not restored_checkpoint_id:
        raise RuntimeError(f"Run {run_id} rollback restore did not return checkpoint_id")

    # 恢复 pending_writes：按 task_id 分组 aput_writes，使未完成写入也回到 pre-run 状态
    pending_writes = pre_run_snapshot.get("pending_writes", [])
    if not pending_writes:
        return

    writes_by_task: dict[str, list[tuple[str, Any]]] = {}
    for item in pending_writes:
        if not isinstance(item, (tuple, list)) or len(item) != 3:
            raise RuntimeError(f"Run {run_id} rollback failed: pending_write is not a 3-tuple: {item!r}")
        task_id, channel, value = item
        if not isinstance(channel, str):
            raise RuntimeError(f"Run {run_id} rollback failed: pending_write has non-string channel: task_id={task_id!r}, channel={channel!r}")
        writes_by_task.setdefault(str(task_id), []).append((channel, value))

    for task_id, writes in writes_by_task.items():
        await _call_checkpointer_method(
            checkpointer,
            "aput_writes",
            "put_writes",
            restored_config,
            writes,
            task_id=task_id,
        )


def _new_checkpoint_marker() -> dict[str, str]:
    marker = empty_checkpoint()
    return {"id": marker["id"], "ts": marker["ts"]}
```

> 注：`_call_checkpointer_method` 是兼容 sync/async、新旧方法名（`aput`/`put`、`adelete_thread`/`delete_thread`、`aput_writes`/`put_writes`）的适配器（见 `core/helix/runtime/goal.py`）。`empty_checkpoint` 来自 `langgraph.checkpoint.base`，产全新 id/ts。

---

## 关键不变量与测试锚点

1. **pre-run 快照深拷贝**：`copy.deepcopy` checkpoint/metadata/pending_writes，防 run 期间 checkpointer 写新 checkpoint 污染快照。
2. **快照失败降级**：`snapshot_capture_failed=True` 时 rollback 跳过并记 warn，不抛错卡住 run。
3. **rollback 写新 checkpoint**：`_new_checkpoint_marker()` 产新 id/ts，载 pre-run `channel_values`，`aput` 写入；不覆盖旧 checkpoint（DB-backed saver 版本冲突）。
4. **pending_writes 恢复**：按 `task_id` 分组 `aput_writes`，使未完成写也回 pre-run。
5. **空线程 rollback**：`pre_run_snapshot is None` 时 `adelete_thread`，回到空状态。
6. **abort_action 协作**：`cancel(action)` 与 `create_or_reject(multitask_strategy)` 都只设 `abort_action`+`abort_event`（不持锁做 IO），worker 终结路径（正常 abort / `CancelledError`）读它决定 rollback 或 interrupt。
7. **`CancelledError` 与正常 abort 同路径**：两条终结分支都读 `record.abort_action`，rollback 分支一致。
8. **finally 一定 publish_end**：success/error/cancel/exception 任何路径，`finally` 末尾 `publish_end` + `cleanup(delay=60)`。
9. **协作式取消粒度**：流循环每 chunk 检查 `abort_event`，goal continuation 每 turn 检查；取消不是立即的，是在下个 chunk/turn 边界生效。
10. **`pre_existing_message_ids` 屏蔽历史 fallback**：防 LangGraph `values` 模式回放历史时把旧 `helix_error_fallback` 标记误判为本轮 error。

> 关联：`run-manager.md`（`cancel` / `create_or_reject` 设 `abort_action`）、`stream-bridge-resume.md`（`publish_end` -> `END_SENTINEL` -> `sse_consumer` 收尾）、`[[e2e-request-lifecycle]]`（跨切不变量 3）、脊柱 `references/code/07-streaming-and-resume.md`（rollback 函数同等深度）。
