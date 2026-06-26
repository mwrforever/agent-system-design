# Agent System Skills

Agent 系统与 RAG 知识库的设计模式技能集，提炼自生产级 agent 框架实践。

## Skill 总览（23 个）

### 🧭 元 skill（入口路由）

| Skill | 何时调用 |
|-------|----------|
| **using-agent-system-design** | 用户说"设计/实现/重构 agent 系统/中间件/沙箱/MCP/SSE 流/RAG ..."时**首先**调用，由它路由到具体领域 skill |

### A. Agent 运行时与上下文（5）

| Skill | 一句话核心 |
|-------|-----------|
| **agent-graph-factory** | 每个 run 一次性构造图；`configurable` × `context` 双通道协议 |
| **thread-state-and-reducers** | TypedDict 扩展 + 自定义 reducer（幂等写 / 合并去重 / 按 hash 重置） |
| **middleware-chain-design** | base + lead-only 两段；`after_model` 逆序；中断型必须最后 |
| **system-prompt-template** | 静态主提示 + `<system-reminder>` 动态注入，最大化 prefix-cache |
| **context-window-management** | 摘要 / 多 system 合并 / 孤儿 tool_call / 循环检测 / token 预算 |

### B. 工具与执行（3）

| Skill | 一句话核心 |
|-------|-----------|
| **tool-assembly-and-policy** | config + builtin + MCP + subagent 装配；skill 白名单收缩；deferred + `tool_search` |
| **sandbox-abstraction** | 虚拟路径契约 + Provider 抽象 + per-thread LRU 实例 |
| **sandbox-tools-and-safety** | 双向路径翻译 + 按 `(sandbox,path)` 串行锁 + 本地 bash 默认禁用 |

### C. 多代理与长任务（3）

| Skill | 一句话核心 |
|-------|-----------|
| **subagent-delegation** | `task()` 工具 + 双线程池 + 持久 isolated event loop + `tool_call_id=task_id` |
| **long-running-and-cancellation** | 后台 `asyncio.Task` + StreamBridge + `Last-Event-ID` + pre-run checkpoint 回滚 |
| **safety-and-guardrails** | 输入消毒 + Guardrail + safety_finish_reason + loop / token 预算 |

### D. 用户态系统（3）

| Skill | 一句话核心 |
|-------|-----------|
| **skill-system-design** | SKILL.md 协议 + 异步加载缓存 + `/skill` 显式激活 + allowed-tools 白名单 |
| **memory-system-design** | per-user 文件 + debounce 队列 + LLM 抽取 + 原子写 + token 预算 |
| **mcp-integration** | lazy + mtime 缓存 + stdio/SSE/HTTP/OAuth + 路径反向翻译 + deferred promote |

### E. 服务化与前端（4）

| Skill | 一句话核心 |
|-------|-----------|
| **gateway-runs-and-sse** | `RunManager` + `run_agent` worker + `stream_mode` 映射 + checkpointer 协作 |
| **frontend-streaming-protocol** | SSE 事件 schema + LangGraph SDK 单例 + `useThreadStream` reducer + CSRF |
| **multi-user-isolation** | `get_effective_user_id()` + per-user 目录 + 内部 Token + owner 检查 + orphan 迁移 |
| **config-and-hot-reload** | `AppConfig` 签名缓存热重载 + `STARTUP_ONLY_FIELDS` + 反射动态导入 + `$ENV` |

### F. 跨切（3）

| Skill | 一句话核心 |
|-------|-----------|
| **observability-tracing** | Tracing 必须挂在图根；metadata 注入；subagent 归到父 session |
| **harness-app-boundary** | 双层包 + 单向依赖 + CI 守护 + 嵌入式客户端复用同一组件 |
| **packaging-and-deployment** | monorepo + uv + `langgraph.json` + `make dev/start/up` + nginx + alembic 自启 |

### G. 知识库基础设施（1）

| Skill | 一句话核心 |
|-------|-----------|
| **enterprise-rag-knowledge-base** | 文件系统范式 + L0/L1/L2 三层 + 5 层检索内核（query 重写 / 双向量 / RRF 混合 / 重排 / 多因子评分）|

## 安装

```bash
/plugin marketplace add <path-to-this-marketplace-dir>
/plugin install agent-system-skills@agent-system-skills
/reload-plugins
```

## 使用规则

1. 当任务涉及 agent / RAG 设计/实现/重构时，**首先**调用 `using-agent-system-design`。
2. 元 skill 会告诉你「这个任务该看哪几个领域 skill」。
3. 每个领域 skill 自带：**设计思想 + 实现模板 + 反模式 + 落地参考索引**。

## SKILL.md 体例

每个 SKILL.md 遵守：
- ≤ 300 行；超长内容拆到同目录 `references/<topic>.md`，由 SKILL.md 通过相对路径索引
- 6 个固定段：何时用 / 设计思想 / 实现模板 / 反模式 / 落地参考 / 进一步阅读
- 代码用通用栈（Python + LangGraph + TypeScript + Next.js），可复制即跑
- **不引用任何具体项目目录路径**——本插件可独立分发
