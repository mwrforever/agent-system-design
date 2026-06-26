---
name: memory-system-design
description: 设计 agent 的跨会话 memory——per-user 文件 + debounce 队列 + LLM 抽取事实 + 原子写 + token 预算注入。覆盖 ContextVar 在 Timer 线程不可见的经典坑。
---

## 何时用

- 想让 agent "记住" 用户偏好 / 工作背景 / 历史事实
- memory 写入不能拖慢响应（异步）
- 多用户严格隔离（不能读串）
- 注入 memory 时要控制 token 预算（不能把 prompt 撑爆）

## 设计思想

1. **per-user 文件存储**：`users/{user_id}/memory.json`；可选 `users/{user_id}/agents/{agent}/memory.json` 做 per-agent 隔离。
2. **结构化数据**：分 `userContext` (workContext / personalContext / topOfMind) + `history`（recentMonths / earlierContext / longTermBackground）+ `facts`（id / content / category / confidence / createdAt / source）。
3. **写入异步 + debounce**：MemoryMiddleware 入队（30s 默认）→ 后台 Timer 线程批量 LLM 抽取 + 合并 + 原子写。
4. **ContextVar 不跨 Timer 线程**：必须在入队时**捕获 user_id**存到 ConversationContext，不能在 Timer 线程里 `get_effective_user_id()`。
5. **原子写**：temp + rename，避免半写状态；并发写用 file lock。
6. **注入有预算**：用 tiktoken / 字符估算控制注入 token；超限按"保证类别（preference / behavior）优先"截断。
7. **tiktoken 冷启动**：首次需下载 BPE 数据，可能阻塞网络受限环境。提供 `char` 模式作为零网络 fallback。

## 实现模板

### 数据结构

```python
class MemoryFact(TypedDict):
    id: str
    content: str
    category: Literal["preference", "knowledge", "context", "behavior", "goal"]
    confidence: float        # 0.0 - 1.0
    createdAt: str           # ISO 8601
    source: str              # "user_explicit" / "llm_inferred"


class MemoryData(TypedDict):
    workContext: str
    personalContext: str
    topOfMind: str
    recentMonths: str
    earlierContext: str
    longTermBackground: str
    facts: list[MemoryFact]
```

### Middleware：入队

```python
class MemoryMiddleware(AgentMiddleware):
    def __init__(self, *, agent_name=None, memory_config):
        self.agent_name = agent_name
        self.config = memory_config

    def after_agent(self, state, runtime):
        if not self.config.enabled: return None
        messages = state["messages"]
        # 只关心 user 输入 + 最终 AI 回答
        user_msg = _last_human_message(messages)
        ai_msg   = _last_ai_message_with_no_tool_calls(messages)
        if not user_msg or not ai_msg: return None

        # ⭐ 在 middleware 线程里 capture user_id（Timer 线程拿不到 ContextVar）
        user_id = get_effective_user_id()
        get_memory_queue().add(
            thread_id=runtime.context["thread_id"],
            messages=[user_msg, ai_msg],
            agent_name=self.agent_name,
            user_id=user_id,
        )
        return None
```

### Queue：debounce

```python
@dataclass
class ConversationContext:
    thread_id: str
    messages: list
    agent_name: str | None
    user_id: str | None        # ⭐ 已 capture
    timestamp: datetime = field(default_factory=lambda: datetime.now(UTC))


class MemoryUpdateQueue:
    def __init__(self):
        self._queue: dict[tuple[str, str | None, str | None], ConversationContext] = {}
        self._lock = threading.Lock()
        self._timer: threading.Timer | None = None

    def add(self, thread_id, messages, agent_name=None, user_id=None):
        key = (thread_id, user_id, agent_name)
        with self._lock:
            self._queue[key] = ConversationContext(thread_id, messages, agent_name, user_id)
            self._reset_timer()

    def _reset_timer(self):
        if self._timer: self._timer.cancel()
        self._timer = threading.Timer(self._debounce_seconds(), self._flush)
        self._timer.daemon = True
        self._timer.start()

    def _flush(self):
        with self._lock:
            batch = list(self._queue.values())
            self._queue.clear()
        for ctx in batch:
            try:
                # ⭐ 在 worker 线程里用 ctx.user_id，不要再调 get_effective_user_id()
                MemoryUpdater(user_id=ctx.user_id, agent_name=ctx.agent_name).process(ctx.messages)
            except Exception:
                logger.exception("memory update failed for %s", ctx.thread_id)
```

### Updater：LLM 抽取 + 原子写

```python
class MemoryUpdater:
    def __init__(self, *, user_id: str, agent_name: str | None = None):
        self.user_id = user_id
        self.agent_name = agent_name

    def process(self, messages: list):
        old = self._load()
        llm_output = self._call_llm(MEMORY_UPDATE_PROMPT.format(
            existing_memory=json.dumps(old, ensure_ascii=False, indent=2),
            conversation=format_conversation(messages),
        ))
        updates = self._parse(llm_output)
        merged = self._merge(old, updates)
        self._atomic_save(merged)
        invalidate_memory_cache(self.user_id, self.agent_name)

    def _merge(self, old: MemoryData, updates: dict) -> MemoryData:
        # 1) 更新 user context 摘要字段
        merged = {**old, **(updates.get("context_updates") or {})}
        # 2) Facts 去重（trim 后内容比较）
        existing = {self._fact_key(f): f for f in old["facts"]}
        for new_fact in updates.get("new_facts", []):
            if new_fact["confidence"] < 0.7: continue
            existing[self._fact_key(new_fact)] = new_fact
        merged["facts"] = list(existing.values())[-100:]    # 上限
        return merged

    @staticmethod
    def _fact_key(f): return f["content"].strip().lower()

    def _atomic_save(self, data: MemoryData):
        path = memory_file(self.user_id, self.agent_name)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(path)        # 原子 rename
```

### 注入到 system-reminder

```python
def format_memory_for_injection(data: MemoryData, *, max_tokens=2000,
                                use_tiktoken=True,
                                guaranteed_categories=("preference", "behavior"),
                                guaranteed_token_budget=500) -> str:
    sections = []
    # 1) 保证类别先入（占用 guaranteed_token_budget 内）
    guaranteed = [f for f in data["facts"] if f["category"] in guaranteed_categories]
    used = 0
    for f in guaranteed:
        cost = _count_tokens(f["content"], use_tiktoken=use_tiktoken)
        if used + cost > guaranteed_token_budget: break
        sections.append(f["content"]); used += cost
    # 2) 其余按 confidence 降序填到 max_tokens
    rest = sorted([f for f in data["facts"] if f["category"] not in guaranteed_categories],
                   key=lambda x: -x["confidence"])
    for f in rest:
        cost = _count_tokens(f["content"], use_tiktoken=use_tiktoken)
        if used + cost > max_tokens: break
        sections.append(f["content"]); used += cost
    return _render(data["userContext"], sections)
```

## 反模式

- ❌ Timer 线程里 `get_effective_user_id()` → ContextVar 不跨线程，永远拿到 fallback 默认用户 → memory **串号**到默认用户
- ❌ 直接 `json.dump(path, data)` 不写 temp → 进程 crash 时半写文件，下次启动 parse 失败
- ❌ 注入时不限 token → memory 字段堆几年后把 system prompt 撑爆
- ❌ tiktoken 在 hot path 同步下载 BPE → 网络受限环境冷启动卡 26 分钟（OS TCP 超时）
- ❌ memory.json 路径用绝对路径配置但不分用户 → 多用户共享一份 memory
- ✅ 入队时 capture user_id 存 dataclass
- ✅ tiktoken 失败 → 缓存 cooldown 600s 内退化到字符估算，避免反复重试
- ✅ 提供 `token_counting=char` 配置开关，零网络环境直接零依赖

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[multi-user-isolation]] [[system-prompt-template]] [[context-window-management]]
