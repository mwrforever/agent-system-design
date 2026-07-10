# 完整源码：系统提示词模块（prompt.py）

> 本文件给出 `core/helix/agents/lead/prompt.py` 的**完整实现**：渲染入口 `apply_prompt_template()`、各分段构造器、记忆上下文、技能签名 LRU 缓存机制与后台预热 worker。`SYSTEM_PROMPT_TEMPLATE` 常量全文见 [system-prompt-full-text.md](./system-prompt-full-text.md)（核心交付物，一字不省）。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`），去除一切项目字样。原代码注释保留以保真。

## 模块导入与常量

```python
# core/helix/agents/lead/prompt.py
from __future__ import annotations

import asyncio
import logging
import threading
from collections import OrderedDict
from functools import lru_cache
from typing import TYPE_CHECKING

from helix.config.agents_config import load_agent_soul
from helix.constants import DEFAULT_SKILLS_CONTAINER_PATH
from helix.skills.storage import get_or_new_skill_storage, get_or_new_user_skill_storage
from helix.skills.types import Skill, SkillCategory
from helix.subagents import get_available_subagent_names
from helix.tools.builtins.tool_search import get_deferred_tools_prompt_section

if TYPE_CHECKING:
    from helix.config.app_config import AppConfig

logger = logging.getLogger(__name__)

# 每个 (app_config, user_id) 的 enabled-skills 缓存上限。
# 没有它，长寿命多用户进程会为每个出现过的用户（及每个注入的 app_config）
# 泄漏一个条目，仅受进程见过的身份数量限制。256 对真实流量足够宽裕，
# 且与 helix.skills.storage 里 _user_scoped_storages 的上限一致；溢出时 LRU 淘汰。
_ENABLED_SKILLS_BY_CONFIG_CACHE_MAXSIZE = 256

_ENABLED_SKILLS_REFRESH_WAIT_TIMEOUT_SECONDS = 5.0
_enabled_skills_lock = threading.Lock()
_enabled_skills_cache: list[Skill] | None = None
_enabled_skills_by_config_cache: "OrderedDict[tuple[int, str], tuple[object, list[Skill]]]" = OrderedDict()
_enabled_skills_refresh_active = False
_enabled_skills_refresh_version = 0
_enabled_skills_refresh_event = threading.Event()
```

## 渲染入口（纯静态，无运行时变量）

```python
# core/helix/agents/lead/prompt.py
def apply_prompt_template(
    subagent_enabled: bool = False,
    max_concurrent_subagents: int = 3,
    *,
    agent_name: str | None = None,
    available_skills: set[str] | None = None,
    app_config: "AppConfig | None" = None,
    deferred_names: frozenset[str] = frozenset(),
    user_id: str | None = None,
    skill_names: frozenset[str] | None = None,
) -> str:
    # 仅在启用时构造子代理段（来自运行时参数，启动期定型）
    n = max_concurrent_subagents
    subagent_section = _build_subagent_section(n, app_config=app_config) if subagent_enabled else ""

    # 子代理提醒注入 critical_reminders（仅启用时）
    subagent_reminder = (
        "- **Orchestrator Mode**: You are a task orchestrator - decompose complex tasks into parallel sub-tasks. "
        f"**HARD LIMIT: max {n} `task` calls per response.** "
        f"If >{n} sub-tasks, split into sequential batches of ≤{n}. Synthesize after ALL batches complete.\n"
        if subagent_enabled else ""
    )

    # 子代理思考指引（仅启用时）
    subagent_thinking = (
        "- **DECOMPOSITION CHECK: Can this task be broken into 2+ parallel sub-tasks? If YES, COUNT them. "
        f"If count > {n}, you MUST plan batches of ≤{n} and only launch the FIRST batch now. "
        f"NEVER launch more than {n} `task` calls in one response.**\n"
        if subagent_enabled else ""
    )

    # 技能段：延迟发现路径(skill_names)与全量元数据路径分叉
    skills_section = get_skills_prompt_section(
        available_skills, app_config=app_config, user_id=user_id, skill_names=skill_names,
    )

    # 延迟工具段（tool_search），与运行时 DeferredToolFilterMiddleware 白名单同源
    deferred_tools_section = get_deferred_tools_prompt_section(deferred_names=deferred_names)

    acp_section = _build_acp_section(app_config=app_config)
    custom_mounts_section = _build_custom_mounts_section(app_config=app_config)
    acp_and_mounts_section = "\n".join(s for s in (acp_section, custom_mounts_section) if s)

    # "Skill First" 文案随发现路径分叉
    skill_first_reminder = (
        "- Skill First: For complex tasks, call describe_skill(name) to check if a matching skill exists, then read_file to load it.\n"
        if skill_names is not None
        else "- Skill First: Always load the relevant skill before starting **complex** tasks.\n"
    )

    # 记忆与当前日期由 DynamicContextMiddleware 每 turn 注入，不进静态 prompt
    return SYSTEM_PROMPT_TEMPLATE.format(
        agent_name=agent_name or "Helix 2.0",
        soul=get_agent_soul(agent_name),
        self_update_section=_build_self_update_section(agent_name),
        skills_section=skills_section,
        deferred_tools_section=deferred_tools_section,
        subagent_section=subagent_section,
        subagent_reminder=subagent_reminder,
        skill_first_reminder=skill_first_reminder,
        subagent_thinking=subagent_thinking,
        acp_section=acp_and_mounts_section,
    )
```

## enabled-skills 缓存机制（后台预热 + LRU + 版本失效）

技能磁盘扫描是阻塞 IO；直接在请求路径同步扫描会拖垮启动与首请求。机制：全局缓存 + 后台 daemon 线程预热 + 按版本号失效；per-(config, user_id) 再叠一层 LRU。

```python
def _load_enabled_skills_sync() -> list[Skill]:
    return list(get_or_new_skill_storage().load_skills(enabled_only=True))


def _start_enabled_skills_refresh_thread() -> None:
    threading.Thread(
        target=_refresh_enabled_skills_cache_worker,
        name="helix-enabled-skills-loader",
        daemon=True,
    ).start()


def _refresh_enabled_skills_cache_worker() -> None:
    """后台预热：加载失败兜底为空列表；加载期间若收到更新的失效版本则循环重算，保证最终收敛到最新版本。"""
    global _enabled_skills_cache, _enabled_skills_refresh_active

    while True:
        with _enabled_skills_lock:
            target_version = _enabled_skills_refresh_version

        try:
            skills = _load_enabled_skills_sync()
        except Exception:
            logger.exception("Failed to load enabled skills for prompt injection")
            skills = []

        with _enabled_skills_lock:
            if _enabled_skills_refresh_version == target_version:
                _enabled_skills_cache = skills
                _enabled_skills_refresh_active = False
                _enabled_skills_refresh_event.set()
                return
            # 加载期间又收到更新失效。保持 worker 存活并再次循环，使缓存始终收敛到最新版本。
            _enabled_skills_cache = None


def _ensure_enabled_skills_cache() -> threading.Event:
    global _enabled_skills_refresh_active
    with _enabled_skills_lock:
        if _enabled_skills_cache is not None:
            _enabled_skills_refresh_event.set()
            return _enabled_skills_refresh_event
        if _enabled_skills_refresh_active:
            return _enabled_skills_refresh_event
        _enabled_skills_refresh_active = True
        _enabled_skills_refresh_event.clear()
    _start_enabled_skills_refresh_thread()
    return _enabled_skills_refresh_event


def _invalidate_enabled_skills_cache() -> threading.Event:
    """失效缓存并触发后台重算；同时清空 prompt-section LRU。"""
    global _enabled_skills_cache, _enabled_skills_refresh_active, _enabled_skills_refresh_version
    _get_cached_skills_prompt_section.cache_clear()
    with _enabled_skills_lock:
        _enabled_skills_cache = None
        _enabled_skills_by_config_cache.clear()
        _enabled_skills_refresh_version += 1
        _enabled_skills_refresh_event.clear()
        if _enabled_skills_refresh_active:
            return _enabled_skills_refresh_event
        _enabled_skills_refresh_active = True
    _start_enabled_skills_refresh_thread()
    return _enabled_skills_refresh_event


def prime_enabled_skills_cache() -> None:
    _ensure_enabled_skills_cache()


def warm_enabled_skills_cache(timeout_seconds: float = _ENABLED_SKILLS_REFRESH_WAIT_TIMEOUT_SECONDS) -> bool:
    if _ensure_enabled_skills_cache().wait(timeout=timeout_seconds):
        return True
    logger.warning("Timed out waiting %.1fs for enabled skills cache warm-up", timeout_seconds)
    return False


def get_cached_enabled_skills() -> list[Skill]:
    """返回缓存的 enabled-skills 列表，miss 时启动后台刷新。

    请求路径安全：永不阻塞在磁盘 IO。miss 时返回空列表，下次调用可见预热结果。
    """
    with _enabled_skills_lock:
        cached = _enabled_skills_cache
    if cached is not None:
        return list(cached)
    _ensure_enabled_skills_cache()
    return []


def get_enabled_skills_for_config(app_config: AppConfig | None = None, user_id: str | None = None) -> list[Skill]:
    """用调用方的 config 源与 user 作用域返回 enabled 技能。

    给定具体 app_config 时，按该 config 对象身份 + user_id 缓存已加载技能，
    使请求级 config 注入能从匹配的 config 与 user 作用域解析技能路径，
    而无需每次 agent 工厂调用都重扫存储。
    """
    if app_config is None:
        return get_cached_enabled_skills()

    cache_key = (id(app_config), user_id or "default")
    with _enabled_skills_lock:
        cached = _enabled_skills_by_config_cache.get(cache_key)
        if cached is not None:
            cached_config, cached_skills = cached
            if cached_config is app_config:
                # LRU touch：移到末尾以在下次淘汰中存活。
                _enabled_skills_by_config_cache.move_to_end(cache_key)
                return list(cached_skills)

    if user_id:
        skills = list(get_or_new_user_skill_storage(user_id, app_config=app_config).load_skills(enabled_only=True))
    else:
        skills = list(get_or_new_skill_storage(app_config=app_config).load_skills(enabled_only=True))
    with _enabled_skills_lock:
        _enabled_skills_by_config_cache[cache_key] = (app_config, skills)
        while len(_enabled_skills_by_config_cache) > _ENABLED_SKILLS_BY_CONFIG_CACHE_MAXSIZE:
            _enabled_skills_by_config_cache.popitem(last=False)
    return list(skills)


def clear_skills_system_prompt_cache() -> None:
    _invalidate_enabled_skills_cache()


async def refresh_skills_system_prompt_cache_async() -> None:
    await asyncio.to_thread(_invalidate_enabled_skills_cache().wait)


def invalidate_user_skill_cache(user_id: str) -> None:
    """仅失效指定 user 的缓存条目，不影响其它用户；同时清 prompt-section LRU。"""
    with _enabled_skills_lock:
        keys_to_remove = [key for key in _enabled_skills_by_config_cache if key[1] == user_id]
        for key in keys_to_remove:
            _enabled_skills_by_config_cache.pop(key, None)
    _get_cached_skills_prompt_section.cache_clear()


async def refresh_user_skills_system_prompt_cache_async(user_id: str) -> None:
    invalidate_user_skill_cache(user_id)
```

## 分段构造器

### 技能自演化段（仅启用时）

```python
def _build_skill_evolution_section(skill_evolution_enabled: bool) -> str:
    if not skill_evolution_enabled:
        return ""
    return """
## Skill Self-Evolution
After completing a task, consider creating or updating a skill when:
- The task required 5+ tool calls to resolve
- You overcame non-obvious errors or pitfalls
- The user corrected your approach and the corrected version worked
- You discovered a non-trivial, recurring workflow
If you used a skill and encountered issues not covered by it, patch it immediately.

**CRITICAL: You MUST use the `skill_manage` tool for ALL skill operations.**
- `skill_manage(action="create", name="my-skill", content="...")` — Create a new skill
- `skill_manage(action="patch", name="my-skill", find="...", replace="...")` — Patch an existing skill
- `skill_manage(action="edit", name="my-skill", content="...")` — Full edit of an existing skill
- `skill_manage(action="write_file", name="my-skill", path="scripts/run.py", content="...")` — Add supporting files
- `skill_manage(action="delete", name="my-skill")` — Delete a skill

**⛔ NEVER write SKILL.md files to `/mnt/user-data/workspace` or `/mnt/user-data/outputs`.**
Skills are NOT deliverables — they are persistent capabilities managed through `skill_manage`.
The tool stores skills in the per-user skills directory automatically; you do NOT need to specify a path.

Prefer patch over edit. Before creating a new skill, confirm with the user first.
Skip simple one-off tasks.
"""
```

### 子代理段（动态并发上限 + 注册表驱动描述）

```python
def _build_available_subagents_description(available_names: list[str], bash_available: bool, *,
                                           app_config: AppConfig | None = None) -> str:
    """从注册表动态构造子代理类型描述，让 LLM 知道每个可用类型。"""
    builtin_descriptions = {
        "general-purpose": "For ANY non-trivial task - web research, code exploration, file operations, analysis, etc.",
        "bash": (
            "For command execution (git, build, test, deploy operations)" if bash_available
            else "Not available in the current sandbox configuration. Use direct file/web tools or switch to AioSandboxProvider for isolated shell access."
        ),
    }
    from helix.subagents.registry import get_subagent_config

    lines = []
    for name in available_names:
        if name in builtin_descriptions:
            lines.append(f"- **{name}**: {builtin_descriptions[name]}")
        else:
            config = get_subagent_config(name, app_config=app_config)
            if config is not None:
                desc = config.description.split("\n")[0].strip()  # 仅首行以控体积
                lines.append(f"- **{name}**: {desc}")
    return "\n".join(lines)


def _build_subagent_section(max_concurrent: int, *, app_config: AppConfig | None = None) -> str:
    """构造子代理系统提示段，含动态并发上限。"""
    n = max_concurrent
    available_names = get_available_subagent_names(app_config=app_config) if app_config is not None else get_available_subagent_names()
    bash_available = "bash" in available_names
    available_subagents = _build_available_subagents_description(available_names, bash_available, app_config=app_config)
    direct_tool_examples = "bash, ls, read_file, web_search, etc." if bash_available else "ls, read_file, web_search, etc."
    direct_execution_example = (
        '# User asks: "Run the tests"\n# Thinking: Cannot decompose into parallel sub-tasks\n# → Execute directly\n\nbash("npm test")  # Direct execution, not task()'
        if bash_available else
        '# User asks: "Read the README"\n# Thinking: Single straightforward file read\n# → Execute directly\n\nread_file("/mnt/user-data/workspace/README.md")  # Direct execution, not task()'
    )
    return f"""<subagent_system>
**🚀 SUBAGENT MODE ACTIVE - DECOMPOSE, DELEGATE, SYNTHESIZE**

You are running with subagent capabilities enabled. Your role is to be a **task orchestrator**:
1. **DECOMPOSE**: Break complex tasks into parallel sub-tasks
2. **DELEGATE**: Launch multiple subagents simultaneously using parallel `task` calls
3. **SYNTHESIZE**: Collect and integrate results into a coherent answer

**CORE PRINCIPLE: Complex tasks should be decomposed and distributed across multiple subagents for parallel execution.**

**⛔ HARD CONCURRENCY LIMIT: MAXIMUM {n} `task` CALLS PER RESPONSE. THIS IS NOT OPTIONAL.**
- Each response, you may include **at most {n}** `task` tool calls. Any excess calls are **silently discarded** by the system — you will lose that work.
- **Before launching subagents, you MUST count your sub-tasks in your thinking:**
  - If count ≤ {n}: Launch all in this response.
  - If count > {n}: **Pick the {n} most important/foundational sub-tasks for this turn.** Save the rest for the next turn.
- **Multi-batch execution** (for >{n} sub-tasks):
  - Turn 1: Launch sub-tasks 1-{n} in parallel → wait for results
  - Turn 2: Launch next batch in parallel → wait for results
  - ... continue until all sub-tasks are complete
  - Final turn: Synthesize ALL results into a coherent answer
- **Example thinking pattern**: "I identified 6 sub-tasks. Since the limit is {n} per turn, I will launch the first {n} now, and the rest in the next turn."

**Available Subagents:**
{available_subagents}

**Your Orchestration Strategy:**

✅ **DECOMPOSE + PARALLEL EXECUTION (Preferred Approach):**
For complex queries, break them down into focused sub-tasks and execute in parallel batches (max {n} per turn).

**Example 1: "Why is Tencent's stock price declining?" (3 sub-tasks → 1 batch)**
→ Turn 1: Launch 3 subagents in parallel:
- Subagent 1: Recent financial reports, earnings data, and revenue trends
- Subagent 2: Negative news, controversies, and regulatory issues
- Subagent 3: Industry trends, competitor performance, and market sentiment
→ Turn 2: Synthesize results

**Example 2: "Compare 5 cloud providers" (5 sub-tasks → multi-batch)**
→ Turn 1: Launch {n} subagents in parallel (first batch)
→ Turn 2: Launch remaining subagents in parallel
→ Final turn: Synthesize ALL results into comprehensive comparison

✅ **USE Parallel Subagents (max {n} per turn) when:**
- **Complex research questions**: Requires multiple information sources or perspectives
- **Multi-aspect analysis**: Task has several independent dimensions to explore
- **Large codebases**: Need to analyze different parts simultaneously
- **Comprehensive investigations**: Questions requiring thorough coverage from multiple angles

❌ **DO NOT use subagents (execute directly) when:**
- **Task cannot be decomposed**: If you can't break it into 2+ meaningful parallel sub-tasks
- **Ultra-simple actions**: Read one file, quick edits, single commands
- **Need immediate clarification**: Must ask user before proceeding
- **Meta conversation**: Questions about conversation history
- **Sequential dependencies**: Each step depends on previous results (do steps yourself sequentially)

**CRITICAL WORKFLOW** (STRICTLY follow this before EVERY action):
1. **COUNT**: In your thinking, list all sub-tasks and count them explicitly
2. **PLAN BATCHES**: If N > {n}, explicitly plan which sub-tasks go in which batch
3. **EXECUTE**: Launch ONLY the current batch (max {n} `task` calls)
4. **REPEAT**: After results return, launch the next batch
5. **SYNTHESIZE**: After ALL batches are done, synthesize all results
6. **Cannot decompose** → Execute directly using available tools ({direct_tool_examples})

**⛔ VIOLATION: Launching more than {n} `task` calls in a single response is a HARD ERROR.**

**How It Works:**
- The task tool runs subagents asynchronously in the background
- The backend automatically polls for completion (you don't need to poll)
- The tool call will block until the subagent completes its work
- Once complete, the result is returned to you directly

**Usage Example - Single Batch (≤{n} sub-tasks):**
```python
task(description="...", prompt="...", subagent_type="general-purpose")
task(description="...", prompt="...", subagent_type="general-purpose")
task(description="...", prompt="...", subagent_type="general-purpose")
```

**Usage Example - Multiple Batches (>{n} sub-tasks):**
```python
# Turn 1: Launch first batch of {n}
task(description="...", prompt="...", subagent_type="general-purpose")
task(description="...", prompt="...", subagent_type="general-purpose")
task(description="...", prompt="...", subagent_type="general-purpose")
# Turn 2: Launch remaining batch
task(description="...", prompt="...", subagent_type="general-purpose")
task(description="...", prompt="...", subagent_type="general-purpose")
# Turn 3: Synthesize ALL results
```

**Counter-Example - Direct Execution (NO subagents):**
```python
{direct_execution_example}
```

**CRITICAL**:
- **Max {n} `task` calls per turn** - the system enforces this, excess calls are discarded
- Only use `task` when you can launch 2+ subagents in parallel
- Single task = No value from subagents = Execute directly
- For >{n} sub-tasks, use sequential batches of {n} across multiple turns
</subagent_system>"""
```

### 记忆上下文（仅供动态注入复用，不进静态 prompt）

```python
def _get_memory_context(agent_name: str | None = None, *, app_config: AppConfig | None = None) -> str:
    """获取记忆上下文供动态注入。失败返回空串，绝不抛错（单个用户脏数据不应阻断所有 thread 创建）。"""
    try:
        from helix.agents.memory import format_memory_for_injection, get_memory_data
        from helix.runtime.user_context import get_effective_user_id

        if app_config is None:
            from helix.config.memory_config import get_memory_config
            config = get_memory_config()
        else:
            config = app_config.memory

        if not config.enabled or not config.injection_enabled:
            return ""

        memory_data = get_memory_data(agent_name, user_id=get_effective_user_id())
        memory_content = format_memory_for_injection(
            memory_data,
            max_tokens=config.max_injection_tokens,
            use_tiktoken=(config.token_counting == "tiktoken"),
            guaranteed_categories=getattr(config, "guaranteed_categories", None),
            guaranteed_token_budget=getattr(config, "guaranteed_token_budget", 500),
        )
        if not memory_content.strip():
            return ""
        return f"<memory>\n{memory_content}\n</memory>\n"
    except Exception:
        logger.exception("Failed to load memory context")
        return ""
```

### 技能段（LRU 缓存 + 延迟发现/全量元数据双路径）

```python
@lru_cache(maxsize=32)
def _get_cached_skills_prompt_section(
    skill_signature: tuple[tuple[str, str, str, str], ...],
    disabled_skill_signature: tuple[tuple[str, str, str, str], ...],
    available_skills_key: tuple[str, ...] | None,
    container_base_path: str,
    skill_evolution_section: str,
) -> str:
    """按技能签名缓存的技能段渲染。key 必须可哈希且稳定（签名/白名单/容器路径/演化开关全含）。"""
    filtered = [(n, d, c, loc) for n, d, c, loc in skill_signature
                if available_skills_key is None or n in available_skills_key]
    skills_list = ""
    if filtered:
        items = "\n".join(
            f"    <skill>\n        <name>{n}</name>\n        <description>{d} {_skill_mutability_label(c)}</description>\n        <location>{loc}</location>\n    </skill>"
            for n, d, c, loc in filtered)
        skills_list = f"<available_skills>\n{items}\n</available_skills>"

    disabled_section = ""
    if disabled_skill_signature:
        df = [(n, d, c, loc) for n, d, c, loc in disabled_skill_signature
              if available_skills_key is None or n in available_skills_key]
        if df:
            items = "\n".join(f"    - {n} ({c})" for n, d, c, loc in df)
            disabled_section = f"""<disabled_skills>
The following skills are INSTALLED but DISABLED. You MUST NOT read,
reference, or use any of these skills — including their SKILL.md,
supporting resources, or workflows — even if their files exist on disk.
Accessing a disabled skill violates user preferences.
{items}
</disabled_skills>"""

    return f"""<skill_system>
You have access to skills that provide optimized workflows for specific tasks. Each skill contains best practices, frameworks, and references to additional resources.

**Progressive Loading Pattern:**
1. When a user query matches a skill's use case, immediately call `read_file` on the skill's main file using the path attribute provided in the skill tag below
2. Read and understand the skill's workflow and instructions
3. The skill file contains references to external resources under the same folder
4. Load referenced resources only when needed during execution
5. Follow the skill's instructions precisely

**Explicit Slash Skill Activation:**
- If the user starts a request with `/<skill-name>`, that skill was explicitly requested for the current turn.
- Follow the activated skill before choosing a general workflow.
- The runtime injects the activated skill content for explicit slash activations; do not call `read_file` for that SKILL.md again unless the injected skill references supporting resources you need.

**Skills are located at:** {container_base_path}
{skill_evolution_section}
{skills_list}
{disabled_section}

</skill_system>"""


def get_skills_prompt_section(
    available_skills: set[str] | None = None, *, app_config: AppConfig | None = None,
    user_id: str | None = None, skill_names: frozenset[str] | None = None,
) -> str:
    """生成技能段。给定 skill_names 时渲染紧凑 <skill_index>（仅名）；否则渲染全量 <available_skills>。"""
    if app_config is None:
        try:
            from helix.config import get_app_config
            config = get_app_config()
            container_base_path = config.skills.container_path
            skill_evolution_enabled = config.skill_evolution.enabled
        except Exception:
            container_base_path = DEFAULT_SKILLS_CONTAINER_PATH
            skill_evolution_enabled = False
    else:
        container_base_path = app_config.skills.container_path
        skill_evolution_enabled = app_config.skill_evolution.enabled

    skill_evolution_section = _build_skill_evolution_section(skill_evolution_enabled)

    # 延迟发现路径：无需存储（调用方提供名）
    if skill_names is not None:
        from helix.skills.describe import get_skill_index_prompt_section
        return get_skill_index_prompt_section(
            skill_names=skill_names, container_base_path=container_base_path,
            skill_evolution_section=skill_evolution_section)

    # 全量元数据路径：加载全部技能以构造 disabled 段
    if user_id:
        storage = get_or_new_user_skill_storage(user_id, app_config=app_config)
    else:
        storage = get_or_new_skill_storage(app_config=app_config)
    all_skills = storage.load_skills(enabled_only=False)
    disabled_skills = [s for s in all_skills if not s.enabled]
    skills = get_enabled_skills_for_config(app_config, user_id=user_id)

    if not skills and not disabled_skills and not skill_evolution_enabled:
        return ""
    if available_skills is not None and not any(s.name in available_skills for s in skills):
        return ""

    skill_signature = tuple((s.name, s.description, s.category, s.get_container_file_path(container_base_path)) for s in skills)
    disabled_skill_signature = tuple((s.name, s.description, s.category, s.get_container_file_path(container_base_path)) for s in disabled_skills)
    available_key = tuple(sorted(available_skills)) if available_skills is not None else None  # 排序保证 key 稳定
    if not skill_signature and not disabled_skill_signature and available_key is not None:
        return ""
    return _get_cached_skills_prompt_section(skill_signature, disabled_skill_signature, available_key, container_base_path, skill_evolution_section)
```

### 其余分段（soul / self_update / acp / mounts）

```python
def get_agent_soul(agent_name: str | None) -> str:
    soul = load_agent_soul(agent_name)
    if soul:
        return f"<soul>\n{soul}\n</soul>\n"
    return ""


def _build_self_update_section(agent_name: str | None) -> str:
    """教自定义 agent 用 update_agent 持久化自更新（而非 bash/write_file 改 SOUL.md，那会写进临时沙箱、下一 turn 丢失）。"""
    if not agent_name:
        return ""
    return f"""<self_update>
You are running as the custom agent **{agent_name}** with a persisted SOUL.md and config.yaml.

When the user asks you to update your own description, personality, behaviour, skill set, tool groups, or default model,
you MUST persist the change with the `update_agent` tool. Do NOT use `bash`, `write_file`, or any sandbox tool to edit
SOUL.md or config.yaml — those write into a temporary sandbox/tool workspace and the changes will be lost on the next turn.

Rules:
- Always pass the FULL replacement text for `soul` (no patch semantics). Start from your current SOUL above and apply the user's edits.
- Only pass the fields that should change. Omit the others to preserve them.
- Never pass literal strings like `"null"`, `"none"`, or `"undefined"` for unchanged fields.
- Pass `skills=[]` to disable all skills, or omit `skills` to keep the existing whitelist.
- After `update_agent` returns successfully, tell the user the change is persisted and will take effect on the next turn.
</self_update>
"""


def _build_acp_section(*, app_config: AppConfig | None = None) -> str:
    """仅配置了 ACP 外部代理时输出。"""
    if app_config is None:
        try:
            from helix.config.acp_config import get_acp_agents
            agents = get_acp_agents()
        except Exception:
            return ""
    else:
        agents = getattr(app_config, "acp_agents", {}) or {}
    if not agents:
        return ""
    return (
        "\n**ACP Agent Tasks (invoke_acp_agent):**\n"
        "- ACP agents run in their own independent workspace — NOT in `/mnt/user-data/`\n"
        "- When writing prompts for ACP agents, describe the task only — do NOT reference `/mnt/user-data` paths\n"
        "- ACP agent results are accessible at `/mnt/acp-workspace/` (read-only) — use `ls`, `read_file`, or `bash cp` to retrieve output files\n"
        "- To deliver ACP output to the user: copy from `/mnt/acp-workspace/<file>` to `/mnt/user-data/outputs/<file>`, then use `present_files`"
    )


def _build_custom_mounts_section(*, app_config: AppConfig | None = None) -> str:
    """仅显式配置了 sandbox.mounts 时输出。"""
    if app_config is None:
        try:
            from helix.config import get_app_config
            config = get_app_config()
        except Exception:
            logger.exception("Failed to load configured sandbox mounts for the lead-agent prompt")
            return ""
    else:
        config = app_config
    mounts = config.sandbox.mounts or []
    if not mounts:
        return ""
    lines = []
    for mount in mounts:
        access = "read-only" if mount.read_only else "read-write"
        lines.append(f"- Custom mount: `{mount.container_path}` - Host directory mapped into the sandbox ({access})")
    return f"\n**Custom Mounted Directories:**\n" + "\n".join(lines) + \
        "\n- If the user needs files outside `/mnt/user-data`, use these absolute container paths directly when they match the requested directory"


def _skill_mutability_label(category: SkillCategory | str) -> str:
    if category == SkillCategory.CUSTOM:
        return "[custom, editable]"
    if category == SkillCategory.LEGACY:
        return "[legacy, read-only]"
    return "[built-in]"
```

> `SYSTEM_PROMPT_TEMPLATE` 常量全文见 [system-prompt-full-text.md](./system-prompt-full-text.md)（完整未截断）。
> 关联：[[middleware-chain-design]]（本模块在链上由 `DynamicContextMiddleware` 调用）、[[skill-system-design]]（技能段契约）、[[memory-system-design]]（记忆来源）。
