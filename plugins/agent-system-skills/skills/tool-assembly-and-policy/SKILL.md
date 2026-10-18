---
name: tool-assembly-and-policy
description: 工具装配管线设计：get_available_tools 六源合并（YAML 配置工具→内置→子代理→MCP→ACP→插件）与按名去重、use: 字符串反射加载机制、tool_search 延迟工具目录（keyword+regex 评分、DeferredToolSetup、catalog_hash 一致性）、工具来源溯源（provenance）、write_file 预算注记、host-bash 剥离。当要设计工具注册/过滤/去重体系、做延迟工具加载、排查"工具该出现没出现/重复/来源不明"时使用。
---

# 工具装配与策略

## 何时用

- 设计 agent 的工具来源体系（配置文件声明 + 内置 + MCP + 插件多源合并）
- 延迟工具加载（工具太多撑爆 schema/提示词）
- 工具级安全策略（host-bash 剥离、来源打标、授权过滤的挂接点）
- 排查工具清单与预期不符

## 设计方案（为什么这么设计）

### 1. 六源合并，config 优先去重

`get_available_tools()`（tools.py:102）按固定顺序装配：

1. **YAML 配置工具**：`config.yaml → tools` 用 `use: helix.sandbox.tools:bash_tool` 这类**字符串引用**实现体，经 `reflection/resolvers.resolve_variable` 反射加载——工具实现与配置解耦，第三方可注入自己的类路径。按 group 过滤；host-bash 未允许时剥离；knowledge 未启用剥 knowledge 组。
2. **内置工具**：present_files / ask_clarification / review_skill_package + 条件项（scheduler、后台任务、list_uploaded_files、skill_manage、view_image）。
3. **子代理工具**：task（见 [[subagent-delegation]]）。
4. **MCP 缓存工具 + 个人 MCP**：同名时弃个人保全局（见 [[mcp-integration]]）。
5. **ACP 工具**：外部 agent 协议。
6. **插件工具**：扩展贡献（见 [[extension-plugin-system]]）。

最后按 `tool.name` 去重，**config 声明优先**——用户配置是最终事实源。

### 2. 延迟工具目录（tool_search）

工具全量暴露会撑爆 schema 与提示词。`assemble_deferred_tools(candidate, enabled)` 把大量低频工具（主要是 MCP）从 schema 集切出，注入一个 `tool_search` 检索工具 + catalog 提示段；运行时模型先 `tool_search`，`McpRoutingMiddleware`/晋升审计再把命中的工具动态放行。`DeferredToolSetup.deferred_names` 同时喂中间件白名单与提示词渲染（catalog_hash 校对）——两侧不同源是经典 bug（见 [[agent-graph-factory]] 反模式）。排序用 keyword+regex 双信号评分（`_rank_catalog_keywords`）。

### 3. 描述增强与来源溯源

- `write_file` 描述按模型 max_tokens 注入"PER-RESPONSE BUDGET"注记——让模型在源头知道输出预算（配合 [[context-window-management]]）。
- `tool_provenance.py`：每个工具标记来源（plugin/host/builtin/mcp/...），供护栏与审计消费（见 [[safety-and-guardrails]]）。
- `mcp_metadata.py`：MCP 工具打标/读取（is_mcp_tool/get_mcp_source）。
- `artifact_registry.py`：工具产物句柄抽取/渲染——工具结果里的文件引用登记为 artifact（配合 [[workspace-and-projects]]）。

### 4. 装配后的三道过滤（工厂侧）

```
get_available_tools() → filter_tools_by_skill_allowed_tools（技能白名单）
                      → apply_tool_authorization（授权 Layer1，见 safety-and-guardrails）
                      → non_interactive 剥离 ask_clarification
                      → assemble_deferred_tools（延迟切分）
```

顺序不可逆：先过滤再切分，否则被禁工具混进延迟集。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/tools/tools.py` | 353 | 装配入口（六源合并/去重/预算注记/host-bash 剥离） |
| `references/code/tools/builtins/tool_search.py` | 444 | 延迟目录/评分/catalog 提示段/路由中间件工厂 |
| `references/code/tools/tool_provenance.py` | 218 | 来源溯源 |
| `references/code/tools/artifact_registry.py` | 452 | 产物句柄登记与渲染 |
| `references/code/tools/mcp_metadata.py` | 80 | MCP 打标 |
| `references/code/tools/sync.py` | 108 | async 工具同步包装 |
| `references/code/tools/conversation.py` | 77 | 会话读取工具 |
| `references/code/tools/resource_placeholder.py` | 73 | 资源占位符（防 URL 泄漏） |
| `references/code/tools/builtins/clarification_tool.py` | 94 | ask_clarification |
| `references/code/tools/builtins/present_file_tool.py` | 121 | present_files |
| `references/code/tools/builtins/view_image_tool.py` | 356 | view_image |
| `references/code/tools/builtins/list_uploaded_files_tool.py` | 353 | 上传清单 |
| `references/code/tools/builtins/background_tasks_tool.py` | 91 | 后台任务查询 |
| `references/code/tools/builtins/invoke_acp_agent_tool.py` | 344 | ACP 外部 agent 调用 |
| `references/code/reflection/resolvers.py` | 95 | use: 字符串反射加载 |
| `references/code/config/tool_search_config.py` | 52 | 延迟加载开关 |
| `references/code/config/tool_config.py` | 20 / `tool_artifact_config.py` | 38 | 工具/产物配置 |

bash/read/write/str_replace/ls/glob/grep 的**实现体**在 [[sandbox-tools-and-safety]]；task 在 [[subagent-delegation]]；skill_manage / review_skill_package 在 [[skill-system-design]]；scheduled_tasks 在 [[scheduled-tasks]]。

## 反模式与陷阱

- ❌ 先 assemble 再 filter → 被禁工具进延迟集，提示词骗模型。
- ❌ 新工具硬编码 import → 失去配置可替换性；走 `use:` 反射。
- ❌ 同名工具不处理冲突 → MCP 覆盖内置或反之；规则：config > 全局 MCP > 个人 MCP。
- ❌ 延迟目录排序只按名称 → 召回差；keyword+regex 双信号。
- ❌ 工具描述写死输出上限 → 换模型即失真；按 model_config 动态注记。

## 落地参考

**自测方向**：六源注入同名工具断言去重优先级；开/关 `tool_search.enabled` 断言 schema 数量与提示段变化；host-bash 未允许时断言剥离；provenance 标记可被护栏读取。

**调参旋钮**：`tool_search.enabled`、`tools` 组、`tool_output` 豁免清单（见上下文 skill）。

## 进一步阅读

- [[agent-graph-factory]]（装配管线在工厂中的位置）、[[mcp-integration]]（MCP 工具缓存源）
- [[safety-and-guardrails]]（授权过滤两层）、[[middleware-chain-design]]（McpRouting/DeferredToolFilter 中间件）
