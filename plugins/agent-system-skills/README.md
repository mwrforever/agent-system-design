# Agent System Skills

生产级 super-agent 平台的设计模式技能集：**33 个 skill + 988 个逐字复制的源码文件（约 26.2 万行）**，完整复刻一套多用户 Agent 平台的全部能力面（图工厂 / 中间件链 / 沙箱 / 技能 / 子代理 / 记忆 / MCP / 网关 / IM / 调度 / 扩展插件 / 持久层 / 模型工厂 / 前端 / 部署），仅做品牌词机械匿名化（见 [`CONVENTIONS.md`](CONVENTIONS.md)）。

## Skill 总览（33 个）

### 🧭 入口（元路由 + 端到端脊柱）

| Skill | 何时调用 |
|-------|----------|
| **using-agent-system-design** | 用户说"设计/实现/重构 agent 系统/中间件/沙箱/MCP/SSE 流/RAG ..."时**首先**调用，由它路由到具体领域 skill |
| **e2e-request-lifecycle** | 把「入口 → 认证 → 路由 → run 编排 → 执行 → SSE → 前端」端到端串起来；其余 skill 以它为脊柱挂载点 |

### A. Agent 运行时与上下文（5）

| Skill | 一句话核心 |
|-------|-----------|
| **agent-graph-factory** | 每 run 重建图；configurable × context 双通道；tracing 挂图根不变量；SDK 工厂 + RuntimeFeatures |
| **middleware-chain-design** | 三层装配（wrap_model_call 外层清洗 → 线程钩子 → 追尾链）；Clarification 永远殿后；49 个中间件源码 |
| **system-prompt-template** | 全静态模板吃 prefix cache；动态内容走 system-reminder；三层技能缓存；不可信内容转义 |
| **thread-state-and-reducers** | 18 通道 + 11 个语义化 reducer；DeltaThreadState 双模式检查点；检查点受控变更 |
| **context-window-management** | 工具输出落盘换预览 / 会话摘要 / run 级预算三档，分层兜底 |

### B. 工具与执行（3）

| Skill | 一句话核心 |
|-------|-----------|
| **tool-assembly-and-policy** | 六源合并 + config 优先去重；use: 反射；延迟工具目录 + catalog 一致性 |
| **sandbox-abstraction** | Provider/Sandbox 双 ABC；虚拟路径映射；租约与串行化；本地 + 生产 provider |
| **sandbox-tools-and-safety** | 3144 行工具实现：词法级 bash 路径校验 + 输出掩码 + 有界捕获 |

### C. 多代理与长任务（2）

| Skill | 一句话核心 |
|-------|-----------|
| **subagent-delegation** | 隔离事件循环执行器；FIFO 容量；双 ID 铁律；确定性验收核验；持久批处理 |
| **long-running-and-cancellation** | RunManager 原子注册/租约/孤儿回收；worker 取消围栏与回滚；StreamBridge 重连；full/delta 检查点 |

### D. 用户态系统（3）

| Skill | 一句话核心 |
|-------|-----------|
| **skill-system-design** | 三级存储 + 投影原子换目录 + 安装三道门 + 运行时 allowed-tools + 评审四件套 |
| **memory-system-design** | Markdown 主后端 + 多后端适配；信号采集 + 预筛；队列式异步写；owner 隔离 |
| **mcp-integration** | 会话池 + 指纹增量对账；stdio 工作区隔离；个人 MCP 网络过滤；MCP 长任务租赁 |

### E. 平台边界（5）

| Skill | 一句话核心 |
|-------|-----------|
| **auth** | 账密/OIDC/PAT/JWT 四凭证 + 节流 + CSRF Double Submit + 内部令牌 |
| **safety-and-guardrails** | 三层授权共享 Principal；deny 转 ToolMessage；fail_closed；PII/注入/写前读 |
| **multi-user-isolation** | 身份三源归一 + Paths 校验分桶 + 密钥上下文 + 来源标记 |
| **config-and-hot-reload** | 内容签名惰性热重载 + 重启边界声明 + 跨副本失效标记 + 双信任级配置文件 |
| **observability-tracing** | 挂图根不挂模型；RunJournal；冻结事件目录 + 三后端存储 + seq 严格递增 |

### F. 服务化（3）

| Skill | 一句话核心 |
|-------|-----------|
| **gateway-runs-and-sse** | app/deps/services 三层装配；threads/runs 全端点；SSE 格式化 + 事件流契约 |
| **im-channels** | Channel 抽象 + 确认式总线 + 忙线合并 + leader 租约 + 10 平台实现全文 |
| **scheduled-tasks** | 纯计算（cron/once/interval + DST）+ 轮询器 + 单活跃约束 + goal 循环 + 通知 outbox |

### G. 前端（2）

| Skill | 一句话核心 |
|-------|-----------|
| **frontend-app-design** | App Router 全路由 + SSR exhaustive 守卫 + core 领域层 + 3778 行 composer |
| **frontend-streaming-protocol** | SDK 单例三补丁 + useThreadStream 归一化 + gap 恢复 + 顺序账本 |

### H. 交付与基础设施（8）

| Skill | 一句话核心 |
|-------|-----------|
| **packaging-and-deployment** | loopback 默认拓扑 + nginx SSE 三段配置 + Helm + provisioner + 多实例四件套 |
| **core-app-boundary** | harness/app 边界 CI 强制 + HelixClient 嵌入式客户端 + Textual TUI |
| **extension-plugin-system** | 零依赖契约包 + 宿主管理器/锚点排序/隔离 + 9 个官方扩展示例 |
| **persistence-layer** | Alembic 三态引导 + advisory lock + 跨方言 JSON 过滤 + 18 域仓库 |
| **model-provider-factory** | 档案驱动工厂 + 推理契约 + 9 家 provider 兼容层 + 凭据/限速 |
| **workspace-and-projects** | O_NOFOLLOW 上传 + 快照 diff 变更追踪 + sha256 文档架 + blob 抽象 |
| **web-search-integrations** | 17+ 家搜索统一范式 + provider_credentials + url_safety SSRF 防线 |
| **enterprise-rag-knowledge-base** | RetrievalProvider 协议 + 能力协商 + scope 三模式 + 引用信封（检索内核外置） |

## 安装

本插件同时适配五个运行时，清单见仓库根 README；各平台任选其一：

| 运行时 | 安装入口 |
|--------|----------|
| zcode | Settings → Plugin Management → Discover → `+` 添加本仓库后安装（清单：`.zcode-plugin/plugin.json`） |
| Claude Code | `/plugin marketplace add <仓库路径>` → `/plugin install agent-system-skills@agent-system-skills` |
| Codex | `codex plugin marketplace add mwrforever/agent-system-design` → `codex plugin add agent-system-skills@agent-system-skills` |
| Kimi Code | `/plugins install https://github.com/mwrforever/agent-system-design/tree/main/plugins/agent-system-skills`（清单：`kimi.plugin.json`） |
| opencode | 仓库内运行自动加载，或执行根目录 `scripts/install-opencode.*` 全局安装 |

## 使用规则

1. 当任务涉及 agent 系统设计/实现/重构时，**首先**调用 `using-agent-system-design`。
2. 元 skill 会告诉你「这个任务该看哪几个领域 skill」。
3. 每个领域 skill 自带：**设计方案（源码可佐证）+ 实现索引 + 反模式与陷阱 + 落地参考**（统一骨架见 [`CONVENTIONS.md`](CONVENTIONS.md) §5）。

## SKILL.md 体例与 references 铁律

每个 SKILL.md 遵守（详见 [`CONVENTIONS.md`](CONVENTIONS.md)）：

- **≤ 500 行硬上限**；6 个固定段：何时用 / 设计方案（为什么这么设计）/ 实现索引 / 反模式与陷阱 / 落地参考 / 进一步阅读
- **references/code/ 为逐字复制的真实源码**（约 26.2 万行），仅按品牌词映射表机械替换；路径即真实仓库相对路径（替换后），禁止人工转述/删减/增补
- 设计方案只断言源码可佐证的事实（函数名/常量/顺序以源码为准）
- 匿名化硬约束：全部内容不出现任何源项目品牌字样（§7 验证命令须 CLEAN）
