# create_helix_agent SDK 工厂 + RuntimeFeatures

> 与 [SKILL.md](../../SKILL.md) 同步。本文件收录 `core/helix/agents/factory.py`（SDK 纯参数工厂）与 `core/helix/agents/features.py`（声明式 feature flag + 定位装饰器）的完整源码。代码为真实实现（已按插件匿名化规则映射到自定结构）。真实代码的原注释保留以保真；关键处补中文注解。

---

## 1. 声明式 feature flag + 定位装饰器（features.py）

纯数据类与装饰器，无 IO、无副作用。`RuntimeFeatures` 的每个字段接受三态：`True`（内置默认中间件）/ `False`（禁用）/ `AgentMiddleware` 实例（自定义替换）。`summarization` 与 `guardrail` 无内置默认，只接受 `False` 或自定义实例。

```python
# core/helix/agents/features.py
"""Declarative feature flags and middleware positioning for create_helix_agent.

Pure data classes and decorators - no I/O, no side effects.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from langchain.agents.middleware import AgentMiddleware


@dataclass
class RuntimeFeatures:
    """``create_helix_agent`` 的声明式 feature flag。

    大多数 feature 接受：
    - ``True``: 用内置默认中间件
    - ``False``: 禁用
    - 一个 ``AgentMiddleware`` 实例: 用这个自定义实现替换

    ``summarization`` 与 ``guardrail`` 没有内置默认 -- 它们只接受
    ``False``（禁用）或 ``AgentMiddleware`` 实例（自定义）。
    """

    sandbox: bool | AgentMiddleware = True
    memory: bool | AgentMiddleware = False
    summarization: Literal[False] | AgentMiddleware = False
    subagent: bool | AgentMiddleware = False
    vision: bool | AgentMiddleware = False
    auto_title: bool | AgentMiddleware = False
    guardrail: Literal[False] | AgentMiddleware = False
    loop_detection: bool | AgentMiddleware = True
    token_budget: bool | AgentMiddleware = False


# ---------------------------------------------------------------------------
# 中间件定位装饰器
# ---------------------------------------------------------------------------


def Next(anchor: type[AgentMiddleware]):
    """声明本中间件应放在 *anchor* 之后。"""
    if not (isinstance(anchor, type) and issubclass(anchor, AgentMiddleware)):
        raise TypeError(f"@Next expects an AgentMiddleware subclass, got {anchor!r}")

    def decorator(cls: type[AgentMiddleware]) -> type[AgentMiddleware]:
        cls._next_anchor = anchor  # type: ignore[attr-defined]
        return cls

    return decorator


def Prev(anchor: type[AgentMiddleware]):
    """声明本中间件应放在 *anchor* 之前。"""
    if not (isinstance(anchor, type) and issubclass(anchor, AgentMiddleware)):
        raise TypeError(f"@Prev expects an AgentMiddleware subclass, got {anchor!r}")

    def decorator(cls: type[AgentMiddleware]) -> type[AgentMiddleware]:
        cls._prev_anchor = anchor  # type: ignore[attr-defined]
        return cls

    return decorator
```

---

## 2. SDK 纯参数工厂（factory.py）

`create_helix_agent` 是 SDK 级入口，介于原始 `langchain.agents.create_agent` 与 config 驱动的 `make_lead_agent` 应用工厂之间。工厂装配本身不读 config 文件；部分注入的运行时组件（如 `task_tool`）在调用时仍可能读全局 config（Phase 2 目标是全 config-free 运行时）。

```python
# core/helix/agents/factory.py
"""Pure-argument factory for Helix agents.

``create_helix_agent`` accepts plain Python arguments - no YAML files, no
global singletons.  It is the SDK-level entry point sitting between the raw
``langchain.agents.create_agent`` primitive and the config-driven
``make_lead_agent`` application factory.

Note: the factory assembly itself is config-free, but some injected runtime
components (e.g. ``task_tool`` for subagent) may still read global config at
invocation time.  Full config-free runtime is a Phase 2 goal.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from langchain.agents import create_agent
from langchain.agents.middleware import AgentMiddleware

from helix.agents.features import RuntimeFeatures
from helix.agents.middlewares.clarification_middleware import ClarificationMiddleware
from helix.agents.middlewares.dangling_tool_call_middleware import DanglingToolCallMiddleware
from helix.agents.middlewares.tool_error_handling_middleware import ToolErrorHandlingMiddleware
from helix.agents.thread_state import ThreadState
from helix.tools.builtins import ask_clarification_tool

if TYPE_CHECKING:
    from langchain_core.language_models import BaseChatModel
    from langchain_core.tools import BaseTool
    from langgraph.checkpoint.base import BaseCheckpointSaver
    from langgraph.graph.state import CompiledStateGraph

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# TodoMiddleware prompts（SDK 精简版）
# ---------------------------------------------------------------------------

_TODO_SYSTEM_PROMPT = """
<todo_list_system>
You have access to the `write_todos` tool to help you manage and track complex multi-step objectives.

**CRITICAL RULES:**
- Mark todos as completed IMMEDIATELY after finishing each step - do NOT batch completions
- Keep EXACTLY ONE task as `in_progress` at any time (unless tasks can run in parallel)
- Update the todo list in REAL-TIME as you work - this gives users visibility into your progress
- DO NOT use this tool for simple tasks (< 3 steps) - just complete them directly
</todo_list_system>
"""

_TODO_TOOL_DESCRIPTION = "Use this tool to create and manage a structured task list for complex work sessions.  Only use for complex tasks (3+ steps)."


# ---------------------------------------------------------------------------
# 公共 API
# ---------------------------------------------------------------------------


def create_helix_agent(
    model: BaseChatModel,
    tools: list[BaseTool] | None = None,
    *,
    system_prompt: str | None = None,
    middleware: list[AgentMiddleware] | None = None,
    features: RuntimeFeatures | None = None,
    extra_middleware: list[AgentMiddleware] | None = None,
    plan_mode: bool = False,
    state_schema: type | None = None,
    checkpointer: BaseCheckpointSaver | None = None,
    name: str = "default",
) -> CompiledStateGraph:
    """从普通 Python 参数创建一个 Helix agent。

    工厂装配本身不读 config 文件。部分注入的运行时组件（如 ``task_tool``）在调用时
    仍可能依赖全局 config -- 见 Phase 2 路线图的 full config-free 运行时。

    Parameters
    ----------
    model:
        Chat model 实例。
    tools:
        用户提供的工具。feature 注入的工具自动追加。
    system_prompt:
        System message。``None`` 用最小默认。
    middleware:
        **全量接管** -- 若提供，就用这个精确列表。
        不能与 *features* 或 *extra_middleware* 组合。
    features:
        声明式 feature flag。不能与 *middleware* 组合。
    extra_middleware:
        经 ``@Next``/``@Prev`` 定位插入自动装配链的额外中间件。
        不能与 *middleware* 同用。
    plan_mode:
        启用 TodoMiddleware 做任务追踪。
    state_schema:
        LangGraph state 类型。默认 ``ThreadState``。
    checkpointer:
        可选持久化后端。
    name:
        agent 名（透传给在意的中间件，如 ``MemoryMiddleware``）。

    Raises
    ------
    ValueError
        若同时提供 *middleware* 与 *features*/*extra_middleware*。
    """
    if middleware is not None and features is not None:
        raise ValueError("Cannot specify both 'middleware' and 'features'.  Use one or the other.")
    if middleware is not None and extra_middleware:
        raise ValueError("Cannot use 'extra_middleware' with 'middleware' (full takeover).")
    if extra_middleware:
        for mw in extra_middleware:
            if not isinstance(mw, AgentMiddleware):
                raise TypeError(f"extra_middleware items must be AgentMiddleware instances, got {type(mw).__name__}")

    effective_tools: list[BaseTool] = list(tools or [])
    effective_state = state_schema or ThreadState

    if middleware is not None:
        effective_middleware = list(middleware)
    else:
        feat = features or RuntimeFeatures()
        effective_middleware, extra_tools = _assemble_from_features(
            feat,
            name=name,
            plan_mode=plan_mode,
            extra_middleware=extra_middleware or [],
        )
        # 按工具名去重 -- 用户提供的工具优先。
        existing_names = {t.name for t in effective_tools}
        for t in extra_tools:
            if t.name not in existing_names:
                effective_tools.append(t)
                existing_names.add(t.name)

    return create_agent(
        model=model,
        tools=effective_tools or None,
        middleware=effective_middleware,
        system_prompt=system_prompt,
        state_schema=effective_state,
        checkpointer=checkpointer,
        name=name,
    )
```

---

## 3. feature 驱动的中间件装配（_assemble_from_features）

两阶段排序：(1) 内置链固定顺序追加；(2) extra 中间件经 `@Next`/`@Prev` 插入。每个 feature 值三态处理：`False` 跳过 / `True` 用内置默认 / `AgentMiddleware` 实例直接用。`ClarificationMiddleware` 永远最后。

```python
# core/helix/agents/factory.py - 内部：feature 驱动的中间件装配


def _assemble_from_features(
    feat: RuntimeFeatures,
    *,
    name: str = "default",
    plan_mode: bool = False,
    extra_middleware: list[AgentMiddleware] | None = None,
) -> tuple[list[AgentMiddleware], list[BaseTool]]:
    """从 *feat* 构建有序中间件链 + 额外工具。

    中间件顺序匹配 ``make_lead_agent``（14 middlewares）：

      0-2. Sandbox infrastructure (ThreadData -> Uploads -> Sandbox)
      3.   DanglingToolCallMiddleware (always)
      4.   GuardrailMiddleware (guardrail feature)
      5.   ToolErrorHandlingMiddleware (always)
      6.   SummarizationMiddleware (summarization feature)
      7.   TodoMiddleware (plan_mode parameter)
      8.   TitleMiddleware (auto_title feature)
      9.   MemoryMiddleware (memory feature)
      10.  ViewImageMiddleware (vision feature)
      11.  SubagentLimitMiddleware (subagent feature)
      12.  LoopDetectionMiddleware (loop_detection feature)
      13.  ClarificationMiddleware (always last)

    两阶段排序：
      1. 内置链 -- 固定顺序追加。
      2. 额外中间件 -- 经 @Next/@Prev 插入。

    每个 feature 值处理为：
      - ``False``: 跳过
      - ``True``: 创建内置默认中间件（``summarization`` 与 ``guardrail`` 不可 --
        它们需要自定义实例）
      - ``AgentMiddleware`` 实例: 直接用（自定义替换）
    """
    chain: list[AgentMiddleware] = []
    extra_tools: list[BaseTool] = []

    # --- [0-2] Sandbox 基础设施 ---
    if feat.sandbox is not False:
        if isinstance(feat.sandbox, AgentMiddleware):
            chain.append(feat.sandbox)
        else:
            from helix.agents.middlewares.thread_data_middleware import ThreadDataMiddleware
            from helix.agents.middlewares.uploads_middleware import UploadsMiddleware
            from helix.sandbox.middleware import SandboxMiddleware

            chain.append(ThreadDataMiddleware(lazy_init=True))
            chain.append(UploadsMiddleware())
            chain.append(SandboxMiddleware(lazy_init=True))

    # --- [3] DanglingToolCall (always) ---
    chain.append(DanglingToolCallMiddleware())

    # --- [4] Guardrail ---
    if feat.guardrail is not False:
        if isinstance(feat.guardrail, AgentMiddleware):
            chain.append(feat.guardrail)
        else:
            raise ValueError("guardrail=True requires a custom AgentMiddleware instance (no built-in GuardrailMiddleware yet)")

    # --- [5] ToolErrorHandling (always) ---
    chain.append(ToolErrorHandlingMiddleware())

    # --- [6] Summarization ---
    if feat.summarization is not False:
        if isinstance(feat.summarization, AgentMiddleware):
            chain.append(feat.summarization)
        else:
            raise ValueError("summarization=True requires a custom AgentMiddleware instance (SummarizationMiddleware needs a model argument)")

    # --- [7] TodoMiddleware (plan_mode) ---
    if plan_mode:
        from helix.agents.middlewares.todo_middleware import TodoMiddleware

        chain.append(TodoMiddleware(system_prompt=_TODO_SYSTEM_PROMPT, tool_description=_TODO_TOOL_DESCRIPTION))

    # --- [8] Auto Title ---
    if feat.auto_title is not False:
        if isinstance(feat.auto_title, AgentMiddleware):
            chain.append(feat.auto_title)
        else:
            from helix.agents.middlewares.title_middleware import TitleMiddleware

            chain.append(TitleMiddleware())

    # --- [9] Memory ---
    if feat.memory is not False:
        if isinstance(feat.memory, AgentMiddleware):
            chain.append(feat.memory)
        else:
            from helix.agents.middlewares.memory_middleware import MemoryMiddleware

            chain.append(MemoryMiddleware(agent_name=name))

    # --- [10] Vision ---
    if feat.vision is not False:
        if isinstance(feat.vision, AgentMiddleware):
            chain.append(feat.vision)
        else:
            from helix.agents.middlewares.view_image_middleware import ViewImageMiddleware

            chain.append(ViewImageMiddleware())

        if feat.sandbox is not False:
            from helix.tools.builtins import view_image_tool

            extra_tools.append(view_image_tool)

    # --- [11] Subagent ---
    if feat.subagent is not False:
        if isinstance(feat.subagent, AgentMiddleware):
            chain.append(feat.subagent)
        else:
            from helix.agents.middlewares.subagent_limit_middleware import SubagentLimitMiddleware

            chain.append(SubagentLimitMiddleware())
        from helix.tools.builtins import task_tool

        extra_tools.append(task_tool)

    # --- [12] LoopDetection ---
    if feat.loop_detection is not False:
        if isinstance(feat.loop_detection, AgentMiddleware):
            chain.append(feat.loop_detection)
        else:
            from helix.agents.middlewares.loop_detection_middleware import LoopDetectionMiddleware
            from helix.config.loop_detection_config import LoopDetectionConfig

            chain.append(LoopDetectionMiddleware.from_config(LoopDetectionConfig()))

    # --- [13] TokenBudget ---
    if feat.token_budget is not False:
        if isinstance(feat.token_budget, AgentMiddleware):
            chain.append(feat.token_budget)
        else:
            from helix.agents.middlewares.token_budget_middleware import TokenBudgetMiddleware
            from helix.config.token_budget_config import TokenBudgetConfig

            chain.append(TokenBudgetMiddleware.from_config(TokenBudgetConfig()))

    # --- [14] Clarification (内置项中永远最后) ---
    chain.append(ClarificationMiddleware())
    extra_tools.append(ask_clarification_tool)

    # --- 经 @Next/@Prev 插入 extra_middleware ---
    if extra_middleware:
        _insert_extra(chain, extra_middleware)
        # 不变量：ClarificationMiddleware 必须永远最后。
        # @Next(ClarificationMiddleware) 可能把它顶离尾部。
        clar_idx = next(i for i, m in enumerate(chain) if isinstance(m, ClarificationMiddleware))
        if clar_idx != len(chain) - 1:
            chain.append(chain.pop(clar_idx))

    return chain, extra_tools
```

---

## 4. @Next/@Prev 锚点解析（_insert_extra）

算法：(1) 校验无中间件同时有 @Next 与 @Prev；(2) 冲突检测（两个 extra 指向同一锚点）；(3) 无锚点 extra 插到 ClarificationMiddleware 前；(4) 有锚点 extra 迭代插入（支持外部间互锚）；(5) 锚点无法解析则报错。

```python
# core/helix/agents/factory.py - 内部：经 @Next/@Prev 插入额外中间件


def _insert_extra(chain: list[AgentMiddleware], extras: list[AgentMiddleware]) -> None:
    """用 ``@Next``/``@Prev`` 锚点把额外中间件插入 *chain*。

    算法：
      1. 校验：无中间件同时有 @Next 与 @Prev。
      2. 冲突检测：两个 extra 指向同一锚点（同向或反向）-> 报错。
      3. 无锚点 extra 插到 ClarificationMiddleware 前。
      4. 有锚点 extra 迭代插入（支持外部间互锚）。
      5. 所有轮次后锚点仍无法解析 -> 报错。
    """
    next_targets: dict[type, type] = {}
    prev_targets: dict[type, type] = {}

    anchored: list[tuple[AgentMiddleware, str, type]] = []
    unanchored: list[AgentMiddleware] = []

    for mw in extras:
        next_anchor = getattr(type(mw), "_next_anchor", None)
        prev_anchor = getattr(type(mw), "_prev_anchor", None)

        if next_anchor and prev_anchor:
            raise ValueError(f"{type(mw).__name__} cannot have both @Next and @Prev")

        if next_anchor:
            if next_anchor in next_targets:
                raise ValueError(f"Conflict: {type(mw).__name__} and {next_targets[next_anchor].__name__} both @Next({next_anchor.__name__})")
            if next_anchor in prev_targets:
                raise ValueError(f"Conflict: {type(mw).__name__} @Next({next_anchor.__name__}) and {prev_targets[next_anchor].__name__} @Prev({next_anchor.__name__}) - use cross-anchoring between extras instead")
            next_targets[next_anchor] = type(mw)
            anchored.append((mw, "next", next_anchor))
        elif prev_anchor:
            if prev_anchor in prev_targets:
                raise ValueError(f"Conflict: {type(mw).__name__} and {prev_targets[prev_anchor].__name__} both @Prev({prev_anchor.__name__})")
            if prev_anchor in next_targets:
                raise ValueError(f"Conflict: {type(mw).__name__} @Prev({prev_anchor.__name__}) and {next_targets[prev_anchor].__name__} @Next({prev_anchor.__name__}) - use cross-anchoring between extras instead")
            prev_targets[prev_anchor] = type(mw)
            anchored.append((mw, "prev", prev_anchor))
        else:
            unanchored.append(mw)

    # 无锚点 -> ClarificationMiddleware 前
    clarification_idx = next(i for i, m in enumerate(chain) if isinstance(m, ClarificationMiddleware))
    for mw in unanchored:
        chain.insert(clarification_idx, mw)
        clarification_idx += 1

    # 有锚点 -> 迭代插入（支持外部到外部的锚定）
    pending = list(anchored)
    max_rounds = len(pending) + 1
    for _ in range(max_rounds):
        if not pending:
            break
        remaining = []
        for mw, direction, anchor in pending:
            idx = next(
                (i for i, m in enumerate(chain) if isinstance(m, anchor)),
                None,
            )
            if idx is None:
                remaining.append((mw, direction, anchor))
                continue
            if direction == "next":
                chain.insert(idx + 1, mw)
            else:
                chain.insert(idx, mw)
        if len(remaining) == len(pending):
            names = [type(m).__name__ for m, _, _ in remaining]
            anchor_types = {a for _, _, a in remaining}
            remaining_types = {type(m) for m, _, _ in remaining}
            circular = anchor_types & remaining_types
            if circular:
                raise ValueError(f"Circular dependency among extra middlewares: {', '.join(t.__name__ for t in circular)}")
            raise ValueError(f"Cannot resolve positions for {', '.join(names)} - anchors {', '.join(a.__name__ for _, _, a in remaining)} not found in chain")
        pending = remaining
```

---

## 5. 与 make_lead_agent 的关系

| 维度 | `make_lead_agent`（生产工厂） | `create_helix_agent`（SDK 工厂） |
|---|---|---|
| 入口 | `langgraph.json` 注册，被 LangGraph Server / Studio / 嵌入式客户端共用 | 编程式调用（子代理、测试、SDK） |
| 参数来源 | `RunnableConfig`（configurable + context 双通道） | 普通 Python 参数（model / tools / features / ...） |
| 中间件装配 | `build_middlewares`（全量 29 项链，见 [make-lead-agent.md](./make-lead-agent.md)） | `_assemble_from_features`（精简 14 项链，feature flag 驱动） |
| 工具装配 | `get_available_tools` + 技能白名单 + 延迟切分 + non_interactive 剥离 | 用户传入 + feature 注入（`task_tool` / `view_image_tool` / `ask_clarification_tool`），按名去重 |
| 底层 | 都调 `langchain.agents.create_agent`，互不委托 | 都调 `langchain.agents.create_agent`，互不委托 |

两者共享 `ClarificationMiddleware 必须最后` 的不变量：`build_middlewares` 在末尾 `append(ClarificationMiddleware())`；`_assemble_from_features` 在插入 extra 后强制把 `ClarificationMiddleware` 移回尾部。

---

相关 skill：[[middleware-chain-design]]（29 项链 vs 14 项链的差异与共享基座）、[[tool-assembly-and-policy]]（工具去重与延迟切分）、[[subagent-delegation]]（`task_tool` 注入时机）、[[system-prompt-template]]（`create_helix_agent` 的 `system_prompt` 参数）
