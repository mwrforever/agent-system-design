# Implementation Notes — using-agent-system-design

> 元 skill 本身不含实现，只承担"路由表"职责。本文档把决策、术语、调用方式、
> 反模式、跨切原则全部收齐，让上游 agent 在 30 秒内挑出最多 3 个领域 skill 激活。
> 共 22 个领域 skill 在簇 A~F 内分布；本文档 = 簇 G 的入口节点。

---

## 1. 何时该激活：每个领域 skill 的"触发词 + 否定词"决策树

> 使用约定：
> - **触发词**：用户原话或上下文里出现这些，就考虑该 skill；多个匹配选 1-3 个最相关的。
> - **否定词**：出现这些应"反向激活"，避免误读。

### 簇 A · 图与状态（基础骨架）

```
agent-graph-factory
  触发：从零搭、再写一个 agent、新增一种 agent 类型、注册新 graph、
        组合 node/edge、graph 工厂、agent 模板
  否定：已经有 graph 只想改一个节点 → 直接看 middleware-chain-design
  常见伙伴：thread-state-and-reducers、middleware-chain-design、system-prompt-template

thread-state-and-reducers
  触发：状态字段、reducer、消息合并、token 累计、字段冲突、
        per-session 数据、并发更新、append vs replace
  否定：只是想加横切日志 → middleware-chain-design

middleware-chain-design
  触发：中间件、横切、拦截、before/after hook、安全检查注入、
        给现有 agent 加功能（限流 / 改写 / 上下文截断 / 审计）
  否定：要拆图或加新节点 → agent-graph-factory
  常见伙伴：safety-and-guardrails、context-window-management、observability-tracing

system-prompt-template
  触发：system prompt、prefix cache、提示词版本、提示词 A/B、
        把变化内容塞进 user 而不是 system、<system-reminder>
  否定：动态参数渲染（如 RAG 注入）→ context-window-management
```

### 簇 B · 工具与沙箱（执行面）

```
tool-assembly-and-policy
  触发：工具注册、tool gating、按 skill 暴露工具、按权限暴露工具、
        工具描述、参数 schema、tool denylist
  否定：执行环境本身 → sandbox-abstraction

sandbox-abstraction
  触发：本地 / Docker / K8s 切换、虚拟路径 /mnt/...、provisioner、
        会话级沙箱生命周期、镜像选择
  否定：单个工具的安全配额 → sandbox-tools-and-safety

sandbox-tools-and-safety
  触发：危险命令拦截、文件白名单、网络隔离、超时与资源限额、
        shell 注入防护、文件 IO 审计
  否定：跨多用户的隔离 → multi-user-isolation
```

### 簇 C · 上下文与记忆

```
context-window-management
  触发：token 爆、上下文压缩、消息裁剪、滑窗、L0/L1/L2 注入、
        prefix cache 友好、动态注入
  否定：跨会话长期记忆 → memory-system-design

memory-system-design
  触发：长期记忆、跨会话、热度、updated_at、衰减、忘记、记住、
        per-user note、记忆生命周期
  否定：检索召回质量 → enterprise-rag-knowledge-base

skill-system-design
  触发：SKILL.md 协议、prompt-only 能力包、skill 发现、skill 元数据、
        skill 加载顺序、bundle vs file skill
  否定：把 skill 暴露为工具 → tool-assembly-and-policy
```

### 簇 D · 多代理与运行控制

```
subagent-delegation
  触发：task()、子 agent、并行任务、fan-out / fan-in、
        子代理状态上报、子代理协议
  常见伙伴：observability-tracing、long-running-and-cancellation

long-running-and-cancellation
  触发：取消、中止、断流重连、resume、超时、后台任务、
        SSE 断开恢复、heartbeat
  常见伙伴：gateway-runs-and-sse、frontend-streaming-protocol

gateway-runs-and-sse
  触发：HTTP 网关、SSE、流式输出、run id、event 协议、
        LangGraph 兼容路由
  否定：前端如何消费流 → frontend-streaming-protocol

frontend-streaming-protocol
  触发：前端 SSE 消费、增量渲染、UI 协议、消息类型、
        前端断线重连
  否定：协议生产者 → gateway-runs-and-sse
```

### 簇 E · 多用户、配置、部署

```
multi-user-isolation
  触发：多租户、account_id、scope 隔离、按用户配额、
        权限边界、跨用户泄漏
  否定：单进程内的工具沙箱 → sandbox-tools-and-safety

config-and-hot-reload
  触发：配置热更新、不重启刷新、配置签名、配置回滚、
        多文件叠加、env vs file
  常见伙伴：harness-app-boundary

packaging-and-deployment
  触发：发布、镜像、wheel、安装、版本号、CI/CD、
        生产部署、入口脚本

harness-app-boundary
  触发：框架 vs 应用、单向依赖、包边界、CI 守护、
        发布层级、内部 import 规则
```

### 簇 F · 安全 / 可观测 / 集成

```
safety-and-guardrails
  触发：内容审核、越权调用、危险工具、注入攻击、
        输入审查、输出审查、PII

observability-tracing
  触发：trace、span、阶段计时、token usage、
        Prometheus、监控、慢查询排查
  常见伙伴：subagent-delegation、long-running-and-cancellation

mcp-integration
  触发：MCP、Model Context Protocol、第三方工具服务、
        外部 MCP server 接入
```

### 簇 G · RAG + 元

```
enterprise-rag-knowledge-base
  触发：检索增强、向量库、dense+sparse、rerank、RRF、
        层级检索、L0/L1/L2、热度、召回质量、知识库
  常见伙伴：memory-system-design、tool-assembly-and-policy、observability-tracing

using-agent-system-design  (本)
  触发：不知道该用哪个 skill、整体架构、术语对照、
        路由表、新人入门
```

---

## 2. 跨切设计原则（4 条 + 反例）

1. **单图 + 中间件链**
   所有 agent 行为收敛到一个图 + 一条可插拔中间件链。新需求 = 新中间件，**不另起图**。
   反例：每加一种横切就新建一个 graph 类，导致 10 个 graph 同 90% 重叠节点。

2. **静态主提示 + 动态注入**
   System prompt 整段稳定（吃 prefix cache），每 turn 变化的内容通过 `<system-reminder>`
   塞进第一条 HumanMessage 之前。
   反例：把 RAG 检索结果直接拼到 system prompt，prefix cache 失效，首 token 延迟 ×N。

3. **虚拟路径契约**
   模型只看到 `/mnt/user-data/...`、`/mnt/skills/...` 这类抽象路径；
   本地 / Docker / K8s 各自映射到物理路径。
   反例：prompt 里写绝对路径 `C:/Users/...`，跨平台直接报"找不到文件"。

4. **框架 / 应用单向依赖**
   可发布的"agent 框架"层与"应用 / 网关"层分包；框架不依赖应用，CI 强制守护。
   反例：框架内 `from <app-layer> import ...`，发包后变成循环 import 死亡。

---

## 3. 路由决策树（按问题类型）

```
用户问题：
├─ 要"从零搭" agent 系统
│   → agent-graph-factory + thread-state-and-reducers
│     + middleware-chain-design + system-prompt-template
│     + tool-assembly-and-policy
├─ 已有 agent，要加横切关注点
│   → middleware-chain-design + 具体 skill
│     （safety-and-guardrails / context-window-management / observability-tracing）
├─ 上下文 / token 问题
│   → context-window-management + system-prompt-template + memory-system-design
├─ 工具 / 沙箱
│   → tool-assembly-and-policy + sandbox-abstraction + sandbox-tools-and-safety
├─ 多代理 / 并行子任务
│   → subagent-delegation + observability-tracing + long-running-and-cancellation
├─ 长任务 / 断流重连 / 取消
│   → long-running-and-cancellation + gateway-runs-and-sse + frontend-streaming-protocol
├─ 多用户 / 隔离 / 认证
│   → multi-user-isolation + gateway-runs-and-sse
├─ 配置 / 部署
│   → config-and-hot-reload + packaging-and-deployment + harness-app-boundary
├─ 可观测性 / Tracing
│   → observability-tracing
├─ Skill / MCP / Memory
│   → skill-system-design / mcp-integration / memory-system-design
└─ RAG 知识库 / 召回质量 / 层级检索
    → enterprise-rag-knowledge-base + memory-system-design + tool-assembly-and-policy
```

---

## 4. 术语对照表（统一通用命名，避免绑定具体项目）

| 通用术语 | 同义 / 别名 | 备注 |
|---------|-------------|------|
| Agent 框架 | LangGraph-based agent runtime / harness | 与应用层分包 |
| ThreadState | per-session 图状态 / SessionState | reducer 合并字段 |
| 中间件链 | middleware pipeline / interceptor chain | 横切关注点都走这里 |
| 沙箱 | sandbox / execution environment | 本地 / Docker / K8s 三态 |
| Skill | SKILL.md 协议的 prompt-only 能力包 | 不是工具，是"激活手册" |
| Subagent | 通过 `task()` 委派的子图 | 输入输出独立 |
| Memory | 跨会话用户记忆 | 与 ThreadState 区分 |
| MCP | Model Context Protocol（Anthropic） | 标准第三方工具协议 |
| RAG 知识库 | 检索增强系统 | 与 Memory 区分 |
| L0 / L1 / L2 | abstract / overview / detail | 三层信息粒度 |
| 双向量 / Hybrid | dense + sparse | 用 RRF 融合 |
| Dense 向量 | 稠密向量 / cosine 向量 | 语义近邻 |
| Sparse 向量 | 学习型稀疏 / 类 SPLADE | **不是** BM25 倒排 |
| RRF | Reciprocal Rank Fusion | k=60 标准 |
| Rerank | cross-encoder 重排 | 输入用 abstract |
| Hotness | 热度 / 时间衰减 + 频次 | sigmoid × exp 半衰期 |
| 层级检索 | hierarchical retrieval / 优先级队列检索 | 父分传播 |
| Telemetry | 阶段计时 + 计数 | 与 trace 区分 |
| Trace | 跨 span 的因果链 | 通常包 telemetry |
| Token usage | 模型用量记账 | 全局 singleton |
| Gateway | REST / SSE 网关 | 进程边界 |

---

## 5. 调用方式速记

```
1. 读元 skill（本文 SKILL.md + implementation-notes.md）确认路由
2. 用第 1 节决策树挑 1~3 个领域 skill
3. 用 Skill 工具激活：Skill(skill="<name>")
4. 每个 skill 先读 SKILL.md（设计思想 + 模板 + 反模式）
5. 需要深入实现细节再读 references/implementation-notes.md
6. 按"反模式"段做自查，再开始落地代码
```

挑选数量经验值：

| 任务规模 | 推荐激活数 | 范例 |
|---------|-----------|------|
| 单点修复 | 1 | 改一个 reducer → 只激活 thread-state-and-reducers |
| 中等特性 | 2~3 | 加 RAG 工具 → enterprise-rag + tool-assembly + observability |
| 架构改造 | 3~5 | 从零搭 agent → 簇 A 全 + tool-assembly |
| 不要超过 | 5 | 超过 5 说明任务没拆细 |

---

## 6. 反模式

- ❌ **跳过元 skill 直接凭印象写代码**：踩遍 6 个不变量后才回来。
- ❌ **一次激活全部 22 个领域 skill**：context 浪费 10~20 倍，重点反而被淹没。
- ❌ **把示例代码原样照搬到生产**：未对照该 skill 的"反模式"段做适配。
- ❌ **跨层激活倒置**：先读 implementation-notes 再读 SKILL.md，错过设计意图。
- ❌ **用元 skill 当"教程"逐条读完**：它是路由表不是教学手册；选定后立即跳走。
- ❌ **盲信触发词**：触发词只是入口启发，仍需用"否定词"反向校验。
- ✅ **正确节奏**：路由 → 激活 1~3 个最相关 skill → 按模板照搬骨架 → 按反模式自查 → 写代码。

---

## 7. 元 skill 不变量

1. **本文档不引用任何具体项目路径 / 包名 / 商号**：保持可移植。
2. **领域 skill 列表是单一事实源**：每个 skill 在簇 A~G 内必须**有且仅有一席**；
   新增 skill 时先扩展决策树和术语表再发布。
3. **触发词描述用户视角，不用实现细节**：避免用户拿着实现关键字才能匹配。
4. **决策树最多 3 层**：再深说明簇切分不合理，应拆新簇。

---

## 相关 skill

- [[agent-graph-factory]] 簇 A 的起点：图与节点工厂
- [[middleware-chain-design]] 簇 A 的"加新行为"入口
- [[tool-assembly-and-policy]] 簇 B 的工具注册与门控
- [[enterprise-rag-knowledge-base]] 簇 G 的同伴：检索内核
- [[observability-tracing]] 跨簇通用：trace / telemetry / stats
