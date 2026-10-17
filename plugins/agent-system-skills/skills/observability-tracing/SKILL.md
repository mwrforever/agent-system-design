---
name: observability-tracing
description: 可观测体系：tracing 工厂（Langfuse/LangSmith 回调统一构建）与"挂图根不挂模型"不变量、RunJournal（BaseCallbackHandler）run 事件持久日志与历史 seed、RunEventDefinition 事件目录（冻结词表 + 8 category）与 RunEventStore 三后端（db/jsonl/memory，seq 按 thread 严格递增）、装配证据投影。当要给 agent 平台接 tracing、设计 run 审计日志/事件回放/用量对账，或排查 session_id 丢失、token 双计、事件乱序时使用。
---

# 可观测与追踪

## 何时用

- 接 LLM tracing（Langfuse/LangSmith），需要正确的 span 层级与 session 归因
- run 级审计：每个 run 发生了什么、可回放
- 事件流持久化（断线重连后补齐、事后分析）
- 用量/token 对账

## 设计方案（为什么这么设计）

### 1. tracing 挂图根不变量

`tracing/factory.py::build_tracing_callbacks()` 统一构建回调；**只**由图工厂追加到 `config["callbacks"]`（图根），图内所有 `create_chat_model` 一律 `attach_tracing=False`（INVARIANT 注释强制，见 [[agent-graph-factory]]）。为什么：一次 LangGraph run 应产出**一条** trace，node/LLM/tool 是子 span；挂在模型上则模型成嵌套 observation——`langfuse_session_id`/`langfuse_user_id` 无法从 `config["metadata"]` 提升到 trace，且每条消息双重 span 导致 token 双计。Monocle 后端（`monocle.py`）同机制。

### 2. RunJournal：run 事件的持久日志

`runtime/journal.py`（1810 行）：`RunJournal(BaseCallbackHandler)` 挂进回调链，把 run 生命周期事件持久化（jsonl/数据库），并作为**历史 seed**——重连或事后分析从 journal 重建事件序列，不依赖内存。

### 3. 事件目录与三后端存储

- `events/catalog.py`：`RunEventDefinition` 目录——事件名/类别/字段是**冻结词表**（与 `contracts/run_event_stream_contract.json` 共同权威，见 [[gateway-runs-and-sse]]）：8 个 category（trace/message/outputs/error/middleware/context/subagent/workspace），动态模式 `middleware:{tag}`。
- `events/store/`：`RunEventStore` 抽象 + db（598）/jsonl（520）/memory（243）三实现；`message_identity.py`/`message_seq.py` 保证**同一 thread 的 seq 严格递增**——重连补流的"不丢不重"靠它。
- `config.run_events` 选后端（多实例部署要求 db）。

### 4. 装配证据

`assembly_evidence.py`：把"本次 run 用了哪个装配描述符"记入证据链（配合 [[agent-graph-factory]] 的 assembly_descriptor）——回答"这次异常回复当时装配了什么 agent"。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/harness/helix/tracing/factory.py` + `metadata.py` + `monocle.py` | 65+114+69 | 回调构建/metadata 提升/monocle |
| `references/code/backend/packages/harness/helix/runtime/journal.py` | 1810 | run 日志 + 历史 seed |
| `references/code/backend/packages/harness/helix/runtime/events/catalog.py` | 121 | 冻结事件目录 |
| `references/code/backend/packages/harness/helix/runtime/events/store/db.py` / `jsonl.py` / `memory.py` | 598/520/243 | 三后端 |
| `references/code/backend/packages/harness/helix/runtime/events/{message_identity,message_seq}.py` | 60/52 | 消息指纹与序号 |
| `references/code/backend/packages/harness/helix/runtime/assembly_evidence.py` | 63 | 装配证据 |
| `references/code/backend/packages/harness/helix/config/tracing_config.py` + `run_events_config.py` | 212+42 | 配置 |

## 反模式与陷阱

- ❌ tracing callback 挂模型 → 双 span + session 丢失 + token 双计（INVARIANT 注释逐调用点枚举）。
- ❌ 事件名随手起 → 消费方漂移；走 catalog + 契约。
- ❌ seq 非严格递增 → 重连补流丢/重；message_seq。
- ❌ 多实例用 memory/jsonl 事件存储 → 跨副本不可见；db（启动时校验拒绝）。
- ❌ 日志打密钥/全文消息 → 泄漏；脱敏走 secret_context。

## 落地参考

**调参旋钮**：`tracing`（provider/开关/采样）、`run_events`（backend/保留）。

**自测方向**：一次 run 恰一条 trace 且层级正确；`langfuse_session_id` 出现在 trace 属性；杀进程后从 journal/db 重建事件序列 seq 连续；token 用量与 provider 对账一致。

## 进一步阅读

- [[agent-graph-factory]]（挂载点与 INVARIANT）、[[gateway-runs-and-sse]]（事件契约与 SSE 出口）
- [[long-running-and-cancellation]]（重连补流消费侧）
