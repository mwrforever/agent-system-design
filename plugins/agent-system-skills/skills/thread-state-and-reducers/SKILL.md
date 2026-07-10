---
name: thread-state-and-reducers
description: 设计 LangGraph agent 的"线程级状态"--TypedDict 扩展 AgentState + 自定义 reducer。完整覆盖三类 reducer（幂等写防重复 / 合并去重保序 / 按 hash 重置应对 fork）、add_messages 继承、空 dict 清空协议、None=未触动约定、终态保护与封顶、reducer 在中间件链与图节点间的数据流。给出完整、未截断的真实代码。当你要为 agent 设计图状态字段、排查"并发写同 key 数据错乱/丢失"、定位 todos 流式后消失（#3123）或 promoted 旧名误放行时调用本 skill。
---

## 何时用

- 你在为 LangGraph agent 设计图状态（`State` / `ThreadState`）字段
- 多个工具 / 中间件可能**同时**写同一个 key（典型：sandbox 惰性初始化、`present_files` 并行调用、`tool_search` 提升延迟工具）
- 字段需要"合并"语义而非简单覆盖（artifacts 列表 / viewed_images 字典 / delegations 台账 / skill_context 引用）
- 需要"清空"信号（已用图像清理）或"未触动"信号（todos 跨 partial update 保留）
- 需要"按版本作用域"（catalog hash 变了，之前提升的工具名整体失效）
- 排查"流式完成后 todos 消失"（#3123）或"并发写 sandbox 触发 `INVALID_CONCURRENT_GRAPH_UPDATE`"
- 排查"MCP server 列表变更后，旧 promoted 名仍被 `DeferredToolFilterMiddleware` 放行"

## 设计方案（为什么这么设计）

### 核心矛盾：State 是并发协议，不是普通数据结构

LangGraph 的图状态在同一个 super-step 内可能被**多个节点 / 多个工具**并发写。若一个字段没有 reducer，LangGraph 退化为 **Last-Write-Wins（LWW）**：后写的 dict 直接覆盖先写的，并发场景下数据静默错乱或丢失。最严重的几类：

- 两个沙箱工具在同一帧懒初始化，各自 emit `{"sandbox": {"sandbox_id": "X"}}` -> LWW 下只剩一个，但更糟的是 LangGraph 会因"同 key 两个不同 dict update"直接抛 `INVALID_CONCURRENT_GRAPH_UPDATE`，整步失败。
- `present_files` 被并行调用两次，各自返回 `{"artifacts": ["a"]}` / `{"artifacts": ["b"]}` -> LWW 下产物列表只剩 `["b"]`，`a` 丢失。
- 下游节点返回不含 `todos` 的 partial update -> LangGraph 以隐式 `None` 合并 -> LWW 下把之前累积的 todos 清成 `None`（**#3123 的根因**）。

**解法：给每个会被并发写 / partial 写的字段挂一个 `Annotated[T, reducer]`。** reducer 是个 `(existing, new) -> merged` 的纯函数，LangGraph 用它合并同一 super-step 内对该字段的所有 update。没有 reducer 的字段才允许 LWW，且**仅当该字段由单一写者独占**（如 `title` 只由 `TitleMiddleware` 写、`uploaded_files` 只由 `UploadsMiddleware` 写、`summary_text` 只由 `SummarizationMiddleware` 写）。

### 为何用 TypedDict + Annotated（而非 dataclass / Pydantic）

- **LangGraph 原生契约**：LangGraph 的 `State` 就是 `TypedDict`；`Annotated[T, reducer]` 是它识别 reducer 的唯一语法糖。用 dataclass / Pydantic 要额外注册，且 checkpointer（SQL/Redis）对 `TypedDict` + 基础类型的 JSON 序列化最稳。
- **继承 `AgentState` 拿到 `add_messages`**：`langchain.agents.AgentState` 已声明 `messages: Annotated[list[AnyMessage], add_messages]`。`ThreadState(AgentState)` 继承它，messages 通道自动走 LangGraph 内置的 `add_messages`--处理 ID-swap（`DynamicContextMiddleware` 原地替换 SystemMessage）、`RemoveMessage(id=REMOVE_ALL_MESSAGES)`（`SummarizationMiddleware` 整段清理）、tool_call 与 ToolMessage 配对。**不要自定义 messages 的 reducer**，否则这些语义全部失效。
- **`NotRequired` 标记可选字段**：初始状态可缺省，避免空 run 强制填一堆 `None`。

### 三类 reducer 的场景

所有自定义 reducer 按语义归为三类，每类解决一种并发 / 演进问题：

**1. 幂等写防重复 / 防误清**

- `merge_sandbox`：多个沙箱工具同帧懒初始化同一 `sandbox_id` -> **相同值直通**（返回 existing，幂等）；**不同值直接 `raise ValueError`**（fail-closed）。静默选一个会让隔离 bug 永远查不出来；抛错让 `INVALID_CONCURRENT_GRAPH_UPDATE` 这种"同 thread 跨沙盒"的 lifecycle/isolation bug 在第一时间暴露。抛错的 `ValueError` 会让整个 super-step 失败回滚--这是故意的，隔离冲突是 P0。
- `merge_todos` / `merge_goal`：把 `new is None` 固定为"节点未触动该字段"语义，返回 `existing`。这是 **#3123 的修复**：之前下游节点 partial update 带隐式 `None`，LWW 下清空了 todos。`merge_todos` 进一步约定：显式 `[]` 才是"用户清空"（`[]` 覆盖 existing），`None` 是"没动"（保留 existing）。

**2. 合并去重保序**

- `merge_artifacts`：`list(dict.fromkeys(existing + new))` -- 去重 + 保首见序。多个 `present_files` 并行调用的产物累加不丢、不重。
- `merge_viewed_images`：`{**existing, **new}` 字典合并（new 覆盖同 key）；**特例 `new == {}` = 清空**（`None` 仍是"未触动"）。`ViewImageMiddleware` 处理完图像后用 `{}` 主动清场，避免 base64 反复进上下文。
- `merge_delegations`：按 `id` 追加、同 id 最新版本胜、**终态（completed/failed/cancelled/timed_out/polling_timed_out）永不被非终态值降级**（防乱序旧快照复活已终结委派）、保留首见 `created_at`、封顶 50 条（控 checkpoint 体积）。
- `merge_skill_context`：归一化遗留条目（丢 SKILL.md 正文、`description` 截 500 字符）、按 `path` 去重、重读刷近度（移到 order 末尾）、封顶 8 条最近读。即使 `new is None` 也会对 existing 做一遍归一化，让旧 checkpoint 自愈。

**3. 按 hash 重置应对 fork**

- `merge_promoted`：`catalog_hash` 变化 -> **整代替换**（丢旧 names，只留 new 的去重 names）；同 hash -> 并集去重。这是"按版本作用域"：MCP server 列表变更（catalog 漂移）后，旧 run 持久化的裸工具名（如 `"search"`）可能对应到**另一个**工具。若沿用并集，`DeferredToolFilterMiddleware` 会误把已不存在的旧名放行进模型 schema。`catalog_hash` 变即整片重置，等价于"fork 出一条新的 promotion 血统"。`existing.get("catalog_hash")` 用 `.get` 而非 `[]`，对外部注入的畸形持久化状态（缺 `catalog_hash`）按不匹配处理、整代替换，不崩溃。

### 约定值：None / 空 dict / 空列表的语义区分

reducer 之间靠**约定值**区分意图，约定写在每个 reducer 的 docstring 里，调用方必须遵守：

| 信号 | 含义 | 谁用 |
|---|---|---|
| `new is None` | 节点未触动该字段 -> 保留 existing | `merge_todos` / `merge_goal` / `merge_artifacts` / `merge_viewed_images` / `merge_promoted` / `merge_delegations` / `merge_skill_context` |
| `new == {}`（空 dict） | **显式清空**（仅 `viewed_images`） | `ViewImageMiddleware` 处理完图像后清场 |
| `new == []`（空 list） | **显式清空**（仅 `todos`） | `write_todos` 工具清空 todo 列表 |
| `new == {}`（falsy dict） | **未触动**（`merge_promoted`：`if not new: return existing`） | `tool_search` 未提升任何工具时 |

> 注意 `merge_viewed_images` 的 `{}` 是清空、`merge_promoted` 的 `{}` 是未触动--两者对 falsy dict 的解释不同，因为 `promoted` 还带 `catalog_hash` 字段（空 dict 无 hash = 未触动），而 `viewed_images` 是裸 dict（空 = 没图像 = 清空）。**给新字段设计 reducer 时必须显式声明对 None / 空集 / falsy 的解释**，否则调用方会猜错。

### State 在中间件链与图节点间的数据流

State 是 ④建图 与 ⑤中间件 之间的**数据载体**：中间件在 `before_model` / `after_model` / `wrap_model_call` / `wrap_tool_call` 里**读** state（`request.state` / `runtime.state` / `state.get(...)`），工具 / 中间件通过 `Command(update={...})` 或返回 dict **写** state；两个 super-step 之间，LangGraph 对每个被更新的字段跑它的 reducer 合并，结果写进 checkpoint。下一个 super-step 的中间件看到的就是合并后的值。

```
④建图  create_agent(state_schema=ThreadState)   <-- schema 一次性绑定；漏传则全部退化为 LWW
         │
         ▼
⑤中间件链（每 super-step 跑一遍）
  before_model（正序）：
    DynamicContextMiddleware   读 messages -> ID-swap 注入 reminder（经 add_messages）
    DurableContextMiddleware   读 messages -> 抽 task 委派/技能 -> 写 delegations/skill_context
                               （经 merge_delegations / merge_skill_context）
    TodoMiddleware             读 todos/messages -> 检测上下文丢失 -> 注入 reminder（不写 todos）
  wrap_model_call：
    DeferredToolFilterMiddleware 读 promoted（按 catalog_hash）-> 过滤延迟工具 schema
    SystemMessageCoalescingMiddleware 读 messages -> 合并 SystemMessage（不动 checkpoint）
  wrap_tool_call（工具执行）：
    SandboxMiddleware          diff state["sandbox"] 前后 -> 写 sandbox（经 merge_sandbox）
    present_files 工具         写 artifacts（经 merge_artifacts）
    view_image 工具            写 viewed_images（经 merge_viewed_images）
    write_todos 工具           写 todos（经 merge_todos）
    tool_search 工具           写 promoted（经 merge_promoted）
  after_model（逆序）：
    SummarizationMiddleware    写 summary_text（LWW）+ messages（RemoveMessage(REMOVE_ALL_MESSAGES) + 保留尾，经 add_messages）
    DurableContextMiddleware   再捕一次 delegations（after_model 路径，防摘要压缩前丢失）
         │
         ▼
   LangGraph 对每个被更新字段跑 reducer -> 合并结果写 checkpoint -> 下一 super-step 中间件读合并后的值
```

关键点：

- **schema 只在 ④建图 绑一次**：`create_agent(state_schema=ThreadState)`。漏传 `state_schema` 或用裸 `AgentState`，所有自定义 reducer 静默失效，`sandbox`/`artifacts`/`promoted`/`delegations`/`skill_context` 全部退化为 LWW（`merge_sandbox` 的冲突检测、`merge_promoted` 的分代重置都不生效）。
- **写 state 必须走 `Command(update={...})` 或返回 dict**，不能 in-place 改 `state["artifacts"].append(x)`--in-place 修改不触发 reducer，LangGraph 看不到。
- **reducer 是纯函数**：无 I/O、无锁、无时间依赖。LangGraph 在重放 checkpoint 时可能多次调用 reducer，有副作用则结果不一致、断点恢复失败。副作用（发请求、写文件）放中间件 / 工具，reducer 只做合并。
- **`messages` 通道靠 `add_messages`**：ID-swap（`DynamicContextMiddleware`）、`RemoveMessage(id=REMOVE_ALL_MESSAGES)`（`SummarizationMiddleware`）、tool_call 配对都依赖它。自定义 messages reducer 会破坏这些语义。

### 在端到端链路中的位置

本 skill 处于端到端链路的 **④建图 / ⑤中间件**（见 [[e2e-request-lifecycle]]）：

- ④建图：`make_lead_agent` 在 `create_agent(state_schema=ThreadState)` 处绑定 schema（见 [[agent-graph-factory]] 第 9 步"一次绑定"）。schema 是图的数据骨架，决定了中间件 / 工具能读写哪些通道、每个通道用什么合并语义。
- ⑤中间件：29 项链里至少 6 项直接读写 `ThreadState` 的非 messages 字段（`SandboxMiddleware` 写 `sandbox`、`DurableContextMiddleware` 写 `delegations`/`skill_context`、`DeferredToolFilterMiddleware` 读 `promoted`、`TodoMiddleware` 读 `todos`、`SummarizationMiddleware` 写 `summary_text`、`ViewImageMiddleware`/`UploadsMiddleware`/`TitleMiddleware` 各写自己的 LWW 字段）。state 是这些中间件之间**唯一的数据传递媒介**--中间件不直接互相调用，全靠读写 state 通道协作。
- ⑥执行：工具（`present_files` / `view_image` / `write_todos` / `tool_search`）通过 `Command(update={...})` 把产物写进 state，reducer 合并后供下游中间件 / 前端消费。

跨切不变量 3（StreamBridge × checkpointer × 回滚）的**持久化基础就在本 skill**：所有带 reducer 的字段经合并后写进 checkpoint，checkpointer 才能在 run 取消时用 `_rollback_to_pre_run_checkpoint` 把线程状态恢复到 run 开始前。若字段退化为 LWW 且被并发覆盖，回滚恢复出的状态就是错的。

## 完整真实代码实现

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/agents/thread_state.py` | `ThreadState`（`AgentState` 子类）根 schema + 全部嵌套 `TypedDict`（`SandboxState` / `ThreadDataState` / `ViewedImageData` / `PromotedTools` / `DelegationEntry` / `SkillEntry`）+ 8 个自定义 reducer + `_normalize_skill_entry` 归一化辅助 + 常量（`TERMINAL_STATUSES` / `_DELEGATION_LEDGER_MAX_ENTRIES=50` / `_SKILL_CONTEXT_MAX_ENTRIES=8` / `_SKILL_DESCRIPTION_MAX_CHARS=500`） |
| `core/helix/agents/goal_state.py` | `GoalState` / `GoalEvaluation` / `GoalBlocker`（`merge_goal` 的值类型，由 goal 写入节点产出） |
| `core/helix/subagents/status_contract.py` | `SUBAGENT_STATUS_VALUES`（终态枚举，`merge_delegations` 用它派生 `TERMINAL_STATUSES`） |
| `core/helix/agents/middlewares/deferred_tool_filter_middleware.py` | `DeferredToolFilterMiddleware`：读 `state["promoted"]`（按 `catalog_hash`）过滤延迟工具 schema / 拦截未提升调用 |
| `core/helix/agents/middlewares/durable_context_middleware.py` | `DurableContextMiddleware`：从 messages 抽 task 委派 / 技能引用，写 `delegations` / `skill_context`；读 `summary_text` 注入为 `<durable_context_data>` |
| `core/helix/agents/middlewares/summarization_middleware.py` | `SummarizationMiddleware`：写 `summary_text` + `messages`（`RemoveMessage(id=REMOVE_ALL_MESSAGES)` + 保留尾） |
| `core/helix/agents/middlewares/todo_middleware.py` | `TodoMiddleware`：读 `state["todos"]` 检测上下文丢失 / 防过早退出 |
| `core/helix/sandbox/middleware.py` | `SandboxMiddleware`：diff `state["sandbox"]` 前后，懒初始化后 `Command(update={"sandbox": {"sandbox_id": ...}})` |
| `core/helix/tools/builtins/present_file_tool.py` | `present_files` 工具：`Command(update={"artifacts": paths, "messages": [...]})` |
| `core/helix/tools/builtins/view_image_tool.py` | `view_image` 工具：`Command(update={"viewed_images": {path: {...}}, "messages": [...]})` |

### 1. `ThreadState` 根 schema（入口片段）

```python
# core/helix/agents/thread_state.py - 根 schema；reducer 实现见 references/code/reducers.md
from typing import Annotated, NotRequired, TypedDict
from langchain.agents import AgentState
from helix.agents.goal_state import GoalState

# merge_sandbox 的实现见 references/code/reducers.md
SandboxStateField = Annotated[NotRequired[SandboxState | None], merge_sandbox]


class ThreadState(AgentState):
    """线程级状态 schema：AgentState 已含 messages（add_messages），本类扩展的字段
    全部经 Annotated 绑定自定义 reducer；不带 Annotated 的字段退化为 LWW，
    仅当该字段由单一写者独占时才允许如此（title / uploaded_files / summary_text / thread_data）。
    """
    sandbox: SandboxStateField
    thread_data: NotRequired[ThreadDataState | None]
    title: NotRequired[str | None]
    artifacts: Annotated[list[str], merge_artifacts]
    todos: Annotated[list | None, merge_todos]
    goal: Annotated[GoalState | None, merge_goal]
    uploaded_files: NotRequired[list[dict] | None]
    viewed_images: Annotated[dict[str, ViewedImageData], merge_viewed_images]  # image_path -> {base64, mime_type}
    promoted: Annotated[PromotedTools | None, merge_promoted]
    delegations: Annotated[list[DelegationEntry], merge_delegations]
    skill_context: Annotated[list[SkillEntry], merge_skill_context]
    summary_text: NotRequired[str | None]
```

> 全部嵌套 `TypedDict`（`SandboxState` / `ThreadDataState` / `ViewedImageData` / `PromotedTools` / `DelegationEntry` / `SkillEntry`）+ 常量 + 字段写者/读者矩阵的**完整源码**见 [references/code/state-schema.md](./references/code/state-schema.md)。

### 2. 三类 reducer 各取一个代表（完整实现见 references）

```python
# core/helix/agents/thread_state.py - 三类 reducer 各一个代表；全集见 references/code/reducers.md

# ① 幂等写防重复：相同 sandbox_id 直通，不同 -> fail-closed 抛错
def merge_sandbox(existing: SandboxState | None, new: SandboxState | None) -> SandboxState | None:
    if new is None:
        return existing
    if existing is None:
        return new
    existing_id = existing.get("sandbox_id")
    new_id = new.get("sandbox_id")
    if existing_id == new_id:
        return existing
    raise ValueError(f"Conflicting sandbox state updates: {existing_id!r} != {new_id!r}")


# ② 合并去重保序：dict.fromkeys 去重 + 保首见序
def merge_artifacts(existing: list[str] | None, new: list[str] | None) -> list[str]:
    if existing is None:
        return new or []
    if new is None:
        return existing
    return list(dict.fromkeys(existing + new))


# ③ 按 hash 重置应对 fork：catalog_hash 变 -> 整代替换；同 hash -> 并集去重
def merge_promoted(existing: PromotedTools | None, new: PromotedTools | None) -> PromotedTools | None:
    if not new:
        return existing
    if existing is None or existing.get("catalog_hash") != new["catalog_hash"]:
        return {"catalog_hash": new["catalog_hash"],
                "names": list(dict.fromkeys(new["names"]))}
    return {"catalog_hash": existing["catalog_hash"],
            "names": list(dict.fromkeys(existing["names"] + new["names"]))}
```

> 8 个 reducer（含 `merge_viewed_images` 清空协议、`merge_todos` #3123 修复、`merge_delegations` 终态保护+封顶、`merge_skill_context` 归一化+刷近度）的**完整源码**见 [references/code/reducers.md](./references/code/reducers.md)。

### 3. 动态数据流（中间件 / 工具如何读写 state）

**写 state（工具 / 中间件经 `Command(update={...})`）** - 真实源码 `core/helix/sandbox/middleware.py`、`core/helix/tools/builtins/present_file_tool.py`、`core/helix/tools/builtins/view_image_tool.py`

```python
# core/helix/sandbox/middleware.py - 沙箱懒初始化后，把 sandbox_id 经 Command 写进 state（触发 merge_sandbox）
@staticmethod
def _attach_sandbox_update(result: ToolMessage | Command, sandbox_id: str) -> ToolMessage | Command:
    """Wrap or merge ``result`` so that ``sandbox.sandbox_id`` is persisted.

    - ``ToolMessage`` -> ``Command(update={"sandbox": ..., "messages": [msg]})``
    - ``Command`` with dict update -> merge ``sandbox`` key, preserve all
      existing fields (``messages``, ``goto``, ``graph``, ``resume``, ...).
    """
    sandbox_update = {"sandbox": {"sandbox_id": sandbox_id}}
    if isinstance(result, ToolMessage):
        return Command(update={**sandbox_update, "messages": [result]})
    existing_update = result.update
    if isinstance(existing_update, dict):
        merged_update = {**existing_update, **sandbox_update}
        return dc_replace(result, update=merged_update)
    return result
```

```python
# core/helix/tools/builtins/present_file_tool.py - 并行安全：reducer 接管合并去重
return Command(
    update={
        "artifacts": normalized_paths,
        "messages": [ToolMessage("Successfully presented files", tool_call_id=tool_call_id)],
    },
)
```

```python
# core/helix/tools/builtins/view_image_tool.py - 写 viewed_images；merge_viewed_images 合并 / {} 清空
new_viewed_images = {image_path: {"base64": image_base64, "mime_type": mime_type}}
return Command(
    update={"viewed_images": new_viewed_images, "messages": [ToolMessage("Successfully read image", tool_call_id=tool_call_id)]},
)
```

**读 state（中间件经 `request.state` / `runtime.state`）** - 真实源码 `core/helix/agents/middlewares/deferred_tool_filter_middleware.py`、`core/helix/agents/middlewares/tool_output_budget_middleware.py`

```python
# core/helix/agents/middlewares/deferred_tool_filter_middleware.py - 读 promoted（按 catalog_hash 过滤）
def _promoted(self, state) -> set[str]:
    promoted = (state or {}).get("promoted")
    if promoted and promoted.get("catalog_hash") == self._catalog_hash:
        return set(promoted.get("names") or [])
    return set()

def _hidden(self, state) -> set[str]:
    return set(self._deferred) - self._promoted(state)
```

```python
# core/helix/agents/middlewares/tool_output_budget_middleware.py - 读 sandbox（不 acquire，只查）
runtime = getattr(request, "runtime", None)
state = getattr(runtime, "state", None)
sandbox_state = state.get("sandbox") if isinstance(state, dict) else None
sandbox_id = sandbox_state.get("sandbox_id") if isinstance(sandbox_state, dict) else None
```

**`messages` 通道靠 `add_messages`（继承自 `AgentState`）** - 真实源码 `core/helix/agents/middlewares/summarization_middleware.py`

```python
# core/helix/agents/middlewares/summarization_middleware.py - RemoveMessage(REMOVE_ALL_MESSAGES) + 保留尾 + 写 summary_text
return {
    "messages": [
        RemoveMessage(id=REMOVE_ALL_MESSAGES),
        *result.preserved_messages,
    ],
    "summary_text": result.summary_text,
}
```

> `RemoveMessage(id=REMOVE_ALL_MESSAGES)` 依赖 `add_messages` 的删除路径：它先清空整个 messages 通道，再追加保留的尾消息。若自定义 messages reducer，`REMOVE_ALL_MESSAGES` 与 tool_call 配对都会失效。

### references 索引

- [references/code/state-schema.md](./references/code/state-schema.md) -- 全部嵌套 `TypedDict` + 常量 + `ThreadState` 根类 + 字段写者/读者矩阵
- [references/code/reducers.md](./references/code/reducers.md) -- 8 个自定义 reducer + `_normalize_skill_entry` 归一化辅助的完整实现（含三类 reducer 速览表 + 每个 reducer 的语义要点）

## 反模式与陷阱

- ❌ **`create_agent` 漏传 `state_schema=ThreadState` 或用裸 `AgentState`** -> `sandbox`/`artifacts`/`promoted`/`delegations`/`skill_context` 全部退化为 LWW，`merge_sandbox` 冲突检测、`merge_promoted` 分代重置、`merge_delegations` 终态保护都不生效；并发写静默丢数据或触发 `INVALID_CONCURRENT_GRAPH_UPDATE`。修复：`state_schema=ThreadState` 显式传入（见 [[agent-graph-factory]] 第 9 步）。
- ❌ **不写 reducer 直接用 `list[str]` / `dict`** -> 并发写时旧值直接覆盖新值（`artifacts` 被覆盖为单元素列表）。修复：`Annotated[list[str], merge_artifacts]` / `Annotated[dict, merge_viewed_images]`。
- ❌ **`merge_sandbox` 静默选一个值** -> sandbox 隔离 bug（同 thread 跨沙盒读写）永远查不出来。修复：不同 id `raise ValueError`，让 P0 隔离冲突第一时间暴露。
- ❌ **节点 in-place 改 `state["artifacts"].append(x)`** -> 不触发 reducer，LangGraph 看不到该更新，checkpoint 不记录。修复：返回 `{"artifacts": [x]}` 让 reducer 接管。
- ❌ **想清空 `viewed_images` 但传 `None`** -> `None` 在协议里是"未触动"，清空意图被吃掉，图像反复注入模型上下文。修复：清空必须传 `{}`（空 dict）。
- ❌ **想清空 `todos` 但靠"不返回 todos"** -> 隐式 `None` 被 `merge_todos` 当"未触动"保留 existing（这正是 #3123 修复后的行为）。修复：显式清空必须返回 `[]`（空 list）。
- ❌ **给 `messages` 自定义 reducer** -> 破坏 `add_messages` 的 ID-swap / `RemoveMessage(REMOVE_ALL_MESSAGES)` / tool_call 配对，摘要、动态注入、工具配对全部失效。修复：继承 `AgentState`，不重写 messages 通道。
- ❌ **reducer 有副作用（写文件 / 发请求 / 读时间）** -> LangGraph 重放 checkpoint 时多次调用 reducer，结果不一致，断点恢复失败。修复：reducer 只做纯合并，副作用放中间件 / 工具。
- ❌ **`merge_promoted` 在 catalog_hash 变化时做并集而非整代替换** -> MCP server 变更后旧工具名残留，`DeferredToolFilterMiddleware` 误放行已不存在的工具。修复：hash 变即整片重置。
- ❌ **`merge_delegations` 允许终态被非终态覆盖** -> 乱序到达的旧快照（`in_progress`）把已 `completed` 的委派"复活"成进行中，台账状态错乱。修复：`previous["status"] in TERMINAL_STATUSES and entry["status"] not in TERMINAL_STATUSES` 时 `continue` 跳过。
- ❌ **`uploaded_files` / `title` / `summary_text` 想去重却没 reducer** -> 现状是 LWW，依赖上游中间件每次给完整列表 / 单一写者独占。修复：要么补 reducer，要么在 schema 注释里显式声明该字段由某某中间件独占写、调用方不得 partial update。
- ❌ **`merge_sandbox` 抛的 `ValueError` 被上层 `try/except` 静默吞掉** -> 隔离失效但日志没痕迹。修复：上层 except 必须 `logger.exception` 后重新抛出（`Conflicting sandbox state updates` 是 P0 告警串）。
- ❌ **reducer import 错同名占位函数** -> `Annotated[list, merge_artifacts]` 静默绑了占位，真实 `merge_artifacts` 没生效。修复：回归测试用 `get_type_hints(ThreadState, include_extras=True)` 断言 `merge_artifacts in hints["artifacts"].__metadata__`（见 `test_thread_state_reducers.py::TestThreadStateAnnotations`）。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 位置 | 说明 |
|---|---|---|
| `state_schema` | `create_agent(state_schema=ThreadState)` | 必须显式传入；漏传则全部退化为 LWW |
| `Annotated[T, reducer]` | `ThreadState` 字段声明 | 决定该字段走合并语义还是 LWW；漏标即 LWW |
| `NotRequired[T \| None]` | `ThreadState` 字段声明 | 决定初始状态可否缺省；可选字段不要求 run 启动时填值 |
| `_DELEGATION_LEDGER_MAX_ENTRIES` | `thread_state.py`（=50） | delegations 台账封顶；超限保留最近 50 条 |
| `_SKILL_CONTEXT_MAX_ENTRIES` | `thread_state.py`（=8） | skill_context 引用封顶；超限丢最久未读 |
| `_SKILL_DESCRIPTION_MAX_CHARS` | `thread_state.py`（=500） | 归一化时 description 截断长度 |
| `TERMINAL_STATUSES` | `thread_state.py`（派生自 `SUBAGENT_STATUS_VALUES`） | delegations 终态集合；终态不被非终态降级 |
| `checkpointer` | 图编译选项 | 决定 reducer 合并结果是否跨进程持久化（跨切不变量 3 的回滚基础） |

**关键日志串（排障时 grep）**

- `Conflicting sandbox state updates: <a> != <b>` -- `merge_sandbox` 触发的隔离冲突，**P0 告警**；上层必须 `logger.exception` 后重抛。
- `Filtered <N> deferred tool schema(s) from model binding` -- `DeferredToolFilterMiddleware` 读 `promoted` 后过滤了 N 个延迟工具（DEBUG 级，正常）。
- `Releasing sandbox <id>` / `Releasing sandbox <id> from context` -- `SandboxMiddleware` 释放沙箱（run 结束）。
- `Create Agent(<name>) -> ...` -- 图工厂每次建图打这一行，定位"schema 按什么参数绑定"（见 [[agent-graph-factory]]）。

**自测方向**

- **reducer 绑定回归**：`get_type_hints(ThreadState, include_extras=True)`，断言每个该挂 reducer 的字段的 `__metadata__` 含对应函数（防 `Annotated` 被误改回裸类型，见 `TestThreadStateAnnotations`）。
- **表驱动 4 分支**：每个 reducer 覆盖 `(existing=None,new=None)` / `(existing=None,new=val)` / `(val,None)` / `(val1,val2)`。
- **`merge_sandbox` 冲突路径**：`existing={"sandbox_id":"a"}`、`new={"sandbox_id":"b"}` -> `pytest.raises(ValueError, match="Conflicting sandbox state updates")`。
- **`merge_sandbox` 幂等**：相同 id / 两边都 `None` / 两边都缺 key（`{}`） -> 返回 existing，不抛。
- **#3123 回归**：`merge_todos(existing=[...], None) == existing`（None 不清空）；`merge_todos(existing=[...], []) == []`（显式空 list 才清空）。
- **`merge_viewed_images` 清空协议**：`merge_viewed_images(existing={...}, {}) == {}`（空 dict 清空）；`merge_viewed_images(existing={...}, None) == existing`（None 保留）。
- **`merge_promoted` 分代隔离**：先写 `hash="h1"`，再写 `hash="h2"` -> 最终只剩 h2 的 names（旧名全丢）；同 hash -> 并集去重保序。畸形 existing（缺 `catalog_hash`）-> 不崩溃，按不匹配整代替换。
- **`merge_delegations` 终态保护**：`existing=[{"id":"a","status":"completed"}]`、`new=[{"id":"a","status":"in_progress"}]` -> 仍是 `completed`；同 id 更新保留首见 `created_at`；超 cap 保留最近 50 条。
- **`merge_skill_context` 归一化自愈**：existing 含遗留 `content` key + 超长 description，`new=None` -> 输出丢 `content`、description 截到 500；同 path 重读 -> 移到末尾（刷近度）；超 cap 丢最久未读。
- **并发 superstep**：两节点同步返回 `{"artifacts": ["a"]}` / `{"artifacts": ["b"]}` -> 最终 `["a","b"]`（不是 `["b"]`）。
- **checkpointer round-trip**：写入后读出，所有字段等价（特别 `viewed_images` 的 base64 编码、`delegations` 的 `created_at` 不漂移）。

## 进一步阅读

- schema 完整源码（TypedDict / 常量 / 字段矩阵）：[references/code/state-schema.md](./references/code/state-schema.md)
- 全部 reducer 完整源码（含语义要点）：[references/code/reducers.md](./references/code/reducers.md)
- 回归测试：`backend/tests/test_thread_state_reducers.py`、`backend/tests/test_thread_state_promoted.py`
- 关联 skill：[[e2e-request-lifecycle]]（④建图 / ⑤中间件 在链路中的位置）、[[agent-graph-factory]]（`create_agent(state_schema=ThreadState)` 绑定时机）、[[middleware-chain-design]]（读写 state 的中间件清单）、[[context-window-management]]（`SummarizationMiddleware` 写 `summary_text` + `RemoveMessage`）、[[tool-assembly-and-policy]]（`tool_search` 写 `promoted`、`DeferredToolFilterMiddleware` 读 `promoted`）、[[sandbox-abstraction]]（`SandboxMiddleware` 写 `sandbox`）、[[subagent-delegation]]（`DurableContextMiddleware` 写 `delegations`）、[[skill-system-design]]（`skill_context` 引用通道）、[[memory-system-design]]（`goal` 通道）
- LangGraph reducer 文档：https://langchain-ai.github.io/langgraph/concepts/low_level/#reducers
- LangGraph `add_messages` / `RemoveMessage` 文档：https://langchain-ai.github.io/langgraph/concepts/messages/
