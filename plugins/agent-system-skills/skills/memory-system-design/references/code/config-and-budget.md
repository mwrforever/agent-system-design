# 完整源码：MemoryConfig + 预算数学 + 陈旧审查设计

> 本文件给出记忆系统的**完整配置**与**预算/陈旧审查的设计推导**。SKILL.md 实现索引段给了配置旋钮速查表；此处给 `MemoryConfig` 全字段 + 两阶段预算数学 + 结构感知截断推导 + 陈旧审查设计。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`），去除一切项目字样。原代码注释保留以保真。

## 1. MemoryConfig 完整字段

```python
# core/helix/config/memory_config.py
"""Configuration for memory mechanism."""

from typing import Literal

from pydantic import BaseModel, Field


class MemoryConfig(BaseModel):
    """Configuration for global memory mechanism."""

    enabled: bool = Field(
        default=True,
        description="Whether to enable memory mechanism",
    )
    storage_path: str = Field(
        default="",
        description=(
            "Path to store memory data. "
            "If empty, defaults to per-user memory at `{base_dir}/users/{user_id}/memory.json`. "
            "Absolute paths are used as-is and opt out of per-user isolation "
            "(all users share the same file). "
            "Relative paths are resolved against `Paths.base_dir` "
            "(not the backend working directory). "
            "Note: if you previously set this to `.helix/memory.json`, "
            "the file will now be resolved as `{base_dir}/.helix/memory.json`; "
            "migrate existing data or use an absolute path to preserve the old location."
        ),
    )
    storage_class: str = Field(
        default="helix.agents.memory.storage.FileMemoryStorage",
        description="The class path for memory storage provider",
    )
    debounce_seconds: int = Field(
        default=30,
        ge=1,
        le=300,
        description="Seconds to wait before processing queued updates (debounce)",
    )
    model_name: str | None = Field(
        default=None,
        description="Model name to use for memory updates (None = use default model)",
    )
    max_facts: int = Field(
        default=100,
        ge=10,
        le=500,
        description="Maximum number of facts to store",
    )
    fact_confidence_threshold: float = Field(
        default=0.7,
        ge=0.0,
        le=1.0,
        description="Minimum confidence threshold for storing facts",
    )
    injection_enabled: bool = Field(
        default=True,
        description="Whether to inject memory into system prompt",
    )
    max_injection_tokens: int = Field(
        default=2000,
        ge=100,
        le=8000,
        description="Maximum tokens to use for memory injection",
    )
    token_counting: Literal["tiktoken", "char"] = Field(
        default="tiktoken",
        description=(
            "Token counting strategy for memory-injection budgeting. "
            "'tiktoken' is accurate but the encoding's BPE data may be "
            "downloaded from a public network endpoint on first use, which "
            "can block for a long time in network-restricted environments "
            "(see issue #3402/#3429). 'char' uses a network-free "
            "CJK-aware character-based estimate and never touches tiktoken."
        ),
    )
    guaranteed_categories: list[str] = Field(
        default_factory=lambda: ["correction"],
        description=(
            "Fact categories that are always injected into the prompt regardless "
            "of the regular token budget. These facts are allocated from a "
            "separate reserved budget (``guaranteed_token_budget``). "
            "This ensures high-value facts such as explicit user corrections "
            "are never silently dropped when the token budget is tight."
        ),
    )
    guaranteed_token_budget: int = Field(
        default=500,
        ge=50,
        le=2000,
        description=(
            "Token ceiling for guaranteed-category facts. "
            "Guaranteed facts are selected first from this budget and placed at "
            "the front of the Facts block so they cannot be evicted by regular "
            "facts. In the common case the total output still fits within "
            "``max_injection_tokens`` (guaranteed lines displace regular ones); "
            "the budget becomes additive only when guaranteed lines alone push "
            "the output past ``max_injection_tokens``, in which case the "
            "safety-truncation ceiling is raised accordingly."
        ),
    )
    # ── Staleness review ────────────────────────────────────────────────
    staleness_review_enabled: bool = Field(
        default=True,
        description=(
            "Enable staleness review for aged facts. When enabled, facts older "
            "than ``staleness_age_days`` are surfaced in the memory-update prompt "
            "so the LLM can semantically judge whether each is still valid or "
            "should be removed. This solves the 'silent staleness' problem where "
            "outdated facts persist because no future conversation explicitly "
            "contradicts them."
        ),
    )
    staleness_age_days: int = Field(
        default=90,
        ge=30,
        le=365,
        description=("Facts older than this many days become candidates for staleness review. 90 days (~one quarter) balances between catching genuine changes (job switches, tech-stack migrations) and avoiding noise on stable facts."),
    )
    staleness_min_candidates: int = Field(
        default=3,
        ge=1,
        le=50,
        description=("Minimum number of stale facts required to trigger a review cycle. Below this threshold the prompt overhead is not justified."),
    )
    staleness_max_removals_per_cycle: int = Field(
        default=10,
        ge=1,
        le=50,
        description=("Maximum number of facts the staleness review can remove in a single update cycle. Prevents the LLM from over-pruning when reviewing a large backlog of aged facts."),
    )
    staleness_protected_categories: list[str] = Field(
        default_factory=lambda: ["correction"],
        description=("Fact categories exempt from staleness review. Correction facts represent explicit user feedback and should not be auto-pruned based on age alone."),
    )


# Global configuration instance
_memory_config: MemoryConfig = MemoryConfig()


def get_memory_config() -> MemoryConfig:
    """Get the current memory configuration."""
    return _memory_config


def set_memory_config(config: MemoryConfig) -> None:
    """Set the memory configuration."""
    global _memory_config
    _memory_config = config


def load_memory_config_from_dict(config_dict: dict) -> None:
    """Load memory configuration from a dictionary."""
    global _memory_config
    _memory_config = MemoryConfig(**config_dict)
```

**字段分组**：

| 组 | 字段 | 作用 |
|---|---|---|
| 总开关 | `enabled` / `injection_enabled` | `enabled` 控写入（含 LLM 抽取），`injection_enabled` 控注入。可只写不注 |
| 存储 | `storage_path` / `storage_class` | 路径（空=per-user 默认）/ 存储实现类（可插拔） |
| 防抖 | `debounce_seconds` | Timer 防抖窗口（1-300s） |
| LLM | `model_name` | 抽取用模型（None=默认模型） |
| 事实入库 | `max_facts` / `fact_confidence_threshold` | 条数上限 / confidence 下限 |
| 注入预算 | `max_injection_tokens` / `token_counting` | 总预算 / 计数模式 |
| guaranteed | `guaranteed_categories` / `guaranteed_token_budget` | 保底类目 / 保底预算 |
| 陈旧审查 | `staleness_review_enabled` / `staleness_age_days` / `staleness_min_candidates` / `staleness_max_removals_per_cycle` / `staleness_protected_categories` | 开关 / 年龄阈值 / 最小候选数 / 单轮上限 / 保护类目 |

## 2. 预算数学（两阶段 + 结构感知截断）

`format_memory_for_injection` 的预算模型是本 skill 最精巧的部分。下面推导其数学。

### 2.1 符号

- `M = max_injection_tokens`（总预算，默认 2000）
- `G = guaranteed_token_budget`（保底预算，默认 500）
- `B` = base 段（user-context + history）的 token 数
- `H` = `"Facts:\n"` header 的 token 数
- `g` = guaranteed 行实际选取的 token 数（含行间 `\n`，不含 header）
- `r` = regular 行实际选取的 token 数
- `S` = 段间 `"\n\n"` 分隔符的 token 数
- `N` = guaranteed 与 regular 两组都存在时的组间 `"\n"` 的 token 数

### 2.2 两阶段选取

**阶段 1（guaranteed）**：从 `G` 预算贪心选 guaranteed 行（confidence 降序），得 `g`。

**阶段 2（regular）**：regular 行的预算 = `M` 扣除已占用的：

```
regular_line_budget = M - B - H - g - (N if guaranteed_lines else 0)
```

即 regular 行只能用 `M` 里 guaranteed 行**没占完**的部分。常见情况下 `g` 较小，guaranteed 行挤占 regular 行，总输出 <= `M`。

### 2.3 何时预算真正叠加

只有当 guaranteed 行**自身**就把输出推过 `M` 时，预算才叠加：

```
effective_limit = M + g
```

此时安全截断上限从 `M` 抬升到 `M + g`，保护 guaranteed 行不被前缀截断。

### 2.4 结构感知截断（受保护后缀）

组装结果 `result = "\n\n".join(sections)` 后，若 `token_count(result) > effective_limit`：

1. 把 Facts 块（`H + "\n".join(all_fact_lines)`）视为**受保护后缀**，预算 = `effective_limit - facts_block_tokens - S`。
2. 只截断前面的 base 段（user-context / history）：按 `char_per_token` 比例裁到 0.95 倍目标字符数，尾接 `"\n..."`。
3. 重组：`preceding + "\n\n" + facts_block`。

**为何这样设计**：若用朴素前缀截断，当 base 段很大时，guaranteed 事实（本设计要保的）会被静默裁掉--白做。把 Facts 块当受保护后缀，只裁 base 段，guaranteed 事实永不丢。当 `g = 0`（无 guaranteed 配置或无该类目事实存活），`effective_limit = M`，退化为原始前缀截断，向后兼容。

### 2.5 fallback 路径

主路径（partition + guaranteed）任何异常都触发 `_fallback_format_facts`：单预算 confidence 排序，选出的 `lines` 回传给 `all_fact_lines`，让结构感知截断把 fallback 事实也当受保护后缀。这保证主路径异常不会让记忆注入完全失败，也不会让 fallback 事实被前缀截断丢掉。

## 3. 陈旧审查设计

### 3.1 问题：silent staleness

记忆事实会陈旧（用户换了工作、技术栈迁移、项目废弃），但若没有后续对话**显式矛盾**该事实，它会永远留在记忆里。这是"静默陈旧"--LLM 只在看到矛盾时才删，没矛盾就留着。

### 3.2 解法：主动审查

`staleness_review_enabled=True` 时，每次更新周期：

1. `_select_stale_candidates`：选 `createdAt` 超过 `staleness_age_days`（默认 90 天）且类目不在 `staleness_protected_categories`（默认 `["correction"]`）的事实。
2. 候选数 >= `staleness_min_candidates`（默认 3）才注入审查段（省 prompt 开销）。
3. `_build_staleness_section` 把候选事实格式化进 `STALENESS_REVIEW_PROMPT`，让 LLM 对每条做 KEEP/REMOVE 语义判断。
4. LLM 返回 `staleFactsToRemove`，`_apply_updates` 处理。

### 3.3 三道守卫

LLM 的删除决策不可信，故三道守卫：

1. **候选集交集**：`stale_ids_to_remove &= candidate_ids`。模型返回删一个非候选 id（保护类目或未超龄）被静默拒。这道守卫**无条件运行**，独立于 `staleness_review_enabled` 标志--即使审查关闭，模型在 `factsToRemove` 里塞的超龄事实也会被候选集过滤。
2. **单轮上限**：`staleness_max_removals_per_cycle`（默认 10）。超额时留最低 confidence 的（最可疑的先删），防模型审查大 backlog 时过度修剪。
3. **保护类目**：`staleness_protected_categories`（默认 `["correction"]`）。`correction` 是显式用户反馈，不该按年龄自动剪。

### 3.4 保守原则

`STALENESS_REVIEW_PROMPT` 明确指示："when in doubt, KEEP. Removing a valid fact is worse than keeping a slightly stale one, because the next review cycle will re-evaluate it."--删错比留旧更糟，因为下一轮还会再审。

## 4. 配置解析时机

`MemoryConfig` 是全局单例（`_memory_config`），由 `get_memory_config()` 读、`set_memory_config()` / `load_memory_config_from_dict()` 写。配置热更新由 [[config-and-hot-reload]] 负责（每 run 解析 config.yaml -> `set_memory_config`）。记忆系统各组件（middleware / queue / updater / storage / injection）都在调用点 `get_memory_config()` 读最新值，不缓存配置对象，故热更新立即生效。

## 进一步阅读

- 存储全貌 + token 计数 + 注入接线：[memory-data-and-injection.md](./memory-data-and-injection.md)
- 防抖队列 + LLM 抽取 + prompt 模板：[extract-and-debounce.md](./extract-and-debounce.md)
- 配置热更新机制：[[config-and-hot-reload]]
- 注入中间件（读 config.injection_enabled / max_injection_tokens）：[[system-prompt-template]]
