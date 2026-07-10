---
name: enterprise-rag-knowledge-base
description: 设计企业级 RAG 知识库的"文件系统范式 + 三层索引 + 五层检索内核"。覆盖 L0/L1/L2 三层知识库（abstract/overview/detail）与 ContextFS 文件系统范式（kb:// URI、目录即节点），五层检索内核（IntentAnalyzer 查询重写 / dense+sparse 双向量 / RRF 混合融合 / RerankClient 精排 / score_propagation+hotness 多因子评分），层级递归优先级队列检索与收敛检测，以及通过 LangChain retriever/tools + REST API 对接 agent 的方式。链路位置：⑥执行（RAG 作为检索工具）。当你要设计企业级 RAG、做层级检索、调双向量 RRF 融合、加 rerank fallback、调热度/传播评分旋钮、把知识库暴露为 agent 工具时调用本 skill。
---

## 何时用

- 设计/重构企业级 RAG，遇到这些症状之一：
  - 单条 query 召回不全（"OAuth 怎么用"召回不到「JWT token 颁发」之类的近义内容）
  - 关键字精确匹配 vs 语义召回顾此失彼
  - flat top-K 缺全局视野，需要"按目录/项目分组深入"
  - 检索黑盒，无法解释为什么排第 1 的不是想要的
  - 老用户/常访问内容总是排到后面，新文档抢分
- 要把知识库以"文件系统"范式组织（目录即节点、URI 即路径、abstract/overview 分层摘要）
- 要把 RAG 检索能力通过 LangChain retriever / StructuredTool / REST API 暴露给 agent

## 设计方案（为什么这么设计）

### 核心矛盾：语义召回质量 vs 可解释性 vs 检索成本

企业知识库不是"一堆文档扔进向量库 top-K"就能用。真实诉求是：多意图混合的用户消息要拆开查、命名实体和近义表述都要命中、沿目录结构深入找高相关子树、常用内容要 boost 而过时内容要降权、且整个过程可解释、可调参、可降级。单靠"一次 embedding + flat top-K"无法同时满足。

### 解法：文件系统范式 + 三层索引 + 五层检索内核

把知识库组织成**文件系统**（ContextFS）：每个目录是一个节点，挂载 `kb://` URI；每个目录有两份摘要文件 `.abstract.md`（L0）和 `.overview.md`（L1），叶子文件本身是 L2。检索不是对 flat 向量做 top-K，而是**沿目录树递归深入**，每层 search 子节点 → rerank → 通过阈值 → 入结果池 / 入队继续递归 → 收敛检测停。

```
# 伪代码：三层索引 + 文件系统范式
# L0 (.abstract.md):  目录的一句话摘要 ~100 token，rerank 输入用这层
# L1 (.overview.md):  目录的中等粒度概览
# L2 (文件本身):      完整内容，向量索引的 detail 层

kb://resources/auth/.abstract.md     # L0: "认证模块：OAuth2/JWT/SSO"
kb://resources/auth/.overview.md     # L1: "包含 token 颁发、刷新、吊销..."
kb://resources/auth/jwt-guide.md     # L2: 完整 JWT 指南
```

### 五层检索内核

```
┌─────────────────────────────────────────────────────────────────────┐
│  1) Query Rewrite (IntentAnalyzer / LLM)                             │
│     单 query -> N×TypedQuery(query, context_type, intent, priority)   │
│     0 条 = 无需检索（闲聊/确认）；每条带 context_type 进各自 root dir │
└──────────────┬──────────────────────────────────────────────────────┘
               ▼  (按 context_type 选 root dir)
┌─────────────────────────────────────────────────────────────────────┐
│  2) Dual Embedding (一次产出双向量)                                  │
│     query -> EmbedResult(dense_vector, sparse_vector)                 │
│       - dense:  L2-normalized float[D]            语义召回           │
│       - sparse: {term: weight}                    关键字 / 命名实体  │
│     CompositeHybridEmbedder 用 asyncio.gather 并发产双向量            │
└──────────────┬──────────────────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  3) Hybrid Retrieval @ Vector Store (prefetch + RRF)                │
│     prefetch dense  -> top-N₁                                         │
│     prefetch sparse -> top-N₂                                         │
│     fusion = "rrf"   ->  score = Σ 1/(k + rank_i)                     │
│     纯 dense / 纯 sparse 自动退化（一路缺失不拖垮全流程）            │
└──────────────┬──────────────────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  4) Cross-Encoder Rerank (THINKING mode)                             │
│     model(query, doc.abstract) -> score; 失败 fallback 到向量分       │
│     输入用 L0 abstract（~100 token）而非全文                         │
└──────────────┬──────────────────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  5) Multi-factor Score (传播 + 热度)                                 │
│     a) 子分 (rerank or vector)                                       │
│     b) 父分传播: propagated = α_prop * 子 + (1-α_prop) * 父          │
│     c) 热度分: hotness = sigmoid(log1p(active_count)) × exp(-λ·age)  │
│     final = (1-α_hot) * 语义 + α_hot * hotness                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 关键设计决策

1. **Query 重写是检索的入口，不是可选优化**。用户自然语言往往多意图混合，LLM 拆成多条带 `context_type` 的 TypedQuery，每条进各自的 root 目录单独检索后合并。`IntentAnalyzer` 支持按 `query_planner` 模型路由不同 prompt（含 SFT 小模型），0 条 query = 无需检索。

2. **Dense + Sparse 必须并行且一次产出**。纯 dense 漏命名实体/罕见词，纯 sparse 漏近义/转述。`CompositeHybridEmbedder` 用 `asyncio.gather` 并发调 dense 和 sparse 两个 embedder 到同一个 `EmbedResult`，不分两次调 API。

3. **融合用 RRF 不用加权和**。加权和需要把 dense/sparse 分数归一化到同一量纲（数值范围、分布都不同，做不好），RRF 只看 rank 不看绝对值：`score(d) = Σ_i 1/(k + rank_i(d))`，天然 cross-modality 安全。向量库后端在 prefetch 完两路后用 `query: {"fusion": "rrf"}` 直接做。

4. **Rerank 仅在 THINKING 模式开，失败必须 fallback**。Cross-encoder rerank 慢（一次 batch 10-50ms），QUICK 模式直接走向量分；rerank 失败/长度不匹配/异常 → fallback 到向量分，不能让 rerank 服务挂掉拖垮整个 RAG。Rerank 输入是文档的 L0 abstract（~100 token）而非全文。

5. **分数有"传播 + 热度"两个旋钮**。`α_propagation`：子目录分数受父目录分数影响的程度（`α=1.0` 纯子分，`α=0.7` 给高分父目录下的孩子加权）。`α_hotness`：访问热度对最终分数的贡献（`α_hot=0` 关闭，`α_hot=0.2` = 80% 语义 + 20% 热度）。热度公式 `sigmoid(log1p(active_count)) × exp(-ln2/half_life × age)` 让"被访问过"且"近期更新"的内容高分。

6. **检索是层级的，不是 flat top-K**。从 root 出发，优先级队列按当前分数推进；每层 search 子节点 → rerank → 通过阈值 → 进结果池 / 入队继续递归 → 拓扑收敛检测（top-K 连续 N 轮不变即停，或池大小连续 N 轮不变即停）。这给了"沿高相关目录深入"的能力，但靠收敛检测控制爆炸。

7. **文件系统范式让知识库可浏览可解释**。`ContextFS` 把目录当节点、URI 当路径，`abstract()`/`overview()`/`find()`/`search()`/`grep()`/`glob()` 是一等 API。agent 可以先 `kb_browse` 看结构，再 `kb_search` 语义查，再 `kb_read` 读全文——检索不再是黑盒。

### 关键不变量（违反则召回崩塌或行为错乱）

1. `embed_query` 必须传 `is_query=True`——很多 embedder 对 query 与 document 用不同 prefix（如 BGE 的 `"query: "` vs `"passage: "`），用错侧 prefix 召回率掉一档。
2. RRF 只看 rank 不看绝对分数——dense cosine ∈ [-1,1]，sparse 内积 ∈ [0,+∞)，量纲完全不可比；RRF 规避归一化难题。
3. Rerank 失败必须 fallback 到向量分，不能抛异常中断检索。
4. 层级递归必须带收敛检测——top-K 连续 `MAX_CONVERGENCE_ROUNDS` 轮不变、或结果池大小连续 N 轮不变即停，否则大目录树跑飞。
5. 稀疏向量是 `{term: weight}` 而非 BM25 倒排表——是 query-time 学习出来的（SPLADE/学习型稀疏），能学语义扩展，这才是 hybrid 比 BM25+dense 更强的原因。
6. `level` 过滤必须一致：L2 文件是终端命中（入结果池不入队），只有 L0/L1 目录入队继续递归。
7. 热度公式中 `updated_at` 为 `None` 时热度直接返回 0.0——"从未更新"的内容不 boost。

### 在端到端链路中的位置

RAG 检索是 agent 执行阶段（⑥执行）的**检索工具**。agent 通过 `kb_search` / `kb_find` 工具或 `HelixRagRetriever` 向 ContextFS 发起语义检索，ContextFS 内部走 `HierarchicalRetriever.retrieve` 五层内核，返回 `FindResult`（按 memory/resource/skill 分组的 `MatchedContext` 列表）。agent 拿到 URI + abstract 后，再用 `kb_read` 按需拉取全文。

**关键联动**（见 [[e2e-request-lifecycle]]）：检索发生在 agent 决定"需要外部知识"之后、生成回答之前。`search()` 带 session 上下文时走 `IntentAnalyzer` 拆 query；`find()` 无状态直接单 query 检索。检索结果通过工具返回值注入 agent 上下文，与 [[memory-system-design]] 的 8 类 memory 对照、与 [[context-window-management]] 的 token 预算协同。

### 伪代码：层级递归检索全链路

```python
# 伪代码：HierarchicalRetriever.retrieve 核心链路（完整源码见 references）
async def retrieve(query: TypedQuery, ctx, limit, mode="thinking"):
    # ① embed query 一次产双向量
    embed_result = await embed_compat(embedder, query.query, is_query=True)
    dense_q, sparse_q = embed_result.dense_vector, embed_result.sparse_vector

    # ② 全局向量搜索补起点候选（后端走 RRF）
    global_results = await vector_proxy.search_global_roots_in_tenant(
        dense_q, sparse_q, context_type=query.context_type, limit=max(limit, 10))

    # ③ 合并起点：global 命中的 L0/L1 目录 + root_uris，rerank 起点分数
    starting_points = self._merge_starting_points(query.query, root_uris, global_results, mode)

    # ④ 优先级队列递归
    candidates = await self._recursive_search(
        vector_proxy, query.query, dense_q, sparse_q,
        starting_points, limit, mode, threshold, ...)

    # ⑤ 多因子评分：传播(已在递归中) + 热度(在此叠加) + 重排
    matched = await self._convert_to_matched_contexts(candidates, ctx)  # 叠加 hotness
    return QueryResult(query=query, matched_contexts=matched[:limit], ...)

# 伪代码：递归搜索 + 收敛检测
async def _recursive_search(..., starting_points, limit, threshold):
    dir_queue = []          # 优先级队列: (-score, uri)
    visited, collected = set(), {}
    convergence_rounds = stagnant_rounds = 0
    prev_topk_uris, prev_pool_size = set(), 0

    for uri, score in starting_points:
        heapq.heappush(dir_queue, (-score, uri))   # 起点入队

    while dir_queue:
        batch = pop_up_to(dir_queue, MAX_PARALLEL_CHILD_SEARCHES)  # 并发展开 4 个目录
        results_per_dir = await asyncio.gather(*[search_children(uri) for uri, _ in batch])

        for (parent_uri, parent_score), results in zip(batch, results_per_dir):
            scores = rerank_or_fallback(query, [r["abstract"] for r in results],
                                        [r["_score"] for r in results]) if THINKING else vec_scores
            for r, child_score in zip(results, scores):
                # 父子传播: α_prop * child + (1-α_prop) * parent
                final = alpha * child_score + (1-alpha) * parent_score if parent_score else child_score
                if not passes_threshold(final): continue
                if r["uri"] not in collected or final > collected[r["uri"]]["_final_score"]:
                    collected[r["uri"]] = {**r, "_final_score": final}
                if r.get("level", 2) != 2 and r["uri"] not in visited:  # 只有目录入队
                    heapq.heappush(dir_queue, (-final, r["uri"]))

        # 收敛检测: top-K 连续 3 轮不变 / 池大小连续 3 轮不变 -> 停
        current_topk_uris = {c["uri"] for c in sorted(collected.values(), key=-_final_score)[:limit]}
        if current_topk_uris == prev_topk_uris and len(current_topk_uris) >= limit:
            convergence_rounds += 1
            if convergence_rounds >= MAX_CONVERGENCE_ROUNDS: break
        elif len(collected) == prev_pool_size:
            stagnant_rounds += 1
            if stagnant_rounds >= MAX_CONVERGENCE_ROUNDS: break
        else:
            convergence_rounds = stagnant_rounds = 0
            prev_topk_uris, prev_pool_size = current_topk_uris, len(collected)

    return sorted(collected.values(), key=-_final_score)[:limit]

# 伪代码：多因子终态评分（传播在递归中已做，此处叠加热度）
def _convert_to_matched_contexts(candidates, cfg):
    for c in candidates:
        semantic = c["_final_score"]  # 已含传播
        if cfg.hotness_alpha > 0:
            h = hotness_score(c["active_count"], c["updated_at"], half_life_days=7.0)
            final = (1 - cfg.hotness_alpha) * semantic + cfg.hotness_alpha * h
        else:
            final = semantic
        c["score"] = final if isfinite(final) else 0.0
    return sorted(candidates, key=-score)  # 热度 boost 可改变排名
```

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/rag/core/context.py` | `ContextLevel`(L0/L1/L2 枚举) + `Context` 统一上下文对象（uri/parent_uri/abstract/level/active_count） | [l0-l1-l2-tiering.md](./references/code/l0-l1-l2-tiering.md) §1 |
| `core/helix/rag/storage/collection_schemas.py` | `CollectionSchemas.context_collection` 向量库 schema（dense+sparse_vector+level+path 索引）+ `init_context_collection` embedding 元数据校验 | [l0-l1-l2-tiering.md](./references/code/l0-l1-l2-tiering.md) §2 |
| `core/helix/rag/parse/tree_builder.py` | `TreeBuilder`：v5.0 架构，Parser 建目录 → TreeBuilder 建 URI 元数据 → SemanticProcessor 异步生成 L0/L1 + 向量化 | [l0-l1-l2-tiering.md](./references/code/l0-l1-l2-tiering.md) §3 |
| `core/helix/rag/storage/queuefs/semantic_processor.py` | `SemanticProcessor`：自底向上生成 `.abstract.md`/`.overview.md`，DAG 并发 + 熔断 + 重入队 | [l0-l1-l2-tiering.md](./references/code/l0-l1-l2-tiering.md) §4 |
| `core/helix/rag/storage/context_fs.py` | `ContextFS`：文件系统范式核心（abstract/overview/read/write/find/search/grep/glob + kb:// URI 转换 + 向量索引同步） | [context-fs.md](./references/code/context-fs.md) |
| `core/helix/rag/retrieve/hierarchical_retriever.py` | `HierarchicalRetriever`：五层检索内核总编排（retrieve + 递归搜索 + 收敛检测 + 多因子评分） | [hierarchical-retriever.md](./references/code/hierarchical-retriever.md) |
| `core/helix/rag/retrieve/intent_analyzer.py` | `IntentAnalyzer`：LLM 查询重写，session 上下文 → N×TypedQuery，按 planner 模型路由 prompt | [intent-and-embed.md](./references/code/intent-and-embed.md) §1 |
| `core/helix/rag/models/embedder/base.py` | `EmbedResult`(dense+sparse) + `EmbedderBase`/`DenseEmbedderBase`/`SparseEmbedderBase`/`HybridEmbedderBase` + `CompositeHybridEmbedder`(asyncio.gather 并发) + `embed_compat` | [intent-and-embed.md](./references/code/intent-and-embed.md) §2 |
| `core/helix/rag/storage/vectordb/collection/qdrant_collection.py` | `QdrantCollection.search_by_vector`：dense+sparse prefetch + `fusion: "rrf"` 混合融合，纯 dense/sparse 退化，`/points/query` 失败 fallback `/points/search` | [rrf-and-rerank.md](./references/code/rrf-and-rerank.md) §1 |
| `core/helix/rag/models/rerank/base.py` + `__init__.py` | `RerankBase`（token 追踪）+ `RerankClient.from_config` 统一调度（volcengine/cohere/litellm/openai） | [rrf-and-rerank.md](./references/code/rrf-and-rerank.md) §2 |
| `core/helix/rag/retrieve/memory_lifecycle.py` | `hotness_score`：`sigmoid(log1p(active_count)) × exp(-ln2/half_life × age)` 纯函数 | [scoring.md](./references/code/scoring.md) §1 |
| `core/helix/rag/config/retrieval_config.py` | `RetrievalConfig`：`hotness_alpha` + `score_propagation_alpha` 两个评分旋钮 | [scoring.md](./references/code/scoring.md) §2 |
| `core/helix/rag/service/search_service.py` | `SearchService`：`find()`（无状态）/ `search()`（带 session）服务层 | [api-and-langchain.md](./references/code/api-and-langchain.md) §1 |
| `core/helix/rag/server/routers/search.py` | FastAPI 路由 `/api/v1/search/{find,search,grep,glob}` + `_sanitize_floats`(inf/nan→0.0) | [api-and-langchain.md](./references/code/api-and-langchain.md) §2 |
| `core/helix/rag/integrations/langchain/retrievers.py` | `HelixRagRetriever`：LangChain `BaseRetriever`，find/search → `Document`，content_mode 控制摘要/概览/全文 | [api-and-langchain.md](./references/code/api-and-langchain.md) §3 |
| `core/helix/rag/integrations/langchain/tools.py` | `create_rag_tools`：kb_find/kb_search/kb_browse/kb_read/kb_grep 等 StructuredTool 工厂 | [api-and-langchain.md](./references/code/api-and-langchain.md) §4 |
| `core/helix/rag/integrations/bot/tools/file_tools.py` | `KbSearchTool`/`KbListTool`/`KbGrepTool`/`KbGlobTool`/`KbMultiReadTool`：原生 Tool 基座暴露 RAG 给 agent | [api-and-langchain.md](./references/code/api-and-langchain.md) §5 |

### 模块入口与索引

**L0/L1/L2 三层索引构建**（完整源码见 [l0-l1-l2-tiering.md](./references/code/l0-l1-l2-tiering.md)）：
- `ContextLevel` 枚举：`ABSTRACT=0` / `OVERVIEW=1` / `DETAIL=2`。URI 命名规则：`{目录}/.abstract.md`(L0)、`{目录}/.overview.md`(L1)、`{文件路径}`(L2)。
- `CollectionSchemas.context_collection`：向量库 schema 含 `vector`(dense) + `sparse_vector` + `level` + `uri`(path 类型) + `active_count` + `context_type`，标量索引覆盖 `uri/context_type/level/active_count/account_id/owner_user_id`。
- `TextEmbeddingHandler._seed_uri_for_id`：按 level 拼 deterministic id seed（`{account}:{uri}/.abstract.md`），md5 成 point id，保证同语义层幂等。
- v5.0 架构：Parser 建目录（无 LLM）→ TreeBuilder 建 URI 元数据 → ResourceProcessor 提交 → SemanticProcessor 异步生成 L0/L1 + 向量化。

**ContextFS 文件系统范式**（完整源码见 [context-fs.md](./references/code/context-fs.md)）：
- `init_context_fs` / `get_context_fs`：单例，注入 AGFS client + embedder + rerank_config + vector_store + retrieval_config。
- `abstract(uri)` / `overview(uri)`：读 `.abstract.md` / `.overview.md`，文件 URI 自动回退到父目录。
- `find(query, target_uri, limit, score_threshold, filter, level)`：无状态语义检索，内部构造 `TypedQuery` 调 `HierarchicalRetriever`，返回 `FindResult`（按 memory/resource/skill 分组）。
- `search(query, target_uri, session_info, ...)`：带 session 上下文，走 `IntentAnalyzer` 拆 query 后 `asyncio.gather` 并发检索多条 TypedQuery。
- `_uri_to_path` / `_path_to_uri`：`kb://{remainder}` ↔ `/local/{account_id}/{remainder}` 纯前缀替换，account 隔离。

**五层检索内核**（完整源码见 [hierarchical-retriever.md](./references/code/hierarchical-retriever.md)）：
- `HierarchicalRetriever.retrieve`：总编排，telemetry 打点 `search.embed_query` / `search.vector_retrieval`。
- `_recursive_search`：优先级队列 + `MAX_PARALLEL_CHILD_SEARCHES=4` 并发 + `MAX_CONVERGENCE_ROUNDS=3` 收敛检测（top-K 不变 / 池大小不变双条件）。
- `_rerank_scores`：rerank fallback 三道防线（无 client/异常/长度不匹配 → 向量分）。
- `_convert_to_matched_contexts`：终态叠加 `hotness_alpha` 热度并重排。
- 常量：`GLOBAL_SEARCH_TOPK=10`、`LEVEL_URI_SUFFIX={0:".abstract.md", 1:".overview.md"}`、`DIRECTORY_DOMINANCE_RATIO=1.2`。

**查询重写与双向量**（完整源码见 [intent-and-embed.md](./references/code/intent-and-embed.md)）：
- `IntentAnalyzer.analyze`：session_summary + recent_messages + current_message → LLM → `QueryPlan`（N×TypedQuery）。`resolve_intent_analysis_prompt_id` 按 planner 模型路由 prompt id（含 SFT 模型映射）。
- `CompositeHybridEmbedder.embed_async`：`asyncio.gather(dense.embed_async, sparse.embed_async)` 一次产双向量到同一 `EmbedResult`。
- `embed_compat`：统一入口，多模态降级 + `bind_telemetry_stage("embed_query"/"embed_resource")`。
- `truncate_and_normalize`：截断到 dimension + L2 归一化。

**RRF 融合与 Rerank**（完整源码见 [rrf-and-rerank.md](./references/code/rrf-and-rerank.md)）：
- `QdrantCollection.search_by_vector`：dense+sparse 同时给 → `prefetch[dense, sparse] + query:{"fusion":"rrf"}`；`hybrid_prefetch_limit = min(max(fetch*4, fetch+8, 32), 256)`；`/points/query` 失败 fallback `/points/search`。
- `_sparse_to_qdrant`：`xxhash -> uint32` 折叠稀疏 term 为后端可索引整数，碰撞采用 weight 合并并告警。
- `RerankClient.from_config(rerank_config)`：统一调度 volcengine/cohere/litellm/openai rerank provider；`is_available()` 控制是否启用。

**评分旋钮**（完整源码见 [scoring.md](./references/code/scoring.md)）：
- `hotness_score(active_count, updated_at, half_life_days=7.0)`：`sigmoid(log1p(N)) × exp(-ln2/h × age)`，`updated_at=None` 返回 0.0。
- `RetrievalConfig`：`hotness_alpha`(0=关, 1=纯热度) + `score_propagation_alpha`(0=纯父分, 1=纯子分)，pydantic `ge=0.0, le=1.0`。

**Agent 对接**（完整源码见 [api-and-langchain.md](./references/code/api-and-langchain.md)）：
- `SearchService.find/search` → `ContextFS.find/search` → `HierarchicalRetriever.retrieve`。
- REST API：`POST /api/v1/search/{find,search,grep,glob}`，`_sanitize_floats` 递归把 inf/nan 替 0.0 保证 JSON 合规。
- `HelixRagRetriever`（LangChain `BaseRetriever`）：`search_mode="find"/"search"`、`content_mode="auto/abstract/overview/read"`、`metadata_prefix="helix_rag"`。
- `create_rag_tools`：`kb_find/kb_search/kb_browse/kb_read/kb_grep/kb_store/kb_archive_search/kb_archive_expand/kb_add_resource/kb_add_skill/kb_health/kb_forget`，按 profile（agent/retrieval/admin）选子集。
- `KbSearchTool`/`KbListTool`/`KbGrepTool`/`KbGlobTool`/`KbMultiReadTool`：原生 Tool 基座，`min_score` 过滤 + memory/resource/skill 分组 JSON 输出，`KbMultiReadTool` 用 `asyncio.Semaphore(10)` 并发读。

## 反模式与陷阱

- ❌ **不做 query 重写**直接把用户原话喂给向量检索 -> 多意图混合时 dense embedding 被"均值化"，每个意图都查得不准。修复：`search()` 带 session 上下文时走 `IntentAnalyzer` 拆 query。
- ❌ **加权和 dense + α·sparse** -> 量纲不可比（cosine ∈ [-1,1]，sparse 内积 ∈ [0,+∞)），α 永远调不对；用 RRF（只看 rank）。
- ❌ **dense / sparse 分两次 embed** -> 延迟翻倍；用 `CompositeHybridEmbedder` + `asyncio.gather` 一次产双向量。
- ❌ **Rerank 输入全文** -> cross-encoder 被迫截断（512-2048 token）；用 L0 abstract（~100 token）输入。
- ❌ **Rerank 服务失败抛异常** -> RAG 整体不可用；必须 `_rerank_scores` 三道 fallback 到向量分。
- ❌ **flat top-K 一次召回** -> 无全局视野、无解释；用层级优先级队列沿目录深入。
- ❌ **递归不带收敛检测** -> 大目录树跑飞；top-K 连续 3 轮不变 / 池大小连续 3 轮不变即停。
- ❌ **直接拿向量距离做最终分数** -> 忽略访问热度（常用内容沉底）和目录权威性（散落孤立文档抢分）。修复：`score_propagation_alpha` + `hotness_alpha`。
- ❌ **embed query 时不传 `is_query=True`** -> 用文档侧 prefix embed query，召回率掉一档。
- ❌ **关键字检索 = BM25 倒排** -> 学习型稀疏向量（SPLADE/BGE-M3 sparse）比 BM25 强一截，能学语义扩展。
- ❌ **稀疏 term 不 hash 直接当索引** -> Qdrant sparse 索引要 uint32；`_sparse_to_qdrant` 用 xxhash 折叠，碰撞合并 weight（否则静默丢 term）。
- ❌ **`/points/query` 失败不 fallback** -> 部分 Qdrant 版本/配置下 `/points/query` 不可用；必须 fallback 到 `/points/search`（dense-only）。
- ❌ **inf/nan 分数直接返回 JSON** -> `json.dumps` 抛 `ValueError` 或前端解析崩；`_sanitize_floats` 递归替 0.0，`_convert_to_matched_contexts` 也做 `isfinite` 兜底。
- ❌ **mv 后不更新向量索引 URI** -> 旧 URI 的向量成孤儿，新 URI 查不到；`_update_vector_store_uris` 必须在 cp 成功后、rm source 前执行，失败回滚 copy。
- ❌ **node_limit 直接 push 给后端 tree** -> ACL 过滤前截断会丢可见条目；用 `_TREE_OVERFETCH_FACTOR=4` 放大 raw 限制，不够再翻倍 re-fetch。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `hotness_alpha` | `RetrievalConfig` | 0=关热度；0.2=80% 语义 + 20% 热度；1=纯热度 |
| `score_propagation_alpha` | `RetrievalConfig` | 1.0=纯子分（默认）；0.7=父分影响子分（高分目录下的孩子加权） |
| `half_life_days` | `hotness_score` 参数 | 热度时间半衰期，默认 7.0 天 |
| `rerank_config.threshold` | `RerankConfig` | rerank 分数阈值，低于则不进结果池 |
| `rerank_config.is_available()` | `RerankConfig` | 是否启用 rerank（THINKING 模式才走） |
| `mode` | `retrieve(mode=)` | `THINKING`=走 rerank；`QUICK`=跳过 rerank 省 50ms |
| `GLOBAL_SEARCH_TOPK` | `HierarchicalRetriever` 常量 | 全局起点候选数（默认 10），越大 rerank 精度越高 |
| `MAX_PARALLEL_CHILD_SEARCHES` | `HierarchicalRetriever` 常量 | 并发递归目录数（默认 4），反压远端向量库 |
| `MAX_CONVERGENCE_ROUNDS` | `HierarchicalRetriever` 常量 | 收敛检测轮数（默认 3），top-K/池大小连续 N 轮不变即停 |
| `hybrid_prefetch_limit` | `QdrantCollection` | RRF prefetch 池 `min(max(fetch*4, fetch+8, 32), 256)` |
| `query_planner` | config | 查询重写专用模型（轻量/SFT），独立于主对话 model |
| `level` | `find/search(level=)` | 过滤返回层级：[0]=L0 abstract、[1]=L1 overview、[2]=L2 文件 |

**关键日志串**

- `[HierarchicalRetriever] Rerank enabled (provider=...), threshold=...` - rerank 启用
- `[HierarchicalRetriever] Rerank failed, fallback to vector scores: ...` - rerank fallback 触发
- `[RecursiveSearch] Entering URI: ...` - 递归进入目录
- `[RecursiveSearch] URI ... score ... did not pass threshold ...` - 阈值未过
- `[RecursiveSearch] Updated URI: ... candidate score to ...` - 候选分数更新
- `[ContextFS.find] Calling retriever.retrieve with ctx.account_id=..., ctx.user=...` - 检索入口（ContextFS 转发到 HierarchicalRetriever）
- `Qdrant sparse term hash collision detected; colliding terms are merged` - 稀疏 term hash 碰撞
- `Falling back to Qdrant /points/search for dense-only query because /points/query failed` - Qdrant fallback
- `IntentAnalyzer] Reasoning: ...` - 查询重写推理
- `search.typed_queries_count` / `vector.returned` / `vector.searches` / `vector.scored` / `vector.passed` - telemetry 打点

**自测方向**

- **双向量并发**：`CompositeHybridEmbedder.embed_async` 断言 dense 与 sparse 在同一 `EmbedResult`，且并发延迟 ≈ max(dense, sparse) 而非 sum。
- **RRF 融合**：构造 dense-only 命中 / sparse-only 命中的文档集，断言 hybrid 检索两者都召回。
- **纯 dense 退化**：sparse_vector=None 时 `search_by_vector` 走 `/points/query` dense-only，不抛异常。
- **Rerank fallback**：mock `rerank_batch` 抛异常 / 返回长度不匹配 / 返回 None，断言 `_rerank_scores` 返回向量分。
- **收敛检测**：构造深目录树，断言检索在 `MAX_CONVERGENCE_ROUNDS` 轮 top-K 不变后停，不无限递归。
- **层级过滤**：`level=[2]` 只返回 L2 文件，`level=[0]` 只返回 L0 abstract；L2 不入队继续递归。
- **热度叠加**：mock `active_count=100, updated_at=now`，断言 `hotness_alpha=0.2` 时高分被 boost、排名改变；`updated_at=None` 时热度=0。
- **分数传播**：`score_propagation_alpha=0.7`，构造高分父目录下的低分子文档，断言 final score 高于孤立高分文档。
- **inf/nan 兜底**：mock 向量返回 `inf` 分数，断言 `_sanitize_floats` 替 0.0、`_convert_to_matched_contexts` 的 `isfinite` 兜底。
- **IntentAnalyzer 0 query**：闲聊消息断言返回空 `QueryPlan`，不触发检索。
- **mv 向量同步**：mv 目录后断言旧 URI 向量删除、新 URI 向量可查；向量更新失败时 copy 回滚、source 完整。
- **LangChain retriever**：`HelixRagRetriever` 的 `content_mode="read"` 对 L2 文件调 read 拉全文，对 L0/L1 用 overview/abstract。
- **工具 profile**：`create_rag_tools(profile="retrieval")` 不含 `kb_store`/`kb_forget`；`profile="admin"` 含全部；`allow_forget=True` 才加 `kb_forget`。

## 进一步阅读

- L0/L1/L2 三层索引 + 构建管线源码：[references/code/l0-l1-l2-tiering.md](./references/code/l0-l1-l2-tiering.md)
- ContextFS 文件系统范式完整源码：[references/code/context-fs.md](./references/code/context-fs.md)
- HierarchicalRetriever 五层检索内核完整源码：[references/code/hierarchical-retriever.md](./references/code/hierarchical-retriever.md)
- IntentAnalyzer + 双向量 embedder 完整源码：[references/code/intent-and-embed.md](./references/code/intent-and-embed.md)
- RRF 融合 + Rerank 完整源码：[references/code/rrf-and-rerank.md](./references/code/rrf-and-rerank.md)
- hotness_score + RetrievalConfig 评分旋钮源码：[references/code/scoring.md](./references/code/scoring.md)
- SearchService + REST API + LangChain retriever/tools 完整源码：[references/code/api-and-langchain.md](./references/code/api-and-langchain.md)
- 关联 skill：[[memory-system-design]]（RAG memory 8 类对照）、[[tool-assembly-and-policy]]（RAG 工具暴露给 LLM）、[[observability-tracing]]（检索 trace 持久化）、[[context-window-management]]（L0 注入 token 预算）、[[subagent-delegation]]（目录递归检索封装为长任务子代理）、[[multi-user-isolation]]（多用户知识库隔离）、[[e2e-request-lifecycle]]（RAG 作为检索工具在执行阶段的位置）
- RRF 论文：Cormack et al., "Reciprocal Rank Fusion outperforms Condorcet and individual Rank Learning Methods", SIGIR 2009
