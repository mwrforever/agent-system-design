---
name: middleware-chain-design
description: 设计 LangChain agent 中间件链——base + lead-only 双段、hook 嵌套与逆序语义、中断型中间件必须最后注册。覆盖 before_agent / wrap_model_call / before_model / after_model / wrap_tool_call 五种 hook 的协作关系。
---

## 何时用

- 你在加新的横切关注点（日志 / 限流 / 上下文压缩 / 安全审计 / Memory 队列…）
- 需要分清楚"哪些中间件主代理与子代理共用，哪些只属于主代理"
- 遇到"我的 `after_model` 中间件被另一个先跑了"的顺序错乱
- 想拦截 tool 调用而非真正执行（`Command(goto=END)` 中断模式）

## 设计思想

1. **两段式**：抽出 `build_runtime_middlewares()` 作为**共享 base**（main agent + subagent 都用），再各自 append 上层独有的。子代理跑成本省一半 + 隔离 bug。
2. **hook 嵌套顺序**：`wrap_model_call` / `wrap_tool_call` 是**注册顺序 = 由外向内**洋葱嵌套；`after_model` 是 **逆序派发**（最后注册的最先跑）。把这条贴在 build 函数顶上当注释。
3. **可选中间件按配置追加**：guardrails / summarization / todo / token_budget 等通过 `app_config.<feature>.enabled` 闸门，避免强依赖。
4. **中断型放最后**：`ClarificationMiddleware` 用 `Command(goto=END)` 中断图，必须是 `wrap_tool_call` 链的最内层（注册最后）。
5. **副作用放 hook，纯逻辑放 reducer**：中间件可以读 `state` / 写 `Command(update=...)`；不要直接 mutate `runtime.state`，下一步骤拿不到。

## 实现模板

```python
# middlewares/build.py
from langchain.agents.middleware import AgentMiddleware

def build_runtime_middlewares(*, app_config, include_uploads, include_dangling, lazy_init=True):
    """主代理 + 子代理共享的 base。"""
    # 1. 输入消毒最外层 → 内层都看到干净消息
    mws: list[AgentMiddleware] = [InputSanitizationMiddleware()]
    # 2. 工具输出体积上限
    mws.append(ToolOutputBudgetMiddleware.from_app_config(app_config))
    # 3. 上传文件清单注入（lead-only 才打开）
    if include_uploads:
        mws.append(UploadsMiddleware())
    # 4. 创建 thread 目录
    mws.append(ThreadDataMiddleware(lazy_init=lazy_init))
    # 5. 沙箱生命周期
    mws.append(SandboxMiddleware(lazy_init=lazy_init))
    # 6. 孤儿 tool_call 补占位（用户中断后续聊会校验失败）
    if include_dangling:
        mws.append(DanglingToolCallMiddleware())
    # 7. LLM provider 错误规范化为可消费 AIMessage
    mws.append(LLMErrorHandlingMiddleware(app_config=app_config))
    # 8. 可选 Guardrail
    if app_config.guardrails.enabled:
        mws.append(make_guardrail_middleware(app_config))
    # 9. 工具执行前审计
    mws.append(SandboxAuditMiddleware())
    # 10. 工具异常 → 错误 ToolMessage（最内层）
    mws.append(ToolErrorHandlingMiddleware())
    return mws


def build_lead_middlewares(config, *, model_name, agent_name=None, app_config, deferred_setup=None):
    """lead-only：在共享 base 之后追加。"""
    mws = build_runtime_middlewares(app_config=app_config,
                                    include_uploads=True, include_dangling=True)

    # ── 上下文层 ──────────────────────────────
    mws.append(DynamicContextMiddleware(agent_name=agent_name, app_config=app_config))  # <system-reminder> 注入
    mws.append(SkillActivationMiddleware(app_config=app_config))                         # /skill-name 触发
    if app_config.summarization.enabled:
        mws.append(make_summarization_middleware(app_config))
    if config.get("configurable", {}).get("is_plan_mode"):
        mws.append(make_todo_middleware())
    if app_config.token_usage.enabled:
        mws.append(TokenUsageMiddleware())

    # ── 业务层 ────────────────────────────────
    mws.append(TitleMiddleware(app_config=app_config))            # 首轮异步生成标题
    mws.append(MemoryMiddleware(agent_name=agent_name,            # 入队异步 memory 更新
                                memory_config=app_config.memory))

    if (mc := app_config.get_model_config(model_name)) and mc.supports_vision:
        mws.append(ViewImageMiddleware())
    if deferred_setup and deferred_setup.deferred_names:
        mws.append(DeferredToolFilterMiddleware(deferred_setup.deferred_names,
                                                deferred_setup.catalog_hash))

    # ── 出口规整层 ────────────────────────────
    mws.append(SystemMessageCoalescingMiddleware())  # 合并多 SystemMessage 为首条
    if config.get("configurable", {}).get("subagent_enabled"):
        mws.append(SubagentLimitMiddleware(max_concurrent=3))
    if app_config.loop_detection.enabled:
        mws.append(LoopDetectionMiddleware.from_config(app_config.loop_detection))
    if app_config.token_budget.enabled:
        mws.append(TokenBudgetMiddleware.from_config(app_config.token_budget))
    if app_config.safety_finish_reason.enabled:
        mws.append(SafetyFinishReasonMiddleware.from_config(app_config.safety_finish_reason))

    # ⭐ ClarificationMiddleware 必须最后，wrap_tool_call 最内层
    mws.append(ClarificationMiddleware())
    return mws
```

`wrap_tool_call` 的"持久化惰性初始化"模板（解决 runtime.state 局部 mutate 丢失）：

```python
class SandboxMiddleware(AgentMiddleware):
    def wrap_tool_call(self, request, handler):
        prev = read_sandbox_id(request.runtime.state)
        result = handler(request)
        if prev is not None:
            return result
        curr = read_sandbox_id(request.runtime.state)
        if curr is None:
            return result
        # ⭐ 把惰性写入升格为 LangGraph 通道更新
        if isinstance(result, ToolMessage):
            return Command(update={"sandbox": {"sandbox_id": curr},
                                   "messages": [result]})
        # Command 类型则 merge
        return dataclass_replace(result, update={**(result.update or {}),
                                                  "sandbox": {"sandbox_id": curr}})
```

## 反模式

- ❌ 在 `build_middlewares` 里写 `if-else` 决定要不要插，但**不**通过 `app_config.<feature>.enabled` → 升级时找不到开关
- ❌ 中断型中间件不放最后 → 后续 `after_model` 派发顺序错乱
- ❌ 在 `wrap_tool_call` 里直接改 `runtime.state["sandbox"]` 不发 `Command(update=...)` → 下一节点拿不到
- ❌ 没有 base / lead 分层 → 子代理也跑 TitleMiddleware / MemoryMiddleware，浪费 token + 数据污染
- ✅ build 函数顶部用注释画出 hook 顺序图，新来的人一秒看懂
- ✅ 可选中间件统一通过 `app_config.<feature>.enabled` 闸门

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[agent-graph-factory]] [[thread-state-and-reducers]] [[context-window-management]] [[safety-and-guardrails]] [[subagent-delegation]]
- LangChain 中间件文档：https://python.langchain.com/docs/concepts/middleware
