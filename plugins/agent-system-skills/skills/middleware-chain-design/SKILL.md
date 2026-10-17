---
name: middleware-chain-design
description: LangChain AgentMiddleware 中间件链的完整设计：三层装配结构（wrap_model_call 外层清洗 → 线程钩子 → 追尾链）、build_middlewares/build_lead_runtime_middlewares/build_subagent_runtime_middlewares 三级构造器、ClarificationMiddleware 永远殿后、约 50 个中间件各自职责与触发条件、共享基础链与 lead 专属链的差异。当要在链上插入新中间件、调整顺序、理解某个中间件为何在那个位置、或排查"中间件没生效/顺序不对/子代理链缺东西"时使用。
---

# 中间件链设计

## 何时用

- 设计/扩展 before-model、wrap-model-call、after-model 钩子链
- 需要某个中间件（澄清、循环检测、token 预算、沙箱审计、工具进度……）的准确位置与条件门
- 子代理与 lead agent 共享哪些中间件、差在哪
- 排查中间件顺序引发的怪象（脱敏在预算之后、澄清不在最后等）

## 设计方案（为什么这么设计）

### 1. 链是"装配"出来的，不是写死的

`build_middlewares()`（lead 全量）与 `_build_runtime_middlewares()`（共享基础链，位于 `tool_error_handling_middleware.py`）分层拼装；`build_lead_runtime_middlewares` / `build_subagent_runtime_middlewares` 是共享链的两个变体出口。所有条件项用 `[..., mw] if enabled else []` 内联展开——**读构造器源码即得权威顺序**。

### 2. Lead 链三层结构（权威顺序）

```
Layer 1  wrap_model_call 外层（请求进出模型的清洗管道）
  InputSanitization → KnowledgeScope → ToolOutputBudget → ToolResultSanitization → [PiiRedaction]
Layer 2  线程钩子（资源准备）
  ThreadData → Uploads → Sandbox
Layer 3  追尾链（按序追加）
  DanglingToolCall → LLMErrorHandling → [ToolReceipt] → [ArtifactResolution]
  → [Guardrail(authz适配)] → [Guardrail(provider)] → SandboxAudit → [ReadBeforeWrite]
  → [ToolProgress] → ToolErrorHandling → [ArtifactCapture]
  —— 以下 lead 专属 ——
  DynamicContext → SkillActivation → [DeferredToolPromotionAudit] → SkillToolPolicy
  → DurableContext → [Summarization] → [Todo] → [TokenUsage] → Title → [Memory]
  → ViewImage → McpRouting → DeferredToolFilter → SystemMessageCoalescing
  → SubagentLimit → LoopDetection → [TokenBudget] → CompletedSubagentUsage
  → ModelContentCompatibility → (自定义/扩展中间件) → TerminalResponse
  → ModelLengthFinishReason → [SafetyFinishReason] → ClarificationMiddleware（永远最后）
```

SDK 链（`create_helix_agent` 用，18 项）是其子集：ThreadData → Uploads → Sandbox → DanglingToolCall → [Guardrail] → ToolErrorHandling → [PiiRedaction] → DurableContext → SystemMessageCoalescing → [Summarization] → [Todo] → [Title] → [Memory] → [ViewImage] → SubagentLimit → LoopDetection → [TokenBudget] → ModelContentCompatibility → Clarification。

### 3. 顺序背后的不变量

- **ClarificationMiddleware 永远最后**：`ask_clarification` 会 `Command(goto=END)` 中断等回复，任何后置中间件都会在"挂起态"下误运行。
- **清洗先于预算/记录**：InputSanitization/ToolResultSanitization/PiiRedaction 在外层，保证进入预算统计与日志的是已净化内容。
- **Sandbox 在 Summarization 之前**：压缩中间件自身要调模型，需要沙箱/线程路径已就绪。
- **DynamicContext 在 DurableContext 之前**：动态注入（日期/记忆 system-reminder）不得写入持久上下文通道。
- **LoopDetection 在 TokenBudget 之前**：先掐死无效循环，再让预算只为有效消耗计数。
- **DanglingToolCall 在最前**：上游给进来的悬空 tool_call 必须先修补，否则后续所有 hook 都在处理畸形消息。

### 4. 中间件职责速查（源 docstring 实录语义）

| 中间件 | 职责 |
|---|---|
| InputSanitization | 用户消息注入防御（提示注入面收窄） |
| KnowledgeScope | 消息级知识检索范围边界 |
| ToolOutputBudget | 超限工具结果落盘，消息内替换为预览摘要 |
| ToolResultSanitization | 工具结果中的控制符中和 |
| ThreadData/Uploads/Sandbox | 线程目录、上传清单注入、沙箱获取 |
| DanglingToolCall | 修补无配对 result 的 tool_call |
| LLMErrorHandling | 模型错误重试退避 + 用户可读兜底 |
| ToolReceipt/ReceiptVerification/DelegationLedger | 确定性回执与委派账本 |
| ArtifactResolution/ArtifactCapture | 工具产物句柄解析与捕获 |
| Guardrail×2 | 授权适配器版 / 显式 provider 版调用前判定 |
| SandboxAudit | bash 命令安全审计 |
| ReadBeforeWrite | 写文件前必须读过（防盲写覆盖） |
| ToolProgress | 工具进度状态机（task_* 事件源） |
| ToolErrorHandling | 工具异常转 ToolMessage（链构造器所在文件） |
| DynamicContext | 静态 prompt 之外的动态 system-reminder（保 prefix cache） |
| SkillActivation/SkillToolPolicy | 斜杠激活技能 / 激活技能的 allowed-tools 执行 |
| DurableContext | goal/摘要/委派账本/技能注入的持久通道 |
| Summarization/Todo/Title/Memory/ViewImage | 压缩 / 计划清单 / 自动标题 / 记忆队列 / 图像注入 |
| McpRouting/DeferredToolFilter | 延迟 MCP 工具自动晋升 / 延迟工具 schema 隐藏 |
| SystemMessageCoalescing | 合并 SystemMessage（vLLM/Anthropic 兼容） |
| SubagentLimit | 每响应/每 run 委派上限 |
| LoopDetection | 重复调用环检测（warn/hard 双阈值） |
| TokenBudget/TokenUsage | run 级预算 / 用量记账 |
| ModelContentCompatibility | 读时净化 URL 内容块 |
| TerminalResponse/ModelLength/SafetyFinishReason | 防空响应 / 长度截断修复 / 安全终止修复 |

## 实现索引

`references/code/backend/packages/harness/helix/agents/middlewares/` 下 **49 个文件、14382 行**（整目录逐字复制，仅排除归属其他 skill 的 11 个：summarization/token_budget/tool_output_budget/tool_output_synopsis → [[context-window-management]]；skill_activation/skill_tool_policy/skill_context → [[skill-system-design]]；memory → [[memory-system-design]]；pii_redaction/input_sanitization/read_before_write → [[safety-and-guardrails]]；SandboxMiddleware 本体在 [[sandbox-abstraction]]）。

| 关键文件 | 行数 | 为什么关键 |
|---|---|---|
| `tool_error_handling_middleware.py` | 856 | `_build_runtime_middlewares` 顺序契约 + lead/subagent 两个变体出口 |
| `dynamic_context_middleware.py` | 806 | 静态/动态提示分离的执行侧 |
| `loop_detection_middleware.py` | 995 | 环检测双阈值状态机 |
| `clarification_middleware.py` | 579 | 殿后中间件的挂起语义 |
| `durable_context_middleware.py` | 465 | 持久上下文通道写入 |
| `todo_middleware.py` | 452 | 计划模式与上下文丢失检测 |
| `tool_progress_middleware.py` | 774 | task_* 事件源头 |
| `view_image_middleware.py` | 622 | 视觉模型图像注入 |
| 其余 41 个 | — | 见目录，每个文件头部 docstring 即职责说明 |

## 反模式与陷阱

- ❌ 把自定义中间件 append 到链尾 → 落在 ClarificationMiddleware 之后，挂起态误触发。正确：用 `@Next`/`@Prev` 锚点或插入 ModelContentCompatibility 之前（见 [[agent-graph-factory]] SDK 工厂）。
- ❌ 在 wrap_model_call 里改 state 又不返回 → 中间件协议要求返回新 state/消息列表。
- ❌ 子代理链直接复用 lead 链 → lead 专属中间件（SkillActivation 等）对子代理无意义且耗 token；共享链构造器已剥离。
- ❌ 新中间件自己 new model 没带 `attach_tracing=False` → 违反 tracing 挂图根不变量。

## 落地参考

**调参旋钮**：`loop_detection`（warn 3 / hard 5）、`token_budget`（max 200k / warn 0.8 / hard_stop 1.0）、`tool_output` 预算与豁免清单、`read_before_write`、`safety_finish_reason`——均在 config.yaml 对应段。

**自测方向**：断言 `build_middlewares` 输出类型序列与预期一致（链序回归测试）；开关任一 feature flag 后链长度变化符合预期；ClarificationMiddleware 恒为最后一项。

## 进一步阅读

- [[agent-graph-factory]]（谁在调 build_middlewares）、[[context-window-management]]（被排除的 4 个上下文中间件全文）
- 深读 `tool_error_handling_middleware.py` 的 `_build_runtime_middlewares`：顺序的唯一权威来源
