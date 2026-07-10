# tool-assembly-and-policy · deferred 与 tool_search 完整源码

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。本文件收录延迟工具发现链路的完整实现：不可变 catalog、闭包式 tool_search 工具、schema 过滤中间件、prompt 段渲染。

## 1. 不可变延迟工具索引（DeferredToolCatalog）

```python
# core/helix/tools/builtins/tool_search.py（catalog 部分）
import hashlib
import json
import re
from functools import cached_property

from langchain.tools import BaseTool
from langchain_core.utils.function_calling import convert_to_openai_function

MAX_RESULTS = 5  # 每次搜索最多返回的工具数


def _compile_catalog_regex(pattern: str) -> re.Pattern[str]:
    """大小写不敏感地编译 pattern；非法正则（如不平衡括号）回退到字面子串匹配。

    搜索 query 来自模型，必须降级而非抛 re.error。
    """
    try:
        return re.compile(pattern, re.IGNORECASE)
    except re.error:
        return re.compile(re.escape(pattern), re.IGNORECASE)


# NOTE: frozen=True 不加 slots=True，保留 __dict__，让下面的 @cached_property 能缓存
# （它们写 instance.__dict__，绕过 frozen 的 __setattr__）。不要加 slots=True，
# 否则 hash/names 在运行时断。
@dataclass(frozen=True)
class DeferredToolCatalog:
    """不可变的延迟工具索引。纯搜索，无 mutation。"""

    tools: tuple[BaseTool, ...]

    @cached_property
    def names(self) -> frozenset[str]:
        return frozenset(t.name for t in self.tools)

    @cached_property
    def hash(self) -> str:
        """catalog 规范 hash：按 name 排序后取每个工具的 name + openai function schema 的 sha256 前 16 位。

        用作 promotion 作用域：MCP server 改了 name/schema 后 hash 变，
        merge_promoted 与 DeferredToolFilterMiddleware 据此丢弃旧 promotion（防漂移）。
        """
        canon = [{"name": t.name, "schema": convert_to_openai_function(t)}
                 for t in sorted(self.tools, key=lambda t: t.name)]
        blob = json.dumps(canon, sort_keys=True, ensure_ascii=False, default=str)
        return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]

    def search(self, query: str) -> list[BaseTool]:
        """按三种语法搜索延迟工具：

        - ``select:Read,Edit`` -- 按 name 精确取（无上限截断到 MAX_RESULTS）
        - ``+slack send`` -- 必含 ``slack``（第一词，在 name 里），按剩余词排序
        - ``notebook jupyter`` -- 关键词/正则，name 命中得分 2、description 命中得分 1
        """
        query = query.strip()
        if not query:
            return []

        if query.startswith("select:"):
            wanted = {n.strip() for n in query[7:].split(",")}
            return [t for t in self.tools if t.name in wanted][:MAX_RESULTS]

        if query.startswith("+"):
            parts = query[1:].split(None, 1)
            if not parts:
                return []  # 裸 "+" 无必含词：无结果
            required = parts[0].lower()
            candidates = [t for t in self.tools if required in t.name.lower()]
            if len(parts) > 1:
                candidates.sort(key=lambda t: _catalog_regex_score(parts[1], t), reverse=True)
            return candidates[:MAX_RESULTS]

        regex = _compile_catalog_regex(query)
        scored: list[tuple[int, BaseTool]] = []
        for t in self.tools:
            searchable = f"{t.name} {t.description or ''}"
            if regex.search(searchable):
                # name 命中得分 2，只在 description 命中得分 1 -> name 命中优先
                scored.append((2 if regex.search(t.name) else 1, t))
        scored.sort(key=lambda x: x[0], reverse=True)
        return [t for _, t in scored][:MAX_RESULTS]


def _catalog_regex_score(pattern: str, t: BaseTool) -> int:
    """+required 模式下，按剩余词在 name+description 里的命中次数排序。"""
    regex = _compile_catalog_regex(pattern)
    return len(regex.findall(f"{t.name} {t.description or ''}"))
```

## 2. 闭包式 tool_search 工具

```python
# core/helix/tools/builtins/tool_search.py（tool 部分）
from dataclasses import dataclass
from typing import Annotated

from langchain_core.messages import ToolMessage
from langchain_core.tools import InjectedToolCallId, tool
from langchain_core.utils.function_calling import convert_to_openai_function
from langgraph.types import Command


@dataclass(frozen=True)
class DeferredToolSetup:
    """一次 agent 建图的延迟工具支持结果。三字段作为整体流动，调用方按 tool_search_tool 分支：

    - **空** ``(None, frozenset(), None)``：延迟未启用，或没有 MCP 工具存活于 policy 过滤。无需延迟，照原样绑定。
    - **填充**：``tool_search_tool`` 追加到 agent 工具集，``deferred_names`` 在模型绑定前隐藏直到被提升，``catalog_hash`` 在 graph state 里给 promotion 作用域。

    不变量：``tool_search_tool is None`` ⟺ ``deferred_names`` 为空 ⟺ ``catalog_hash is None``。
    """

    tool_search_tool: BaseTool | None
    deferred_names: frozenset[str]
    catalog_hash: str | None


def build_tool_search_tool(catalog: DeferredToolCatalog) -> BaseTool:
    """构造 tool_search 工具：闭包在一个 catalog 上，提升命中工具到 graph state。

    返回的工具调 Command(update={"promoted": ..., "messages": [ToolMessage]})：
    promoted 由 merge_promoted reducer 按 catalog_hash 作用域并集；
    ToolMessage 把命中工具的完整 schema 还给模型（下一 turn 即可调用）。
    """
    catalog_hash = catalog.hash

    @tool
    def tool_search(query: str, tool_call_id: Annotated[str, InjectedToolCallId]) -> Command:
        """Fetches full schema definitions for deferred tools so they can be called.

        Deferred tools appear by name in <available-deferred-tools> in the system
        prompt. Until fetched, only the name is known. This tool matches a query
        against the deferred tools and returns the matched tools complete schemas;
        once returned, a tool becomes callable.

        Query forms:
          - "select:Read,Edit" -- fetch these exact tools by name
          - "notebook jupyter" -- keyword search, up to max_results best matches
          - "+slack send" -- require "slack" in the name, rank by remaining terms
        """
        matched = catalog.search(query)[:MAX_RESULTS]
        if not matched:
            content, names = f"No tools found matching: {query}", []
        else:
            # 返回完整 openai function schema，模型据此可在下一 turn 调用
            content = json.dumps([convert_to_openai_function(t) for t in matched], indent=2, ensure_ascii=False)
            names = [t.name for t in matched]
        return Command(
            update={
                # promoted 写 graph state，由 merge_promoted 按 catalog_hash 作用域并集去重
                "promoted": {"catalog_hash": catalog_hash, "names": names},
                # ToolMessage 把 schema 还给模型（同一 turn 即可见）
                "messages": [ToolMessage(content=content, tool_call_id=tool_call_id, name="tool_search")],
            }
        )

    return tool_search
```

## 3. 切分装配（build_deferred_tool_setup + assemble_deferred_tools）

```python
# core/helix/tools/builtins/tool_search.py（setup 部分）
from helix.tools.mcp_metadata import is_mcp_tool


def build_deferred_tool_setup(filtered_tools: list[BaseTool], *, enabled: bool) -> DeferredToolSetup:
    """从 POLICY-FILTERED 列表构建延迟工具支持。

    必须在 skill/agent tool-policy 过滤之后调用，确保 catalog 永不暴露当前 agent 不被允许使用的工具。

    两种情况都返回空 setup（见 DeferredToolSetup）：延迟未启用；或启用了但没有 MCP 工具存活于过滤。
    """
    if not enabled:
        # 延迟未启用：什么都不延迟，模型照旧绑定每个工具。
        return DeferredToolSetup(None, frozenset(), None)
    deferred = [t for t in filtered_tools if is_mcp_tool(t)]
    if not deferred:
        # 启用但没有 MCP 工具可延迟：同样空结果，原因不同。
        return DeferredToolSetup(None, frozenset(), None)
    catalog = DeferredToolCatalog(tuple(deferred))
    return DeferredToolSetup(build_tool_search_tool(catalog), catalog.names, catalog.hash)


def assemble_deferred_tools(filtered_tools: list[BaseTool], *, enabled: bool) -> tuple[list[BaseTool], DeferredToolSetup]:
    """从 POLICY-FILTERED 列表构建最终工具列表 + 延迟 setup。

    在 tool-policy 过滤之后调用，catalog 永不暴露 agent 不被允许的工具。fail-closed：
    若 tool_search 启用、MCP 工具存活于过滤、但没有回收到延迟集，抛异常而非裸绑 schema。

    所有 agent-build 路径（lead / 嵌入式 client / subagent）共享，同一处 fail-closed 保证。
    """
    deferred_setup = build_deferred_tool_setup(filtered_tools, enabled=enabled)
    if enabled and not deferred_setup.deferred_names and any(is_mcp_tool(t) for t in filtered_tools):
        raise RuntimeError("tool_search enabled and MCP tools survived policy filtering, "
                           "but no deferred set was recovered - refusing to bind MCP schemas (fail-closed).")
    final_tools = list(filtered_tools)
    if deferred_setup.tool_search_tool:
        final_tools.append(deferred_setup.tool_search_tool)
    return final_tools, deferred_setup
```

## 4. prompt 段渲染（get_deferred_tools_prompt_section）

```python
# core/helix/tools/builtins/tool_search.py（prompt 渲染部分）
def get_deferred_tools_prompt_section(*, deferred_names: frozenset[str] = frozenset()) -> str:
    """从显式的 deferred-name 集合生成 <available-deferred-tools> 段。

    只列 name，让 agent 知道这些工具存在并可以用 tool_search 装载。无延迟工具时返回空串。
    name 集合在 agent 建图期（tool-policy 过滤之后）算出并传入。

    放在这里（紧挨产出 deferred_names 的装配），让每条 agent-build 路径（lead / 嵌入式 client /
    subagent）渲染同一段，而不耦合回 lead_agent.prompt。
    """
    if not deferred_names:
        return ""
    names = "\n".join(sorted(deferred_names))
    return f"<available-deferred-tools>\n{names}\n</available-deferred-tools>"
```

## 5. 运行时 schema 过滤中间件（DeferredToolFilterMiddleware 完整类）

```python
# core/helix/agents/middlewares/deferred_tool_filter_middleware.py
"""中间件：从模型绑定里滤除延迟工具 schema。

tool_search 启用时，MCP 工具仍传给 ToolNode 用于执行路由，但其 schema 绝不能经 bind_tools
发给 LLM，直到模型经 tool_search 发现它们。本中间件在模型绑定前从 request.tools 移除仍延迟的工具，
并阻截对未提升工具的直接调用。

延迟名集合与 catalog hash 在构造期注入（无 ContextVar）。promotion 状态从 graph state
（state["promoted"]）读，按 catalog hash 作用域，防止持久化的旧 promotion 暴露已改名/漂移的工具。
"""

import logging
from collections.abc import Awaitable, Callable
from typing import override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelCallResult, ModelRequest, ModelResponse
from langchain_core.messages import ToolMessage
from langgraph.prebuilt.tool_node import ToolCallRequest
from langgraph.types import Command

logger = logging.getLogger(__name__)


class DeferredToolFilterMiddleware(AgentMiddleware[AgentState]):
    """把延迟工具 schema 对绑定的模型隐藏，直到被提升。

    ToolNode 仍持有全部工具（含延迟工具）用于执行路由，但 LLM 只看到 active schema
    加已提升工具（记录在 state["promoted"] 当前 catalog hash 下）。
    """

    def __init__(self, deferred_names: frozenset[str], catalog_hash: str | None):
        super().__init__()
        self._deferred = deferred_names
        self._catalog_hash = catalog_hash

    def _promoted(self, state) -> set[str]:
        """从 graph state 读已提升工具名，按 catalog_hash 作用域。

        hash 不匹配（catalog 漂移）-> 返回空集，旧 promotion 失效，全部按未提升处理。
        """
        promoted = (state or {}).get("promoted")
        if promoted and promoted.get("catalog_hash") == self._catalog_hash:
            return set(promoted.get("names") or [])
        return set()

    def _hidden(self, state) -> set[str]:
        """当前应隐藏（仍延迟）的工具名 = deferred_names - 已提升。"""
        return set(self._deferred) - self._promoted(state)

    def _filter_tools(self, request: ModelRequest) -> ModelRequest:
        """从 request.tools 滤除仍延迟的工具 schema（不发给模型）。"""
        if not self._deferred:
            return request
        hide = self._hidden(request.state)
        if not hide:
            return request
        active = [t for t in request.tools if getattr(t, "name", None) not in hide]
        if len(active) < len(request.tools):
            logger.debug("Filtered %d deferred tool schema(s) from model binding",
                         len(request.tools) - len(active))
        return request.override(tools=active)

    def _blocked_tool_message(self, request: ToolCallRequest) -> ToolMessage | None:
        """模型绕过提升直接调延迟工具时，返回 error ToolMessage（阻截）。

        模型本应先调 tool_search 拿到 schema 再调用；这里兜底防漏。
        """
        if not self._deferred:
            return None
        name = str(request.tool_call.get("name") or "")
        if not name or name not in self._hidden(request.state):
            return None
        tool_call_id = str(request.tool_call.get("id") or "missing_tool_call_id")
        return ToolMessage(
            content=(f"Error: Tool '{name}' is deferred and has not been promoted yet. "
                     "Call tool_search first to expose and promote this tool's schema, then retry."),
            tool_call_id=tool_call_id,
            name=name,
            status="error",
        )

    @override
    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelCallResult:
        return handler(self._filter_tools(request))

    @override
    def wrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], ToolMessage | Command],
    ) -> ToolMessage | Command:
        blocked = self._blocked_tool_message(request)
        if blocked is not None:
            return blocked
        return handler(request)

    @override
    async def awrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], Awaitable[ModelResponse]],
    ) -> ModelCallResult:
        return await handler(self._filter_tools(request))

    @override
    async def awrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], Awaitable[ToolMessage | Command]],
    ) -> ToolMessage | Command:
        blocked = self._blocked_tool_message(request)
        if blocked is not None:
            return blocked
        return await handler(request)
```

## 6. 三方协作时序（assemble × tool_search × filter）

```
建图期（④，agent 工厂内，per-agent 一次）
  assemble_deferred_tools(filtered, enabled=True)
    ├─ is_mcp_tool(t) 扫描 filtered -> deferred = [MCP 工具]
    ├─ catalog = DeferredToolCatalog(tuple(deferred))  # frozen，@cached_property 算 names/hash
    ├─ tool_search_tool = build_tool_search_tool(catalog)  # 闭包在 catalog 上
    ├─ final_tools = filtered + [tool_search_tool]
    └─ DeferredToolSetup(tool_search_tool, catalog.names, catalog.hash)
         ├─ deferred_names 喂 apply_prompt_template -> <available-deferred-tools>
         └─ deferred_names + catalog_hash 喂 DeferredToolFilterMiddleware(__init__)

执行期（⑥，模型循环内，每 turn）
  ┌─ DeferredToolFilterMiddleware.wrap_model_call
  │    hide = deferred_names - state["promoted"][catalog_hash].names
  │    request.tools = [t for t if t.name not in hide]  # schema 不发给模型
  │    -> handler -> 模型只看到 immediate + 已提升工具 schema
  ├─ 模型看到 <available-deferred-tools>name 列表，决定需要哪个
  ├─ 模型调 tool_search("select:Read,Edit")
  │    catalog.search -> matched = [tool, tool]
  │    Command(update={
  │      "promoted": {"catalog_hash": ..., "names": ["Read", "Edit"]},
  │      "messages": [ToolMessage(完整 openai function schema)]
  │    })
  ├─ merge_promoted reducer（按 catalog_hash 作用域并集去重，见 [[thread-state-and-reducers]]）
  └─ 下一 turn wrap_model_call：state["promoted"] 已含 Read/Edit -> hide 集合变小 -> schema 放行

阻截路径（模型绕过 tool_search 直接调延迟工具）
  ┌─ DeferredToolFilterMiddleware.wrap_tool_call
  ├─ _blocked_tool_message: name in _hidden(state) -> 返回 error ToolMessage
  └─ 模型收到 "Tool 'X' is deferred ... Call tool_search first" -> 下一 turn 先 search

漂移路径（MCP server 改了工具名）
  ┌─ 下次建图：catalog.hash 变（name+schema 变了）
  ├─ DeferredToolFilterMiddleware 用新 hash 构造
  ├─ 旧 state["promoted"] 的 catalog_hash 不匹配 -> _promoted 返回空集
  └─ 旧 promotion 失效，模型需重新 tool_search（不会调到已删工具）
```
