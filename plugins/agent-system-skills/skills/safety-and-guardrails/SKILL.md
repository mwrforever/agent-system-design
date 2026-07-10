---
name: safety-and-guardrails
description: 设计 lead-agent 级安全层--输入消毒（转义伪造结构标签 + 边界标记）、Guardrail 工具调用授权（allow/deny + 路径授权 + 网络访问策略，可插拔 Provider）、SafetyFinishReason（provider 安全终止时抑制半截 tool_calls）、lead 级 loop/token 预算（hard-stop 软停 + additive stop_reason）。覆盖 fail-closed 拒绝模型、after_model 逆序注册不变量、consume_stop_reason 有界 dict 机制。给出真实代码的模块索引。当你要做提示注入防护、工具调用授权、排查 provider content_filter 循环、或想读懂 lead 级护栏如何以 additive stop_reason 软停而不破契约时调用本 skill。
---

## 何时用

- agent 暴露在公网 / 多用户，需要防御提示注入（用户消息里伪造 `<system-reminder>` / `<system>` 等结构标签）
- 接入了高风险工具（删除文件、转账、发邮件、外部 API 调用），需要工具调用前的授权层
- provider 启用了内容安全审查（OpenAI `content_filter` / Anthropic `refusal` / Gemini `SAFETY`），安全终止时仍返回半截 `tool_calls` 导致 agent 反复重试被过滤的内容
- 想让授权策略可插拔（内置 allow/deny list / OAP / 自定义业务策略源），且 core 不耦合具体策略
- lead agent 需要防退化循环（重复 tool-call）与 token 预算熔断，且截断后仍能产出可用结果而非整 run 失败
- 想读懂 guard cap 如何以 additive `stop_reason`（`token_capped` / `loop_capped`）软停冒泡，而非新增 status 枚举破坏契约

> 本 skill 处于端到端链路的 **⑤中间件** 跳（见 [[e2e-request-lifecycle]]）：输入消毒是 `wrap_model_call` 最外层，Guardrail 是 `wrap_tool_call` 拦截，SafetyFinishReason / LoopDetection / TokenBudget 是 `after_model` 出口链。子代理级 guardrail 三轴（per-subagent turn/token/loop）在 [[subagent-delegation]] 讲，本 skill 讲 lead-agent 级，引用不重复。

## 设计方案（为什么这么设计）

### 核心定位：lead-agent 级安全层，子代理级在别处

lead agent 的安全层由五个独立中间件组成，分布在中间件链的三个 hook 位上：入口消毒（`wrap_model_call` 最外层）、工具调用前授权（`wrap_tool_call`）、出口熔断（`after_model`）。它们都是 **lead-agent 级**--跑在 lead agent 的中间件链上，对 lead run 的消息与工具调用生效。

**与 [[subagent-delegation]] 的边界**：子代理（`task()` 委派的执行体）继承同一套安全基座中间件（LoopDetection / TokenBudget / SafetyFinishReason 镜像防护），但子代理级的 guardrail 三轴（turn/token/loop）+ `consume_stop_reason` 收集 + additive `stop_reason` 冒泡到主代理的完整链路在 [[subagent-delegation]] 讲。本 skill 讲**中间件本身**如何检测 / 抑制 / 暴露 `consume_stop_reason`，不讲子代理执行器如何收集与冒泡。两处互补：本 skill 是"护栏代码"，[[subagent-delegation]] 是"执行器如何读护栏的 cap 原因"。

### 输入消毒：为何转义而非拒绝，为何只清结构标签

用户消息可能含 `<system-reminder>` / `<system>` / `<memory>` 等结构标签--这些是框架注入结构化上下文的标记。若用户消息原样进模型，恶意用户可伪造这些标签劫持模型上下文（提示注入）。

**解法：de-identify-don't-reject（转义而非拒绝）**。把封锁集内的标签 HTML-escape（`<system>` -> `&lt;system&gt;`），标签失去语义但用户意图保留--用户问"how do I use Helix's `<think>` tag?"仍能得到正常回答，而 `<think>` 不会被模型当结构化上下文解析。这与 AWS Bedrock PII ANONYMIZE 同策略：去标识化，不拒绝。

**为何只清结构标签、不动普通 HTML/XML**：封锁集是**有限枚举**（`system-reminder` / `memory` / `current_date` / `think` / `analysis` / `subagent_system` / `skill_system` / `uploaded_files` / `todo_list_system` + 常见注入伪标签 `system` / `instruction` / `role` / `important` / `override` / `ignore` / `prompt`）。普通 HTML/XML（`<div>` / `<span>` / 用户代码里的标签）不转义--否则误伤用户合法内容。

**次级防御：边界标记**。消毒后的输入包裹在 `--- BEGIN USER INPUT ---` / `--- END USER INPUT ---` 纯文本边界标记里（OWASP structured-prompt guidance）。用户文本里若已含边界标记，被 neutralize 成 `[BEGIN USER INPUT]` / `[END USER INPUT]`（视觉相似但不匹配真实分隔符），防 self-suppression 与 break-out 攻击。

**为何在 `wrap_model_call` 最外层**：消毒是 `wrap_model_call` 链表的第一项（最外层洋葱包裹），所有内层中间件（含 LLM 重试）都看到消毒后消息。若消毒在内层，LLM 重试中间件会先看到未消毒内容，触发 provider 级 4xx。

**幂等性与临时性**：只处理"最后一条真用户消息"（从尾向头扫，跳过 ToolMessage / AIMessage / 框架注入的 HumanMessage），已严格包裹的文本原样返回。变换临时（`wrap_model_call` 只改请求载荷，`request.override` 返回新请求），**永不写回 state**--原文经 `additional_kwargs[ORIGINAL_USER_CONTENT_KEY]` 保留，下游（slash skill 激活 / regenerate）可恢复真用户输入。

```python
# 伪代码：输入消毒核心流程（完整源码见 references/code/input-sanitization.md）
def _check_user_content(text):
    if not text.strip(): return text
    text = _BLOCKED_TAG_PATTERN.sub(_escape_tag, text)   # <system> -> &lt;system&gt;，普通 HTML 不动
    if text.startswith(BEGIN) and text.endswith(END):     # 已包裹：只 neutralize 内部边界标记（防 break-out），幂等
        return rewrap(neutralize_inner(text))
    text = _BOUNDARY_TOKEN_RE.sub(neutralize_token, text) # neutralize 用户塞的边界标记
    return f"{BEGIN}\n{text}\n{END}"                       # 包裹

class InputSanitizationMiddleware:
    def wrap_model_call(self, request, handler):          # 最外层：所有内层见消毒后消息
        return handler(self._try_process(request))        # fail-open：异常返回原请求，GraphBubbleUp 原样上抛
```

### 工具调用授权：为何在中间件层而非工具内，为何可插拔

高风险工具（bash / write_file / web_fetch / 转账）需要授权门。把授权逻辑写进每个工具内部有两个问题：(1) 每个工具各自实现，策略 drift；(2) 工具内授权无法拿到**调用上下文**（user_id / user_role / is_subagent / run_id），只能做无状态检查。

**解法：`wrap_tool_call` 中间件层统一拦截**。`GuardrailMiddleware` 在每次工具调用前调 `GuardrailProvider.evaluate(GuardrailRequest) -> GuardrailDecision`，allow 则透传到下层 handler，deny 则返回 error `ToolMessage`（不抛异常）。`GuardrailRequest` 携带 `tool_name` + `tool_input`（完整参数）+ 身份字段（`user_id` / `user_role` / `oauth_provider` / `oauth_id` / `is_subagent` / `run_id` / `tool_call_id`），所以 provider 能做三类策略：

1. **allow/deny list**（内置 `AllowlistProvider`）：按 `tool_name` 做白名单 / 黑名单。零依赖。
2. **路径授权**：provider 读 `tool_input["path"]`，按身份决定是否允许写该路径。
3. **网络访问策略**：provider 读 `tool_input["url"]` / `tool_input["host"]`，按身份 / 角色决定是否允许该出站目标。

**为何 core 只内置 allow/deny、不内置路径 / 网络策略**：路径授权与网络访问策略是**业务规则**，core 不感知。框架只定义 `GuardrailProvider` 协议 + `AllowlistProvider` 兜底，richer 的 OAP 策略源 / 自定义业务 provider 通过**反射加载**（`resolve_variable` 类路径，与 model / tool / sandbox 同源机制）注入。这样 core 不耦合业务策略，业务策略也不依赖 core 内部。

**沙箱级路径授权在别处**：沙箱工具自身的路径白名单（`_is_allowed_local_bash_absolute_path` / `_get_mcp_allowed_paths`）是工具内层的第二道门，在 [[sandbox-tools-and-safety]] 讲。Guardrail 是工具调用前的策略层（按身份 / 角色），沙箱路径限制是工具执行内的物理层（按路径前缀），两者互补不重复。

**Fail-closed 优先**：provider 抛异常时，`fail_closed=true`（默认）返回 `GuardrailDecision(allow=False, reasons=["oap.evaluator_error"])` -> error `ToolMessage`，**绝不**把异常上抛终止整 run。模型读到拒绝原因后可自行换路径。唯一例外是 `GraphBubbleUp`（LangGraph 的 interrupt / pause / resume 控制流），必须原样上抛。`fail_closed=false` 时 provider 异常仅 warn 并放行。

```python
# 伪代码：Guardrail 授权拦截流程（完整源码见 references/code/guardrail-authorization.md）
def wrap_tool_call(self, request, handler):
    gr = self._build_request(request, runtime.context)    # 含 user_id / is_subagent / run_id / tool_input
    try: decision = self.provider.evaluate(gr)
    except GraphBubbleUp: raise                            # 保留 LangGraph 控制流信号
    except Exception:                                     # provider 异常：绝不终止整 run
        decision = deny("oap.evaluator_error") if self.fail_closed else allow_with_warn()
    if not decision.allow:
        return error_tool_message(gr, decision)            # 拒绝原因写进 content，模型读后换路径
    return handler(request)                                # allow -> 透传到下层工具 handler
```

### SafetyFinishReason：何时安全终止 run

某些 provider（OpenAI `finish_reason='content_filter'` / Anthropic `stop_reason='refusal'` / Gemini `finish_reason='SAFETY'`）会在生成中途停止，却仍返回**部分成型**的 `tool_calls`。LangChain 的工具路由把任何带非空 `tool_calls` 的 `AIMessage` 当"去执行这些"，于是半截参数被当作完整调用派发。agent 看到截断的文件，尝试修复，又被过滤，**循环**。

**解法**：`SafetyFinishReasonMiddleware` 在 `after_model` 检测 provider 安全终止信号**且** AIMessage 带 tool_calls 时，剥除 tool_calls（结构化 + provider 原始 `additional_kwargs.tool_calls` + `function_call` 三处同清），追加用户态解释，盖 `additional_kwargs.safety_termination` 可观测性记录。

**何时不干预**：`content_filter` 但**无** tool_calls 的纯文本响应原样放行--部分文本（若有）应自然到达用户。只在"有半截 tool_calls 需要抑制"时才动手。

**可插拔 detector**：不同 provider 用不同字段不同值表达"我为安全停止了"。`SafetyTerminationDetector` 协议 + 三个内置 detector（`OpenAICompatibleContentFilterDetector` / `AnthropicRefusalDetector` / `GeminiSafetyDetector`）覆盖主流 provider。新 provider 通过 `safety_finish_reason.detectors` 反射加载自定义 detector。空 detectors 列表非法（要禁用就 `enabled: false`，避免"中间件在链上却不检测"的最坏情况）。detector 异常不传染--`_detect` 对单个 detector 的异常 `try/except` 后继续遍历下一个。

**不走 `consume_stop_reason`**：provider 安全终止是另一类信号（provider 主动停），不是 guard cap（框架主动熔断），不 surface 为 `token_capped` / `loop_capped`。它只盖 `safety_termination` 可观测性记录 + 发一帧 `safety_termination` SSE 自定义事件（前端据此清理"工具进行中"占位卡片）。

```python
# 伪代码：SafetyFinishReason 抑制流程（完整源码见 references/code/safety-finish-and-budget.md §1-2）
def after_model(self, state, runtime):                    # 注册在 LoopDetection 之后，逆序最先跑
    last = state["messages"][-1]
    if not isinstance(last, AIMessage) or not last.tool_calls:
        return None                                        # 无 tool_calls 的 content_filter 原样放行
    term = self._detect(last)                              # 遍历 detector，单个异常不传染
    if term is None: return None
    patched = clone_ai_message_with_tool_calls(last, tool_calls=[],  # 三处同清（结构化+additional_kwargs+function_call）
        append_text=用户态解释, additional_kwargs={"safety_termination": term记录})
    self._emit_event(term, runtime)                        # 发 safety_termination SSE，前端清占位卡片
    return {"messages": [patched]}                         # finish_reason 保留 provider 原值，不改写
```

### Loop / Token 预算：lead 级 vs subagent 级边界

lead agent 跑长任务时可能退化：重复调同一工具（循环）或烧穿 token（预算）。两个中间件各自独立轴：

| 轴 | 中间件 | 触发 | 机制 |
|---|---|---|---|
| **loop** | `LoopDetectionMiddleware` | 同 hash 重复 warn=3/hard=5，或单工具频率 warn=30/hard=50 | hard-stop 剥 `tool_calls` + 强制收尾 |
| **token** | `TokenBudgetMiddleware` | per-run 累计 token，0.8 warn / 1.0 hard-stop | hard-stop 剥 `tool_calls` + 强制收尾 |

**lead 级 vs subagent 级边界**：这两个中间件的**代码同一份**，lead agent 与子代理都跑（子代理基座续装镜像防护）。差异在**谁来消费 `consume_stop_reason`**：

- **lead 级**：lead run 是顶层 run，没有上层执行器调 `consume_stop_reason`。hard-stop 触发时，run 自然完成出最终答案（末尾追加 `[TOKEN BUDGET EXCEEDED]` / `[FORCED STOP]` 文本）。`_stop_reason` 记录只会在 `BoundedDict` 里老化淘汰（lead 中间件实例跨大量 run 长期存活）。
- **subagent 级**：子代理执行器在 run 返回后调 `consume_stop_reason(run_id)`，把 `token_capped` / `loop_capped` 作为 additive `stop_reason` 盖到 `SubagentResult`，再经 `task()` 工具的 `ToolMessage.additional_kwargs.subagent_stop_reason` 冒泡到主代理。这条**收集 + 冒泡**链路在 [[subagent-delegation]] 讲，本 skill 不重复。

**为何 hard-stop 不抛异常而要"软停"**：抛异常会让 run 整个失败、丢弃已产出的可用结果。软停则剥 `tool_calls` + 强制 `finish_reason="stop"`，让模型用已收集到的信息收尾出最终答案--大部分情况下 lead run 仍能交出有价值的部分成果。

**Loop 检测双轴**：(1) hash 轴--同 `tool_calls` 集合重复（按 name + 稳定键 hash，多 tool_call 排序后 join）；(2) 频率轴--同名工具跨参数高频调用（catches `read_file` 读 40 个不同文件这类 hash 检测漏掉的循环）。稳定键按工具类型选：`read_file` 用路径 + 200 行 bucket（避免连续翻页误判）、`write_file` / `str_replace` 全 args hash（内容敏感）、其他抽 salient 字段（`path` / `url` / `query` / `command` / `pattern` / `glob` / `cmd`）。

**告警延后注入**：warn 阈值触发时不立即注入（`after_model` 此时 ToolMessage 还没落位，插入消息会破坏 `AIMessage(tool_calls) -> ToolMessage` 配对，OpenAI/Moonshot 拒收 `tool_call_ids did not have response messages`），而是 queue 到 `wrap_model_call`，在下次模型调用时作为 `HumanMessage` 追加到消息列表末尾。

### Additive stop_reason：安全终止叠加不破契约

loop / token 的 hard-stop 是"提前结束但仍有产物"。如何让调用方区分"干净完成"与"被截断但仍可用"？**不加新 status 枚举，加一个 additive 字段 `stop_reason`。**

- **为何不是新枚举**：新增 status 会破坏 v1 契约消费者（前端 / 持久化 ledger / JSON fixture）；additive 可选字段则被旧消费者静默忽略。
- **值域**：`token_capped` / `loop_capped`（`turn_capped` 是子代理 `GraphRecursionError` 路径，在 [[subagent-delegation]]）。
- **机制**：每个护栏中间件暴露 `consume_stop_reason(run_id) -> str | None`。hard-stop 触发时在 per-`run_id` 的 `BoundedDict` 上记 `_stop_reason[run_id] = "token_capped"` / `"loop_capped"`。该 dict **不被** `after_agent` / `_clear_run_state` 清除（让 executor 在 run 返回后能读）；有界（`BoundedDict(1000)`）防 lead 实例跨 run 泄漏。
- **duck-typed 收集**：子代理执行器用 `[m for m in middlewares if hasattr(m, "consume_stop_reason")]` 收集**所有**具此方法的中间件，run 结束后逐个查返回首个非 `None`。新增护栏不需要改执行器--只要新中间件实现该方法就自动被收集。这条**收集 + 冒泡**链路在 [[subagent-delegation]]，本 skill 只讲中间件侧的 `consume_stop_reason` 实现。

> **注**：`SafetyFinishReasonMiddleware` **没有** `consume_stop_reason`--provider 安全终止不 surface 为 guard cap 的 stop_reason，它走自己的 `safety_termination` 可观测性通道。additive `stop_reason` 只属 loop / token 两个 guard cap 轴。

```python
# 伪代码：hard-stop 软停 + consume_stop_reason（完整源码见 references/code/safety-finish-and-budget.md §3-5）
class TokenBudgetMiddleware:                               # LoopDetectionMiddleware 镜像同型
    def __init__(self, config): self._stop_reason = BoundedDict(1000)  # 不被 after_agent 清除，让 executor 能读
    def _apply(self, state, runtime):
        if highest_fraction >= config.hard_stop_threshold:
            self._stop_reason[run_id] = "token_capped"    # additive，不破契约
            return strip_tool_calls(last_msg, force_finish="stop", append="[TOKEN BUDGET EXCEEDED]")
        if highest_fraction >= config.warn_threshold:
            queue_warning_to_wrap_model_call(warn_text)   # 不在 after_model 注入（破坏 tool_call 配对）
            return None
    def consume_stop_reason(self, run_id): return self._stop_reason.pop(run_id, None)  # executor 读，pop 语义
```

### 在端到端链路中的位置

本 skill 处于端到端链路的 **⑤中间件**（见 [[e2e-request-lifecycle]]）：

- **输入消毒**（第 1 项 InputSanitization）：`wrap_model_call` 最外层，所有内层见消毒后消息。上游 ④建图装配它进共享基座（lead + 子代理都复用）。
- **Guardrail**（第 8 项）：`wrap_tool_call`，工具调用前授权。在共享基座 tail 段，`guardrails.enabled` 时反射加载 provider 装配。
- **SafetyFinishReason**（第 28 项）：`after_model`，lead 专用续装，`safety_finish_reason.enabled` 时装配。注册在 LoopDetection 之后（逆序 after_model 最先跑）。
- **LoopDetection**（第 25 项）/ **TokenBudget**（第 26 项）：`after_model` + `wrap_model_call`（告警注入），lead 专用续装 + 子代理镜像续装。

下游 ⑥执行：中间件链与工具循环由 `astream` 驱动--`wrap_model_call` 洋葱包裹模型 -> `after_model` 逆序处理输出 -> `wrap_tool_call` 洋葱包裹工具 -> 循环直到无 tool_calls 或被截停。

跨切关联：guardrail 的身份字段（`user_id` / `user_role` / `oauth_*`）来自 `runtime.context`，由 ②认证写入 `user_context` contextvar、④建图装进 `runtime.context`（见 [[e2e-request-lifecycle]] 跨切不变量 2 user_id 全链路隔离）。`is_subagent` 由子代理执行器设置（见 [[subagent-delegation]]）。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/guardrails/provider.py` | `GuardrailProvider` 协议 + `GuardrailRequest` / `GuardrailReason` / `GuardrailDecision` | [guardrail-authorization.md](./references/code/guardrail-authorization.md) §1 |
| `core/helix/guardrails/builtin.py` | `AllowlistProvider`：内置 allow/deny list provider（零依赖） | [guardrail-authorization.md](./references/code/guardrail-authorization.md) §2 |
| `core/helix/guardrails/middleware.py` | `GuardrailMiddleware`：`wrap_tool_call` 拦截 + 同步/异步 + fail-closed + 审计 | [guardrail-authorization.md](./references/code/guardrail-authorization.md) §3 |
| `core/helix/agents/middlewares/tool_error_handling_middleware.py` | `_build_runtime_middlewares` 中反射加载 provider 装配 Guardrail 的构造块 | [guardrail-authorization.md](./references/code/guardrail-authorization.md) §4 |
| `core/helix/config/guardrails_config.py` | `GuardrailsConfig` / `GuardrailProviderConfig`（Pydantic 校验） | [guardrail-authorization.md](./references/code/guardrail-authorization.md) §5 |
| `core/helix/agents/middlewares/input_sanitization_middleware.py` | `InputSanitizationMiddleware`：`wrap_model_call` 最外层消毒（封锁集 + boundary neutralize + 多模态回写 + 幂等 + fail-open） | [input-sanitization.md](./references/code/input-sanitization.md) |
| `core/helix/agents/middlewares/safety_termination_detectors.py` | `SafetyTerminationDetector` 协议 + 3 内置 detector + `default_detectors` | [safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md) §1 |
| `core/helix/agents/middlewares/safety_finish_reason_middleware.py` | `SafetyFinishReasonMiddleware`：`after_model` 抑制半截 tool_calls | [safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md) §2 |
| `core/helix/agents/middlewares/loop_detection_middleware.py` | `LoopDetectionMiddleware`：hash + 频率双轴检测 + `consume_stop_reason` | [safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md) §4 |
| `core/helix/agents/middlewares/token_budget_middleware.py` | `TokenBudgetMiddleware`：per-run token 预算 + `consume_stop_reason` | [safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md) §3 |
| `core/helix/agents/middlewares/_bounded_dict.py` | `BoundedDict`：per-`run_id` 有界状态（防泄漏） | [safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md) §5 |
| `core/helix/agents/middlewares/tool_call_metadata.py` | `clone_ai_message_with_tool_calls`：清空 tool_calls 统一入口（三处同清） | [safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md) §6 |
| `core/helix/config/safety_finish_reason_config.py` | `SafetyFinishReasonConfig` / `SafetyDetectorConfig` | [safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md) §7.1 |
| `core/helix/config/token_budget_config.py` / `loop_detection_config.py` | `TokenBudgetConfig` / `LoopDetectionConfig` / `ToolFreqOverride` | [safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md) §7.2-7.3 |

### 一次 turn 穿越安全层（动态时序）

```
state, config -> graph.astream
  step 1: wrap_model_call 链（洋葱，外->内）
           1 InputSanitization ─── 转义封锁标签 + 包裹 BEGIN/END USER INPUT（只动最后一条真用户消息）
             -> ... 内层中间件见消毒后消息 ... -> 真实模型
  step 2: after_model 链（逆序，最后注册的最先跑）
           28 SafetyFinishReason? ── provider 安全终止 + 有 tool_calls？
             ├── 是 -> clone 清空 tool_calls + 追加解释 + 盖 safety_termination + 发 SSE -> 模型收尾
             └── 否 -> 透传
             -> 25 LoopDetection? ── hash/频率触顶？
             ├── hard -> 剥 tool_calls + _stop_reason[run_id]="loop_capped" + 强制收尾
             └── warn -> queue 告警到 wrap_model_call
             -> 26 TokenBudget? ── 累计 token 超阈值？
             ├── hard -> 剥 tool_calls + _stop_reason[run_id]="token_capped" + 强制收尾
             └── warn -> queue 告警到 wrap_model_call
  step 3: tools 节点（若 after_model 未清空 tool_calls）
           wrap_tool_call 链（洋葱，外->内）
             8 Guardrail? ── provider.evaluate(GuardrailRequest)
             ├── deny -> error ToolMessage（fail-closed）-> 模型读原因换路径
             ├── allow -> 透传 -> 9 SandboxAudit -> 12 ToolErrorHandling -> 真实工具
             └── provider 异常 -> fail_closed=true 拒绝 / false 放行+warn
             -> ... -> 真实工具（沙箱内执行，路径限制见 [[sandbox-tools-and-safety]]）
  step 4: 循环回 step 1 直到无 tool_calls 或被 hard-stop 截停
  step 5: run 终态
           lead 级：hard-stop 时末尾追加 [TOKEN BUDGET EXCEEDED]/[FORCED STOP]，用户看到带提示的最终答案
           subagent 级：executor 调 consume_stop_reason 收集 token_capped/loop_capped -> 冒泡（见 [[subagent-delegation]]）
```

### 模块索引

- [references/code/guardrail-authorization.md](./references/code/guardrail-authorization.md) -- Guardrail 完整源码：Provider 协议 + AllowlistProvider + GuardrailMiddleware（同步/异步 + fail-closed + 审计落 journal）+ 构造块反射加载 + GuardrailsConfig + 配置示例
- [references/code/input-sanitization.md](./references/code/input-sanitization.md) -- 输入消毒完整源码：InputSanitizationMiddleware（封锁集 + boundary neutralize + 多模态 content-block 回写 + 幂等不变量 + fail-open）+ 关键不变量提炼
- [references/code/safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md) -- 安全终止 + Loop/Token 预算完整源码：SafetyTerminationDetector 协议 + 3 内置 detector 全文 + SafetyFinishReasonMiddleware + TokenBudgetMiddleware + LoopDetectionMiddleware + BoundedDict + clone_ai_message_with_tool_calls + 3 个 config + 关键不变量提炼

## 反模式与陷阱

- ❌ **Guardrail 抛异常未捕获** -> 整 run 死，已产出结果全丢。修复：`evaluate` 调用包 `try/except`，异常路径走 `fail_closed`（默认拒绝返回 error ToolMessage，绝不终止 run）；`GraphBubbleUp` 原样上抛。
- ❌ **拒绝时不返回 reason 给模型** -> LLM 不知道为何被拒、盲目重试同样调用。修复：`GuardrailDecision.reasons[0]` 的 code + message 必须写进 error `ToolMessage` content。
- ❌ **输入消毒规则过广（删所有尖括号）** -> 误伤用户合法 HTML / 代码 / `<details>` 标签。修复：封锁集是有限枚举（系统标签 + 注入伪标签），普通 HTML/XML 不转义；de-identify-don't-reject，不拒绝。
- ❌ **SafetyFinishReason 注册在 LoopDetection 之前** -> 逆序 `after_model` 派发使 Loop 先跑，对带截断 tool_calls 的消息计数触发误报。修复：Safety 必须注册在 Loop 之后（链表中更靠后），docstring 要求 "register after LoopDetection"。
- ❌ **Safety / Loop / Token hard-stop 改成抛异常** -> 已产出的可用结果随异常丢弃。修复：hard-stop 剥 `tool_calls` + 强制 `finish_reason="stop"`，让 run 自然完成；executor 靠 `consume_stop_reason` 事后得知。
- ❌ **清 tool_calls 只清结构化字段** -> provider 原始 `additional_kwargs.tool_calls` / `function_call` 残留，执行器仍派发半截参数。修复：经 `clone_ai_message_with_tool_calls` 三处同清（结构化 + additional_kwargs + function_call）。
- ❌ **把 `finish_reason` 改写成 `tool_calls`** -> SSE 下游误以为是正常完成，统计错乱。修复：hard-stop 只在原值是 `tool_calls` 时改写成 `stop`；provider 原值（content_filter / refusal / SAFETY）保留不动。
- ❌ **LoopDetection 告警注入到 `after_model`** -> OpenAI / Moonshot 拒收：`tool_call_ids did not have response messages`（ToolMessage 还没落位）。修复：warn queue 到 `wrap_model_call`，在下次模型调用时作为 `HumanMessage` 追加到消息列表末尾。
- ❌ **list-content 直接 `str +` 追加解释** -> Anthropic thinking blocks / vLLM reasoning 分段把 `content` 表示成 `list[dict]`，`str + list` 抛 TypeError。修复：`_append_text` 检测 list 类型，追加 `{"type":"text","text":...}` block。
- ❌ **审计持久化被过滤的 tool arguments** -> 那是 provider 过滤的内容本身，重新落盘等于绕开 safety filter。修复：只记 `suppressed_tool_call_names` / `ids` / `count` / `detector`。
- ❌ **审计同步写文件** -> 高 QPS 时阻塞 worker。修复：走 `RunJournal.record_middleware` -> 异步 `RunEventStore`；审计写入失败也吞掉，绝不影响 agent 运行。
- ❌ **Provider 不限超时** -> 单次 tool call 卡 10s 以上。修复：自定义 provider 走 HTTP 策略服务时，`aevaluate` 单独实现并加 3-5s 超时。
- ❌ **新增 guard cap 抛新 status 枚举** -> 破坏 v1 契约消费者（前端 / ledger / JSON fixture）。修复：additive `stop_reason` 字段（`token_capped` / `loop_capped`），旧消费者静默忽略。
- ❌ **`consume_stop_reason` 只查一个护栏** -> 加新护栏要改执行器。修复：`[m for m in middlewares if hasattr(m, "consume_stop_reason")]` 收集全部，逐个查返回首个非 None（duck-typed，零 import 耦合）。注：这条收集在 [[subagent-delegation]]，本 skill 只讲中间件侧实现。
- ❌ **per-run_id 状态无界 dict** -> lead 中间件实例跨大量 run 长期存活，每个 run 累积一条，内存泄漏。修复：`BoundedDict(1000)` 满额淘汰最早插入的 key。
- ❌ **`_stop_reason` 被 `after_agent` 清除** -> executor 在 run 返回后读不到。修复：`_stop_reason` 刻意不被 `after_agent` / `_clear_run_state` 清除（与 `_warned` / `_pending_warnings` 等其他 per-run 状态不同），让 executor 能在 run 返回后消费。
- ❌ **Detector `detect()` 有副作用** -> 同一条 AIMessage 被多个 detector 看到，副作用重复触发。修复：`SafetyTerminationDetector.detect` 协议明确要求 side-effect free；单个 detector 异常 `_detect` 也 `try/except` 后继续遍历。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 默认 | 说明 |
|---|---|---|---|
| `guardrails.enabled` | app config | `false` | 主开关；关闭时 `GuardrailMiddleware` 不入链 |
| `guardrails.fail_closed` | app config | `true` | provider 异常时拒绝 / 放行 |
| `guardrails.passport` | app config | `None` | 透传到 `GuardrailRequest.agent_id`，供 OAP 按 agent 审计 |
| `guardrails.provider.use` / `.config` | app config | - | 反射加载类路径 + provider 构造 kwargs（`allowed_tools` / `denied_tools`） |
| `safety_finish_reason.enabled` | app config | `true` | SafetyFinishReason 主开关 |
| `safety_finish_reason.detectors` | app config | 内置 3 个 | 反射加载自定义 detector；空列表非法（要禁用就 `enabled: false`） |
| `loop_detection.warn_threshold` / `hard_limit` | app config | 3 / 5 | 同套 tool_calls 出现次数 -> warn / hard-stop |
| `loop_detection.window_size` / `max_tracked_threads` | app config | 20 / 100 | 滑窗大小 / LRU 上限（超限 evict 最久未访问 thread） |
| `loop_detection.tool_freq_warn` / `hard_limit` | app config | 30 / 50 | 同名工具调用频次（跨参数） |
| `loop_detection.tool_freq_overrides` | app config | `{}` | per-tool 频次覆盖；`{bash: {warn: 60, hard_limit: 100}}` |
| `token_budget.enabled` / `max_tokens` | app config | `false` / 200000 | TokenBudget 主开关 / per-run 总 token 上限 |
| `token_budget.warn_threshold` / `hard_stop_threshold` | app config | 0.8 / 1.0 | warn / hard-stop 分数阈值；hard >= warn（Pydantic 校验） |
| `InputSanitization` 封锁集 | 源码常量 | 16 个标签 | 框架系统标签 + 注入伪标签；普通 HTML/XML 不在内 |

**关键日志串**（排障时 grep）

- `Guardrail denied: tool=%s policy=%s code=%s` -- Guardrail 拒绝；`Guardrail provider error (sync)` / `(async)` -- provider 异常（fail-closed 路径）
- `InputSanitizationMiddleware: original=%r -> processed=%r` -- 消毒变换（debug 级）；`Input guardrail processing failed; passing original request to model` -- 消毒 fail-open
- `Provider safety termination detected - suppressed %d tool call(s)` -- Safety 抑制；`SafetyTerminationDetector %r raised; treating as no-match` -- detector 异常不传染
- `Loop hard limit reached - forcing stop` / `Tool frequency hard limit reached - forcing stop` -- loop 轴 hard-stop（盖 `loop_capped`）
- `Token budget hard stop triggered for run %s: %s limit exceeded` -- token 轴 hard-stop（盖 `token_capped`）

**调试入口（安全事件排查序列）**

1. **看 Guardrail 拒绝**：`grep "Guardrail denied"` 拉 tool / policy_id / code；fail-closed 路径单独 grep `Guardrail provider error`。
2. **看 Safety 抑制**：被抑制的 AIMessage 在 `additional_kwargs["safety_termination"]` 留 `{detector, reason_field, reason_value, suppressed_tool_call_count, suppressed_tool_call_names, extras}`；`finish_reason` 保留 provider 原值（不会被改写）。
3. **看 loop / token 截断**：hard-stop 时末尾追加 `[FORCED STOP]` / `[TOKEN BUDGET EXCEEDED]`；`_stop_reason[run_id]` 记 `loop_capped` / `token_capped`（子代理执行器消费，见 [[subagent-delegation]]）。
4. **看 RunJournal 事件**：tag `guardrail`（授权决策，含 `allow` / `policy_id` / `reason_codes` / `provider_error`）、`safety_termination`（含 `detector` / `suppressed_tool_call_names` / `count`，不含被过滤的参数）。
5. **看消毒效果**：debug 级 `InputSanitizationMiddleware: original=%r -> processed=%r`；`ORIGINAL_USER_CONTENT_KEY` 在 `additional_kwargs` 保留原文，下游（slash skill / regenerate）可恢复。

**自测方向**

- **输入消毒**：幂等（消毒两次第二次返回原请求）；不误伤 `<div>` / `<details>` 但转义 `<system>`；break-out 防御（中间的 `--- END USER INPUT ---` 被 neutralize）；跳过框架注入的 HumanMessage（summary / 隐藏回复）；原文保留（`ORIGINAL_USER_CONTENT_KEY` setdefault 不覆盖）；多模态兼容（text block 合并、image block 保留原位）。
- **Guardrail**：allow/deny list 正确（白名单外 deny、黑名单内 deny）；fail-closed（provider 异常 -> error ToolMessage `oap.evaluator_error`；fail-open -> 放行 + warn）；身份透传（`GuardrailRequest` 携带 `user_id` / `is_subagent`）；`GraphBubbleUp` 原样上抛不被 except 吞。
- **SafetyFinishReason**：`content_filter` + 非空 `tool_calls` -> 清空 + 追加解释 + 盖 `safety_termination`；无 tool_calls 的 `content_filter` 原样放行；`finish_reason="stop"` + tool_calls 透传不清空；Safety 先于 Loop（逆序 after_model 使 Safety 先清空，Loop 对清理后消息不误报）；detector 异常不传染。
- **Loop / Token**：同 hash 重复 5 次 -> hard-stop（剥 tool_calls + `_stop_reason="loop_capped"` + `finish_reason="stop"`）；频率轴（同名工具跨参数 50 次 -> hard-stop，hash 轴漏检但频率轴 catch）；`read_file` 连续翻页不误判（200 行 bucket）；token 超 `hard_stop_threshold` -> 剥 tool_calls + `_stop_reason="token_capped"`；warn 触发时 `after_model` 返回 `None`，下次 `wrap_model_call` 追加 `HumanMessage(name="loop_warning"/"budget_warning")`。
- **additive stop_reason**：hard-stop 后 `consume_stop_reason(run_id)` 返回 `loop_capped` / `token_capped`；再次调用返回 `None`（pop 语义）；旧消费者不读 `stop_reason` 仍正常；`BoundedDict` 插入 > 1000 个 run_id 最早插入的被淘汰、总量不超 1000。

## 进一步阅读

- Guardrail 完整源码（Provider 协议 + AllowlistProvider + GuardrailMiddleware + 构造块 + config）：[references/code/guardrail-authorization.md](./references/code/guardrail-authorization.md)
- 输入消毒完整源码（InputSanitizationMiddleware + 封锁集 + boundary neutralize + 多模态回写）：[references/code/input-sanitization.md](./references/code/input-sanitization.md)
- 安全终止 + Loop/Token 预算完整源码（detector + SafetyFinishReason + TokenBudget + LoopDetection + BoundedDict + clone + config）：[references/code/safety-finish-and-budget.md](./references/code/safety-finish-and-budget.md)
- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 关联 skill：[[e2e-request-lifecycle]]（⑤中间件 链路位置）、[[middleware-chain-design]]（29 项链顺序 + Safety 注册在 Loop 后的逆序不变量 + InputSanitization 最外层）、[[subagent-delegation]]（子代理级 guardrail 三轴 + `consume_stop_reason` 收集 + additive `stop_reason` 冒泡）、[[context-window-management]]（LoopDetection / TokenBudget 的上下文窗视角）、[[sandbox-tools-and-safety]]（沙箱级路径授权 `_is_allowed_local_bash_absolute_path` + bash 工具安全）、[[tool-assembly-and-policy]]（工具装配与 Guardrail 的工具集边界）、[[observability-tracing]]（RunJournal 审计事件 + safety_termination SSE 事件）、[[multi-user-isolation]]（GuardrailRequest 的 user_id / user_role 身份来源）
