---
name: context-window-management
description: 上下文窗口治理四件套：SummarizationMiddleware 历史压缩（trigger/keep/trim_tokens 阈值）、TokenBudgetMiddleware run 级预算（max/warn/hard_stop 三档）、ToolOutputBudgetMiddleware 超限工具结果落盘换预览（externalize + synopsis）、compact_thread_context 手动紧缩。当上下文爆长、工具输出撑爆窗口、要设计"预算分层"（工具输出预算 < 会话预算 < run 预算）或压缩策略时使用。
---

# 上下文窗口管理

## 何时用

- 会话历史增长失控，需要分层压缩策略
- 单个工具输出（日志、爬虫、大文件）撑爆上下文
- 设计 token 预算体系（预警/硬停）与超限后的降级行为
- 手动 compact 端点的语义设计

## 设计方案（为什么这么设计）

### 1. 治理发生在三个不同的层

| 层 | 组件 | 时机 | 默认 |
|---|---|---|---|
| 单工具输出 | ToolOutputBudgetMiddleware | 工具结果产生时 | 超限结果**落盘为 artifact**，消息内替换为预览摘要（synopsis），模型按需再读 |
| 会话历史 | SummarizationMiddleware | 阈值触发时 | 老历史压缩为摘要，保留最近 K 轮与关键块（trigger/keep/trim_tokens） |
| 整个 run | TokenBudgetMiddleware | 每次模型调用前 | max 200k / warn 0.8 / hard_stop 1.0，硬停走终止路径而非异常崩溃 |

越底层的预算越先收紧——工具输出先被治，轮不到会话压缩出手；会话先被压缩，轮不到 run 预算硬停。**分层的目的：每一层只在更低层治理失败后兜底。**

### 2. 工具输出落盘而非截断

截断丢信息且模型不自知；落盘（externalize）后消息内是**结构化预览 + 句柄**，模型可用文件工具按需读取原文。`tool_output_synopsis.py` 负责生成预览；豁免清单（`tool_output` 配置段）放行小而关键的结果（如 `ask_clarification`）。产物走 artifact 通道（[[workspace-and-projects]]）。

### 3. 摘要是中间件不是前置步骤

SummarizationMiddleware 自建模型调用（`attach_tracing=False`，遵守挂图根不变量），触发阈值可配；压缩产生的 transient 消息在前端被专门归约处理（见 [[frontend-streaming-protocol]] 的 stream-state）。

### 4. 手动紧缩

`compact_thread_context`（runtime/context_compaction.py）服务于 `POST /api/threads/{id}/compact`：一次性重写检查点上下文（走状态变更图，不绕 reducer），语义上是"立即做一次深度压缩 + 持久化"。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/agents/middlewares/summarization_middleware.py` | 1279 | 历史压缩中间件（阈值/保留策略/自建模型） |
| `references/code/agents/middlewares/tool_output_budget_middleware.py` | 1277 | 工具输出预算 + 落盘替换 |
| `references/code/agents/middlewares/tool_output_synopsis.py` | 651 | 预览摘要生成 |
| `references/code/agents/middlewares/token_budget_middleware.py` | 388 | run 级预算三档 |
| `references/code/runtime/context_compaction.py` | 244 | 手动紧缩 |
| `references/code/config/summarization_config.py` | 124 | trigger/keep/trim_tokens |
| `references/code/config/tool_output_config.py` | 121 | externalize/预览/豁免 |
| `references/code/config/token_budget_config.py` | 21 | max/warn/hard_stop |
| `references/code/config/token_usage_config.py` | 7 | 用量记账开关 |

## 反模式与陷阱

- ❌ 工具输出直接 truncate → 模型不知道丢了什么；落盘 + 预览 + 句柄。
- ❌ 摘要中间件放在 Sandbox 之前 → 压缩要调模型时沙箱/路径未就绪（链序见 [[middleware-chain-design]]）。
- ❌ 预算硬停抛异常 → run 进入 error 而非有序终止；硬停是终止路径。
- ❌ 预警/硬停共用一个阈值 → 没有缓冲带；0.8/1.0 分档。
- ❌ compact 直接改检查点 → 绕过 reducer；走 context_compaction 的受控路径。

## 落地参考

**调参旋钮**：`summarization.trigger/keep/trim_tokens`；`tool_output` 预算字节数与豁免工具清单；`token_budget.max_tokens/warn_ratio/hard_stop_ratio`。

**自测方向**：超大工具输出 → 断言消息内为预览、artifact 存原文、模型可二次读取；历史超阈值 → 断言压缩后 token 降到 keep 水位；跨过 hard_stop → run 有序终止且 usage 已记账。

## 进一步阅读

- [[middleware-chain-design]]（三个中间件在链上的位置与条件门）
- [[workspace-and-projects]]（落盘 artifact 的存储侧）、[[frontend-streaming-protocol]]（压缩 transient 消息的前端归约）
