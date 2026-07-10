# 循环检测 + token 预算 + BoundedDict 完整源码 — context-window-management

> 本文件是 `context-window-management` skill 的 references/code，承载 `LoopDetectionMiddleware`、`TokenBudgetMiddleware`、共享的 `BoundedDict` 及配套 config 的**完整真实源码**（已按插件匿名化规则映射到自定结构）。SKILL.md 只放入口片段，深度在此。

两者共享同一套工程模式：

- **延迟注入**：`after_model` 检测命中 warn 时只**队列**告警（不能在此直接注入——tools 节点没跑，会破坏 `AIMessage(tool_calls) → ToolMessage` 配对），`wrap_model_call` 在下次模型调用排空队列追加 `HumanMessage` 到末尾。
- **硬停双清**：strip 结构化 `tool_calls` + pop `additional_kwargs["tool_calls"]` / `function_call` + 改 `finish_reason: tool_calls → stop`，让 run 自然结束产最终答（**不 raise**）。
- **stop_reason 上报**：硬停写 `_stop_reason[run_id]`，executor run 返回后调 `consume_stop_reason` 读，把 `loop_capped` / `token_capped` 加性地上报给 lead。
- **BoundedDict 防 leak**：lead 中间件实例长生命周期，per-`run_id` 状态全用 `BoundedDict(1000)` 防 abandoned run 累积。

---

## 1. `LoopDetectionMiddleware` 完整源码

真实路径 `core/helix/agents/middlewares/loop_detection_middleware.py`。两个检测层（hash-based 集合 + per-tool-type frequency）、两段降级（warn 队列 / hard_stop 双清）、跨钩子状态（`after_model` 队列 → `wrap_model_call` 排空）、per-thread LRU、`_pending_warnings` LRU cap。

```python
# core/helix/agents/middlewares/loop_detection_middleware.py
"""Middleware to detect and break repetitive tool call loops.

P0 safety: prevents the agent from calling the same tool with the same
arguments indefinitely until the recursion limit kills the run.

Detection strategy:
  1. After each model response, hash the tool calls (name + args).
  2. Track recent hashes in a sliding window.
  3. If the same hash appears >= warn_threshold times, queue a
     "you are repeating yourself — wrap up" warning for the current
     thread/run. The warning is **injected at the next model call** (in
     wrap_model_call) as a HumanMessage appended to the message
     list, *after* all ToolMessage responses to the previous
     AIMessage(tool_calls).
  4. If it appears >= hard_limit times, strip all tool_calls from the
     response so the agent is forced to produce a final text answer.

Why the warning is injected at wrap_model_call instead of
after_model:

  after_model fires immediately after the model emits an
  AIMessage that may carry tool_calls. The tools node has not
  run yet, so no matching ToolMessage exists in the history. Any
  message we add here lands *between* the assistant's tool_calls and
  their responses. OpenAI/Moonshot reject the next request with
  "tool_call_ids did not have response messages" because their
  validators require the assistant's tool_calls to be followed
  immediately by tool messages. Anthropic also disallows mid-stream
  SystemMessage. By deferring the warning to wrap_model_call,
  every prior ToolMessage is already present in the request's message
  list and the warning is appended at the end — pairing intact, no
  AIMessage semantics are mutated.

Queued warnings are intentionally transient. If a run ends before the
next model request drains a queued warning, after_agent drops it
instead of carrying it into a later invocation for the same thread. The
hard-stop path still forces termination when the configured safety limit
is reached.

Stop-reason surfacing (#3875 Phase 2):
  Like the token-budget guard, the loop hard stop does NOT raise — it
  strips tool_calls so the agent loop terminates naturally with a
  final answer. To let the caller (the subagent executor) distinguish a
  loop-capped completion from a clean one, the run that triggered the hard
  stop is recorded in _stop_reason and exposed via
  consume_stop_reason. The executor collects that reason alongside
  the token-budget guard's so a loop-capped run surfaces as
  completed + loop_capped and the lead/ledger can tell it was capped
  without parsing result text.
"""

from __future__ import annotations

import hashlib
import json
import logging
import threading
from collections import OrderedDict, defaultdict
from collections.abc import Awaitable, Callable
from copy import deepcopy
from typing import TYPE_CHECKING, override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelCallResult, ModelRequest, ModelResponse
from langchain_core.messages import HumanMessage
from langgraph.runtime import Runtime

from helix.agents.middlewares._bounded_dict import BoundedDict

if TYPE_CHECKING:
    from helix.config.loop_detection_config import LoopDetectionConfig

logger = logging.getLogger(__name__)

# Defaults — can be overridden via constructor
_DEFAULT_WARN_THRESHOLD = 3  # inject warning after 3 identical calls
_DEFAULT_HARD_LIMIT = 5  # force-stop after 5 identical calls
_DEFAULT_WINDOW_SIZE = 20  # track last N tool calls
_DEFAULT_MAX_TRACKED_THREADS = 100  # LRU eviction limit
_DEFAULT_TOOL_FREQ_WARN = 30  # warn after 30 calls to the same tool type
_DEFAULT_TOOL_FREQ_HARD_LIMIT = 50  # force-stop after 50 calls to the same tool type
_MAX_PENDING_WARNINGS_PER_RUN = 4


def _normalize_tool_call_args(raw_args: object) -> tuple[dict, str | None]:
    """Normalize tool call args to a dict plus an optional fallback key.

    Some providers serialize args as a JSON string instead of a dict.
    We defensively parse those cases so loop detection does not crash while
    still preserving a stable fallback key for non-dict payloads.
    """
    if isinstance(raw_args, dict):
        return raw_args, None

    if isinstance(raw_args, str):
        try:
            parsed = json.loads(raw_args)
        except (TypeError, ValueError, json.JSONDecodeError):
            return {}, raw_args

        if isinstance(parsed, dict):
            return parsed, None
        return {}, json.dumps(parsed, sort_keys=True, default=str)

    if raw_args is None:
        return {}, None

    return {}, json.dumps(raw_args, sort_keys=True, default=str)


def _stable_tool_key(name: str, args: dict, fallback_key: str | None) -> str:
    """Derive a stable key from salient args without overfitting to noise."""
    if name == "read_file" and fallback_key is None:
        path = args.get("path") or ""
        start_line = args.get("start_line")
        end_line = args.get("end_line")

        bucket_size = 200
        try:
            start_line = int(start_line) if start_line is not None else 1
        except (TypeError, ValueError):
            start_line = 1
        try:
            end_line = int(end_line) if end_line is not None else start_line
        except (TypeError, ValueError):
            end_line = start_line

        start_line, end_line = sorted((start_line, end_line))
        bucket_start = max(start_line, 1)
        bucket_end = max(end_line, 1)
        bucket_start = (bucket_start - 1) // bucket_size
        bucket_end = (bucket_end - 1) // bucket_size
        return f"{path}:{bucket_start}-{bucket_end}"

    # write_file / str_replace are content-sensitive: same path may be updated
    # with different payloads during iteration. Using only salient fields (path)
    # can collapse distinct calls, so we hash full args to reduce false positives.
    if name in {"write_file", "str_replace"}:
        if fallback_key is not None:
            return fallback_key
        return json.dumps(args, sort_keys=True, default=str)

    salient_fields = ("path", "url", "query", "command", "pattern", "glob", "cmd")
    stable_args = {field: args[field] for field in salient_fields if args.get(field) is not None}
    if stable_args:
        return json.dumps(stable_args, sort_keys=True, default=str)

    if fallback_key is not None:
        return fallback_key

    return json.dumps(args, sort_keys=True, default=str)


def _hash_tool_calls(tool_calls: list[dict]) -> str:
    """Deterministic hash of a set of tool calls (name + stable key).

    This is intended to be order-independent: the same multiset of tool calls
    should always produce the same hash, regardless of their input order.
    """
    # Normalize each tool call to a stable (name, key) structure.
    normalized: list[str] = []
    for tc in tool_calls:
        name = tc.get("name", "")
        args, fallback_key = _normalize_tool_call_args(tc.get("args", {}))
        key = _stable_tool_key(name, args, fallback_key)

        normalized.append(f"{name}:{key}")

    # Sort so permutations of the same multiset of calls yield the same ordering.
    normalized.sort()
    blob = json.dumps(normalized, sort_keys=True, default=str)
    return hashlib.md5(blob.encode()).hexdigest()[:12]


_WARNING_MSG = "[LOOP DETECTED] You are repeating the same tool calls. Stop calling tools and produce your final answer now. If you cannot complete the task, summarize what you accomplished so far."

_TOOL_FREQ_WARNING_MSG = (
    "[LOOP DETECTED] You have called {tool_name} {count} times without producing a final answer. Stop calling tools and produce your final answer now. If you cannot complete the task, summarize what you accomplished so far."
)

_HARD_STOP_MSG = "[FORCED STOP] Repeated tool calls exceeded the safety limit. Producing final answer with results collected so far."

_TOOL_FREQ_HARD_STOP_MSG = "[FORCED STOP] Tool {tool_name} called {count} times — exceeded the per-tool safety limit. Producing final answer with results collected so far."


class LoopDetectionMiddleware(AgentMiddleware[AgentState]):
    """Detects and breaks repetitive tool call loops.

    Threshold parameters are validated upstream by LoopDetectionConfig;
    construct via from_config to ensure values pass Pydantic validation.

    Args:
        warn_threshold: Number of identical tool call sets before injecting
            a warning message. Default: 3.
        hard_limit: Number of identical tool call sets before stripping
            tool_calls entirely. Default: 5.
        window_size: Size of the sliding window for tracking calls.
            Default: 20.
        max_tracked_threads: Maximum number of threads to track before
            evicting the least recently used. Default: 100.
        tool_freq_warn: Number of calls to the same tool *type* (regardless
            of arguments) before injecting a frequency warning. Catches
            cross-file read loops that hash-based detection misses.
            Default: 30.
        tool_freq_hard_limit: Number of calls to the same tool type before
            forcing a stop. Default: 50.
        tool_freq_overrides: Per-tool overrides for frequency thresholds,
            keyed by tool name. Each value is a (warn, hard_limit) tuple
            that replaces tool_freq_warn / tool_freq_hard_limit for
            that specific tool. Tools not listed here fall back to the global
            thresholds. Useful for raising limits on intentionally
            high-frequency tools (e.g. bash in batch pipelines) without
            weakening protection on all other tools. Default: None
            (no overrides).
    """

    def __init__(
        self,
        warn_threshold: int = _DEFAULT_WARN_THRESHOLD,
        hard_limit: int = _DEFAULT_HARD_LIMIT,
        window_size: int = _DEFAULT_WINDOW_SIZE,
        max_tracked_threads: int = _DEFAULT_MAX_TRACKED_THREADS,
        tool_freq_warn: int = _DEFAULT_TOOL_FREQ_WARN,
        tool_freq_hard_limit: int = _DEFAULT_TOOL_FREQ_HARD_LIMIT,
        tool_freq_overrides: dict[str, tuple[int, int]] | None = None,
    ):
        super().__init__()
        self.warn_threshold = warn_threshold
        self.hard_limit = hard_limit
        self.window_size = window_size
        self.max_tracked_threads = max_tracked_threads
        self.tool_freq_warn = tool_freq_warn
        self.tool_freq_hard_limit = tool_freq_hard_limit
        self._tool_freq_overrides: dict[str, tuple[int, int]] = tool_freq_overrides or {}
        self._lock = threading.Lock()
        self._history: OrderedDict[str, list[str]] = OrderedDict()
        self._warned: dict[str, set[str]] = defaultdict(set)
        self._tool_freq: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
        self._tool_freq_warned: dict[str, set[str]] = defaultdict(set)
        # Per-thread/run queue of warnings to inject at the next model call.
        # Populated by after_model (detection) and drained by
        # wrap_model_call (injection); see module docstring.
        self._pending_warnings: dict[tuple[str, str], list[str]] = defaultdict(list)
        self._pending_warning_touch_order: OrderedDict[tuple[str, str], None] = OrderedDict()
        self._max_pending_warning_keys = max(1, self.max_tracked_threads * 2)
        # Stop reason set when a hard-stop fires (#3875 Phase 2). Keyed by run_id
        # (matching TokenBudgetMiddleware) and bounded — the lead agent's
        # middleware instance is long-lived across many runs, so without a cap
        # an entry would accumulate for every looped lead run. Intentionally NOT
        # cleared by after_agent/_clear_current_run_pending_warnings so
        # the subagent executor can consume it after the run returns; reset()
        # still drops it.
        self._stop_reason: BoundedDict[str, str] = BoundedDict(1000)

    @classmethod
    def from_config(cls, config: LoopDetectionConfig) -> LoopDetectionMiddleware:
        """Construct from a Pydantic-validated config, trusting its validation."""
        return cls(
            warn_threshold=config.warn_threshold,
            hard_limit=config.hard_limit,
            window_size=config.window_size,
            max_tracked_threads=config.max_tracked_threads,
            tool_freq_warn=config.tool_freq_warn,
            tool_freq_hard_limit=config.tool_freq_hard_limit,
            tool_freq_overrides={name: (o.warn, o.hard_limit) for name, o in config.tool_freq_overrides.items()},
        )

    def _get_thread_id(self, runtime: Runtime) -> str:
        """Extract thread_id from runtime context for per-thread tracking."""
        thread_id = runtime.context.get("thread_id") if runtime.context else None
        if thread_id:
            return str(thread_id)
        return "default"

    def _get_run_id(self, runtime: Runtime) -> str:
        """Extract run_id from runtime context for per-run warning scoping."""
        run_id = runtime.context.get("run_id") if runtime.context else None
        if run_id:
            return str(run_id)
        return "default"

    def consume_stop_reason(self, run_id: str | None) -> str | None:
        """Pop and return the stop reason the hard-stop set for this run.

        Returns "loop_capped" when a repeated tool-call loop tripped the hard
        stop during the run — the run still completed with a forced final answer
        (the hard stop strips tool_calls rather than raising). The subagent
        executor calls this after the run returns so a loop-capped completion
        carries stop_reason=loop_capped to the lead instead of looking like
        a clean completed. Mirrors TokenBudgetMiddleware.consume_stop_reason;
        popping keeps the dict from accumulating on a reused instance.
        """
        with self._lock:
            return self._stop_reason.pop(run_id, None)

    def _pending_key(self, runtime: Runtime) -> tuple[str, str]:
        """Return the pending-warning key for the current thread/run."""
        return self._get_thread_id(runtime), self._get_run_id(runtime)

    def _evict_if_needed(self) -> None:
        """Evict least recently used threads if over the limit.

        Must be called while holding self._lock.
        """
        while len(self._history) > self.max_tracked_threads:
            evicted_id, _ = self._history.popitem(last=False)
            self._warned.pop(evicted_id, None)
            self._tool_freq.pop(evicted_id, None)
            self._tool_freq_warned.pop(evicted_id, None)
            for key in list(self._pending_warnings):
                if key[0] == evicted_id:
                    self._drop_pending_warning_key_locked(key)
            logger.debug("Evicted loop tracking for thread %s (LRU)", evicted_id)

    def _drop_pending_warning_key_locked(self, key: tuple[str, str]) -> None:
        """Drop all pending-warning bookkeeping for one thread/run key.

        Must be called while holding self._lock.
        """
        self._pending_warnings.pop(key, None)
        self._pending_warning_touch_order.pop(key, None)

    def _touch_pending_warning_key_locked(self, key: tuple[str, str]) -> None:
        """Mark a pending-warning key as recently used.

        Must be called while holding self._lock.
        """
        self._pending_warning_touch_order[key] = None
        self._pending_warning_touch_order.move_to_end(key)

    def _prune_pending_warning_state_locked(self, protected_key: tuple[str, str]) -> None:
        """Cap pending-warning state across abnormal or concurrent runs.

        Must be called while holding self._lock.
        """
        overflow = len(self._pending_warning_touch_order) - self._max_pending_warning_keys
        if overflow <= 0:
            return

        candidates = [key for key in self._pending_warning_touch_order if key != protected_key]
        for key in candidates[:overflow]:
            self._drop_pending_warning_key_locked(key)

    def _queue_pending_warning(self, runtime: Runtime, warning: str) -> None:
        """Queue one transient warning for the current thread/run with caps."""
        pending_key = self._pending_key(runtime)
        with self._lock:
            warnings = self._pending_warnings[pending_key]
            if warning not in warnings:
                warnings.append(warning)
            if len(warnings) > _MAX_PENDING_WARNINGS_PER_RUN:
                del warnings[: len(warnings) - _MAX_PENDING_WARNINGS_PER_RUN]
            self._touch_pending_warning_key_locked(pending_key)
            self._prune_pending_warning_state_locked(protected_key=pending_key)

    def _track_and_check(self, state: AgentState, runtime: Runtime) -> tuple[str | None, bool]:
        """Track tool calls and check for loops.

        Two detection layers:
          1. **Hash-based** (existing): catches identical tool call sets.
          2. **Frequency-based** (new): catches the same *tool type* being
             called many times with varying arguments (e.g. read_file
             on 40 different files).

        Returns:
            (warning_message_or_none, should_hard_stop)
        """
        messages = state.get("messages", [])
        if not messages:
            return None, False

        last_msg = messages[-1]
        if getattr(last_msg, "type", None) != "ai":
            return None, False

        tool_calls = getattr(last_msg, "tool_calls", None)
        if not tool_calls:
            return None, False

        thread_id = self._get_thread_id(runtime)
        call_hash = _hash_tool_calls(tool_calls)

        with self._lock:
            # Touch / create entry (move to end for LRU)
            if thread_id in self._history:
                self._history.move_to_end(thread_id)
            else:
                self._history[thread_id] = []
                self._evict_if_needed()

            history = self._history[thread_id]
            history.append(call_hash)
            if len(history) > self.window_size:
                history[:] = history[-self.window_size:]

            warned_hashes = self._warned.get(thread_id)
            if warned_hashes is not None:
                warned_hashes.intersection_update(history)
                if not warned_hashes:
                    self._warned.pop(thread_id, None)

            count = history.count(call_hash)
            tool_names = [tc.get("name", "?") for tc in tool_calls]

            # --- Layer 1: hash-based (identical call sets) ---
            if count >= self.hard_limit:
                logger.error(
                    "Loop hard limit reached — forcing stop",
                    extra={
                        "thread_id": thread_id,
                        "call_hash": call_hash,
                        "count": count,
                        "tools": tool_names,
                    },
                )
                return _HARD_STOP_MSG, True

            if count >= self.warn_threshold:
                warned = self._warned[thread_id]
                if call_hash not in warned:
                    warned.add(call_hash)
                    logger.warning(
                        "Repetitive tool calls detected — injecting warning",
                        extra={
                            "thread_id": thread_id,
                            "call_hash": call_hash,
                            "count": count,
                            "tools": tool_names,
                        },
                    )
                    return _WARNING_MSG, False

            # --- Layer 2: per-tool-type frequency ---
            freq = self._tool_freq[thread_id]
            for tc in tool_calls:
                name = tc.get("name", "")
                if not name:
                    continue
                freq[name] += 1
                tc_count = freq[name]

                if name in self._tool_freq_overrides:
                    eff_warn, eff_hard = self._tool_freq_overrides[name]
                else:
                    eff_warn, eff_hard = self.tool_freq_warn, self.tool_freq_hard_limit

                if tc_count >= eff_hard:
                    logger.error(
                        "Tool frequency hard limit reached — forcing stop",
                        extra={
                            "thread_id": thread_id,
                            "tool_name": name,
                            "count": tc_count,
                        },
                    )
                    return _TOOL_FREQ_HARD_STOP_MSG.format(tool_name=name, count=tc_count), True

                if tc_count >= eff_warn:
                    warned = self._tool_freq_warned[thread_id]
                    if name not in warned:
                        warned.add(name)
                        logger.warning(
                            "Tool frequency warning — too many calls to same tool type",
                            extra={
                                "thread_id": thread_id,
                                "tool_name": name,
                                "count": tc_count,
                            },
                        )
                        return _TOOL_FREQ_WARNING_MSG.format(tool_name=name, count=tc_count), False

        return None, False

    @staticmethod
    def _append_text(content: str | list | None, text: str) -> str | list:
        """Append *text* to AIMessage content, handling str, list, and None.

        When content is a list of content blocks (e.g. Anthropic thinking mode),
        we append a new {"type": "text", ...} block instead of concatenating
        a string to a list, which would raise TypeError.
        """
        if content is None:
            return text
        if isinstance(content, list):
            return [*content, {"type": "text", "text": f"\n\n{text}"}]
        if isinstance(content, str):
            return content + f"\n\n{text}"
        # Fallback: coerce unexpected types to str to avoid TypeError
        return str(content) + f"\n\n{text}"

    @staticmethod
    def _build_hard_stop_update(last_msg, content: str | list) -> dict:
        """Clear tool-call metadata so forced-stop messages serialize as plain assistant text."""
        update = {
            "tool_calls": [],
            "content": content,
        }

        additional_kwargs = dict(getattr(last_msg, "additional_kwargs", {}) or {})
        for key in ("tool_calls", "function_call"):
            additional_kwargs.pop(key, None)
        update["additional_kwargs"] = additional_kwargs

        response_metadata = deepcopy(getattr(last_msg, "response_metadata", {}) or {})
        if response_metadata.get("finish_reason") == "tool_calls":
            response_metadata["finish_reason"] = "stop"
        update["response_metadata"] = response_metadata

        return update

    def _apply(self, state: AgentState, runtime: Runtime) -> dict | None:
        warning, hard_stop = self._track_and_check(state, runtime)

        if hard_stop:
            # Record the stop reason so the executor can surface
            # stop_reason=loop_capped after the run returns (#3875 Phase 2).
            # The hard stop does not raise — it strips tool_calls and lets the
            # run finish with a forced final answer — so without this the caller
            # would see a clean completed. See consume_stop_reason.
            # Written under the lock to match TokenBudgetMiddleware: the lead
            # agent's middleware instance is shared across concurrent Gateway
            # threads, so the bounded-dict write needs the same guard.
            run_id = self._get_run_id(runtime)
            with self._lock:
                self._stop_reason[run_id] = "loop_capped"
            # Strip tool_calls from the last AIMessage to force text output.
            # Once tool_calls are stripped, the AIMessage no longer requires
            # matching ToolMessage responses, so mutating it in place here
            # is safe for OpenAI/Moonshot pairing validators.
            messages = state.get("messages", [])
            last_msg = messages[-1]
            content = self._append_text(last_msg.content, warning or _HARD_STOP_MSG)
            stripped_msg = last_msg.model_copy(update=self._build_hard_stop_update(last_msg, content))
            return {"messages": [stripped_msg]}

        if warning:
            # Defer injection to the next model call. We must NOT alter the
            # AIMessage(tool_calls=...) here (would put framework words in
            # the model's mouth, polluting downstream consumers like
            # MemoryMiddleware), nor insert a separate non-tool message
            # (would break OpenAI/Moonshot tool-call pairing because the
            # tools node has not produced ToolMessage responses yet). The
            # warning is delivered via wrap_model_call below.
            self._queue_pending_warning(runtime, warning)
            return None

        return None

    def _clear_other_run_pending_warnings(self, runtime: Runtime) -> None:
        """Drop stale pending warnings for previous runs in this thread."""
        thread_id, current_run_id = self._pending_key(runtime)
        with self._lock:
            for key in list(self._pending_warnings):
                if key[0] == thread_id and key[1] != current_run_id:
                    self._drop_pending_warning_key_locked(key)

    def _clear_current_run_pending_warnings(self, runtime: Runtime) -> None:
        """Drop pending warnings owned by the current thread/run."""
        pending_key = self._pending_key(runtime)
        with self._lock:
            self._drop_pending_warning_key_locked(pending_key)

    @staticmethod
    def _format_warning_message(warnings: list[str]) -> str:
        """Merge pending warnings into one prompt message."""
        deduped = list(dict.fromkeys(warnings))
        return "\n\n".join(deduped)

    @override
    def before_agent(self, state: AgentState, runtime: Runtime) -> dict | None:
        self._clear_other_run_pending_warnings(runtime)
        return None

    @override
    async def abefore_agent(self, state: AgentState, runtime: Runtime) -> dict | None:
        self._clear_other_run_pending_warnings(runtime)
        return None

    @override
    def after_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)

    @override
    async def aafter_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)

    @override
    def after_agent(self, state: AgentState, runtime: Runtime) -> dict | None:
        self._clear_current_run_pending_warnings(runtime)
        return None

    @override
    async def aafter_agent(self, state: AgentState, runtime: Runtime) -> dict | None:
        self._clear_current_run_pending_warnings(runtime)
        return None

    def _drain_pending_warnings(self, runtime: Runtime) -> list[str]:
        """Pop and return all queued warnings for *runtime*'s thread/run."""
        pending_key = self._pending_key(runtime)
        with self._lock:
            warnings = self._pending_warnings.pop(pending_key, [])
            self._pending_warning_touch_order.pop(pending_key, None)
        return warnings

    def _augment_request(self, request: ModelRequest) -> ModelRequest:
        """Append queued loop warnings (if any) to the outgoing message list.

        The warning is placed *after* every existing message, including the
        ToolMessage responses to the previous AIMessage(tool_calls). This
        keeps assistant tool_calls -> tool_messages pairing intact for
        OpenAI/Moonshot, avoids the Anthropic mid-stream SystemMessage
        restriction (we use HumanMessage), and never mutates an existing
        AIMessage.
        """
        warnings = self._drain_pending_warnings(request.runtime)
        if not warnings:
            return request
        new_messages = [
            *request.messages,
            HumanMessage(content=self._format_warning_message(warnings), name="loop_warning"),
        ]
        return request.override(messages=new_messages)

    @override
    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelCallResult:
        return handler(self._augment_request(request))

    @override
    async def awrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], Awaitable[ModelResponse]],
    ) -> ModelCallResult:
        return await handler(self._augment_request(request))

    def reset(self, thread_id: str | None = None) -> None:
        """Clear tracking state. If thread_id given, clear only that thread."""
        with self._lock:
            if thread_id:
                self._history.pop(thread_id, None)
                self._warned.pop(thread_id, None)
                self._tool_freq.pop(thread_id, None)
                self._tool_freq_warned.pop(thread_id, None)
                for key in list(self._pending_warnings):
                    if key[0] == thread_id:
                        self._drop_pending_warning_key_locked(key)
            else:
                self._history.clear()
                self._warned.clear()
                self._tool_freq.clear()
                self._tool_freq_warned.clear()
                self._pending_warnings.clear()
                self._pending_warning_touch_order.clear()
                self._stop_reason.clear()
```

---

## 2. `TokenBudgetMiddleware` 完整源码

真实路径 `core/helix/agents/middlewares/token_budget_middleware.py`。`after_model` diff 累加 token usage（处理子代理追溯 token）、三维 fraction（total/input/output）、两段降级（warn 队列 / hard_stop 双清）。

```python
# core/helix/agents/middlewares/token_budget_middleware.py
"""Middleware to enforce per-run token budget limits.

Tracks cumulative token usage (input, output, total) across model calls within
a single agent run and enforces configurable soft-warning and hard-stop
thresholds.

Detection strategy:
  1. After each model response, sum the usage_metadata of all AIMessages
     in the current thread history. This automatically captures tokens from
     subagents because TokenUsageMiddleware retroactively adds them to the
     history.
  2. If the highest fraction (input, output, or total) >= warn_threshold,
     queue a warning.
  3. If the highest fraction >= hard_stop_threshold, strip tool_calls.

Warning injection uses the deferred pattern:
  - after_model queues the warning (does NOT mutate state).
  - wrap_model_call injects it as a HumanMessage at the next model call.

This preserves AIMessage(tool_calls) -> ToolMessage pairing.

Stop-reason surfacing (#3875 Phase 2):
  The hard stop does NOT raise — it strips tool_calls so the agent loop
  terminates naturally and produces a final answer. To let the caller (e.g.
  the subagent executor) distinguish a budget-capped completion from a clean
  one, the run that triggered the hard stop is recorded in _stop_reason
  and exposed via consume_stop_reason. That dict is intentionally NOT
  cleared by after_agent/_clear_run_state so the executor can read it
  after the run returns; the bounded dict prevents unbounded growth on
  abandoned runs, and each subagent run builds a fresh middleware instance so
  there is no cross-run contamination.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any, override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelCallResult, ModelRequest, ModelResponse
from langchain_core.messages import AIMessage, HumanMessage
from langgraph.runtime import Runtime

from helix.agents.middlewares._bounded_dict import BoundedDict
from helix.config.token_budget_config import TokenBudgetConfig

logger = logging.getLogger(__name__)

_BUDGET_WARNING_MSG = (
    "[TOKEN BUDGET WARNING] You have used {used:,} of your {budget:,} {reason} token budget ({percent:.0f}%). Wrap up your current work and produce a final answer. Avoid starting new tool calls unless absolutely necessary."
)
_BUDGET_EXCEEDED_MSG = "[TOKEN BUDGET EXCEEDED] The {reason} token usage ({used:,}) has exceeded the safety limit ({budget:,}). Producing final answer with results collected so far."


@dataclass
class TokenUsage:
    input: int = 0
    output: int = 0
    total: int = 0


class TokenBudgetMiddleware(AgentMiddleware[AgentState]):
    """Enforce per-run token budget limits."""

    def __init__(self, config: TokenBudgetConfig) -> None:
        super().__init__()
        self._config = config
        self._lock = threading.Lock()

        # Keyed strictly by run_id (clobber-safe) and bounded (leak-safe)
        self._warned: BoundedDict[str, bool] = BoundedDict(1000)
        self._pending_warnings: BoundedDict[str, list[str]] = BoundedDict(1000)
        self._seen_messages: BoundedDict[str, dict[str, tuple[int, int]]] = BoundedDict(1000)
        self._cumulative_usage: BoundedDict[str, TokenUsage] = BoundedDict(1000)
        # Stop reason set when the hard-stop fires. NOT cleared by
        # _clear_run_state/after_agent so the executor can consume it
        # after the run returns; bounded so abandoned runs cannot leak.
        self._stop_reason: BoundedDict[str, str] = BoundedDict(1000)

    @classmethod
    def from_config(cls, config: TokenBudgetConfig) -> TokenBudgetMiddleware:
        return cls(config=config)

    def reset(self) -> None:
        with self._lock:
            self._warned.clear()
            self._pending_warnings.clear()
            self._seen_messages.clear()
            self._cumulative_usage.clear()
            self._stop_reason.clear()

    def consume_stop_reason(self, run_id: str | None) -> str | None:
        """Pop and return the stop reason the hard-stop set for this run.

        Returns "token_capped" when the budget hard-stop fired during the
        run, otherwise None. The executor calls this after the run returns
        to decide whether a completed subagent was actually budget-capped
        (and should carry stop_reason=token_capped to the lead). Popping
        keeps the dict from accumulating across runs on a reused instance.
        """
        with self._lock:
            return self._stop_reason.pop(run_id, None)

    @staticmethod
    def _get_run_id(runtime: Runtime) -> str:
        ctx = getattr(runtime, "context", None)
        if isinstance(ctx, dict) and "run_id" in ctx:
            return ctx["run_id"]
        # Fallback to runtime object ID to prevent collisions across embedded client runs
        return str(id(runtime))

    def _clear_run_state(self, run_id: str) -> None:
        with self._lock:
            self._warned.pop(run_id, None)
            self._pending_warnings.pop(run_id, None)
            self._seen_messages.pop(run_id, None)
            self._cumulative_usage.pop(run_id, None)

    @override
    def before_agent(self, state: AgentState, runtime: Runtime) -> None:
        if not self._config.enabled:
            return

        # Mark all old messages from previous runs as 'seen' so they don't count toward THIS run's budget
        messages = state.get("messages", [])
        if not messages:
            return

        run_id = self._get_run_id(runtime)
        with self._lock:
            seen = self._seen_messages.setdefault(run_id, {})
            self._cumulative_usage.setdefault(run_id, TokenUsage())

            for msg in messages:
                if isinstance(msg, AIMessage) and msg.id and hasattr(msg, "usage_metadata"):
                    usage = msg.usage_metadata or {}
                    input_tokens = usage.get("input_tokens", 0)
                    output_tokens = usage.get("output_tokens", 0)
                    seen[msg.id] = (input_tokens, output_tokens)

    @override
    async def abefore_agent(self, state: AgentState, runtime: Runtime) -> None:
        self.before_agent(state, runtime)

    @override
    def after_agent(self, state: AgentState, runtime: Runtime) -> None:
        if not self._config.enabled:
            return
        self._clear_run_state(self._get_run_id(runtime))

    @override
    async def aafter_agent(self, state: AgentState, runtime: Runtime) -> None:
        self.after_agent(state, runtime)

    @staticmethod
    def _append_text(content: str | list[dict | None] | None, stop_msg: str) -> str | list[dict | str]:
        """Append a stop message to an AIMessage.content field."""
        if content is None:
            return stop_msg
        if isinstance(content, str):
            if content:
                return f"{content}\n\n{stop_msg}"
            return f"\n\n{stop_msg}"
        if isinstance(content, list):
            new_content = list(content)
            new_content.append({"type": "text", "text": f"\n\n{stop_msg}"})
            return new_content
        return f"{content}\n\n{stop_msg}"

    def _build_hard_stop_update(self, msg: AIMessage, stop_msg: str) -> dict[str, Any]:
        """Build the state update dictionary for a hard stop."""
        updated_content = self._append_text(msg.content, stop_msg)
        kwargs = dict(msg.additional_kwargs) if msg.additional_kwargs else {}
        if "tool_calls" in kwargs:
            del kwargs["tool_calls"]
        if "function_call" in kwargs:
            del kwargs["function_call"]

        response_metadata = dict(getattr(msg, "response_metadata", {}) or {})

        if response_metadata.get("finish_reason") == "tool_calls":
            response_metadata["finish_reason"] = "stop"

        stopped_msg = msg.model_copy(update={"content": updated_content, "tool_calls": [], "additional_kwargs": kwargs, "response_metadata": response_metadata})
        return {"messages": [stopped_msg]}

    def _apply(self, state: AgentState, runtime: Runtime) -> dict | None:
        if not self._config.enabled:
            return None

        messages = state.get("messages", [])
        if not messages:
            return None

        last_msg = messages[-1]
        if not isinstance(last_msg, AIMessage):
            return None

        run_id = self._get_run_id(runtime)

        with self._lock:
            seen = self._seen_messages.setdefault(run_id, {})
            usage_accum = self._cumulative_usage.setdefault(run_id, TokenUsage())

            for msg in messages:
                if isinstance(msg, AIMessage) and msg.id and hasattr(msg, "usage_metadata"):
                    usage = msg.usage_metadata or {}

                    input_tokens = usage.get("input_tokens", 0)
                    output_tokens = usage.get("output_tokens", 0)

                    # Check what previously recorded for this exact message
                    prev_input, prev_output = seen.get(msg.id, (0, 0))

                    # Calculate if any new tokens were added (handles retroactive subagent tokens)
                    diff_input = max(0, input_tokens - prev_input)
                    diff_output = max(0, output_tokens - prev_output)

                    if diff_input > 0 or diff_output > 0:
                        usage_accum.input += diff_input
                        usage_accum.output += diff_output
                        usage_accum.total += diff_input + diff_output
                        seen[msg.id] = (input_tokens, output_tokens)

            if usage_accum.total <= 0:
                return None

            fractions = [("total", usage_accum.total, self._config.max_tokens)]
            if self._config.max_input_tokens:
                fractions.append(("input", usage_accum.input, self._config.max_input_tokens))
            if self._config.max_output_tokens:
                fractions.append(("output", usage_accum.output, self._config.max_output_tokens))

            highest_fraction = 0.0
            trigger_reason = ""
            trigger_used = 0
            trigger_budget = 0

            for reason, used, limit in fractions:
                frac = used / limit
                if frac > highest_fraction:
                    highest_fraction = frac
                    trigger_reason = reason
                    trigger_used = used
                    trigger_budget = limit

            if highest_fraction >= self._config.hard_stop_threshold:
                logger.warning("Token budget hard stop triggered for run %s: %s limit exceeded", run_id, trigger_reason)
                # Record the stop reason so the executor can surface
                # stop_reason=token_capped to the lead after the run
                # returns (the hard stop itself does not raise). See
                # consume_stop_reason.
                self._stop_reason[run_id] = "token_capped"
                stop_text = _BUDGET_EXCEEDED_MSG.format(reason=trigger_reason, used=trigger_used, budget=trigger_budget)
                return self._build_hard_stop_update(last_msg, stop_text)

            if highest_fraction >= self._config.warn_threshold and not self._warned.get(run_id, False):
                self._warned[run_id] = True
                percent = highest_fraction * 100
                warn_text = _BUDGET_WARNING_MSG.format(reason=trigger_reason, used=trigger_used, budget=trigger_budget, percent=percent)
                logger.info("Token budget warning triggered for run %s: %s limit at %.1f%%", run_id, trigger_reason, percent)
                # queue warning for wrap_model_call
                warnings = self._pending_warnings.setdefault(run_id, [])
                warnings.append(warn_text)
                return None

            return None

    @override
    def after_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)

    @override
    async def aafter_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        return self._apply(state, runtime)

    def _drain_pending_warnings(self, runtime: Runtime) -> list[str]:
        if not self._config.enabled:
            return []

        run_id = self._get_run_id(runtime)
        with self._lock:
            warnings = self._pending_warnings.pop(run_id, None)
        return warnings or []

    def _inject_warnings(self, request: ModelRequest, warnings: list[str]) -> ModelRequest:
        if not warnings:
            return request

        merged_text = "\n\n".join(warnings)
        warning_msg = HumanMessage(content=merged_text, name="budget_warning")

        messages = getattr(request, "messages", [])
        new_messages = list(messages) + [warning_msg]
        return request.override(messages=new_messages)

    @override
    def wrap_model_call(self, request: ModelRequest, handler: Callable[[ModelRequest], ModelResponse]) -> ModelCallResult:

        warnings = self._drain_pending_warnings(request.runtime)
        request = self._inject_warnings(request, warnings)

        return handler(request)

    @override
    async def awrap_model_call(self, request: ModelRequest, handler: Callable[[ModelRequest], Awaitable[ModelResponse]]) -> ModelCallResult:
        warnings = self._drain_pending_warnings(request.runtime)
        request = self._inject_warnings(request, warnings)
        return await handler(request)
```

---

## 3. `BoundedDict`（共享 FIFO 驱逐 OrderedDict）

真实路径 `core/helix/agents/middlewares/_bounded_dict.py`。LoopDetection 与 TokenBudget 共用，防长生命周期中间件实例在 abandoned run 上 leak。

```python
# core/helix/agents/middlewares/_bounded_dict.py
"""A small bounded OrderedDict shared by guard middlewares.

Guard middlewares (TokenBudgetMiddleware, LoopDetectionMiddleware) keep
per-run_id state that must not grow without bound on abandoned or reused
runs. This module provides the single shared implementation so both middlewares
cap identically and a future guard does not reinvent it.
"""

from __future__ import annotations

from collections import OrderedDict
from typing import Any


class BoundedDict(OrderedDict):
    """An OrderedDict that evicts the oldest entry once maxsize is reached.

    Used for per-run_id state (stop-reason flags, pending warnings, usage
    accumulators) so a long-lived middleware instance on the lead agent cannot
    leak memory across many runs. Insertion order is preserved, so the
    least-recently-inserted key is evicted first.
    """

    def __init__(self, maxsize: int = 1000, *args: Any, **kwds: Any) -> None:
        self.maxsize = maxsize
        super().__init__(*args, **kwds)

    def __setitem__(self, key: Any, value: Any) -> None:
        if key not in self:
            if len(self) >= self.maxsize:
                self.popitem(last=False)
        super().__setitem__(key, value)
```

---

## 4. `LoopDetectionConfig` / `ToolFreqOverride`

真实路径 `core/helix/config/loop_detection_config.py`。Pydantic 校验保证 `hard_limit >= warn_threshold`、`tool_freq_hard_limit >= tool_freq_warn`。

```python
# core/helix/config/loop_detection_config.py
"""Configuration for loop detection middleware."""

from pydantic import BaseModel, Field, model_validator


class ToolFreqOverride(BaseModel):
    """Per-tool frequency threshold override.

    Can be higher or lower than the global defaults. Commonly used to raise
    thresholds for high-frequency tools like bash in batch workflows (e.g.
    RNA-seq pipelines) without weakening protection on every other tool.
    """

    warn: int = Field(ge=1)
    hard_limit: int = Field(ge=1)

    @model_validator(mode="after")
    def _validate(self) -> "ToolFreqOverride":
        if self.hard_limit < self.warn:
            raise ValueError("hard_limit must be >= warn")
        return self


class LoopDetectionConfig(BaseModel):
    """Configuration for repetitive tool-call loop detection."""

    enabled: bool = Field(
        default=True,
        description="Whether to enable repetitive tool-call loop detection",
    )
    warn_threshold: int = Field(
        default=3,
        ge=1,
        description="Number of identical tool-call sets before injecting a warning",
    )
    hard_limit: int = Field(
        default=5,
        ge=1,
        description="Number of identical tool-call sets before forcing a stop",
    )
    window_size: int = Field(
        default=20,
        ge=1,
        description="Number of recent tool-call sets to track per thread",
    )
    max_tracked_threads: int = Field(
        default=100,
        ge=1,
        description="Maximum number of thread histories to keep in memory",
    )
    tool_freq_warn: int = Field(
        default=30,
        ge=1,
        description="Number of calls to the same tool type before injecting a frequency warning",
    )
    tool_freq_hard_limit: int = Field(
        default=50,
        ge=1,
        description="Number of calls to the same tool type before forcing a stop",
    )
    tool_freq_overrides: dict[str, ToolFreqOverride] = Field(
        default_factory=dict,
        description=("Per-tool overrides for tool_freq_warn / tool_freq_hard_limit, keyed by tool name. Values can be higher or lower than the global defaults. Commonly used to raise thresholds for high-frequency tools like bash."),
    )

    @model_validator(mode="after")
    def validate_thresholds(self) -> "LoopDetectionConfig":
        """Ensure hard stop cannot happen before the warning threshold."""
        if self.hard_limit < self.warn_threshold:
            raise ValueError("hard_limit must be greater than or equal to warn_threshold")
        if self.tool_freq_hard_limit < self.tool_freq_warn:
            raise ValueError("tool_freq_hard_limit must be greater than or equal to tool_freq_warn")
        return self
```

---

## 5. `TokenBudgetConfig`

真实路径 `core/helix/config/token_budget_config.py`。三维上限（total/input/output）+ 两段阈值 fraction。

```python
# core/helix/config/token_budget_config.py
"""Config for token budget middleware."""

from pydantic import BaseModel, Field, model_validator


class TokenBudgetConfig(BaseModel):
    """Configuration for per-run token budget enforcement."""

    enabled: bool = Field(default=False, description="Whether to enable per-run token budget enforcement.")
    max_tokens: int = Field(default=200000, ge=1000, description="Maximum total tokens (input + output) allowed per run.")
    max_input_tokens: int | None = Field(default=None, ge=1, description="Optional separate limit for input tokens only.")
    max_output_tokens: int | None = Field(default=None, ge=1, description="Optional separate limit for output tokens only.")
    warn_threshold: float = Field(default=0.8, ge=0.0, le=1.0, description="Fraction of max_tokens at which a soft warning is injected. E.g., 0.8 means warn at 80% of max_tokens")
    hard_stop_threshold: float = Field(default=1.0, ge=0.0, le=1.0, description=("Fraction of max_tokens at which tool calls are stripped and the agent is forced to produce a final answer. E.g., 1.0 means stop at 100% of max_tokens."))

    @model_validator(mode="after")
    def validate_thresholds(self) -> "TokenBudgetConfig":
        """Ensure hard stop cannot trigger before the warning."""
        if self.hard_stop_threshold < self.warn_threshold:
            raise ValueError("hard_stop_threshold must be >= warn_threshold")
        return self
```

---

## 6. lead agent 的装配片段

真实路径 `core/helix/agents/lead/agent.py`。`build_middlewares` 在 SystemMessageCoalescing（23）之后、custom（27）之前续装 25/26 号位的 LoopDetection 与 TokenBudget（条件可选，config 驱动）。注意 SafetyFinishReason（28）注册在其后——逆序 `after_model` 派发使 Safety 先跑清安全终止的 tool_calls，Loop/Budget 再对清理后的消息计数。

```python
# core/helix/agents/lead/agent.py
from helix.agents.middlewares.loop_detection_middleware import LoopDetectionMiddleware

# build_middlewares 内部：
def build_middlewares(config, model_name, agent_name=None, custom_middlewares=None, *,
                      available_skills=None, app_config=None, deferred_setup=None, user_id=None):
    resolved_app_config = app_config or get_app_config()
    middlewares = build_lead_runtime_middlewares(app_config=resolved_app_config, lazy_init=True)  # 1-12 共享基座
    # ... 13-23 DynamicContext / SkillActivation / DurableContext / Summarization /
    #       TodoList / TokenUsage / Title / Memory / ViewImage / DeferredToolFilter /
    #       SystemMessageCoalescing ...
    subagent_enabled = cfg.get("subagent_enabled", False)
    if subagent_enabled:
        max_concurrent_subagents = cfg.get("max_concurrent_subagents", 3)
        middlewares.append(SubagentLimitMiddleware(max_concurrent=max_concurrent_subagents))      # 24?

    # LoopDetectionMiddleware — detect and break repetitive tool call loops
    loop_detection_config = resolved_app_config.loop_detection
    if loop_detection_config.enabled:
        middlewares.append(LoopDetectionMiddleware.from_config(loop_detection_config))            # 25?

    # TokenBudgetMiddleware - enforce per-run token limits
    token_budget_config = resolved_app_config.token_budget
    if token_budget_config.enabled:
        from helix.agents.middlewares.token_budget_middleware import TokenBudgetMiddleware
        middlewares.append(TokenBudgetMiddleware.from_config(token_budget_config))                # 26?

    # Inject custom middlewares before ClarificationMiddleware
    if custom_middlewares:
        middlewares.extend(custom_middlewares)                                                    # 27

    # SafetyFinishReasonMiddleware — registered after custom so reverse-order after_model
    # runs Safety first; cleared tool_calls flow through Loop/Subagent accounting.
    safety_config = resolved_app_config.safety_finish_reason
    if safety_config.enabled:
        middlewares.append(SafetyFinishReasonMiddleware.from_config(safety_config))               # 28?

    # ClarificationMiddleware should always be last
    middlewares.append(ClarificationMiddleware())                                                 # 29
    return middlewares
```
