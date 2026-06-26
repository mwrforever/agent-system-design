# tool-assembly-and-policy · implementation-notes

工具装配层把 **配置驱动的工具描述符**、**内建工具**、**MCP 远端工具**、**ACP 外部代理工具**、**子代理委托工具** 五条来源合成为一份用于绑定到模型的 `BaseTool` 列表，再叠加 **能力策略过滤**（视觉/子代理/Host-Bash 等开关）和 **延迟披露**（deferred-tool / `tool_search` 提升机制）。本文记录复刻这套装配逻辑时容易翻车的细节。

## 一、组件矩阵

| 组件 | 角色 | 关键关注点 |
|---|---|---|
| `BuiltinTools` 常量 | 始终装载的最小集（present_file、ask_clarification） | 任何 agent 都应得到这两个；ask_clarification 由中间件拦截转 `Command(goto=END)` |
| `SubagentTools` 常量 | 仅在 `subagent_enabled=True` 时追加的 `task` 工具 | 暴露给 LLM 的只有派发器，状态轮询走后端 |
| `get_available_tools(...)` | 装配主入口（同步函数） | 输入 `groups / include_mcp / model_name / subagent_enabled`，输出按 name 去重的 `BaseTool` 列表 |
| `resolve_variable(use_path, BaseTool)` | 反射加载 `config.tools[*].use` | 失败要给出可执行的 install 提示，而不是裸 `ImportError` |
| `tag_mcp_tool / is_mcp_tool` | MCP 来源单一真值标记 | 用 `tool.metadata["<mcp_flag>"] = True`，禁止用 name 前缀或目录路径推断 |
| `DeferredToolCatalog` | 不可变的延迟工具索引（dataclass frozen） | `@cached_property` 提供 `names` / `hash` / `search`；hash 用作 promotion 作用域 |
| `build_tool_search_tool(catalog)` | 闭包式 `tool_search` 工具 | 返回 `Command(update={"promoted": {...}, "messages": [...]})` 写回 graph state |
| `assemble_deferred_tools(filtered, enabled)` | 装配延迟集合 + 在尾部追加 `tool_search` | Fail-closed：开关开启且仍有 MCP 工具但没回收到延迟集，则抛 `RuntimeError` 而不是裸绑 schema |
| `_ensure_sync_invocable_tool` | 给 async-only 工具补 `.func` 同步包装 | sync caller（如某些 agent 路径）才能 invoke async 工具 |
| Host-Bash 策略 (`is_host_bash_allowed`) | 在本地 Provider 上默认剔除 `bash` 工具 | 通过 `group=="bash"` 或 `use=="<harness-pkg>/sandbox/tools:bash_tool"` 双重识别 |
| 视觉策略 | 仅在 `model_config.supports_vision` 为真时追加 `view_image_tool` | 写在装配末尾，避免模型不支持时仍然出现在 schema |
| ACP 装配 | 当 `acp_agents` 非空，追加 `invoke_acp_agent` | 失败只 warn，不应阻塞其他工具 |

## 二、关键调用时序

```text
build_agent(config, model_name, subagent_enabled)
  ├─ get_available_tools(groups, include_mcp, model_name, subagent_enabled)
  │    ├─ 取 AppConfig；按 groups 过滤 tool_configs
  │    ├─ if not is_host_bash_allowed(config): 过滤掉 host-bash 描述符
  │    ├─ for cfg in tool_configs:
  │    │      loaded = resolve_variable(cfg.use, BaseTool)
  │    │      if cfg.name != loaded.name: 记 warn（schema/router 名不一致是常见 bug 源）
  │    ├─ builtin_tools = [BuiltinTools] + ([SubagentTools] if subagent_enabled)
  │    ├─ if vision: builtin_tools.append(view_image_tool)
  │    ├─ if include_mcp and 有启用的 MCP server:
  │    │      mcp_tools = get_cached_mcp_tools()        # 由 mcp 子系统 lazy 缓存
  │    │      for t in mcp_tools: tag_mcp_tool(t)       # 单一真值标记
  │    ├─ 装配 ACP 工具（失败仅 warn）
  │    └─ 合并 + 按 name 去重（loaded > builtin > mcp > acp）
  ├─ filtered = apply_skill_or_agent_policy(all_tools)   # 视外层 policy 而定
  └─ final, deferred_setup = assemble_deferred_tools(filtered, enabled=cfg.tool_search.enabled)
        ├─ build_deferred_tool_setup(filtered, enabled)
        │      deferred = [t for t in filtered if is_mcp_tool(t)]
        │      if not deferred: 返回 EMPTY setup
        │      catalog = DeferredToolCatalog(tuple(deferred))
        │      tool_search = build_tool_search_tool(catalog)   # 闭包持有 catalog.hash
        └─ fail-closed: enabled && 仍有 MCP 且 deferred 集为空 → RuntimeError
```

运行期工具调用时序（延迟提升的视角）：

```text
LLM round N      → 模型仅看到 deferred 集合的"名字 + 一句话"
LLM round N+1    → 模型决定调用 tool_search(query="select:foo,bar")
DeferredToolFilterMiddleware.before_model
                 → 读取 state.promoted，按 catalog_hash 校验后允许 foo/bar 的 schema 暴露
LLM round N+2    → 真正用完整 schema 调用 foo/bar
```

### catalog_hash 失效机制

```text
配置变更 (例如新增/移除一个 MCP server)
  → 下次 build_lead_agent 触发 get_available_tools()
  → mcp_tools 列表变动
  → assemble_deferred_tools 重建 DeferredToolCatalog
  → 新的 catalog.hash ≠ 老的 catalog_hash
  → DeferredToolFilterMiddleware 比对 state.promoted.catalog_hash 时整组失效
  → 模型必须重新走 tool_search 才能再次拿到 schema
```

### 子代理装配复用

子代理在 `subagents/executor.py::_aexecute` 里也会走相同的装配链：

```text
_build_initial_state(prompt, ...)
  ├─ filtered_tools = 经 subagent 类型策略过滤
  ├─ final_tools, deferred_setup = assemble_deferred_tools(filtered, enabled=cfg.tool_search.enabled)
  ├─ 把 <available-deferred-tools> 段塞进子代理的 SystemMessage
  └─ build_subagent_runtime_middlewares(deferred_setup=...)
        在子代理 graph 中追加 DeferredToolFilterMiddleware（hash 与子代理自有 catalog 对齐）
```
每次 `task` 派发都得到全新 ThreadState，所以子代理之间 `promoted` 完全隔离，不会互相借用 schema。

## 三、数据契约

### `DeferredToolCatalog`（frozen dataclass）
| 字段 | 类型 | 含义 |
|---|---|---|
| `tools` | `tuple[BaseTool, ...]` | 通过策略过滤后的延迟工具元组（顺序无关，hash 内部排序） |
| `names`（cached） | `frozenset[str]` | 渲染 `<available-deferred-tools>` 用 |
| `hash`（cached） | `str` (前 16 位 sha256) | promotion 作用域；catalog 变了 → 旧 promotion 无效 |
| `search(query)` | `list[BaseTool]` ≤ MAX_RESULTS | 支持 `select:` / `+required` / 纯关键字三种语法 |

`search()` 三种语法：

- `select:foo,bar` — 精确选取一组工具，按名字命中，**不** 走打分
- `+slack send` — 必须命中 `slack`，再按 `send` 的正则匹配数排序
- `notebook jupyter` — 模糊正则匹配 name + description；name 中命中 +2，description 中命中 +1
- 空字符串 / 仅空白 → 返回 `[]`

### `DeferredToolSetup`（frozen dataclass）
| 字段 | 类型 | 不变量 |
|---|---|---|
| `tool_search_tool` | `BaseTool | None` | 三字段同步：None ⟺ deferred_names 为空 ⟺ catalog_hash 为 None |
| `deferred_names` | `frozenset[str]` | 不能与未延迟工具名重叠 |
| `catalog_hash` | `str | None` | 必须由 `DeferredToolCatalog.hash` 提供 |

### `tool_search` 返回的 `Command`
```python
Command(update={
    "promoted": {"catalog_hash": "<hex16>", "names": [...]},
    "messages": [ToolMessage(content="<json schemas>", tool_call_id=..., name="tool_search")]
})
```
- `update.promoted` 由 reducer 合并到 `ThreadState.promoted`
- `messages` 必须把 schema JSON 作为 `ToolMessage.content` 返回；模型据此构造下一轮 tool_call
- 未命中时仍返回 `Command`（content 是 `No tools found matching: <query>`，`names=[]`），不能 raise

### `tool_metadata` 标记
| 键 | 写入点 | 读取点 |
|---|---|---|
| `<mcp_flag>` (常量 `MCP_TOOL_METADATA_KEY`) | MCP tools 加载循环 | `is_mcp_tool()` → 延迟装配 |

### 反射加载契约
- `resolve_variable(use, BaseTool)`：模块路径 `module.path:variable_name`；若变量不是 `BaseTool` 实例必须 raise 而不是返回 None
- `resolve_class(use, AgentMiddleware)`：装配自定义中间件时用同一族函数；缺包时给出 `uv add <pkg>` 的提示

## 四、不变量

1. **同名去重幂等**：合并后 `len(unique_tools) == len({t.name for t in unique_tools})`；重复名一律保留先入者并 warn（重复 schema 会让 LLM 收到拼接函数签名）。
2. **config.name 与 tool.name 不一致只 warn 不拒绝**：以工具自身的 `.name` 为最终绑定名，但要在日志里给出 `use:` 字段让排错可追溯。
3. **MCP-source 单一真值**：除 `is_mcp_tool()` 之外不允许任何代码用 name / module 路径推断"是否来自 MCP"；这是延迟披露的 fail-closed 前提。
4. **延迟装配位置**：必须在 **策略过滤之后** 再调用 `assemble_deferred_tools`，否则被禁掉的工具会出现在 catalog 中，模型用 `tool_search` 仍能拉取到。
5. **catalog_hash 是 promotion 作用域**：catalog 重建（增删工具）后旧的 `promoted` 自动失效；中间件读取时必须校验 hash。
6. **Host-Bash 默认关**：当 sandbox provider 是本地 Host 类时，必须显式 `allow_host_bash: true` 才装配 bash 工具；该判断同时检查 `group` 与 `use` 两个轴。
7. **MCP 子系统不可达 ≠ 工具装配失败**：捕获 `ImportError` 与一般异常分别 warn / error，但函数主体必须照常返回；否则一台未安装 `langchain-mcp-adapters` 的机器会让所有 agent 启动失败。
8. **ACP 装配失败不阻断主流程**：只 warn，并跳过 `invoke_acp_agent`。
9. **`tool_search` 不进入延迟集合本身**：永远作为普通工具追加到 final list，否则会出现"要靠延迟工具搜出延迟搜索器自己"的死循环。
10. **regex 容错**：`DeferredToolCatalog._compile_catalog_regex` 在非法正则时回退到字面量匹配；查询来自模型不可信。
11. **builtin 工具集合是只读默认**：`BUILTIN_TOOLS.copy()` 在每次装配开头执行；如果在末尾追加 `view_image_tool` / 子代理工具忘了 copy，会污染下一次装配的"全局默认"。
12. **`app_config` 可注入**：装配函数允许 `app_config=` 透传以便测试；当注入时必须避免重新走 `get_app_config()`，否则会读到磁盘上不一致的配置。

## 五、常见踩坑

- **延迟开关开了但 MCP 全部被策略过滤掉**：`build_deferred_tool_setup` 返回 EMPTY，这是正常路径；`assemble_deferred_tools` 的 fail-closed 分支只在 "MCP 工具仍存在但延迟集为空" 时才抛。两者别混。
- **`@dataclass(frozen=True, slots=True)` 会破坏 `@cached_property`**：slots 阻止写 `__dict__`，cached_property 写不进去就每次都重算。catalog 这种热路径要保留默认（不加 slots）。
- **MCP 工具用 name 前缀识别**：换 server 后前缀会变，导致延迟披露完全失效；只能用 metadata 标记。
- **同名 MCP 与本地工具同时存在**：合并顺序决定胜者；当前规则是 loaded > builtin > mcp > acp。把 MCP 工具配置成同名会被静默丢弃 + warn，注意排查。
- **vision 工具误装**：必须根据 `model_config.supports_vision` 决定，而不是按 model_name 字符串匹配，否则切换模型时极易出错。
- **bash 工具的判断条件**：`group == "bash"` 和 `use` 等于 host-bash 路径，两个都要查；只查一个会被另一种配置绕过。
- **ContextVar 走私延迟集合**：早期实现用 ContextVar 把延迟集传到中间件，多 agent 并发就互相串。正确做法是 build-time 闭包 + per-thread `state.promoted`。
- **`tool_search` 查询为空字符串**：`search("")` 必须返回 `[]`，否则模型会收到全量 catalog 反向"穿透"延迟披露。
- **重复 tool 名的 schema 拼接**：模型供应商有时会把同名函数定义合并，参数 schema 互相污染；去重时 warn 必须打印 `use:` 才能定位是哪个 entry 引入的。
- **`include_mcp=False` 但仍开启 deferred**：实现要保证 `mcp_tools` 为空时整条延迟链路无副作用。
- **每次 agent 重建都触发 MCP 重连**：`get_cached_mcp_tools` 应做 mtime / 配置签名级别的缓存；忽略此项会让每次工具装配都对远端 server 发握手。
- **`subagent_enabled` 同时来自配置和运行期**：实际生效的是 `app_config.subagents.enabled and runtime_subagent_enabled`；只看一个会出现"配置开了但用户在请求里关掉了"被忽略的反向 bug。

## 六、调参旋钮 + 调试入口

### 配置旋钮
- `tools[]`：每个条目 `use:` 反射目标、`group:` 分组、`name:` 期望名（与工具自身 `.name` 不一致仅 warn）
- `tool_groups[]`：调用方传 `groups=` 过滤时的逻辑分组
- `sandbox.allow_host_bash: bool`：本地 Provider 上是否允许装配 host bash
- `tool_search.enabled: bool`：是否启用延迟披露
- `models[*].supports_vision: bool`：决定是否追加视觉工具
- `subagents.enabled` + 运行期 `config.configurable.subagent_enabled`：决定是否追加 `task`
- `MAX_RESULTS`（`tool_search` 内部）：单次返回的 schema 数上限
- 反射目标 `use:` 字符串：建议跑一次静态扫描，确保所有 `use:` 都能 `resolve_variable` 成功，否则只在装配阶段才暴露
- ACP 配置 `acp_agents`：每个外部代理一个 entry，决定是否追加 `invoke_acp_agent` 工具
- `skill_evolution.enabled`：开启后追加 `skill_manage_tool` 到 builtin 列表（允许 agent 自行管理 skill）

### 运行期参数
- `get_available_tools(groups=..., include_mcp=..., model_name=..., subagent_enabled=...)`：每条都是显式开关
- `app_config=` 注入：测试时直接传伪造的 AppConfig 比 mock 整套配置层更稳

### 调试入口
1. 启动后查 `Total tools loaded: N, built-in tools: B, MCP tools: M, ACP tools: A` 这一行：定位"装配阶段"是否正确
2. `Tool name mismatch` warn：定位 config.name 与 `.name` 漂移
3. `Duplicate tool name 'X' detected and skipped`：定位同名冲突
4. `DeferredToolCatalog.hash` 出现在 `<available-deferred-tools>` 段附近的 trace：用来确认 promotion 作用域是否随 catalog 变化失效
5. 让 `tool_search` 工具的 `ToolMessage.content` 在调试视图中明文可见：能直接读到模型当前能解锁的全部 schema
6. 在 `assemble_deferred_tools` 失败时打开堆栈：fail-closed 的 RuntimeError 包含"开关开启且 MCP 工具仍存在"的关键字
7. 单元层验证：构造一个 dummy MCP 工具用 `tag_mcp_tool` 标记，断言 `catalog.search("select:dummy")` 命中、`hash` 稳定
8. 在 `_ensure_sync_invocable_tool` 内打点：若一个 async-only 工具在同步 caller 中报"未实现 `func`"，说明这里漏接管了
9. 用一个空的 `extensions_config`（无 mcp_servers）跑 `get_available_tools(include_mcp=True)`：MCP 分支必须直接走"无启用 server"短路，不去触发 cache 加载
10. 录制一次完整 `<system-prompt>` 渲染：核对 `<available-deferred-tools>` 名字与 `state.promoted.names` 的差集，差集大于 0 说明模型仍在用旧 schema 调用未提升的工具

### 相关 skill
- [[mcp-integration]]
- [[subagent-delegation]]
- [[safety-and-guardrails]]
- [[skill-system-design]]
- [[sandbox-tools-and-safety]]
