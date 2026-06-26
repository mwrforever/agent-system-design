# Implementation Notes — safety-and-guardrails

> 本文档总结 Guardrail / Safety 防御链的组件分工、hook 位置语义、Provider 协议与失败模型。
> 占位路径：`<harness-pkg>/guardrails/`、`<harness-pkg>/agents/middlewares/`。

## 一、组件拓扑与 hook 位置

安全 / 守门链由六个中间件 + 一组检测器组合而成。每个组件都绑定到中间件链路上的特定 hook，hook 位置即语义：

| 组件 | hook | 触发时机 | 作用 |
|------|------|----------|------|
| `InputSanitizationMiddleware` | `wrap_model_call`（最外层） | 调模型前 | 清理消息中伪造的结构标签（`</system-reminder>`、注入的 system 段等），是所有内层包括 retry 共同看到的"消过毒"输入 |
| `GuardrailMiddleware` | `wrap_tool_call` | 每次工具调用前 | 调 `GuardrailProvider.evaluate(GuardrailRequest) → GuardrailDecision`；拒绝时返回 error `ToolMessage`，allow 时透传到下层 handler |
| `SandboxAuditMiddleware` | `wrap_tool_call`（前置） | 每次沙箱 / 文件类工具调用前 | 把工具名、参数摘要、决策等写审计事件到 `RunJournal`（持久化） |
| `LoopDetectionMiddleware` | `after_model` | 每次模型 response | 滑窗 hash 检测重复 tool_call 模式；`warn_threshold` 注入告警 HumanMessage，`hard_limit` 双清 tool_calls 强制收尾 |
| `SafetyFinishReasonMiddleware` | `after_model`（最先派发） | 每次模型 response | provider `finish_reason ∈ {content_filter / refusal / SAFETY / ...}` 且带 tool_calls 时清空双层 tool_calls + 注入用户态解释 |
| `TokenBudgetMiddleware` | `after_model` | 每次模型 response | 单 run token 上限熔断；超额 → set_status(error) |

LangChain 的中间件 hook 有四个钩子位（`before_agent / wrap_model_call / wrap_tool_call / after_model`）。`wrap_*` 是装饰器型，最外注册最外执行；`after_model` 是事件型，最后注册最先派发。Safety / Guardrail 利用的就是这两条规则——位置错就语义错，单测里最容易抓的就是中间件顺序回归。

子代理图共用同一套 base，再追加对应条件项（详见 [[middleware-chain-design]]）。

## 二、GuardrailProvider 协议

Provider 是协议而非基类——任何实现了 `evaluate` / `aevaluate` 的对象即可注入，由反射按类路径加载（`config.yaml::guardrails.provider.use = "<module>:<ClassName>"`，机制与 model / tool / sandbox 同源）。

```python
@dataclass
class GuardrailRequest:
    tool_name: str
    tool_input: dict
    agent_id: str | None         # passport
    thread_id: str | None
    is_subagent: bool            # 区分父子身份
    timestamp: str               # ISO8601 UTC
    user_id: str | None
    user_role: str | None
    oauth_provider: str | None
    oauth_id: str | None
    run_id: str | None
    tool_call_id: str | None

@dataclass
class GuardrailReason:
    code: str                    # e.g. "oap.tool_not_allowed"
    message: str = ""

@dataclass
class GuardrailDecision:
    allow: bool
    reasons: list[GuardrailReason]
    policy_id: str | None
    metadata: dict
```

`GuardrailMiddleware` 从 `request.runtime.context` 抽取身份字段，构造 `GuardrailRequest` 后调 Provider；Decision 的首条 reason 的 `code` 与 `message` 会被嵌进返回给模型的 error `ToolMessage`，LLM 能据此自我调整路径而不是直接死。

`GuardrailMiddleware` 同时实现 `wrap_tool_call` 与 `awrap_tool_call`——同步 graph 与 async graph 走各自的 Provider 入口（`evaluate` vs `aevaluate`），但拦截语义完全一致。fail-closed 异常路径在 sync / async 两侧都返回 `GuardrailDecision(allow=False, reasons=[GuardrailReason(code="oap.evaluator_error", message="guardrail provider error (fail-closed)")])`，error ToolMessage 文案统一为：

```
Guardrail denied: tool '<name>' was blocked (<code>). Reason: <message>. Choose an alternative approach.
```

内置实现是 `AllowlistProvider(allowed_tools, denied_tools)`——零依赖，单进程足够；OAP 策略源（如 `aport-agent-guardrails`）和自定义业务 Provider 通过反射加入。`AllowlistProvider.aevaluate` 默认转发到 `evaluate`，不做 I/O；写自定义 Provider 时若要走 HTTP 策略服务，记得给 `aevaluate` 单独实现并加 3-5s 超时。

`SafetyTerminationDetector` 是另一条策略接口，用于 provider 安全终止信号识别：

```python
@runtime_checkable
class SafetyTerminationDetector(Protocol):
    name: str
    def detect(self, message: AIMessage) -> SafetyTermination | None: ...
```

返回的 `SafetyTermination` 字段 `(detector, reason_field, reason_value, extras)` 会被原样盖进 `additional_kwargs.safety_termination`，便于审计。Detector 通过 `safety_finish_reason.detectors[]` 反射注入；空列表非法（要禁用就改 `enabled: false`），缺省则用内置 detectors 集（OpenAI / Anthropic / Gemini）。


## 三、配置示例

```yaml
guardrails:
  enabled: true
  fail_closed: true
  passport: "lead-agent-v1"
  provider:
    use: <module.path>:<ClassName>
    config:
      allowed_tools: [read_file, ls, web_search, str_replace]
      denied_tools: [bash]
```

`fail_closed` 决定 Provider 异常时的行为：`true`（默认）走拒绝，`false` 仅 warn 并放行。`passport` 透传到 `GuardrailRequest.agent_id`，供 OAP 策略按 agent 维度审计。

Safety 终止检测配置：

```yaml
safety_finish_reason:
  enabled: true
  detectors:
    - use: <module>:OpenAIFinishReasonDetector
      config: {match: [content_filter]}
    - use: <module>:AnthropicStopReasonDetector
      config: {match: [refusal]}
    - use: <module>:GeminiFinishReasonDetector
      config: {match: [SAFETY, RECITATION]}
```

不指定 `detectors` 时使用 `default_detectors()` 返回的内置组合，覆盖 OpenAI / Anthropic / Gemini 主流 provider。

LoopDetection 配置：

```yaml
loop_detection:
  enabled: true
  warn_threshold: 3
  hard_limit: 5
  window_size: 20
  tool_freq_warn: 30
  tool_freq_hard_limit: 50
  tool_freq_overrides:
    bash: [60, 100]
```

`tool_freq_overrides` 给 bash / 命令工具等高频调用场景留口子，不削弱其它工具的防护。

## 四、关键不变量

1. **位置即语义**：`SafetyFinishReasonMiddleware` 在中间件列表中注册"晚"（在 LoopDetection / 自定义中间件之后）。LangChain factory 把 `after_model` 边逆序连接，所以**最后注册的最先派发**。Safety 必须最先跑——清空 tool_calls 后，Loop / TokenBudget / Subagent 才在"干净"消息上计数，不触发误警，也不把半截 tool_call 喂给执行器。
2. **多层不同位置防御**（深度防御）：
   - 入：消毒（`wrap_model_call` 最外）
   - 中：鉴权 + 审计（`wrap_tool_call`）
   - 出：循环熔断 / 安全终止 / 预算（`after_model`）
3. **Fail-closed 优先**：Provider 抛异常 → `GuardrailDecision(allow=False, reasons=["oap.evaluator_error"])` → error ToolMessage。**绝不**把异常上抛终止整 run。例外是 `GraphBubbleUp`（LangGraph 内部的 interrupt / pause / resume 控制流），必须原样上抛。
4. **审计落 `RunJournal` 而非同步 IO**：高 QPS 时同步写文件会阻塞 worker；统一走 `journal.record_middleware(tag, name, hook, action, changes)`，异步入库（详见 [[observability-tracing]]）。审计写入失败也吞掉，绝不影响 agent 运行。
5. **循环检测 / 安全终止双清**：清结构化 `tool_calls` 字段 + provider 原始 `additional_kwargs["tool_calls"]` 必须同时清，并把 `finish_reason` 保持为 provider 原值（不改写成 `tool_calls`），下游 SSE / 转换器才知道这是被安全抑制不是正常完成。
6. **list-content 兼容**：Anthropic thinking blocks / vLLM reasoning 分段把 `content` 表示成 `list[dict]`；Safety / Loop 的"追加用户态解释"必须保持 list 结构（追加 `{"type":"text", "text":...}` block），不能直接 `str +`，否则 TypeError。
7. **Provider 必须做 5s 内决策**：守门同步阻塞工具调用路径，单 Provider 长尾会把 run 卡死；3-5s 超时是工程默认。
8. **子代理 Guardrail 继承父身份**：`is_subagent=True`，`user_id / user_role / oauth_* / run_id` 全量透传（详见 [[subagent-delegation]]），防止"父被审计、子直通"。
9. **Detector 异常不传染**：`SafetyFinishReasonMiddleware._detect` 对单个 detector 的异常做 `try/except` 并 `logger.exception` 后继续遍历下一个 detector，绝不让某个 detector 的 bug 把所有响应阻断。
10. **不持久化被过滤的 tool arguments**：审计事件只记 `suppressed_tool_call_names / suppressed_tool_call_ids / count`，参数本身就是 provider 过滤掉的内容，重新落盘等于绕开 safety filter。

## 五、调参旋钮与典型踩坑

| 字段 | 默认 | 说明 |
|------|------|------|
| `guardrails.enabled` | `false` | 主开关；关闭时 `GuardrailMiddleware` 不入链 |
| `guardrails.fail_closed` | `true` | Provider 异常时拒绝 / 放行 |
| `loop_detection.warn_threshold` | 3 | 同套 tool_calls 出现次数 → 注入告警 HumanMessage |
| `loop_detection.hard_limit` | 5 | 同套 tool_calls → 双清 + 强制收尾 |
| `loop_detection.window_size` | 20 | 滑窗大小 |
| `loop_detection.max_tracked_threads` | 100 | LRU 上限；超过时 evict 最久未访问的 thread 状态 |
| `loop_detection.tool_freq_warn / hard_limit` | 30 / 50 | 同名工具调用频次（跨参数） |
| `loop_detection.tool_freq_overrides` | None | per-tool 频次覆盖；`{bash: (60, 100)}` 等场景 |
| `safety_finish_reason.detectors` | 内置 3 个 | 可通过 `from_config` 反射扩展；空列表会被拒绝（要禁用就 `enabled: false`） |

LoopDetection 的 hash 策略对不同工具有不同的稳定键选择：

- `read_file`：路径 + start/end 行号按 200 行 bucket，避免连续翻页被误判循环；
- `write_file / str_replace`：内容敏感，全 args hash，避免同路径不同 payload 被合并；
- 其他工具：抽 salient 字段 `(path / url / query / command / pattern / glob / cmd)` 排序后 hash；
- 没有 salient 字段：退化到全 args JSON。

hash 计算用 MD5 取前 12 字符；多 tool_call 按 hash 排序后再 join，让"工具集合"而非"工具顺序"决定循环判定。

常见踩坑：

1. **Guardrail 抛异常未捕获** → 整 run 死。`evaluate` 必须用 try/except 包裹，异常路径走 `fail_closed`。
2. **`SafetyFinishReasonMiddleware` 注册位置错乱** → `after_model` 逆序里跑得晚，清空操作发生在 Loop / TokenBudget 计数**之后**，导致循环计数和 token 账目把被抑制的 tool_calls 也算进去，并把半截参数喂给执行器。
3. **输入消毒规则过广** → 误伤用户合法 HTML / 代码 / `<details>` 标签。规则必须精确锚定模型注入伪标签的 pattern。
4. **审计同步写文件** → QPS 高时阻塞 worker。走 `RunJournal` → 异步 `RunEventStore`。
5. **Provider 不限超时** → 单次 tool call 卡 10s 以上。3-5s 超时 + 熔断。
6. **拒绝时不返回 reason 给模型** → LLM 不知道为啥被拒、继续重试同样的调用。`GuardrailDecision.reasons[0].message` 必须写入 error ToolMessage。
7. **`finish_reason` 改写成 `tool_calls`** → SSE 下游误以为是正常完成，统计错乱。Safety 抑制时 **保留** provider 原始 `finish_reason`。
8. **子代理不带 `is_subagent=True`** → Provider 无法应用"子代理禁用某些工具"的差异策略，权限边界被绕过。
9. **LoopDetection 告警注入到 `after_model`** → OpenAI / Moonshot 拒收：`tool_call_ids did not have response messages`。告警必须延后到 `wrap_model_call`，所有 ToolMessage 已经落位之后再追加 HumanMessage。
10. **Detector `detect()` 有副作用** → 同一条 AIMessage 会被多个 detector 看到，副作用会重复触发。`SafetyTerminationDetector.detect` 协议明确要求 side-effect free。
11. **Provider 返回空 reasons** → 拒绝消息退化到 `"blocked by guardrail policy"` 通用文案，无法定位策略。Decision 必须至少带一条 `GuardrailReason`。


## 六、调试入口

- `RunJournal` 事件 tag：`safety_termination`（安全抑制）、`skill_activation`、`sandbox_audit:*`、`guardrail.decision`（如 Provider 自定义记录）。
- `GuardrailMiddleware` 拒绝日志：`Guardrail denied: tool=%s policy=%s code=%s`；过滤这一行就能拉出全部拒绝事件。fail-closed 路径单独打 `Guardrail provider error (sync/async)` exception log，包含完整堆栈。
- `SafetyFinishReasonMiddleware`：被抑制的 AIMessage 在 `additional_kwargs["safety_termination"]` 留下 `{detector, reason_field, reason_value, suppressed_tool_call_count, suppressed_tool_call_names, extras}`；事后审计直接捞这个键。`finish_reason` 保留 provider 原值（`content_filter / refusal / SAFETY`），不会被改写。
- `SafetyFinishReasonMiddleware._emit_event` 还会通过 `StreamWriter` 发一帧 `safety_termination` 自定义事件给 SSE，前端可据此清理"工具进行中"占位卡片。事件 payload 含 `thread_id`，便于关联会话。
- `SafetyFinishReasonMiddleware._record_audit_event` 通过 `runtime.context["__run_journal"]` 拿 run-scoped journal，写一条 `middleware:safety_termination` 持久事件。注意：被过滤的 tool **arguments** 不会被记录（那是 provider 过滤的内容本身）；只记 names / ids / count / detector。
- `LoopDetectionMiddleware` 注入的告警是 `HumanMessage("[LOOP DETECTED] ...")`；硬停时模型最后一条 AIMessage 末尾追加 `[FORCED STOP] ...`，便于在对话回放里定位熔断点。频次告警走另一条文案 `[LOOP DETECTED] You have called <tool> <count> times ...`，与 hash 重复告警区分。
- `clone_ai_message_with_tool_calls` 是清空 tool_calls 的统一入口，同时处理结构化 `tool_calls` 字段、`additional_kwargs.tool_calls` 与 `additional_kwargs.function_call`，避免某条路径漏清导致执行器仍然派发半截参数。

## 相关 skill

- [[middleware-chain-design]]
- [[subagent-delegation]]
- [[long-running-and-cancellation]]
- [[observability-tracing]]
- [[sandbox-tools-and-safety]]
