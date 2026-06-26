# Implementation Notes — enterprise-rag-knowledge-base

> 落地档案：本文档把 RAG 检索内核拆成 6 段（组件矩阵 / 关键调用时序 /
> 数据契约 / 不变量 / 常见踩坑 / 调参旋钮 + 调试入口），对应 `<rag-pkg>/`
> 下的层级检索实现。所有路径均为占位，请按自己工程的目录前缀映射。

---

## 1. 组件矩阵

| 层 | 角色 | 关键类型 / 函数 | 位置（占位） | 关键 API |
|---|------|----------------|-------------|----------|
| 0. 入口 | 总编排器 | `HierarchicalRetriever` | `<rag-pkg>/retrieval/hierarchical_retriever.py` | `retrieve(query, ctx, limit, mode, level=...) → QueryResult` |
| 1. 查询重写 | 意图分析 | `IntentAnalyzer` | `<rag-pkg>/retrieval/intent_analyzer.py` | `analyze(summary, msgs, current, ctx_type, target_abstract) → QueryPlan` |
| 1. 查询重写 | 查询契约 | `TypedQuery` dataclass | 同上 | `query / context_type / intent / priority(1..5) / target_directories` |
| 1. 查询重写 | 提示路由 | `resolve_intent_analysis_prompt_id(planner)` | 同上 | 按 `planner.model` 选择 prompt id；未命中走默认 |
| 2. Embedding | 抽象基类 | `EmbedderBase / DenseEmbedderBase / SparseEmbedderBase / HybridEmbedderBase` | `<rag-pkg>/embedder/base.py` | `embed_async(content, is_query=True) → EmbedResult` |
| 2. Embedding | 双路融合 | `CompositeHybridEmbedder` | 同上 | 内部 `asyncio.gather(dense.embed_async, sparse.embed_async)` |
| 2. Embedding | 入口适配 | `embed_compat(embedder, content, is_query)` | 同上 | 统一处理多模态降级 + `bind_telemetry_stage("embed_query")` |
| 2. Embedding | 输入规范 | `truncate_and_normalize` | 同上 | 截断到 `dimension`，按 L2 归一化 |
| 3. 向量后端 | 双向量检索 | `VectorCollection.search_by_vector(dense, sparse, ...)` | `<rag-pkg>/vector/qdrant_collection.py` | dense + sparse 同时给则走 `prefetch + query: {"fusion": "rrf"}` |
| 3. 向量后端 | 稀疏编码 | `_sparse_to_qdrant(sparse_vector)` | 同上 | `xxhash → uint32` 折叠为后端可索引整数；碰撞采用 weight 合并 |
| 3. 向量后端 | Proxy | `VectorDBProxy(store, ctx)` | `<rag-pkg>/vector/proxy.py` | 绑定 ctx 后暴露 `search_global_roots_in_tenant / search_children_in_tenant` |
| 4. Rerank | 客户端 | `RerankClient.from_config(cfg)` | `<rag-pkg>/rerank/<provider>.py` | `rerank_batch(query, docs) → list[float] | None` |
| 4. Rerank | Fallback | `HierarchicalRetriever._rerank_scores(...)` | 1 入口同 | 服务挂 / 长度不匹配 / 异常 → 返回向量分 |
| 5. 多因子打分 | 热度 | `hotness_score(active_count, updated_at, half_life_days)` | `<rag-pkg>/memory/memory_lifecycle.py` | `sigmoid(log1p(N)) × exp(-ln2/τ · Δt)` |
| 5. 多因子打分 | 父子传播 | `α_prop · child + (1-α_prop) · parent` | retriever 内 | 在 `_recursive_search` 中即时混合 |
| 5. 多因子打分 | 终态打分 | `_convert_to_matched_contexts` | 同上 | 在最终输出前再叠加 `α_hot · hotness` |
| 6. 观测 | 单查询打点 | `RetrievalStatsCollector.record_query(...)` | `<rag-pkg>/retrieval/retrieval_stats.py` | 线程安全 singleton，监控/巡检读 `snapshot()` |
| 6. 观测 | 计数器 | `telemetry.count("vector.searches" / "vector.scored" / "vector.passed", n)` | 同上 | 每路递归独立计数 |

---

## 2. 关键调用时序（一次 `retrieve` 的全链路）

```
HierarchicalRetriever.retrieve(query, ctx, limit=K, mode)
│
├─ vector_proxy = VectorDBProxy(store, ctx)
├─ vector_proxy.collection_exists_bound() → False 则空 QueryResult
│
├─ [1] embed_compat(embedder, query.query, is_query=True)
│        └─ telemetry.measure("search.embed_query")
│        └─ CompositeHybridEmbedder.embed_async →
│             asyncio.gather(dense.embed_async, sparse.embed_async)
│        ← EmbedResult(dense_vector, sparse_vector)
│
├─ [2] 起点确定：query.target_directories 或 default_target_directories(ctx, type)
│
├─ [3] _global_vector_search(query_vec, sparse_vec, ctx_type, target_dirs, scope_dsl, limit=max(K,10))
│        └─ vector_proxy.search_global_roots_in_tenant(...)
│              └─ collection.search_by_vector(dense, sparse, filter=租户+类型+scope_dsl)
│                    └─ 双向量在场：prefetch×2 + {"fusion": "rrf"}
│        ← list[dict]，含 uri / level / abstract / _score
│        telemetry.count("vector.searches" / "vector.scored" / "vector.scanned")
│
├─ [4] _merge_starting_points(query, root_uris, global_results, mode)
│        └─ thinking 模式：对全局命中里 level != 2 的项做 rerank 摘要打分
│             _rerank_scores(query, [abstract...], fallback=raw _score)
│        ├─ 通过摘要分数的目录加入起点
│        └─ root_uris 中尚未出现的，按 score=0 兜底
│
├─ [5] _prepare_initial_candidates：把全局命中里 level ∈ filter 的项预放入 pool，
│        thinking 模式同样 rerank 一次保存 `_score`
│
├─ [6] _recursive_search（堆 + 异步并行）
│        priority_queue: heappush(-score, uri)
│        while queue:
│          batch = 取前 N（N = MAX_PARALLEL_CHILD_SEARCHES）
│          asyncio.gather(*[vector_proxy.search_children_in_tenant(parent_uri,
│                              query_vec, sparse_vec, ctx_type, target_dirs, scope_dsl,
│                              limit=max(K*2, 20)) for parent_uri, _ in batch])
│          for child in results:
│            score = rerank(child.abstract) if thinking else child._score
│            final = α_prop·score + (1-α_prop)·parent_score   # 当 parent>0
│            if final <= threshold: continue
│            level ∈ filter → 入 pool（去重保留最大）
│            child.level != 2 → 入 queue 继续递归
│          收敛检测：连续 MAX_CONVERGENCE_ROUNDS 轮 topK 不变 或 pool 不增长 → break
│
├─ [7] _convert_to_matched_contexts(candidates, ctx)
│        for each c:
│          semantic = clamp_finite(c._final_score)
│          if α_hot > 0:
│             h = hotness_score(c.active_count, c.updated_at, half_life=τ)
│             final = (1-α_hot)·semantic + α_hot·h
│          uri = _append_level_suffix(uri, level)   # 0→.abstract.md / 1→.overview.md
│        results.sort(score desc)
│
├─ [8] RetrievalStatsCollector.record_query(ctx_type, len(final), scores, latency_ms, rerank_used)
└─ return QueryResult(query, matched_contexts[:K], searched_directories)
```

---

## 3. 数据契约

```python
@dataclass
class EmbedResult:
    dense_vector:  list[float] | None        # 已 L2 归一化、维度 = dim
    sparse_vector: dict[str, float] | None   # {term: weight}，学习型稀疏（非 BM25）

@dataclass
class TypedQuery:
    query: str
    context_type: ContextType                # RESOURCE / MEMORY / SKILL
    intent: str
    priority: int                            # 1..5
    target_directories: list[str] | None     # 显式指定起点目录，可为空

@dataclass
class QueryPlan:
    queries: list[TypedQuery]
    session_context: str
    reasoning: str

@dataclass
class MatchedContext:
    uri: str                                 # 带 .abstract.md / .overview.md 后缀
    context_type: ContextType
    level: int                               # 0=abstract / 1=overview / 2=detail
    abstract: str
    category: str
    score: float                             # propagated × (1-α_hot) + hotness × α_hot
    relations: list[RelatedContext]

@dataclass
class QueryResult:
    query: TypedQuery
    matched_contexts: list[MatchedContext]
    searched_directories: list[str]
```

向量后端返回原始 dict 至少包含：
`uri / level / abstract / category / context_type / account_id / _score / updated_at / active_count`。
Retriever 在 pool 里挂载 `_final_score`（传播后），最终输出再混入 hotness。

---

## 4. 不变量

1. **Query 重写不可省**：用户自然语言常多意图混合，直接喂单一向量召回质量塌一档。
2. **Dense + Sparse 一次性产出**：用 `asyncio.gather`，禁止串行两次 embed。
3. **融合用 RRF 不用加权和**：dense cosine ∈ [-1,1]、sparse 内积 ∈ [0,+∞)，量纲不可比；
   后端实现见 `prefetch + query:{fusion:"rrf"}`。
4. **Rerank 输入用 L0 abstract**：~100 token，既快又精准；cross-encoder 截断全文反降精度。
5. **Rerank 必须 fallback**：Provider 异常 / score 数 ≠ docs 数 / 非数值 → 退回向量分。
6. **L2 是终态文件**：只有 `level != 2` 的节点（目录）才入 priority queue 继续递归。
7. **双信号收敛**：top-K 集合 + pool 总长度都纳入"连续 N 轮不变即停"。
8. **finite 兜底**：向量得分可能出现 `inf/nan`（短文本极端），所有阶段 clamp 为 0.0。
9. **稀疏键持久化要可重放**：term → bucket 用稳定哈希（xxh64 折叠到正 int32），碰撞合并 weight。
10. **Query embedding 必须传 `is_query=True`**：很多模型 query / document 用不同 prefix（asymmetric）。
11. **租户隔离在 Proxy 层而非 Collection 层**：所有 `search_*` 都通过 `VectorDBProxy(store, ctx)`，
    禁止业务层直连 `collection.search_by_vector`。
12. **观测必须在最外层 try-finally 之外不影响主流程**：`record_query` / telemetry 任何异常吞掉。

---

## 5. 常见踩坑

1. **把用户原话直接喂向量检索**：多意图被均值化、近义词无召回。
2. **加权和融合 dense + sparse**：α 永远调不对；用 RRF 让排名做归一。
3. **分两次 embed**：延迟翻倍；接口配额浪费一半。
4. **Rerank 输入全文**：cross-encoder 截断后等价随机；只喂 abstract。
5. **Rerank 异常往上抛**：整套 RAG 不可用；必须 try / fallback。
6. **flat top-K**：无全局视野、无解释；用层级 + abstract 提供"路径感"。
7. **递归不收敛**：大目录树跑飞；必须 `MAX_CONVERGENCE_ROUNDS` + visited set。
8. **直接拿向量分作为最终分**：忽略热度（常用沉底）+ 拓扑结构。
9. **embed query 不传 `is_query=True`**：对 asymmetric 模型精度直降一档。
10. **当稀疏 = BM25 倒排**：学习型稀疏（SPLADE / 类 BGE-M3 sparse）能学语义扩展，强很多。
11. **`prefetch.limit` 设得太小**：每路 K 个候选给 RRF 不够看；保守用 `max(K*4, K+8, 50)`。
12. **稀疏向量空 dict 仍走 hybrid 分支**：要在调用前判空，否则后端报 400。
13. **不 clamp `_score` 为有限数**：sort 时 NaN 行为未定义，topK 可能错乱。
14. **rerank score 类型混杂**：provider 偶尔返回 `null / str`，要逐项 `isinstance(int,float)` 校验。
15. **跨 event loop 共享 semaphore**：embed 并发限流要 per-loop 持有（weakref 字典）。

---

## 6. 调参旋钮 + 调试入口

### 6.1 调参

| 配置项 | 默认 | 影响 | 建议 |
|--------|------|------|------|
| `retrieval.score_propagation_alpha` (α_prop) | 1.0 | 子分权重；< 1 时父分参与 | 目录质量稳定时调到 0.7~0.9 |
| `retrieval.hotness_alpha` (α_hot) | 0.0 | 热度权重；0 关闭 | 长期对话场景 0.1~0.2 |
| `retrieval.half_life_days` (τ) | 7.0 | 热度衰减半衰期 | 短期任务 3，长期资料库 14~30 |
| `retrieval.rerank_threshold` | 0.30 | 通过分阈值 | 召回不足降到 0.2，精度优先升到 0.4 |
| `retrieval.global_search_topk` | 10 | 全局起点候选数 | 候选过少首轮迷路；过多 rerank 浪费 |
| `MAX_PARALLEL_CHILD_SEARCHES` | 4 | 同时递归 N 个目录 | 远端向量库并发限制时下调 |
| `MAX_CONVERGENCE_ROUNDS` | 3 | top-K 连续 N 轮不变即停 | 大库可调到 4~5 |
| `DIRECTORY_DOMINANCE_RATIO` | 1.2 | 目录分压制子节点的阈值 | 多目录抢分严重时上调 |
| `DEFAULT_HYBRID_PREFETCH_LIMIT` (后端) | 50 | RRF 每路预取量 | 减小召回；增大精度但贵 |
| RRF `k` | 60 | 抑制低 rank 影响 | 标准做法不改 |
| `embedder.dense.dim` | 1024 | 与模型一致 | 不能随意截断；改维度要重建集合 |
| `embedder.max_concurrent` | 10 | embedding 并发 | per-loop semaphore 限流 |
| `MAX_COMPRESSION_SUMMARY_CHARS` | 30000 | 意图分析输入上限 | 约 10K token，与 planner 上下文窗口对齐 |

### 6.2 公式总览

```
RRF(d) = Σ_i 1 / (k + rank_i(d))         # i ∈ {dense, sparse}
propagated = α_prop·score_child + (1-α_prop)·score_parent
hotness    = sigmoid(log1p(active_count)) · exp(-ln2/τ · age_days)
final      = (1-α_hot)·propagated + α_hot·hotness
```

### 6.3 调试入口

- **Telemetry 阶段计时**：`telemetry.measure("search.embed_query" | "search.vector_retrieval")`
  自动产出 wall-clock + 候选数 + 通过数。
- **统计快照**：`get_stats_collector().snapshot()` 拿到 `total_queries / zero_result_rate /
  avg_results_per_query / avg_score / rerank_used / rerank_fallback / avg_latency_ms`，
  对接巡检接口或 Prometheus。
- **可视化轨迹**：把 `_recursive_search` 内每次 `visit` 记成
  `(round, parent_uri, parent_score, children: [(uri, raw, rerank, final, kept?)])`，
  直接画成森林图，看清剪枝边界。
- **向量后端调试**：开 DEBUG 级别看 `prefetch + fusion` 请求体，确认 `using` 名字、
  filter 结构、prefetch 的两个 limit 是否够大。
- **意图分析回归**：保留 `IntentAnalyzer` 的 `reasoning` 字段做事后诊断，
  线下用同一 planner 复现 QueryPlan 做 A/B。
- **稀疏权重健康度**：定期统计 `sparse_vector` 平均非零项数；< 5 通常意味
  sparse encoder 退化为停用词过滤，需要切回 SPLADE 类模型。

---

## 相关 skill

- [[memory-system-design]] 热度衰减、active_count 更新策略与生命周期
- [[tool-assembly-and-policy]] 把 retriever 暴露成 agent 工具 + 速率门控
- [[observability-tracing]] telemetry 阶段 / token usage / stats collector 串成 trace
- [[context-window-management]] L0/L1/L2 摘要分层与 prefix cache 友好的注入
- [[skill-system-design]] retrieval 结果作为 skill metadata 的可发现性接入

参考论文：Cormack et al., "Reciprocal Rank Fusion outperforms Condorcet and individual Rank Learning Methods", SIGIR 2009.
