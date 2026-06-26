---
name: safety-and-guardrails
description: 设计 agent 的安全层——输入消毒、Guardrail Provider、SafetyFinishReason 抑制、循环检测、token 预算、Sandbox 审计。覆盖防注入与最小权限的多层防御。
---

## 何时用

- agent 暴露在公网 / 多用户，需要防御提示注入
- 接入了高风险工具（删除文件、转账、发邮件、外部 API 调用）
- provider 启用了内容安全审查（finish_reason=content_filter）
- 希望策略可插拔（Allowlist / OAP / 自定义）

## 设计思想

1. **多层 / 不同位置防御**：消毒（最外）→ 鉴权（工具调用前）→ 审计（工具调用前）→ 循环熔断（after_model）→ token 预算（after_model）→ 安全终止抑制（after_model 最先派发）。
2. **GuardrailProvider 用反射加载**：策略与框架解耦——`AllowlistProvider`（内置）/ OAP / 用户自定义；通过 `app_config.guardrails.provider.use` 配置。
3. **Fail-closed 优先**：拒绝时返回 error ToolMessage 而非异常；让 run 继续，模型自己换路径。
4. **「位置 = 语义」**：`SafetyFinishReasonMiddleware` 注册**晚**（在自定义中间件之后），由于 `after_model` 逆序派发，它**最先**跑——这样清空的 tool_calls 才能流过后面的 Loop / Subagent 累加而不触发误警。
5. **审计有结构**：bash 命令 / write path / diff hash 都写入 `RunEventStore`，便于事后追溯。

## 实现模板

### 输入消毒（最外层）

```python
class InputSanitizationMiddleware(AgentMiddleware):
    """清理消息中的注入痕迹：伪造的 </system-reminder> 等结构标签."""
    PATTERNS = [
        re.compile(r"</?system-reminder>"),
        re.compile(r"</?system_prompt>"),
        # ...
    ]
    def wrap_model_call(self, request, handler):
        # 注意：只清"声称是系统标签"的注入，不动用户合法 Markdown
        sanitized = []
        for m in request.messages:
            if isinstance(m, HumanMessage) and isinstance(m.content, str):
                content = m.content
                for p in self.PATTERNS:
                    content = p.sub("", content)
                if content != m.content:
                    m = m.model_copy(update={"content": content})
            sanitized.append(m)
        return handler(replace(request, messages=sanitized))
```

### Guardrail 中间件

```python
class GuardrailProvider(ABC):
    @abstractmethod
    async def check(self, *, tool_name: str, tool_input: dict,
                    runtime: Runtime) -> "GuardrailDecision": ...


@dataclass
class GuardrailDecision:
    allow: bool
    reason: str | None = None


class GuardrailMiddleware(AgentMiddleware):
    def __init__(self, provider, *, fail_closed=True, passport=None):
        self.provider = provider
        self.fail_closed = fail_closed
        self.passport = passport      # 可选：携带 user_role / oauth_id 等给 provider

    async def awrap_tool_call(self, request, handler):
        try:
            decision = await self.provider.check(
                tool_name=request.tool_call["name"],
                tool_input=request.tool_call.get("args", {}),
                runtime=request.runtime,
            )
        except Exception:
            if self.fail_closed:
                return ToolMessage(content="Tool blocked: guardrail unavailable",
                                    tool_call_id=request.tool_call["id"],
                                    status="error")
            raise
        if not decision.allow:
            return ToolMessage(content=f"Tool blocked: {decision.reason}",
                                tool_call_id=request.tool_call["id"], status="error")
        return await handler(request)
```

### SafetyFinishReason 抑制

```python
class SafetyFinishReasonMiddleware(AgentMiddleware):
    """provider 安全终止（content_filter / safety）时抑制本轮 tool 执行."""
    def __init__(self, detectors):
        self.detectors = detectors        # ["content_filter", "safety", ...]

    def after_model(self, state, runtime):
        last = _last_ai_message(state["messages"])
        if not last or not last.tool_calls:
            return None
        finish_reason = last.response_metadata.get("finish_reason")
        if finish_reason not in self.detectors:
            return None
        # 双清：结构化 + provider 原始
        last.tool_calls = []
        last.additional_kwargs.pop("tool_calls", None)
        # 留审计
        journal = (runtime.context or {}).get("__run_journal")
        if journal:
            journal.record_event("safety_suppression",
                                  {"finish_reason": finish_reason})
        return {"messages": [*state["messages"][:-1], last]}
```

### Sandbox 审计

```python
class SandboxAuditMiddleware(AgentMiddleware):
    """工具执行前留审计事件 → RunJournal → RunEventStore."""
    AUDITED = {"bash", "write_file", "str_replace"}

    def wrap_tool_call(self, request, handler):
        name = request.tool_call.get("name", "")
        if name in self.AUDITED:
            journal = (request.runtime.context or {}).get("__run_journal")
            if journal:
                journal.record_event(f"sandbox_audit:{name}", {
                    "args": _redact(request.tool_call.get("args", {})),
                    "tool_call_id": request.tool_call.get("id"),
                })
        return handler(request)
```

### 配置 + 反射加载

```yaml
# config.yaml
guardrails:
  enabled: true
  fail_closed: true
  passport: { roles_from_context: true }
  provider:
    use: agent_framework.guardrails.allowlist:AllowlistProvider
    config:
      allow_tools: [read_file, ls, web_search]
      deny_tools: [bash]
```

```python
provider_cls = resolve_class(app_config.guardrails.provider.use, base_class=GuardrailProvider)
provider = provider_cls(**(app_config.guardrails.provider.config or {}))
mws.append(GuardrailMiddleware(provider, fail_closed=app_config.guardrails.fail_closed))
```

## 反模式

- ❌ Guardrail 抛异常 → 整次 run 死；应该 fail-closed 返回 error ToolMessage 让 run 继续
- ❌ `SafetyFinishReasonMiddleware` 注册位置随便放 → `after_model` 逆序里跑得晚，清空操作影响 Loop / Subagent 计数
- ❌ 输入消毒规则过广（删所有尖括号）→ 误伤用户合法 HTML / 代码
- ❌ 审计写文件没限速 → 高 QPS 时 IO 阻塞
- ❌ Guardrail Provider 直接调外部 HTTP 但不限超时 → 一次 tool call 卡 10s
- ✅ 审计写 `RunEventStore`，靠 DB 异步写而非同步 IO
- ✅ Guardrail Provider 限定 3-5s 超时

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[middleware-chain-design]] [[context-window-management]] [[sandbox-tools-and-safety]]
