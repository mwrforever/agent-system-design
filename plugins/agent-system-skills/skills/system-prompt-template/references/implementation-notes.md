# Implementation Notes — system-prompt-template

> 适用范围：LangChain 1.x agent 的 `system_prompt` 渲染层。
> 核心约束：**系统提示是纯静态字符串**，动态部分（日期/记忆/技能激活）通过中间件以 `<system-reminder>` 形式注入。
> 关联：[[agent-graph-factory]]（渲染时机）、[[middleware-chain-design]]（动态注入）、[[context-window-management]]（prefix-cache）。

---

## 1. 组件矩阵

| 通用组件名 | 真实职责 | 关键 API / 签名 |
|---|---|---|
| `apply_prompt_template(...)` | 顶层渲染入口；返回纯静态完整 system prompt | 仅做模板字符串 `.format(...)`，无任何运行时数据（日期/用户/上下文） |
| `SYSTEM_PROMPT_TEMPLATE` | 顶层 Jinja-less 模板常量 | 占位符使用 `{name}` 语法；保持稳定文本以最大化 prefix-cache hit |
| `get_skills_prompt_section(available_skills, app_config)` | 渲染 `<skill_system>` 段；按 enabled / available 过滤 | 内部用 `_get_cached_skills_prompt_section(LRU)` 做按签名缓存 |
| `get_deferred_tools_prompt_section(deferred_names)` | 渲染 `<available-deferred-tools>` | 与 `DeferredToolFilterMiddleware` 的 `deferred_names` 必须同源 |
| `_build_subagent_section(max_concurrent, app_config)` | 子 agent 调度提示 | 根据已注册子 agent 列表动态构造，但参数仍是启动期定值 |
| `_build_self_update_section(agent_name)` | 自定义 agent 自我更新指引 | 仅在 `agent_name` 非空时输出 |
| `_build_acp_section(app_config)` / `_build_custom_mounts_section(app_config)` | 外挂目录与 ACP agent 工作区说明 | 没有配置时为空字符串 |
| `get_agent_soul(agent_name)` | 装载自定义 agent 的 `SOUL.md` | 包裹成 `<soul>…</soul>` 段；缺失则空 |
| `_get_memory_context(agent_name, app_config)` | 渲染 `<memory>` 段（仅供动态注入复用） | **不参与静态 prompt**；只在动态中间件里调用 |
| `_get_cached_skills_prompt_section(...)` | LRU 缓存的 skills 子段 | key = `(skill_signature, available_key, container_base_path, evolution_section)` |
| `clear_skills_system_prompt_cache()` | skill 配置变化时主动失效 | 同时清空 LRU 与签名缓存 |

---

## 2. 关键调用时序

### 时序 A：图工厂渲染（启动期一次性）

```
make_agent(config)
  └─ apply_prompt_template(subagent_enabled, max_concurrent_subagents,
                           agent_name, available_skills, app_config,
                           deferred_names=setup.deferred_names)
        ├─ get_agent_soul(agent_name)               # 可选
        ├─ _build_self_update_section(agent_name)   # 可选
        ├─ get_skills_prompt_section(...)           # LRU 命中即纯字符串拼接
        ├─ get_deferred_tools_prompt_section(deferred_names)
        ├─ _build_subagent_section(n) if subagent_enabled
        ├─ _build_acp_section(app_config) + _build_custom_mounts_section(...)
        └─ SYSTEM_PROMPT_TEMPLATE.format(**slots) → 静态字符串
  └─ create_agent(system_prompt=<上面的字符串>, …)
```

### 时序 B：每轮注入（动态部分独立通道）

```
before_agent (DynamicContextMiddleware)
  └─ _build_full_reminder()
        ├─ date_reminder = "<system-reminder><current_date>YYYY-MM-DD, Weekday</current_date></system-reminder>"
        └─ memory_block  = "<memory>… 已格式化的事实 …</memory>"  # 来自 _get_memory_context
  └─ ID-swap：用 SystemMessage(reminder) 替换首条 HumanMessage 的 id
            另起 HumanMessage(memory_block) + HumanMessage(原内容)
  → 静态系统提示完全不变 → prefix-cache 持续命中
```

### 时序 C：技能配置热更新

```
PUT /skills/<name>  (enabled 翻转)
  → 业务层 dispatch → clear_skills_system_prompt_cache()
       ├─ _get_cached_skills_prompt_section.cache_clear()
       ├─ _enabled_skills_cache = None
       └─ 触发后台 worker 重新加载
下一次 make_agent → get_skills_prompt_section() 重新进入 LRU → 静态 prompt 重新计算
```

---

## 3. 数据契约 / 类型签名

```python
from typing import Iterable

def apply_prompt_template(
    subagent_enabled: bool = False,
    max_concurrent_subagents: int = 3,
    *,
    agent_name: str | None = None,
    available_skills: set[str] | None = None,
    app_config: "AppConfig | None" = None,
    deferred_names: frozenset[str] = frozenset(),
) -> str: ...

def get_skills_prompt_section(
    available_skills: set[str] | None = None,
    *,
    app_config: "AppConfig | None" = None,
) -> str: ...

# LRU key 形状（必须可哈希 & 稳定）
SkillSignature = tuple[tuple[str, str, str, str], ...]   # (name, description, category, container_path)
AvailableKey  = tuple[str, ...] | None                   # sorted tuple，None 表示无白名单

# 模板 slots
SLOTS = {
    "agent_name": str,
    "soul": str,                       # "<soul>…</soul>\n" 或 ""
    "self_update_section": str,        # "<self_update>…</self_update>" 或 ""
    "skills_section": str,             # "<skill_system>…</skill_system>" 或 ""
    "deferred_tools_section": str,     # "<available-deferred-tools>…" 或 ""
    "subagent_section": str,
    "subagent_reminder": str,          # critical_reminders 内嵌片段
    "subagent_thinking": str,
    "acp_section": str,                # acp + custom mounts 合并
}
```

---

## 4. 关键不变量

1. **`apply_prompt_template` 不引入任何运行时变量** — 不调 `datetime.now()`、不读 `user_id`、不查实时配置。违反后果：prefix-cache 命中率崩塌，token 成本显著上升。
2. **动态部分必须走 `<system-reminder>` 系统消息** — 不能写进系统 prompt。违反后果：每轮 prompt 不同，模型重新冷启动，且无法跨用户复用。
3. **`skills_section` 的 LRU key 必须包含所有渲染因子** — `(签名, 白名单, 容器路径, evolution 开关)`。违反后果：配置变更后渲染结果残留。
4. **`deferred_names` 必须等于运行时过滤器持有的集合** — 提示与运行时白名单一致。违反后果：模型尝试调用提示里说存在但运行时被屏蔽的工具，反复失败。
5. **`agent_name` 缺省时使用稳定占位串**（如 `agent`）— 不要写当前时间或随机串。违反后果：每个图实例 prompt 不同。
6. **`SOUL.md` 加载失败时返回空字符串**，不抛错 — 违反后果：单个自定义 agent 的脏数据让所有 thread 创建失败。
7. **可选段在不启用时输出空字符串而非 `None`** — 保持 `.format(**slots)` 永远拿到字符串。违反后果：`.format` 抛 `TypeError: unsupported format string passed to NoneType`。
8. **`skills_section` 与 `skill_evolution_section` 来源同一份 `app_config`** — 否则 LRU 缓存的“evolution 开关”片段可能与实际不一致。违反后果：模型按已禁用的 self-evolution 行为操作。
9. **`deferred_tools_section` 在 deferred 为空时返回空字符串** — 不要输出空 XML 容器节点。违反后果：模型把空容器当作“有但未声明”，产生幻觉调用。
10. **模板里 `{` `}` 全部转义为 `{{` `}}`，仅占位符保留单括号** — 否则 `.format` 抛 `KeyError`。违反后果：渲染崩溃，整个 agent 创建链路崩溃。
11. **缓存失效与重建必须原子** — `cache_clear` 后立即触发后台重载，且后台失败要保证下次请求自愈。违反后果：长期返回空 skills 段。

---

## 5. 常见踩坑

1. **在模板里写当前日期** — 看似省事，实际让 prefix-cache 完全失效。修复：日期一律由 dynamic context 中间件注入。
2. **`available_skills=list(...)` 不排序** — LRU key 不稳定，相同内容生成不同 key。修复：`tuple(sorted(set(available_skills)))`。
3. **直接在 `SYSTEM_PROMPT_TEMPLATE` 拼装用户名/工作区** — 用户切换后旧 prompt 还在缓存。修复：用 reminder 注入。
4. **`get_skills_prompt_section` 抛异常未兜底** — 整个 agent 启动失败。修复：try/except + 日志 + 返回空段。
5. **`deferred_names` 传 `set` 而非 `frozenset`** — 不可哈希，无法做缓存 key。修复：参数声明就用 `frozenset`。
6. **自定义 agent 的 `SOUL.md` 含 `{xxx}` 字符** — 渲染时被当占位符。修复：先把 SOUL 内容做 `.replace("{","{{").replace("}","}}")`，或换 Jinja。
7. **多语言提示直接硬塞英文模板** — 模型语言一致性变差。修复：按用户语言挑选模板变体，但仍保持单回话内稳定。
8. **缓存命中后忘记 `list(...)` 拷贝** — 外部修改返回值污染缓存。修复：返回前 `list(skills)` 或写一个 immutable wrapper。
9. **`subagent_section` 包含已注册子 agent 列表，但注册表是动态的** — 容易出现“提示说有 X，运行时没有 X”。修复：渲染时基于一份冻结快照，并随注册变更主动失效缓存。
10. **`apply_prompt_template` 把超长 deferred 列表全部展开** — prompt 体积爆炸。修复：只列名 + 描述首行，详细 schema 放进运行时按需附加。
11. **多套 `available_skills` 共用同一 LRU 但 key 没排序** — 同集合不同顺序产生两份缓存，命中率减半。修复：`tuple(sorted(set(...)))`。
12. **`get_skills_prompt_section` 在缓存命中后返回内部对象引用** — 调用方追加内容污染缓存。修复：返回前 `str(...)` 重新固化字符串。

---

## 6. 调参旋钮 + 调试入口

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `subagent_enabled` | runtime config | 整段 subagent section 是否出现 |
| `max_concurrent_subagents` | runtime config | 子 agent 并发硬上限提示文案 |
| `agent_name` | runtime config | 决定 SOUL / self_update 段 |
| `available_skills` | agent 配置 | 白名单过滤 |
| `deferred_names` | `assemble_deferred_tools` 输出 | 与 prompt 中提示完全一致 |
| `skills.container_path` | app config | 模板中 “Skills are located at: …” 路径 |
| `skill_evolution.enabled` | app config | 是否输出 self-evolution 段 |
| `acp_agents` / `sandbox.mounts` | app config | 外部工作区 / 自定义挂载点段 |

**关键日志串**：

- `Failed to load skills for allowed-tools policy` — skills 加载失败但不阻塞，进入 fallback。
- `Timed out waiting %.1fs for enabled skills cache warm-up` — 启动期预热未完成。
- `apply_prompt_template: rendered N=<len> chars, skills_section_cached=true|false` — 建议加这一行 INFO，定位渲染开销。
- `deferred_names mismatch: prompt=… runtime=…` — 静态/运行时一致性自检，应为 0。

**测试方向**：

- 纯静态断言：相同入参 5 次 `apply_prompt_template(...)` 字节级相等。
- 跨用户稳定性：mock 不同 `user_id`，断言两次输出完全一致。
- LRU 命中：连续两次同签名调用，第二次 `cache_info().hits` 增加。
- 缓存失效：翻转 skill enabled → `clear_skills_system_prompt_cache()` → 第三次渲染 hit=0、misses 增。
- deferred 一致性：随机生成 `deferred_setup.deferred_names`，断言 prompt 中出现的工具名集合等于该集合。
- 转义安全：SOUL.md 内容含 `{}` → 渲染不抛 `KeyError`。
- 渲染体积：模板长度上界监控，超阈值 CI 报警，预防 token 隐性膨胀。
- 占位符完备性：模板 `.format` 时若 slots 缺失任一 key 必须立刻 `KeyError`；保留这个失败模式以便 CI 第一时间发现新增字段未传。
- 段空稳定：`subagent_enabled=False / acp_agents={} / mounts=[]` 下相应段输出空字符串，而非 `"\n"` 或空 XML 节点。
- 并发渲染：用 `ThreadPoolExecutor` 并发调用 50 次 `apply_prompt_template`，断言 LRU 不出现竞争异常且最终命中率稳定。

---

相关 skill：[[agent-graph-factory]] · [[middleware-chain-design]] · [[context-window-management]] · [[skill-system-design]] · [[memory-system-design]]
