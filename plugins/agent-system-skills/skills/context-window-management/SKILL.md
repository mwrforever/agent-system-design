---
name: context-window-management
description: 治理 agent 的上下文窗口——摘要压缩、多 SystemMessage 合并、孤儿 tool_call 补占位、循环检测硬停、token 预算。覆盖五件套中间件协作。
---

## 何时用

- agent 跑长了 LLM 报 token overflow
- 用户中断后续聊 OpenAI / Anthropic 报"tool_calls without corresponding tool"
- agent 陷入"调 A → 调 B → 调 A → 调 B"循环不出来
- 单 run 想限制 token 用量（多用户 / 限免场景）
- vLLM / Qwen 拒绝非首条 SystemMessage

## 设计思想

1. **每个问题一个独立中间件**，不要在一个超级中间件里塞所有逻辑。
2. **摘要走 LLM 子调用**，老消息折叠为 SystemMessage("summary")，**保留近 N 条**给模型上下文。
3. **多 SystemMessage 合并放最后**：所有上游中间件可以自由插 SystemMessage，出口前合并为首条单一 SystemMessage。
4. **循环检测 = 硬停**：检测到 tool_call 重复模式 → 清空 `tool_calls` + 原始 provider tool_calls 元数据 → 强制模型出文本最终答。
5. **token 预算放最后**：摘要 / 工具截断之后再统计剩余 token，预算用尽 → 终止 run + 友好提示。

## 实现模板

### 摘要中间件骨架

```python
class SummarizationMiddleware(AgentMiddleware):
    def __init__(self, model, trigger, keep, summary_prompt,
                 before_summarization=None):
        self.model = model              # 小模型（便宜）
        self.trigger = trigger          # ("tokens", 12_000) / ("messages", 30) / ("fraction", 0.7)
        self.keep = keep                # ("messages", 6) / ("tokens", 2000)
        self.summary_prompt = summary_prompt
        self.before_summarization = before_summarization or []  # hook：摘要前先 flush memory

    async def before_model(self, state, runtime):
        if not should_trigger(state["messages"], self.trigger):
            return None
        for hook in self.before_summarization:
            await hook(state, runtime)         # 例如 memory_flush_hook
        old, new = split_messages_by_keep(state["messages"], self.keep)
        summary_text = await self.model.ainvoke(
            [SystemMessage(self.summary_prompt), *old]
        )
        summary_msg = SystemMessage(
            content=summary_text.content,
            name="summary",          # 后续中间件可识别"这是摘要不是真历史"
        )
        return {"messages": [RemoveMessage(id=m.id) for m in old] + [summary_msg]}
```

### 多 SystemMessage 合并

```python
class SystemMessageCoalescingMiddleware(AgentMiddleware):
    """合并所有 SystemMessage 为首条单一 SystemMessage（per-request 视图）.

    只动 wrap_model_call 的 payload，不改 checkpoint state.
    """
    def wrap_model_call(self, request, handler):
        msgs = request.messages
        systems = [m for m in msgs if isinstance(m, SystemMessage)]
        others  = [m for m in msgs if not isinstance(m, SystemMessage)]
        if len(systems) <= 1:
            return handler(request)
        # 跨日时只留最新的 dynamic_context_reminder
        systems = dedupe_dynamic_context_reminders(systems)
        merged = SystemMessage(content="\n\n".join(s.content for s in systems))
        request = replace(request, messages=[merged, *others])
        return handler(request)
```

### 孤儿 tool_call 补占位

```python
class DanglingToolCallMiddleware(AgentMiddleware):
    """AIMessage 含 tool_calls 但缺对应 ToolMessage 时补占位."""
    def before_model(self, state, runtime):
        msgs = state["messages"]
        new_messages = []
        for i, msg in enumerate(msgs):
            new_messages.append(msg)
            if not (isinstance(msg, AIMessage) and msg.tool_calls):
                continue
            for tc in msg.tool_calls:
                if not _has_matching_tool_message(msgs[i+1:], tc["id"]):
                    new_messages.append(ToolMessage(
                        content="[Tool call was interrupted before completion.]",
                        tool_call_id=tc["id"], name=tc.get("name", "unknown"),
                        status="error",
                    ))
        if len(new_messages) != len(msgs):
            return {"messages": new_messages}
        return None
```

### 循环检测硬停

```python
class LoopDetectionMiddleware(AgentMiddleware):
    def __init__(self, repeat_threshold=3, window=6):
        self.threshold = repeat_threshold
        self.window = window

    def after_model(self, state, runtime):
        last_ai = _last_ai_message(state["messages"])
        if not last_ai or not last_ai.tool_calls:
            return None
        signature = _signature_of_recent_tool_calls(state["messages"], self.window)
        if _max_repeat_count(signature) >= self.threshold:
            # ⭐ 双清：结构化 + provider 原始
            last_ai.tool_calls = []
            last_ai.additional_kwargs.pop("tool_calls", None)
            last_ai.content = (last_ai.content or "") + \
                "\n\n[Loop detected. Producing final answer with available context.]"
            return {"messages": [*state["messages"][:-1], last_ai]}
        return None
```

## 反模式

- ❌ 在摘要中间件里把 `messages` 全清空 → 模型彻底失忆
- ❌ 只清 `tool_calls` 不清 `additional_kwargs["tool_calls"]` → provider 仍下发原始调用，循环继续
- ❌ 把多 SystemMessage 合并写在 checkpoint state 里 → 持久化层永远只剩一条，跨日 reminder 全丢
- ❌ 摘要不留 anchor message → 用户问"刚才提到的 X 是啥"时模型答不上
- ✅ 摘要消息用 `name="summary"` 标记，其他中间件可识别
- ✅ 合并只动 per-request payload，state 保留原始多条 SystemMessage

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[middleware-chain-design]] [[system-prompt-template]] [[memory-system-design]] [[safety-and-guardrails]]
