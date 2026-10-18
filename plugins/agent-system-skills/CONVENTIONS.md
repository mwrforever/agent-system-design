# Agent System Skills — 共享约定（CONVENTIONS）v2

> 本文件是 `agent-system-skills` 语料的**唯一事实源**。所有 skill 的内容策略、匿名化规则、骨架结构、验证命令均以此为准。
>
> **v2 核心变更**：废弃 v1 的"适配自定结构改写代码"策略。v1 的改写引入了截断、失真与虚构设计（例：知识库 skill 曾描述项目中并不存在的分层检索算法）。v2 起 references 一律**逐字复制真实源码**，仅做品牌词机械替换。

---

## 1. 代号与身份

- 中立产品代号：**`Helix`**。
- 该代号贯穿：包名（`helix`）、import 前缀（`helix.*`）、env 前缀（`HELIX_*`）、记忆后端（`helixmem`）、默认显示名（`Helix`）。
- 中性类名/函数名（如 `AuthMiddleware`、`RunManager`、`StreamBridge`、`apply_prompt_template`、`make_lead_agent`、`ChannelManager`、`MessageBus`）**保持源码原样**——它们不带品牌语义。

## 2. 品牌词机械替换表（唯一允许的内容改动）

所有 references 内容 = 源码原文按本表**确定性替换**后的结果。替换是双向可逆的（还原时逆向 find-replace 即可），除本表外**零改动**。下表用 `＄` 指代源品牌小写词根（本文件自身不得拼出该词根，见 §7 自检）：

| 源词形（`＄` = 品牌词根） | 替换为 | 说明 |
|---|---|---|
| `＄`（小写连写，包名/import 前缀/URL 段） | `helix` | 最常见变体 |
| `＄` 的连字符变体（镜像名/目录/chart 名） | `helix` | 如 `.helix` 数据目录、镜像名 |
| `＄` 的下划线变体 | `helix` | 罕见 |
| `＄mem`（记忆后端目录/模块，小写连写） | `helixmem` | |
| `＄mem` 的下划线变体（记忆模块文件 `＄_mem.py`） | `helix_mem` | |
| `＄MEM`（记忆 env 前缀，如 `＄MEM_DATA_DIR`） | `HELIXMEM` | |
| `＄` 的首字母大写变体（类名 `＄Client`、显示名） | `Helix` | |
| `＄` 的全大写下划线变体（env 前缀 `＄_HOME` 等） | `HELIX` | 两种大写形态均替换 |
| `＄Mem`（记忆类名） | `HelixMem` | |
| 源组织名（GitHub org / 镜像 registry / issue 引用，小写或首字母大写） | `example` / `Example` | |
| `＄.svg`（前端蒙版图片文件名） | `helix.svg` | 资源本体未随语料分发 |

注意：`UnicodeDecodeError` 等异常名在做大小写不敏感检查时会误命中品牌子串，属误报，不属于品牌词。

## 3. 逐字复制铁律

- `references/code/` 下的每个文件 = **一个真实源文件**的逐字复制（含全部注释、docstring、空行），路径 = 源仓库相对路径（品牌词替换后）再经**压缩映射**，如源 `backend/packages/harness/helix/agents/lead_agent/agent.py` → `references/code/agents/lead_agent/agent.py.md`。
- 压缩映射表（链式应用），动机：Windows MAX_PATH=260——市场缓存前缀（`C:/Users/<name>/.claude/plugins/marketplaces/<mkt>/`）约 83-100 字符，仓库内路径必须留余量：

| 源路径前缀 | 映射为 |
|---|---|
| `backend/packages/harness/helix/` | （剥离，框架包根即 code 根） |
| `backend/packages/extension-api/helix_extension_api/` | `extension-api/` |
| `backend/packages/harness/pyproject.toml` | `pyproject.harness.toml` |
| `backend/docs/` | `docs-backend/` |
| `backend/app/` | `app/` |
| `backend/tests/` | `tests/` |
| `backend/pyproject.toml` | `pyproject.backend.toml` |
| `backend/`（其余，如 AGENTS.md / langgraph.json） | （剥离） |
| `frontend/src/` | `frontend/` |
| `agents/memory/backends/helixmem/helixmem/` | `agents/memory/backends/helixmem/pkg/`（同名双层折叠，防碰撞） |

> 硬约束：仓库内任意文件完整路径 ≤ 160 字符（实测最长 151）。
- **禁止**：手工转述、删减截断、增补注释、"适配结构"、重命名目录层级。发现引用与源不符即为缺陷。
- 复制由**仓库外的生成脚本**批量完成（脚本含源品牌词，不得进入本仓库）。人工只维护 SKILL.md 与清单文件。
- `.md` 源文件（架构文档、AGENTS.md）直接内嵌；代码/配置文件包一层代码围栏并附路径头。

## 4. 单向依赖结构（引用真实架构，不得虚构）

```
   ← 第1层：可发布 agent 框架（import 前缀 helix.*）
backend/packages/extension-api/helix_extension_api/  ← 扩展契约包（禁止 import helix）
backend/app/                      ← 第2层：应用层（gateway / channels / scheduler / mcp_tasks / subagent_batches）
frontend/                         ← 第3层：Next.js（经 HTTP/SSE 调第2层）
contracts/                        ← 跨组件 JSON 契约
```

- 硬规则：`app` 可 import `helix`，`helix` **绝不** import `app`；CI 边界测试强制（见 `core-app-boundary` skill）。
- `helix_extension_api` 零依赖（不 import helix），扩展因此可独立发布。

## 5. 统一骨架（每篇 SKILL.md 强制，≤ 500 行硬上限）

```
---
name + description（含触发条件 + 核心要点，主动表述）
---
## 何时用                      ← 触发场景清单（用户会怎么问）
## 设计方案（为什么这么设计）    ← 核心矛盾/约束/不变量/关键决策；只写源码能佐证的事实
## 实现索引                    ← 真实文件清单（路径 + 职责 + 行数）→ references/code/ 相对路径
## 反模式与陷阱                ← 真实踩坑（源码注释/issue 引用可佐证）
## 落地参考                    ← 自测方向 / 调参旋钮 / 调试日志串
## 进一步阅读                  ← 关联 skill（[[名称]]）+ 关键 reference 深读入口
```

**内容纪律**：
- 设计方案段**只断言源码可佐证的事实**（函数名/常量名/顺序以源码为准）；不确定就不断言。
- 实现索引表列出每个复制文件；SKILL.md 不内嵌大段源码，只放最小伪代码/时序图。
- 禁止出现 v1 时代的虚构机制；本套语料已知的 v1 错误（如"知识分层检索/RRF/rerank"）不得回潮。

## 6. 单篇生产 checklist

- [ ] 骨架六段齐全，SKILL.md ≤ 500 行
- [ ] description 写明触发场景（用户措辞级别）
- [ ] 实现索引与 `references/code/` 实际文件一一对应（无死链）
- [ ] 设计方案中的每个具名函数/常量/顺序都在源码中存在
- [ ] 反模式来自真实注释/issue 编号，不编造
- [ ] 禁词检查 CLEAN（§7）
- [ ] 品牌词只以 Helix 侧形态出现

## 7. 验证命令（在 `skills/` 目录运行）

```bash
# 禁词通过变量拼合构造，避免检查脚本自身被误命中
_d="deer"; _b="byte"
grep -rilE "${_d}flow|${_d}-flow|${_d}_flow|${_d}mem|${_d}_mem|${_d}\.svg|${_b}dance" . \
  && echo "VIOLATION（须按 §2 映射表改写）" || echo "CLEAN"
```

判定：输出 `CLEAN` 为合格；任何命中行须定位修复后重跑，直到 `CLEAN`。

## 8. Skill 划分总表（33 个）

| # | skill | 覆盖源模块 |
|---|---|---|
| 1 | using-agent-system-design | 元入口/架构总览 |
| 2 | e2e-request-lifecycle | 端到端请求脊柱（nginx→gateway→run→SSE） |
| 3 | agent-graph-factory | agents 装配（lead/factory/features/descriptor） |
| 4 | middleware-chain-design | middlewares（链装配 + 通用中间件） |
| 5 | system-prompt-template | lead_agent/prompt.py |
| 6 | thread-state-and-reducers | ThreadState/reducers/goal_state/task_continuity |
| 7 | context-window-management | summarization/token budget/tool output budget/compaction |
| 8 | tool-assembly-and-policy | tools 装配 + tool_search 延迟目录 + provenance |
| 9 | sandbox-abstraction | SandboxProvider/Sandbox/lease/local/aio provider |
| 10 | sandbox-tools-and-safety | sandbox/tools.py（bash/文件工具/路径安全/脱敏） |
| 11 | subagent-delegation | subagents 全模块 + task 工具 + 批处理 |
| 12 | mcp-integration | mcp 全模块 + capabilities + mcp_tasks 服务 |
| 13 | skill-system-design | skills 全模块 + 激活/策略中间件 + 评审 |
| 14 | memory-system-design | agents/memory（manager/signals/多后端） |
| 15 | enterprise-rag-knowledge-base | knowledge 协议层 + ragflow/lightrag 客户端 |
| 16 | auth | gateway auth（JWT/OIDC/PAT/密码/节流/CSRF/internal token） |
| 17 | safety-and-guardrails | guardrails + authz + typesafe + 脱敏/净化中间件 |
| 18 | multi-user-isolation | user_context/secret_context/run_origin/paths |
| 19 | config-and-hot-reload | AppConfig/热重载/共享重置标记/扩展配置 |
| 20 | observability-tracing | tracing + journal + events store |
| 21 | gateway-runs-and-sse | gateway 服务装配 + threads/runs 路由 + SSE |
| 22 | im-channels | channels 全部（10 平台 + 总线/管理器/租约） |
| 23 | scheduled-tasks | scheduler 计算 + 调度服务 + 通知 + goal |
| 24 | frontend-app-design | Next.js 应用结构/SSR 鉴权/领域 API/composer |
| 25 | frontend-streaming-protocol | api-client/useThreadStream/事件归一化/重连 |
| 26 | packaging-and-deployment | compose/nginx/provisioner/helm/Makefile |
| 27 | core-app-boundary | harness/app 边界测试 + 嵌入式 client + TUI |
| 28 | long-running-and-cancellation | RunManager/worker/StreamBridge/checkpointer/租约 |
| 29 | extension-plugin-system | extension-api 契约 + extensions 宿主 + 示例 |
| 30 | persistence-layer | engine/bootstrap/18 域仓库/migrations |
| 31 | model-provider-factory | models 工厂/推理契约/多 provider 补丁 |
| 32 | workspace-and-projects | uploads/workspace_changes/projects/storage |
| 33 | web-search-integrations | community 搜索工具 + URL 安全 |
