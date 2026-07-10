# state-schema.md — `ThreadState` 完整 schema

> 本文件是 `core/helix/agents/thread_state.py` 的 **schema 部分**（imports + 全部嵌套 `TypedDict` + 常量 + `ThreadState` 根 schema）。reducer 函数的实现见同模块的 [./reducers.md](./reducers.md)。
>
> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

## 完整 schema（未截断）

```python
# core/helix/agents/thread_state.py
from collections.abc import Mapping
from typing import Annotated, NotRequired, TypedDict

from langchain.agents import AgentState

from helix.agents.goal_state import GoalState
from helix.subagents.status_contract import SUBAGENT_STATUS_VALUES


class SandboxState(TypedDict):
    sandbox_id: NotRequired[str | None]


class ThreadDataState(TypedDict):
    workspace_path: NotRequired[str | None]
    uploads_path: NotRequired[str | None]
    outputs_path: NotRequired[str | None]


class ViewedImageData(TypedDict):
    base64: str
    mime_type: str


# merge_sandbox 的实现见 ./reducers.md；此处仅给出字段别名定义。
SandboxStateField = Annotated[NotRequired[SandboxState | None], merge_sandbox]


class PromotedTools(TypedDict):
    catalog_hash: str
    names: list[str]


# 终态集合由 subagent 状态契约派生（completed/failed/cancelled/timed_out/polling_timed_out）。
# merge_delegations 用它保证：已终结的委派状态永不被非终态值覆盖（见 ./reducers.md）。
TERMINAL_STATUSES: frozenset[str] = frozenset(SUBAGENT_STATUS_VALUES)
_DELEGATION_LEDGER_MAX_ENTRIES = 50


class DelegationEntry(TypedDict):
    id: str
    description: str
    subagent_type: str
    status: str
    result_brief: NotRequired[str]
    result_sha256: NotRequired[str]
    result_ref: NotRequired[str]
    # Why a guardrail cap ended the run early (#3875 Phase 2): token_capped /
    # turn_capped / loop_capped. The status stays completed/failed; this field
    # is the additive signal that distinguishes a capped run from a clean one.
    stop_reason: NotRequired[str]
    created_at: str


_SKILL_CONTEXT_MAX_ENTRIES = 8
_SKILL_DESCRIPTION_MAX_CHARS = 500


class SkillEntry(TypedDict):
    name: str
    path: str
    description: str
    loaded_at: int


class ThreadState(AgentState):
    """线程级状态 schema：在 AgentState 之上扩展的字段全部经 Annotated 绑定自定义 reducer。

    AgentState（langchain.agents.AgentState）已声明 ``messages: Annotated[list[AnyMessage], add_messages]``，
    本类继承它，故 messages 通道走 LangGraph 内置的 add_messages（处理 ID-swap / RemoveMessage /
    tool_call 配对），**不要自定义 messages 的 reducer**。下面每个带 Annotated[..., fn] 的字段
    在同一 super-step 内被多个节点/中间件并发写时，由 fn 合并；不带 Annotated 的字段退化为
    Last-Write-Wins（LWW），仅当该字段由单一写者独占时才允许如此。
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

## 字段一览（reducer 绑定 + 写者/读者）

| 字段 | 类型注解 | reducer | 写者 | 读者 |
|---|---|---|---|---|
| `messages` | 继承自 `AgentState` | `add_messages`（内置） | 模型 / 工具 / 各中间件（`Command(update={"messages": [...]})`） | 全链路（模型上下文、摘要、渲染） |
| `sandbox` | `SandboxStateField` | `merge_sandbox` | `SandboxMiddleware`（懒初始化后 `Command(update={"sandbox": {"sandbox_id": ...}})`） | `ToolOutputBudgetMiddleware` / `ReadBeforeWriteMiddleware` / 沙箱工具 |
| `thread_data` | `NotRequired[ThreadDataState \| None]` | 无（LWW） | `ThreadDataMiddleware`（建 per-thread 目录，单一写者） | 沙箱工具（虚拟路径映射） |
| `title` | `NotRequired[str \| None]` | 无（LWW） | `TitleMiddleware`（单一写者） | gateway 线程元数据同步 |
| `artifacts` | `Annotated[list[str], merge_artifacts]` | `merge_artifacts` | `present_files` 工具（`Command(update={"artifacts": paths})`） | 前端产物列表 |
| `todos` | `Annotated[list \| None, merge_todos]` | `merge_todos` | `write_todos` 工具（经 `TodoListMiddleware`） | `TodoMiddleware`（上下文丢失检测 + 防过早退出） |
| `goal` | `Annotated[GoalState \| None, merge_goal]` | `merge_goal` | goal 写入节点 | goal 评估节点 |
| `uploaded_files` | `NotRequired[list[dict] \| None]` | 无（LWW） | `UploadsMiddleware`（单一写者，每次给完整列表） | 系统提示词 `<uploaded_files>` 段 |
| `viewed_images` | `Annotated[dict[str, ViewedImageData], merge_viewed_images]` | `merge_viewed_images` | `view_image` 工具（`Command(update={"viewed_images": {path: {...}}})`）；`ViewImageMiddleware` 处理后清空（`{}`） | `ViewImageMiddleware`（注入 base64 到模型请求） |
| `promoted` | `Annotated[PromotedTools \| None, merge_promoted]` | `merge_promoted` | `tool_search` 工具（提升延迟 MCP 工具时写） | `DeferredToolFilterMiddleware`（按 catalog_hash 过滤 schema / 拦截未提升调用） |
| `delegations` | `Annotated[list[DelegationEntry], merge_delegations]` | `merge_delegations` | `DurableContextMiddleware`（从 messages 抽取 task 委派，摘要前捕获） | `DurableContextMiddleware`（注入为 `<durable_context_data>`） |
| `skill_context` | `Annotated[list[SkillEntry], merge_skill_context]` | `merge_skill_context` | `DurableContextMiddleware`（从 messages 抽取已加载技能引用） | `DurableContextMiddleware`（注入为 `<durable_context_data>`） |
| `summary_text` | `NotRequired[str \| None]` | 无（LWW） | `SummarizationMiddleware`（压缩后写摘要文本） | `DurableContextMiddleware`（注入为持久上下文） |

## 相关

- 全部 reducer 实现：[./reducers.md](./reducers.md)
- schema 如何被图工厂绑定：[[agent-graph-factory]]（`create_agent(state_schema=ThreadState)`）
- 中间件如何读写 state：[[middleware-chain-design]]
