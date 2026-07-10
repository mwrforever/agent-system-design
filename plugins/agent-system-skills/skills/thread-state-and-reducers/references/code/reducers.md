# reducers.md - `ThreadState` 全部自定义 reducer 实现

> 本文件是 `core/helix/agents/thread_state.py` 的 **reducer 部分**（8 个 reducer 函数 + 1 个归一化辅助函数）。schema（TypedDict / 常量 / `ThreadState` 根类）见同模块的 [./state-schema.md](./state-schema.md)。
>
> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原 docstring / 注释保留以保真；关键处补中文注解。每个 reducer 都是**纯函数**（无 I/O、无锁、无时间依赖），满足 LangGraph checkpoint 重放一致性要求。

## 三类 reducer 速览

| 类别 | reducer | 语义 |
|---|---|---|
| 幂等写防重复 | `merge_sandbox` | 相同值直通；不同值 **抛 ValueError**（fail-closed，暴露隔离 bug） |
| 幂等写防误清 | `merge_todos` / `merge_goal` | `new is None` = 节点未触动 -> 保留 existing；显式值覆盖 |
| 合并去重保序 | `merge_artifacts` | `dict.fromkeys(existing + new)` 去重 + 保序 |
| 合并去重保序（字典 + 清空协议） | `merge_viewed_images` | `{**existing, **new}`；特例 `new == {}` = 清空 |
| 合并去重保序（带 id + 终态保护 + 上限） | `merge_delegations` | 按 id 追加、同 id 最新胜、终态不被降级、保首见 created_at、封顶 50 条 |
| 合并去重保序（带 path + 归一化 + 上限） | `merge_skill_context` | 归一化遗留条目（丢正文、截 description）、按 path 去重、重读刷近度、封顶 8 条 |
| 按 hash 重置应对 fork | `merge_promoted` | `catalog_hash` 变 -> 整代替换（丢旧名）；同 hash -> 并集去重 |

## 完整实现（未截断）

### 1. `merge_sandbox` - 幂等写，冲突 fail-closed

```python
# core/helix/agents/thread_state.py
def merge_sandbox(existing: SandboxState | None, new: SandboxState | None) -> SandboxState | None:
    """Reducer for sandbox state - accepts idempotent writes only.

    Multiple sandbox tools can initialize lazily in the same graph step and
    emit the same sandbox_id via Command(update=...). LangGraph needs an
    explicit reducer for that shared state key. Different sandbox ids in the
    same thread indicate a lifecycle/isolation bug, so fail closed instead of
    choosing one silently.
    """
    if new is None:
        return existing
    if existing is None:
        return new

    existing_id = existing.get("sandbox_id")
    new_id = new.get("sandbox_id")
    if existing_id == new_id:
        return existing
    raise ValueError(f"Conflicting sandbox state updates: {existing_id!r} != {new_id!r}")
```

### 2. `merge_artifacts` - 合并去重保序

```python
# core/helix/agents/thread_state.py
def merge_artifacts(existing: list[str] | None, new: list[str] | None) -> list[str]:
    """Reducer for artifacts list - merges and deduplicates artifacts."""
    if existing is None:
        return new or []
    if new is None:
        return existing
    # Use dict.fromkeys to deduplicate while preserving order
    return list(dict.fromkeys(existing + new))
```

### 3. `merge_viewed_images` - 字典合并 + 空字典清空协议

```python
# core/helix/agents/thread_state.py
def merge_viewed_images(existing: dict[str, ViewedImageData] | None, new: dict[str, ViewedImageData] | None) -> dict[str, ViewedImageData]:
    """Reducer for viewed_images dict - merges image dictionaries.

    Special case: If new is an empty dict {}, it clears the existing images.
    This allows middlewares to clear the viewed_images state after processing.
    """
    if existing is None:
        return new or {}
    if new is None:
        return existing
    # Special case: empty dict means clear all viewed images
    if len(new) == 0:
        return {}
    # Merge dictionaries, new values override existing ones for same keys
    return {**existing, **new}
```

### 4. `merge_todos` - 最后非 None 胜（修复 #3123）

```python
# core/helix/agents/thread_state.py
def merge_todos(existing: list | None, new: list | None) -> list | None:
    """Reducer for todos list - keeps the last non-None value.

    Semantics:
    - If `new` is None (node didn't touch todos), preserve `existing`.
    - If `new` is provided (even empty list), it represents an explicit
      update and wins over `existing`.
    """
    if new is None:
        return existing
    return new
```

> **#3123 回归背景**：流式完成后 todos 列表消失，因为下游节点的 partial state update 带隐式 `todos=None`，在 Last-Write-Wins 下覆盖了之前累积的值。本 reducer 把 `None` 语义固定为"节点未触动"，显式 `[]` 才是"用户清空"。

### 5. `merge_goal` - 保留 active goal

```python
# core/helix/agents/thread_state.py
def merge_goal(existing: GoalState | None, new: GoalState | None) -> GoalState | None:
    """Reducer for goal state - preserves existing when a node does not touch it."""
    if new is None:
        return existing
    return new
```

### 6. `merge_promoted` - 按 catalog_hash 重置（应对 fork）

```python
# core/helix/agents/thread_state.py
def merge_promoted(existing: PromotedTools | None, new: PromotedTools | None) -> PromotedTools | None:
    """Reducer for deferred-tool promotions, scoped by catalog hash.

    - new None/empty -> preserve existing (node didn't touch promotions).
    - catalog_hash changed -> replace wholesale, dropping stale names (prevents a
      persisted bare name from exposing a different tool after catalog drift).
    - same catalog_hash -> union names, dedupe, preserve order.
    """
    if not new:
        return existing
    if existing is None or existing.get("catalog_hash") != new["catalog_hash"]:
        return {
            "catalog_hash": new["catalog_hash"],
            "names": list(dict.fromkeys(new["names"])),
        }
    return {
        "catalog_hash": existing["catalog_hash"],
        "names": list(dict.fromkeys(existing["names"] + new["names"])),
    }
```

> **fork 场景**：MCP server 列表变更后，旧 run 持久化的 `promoted.names` 里某个裸名（如 `"search"`）可能对应到**另一个**工具（catalog 漂移）。`catalog_hash` 变化即整代替换，防止 `DeferredToolFilterMiddleware` 误把已不存在的旧名放行进模型 schema。`existing.get("catalog_hash")` 用 `.get` 而非 `[]`，对外部注入的畸形持久化状态（缺 `catalog_hash`）按不匹配处理、整代替换，不崩溃。

### 7. `merge_delegations` - 按 id 追加 + 终态保护 + 封顶

```python
# core/helix/agents/thread_state.py
def merge_delegations(existing: list[DelegationEntry] | None, new: list[DelegationEntry] | None) -> list[DelegationEntry]:
    """Reducer for the delegation ledger.

    - new None/empty -> preserve existing.
    - append entries, replacing same id with the latest version while preserving
      first-seen order.
    - terminal status is never overwritten by a non-terminal status.
    """
    if not new:
        return existing or []

    by_id: dict[str, DelegationEntry] = {}
    order: list[str] = []
    for entry in [*(existing or []), *new]:
        entry_id = entry["id"]
        previous = by_id.get(entry_id)
        if previous is not None and previous["status"] in TERMINAL_STATUSES and entry["status"] not in TERMINAL_STATUSES:
            continue
        if entry_id not in by_id:
            order.append(entry_id)
        elif previous.get("created_at"):
            entry = {**entry, "created_at": previous["created_at"]}
        by_id[entry_id] = entry
    merged = [by_id[entry_id] for entry_id in order]
    if len(merged) > _DELEGATION_LEDGER_MAX_ENTRIES:
        merged = merged[-_DELEGATION_LEDGER_MAX_ENTRIES:]
    return merged
```

> 语义要点：
> - **同 id 最新胜**：同一 task 委派的 in_progress -> completed 更新覆盖旧版本，但保留首见 `created_at`（时间锚不漂移）。
> - **终态不被降级**：已 `completed`/`failed`/`cancelled`/`timed_out`/`polling_timed_out` 的条目，不被后来的非终态值（如滞留的 `in_progress`）覆盖--防止乱序到达的旧快照把已终结的委派"复活"成进行中。
> - **封顶 50 条**：超过 `_DELEGATION_LEDGER_MAX_ENTRIES` 时保留最近的 50 条（`merged[-50:]`），控制 checkpoint 体积。

### 8. `merge_skill_context` - 归一化 + 按 path 去重 + 重读刷近度 + 封顶

```python
# core/helix/agents/thread_state.py
def _normalize_skill_entry(entry: Mapping[str, object]) -> SkillEntry:
    """Drop legacy payload keys before storing skill_context back to state."""
    description = entry.get("description")
    loaded_at = entry.get("loaded_at")
    return {
        "name": str(entry.get("name") or ""),
        "path": str(entry["path"]),
        "description": " ".join(description.split())[:_SKILL_DESCRIPTION_MAX_CHARS] if isinstance(description, str) else "",
        "loaded_at": loaded_at if isinstance(loaded_at, int) else 0,
    }


def merge_skill_context(existing: list[SkillEntry] | None, new: list[SkillEntry] | None) -> list[SkillEntry]:
    """Reducer for the skill-context channel.

    - new None/empty -> preserve existing.
    - legacy entries are normalized to references; verbatim body keys are dropped.
    - dedup by ``path``; later reads refresh recency and replace the reference.
    - cap by keeping the most recently read entries. ``loaded_at`` is
      observational only because message indices reset after compaction.
    """
    normalized_existing = [_normalize_skill_entry(entry) for entry in existing or []]
    if not new:
        return normalized_existing

    by_path: dict[str, SkillEntry] = {}
    order: list[str] = []
    for entry in normalized_existing:
        path = entry["path"]
        if path not in by_path:
            order.append(path)
        by_path[path] = entry

    for entry in (_normalize_skill_entry(entry) for entry in new):
        path = entry["path"]
        if path in by_path:
            order.remove(path)
        order.append(path)
        by_path[path] = entry

    merged = [by_path[path] for path in order]
    if len(merged) > _SKILL_CONTEXT_MAX_ENTRIES:
        merged = merged[-_SKILL_CONTEXT_MAX_ENTRIES:]
    return merged
```

> 语义要点：
> - **归一化遗留条目**：旧版本曾把 SKILL.md **正文**（`content` key）存进 state，体积大且违反"引用而非内容"原则。`_normalize_skill_entry` 在每次合并前丢弃 `content`，只保留 `name`/`path`/`description`（`description` 截到 500 字符并压空白）。即使 `new is None`（节点未触动），也会对 existing 做一遍归一化，让旧 checkpoint 在读取时自愈。
> - **按 path 去重 + 重读刷近度**：同一技能被重读时，从 order 中移除旧位置、追加到末尾（`order.remove(path); order.append(path)`），使其成为"最近读"--封顶驱逐时优先丢最久未读的。
> - **封顶 8 条**：`loaded_at` 仅作观测（摘要压缩后消息索引会重置，不可靠），排序靠 order 而非 `loaded_at`。

## 相关

- schema（TypedDict / 常量 / `ThreadState` 根类）：[./state-schema.md](./state-schema.md)
- reducer 绑定的回归测试（`get_type_hints(ThreadState, include_extras=True)` 断言 `Annotated` 元数据）：见 `backend/tests/test_thread_state_reducers.py`、`backend/tests/test_thread_state_promoted.py`
- 消费者：[[middleware-chain-design]]（`DeferredToolFilterMiddleware` 读 `promoted`、`DurableContextMiddleware` 写 `delegations`/`skill_context`、`SummarizationMiddleware` 写 `summary_text`、`TodoMiddleware` 读 `todos`）
