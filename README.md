# Agent System Skills Marketplace

一个多平台 Agent 技能市场，提供 Agent 系统与 RAG 知识库的设计模式技能集，同时支持 **Claude Code / Codex / opencode** 三个运行时。

## 安装方式

### Claude Code

```bash
# 添加本市场（开发期，本地路径）
/plugin marketplace add <path-to-this-marketplace-dir>

# 安装其中的插件
/plugin install agent-system-skills@agent-system-skills

# 重新加载
/reload-plugins
```

### Codex

本仓库根目录的 `.claude-plugin/marketplace.json` 与插件目录内的 `.codex-plugin/plugin.json` 均被 Codex 原生识别（发现优先级 `.codex-plugin` > `.claude-plugin`）。本地或远程安装：

```bash
# 添加市场（本地路径 / owner/repo / Git URL 均可）
codex plugin marketplace add <path-to-this-repo>
codex plugin marketplace add mwrforever/agent-system-design

# 安装插件
codex plugin add agent-system-skills@agent-system-skills

# 验证：codex plugin list 中 STATUS 应为 installed, enabled
```

安装后技能以 `agent-system-skills:<技能名>` 命名空间暴露（如 `agent-system-skills:auth`）。

### opencode

仓库根目录自带 `opencode.json`（声明 `skills.paths` 指向技能目录），在仓库内运行 opencode 即自动加载全部技能。全局安装（任意目录可用）：

```bash
# Windows（PowerShell 5.1+，UTF-8 BOM 编码）
.\scripts\install-opencode.ps1

# macOS / Linux
./scripts/install-opencode.sh
```

脚本将技能目录合并进 `~/.config/opencode/opencode.json` 的 `skills.paths`（幂等可重复执行），完成后**重启 opencode** 生效。验证：`opencode debug skill` 中应出现 28 个技能，location 指向本仓库 `plugins/agent-system-skills/skills/`。

> 注意：若 `~/.config/opencode/skills/` 下已手动安装过同名旧副本，opencode 会以全局副本为准（同名去重）。建议删除旧副本或保持两边同步。

## 包含的插件

### `agent-system-skills` (v1.2.0)

28 个 skill：

- **入口（元 skill + 端到端脊柱）**：
  - `using-agent-system-design` — 告诉 AI **何时该调用哪个领域 skill**
  - `e2e-request-lifecycle` — 端到端请求全链路脊柱（入站 → 认证 → 建图 → 中间件 → 执行 → 流式 → 渲染）
- **领域 skill ×22**，分 7 簇（A–G）：
  - **A. 运行时与上下文 (5)**：`agent-graph-factory`、`thread-state-and-reducers`、`middleware-chain-design`、`system-prompt-template`、`context-window-management`
  - **B. 工具与执行 (3)**：`tool-assembly-and-policy`、`sandbox-abstraction`、`sandbox-tools-and-safety`
  - **C. 多代理与长任务 (3)**：`subagent-delegation`、`long-running-and-cancellation`、`safety-and-guardrails`
  - **D. 用户态系统 (3)**：`skill-system-design`、`memory-system-design`、`mcp-integration`
  - **E. 服务化与前端 (4)**：`gateway-runs-and-sse`、`frontend-streaming-protocol`、`multi-user-isolation`、`config-and-hot-reload`
  - **F. 跨切 (3)**：`observability-tracing`、`core-app-boundary`、`packaging-and-deployment`
  - **G. 知识库基础设施 (1)**：`enterprise-rag-knowledge-base`
- **平台维度 ×4（H 簇）**：`auth`（认证）、`scheduled-tasks`（定时任务）、`im-channels`（IM 渠道，含钉钉）、`frontend-app-design`（前端应用）

## 使用约定

- Claude Code 会扫描 `plugins/agent-system-skills/skills/*/SKILL.md` 注册技能；Codex 通过插件清单的 `skills: "./skills"` 声明注册；opencode 通过 `skills.paths` 扫描注册。
- 当用户提到「设计 agent 系统 / 中间件链 / 沙箱 / RAG …」时，AI **必须先调用** `using-agent-system-design`，再按指引激活具体领域 skill。
- 每个 SKILL.md 保持轻量（100-300 行）：设计思想 + 实现模板 + 反模式 + 落地参考索引；额外的长材料放在该 skill 自己的 `references/` 子目录中。

## 目录结构

```
md/skills/
├── .claude-plugin/marketplace.json     # 市场元数据（Claude Code / Codex 通用）
├── opencode.json                        # opencode 项目级 skills.paths 声明
├── README.md                            # 本文件
├── scripts/
│   ├── install-opencode.ps1             # opencode 全局安装脚本（Windows）
│   └── install-opencode.sh              # opencode 全局安装脚本（macOS / Linux）
└── plugins/
    └── agent-system-skills/
        ├── .codex-plugin/plugin.json    # Codex 插件清单（显式声明 skills 路径）
        ├── .claude-plugin/plugin.json   # Claude Code 插件元数据
        ├── CONVENTIONS.md               # 共享约定：中立结构 + 匿名化映射 + skill 骨架
        ├── README.md                    # 插件说明 + 完整 skill 索引
        └── skills/
            ├── using-agent-system-design/
            │   ├── SKILL.md             # 元 skill
            │   └── references/          # 路由表扩展、术语表等
            └── <其余 skill 目录>/
                ├── SKILL.md
                └── references/          # 详细落地代码、参数清单、外部链接
```

## SKILL.md 体例

每个 SKILL.md 遵守：
- ≤ 300 行；超长内容拆到同目录 `references/<topic>.md`，由 SKILL.md 索引引用
- 6 个固定段：何时用 / 设计思想 / 实现模板 / 反模式 / 落地参考 / 进一步阅读
- 代码示例使用通用栈（Python + LangGraph + TypeScript），不引用任何具体项目内文件路径
