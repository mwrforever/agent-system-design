---
name: memory-system-design
description: 设计 agent 的跨会话记忆系统--per-user 记忆文件 + debounce 防抖队列 + LLM 抽取事实 + 原子写（temp+rename）+ token 预算注入 + guaranteed_categories 保底 + format_memory_for_injection 注入格式化 + MemoryConfig 配置。覆盖 ContextVar 不跨 Timer 线程导致串号、cross-loop 连接复用、tiktoken 冷启动三大真实坑。给出完整真实代码的模块索引。当你要让 agent 记住用户偏好/工作背景/历史事实、做记忆写入不拖慢响应、多用户严格隔离、控制注入 token 预算、保底注入关键类目（如 correction）时调用本 skill。
---

## 何时用

- 想让 agent "记住" 用户偏好 / 工作背景 / 历史事实，跨会话生效
- 记忆写入不能拖慢响应（异步 + 防抖）
- 多用户严格隔离（不能读串、不能写串）
- 注入记忆时要控制 token 预算（不能把 prompt 撑爆），且关键类目（如 correction）必须保底注入
- 排查"记忆写到了 default 用户"、"tiktoken 冷启动卡死"、"半写文件损坏"、"guaranteed 事实被截断丢失"

> 本 skill 讲**记忆系统本身**（数据模型 / 读写 / 抽取 / 防抖 / 注入格式化 / 配置）。记忆**在链路中如何被注入**由 `DynamicContextMiddleware` 每 turn 完成，见 [[system-prompt-template]]；per-user 路径解析与 `user_id` 全链路隔离见 [[multi-user-isolation]]。

## 设计方案（为什么这么设计）

### 核心矛盾：跨会话记忆 vs 写入开销 vs 注入预算

Agent 需要跨会话记住用户（偏好、工作背景、历史事实），但有三股张力：

1. **写入不能拖慢响应**：每轮对话都写盘 + 调 LLM 抽事实，会让用户等秒级延迟。
2. **记忆不能塞爆 prompt**：记忆用几年后，事实列表会膨胀，直接全量注入会把 system prompt 撑爆、击穿 token 上限。
3. **关键事实不能被预算挤掉**：用户的纠正（"你理解错了，应该是 X"）是高价值事实，若普通事实把 token 预算占满，纠正事实被静默丢弃，agent 下次还犯同样的错。

**解法是五件事串联**：per-user 文件存储（隔离 + 可读可编辑）+ debounce 防抖队列（不每 turn 写盘）+ LLM 抽取事实（结构化而非全量对话）+ 原子写（防半写损坏）+ token 预算 + guaranteed_categories（关键类目保底注入）。

### 1. per-user 文件存储（为何：用户隔离 + 可读可编辑）

记忆存为 JSON 文件，路径 `{base_dir}/users/{user_id}/memory.json`（per-user），可选 `{base_dir}/users/{user_id}/agents/{name}/memory.json`（per-user + per-agent）。

- **为何文件而非数据库**：记忆是低频写、低频读（每 turn 注入一次）的文档型数据；JSON 文件让人可直接读、可手动编辑、可版本管理。用户可在 UI 看到并修改自己的记忆，这是产品特性，不是副作用。
- **为何 per-user**：多用户系统里，记忆是最敏感的跨会话数据，必须按 `user_id` 分桶。路径解析由 `get_paths().user_memory_file(user_id)` 统一负责（见 [[multi-user-isolation]]），记忆系统只消费 `user_id` 参数，不自己拼路径。
- **存储可插拔**：`MemoryStorage` 抽象 + `storage_class` 配置，默认 `FileMemoryStorage`，可换成别的实现。

### 2. debounce 防抖队列（为何：高频对话不每 turn 写盘）

`MemoryMiddleware` 在 `after_agent` 把对话入队，**不直接写**。`MemoryUpdateQueue` 用 `threading.Timer` 防抖：每次入队重置定时器到 `debounce_seconds`（默认 30s），到期后批量处理。

- **为何防抖**：用户连续聊 5 轮，不该触发 5 次 LLM 抽取 + 5 次写盘。防抖把窗口内的多次更新合并--同 `(thread_id, user_id, agent_name)` 的新对话**替换**旧快照（最新对话赢），但 `correction_detected` / `reinforcement_detected` 信号 OR-合并（早期信号不丢）。
- **为何用 `threading.Timer` 而非 asyncio**：记忆更新是冷数据写入，best-effort，不该占用 agent 的事件循环。Timer 跑在独立 daemon 线程，进程退出时未完成的更新会丢失（可接受：冷数据，下次对话会重新抽取）。

### 3. LLM 抽取事实（为何：结构化事实而非全量对话）

记忆不存原始对话，而是调 LLM 从对话中抽取结构化事实（`content` / `category` / `confidence`）+ 更新摘要段（`workContext` / `topOfMind` / `recentMonths` 等）。

- **为何不存全量对话**：全量对话体积爆炸，注入时无法控制预算，且大部分内容无长期价值。LLM 抽取把"用户说用 Python 3.12、偏好简洁回复"提炼成一条事实，可控、可去重、可按 confidence 排序注入。
- **为何 LLM 而非规则**：事实的语义判断（这是偏好还是背景？confidence 多少？是否与已有事实矛盾？）规则做不好。LLM 做语义抽取 + 矛盾检测 + 陈旧审查（staleness review）。
- **confidence 阈值**：低于 `fact_confidence_threshold`（默认 0.7）的事实直接丢弃，避免低质量推断污染记忆。
- **去重**：新事实按 `content.strip().casefold()` 做 key，与已有事实撞 key 则丢弃（去重是 writer 的职责，不是模型的）。

### 4. 原子写（为何：防半写损坏）

`FileMemoryStorage.save` 不直接 `json.dump` 到目标文件，而是写 temp 文件（`{path}.{uuid}.tmp`）再 `temp_path.replace(file_path)`（原子 rename）。

```python
# 伪代码：原子写 = temp + rename，crash 时永不半写
def save(memory_data, agent_name, *, user_id):
    file_path = _get_memory_file_path(agent_name, user_id=user_id)
    memory_data = {**memory_data, "lastUpdated": utc_now_iso_z()}   # 浅拷贝，不 mutate caller
    temp_path = file_path.with_suffix(f".{uuid.uuid4().hex}.tmp")
    json.dump(memory_data, open(temp_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    temp_path.replace(file_path)                                    # 同文件系统原子 rename
    _memory_cache[(user_id, agent_name)] = (memory_data, file_path.stat().st_mtime)  # mtime 缓存
    return True
```

- **为何原子写**：进程在 `json.dump` 中途 crash（OOM、kill、断电）会留下半写文件，下次启动 `json.load` 解析失败，记忆永久丢失。temp + rename 保证目标文件要么是旧完整版、要么是新完整版，永不半写。
- **浅拷贝再写**：save 前先 `{**memory_data, "lastUpdated": ...}` 浅拷贝，避免把 caller 的 dict 副作用修改；且缓存引用不会在写盘失败前被更新。
- **mtime 缓存**：`load` 用 `(memory_data, file_mtime)` 做缓存，mtime 变了才重读文件。这让手动编辑文件（UI 改记忆）+ LLM 自动更新两条写入路径不会读到过期缓存。

### 5. token 预算 + guaranteed_categories（为何：关键类目保底注入）

`format_memory_for_injection` 按 `max_injection_tokens`（默认 2000）预算裁剪，但 `guaranteed_categories`（默认 `["correction"]`）内的事实从**独立预算** `guaranteed_token_budget`（默认 500）先选、放在 Facts 块最前，不会被普通事实挤掉。

```python
# 伪代码：两阶段选取 + 结构感知截断（Facts 块是受保护后缀）
def format_memory_for_injection(memory_data, max_tokens=2000, *, guaranteed_categories=None,
                                guaranteed_token_budget=500, use_tiktoken=True):
    sections = [build_user_context(memory_data), build_history(memory_data)]  # base 段
    base_tokens = count_tokens("\n\n".join(sections))
    facts_header = "Facts:\n"
    # 阶段 1：guaranteed 事实从独立预算 G 选，放 Facts 块最前
    guaranteed_lines, g = _select_fact_lines(ranked_guaranteed, token_budget=guaranteed_token_budget, ...)
    # 阶段 2：regular 事实从 M 扣除已占用（base + header + g + 组间 \n）后选
    regular_line_budget = max_tokens - base_tokens - header_cost - g - (N if guaranteed_lines else 0)
    regular_lines, _ = _select_fact_lines(ranked_regular, token_budget=regular_line_budget, ...)
    all_fact_lines = guaranteed_lines + regular_lines
    sections.append(facts_header + "\n".join(all_fact_lines))
    result = "\n\n".join(sections)
    # 结构感知截断：effective_limit = M + g（仅 guaranteed 行自身超 M 时叠加）
    effective_limit = max_tokens + g
    if count_tokens(result) > effective_limit:
        # Facts 块是受保护后缀 -> 只截前面的 base 段（尾裁 + "..."），Facts 块完整
        result = truncate_prefix(sections[:-1], budget=effective_limit - facts_block_tokens) + "\n\n" + facts_block
    return result
```

- **两阶段选取**：阶段 1 从 `guaranteed_token_budget` 选 guaranteed 事实；阶段 2 从 `max_tokens` 扣除已用后选普通事实。常见情况下 guaranteed 行**挤占**普通行（总输出仍 ≤ `max_tokens`）；只有 guaranteed 行本身超出 `max_tokens` 时预算才真正叠加，此时安全截断上限抬升 `max_tokens + guaranteed_actual_usage` 保护它们。
- **结构感知截断**：超预算时，Facts 块是**受保护后缀**，只截断前面的 user-context / history 段。否则 guaranteed 事实会被前缀截断静默丢弃--这恰恰是本设计要避免的。
- **token 计数两模式**：`tiktoken`（准确，但首次需下载 BPE 数据，网络受限环境会卡）+ `char`（零网络，CJK 感知字符估算）。tiktoken 失败缓存 600s 冷却，期间退化到 char，避免反复重试卡死。

### 6. 注入格式化与角色分离

`format_memory_for_injection` 输出纯文本，由 `_get_memory_context` 包成 `<memory>...</memory>` 块，再由 `DynamicContextMiddleware` 注入为一条 `<system-reminder>` 里的 **HumanMessage**（不是 SystemMessage）。

- **角色分离**（OWASP LLM01）：框架权威数据（当前日期）走 `SystemMessage`，用户可影响数据（记忆）走 `HumanMessage`。记忆内容用户可编辑，若给 system 权限构成提示注入。详见 [[system-prompt-template]] 的"动态注入中间件"段。
- **注入时机**：每 turn 由 `DynamicContextMiddleware.before_agent` 注入，首轮冻结（整会话不变，保 prefix cache）。本 skill 只负责**产出注入内容**，注入动作归 [[system-prompt-template]]。
- **prefix cache 友好**：记忆走动态通道（不进静态 system prompt），静态 prompt 跨用户跨会话字节级一致，cache 持续命中。

### 7. 边界与链路位置

**与 [[system-prompt-template]] 的边界**：本 skill 产出记忆文本（`format_memory_for_injection` + `_get_memory_context`），`DynamicContextMiddleware` 消费它并注入。`_get_memory_context` 在 `core/helix/agents/lead/prompt.py`，是 `DynamicContextMiddleware._build_full_reminder` 的调用点。记忆的**角色分离**（走 HumanMessage）由 `DynamicContextMiddleware` 决定，不在本 skill。

**与 [[multi-user-isolation]] 的边界**：本 skill 只接收 `user_id` 参数并透传给存储层；`user_id` 的解析链（contextvar + fallback `default`）、per-user 路径模板（`get_paths().user_memory_file`）、`make_safe_user_id` 规范化归 [[multi-user-isolation]]。

**在端到端链路中的位置**（见 [[e2e-request-lifecycle]]）：

- **注入（读）**：⑤ 中间件链第 13 项 `DynamicContextMiddleware.before_agent` -> `_get_memory_context` -> `get_memory_data(user_id)` -> `format_memory_for_injection` -> `<memory>` 块进 HumanMessage。
- **入队（写）**：⑤ 中间件链第 20 项 `MemoryMiddleware.after_agent` -> 捕获 `user_id`（ContextVar 在此还可见）-> `MemoryUpdateQueue.add`。
- **抽取（写）**：Timer 线程到期 -> `MemoryUpdateQueue._process_queue` -> `MemoryUpdater.update_memory` -> 同步 `model.invoke()` 抽事实 -> `_apply_updates` -> `FileMemoryStorage.save`（原子写）。

记忆系统横跨⑤中间件的读路径（#13）与写路径（#20），两条路径用不同的中间件、不同的时机，互不阻塞。

### 关键不变量（违反则串号 / 丢数据 / 卡死）

1. **`user_id` 必须在入队时捕获**：`MemoryMiddleware.after_agent` 在请求线程读 `get_effective_user_id()` 存进 `ConversationContext`；Timer 线程不继承 ContextVar，若在 Timer 线程里才读，永远拿到 fallback `"default"`，记忆**串号**到默认用户。
2. **写记忆用同步 `model.invoke()` + 专用线程池**：不能复用 lead agent 的 async `httpx.AsyncClient`（全局 lru_cache），否则 cross-loop 连接复用导致连接错误。
3. **原子写必须 temp + rename**：直接写目标文件，crash 时半写损坏。
4. **guaranteed 事实是受保护后缀**：截断时只截前缀段，guaranteed 事实永不丢。
5. **`hide_from_ui` 的中间件注入消息不进记忆 LLM**：否则框架内部文本污染记忆，且 `__memory` 载荷会触发自放大循环。
6. **`factsToRemove` + 畸形 `newFacts` 拒绝整体更新**：否则部分更新（删了事实但没加新的）会丢数据。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/agents/memory/storage.py` | `MemoryStorage` 抽象 + `FileMemoryStorage`（per-user 路径 + mtime 缓存 + 原子写）+ `create_empty_memory` 数据模型 + `get_memory_storage` 单例 | [memory-data-and-injection.md](./references/code/memory-data-and-injection.md) §1 |
| `core/helix/agents/memory/prompt.py` | `format_memory_for_injection`（两阶段预算 + 结构感知截断）+ token 计数（tiktoken / char）+ 格式辅助（`_select_fact_lines` 等）+ 抽取/更新 prompt 模板 | [memory-data-and-injection.md](./references/code/memory-data-and-injection.md) §2-§4 + [extract-and-debounce.md](./references/code/extract-and-debounce.md) §6 |
| `core/helix/agents/memory/queue.py` | `ConversationContext` + `MemoryUpdateQueue`（debounce Timer + 批量处理 + trace 重绑定） | [extract-and-debounce.md](./references/code/extract-and-debounce.md) §2 |
| `core/helix/agents/memory/updater.py` | `MemoryUpdater`（同步 LLM 抽取 + `_apply_updates` 合并 + 陈旧审查 + 上传提及清洗）+ `get_memory_data` 读 API + 手动 CRUD | [extract-and-debounce.md](./references/code/extract-and-debounce.md) §3 |
| `core/helix/agents/memory/message_processing.py` | `filter_messages_for_memory`（剥工具调用 + 剥上传块 + 滤 hide_from_ui）+ correction/reinforcement 检测 | [extract-and-debounce.md](./references/code/extract-and-debounce.md) §4 |
| `core/helix/agents/memory/summarization_hook.py` | 摘要前把即将被压掉的消息冲进记忆队列（`add_nowait`） | [extract-and-debounce.md](./references/code/extract-and-debounce.md) §5 |
| `core/helix/agents/middlewares/memory_middleware.py` | `MemoryMiddleware.after_agent`：入队入口，捕获 `user_id` + trace_id | [extract-and-debounce.md](./references/code/extract-and-debounce.md) §1 |
| `core/helix/config/memory_config.py` | `MemoryConfig`：enabled / injection_enabled / max_injection_tokens / token_counting / guaranteed_categories / debounce_seconds / staleness 等 | [config-and-budget.md](./references/code/config-and-budget.md) §1 |
| `core/helix/agents/lead/prompt.py` | `_get_memory_context`：注入接线（读配置 -> 取记忆 -> 格式化 -> 包 `<memory>`） | [memory-data-and-injection.md](./references/code/memory-data-and-injection.md) §5 |

### 入口伪代码

```python
# 伪代码：写路径入口 -- after_agent 在请求线程捕获 user_id（第一不变量），Timer 线程只读 context.user_id
class MemoryMiddleware:
    def after_agent(self, state, runtime):
        if not get_memory_config().enabled: return None
        thread_id = runtime.context.get("thread_id") or get_config()["configurable"]["thread_id"]
        filtered = filter_messages_for_memory(state["messages"])     # 剥工具调用/上传块/hide_from_ui
        if not has_user_and_ai(filtered): return None
        correction = detect_correction(filtered)
        reinforcement = not correction and detect_reinforcement(filtered)
        user_id = get_effective_user_id()                            # 请求线程读 contextvar（此时尚可见）
        helix_trace_id = normalize_trace_id(runtime.context.get(HELIX_TRACE_METADATA_KEY)) or get_current_trace_id()
        get_memory_queue().add(thread_id, filtered, agent_name=self._agent_name,
                               user_id=user_id, helix_trace_id=helix_trace_id,
                               correction_detected=correction, reinforcement_detected=reinforcement)
        return None

# 伪代码：注入接线 -- _get_memory_context 是记忆系统与注入中间件的唯一接线点
def _get_memory_context(agent_name=None, *, app_config=None):
    config = (app_config.memory if app_config else get_memory_config())
    if not config.enabled or not config.injection_enabled: return ""
    memory_data = get_memory_data(agent_name, user_id=get_effective_user_id())   # to_thread 传播 contextvar
    content = format_memory_for_injection(memory_data, max_tokens=config.max_injection_tokens,
                                          use_tiktoken=(config.token_counting == "tiktoken"),
                                          guaranteed_categories=config.guaranteed_categories,
                                          guaranteed_token_budget=config.guaranteed_token_budget)
    return f"<memory>\n{content}\n</memory>\n" if content.strip() else ""        # 异常兜底空串，永不阻塞注入
```

### 模块索引（references/code/）

- [memory-data-and-injection.md](./references/code/memory-data-and-injection.md) -- `FileMemoryStorage` 全貌（load/reload/路径解析/单例/mtime 缓存）+ token 计数（tiktoken 冷启动冷却 + char 估算）+ `format_memory_for_injection` 主函数（两阶段预算 + 结构感知截断 + fallback）+ 格式辅助（`_select_fact_lines` / `_fallback_format_facts` 等）+ `_get_memory_context` 注入接线
- [extract-and-debounce.md](./references/code/extract-and-debounce.md) -- `MemoryMiddleware.after_agent` 入队入口（捕获 user_id + trace_id）+ `MemoryUpdateQueue`（debounce Timer + 批量处理 + trace 重绑定）+ `MemoryUpdater`（同步 LLM 抽取 + `_apply_updates` 合并 + 陈旧审查 + 上传提及清洗）+ 手动 CRUD + `message_processing` + `summarization_hook` + 抽取 prompt 模板
- [config-and-budget.md](./references/code/config-and-budget.md) -- `MemoryConfig` 完整字段 + 预算数学（两阶段 + 结构感知截断）+ 陈旧审查设计

### 配置旋钮速查

| 旋钮 | 默认 | 说明 |
|---|---|---|
| `enabled` / `injection_enabled` | `True` / `True` | 总开关（含写入）/ 注入开关（可只写不注） |
| `max_injection_tokens` | `2000` | 注入 token 预算上限 |
| `token_counting` | `tiktoken` | `tiktoken`（准确）/ `char`（零网络 CJK 感知） |
| `guaranteed_categories` | `["correction"]` | 保底注入的类目（独立预算） |
| `guaranteed_token_budget` | `500` | guaranteed 段 token 上限 |
| `debounce_seconds` | `30` | 防抖窗口（1-300） |
| `max_facts` / `fact_confidence_threshold` | `100` / `0.7` | 事实条数上限 / 入库 confidence 下限 |
| `staleness_review_enabled` / `staleness_age_days` | `True` / `90` | 陈旧审查开关 / 年龄阈值 |

## 反模式与陷阱

- ❌ **Timer 线程里 `get_effective_user_id()`** -> ContextVar 不跨 `threading.Timer` 线程，永远拿到 fallback `"default"`，记忆**串号**到默认用户。修复：`MemoryMiddleware.after_agent` 在请求线程捕获 `user_id` 存入 `ConversationContext`，Timer 线程只读 `context.user_id`。trace_id 同理（`helix_trace_id` 捕获后在 Timer 线程 `request_trace_context(...)` 重绑定）。
- ❌ **记忆更新复用 lead agent 的 async `httpx.AsyncClient`** -> langchain 全局 lru_cache 的 async 客户端连接池跨事件循环复用，连接错误（issue #2615）。修复：`MemoryUpdater` 用**同步** `model.invoke()` + 专用 `ThreadPoolExecutor`（4 worker），不碰 async 客户端池。
- ❌ **直接 `json.dump(path, data)` 不写 temp** -> 进程 crash 时半写文件，下次 `json.load` 解析失败，记忆永久丢失。修复：temp + `replace`（原子 rename）。
- ❌ **tiktoken 在 hot path 同步下载 BPE** -> 网络受限环境冷启动卡到 OS TCP 超时（~26 分钟）。修复：lazy 缓存 + loading sentinel（并发 caller 不重复触发）+ 失败缓存 600s 冷却（期间退化 char 估算）+ `warm_tiktoken_cache()` 启动预热 + `token_counting=char` 零网络开关。
- ❌ **`guaranteed_categories` 传裸字符串** -> 迭代 `str` 产出单字符 frozenset，静默关闭 guarantee 无告警。修复：`isinstance(guaranteed_categories, str)` 显式 `TypeError`（配置层 Pydantic 兜底，公共 helper 也守一道）。
- ❌ **超预算时前缀截断丢 guaranteed 事实** -> guaranteed 事实被 user-context 段挤掉，本设计白做。修复：结构感知截断--Facts 块是受保护后缀，只截前面的 user-context / history 段。
- ❌ **`hide_from_ui` 的框架注入消息进记忆 LLM** -> 框架内部文本（TodoMiddleware 提醒、`__memory` 载荷）污染长期记忆，`__memory` 载荷还会触发自放大循环。修复：`filter_messages_for_memory` 跳过 `hide_from_ui` 且非 human-input-response 的消息。
- ❌ **`factsToRemove` 配畸形 `newFacts`** -> 部分更新（删了事实但新事实全废）丢数据。修复：`_normalize_memory_update_data` 检测到此组合抛 `JSONDecodeError`，拒绝整体更新。
- ❌ **LLM 幻觉删保护类目事实** -> staleness 审查时模型删了 `correction` 类目（不该删）。修复：`_select_stale_candidates` 排除 `staleness_protected_categories`；`_apply_updates` 把模型返回的删除 id 与候选集**交集**（模型 slip 删非候选 id 被静默拒）。
- ❌ **记忆里记上传文件事件** -> agent 下个会话幻觉老文件还在。修复：`_strip_upload_mentions_from_memory` 用窄正则剥上传事件句（"user works with CSV files" 这类偏好不动）。
- ❌ **`memory.json` 用绝对 `storage_path` 不分用户** -> 多用户共享一份记忆。修复：`storage_path` 留空走 per-user 默认；绝对路径是显式 opt-out（文档警告）。
- ❌ **save 前不深拷贝** -> save 失败时 in-place mutation 已腐蚀缓存里的原对象引用。修复：`_apply_updates` 对 `current_memory` 做 `copy.deepcopy`；`save` 做 shallow-copy 再加 `lastUpdated`。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 调节效果 |
|---|---|---|
| `memory.debounce_seconds` | config | 增大 -> 写盘更懒、丢更新风险略增；减小 -> 更实时但 LLM 调用更频繁 |
| `memory.max_injection_tokens` | config | 注入预算；过大会挤占对话上下文，过小会丢事实 |
| `memory.guaranteed_categories` | config | 加 `"preference"` / `"behavior"` 可保底更多类目；注意每加一类都从 `guaranteed_token_budget` 扣 |
| `memory.guaranteed_token_budget` | config | guaranteed 段上限；过大则普通事实被挤占 |
| `memory.fact_confidence_threshold` | config | 调高 -> 入库更保守；调低 -> 噪声事实增多 |
| `memory.max_facts` | config | 事实条数硬上限（超限按 confidence 截断，无 recency tiebreaker） |
| `memory.token_counting` | config | 网络受限环境设 `char`，零依赖零阻塞 |
| `memory.staleness_age_days` / `staleness_min_candidates` | config | 陈旧审查触发条件；候选太少不审查（省 prompt 开销） |

**关键日志串**

- `Memory update queued for thread %s, queue size: %d` -- ⑤ #20 `MemoryMiddleware` 入队
- `Processing %d queued memory updates` -- Timer 线程开始批量处理
- `Updating memory for thread %s` / `Memory updated successfully for thread %s` -- 单条更新开始/成功
- `Memory update skipped/failed for thread %s` -- 更新跳过/失败（LLM 解析失败等）
- `Memory saved to %s` -- 原子写落盘
- `Failed to load tiktoken encoding %r; falling back to char-based estimation` -- tiktoken 冷启动失败，退化 char
- `Memory injection: guaranteed-category path failed, falling back to confidence-only ranking` -- 注入主路径异常，降级
- `Staleness review removed fact %s: %s` -- 陈旧审查实际删除某事实（带 reason）
- `Failed to load memory context` -- `_get_memory_context` 异常但返回空串（不阻塞注入）

**自测方向**

- **串号防护**：mock 两个不同 `user_id` 的请求，入队后检查 `ConversationContext.user_id` 分别正确；Timer 触发后断言写到各自的 `users/{user_id}/memory.json`，未串到 `default`。
- **原子写**：在 `json.dump` 中途注入异常，断言目标文件仍是旧完整版（temp 残留可接受，目标文件不半写）。
- **debounce 合并**：同 `(thread_id, user_id, agent_name)` 连续入队 3 次，断言队列只保留 1 条（最新快照），但 `correction_detected` 若任一为 True 则最终为 True。
- **guaranteed 保底**：构造 50 条普通事实（高 confidence）+ 2 条 correction 事实，`max_injection_tokens=2000`，断言 correction 事实在输出中、且在 Facts 块最前；普通事实被预算裁剪。
- **结构感知截断**：构造超大 user-context 段 + guaranteed 事实，断言截断只发生在 user-context 段（尾裁 + `...`），Facts 块完整。
- **tiktoken 降级**：mock `tiktoken.get_encoding` 抛异常，断言首次返回 char 估算、600s 内不重试、`token_counting=char` 完全不调 tiktoken。
- **cross-loop 安全**：在运行中的事件循环里调 `update_memory`，断言走 `_SYNC_MEMORY_UPDATER_EXECUTOR` 线程池（`model.invoke()` 同步），不创建新事件循环。
- **hide_from_ui 防污染**：构造含 `hide_from_ui=True` 的 HumanMessage（含 `__memory` 载荷），断言 `filter_messages_for_memory` 不输出它。
- **staleness 守卫**：构造一个 `correction` 类目且超龄的事实，断言它不在 `_select_stale_candidates` 输出里（保护类目豁免）；模型返回删一个非候选 id，断言被交集拒。
- **部分更新拒绝**：LLM 返回 `factsToRemove` 非空 + `newFacts` 含畸形条目，断言 `_normalize_memory_update_data` 抛 `JSONDecodeError`。

## 进一步阅读

- 存储全貌 + token 计数 + `format_memory_for_injection` 主函数 + 注入接线源码：[references/code/memory-data-and-injection.md](./references/code/memory-data-and-injection.md)
- 入队入口 + 防抖队列 + LLM 抽取 + 消息处理 + prompt 模板源码：[references/code/extract-and-debounce.md](./references/code/extract-and-debounce.md)
- 完整配置 + 预算数学 + 陈旧审查设计：[references/code/config-and-budget.md](./references/code/config-and-budget.md)
- 关联 skill：[[system-prompt-template]]（`DynamicContextMiddleware` 注入记忆 + 角色分离）、[[multi-user-isolation]]（per-user 路径 + `get_effective_user_id` 解析链）、[[middleware-chain-design]]（#13 DynamicContext 读 / #20 Memory 写 在链上位置）、[[context-window-management]]（注入预算与摘要的协同）、[[observability-tracing]]（trace_id 跨线程重绑定）、[[e2e-request-lifecycle]]（记忆系统在⑤中间件链的读/写双路径位置）
