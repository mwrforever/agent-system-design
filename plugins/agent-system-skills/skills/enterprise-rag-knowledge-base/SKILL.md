---
name: enterprise-rag-knowledge-base
description: 设计企业级 RAG 知识库的"向量检索内核"——LLM 查询重写为 N 条 TypedQuery、Dense+Sparse 双向量 RRF 混合检索、Cross-Encoder Rerank、分数传播（α_propagation）+ 热度加权（α_hotness）多因子综合评分、目录优先级队列层级检索。提炼自生产级 RAG 系统实践。
---

## 何时用

- 设计/重构企业级 RAG，遇到这些症状之一：
  - 单条 query 召回不全（"OAuth 怎么用"召回不到「JWT token 颁发」之类的近义内容）
  - 关键字精确匹配 vs 语义召回顾此失彼
  - flat top-K 缺全局视野，需要"按目录/项目分组深入"
  - 检索黑盒，无法解释为什么排第 1 的不是想要的
  - 老用户/常访问内容总是排到后面，新文档抢分

## 检索内核：5 个真正决定召回质量的环节

```
┌─────────────────────────────────────────────────────────────────────┐
│  1) Query Rewrite (LLM)                                              │
│     单 query → N×TypedQuery(query, context_type, intent, priority)   │
└──────────────┬──────────────────────────────────────────────────────┘
               ▼  (按 context_type 选 root dir)
┌─────────────────────────────────────────────────────────────────────┐
│  2) Dual Embedding (一次产出双向量)                                  │
│     query → EmbedResult(dense_vector, sparse_vector)                 │
│       - dense:  L2-normalized float[D]            语义召回           │
│       - sparse: {term: weight}                    关键字 / 命名实体  │
└──────────────┬──────────────────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  3) Hybrid Retrieval @ Vector Store (Qdrant prefetch + RRF)         │
│     prefetch dense  → top-N₁                                         │
│     prefetch sparse → top-N₂                                         │
│     fusion = "rrf"   →  score = Σ 1/(k + rank_i)                     │
└──────────────┬──────────────────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  4) Cross-Encoder Rerank (THINKING mode)                             │
│     model(query, doc.abstract) → score; 失败 fallback 到向量分       │
└──────────────┬──────────────────────────────────────────────────────┘
               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  5) Multi-factor Score (4 个分数线性组合)                            │
│     a) 子分 (rerank or vector)                                       │
│     b) 父分（沿目录从父节点传播）                                    │
│        propagated = α_prop * 子 + (1-α_prop) * 父                    │
│     c) 语义分 (= propagated)                                         │
│     d) 热度分 hotness = sigmoid(log1p(active_count)) × exp(-λ·age)   │
│        final = (1-α_hot) * 语义 + α_hot * hotness                    │
└─────────────────────────────────────────────────────────────────────┘
```

## 设计思想

1. **Query 重写不是可选的优化，是检索的入口**。用户自然语言往往**多意图混合**（"先查我之前的偏好，再找 OAuth 文档，最后用 RFC skill 生成"），LLM 把它拆成多条带 `context_type` 的 TypedQuery，每条进各自的 root 目录单独检索后合并——比把杂烩 query 喂给单次向量检索召回质量高一个量级。

2. **Dense + Sparse 必须并行**，纯 dense 漏命名实体 / 罕见词，纯 sparse 漏近义/转述。**关键**：一次 embedding 同时产 `dense_vector + sparse_vector`，**不要分两次调 embed API**——生产实现常用 `CompositeHybridEmbedder` 模式 把 `OpenAIDenseEmbedder` 和 `SparseEmbedder` 用 `asyncio.gather` 并发到同一个 `EmbedResult`。

3. **融合用 RRF 不用加权和**：加权和需要把 dense / sparse 分数归一化到同一量纲（数值范围、分布都不同，做不好），RRF 只看 **rank** 不看绝对值：`score(d) = Σ_i 1/(k + rank_i(d))`，天然 cross-modality 安全。Qdrant 在 prefetch 完两路后用 `query: {"fusion": "rrf"}` 直接做。

4. **Rerank 仅在 THINKING 模式开**：Cross-encoder rerank 慢（一次 batch 10-50ms），QUICK 模式直接走向量分；rerank **失败必须 fallback** 到向量分，不能让 rerank 服务挂掉拖垮整个 RAG。Rerank 输入是文档的 **L0 abstract（~100 token）** 而非全文——既快又不污染上下文。

5. **分数有"传播 + 热度"两个旋钮**：
   - `α_propagation`：子目录的分数有多大程度受父目录分数影响。`α=1.0` = 纯子分（默认）；`α=0.7` = 给"高分父目录下的孩子"加权。**用途**：让"在`/docs/auth/` 这条高相关路径上"的文档比"散落在低相关路径上"的文档优先。
   - `α_hotness`：访问热度对最终分数的贡献。`α_hot=0` 关闭；`α_hot=0.2` = 80% 语义 + 20% 热度。**用途**：常用内容 boost、过时内容降权（半衰期默认 7 天）。

6. **检索是层级的，不是 flat top-K**：从 root 出发，**优先级队列**按当前分数推进；每层 search 子节点 → rerank → 通过阈值 → 进结果池 / 入队继续递归 → **拓扑收敛检测**（top-K 连续 N 轮不变即停）。这给了"沿高相关目录深入"的能力，但靠收敛检测控制爆炸。

7. **Telemetry 是一等公民**：每次 `embed_query / vector_retrieval / rerank` 都打点（耗时 + 候选数 + 通过数）；检索 trace 写到 `RetrievalStatsCollector`——上线后调 `α` / `threshold` 有据可查。

## 实现模板

### 1) Query 重写：从单 query 到 N 条 TypedQuery

```python
from dataclasses import dataclass
from typing import Literal

@dataclass
class TypedQuery:
    query: str                          # 改写后的子查询
    context_type: Literal["RESOURCE", "MEMORY", "SKILL"]
    intent: str                         # 意图说明（debug 用）
    priority: int                       # 1..5

INTENT_ANALYSIS_PROMPT = """\
You are a query planner. Decompose the user's current message into 0..5 TypedQueries.

Rules:
- Each TypedQuery has ONE context_type: RESOURCE | MEMORY | SKILL.
- RESOURCE queries are NOUN phrases ("OAuth 2.0 setup guide").
- SKILL queries are VERB-first ("Create RFC document", "Extract PDF tables").
- MEMORY queries are "User's XX" ("User's coding style preference").
- Empty array [] is valid for chit-chat / acknowledgements.

Context:
- compression_summary: {{compression_summary}}
- recent_messages: {{recent_messages}}
- current_message: {{current_message}}

Output JSON: {"queries": [{"query": ..., "context_type": ..., "intent": ..., "priority": 1-5}],
              "reasoning": "..."}
"""

async def analyze_intent(query: str, *, session_summary: str, recent_msgs: list[str],
                         planner_model) -> list[TypedQuery]:
    """LLM-driven query rewriting. 0 queries = no retrieval needed."""
    prompt = INTENT_ANALYSIS_PROMPT.format(
        compression_summary=session_summary,
        recent_messages="\n".join(f"[{m.role}] {m.content}" for m in recent_msgs[-5:]),
        current_message=query,
    )
    raw = await planner_model.acomplete(prompt)
    parsed = parse_json_from_response(raw)          # 容错 JSON 解析
    return [TypedQuery(**q) for q in parsed.get("queries", [])]
```

**生产经验**：
- Planner 模型用**轻量级**模型（`gpt-4o-mini` / `<lightweight-planner-model>` / 本地 SFT 模型），独立于主对话 model（推荐配置一个独立的 `query_planner`，fallback 到主模型）。
- Planner 模型可针对 query rewriting 任务**SFT 一个小模型**（如 `intent-analysis-sft`），延迟低、JSON 输出稳定。
- `priority` 用于合并时排序 + topK 截断，不直接当分数。

### 2) Dual Embedding：一次产出 dense + sparse

```python
@dataclass
class EmbedResult:
    dense_vector:  list[float] | None       # L2-normalized
    sparse_vector: dict[str, float] | None  # {term: weight}

    @property
    def is_hybrid(self) -> bool:
        return self.dense_vector is not None and self.sparse_vector is not None


class CompositeHybridEmbedder:
    """组合 dense + sparse 两个独立 embedder，asyncio.gather 并发产双向量."""

    def __init__(self, dense_embedder, sparse_embedder):
        self.dense = dense_embedder      # e.g. OpenAI text-embedding-3-large (1024-d, normalized)
        self.sparse = sparse_embedder    # e.g. Generic Provider sparse / SPLADE / BGE-M3 sparse head

    async def embed_async(self, text: str, *, is_query: bool) -> EmbedResult:
        d_in = self.dense.prepare_embedding_input(text)
        s_in = self.sparse.prepare_embedding_input(text)
        d, s = await asyncio.gather(
            self.dense.embed_async(d_in, is_query=is_query),
            self.sparse.embed_async(s_in, is_query=is_query),
        )
        return EmbedResult(dense_vector=d.dense_vector, sparse_vector=s.sparse_vector)
```

**生产细节**：
- **is_query 标志**：很多 embedder 对 query 与 document 用不同 prefix（如 BGE 的 `"query: "` vs `"passage: "`），失之毫厘差之千里。
- **input truncation**：每个 embedder 自带 `max_input_tokens`；长文档 chunk 前要切，**不要相信 provider 默认截断**（多数会静默截掉后半段）。
- **L2 归一化**：dense 向量入库前归一化，距离才能直接用作分数（cosine ↔ 内积等价）。
- **稀疏向量是 `{term: weight}` 而非 BM25 倒排表**——它是 query-time **学习** 出来的（SPLADE / 学习型稀疏），不是统计型 TF-IDF。能学到 "OAuth → {auth: 0.8, token: 0.5, oauth: 1.2, openid: 0.3}" 这种语义扩展，**这才是 hybrid 比 BM25+dense 更强的原因**。

### 3) Hybrid Retrieval：RRF 融合

向量库后端（以 Qdrant 为例）原生支持 prefetch + fusion：

```python
# 物理 search 请求 (Qdrant /collections/{c}/points/query)
body = {
    "prefetch": [
        {"query": dense_vector,           "using": "dense",  "limit": prefetch_n},
        {"query": sparse_payload,         "using": "sparse", "limit": prefetch_n},
    ],
    "query":   {"fusion": "rrf"},          # ⭐ 关键：Reciprocal Rank Fusion
    "limit":   final_k,
    "filter":  scope_filter,               # 元数据过滤（context_type / parent_uri / level）
    "with_payload": ["uri", "abstract", "level", "context_type",
                     "active_count", "updated_at"],
}
```

`prefetch_n` 经验值：`max(final_k * 4, final_k + 8, 50)`——双路 prefetch 池要比 final_k 大几倍，RRF 才有充足候选去融合。

**RRF 数学**：

```
score_RRF(d) = Σ_i  1 / (k + rank_i(d))     # i ∈ {dense, sparse}; k 默认 60
```

只用 rank 不用绝对分数。**好处**：dense cosine ∈ [-1, 1]，sparse 内积 ∈ [0, +∞)，**量纲完全不可比**；强行 z-score / min-max 都不稳——RRF 完全规避这个问题。

**纯 dense / 纯 sparse 退化**：当 sparse embedder 没配 / 返回空时，自动退化为纯 dense `/points/search`，不要让一路缺失拖整个流程挂掉：

```python
if sparse_vector is None or not sparse_vector:
    body = {"query": dense_vector, "using": "dense", "limit": final_k, ...}
```

### 4) Rerank：cross-encoder 精排

```python
class RerankClient:
    """通用 cross-encoder rerank client（兼容 Cohere / Jina / 自建 reranker）。"""

    def rerank_batch(self, query: str, docs: list[str]) -> list[float]:
        # 模型：<cross-encoder-rerank-model> / bge-reranker-v2-m3 / cohere rerank-3
        ...

def rerank_or_fallback(rerank_client, query, docs, fallback_scores) -> list[float]:
    if not rerank_client or not docs:
        return fallback_scores
    try:
        scores = rerank_client.rerank_batch(query, docs)
    except Exception as e:
        logger.warning("Rerank failed, fallback to vector scores: %s", e)
        return fallback_scores
    if not scores or len(scores) != len(docs):
        return fallback_scores                # 长度不匹配 = provider bug，fallback
    return [float(s) if isinstance(s, (int, float)) else fb
            for s, fb in zip(scores, fallback_scores, strict=True)]
```

**Rerank 输入用 L0 abstract 而非全文**：
- 全文几千 token，rerank cross-encoder 一次只能吃 512-2048 token，被迫截断。
- abstract（~100 token）已经把"这文档讲什么"压缩到位，**精准且省 token**。

**触发条件**：
- 配置了 `rerank_config.is_available()`
- `mode == THINKING`（QUICK 模式跳过，省 50ms）
- THINKING 默认给 `search()`，QUICK 默认给 `find()`

### 5) 多因子综合评分

```python
@dataclass
class RetrievalConfig:
    score_propagation_alpha: float = 1.0   # 1.0 = 纯子分；< 1 = 父分影响子分
    hotness_alpha: float = 0.0             # 0.0 = 关；0.2 = 给热度 20% 权重
    half_life_days: float = 7.0            # 热度时间半衰期

def compute_final_score(*, child_score: float, parent_score: float,
                        active_count: int, updated_at: datetime | None,
                        cfg: RetrievalConfig) -> float:
    # ① 传播：父分按 1-α_prop 加权
    if parent_score and cfg.score_propagation_alpha < 1.0:
        semantic = (cfg.score_propagation_alpha * child_score
                    + (1 - cfg.score_propagation_alpha) * parent_score)
    else:
        semantic = child_score

    # ② 热度
    if cfg.hotness_alpha > 0:
        freq = 1.0 / (1.0 + math.exp(-math.log1p(active_count)))   # sigmoid(log1p(n))
        if updated_at is None:
            hot = 0.0
        else:
            if updated_at.tzinfo is None:
                updated_at = updated_at.replace(tzinfo=timezone.utc)
            age_days = max((datetime.now(timezone.utc) - updated_at).total_seconds() / 86400, 0)
            recency = math.exp(-math.log(2) / cfg.half_life_days * age_days)
            hot = freq * recency
        final = (1 - cfg.hotness_alpha) * semantic + cfg.hotness_alpha * hot
    else:
        final = semantic
    return final if math.isfinite(final) else 0.0
```

**热度公式拆解**：
- `sigmoid(log1p(active_count))`：访问 0 → 0.5；10 次 → 0.77；100 次 → 0.89；**log1p 防止头部内容垄断**。
- `exp(-ln(2)/h * age)`：半衰期为 h 天的指数衰减；7 天前的内容权重 0.5，14 天前 0.25。
- 两者**相乘**：必须既"被访问过"又"近期更新"才高分；让"曾经爆款但已过时"的内容自然降权。

### 6) 层级递归 + 收敛检测（把上面拼起来）

```python
import heapq

async def hierarchical_retrieve(tq: TypedQuery, *, vector_store, embedder, rerank_client,
                                cfg: RetrievalConfig, threshold: float, limit: int,
                                mode: str = "thinking") -> list[dict]:
    # — 1) embed query —
    embed_result = await embedder.embed_async(tq.query, is_query=True)
    dense_q, sparse_q = embed_result.dense_vector, embed_result.sparse_vector

    # — 2) global vector search 起点候选 —
    starts = await vector_store.search_global_roots(
        dense_q, sparse_q, context_type=tq.context_type, limit=10,
    )                                          # 后端走 RRF
    # rerank 起点
    if rerank_client and mode == "thinking":
        starts_scores = rerank_or_fallback(
            rerank_client, tq.query,
            [r["abstract"] for r in starts],
            [r["_score"] for r in starts],
        )
        for r, s in zip(starts, starts_scores, strict=True):
            r["_score"] = s

    # — 3) 优先级队列递归 —
    dir_queue: list = []                       # (-score, uri)
    visited: set[str] = set()
    collected: dict[str, dict] = {}            # uri -> result
    prev_topk = set()
    stable_rounds = 0
    MAX_STABLE = 3

    for r in starts:
        if r.get("level", 2) != 2:             # 只有目录 (L0/L1) 入队继续递归
            heapq.heappush(dir_queue, (-r["_score"], r["uri"]))
        # L2 文件直接入结果池
        collected[r["uri"]] = {**r, "_final_score": r["_score"]}

    while dir_queue:
        # 并发展开 4 个最高分目录，加快收敛
        batch: list[tuple[str, float]] = []
        while dir_queue and len(batch) < 4:
            neg_s, uri = heapq.heappop(dir_queue)
            if uri in visited: continue
            visited.add(uri)
            batch.append((uri, -neg_s))

        results_per_dir = await asyncio.gather(*[
            vector_store.search_children(parent_uri=uri,
                                         dense=dense_q, sparse=sparse_q,
                                         limit=max(limit * 2, 20))
            for uri, _ in batch
        ])

        for (parent_uri, parent_score), results in zip(batch, results_per_dir):
            # rerank 当前层
            vec_scores = [r.get("_score", 0.0) for r in results]
            scores = (rerank_or_fallback(
                          rerank_client, tq.query,
                          [r["abstract"] for r in results], vec_scores)
                      if rerank_client and mode == "thinking" else vec_scores)

            for r, child_score in zip(results, scores, strict=True):
                final = compute_final_score(
                    child_score=child_score, parent_score=parent_score,
                    active_count=r.get("active_count", 0),
                    updated_at=parse_iso_datetime(r.get("updated_at")),
                    cfg=cfg,
                )
                if final <= threshold: continue
                # 取最高分版本
                prev = collected.get(r["uri"])
                if prev is None or final > prev["_final_score"]:
                    collected[r["uri"]] = {**r, "_final_score": final}
                if r.get("level", 2) != 2 and r["uri"] not in visited:
                    heapq.heappush(dir_queue, (-final, r["uri"]))

        # — 收敛检测 —
        topk = sorted(collected.values(), key=lambda x: -x["_final_score"])[:limit]
        topk_uris = {x["uri"] for x in topk}
        if topk_uris == prev_topk and len(topk_uris) >= limit:
            stable_rounds += 1
            if stable_rounds >= MAX_STABLE: break
        else:
            stable_rounds = 0
            prev_topk = topk_uris

    return sorted(collected.values(), key=lambda x: -x["_final_score"])[:limit]
```

### 7) 配置示例

```yaml
retrieval:
  # ── 分数旋钮 ──
  score_propagation_alpha: 0.85   # 子 85% + 父 15%；启用目录权重传播
  hotness_alpha:           0.15   # 语义 85% + 热度 15%
  half_life_days:          7      # 热度衰减半衰期

  # ── 阈值与规模 ──
  rerank_threshold:        0.30
  global_search_topk:      10
  max_parallel_children:   4      # 同时递归 N 个目录，反压远端向量库
  max_convergence_rounds:  3

# ── 模型 ──
embedder:
  type: composite_hybrid
  dense:  { provider: openai,     model: text-embedding-3-large, dim: 1024 }
  sparse: { provider: generic_provider, model: <sparse-embedding-model> }
rerank:
  provider: generic_provider
  model:    <cross-encoder-rerank-model>
  threshold: 0.30
query_planner:                    # query 重写专用模型
  provider: openai
  model:    gpt-4o-mini
  # 或 fine-tuned: <self-hosted intent-analysis SFT>
```

## 反模式

- ❌ **不做 query 重写**直接把用户原话喂给向量检索 → 多意图混合时 dense embedding 被"均值化"，每个意图都查得不准
- ❌ **加权和 dense + α·sparse** → 量纲不可比，α 永远调不对；用 **RRF**（只看 rank）
- ❌ **dense / sparse 分两次 embed** → 延迟翻倍；并发 `asyncio.gather` 一次产双向量
- ❌ **Rerank 输入全文** → cross-encoder 被迫截断；用 L0 abstract（~100 token）输入
- ❌ **Rerank 服务失败抛异常** → RAG 整体不可用；必须 fallback 到向量分
- ❌ **flat top-K 一次召回** → 无全局视野、无解释；用**层级优先级队列**沿目录深入
- ❌ **递归不带收敛检测** → 大目录树容易跑飞；top-K 连续 3 轮不变即停
- ❌ **直接拿向量距离做最终分数** → 忽略访问热度（常用内容沉底）和目录权威性（散落孤立文档抢分）
- ❌ **embed query 时不传 `is_query=True` 标志** → 用文档侧 prefix embed query，召回率掉一档
- ❌ **关键字检索 = BM25 倒排** → 学习型稀疏向量（SPLADE/BGE-M3 sparse）比 BM25 强一截，能学语义扩展

## 与 本插件其他 skill 的协同

| 目标 | 配合的本插件 skill |
|------|------------------------|
| 把 RAG 召回结果通过工具暴露给 LLM | [[tool-assembly-and-policy]] |
| Memory 与 RAG memory 8 类对照 | [[memory-system-design]] |
| 检索 trace 持久化（每次 visit/rerank 打点） | [[observability-tracing]] |
| L0 注入 system prompt 时的 token 预算 | [[context-window-management]] [[system-prompt-template]] |
| 把"目录递归检索"封装为长任务子代理 | [[subagent-delegation]] |
| 多用户知识库隔离 | [[multi-user-isolation]] |
| Embedding/Rerank 慢调用与背压 | [[long-running-and-cancellation]] |

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[memory-system-design]] [[tool-assembly-and-policy]] [[observability-tracing]] [[context-window-management]]
- 检索机制概念文档：RAG 检索机制经典实现（参见同目录 `references/`）
- 上下文分层（L0/L1/L2）：L0/L1/L2 分层（参见同目录 `references/`）
- RRF 论文：Cormack et al., "Reciprocal Rank Fusion outperforms Condorcet and individual Rank Learning Methods", SIGIR 2009
