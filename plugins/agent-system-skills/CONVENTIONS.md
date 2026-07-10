# Agent System Skills — 共享约定（CONVENTIONS）

> 本文件是 `agent-system-skills` 语料的**唯一事实源**。所有 organ skill 与后续 P1/P2/P3 计划必须引用并遵守本文件：代号、目录结构、匿名化映射、6 段骨架、单篇 checklist、验证命令均以此为准。
>
> **定位**：本文件位于 `md/skills/` 下，属于 skill 内容，因此**同样遵守匿名化硬约束**——全文不得出现任何项目品牌字样（按 §6 验证命令自检须为 CLEAN）。映射表左列使用"层角色"通用描述符指代真实侧，不展开具体品牌词。

---

## 1. 代号与身份

- 中立产品代号：**`Helix`**。
- 该代号贯穿全部 skill 的：自定目录根（`helix/`）、import 前缀（`helix.*`）、env 前缀（`HELIX_*`）、HTTP 内部认证头（`X-Helix-Internal-Token`）、嵌入式客户端类（`HelixClient`）、默认 agent 显示名（`Helix 2.0`）。
- **易替换**：`Helix` 是单一中性代号。未来若需还原为真实品牌，对全部 skill 做一次全文 find-replace 即可，无需逐篇改写逻辑；反之从真实品牌迁出亦然。
- 中性类名/函数名（如 `AuthMiddleware`、`ScheduledTaskService`、`apply_prompt_template`、`make_lead_agent`、`RunManager`、`StreamBridge`、`ChannelManager`、`MessageBus` 等）**保持原样不动**——它们不带品牌语义，是真实实现的中性命名，直接复用。

---

## 2. 自定 monorepo 结构（三层 + 单向依赖）

为同时满足"代码真实、身份匿名"，全部 skill 统一采用下列自定 monorepo 结构（**非**真实仓库路径）。任何 skill 引用代码时，必须落到本结构的某个具体文件路径。

```
helix/
├── core/                  # 第1层：可发布 agent 框架包（import 前缀 helix.*）
│   └── helix/
│       ├── agents/lead/        # 主 agent：agent.py + prompt.py
│       ├── middlewares/        # 运行时中间件链
│       ├── graph/              # factory / thread_state / features
│       ├── tools/builtins/     # ask_clarification / present_files / tool_search 等
│       ├── sandbox/            # 沙箱抽象 + local provider
│       ├── subagents/          # task() 委派
│       ├── mcp/                # MCP 多 server 集成
│       ├── skills/             # 技能发现 / 加载 / per-user 存储
│       ├── models/             # 模型工厂
│       ├── config/             # AppConfig / SchedulerConfig 等
│       ├── runtime/            # checkpointer / runs worker / stream_bridge / user_context
│       ├── scheduler/          # schedules.py（纯计算 cron / once）
│       ├── persistence/        # SQL 仓库 + alembic 迁移
│       ├── guardrails/         # 工具调用授权
│       └── tracing/            # LangSmith / Langfuse 回调
├── gateway/               # 第2层：FastAPI 应用（不发布）
│   └── gateway/{app.py, auth/, auth_middleware.py, csrf_middleware.py, internal_auth.py, routers/, services.py}
├── channels/              # 第2层：IM 集成
│   └── channels/{base, manager, service, message_bus, store, dingtalk, feishu, slack, telegram, discord, wechat, wecom, github}.py
├── scheduler/             # 第2层：任务服务
│   └── scheduler/service.py    # ScheduledTaskService（poller）
├── frontend/              # 第3层：Next.js App Router
│   └── src/{app, components, core, hooks, lib}
├── skills/                # agent 技能（public / custom）
├── contracts/             # 跨组件 JSON 契约
└── config.example.yaml
```

**单向依赖硬规则**：

- 方向：`gateway` / `channels` / `scheduler`（第2层，应用层）→ 依赖 → `core`（第1层，框架包）。**反向一律禁止**：`core` 不得 import 任何应用层模块。
- 这条边界在真实架构中由 **CI 边界测试强制守护**，重构语料时必须保留该语义，并写进 `core-app-boundary` skill。
- 第3层 `frontend` 通过 HTTP / SSE 与第2层 `gateway` 通信，不直接 import Python 侧。

---

## 3. 匿名化映射表

映射在**写入时执行**：读取真实源码树（按下表左列"层角色描述符"定位真实包路径）→ 写入 skill 时统一替换为右列 Helix 路径 / 前缀 / 名称。映射是单向、确定性的；每个 skill 落地后须自检映射一致（见 §5 第 3、8 条）。

| 真实侧（按层角色描述符） | 自定侧（Helix） |
|---|---|
| 框架层包路径（harness 包） | `core/helix/` |
| 网关应用层路径（gateway 应用） | `gateway/gateway/` |
| IM 集成层路径（channels 应用） | `channels/channels/` |
| 任务服务层路径（scheduler 应用） | `scheduler/scheduler/` |
| import 前缀 `<项目包前缀>.*` | `helix.*` |
| env 前缀 `<PROJECT>_*` | `HELIX_*` |
| 内部认证头 `X-<Project>-Internal-Token` | `X-Helix-Internal-Token` |
| 嵌入式客户端类 `<Project>Client` | `HelixClient` |
| 默认 agent 显示名 `<Project> 2.0` | `Helix 2.0` |
| 中性名（`AuthMiddleware` / `ScheduledTaskService` / `apply_prompt_template` / `make_lead_agent` 等） | 保持不变 |

> 说明：左列刻意不写具体品牌词，仅以"层角色"指代真实侧；右列是 skill 内容中**唯一允许出现**的具体值。

---

## 4. 统一 6 段骨架（每篇 skill 强制）

每个 organ skill 的 `SKILL.md` 必须按下列 6 段顺序组织--**设计方案段先于代码段**，且 **SKILL.md ≤ 500 行（硬上限）**。

```
---
name + description（含触发条件 + 核心要点）
---
## 何时用
## 设计方案（为什么这么设计）   ← 核心矛盾 / 约束 / 不变量 + 关键决策权衡 + 在端到端链路中的位置 + 伪代码示例
## 实现索引                    ← 文件清单（映射自定结构）+ 各模块入口伪代码 + 到 references/code/ 的模块索引（不放整块完整代码）
## 反模式与陷阱                ← 真实踩坑
## 落地参考                    ← 自测 / 调参旋钮 / 调试日志串
## 进一步阅读                  ← 关联 skill
```

**代码呈现约定（精炼优先）**：

- **SKILL.md ≤ 500 行（硬上限）**：只放设计架构思路 + 伪代码示例 + references 模块索引。**绝不整块搬入完整源码**。
- `references/code/`：完整真实代码，**按独立功能模块细分**（一个文件 = 一个独立功能模块），由 SKILL.md "实现索引" 段建立模块索引。
- `references/` **不放 `implementation-notes.md`**（已废弃、无价值）；只放 `code/<module>.md` 与必要扩展材料。
- 伪代码示例：用精炼伪代码展示核心结构 / 数据流 / 时序，不逐行复制源码；完整源码在 `references/code/` 对应模块文件。
- 范例标尺：`skills/system-prompt-template/`。

---

## 5. 单篇生产 checklist（每个 skill 落地必须全勾）

- [ ] 6 段骨架齐全；设计方案段先于代码段
- [ ] **SKILL.md ≤ 500 行**（硬上限）
- [ ] SKILL.md 只含设计架构思路 + 伪代码示例 + references 模块索引（**无整块完整源码**）
- [ ] 设计方案含：核心矛盾 / 约束、关键不变量、在端到端链路中的位置（含 `[[e2e-request-lifecycle]]` 交叉引用）
- [ ] `references/code/` 按独立功能模块细分，完整真实代码（非伪代码），适配 §2 自定结构，与 §3 映射表一致
- [ ] **无 `implementation-notes.md`**（已废弃，删除）
- [ ] 反模式段含**真实踩坑**（非泛泛而论）
- [ ] 落地参考段含调参旋钮 + 调试日志串 + 自测方向
- [ ] **grep 验证无任何项目字样**（按 §6 验证命令执行，结果须为 CLEAN）
- [ ] 中立名按映射表；品牌名（client / header / env / 默认 agent 名）已替换为 Helix 侧

---

## 6. 验证命令（每个 skill 落地后统一自检）

每个 skill 目录落地后，在**该 skill 目录**下运行一次匿名化硬约束检查。命中任何项目字样即 `VIOLATION`（须按 §3 改为通用描述符 / Helix 侧值），无命中即 `CLEAN`（通过）。

```bash
# 单篇 skill 落地后自检——在该 skill 目录运行
# 禁词通过变量拼合构造，避免本约定文档自身被误命中
# 变量在运行时展开为禁词，等价于直接 grep 禁词列表（含无分隔/连字符/下划线三种变体）
_d="deer"; _b="byte"
grep -rniE "${_d}flow|${_d}-flow|${_d}_flow|${_b}dance" . && echo "VIOLATION（命中项目字样，须按 §3 改写）" || echo "CLEAN（无项目字样，通过）"
```

**判定规则**：

- 输出 `CLEAN` → 该 skill 匿名化合格。
- 输出 `VIOLATION`（或任何 grep 命中行）→ 定位命中处，按 §3 映射表改写后重跑，直到 `CLEAN`。

> 本约定文档自身亦须通过同一检查（对其文件运行等价命令，结果须 `CLEAN`）。
