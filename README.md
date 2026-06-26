# Agent System Skills Marketplace

一个 Claude Code 插件市场，提供 Agent 系统与 RAG 知识库的设计模式技能集。

## 安装方式

在 Claude Code 中执行：

```bash
# 添加本市场（开发期，本地路径）
/plugin marketplace add <path-to-this-marketplace-dir>

# 安装其中的插件
/plugin install agent-system-skills@agent-system-skills

# 重新加载
/reload-plugins
```

## 包含的插件

### `agent-system-skills` (v1.1.0)

23 个 skill：

- **入口（元 skill）**：`using-agent-system-design` — 告诉 AI **何时该调用哪个领域 skill**
- **领域 skill ×22**，分 7 簇：
  - **A. 运行时与上下文 (5)**：`agent-graph-factory`、`thread-state-and-reducers`、`middleware-chain-design`、`system-prompt-template`、`context-window-management`
  - **B. 工具与执行 (3)**：`tool-assembly-and-policy`、`sandbox-abstraction`、`sandbox-tools-and-safety`
  - **C. 多代理与长任务 (3)**：`subagent-delegation`、`long-running-and-cancellation`、`safety-and-guardrails`
  - **D. 用户态系统 (3)**：`skill-system-design`、`memory-system-design`、`mcp-integration`
  - **E. 服务化与前端 (4)**：`gateway-runs-and-sse`、`frontend-streaming-protocol`、`multi-user-isolation`、`config-and-hot-reload`
  - **F. 跨切 (3)**：`observability-tracing`、`harness-app-boundary`、`packaging-and-deployment`
  - **G. 知识库基础设施 (1)**：`enterprise-rag-knowledge-base`

## 使用约定

- 安装后，Claude Code 会扫描 `plugins/agent-system-skills/skills/*/SKILL.md` 注册技能。
- 当用户提到「设计 agent 系统 / 中间件链 / 沙箱 / RAG …」时，AI **必须先调用** `using-agent-system-design`，再按指引激活具体领域 skill。
- 每个 SKILL.md 保持轻量（100-300 行）：设计思想 + 实现模板 + 反模式 + 落地参考索引；额外的长材料放在该 skill 自己的 `references/` 子目录中。

## 目录结构

```
md/skills/
├── .claude-plugin/marketplace.json     # 市场元数据
├── README.md                            # 本文件
└── plugins/
    └── agent-system-skills/
        ├── .claude-plugin/plugin.json   # 插件元数据
        ├── README.md                    # 插件说明 + 完整 skill 索引
        └── skills/
            ├── using-agent-system-design/
            │   ├── SKILL.md             # 元 skill
            │   └── references/          # 路由表扩展、术语表等
            └── <22 个领域 skill>/
                ├── SKILL.md
                └── references/          # 详细落地代码、参数清单、外部链接
```

## SKILL.md 体例

每个 SKILL.md 遵守：
- ≤ 300 行；超长内容拆到同目录 `references/<topic>.md`，由 SKILL.md 索引引用
- 6 个固定段：何时用 / 设计思想 / 实现模板 / 反模式 / 落地参考 / 进一步阅读
- 代码示例使用通用栈（Python + LangGraph + TypeScript），不引用任何具体项目内文件路径
