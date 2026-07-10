# 完整源码：RRF 混合融合 + Rerank 精排（core/helix/rag/）

> 本文件给出 RRF 融合与 rerank 精排的完整源码。`QdrantCollection.search_by_vector` 实现 dense+sparse prefetch + `fusion: "rrf"` 混合融合，`_sparse_to_qdrant` 把学习型稀疏 term hash 成后端可索引整数。`RerankClient` 统一调度 volcengine/cohere/litellm/openai rerank provider。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.rag.*`），Qdrant 命名空间常量、原始 ID 字段名、URI scheme、rerank provider 名均已映射到中性名。原代码注释保留以保真。

## §1 QdrantCollection：RRF 混合融合（core/helix/rag/storage/vectordb/collection/qdrant_collection.py）

```python
# core/helix/rag/storage/vectordb/collection/qdrant_collection.py
"""Qdrant-backed ICollection implementation for Helix RAG."""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Any, Dict, List, Optional, Sequence, Tuple

import xxhash

from helix.rag.storage.vectordb.collection.collection import ICollection
from helix.rag.storage.vectordb.collection.qdrant_meta_store import QdrantMetaStore
from helix.rag.storage.vectordb.collection.qdrant_rest import QdrantRestClient, QdrantRestError
from helix.rag.storage.vectordb.collection.result import (
    AggregateResult,
    DataItem,
    FetchDataInCollectionResult,
    SearchItemResult,
    SearchResult,
)
from helix.rag.storage.vectordb.index.index import IIndex
from helix.rag.storage.vectordb.store.data import DeltaRecord
from helix.rag.utils import get_logger

logger = get_logger(__name__)

QDRANT_SPARSE_INDEX_MAX = 2**31 - 1
QDRANT_UINT64_MAX = 2**64 - 1
HELIX_RAG_QDRANT_ID_NAMESPACE = uuid.UUID("4b6bb5a8-7f1f-5b1a-9d4c-b93f29b1d67c")
ORIGINAL_ID_FIELD = "_helix_original_id"


def _coerce_iso_datetime(value: Any) -> Any:
    if isinstance(value, dt.datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=dt.timezone.utc)
        return value.isoformat()
    return value


def _normalize_distance(distance: str) -> str:
    """把距离度量名映射到 Qdrant 接受的枚举值。"""
    distance_value = (distance or "cosine").strip().lower()
    mapping = {
        "cosine": "Cosine",
        "ip": "Dot",
        "dot": "Dot",
        "l2": "Euclid",
        "euclid": "Euclid",
        "manhattan": "Manhattan",
    }
    return mapping.get(distance_value, "Cosine")


def _payload_selector(output_fields: Optional[List[str]]) -> bool | Dict[str, List[str]]:
    if not output_fields:
        return True
    include_fields = [field for field in output_fields if field != "id"]
    if ORIGINAL_ID_FIELD not in include_fields:
        include_fields.append(ORIGINAL_ID_FIELD)
    return {"include": include_fields} if include_fields else True


def _parse_point_id(value: Any) -> Any:
    if value is None:
        return ""
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    return str(value)


def _to_qdrant_point_id(value: Any) -> int | str:
    """把任意 id 转成 Qdrant point id（uint64 或 UUID 字符串）。

    优先用 uint64（Qdrant 原生整数 id），否则尝试解析为 UUID，
    再不行用 uuid5 做确定性命名空间哈希。
    """
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= QDRANT_UINT64_MAX:
        return value
    value_str = str(value)
    try:
        return str(uuid.UUID(value_str))
    except (ValueError, AttributeError, TypeError):
        return str(uuid.uuid5(HELIX_RAG_QDRANT_ID_NAMESPACE, value_str))


def _extract_points(response: Dict[str, Any]) -> List[Dict[str, Any]]:
    result = response.get("result", response)
    if isinstance(result, list):
        return result
    if isinstance(result, dict):
        if isinstance(result.get("points"), list):
            return result.get("points", [])
        if isinstance(result.get("result"), list):
            return result.get("result", [])
    return []


def _hash_sparse_term(term: str) -> int:
    """把稀疏 term 字符串 hash 成正 signed 32-bit 整数（Qdrant sparse vectors 要求）。

    用 xxhash 折叠到 QDRANT_SPARSE_INDEX_MAX 范围内。
    """
    return xxhash.xxh64_intdigest(str(term)) % QDRANT_SPARSE_INDEX_MAX


def _sparse_to_qdrant(sparse_vector: Optional[Dict[str, float]]) -> Optional[Dict[str, List[Any]]]:
    """把学习型稀疏向量 {term: weight} 转成 Qdrant 可索引的 {indices, values}。

    稀疏 term 经 xxhash 折叠成 uint32 索引。hash 碰撞时把权重合并到同一索引桶，
    并告警（碰撞会导致不同 term 被合并，影响稀疏召回精度）。
    空稀疏向量返回 None。
    """
    if not sparse_vector:
        return None
    merged: Dict[int, float] = {}
    hashed_terms: Dict[int, str] = {}
    collisions: List[tuple[str, str, int]] = []
    for raw_term, raw_weight in sparse_vector.items():
        try:
            weight = float(raw_weight)
        except (TypeError, ValueError):
            continue
        idx = _hash_sparse_term(str(raw_term))
        previous_term = hashed_terms.get(idx)
        if previous_term is not None and previous_term != str(raw_term):
            collisions.append((previous_term, str(raw_term), idx))
        else:
            hashed_terms[idx] = str(raw_term)
        merged[idx] = merged.get(idx, 0.0) + weight
    if collisions:
        sample = ", ".join(
            f"{left!r}<->{right!r}@{idx}" for left, right, idx in collisions[:3]
        )
        logger.warning(
            "Qdrant sparse term hash collision detected; colliding terms are merged into the same sparse index bucket. count=%s sample=%s",
            len(collisions),
            sample,
        )
    if not merged:
        return None
    indices = sorted(merged.keys())
    values = [merged[idx] for idx in indices]
    return {"indices": indices, "values": values}


class QdrantCollection(ICollection):
    """Qdrant-backed collection implementation.

    核心方法 search_by_vector 实现 dense+sparse 双向量 RRF 混合融合：
    - dense + sparse 同时给 -> prefetch[dense, sparse] + query:{"fusion": "rrf"}
    - 纯 sparse -> /points/query sparse-only
    - 纯 dense -> /points/query dense-only，失败 fallback /points/search
    """

    DEFAULT_SCROLL_PAGE_SIZE = 256
    DEFAULT_DELETE_BATCH_SIZE = 1_000
    DEFAULT_HYBRID_PREFETCH_LIMIT = 32
    MAX_HYBRID_PREFETCH_LIMIT = 256
    MAX_SCROLL_ITERATIONS = 10_000
    CLIENT_SIDE_SCAN_WARNING_THRESHOLD = 10_000
    TEXT_INDEX_FIELDS = {"name", "description", "abstract", "tags"}

    def __init__(
        self,
        *,
        url: str,
        api_key: str | None,
        timeout_seconds: int,
        project_name: str,
        logical_collection_name: str,
        physical_collection_name: str,
        dense_vector_name: str,
        sparse_vector_name: str,
        meta_collection_name: str,
        distance_metric: str,
        enable_text_index: bool = False,
    ) -> None:
        super().__init__()
        self._client = QdrantRestClient(
            url=url,
            api_key=api_key,
            timeout_seconds=timeout_seconds,
        )
        self._project_name = project_name
        self._logical_collection_name = logical_collection_name
        self._physical_collection_name = physical_collection_name
        self._dense_vector_name = dense_vector_name
        self._sparse_vector_name = sparse_vector_name
        self._distance_metric = distance_metric
        self._enable_text_index = enable_text_index
        self._meta_store = QdrantMetaStore(
            client=self._client,
            meta_collection_name=meta_collection_name,
        )
        self._vector_dim = 0
        self._path_payload_fields: set[str] = {"parent_uri", "scope_roots"}
        self._refresh_vector_dim_from_meta()

    @staticmethod
    def _decode_path_value(value: Any) -> Any:
        """把后端存储的 path 值解码回 kb:// URI 形式。"""
        if isinstance(value, list):
            return [QdrantCollection._decode_path_value(item) for item in value]
        if not isinstance(value, str):
            return value
        stripped = value.strip()
        if stripped.startswith("kb://") or not stripped.startswith("/"):
            return value
        suffix = stripped.strip("/")
        return f"kb://{suffix}" if suffix else "kb://"

    def search_by_vector(
        self,
        index_name: str,
        dense_vector: Optional[List[float]] = None,
        limit: int = 10,
        offset: int = 0,
        filters: Optional[Dict[str, Any]] = None,
        sparse_vector: Optional[Dict[str, float]] = None,
        output_fields: Optional[List[str]] = None,
    ) -> SearchResult:
        """向量检索：支持 dense-only / sparse-only / dense+sparse hybrid (RRF)。

        三条路径：
        1. dense + sparse 同时给 -> prefetch[dense, sparse] + query:{"fusion":"rrf"}
           hybrid_prefetch_limit = min(max(fetch*4, fetch+8, 32), 256)
        2. 纯 sparse -> /points/query sparse-only
        3. 纯 dense -> /points/query dense-only，失败 fallback /points/search

        RRF 数学：score(d) = Σ_i 1/(k + rank_i(d))，只看 rank 不看绝对值，
        天然 cross-modality 安全（dense cosine 与 sparse 内积量纲不可比）。
        """
        if dense_vector is None and sparse_vector is None:
            return SearchResult()

        fetch_limit = max(limit + offset, limit)
        body: Dict[str, Any] = {
            "limit": fetch_limit,
            "with_payload": _payload_selector(output_fields),
        }
        if filters:
            body["filter"] = filters

        try:
            if dense_vector is not None and sparse_vector:
                # 路径 1：dense + sparse hybrid -> RRF 融合
                sparse_payload = _sparse_to_qdrant(sparse_vector)
                if not sparse_payload:
                    sparse_vector = None
                else:
                    hybrid_prefetch_limit = min(
                        max(fetch_limit * 4, fetch_limit + 8, self.DEFAULT_HYBRID_PREFETCH_LIMIT),
                        self.MAX_HYBRID_PREFETCH_LIMIT,
                    )
                    body.update(
                        {
                            "prefetch": [
                                {
                                    "query": dense_vector,
                                    "using": self._dense_vector_name,
                                    "limit": hybrid_prefetch_limit,
                                },
                                {
                                    "query": sparse_payload,
                                    "using": self._sparse_vector_name,
                                    "limit": hybrid_prefetch_limit,
                                },
                            ],
                            "query": {"fusion": "rrf"},
                        }
                    )
                    response = self._client.request(
                        "POST",
                        f"/collections/{self._physical_collection_name}/points/query",
                        json_body=body,
                        expected_statuses=(200, 202),
                    )
                    return self._parse_search_result(response, offset=offset, limit=limit)

            if sparse_vector and dense_vector is None:
                # 路径 2：纯 sparse -> sparse-only query
                sparse_payload = _sparse_to_qdrant(sparse_vector)
                if not sparse_payload:
                    return SearchResult()
                body.update(
                    {
                        "query": sparse_payload,
                        "using": self._sparse_vector_name,
                    }
                )
                response = self._client.request(
                    "POST",
                    f"/collections/{self._physical_collection_name}/points/query",
                    json_body=body,
                    expected_statuses=(200, 202),
                )
                return self._parse_search_result(response, offset=offset, limit=limit)

            if dense_vector is None:
                return SearchResult()

            # 路径 3：纯 dense -> dense-only query
            body.update(
                {
                    "query": dense_vector,
                    "using": self._dense_vector_name,
                }
            )
            response = self._client.request(
                "POST",
                f"/collections/{self._physical_collection_name}/points/query",
                json_body=body,
                expected_statuses=(200, 202),
            )
            return self._parse_search_result(response, offset=offset, limit=limit)
        except QdrantRestError as exc:
            # /points/query 不可用时 fallback 到 /points/search（dense-only）
            if dense_vector is None:
                raise
            logger.warning(
                "Falling back to Qdrant /points/search for dense-only query because /points/query failed: %s",
                exc,
            )
            fallback_body: Dict[str, Any] = {
                "vector": {
                    "name": self._dense_vector_name,
                    "vector": dense_vector,
                },
                "limit": fetch_limit,
                "with_payload": _payload_selector(output_fields),
            }
            if filters:
                fallback_body["filter"] = filters
            response = self._client.request(
                "POST",
                f"/collections/{self._physical_collection_name}/points/search",
                json_body=fallback_body,
                expected_statuses=(200, 202),
            )
            return self._parse_search_result(response, offset=offset, limit=limit)

    def _parse_search_result(
        self,
        response: Dict[str, Any],
        *,
        offset: int,
        limit: int,
    ) -> SearchResult:
        """解析 Qdrant /points/query 响应为 SearchResult。"""
        items: List[SearchItemResult] = []
        for point in _extract_points(response):
            if not isinstance(point, dict):
                continue
            original_id, payload = self._point_payload_for_read(point)
            score = point.get("score") if isinstance(point, dict) else None
            items.append(
                SearchItemResult(
                    id=original_id,
                    fields=payload,
                    score=score,
                )
            )
        if offset > 0:
            items = items[offset:]
        if len(items) > limit:
            items = items[:limit]
        return SearchResult(data=items)

    def _point_payload_for_read(self, point: Dict[str, Any]) -> Tuple[Any, Dict[str, Any]]:
        """从 Qdrant point 提取 original_id 与 normalize 后的 payload。"""
        raw_payload = dict(point.get("payload", {}) or {})
        original_id = raw_payload.pop(ORIGINAL_ID_FIELD, None)
        if original_id is None:
            original_id = _parse_point_id(point.get("id"))
        return original_id, self._normalize_payload_for_read(raw_payload)

    def _normalize_payload_for_read(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        """读出时把 path 类型字段从 /local/... 形式解码回 kb:// URI。"""
        if not payload:
            return {}
        normalized = dict(payload)
        for field_name in self._path_payload_fields:
            if field_name in normalized:
                normalized[field_name] = self._decode_path_value(normalized[field_name])
        return normalized

    def has_helix_metadata(self) -> bool:
        """Check whether this collection has Helix RAG metadata stored."""
        return bool(self._meta_store.get_collection_meta(collection_key=self.collection_key))

    @property
    def collection_key(self) -> str:
        return self._physical_collection_name

    def collection_exists(self) -> bool:
        return self._client.collection_exists(self._physical_collection_name)
```

## §2 RerankBase + RerankClient 统一调度（core/helix/rag/models/rerank/）

```python
# core/helix/rag/models/rerank/__init__.py
"""
Rerank models for Helix RAG.

Provides rerank functionality for hierarchical retrieval with multiple provider support:
- volcengine: Volcengine 向量库 native rerank service
- cohere: Cohere Rerank v3.5 API
- litellm: LiteLLM rerank (supports multiple providers)
- openai: OpenAI-compatible rerank API
"""

from helix.rag.models.rerank.base import RerankBase
from helix.rag.models.rerank.cohere_rerank import CohereRerankClient
from helix.rag.models.rerank.litellm_rerank import LiteLLMRerankClient
from helix.rag.models.rerank.openai_rerank import OpenAIRerankClient
from helix.rag.models.rerank.volcengine_rerank import RerankClient

__all__ = [
    "RerankBase",
    "RerankClient",
    "CohereRerankClient",
    "LiteLLMRerankClient",
    "OpenAIRerankClient",
]
```

```python
# core/helix/rag/models/rerank/base.py
"""
RerankBase: Base class for all rerank clients.

Provides common token usage tracking functionality.
"""

import logging
from typing import Any, Dict

from helix.rag.utils import get_logger

_token_tracker_instance = None
logger = get_logger(__name__)


def _get_token_tracker():
    """Lazy import to avoid circular dependency. Returns shared singleton instance."""
    global _token_tracker_instance
    if _token_tracker_instance is None:
        from helix.rag.models.vlm.token_usage import TokenUsageTracker

        _token_tracker_instance = TokenUsageTracker()
    return _token_tracker_instance


def get_shared_rerank_token_usage() -> Dict[str, Any]:
    """
    Return the process-wide rerank token usage snapshot.

    读取共享单例 TokenUsageTracker 的快照，供可观测性路径
    （如 Prometheus scrape）在不构造 provider client 的情况下访问 rerank 用量。
    """
    return _get_token_tracker().to_dict()


class RerankBase:
    """Base class for all rerank clients.

    Provides common token usage tracking functionality.

    所有 rerank provider（volcengine/cohere/litellm/openai）继承此类，
    共享 token 追踪与 telemetry 上报逻辑。rerank 失败时由调用方
    （HierarchicalRetriever._rerank_scores）fallback 到向量分。
    """

    def __init__(self):
        """Initialize rerank client with token tracking"""
        # Token usage tracking
        self._token_tracker = _get_token_tracker()

    def _estimate_tokens(self, text: str) -> int:
        """Estimate token count for text (rough approximation: 1 token ≈ 4 characters)."""
        return max(1, len(text) // 4)

    def update_token_usage(
        self,
        model_name: str,
        provider: str,
        prompt_tokens: int,
        completion_tokens: int,
        duration_seconds: float = 0.0,
    ) -> None:
        """Update token usage.

        Args:
            model_name: Model name
            provider: Provider name (volcengine, openai, cohere, litellm, etc.)
            prompt_tokens: Number of input tokens
            completion_tokens: Number of output tokens
            duration_seconds: Wall-clock duration of the rerank provider call in seconds
        """
        self._token_tracker.update(
            model_name=model_name,
            provider=provider,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
        )
        try:
            from helix.rag.telemetry import get_current_telemetry

            get_current_telemetry().record_token_usage(
                "rerank",
                int(prompt_tokens),
                int(completion_tokens),
                stage="rerank",
            )
        except Exception as e:
            # Telemetry must never break rerank execution.
            if logger.isEnabledFor(logging.DEBUG):
                logger.debug(
                    "rerank.update_token_usage telemetry emit failed provider=%s model_name=%s err=%s: %s",
                    provider,
                    model_name,
                    type(e).__name__,
                    e,
                )
        try:
            from helix.rag.metrics.datasources import RerankEventDataSource
            from helix.rag.observability.context import get_root_observability_context

            root_context = get_root_observability_context()

            RerankEventDataSource.record_call(
                provider=str(provider),
                model_name=str(model_name),
                duration_seconds=max(float(duration_seconds), 0.0),
                prompt_tokens=int(prompt_tokens),
                completion_tokens=int(completion_tokens),
                account_id=root_context.account_id if root_context is not None else None,
            )
        except Exception as e:
            # Metrics must never break rerank execution.
            if logger.isEnabledFor(logging.DEBUG):
                logger.debug(
                    "rerank.update_token_usage metrics emit failed provider=%s model_name=%s err=%s: %s",
                    provider,
                    model_name,
                    type(e).__name__,
                    e,
                )

    def _extract_and_update_token_usage(
        self,
        response_data: dict,
        query: str,
        documents: list,
        duration_seconds: float = 0.0,
    ) -> None:
        """Extract and update token usage from API response.

        优先从 response meta（Cohere 格式）提取 billed_units，
        提取不到则按文本长度估算 prompt_tokens。
        """
        prompt_tokens = 0
        completion_tokens = 0

        # Try to extract token usage from response meta (Cohere format)
        meta = response_data.get("meta", {})
        if isinstance(meta, dict):
            billed_units = meta.get("billed_units", {})
            if isinstance(billed_units, dict):
                prompt_tokens = billed_units.get("input_tokens", 0)
                completion_tokens = billed_units.get("output_tokens", 0)

        # If no token info in response, estimate based on text
        if prompt_tokens == 0 and completion_tokens == 0:
            prompt_tokens = self._estimate_tokens(query)
            for doc in documents:
                prompt_tokens += self._estimate_tokens(str(doc))
            # Rerank typically doesn't generate output tokens, just scores
            completion_tokens = 0

        # Get model name
        model_name = getattr(self, "model_name", None) or getattr(self, "model", None) or "unknown"

        self.update_token_usage(
            model_name=model_name,
            provider=self.provider,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            duration_seconds=duration_seconds,
        )

    def get_token_usage(self) -> Dict[str, Any]:
        """Get token usage"""
        return self._token_tracker.to_dict()

    def reset_token_usage(self) -> None:
        """Reset token usage"""
        self._token_tracker.reset()
```

> **RRF 与 Rerank 要点**：`search_by_vector` 三条路径--dense+sparse 同时给走 `prefetch[dense, sparse] + query:{"fusion":"rrf"}`（`hybrid_prefetch_limit = min(max(fetch*4, fetch+8, 32), 256)`），纯 sparse 走 sparse-only，纯 dense 走 dense-only 且 `/points/query` 失败时 fallback `/points/search`。RRF 只看 rank 不看绝对值，规避 dense cosine（[-1,1]）与 sparse 内积（[0,+∞)）量纲不可比难题。`_sparse_to_qdrant` 用 xxhash 把学习型稀疏 term 折叠成 uint32 索引，碰撞合并 weight 并告警。`RerankClient.from_config` 统一调度 volcengine/cohere/litellm/openai provider；rerank 失败由 `HierarchicalRetriever._rerank_scores` 三道 fallback 到向量分，不让 rerank 挂掉拖垮 RAG。Rerank 输入用 L0 abstract（~100 token）而非全文。
