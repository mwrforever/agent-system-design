---
name: thread-state-and-reducers
description: 设计 LangGraph agent 的"线程级状态"——TypedDict 扩展 AgentState + 自定义 reducer。覆盖幂等写、合并去重、按 hash 重置、空 dict 清空、并发冲突 fail-closed 等场景。
---

## 何时用

- 你在为 agent 设计图状态（State）字段
- 多个工具 / 中间件可能**同时**写同一个 key（典型：sandbox 惰性初始化）
- 字段需要"合并"语义，而非简单覆盖（artifacts 列表 / viewed_images 字典）
- 需要"清空"信号（已用图像清理）
- 需要"按版本作用域"（catalog hash 变了之前的 promotion 失效）

## 设计思想

1. **State 是 LangGraph 的并发协议**。同一 super-step 内多个节点写同一 key 时，**必须**通过 reducer 合并；没有 reducer = "last write wins"，并发场景下数据错乱。
2. **幂等写优先**。多个工具同时初始化同一资源（sandbox_id）时，相同值 OK，不同值 → **直接抛错**，让 bug 早暴露。
3. **特殊语义用约定值**。"空 dict = 清空"、"None = 没动"，约定写在 reducer docstring 里。
4. **版本作用域**。带 catalog_hash 的合并：hash 一致才合并，不一致整片重置——防止过时数据复用。
5. **state schema 在 `create_agent(state_schema=...)` 一处声明**，所有中间件用 TypedDict 子类做类型提示，IDE 能查。

## 实现模板

```python
# agents/thread_state.py
from typing import Annotated, NotRequired, TypedDict
from langchain.agents import AgentState


class SandboxState(TypedDict):
    sandbox_id: NotRequired[str | None]


def merge_sandbox(existing: SandboxState | None, new: SandboxState | None):
    """幂等写：相同 ok，不同 → fail-closed."""
    if new is None:    return existing
    if existing is None: return new
    if existing.get("sandbox_id") == new.get("sandbox_id"):
        return existing
    raise ValueError(
        f"Conflicting sandbox state: {existing['sandbox_id']!r} != {new['sandbox_id']!r}"
    )


def merge_artifacts(existing: list[str] | None, new: list[str] | None) -> list[str]:
    """合并去重，保序."""
    if existing is None: return new or []
    if new is None:      return existing
    return list(dict.fromkeys(existing + new))


def merge_viewed_images(existing: dict | None, new: dict | None) -> dict:
    """合并字典；特殊：new == {} 视为清空."""
    if existing is None: return new or {}
    if new is None:      return existing
    if len(new) == 0:    return {}                  # ⭐ 清空信号
    return {**existing, **new}


def merge_todos(existing: list | None, new: list | None) -> list | None:
    """显式 list 覆盖；None 表示"没动"."""
    if new is None: return existing
    return new


class PromotedTools(TypedDict):
    catalog_hash: str
    names: list[str]


def merge_promoted(existing: PromotedTools | None, new: PromotedTools | None):
    """按 catalog_hash 作用域：hash 变了 → 整片替换；一致 → union names."""
    if not new: return existing
    if existing is None or existing["catalog_hash"] != new["catalog_hash"]:
        return {"catalog_hash": new["catalog_hash"],
                "names": list(dict.fromkeys(new["names"]))}
    return {"catalog_hash": existing["catalog_hash"],
            "names": list(dict.fromkeys(existing["names"] + new["names"]))}


class ThreadState(AgentState):  # AgentState 已含 messages
    sandbox:        Annotated[NotRequired[SandboxState | None], merge_sandbox]
    title:          NotRequired[str | None]
    artifacts:      Annotated[list[str], merge_artifacts]
    todos:          Annotated[list | None, merge_todos]
    uploaded_files: NotRequired[list[dict] | None]
    viewed_images:  Annotated[dict, merge_viewed_images]
    promoted:       Annotated[PromotedTools | None, merge_promoted]
```

## 反模式

- ❌ 不写 reducer 直接用 `list[str]` → 并发写时旧 list 直接覆盖新 list
- ❌ `merge_sandbox` 静默选一个值 → sandbox 隔离 bug 永远查不出来
- ❌ 用魔法值 "CLEAR" 表示清空 → 不如直接用 `{}` 或单独信号 key
- ❌ 把 reducer 写得有副作用（写文件 / 发请求） → reducer 在 LangGraph 内可能被多次调用
- ✅ reducer = 纯函数；副作用放中间件
- ✅ 每个 reducer 配 docstring 说明 None / 空集 / 版本作用域的语义

## 触发场景：常见状态字段对照表

| 业务字段 | 推荐 reducer | 理由 |
|---|---|---|
| 资源 id (sandbox_id) | 幂等 + 冲突抛错 | 并发初始化幂等，但分裂 = bug |
| 列表追加 (artifacts, viewed_files) | 合并 + 去重保序 | 多工具产出会重复 |
| 字典累积 (viewed_images) | 合并 + 空字典清空 | 中间件需要主动清场 |
| 单值快照 (title, current_todo) | None=保留 / 非 None=覆盖 | 中间件按需 / 不写 |
| 版本化集合 (promoted tools) | 按版本 hash 作用域 | catalog 变了旧名失效 |

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[agent-graph-factory]] [[middleware-chain-design]] [[sandbox-abstraction]]
- LangGraph reducer 文档：https://langchain-ai.github.io/langgraph/concepts/low_level/#reducers
