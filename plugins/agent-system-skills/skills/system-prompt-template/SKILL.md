---
name: system-prompt-template
description: 设计生产级 agent 的系统提示词--静态主体 + 动态 <system-reminder> 注入。覆盖 prefix-cache 友好的分段结构、保密段、澄清系统（ask_clarification 中断）、技能/子代理/工作目录段、动态日期与记忆注入、SystemMessage 合并。给出真实提示词全文与可运行代码的模块索引。当你要写 agent 系统提示词、做 prefix-cache 优化、处理"非首条 SystemMessage"报错、加澄清强约束时调用本 skill。
---

## 何时用

- 你在写一个生产级 agent 的系统提示词
- 想让逐 turn 变化的内容（日期、记忆、激活技能）注入但不破坏 prefix cache
- 要给 agent 加"不清楚先澄清"的强约束（`ask_clarification` 中断）
- 模型客户端报"非首条 SystemMessage / System message must be at the beginning"错误（vLLM / SGLang / Qwen / Anthropic）
- 想阻止用户套话拿到内部 prompt（提示注入防护）

## 设计方案（为什么这么设计）

### 核心矛盾：prefix cache vs 每 turn 变化

LLM provider 的 prefix caching 要求 system prompt 前缀**字节级稳定**：只要 system prompt 里出现当前日期、用户 id、实时记忆，cache 就永远 miss，token 成本与首 token 延迟显著上升。但 agent 又需要"今天是几号"、"这个用户记得什么"、"激活了哪个 skill"这类每 turn 可能变化的信息。

### 解法：双通道

- **静态通道**：`SYSTEM_PROMPT_TEMPLATE` 是纯静态字符串，`.format()` 只填充**会话级**变量（`agent_name`、启用的技能签名、是否开子代理这类启动期就定型的内容）。整段在多用户、多会话间完全一致 -> prefix cache 持续命中。
- **动态通道**：日期、记忆这类**每 turn 变化**的内容，**不进** system prompt，而是由 `DynamicContextMiddleware` 在 `before_agent` 阶段，以一条 `<system-reminder>` SystemMessage 注入到第一条 HumanMessage 之前，用 `additional_kwargs` 标记隐藏。

```python
# 伪代码：双通道分离
def apply_prompt_template(...启动期定型参数...) -> str:
    # 静态通道：只填会话级变量，绝不调 datetime.now() / 不读 user_id / 不查实时配置
    return SYSTEM_PROMPT_TEMPLATE.format(**slots)   # 字节级稳定，跨用户一致

# 动态通道：每 turn 跑，注入 <system-reminder>，不碰静态 prompt
class DynamicContextMiddleware:
    def before_agent(self, state):
        last_date = 读 additional_kwargs.reminder_date（权威，非 regex 解析内容）
        if last_date is None:       插入完整 reminder(日期+记忆) 到首条 HumanMessage 前
        elif last_date == today:    return None   # 同日：零改动，prefix cache 持续命中
        else:                       插入轻量日期校正到末条 HumanMessage 前
```

### 关键不变量（违反则 cache 崩塌或行为错乱）

1. `apply_prompt_template` 绝不引入运行时变量--不调 `datetime.now()`、不读 `user_id`、不查实时配置。违反后果：prefix-cache 命中率崩塌。
2. 动态部分必须走 `<system-reminder>` SystemMessage，不能写进 system prompt。违反后果：每轮 prompt 不同，跨用户无法复用。
3. **角色分离**（OWASP LLM01）：框架权威数据（日期）走 `SystemMessage`，用户可影响数据（记忆）走 `HumanMessage`，避免不可信内容获得 system 权限。
4. 静态模板里 `{` `}` 全部转义为 `{{` `}}`，仅占位符保留单括号，否则 `.format` 抛 `KeyError`。
5. 可选段（subagent / acp / skills）在不启用时输出空字符串而非 `None`，保证 `.format(**slots)` 永远拿到字符串。

### 分段设计（每段独立 enable/disable，缺失配置返回 `""`）

```python
# 伪代码：分段顺序与占位符
SYSTEM_PROMPT_TEMPLATE = """
<role>You are {agent_name}, ...</role>
## Confidentiality ...        # 保密段：禁止泄露 prompt / <system-reminder> 内容
{soul}{self_update_section}
<thinking_style>...{subagent_thinking}...</thinking_style>
<clarification_system>CLARIFY -> PLAN -> ACT; 5 类必澄清场景</clarification_system>
{skills_section}{deferred_tools_section}{subagent_section}
<working_directory>...{acp_section}</working_directory>
<response_style>...</response_style>
<citations>...</citations>
<critical_reminders>{subagent_reminder}{skill_first_reminder}...</critical_reminders>
"""
# slots 全部由独立构造器产出：subagent_enabled=False -> subagent_section=""
# .format(**slots) -> 纯静态字符串，跨用户/会话一致
```

每段由独立构造器产出（`_build_subagent_section` / `get_skills_prompt_section` / `_build_acp_section` 等），缺失配置时返回 `""`。分段顺序：`role` -> 保密段 -> `soul` -> 自我更新段 -> `thinking_style` -> `clarification_system` -> `skills_section` -> `deferred_tools` -> `subagent_section` -> `working_directory` -> `response_style` -> `citations` -> `critical_reminders`。

### 澄清系统（ask_clarification 中断）-- 在端到端链路中的位置

`<clarification_system>` 强制 `CLARIFY -> PLAN -> ACT`，定义 5 类必澄清场景：`missing_info` / `ambiguous_requirement` / `approach_choice` / `risk_confirmation` / `suggestion`。`ask_clarification` 是**真工具**，由中间件链**末尾**的 `ClarificationMiddleware` 拦截，写 `ToolMessage.artifact.human_input` 请求载荷后经 `Command(goto=END)` 中断 run，等待 Human Input Card 回复。

**关键联动**（见 [[e2e-request-lifecycle]]）：调度任务 / 后台运行设 `context={"non_interactive": True}` 时，图工厂会**剥离** `ask_clarification` 工具（`_NON_INTERACTIVE_DISABLED_TOOL_NAMES`），避免无人值守时卡在中断态。该 context key 仅对**内部认证调用者**（scheduler 启动路径）生效，普通 HTTP/IM 客户端塞入会被 `strip_internal_context_keys` 抹除。

### SystemMessage 合并兜底

动态注入会产生多条 SystemMessage（首轮一条 + 跨午夜再一条），而 vLLM / SGLang / Qwen / Anthropic 拒绝非首条 SystemMessage。`SystemMessageCoalescingMiddleware` 在 `wrap_model_call` 把 `request.system_message` 与 `request.messages` 里的所有 SystemMessage 合并为一条首条--provider 无关、**只动请求载荷、不碰 checkpoint**，所以按标记扫描历史的中间件（记忆构造、摘要、动态上下文检测）不受影响。

```python
# 伪代码：合并只动载荷，不碰 state["messages"]
def wrap_model_call(self, request, handler):
    in_msg_systems = [m for m in request.messages if isinstance(m, SystemMessage)]
    if not in_msg_systems:  return handler(request)        # 零改动，保 prefix cache
    parts = [request.system_message, *in_msg_systems]
    去重: 跨午夜只保留最后一条 dynamic_context_reminder（最新日期）
    merged = SystemMessage("\n\n".join(parts 内容), id=parts[0].id, kwargs=合并)
    return handler(request.override(system_message=merged, messages=非system消息))
    # state["messages"] 不变 -> checkpoint 完整，扫描历史的中间件不受影响
```

### 注入时序（ID-swap 首轮冻结 + 跨午夜校正）

```python
# 伪代码：ID-swap 使首消息持久化冻结，prefix cache 跨 turn 命中
def _inject(state):
    last_date = _last_injected_date(messages)   # 读 additional_kwargs.reminder_date（权威）
    if last_date is None:                        # 首轮
        date_reminder, memory = build_full_reminder()
        return ID-swap(首条 HumanMessage, 同 id 原地替换 -> 持久化冻结):
            SystemMessage(date_reminder, id=原id, kwargs={reminder_date: today})  # 日期走 system
            HumanMessage(memory, id=原id+"__memory")   # 记忆走 user 角色（OWASP LLM01）
            HumanMessage(原内容, id=原id+"__user")      # 后缀防递归 swap
    elif last_date == today:  return None        # 同日：零改动，cache 命中
    else:                                          # 跨午夜
        return ID-swap(末条 HumanMessage): 注入轻量日期校正（无记忆）
```

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/agents/lead/prompt.py` | `SYSTEM_PROMPT_TEMPLATE` 常量 + `apply_prompt_template()` 渲染入口 + 分段构造器 + 技能签名 LRU 缓存 | [system-prompt-full-text.md](./references/code/system-prompt-full-text.md) + [full-prompt-module.md](./references/code/full-prompt-module.md) |
| `core/helix/agents/middlewares/dynamic_context_middleware.py` | `DynamicContextMiddleware`：注入日期/记忆 `<system-reminder>`（首轮冻结 + 跨午夜校正） | [dynamic-context-and-coalescing.md](./references/code/dynamic-context-and-coalescing.md) §1 |
| `core/helix/agents/middlewares/system_message_coalescing_middleware.py` | `SystemMessageCoalescingMiddleware`：合并多条 SystemMessage（provider 兜底） | [dynamic-context-and-coalescing.md](./references/code/dynamic-context-and-coalescing.md) §2 |
| `core/helix/agents/middlewares/clarification_middleware.py` | `ClarificationMiddleware`：拦截 `ask_clarification` 并 `Command(goto=END)` 中断（链尾） | 见 [[middleware-chain-design]] |

### 模块入口与索引

**完整提示词全文**（核心交付物，一字不省）：[system-prompt-full-text.md](./references/code/system-prompt-full-text.md)。含 `<role>` / 保密段 / `<thinking_style>` / `<clarification_system>` / `<working_directory>` / `<response_style>` / `<citations>` / `<critical_reminders>` 全部段落的真实文本与占位符清单表。旧版 skill 曾用 `...` 截断后四段导致无法落地，此处完整保留。

**渲染入口**（完整源码见 [full-prompt-module.md](./references/code/full-prompt-module.md) "渲染入口" 节）：

```python
# 伪代码：渲染入口，纯静态
def apply_prompt_template(subagent_enabled, max_concurrent_subagents, *,
                          agent_name, available_skills, app_config,
                          deferred_names, user_id, skill_names) -> str:
    subagent_section = _build_subagent_section(n) if subagent_enabled else ""
    subagent_reminder / subagent_thinking = 仅 subagent_enabled 时的并发上限文案，否则 ""
    skills_section = get_skills_prompt_section(available_skills, app_config, user_id, skill_names)
    deferred_tools_section = get_deferred_tools_prompt_section(deferred_names)
    acp_and_mounts_section = _build_acp_section(...) + _build_custom_mounts_section(...)
    skill_first_reminder = 按 skill_names 是否为 None 分叉文案
    return SYSTEM_PROMPT_TEMPLATE.format(agent_name=..., soul=..., **slots)
    # 记忆与当前日期由 DynamicContextMiddleware 每 turn 注入，不进静态 prompt
```

**分段构造器与技能签名 LRU 缓存**（完整源码见 [full-prompt-module.md](./references/code/full-prompt-module.md)）：
- `_get_cached_skills_prompt_section`：按 `(技能签名, 白名单, 容器路径, evolution 开关)` 做 LRU 缓存（`maxsize=32`）。
- `get_enabled_skills_for_config`：per-`(config, user_id)` LRU（`maxsize=256`），请求路径永不阻塞磁盘 IO。
- 后台 daemon 线程预热 + 版本号失效：`_refresh_enabled_skills_cache_worker` 加载失败兜底空列表，加载期间收到更新失效版本则循环重算收敛到最新。
- `_build_subagent_section`：动态并发上限文案 + 注册表驱动的子代理类型描述。
- `get_agent_soul` / `_build_self_update_section` / `_build_acp_section` / `_build_custom_mounts_section` / `_get_memory_context`：各可选段构造器，缺失配置返回 `""`。

**动态注入完整源码**（见 [dynamic-context-and-coalescing.md](./references/code/dynamic-context-and-coalescing.md) §1）：
- `_last_injected_date`：读 `additional_kwargs.reminder_date` 做权威检测（不 regex 解析内容）；regex 仅作旧 checkpoint 向后兼容且限定到 `SystemMessage`，永不在用户可影响的记忆 `HumanMessage` 上运行。
- `_is_user_injection_target`：排除 `__user` 后缀消息，杜绝递归 ID-swap 导致 id 无限增长（`id__user__user...`）与幽灵消息重放。
- `abefore_agent`：`asyncio.to_thread` + `_INJECT_TIMEOUT_SECONDS=5.0` 有界超时，超时优雅降级返回 `None`（防止 tiktoken 首次 BPE 下载阻塞事件循环数十分钟）。

**SystemMessage 合并完整源码**（见 [dynamic-context-and-coalescing.md](./references/code/dynamic-context-and-coalescing.md) §2）：
- `_coalesce_request`：`request.messages` 内无 SystemMessage 时返回 `None`（零改动透传，保 prefix cache）；有则合并到 `system_message` 字段，跨午夜去重只保留最新日期 reminder。
- `_flatten_content`：兼容 `str` 与 `list`（多模态）内容形状。
- 用 `wrap_model_call`（非 `before_agent`）：合并在最终请求载荷上运行，`state["messages"]` 不变，checkpoint 完整。

## 反模式与陷阱

- ❌ **system prompt 里直接 f-string 拼 `{user_id}` / `{today}` / `{memory}`** -> prefix cache 永远 miss。修复：日期/记忆一律由 `DynamicContextMiddleware` 注入。
- ❌ **把多条 SystemMessage 直接发给 provider 不做合并** -> vLLM / Anthropic 直接拒（"System message must be at the beginning"）。修复：`SystemMessageCoalescingMiddleware` 兜底。
- ❌ **记忆注入到 SystemMessage（system 角色）** -> 用户可影响内容获得 system 权限，构成提示注入（OWASP LLM01）。修复：记忆走 `HumanMessage`，仅日期走 `SystemMessage`。
- ❌ **用 regex 解析消息内容判断"是否已注入日期"** -> 用户消息里含 `<system-reminder>` 字样会误判。修复：用 `additional_kwargs["reminder_date"]` 做权威检测。
- ❌ **同一 turn 多次注入 reminder / 递归 ID-swap** -> 历史堆出 N 条、id 后缀无限增长（`id__user__user...`）。修复：`_is_user_injection_target` 排除已 swap 的 `__user` 后缀消息。
- ❌ **`deferred_names` 传 `set` 而非 `frozenset`** -> 不可哈希，无法做缓存 key；且与运行时 `DeferredToolFilterMiddleware` 白名单不一致 -> 模型尝试调用提示里说存在但运行时被屏蔽的工具。修复：声明即用 `frozenset`，与运行时同源。
- ❌ **`SOUL.md` 含 `{xxx}` 字符** -> `.format` 把它当占位符抛 `KeyError`，整个 agent 创建链路崩溃。修复：SOUL 内容先 `.replace("{","{{").replace("}","}}")`。
- ❌ **可选段返回 `None`** -> `.format(**slots)` 抛 `TypeError`。修复：不启用时返回 `""`。
- ❌ **`abefore_agent` 不 offload 阻塞 IO** -> tiktoken 首次 BPE 下载阻塞事件循环数十分钟，饿死所有并发请求。修复：`asyncio.to_thread` + 有界 timeout 优雅降级。
- ❌ **`available_skills` 传 `list` 不排序做 LRU key** -> 同集合不同顺序产生两份缓存，命中率减半。修复：`tuple(sorted(set(available_skills)))`。
- ❌ **缓存命中后返回内部对象引用不拷贝** -> 调用方追加内容污染缓存。修复：返回前 `list(...)` / `str(...)` 重新固化。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `subagent_enabled` / `max_concurrent_subagents` | runtime config | 是否输出子代理段 + 并发硬上限文案 |
| `agent_name` | runtime config | 决定 SOUL / self_update 段；缺省 `Helix 2.0` |
| `available_skills` / `skill_names` | agent 配置 | 白名单过滤 / 延迟发现路径分叉 |
| `deferred_names` | `assemble_deferred_tools` 输出 | 必须与运行时过滤器持有的集合同源（`frozenset`） |
| `skills.container_path` | app config | 模板中 "Skills are located at" 路径 |
| `skill_evolution.enabled` | app config | 是否输出 self-evolution 段 |
| `memory.injection_enabled` / `max_injection_tokens` | app config | 动态注入是否带记忆 + token 预算 |
| `acp_agents` / `sandbox.mounts` | app config | 外部工作区 / 自定义挂载点段 |

**关键日志串**

- `DynamicContextMiddleware: injecting full reminder (has_memory=...) into first HumanMessage id=...` - 首轮注入
- `DynamicContextMiddleware: midnight crossing detected - injected date update` - 跨午夜校正
- `DynamicContextMiddleware: injection timed out (...); skipping memory/date injection for this turn` - 优雅降级
- `Failed to load memory context` - 记忆加载失败但不阻塞（返回空串）
- `Failed to load enabled skills for prompt injection` - 技能加载失败兜底空列表
- `Timed out waiting %.1fs for enabled skills cache warm-up` - 启动期预热未完成

**自测方向**

- **纯静态断言**：相同入参 5 次 `apply_prompt_template(...)` 字节级相等。
- **跨用户稳定性**：mock 不同 `user_id`，断言两次静态输出完全一致。
- **完整渲染**：开启 subagent + skills + acp，断言输出含全部段且无 `...` 截断。
- **LRU 命中**：连续两次同签名调用，第二次 `cache_info().hits` 增加；`available_skills` 顺序不同仍命中同一 key。
- **缓存失效**：翻转 skill enabled -> `clear_skills_system_prompt_cache()` -> 第三次渲染 hit=0、misses 增。
- **动态注入首轮冻结**：首轮注入后，第二轮 `before_agent` 返回 `None`（同日不重复注入）。
- **跨午夜**：mock 日期变化，断言只在当前 turn 插入日期校正、历史不变。
- **角色分离**：首轮注入后，日期在 `SystemMessage`、记忆在 `HumanMessage`；记忆 HumanMessage 永不带 `reminder_date`。
- **合并兜底**：构造含 2 条 SystemMessage 的请求，断言合并为 1 条首条、`state["messages"]` checkpoint 不变；无多余 SystemMessage 时零改动透传。
- **转义安全**：SOUL.md 含 `{}` -> 渲染不抛 `KeyError`。
- **deferred 一致性**：随机 `deferred_names`，断言 prompt 出现的工具名集合 == 该集合。
- **超时降级**：mock `_inject` 超时，断言 `abefore_agent` 返回 `None` 且不抛。
- **段空稳定**：`subagent_enabled=False / acp_agents={} / mounts=[]` 下相应段输出 `""`，而非 `"\n"` 或空 XML 节点。
- **并发渲染**：`ThreadPoolExecutor` 并发 50 次 `apply_prompt_template`，断言 LRU 无竞争异常、命中率稳定。

## 进一步阅读

- 完整提示词全文（核心交付物）：[references/code/system-prompt-full-text.md](./references/code/system-prompt-full-text.md)
- 渲染入口 + 分段构造器 + 技能签名 LRU 缓存源码：[references/code/full-prompt-module.md](./references/code/full-prompt-module.md)
- 动态注入与合并中间件完整源码：[references/code/dynamic-context-and-coalescing.md](./references/code/dynamic-context-and-coalescing.md)
- 关联 skill：[[agent-graph-factory]]（渲染时机）、[[middleware-chain-design]]（动态注入与合并的链上位置）、[[context-window-management]]（prefix-cache）、[[memory-system-design]]（记忆来源）、[[skill-system-design]]（技能段）、[[e2e-request-lifecycle]]（ask_clarification 中断与 non_interactive 剥离的端到端位置）
- prefix caching 概念：https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching
