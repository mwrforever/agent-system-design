---
name: tool-assembly-and-policy
description: 设计 agent 工具装配流水线——config-driven + 内置 + MCP + subagent；skill allowed-tools 白名单收缩；deferred + tool_search 按需 promote。
---

## 何时用

- 不同 agent / 不同用户应该看到不同工具集
- 工具数量爆炸（MCP 接 N 个 server 后总 schema 几百个）
- 想让 skill 限制自己能调的工具（最小权限）
- 想支持运行时切换 model（不同 model 工具集不同）

## 设计思想

1. **装配流水线 = 来源 + 过滤 + 后处理三阶段**。来源：config-defined / builtin / MCP / subagent。过滤：skill `allowed-tools` 取并集后收窄。后处理：`assemble_deferred_tools()` 拆出"立即可见"vs"延迟 promote"。
2. **config 定义工具用反射加载**：`tools[].use = "module.path:variable_name"` 通过 `resolve_variable()` 动态导入；新增工具不改主代码。
3. **MCP lazy**：MCP 工具按需在首次使用时连接 server，并按 mtime 缓存——`extensions_config.json` 改了下次自动失效。
4. **deferred + tool_search**：工具太多时，系统提示只列"名字"，schema 不绑定到模型；模型必须先调 `tool_search(name="...")` 才能拿到 schema。
5. **subagent 不传 `task`**：避免无限嵌套委派。

## 实现模板

### 工具装配

```python
def get_available_tools(*, groups=None, model_name=None, subagent_enabled=False,
                       app_config=None, include_mcp=True):
    """组合所有工具来源，按 groups 过滤."""
    tools: list[BaseTool] = []

    # 1) config-defined（反射加载）
    for tool_cfg in (app_config or get_app_config()).tools:
        if groups and tool_cfg.group not in groups:
            continue
        tool = resolve_variable(tool_cfg.use)  # "module:variable"
        tools.append(tool)

    # 2) 内置
    tools.extend([present_files, ask_clarification])
    model_config = app_config.get_model_config(model_name) if model_name else None
    if model_config and model_config.supports_vision:
        tools.append(view_image)

    # 3) MCP（lazy + 缓存）
    if include_mcp:
        tools.extend(get_cached_mcp_tools(app_config=app_config))

    # 4) 子代理委派
    if subagent_enabled:
        tools.append(task_tool)
    return tools
```

### Skill 工具白名单收缩

```python
def filter_tools_by_skill_allowed_tools(tools, skills):
    """启用的 skill 中如果任意一个声明了 allowed-tools，只保留并集 + 常驻基础工具.

    全为 None → 不收缩（向后兼容）.
    """
    declared = [s.allowed_tools for s in skills if s.allowed_tools is not None]
    if not declared:
        return tools
    allowed: set[str] = set().union(*declared) | _ALWAYS_AVAILABLE_TOOLS
    return [t for t in tools if t.name in allowed]
```

### Deferred + tool_search 切分

```python
@dataclass(frozen=True)
class DeferredToolSetup:
    deferred_names: frozenset[str]
    catalog_hash: str
    tool_search_tool: BaseTool


def assemble_deferred_tools(tools: list[BaseTool], *, enabled: bool):
    """启用时把 MCP 工具拆为 deferred；模型需要先调 tool_search 才能拿 schema."""
    if not enabled:
        return tools, DeferredToolSetup(frozenset(), "", make_tool_search_noop())

    is_mcp = lambda t: t.metadata.get("source") == "mcp"
    deferred = [t for t in tools if is_mcp(t)]
    immediate = [t for t in tools if not is_mcp(t)]
    deferred_names = frozenset(t.name for t in deferred)
    catalog_hash = hashlib.sha1(
        ",".join(sorted(deferred_names)).encode()
    ).hexdigest()[:12]

    tool_search = make_tool_search_tool(deferred=deferred, catalog_hash=catalog_hash)
    return immediate + [tool_search], DeferredToolSetup(deferred_names, catalog_hash, tool_search)
```

### 配套 `DeferredToolFilterMiddleware`

```python
class DeferredToolFilterMiddleware(AgentMiddleware):
    """绑定模型时隐藏 deferred 工具 schema；按 state.promoted 暴露已激活的."""
    def __init__(self, deferred_names, catalog_hash):
        self.deferred_names = deferred_names
        self.catalog_hash = catalog_hash

    def wrap_model_call(self, request, handler):
        promoted = state_get(request, "promoted") or {}
        if promoted.get("catalog_hash") != self.catalog_hash:
            promoted = {}  # catalog 变了，旧 promotion 失效
        promoted_names = set(promoted.get("names", []))
        request.tools = [t for t in request.tools
                          if t.name not in self.deferred_names or t.name in promoted_names]
        return handler(request)
```

## 反模式

- ❌ 把工具静态 import 到主代码 → 新增第三方工具要改主代理
- ❌ MCP 工具在 agent 工厂里 await 初始化 → 冷启动慢，断网启动失败
- ❌ `allowed-tools` 取交集而非并集 → 多 skill 启用时几乎没工具可用
- ❌ deferred 不带 catalog_hash → MCP server 改了名后旧 promotion 仍指向已删除的工具
- ✅ config-driven 反射 + lazy MCP + skill 白名单 + deferred 四层独立可控
- ✅ catalog_hash 切换时 `merge_promoted` reducer 自动重置（见 [[thread-state-and-reducers]]）

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[agent-graph-factory]] [[mcp-integration]] [[skill-system-design]] [[thread-state-and-reducers]]
