# 完整源码：多因子评分（hotness_score + RetrievalConfig）

> 本文件给出热度评分与检索配置旋钮的完整源码。`hotness_score` 是纯函数，基于访问频次（active_count）与时效（updated_at）计算 0.0-1.0 热度分。`RetrievalConfig` 定义两个评分旋钮：`hotness_alpha`（热度权重）与 `score_propagation_alpha`（父子传播权重）。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.rag.*`）。原代码注释保留以保真。

## §1 hotness_score 热度评分（core/helix/rag/retrieve/memory_lifecycle.py）

```python
# core/helix/rag/retrieve/memory_lifecycle.py
"""Hotness scoring for cold/hot memory lifecycle management.

Provides a pure function to compute a 0.0–1.0 hotness score based on
access frequency (active_count) and recency (updated_at).  The score
can be blended with semantic similarity to boost frequently-accessed,
recently-updated contexts in search results.
"""

import math
from datetime import datetime, timezone
from typing import Optional

# Default half-life in days for the exponential time-decay component.
DEFAULT_HALF_LIFE_DAYS: float = 7.0


def hotness_score(
    active_count: int,
    updated_at: Optional[datetime],
    now: Optional[datetime] = None,
    half_life_days: float = DEFAULT_HALF_LIFE_DAYS,
) -> float:
    """Compute a 0.0–1.0 hotness score.

    Formula::

        score = sigmoid(log1p(active_count)) * time_decay(updated_at)

    * **sigmoid** maps ``log1p(active_count)`` into (0, 1).
      log1p 防止头部内容垄断：访问 0 -> 0.5；10 次 -> 0.77；100 次 -> 0.89。
    * **time_decay** is an exponential decay with configurable half-life;
      returns 0.0 when *updated_at* is ``None``.
      半衰期 h 天的指数衰减：7 天前权重 0.5，14 天前 0.25。
    * 两者相乘：必须既"被访问过"又"近期更新"才高分，
      让"曾经爆款但已过时"的内容自然降权。

    Args:
        active_count: Number of times this context was retrieved/accessed.
        updated_at: Last update / access timestamp (preferably UTC).
        now: Current time override (useful for deterministic tests).
        half_life_days: Half-life for the recency decay, in days.

    Returns:
        A float in [0.0, 1.0].
    """
    if now is None:
        now = datetime.now(timezone.utc)

    # --- frequency component ---
    # sigmoid(log1p(N))：访问 0 -> 0.5；10 -> 0.77；100 -> 0.89
    freq = 1.0 / (1.0 + math.exp(-math.log1p(active_count)))

    # --- recency component ---
    if updated_at is None:
        # 从未更新的内容不 boost
        return 0.0

    # Normalise to aware UTC so subtraction always works.
    if updated_at.tzinfo is None:
        updated_at = updated_at.replace(tzinfo=timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)

    age_days = max((now - updated_at).total_seconds() / 86400.0, 0.0)
    decay_rate = math.log(2) / half_life_days
    # exp(-ln2/h * age)：半衰期 h 天的指数衰减
    recency = math.exp(-decay_rate * age_days)

    return freq * recency
```

### 热度公式拆解

```
freq     = 1 / (1 + exp(-log1p(active_count)))    # sigmoid(log1p(N))
recency  = exp(-ln(2) / half_life_days * age_days)  # 指数衰减
hotness  = freq * recency                           # 相乘

# 数值示例（half_life_days=7.0）：
# active_count=0,  updated_at=now      -> freq=0.5,  recency=1.0  -> hotness=0.5
# active_count=10, updated_at=now      -> freq=0.77, recency=1.0  -> hotness=0.77
# active_count=100,updated_at=now      -> freq=0.89, recency=1.0  -> hotness=0.89
# active_count=100,updated_at=7天前    -> freq=0.89, recency=0.5  -> hotness=0.445
# active_count=100,updated_at=14天前   -> freq=0.89, recency=0.25 -> hotness=0.223
# active_count=100,updated_at=None     -> return 0.0（从未更新不 boost）
```

- `sigmoid(log1p(active_count))`：log1p 防止头部内容垄断（访问 100 次只到 0.89，不是 1.0）。
- `exp(-ln(2)/h * age)`：半衰期为 h 天的指数衰减；7 天前的内容权重 0.5，14 天前 0.25。
- 两者**相乘**：必须既"被访问过"又"近期更新"才高分；让"曾经爆款但已过时"的内容自然降权。
- `updated_at=None` 直接返回 0.0--"从未更新"的内容不 boost。

## §2 RetrievalConfig 评分旋钮（core/helix/rag/config/retrieval_config.py）

```python
# core/helix/rag/config/retrieval_config.py

from pydantic import BaseModel, Field


class RetrievalConfig(BaseModel):
    """Configuration for retrieval ranking behavior.

    两个评分旋钮控制 HierarchicalRetriever 的最终分数：
    - hotness_alpha: 热度权重。0=关热度（纯语义）；1=纯热度；0.2=80%语义+20%热度。
    - score_propagation_alpha: 父子传播权重。
      0=纯父分；1=纯子分（默认）；0.7=子70%+父30%（高分目录下的孩子加权）。
    """

    hotness_alpha: float = Field(
        default=0.0,
        ge=0.0,
        le=1.0,
        description=(
            "Weight for blending hotness into final retrieval scores. "
            "0 disables hotness boost; 1 uses only hotness."
        ),
    )
    score_propagation_alpha: float = Field(
        default=1.0,
        ge=0.0,
        le=1.0,
        description=(
            "Weight for each child result's own score when blending with its parent score "
            "during hierarchical retrieval. 0 uses only the parent score; "
            "1 uses only the child score."
        ),
    )

    model_config = {"extra": "forbid"}
```

### 两个旋钮的作用位置

```
# 在 HierarchicalRetriever 中：

# ① score_propagation_alpha：在 _recursive_search 递归中即时混合
final_score = (
    alpha * child_score + (1 - alpha) * parent_score
    if parent_score else child_score
)
# alpha = score_propagation_alpha
# 1.0 = 纯子分（默认）；0.7 = 子 70% + 父 30%

# ② hotness_alpha：在 _convert_to_matched_contexts 终态叠加
if hotness_alpha > 0:
    h_score = hotness_score(active_count, updated_at, half_life_days=7.0)
    final_score = (1 - hotness_alpha) * semantic_score + hotness_alpha * h_score
else:
    final_score = semantic_score
# hotness_alpha = 0.0（默认关闭）；0.2 = 80% 语义 + 20% 热度
# 叠加后重排：hotness boost 可改变最终排名
```

| 旋钮 | 范围 | 默认 | 作用 | 用途 |
|---|---|---|---|---|
| `score_propagation_alpha` | [0, 1] | 1.0 | 递归中父子分混合权重 | `0.7` 让高分目录下的孩子加权，散落孤立文档降权 |
| `hotness_alpha` | [0, 1] | 0.0 | 终态语义分与热度分混合权重 | `0.2` 常用内容 boost、过时内容降权 |
| `half_life_days` | > 0 | 7.0 | 热度时间半衰期 | 14 天慢衰减；3 天快衰减 |

> **评分要点**：分数传播（`score_propagation_alpha`）在 `_recursive_search` 递归中即时混合--`α_prop * child + (1-α_prop) * parent`，让"在高相关父目录路径上"的文档比"散落在低相关路径上"的文档优先。热度（`hotness_alpha`）在 `_convert_to_matched_contexts` 终态叠加--`(1-α_hot) * 语义 + α_hot * hotness`，叠加后重排使热度 boost 可改变排名。两者独立可调，默认 `hotness_alpha=0`（关热度）、`score_propagation_alpha=1.0`（纯子分）。热度公式 `sigmoid(log1p(N)) × exp(-ln2/h × age)` 让"被访问过"且"近期更新"的内容高分，`updated_at=None` 返回 0.0。
