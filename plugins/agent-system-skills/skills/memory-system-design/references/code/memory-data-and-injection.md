# 完整源码：存储 + 注入格式化 + 注入接线

> 本文件给出记忆系统的**读/写存储**与**注入格式化**全貌。SKILL.md 设计方案段给了原子写与两阶段预算的伪代码；此处给 `FileMemoryStorage` 全貌、token 计数、格式辅助（`_select_fact_lines` 等）、`format_memory_for_injection` 主函数全貌、`_get_memory_context` 注入接线的完整真实源码。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`），去除一切项目字样。原代码注释保留以保真。

## 1. 存储抽象与文件实现

```python
# core/helix/agents/memory/storage.py
"""Memory storage providers."""

import abc
import json
import logging
import threading
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from helix.config.agents_config import AGENT_NAME_PATTERN
from helix.config.memory_config import get_memory_config
from helix.config.paths import get_paths

logger = logging.getLogger(__name__)


def utc_now_iso_z() -> str:
    """Current UTC time as ISO-8601 with ``Z`` suffix (matches prior naive-UTC output)."""
    return datetime.now(UTC).isoformat().removesuffix("+00:00") + "Z"


def create_empty_memory() -> dict[str, Any]:
    """Create an empty memory structure."""
    return {
        "version": "1.0",
        "lastUpdated": utc_now_iso_z(),
        "user": {
            "workContext": {"summary": "", "updatedAt": ""},
            "personalContext": {"summary": "", "updatedAt": ""},
            "topOfMind": {"summary": "", "updatedAt": ""},
        },
        "history": {
            "recentMonths": {"summary": "", "updatedAt": ""},
            "earlierContext": {"summary": "", "updatedAt": ""},
            "longTermBackground": {"summary": "", "updatedAt": ""},
        },
        "facts": [],
    }


class MemoryStorage(abc.ABC):
    """Abstract base class for memory storage providers."""

    @abc.abstractmethod
    def load(self, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
        """Load memory data for the given agent."""
        pass

    @abc.abstractmethod
    def reload(self, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
        """Force reload memory data for the given agent."""
        pass

    @abc.abstractmethod
    def save(self, memory_data: dict[str, Any], agent_name: str | None = None, *, user_id: str | None = None) -> bool:
        """Save memory data for the given agent."""
        pass


class FileMemoryStorage(MemoryStorage):
    """File-based memory storage provider."""

    def __init__(self):
        """Initialize the file memory storage."""
        # Per-user/agent memory cache: keyed by (user_id, agent_name) tuple (None = global)
        # Value: (memory_data, file_mtime)
        self._memory_cache: dict[tuple[str | None, str | None], tuple[dict[str, Any], float | None]] = {}
        # Guards all reads and writes to _memory_cache across concurrent callers.
        self._cache_lock = threading.Lock()

    def _validate_agent_name(self, agent_name: str) -> None:
        """Validate that the agent name is safe to use in filesystem paths.

        Uses the repository's established AGENT_NAME_PATTERN to ensure consistency
        across the codebase and prevent path traversal or other problematic characters.
        """
        if not agent_name:
            raise ValueError("Agent name must be a non-empty string.")
        if not AGENT_NAME_PATTERN.match(agent_name):
            raise ValueError(f"Invalid agent name {agent_name!r}: names must match {AGENT_NAME_PATTERN.pattern}")

    def _get_memory_file_path(self, agent_name: str | None = None, *, user_id: str | None = None) -> Path:
        """Get the path to the memory file."""
        if user_id is not None:
            if agent_name is not None:
                self._validate_agent_name(agent_name)
                return get_paths().user_agent_memory_file(user_id, agent_name)
            config = get_memory_config()
            if config.storage_path and Path(config.storage_path).is_absolute():
                return Path(config.storage_path)
            return get_paths().user_memory_file(user_id)
        # Legacy: no user_id
        if agent_name is not None:
            self._validate_agent_name(agent_name)
            return get_paths().agent_memory_file(agent_name)
        config = get_memory_config()
        if config.storage_path:
            p = Path(config.storage_path)
            return p if p.is_absolute() else get_paths().base_dir / p
        return get_paths().memory_file

    def _load_memory_from_file(self, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
        """Load memory data from file."""
        file_path = self._get_memory_file_path(agent_name, user_id=user_id)

        if not file_path.exists():
            return create_empty_memory()

        try:
            with open(file_path, encoding="utf-8") as f:
                data = json.load(f)
            return data
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("Failed to load memory file: %s", e)
            return create_empty_memory()

    @staticmethod
    def _cache_key(agent_name: str | None = None, *, user_id: str | None = None) -> tuple[str | None, str | None]:
        return (user_id, agent_name)

    def load(self, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
        """Load memory data (cached with file modification time check)."""
        file_path = self._get_memory_file_path(agent_name, user_id=user_id)
        cache_key = self._cache_key(agent_name, user_id=user_id)

        try:
            current_mtime = file_path.stat().st_mtime if file_path.exists() else None
        except OSError:
            current_mtime = None

        with self._cache_lock:
            cached = self._memory_cache.get(cache_key)
            if cached is not None and cached[1] == current_mtime:
                return cached[0]

        memory_data = self._load_memory_from_file(agent_name, user_id=user_id)

        with self._cache_lock:
            self._memory_cache[cache_key] = (memory_data, current_mtime)

        return memory_data

    def reload(self, agent_name: str | None = None, *, user_id: str | None = None) -> dict[str, Any]:
        """Reload memory data from file, forcing cache invalidation."""
        file_path = self._get_memory_file_path(agent_name, user_id=user_id)
        memory_data = self._load_memory_from_file(agent_name, user_id=user_id)
        cache_key = self._cache_key(agent_name, user_id=user_id)

        try:
            mtime = file_path.stat().st_mtime if file_path.exists() else None
        except OSError:
            mtime = None

        with self._cache_lock:
            self._memory_cache[cache_key] = (memory_data, mtime)
        return memory_data

    def save(self, memory_data: dict[str, Any], agent_name: str | None = None, *, user_id: str | None = None) -> bool:
        """Save memory data to file and update cache."""
        file_path = self._get_memory_file_path(agent_name, user_id=user_id)
        cache_key = self._cache_key(agent_name, user_id=user_id)

        try:
            file_path.parent.mkdir(parents=True, exist_ok=True)
            # Shallow-copy before adding lastUpdated so the caller's dict is not
            # mutated as a side-effect, and the cache reference is not silently
            # updated before the file write succeeds.
            memory_data = {**memory_data, "lastUpdated": utc_now_iso_z()}

            temp_path = file_path.with_suffix(f".{uuid.uuid4().hex}.tmp")
            with open(temp_path, "w", encoding="utf-8") as f:
                json.dump(memory_data, f, indent=2, ensure_ascii=False)

            temp_path.replace(file_path)

            try:
                mtime = file_path.stat().st_mtime
            except OSError:
                mtime = None

            with self._cache_lock:
                self._memory_cache[cache_key] = (memory_data, mtime)
            logger.info("Memory saved to %s", file_path)
            return True
        except OSError as e:
            logger.error("Failed to save memory file: %s", e)
            return False


_storage_instance: MemoryStorage | None = None
_storage_lock = threading.Lock()


def get_memory_storage() -> MemoryStorage:
    """Get the configured memory storage instance."""
    global _storage_instance
    if _storage_instance is not None:
        return _storage_instance

    with _storage_lock:
        if _storage_instance is not None:
            return _storage_instance

        config = get_memory_config()
        storage_class_path = config.storage_class

        try:
            module_path, class_name = storage_class_path.rsplit(".", 1)
            import importlib

            module = importlib.import_module(module_path)
            storage_class = getattr(module, class_name)

            # Validate that the configured storage is a MemoryStorage implementation
            if not isinstance(storage_class, type):
                raise TypeError(f"Configured memory storage '{storage_class_path}' is not a class: {storage_class!r}")
            if not issubclass(storage_class, MemoryStorage):
                raise TypeError(f"Configured memory storage '{storage_class_path}' is not a subclass of MemoryStorage")

            _storage_instance = storage_class()
        except Exception as e:
            logger.error(
                "Failed to load memory storage %s, falling back to FileMemoryStorage: %s",
                storage_class_path,
                e,
            )
            _storage_instance = FileMemoryStorage()

    return _storage_instance
```

**要点**：

- `_get_memory_file_path` 的 per-user 分支：`user_id` 非空时走 `get_paths().user_memory_file(user_id)`（`{base_dir}/users/{user_id}/memory.json`）；`agent_name` 也非空时走 `user_agent_memory_file`（`.../users/{user_id}/agents/{name}/memory.json`）。`storage_path` 绝对路径是显式 opt-out per-user 隔离（所有用户共享一文件）。
- `load` 用 mtime 做缓存校验：文件被外部改（UI 编辑）后 mtime 变，缓存自动失效重读。这让"手动 CRUD"与"LLLM 自动更新"两条写入路径不会读到过期缓存。
- `storage_class` 可插拔，加载失败回退 `FileMemoryStorage`（记忆永不因配置错误而完全不可用）。

## 2. token 计数（tiktoken 冷启动保护 + char 估算）

```python
# core/helix/agents/memory/prompt.py（token 计数部分）
from __future__ import annotations

import logging
import math
import re
import threading
import time
from typing import Any, cast

logger = logging.getLogger(__name__)

try:
    import tiktoken

    TIKTOKEN_AVAILABLE = True
except ImportError:
    TIKTOKEN_AVAILABLE = False


# Module-level tiktoken encoding cache.  Populated lazily on first use;
# subsequent calls are a dict lookup (no network I/O).  Pre-warming at
# startup via :func:`warm_tiktoken_cache` avoids blocking a request on the
# (potentially slow) first ``get_encoding`` call.
#
# A *failed* load is cached as a ``(None, monotonic_timestamp)`` tuple so that
# a network-restricted environment does not re-attempt the blocking BPE
# download on every subsequent call.  After ``_TIKTOKEN_RETRY_COOLDOWN_S`` the
# failure is allowed to expire so a transient network outage can self-heal back
# to accurate tiktoken counting without a process restart.  A load already in
# progress is cached as ``_TIKTOKEN_ENCODING_LOADING`` so concurrent callers
# fall back immediately instead of spawning more blocking
# ``tiktoken.get_encoding`` threads.  Use the ``memory.token_counting: char``
# config to skip tiktoken entirely.
_TIKTOKEN_ENCODING_MISSING = object()
_TIKTOKEN_ENCODING_LOADING = object()
# Cooldown before a *failed* tiktoken load is re-attempted. This is an internal
# tuning constant rather than a user-facing config: it only affects how quickly
# the default ``tiktoken`` mode self-heals after a transient network outage.
# Deployments that want to avoid tiktoken's network dependency entirely should
# set ``memory.token_counting: char`` instead of tuning this value.
_TIKTOKEN_RETRY_COOLDOWN_S = 600.0
_tiktoken_encoding_cache: dict[str, Any] = {}
_tiktoken_encoding_cache_lock = threading.Lock()


def _get_tiktoken_encoding(encoding_name: str = "cl100k_base") -> tiktoken.Encoding | None:
    """Return a cached tiktoken encoding, or ``None`` on failure / unavailability.

    On the very first call for a given *encoding_name*, tiktoken may need to
    download the BPE data from ``openaipublic.blob.core.windows.net``.  In
    network-restricted environments (e.g. deployments behind the GFW) this
    download can block for tens of minutes before the OS TCP timeout kicks in.
    The caller must therefore be prepared for this to block and should run it
    off the event loop (e.g. via ``asyncio.to_thread``).

    A failed load is remembered (with a timestamp) so subsequent calls fall
    back immediately to character-based estimation instead of re-triggering the
    blocking download. The failure expires after ``_TIKTOKEN_RETRY_COOLDOWN_S``
    so a transient outage can self-heal without a restart. A load already in
    progress is also remembered so that a timed-out caller does not leave a
    window where later requests start more blocking ``get_encoding`` calls.
    """
    if not TIKTOKEN_AVAILABLE:
        return None

    with _tiktoken_encoding_cache_lock:
        cached = _tiktoken_encoding_cache.get(encoding_name, _TIKTOKEN_ENCODING_MISSING)
        if cached is _TIKTOKEN_ENCODING_LOADING:
            return None
        if isinstance(cached, tuple):
            # Cached failure: (None, failed_at). Retry only after cooldown.
            _, failed_at = cached
            if time.monotonic() - failed_at < _TIKTOKEN_RETRY_COOLDOWN_S:
                return None
            cached = _TIKTOKEN_ENCODING_MISSING
        if cached is not _TIKTOKEN_ENCODING_MISSING:
            return cast("tiktoken.Encoding", cached)
        _tiktoken_encoding_cache[encoding_name] = _TIKTOKEN_ENCODING_LOADING

    try:
        encoding = tiktoken.get_encoding(encoding_name)
    except Exception:
        logger.warning("Failed to load tiktoken encoding %r; falling back to char-based estimation", encoding_name, exc_info=True)
        with _tiktoken_encoding_cache_lock:
            _tiktoken_encoding_cache[encoding_name] = (None, time.monotonic())
        return None

    with _tiktoken_encoding_cache_lock:
        _tiktoken_encoding_cache[encoding_name] = encoding
    return encoding


def _char_based_token_estimate(text: str) -> int:
    """Network-free token estimate that accounts for CJK density.

    The plain ``len(text) // 4`` heuristic is reasonable for English/code
    (~4 chars per token) but significantly under-estimates token counts for
    Chinese, Japanese, and Korean text, where the ratio is closer to 1.5-2
    characters per token. Counting CJK characters separately (~2 chars per
    token) avoids over-filling the injection budget for CJK-heavy memory
    content.
    """
    cjk = sum(
        1
        for ch in text
        if "一" <= ch <= "鿿"  # CJK Unified Ideographs
        or "぀" <= ch <= "ヿ"  # Hiragana + Katakana
        or "가" <= ch <= "힣"  # Hangul syllables
    )
    return (len(text) - cjk) // 4 + cjk // 2


def _count_tokens(text: str, encoding_name: str = "cl100k_base", *, use_tiktoken: bool = True) -> int:
    """Count tokens in text using tiktoken.

    Args:
        text: The text to count tokens for.
        encoding_name: The encoding to use (default: cl100k_base for GPT-4/3.5).
        use_tiktoken: When ``False``, skip tiktoken entirely and use the
            network-free character-based estimate. This guarantees no BPE
            download is attempted (see ``memory.token_counting`` config).

    Returns:
        The number of tokens in the text.
    """
    if not use_tiktoken:
        return _char_based_token_estimate(text)

    encoding = _get_tiktoken_encoding(encoding_name)
    if encoding is None:
        # Fallback to CJK-aware character estimation if tiktoken is not
        # available or the encoding failed to load.
        return _char_based_token_estimate(text)

    try:
        return len(encoding.encode(text))
    except Exception:
        # Fallback to CJK-aware character estimation on error.
        return _char_based_token_estimate(text)


def warm_tiktoken_cache() -> bool:
    """Pre-warm the tiktoken encoding cache.

    Call at startup (off the event loop) so the first request never blocks
    on the BPE download.  Returns ``True`` if the encoding was loaded
    successfully (or was already cached), ``False`` if tiktoken is
    unavailable or the download failed.
    """
    return _get_tiktoken_encoding("cl100k_base") is not None
```

**要点**：

- 三态缓存：`_TIKTOKEN_ENCODING_MISSING`（未加载）-> `_TIKTOKEN_ENCODING_LOADING`（加载中，并发 caller 立即 fallback）-> `Encoding`（成功）/ `(None, failed_at)`（失败 + 冷却时间戳）。
- 失败缓存 600s 冷却：网络受限环境首次 BPE 下载卡死后，600s 内不再重试（直接 char 估算），避免每请求都卡；冷却到期后允许重试，瞬时网络故障可自愈。
- `_char_based_token_estimate` 对 CJK 单独算（~2 字符/token），避免中文记忆内容按 `len//4` 严重低估、撑爆注入预算。
- `warm_tiktoken_cache()` 供启动期预热（`DynamicContextMiddleware.abefore_agent` 里 `asyncio.to_thread` 调用前已 offload，但首次仍可能阻塞，故预热）。

## 3. 格式辅助（guaranteed/regular 选取 + fallback）

```python
# core/helix/agents/memory/prompt.py（格式辅助部分）
def _coerce_confidence(value: Any, default: float = 0.0) -> float:
    """Coerce a confidence-like value to a bounded float in [0, 1].

    Non-finite values (NaN, inf, -inf) are treated as invalid and fall back
    to the default before clamping, preventing them from dominating ranking.
    The ``default`` parameter is assumed to be a finite value.
    """
    try:
        confidence = float(value)
    except (TypeError, ValueError):
        return max(0.0, min(1.0, default))
    if not math.isfinite(confidence):
        return max(0.0, min(1.0, default))
    return max(0.0, min(1.0, confidence))


def _format_fact_line(fact: dict[str, Any]) -> str | None:
    """Build a single formatted fact line, or return ``None`` for invalid facts.

    Extracted as a shared helper so the guaranteed-injection and regular-injection
    paths produce identical line formatting.
    """
    content_value = fact.get("content")
    if not isinstance(content_value, str):
        return None
    content = content_value.strip()
    if not content:
        return None
    category = str(fact.get("category", "context")).strip() or "context"
    confidence = _coerce_confidence(fact.get("confidence"), default=0.0)
    source_error = fact.get("sourceError")
    if category == "correction" and isinstance(source_error, str) and source_error.strip():
        return f"- [{category} | {confidence:.2f}] {content} (avoid: {source_error.strip()})"
    return f"- [{category} | {confidence:.2f}] {content}"


def _select_fact_lines(
    ranked_facts: list[dict[str, Any]],
    *,
    token_budget: int,
    use_tiktoken: bool,
) -> tuple[list[str], int]:
    """Greedily select formatted fact lines within a *line-only* token budget.

    This function is intentionally **header-agnostic**: it counts only the
    fact lines themselves (including ``\\n`` separators between lines).  The
    caller is responsible for reserving tokens for the ``"Facts:\\n"`` header
    and any inter-section ``"\\n\\n"`` separator *before* calling this
    function, and passing the remaining capacity as *token_budget*.

    Stops at the first fact that would exceed the budget so the caller's
    pre-sorted order (typically confidence-descending) is preserved strictly:
    a shorter lower-ranked fact can never slip ahead of a skipped
    higher-ranked one.

    Args:
        ranked_facts: Facts pre-sorted by the caller's preferred ranking.
        token_budget: Maximum tokens available for fact lines only.
        use_tiktoken: Whether to use tiktoken for counting.

    Returns:
        ``(selected_lines, consumed_tokens)`` - *consumed_tokens* is the
        exact token cost of the returned lines (including inter-line
        ``\\n`` separators, but *not* a leading header).
    """
    lines: list[str] = []
    consumed = 0
    for fact in ranked_facts:
        formatted = _format_fact_line(fact)
        if formatted is None:
            continue
        line_text = ("\n" + formatted) if lines else formatted
        line_tokens = _count_tokens(line_text, use_tiktoken=use_tiktoken)
        if consumed + line_tokens > token_budget:
            break
        lines.append(formatted)
        consumed += line_tokens
    return lines, consumed


def _fallback_format_facts(
    valid_facts: list[dict[str, Any]],
    *,
    preceding_section_cost: int,
    max_tokens: int,
    use_tiktoken: bool,
) -> tuple[str, list[str]] | tuple[None, None]:
    """Confidence-only ranking used when the primary path raises an exception.

    Returns a tuple ``(section_text, fact_lines)`` where ``section_text`` is the
    formatted ``"Facts:\\n..."`` section string (without any leading inter-section
    separator - the caller owns that), and ``fact_lines`` are the individual lines
    that make up the facts block.  Both elements are ``None`` if no facts survive.

    Returning the lines separately lets the caller track them for the
    structure-aware safety truncation so fallback facts enjoy the same
    protected-suffix treatment as facts emitted by the primary path.

    *valid_facts* is the already-filtered fact list built by the primary path so
    the fallback does not redo validation work.  *preceding_section_cost* is the
    tokens already consumed by user-context / history sections (used to derive
    the remaining budget).
    """
    ranked = sorted(valid_facts, key=lambda f: _coerce_confidence(f.get("confidence"), default=0.0), reverse=True)

    header = "Facts:\n"
    overhead = _count_tokens(header, use_tiktoken=use_tiktoken)
    line_budget = max_tokens - preceding_section_cost - overhead
    if line_budget <= 0:
        return None, None

    lines, _ = _select_fact_lines(ranked, token_budget=line_budget, use_tiktoken=use_tiktoken)
    if not lines:
        return None, None
    return header + "\n".join(lines), lines
```

**要点**：

- `_select_fact_lines` 是 header-agnostic 的：只算事实行（含行间 `\n`），header 与段间分隔符由调用方 `format_memory_for_injection` 扣预算。这让 guaranteed 与 regular 两阶段复用同一选取逻辑。
- 选取在第一个超预算事实处 `break`，严格保留调用方排序（confidence 降序）--矮的低排名事实不能插到被跳过的高排名事实前面。
- `_fallback_format_facts` 在主路径异常时接管：单预算 confidence 排序，且把选出的 `lines` 回传给 `format_memory_for_injection` 的 `all_fact_lines`，让结构感知截断把 fallback 事实也当受保护后缀。

## 4. 注入格式化主函数（format_memory_for_injection）

```python
# core/helix/agents/memory/prompt.py（注入格式化主函数）
def format_memory_for_injection(
    memory_data: dict[str, Any],
    max_tokens: int = 2000,
    *,
    use_tiktoken: bool = True,
    guaranteed_categories: list[str] | None = None,
    guaranteed_token_budget: int = 500,
) -> str:
    """Format memory data for injection into system prompt.

    Args:
        memory_data: The memory data dictionary.
        max_tokens: Maximum tokens to use (counted via tiktoken for accuracy).
        use_tiktoken: When ``False``, all token counting uses the network-free
            character-based estimate instead of tiktoken (see
            ``memory.token_counting`` config). Defaults to ``True``.
        guaranteed_categories: Fact categories that must always be injected
            regardless of the regular token budget. These facts draw from a
            separate *guaranteed_token_budget*. When ``None`` or empty, all
            facts compete for the same budget (original behaviour).
        guaranteed_token_budget: Token ceiling for the guaranteed section.
            In the common case the guaranteed lines *displace* regular lines
            within *max_tokens* (the total output stays <= ``max_tokens``);
            the budget becomes truly additive only when the guaranteed lines
            alone would push the assembled output past *max_tokens*, at which
            point the safety-truncation ceiling is raised to
            ``max_tokens + guaranteed_actual_usage`` to protect them.
            Ignored when *guaranteed_categories* is ``None`` or empty.

    Returns:
        Formatted memory string for system prompt injection.
    """
    if not memory_data:
        return ""

    # Reject a bare string explicitly: iterating a ``str`` yields single
    # characters, which would silently produce a meaningless frozenset of
    # letters and turn the guarantee off without any warning.  Config-layer
    # callers go through Pydantic (which enforces ``list[str]``), so this
    # only guards the public helper surface.
    if isinstance(guaranteed_categories, str):
        raise TypeError("guaranteed_categories must be an iterable of strings, not a bare str")
    effective_guaranteed: frozenset[str] = frozenset(c.strip() for c in guaranteed_categories if isinstance(c, str) and c.strip()) if guaranteed_categories else frozenset()

    sections: list[str] = []

    # Format user context
    user_data = memory_data.get("user", {})
    if user_data:
        user_sections = []

        work_ctx = user_data.get("workContext", {})
        if work_ctx.get("summary"):
            user_sections.append(f"Work: {work_ctx['summary']}")

        personal_ctx = user_data.get("personalContext", {})
        if personal_ctx.get("summary"):
            user_sections.append(f"Personal: {personal_ctx['summary']}")

        top_of_mind = user_data.get("topOfMind", {})
        if top_of_mind.get("summary"):
            user_sections.append(f"Current Focus: {top_of_mind['summary']}")

        if user_sections:
            sections.append("User Context:\n" + "\n".join(f"- {s}" for s in user_sections))

    # Format history
    history_data = memory_data.get("history", {})
    if history_data:
        history_sections = []

        recent = history_data.get("recentMonths", {})
        if recent.get("summary"):
            history_sections.append(f"Recent: {recent['summary']}")

        earlier = history_data.get("earlierContext", {})
        if earlier.get("summary"):
            history_sections.append(f"Earlier: {earlier['summary']}")

        background = history_data.get("longTermBackground", {})
        if background.get("summary"):
            history_sections.append(f"Background: {background['summary']}")

        if history_sections:
            sections.append("History:\n" + "\n".join(f"- {s}" for s in history_sections))

    # ── Facts ────────────────────────────────────────────────────────────────
    #
    # Design notes
    # ~~~~~~~~~~~~
    # • A single ``"Facts:\\n"`` header is emitted at most once.
    # • Guaranteed-category facts are selected first from their own
    #   *guaranteed_token_budget* and placed at the front of the Facts block,
    #   so they cannot be evicted by regular facts.  In the common case the
    #   total output still fits within *max_tokens* (guaranteed lines displace
    #   regular ones); the budget becomes truly additive only when the
    #   guaranteed lines alone push the output past *max_tokens*, in which
    #   case the safety-truncation ceiling is raised accordingly.
    # • Regular facts draw from *max_tokens* only.
    # • All token accounting (header, separators, lines) is performed here
    #   in the caller; the ``_select_fact_lines`` helper is header-agnostic.
    # • When the primary path raises any exception, ``_fallback_format_facts``
    #   performs a single-pass confidence-only ranking.
    facts_data = memory_data.get("facts", [])
    guaranteed_line_tokens = 0  # used later for the effective truncation limit
    if isinstance(facts_data, list) and facts_data:
        # Token cost of sections built above (user context, history).
        base_text = "\n\n".join(sections)
        base_tokens = _count_tokens(base_text, use_tiktoken=use_tiktoken) if base_text else 0

        # Pre-filter valid facts *before* entering the try so the except
        # path can pass the same list straight into the fallback without
        # redoing validation work on the hot prompt-injection path.
        valid_facts = [f for f in facts_data if isinstance(f, dict) and isinstance(f.get("content"), str) and f.get("content", "").strip()]

        # Initialise the facts-block markers *before* the try so the
        # structure-aware truncation at the bottom of the function can
        # reason about them regardless of whether the primary path or
        # the except/fallback path produced the final Facts section.
        facts_header = "Facts:\n"
        all_fact_lines: list[str] = []

        try:
            # Partition valid facts into guaranteed vs regular groups.
            # Use the *raw* category field (no ``or "context"`` default) so
            # a category-less legacy fact is never silently promoted into
            # a guaranteed pool whose operator configured
            # ``guaranteed_categories=["context"]``.  Missing-category facts
            # always fall through to the regular path.
            def _confidence_key(fact: dict[str, Any]) -> float:
                return _coerce_confidence(fact.get("confidence"), default=0.0)

            if effective_guaranteed:

                def _category_match(fact: dict[str, Any]) -> bool:
                    raw = fact.get("category")
                    if not isinstance(raw, str):
                        return False
                    cat = raw.strip()
                    return bool(cat) and cat in effective_guaranteed

                guaranteed = sorted(
                    [f for f in valid_facts if _category_match(f)],
                    key=_confidence_key,
                    reverse=True,
                )
                regular = sorted(
                    [f for f in valid_facts if not _category_match(f)],
                    key=_confidence_key,
                    reverse=True,
                )
            else:
                guaranteed = []
                regular = sorted(valid_facts, key=_confidence_key, reverse=True)

            # ── Phase 1: select guaranteed lines ──────────────────────────
            header_cost = _count_tokens(facts_header, use_tiktoken=use_tiktoken)

            guaranteed_lines: list[str] = []
            if guaranteed:
                guaranteed_line_budget = guaranteed_token_budget
                guaranteed_lines, guaranteed_line_tokens = _select_fact_lines(
                    guaranteed,
                    token_budget=guaranteed_line_budget,
                    use_tiktoken=use_tiktoken,
                )

            # ── Phase 2: select regular lines ────────────────────────────
            # Regular facts compete for *max_tokens* (the main budget).
            # Subtract everything already accounted for:
            #   base sections + inter-section separator + header
            #   + guaranteed lines + the inter-group ``\n`` that joins the
            #   regular block to the guaranteed block (when both are present).
            regular_lines: list[str] = []
            if regular:
                inter_group_newline_tokens = _count_tokens("\n", use_tiktoken=use_tiktoken) if guaranteed_lines else 0
                used_before_regular = base_tokens + header_cost + guaranteed_line_tokens + inter_group_newline_tokens
                regular_line_budget = max_tokens - used_before_regular
                if regular_line_budget > 0:
                    regular_lines, _ = _select_fact_lines(
                        regular,
                        token_budget=regular_line_budget,
                        use_tiktoken=use_tiktoken,
                    )

            # ── Emit a single "Facts:" section ───────────────────────────
            # Leading inter-section separator is NOT embedded here; the
            # final ``"\n\n".join(sections)`` is the single source of truth
            # for section-to-section spacing, preventing the prior
            # double-``\n\n`` bug.
            all_fact_lines = guaranteed_lines + regular_lines
            if all_fact_lines:
                section_text = facts_header + "\n".join(all_fact_lines)
                sections.append(section_text)

        except Exception:
            # ── Fallback: confidence-only ranking, single budget ─────────
            # Any unexpected error in the partition / guaranteed path must
            # not prevent memory injection entirely.  Fall back to the
            # original single-pass confidence ranking.  Re-use the
            # pre-filtered ``valid_facts`` so we don't redo validation work
            # on the hot fallback path.
            logger.warning(
                "Memory injection: guaranteed-category path failed, falling back to confidence-only ranking",
                exc_info=True,
            )
            fallback, fallback_lines = _fallback_format_facts(
                valid_facts,
                preceding_section_cost=base_tokens,
                max_tokens=max_tokens,
                use_tiktoken=use_tiktoken,
            )
            if fallback:
                sections.append(fallback)
                # Surface the fallback's lines to ``all_fact_lines`` so the
                # structure-aware truncation below treats fallback facts as a
                # protected suffix too.  Without this, a large user-context
                # prefix could silently clip fallback facts via the original
                # prefix-cut.
                all_fact_lines = fallback_lines

    if not sections:
        return ""

    result = "\n\n".join(sections)

    token_count = _count_tokens(result, use_tiktoken=use_tiktoken)
    effective_limit = max_tokens + guaranteed_line_tokens
    if token_count > effective_limit:
        # Structure-aware truncation: the ``Facts:\n...`` block is treated as
        # a *protected suffix* so guaranteed-category facts - the very facts
        # this PR exists to preserve - can never be silently discarded by a
        # prefix-cut on overflow.  Only the preceding (user-context / history)
        # sections are eligible for truncation; if they alone exceed the
        # budget available after reserving the Facts block, they are clipped
        # from the tail.  When *guaranteed_line_tokens* is zero (no
        # guaranteed categories configured or no facts survived), the
        # equation collapses to the original prefix-truncation against
        # ``max_tokens``, so backward compatibility is preserved.
        facts_block = (facts_header + "\n".join(all_fact_lines)) if all_fact_lines else ""
        facts_block_tokens = _count_tokens(facts_block, use_tiktoken=use_tiktoken)
        separator_tokens = _count_tokens("\n\n", use_tiktoken=use_tiktoken)
        budget_for_non_facts = max(
            0,
            effective_limit - facts_block_tokens - (separator_tokens if facts_block else 0),
        )

        # Build the preceding (non-facts) portion from *sections* excluding
        # the trailing Facts block.
        preceding_sections = sections[:-1] if all_fact_lines else sections
        preceding = "\n\n".join(preceding_sections)

        if preceding:
            preceding_tokens = _count_tokens(preceding, use_tiktoken=use_tiktoken)
            if preceding_tokens > budget_for_non_facts:
                char_per_token = len(preceding) / max(preceding_tokens, 1)
                target_chars = int(budget_for_non_facts * char_per_token * 0.95)
                preceding = preceding[:target_chars].rstrip() + "\n..."
            result = (preceding + "\n\n" + facts_block) if facts_block else preceding
        else:
            result = facts_block

    return result
```

**要点**：

- **两阶段选取**：guaranteed 事实先从独立预算 `guaranteed_token_budget` 选（confidence 降序），放 Facts 块最前；regular 事实从 `max_tokens` 扣除已占用（base + header + guaranteed + 组间 `\n`）后选。guaranteed 行挤占 regular 行，总输出常见情况 ≤ `max_tokens`。
- **裸字符串守卫**：`isinstance(guaranteed_categories, str)` 显式 `TypeError`，防迭代 `str` 产出单字符 frozenset 静默关闭 guarantee。
- **结构感知截断**：`effective_limit = max_tokens + guaranteed_line_tokens`（仅 guaranteed 行自身超 `max_tokens` 时叠加）。超预算时 Facts 块是受保护后缀，只截前面的 base 段（按 `char_per_token` 比例裁到 0.95 倍 + `"\n..."`）。`guaranteed_line_tokens = 0` 时退化为原始前缀截断，向后兼容。
- **fallback 路径**：主路径任何异常都触发 `_fallback_format_facts`（单预算 confidence 排序），选出的 `lines` 回传 `all_fact_lines` 让结构感知截断把 fallback 事实也当受保护后缀。
- **raw category 不默认**：`_category_match` 用 raw `category` 字段（无 `or "context"` 默认），避免无类目的旧事实被误提升进 `guaranteed_categories=["context"]` 的保底池。

## 5. 注入接线（_get_memory_context）

```python
# core/helix/agents/lead/prompt.py
def _get_memory_context(agent_name: str | None = None, *, app_config: AppConfig | None = None) -> str:
    """Get memory context for injection into system prompt.

    Args:
        agent_name: If provided, loads per-agent memory. If None, loads global memory.
        app_config: Explicit application config. When provided, memory options
            are read from this value instead of the global config singleton.

    Returns:
        Formatted memory context string wrapped in XML tags, or empty string if disabled.
    """
    try:
        from helix.agents.memory import format_memory_for_injection, get_memory_data
        from helix.runtime.user_context import get_effective_user_id

        if app_config is None:
            from helix.config.memory_config import get_memory_config

            config = get_memory_config()
        else:
            config = app_config.memory

        if not config.enabled or not config.injection_enabled:
            return ""

        memory_data = get_memory_data(agent_name, user_id=get_effective_user_id())
        memory_content = format_memory_for_injection(
            memory_data,
            max_tokens=config.max_injection_tokens,
            use_tiktoken=(config.token_counting == "tiktoken"),
            guaranteed_categories=getattr(config, "guaranteed_categories", None),
            guaranteed_token_budget=getattr(config, "guaranteed_token_budget", 500),
        )

        if not memory_content.strip():
            return ""

        return f"""<memory>
{memory_content}
</memory>
"""
    except Exception:
        logger.exception("Failed to load memory context")
        return ""
```

**要点**：

- `_get_memory_context` 是记忆系统与注入中间件的**唯一接线点**：`DynamicContextMiddleware._build_full_reminder` 调用它，把返回的 `<memory>...</memory>` 块放进一条 `HumanMessage`（角色分离，见 [[system-prompt-template]]）。
- `user_id=get_effective_user_id()` 在此解析--这是 `DynamicContextMiddleware.abefore_agent` 里 `asyncio.to_thread` 的线程中调用，`user_context` contextvar 由请求线程设置、`to_thread` 会传播 contextvar（与 `threading.Timer` 不同），故此处可直接读。
- `getattr(config, "guaranteed_categories", None)` 容错：旧配置可能无此字段，`None` 时 `format_memory_for_injection` 退化为原始单预算行为。
- 整个函数包在 `try/except` 里：记忆加载/格式化任何异常都返回空串，**永不阻塞注入**（记忆是增强，不是必需）。

## 进一步阅读

- 防抖队列 + LLM 抽取源码：[extract-and-debounce.md](./extract-and-debounce.md)
- 完整配置 + 预算数学：[config-and-budget.md](./config-and-budget.md)
- 注入中间件（消费 `_get_memory_context` 的地方）：[[system-prompt-template]]
- per-user 路径解析（`get_paths().user_memory_file`）：[[multi-user-isolation]]
