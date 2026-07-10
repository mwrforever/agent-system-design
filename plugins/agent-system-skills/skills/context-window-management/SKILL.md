---
name: context-window-management
description: 治理 agent 的上下文窗口--摘要压缩历史、孤儿 tool_call 补占位、循环检测硬停、token 预算硬上限。覆盖四件套中间件的设计与真实代码索引：摘要触发阈值（tokens/messages/fraction）+ RemoveMessage 替换历史 + summary_text 持久通道 + 保护 dynamic-context reminder、DanglingToolCall 三源扫描与按 AIMessage 精确位置补占位、LoopDetection 双层（hash + per-tool frequency）检测与延迟注入与硬停双清、TokenBudget 三维 fraction + diff 累加 + stop_reason 上报；多 SystemMessage 合并引用 [[system-prompt-template]] 不重复。当你的 agent 跑长报 token overflow、用户中断后续聊 OpenAI/Anthropic 报 tool_call 缺响应、agent 陷入重复工具调用循环不出来、或要限单 run token 用量时调用本 skill。
---

## 何时用

- agent 跑长了，LLM 报 token overflow / context length exceeded，需要在撞上限前压缩历史
- 用户中断后继续聊，OpenAI / Anthropic / Moonshot 报 `"tool_call_ids did not have response messages"`（tool_call 缺配对 ToolMessage）
- agent 陷入"调 A -> 调 B -> 调 A -> 调 B"循环不出来，或对同一类工具（如 `read_file`）狂调几十次（跨文件扫描）
- 单 run 想限制 token 用量（多用户共享、限免场景、子代理防烧穿）
- 排查摘要压掉了 dynamic-context reminder / 压掉了用户最新一轮 / hard-stop 后状态不一致

> 多 SystemMessage 合并（SystemMessageCoalescing）已在 [[system-prompt-template]] 详讲，本 skill 只讲它与四件套的边界，不重复其实现。

## 设计方案（为什么这么设计）

### 核心矛盾：上下文上限、成本、防循环--三个独立压力

agent 的消息历史随轮次累积，给上下文窗带来三个**相互独立**的压力，不能用一个超级中间件一站式解决：

1. **模型上下文上限**：任何 LLM 都有 `max_input_tokens` 硬顶，撞顶就 4xx 整轮失败。确定性压力，必须有兜底压缩。
2. **token 成本**：即便没撞顶，历史越长每轮越贵。多用户 / 限免 / 子代理场景还要有**单 run 总预算**硬上限，防一个失控任务烧穿配额。
3. **循环 / 失控**：模型可能反复调同一组工具（hash 相同）或对同一类工具狂调（args 变但 tool type 不变），既烧 token 又不出最终答。行为压力，要按调用模式检测并硬停。

三者正交：压缩历史不防循环，防循环不省 token，token 预算不补孤儿。所以**每个压力一个独立中间件**，各自在链上的最佳位置挂载，职责不重叠。

### 五件套职责分工与链路位置

四件套在 29 项链（见 [[middleware-chain-design]]）上**分散在四个位置**，各自在"最合适的时机"跑：

| 中间件 | 链序号 | 段 | hook | 时机 |
|---|---|---|---|---|
| DanglingToolCall | 6 | base | `wrap_model_call` | 模型调用前补齐孤儿（lead + 子代理都挂） |
| Summarization | 16? | lead | `before_model` | 模型调用前压缩历史，给后续中间件减负 |
| SystemMessageCoalescing | 23 | lead | `wrap_model_call` | 合并 SystemMessage（见 [[system-prompt-template]]） |
| LoopDetection | 25? | lead | `after_model` + `wrap_model_call` | 模型返回后检测循环，下次调用注入告警 |
| TokenBudget | 26? | lead | `after_model` + `wrap_model_call` | 模型返回后累加 token，下次调用注入告警 |

**位置设计理由**：

- **DanglingToolCall 在最前（6）**：孤儿是"历史不完整"问题，必须在任何读历史的中间件之前修复，否则 Summarization 会把孤立 tool_call 当真实历史压进摘要。base 段--子代理也会孤儿（同样会被取消），lead + 子代理都挂。
- **Summarization 靠前（16）**：源码注释 `SummarizationMiddleware should be early to reduce context before other processing`。压完历史，后续 Title / Memory / ViewImage 等扫历史的中间件都受益。
- **LoopDetection / TokenBudget 在后（25/26）**：都读"模型刚返回的 AIMessage"，必须在模型之后跑（`after_model`）。夹在 SubagentLimit（24）与 SafetyFinishReason（28）之间：Safety 在更靠后注册，逆序 `after_model` 派发使 Safety 先跑清安全终止的 tool_calls，Loop/Budget 再对清理后的消息计数（不误报，见 [[middleware-chain-design]]）。

### 摘要触发策略与"替换历史"持久化

`before_model` 决策"要不要压"。触发阈值三种，任一满足即触发（`trigger` 可传单条或列表）：`("tokens", N)` / `("messages", N)` / `("fraction", F)`（历史 token ≥ 模型 `max_input_tokens × F`）。

```python
# 伪代码：摘要中间件 before_model 决策流（完整源码见 references/code/summarization.md）
def before_model(state, runtime):
    prepared = _prepare_compaction(state)            # 触发阈值? -> 切分 cutoff -> 保护 reminder
    if prepared is None: return None                 # 未触发，本轮不压
    to_summarize, preserved, prev_summary, _ = prepared
    _fire_hooks(to_summarize, preserved, runtime)    # memory_flush_hook 先灌记忆队列（见 [[memory-system-design]]）
    summary = _summarize_with(to_summarize, prev_summary)  # nostream 模型副本，禁流防幽灵 AI 消息
    if summary is None: return None                  # LLM 失败优雅降级，不阻塞 run
    return {
        "messages": [RemoveMessage(REMOVE_ALL_MESSAGES), *preserved],  # 全清再重建协议
        "summary_text": summary,                     # 摘要进独立通道，不进 messages
    }
```

**关键持久化决策**：摘要写回用 `RemoveMessage(id=REMOVE_ALL_MESSAGES)` 清空全部 messages 再补 preserved--LangGraph 的"全清再重建"协议，保证 checkpoint 里只剩保留窗口。摘要**文本不进 messages**，而是写到独立的 `state["summary_text"]` 通道（`ThreadState` 的 LastValue 字段），由 `DurableContextMiddleware`（第 15 项）投影回每次模型调用。这样摘要不会被再次摘要（无递归），也不占用 messages reducer 去重逻辑。

**保护 dynamic-context reminder**：`_preserve_dynamic_context_reminders` 把 reminder 及其 ID-swap 对（`__memory` / `__user`）从"待压"捞回"保留"--否则 DynamicContext 丢失已注入的日期锚点，或在错误位置重注入（见 [[system-prompt-template]] 的 ID-swap 机制）。扫描 `additional_kwargs["dynamic_context_reminder"]` 标记识别。

**增量摘要**：`_build_summary_prompt` 把已有 `previous_summary` 作为 `<existing_summary>` 段喂给 LLM，`trim_tokens_to_summarize` 把两边各砍一半 token 防摘要 prompt 自身撑爆。

### 孤儿 tool_call 的产生原因与清理

**产生原因**（三种，DanglingToolCall 都要处理）：

1. **用户中断 / 请求取消**：模型刚发 `AIMessage(tool_calls=[...])`，用户点停止，tools 节点没跑，没产生配对 ToolMessage。
2. **历史裁剪 / checkpoint resume**：消息被外部机制截断，恰好把 ToolMessage 截掉留下 AIMessage(tool_calls)。
3. **malformed provider payload**：provider 返回的 function call JSON 不合法，LangChain 存进 `invalid_tool_calls`（不执行），但 provider 适配器下次仍可能把 call id/name 序列化回去，严格校验器仍期望配对 ToolMessage。

```python
# 伪代码：孤儿清理（完整源码见 references/code/orphan-toolcall.md）
def wrap_model_call(request, handler):
    patched = _build_patched_messages(request.messages)   # 三源扫描 + 按 AIMessage 精确位置重组
    if patched is not None:
        request = request.override(messages=patched)      # per-request 载荷，不改 checkpoint
    return handler(request)

# _build_patched_messages 内部：
#   三源归一化 _message_tool_calls：msg.tool_calls + additional_kwargs["tool_calls"] + invalid_tool_calls
#   重组：每个 ToolMessage 紧贴其 AIMessage；缺的补合成占位 ToolMessage(status="error")
#     interrupted -> "[Tool call was interrupted and did not return a result.]"
#     invalid write_file -> 专门长引导（issue #2894，不回显巨大 Markdown payload）
#     其他 invalid -> 参数错误引导
```

**为什么用 `wrap_model_call` 而非 `before_model`**：`before_model` 返回的列表经 `add_messages` reducer 会**追加到末尾**，破坏"`AIMessage(tool_calls)` 紧跟其 `ToolMessage`"的因果序；`wrap_model_call` 在最终载荷上重组，把每个 ToolMessage 紧贴在其 AIMessage 之后。

### 循环检测：双层策略 + 延迟注入 + 硬停双清

**双层检测**（`_track_and_check`，`after_model`）：

- **Layer 1 hash-based**：`_hash_tool_calls` 把当前 turn 的 tool_calls 归一化为 `(name, stable_key)` 多重集，**排序**后 md5--order-independent（同样一组调用乱序也判同）。滑动窗口（`window_size` 默认 20）跟踪最近 N 个 hash，同一 hash 出现 `warn_threshold`（默认 3）次告警，`hard_limit`（默认 5）次硬停。
- **Layer 2 per-tool-type frequency**：同一 **tool type**（不看 args）被调 `tool_freq_warn`（默认 30）次告警，`tool_freq_hard_limit`（默认 50）次硬停。专抓 Layer 1 漏的"跨文件扫描"--模型对 40 个不同文件调 `read_file`，每次 args 不同 Layer 1 hash 全不同，但行为明显失控。`tool_freq_overrides` 支持给特定工具（如批处理 `bash`）单独抬高阈值。

**`_stable_tool_key` 降噪**：`read_file` 用 `path + line bucket`（200 行一桶，渐进式读不算循环，跨文件算不同 key）；`write_file` / `str_replace` 用 full args hash（同路径可能迭代不同 payload，只用 path 会误判）；其他用 salient fields（`path/url/query/command/pattern/glob/cmd`）。

```python
# 伪代码：循环检测双钩子（完整源码见 references/code/loop-and-budget.md §1）
def after_model(state, runtime):
    warning, hard_stop = _track_and_check(state, runtime)   # Layer1 hash + Layer2 freq
    if hard_stop:
        _stop_reason[run_id] = "loop_capped"                # executor consume_stop_reason 读
        return {"messages": [_strip_tool_calls(last_msg, warning)]}  # 硬停双清，强制最终答
    if warning:
        _queue_pending_warning(runtime, warning)            # 不能在 after_model 直接注入！
        return None                                          # 延迟到下次 wrap_model_call
    return None

def wrap_model_call(request, handler):
    warnings = _drain_pending_warnings(request.runtime)     # 排空队列
    if warnings:
        request = request.override(messages=[*request.messages,
            HumanMessage(content=warnings, name="loop_warning")])  # 追加到末尾，在所有 ToolMessage 后
    return handler(request)
```

**延迟注入关键不变量**：告警**不能**在 `after_model` 直接注入--`after_model` 在模型刚发 `AIMessage(tool_calls=...)` 时触发，此时 tools 节点**还没跑**，没有配对 ToolMessage。在此时插任何非 tool 消息会落到"assistant tool_calls 与其 tool responses 之间"，OpenAI / Moonshot 直接拒，Anthropic 也禁中段 SystemMessage。所以 `after_model` 只**队列**，`wrap_model_call` 在下次模型调用**排空**追加到末尾。`before_agent` 清其他 run 的旧告警；`after_agent` 清当前 run 的告警（告警是 transient，run 结束就丢）。

**硬停双清**（`_build_hard_stop_update`）：达到 `hard_limit` 时清**两处** tool_call 元数据：结构化 `tool_calls = []` + 原始 provider payload `additional_kwargs` 里 pop `tool_calls` 与 `function_call` + `response_metadata.finish_reason: "tool_calls" -> "stop"` + 追加 `[FORCED STOP]` 文本。**只清一处不够**--不清 `additional_kwargs["tool_calls"]`，provider 适配器仍会序列化原始调用下发，循环继续。

**stop_reason 上报**（#3875 Phase 2）：硬停**不 raise**--清完 tool_calls 让 run 自然结束产最终答。硬停时写 `_stop_reason[run_id] = "loop_capped"`，executor 在 run 返回后调 `consume_stop_reason(run_id)` pop 读，把 `completed + stop_reason=loop_capped` 上报给 lead，lead 据此决定"重试更紧 / 提高预算 / 复用部分结果"。该 dict **不**被 `after_agent` 清（executor 在 run 后才读），靠 `BoundedDict(1000)` 防 leak。

### token 预算：硬上限与优雅降级

**diff 累加**（`_apply`，`after_model`）：每个 `AIMessage` 带 `usage_metadata`。中间件按 `run_id` 维护 `seen[msg.id] = (input, output)` 与累计 `TokenUsage`。每次扫历史算 `diff = max(0, current - prev)` 再累加--**为什么用 diff**：`TokenUsageMiddleware`（第 18 项）会把子代理追溯的 token 回填到历史某条 AIMessage 上（message position 机制），同一条消息的 `usage_metadata` 会在本轮"变大"，直接加会重复计数；diff 只加增量。

**`before_agent` 标记旧消息为 seen**：run 开始时把所有历史 AIMessage 的 usage 记进 `seen`，这样它们**不计入本 run 预算**--只算本 run 新增的 token（per-run 语义，不是 per-thread）。

**三维 fraction**：同时支持 `max_tokens`（total）、`max_input_tokens`、`max_output_tokens` 三个上限，取**最高 fraction** 触发。既能防总爆，也能单独限输入或输出（如限免场景只给输出配额）。

**两段降级**（与 LoopDetection 同样的延迟注入）：`warn_threshold`（默认 0.8）注入 `[TOKEN BUDGET WARNING]`，`_warned[run_id]` 去重（每 run 只告警一次）；`hard_stop_threshold`（默认 1.0）strip tool_calls + 追加 `[TOKEN BUDGET EXCEEDED]`，写 `_stop_reason[run_id] = "token_capped"`，executor 读。同样不 raise。

**BoundedDict 防 leak**：lead agent 的中间件实例是**长生命周期**的（跨很多 run 复用），per-`run_id` 状态用普通 dict 会无限累积。`BoundedDict(1000)` 是 `OrderedDict` 子类，`__setitem__` 时 FIFO 驱逐最老条目--`_warned` / `_pending_warnings` / `_seen_messages` / `_cumulative_usage` / `_stop_reason` 全用它。`after_agent` 清当前 run 的前四项（`_clear_run_state`），但**不清 `_stop_reason`**。

### 与 SystemMessageCoalescing / system-prompt 的边界

四件套**不动** SystemMessage，只动 messages 与 state：

- **Summarization** 压缩 messages（RemoveMessage + preserved），摘要文本进 `summary_text` 通道而非新 SystemMessage。
- **DanglingToolCall** 注入 ToolMessage，不碰 SystemMessage。
- **LoopDetection / TokenBudget** 注入 `HumanMessage(name="loop_warning" / "budget_warning")`，不碰 SystemMessage。

SystemMessage 的合并完全是 SystemMessageCoalescing（第 23 项）的职责--DynamicContext 注入的 `<system-reminder>`、DurableContext 注入的权威规则、摘要前遗留的 SystemMessage，全由它在 `wrap_model_call` 合并为一条首条。详见 [[system-prompt-template]]。

**与 DynamicContext 的协同**：Summarization 必须保护 dynamic-context reminder 不被压掉（`_preserve_dynamic_context_reminders`），否则 DynamicContext 丢失已注入的日期锚点。两者通过 `additional_kwargs["dynamic_context_reminder"]` 标记通信。

### 在端到端链路中的位置

本 skill 处于端到端链路的 **⑤中间件**（见 [[e2e-request-lifecycle]]）：

- 上游 ④建图：`make_lead_agent` 调 `build_middlewares` 装配 29 项链，四件套按 6 / 16 / 25 / 26 号位落定（见 [[agent-graph-factory]]）。
- 下游 ⑥执行：worker `astream` 驱动中间件链--`before_model` 正序（Summarization 压历史）-> `wrap_model_call` 洋葱（DanglingToolCall 补孤儿、SystemMessageCoalescing 合并、Loop/Budget 注入告警）-> 真实模型 -> `after_model` 逆序（SafetyFinishReason 先清、Loop/Budget 后检）-> tools 节点。

子代理（`task()` 委派）同样挂四件套镜像--DanglingToolCall（base 段自带）、LoopDetection、TokenBudget、SafetyFinishReason--防退化子代理烧穿 token 或死循环（见 [[subagent-delegation]]）。子代理的 `consume_stop_reason` 是 executor 上报 `stop_reason=token_capped|loop_capped` 的关键钩子。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/agents/middlewares/summarization_middleware.py` | `HelixSummarizationMiddleware`（继承 langchain `SummarizationMiddleware`）+ `create_summarization_middleware` 工厂 + `SummarizationEvent` / `BeforeSummarizationHook` 协议 | [summarization.md](./references/code/summarization.md) |
| `core/helix/agents/middlewares/dangling_tool_call_middleware.py` | `DanglingToolCallMiddleware`：三源扫描 + 按 AIMessage 精确位置补占位 ToolMessage | [orphan-toolcall.md](./references/code/orphan-toolcall.md) |
| `core/helix/agents/middlewares/loop_detection_middleware.py` | `LoopDetectionMiddleware`：hash + per-tool frequency 双层检测 + 延迟注入 + 硬停双清 | [loop-and-budget.md](./references/code/loop-and-budget.md) §1 |
| `core/helix/agents/middlewares/token_budget_middleware.py` | `TokenBudgetMiddleware`：三维 fraction + diff 累加 + 两段降级 | [loop-and-budget.md](./references/code/loop-and-budget.md) §2 |
| `core/helix/agents/middlewares/_bounded_dict.py` | `BoundedDict`：共享 FIFO 驱逐 OrderedDict，供 Loop/Budget 防 leak | [loop-and-budget.md](./references/code/loop-and-budget.md) §3 |
| `core/helix/agents/memory/summarization_hook.py` | `memory_flush_hook`：摘要前把待压消息灌进记忆队列 | [summarization.md](./references/code/summarization.md) §3 |
| `core/helix/config/summarization_config.py` | `SummarizationConfig` + `ContextSize` | [summarization.md](./references/code/summarization.md) §4 |
| `core/helix/config/loop_detection_config.py` | `LoopDetectionConfig` + `ToolFreqOverride` | [loop-and-budget.md](./references/code/loop-and-budget.md) §4 |
| `core/helix/config/token_budget_config.py` | `TokenBudgetConfig` | [loop-and-budget.md](./references/code/loop-and-budget.md) §5 |
| `core/helix/agents/middlewares/system_message_coalescing_middleware.py` | 第 23 项（完整源码见 [[system-prompt-template]]） | - |
| `core/helix/agents/lead/agent.py` | `build_middlewares`：四件套按 16/25/26 号位 append（第 6 在 base 段） | 各模块"装配片段"节 |

### 模块入口与索引

**摘要中间件**（完整源码见 [summarization.md](./references/code/summarization.md)）：
- `HelixSummarizationMiddleware`：继承 langchain `SummarizationMiddleware`，重写 `_create_summary` / `_acreate_summary` 走 nostream 标记的模型副本（`TAG_NOSTREAM` 防摘要 token 流被 `messages-tuple` 流回调抓成幽灵 AI 消息；`self.model` 保留不打标供父类 profile / ls_params 检查）。
- `_prepare_compaction`：触发阈值判断 -> `_determine_cutoff_index` 切分 -> `_preserve_dynamic_context_reminders` 保护 reminder ID-swap 对。
- `compact_state` / `acompact_state`：手动 `/compact` 路径与自动路径共同入口，fire hooks 后调 LLM 生成摘要。
- `_build_summary_prompt`：增量摘要（`<existing_summary>` + `<new_messages>`），`_trim_summary_section_text` token 裁剪。
- `create_summarization_middleware` 工厂：lead 自动路径与手动 `/compact` 路径共同入口，防 model 解析 / hooks / prompt / retention 漂移。
- `memory_flush_hook`：注册为 `BeforeSummarizationHook`，历史被压掉前先灌记忆队列。
- `SummarizationConfig`：`trigger`（单条或 list，任一满足）+ `keep`（保留窗口）+ `trim_tokens_to_summarize`。

**孤儿清理**（完整源码见 [orphan-toolcall.md](./references/code/orphan-toolcall.md)）：
- `_message_tool_calls`：三源归一化（`tool_calls` + `additional_kwargs["tool_calls"]` + `invalid_tool_calls`）。
- `_build_patched_messages`：按 AIMessage 顺序重组，ToolMessage 紧贴其后，缺的补合成占位。
- `_synthetic_tool_message_content`：interrupted 给中断文案；invalid 给参数错误引导，`write_file` 专门给长引导（issue #2894 防 malformed 巨大 payload 回显）。
- base 段第 6 项，`include_dangling_tool_call_patch=True` 控制 lead + 子代理都挂。

**循环检测 + token 预算**（完整源码见 [loop-and-budget.md](./references/code/loop-and-budget.md)）：
- `LoopDetectionMiddleware`：`_hash_tool_calls`（order-independent md5）+ `_stable_tool_key`（read_file line bucket / write_file full args / 其他 salient fields）+ `_track_and_check` 双层检测 + `_pending_warnings` LRU cap + `from_config` / `reset` / `consume_stop_reason`。
- `TokenBudgetMiddleware`：`_apply` diff 累加 + 三维 fraction + `_inject_warnings` / `_clear_run_state` / `consume_stop_reason`。
- `BoundedDict`：`OrderedDict` 子类，`__setitem__` 时 FIFO 驱逐，`maxsize=1000`。
- `LoopDetectionConfig`：Pydantic 校验 `hard_limit >= warn_threshold`、`tool_freq_hard_limit >= tool_freq_warn`；`TokenBudgetConfig`：校验 `hard_stop_threshold >= warn_threshold`。
- 两者装配在 25/26 号位，SafetyFinishReason（28）注册在其后--逆序 `after_model` 使 Safety 先清，Loop/Budget 再计数。

**动态时序**（一次长 turn 穿越四件套）：

```
state, config -> graph.astream
  before_agent 链（正序）
    25 LoopDetection? -> _clear_other_run_pending_warnings（清其他 run 旧告警）
    26 TokenBudget?   -> before_agent 把历史 AIMessage 标 seen（不计入本 run 预算）
  before_model 链（正序）
    16 Summarization? -> _maybe_summarize：触发则 RemoveMessage(ALL) + preserved + summary_text
  model 节点
    wrap_model_call 链（洋葱，外->内）
      6 DanglingToolCall（补孤儿 ToolMessage 到精确位置）
        -> 23 SystemMessageCoalescing（合并 SystemMessage，见 [[system-prompt-template]]）
        -> 25 LoopDetection? -> _augment_request（排空 pending_warnings，追加 HumanMessage 到末尾）
        -> 26 TokenBudget?   -> _inject_warnings（追加 budget_warning HumanMessage）
        -> 真实模型
    after_model 链（逆序：29->1）
      28 SafetyFinishReason? -> 先清安全终止 tool_calls（逆序使 Safety 先于 Loop/Budget）
      25 LoopDetection?       -> _track_and_check：hash/freq 检测，hard_stop 双清，warn 队列
      26 TokenBudget?         -> _apply：diff 累加 + 三维 fraction，hard_stop 双清，warn 队列
  tools 节点（若 tool_calls 没被 hard_stop 清空）
  循环回 before_model 直到无 tool_calls 或被 hard_stop 截停
  after_agent 链（正序）
    25 LoopDetection? -> _clear_current_run_pending_warnings（清本 run transient 告警）
    26 TokenBudget?   -> _clear_run_state（清 warned/pending/seen/usage；_stop_reason 留给 executor）
  run 返回 -> 子代理 executor 调 consume_stop_reason(run_id) 读 loop_capped / token_capped
```

## 反模式与陷阱

- ❌ **在 `after_model` 直接注入告警 HumanMessage** -> 此时 tools 节点没跑，没有配对 ToolMessage，告警落在 `AIMessage(tool_calls)` 与其 ToolMessage 之间，OpenAI / Moonshot 直接拒，Anthropic 禁中段 SystemMessage。修复：`after_model` 只队列，`wrap_model_call` 排空时追加到**所有消息末尾**。
- ❌ **硬停只清结构化 `tool_calls` 不清 `additional_kwargs["tool_calls"]`** -> provider 适配器仍序列化原始 payload 下发，循环不停。修复：`_build_hard_stop_update` 同时 pop `additional_kwargs["tool_calls"]` 与 `function_call`，`finish_reason: tool_calls -> stop`。
- ❌ **摘要把 dynamic-context reminder 也压掉** -> DynamicContext 丢失日期锚点，下一轮在错误位置重注入。修复：`_preserve_dynamic_context_reminders` 按 `additional_kwargs["dynamic_context_reminder"]` 标记把 reminder 及其 ID-swap 对捞回"保留"。
- ❌ **摘要 LLM 不打 TAG_NOSTREAM** -> 摘要 token 流被 `messages-tuple` 流回调抓到，广播成幽灵 AI 消息。修复：专属模型副本 `.with_config(tags=[TAG_NOSTREAM])`。
- ❌ **摘要文本作为新 SystemMessage 写进 messages** -> 被再次摘要（递归）、占用 reducer 去重逻辑。修复：摘要写到独立 `state["summary_text"]` 通道，由 DurableContextMiddleware 投影。
- ❌ **DanglingToolCall 用 `before_model` 而非 `wrap_model_call`** -> `before_model` 返回列表经 reducer 追加末尾，ToolMessage 不再紧贴 AIMessage，因果序破坏。修复：`wrap_model_call` 在最终载荷重组。
- ❌ **DanglingToolCall 只扫 `msg.tool_calls` 不扫 `additional_kwargs` 与 `invalid_tool_calls`** -> malformed payload 与 invalid JSON args 的 call 漏掉，下次仍 4xx。修复：`_message_tool_calls` 三源归一化。
- ❌ **LoopDetection hash 按原始顺序拼接** -> 同一组调用乱序 hash 不同，漏报。修复：`_hash_tool_calls` 归一化为 `(name, stable_key)` 多重集后**排序**再 md5。
- ❌ **read_file 用全 args hash 做 stable_key** -> 渐进式读同文件不同行段算不同 key，Layer 1 漏报。修复：`_stable_tool_key` 对 read_file 用 `path + line bucket`（200 行一桶）。
- ❌ **TokenBudget 直接累加每条 AIMessage 的 usage_metadata** -> TokenUsageMiddleware 把子代理 token 追溯回填，同一条消息 usage 本轮"变大"，直接加重复计数。修复：diff 累加 `max(0, current - prev)`。
- ❌ **per-run 状态用普通 dict 不用 BoundedDict** -> lead 中间件实例长生命周期，每个废弃 run 留一条，无限 leak。修复：全用 `BoundedDict(1000)`。
- ❌ **hard_stop raise 异常** -> run 直接失败，前功尽弃。修复：strip tool_calls 让 run 自然结束产最终答，stop_reason 经 `consume_stop_reason` 上报。
- ❌ **`_stop_reason` 被 `after_agent` 清掉** -> executor 在 run 返回后才读，清早就丢了。修复：`_clear_run_state` 只清 warned/pending/seen/usage，不清 `_stop_reason`。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `summarization.enabled` | app config | 16 摘要中间件总开关 |
| `summarization.trigger` | app config | 触发阈值，单条或 list（tokens/messages/fraction 任一满足） |
| `summarization.keep` | app config | 保留窗口（默认 messages:20） |
| `summarization.trim_tokens_to_summarize` | app config | 摘要 prompt 自身 token 上限（默认 4000，null 跳过裁剪） |
| `summarization.model_name` | app config | 摘要专用模型（null 用轻量默认） |
| `loop_detection.enabled` | app config | 25 循环检测总开关（默认 true） |
| `loop_detection.warn_threshold` / `hard_limit` | app config | Layer 1 hash 告警/硬停阈值（默认 3/5） |
| `loop_detection.window_size` | app config | Layer 1 滑动窗口（默认 20） |
| `loop_detection.tool_freq_warn` / `tool_freq_hard_limit` | app config | Layer 2 per-tool-type 频率阈值（默认 30/50） |
| `loop_detection.tool_freq_overrides` | app config | per-tool 单独阈值（如批处理 bash 抬高） |
| `loop_detection.max_tracked_threads` | app config | per-thread LRU 上限（默认 100） |
| `token_budget.enabled` | app config | 26 token 预算总开关（默认 false） |
| `token_budget.max_tokens` | app config | 每 run 总 token 上限（默认 200000） |
| `token_budget.max_input_tokens` / `max_output_tokens` | app config | 可选的输入/输出单独上限 |
| `token_budget.warn_threshold` / `hard_stop_threshold` | app config | 告警/硬停 fraction（默认 0.8/1.0） |

**关键日志串**（排障时 grep）

- `Injecting N placeholder ToolMessage(s) for dangling tool calls` - 6 DanglingToolCall 补占位
- `Summary generation failed; skipping compaction this turn` - 16 摘要 LLM 失败降级
- `before_summarization hook ... failed` - 16 memory_flush_hook 异常（不阻塞摘要）
- `Loop hard limit reached - forcing stop` - 25 Layer 1 hash 硬停
- `Repetitive tool calls detected - injecting warning` - 25 Layer 1 hash 告警队列
- `Tool frequency hard limit reached - forcing stop` - 25 Layer 2 per-tool 硬停
- `Tool frequency warning - too many calls to same tool type` - 25 Layer 2 per-tool 告警队列
- `Token budget hard stop triggered for run ...: ... limit exceeded` - 26 预算硬停
- `Token budget warning triggered for run ...: ... limit at N%` - 26 预算告警队列
- `Evicted loop tracking for thread ... (LRU)` - 25 thread LRU 驱逐

**自测方向**

- **摘要触发**：构造超过 `trigger` 阈值的历史，断言 `before_model` 返回 `RemoveMessage(REMOVE_ALL_MESSAGES) + preserved + summary_text`；未触发返回 None。
- **摘要保护 reminder**：历史含 dynamic-context reminder（带 `additional_kwargs["dynamic_context_reminder"]=True`）+ 其 `__user` 对，触发摘要后断言 reminder 与 `__user` 都在 preserved、不在 messages_to_summarize。
- **摘要失败降级**：mock 摘要 LLM 抛异常，断言 `compact_state` 返回 None、run 不阻塞。
- **孤儿补占位**：构造 `AIMessage(tool_calls=[{id:"x"}])` 无配对 ToolMessage，断言 `_build_patched_messages` 在 AIMessage 后插入 `ToolMessage(status="error", tool_call_id="x")`。
- **孤儿三源**：分别构造只有 `tool_calls` / 只有 `additional_kwargs["tool_calls"]` / 只有 `invalid_tool_calls` 的 AIMessage，断言三源都触发补占位。
- **孤儿不改 state**：补占位后断言 `request.messages` 是新列表，原 state messages 引用不变。
- **循环 Layer 1 告警/硬停**：连续 3 turn 发同 hash tool_calls 断言第 3 turn 队列告警；连续 5 turn 断言第 5 turn 返回 stripped_msg（tool_calls=[]、additional_kwargs 无 tool_calls、finish_reason=stop、content 含 [FORCED STOP]）。
- **循环 Layer 2 频率**：30 turn 调 `read_file`（不同 path）断言第 30 turn 告警、第 50 turn 硬停。
- **循环 order-independent**：turn A 调 [tool1, tool2]，turn B 调 [tool2, tool1]，断言两者 hash 相同。
- **循环 stop_reason**：硬停后断言 `consume_stop_reason(run_id) == "loop_capped"`，再次 consume 返回 None（pop 语义）。
- **预算 diff 累加**：一条 AIMessage 的 usage_metadata 从 (100, 50) 变 (150, 80)（追溯回填），断言只累加 diff (50, 30)。
- **预算三维 fraction**：total 未超但 output 超单独上限，断言 trigger_reason == "output"。
- **预算 before_agent 标 seen**：run 开始时历史有 AIMessage，断言它们进 seen、`_apply` 不把它们计入累计。
- **预算 stop_reason**：hard_stop 后断言 `consume_stop_reason(run_id) == "token_capped"`，`after_agent` 后仍可读（不清）。
- **BoundedDict 防 leak**：插入 1001 个 run_id，断言最老的被驱逐（FIFO）。
- **延迟注入 pairing**：`after_model` 队列告警后断言当前 state messages 不变；`wrap_model_call` 排空时 HumanMessage 在所有 ToolMessage 之后。

## 进一步阅读

- 摘要中间件完整源码 + 工厂 + hook + config：[references/code/summarization.md](./references/code/summarization.md)
- 循环检测 + token 预算 + BoundedDict 完整源码 + config：[references/code/loop-and-budget.md](./references/code/loop-and-budget.md)
- 孤儿 tool_call 清理完整源码：[references/code/orphan-toolcall.md](./references/code/orphan-toolcall.md)
- 关联 skill：[[e2e-request-lifecycle]]（⑤中间件 链路位置）、[[middleware-chain-design]]（29 项链顺序 + SafetyFinishReason 逆序先于 Loop/Budget）、[[system-prompt-template]]（DynamicContext reminder + SystemMessageCoalescing，本 skill 引用不重复）、[[memory-system-design]]（memory_flush_hook 把待压消息灌进记忆队列）、[[subagent-delegation]]（子代理镜像挂 Loop/Budget + consume_stop_reason 上报）、[[thread-state-and-reducers]]（summary_text 通道 + RemoveMessage/REMOVE_ALL_MESSAGES 协议）、[[safety-and-guardrails]]（SafetyFinishReason 与 Loop/Budget 的逆序协作）、[[durable-context-design]]（summary_text 投影回模型调用）
- LangChain SummarizationMiddleware 文档：https://python.langchain.com/docs/concepts/middleware
