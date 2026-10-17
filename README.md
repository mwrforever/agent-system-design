# Agent System Skills Marketplace

一个多平台 Agent 技能市场，提供生产级 Agent 系统的设计模式技能集，同时支持 **zcode / Claude Code / Codex / Kimi Code / opencode** 五个运行时。

## 安装方式

### zcode

zcode 原生兼容本仓库的市场与插件清单（清单探测优先级 `.zcode-plugin` > `.claude-plugin` > `.codex-plugin`）：

- **方式一（市场安装，推荐）**：打开 zcode 的 **Settings → Plugin Management → Discover**，点 **`+`** 添加本仓库（本地路径 / GitHub 仓库 `mwrforever/agent-system-design` / Git URL 均可），然后安装其中的 `agent-system-skills` 插件。
- **方式二（本地直装）**：在 Discover 的 `+` 中直接指向 `plugins/agent-system-skills` 目录（内含首选清单 `.zcode-plugin/plugin.json`）。

安装后默认启用，在 **Settings → Skills** 或 `/` 菜单中应能看到 `agent-system-skills:*` 全部 33 个技能。

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

### Kimi Code

插件目录内置 Kimi 首选清单 `kimi.plugin.json`，并在仓库根目录提供自定义市场文件 `kimi-marketplace.json`：

```bash
# 方式一：直接从 GitHub 安装插件（支持 /tree/<ref> 钉住分支、tag 或 commit）
/plugins install https://github.com/mwrforever/agent-system-design/tree/main/plugins/agent-system-skills

# 方式二：添加自定义市场（传 kimi-marketplace.json 的本地路径或 URL），再在 Custom 页安装
/plugins marketplace <path-or-url-to-this-repo>/kimi-marketplace.json
```

安装后在 `/plugins` 中确认插件已启用，执行 `/reload` 或开启新会话生效；技能通过 `/skill:<技能名>` 显式调用或由模型按需自动调用。

### opencode

仓库根目录自带 `opencode.json`（声明 `skills.paths` 指向技能目录），在仓库内运行 opencode 即自动加载全部技能。全局安装（任意目录可用）：

```bash
# Windows（PowerShell 5.1+，UTF-8 BOM 编码）
.\scripts\install-opencode.ps1

# macOS / Linux
./scripts/install-opencode.sh
```

脚本将技能目录合并进 `~/.config/opencode/opencode.json` 的 `skills.paths`（幂等可重复执行），完成后**重启 opencode** 生效。验证：`opencode debug skill` 中应出现 33 个技能，location 指向本仓库 `plugins/agent-system-skills/skills/`。

> 注意：若 `~/.config/opencode/skills/` 下已手动安装过同名旧副本，opencode 会以全局副本为准（同名去重）。建议删除旧副本或保持两边同步。

## 包含的插件

### `agent-system-skills` (v1.3.0)

**33 个 skill**，references 含 **988 个源码文件的逐字复制（约 26.2 万行）**——完整复刻一个生产级 super-agent 平台的全部能力面，仅做品牌词机械匿名化（见 `CONVENTIONS.md`）。

- **入口（元 skill + 端到端脊柱）**：
  - `using-agent-system-design` — 能力地图与路由（何时调用哪个领域 skill）
  - `e2e-request-lifecycle` — 端到端请求全链路（入口 → 认证 → 路由 → run 编排 → 执行 → SSE → 前端）
- **A. 运行时与上下文 (5)**：`agent-graph-factory`、`middleware-chain-design`、`system-prompt-template`、`thread-state-and-reducers`、`context-window-management`
- **B. 工具与执行 (3)**：`tool-assembly-and-policy`、`sandbox-abstraction`、`sandbox-tools-and-safety`
- **C. 多代理与长任务 (2)**：`subagent-delegation`、`long-running-and-cancellation`
- **D. 用户态系统 (3)**：`skill-system-design`、`memory-system-design`、`mcp-integration`
- **E. 平台边界 (5)**：`auth`、`safety-and-guardrails`、`multi-user-isolation`、`config-and-hot-reload`、`observability-tracing`
- **F. 服务化 (3)**：`gateway-runs-and-sse`、`im-channels`（10 平台）、`scheduled-tasks`
- **G. 前端 (2)**：`frontend-app-design`、`frontend-streaming-protocol`
- **H. 交付与基础设施 (8)**：`packaging-and-deployment`、`core-app-boundary`（含嵌入式客户端与 TUI）、`extension-plugin-system`、`persistence-layer`、`model-provider-factory`、`workspace-and-projects`、`web-search-integrations`、`enterprise-rag-knowledge-base`

## 使用约定

- Claude Code 会扫描 `plugins/agent-system-skills/skills/*/SKILL.md` 注册技能；zcode 按 `.zcode-plugin` > `.claude-plugin` > `.codex-plugin` 优先级读取清单；Codex 通过插件清单的 `skills: "./skills"` 声明注册；Kimi Code 通过 `kimi.plugin.json` 的 `skills` 字段注册；opencode 通过 `skills.paths` 扫描注册。
- 当用户提到「设计 agent 系统 / 中间件链 / 沙箱 / RAG …」时，AI **必须先调用** `using-agent-system-design`，再按指引激活具体领域 skill。
- 每个 SKILL.md 保持轻量（100-300 行，硬上限 500）：设计决策（只断言源码可佐证的事实）+ 实现索引 + 反模式 + 落地参考；完整源码逐字复制在各 skill 的 `references/code/` 下（路径即真实仓库相对路径）。

## 目录结构

```
agent-system-design/
├── .claude-plugin/marketplace.json     # 市场元数据（zcode / Claude Code / Codex 通用）
├── kimi-marketplace.json               # Kimi Code 自定义市场文件
├── opencode.json                        # opencode 项目级 skills.paths 声明
├── README.md                            # 本文件
├── scripts/
│   ├── install-opencode.ps1             # opencode 全局安装脚本（Windows）
│   └── install-opencode.sh              # opencode 全局安装脚本（macOS / Linux）
└── plugins/
    └── agent-system-skills/
        ├── .zcode-plugin/plugin.json    # zcode 首选插件清单（探测优先级最高）
        ├── .codex-plugin/plugin.json    # Codex 插件清单（显式声明 skills 路径）
        ├── .claude-plugin/plugin.json   # Claude Code 插件元数据
        ├── kimi.plugin.json             # Kimi Code 首选插件清单
        ├── CONVENTIONS.md               # 共享约定 v2：逐字复制铁律 + 匿名化映射表 + skill 骨架
        ├── README.md                    # 插件说明 + 完整 skill 索引
        └── skills/                      # 33 个 skill
            └── <skill-name>/
                ├── SKILL.md             # 设计决策 + 实现索引（精简）
                └── references/code/     # 真实源码逐字复制（路径 = 仓库相对路径）
```

## SKILL.md 体例

每个 SKILL.md 遵守（详见 `CONVENTIONS.md`）：

- ≤ 500 行硬上限；6 个固定段：何时用 / 设计方案（为什么这么设计）/ 实现索引 / 反模式与陷阱 / 落地参考 / 进一步阅读
- **references 为逐字复制的真实源码**（仅品牌词机械替换），实现索引中的每个路径都真实存在于 `references/code/`
- 设计方案只断言源码可佐证的事实（函数/常量/顺序以源码为准）
