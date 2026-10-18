---
name: using-agent-system-design
description: Agent 系统设计技能集的元路由入口。当用户要设计/搭建/重构任何"多用户 Agent 平台"组件——图工厂、中间件链、沙箱、技能系统、子代理、记忆、MCP、SSE 流式、网关、IM 渠道、定时任务、扩展插件、持久层、模型接入、前端聊天应用——或排查此类系统的架构问题时，必须先读本 skill 选择正确的领域 skill。提到"agent 系统 / super agent / agent harness / LangGraph 应用 / 类 Claude Code 的 agent 平台"等措辞时同样适用。
---

# Agent 系统设计：能力地图与路由

本技能集从一个真实生产级 super-agent 平台（代号 **Helix**）逐字蒸馏而来：**988 个源码文件、约 26.2 万行**，全部按 `CONVENTIONS.md` 的机械替换规则匿名化，结构零改动。每个 skill = 一个能力域的"设计决策 + 完整真实源码索引"。

## 何时用

- 用户描述的需求落在下表任一能力域（即使只用了口语化措辞，如"让 bot 也能在飞书里跑"、"上下文太长怎么办"、"怎么给工具加权限"）
- 需要整体了解这套系统的分层与依赖，再决定深入哪个域
- 排查跨域问题需要先定位"问题属于哪一层"

## 系统全景（三个事实先记住）

1. **四服务拓扑**：Nginx `2026`（唯一公网入口）→ Gateway `8001`（FastAPI + 内嵌 LangGraph 兼容运行时）+ 前端 `3000`（Next.js）+ 可选 Provisioner `8002`（K8s 沙箱供给）。`/api/langgraph/*` 被 nginx 重写为 Gateway 原生 `/api/*`，标准 LangGraph SDK 客户端无需独立 LangGraph Server 即可直连。
2. **三层单向依赖**：`harness`（可发布框架包，`helix.*`）← `app`（gateway/channels/scheduler 等应用层）← `frontend`（HTTP/SSE）。框架绝不反向 import 应用层，CI 边界测试强制。`helix_extension_api`（扩展契约包）零依赖。
3. **运行时三元组**都在框架层：`RunManager`（run 生命周期/租约）+ `run_agent()` worker（后台执行）+ `StreamBridge`（SSE 桥，支持 `Last-Event-ID` 重连）。应用层只做装配与 HTTP 编排。

## 能力路由表

| 用户要做的事 | 调用 skill |
|---|---|
| 理解一次请求从 nginx 到前端的完整旅程 | [[e2e-request-lifecycle]] |
| 写 LangGraph 图工厂 / 双通道 config / 装配 agent | [[agent-graph-factory]] |
| 设计中间件链 / 加一个 before-model 钩子 | [[middleware-chain-design]] |
| 写系统提示词模板并吃 prefix cache | [[system-prompt-template]] |
| 扩展 ThreadState / 自定义 reducer / Delta 通道 | [[thread-state-and-reducers]] |
| 上下文压缩 / token 预算 / 工具输出预算 | [[context-window-management]] |
| 工具装配管线 / 嶭延迟工具目录 / 工具来源溯源 | [[tool-assembly-and-policy]] |
| 沙箱抽象 / 多 provider / 租约 / 暖池 | [[sandbox-abstraction]] |
| bash 与文件工具的路径安全 / 输出脱敏 | [[sandbox-tools-and-safety]] |
| 子代理委派 / 并发容量 / 批处理 / 验收核验 | [[subagent-delegation]] |
| MCP 多 server / 会话池 / 个人 MCP / MCP 长任务 | [[mcp-integration]] |
| SKILL.md 发现 / 三级投影 / 安装扫描 / 技能评审 | [[skill-system-design]] |
| 记忆系统 / 多后端 / 信号采集 | [[memory-system-design]] |
| 知识检索接入（RAGFlow/LightRAG provider 协议） | [[enterprise-rag-knowledge-base]] |
| 登录 / JWT / OIDC / PAT / CSRF / 内部令牌 | [[auth]] |
| 工具授权 / 护栏 / PII 脱敏 / 注入防御 | [[safety-and-guardrails]] |
| 多用户数据隔离 / 身份归一 / 密钥上下文 | [[multi-user-isolation]] |
| 配置中心 / 热重载 / 跨进程缓存失效 | [[config-and-hot-reload]] |
| Tracing / run 日志 / 事件存储 | [[observability-tracing]] |
| Gateway 装配 / threads-runs API / SSE 格式化 | [[gateway-runs-and-sse]] |
| IM 渠道接入（飞书/Slack/TG/Discord/钉钉/企微/QQ/GitHub…） | [[im-channels]] |
| 定时任务 / cron 计算 / 通知投递 / goal 循环 | [[scheduled-tasks]] |
| Next.js 聊天应用结构 / SSR 鉴权 / composer | [[frontend-app-design]] |
| 前端流式订阅 / SSE 归一化 / 断线重连 | [[frontend-streaming-protocol]] |
| Docker/Nginx/Helm 部署 / 多实例 | [[packaging-and-deployment]] |
| 框架-应用边界 / 嵌入式客户端 / TUI | [[core-app-boundary]] |
| run 取消 / 心跳租约 / 检查点恢复 / StreamBridge | [[long-running-and-cancellation]] |
| 扩展插件（贡献中间件/工具/路由/模型工具/Agent 编排） | [[extension-plugin-system]] |
| SQL 持久层 / 18 域仓库 / Alembic 引导 | [[persistence-layer]] |
| 模型工厂 / 推理契约 / 多 provider 兼容补丁 | [[model-provider-factory]] |
| 上传安全 / 工作区变更追踪 / 项目文档 / blob 存储 | [[workspace-and-projects]] |
| 联网搜索工具集成 / URL 安全 | [[web-search-integrations]] |

## 域簇速览

- **A 运行时核心**（e2e/图工厂/中间件/提示词/状态/上下文）：改这些先读 [[e2e-request-lifecycle]] 定位自己在链路哪一步
- **B 工具与执行**（工具装配/沙箱×2）：一切"agent 能动手"的能力
- **C 多代理与外部能力**（子代理/MCP/技能/记忆/检索）
- **D 平台边界**（认证/护栏/隔离/配置/观测）：谁能用、用什么、怎么观测
- **E 服务化**（网关/IM/定时）：HTTP 面、IM 面、时间面
- **F 前端**（应用结构/流式协议）
- **G 交付**（部署/边界/扩展/持久层/模型/工作区/搜索）

## 实现索引

| 文件 | 行数 | 说明 |
|---|---|---|
| `references/code/docs/ARCHITECTURE.md` | 197 | 顶层架构总览：服务拓扑/分层/横切子系统/安全模型 |
| `references/code/docs-backend/ARCHITECTURE.md` | 504 | 后端深度：组件清单/装配链/测试策略 |

从任一 skill 进入后，其"实现索引"段给出该域全部源码文件（真实路径 + 行数），源码逐字复制于 `references/code/`。

## 进一步阅读

- 全部约定（匿名化映射表、逐字复制铁律、骨架）见插件根 `CONVENTIONS.md`
- 建议阅读顺序：本 skill → [[e2e-request-lifecycle]] → 按需进入领域 skill
