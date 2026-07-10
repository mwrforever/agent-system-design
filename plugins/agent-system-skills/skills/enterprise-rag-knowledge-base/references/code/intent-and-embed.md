# 完整源码：IntentAnalyzer 查询重写 + 双向量 Embedder（core/helix/rag/）

> 本文件给出查询重写与双向量 embedding 的完整源码。`IntentAnalyzer` 把 session 上下文 + 当前消息交给 LLM 拆成 N×TypedQuery。`EmbedResult`/`EmbedderBase`/`CompositeHybridEmbedder` 支撑 dense+sparse 双向量一次产出。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.rag.*`）。原代码注释保留以保真。

## §1 IntentAnalyzer 查询重写（core/helix/rag/retrieve/intent_analyzer.py）

```python
# core/helix/rag/retrieve/intent_analyzer.py
"""
Intent analyzer for Helix RAG retrieval.

Analyzes session context to generate query plans.
"""

from typing import Any, List, Optional

from helix.rag.message import Message
from helix.rag.prompts import render_prompt
from helix.rag.retrieve.types import ContextType, QueryPlan, TypedQuery
from helix.rag.config import get_helix_rag_config
from helix.rag.utils.llm import parse_json_from_response
from helix.rag.utils.logger import get_logger

logger = get_logger(__name__)

DEFAULT_INTENT_ANALYSIS_PROMPT = "retrieval.intent_analysis"

# Model-specific query-planner prompts. Models not listed here keep using the
# default intent-analysis prompt for backward compatibility.
# 按 planner 模型路由 prompt id：SFT 小模型用紧凑 prompt 契约，通用模型用默认。
QUERY_PLANNER_PROMPT_BY_MODEL: dict[str, str] = {
    "ollama/guoxuter/helix_intent_analysis_sft:v4_q8": "retrieval.helix_intent_analysis_sft_v4",
}


def resolve_intent_analysis_prompt_id(query_planner: Any) -> str:
    """Return the prompt id expected by the configured query-planner model.

    按 planner 模型名查 QUERY_PLANNER_PROMPT_BY_MODEL，未命中走默认 prompt。
    """
    model = getattr(query_planner, "model", None)
    if not isinstance(model, str):
        return DEFAULT_INTENT_ANALYSIS_PROMPT
    return QUERY_PLANNER_PROMPT_BY_MODEL.get(model.strip(), DEFAULT_INTENT_ANALYSIS_PROMPT)


class IntentAnalyzer:
    """
    Intent analyzer: generates query plans from session context.

    Responsibilities:
    1. Integrate session context (compression + recent messages + current message)
    2. Call LLM to analyze intent
    3. Generate multiple TypedQueries for memory/resources/skill

    查询重写是检索的入口，不是可选优化：用户自然语言往往多意图混合，
    LLM 拆成多条带 context_type 的 TypedQuery，每条进各自 root 目录单独检索后合并。
    0 条 query = 无需检索（闲聊/确认）。
    """

    # Limit content length (about 10000 tokens)
    MAX_COMPRESSION_SUMMARY_CHARS = 30000

    def __init__(self, max_recent_messages: int = 5):
        """Initialize intent analyzer."""
        self.max_recent_messages = max_recent_messages

    async def analyze(
        self,
        compression_summary: str,
        messages: List[Message],
        current_message: Optional[str] = None,
        context_type: Optional[ContextType] = None,
        target_abstract: str = "",
    ) -> QueryPlan:
        """Analyze session context and generate query plan.

        Args:
            compression_summary: Session compression summary
            messages: Session message history
            current_message: Current message (if any)
            context_type: Constrained context type (only generate queries for this type)
            target_abstract: Target directory abstract for more precise queries
        """
        # Call the lightweight query planner when configured; otherwise keep using VLM.
        config = get_helix_rag_config()
        query_planner = config.get_query_planner()

        # Build context prompt. Some fine-tuned planner models expect a compact
        # prompt/output contract, selected by exact model mapping above.
        prompt = self._build_context_prompt(
            compression_summary,
            messages,
            current_message,
            context_type,
            target_abstract,
            prompt_id=resolve_intent_analysis_prompt_id(query_planner),
        )

        response = await query_planner.get_completion_async(prompt)

        # Parse result
        parsed = parse_json_from_response(response)
        if not parsed:
            raise ValueError("Failed to parse intent analysis response")

        # Build QueryPlan
        queries = []
        for q in parsed.get("queries", []):
            try:
                context_type = ContextType(q.get("context_type", "resource"))
            except ValueError:
                context_type = ContextType.RESOURCE

            queries.append(
                TypedQuery(
                    query=q.get("query", ""),
                    context_type=context_type,
                    intent=q.get("intent", ""),
                    priority=q.get("priority", 3),
                )
            )

        # Log analysis result
        for i, q in enumerate(queries):
            logger.info(
                f'  [{i + 1}] type={q.context_type.value}, priority={q.priority}, query="{q.query}"'
            )
        logger.debug(f"[IntentAnalyzer] Reasoning: {parsed.get('reasoning', '')[:200]}...")

        return QueryPlan(
            queries=queries,
            session_context=self._summarize_context(compression_summary, current_message),
            reasoning=parsed.get("reasoning", ""),
        )

    def _build_context_prompt(
        self,
        compression_summary: str,
        messages: List[Message],
        current_message: Optional[str],
        context_type: Optional[ContextType] = None,
        target_abstract: str = "",
        prompt_id: str = DEFAULT_INTENT_ANALYSIS_PROMPT,
    ) -> str:
        """Build prompt for intent analysis.

        组装 compression_summary + recent_messages + current_message + target_abstract，
        通过 render_prompt 渲染对应 prompt id 的模板。
        """
        # Format compression info
        summary = self._truncate_text(compression_summary, self.MAX_COMPRESSION_SUMMARY_CHARS)
        summary = summary if summary else "None"

        # Format recent messages
        recent = messages[-self.max_recent_messages :] if messages else []
        recent_messages = (
            "\n".join(f"[{m.role}]: {m.content}" for m in recent if m.content) if recent else "None"
        )

        # Current message
        current = current_message if current_message else "None"

        return render_prompt(
            prompt_id,
            {
                "compression_summary": summary,
                "recent_messages": recent_messages,
                "current_message": current,
                "context_type": context_type.value if context_type else "",
                "target_abstract": target_abstract,
            },
        )

    @staticmethod
    def _truncate_text(text: str, max_chars: int) -> str:
        """Truncate text to avoid oversized prompt context."""
        if not text or len(text) <= max_chars:
            return text
        return text[: max_chars - 15] + "\n...(truncated)"

    def _summarize_context(
        self,
        compression_summary: str,
        current_message: Optional[str],
    ) -> str:
        """Generate context summary."""
        parts = []
        if compression_summary:
            parts.append(f"Session summary: {compression_summary}")
        if current_message:
            parts.append(f"Current message: {current_message[:100]}")
        return " | ".join(parts) if parts else "No context"
```

## §2 EmbedResult + EmbedderBase + CompositeHybridEmbedder（core/helix/rag/models/embedder/base.py）

```python
# core/helix/rag/models/embedder/base.py
import asyncio
import logging
import random
import time
import weakref
from abc import ABC, abstractmethod
from dataclasses import dataclass
from threading import Lock
from typing import Any, Awaitable, Callable, Dict, List, Optional, TypeVar, Union

from helix.rag.telemetry import get_current_telemetry
from helix.rag.utils.embedding_input import (
    resolve_embedding_max_input_tokens,
    truncate_embedding_input,
)
from helix.rag.utils.model_retry import retry_async, retry_sync
from helix.rag.utils import get_logger

T = TypeVar("T")
logger = get_logger(__name__)

# A multimodal embedding input is a list of content parts, e.g.
# [{"type": "text", "text": "..."}, {"type": "image_url", "image_url": {"url": "..."}}]
EmbeddingInput = Union[str, List[Dict[str, Any]]]


_token_tracker_instance = None
_ASYNC_EMBED_SEMAPHORES: "weakref.WeakKeyDictionary[asyncio.AbstractEventLoop, Dict[int, asyncio.Semaphore]]" = weakref.WeakKeyDictionary()
_ASYNC_EMBED_LOCK = Lock()


def _get_async_embed_semaphore(limit: int) -> asyncio.Semaphore:
    """按 event loop +并发限制缓存信号量，防止单 loop 内 embed 并发失控。"""
    loop = asyncio.get_running_loop()
    normalized_limit = max(1, limit)
    with _ASYNC_EMBED_LOCK:
        semaphores_by_limit = _ASYNC_EMBED_SEMAPHORES.setdefault(loop, {})
        semaphore = semaphores_by_limit.get(normalized_limit)
        if semaphore is None:
            semaphore = asyncio.Semaphore(normalized_limit)
            semaphores_by_limit[normalized_limit] = semaphore
        return semaphore


def _get_token_tracker():
    """Lazy import to avoid circular dependency."""
    global _token_tracker_instance
    if _token_tracker_instance is None:
        from helix.rag.models.vlm.token_usage import TokenUsageTracker

        _token_tracker_instance = TokenUsageTracker()
    return _token_tracker_instance


def extract_text_from_content(content: "EmbeddingInput") -> str:
    """Extract and join the text parts from a multimodal input.

    ``content`` may be a plain string (returned as-is) or a list of content
    parts such as ``[{"type": "text", "text": "..."}, {"type": "image_url", ...}]``.
    Non-text parts (e.g. images) are ignored.
    """
    if isinstance(content, str):
        return content
    text_parts = [
        part.get("text", "")
        for part in content
        if isinstance(part, dict) and part.get("type") == "text"
    ]
    return "\n".join(p for p in text_parts if p)


async def embed_compat(
    embedder: "EmbedderBase", content: "EmbeddingInput", *, is_query: bool = False
) -> "EmbedResult":
    """Prepare input, then call the embedder's async-compatible entrypoint.

    统一入口：接受纯文本或多模态输入（content parts list）。
    ``prepare_embedding_input`` 对不支持图片的 embedder 把多模态降级为文本，
    使所有 embedder 可用同一方式调用。
    """
    from helix.rag.telemetry import bind_telemetry_stage

    stage = "embed_query" if is_query else "embed_resource"
    embedding_input = embedder.prepare_embedding_input(content)
    with bind_telemetry_stage(stage):
        return await embedder.embed_async(embedding_input, is_query=is_query)


async def embed_batch_compat(
    embedder: "EmbedderBase", texts: List[str], *, is_query: bool = False
) -> List["EmbedResult"]:
    """Prepare inputs, then call the embedder's async-compatible batch entrypoint."""
    from helix.rag.telemetry import bind_telemetry_stage

    stage = "embed_query" if is_query else "embed_resource"
    embedding_inputs = embedder.prepare_embedding_inputs(texts)
    with bind_telemetry_stage(stage):
        return await embedder.embed_batch_async(embedding_inputs, is_query=is_query)


def truncate_and_normalize(embedding: List[float], dimension: Optional[int]) -> List[float]:
    """Truncate and L2 normalize embedding vector.

    截断到 dimension 并 L2 归一化，使距离可直接用作分数（cosine ↔ 内积等价）。
    """
    if not dimension or len(embedding) <= dimension:
        return embedding

    import math

    embedding = embedding[:dimension]
    norm = math.sqrt(sum(x**2 for x in embedding))
    if norm > 0:
        embedding = [x / norm for x in embedding]
    return embedding


@dataclass
class EmbedResult:
    """Embedding result that supports dense, sparse, or hybrid vectors.

    双向量结果：dense_vector（语义召回）+ sparse_vector（关键字/命名实体）。
    一次 embedding 同时产出两者，不分两次调 API。

    Attributes:
        dense_vector: Dense vector in List[float] format
        sparse_vector: Sparse vector in Dict[str, float] format, e.g. {'token1': 0.5, 'token2': 0.3}
    """

    dense_vector: Optional[List[float]] = None
    sparse_vector: Optional[Dict[str, float]] = None

    @property
    def is_dense(self) -> bool:
        """Check if result contains dense vector"""
        return self.dense_vector is not None

    @property
    def is_sparse(self) -> bool:
        """Check if result contains sparse vector"""
        return self.sparse_vector is not None

    @property
    def is_hybrid(self) -> bool:
        """Check if result is hybrid (contains both dense and sparse vectors)"""
        return self.dense_vector is not None and self.sparse_vector is not None


class EmbedderBase(ABC):
    """Base class for all embedders.

    Provides unified embedding interface supporting dense, sparse, and hybrid modes.
    """

    def __init__(self, model_name: str, config: Optional[Dict[str, Any]] = None):
        """Initialize embedder

        Args:
            model_name: Model name
            config: Configuration dict containing api_key, api_base, etc.
        """
        self.model_name = model_name
        self.config = config or {}
        self.max_input_tokens = resolve_embedding_max_input_tokens(self.config)
        self.max_retries = int(self.config.get("max_retries", 3))
        self.max_concurrent = int(self.config.get("max_concurrent", 10))
        self.provider = self.config.get("provider", "unknown")

        # Token usage tracking
        self._token_tracker = _get_token_tracker()
        self._active_call_started_at: float | None = None

    def prepare_embedding_input(self, content: "EmbeddingInput") -> "EmbeddingInput":
        """Apply this embedder's input guard before provider calls.

        纯文本截断到 max_input_tokens。支持图片的 embedder 保留多模态 list；
        不支持多模态的 embedder 提取文本部分，安全丢弃图片。
        """
        if isinstance(content, list) and self.supports_multimodal:
            if self.max_input_tokens is None:
                return content
            truncated_parts = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    part = {
                        **part,
                        "text": truncate_embedding_input(
                            part.get("text", ""), self.max_input_tokens
                        ),
                    }
                truncated_parts.append(part)
            return truncated_parts
        else:
            content = extract_text_from_content(content)
            if self.max_input_tokens is None:
                return content
            return truncate_embedding_input(content, self.max_input_tokens)

    def prepare_embedding_inputs(
        self, contents: List["EmbeddingInput"]
    ) -> List["EmbeddingInput"]:
        """Apply this embedder's input guard to a batch."""
        return [self.prepare_embedding_input(content) for content in contents]

    @property
    def supports_multimodal(self) -> bool:
        """Whether this embedder can consume multimodal (image) inputs directly.

        Text-only embedders return False so that multimodal inputs are downgraded
        to their text parts before being embedded.
        """
        return False

    @abstractmethod
    def embed(self, content: "EmbeddingInput", is_query: bool = False) -> EmbedResult:
        """Embed text or multimodal content.

        Args:
            content: Input text, or a list of multimodal content parts
            is_query: Flag to indicate if this is a query embedding

        Returns:
            EmbedResult: Embedding result containing dense_vector, sparse_vector, or both
        """
        pass

    def embed_batch(
        self, contents: List["EmbeddingInput"], is_query: bool = False
    ) -> List[EmbedResult]:
        """Batch embedding (default implementation loops, subclasses can override)"""
        return [self.embed(content, is_query=is_query) for content in contents]

    def embed_query(self, text: str) -> EmbedResult:
        """Embed query text with explicit retrieval-side semantics."""
        return self.embed(text, is_query=True)

    def embed_document(self, text: str) -> EmbedResult:
        """Embed document text with explicit indexing-side semantics."""
        return self.embed(text, is_query=False)

    async def embed_async(
        self, content: "EmbeddingInput", is_query: bool = False
    ) -> EmbedResult:
        """Async embed text or multimodal content.

        Subclasses should override this with a non-blocking implementation.
        """
        return self.embed(content, is_query=is_query)

    async def embed_batch_async(
        self, contents: List["EmbeddingInput"], is_query: bool = False
    ) -> List[EmbedResult]:
        """Async batch embedding."""
        results: List[EmbedResult] = []
        for content in contents:
            results.append(await self.embed_async(content, is_query=is_query))
        return results

    async def _run_with_async_retry(
        self,
        func: Callable[[], Awaitable[T]],
        *,
        logger=None,
        operation_name: str,
    ) -> T:
        """带信号量限流 + 指数退避重试的异步 embed 调用包装。

        信号量按 (event_loop, max_concurrent) 缓存，防单 loop 内并发失控。
        慢调用（>=3s）打 warning 含 provider/model/等待/耗时。
        """
        async def _wrapped() -> T:
            semaphore = _get_async_embed_semaphore(self.max_concurrent)
            wait_started = time.monotonic()
            await semaphore.acquire()
            wait_elapsed = time.monotonic() - wait_started
            telemetry = get_current_telemetry()
            telemetry.set("embedding.async.max_concurrent", self.max_concurrent)
            telemetry.set("embedding.async.wait_ms", round(wait_elapsed * 1000, 3))

            started = time.monotonic()
            previous_started_at = self._active_call_started_at
            self._active_call_started_at = started
            try:
                return await func()
            finally:
                elapsed = time.monotonic() - started
                telemetry.set("embedding.async.duration_ms", round(elapsed * 1000, 3))
                if logger and elapsed >= 3.0:
                    logger.warning(
                        "%s slow call provider=%s model=%s wait_ms=%.2f duration_ms=%.2f",
                        operation_name,
                        self.provider,
                        self.model_name,
                        wait_elapsed * 1000,
                        elapsed * 1000,
                    )
                self._active_call_started_at = previous_started_at
                semaphore.release()

        return await retry_async(
            _wrapped,
            max_retries=self.max_retries,
            logger=logger,
            operation_name=operation_name,
        )

    @property
    def is_dense(self) -> bool:
        return True

    @property
    def is_sparse(self) -> bool:
        return False

    @property
    def is_hybrid(self) -> bool:
        return False


class DenseEmbedderBase(EmbedderBase):
    """Dense embedder base class that returns dense vectors."""

    @abstractmethod
    def embed(self, content: "EmbeddingInput", is_query: bool = False) -> EmbedResult:
        """Perform dense embedding on text or multimodal content"""
        pass

    @abstractmethod
    def get_dimension(self) -> int:
        """Get embedding dimension"""
        pass


class SparseEmbedderBase(EmbedderBase):
    """Sparse embedder base class that returns sparse vectors.

    Sparse vector format is Dict[str, float], mapping terms to weights.
    Example: {'information': 0.8, 'retrieval': 0.6, 'system': 0.4}

    稀疏向量是 {term: weight} 而非 BM25 倒排表--是 query-time 学习出来的
    （SPLADE/学习型稀疏），能学语义扩展，这才是 hybrid 比 BM25+dense 更强的原因。
    """

    @abstractmethod
    def embed(self, content: "EmbeddingInput", is_query: bool = False) -> EmbedResult:
        """Perform sparse embedding on text or multimodal content"""
        pass

    @property
    def is_sparse(self) -> bool:
        return True


class HybridEmbedderBase(EmbedderBase):
    """Hybrid embedder base class that returns both dense and sparse vectors.

    Used for hybrid search, combining advantages of both dense and sparse vectors.
    """

    @abstractmethod
    def embed(self, content: "EmbeddingInput", is_query: bool = False) -> EmbedResult:
        """Perform hybrid embedding on text or multimodal content"""
        pass

    @abstractmethod
    def get_dimension(self) -> int:
        """Get dense embedding dimension"""
        pass

    @property
    def is_sparse(self) -> bool:
        return True

    @property
    def is_hybrid(self) -> bool:
        return True


class CompositeHybridEmbedder(HybridEmbedderBase):
    """Composite Hybrid Embedder that combines a dense embedder and a sparse embedder.

    组合 dense + sparse 两个独立 embedder，asyncio.gather 并发产双向量到同一 EmbedResult。
    关键：一次 embed 同时产 dense_vector + sparse_vector，不分两次调 embed API。

    Example:
        >>> dense = OpenAIDenseEmbedder(...)
        >>> sparse = VolcengineSparseEmbedder(...)
        >>> embedder = CompositeHybridEmbedder(dense, sparse)
        >>> result = embedder.embed("test")
    """

    def __init__(self, dense_embedder: DenseEmbedderBase, sparse_embedder: SparseEmbedderBase):
        """Initialize with two separate embedders"""
        super().__init__(
            model_name=f"{dense_embedder.model_name}+{sparse_embedder.model_name}",
            config={},
        )
        self.dense_embedder = dense_embedder
        self.sparse_embedder = sparse_embedder

    @property
    def supports_multimodal(self) -> bool:
        """Supports multimodal input only if both sub-embedders do."""
        return (
            self.dense_embedder.supports_multimodal
            and self.sparse_embedder.supports_multimodal
        )

    def embed(self, content: "EmbeddingInput", is_query: bool = False) -> EmbedResult:
        """Combine results from both embedders (sync)."""
        dense_input = self.dense_embedder.prepare_embedding_input(content)
        sparse_input = self.sparse_embedder.prepare_embedding_input(content)
        dense_res = self.dense_embedder.embed(dense_input, is_query=is_query)
        sparse_res = self.sparse_embedder.embed(sparse_input, is_query=is_query)

        return EmbedResult(
            dense_vector=dense_res.dense_vector, sparse_vector=sparse_res.sparse_vector
        )

    def embed_batch(
        self, contents: List["EmbeddingInput"], is_query: bool = False
    ) -> List[EmbedResult]:
        """Combine batch results (sync)."""
        dense_inputs = self.dense_embedder.prepare_embedding_inputs(contents)
        sparse_inputs = self.sparse_embedder.prepare_embedding_inputs(contents)
        dense_results = self.dense_embedder.embed_batch(dense_inputs, is_query=is_query)
        sparse_results = self.sparse_embedder.embed_batch(sparse_inputs, is_query=is_query)

        return [
            EmbedResult(dense_vector=d.dense_vector, sparse_vector=s.sparse_vector)
            for d, s in zip(dense_results, sparse_results, strict=True)
        ]

    async def embed_async(
        self, content: "EmbeddingInput", is_query: bool = False
    ) -> EmbedResult:
        """Combine results from both embedders (async, 并发).

        关键：asyncio.gather 并发调 dense 和 sparse 两个 embedder，
        延迟 ≈ max(dense, sparse) 而非 sum。
        """
        dense_input = self.dense_embedder.prepare_embedding_input(content)
        sparse_input = self.sparse_embedder.prepare_embedding_input(content)
        dense_res, sparse_res = await asyncio.gather(
            self.dense_embedder.embed_async(dense_input, is_query=is_query),
            self.sparse_embedder.embed_async(sparse_input, is_query=is_query),
        )
        return EmbedResult(
            dense_vector=dense_res.dense_vector, sparse_vector=sparse_res.sparse_vector
        )

    async def embed_batch_async(
        self, contents: List["EmbeddingInput"], is_query: bool = False
    ) -> List[EmbedResult]:
        """Combine batch results (async, 并发)."""
        dense_inputs = self.dense_embedder.prepare_embedding_inputs(contents)
        sparse_inputs = self.sparse_embedder.prepare_embedding_inputs(contents)
        dense_results, sparse_results = await asyncio.gather(
            self.dense_embedder.embed_batch_async(dense_inputs, is_query=is_query),
            self.sparse_embedder.embed_batch_async(sparse_inputs, is_query=is_query),
        )
        return [
            EmbedResult(dense_vector=d.dense_vector, sparse_vector=s.sparse_vector)
            for d, s in zip(dense_results, sparse_results, strict=True)
        ]

    def get_dimension(self) -> int:
        return self.dense_embedder.get_dimension()

    def close(self):
        self.dense_embedder.close()
        self.sparse_embedder.close()


def exponential_backoff_retry(
    func: Callable[[], T],
    max_wait: float = 10.0,
    base_delay: float = 0.5,
    max_delay: float = 2.0,
    jitter: bool = True,
    is_retryable: Optional[Callable[[Exception], bool]] = None,
    logger=None,
) -> T:
    """指数退避重试函数。

    Args:
        func: 要执行的函数
        max_wait: 最大总等待时间（秒）
        base_delay: 基础延迟时间（秒）
        max_delay: 单次最大延迟时间（秒）
        jitter: 是否添加随机抖动
        is_retryable: 判断异常是否可重试的函数
        logger: 日志记录器

    Returns:
        函数执行结果

    Raises:
        最后一次尝试的异常
    """
    start_time = time.time()
    attempt = 0

    while True:
        try:
            return func()
        except Exception as e:
            attempt += 1
            elapsed = time.time() - start_time

            if elapsed >= max_wait:
                if logger:
                    logger.error(
                        f"Exceeded max wait time ({max_wait}s) after {attempt} attempts, giving up"
                    )
                raise

            if is_retryable and not is_retryable(e):
                if logger:
                    logger.error(f"Non-retryable error after {attempt} attempts: {e}")
                raise

            delay = min(base_delay * (2 ** (attempt - 1)), max_delay)

            if jitter:
                delay = delay * (0.5 + random.random())

            remaining_time = max_wait - elapsed
            delay = min(delay, remaining_time)

            if logger:
                logger.info(
                    f"Retry attempt {attempt}, waiting {delay:.2f}s before next try (elapsed: {elapsed:.2f}s)"
                )

            time.sleep(delay)
```

> **查询重写与双向量要点**：`IntentAnalyzer.analyze` 把 compression_summary + recent_messages + current_message + target_abstract 交给 LLM 拆成 N×TypedQuery，按 planner 模型路由 prompt（含 SFT 小模型映射）。0 条 query = 无需检索。`CompositeHybridEmbedder.embed_async` 用 `asyncio.gather` 并发调 dense 和 sparse embedder，一次产双向量到同一 `EmbedResult`，延迟 ≈ max 而非 sum。`embed_compat` 是统一入口，处理多模态降级 + telemetry stage 绑定。`is_query` 标志必须传--很多 embedder 对 query/document 用不同 prefix。稀疏向量是学习型 `{term: weight}`（SPLADE/BGE-M3 sparse），非 BM25 倒排，能学语义扩展。
