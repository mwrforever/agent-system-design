# Implementation Notes — context-window-management

> 适用范围：LangChain ≥ 1.x 中“上下文窗口”相关的所有中间件协作：动态注入、清洗、压缩、合并、提供商兼容。
> 关联：[[middleware-chain-design]]（注册顺序）、[[system-prompt-template]]（静态 prompt）、[[thread-state-and-reducers]]（messages 字段语义）。

---

## 1. 组件矩阵

| 通用组件名 | 真实职责 | 关键 API / 钩子 |
|---|---|---|
| Dynamic Context 中间件 | 把日期/记忆作为 `<system-reminder>` 注入首条 HumanMessage 之前 | `before_agent / abefore_agent`；ID-swap 保持 message id 稳定，跨日触发增量注入 |
| Skill Activation 中间件 | 严格解析 `/skill-name task` 语法激活当前回合的 skill | `before_agent`；命中后把 SKILL.md 体作为隐藏的当前回合上下文塞入 |
| Input Sanitization 中间件 | 清洗用户输入（控制字符、危险标记） | `wrap_model_call`，链路最外层 |
| Tool Output Budget 中间件 | 限制单次工具返回字节数 | `wrap_tool_call` 后做截断；也可在 `after_model` 检查未消费历史 |
| Summarization 中间件 | 接近上下文上限时压缩历史 | `wrap_model_call` 内部决策；触发条件可基于 token / 消息数 / max input fraction |
| Dangling Tool Call 中间件 | 为缺响应的 tool_call 注入占位 ToolMessage | `wrap_model_call`；防止提供商以 “tool_call_ids did not have response” 报错 |
| View Image 中间件 | 把已查看图像的 base64 注入到下一次请求中 | `wrap_model_call`，仅当模型 `supports_vision` |
| System Message Coalescing 中间件 | 合并所有 SystemMessage 为单条领头消息 | `wrap_model_call`，最贴近提供商 |
| Token Usage / Token Budget 中间件 | 单次 / 整 run 的用量记录与上限 | `after_model` 累加；超额可强制终止 |
| Loop Detection 中间件 | 重复工具调用检测 + 警告注入 + 硬截停 | `after_model` 检测；`wrap_model_call` 注入告警 HumanMessage |

### 几个“通道”的职责切分

| 通道 | 写入位置 | 持久化 |
|---|---|---|
| 静态系统提示 | `system_prompt` 参数 | 不持久（每次渲染同串） |
| 动态系统提示 | `<system-reminder>` SystemMessage（独立 ID） | 写入 messages，受 reducer 管理 |
| 用户原始消息 | HumanMessage（独立 ID，例如 `{base}__user`） | 写入 messages |
| 工具响应 | ToolMessage / Command | 写入 messages |
| 仅本次请求的临时数据 | `ModelRequest.system_message / messages` | **不写回 state** |

---

## 2. 关键调用时序

### 时序 A：首轮注入（无既存日期标记）

```
before_agent:
  DynamicContext._inject:
    last_date = _last_injected_date(messages)  # None
    first_idx = 第一个可注入 HumanMessage
    date_reminder = "<system-reminder><current_date>YYYY-MM-DD, Weekday</current_date></system-reminder>"
    memory_block  = "<memory>…</memory>"  (可选)
    ID-swap：
      messages[first_idx] (id=X) →
        SystemMessage(content=date_reminder, id=X, kwargs={"reminder_date":...})
        HumanMessage(content=memory_block,  id=X__memory)   # 可选
        HumanMessage(content=原内容,        id=X__user)
  返回 {"messages": result_msgs}
add_messages reducer → 用同一 id 替换原消息
```

### 时序 B：跨日（midnight crossing）

```
_last_injected_date == "2026-06-25"，now == "2026-06-26"
  → 在“当前最后一条 HumanMessage”位置注入轻量级 date-update reminder
  → 同样走 ID-swap；新 reminder 持久化到 state，历史里不再触发
```

### 时序 C：模型调用前的多层清洗与压缩

```
wrap_model_call 链（外→内）:
  InputSanitization.awrap_model_call(req, next):
    req = req.override(messages=[clean(m) for m in req.messages])
    return await next(req)

  ToolOutputBudget.awrap_model_call:
    req = enforce_per_tool_chunk_budget(req)
    ...

  Summarization.awrap_model_call:
    if triggered(req): req = req.override(messages=summarize(req.messages))
    ...

  ViewImage.awrap_model_call (仅 vision 模型):
    req = inject_image_payload(req, state["viewed_images"])
    ...

  SystemMessageCoalescing.awrap_model_call:
    req = coalesce_system_messages(req)
    return await next(req)            # ← 真实模型调用
```

### 时序 D：System Message 合并

```
入：
  req.system_message = SystemMessage(static prompt, id=base)
  req.messages = [SystemMessage(reminder1), HumanMessage, …, SystemMessage(reminder2-midnight)]

合并：
  parts = [system_message, *(SystemMessage in messages)]
  dedup dynamic_context_reminder (跨日时只保留最新一条 reminder_date)
  merged.content = "\n\n".join(_flatten_content(p.content) for p in parts)
  merged.id = parts[0].id
  merged.additional_kwargs = merge(parts[*].additional_kwargs)

出：
  req.system_message = merged
  req.messages = [m for m in req.messages if not isinstance(m, SystemMessage)]
```

---

## 3. 数据契约 / 类型签名

```python
from typing import override
from collections.abc import Awaitable, Callable
from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelRequest, ModelResponse, ModelCallResult
from langchain_core.messages import HumanMessage, SystemMessage, ToolMessage

# DynamicContext 标记（写在 SystemMessage.additional_kwargs）
_DYNAMIC_CONTEXT_REMINDER_KEY = "dynamic_context_reminder"  # bool
_REMINDER_DATE_KEY            = "reminder_date"             # "YYYY-MM-DD, Weekday"

def is_dynamic_context_reminder(msg) -> bool:
    return isinstance(msg, (SystemMessage, HumanMessage)) \
       and bool(msg.additional_kwargs.get(_DYNAMIC_CONTEXT_REMINDER_KEY))

class SystemMessageCoalescer(AgentMiddleware[AgentState]):
    @override
    async def awrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], Awaitable[ModelResponse]],
    ) -> ModelCallResult:
        return await handler(_coalesce(request))

# Summarization trigger
class SummarizationTrigger:
    type: str         # "tokens" | "messages" | "fraction"
    threshold: float
    def to_tuple(self) -> tuple: ...
```

---

## 4. 关键不变量

1. **静态系统提示在整个会话内字节级稳定** — 动态部分一律走 reminder。违反后果：prefix-cache 命中跌至 0，单次成本翻倍。
2. **ID-swap 必须用稳定后缀** — 例如 `X__user` / `X__memory` / `X__system`。再次进入注入逻辑时通过后缀判定“已注入”跳过。违反后果：每次注入生成新 id，链路无限增长，幽灵消息执行。
3. **动态 reminder 的权威日期必须存 `additional_kwargs.reminder_date`** — 不能从 content 正则解析。违反后果：包含 `<current_date>` 的用户消息被误判为 reminder。
4. **memory 永远写成 HumanMessage** — 不要写成 SystemMessage。违反后果：用户可影响的数据获得 system 权威（OWASP LLM01）。
5. **System Message Coalescing 只改 `ModelRequest`，不写 state** — 持久化历史保持原貌。违反后果：summarization / memory 等扫历史的中间件被错信号干扰。
6. **跨日时只保留最新 reminder_date 的 reminder** — 提供商对“多日期”会困惑。违反后果：模型给出错误日期。
7. **summarization 不可删除最后一个 user + assistant 配对** — 必须保留最近完整轮次。违反后果：模型“忘记”刚刚收到的指令。
8. **dangling tool_call 必须在模型调用前修复** — 给每个未配对 tool_call 注入占位 ToolMessage。违反后果：提供商 4xx，整轮失败。
9. **vision payload 注入仅在模型 `supports_vision` 时执行** — 非 vision 模型收到 base64 会直接 400。违反后果：图像查看后整轮崩溃。
10. **token budget 命中要早于真实调用** — 在 `wrap_model_call` 内部决策，不要等 `after_model` 再补刀。违反后果：已花钱仍超额。

---

## 5. 常见踩坑

1. **`DynamicContext` 同步钩子做 tiktoken 首次下载** — 阻塞事件循环数十分钟。修复：异步钩子 `asyncio.to_thread + wait_for(timeout)`，超时降级。
2. **正则匹配 `<current_date>` 来判断 reminder** — 用户消息内出现该字符串就被误判。修复：用 `additional_kwargs` 标志位。
3. **Summarization 把 reminder 也压缩掉** — 之后失去时间锚点。修复：压缩前过滤 `is_dynamic_context_reminder`。
4. **System Message Coalescing 改写了 `state["messages"]`** — 后续 reducer 把 SystemMessage 全部删除。修复：只在 request 层面合并，state 不动。
5. **ID-swap 时丢失 `additional_kwargs`** — 上传文件标记、隐藏标记被清空。修复：完整传递并视情况合并。
6. **`__user` 后缀用 `in` 判定而非 `endswith`** — message id 中部含该子串就误判。修复：严格 `endswith("__user")`。
7. **`memory` 段写入了过多 token 撑爆窗口** — 修复：渲染时按 `max_injection_tokens` 截断，且优先保留 `guaranteed_categories`。
8. **vision 中间件每轮都重发同一图** — 上下文成倍膨胀。修复：发送后清空 `viewed_images`（reducer 的 `{}` 清空协议）。
9. **dangling tool_call 修复时给的 ToolMessage `content` 太长** — token 浪费。修复：固定短模板 `"interrupted: no response"`。
10. **Summarization 触发器只看 tokens 而忽略 messages 数** — 短消息洪流冲爆窗口。修复：trigger 用 list 形式同时设置 tokens / messages。
11. **`InputSanitization` 不是最外层** — LLM error 重试时拿到的是已被内层中间件处理过的消息。修复：注册顺序保证它在 `wrap_model_call` 最外层。
12. **Loop Detection 注入告警消息成 SystemMessage** — Anthropic 等不允许中段 SystemMessage。修复：注入为 `HumanMessage`，附在 ToolMessage 之后。

---

## 6. 调参旋钮 + 调试入口

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `memory.injection_enabled` / `max_injection_tokens` / `token_counting` | app config | 控制 `<memory>` 体量与 tiktoken 行为 |
| `summarization.enabled` / `trigger` / `keep` / `trim_tokens_to_summarize` | app config | 何时压缩、保留多少 |
| `preserve_recent_skill_count / tokens / tokens_per_skill` | summarization 子配置 | 压缩时对近端 skill 调用的保护额度 |
| `tool_output_budget.*` | app config | 单次工具返回上限（字节/字符/tokens） |
| `view_image` 是否启用 | 模型 `supports_vision` | 见 [[agent-graph-factory]] |
| `safety_finish_reason.enabled` | app config | 提供商安全终止保护 |
| Coalescer 默认开启 | 无开关 | 提供商兼容必备 |
| `INJECT_TIMEOUT_SECONDS` | DynamicContext 常量 | tiktoken 冷启动护栏（默认 5 秒） |

**关键日志串**：

- `DynamicContextMiddleware: injecting full reminder (has_memory=…)` — 首轮注入。
- `DynamicContextMiddleware: midnight crossing detected` — 跨日重注入。
- `DynamicContextMiddleware: injection timed out (5.0s); skipping memory/date injection` — tiktoken 冷启降级。
- `Summarization: messages_to_summarize=N preserved=M tokens_before=… tokens_after=…` — 压缩落地。
- `SystemMessageCoalescing: merged N system blocks` — 合并次数。
- `LoopDetection: pending warning queued (count=…)` / `hard-stop forcing final answer` — 重复工具调用控制。

**测试方向**：

- prefix-cache 稳定性：连续 5 轮请求，断言静态 system_prompt 字节级相等且 messages 中静态部分不被破坏。
- 跨日：mock `datetime.now()` 跨午夜两侧，断言只新增一条 date-update reminder 且只保留最新一条 `reminder_date`。
- 用户输入伪装：HumanMessage 内含 `<current_date>2099-01-01</current_date>` → `_last_injected_date` 必须忽略它（依赖 kwargs 标志）。
- Summarization 保护：压缩后最后一轮 user/assistant 必须完整保留；reminder 不被删除。
- vision 注入清空：调用 view_image 后下一轮 base64 出现一次，再下一轮 `viewed_images` 已清空。
- dangling tool_call：构造一条只含 tool_calls 的 AIMessage，无对应 ToolMessage → 中间件应注入占位再发模型。
- SystemMessage 合并：构造 `system_message + 2 reminder` → 合并后 messages 中已无 SystemMessage；合并后的 id 与原 `system_message.id` 一致。

---

相关 skill：[[middleware-chain-design]] · [[system-prompt-template]] · [[thread-state-and-reducers]] · [[memory-system-design]] · [[agent-graph-factory]]
