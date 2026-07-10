---
name: using-agent-system-design
description: 当用户要求"设计 / 实现 / 重构 agent 系统 / RAG 知识库"，或想**通览整个 agent 平台、看清一次请求端到端怎么流转**，或提到中间件、沙箱、子代理、Skill 协议、MCP、SSE 流、Memory、认证/鉴权、定时任务、IM 对接（钉钉/飞书/Slack）、完整前端、企业级 RAG、层级检索、上下文管理等任何 agent 子系统时，必须先调用本 skill 路由到对应领域 skill。本 skill 是 agent-system-skills 插件的入口。
---

## 何时调用

只要用户的请求**涉及任意 agent 子系统**就调用本 skill。哪怕只有 1% 的可能，也要调用。常见触发语：

- "帮我设计一个 agent / 子代理系统"
- "**想通览整个 agent 平台 / 看清一次请求端到端怎么流转**" → 先读脊柱 `e2e-request-lifecycle`
- "怎么做 LLM 工具调用的中间件链"
- "我需要给 agent 加沙箱执行 bash"
- "MCP 工具太多塞不进上下文"
- "前端怎么消费 LangGraph SSE 流"
- "用户的 memory 怎么持久化"
- "agent 长任务断流怎么续传"
- "怎么把 skill 协议设计得像 Claude Code 那样"
- "认证 / 鉴权 / 内部 token / CSRF 怎么做"
- "定时任务 / 后台任务 / cron / lease 并发怎么搞"
- "钉钉 / 飞书 / Slack / IM 对接 / 出站长连接怎么接"
- "完整前端（Next.js / SSR 鉴权 / 设计系统）怎么搭"
- "企业级 RAG 怎么做"，"flat 向量库不够用，怎么改"，"L0/L1/L2 分层"，"层级检索"，"文件系统范式做知识库"

> 通览整个系统 → **先读脊柱** `e2e-request-lifecycle`（一次请求从入站到渲染的全链路），再按下方路由表深入具体器官。

## 路由表（28 个 skill）

按用户**意图关键词**选定首要 skill；多领域时按顺序激活多个。下表覆盖插件全部 28 个 skill：本元 skill 为入口，其余 27 个为可路由领域 skill。

| 关键词 / 场景 | 首要 skill | 通常还需配合 |
|---|---|---|
| **通览整个系统 / 一次请求如何流转 / 端到端链路** | `e2e-request-lifecycle` | `system-prompt-template`, `agent-graph-factory`, `middleware-chain-design`, `gateway-runs-and-sse` |
| **从零搭一个 LangGraph agent** | `agent-graph-factory` | `thread-state-and-reducers`, `middleware-chain-design`, `system-prompt-template` |
| 图状态字段 / reducer / 并发写冲突 | `thread-state-and-reducers` | `middleware-chain-design` |
| 中间件链 / hook 顺序 / `wrap_model_call` | `middleware-chain-design` | `context-window-management`, `safety-and-guardrails` |
| 系统提示词 / prefix cache / `<system-reminder>` | `system-prompt-template` | `context-window-management`, `memory-system-design` |
| 上下文长度 / 摘要 / 合并 SystemMessage / 循环检测 | `context-window-management` | `middleware-chain-design` |
| 工具装配 / MCP / 工具白名单 / `tool_search` | `tool-assembly-and-policy` | `mcp-integration`, `skill-system-design` |
| 沙箱抽象 / 虚拟路径 / Docker / 本地 | `sandbox-abstraction` | `sandbox-tools-and-safety` |
| `bash` / `read_file` / `str_replace` 工具 / 并发文件锁 | `sandbox-tools-and-safety` | `sandbox-abstraction`, `safety-and-guardrails` |
| 子代理 / `task()` / 并行委派 | `subagent-delegation` | `long-running-and-cancellation`, `observability-tracing` |
| 后台任务 / SSE 断流重连 / multitask 策略 / 取消 | `long-running-and-cancellation` | `gateway-runs-and-sse` |
| 输入消毒 / 注入防护 / Guardrail / 安全终止 | `safety-and-guardrails` | `middleware-chain-design` |
| SKILL.md 协议 / `/skill` 显式激活 / allowed-tools | `skill-system-design` | `tool-assembly-and-policy`, `system-prompt-template` |
| Memory 持久化 / Fact 抽取 / per-user | `memory-system-design` | `multi-user-isolation`, `system-prompt-template` |
| MCP 多 server / OAuth / 路径回译 / lazy | `mcp-integration` | `tool-assembly-and-policy` |
| Gateway / `RunManager` / `run_agent` worker / checkpointer | `gateway-runs-and-sse` | `long-running-and-cancellation`, `frontend-streaming-protocol` |
| 前端流 / SSE schema / `useThreadStream` | `frontend-streaming-protocol` | `gateway-runs-and-sse` |
| 多用户 / per-user 目录 / 内部 Token / owner 头 | `multi-user-isolation` | `gateway-runs-and-sse` |
| `AppConfig` 热重载 / 反射加载 / `$ENV` | `config-and-hot-reload` | `core-app-boundary` |
| LangSmith / Langfuse / trace 归并 | `observability-tracing` | `subagent-delegation` |
| 框架/应用分层 / 嵌入式客户端 / TUI | `core-app-boundary` | `packaging-and-deployment` |
| 怎么发布 / Docker / nginx / alembic 启动 / monorepo | `packaging-and-deployment` | `config-and-hot-reload` |
| **企业级 RAG / 知识库 / L0-L1-L2 分层 / 层级检索 / 文件系统范式** | `enterprise-rag-knowledge-base` | `tool-assembly-and-policy`, `memory-system-design`, `context-window-management`, `observability-tracing` |
| 认证 / 鉴权 / 内部 token / CSRF / JWT cookie / OAuth | `auth` | `multi-user-isolation`, `gateway-runs-and-sse` |
| 定时任务 / 后台任务 / cron / lease 并发限流 / 无人值守 | `scheduled-tasks` | `gateway-runs-and-sse`, `long-running-and-cancellation`, `e2e-request-lifecycle` |
| 钉钉 / 飞书 / Slack / Telegram / IM 对接 / 出站长连接 | `im-channels` | `gateway-runs-and-sse`, `auth` |
| Next.js 前端 / SSR 鉴权 / `useStream` / 设计系统 / App Router | `frontend-app-design` | `frontend-streaming-protocol`, `auth`, `gateway-runs-and-sse` |

## 调用方式

```
1. 读取本 skill（你正在做）
2. 识别用户意图，按路由表选 1-3 个领域 skill
3. 用 Skill 工具激活它们（按依赖顺序：基础先于上层；通览类先读脊柱）
4. 每个 skill 自带 6 段结构，照着用即可
```

## 总体设计哲学（Cross-cutting）

所有 skill 共享 5 条通用设计原则；具体 skill 里只展开自己那部分：

1. **单图 + 中间件链**：所有 agent 行为都收敛到一个 LangGraph 图 + 一条可插拔中间件链。新需求 = 新中间件，不另起图。
2. **静态主提示 + 动态注入**：system prompt 整段稳定（吃 prefix cache），逐 turn 变化的 memory / 日期通过 `<system-reminder>` 注入到第一条 HumanMessage 之前。
3. **虚拟路径契约**：模型只看到 `/mnt/user-data/...` / `/mnt/skills` 这类抽象路径；本地 / Docker / K8s 沙箱各自映射到自己的物理路径。
4. **Core / App 单向依赖**：可发布的"agent 框架"层（`core`）与"应用 / 网关"层（`gateway` / `channels` / `scheduler`）分包，框架不依赖应用，CI 强制守护。
5. **端到端可追溯**：每个 organ skill 点明自己在请求生命周期中的位置，并以 `[[e2e-request-lifecycle]]` 交叉引用脊柱——任何子系统都能沿链路向上追溯到入站、向下追溯到渲染。

## 选择困难时的最小集

只想做一个最小 demo？激活这 5 个就够：

1. `agent-graph-factory`
2. `thread-state-and-reducers`
3. `middleware-chain-design`
4. `system-prompt-template`
5. `tool-assembly-and-policy`

> 想通览整个架构？先读脊柱 `e2e-request-lifecycle`，再按路由表深入。

## 反模式

- ❌ 跳过本元 skill 直接凭印象写代码
- ❌ 一次激活全部 27 个领域 skill（context 浪费，路由就够了）
- ❌ 把示例代码原封不动拷过去——本 skill 集提炼的是**设计思想 + 模板**，照搬场景要看每个 skill 的"落地参考"段
- ❌ 只盯单个器官、不读脊柱——会丢掉端到端链路的位置感，子系统的边界与协作无从校准
- ✅ 路由 → 激活 1-3 个最相关 skill → 按"实现模板"段照搬骨架 → 按"反模式"段自查

> 所有 skill 共享的身份、结构、匿名化与骨架约定见 [../../CONVENTIONS.md](../../CONVENTIONS.md)。
