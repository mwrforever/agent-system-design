# 完整源码：HierarchicalRetriever 五层检索内核（core/helix/rag/retrieve/hierarchical_retriever.py）

> 本文件给出 `HierarchicalRetriever` 的完整实现：五层检索内核总编排。`retrieve()` 是入口，`_recursive_search()` 是优先级队列递归 + 收敛检测，`_rerank_scores()` 是 rerank 三道 fallback，`_convert_to_matched_contexts()` 是终态热度叠加。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.rag.*`），向量库管理类与代理类均已映射到中性名。原代码注释保留以保真。

```python
# core/helix/rag/retrieve/hierarchical_retriever.py
"""
Hierarchical retriever for Helix RAG.

Implements directory-based hierarchical retrieval with recursive search
and rerank-based relevance scoring.
"""

import asyncio
import heapq
import logging
import math
import time
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

from helix.rag.core.retrieval_targets import default_target_directories
from helix.rag.models.embedder.base import EmbedResult, embed_compat
from helix.rag.models.rerank import RerankClient
from helix.rag.retrieve.memory_lifecycle import hotness_score
from helix.rag.retrieve.retrieval_stats import get_stats_collector
from helix.rag.server.identity import RequestContext
from helix.rag.storage import VectorDBManager, VectorDBManagerProxy
from helix.rag.telemetry import get_current_telemetry
from helix.rag.utils.time_utils import parse_iso_datetime
from helix.rag.retrieve.types import (
    ContextType,
    MatchedContext,
    QueryResult,
    TypedQuery,
)
from helix.rag.config import RerankConfig, RetrievalConfig
from helix.rag.utils.logger import get_logger

logger = get_logger(__name__)


class RetrieverMode(str):
    THINKING = "thinking"
    QUICK = "quick"


class HierarchicalRetriever:
    """Hierarchical retriever with dense and sparse vector support.

    五层检索内核总编排：
    1. embed query 一次产双向量
    2. 全局向量搜索补起点候选（后端走 RRF）
    3. 合并起点 + rerank 起点分数
    4. 优先级队列递归（并发展开 + 收敛检测）
    5. 多因子终态评分（传播在递归中，热度在此叠加）
    """

    MAX_CONVERGENCE_ROUNDS = 3  # Stop after multiple rounds with unchanged topk
    MAX_RELATIONS = 5  # Maximum relations per resource
    DIRECTORY_DOMINANCE_RATIO = 1.2  # Directory score must exceed max child score
    GLOBAL_SEARCH_TOPK = 10  # Global retrieval count (more candidates = better rerank precision)
    MAX_PARALLEL_CHILD_SEARCHES = 4  # Limit per-request fan-out against remote vector stores
    LEVEL_URI_SUFFIX = {0: ".abstract.md", 1: ".overview.md"}

    def __init__(
        self,
        storage: VectorDBManager,
        embedder: Optional[Any],
        rerank_config: Optional[RerankConfig] = None,
        retrieval_config: Optional[RetrievalConfig] = None,
    ):
        """Initialize hierarchical retriever with rerank_config.

        Args:
            storage: VectorIndexBackend instance
            embedder: Embedder instance (supports dense/sparse/hybrid)
            rerank_config: Rerank configuration (optional, will fallback to vector search only)
            retrieval_config: Retrieval ranking configuration.
        """
        self.vector_store = storage
        self.embedder = embedder
        self.rerank_config = rerank_config
        self.retrieval_config = retrieval_config or RetrievalConfig()
        self.hotness_alpha = self.retrieval_config.hotness_alpha
        self.score_propagation_alpha = self.retrieval_config.score_propagation_alpha

        # Use rerank threshold if available, otherwise use a default
        self.threshold = rerank_config.threshold if rerank_config else 0

        # Initialize rerank client - all providers go through unified dispatch
        if rerank_config and rerank_config.is_available():
            self._rerank_client = RerankClient.from_config(rerank_config)
            provider = rerank_config._effective_provider()
            logger.info(
                f"[HierarchicalRetriever] Rerank enabled (provider={provider}), threshold={self.threshold}"
            )
        else:
            self._rerank_client = None
            logger.info(
                f"[HierarchicalRetriever] Rerank not configured, using vector search only with threshold={self.threshold}"
            )

    async def retrieve(
        self,
        query: TypedQuery,
        ctx: RequestContext,
        limit: int = 5,
        mode: str = RetrieverMode.THINKING,
        score_threshold: Optional[float] = None,
        score_gte: bool = False,
        scope_dsl: Optional[Dict[str, Any]] = None,
        level: Optional[List[int]] = None,
    ) -> QueryResult:
        """Execute hierarchical retrieval. 五层检索内核入口。

        Args:
            query: TypedQuery（含 query 文本、context_type、target_directories）
            ctx: 请求上下文（含 account_id / user，用于多租户隔离）
            limit: 返回数量上限
            mode: THINKING=走 rerank；QUICK=跳过 rerank
            score_threshold: 自定义分数阈值（覆盖 config）
            score_gte: True 用 >=，False 用 >
            scope_dsl: 额外 scope 约束（从 find/search filter 传入）
            level: 过滤返回层级（[0]=L0/[1]=L1/[2]=L2）
        """
        t0 = time.monotonic()
        telemetry = get_current_telemetry()
        # Use custom threshold or default threshold
        effective_threshold = score_threshold if score_threshold is not None else self.threshold

        # 创建 proxy 包装器，绑定当前 ctx
        vector_proxy = VectorDBManagerProxy(self.vector_store, ctx)

        target_dirs = [d for d in (query.target_directories or []) if d]

        if not await vector_proxy.collection_exists_bound():
            logger.warning(
                "[RecursiveSearch] Collection %s does not exist",
                vector_proxy.collection_name,
            )
            return QueryResult(
                query=query,
                matched_contexts=[],
                searched_directories=[],
            )

        # Generate query vectors once to avoid duplicate embedding calls
        query_vector = None
        sparse_query_vector = None
        if self.embedder:
            with telemetry.measure("search.embed_query"):
                result: EmbedResult = await embed_compat(self.embedder, query.query, is_query=True)
                query_vector = result.dense_vector
                sparse_query_vector = result.sparse_vector

        # Step 1: Determine starting directories based on explicit target dirs.
        if target_dirs:
            root_uris = target_dirs
        else:
            root_uris = default_target_directories(ctx, context_type=query.context_type)

        # Step 2: Global vector search to supplement starting points
        with telemetry.measure("search.vector_retrieval"):
            global_results = await self._global_vector_search(
                vector_proxy=vector_proxy,
                query_vector=query_vector,
                sparse_query_vector=sparse_query_vector,
                context_type=query.context_type.value if query.context_type else None,
                target_dirs=target_dirs,
                scope_dsl=scope_dsl,
                limit=max(limit, self.GLOBAL_SEARCH_TOPK),
            )

        # Debug: Print all URIs in global_results
        if logger.isEnabledFor(logging.DEBUG):
            logger.debug(f"[retrieve] target_dirs: {target_dirs}")
            logger.debug(f"[retrieve] root_uris: {root_uris}")
            logger.debug(f"[retrieve] scope_dsl: {scope_dsl}")
            logger.debug(
                f"[retrieve] Step 2 completed, global_results contains {len(global_results)} items:"
            )
            for i, r in enumerate(global_results):
                uri = r.get("uri", "UNKNOWN_URI")
                score = r.get("_score", 0.0)
                result_level = r.get("level", "UNKNOWN_LEVEL")
                account_id = r.get("account_id", "UNKNOWN_ACCOUNT_ID")
                logger.debug(
                    f"  [{i}] URI: {uri}, score: {score:.4f}, level: {result_level}, account_id: {account_id}"
                )

        # Step 3: Merge starting points
        starting_points = self._merge_starting_points(
            query.query,
            root_uris,
            global_results,
            mode=mode,
        )

        # Add global hits to the result pool only when they match the requested level.
        if level is not None:
            initial_candidates = [r for r in global_results if r.get("level", 2) in level]
        else:
            initial_candidates = [r for r in global_results if r.get("level", 2) == 2]

        initial_candidates = self._prepare_initial_candidates(
            query.query,
            initial_candidates,
            mode=mode,
        )

        # Step 4: Recursive search
        with telemetry.measure("search.vector_retrieval"):
            candidates = await self._recursive_search(
                vector_proxy=vector_proxy,
                query=query.query,
                query_vector=query_vector,
                sparse_query_vector=sparse_query_vector,
                starting_points=starting_points,
                limit=limit,
                mode=mode,
                threshold=effective_threshold,
                score_gte=score_gte,
                context_type=query.context_type.value if query.context_type else None,
                target_dirs=target_dirs,
                scope_dsl=scope_dsl,
                initial_candidates=initial_candidates,
                level=level,
            )

        # Step 6: Convert results
        matched = await self._convert_to_matched_contexts(
            candidates,
            ctx=ctx,
        )

        final = matched[:limit]

        # Record retrieval stats for the observer.
        elapsed_ms = (time.monotonic() - t0) * 1000
        get_stats_collector().record_query(
            context_type=query.context_type.value if query.context_type else "unknown",
            result_count=len(final),
            scores=[m.score for m in final],
            latency_ms=elapsed_ms,
            rerank_used=self._rerank_client is not None and mode == RetrieverMode.THINKING,
        )

        return QueryResult(
            query=query,
            matched_contexts=final,
            searched_directories=root_uris,
        )

    async def _global_vector_search(
        self,
        vector_proxy: VectorDBManagerProxy,
        query_vector: Optional[List[float]],
        sparse_query_vector: Optional[Dict[str, float]],
        context_type: Optional[str],
        target_dirs: List[str],
        scope_dsl: Optional[Dict[str, Any]],
        limit: int,
    ) -> List[Dict[str, Any]]:
        """Global vector search to locate initial directories. 全局向量搜索定位起点。"""
        results = await vector_proxy.search_global_roots_in_tenant(
            query_vector=query_vector,
            sparse_query_vector=sparse_query_vector,
            context_type=context_type,
            target_directories=target_dirs,
            extra_filter=scope_dsl,
            limit=limit,
        )
        telemetry = get_current_telemetry()
        telemetry.count("vector.searches", 1)
        telemetry.count("vector.scored", len(results))
        telemetry.count("vector.scanned", len(results))
        return results

    def _rerank_scores(
        self,
        query: str,
        documents: List[str],
        fallback_scores: List[float],
    ) -> List[float]:
        """Return rerank scores or fall back to vector scores. Rerank 三道 fallback。

        三道防线：
        1. 无 rerank client 或无文档 -> 直接返回向量分
        2. rerank 抛异常 -> 返回向量分（不让 rerank 挂掉拖垮 RAG）
        3. 返回长度不匹配 / None -> 返回向量分（provider bug 兜底）
        非数值分数也逐个替换为对应 fallback。
        """
        if not self._rerank_client or not documents:
            return fallback_scores

        try:
            scores = self._rerank_client.rerank_batch(query, documents)
        except Exception as e:
            logger.warning(
                "[HierarchicalRetriever] Rerank failed, fallback to vector scores: %s", e
            )
            return fallback_scores

        if not scores or len(scores) != len(documents):
            logger.warning(
                "[HierarchicalRetriever] Invalid rerank result, fallback to vector scores"
            )
            return fallback_scores

        normalized_scores: List[float] = []
        for score, fallback in zip(scores, fallback_scores, strict=True):
            if isinstance(score, (int, float)):
                normalized_scores.append(float(score))
            else:
                normalized_scores.append(fallback)
        return normalized_scores

    def _merge_starting_points(
        self,
        query: str,
        root_uris: List[str],
        global_results: List[Dict[str, Any]],
        mode: str = "thinking",
    ) -> List[Tuple[str, float]]:
        """Merge starting points. 合并起点：global 命中的 L0/L1 目录 + root_uris。

        Returns:
            List of (uri, parent_score) tuples
        """
        points = []
        seen = set()

        global_results = [r for r in global_results if r.get("level", 2) != 2]

        # Results from global search
        default_scores = [
            s if math.isfinite(s) else 0.0 for s in (r.get("_score", 0.0) for r in global_results)
        ]
        if self._rerank_client and mode == RetrieverMode.THINKING:
            docs = [str(r.get("abstract", "")) for r in global_results]
            query_scores = self._rerank_scores(query, docs, default_scores)
            for i, r in enumerate(global_results):
                # 只添加非 level 2 的项目到起始点
                if r.get("level", 2) != 2:
                    points.append((r["uri"], query_scores[i]))
                    seen.add(r["uri"])
        else:
            for r in global_results:
                # 只添加非 level 2 的项目到起始点
                if r.get("level", 2) != 2:
                    points.append((r["uri"], r["_score"]))
                    seen.add(r["uri"])

        # Root directories as starting points
        for uri in root_uris:
            if uri not in seen:
                points.append((uri, 0.0))
                seen.add(uri)

        return points

    def _prepare_initial_candidates(
        self,
        query: str,
        global_results: List[Dict[str, Any]],
        mode: str = RetrieverMode.THINKING,
    ) -> List[Dict[str, Any]]:
        """Preserve rerank scores for global hits added to the result pool."""
        initial_candidates = [dict(r) for r in global_results]
        if not initial_candidates:
            return []

        default_scores = [
            s if math.isfinite(s) else 0.0
            for s in (r.get("_score", 0.0) for r in initial_candidates)
        ]
        if self._rerank_client and mode == RetrieverMode.THINKING:
            docs = [str(r.get("abstract", "")) for r in initial_candidates]
            query_scores = self._rerank_scores(query, docs, default_scores)
        else:
            query_scores = default_scores

        for candidate, score in zip(initial_candidates, query_scores, strict=True):
            candidate["_score"] = score

        return initial_candidates

    async def _recursive_search(
        self,
        vector_proxy: VectorDBManagerProxy,
        query: str,
        query_vector: Optional[List[float]],
        sparse_query_vector: Optional[Dict[str, float]],
        starting_points: List[Tuple[str, float]],
        limit: int,
        mode: str,
        threshold: Optional[float] = None,
        score_gte: bool = False,
        context_type: Optional[str] = None,
        target_dirs: Optional[List[str]] = None,
        scope_dsl: Optional[Dict[str, Any]] = None,
        initial_candidates: Optional[List[Dict[str, Any]]] = None,
        level: Optional[List[int]] = None,
    ) -> List[Dict[str, Any]]:
        """Recursive search with directory priority return and score propagation.

        优先级队列递归 + 分数传播 + 收敛检测：
        - 起点入队，每次并发展开 MAX_PARALLEL_CHILD_SEARCHES 个目录
        - 每层 search 子节点 -> rerank -> 父子传播 -> 阈值过滤 -> 入结果池 / 入队
        - L2 文件是终端命中（入池不入队），只有 L0/L1 目录入队继续递归
        - 收敛检测：top-K 连续 MAX_CONVERGENCE_ROUNDS 轮不变 / 池大小连续 N 轮不变 -> 停

        Args:
            threshold: Score threshold
            score_gte: True uses >=, False uses >
            scope_dsl: Additional scope constraints from public find/search filter
        """
        # Use passed threshold or default threshold
        effective_threshold = threshold if threshold is not None else self.threshold

        def passes_threshold(score: float) -> bool:
            """Check if score passes threshold."""
            if score_gte:
                return score >= effective_threshold
            return score > effective_threshold

        sparse_query_vector = sparse_query_vector or None

        collected_by_uri: Dict[str, Dict[str, Any]] = {}
        dir_queue: List[tuple] = []  # Priority queue: (-score, uri)
        visited: set = set()
        prev_topk_uris: set = set()
        prev_pool_size = 0
        convergence_rounds = 0
        stagnant_rounds = 0

        # Add initial candidates that match the requested level.
        if initial_candidates:
            for r in initial_candidates:
                uri = r.get("uri", "")
                if not uri:
                    continue
                if level is None or r.get("level", 2) in level:
                    score = r.get("_score", 0.0)
                    if not passes_threshold(score):
                        logger.debug(
                            f"[RecursiveSearch] Initial candidate URI {uri} score {score:.4f} did not pass threshold {effective_threshold}"
                        )
                        continue
                    r["_final_score"] = score
                    collected_by_uri[uri] = r
                    logger.debug(
                        f"[RecursiveSearch] Added initial candidate: {uri} (score: {score:.4f})"
                    )

        alpha = self.score_propagation_alpha

        # Initialize: process starting points
        for uri, score in starting_points:
            heapq.heappush(dir_queue, (-score, uri))

        async def search_children(current_uri: str) -> List[Dict[str, Any]]:
            return await vector_proxy.search_children_in_tenant(
                parent_uri=current_uri,
                query_vector=query_vector,
                sparse_query_vector=sparse_query_vector,  # Pass sparse vector
                context_type=context_type,
                target_directories=target_dirs,
                extra_filter=scope_dsl,
                limit=max(limit * 2, 20),
            )

        parallelism = max(1, self.MAX_PARALLEL_CHILD_SEARCHES)

        while dir_queue:
            batch: List[Tuple[str, float]] = []
            while dir_queue and len(batch) < parallelism:
                temp_score, current_uri = heapq.heappop(dir_queue)
                current_score = -temp_score
                if current_uri in visited:
                    continue
                visited.add(current_uri)
                logger.info(f"[RecursiveSearch] Entering URI: {current_uri}")
                batch.append((current_uri, current_score))

            if not batch:
                continue

            batch_results = await asyncio.gather(
                *(search_children(current_uri) for current_uri, _ in batch)
            )

            telemetry = get_current_telemetry()
            for (_, current_score), results in zip(batch, batch_results, strict=True):
                telemetry.count("vector.searches", 1)
                telemetry.count("vector.scored", len(results))
                telemetry.count("vector.scanned", len(results))

                if not results:
                    continue

                query_scores = [
                    s if math.isfinite(s) else 0.0 for s in (r.get("_score", 0.0) for r in results)
                ]
                if self._rerank_client and mode == RetrieverMode.THINKING:
                    documents = [str(r.get("abstract", "")) for r in results]
                    query_scores = self._rerank_scores(query, documents, query_scores)

                for r, score in zip(results, query_scores, strict=True):
                    uri = r.get("uri", "")
                    # 父子传播: α_prop * child + (1-α_prop) * parent
                    final_score = (
                        alpha * score + (1 - alpha) * current_score if current_score else score
                    )

                    if not passes_threshold(final_score):
                        logger.debug(
                            f"[RecursiveSearch] URI {uri} score {final_score} did not pass threshold {effective_threshold}"
                        )
                        continue

                    telemetry.count("vector.passed", 1)
                    if level is None or r.get("level", 2) in level:
                        # Deduplicate by URI and keep the highest-scored candidate.
                        previous = collected_by_uri.get(uri)
                        if previous is None or final_score > previous.get("_final_score", 0):
                            r["_final_score"] = final_score
                            collected_by_uri[uri] = r
                            logger.debug(
                                "[RecursiveSearch] Updated URI: %s candidate score to %.4f",
                                uri,
                                final_score,
                            )

                    # Only recurse into directories (L0/L1). L2 files are terminal hits.
                    if uri not in visited and r.get("level", 2) != 2:
                        heapq.heappush(dir_queue, (-final_score, uri))

            # Convergence check after each parallel expansion round.
            current_topk = sorted(
                collected_by_uri.values(),
                key=lambda x: x.get("_final_score", 0),
                reverse=True,
            )[:limit]
            current_topk_uris = {c.get("uri", "") for c in current_topk}
            current_pool_size = len(collected_by_uri)

            if current_topk_uris == prev_topk_uris and len(current_topk_uris) >= limit:
                convergence_rounds += 1

                if convergence_rounds >= self.MAX_CONVERGENCE_ROUNDS:
                    break
            elif current_pool_size == prev_pool_size:
                stagnant_rounds += 1

                if stagnant_rounds >= self.MAX_CONVERGENCE_ROUNDS:
                    break
            else:
                convergence_rounds = 0
                stagnant_rounds = 0
                prev_topk_uris = current_topk_uris
                prev_pool_size = current_pool_size

        collected = sorted(
            collected_by_uri.values(),
            key=lambda x: x.get("_final_score", 0),
            reverse=True,
        )
        return collected[:limit]

    async def _convert_to_matched_contexts(
        self,
        candidates: List[Dict[str, Any]],
        ctx: RequestContext,
    ) -> List[MatchedContext]:
        """Convert candidate results to MatchedContext list. 终态评分：叠加热度并重排。

        把语义相似度（已含分数传播）与热度分（来自 active_count + updated_at）
        按 hotness_alpha 混合。hotness_alpha=0 时关闭热度 boost。
        """
        results = []
        for c in candidates:
            relations = []

            semantic_score = c.get("_final_score", c.get("_score", 0.0))
            # Fix: clamp inf/nan scores from vector search (#inf-score)
            if not math.isfinite(semantic_score):
                semantic_score = 0.0

            alpha = self.hotness_alpha
            if alpha > 0:
                updated_at_raw = c.get("updated_at")
                if isinstance(updated_at_raw, str):
                    try:
                        updated_at_val = parse_iso_datetime(updated_at_raw)
                    except (ValueError, TypeError):
                        updated_at_val = None
                elif isinstance(updated_at_raw, datetime):
                    updated_at_val = updated_at_raw
                else:
                    updated_at_val = None

                h_score = hotness_score(
                    active_count=c.get("active_count", 0),
                    updated_at=updated_at_val,
                )
                final_score = (1 - alpha) * semantic_score + alpha * h_score
            else:
                final_score = semantic_score
            if not math.isfinite(final_score):
                final_score = 0.0
            level = c.get("level", 2)
            display_uri = self._append_level_suffix(c.get("uri", ""), level)

            results.append(
                MatchedContext(
                    uri=display_uri,
                    context_type=ContextType(c["context_type"])
                    if c.get("context_type")
                    else ContextType.RESOURCE,
                    level=level,
                    abstract=c.get("abstract", ""),
                    category=c.get("category", ""),
                    score=final_score,
                    relations=relations,
                )
            )

        # Re-sort by blended score so hotness boost can change ranking
        results.sort(key=lambda x: x.score, reverse=True)
        return results

    @classmethod
    def _append_level_suffix(cls, uri: str, level: int) -> str:
        """Return user-facing URI with L0/L1 suffix reconstructed by level.

        按 level 重建 .abstract.md / .overview.md 后缀，使用户面 URI 与层级一致。
        """
        suffix = cls.LEVEL_URI_SUFFIX.get(level)
        if not uri or not suffix:
            return uri
        if uri.endswith(f"/{suffix}"):
            return uri
        if uri.endswith("/.abstract.md") or uri.endswith("/.overview.md"):
            return uri
        if uri.endswith("/") and not uri.endswith("://"):
            uri = uri.rstrip("/")
        return f"{uri}/{suffix}"
```

> **检索内核要点**：`retrieve()` 是五层编排入口--embed query 一次产双向量 -> 全局向量搜索补起点 -> 合并起点（rerank 起点分数）-> 优先级队列递归 -> 终态热度叠加。`_recursive_search()` 用 `heapq` 优先级队列 + `MAX_PARALLEL_CHILD_SEARCHES=4` 并发展开 + 双条件收敛检测（top-K 不变 / 池大小不变，连续 `MAX_CONVERGENCE_ROUNDS=3` 轮即停）。分数传播 `alpha * child + (1-alpha) * parent` 在递归中即时混合。`_rerank_scores()` 三道 fallback 保证 rerank 不拖垮 RAG。`_convert_to_matched_contexts()` 终态叠加 `hotness_alpha` 热度并重排（热度 boost 可改变排名）。
