---
name: extension-plugin-system
description: 第三方扩展插件系统：helix_extension_api 宿主无关契约包（@extension 装饰器、MiddlewareContributor/TaskLifecycleContributor/ModelTool/AgentRuns/RunEvidenceReader 等全部贡献面，零依赖不 import 宿主）、宿主侧 ExtensionManager（发现/安装/uv 管理/git-local-registry 来源、版本兼容加载、隔离包装、路由贡献冲突检测、中间件锚点排序）、模型调用钩子与浏览器资产、九个官方扩展示例（中间件注入/全栈插件页/Agent 团队编排/JS 工作流引擎/ModelTool 分类/上下文修剪/检索 provider）。当要给 agent 平台设计插件生态、写第三方扩展、贡献中间件/工具/路由/模型工具时使用。
---

# 扩展插件系统

## 何时用

- 设计宿主-插件契约（贡献面、隔离、版本兼容）
- 写第三方扩展（中间件 / 工具 / HTTP 路由 / 模型工具 / 全栈插件页 / agent 编排）
- 插件的安装/加载/冲突治理

## 设计方案（为什么这么设计）

### 1. 契约包零依赖，插件独立发布

`helix_extension_api`（API_VERSION 0.2.7）**禁止 import helix**——插件只依赖契约包即可编译发布，宿主升级不破坏插件二进制面。`@extension` 装饰器注册，贡献面全部类型化：

| 贡献面 | 契约 | 典型示例 |
|---|---|---|
| 中间件 | `MiddlewareContributor` + `Placement`（`@Next/@Prev` 锚点复用宿主算法） | jev-screening（TOOL_VISIBLE 单中间件） |
| 任务生命周期 | `TaskLifecycleContributor`（TaskInfo/TaskOutcome） | example 插件 |
| 模型观察/调用 | `SystemModelCallObserver` / `ModelInvoker` | jev-classify（ModelTool 分类） |
| 上下文修剪 | `ContextCompactionObserver`（TOOL_VISIBLE 放置） | jev-context |
| HTTP 路由 | 路由贡献（宿主 `include_contributed_routers` 冲突检测） | bookmarks 后端动作 |
| 浏览器资产 | `BrowserAssets`（打包 mjs 模块） | bookmarks 全栈插件页 |
| Agent 编排 | `AgentRuns` + `require_agent_runs`（resolver key 注入） | agent-teams / workflows |
| 运行证据 | `RunEvidenceReader`（RunEventView/RunStatusView 只读） | 审计类插件 |
| 检索 provider | RetrievalProvider 注册 | knowledge 示例 |

### 2. 宿主侧：管理器 + 锚点排序 + 隔离

`extensions/manager.py`（1138 行）：来源校验（git/local/registry）→ uv 管理安装 → `load_extensions` 版本兼容加载 → `ExtensionRegistry`。中间件经 `stack.py::compose_with_extensions` + `anchors.py` 锚点合入主链（与 [[agent-graph-factory]] 的 @Next/@Prev 同一算法）；`isolation.py`（380 行）包装插件异常防击穿宿主；`gateway.py` 检测路由贡献冲突；`plugin_tools.py` 把插件工具并入装配（见 [[tool-assembly-and-policy]]）；`notify.py` 通知面。

### 3. 信任边界：代码 import 面只归操作员

插件是**代码**（会 import 执行）——清单只允许出现在操作员控制的 `config.yaml → plugins:`，**绝不进 API 可写的 extensions_config.json**（见 [[config-and-hot-reload]]）。插件页面/动作再过一层授权（见 [[safety-and-guardrails]]）。

### 4. 九个示例 = 九种模式

example（入门全贡献面）/ bookmarks（全栈：浏览器页+动作+资产+ModelTool）/ agent-teams（AgentRuns 多成员各自持久会话编排）/ workflows（后台 JS 脚本编排，workflow run ID 立返）/ jev-classify（ModelTool）/ jev-context（上下文修剪）/ jev-screening（单中间件）/ knowledge（检索 provider）/ retrieval（content_and_artifact 工具）。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/extension-api/helix_extension_api/__init__.py` + `contracts.py` | 188+258 | 契约索引 + 核心类型 |
| `references/code/backend/packages/extension-api/helix_extension_api/{agent_runs,assembly,plugins,run_evidence,auth,release,provenance,model_invocation,placement,compaction,settings,state}.py` | — | 各贡献面契约 |
| `references/code/backend/packages/harness/helix/extensions/manager.py` | 1138 | 宿主管理器 |
| `references/code/backend/packages/harness/helix/extensions/{loader,registry,stack,anchors,isolation,gateway,plugin_tools,notify,model_invocation,ordering,browser_assets,injection,run_evidence,model_access}.py` | 282/271/191/120/380/654/144/548/263/127/112/139/168/94 | 宿主侧全家桶 |
| `references/code/examples/**`（9 示例 + README） | ~4700 | 官方模式样例 |
| `references/code/backend/app/gateway/routers/plugins.py` | 158 | 插件资产/动作服务 |

## 反模式与陷阱

- ❌ 契约包 import 宿主 → 插件被宿主版本锁死；零依赖铁律。
- ❌ API 可写插件清单 → RCE 提权面；只留操作员配置。
- ❌ 插件异常裸抛 → 宿主崩；隔离包装。
- ❌ 贡献路由不经冲突检测 → 路由覆盖。
- ❌ 插件中间件无锚点插到链尾 → 落在 Clarification 之后（见 [[middleware-chain-design]]）。
- ❌ 插件工具绕过 provenance → 授权判定失明（见 [[safety-and-guardrails]]）。

## 落地参考

**自测方向**：示例插件 install→load→贡献可见全流程；不兼容 API_VERSION 拒载且报语义版本；插件抛异常只影响自身贡献面；路由冲突启动即报；agent-teams/workflows 的 run 证据可读。

## 进一步阅读

- [[middleware-chain-design]]（锚点合链）、[[tool-assembly-and-policy]]（插件工具并入）
- [[config-and-hot-reload]]（plugins 信任边界）、[[safety-and-guardrails]]（插件授权层）
