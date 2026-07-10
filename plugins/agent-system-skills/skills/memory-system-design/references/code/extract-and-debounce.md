# 完整源码：入队入口 + 防抖队列 + LLM 抽取 + 消息处理 + prompt 模板

> 本文件给出记忆系统**写路径**全貌：入队入口（`MemoryMiddleware.after_agent`，捕获 `user_id` + trace_id）、debounce 队列、`MemoryUpdater`（同步 LLM 抽取 + 合并 + 陈旧审查 + 上传清洗）、手动 CRUD、消息过滤、摘要前 flush hook、抽取 prompt 模板。SKILL.md 实现索引段给了入队入口与注入接线的伪代码。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`），去除一切项目字样。原代码注释保留以保真。

## 1. 入队入口（MemoryMiddleware.after_agent -- 捕获 user_id，第一不变量）

```python
# core/helix/agents/middlewares/memory_middleware.py
class MemoryMiddleware(AgentMiddleware[MemoryMiddlewareState]):
    """Middleware that queues conversation for memory update after agent execution.

    This middleware:
    1. After each agent execution, queues the conversation for memory update
    2. Only includes user inputs and final assistant responses (ignores tool calls)
    3. The queue uses debouncing to batch multiple updates together
    4. Memory is updated asynchronously via LLM summarization
    """

    state_schema = MemoryMiddlewareState

    def __init__(self, agent_name: str | None = None, *, memory_config: "MemoryConfig | None" = None):
        super().__init__()
        self._agent_name = agent_name
        self._memory_config = memory_config

    @override
    def after_agent(self, state: MemoryMiddlewareState, runtime: Runtime) -> dict | None:
        """Queue conversation for memory update after agent completes."""
        config = self._memory_config or get_memory_config()
        if not config.enabled:
            return None

        # Get thread ID from runtime context first, then fall back to LangGraph's configurable metadata
        thread_id = runtime.context.get("thread_id") if runtime.context else None
        if thread_id is None:
            config_data = get_config()
            thread_id = config_data.get("configurable", {}).get("thread_id")
        if not thread_id:
            logger.debug("No thread_id in context, skipping memory update")
            return None

        messages = state.get("messages", [])
        if not messages:
            logger.debug("No messages in state, skipping memory update")
            return None

        # Filter to only keep user inputs and final assistant responses
        filtered_messages = filter_messages_for_memory(messages)

        # Only queue if there's meaningful conversation
        # At minimum need one user message and one assistant response
        user_messages = [m for m in filtered_messages if getattr(m, "type", None) == "human"]
        assistant_messages = [m for m in filtered_messages if getattr(m, "type", None) == "ai"]

        if not user_messages or not assistant_messages:
            return None

        # Queue the filtered conversation for memory update
        correction_detected = detect_correction(filtered_messages)
        reinforcement_detected = not correction_detected and detect_reinforcement(filtered_messages)
        # Capture user_id at enqueue time while the request context is still alive.
        # threading.Timer fires on a different thread where ContextVar values are not
        # propagated, so we must store user_id explicitly in ConversationContext.
        user_id = get_effective_user_id()
        runtime_context = runtime.context if isinstance(runtime.context, dict) else {}
        helix_trace_id = normalize_trace_id(runtime_context.get(HELIX_TRACE_METADATA_KEY))
        if helix_trace_id is None:
            try:
                config_data = get_config()
            except RuntimeError:
                config_data = {}
            config_metadata = config_data.get("metadata", {}) if isinstance(config_data.get("metadata"), dict) else {}
            helix_trace_id = normalize_trace_id(config_metadata.get(HELIX_TRACE_METADATA_KEY))
        if helix_trace_id is None:
            helix_trace_id = get_current_trace_id()
        queue = get_memory_queue()
        queue.add(
            thread_id=thread_id,
            messages=filtered_messages,
            agent_name=self._agent_name,
            user_id=user_id,
            helix_trace_id=helix_trace_id,
            correction_detected=correction_detected,
            reinforcement_detected=reinforcement_detected,
        )

        return None
```

**要点**：

- **第一不变量**：`user_id = get_effective_user_id()` 在请求线程（contextvar 可见）执行，存入 `ConversationContext`。`threading.Timer` 线程不继承 ContextVar，若在此处才读会永远拿到 fallback `"default"`，记忆**串号**到默认用户。`helix_trace_id` 同理捕获（Timer 线程不继承 trace contextvar），后续在 `_process_queue` 里 `request_trace_context(...)` 重绑定。
- `filter_messages_for_memory` 剥掉工具调用、`<uploaded_files>` 块、`hide_from_ui` 的框架注入消息（防 `__memory` 载荷自放大循环，见 §4）。
- `correction_detected` 抑制 `reinforcement_detected`（纠正更强）：`reinforcement = not correction and detect_reinforcement(...)`。
- `thread_id` 解析优先 `runtime.context`，回退 LangGraph `configurable` metadata；两者皆空则跳过（无 thread_id 无法定位会话）。

## 2. ConversationContext + 防抖队列

```python
# core/helix/agents/memory/queue.py
"""Memory update queue with debounce mechanism."""

import logging
import threading
import time
from contextlib import nullcontext
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from helix.config.memory_config import get_memory_config
from helix.trace_context import request_trace_context

logger = logging.getLogger(__name__)


@dataclass
class ConversationContext:
    """Context for a conversation to be processed for memory update."""

    thread_id: str
    messages: list[Any]
    timestamp: datetime = field(default_factory=lambda: datetime.now(UTC))
    agent_name: str | None = None
    user_id: str | None = None
    helix_trace_id: str | None = None
    correction_detected: bool = False
    reinforcement_detected: bool = False


class MemoryUpdateQueue:
    """Queue for memory updates with debounce mechanism.

    This queue collects conversation contexts and processes them after
    a configurable debounce period. Multiple conversations received within
    the debounce window are batched together.
    """

    def __init__(self):
        """Initialize the memory update queue."""
        self._queue: list[ConversationContext] = []
        self._lock = threading.Lock()
        self._timer: threading.Timer | None = None
        self._processing = False

    @staticmethod
    def _queue_key(
        thread_id: str,
        user_id: str | None,
        agent_name: str | None,
    ) -> tuple[str, str | None, str | None]:
        """Return the debounce identity for a memory update target."""
        return (thread_id, user_id, agent_name)

    def add(
        self,
        thread_id: str,
        messages: list[Any],
        agent_name: str | None = None,
        user_id: str | None = None,
        helix_trace_id: str | None = None,
        correction_detected: bool = False,
        reinforcement_detected: bool = False,
    ) -> None:
        """Add a conversation to the update queue.

        Args:
            thread_id: The thread ID.
            messages: The conversation messages.
            agent_name: If provided, memory is stored per-agent. If None, uses global memory.
            user_id: The user ID captured at enqueue time. Stored in ConversationContext so it
                survives the threading.Timer boundary (ContextVar does not propagate across
                raw threads).
            helix_trace_id: Request trace id captured at enqueue time so the
                later Timer thread can attach it to memory LLM tracing metadata.
            correction_detected: Whether recent turns include an explicit correction signal.
            reinforcement_detected: Whether recent turns include a positive reinforcement signal.
        """
        config = get_memory_config()
        if not config.enabled:
            return

        with self._lock:
            self._enqueue_locked(
                thread_id=thread_id,
                messages=messages,
                agent_name=agent_name,
                user_id=user_id,
                helix_trace_id=helix_trace_id,
                correction_detected=correction_detected,
                reinforcement_detected=reinforcement_detected,
            )
            self._reset_timer()

        logger.info("Memory update queued for thread %s, queue size: %d", thread_id, len(self._queue))

    def add_nowait(
        self,
        thread_id: str,
        messages: list[Any],
        agent_name: str | None = None,
        user_id: str | None = None,
        helix_trace_id: str | None = None,
        correction_detected: bool = False,
        reinforcement_detected: bool = False,
    ) -> None:
        """Add a conversation and start processing immediately in the background."""
        config = get_memory_config()
        if not config.enabled:
            return

        with self._lock:
            self._enqueue_locked(
                thread_id=thread_id,
                messages=messages,
                agent_name=agent_name,
                user_id=user_id,
                helix_trace_id=helix_trace_id,
                correction_detected=correction_detected,
                reinforcement_detected=reinforcement_detected,
            )
            self._schedule_timer(0)

        logger.info("Memory update queued for immediate processing on thread %s, queue size: %d", thread_id, len(self._queue))

    def _enqueue_locked(
        self,
        *,
        thread_id: str,
        messages: list[Any],
        agent_name: str | None,
        user_id: str | None,
        helix_trace_id: str | None,
        correction_detected: bool,
        reinforcement_detected: bool,
    ) -> None:
        queue_key = self._queue_key(thread_id, user_id, agent_name)
        existing_context = next(
            (context for context in self._queue if self._queue_key(context.thread_id, context.user_id, context.agent_name) == queue_key),
            None,
        )
        merged_correction_detected = correction_detected or (existing_context.correction_detected if existing_context is not None else False)
        merged_reinforcement_detected = reinforcement_detected or (existing_context.reinforcement_detected if existing_context is not None else False)
        context = ConversationContext(
            thread_id=thread_id,
            messages=messages,
            agent_name=agent_name,
            user_id=user_id,
            helix_trace_id=helix_trace_id,
            correction_detected=merged_correction_detected,
            reinforcement_detected=merged_reinforcement_detected,
        )

        self._queue = [context for context in self._queue if self._queue_key(context.thread_id, context.user_id, context.agent_name) != queue_key]
        self._queue.append(context)

    def _reset_timer(self) -> None:
        """Reset the debounce timer."""
        config = get_memory_config()
        self._schedule_timer(config.debounce_seconds)

        logger.debug("Memory update timer set for %ss", config.debounce_seconds)

    def _schedule_timer(self, delay_seconds: float) -> None:
        """Schedule queue processing after the provided delay."""
        # Cancel existing timer if any
        if self._timer is not None:
            self._timer.cancel()

        self._timer = threading.Timer(
            delay_seconds,
            self._process_queue,
        )
        self._timer.daemon = True
        self._timer.start()

    def _process_queue(self) -> None:
        """Process all queued conversation contexts."""
        # Import here to avoid circular dependency
        from helix.agents.memory.updater import MemoryUpdater

        with self._lock:
            if self._processing:
                # Preserve immediate flush semantics even if another worker is active.
                self._schedule_timer(0)
                return

            if not self._queue:
                return

            self._processing = True
            contexts_to_process = self._queue.copy()
            self._queue.clear()
            self._timer = None

        logger.info("Processing %d queued memory updates", len(contexts_to_process))

        try:
            updater = MemoryUpdater()

            for context in contexts_to_process:
                # Rebind the request-trace ContextVar from the value captured at
                # enqueue time so ``TraceContextFilter`` attaches the correct
                # trace id to every log record emitted below (this Timer thread
                # does not inherit the enqueue-thread's ContextVar). Each
                # iteration is scoped independently so id A does not leak into
                # id B's logs.
                trace_ctx = request_trace_context(context.helix_trace_id) if context.helix_trace_id else nullcontext()
                with trace_ctx:
                    try:
                        logger.info("Updating memory for thread %s", context.thread_id)
                        success = updater.update_memory(
                            messages=context.messages,
                            thread_id=context.thread_id,
                            agent_name=context.agent_name,
                            correction_detected=context.correction_detected,
                            reinforcement_detected=context.reinforcement_detected,
                            user_id=context.user_id,
                            helix_trace_id=context.helix_trace_id,
                        )
                        if success:
                            logger.info("Memory updated successfully for thread %s", context.thread_id)
                        else:
                            logger.warning("Memory update skipped/failed for thread %s", context.thread_id)
                    except Exception as e:
                        logger.error("Error updating memory for thread %s: %s", context.thread_id, e)

                    # Small delay between updates to avoid rate limiting
                    if len(contexts_to_process) > 1:
                        time.sleep(0.5)

        finally:
            with self._lock:
                self._processing = False

    def flush(self) -> None:
        """Force immediate processing of the queue.

        This is useful for testing or graceful shutdown.
        """
        with self._lock:
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None

        self._process_queue()

    def flush_nowait(self) -> None:
        """Start queue processing immediately in a background thread."""
        with self._lock:
            # Daemon thread: queued messages may be lost if the process exits
            # before _process_queue completes. Acceptable for best-effort memory updates.
            self._schedule_timer(0)

    def clear(self) -> None:
        """Clear the queue without processing.

        This is useful for testing.
        """
        with self._lock:
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None
            self._queue.clear()
            self._processing = False

    @property
    def pending_count(self) -> int:
        """Get the number of pending updates."""
        with self._lock:
            return len(self._queue)

    @property
    def is_processing(self) -> bool:
        """Check if the queue is currently being processed."""
        with self._lock:
            return self._processing


# Global singleton instance
_memory_queue: MemoryUpdateQueue | None = None
_queue_lock = threading.Lock()


def get_memory_queue() -> MemoryUpdateQueue:
    """Get the global memory update queue singleton.

    Returns:
        The memory update queue instance.
    """
    global _memory_queue
    with _queue_lock:
        if _memory_queue is None:
            _memory_queue = MemoryUpdateQueue()
        return _memory_queue


def reset_memory_queue() -> None:
    """Reset the global memory queue.

    This is useful for testing.
    """
    global _memory_queue
    with _queue_lock:
        if _memory_queue is not None:
            _memory_queue.clear()
        _memory_queue = None
```

**要点**：

- `_queue_key = (thread_id, user_id, agent_name)` 是防抖身份：同 key 的新入队**替换**旧快照（最新对话赢），但 `correction_detected` / `reinforcement_detected` 做 OR-合并（早期信号不丢）。
- `_process_queue` 拿锁后设 `_processing=True`、快照队列、清空、**丢锁**，再做 LLM 工作（不持锁做 LLM 调用）。若 flush 请求到来时正在处理，重排 `delay=0` 让在途 worker 下一轮捡起。
- 每个 context 处理前用 `request_trace_context(context.helix_trace_id)` 重绑定 trace contextvar（Timer 线程不继承），让 `TraceContextFilter` 给日志挂对的 trace id；`nullcontext()` 兜底避免 fabricate 假 id。
- Timer 是 daemon 线程：进程退出时未完成更新会丢（可接受，冷数据 best-effort）。

## 3. MemoryUpdater（同步 LLM 抽取 + 合并）

```python
# core/helix/agents/memory/updater.py
"""Memory updater for reading, writing, and updating memory data."""

import asyncio
import atexit
import concurrent.futures
import copy
import json
import logging
import math
import os
import re
import uuid
from contextlib import nullcontext
from datetime import UTC, datetime, timedelta
from typing import Any

from helix.agents.memory.prompt import (
    MEMORY_UPDATE_PROMPT,
    STALENESS_REVIEW_PROMPT,
    format_conversation_for_update,
)
from helix.agents.memory.storage import (
    create_empty_memory,
    get_memory_storage,
    utc_now_iso_z,
)
from helix.config.memory_config import get_memory_config
from helix.models import create_chat_model
from helix.trace_context import request_trace_context
from helix.tracing import inject_langfuse_metadata

logger = logging.getLogger(__name__)


# Thread pool for offloading sync memory updates when called from an async
# context.  Unlike the previous asyncio.run() approach, this runs *sync*
# model.invoke() calls - no event loop is created, so the langchain async
# httpx client pool (globally cached via @lru_cache) is never touched and
# cross-loop connection reuse is impossible.
_SYNC_MEMORY_UPDATER_EXECUTOR = concurrent.futures.ThreadPoolExecutor(
    max_workers=4,
    thread_name_prefix="memory-updater-sync",
)
atexit.register(lambda: _SYNC_MEMORY_UPDATER_EXECUTOR.shutdown(wait=False))


def _save_memory_to_file(memory_data: dict[str, Any], agent_name: str | None = None, *, user_id: str | None = None) -> bool:
    """Backward-compatible wrapper around the configured memory storage save path."""
    return get_memory_storage().save(memory_data, agent_name, user_id=user_id)


def get_memory_data(agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
    """Get the current memory data via storage provider."""
    return get_memory_storage().load(agent_name, user_id=user_id)


def reload_memory_data(agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
    """Reload memory data via storage provider."""
    return get_memory_storage().reload(agent_name, user_id=user_id)


def import_memory_data(memory_data: dict[str, Any], agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
    """Persist imported memory data via storage provider.

    Args:
        memory_data: Full memory payload to persist.
        agent_name: If provided, imports into per-agent memory.
        user_id: If provided, scopes memory to a specific user.

    Returns:
        The saved memory data after storage normalization.

    Raises:
        OSError: If persisting the imported memory fails.
    """
    storage = get_memory_storage()
    if not storage.save(memory_data, agent_name, user_id=user_id):
        raise OSError("Failed to save imported memory data")
    return storage.load(agent_name, user_id=user_id)


def clear_memory_data(agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
    """Clear all stored memory data and persist an empty structure."""
    cleared_memory = create_empty_memory()
    if not _save_memory_to_file(cleared_memory, agent_name, user_id=user_id):
        raise OSError("Failed to save cleared memory data")
    return cleared_memory


def _validate_confidence(confidence: float) -> float:
    """Validate persisted fact confidence so stored JSON stays standards-compliant."""
    if not math.isfinite(confidence) or confidence < 0 or confidence > 1:
        raise ValueError("confidence")
    return confidence


# ── Manual CRUD（UI / 操作员入口，不走 LLM 抽取）─────────────────────────────

def create_memory_fact(
    content: str,
    category: str = "context",
    confidence: float = 0.5,
    agent_name: str | None = None,
    *,
    user_id: str | None = None,
) -> dict[str, Any]:
    """Create a new fact and persist the updated memory data."""
    normalized_content = content.strip()
    if not normalized_content:
        raise ValueError("content")

    normalized_category = category.strip() or "context"
    validated_confidence = _validate_confidence(confidence)
    now = utc_now_iso_z()
    memory_data = get_memory_data(agent_name, user_id=user_id)
    updated_memory = dict(memory_data)
    facts = list(memory_data.get("facts", []))
    facts.append(
        {
            "id": f"fact_{uuid.uuid4().hex[:8]}",
            "content": normalized_content,
            "category": normalized_category,
            "confidence": validated_confidence,
            "createdAt": now,
            "source": "manual",
        }
    )
    updated_memory["facts"] = facts

    if not _save_memory_to_file(updated_memory, agent_name, user_id=user_id):
        raise OSError("Failed to save memory data after creating fact")

    return updated_memory


def delete_memory_fact(fact_id: str, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
    """Delete a fact by its id and persist the updated memory data."""
    memory_data = get_memory_data(agent_name, user_id=user_id)
    facts = memory_data.get("facts", [])
    updated_facts = [fact for fact in facts if fact.get("id") != fact_id]
    if len(updated_facts) == len(facts):
        raise KeyError(fact_id)

    updated_memory = dict(memory_data)
    updated_memory["facts"] = updated_facts

    if not _save_memory_to_file(updated_memory, agent_name, user_id=user_id):
        raise OSError(f"Failed to save memory data after deleting fact '{fact_id}'")

    return updated_memory


def update_memory_fact(
    fact_id: str,
    content: str | None = None,
    category: str | None = None,
    confidence: float | None = None,
    agent_name: str | None = None,
    *,
    user_id: str | None = None,
) -> dict[str, Any]:
    """Update an existing fact and persist the updated memory data."""
    memory_data = get_memory_data(agent_name, user_id=user_id)
    updated_memory = dict(memory_data)
    updated_facts: list[dict[str, Any]] = []
    found = False

    for fact in memory_data.get("facts", []):
        if fact.get("id") == fact_id:
            found = True
            updated_fact = dict(fact)
            if content is not None:
                normalized_content = content.strip()
                if not normalized_content:
                    raise ValueError("content")
                updated_fact["content"] = normalized_content
            if category is not None:
                updated_fact["category"] = category.strip() or "context"
            if confidence is not None:
                updated_fact["confidence"] = _validate_confidence(confidence)
            updated_facts.append(updated_fact)
        else:
            updated_facts.append(fact)

    if not found:
        raise KeyError(fact_id)

    updated_memory["facts"] = updated_facts

    if not _save_memory_to_file(updated_memory, agent_name, user_id=user_id):
        raise OSError(f"Failed to save memory data after updating fact '{fact_id}'")

    return updated_memory


def _extract_text(content: Any) -> str:
    """Extract plain text from LLM response content (str or list of content blocks).

    Modern LLMs may return structured content as a list of blocks instead of a
    plain string, e.g. [{"type": "text", "text": "..."}]. Using str() on such
    content produces Python repr instead of the actual text, breaking JSON
    parsing downstream.

    String chunks are concatenated without separators to avoid corrupting
    chunked JSON/text payloads. Dict-based text blocks are treated as full text
    blocks and joined with newlines for readability.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        pieces: list[str] = []
        pending_str_parts: list[str] = []

        def flush_pending_str_parts() -> None:
            if pending_str_parts:
                pieces.append("".join(pending_str_parts))
                pending_str_parts.clear()

        for block in content:
            if isinstance(block, str):
                pending_str_parts.append(block)
            elif isinstance(block, dict):
                flush_pending_str_parts()
                text_val = block.get("text")
                if isinstance(text_val, str):
                    pieces.append(text_val)

        flush_pending_str_parts()
        return "\n".join(pieces)
    return str(content)


_REQUIRED_MEMORY_UPDATE_TOP_LEVEL_KEYS = frozenset({"user", "history", "newFacts", "factsToRemove"})


def _normalize_memory_update_fact(fact: Any) -> dict[str, Any] | None:
    """Normalize a single fact entry from a model-produced memory update."""
    if not isinstance(fact, dict):
        return None

    raw_content = fact.get("content")
    if not isinstance(raw_content, str):
        return None
    content = raw_content.strip()
    if not content:
        return None

    raw_category = fact.get("category")
    category = raw_category.strip() if isinstance(raw_category, str) and raw_category.strip() else "context"

    raw_confidence = fact.get("confidence", 0.5)
    if isinstance(raw_confidence, bool):
        return None
    if isinstance(raw_confidence, str):
        raw_confidence = raw_confidence.strip()
        if not raw_confidence:
            return None
        try:
            raw_confidence = float(raw_confidence)
        except ValueError:
            return None
    elif isinstance(raw_confidence, (int, float)):
        raw_confidence = float(raw_confidence)
    else:
        return None

    if not math.isfinite(raw_confidence):
        return None

    normalized_fact = {
        "content": content,
        "category": category,
        "confidence": raw_confidence,
    }
    source_error = fact.get("sourceError")
    if isinstance(source_error, str):
        normalized_source_error = source_error.strip()
        if normalized_source_error:
            normalized_fact["sourceError"] = normalized_source_error

    return normalized_fact


def _normalize_memory_update_data(update_data: dict[str, Any]) -> dict[str, Any]:
    """Coerce parsed memory update data into the shape consumed by _apply_updates."""
    user = update_data.get("user")
    history = update_data.get("history")
    new_facts = update_data.get("newFacts")
    facts_to_remove = update_data.get("factsToRemove")
    normalized_facts_to_remove = [fact_id for fact_id in facts_to_remove if isinstance(fact_id, str)] if isinstance(facts_to_remove, list) else []
    normalized_new_facts = []
    dropped_new_fact = not isinstance(new_facts, list)
    if isinstance(new_facts, list):
        for fact in new_facts:
            normalized_fact = _normalize_memory_update_fact(fact)
            if normalized_fact is not None:
                normalized_new_facts.append(normalized_fact)
            else:
                dropped_new_fact = True

    if normalized_facts_to_remove and dropped_new_fact:
        raise json.JSONDecodeError(
            "Unsafe partial memory update: factsToRemove with malformed newFacts",
            json.dumps(update_data, ensure_ascii=False),
            0,
        )

    # ── Normalize staleness review removals ──
    stale_removals_raw = update_data.get("staleFactsToRemove")
    normalized_stale_removals: list[dict[str, str]] = []
    if isinstance(stale_removals_raw, list):
        for entry in stale_removals_raw:
            if not isinstance(entry, dict):
                continue
            fact_id = entry.get("id")
            if not isinstance(fact_id, str) or not fact_id:
                continue
            reason = entry.get("reason", "")
            normalized_stale_removals.append(
                {
                    "id": fact_id,
                    "reason": reason if isinstance(reason, str) else "",
                }
            )

    return {
        "user": user if isinstance(user, dict) else {},
        "history": history if isinstance(history, dict) else {},
        "newFacts": normalized_new_facts,
        "factsToRemove": normalized_facts_to_remove,
        "staleFactsToRemove": normalized_stale_removals,
    }


def _parse_memory_update_response(response_content: Any) -> dict[str, Any]:
    """Parse the first valid memory-update JSON object from an LLM response.

    Some providers may wrap JSON in thinking traces, prose, or markdown fences
    even when prompted to return JSON only. This parser accepts safely
    extractable JSON objects but does not repair truncated or malformed JSON.
    """
    response_text = _extract_text(response_content).strip()
    decoder = json.JSONDecoder()

    for match in re.finditer(r"\{", response_text):
        try:
            parsed, _end = decoder.raw_decode(response_text[match.start() :])
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict) and _REQUIRED_MEMORY_UPDATE_TOP_LEVEL_KEYS.issubset(parsed):
            return _normalize_memory_update_data(parsed)

    raise json.JSONDecodeError("No valid memory update JSON object found", response_text, 0)


# Matches sentences that describe a file-upload *event* rather than general
# file-related work.  Deliberately narrow to avoid removing legitimate facts
# such as "User works with CSV files" or "prefers PDF export".
_UPLOAD_SENTENCE_RE = re.compile(
    r"[^.!?]*\b(?:"
    r"upload(?:ed|ing)?(?:\s+\w+){0,3}\s+(?:file|files?|document|documents?|attachment|attachments?)"
    r"|file\s+upload"
    r"|/mnt/user-data/uploads/"
    r"|<uploaded_files>"
    r")[^.!?]*[.!?]?\s*",
    re.IGNORECASE,
)


def _strip_upload_mentions_from_memory(memory_data: dict[str, Any]) -> dict[str, Any]:
    """Remove sentences about file uploads from all memory summaries and facts.

    Uploaded files are session-scoped; persisting upload events in long-term
    memory causes the agent to search for non-existent files in future sessions.
    """
    # Scrub summaries in user/history sections
    for section in ("user", "history"):
        section_data = memory_data.get(section, {})
        for _key, val in section_data.items():
            if isinstance(val, dict) and "summary" in val:
                cleaned = _UPLOAD_SENTENCE_RE.sub("", val["summary"]).strip()
                cleaned = re.sub(r"  +", " ", cleaned)
                val["summary"] = cleaned

    # Also remove any facts that describe upload events
    facts = memory_data.get("facts", [])
    if facts:
        memory_data["facts"] = [f for f in facts if not _UPLOAD_SENTENCE_RE.search(f.get("content", ""))]

    return memory_data


def _fact_content_key(content: Any) -> str | None:
    if not isinstance(content, str):
        return None
    stripped = content.strip()
    if not stripped:
        return None
    return stripped.casefold()


# ── Staleness review helpers ──────────────────────────────────────────────


def _parse_fact_datetime(raw: str) -> datetime | None:
    """Parse an ISO-8601 datetime string from a fact's createdAt field.

    Returns ``None`` on any parse failure so callers can safely skip malformed facts.
    """
    if not raw:
        return None
    try:
        result = datetime.fromisoformat(raw)
        # Naive datetimes (no tzinfo) would cause TypeError when compared
        # with the timezone-aware cutoff.  Assume UTC for safety.
        if result.tzinfo is None:
            result = result.replace(tzinfo=UTC)
        return result
    except (ValueError, TypeError):
        return None


def _select_stale_candidates(
    current_memory: dict[str, Any],
    config: Any,
) -> list[dict[str, Any]]:
    """Return facts that are older than ``staleness_age_days`` and not protected.

    Protected categories (default: ``correction``) are excluded because they
    represent explicit user feedback that should not be auto-pruned by age.
    """
    cutoff = datetime.now(UTC) - timedelta(days=config.staleness_age_days)
    protected = frozenset(config.staleness_protected_categories)
    candidates: list[dict[str, Any]] = []
    for fact in current_memory.get("facts", []):
        if not isinstance(fact, dict):
            continue
        category = fact.get("category", "")
        if isinstance(category, str) and category in protected:
            continue
        created_at = _parse_fact_datetime(fact.get("createdAt", ""))
        if created_at is not None and created_at < cutoff:
            candidates.append(fact)
    return candidates


def _build_staleness_section(
    stale_candidates: list[dict[str, Any]],
    age_days: int,
) -> str:
    """Format the staleness review prompt section from candidate facts."""
    if not stale_candidates:
        return ""
    lines: list[str] = []
    for fact in stale_candidates:
        fid = fact.get("id", "?")
        cat = str(fact.get("category", "context")).strip() or "context"
        conf = fact.get("confidence", 0.0)
        created_raw = fact.get("createdAt", "")
        created_short = created_raw[:10] if isinstance(created_raw, str) and len(created_raw) >= 10 else created_raw
        content = str(fact.get("content", ""))
        lines.append(f'- [{fid} | {cat} | {conf:.2f} | {created_short}] "{content}"')
    return STALENESS_REVIEW_PROMPT.format(
        stale_facts="\n".join(lines),
        age_days=age_days,
    )


class MemoryUpdater:
    """Updates memory using LLM based on conversation context."""

    def __init__(self, model_name: str | None = None):
        """Initialize the memory updater.

        Args:
            model_name: Optional model name to use. If None, uses config or default.
        """
        self._model_name = model_name

    def _get_model(self):
        """Get the model for memory updates."""
        return create_chat_model(name=self._resolve_model_name(), thinking_enabled=False)

    def _resolve_model_name(self) -> str | None:
        """Return the configured model name for memory updates."""
        config = get_memory_config()
        return self._model_name or config.model_name

    def _build_correction_hint(
        self,
        correction_detected: bool,
        reinforcement_detected: bool,
    ) -> str:
        """Build optional prompt hints for correction and reinforcement signals."""
        correction_hint = ""
        if correction_detected:
            correction_hint = (
                "IMPORTANT: Explicit correction signals were detected in this conversation. "
                "Pay special attention to what the agent got wrong, what the user corrected, "
                "and record the correct approach as a fact with category "
                '"correction" and confidence >= 0.95 when appropriate.'
            )
        if reinforcement_detected:
            reinforcement_hint = (
                "IMPORTANT: Positive reinforcement signals were detected in this conversation. "
                "The user explicitly confirmed the agent's approach was correct or helpful. "
                "Record the confirmed approach, style, or preference as a fact with category "
                '"preference" or "behavior" and confidence >= 0.9 when appropriate.'
            )
            correction_hint = (correction_hint + "\n" + reinforcement_hint).strip() if correction_hint else reinforcement_hint

        return correction_hint

    def _prepare_update_prompt(
        self,
        messages: list[Any],
        agent_name: str | None,
        correction_detected: bool,
        reinforcement_detected: bool,
        user_id: str | None = None,
    ) -> tuple[dict[str, Any], str] | None:
        """Load memory and build the update prompt for a conversation."""
        config = get_memory_config()
        if not config.enabled or not messages:
            return None

        current_memory = get_memory_data(agent_name, user_id=user_id)
        conversation_text = format_conversation_for_update(messages)
        if not conversation_text.strip():
            return None

        correction_hint = self._build_correction_hint(
            correction_detected=correction_detected,
            reinforcement_detected=reinforcement_detected,
        )

        # ── Build staleness review section ──
        staleness_section = ""
        if config.staleness_review_enabled:
            stale_candidates = _select_stale_candidates(current_memory, config)
            if len(stale_candidates) >= config.staleness_min_candidates:
                staleness_section = _build_staleness_section(
                    stale_candidates,
                    config.staleness_age_days,
                )

        prompt = MEMORY_UPDATE_PROMPT.format(
            current_memory=json.dumps(current_memory, indent=2, ensure_ascii=False),
            conversation=conversation_text,
            correction_hint=correction_hint,
            staleness_review_section=staleness_section,
        )
        return current_memory, prompt

    def _finalize_update(
        self,
        current_memory: dict[str, Any],
        response_content: Any,
        thread_id: str | None,
        agent_name: str | None,
        user_id: str | None = None,
    ) -> bool:
        """Parse the model response, apply updates, and persist memory."""
        update_data = _parse_memory_update_response(response_content)
        # Deep-copy before in-place mutation so a subsequent save() failure
        # cannot corrupt the still-cached original object reference.
        updated_memory = self._apply_updates(copy.deepcopy(current_memory), update_data, thread_id)
        updated_memory = _strip_upload_mentions_from_memory(updated_memory)
        return get_memory_storage().save(updated_memory, agent_name, user_id=user_id)

    async def aupdate_memory(
        self,
        messages: list[Any],
        thread_id: str | None = None,
        agent_name: str | None = None,
        correction_detected: bool = False,
        reinforcement_detected: bool = False,
        user_id: str | None = None,
        helix_trace_id: str | None = None,
    ) -> bool:
        """Update memory asynchronously by delegating to the sync path.

        Uses ``asyncio.to_thread`` to run the *sync* ``model.invoke()`` path
        in a worker thread so no second event loop is created and the
        langchain async httpx client pool (shared with the lead agent) is
        never touched.  This eliminates the cross-loop connection-reuse bug
        described in issue #2615.
        """
        return await asyncio.to_thread(
            self._do_update_memory_sync,
            messages=messages,
            thread_id=thread_id,
            agent_name=agent_name,
            correction_detected=correction_detected,
            reinforcement_detected=reinforcement_detected,
            user_id=user_id,
            helix_trace_id=helix_trace_id,
        )

    def _do_update_memory_sync(
        self,
        messages: list[Any],
        thread_id: str | None = None,
        agent_name: str | None = None,
        correction_detected: bool = False,
        reinforcement_detected: bool = False,
        user_id: str | None = None,
        helix_trace_id: str | None = None,
    ) -> bool:
        """Pure-sync memory update using ``model.invoke()``.

        Uses the *sync* LLM call path so no event loop is created.  This
        guarantees that the langchain provider's globally cached async
        httpx ``AsyncClient`` / connection pool (the one shared with the
        lead agent) is never touched - no cross-loop connection reuse is
        possible.
        """
        # Callers may run us in a ``threading.Timer`` thread or an
        # ``_SYNC_MEMORY_UPDATER_EXECUTOR`` worker - neither propagates the
        # request-trace ContextVar. Rebind it here from the explicitly plumbed
        # ``helix_trace_id`` so ``TraceContextFilter`` attaches the correct
        # trace id to every log record emitted below (including model-invoke
        # tracing-callback logs). ``nullcontext`` when unknown avoids
        # fabricating a bogus id via ``request_trace_context(None)``.
        trace_ctx = request_trace_context(helix_trace_id) if helix_trace_id else nullcontext()
        with trace_ctx:
            try:
                prepared = self._prepare_update_prompt(
                    messages=messages,
                    agent_name=agent_name,
                    correction_detected=correction_detected,
                    reinforcement_detected=reinforcement_detected,
                    user_id=user_id,
                )
                if prepared is None:
                    return False

                current_memory, prompt = prepared
                model_name = self._resolve_model_name()
                model = self._get_model()
                invoke_config: dict[str, Any] = {"run_name": "memory_agent"}
                inject_langfuse_metadata(
                    invoke_config,
                    thread_id=thread_id,
                    user_id=user_id,
                    assistant_id="memory_agent",
                    model_name=model_name,
                    environment=os.environ.get("HELIX_ENV") or os.environ.get("ENVIRONMENT"),
                    helix_trace_id=helix_trace_id,
                )
                response = model.invoke(prompt, config=invoke_config)
                return self._finalize_update(
                    current_memory=current_memory,
                    response_content=response.content,
                    thread_id=thread_id,
                    agent_name=agent_name,
                    user_id=user_id,
                )
            except json.JSONDecodeError as e:
                logger.warning("Failed to parse LLM response for memory update: %s", e)
                return False
            except Exception as e:
                logger.exception("Memory update failed: %s", e)
                return False

    def update_memory(
        self,
        messages: list[Any],
        thread_id: str | None = None,
        agent_name: str | None = None,
        correction_detected: bool = False,
        reinforcement_detected: bool = False,
        user_id: str | None = None,
        helix_trace_id: str | None = None,
    ) -> bool:
        """Synchronously update memory using the sync LLM path.

        Uses ``model.invoke()`` (sync HTTP) which operates on a completely
        separate connection pool from the async ``AsyncClient`` shared by
        the lead agent.  This eliminates the cross-loop connection-reuse
        bug described in issue #2615.

        When called from within a running event loop (e.g. from a LangGraph
        node), the blocking sync call is offloaded to a thread pool so the
        caller's loop is not blocked.

        Args:
            messages: List of conversation messages.
            thread_id: Optional thread ID for tracking source.
            agent_name: If provided, updates per-agent memory. If None, updates global memory.
            correction_detected: Whether recent turns include an explicit correction signal.
            reinforcement_detected: Whether recent turns include a positive reinforcement signal.
            user_id: If provided, scopes memory to a specific user.

        Returns:
            True if update was successful, False otherwise.
        """
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        if loop is not None and loop.is_running():
            try:
                future = _SYNC_MEMORY_UPDATER_EXECUTOR.submit(
                    self._do_update_memory_sync,
                    messages=messages,
                    thread_id=thread_id,
                    agent_name=agent_name,
                    correction_detected=correction_detected,
                    reinforcement_detected=reinforcement_detected,
                    user_id=user_id,
                    helix_trace_id=helix_trace_id,
                )
                return future.result()
            except Exception:
                logger.exception("Failed to offload memory update to executor")
                return False

        return self._do_update_memory_sync(
            messages=messages,
            thread_id=thread_id,
            agent_name=agent_name,
            correction_detected=correction_detected,
            reinforcement_detected=reinforcement_detected,
            user_id=user_id,
            helix_trace_id=helix_trace_id,
        )

    def _apply_updates(
        self,
        current_memory: dict[str, Any],
        update_data: dict[str, Any],
        thread_id: str | None = None,
    ) -> dict[str, Any]:
        """Apply LLM-generated updates to memory.

        Args:
            current_memory: Current memory data.
            update_data: Updates from LLM.
            thread_id: Optional thread ID for tracking.

        Returns:
            Updated memory data.
        """
        config = get_memory_config()
        now = utc_now_iso_z()

        # Update user sections
        user_updates = update_data.get("user", {})
        for section in ["workContext", "personalContext", "topOfMind"]:
            section_data = user_updates.get(section, {})
            if section_data.get("shouldUpdate") and section_data.get("summary"):
                current_memory["user"][section] = {
                    "summary": section_data["summary"],
                    "updatedAt": now,
                }

        # Update history sections
        history_updates = update_data.get("history", {})
        for section in ["recentMonths", "earlierContext", "longTermBackground"]:
            section_data = history_updates.get(section, {})
            if section_data.get("shouldUpdate") and section_data.get("summary"):
                current_memory["history"][section] = {
                    "summary": section_data["summary"],
                    "updatedAt": now,
                }

        # Remove facts (contradiction-based)
        facts_to_remove = set(update_data.get("factsToRemove", []))
        if facts_to_remove:
            current_memory["facts"] = [f for f in current_memory.get("facts", []) if f.get("id") not in facts_to_remove]

        # ── Staleness review removals ──
        stale_removals = update_data.get("staleFactsToRemove", [])
        if isinstance(stale_removals, list) and stale_removals:
            stale_ids_to_remove = {entry["id"] for entry in stale_removals if isinstance(entry, dict) and "id" in entry}

            # Deterministic guardrail: intersect with actual staleness
            # candidates so an LLM slip that emits a protected-category or
            # non-aged fact id is silently rejected.  Runs unconditionally
            # so the apply-layer protection is independent of model behavior
            # AND of the staleness_review_enabled flag.
            candidate_ids = {f["id"] for f in _select_stale_candidates(current_memory, config)}
            stale_ids_to_remove &= candidate_ids

            if not stale_ids_to_remove:
                # After intersection with candidate set, nothing to remove.
                stale_removals = []
            else:
                # Safety cap: limit max staleness removals per cycle.
                # When the LLM returns more than the cap, keep only the
                # lowest-confidence entries up to the limit so the most
                # questionable facts are removed first.
                max_stale = config.staleness_max_removals_per_cycle
                if len(stale_ids_to_remove) > max_stale:
                    stale_facts = [f for f in current_memory.get("facts", []) if f.get("id") in stale_ids_to_remove]
                    stale_facts.sort(key=lambda f: f.get("confidence", 0))
                    stale_ids_to_remove = {f["id"] for f in stale_facts[:max_stale]}

                current_memory["facts"] = [f for f in current_memory.get("facts", []) if f.get("id") not in stale_ids_to_remove]

            # Log removals for observability
            for entry in stale_removals:
                if isinstance(entry, dict) and entry.get("id") in stale_ids_to_remove:
                    logger.info(
                        "Staleness review removed fact %s: %s",
                        entry["id"],
                        entry.get("reason", "no reason provided"),
                    )

        # Add new facts
        existing_fact_keys = {fact_key for fact_key in (_fact_content_key(fact.get("content")) for fact in current_memory.get("facts", [])) if fact_key is not None}
        new_facts = update_data.get("newFacts", [])
        for fact in new_facts:
            confidence = fact.get("confidence", 0.5)
            if confidence >= config.fact_confidence_threshold:
                raw_content = fact.get("content", "")
                if not isinstance(raw_content, str):
                    continue
                normalized_content = raw_content.strip()
                fact_key = _fact_content_key(normalized_content)
                if fact_key is None:
                    # Empty / whitespace-only content: skip it the same way the
                    # non-string guard above does, instead of appending a blank
                    # fact that violates the non-empty-content invariant.
                    continue
                if fact_key in existing_fact_keys:
                    continue

                fact_entry = {
                    "id": f"fact_{uuid.uuid4().hex[:8]}",
                    "content": normalized_content,
                    "category": fact.get("category", "context"),
                    "confidence": confidence,
                    "createdAt": now,
                    "source": thread_id or "unknown",
                }
                source_error = fact.get("sourceError")
                if isinstance(source_error, str):
                    normalized_source_error = source_error.strip()
                    if normalized_source_error:
                        fact_entry["sourceError"] = normalized_source_error
                current_memory["facts"].append(fact_entry)
                if fact_key is not None:
                    existing_fact_keys.add(fact_key)

        # Enforce max facts limit
        if len(current_memory["facts"]) > config.max_facts:
            # Sort by confidence and keep top ones
            current_memory["facts"] = sorted(
                current_memory["facts"],
                key=lambda f: f.get("confidence", 0),
                reverse=True,
            )[: config.max_facts]

        return current_memory


def update_memory_from_conversation(
    messages: list[Any],
    thread_id: str | None = None,
    agent_name: str | None = None,
    correction_detected: bool = False,
    reinforcement_detected: bool = False,
    user_id: str | None = None,
    helix_trace_id: str | None = None,
) -> bool:
    """Convenience function to update memory from a conversation.

    Args:
        messages: List of conversation messages.
        thread_id: Optional thread ID.
        agent_name: If provided, updates per-agent memory. If None, updates global memory.
        correction_detected: Whether recent turns include an explicit correction signal.
        reinforcement_detected: Whether recent turns include a positive reinforcement signal.
        user_id: If provided, scopes memory to a specific user.

    Returns:
        True if successful, False otherwise.
    """
    updater = MemoryUpdater()
    return updater.update_memory(messages, thread_id, agent_name, correction_detected, reinforcement_detected, user_id=user_id, helix_trace_id=helix_trace_id)
```

**要点**：

- **同步 LLM 路径**：`update_memory` 检测到运行中的事件循环时，submit 到 `_SYNC_MEMORY_UPDATER_EXECUTOR`（4 worker，`atexit` 注册关闭），否则 inline。两条路都走 `_do_update_memory_sync` 的 `model.invoke()`（同步 HTTP），不碰 langchain 全局缓存的 async `httpx.AsyncClient`，杜绝 cross-loop 连接复用（issue #2615）。
- **`_apply_updates` 顺序**：先移除矛盾事实（`factsToRemove`）-> 陈旧审查移除（与候选集交集守卫 + 安全上限）-> 加新事实（confidence 阈值 + casefold 去重）-> max_facts 截断（confidence 降序，无 recency tiebreaker）。先删后加，避免"被重新断言的事实删了自己"。
- **陈旧审查守卫**：`stale_ids_to_remove &= candidate_ids`--模型返回删一个非候选 id（保护类目或未超龄）被静默拒。`staleness_max_removals_per_cycle` 上限，超额时留最低 confidence 的（最可疑的先删）。
- **上传提及清洗**：`_strip_upload_mentions_from_memory` 用窄正则剥上传事件句（"user works with CSV files" 这类偏好不动），防 agent 下个会话幻觉老文件还在。
- **手动 CRUD vs LLM 策展**：`create_memory_fact` / `delete_memory_fact` / `update_memory_fact` 走 UI/操作员，`source="manual"`，不做去重/不截 max_facts（手动编辑假定有意）；两条路共享同一原子 save 与缓存失效。

## 4. 消息处理（过滤 + 信号检测）

```python
# core/helix/agents/memory/message_processing.py
"""Shared helpers for turning conversations into memory update inputs."""

from __future__ import annotations

import re
from copy import copy
from typing import Any

from helix.agents.human_input import read_human_input_response

_UPLOAD_BLOCK_RE = re.compile(r"<uploaded_files>[\s\S]*?</uploaded_files>\n*", re.IGNORECASE)
_CORRECTION_PATTERNS = (
    re.compile(r"\bthat(?:'s| is) (?:wrong|incorrect)\b", re.IGNORECASE),
    re.compile(r"\byou misunderstood\b", re.IGNORECASE),
    re.compile(r"\btry again\b", re.IGNORECASE),
    re.compile(r"\bredo\b", re.IGNORECASE),
    re.compile(r"不对"),
    re.compile(r"你理解错了"),
    re.compile(r"你理解有误"),
    re.compile(r"重试"),
    re.compile(r"重新来"),
    re.compile(r"换一种"),
    re.compile(r"改用"),
)
_REINFORCEMENT_PATTERNS = (
    re.compile(r"\byes[,.]?\s+(?:exactly|perfect|that(?:'s| is) (?:right|correct|it))\b", re.IGNORECASE),
    re.compile(r"\bperfect(?:[.!?]|$)", re.IGNORECASE),
    re.compile(r"\bexactly\s+(?:right|correct)\b", re.IGNORECASE),
    re.compile(r"\bthat(?:'s| is)\s+(?:exactly\s+)?(?:right|correct|what i (?:wanted|needed|meant))\b", re.IGNORECASE),
    re.compile(r"\bkeep\s+(?:doing\s+)?that\b", re.IGNORECASE),
    re.compile(r"\bjust\s+(?:like\s+)?(?:that|this)\b", re.IGNORECASE),
    re.compile(r"\bthis is (?:great|helpful)\b(?:[.!?]|$)", re.IGNORECASE),
    re.compile(r"\bthis is what i wanted\b(?:[.!?]|$)", re.IGNORECASE),
    re.compile(r"对[，,]?\s*就是这样(?:[。！？!?.]|$)"),
    re.compile(r"完全正确(?:[。！？!?.]|$)"),
    re.compile(r"(?:对[，,]?\s*)?就是这个意思(?:[。！？!?.]|$)"),
    re.compile(r"正是我想要的(?:[。！？!?.]|$)"),
    re.compile(r"继续保持(?:[。！？!?.]|$)"),
)


def extract_message_text(message: Any) -> str:
    """Extract plain text from message content for filtering and signal detection."""
    content = getattr(message, "content", "")
    if isinstance(content, list):
        text_parts: list[str] = []
        for part in content:
            if isinstance(part, str):
                text_parts.append(part)
            elif isinstance(part, dict):
                text_val = part.get("text")
                if isinstance(text_val, str):
                    text_parts.append(text_val)
        return " ".join(text_parts)
    return str(content)


def filter_messages_for_memory(messages: list[Any]) -> list[Any]:
    """Keep only user inputs and final assistant responses for memory updates."""
    filtered = []
    skip_next_ai = False
    for msg in messages:
        msg_type = getattr(msg, "type", None)

        if msg_type == "human":
            # Middleware-injected hidden messages (e.g. TodoMiddleware.todo_reminder,
            # ViewImageMiddleware, p0 DynamicContextMiddleware.__memory) carry
            # hide_from_ui and must never reach the memory-updating LLM - otherwise
            # framework-internal text pollutes long-term memory (and the p0 __memory
            # payload could trigger a self-amplification loop).
            additional_kwargs = getattr(msg, "additional_kwargs", {}) or {}
            if additional_kwargs.get("hide_from_ui") and read_human_input_response(additional_kwargs) is None:
                continue
            content_str = extract_message_text(msg)
            if "<uploaded_files>" in content_str:
                stripped = _UPLOAD_BLOCK_RE.sub("", content_str).strip()
                if not stripped:
                    skip_next_ai = True
                    continue
                clean_msg = copy(msg)
                clean_msg.content = stripped
                filtered.append(clean_msg)
                skip_next_ai = False
            else:
                filtered.append(msg)
                skip_next_ai = False
        elif msg_type == "ai":
            tool_calls = getattr(msg, "tool_calls", None)
            if not tool_calls:
                if skip_next_ai:
                    skip_next_ai = False
                    continue
                filtered.append(msg)

    return filtered


def detect_correction(messages: list[Any]) -> bool:
    """Detect explicit user corrections in recent conversation turns."""
    recent_user_msgs = [msg for msg in messages[-6:] if getattr(msg, "type", None) == "human"]

    for msg in recent_user_msgs:
        content = extract_message_text(msg).strip()
        if content and any(pattern.search(content) for pattern in _CORRECTION_PATTERNS):
            return True

    return False


def detect_reinforcement(messages: list[Any]) -> bool:
    """Detect explicit positive reinforcement signals in recent conversation turns."""
    recent_user_msgs = [msg for msg in messages[-6:] if getattr(msg, "type", None) == "human"]

    for msg in recent_user_msgs:
        content = extract_message_text(msg).strip()
        if content and any(pattern.search(content) for pattern in _REINFORCEMENT_PATTERNS):
            return True

    return False
```

**要点**：

- `filter_messages_for_memory` 剥三样：工具调用（机制不是信号）、`<uploaded_files>` 块（会话级临时数据，不进长期记忆；剥完为空则跳过紧跟的 AI 回复--纯上传消息无记忆价值）、`hide_from_ui` 的框架注入消息（防 `__memory` 载荷自放大循环）。`read_human_input_response(additional_kwargs) is None` 兜底：真正的 Human Input Card 回复虽 `hide_from_ui` 但需保留。
- `detect_correction` / `detect_reinforcement` 只看最近 6 条里的 human 消息；中英双语模式。`MemoryMiddleware` 里 `reinforcement = not correction and detect_reinforcement(...)`--纠正优先（更强信号）。

## 5. 摘要前 flush hook

```python
# core/helix/agents/memory/summarization_hook.py
"""Hooks fired before summarization removes messages from state."""

from __future__ import annotations

from helix.agents.memory.message_processing import detect_correction, detect_reinforcement, filter_messages_for_memory
from helix.agents.memory.queue import get_memory_queue
from helix.agents.middlewares.summarization_middleware import SummarizationEvent
from helix.config.memory_config import get_memory_config
from helix.runtime.user_context import resolve_runtime_user_id


def memory_flush_hook(event: SummarizationEvent) -> None:
    """Flush messages about to be summarized into the memory queue."""
    if not get_memory_config().enabled or not event.thread_id:
        return

    filtered_messages = filter_messages_for_memory(list(event.messages_to_summarize))
    user_messages = [message for message in filtered_messages if getattr(message, "type", None) == "human"]
    assistant_messages = [message for message in filtered_messages if getattr(message, "type", None) == "ai"]
    if not user_messages or not assistant_messages:
        return

    correction_detected = detect_correction(filtered_messages)
    reinforcement_detected = not correction_detected and detect_reinforcement(filtered_messages)
    user_id = resolve_runtime_user_id(event.runtime)
    queue = get_memory_queue()
    queue.add_nowait(
        thread_id=event.thread_id,
        messages=filtered_messages,
        agent_name=event.agent_name,
        user_id=user_id,
        correction_detected=correction_detected,
        reinforcement_detected=reinforcement_detected,
    )
```

**要点**：摘要中间件压缩历史前，把即将被删的消息 `add_nowait`（`delay=0` 立即处理）冲进记忆队列。否则被摘要压掉的消息永远没机会进长期记忆。`resolve_runtime_user_id(event.runtime)` 在 hook 线程解析 user_id（优先 `runtime.context['user_id']` -> contextvar -> default）。

## 6. 抽取 / 更新 prompt 模板

```python
# core/helix/agents/memory/prompt.py（prompt 模板部分）
# Prompt template for updating memory based on conversation
MEMORY_UPDATE_PROMPT = """You are a memory management system. Your task is to analyze a conversation and update the user's memory profile.

Current Memory State:
<current_memory>
{current_memory}
</current_memory>

New Conversation to Process:
<conversation>
{conversation}
</conversation>

Instructions:
1. Analyze the conversation for important information about the user
2. Extract relevant facts, preferences, and context with specific details (numbers, names, technologies)
3. Update the memory sections as needed following the detailed length guidelines below

Before extracting facts, perform a structured reflection on the conversation:
1. Error/Retry Detection: Did the agent encounter errors, require retries, or produce incorrect results?
   If yes, record the root cause and correct approach as a high-confidence fact with category "correction".
2. User Correction Detection: Did the user correct the agent's direction, understanding, or output?
   If yes, record the correct interpretation or approach as a high-confidence fact with category "correction".
   Include what went wrong in "sourceError" only when category is "correction" and the mistake is explicit in the conversation.
3. Project Constraint Discovery: Were any project-specific constraints discovered during the conversation?
   If yes, record them as facts with the most appropriate category and confidence.

{correction_hint}

Memory Section Guidelines:

**User Context** (Current state - concise summaries):
- workContext: Professional role, company, key projects, main technologies (2-3 sentences)
  Example: Core contributor, project names with metrics (16k+ stars), technical stack
- personalContext: Languages, communication preferences, key interests (1-2 sentences)
  Example: Bilingual capabilities, specific interest areas, expertise domains
- topOfMind: Multiple ongoing focus areas and priorities (3-5 sentences, detailed paragraph)
  Example: Primary project work, parallel technical investigations, ongoing learning/tracking
  Include: Active implementation work, troubleshooting issues, market/research interests
  Note: This captures SEVERAL concurrent focus areas, not just one task

**History** (Temporal context - rich paragraphs):
- recentMonths: Detailed summary of recent activities (4-6 sentences or 1-2 paragraphs)
  Timeline: Last 1-3 months of interactions
  Include: Technologies explored, projects worked on, problems solved, interests demonstrated
- earlierContext: Important historical patterns (3-5 sentences or 1 paragraph)
  Timeline: 3-12 months ago
  Include: Past projects, learning journeys, established patterns
- longTermBackground: Persistent background and foundational context (2-4 sentences)
  Timeline: Overall/foundational information
  Include: Core expertise, longstanding interests, fundamental working style

**Facts Extraction**:
- Extract specific, quantifiable details (e.g., "16k+ GitHub stars", "200+ datasets")
- Include proper nouns (company names, project names, technology names)
- Preserve technical terminology and version numbers
- Categories:
  * preference: Tools, styles, approaches user prefers/dislikes
  * knowledge: Specific expertise, technologies mastered, domain knowledge
  * context: Background facts (job title, projects, locations, languages)
  * behavior: Working patterns, communication habits, problem-solving approaches
  * goal: Stated objectives, learning targets, project ambitions
  * correction: Explicit agent mistakes or user corrections, including the correct approach
- Confidence levels:
  * 0.9-1.0: Explicitly stated facts ("I work on X", "My role is Y")
  * 0.7-0.8: Strongly implied from actions/discussions
  * 0.5-0.6: Inferred patterns (use sparingly, only for clear patterns)

**What Goes Where**:
- workContext: Current job, active projects, primary tech stack
- personalContext: Languages, personality, interests outside direct work tasks
- topOfMind: Multiple ongoing priorities and focus areas user cares about recently (gets updated most frequently)
  Should capture 3-5 concurrent themes: main work, side explorations, learning/tracking interests
- recentMonths: Detailed account of recent technical explorations and work
- earlierContext: Patterns from slightly older interactions still relevant
- longTermBackground: Unchanging foundational facts about the user

**Multilingual Content**:
- Preserve original language for proper nouns and company names
- Keep technical terms in their original form (DeepSeek, LangGraph, etc.)
- Note language capabilities in personalContext

Output Format (JSON):
{{
  "user": {{
    "workContext": {{ "summary": "...", "shouldUpdate": true/false }},
    "personalContext": {{ "summary": "...", "shouldUpdate": true/false }},
    "topOfMind": {{ "summary": "...", "shouldUpdate": true/false }}
  }},
  "history": {{
    "recentMonths": {{ "summary": "...", "shouldUpdate": true/false }},
    "earlierContext": {{ "summary": "...", "shouldUpdate": true/false }},
    "longTermBackground": {{ "summary": "...", "shouldUpdate": true/false }}
  }},
  "newFacts": [
    {{ "content": "...", "category": "preference|knowledge|context|behavior|goal|correction", "confidence": 0.0-1.0 }}
  ],
  "factsToRemove": ["fact_id_1", "fact_id_2"],
  "staleFactsToRemove": [{{ "id": "fact_id", "reason": "brief explanation" }}]
}}

Important Rules:
- Only set shouldUpdate=true if there's meaningful new information
- Follow length guidelines: workContext/personalContext are concise (1-3 sentences), topOfMind and history sections are detailed (paragraphs)
- Include specific metrics, version numbers, and proper nouns in facts
- Only add facts that are clearly stated (0.9+) or strongly implied (0.7+)
- Use category "correction" for explicit agent mistakes or user corrections; assign confidence >= 0.95 when the correction is explicit
- Include "sourceError" only for explicit correction facts when the prior mistake or wrong approach is clearly stated; omit it otherwise
- Remove facts that are contradicted by new information
- When updating topOfMind, integrate new focus areas while removing completed/abandoned ones
  Keep 3-5 concurrent focus themes that are still active and relevant
- For history sections, integrate new information chronologically into appropriate time period
- Preserve technical accuracy - keep exact names of technologies, companies, projects
- Focus on information useful for future interactions and personalization
- IMPORTANT: Do NOT record file upload events in memory. Uploaded files are
  session-specific and ephemeral - they will not be accessible in future sessions.
  Recording upload events causes confusion in subsequent conversations.

{staleness_review_section}

Return ONLY valid JSON, no explanation or markdown."""


# Prompt section injected into MEMORY_UPDATE_PROMPT when staleness review triggers.
# Surfaces aged facts explicitly so the LLM can semantically judge each one,
# rather than relying on passive contradiction from the current conversation.
STALENESS_REVIEW_PROMPT = """## Staleness Review

The following facts were created more than {age_days} days ago and may no longer
accurately reflect the user's current situation. Review each one against the full
conversation context and your understanding of the user.

<stale_facts>
{stale_facts}
</stale_facts>

For each fact, decide KEEP or REMOVE:
- KEEP: Still likely valid - even if not mentioned in this conversation.
  Stable attributes (native language, core expertise, personality traits) often
  remain true indefinitely.
- REMOVE: Outdated, contradicted by recent context, or no longer relevant.
  Examples: tech-stack migrations, job changes, relocated offices, abandoned projects.

Add REMOVE decisions to "staleFactsToRemove" in your output JSON.
Each entry must be {{"id": "fact_id", "reason": "brief explanation"}}.
The reason should cite what signal in the conversation (or absence thereof)
supports the removal.

Be conservative - when in doubt, KEEP. Removing a valid fact is worse than
keeping a slightly stale one, because the next review cycle will re-evaluate it."""


# Prompt template for extracting facts from a single message
FACT_EXTRACTION_PROMPT = """Extract factual information about the user from this message.

Message:
{message}

Extract facts in this JSON format:
{{
  "facts": [
    {{ "content": "...", "category": "preference|knowledge|context|behavior|goal|correction", "confidence": 0.0-1.0 }}
  ]
}}

Categories:
- preference: User preferences (likes/dislikes, styles, tools)
- knowledge: User's expertise or knowledge areas
- context: Background context (location, job, projects)
- behavior: Behavioral patterns
- goal: User's goals or objectives
- correction: Explicit corrections or mistakes to avoid repeating

Rules:
- Only extract clear, specific facts
- Confidence should reflect certainty (explicit statement = 0.9+, implied = 0.6-0.8)
- Skip vague or temporary information

Return ONLY valid JSON."""


def format_conversation_for_update(messages: list[Any]) -> str:
    """Format conversation messages for memory update prompt.

    Args:
        messages: List of conversation messages.

    Returns:
        Formatted conversation string.
    """
    lines = []
    for msg in messages:
        role = getattr(msg, "type", "unknown")
        content = getattr(msg, "content", str(msg))

        # Handle content that might be a list (multimodal)
        if isinstance(content, list):
            text_parts = []
            for p in content:
                if isinstance(p, str):
                    text_parts.append(p)
                elif isinstance(p, dict):
                    text_val = p.get("text")
                    if isinstance(text_val, str):
                        text_parts.append(text_val)
            content = " ".join(text_parts) if text_parts else str(content)

        # Strip uploaded_files tags from human messages to avoid persisting
        # ephemeral file path info into long-term memory.  Skip the turn entirely
        # when nothing remains after stripping (upload-only message).
        if role == "human":
            content = re.sub(r"<uploaded_files>[\s\S]*?</uploaded_files>\n*", "", str(content)).strip()
            if not content:
                continue

        # Truncate very long messages
        if len(str(content)) > 1000:
            content = str(content)[:1000] + "..."

        if role == "human":
            lines.append(f"User: {content}")
        elif role == "ai":
            lines.append(f"Assistant: {content}")

    return "\n\n".join(lines)
```

**要点**：

- `MEMORY_UPDATE_PROMPT` 要求 LLM 返回结构化 JSON：`user` / `history`（带 `shouldUpdate` + `summary`）/ `newFacts` / `factsToRemove` / `staleFactsToRemove`。`{{` `}}` 转义给 `.format()` 用。
- `correction_hint` 是动态注入段：`MemoryMiddleware` 检测到纠正/强化信号时，hint 提示 LLM 以 `correction` 类目 + confidence >= 0.95（或 `preference`/`behavior` + >= 0.9）记录。
- `staleness_review_section` 在候选事实数 >= `staleness_min_candidates` 时注入，让 LLM 对每条超龄事实做 KEEP/REMOVE 语义判断（而非被动等矛盾）。
- `format_conversation_for_update` 把消息格式化为 `User: ...` / `Assistant: ...`，剥 `<uploaded_files>` 块、截断超长消息（1000 字符）。

## 进一步阅读

- 存储全貌 + token 计数 + `format_memory_for_injection` 主函数 + 注入接线：[memory-data-and-injection.md](./memory-data-and-injection.md)
- 完整配置 + 预算数学：[config-and-budget.md](./config-and-budget.md)
- 入队入口（`MemoryMiddleware.after_agent`）：本文件 §1
- 注入中间件（消费记忆的地方）：[[system-prompt-template]]
- trace_id 跨线程重绑定背景：[[observability-tracing]]
