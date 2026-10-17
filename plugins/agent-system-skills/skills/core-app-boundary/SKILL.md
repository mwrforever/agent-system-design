---
name: core-app-boundary
description: 框架/应用边界与直连消费方：harness↔app 单向依赖的 CI 强制测试、可发布框架包的工程配置（pyproject）、嵌入式 Python 客户端 HelixClient（1989 行——不经 Gateway 进程直连 agent，复用与 lead 完全相同的中间件/提示词链，含线程/模型/技能/记忆/MCP/上传管理面）、Textual 终端 UI（ Elm 架构 reducer + headless print/json 双模式 CLI + 会话持久化）。当要把 agent 框架做成可发布包、写嵌入式客户端/TUI、或守住框架-应用边界时使用。
---

# 核心边界、嵌入式客户端与 TUI

## 何时用

- 把 agent 框架抽成独立发布包（边界怎么划、怎么守）
- 不起 Gateway 进程直接在 Python 里用 agent（测试/脚本/嵌入产品）
- 终端 UI（交互 TUI / 一次性 headless 输出）

## 设计方案（为什么这么设计）

### 1. 边界：一条规则 + 一个 CI 测试

框架包（`helix.*`）包含 orchestration/tools/sandbox/models/MCP/skills/memory/config/runtime 全量能力；应用层（`app.*`）只有 Gateway 与渠道。**App imports helix，helix 绝不 import app**——`backend/tests/test_harness_boundary.py` 在 CI 强制。为什么值得一个专门测试：反向 import 会让框架悄悄耦合 HTTP/渠道细节，失去可发布性（嵌入式客户端与 TUI 全靠这条边界才能存在）。第三方扩展契约更进一步：`helix_extension_api` 连 helix 都不 import（见 [[extension-plugin-system]]）。

### 2. HelixClient：进程内全功能客户端

`client.py`（1989 行）：`HelixClient(model_name=..., agent_name=..., middlewares=...)` 惰性建 agent（缓存 key 变更即重建，冻结 checkpoint 模式），复用 `build_middlewares` + `apply_prompt_template` **同一条链**（与 Gateway 行为零漂移）。
- 会话面：`stream(message, thread_id=...)`（SSE 形态事件迭代器，含 usage 记账与沙箱租约清理）/ `chat()`（取纯文本）/ `reset_agent()`
- 线程面：list/get/分支/goal 读写
- 管理面：模型/技能（安装更新）/MCP 配置/记忆（导入导出 CRUD）/上传/工件

调度器测试、TUI、二次嵌入都走它——**同一个系统四种入口**（Web/Gateway HTTP、IM 渠道、调度器、嵌入式），执行语义只有一条。

### 3. TUI：Elm 架构

`tui/`：`runtime.py::translate(event) -> list[Action]` 把客户端流事件翻译成 Action；`view_state.py::reduce(state, action)` 纯函数归约出 ViewState；`app.py`（Textual）只做渲染与 worker 调度。headless 双模式：`python -m helix.tui --print/--json`（CLI 一次性输出，给脚本与测试）。会话经 `session.py` + `persistence.py` 跨进程续接；`command_registry.py` 提供斜杠命令与技能补全。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/tests/test_harness_boundary.py` | — | 边界 CI 强制 |
| `references/code/backend/AGENTS.md` | 361 | 后端工程契约（命令/TDD/边界/重载） |
| `references/code/backend/packages/harness/pyproject.toml` | — | 框架包发布配置 |
| `references/code/backend/packages/harness/helix/client.py` | 1989 | 嵌入式客户端 |
| `references/code/backend/packages/harness/helix/tui/app.py` | 890 | Textual 应用 |
| `references/code/backend/packages/harness/helix/tui/cli.py` | 412 | 三模式入口 |
| `references/code/backend/packages/harness/helix/tui/view_state.py` | 390 | reducer |
| `references/code/backend/packages/harness/helix/tui/{runtime,session,command_registry,render,persistence,message_format,input_history,theme,widgets/composer}.py` | 130/103/132/152/111/108/58/42/64 | 配套 |

## 反模式与陷阱

- ❌ 框架里"顺手"import 应用层 → 可发布性静默死亡；边界测试拦。
- ❌ 嵌入客户端另写一条装配链 → 行为漂移；复用 build_middlewares。
- ❌ TUI 在渲染线程做流处理 → 卡死；worker + Action 队列。
- ❌ 客户端长期持有 agent 不检查配置变更 → 改配置不生效；缓存 key 重建。

## 落地参考

**自测方向**：边界测试对违规 import 样本必红；同一会话用 HelixClient 与 HTTP 跑同样输入，中间件链与提示词一致；TUI 断线重连后续接；`--json` 模式输出可被 jq 解析。

## 进一步阅读

- [[extension-plugin-system]]（更严格的零依赖契约包）、[[agent-graph-factory]]（客户端复用的装配链）
- [[frontend-streaming-protocol]]（Web 端的对应消费面）
