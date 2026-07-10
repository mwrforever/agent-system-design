---
name: tool-assembly-and-policy
description: 设计 agent 工具装配流水线--config 反射 + builtin + MCP + subagent + ACP 五源聚集，叠加 tool_groups 分组、host-bash 门、视觉门等能力策略，再经 skill allowed-tools 白名单收缩（并集非交集），最后由 deferred + tool_search 把 MCP 工具拆为"命名可见 / schema 延迟"。完整覆盖 get_available_tools 装配主体、assemble_deferred_tools 切分、filter_tools_by_skill_allowed_tools 白名单、DeferredToolFilterMiddleware 运行时 schema 过滤、catalog_hash promotion 作用域。当你要装配工具集、做最小权限收缩、排查"工具名不一致 / 重复名 / 模型调到不存在的工具 / MCP 工具塞爆上下文"，或定位延迟工具提升丢失时调用本 skill。
---

## 何时用

- 你要把多源工具（config 反射 / builtin / MCP / subagent / ACP）聚集成一份绑定到模型的 `BaseTool` 列表
- 工具数量爆炸（MCP 接 N 个 server 后总 schema 几百个，塞爆上下文窗）-> 需要 deferred + `tool_search` 按需 promote
- 不同 agent / 不同用户应看到不同工具集（`tool_groups` 分组 / skill `allowed-tools` 白名单 / 视觉模型门 / host-bash 门）
- 排查"工具名不一致（#1803）""重复名""模型调到不存在的工具""延迟工具提升丢失""白名单取交集导致没工具可用""catalog 漂移后 promotion 指向已删工具"
- 在端到端链路中定位工具装配的落点（④建图 时装配，⑥执行 时调用）

## 设计方案（为什么这么设计）

### 核心矛盾：来源杂 × 上下文窗有限 × 最小权限

工具来源天然碎片化：config.yaml 反射加载的沙箱/社区工具、始终在场的 builtin、远端 MCP server 聚合工具、子代理委派的 `task`、外部 ACP 代理。一个生产 agent 接入 5 个 MCP server 后，工具 schema 可能膨胀到几百个，全绑到模型上会同时引发三个问题：(a) 上下文窗被工具 schema 占满、挤压用户历史；(b) 模型在过多 schema 里选错的概率上升；(c) prompt token 成本随 schema 数量线性上涨。同时安全侧要求最小权限--不同 skill、不同 agent、不同通道看到的工具集应该不同。

**解法：装配流水线 = 来源聚集 + 能力策略过滤 + 白名单收缩 + deferred 切分四阶段。** 每阶段独立可控，顺序固定（顺序错会引发真实 bug，见反模式段）。

### 五源聚集（get_available_tools）

| 来源 | 装载方式 | 谁控制 |
|---|---|---|
| **config-defined** | `resolve_variable(cfg.use, BaseTool)` 反射加载 `config.yaml -> tools[*].use` | 运维配 config.yaml |
| **builtin** | `BUILTIN_TOOLS` 常量（`present_files` + `ask_clarification`）+ 条件追加（`view_image` / `skill_manage` / `task`） | 框架代码 |
| **MCP** | `get_cached_mcp_tools()`（lazy + mtime 失效缓存） | `extensions_config.json -> mcpServers` |
| **subagent** | `subagent_enabled=True` 时追加 `task_tool` | 运行时 `configurable` |
| **ACP** | `acp_agents` 非空时构造 `invoke_acp_agent` | `config.yaml -> acp_agents` |

聚集后按 name 去重，优先级 config > builtin > MCP > ACP--重复 name 会让 LLM 收到歧义/拼接的 function schema（issue #1803 根因）。

```python
# 伪代码：五源聚集 + 能力门 + 去重（完整源码见 references/code/tool-assembly.md §1）
def get_available_tools(groups, model_name, subagent_enabled, app_config):
    config = app_config or get_app_config()
    tool_configs = [t for t in config.tools if groups is None or t.group in groups]
    if not is_host_bash_allowed(config):              # host-bash 门
        tool_configs = [t for t in tool_configs if not _is_host_bash_tool(t)]
    loaded = [resolve_variable(cfg.use, BaseTool) for cfg in tool_configs]  # ① config 反射
    builtin = BUILTIN_TOOLS.copy()                    # ② builtin 最小集
    if skill_evolution.enabled: builtin.append(skill_manage_tool)
    if subagent_enabled: builtin.extend(SUBAGENT_TOOLS)   # subagent 门
    if model_config.supports_vision: builtin.append(view_image_tool)  # 视觉门
    mcp = [tag_mcp_tool(t) for t in get_cached_mcp_tools()] if include_mcp else []  # ③ MCP
    acp = [build_invoke_acp_agent_tool(acp_agents)] if acp_agents else []  # ④ ACP
    return dedup_by_name(loaded + builtin + mcp + acp)  # config > builtin > MCP > ACP
```

### 能力策略过滤（装配内联）

工具不是全部无条件暴露，装配时按能力门逐道过滤：

- **`tool_groups` 分组**：agent 配置可声明 `tool_groups`（如 `["web", "file:read"]`），装配时 `groups` 参数过滤 `config.tools[*].group`，只装载这些组。agent 级声明式工具集收缩。
- **host-bash 门**：`is_host_bash_allowed(config)` 为否（`LocalSandboxProvider` 默认）时，剔除 `group == "bash"` 或 `use == "helix.sandbox.tools:bash_tool"` 的描述符--避免本地模式下把宿主 shell 暴露给模型。
- **视觉门**：仅当 `model_config.supports_vision` 为真时追加 `view_image_tool`。写在装配末尾，避免模型不支持时 schema 仍然出现。
- **subagent 门**：`subagent_enabled=False` 时 `task` 工具根本不进 builtin 列表--子代理不传 `task`，防无限嵌套委派。

### skill allowed-tools 白名单：并集而非交集（向后兼容的最小权限）

启用的 skill 可在 `SKILL.md` frontmatter 声明 `allowed-tools`（允许调用的工具名白名单）。装配后用 `filter_tools_by_skill_allowed_tools` 收缩：

- **取并集**：多 skill 启用时，把所有声明取并集（不是交集）--否则两个 skill 各自的限制叠加后几乎没工具可用。
- **None 不收缩**：任一 skill 声明了 `allowed-tools` 才激活收缩；全为 `None` 时维持 legacy allow-all。已声明白名单的 skill + 未声明的 legacy skill 共存时，legacy 不贡献工具但也不禁用他人的显式限制。
- **框架常驻工具**：`SKILL_LOADING_TOOL_NAMES = frozenset({"read_file"})` 永远放行--否则 skill 激活后连 `read_file`（加载 SKILL.md 正文必备）都不可用，自相矛盾。

```python
# 伪代码：白名单收缩（并集 + 框架常驻；完整源码见 references/code/policy-and-whitelist.md §6）
def filter_tools_by_skill_allowed_tools(tools, skills, *, always_allowed=SKILL_LOADING_TOOL_NAMES):
    allowed = allowed_tool_names_for_skills(skills)  # 并集；全 None -> None
    if allowed is None: return tools                 # legacy allow-all，不收缩
    return [t for t in tools if t.name in (allowed | always_allowed)]
```

### deferred + tool_search：为什么延迟

MCP 工具 schema 大（一个 server 几十个工具，每个 schema 几百 token），全塞进上下文窗 -> (a) 挤压用户历史；(b) 模型注意力分散、调错工具；(c) prompt 成本暴涨。**解法：装配时把 MCP 工具拆出，只把"名字"列在 system prompt，schema 不绑定模型；模型需要时调 `tool_search(query)` 搜索，返回完整 schema 并写 `state.promoted`，下一 turn 过滤中间件放行该工具。**

- **建图期**（④）：`assemble_deferred_tools(filtered, enabled)` 从 policy 过滤后的列表里挑出 MCP 工具（靠 `helix_mcp` metadata tag 识别），构造不可变 `DeferredToolCatalog`，返回 `DeferredToolSetup(tool_search_tool, deferred_names, catalog_hash)`；`tool_search_tool` 追加到 agent 工具集，`deferred_names` 同时喂给 system prompt（渲染 `<available-deferred-tools>`）和 `DeferredToolFilterMiddleware`（运行时 schema 过滤），二者用同一 `catalog_hash` 校对。
- **运行时**（⑥）：模型调 `tool_search("select:Read,Edit" | "+slack send" | "notebook jupyter")`，catalog 按 select 精确取 / `+required` 必含词 / 关键词正则三种语法搜索，返回最多 5 个匹配工具的完整 schema，同时 `Command(update={"promoted": {...}, "messages": [ToolMessage]})` 写回 graph state。
- **每 model call**（⑤中间件链第 22 项）：`DeferredToolFilterMiddleware` 读 `state["promoted"]`，按 `catalog_hash` 作用域取出已提升名集，把"仍延迟"的工具从 `request.tools` 滤除（schema 不发给模型），并拦阻模型对未提升延迟工具的直接调用（返回 error ToolMessage）。ToolNode 仍持有全部工具用于执行路由。

```python
# 伪代码：deferred 切分（fail-closed，必须在白名单之后；完整源码见 references/code/deferred-and-tool-search.md §3）
def assemble_deferred_tools(filtered, *, enabled):
    if not enabled: return filtered, DeferredToolSetup(None, frozenset(), None)
    deferred = [t for t in filtered if is_mcp_tool(t)]
    if not deferred: return filtered, DeferredToolSetup(None, frozenset(), None)
    catalog = DeferredToolCatalog(tuple(deferred))
    setup = DeferredToolSetup(build_tool_search_tool(catalog), catalog.names, catalog.hash)
    if enabled and not setup.deferred_names and any(is_mcp_tool(t) for t in filtered):
        raise RuntimeError("fail-closed: MCP survived policy but no deferred set recovered")
    return filtered + [setup.tool_search_tool], setup
```

**fail-closed**：`tool_search.enabled` 且 MCP 工具存活于过滤后列表、但没回收到 deferred 集（实现 bug），抛 `RuntimeError` 而非裸绑 schema--宁可硬错也不让模型看到本该延迟的全量 schema。

### catalog_hash：promotion 作用域（防漂移）

MCP server 改了工具名/签名后，checkpoint 里持久化的旧 promotion 不能指向已删除/已漂移的工具。`DeferredToolCatalog.hash` 由工具 name + schema 的规范 JSON 的 sha256 前 16 位组成。`merge_promoted` reducer（见 [[thread-state-and-reducers]]）按 hash 作用域：hash 变了 wholesale replace（丢弃旧 names），hash 相同则并集去重。`DeferredToolFilterMiddleware` 也只认当前 `catalog_hash` 匹配的 promotion，hash 不匹配一律按"未提升"处理。

```python
# 伪代码：运行时 schema 过滤核心（完整源码见 references/code/deferred-and-tool-search.md §5）
def _promoted(self, state):
    p = (state or {}).get("promoted")
    return set(p["names"]) if p and p["catalog_hash"] == self._catalog_hash else set()  # 漂移->空集

def _filter_tools(self, request):       # wrap_model_call：隐藏仍延迟的 schema
    hide = self._deferred - self._promoted(request.state)
    return request.override(tools=[t for t in request.tools if t.name not in hide])

def _blocked_tool_message(self, request):  # wrap_tool_call：阻截未提升直接调用
    if request.tool_call["name"] in self._hidden(request.state):
        return ToolMessage(content="Error: deferred, call tool_search first", status="error")
```

### 在端到端链路中的位置

本 skill 处于端到端链路的 **④建图**（装配）与 **⑥执行**（调用）两跳（见 [[e2e-request-lifecycle]]）：

- **④建图** `make_lead_agent`（见 [[agent-graph-factory]]）调 `get_available_tools(...)` 聚集 -> `filter_tools_by_skill_allowed_tools(...)` 白名单 -> `non_interactive` 剥离 `ask_clarification`（跨切不变量 1）-> `assemble_deferred_tools(...)` 切分 -> `create_agent(tools=final_tools, middleware=[..., DeferredToolFilterMiddleware, ...])` 一次绑定。
- **⑥执行** 模型循环驱动工具调用：沙箱工具（bash/read_file/write_file/str_replace，见 [[sandbox-tools-and-safety]]）/ `task()` 委派（见 [[subagent-delegation]]）/ MCP 工具（经 `tool_search` 提升后，见 [[mcp-integration]]）/ skill 工具。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/tools/tools.py` | `get_available_tools` 装配主入口 + `BUILTIN_TOOLS` / `SUBAGENT_TOOLS` + `_ensure_sync_invocable_tool` + `_is_host_bash_tool` + 四源聚集 + 去重 | [tool-assembly.md](./references/code/tool-assembly.md) §1 |
| `core/helix/reflection/resolvers.py` | `resolve_variable(path, expected_type)` 反射加载（含 install hint） | [tool-assembly.md](./references/code/tool-assembly.md) §2 |
| `core/helix/tools/sync.py` | `make_sync_tool_wrapper`（async-only 工具 sync 包装） | [tool-assembly.md](./references/code/tool-assembly.md) §3 |
| `core/helix/tools/mcp_metadata.py` | `MCP_TOOL_METADATA_KEY` + `tag_mcp_tool` / `is_mcp_tool` | [tool-assembly.md](./references/code/tool-assembly.md) §4 |
| `core/helix/mcp/cache.py` | MCP lazy + mtime 失效缓存 `get_cached_mcp_tools` | [tool-assembly.md](./references/code/tool-assembly.md) §5 |
| `core/helix/tools/builtins/invoke_acp_agent_tool.py` | `build_invoke_acp_agent_tool` ACP 构造器 | [tool-assembly.md](./references/code/tool-assembly.md) §6 |
| `core/helix/tools/builtins/__init__.py` | builtin 工具导出清单 | [tool-assembly.md](./references/code/tool-assembly.md) §7 |
| `core/helix/tools/builtins/tool_search.py` | `DeferredToolCatalog` + `build_tool_search_tool` + `assemble_deferred_tools` + `get_deferred_tools_prompt_section` | [deferred-and-tool-search.md](./references/code/deferred-and-tool-search.md) §1-§4 |
| `core/helix/agents/middlewares/deferred_tool_filter_middleware.py` | `DeferredToolFilterMiddleware`：运行时 schema 过滤 + 阻截 | [deferred-and-tool-search.md](./references/code/deferred-and-tool-search.md) §5 |
| `core/helix/skills/tool_policy.py` | `filter_tools_by_skill_allowed_tools` + `allowed_tool_names_for_skills`（并集）+ `SKILL_LOADING_TOOL_NAMES` | [policy-and-whitelist.md](./references/code/policy-and-whitelist.md) §6 |
| `core/helix/agents/thread_state.py` | `PromotedTools` TypedDict + `merge_promoted` reducer（catalog_hash 作用域） | [policy-and-whitelist.md](./references/code/policy-and-whitelist.md) §1 |
| `core/helix/config/tool_search_config.py` | `ToolSearchConfig(enabled)` 开关 | [policy-and-whitelist.md](./references/code/policy-and-whitelist.md) §2 |
| `core/helix/config/tool_config.py` | `ToolConfig` / `ToolGroupConfig` schema | [policy-and-whitelist.md](./references/code/policy-and-whitelist.md) §3 |

### 装配时序（一次 run 的装配 -> 执行）

```
make_lead_agent(config)  # ④建图（见 [[agent-graph-factory]]）
  ├─ raw_tools = get_available_tools(groups, model_name, subagent_enabled, app_config)
  │     ├─ ① config 反射加载（按 groups 过滤；host-bash 门）
  │     ├─ ② builtin（present_files + ask_clarification；+view_image 视觉门；+task subagent 门）
  │     ├─ ③ MCP（get_cached_mcp_tools + tag_mcp_tool）
  │     ├─ ④ ACP（acp_agents 非空时构造）
  │     └─ 按 name 去重（config > builtin > MCP > ACP）
  ├─ filtered = filter_tools_by_skill_allowed_tools(raw_tools, skills, always_allowed=SKILL_LOADING_TOOL_NAMES)
  ├─ if non_interactive: filtered = [t for t in filtered if t.name != "ask_clarification"]  # 跨切不变量 1
  ├─ final_tools, deferred_setup = assemble_deferred_tools(filtered, enabled=app_config.tool_search.enabled)
  │     ├─ MCP 工具（is_mcp_tool tag）-> DeferredToolCatalog -> build_tool_search_tool
  │     └─ deferred_setup = (tool_search_tool, deferred_names, catalog_hash)
  ├─ create_agent(tools=final_tools,
  │                middleware=[..., DeferredToolFilterMiddleware(deferred_names, catalog_hash), ...],
  │                system_prompt=apply_prompt_template(deferred_names=deferred_setup.deferred_names, ...))
  └─ agent.astream(...)  # ⑥执行
        ├─ 模型看到 immediate 工具 schema + <available-deferred-tools>name 列表（无 schema）
        ├─ 模型调 tool_search("select:Read,Edit") -> catalog.search -> ToolMessage(完整 schema)
        │     + Command(update={"promoted": {"catalog_hash": ..., "names": [...]}})
        ├─ merge_promoted reducer 按 catalog_hash 作用域并集去重（见 [[thread-state-and-reducers]]）
        ├─ 下一 model call：DeferredToolFilterMiddleware 读 state["promoted"]，放行已提升工具 schema
        └─ 未提升的直接调会被 _blocked_tool_message 阻截
```

### 模块索引

- [references/code/tool-assembly.md](./references/code/tool-assembly.md) -- 装配主入口 `get_available_tools`（§1）+ 配套：`resolve_variable` 反射 + install hint（§2）、`make_sync_tool_wrapper` async->sync 包装（§3）、`tag_mcp_tool` / `is_mcp_tool` MCP 来源单一真值标记（§4）、MCP lazy/mtime 缓存（§5）、`build_invoke_acp_agent_tool` ACP 构造（§6）、builtin 工具导出清单（§7）、tools 包懒导出（§8）
- [references/code/deferred-and-tool-search.md](./references/code/deferred-and-tool-search.md) -- `DeferredToolCatalog` 不可变索引 + select / `+required` / 关键词正则三语法 search + sha256 hash（§1）、`build_tool_search_tool` 闭包式 tool_search（§2）、`assemble_deferred_tools` 切分 fail-closed（§3）、`get_deferred_tools_prompt_section` 渲染（§4）、`DeferredToolFilterMiddleware` 完整类含 async 变体（§5）、三方协作时序（§6）
- [references/code/policy-and-whitelist.md](./references/code/policy-and-whitelist.md) -- `merge_promoted` reducer catalog_hash 作用域（§1）、`ToolSearchConfig` 开关（§2）、`ToolConfig` / `ToolGroupConfig` schema（§3）、config.yaml `tools` / `tool_groups` 示例（§4）、skill `allowed-tools` frontmatter 形态（§5）、`filter_tools_by_skill_allowed_tools` 白名单收缩完整实现（§6）、filter -> assemble 顺序约束 + 子代理路径（§7）

## 反模式与陷阱

- ❌ **`assemble_deferred_tools` 在 `filter_tools_by_skill_allowed_tools` 之前调用** -> 被策略禁掉的工具进了 deferred catalog，模型 `tool_search` 能 promote 它们、prompt 提示了但运行时白名单不允许。修复：永远 `filter -> assemble`，顺序不可逆。
- ❌ **allowed-tools 取交集而非并集** -> 两个 skill 各自的限制叠加后几乎没工具可用，agent 直接瘫。修复：`allowed_tool_names_for_skills` 显式取并集；`None` 声明不参与收缩（向后兼容 legacy）。
- ❌ **catalog_hash 缺失或不用它做 promotion 作用域** -> MCP server 改了工具名后，checkpoint 里旧 promotion 仍指向已删除/已漂移的工具，`DeferredToolFilterMiddleware` 放行一个不存在的 schema。修复：catalog hash 由 name+schema 规范 JSON 的 sha256 算出；`merge_promoted` 与 `_promoted` 都按 hash 作用域，hash 变了 wholesale replace。
- ❌ **`DeferredToolFilterMiddleware` 只 hook `wrap_model_call` 不 hook `wrap_tool_call`** -> 模型可能绕过 `tool_search` 直接调用延迟工具（schema 已在 prompt name 列表），ToolNode 仍持有该工具会照常执行。修复：同时 hook `wrap_tool_call`，未提升的直接调返回 error ToolMessage 阻截。
- ❌ **`deferred_setup` 只喂 `build_middlewares` 不喂 `apply_prompt_template`**（或反之）-> prompt 提示的延迟工具名与运行时过滤器持有的 `deferred_names` 集合不一致，模型反复尝试不存在的工具。修复：二者用同一 `setup.deferred_names` / `catalog_hash`（[[agent-graph-factory]] 的不变量）。
- ❌ **MCP 来源用 name 前缀（如 `mcp__`）或目录路径推断** -> MCP server 重命名工具后前缀规则失效，漏 tag -> 该延迟的工具被当成 immediate 全 schema 绑定。修复：`tag_mcp_tool` 写 `metadata["helix_mcp"] = True`，单一真值标记，`is_mcp_tool` 只认这个 key。
- ❌ **去重顺序反了（MCP 优先于 config）** -> 同名时 config 工具被 MCP 覆盖，运维改 config.yaml 不生效。修复：`loaded_tools + builtin_tools + mcp_tools + acp_tools` 顺序，先入 wins。
- ❌ **tool_search 的 query 直接喂正则不兜底** -> 模型吐一个不平衡括号的正则，`re.compile` 抛异常，工具调用失败。修复：`_compile_catalog_regex` try/except 回退到字面子串匹配。
- ❌ **`fail-closed` 被改成 warn-and-continue** -> 装配 bug 时模型看到本该延迟的全量 MCP schema，静默违背 deferred 契约。修复：`assemble_deferred_tools` 检测到"启用 + MCP 存活 + 无 deferred 集"抛 `RuntimeError`。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 默认 | 来源 | 说明 |
|---|---|---|---|
| `tool_search.enabled` | `false` | `config.yaml -> tool_search` | 开启后 MCP 工具延迟，模型按需 `tool_search` promote |
| `tools[*].group` | 必填 | `config.yaml -> tools` | 配合 agent `tool_groups` 分组收缩 |
| `tool_groups[*].name` | - | `config.yaml -> tool_groups` | 声明可用组 |
| agent `tool_groups` | `None`（全部） | agent `config.yaml` | 自定义 agent 收缩到这些组 |
| `skill.allowed-tools` | `None`（allow-all） | `SKILL.md` frontmatter | 白名单收缩（取并集） |
| `subagent_enabled` | `false` | runtime `configurable` | 追加 `task` 工具 |
| `model_config.supports_vision` | 模型决定 | `config.yaml -> models[*]` | 追加 `view_image_tool` |
| `is_host_bash_allowed(config)` | 本地 Provider 下 false | sandbox 配置 | host-bash 门 |
| `skill_evolution.enabled` | false | `config.yaml` | 追加 `skill_manage_tool` |

**关键日志串**（排障时 grep）

- `Total tools loaded: X, built-in tools: Y, MCP tools: Z, ACP tools: W` - 装配汇总
- `Tool name mismatch: config name 'X' does not match tool .name 'Y'` - #1803 根因告警
- `Duplicate tool name 'X' detected and skipped` - 重复名（config 与 MCP 撞名常见）
- `Using N cached MCP tool(s)` / `MCP tools not initialized, performing lazy initialization...` - MCP 缓存路径
- `MCP config file has been modified (mtime: X -> Y), cache is stale` - Gateway API 改了 extensions_config.json，下次装配自动失效
- `Including view_image_tool for model 'X' (supports_vision=True)` - 视觉门生效
- `Filtered N deferred tool schema(s) from model binding` - DeferredToolFilterMiddleware 在工作（debug 级）
- `tool_search enabled and MCP tools survived policy filtering, but no deferred set was recovered` - fail-closed 抛错

**自测方向**

- **五源装配确定性**：相同 config + 相同 model_name + 相同 subagent_enabled，5 次 `get_available_tools` 返回工具集按 name 排序字节级相等。
- **tool_groups 收缩**：agent `tool_groups=["web"]` -> 只含 `group == "web"` 的 config 工具 + builtin（builtin 不受 groups 过滤）。
- **host-bash 门**：本地 Provider 下 `is_host_bash_allowed=false` -> `bash` 不在工具集；远程 Provider 下在。
- **视觉门**：`model_config.supports_vision=True` -> 含 `view_image`；`False` -> 不含。
- **去重**：config 与 MCP 同名工具 -> config wins，告警 `Duplicate tool name ... skipped`。
- **白名单并集**：两 skill 各声明 `["a","b"]` / `["b","c"]` -> 最终允许 `{"a","b","c"}` ∪ `SKILL_LOADING_TOOL_NAMES`。
- **白名单 None 不收缩**：全部 skill `allowed_tools=None` -> 工具集不变；一个声明 + 一个 None -> 按声明的并集收缩。
- **deferred 切分顺序**：先 filter 后 assemble；assemble 后 immediate 不含 MCP 工具、含 `tool_search`。
- **fail-closed**：mock `build_deferred_tool_setup` 返回空 deferred_names 但 `is_mcp_tool(t)` 为真 -> `assemble_deferred_tools` 抛 `RuntimeError`。
- **catalog_hash 漂移**：promote 后改 catalog（增删 MCP 工具）-> `merge_promoted` wholesale replace，旧 names 失效；`DeferredToolFilterMiddleware` hash 不匹配 -> `_promoted` 返回空集。
- **阻截未提升调用**：模型直接调延迟工具名 -> `wrap_tool_call` 返回 error ToolMessage；先 `tool_search` 提升后 -> 正常执行。
- **prompt 与运行时一致性**：`deferred_setup.deferred_names` == system prompt `<available-deferred-tools>` 列表 == `DeferredToolFilterMiddleware._deferred` 集合。
- **tool_search query 兜底**：query=`"("`（非法正则）-> 回退字面子串匹配，不抛 `re.error`。

## 进一步阅读

- 装配主体与配套源码：[references/code/tool-assembly.md](./references/code/tool-assembly.md)
- deferred 与 tool_search 完整源码：[references/code/deferred-and-tool-search.md](./references/code/deferred-and-tool-search.md)
- 白名单 + reducer + config schema 完整源码：[references/code/policy-and-whitelist.md](./references/code/policy-and-whitelist.md)
- 关联 skill：[[e2e-request-lifecycle]]（④建图装配 / ⑥执行调用 在链路中的位置）、[[agent-graph-factory]]（`make_lead_agent` 调用点 + deferred_setup 双通道一致性）、[[mcp-integration]]（MCP 多 server / lazy 缓存 / stdio/SSE/HTTP 传输）、[[subagent-delegation]]（`task` 工具 + 子代理延迟装配）、[[skill-system-design]]（skill `allowed-tools` frontmatter / 技能发现）、[[thread-state-and-reducers]]（`merge_promoted` reducer + `PromotedTools` 通道）、[[middleware-chain-design]]（`DeferredToolFilterMiddleware` 链上位置第 22 项）、[[sandbox-tools-and-safety]]（bash/read_file/write_file/str_replace 沙箱工具）
