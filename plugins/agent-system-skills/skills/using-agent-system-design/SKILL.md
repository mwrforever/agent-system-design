---
name: using-agent-system-design
description: 当用户要求"设计 / 实现 / 重构 agent 系统 / RAG 知识库"或提到中间件、沙箱、子代理、Skill 协议、MCP、SSE 流、Memory、企业级 RAG、层级检索、上下文管理等任何 agent 子系统时，必须先调用本 skill 路由到对应领域 skill。本 skill 是 agent-system-skills 插件的入口。
---

## 何时调用

只要用户的请求**涉及任意 agent 子系统**就调用本 skill。哪怕只有 1% 的可能，也要调用。常见触发语：

- "帮我设计一个 agent / 子代理系统"
- "怎么做 LLM 工具调用的中间件链"
- "我需要给 agent 加沙箱执行 bash"
- "MCP 工具太多塞不进上下文"
- "前端怎么消费 LangGraph SSE 流"
- "用户的 memory 怎么持久化"
- "agent 长任务断流怎么续传"
- "怎么把 skill 协议设计得像 Claude Code 那样"
- "企业级 RAG 怎么做"，"flat 向量库不够用，怎么改"，"L0/L1/L2 分层"，"层级检索"，"文件系统范式做知识库"

## 路由表（23 个 skill）

按用户**意图关键词**选定首要 skill；多领域时按顺序激活多个。

| 关键词 / 场景 | 首要 skill | 通常还需配合 |
|---|---|---|
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
| `AppConfig` 热重载 / 反射加载 / `$ENV` | `config-and-hot-reload` | `harness-app-boundary` |
| LangSmith / Langfuse / trace 归并 | `observability-tracing` | `subagent-delegation` |
| 框架/应用分层 / 嵌入式客户端 / TUI | `harness-app-boundary` | `packaging-and-deployment` |
| 怎么发布 / Docker / nginx / alembic 启动 / monorepo | `packaging-and-deployment` | `config-and-hot-reload` |
| **企业级 RAG / 知识库 / L0-L1-L2 分层 / 层级检索 / 文件系统范式** | `enterprise-rag-knowledge-base` | `tool-assembly-and-policy`, `memory-system-design`, `context-window-management`, `observability-tracing` |

## 调用方式

```
1. 读取本 skill（你正在做）
2. 识别用户意图，按路由表选 1-3 个领域 skill
3. 用 Skill 工具激活它们（按依赖顺序：基础先于上层）
4. 每个 skill 自带 6 段结构，照着用即可
```

## 总体设计哲学（Cross-cutting）

所有 skill 共享 4 条通用设计原则；具体 skill 里只展开自己那部分：

1. **单图 + 中间件链**：所有 agent 行为都收敛到一个 LangGraph 图 + 一条可插拔中间件链。新需求 = 新中间件，不另起图。
2. **静态主提示 + 动态注入**：system prompt 整段稳定（吃 prefix cache），逐 turn 变化的 memory / 日期通过 `<system-reminder>` 注入到第一条 HumanMessage 之前。
3. **虚拟路径契约**：模型只看到 `/mnt/user-data/...` / `/mnt/skills` 这类抽象路径；本地 / Docker / K8s 沙箱各自映射到自己的物理路径。
4. **Harness / App 单向依赖**：可发布的"agent 框架"层与"应用 / 网关"层分包，框架不依赖应用，CI 强制守护。

## 选择困难时的最小集

只想做一个最小 demo？激活这 5 个就够：

1. `agent-graph-factory`
2. `thread-state-and-reducers`
3. `middleware-chain-design`
4. `system-prompt-template`
5. `tool-assembly-and-policy`

## 反模式

- ❌ 跳过本元 skill 直接凭印象写代码
- ❌ 一次激活全部 22 个 skill（context 浪费，路由就够了）
- ❌ 把示例代码原封不动拷过去——本 skill 集提炼的是**设计思想 + 模板**，照搬场景要看每个 skill 的"落地参考"段
- ✅ 路由 → 激活 1-3 个最相关 skill → 按"实现模板"段照搬骨架 → 按"反模式"段自查
