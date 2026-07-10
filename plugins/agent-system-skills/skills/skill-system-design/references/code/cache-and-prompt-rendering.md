# Cache & Prompt Rendering - 完整源码

> 本文件是 `skill-system-design` 的**缓存 + skills_section 渲染 + ④建图装配入口**完整源码：`prompt.py` 的 enabled-skills 缓存（启动预热 + 写后失效 + per-`(config,user)` LRU）+ `get_skills_prompt_section`（全量 `<available_skills>` / 延迟 `<skill_index>` 分叉）+ 技能自演化文案构造器 + `prime`/`warm` 预热入口 + `_make_lead_agent` 装配串联。SKILL.md 只放设计架构思路与伪代码，完整源码以此文件为准。代码已按插件匿名化规则映射到自定结构；真实代码原注释保留以保真。

## 1. 异步加载缓存 + skills_section 渲染（prompt.py 技能相关段）

```python
# core/helix/agents/lead/prompt.py（技能相关段；完整模块见 [[system-prompt-template]]）
from __future__ import annotations

import asyncio
import logging
import threading
from collections import OrderedDict
from functools import lru_cache

from helix.constants import DEFAULT_SKILLS_CONTAINER_PATH
from helix.skills.storage import get_or_new_skill_storage, get_or_new_user_skill_storage
from helix.skills.types import Skill, SkillCategory

logger = logging.getLogger(__name__)

# 每 (app_config, user_id) 的 enabled-skills 缓存 LRU 上限。
# 没有它，长跑多用户进程每见过一个 (config, user) 就泄漏一项，只受进程见过的身份数约束。
_ENABLED_SKILLS_BY_CONFIG_CACHE_MAXSIZE = 256
_ENABLED_SKILLS_REFRESH_WAIT_TIMEOUT_SECONDS = 5.0
_enabled_skills_lock = threading.Lock()
_enabled_skills_cache: list[Skill] | None = None  # 全局默认缓存（无 app_config 时）
_enabled_skills_by_config_cache: "OrderedDict[tuple[int, str], tuple[object, list[Skill]]]" = OrderedDict()
_enabled_skills_refresh_active = False
_enabled_skills_refresh_version = 0  # 版本号：失效 +1，后台线程据此判断是否需重跑
_enabled_skills_refresh_event = threading.Event()


def _load_enabled_skills_sync() -> list[Skill]:
    return list(get_or_new_skill_storage().load_skills(enabled_only=True))


def _refresh_enabled_skills_cache_worker() -> None:
    """后台 daemon 线程：加载 enabled skills，版本号未变则写入缓存。"""
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
            # 失效期间又有新 invalidation：清空缓存，继续循环收敛到最新版本
            _enabled_skills_cache = None


def _ensure_enabled_skills_cache() -> threading.Event:
    """miss 时起后台线程预热，返回 Event 供调用方可选 wait。"""
    global _enabled_skills_refresh_active

    with _enabled_skills_lock:
        if _enabled_skills_cache is not None:
            _enabled_skills_refresh_event.set()
            return _enabled_skills_refresh_event
        if _enabled_skills_refresh_active:
            return _enabled_skills_refresh_event
        _enabled_skills_refresh_active = True
        _enabled_skills_refresh_event.clear()

    threading.Thread(target=_refresh_enabled_skills_cache_worker, name="helix-enabled-skills-loader", daemon=True).start()
    return _enabled_skills_refresh_event


def _invalidate_enabled_skills_cache() -> threading.Event:
    """全局失效：清缓存 + 清 prompt 段 LRU + 版本号 +1 + 起后台重载。"""
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

    _ensure_enabled_skills_cache()
    return _enabled_skills_refresh_event


def warm_enabled_skills_cache(timeout_seconds: float = _ENABLED_SKILLS_REFRESH_WAIT_TIMEOUT_SECONDS) -> bool:
    """启动时预热：阻塞等后台线程完成（最多 timeout）。"""
    if _ensure_enabled_skills_cache().wait(timeout=timeout_seconds):
        return True
    logger.warning("Timed out waiting %.1fs for enabled skills cache warm-up", timeout_seconds)
    return False


def get_cached_enabled_skills() -> list[Skill]:
    """返回缓存列表，miss 时不阻塞（返回 []），后台预热好后下次命中。"""
    with _enabled_skills_lock:
        cached = _enabled_skills_cache
    if cached is not None:
        return list(cached)
    _ensure_enabled_skills_cache()
    return []


def get_enabled_skills_for_config(app_config: AppConfig | None = None, user_id: str | None = None) -> list[Skill]:
    """按调用方的 config + user scope 返回 enabled 技能。

    有 app_config 时按 (id(app_config), user_id) 缓存，LRU 256，避免每次建图都扫盘。
    有 user_id 时走 per-user 存储（public + 用户 custom），否则走全局存储。
    """
    if app_config is None:
        return get_cached_enabled_skills()

    cache_key = (id(app_config), user_id or "default")
    with _enabled_skills_lock:
        cached = _enabled_skills_by_config_cache.get(cache_key)
        if cached is not None:
            cached_config, cached_skills = cached
            if cached_config is app_config:
                _enabled_skills_by_config_cache.move_to_end(cache_key)  # LRU touch
                return list(cached_skills)

    if user_id:
        skills = list(get_or_new_user_skill_storage(user_id, app_config=app_config).load_skills(enabled_only=True))
    else:
        skills = list(get_or_new_skill_storage(app_config=app_config).load_skills(enabled_only=True))
    with _enabled_skills_lock:
        _enabled_skills_by_config_cache[cache_key] = (app_config, skills)
        while len(_enabled_skills_by_config_cache) > _ENABLED_SKILLS_BY_CONFIG_CACHE_MAXSIZE:
            _enabled_skills_by_config_cache.popitem(last=False)  # 驱逐最久未用
    return list(skills)


def clear_skills_system_prompt_cache() -> None:
    """全局失效入口（安装/卸载/全局开关调用）。"""
    _invalidate_enabled_skills_cache()


async def refresh_skills_system_prompt_cache_async() -> None:
    await asyncio.to_thread(_invalidate_enabled_skills_cache().wait)


def invalidate_user_skill_cache(user_id: str) -> None:
    """仅失效某用户的缓存（skill_manage 写后调用），不影响其他用户。"""
    with _enabled_skills_lock:
        keys_to_remove = [key for key in _enabled_skills_by_config_cache if key[1] == user_id]
        for key in keys_to_remove:
            _enabled_skills_by_config_cache.pop(key, None)
    _get_cached_skills_prompt_section.cache_clear()  # 清 prompt 段 LRU，防返回旧签名


async def refresh_user_skills_system_prompt_cache_async(user_id: str) -> None:
    """per-user 失效入口（skill_manage 写后调用）。"""
    invalidate_user_skill_cache(user_id)


@lru_cache(maxsize=32)
def _get_cached_skills_prompt_section(
    skill_signature: tuple[tuple[str, str, str, str], ...],
    disabled_skill_signature: tuple[tuple[str, str, str, str], ...],
    available_skills_key: tuple[str, ...] | None,
    container_base_path: str,
    skill_evolution_section: str,
) -> str:
    """按技能签名缓存渲染后的 <skill_system> XML。签名不变就不重渲染。"""
    filtered = [(name, description, category, location) for name, description, category, location in skill_signature if available_skills_key is None or name in available_skills_key]
    skills_list = ""
    if filtered:
        skill_items = "\n".join(
            f"    <skill>\n        <name>{name}</name>\n        <description>{description} {_skill_mutability_label(category)}</description>\n        <location>{location}</location>\n    </skill>"
            for name, description, category, location in filtered
        )
        skills_list = f"<available_skills>\n{skill_items}\n</available_skills>"

    disabled_section = ""
    if disabled_skill_signature:
        disabled_filtered = [(name, description, category, location) for name, description, category, location in disabled_skill_signature if available_skills_key is None or name in available_skills_key]
        if disabled_filtered:
            disabled_items = "\n".join(f"    - {name} ({category})" for name, description, category, location in disabled_filtered)
            disabled_section = f"""<disabled_skills>
The following skills are INSTALLED but DISABLED. You MUST NOT read,
reference, or use any of these skills - including their SKILL.md,
supporting resources, or workflows - even if their files exist on disk.
Accessing a disabled skill violates user preferences.
{disabled_items}
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
    available_skills: set[str] | None = None,
    *,
    app_config: AppConfig | None = None,
    user_id: str | None = None,
    skill_names: frozenset[str] | None = None,
) -> str:
    """生成 skills prompt 段。

    有 skill_names 时渲染紧凑 <skill_index>（延迟发现，模型用 describe_skill 取元数据）。
    无 skill_names 时回退全量元数据 <available_skills>（含 <disabled_skills> 禁用清单）。
    """
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

    # ── 延迟发现路径：不需要读存储（调用方已给名字）──
    if skill_names is not None:
        from helix.skills.describe import get_skill_index_prompt_section
        return get_skill_index_prompt_section(
            skill_names=skill_names,
            container_base_path=container_base_path,
            skill_evolution_section=skill_evolution_section,
        )

    # ── 全量元数据路径：需读全部技能（含 disabled）以渲染禁用清单 ──
    if user_id:
        storage = get_or_new_user_skill_storage(user_id, app_config=app_config)
    else:
        storage = get_or_new_skill_storage(app_config=app_config)
    all_skills = storage.load_skills(enabled_only=False)
    disabled_skills = [s for s in all_skills if not s.enabled]

    skills = get_enabled_skills_for_config(app_config, user_id=user_id)

    if not skills and not disabled_skills and not skill_evolution_enabled:
        return ""
    if available_skills is not None and not any(skill.name in available_skills for skill in skills):
        return ""

    skill_signature = tuple((skill.name, skill.description, skill.category, skill.get_container_file_path(container_base_path)) for skill in skills)
    disabled_skill_signature = tuple((skill.name, skill.description, skill.category, skill.get_container_file_path(container_base_path)) for skill in disabled_skills)
    available_key = tuple(sorted(available_skills)) if available_skills is not None else None
    if not skill_signature and not disabled_skill_signature and available_key is not None:
        return ""
    return _get_cached_skills_prompt_section(skill_signature, disabled_skill_signature, available_key, container_base_path, skill_evolution_section)
```

## 2. 技能自演化文案 + 可编辑性标签（prompt.py 补全）

```python
# core/helix/agents/lead/prompt.py（_build_skill_evolution_section + _skill_mutability_label）


def _skill_mutability_label(category: SkillCategory | str) -> str:
    """技能可编辑性标签，渲染进 <available_skills> 的 description 后。"""
    if category == SkillCategory.CUSTOM:
        return "[custom, editable]"
    if category == SkillCategory.LEGACY:
        return "[legacy, read-only]"
    return "[built-in]"


def _build_skill_evolution_section(skill_evolution_enabled: bool) -> str:
    """技能自演化 prompt 段。仅在 skill_evolution.enabled 时输出。"""
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
- `skill_manage(action="create", name="my-skill", content="...")` - Create a new skill
- `skill_manage(action="patch", name="my-skill", find="...", replace="...")` - Patch an existing skill
- `skill_manage(action="edit", name="my-skill", content="...")` - Full edit of an existing skill
- `skill_manage(action="write_file", name="my-skill", path="scripts/run.py", content="...")` - Add supporting files
- `skill_manage(action="delete", name="my-skill")` - Delete a skill

**⛔ NEVER write SKILL.md files to `/mnt/user-data/workspace` or `/mnt/user-data/outputs`.**
Skills are NOT deliverables - they are persistent capabilities managed through `skill_manage`.
The tool stores skills in the per-user skills directory automatically; you do NOT need to specify a path.

Prefer patch over edit. Before creating a new skill, confirm with the user first.
Skip simple one-off tasks.
"""
```

## 3. 启动预热入口（prompt.py 补全）

```python
# core/helix/agents/lead/prompt.py（prime_enabled_skills_cache + _start_enabled_skills_refresh_thread）


def _start_enabled_skills_refresh_thread() -> None:
    threading.Thread(
        target=_refresh_enabled_skills_cache_worker,
        name="helix-enabled-skills-loader",
        daemon=True,
    ).start()


def prime_enabled_skills_cache() -> None:
    """启动时触发后台预热线程（非阻塞）。"""
    _ensure_enabled_skills_cache()
```

应用启动时调 `prime_enabled_skills_cache()` 触发后台预热；可选 `warm_enabled_skills_cache(timeout=5.0)` 阻塞等预热完成（用于启动钩子，确保第一批请求即命中缓存）。

## 4. ④建图装配串联（工具白名单 + describe_skill + skills_section）

```python
# core/helix/agents/lead/agent.py（_make_lead_agent 技能相关段）
from helix.skills.tool_policy import SKILL_LOADING_TOOL_NAMES, filter_tools_by_skill_allowed_tools
from helix.skills.types import Skill


def _load_enabled_skills_for_tool_policy(available_skills: set[str] | None, *, app_config: AppConfig, user_id: str | None = None) -> list[Skill]:
    """加载 enabled 技能并按 agent 白名单过滤（供工具策略 + describe_skill 复用同一列表）。"""
    from helix.agents.lead_agent.prompt import get_enabled_skills_for_config
    skills = get_enabled_skills_for_config(app_config, user_id=user_id)
    if available_skills is None:
        return skills
    return [skill for skill in skills if skill.name in available_skills]


def _make_lead_agent(config: RunnableConfig, *, app_config: AppConfig):
    # ... 解析 user_id、model_name、non_interactive 等 ...
    resolved_user_id = str(runtime_user_id) if runtime_user_id else get_effective_user_id()

    # 1) 加载 enabled 技能（命中缓存或后台预热）
    skills_for_tool_policy = _load_enabled_skills_for_tool_policy(available_skills, app_config=resolved_app_config, user_id=resolved_user_id)

    # 2) 构建延迟发现装配（describe_skill 工具 + skill_names），由 skills.deferred_discovery 开关
    from helix.skills.describe import build_skill_search_setup
    skill_search_enabled = resolved_app_config.skills.deferred_discovery
    container_base_path = resolved_app_config.skills.container_path
    skill_setup = build_skill_search_setup(skills_for_tool_policy, enabled=skill_search_enabled, container_base_path=container_base_path)

    # 3) 工具白名单收窄：always_allowed 含 read_file（技能加载自身全文需要）
    raw_tools = get_available_tools(model_name=model_name, groups=agent_config.tool_groups if agent_config else None, subagent_enabled=subagent_enabled, app_config=resolved_app_config)
    filtered = filter_tools_by_skill_allowed_tools(raw_tools + extra_tools, skills_for_tool_policy, always_allowed_tool_names=SKILL_LOADING_TOOL_NAMES)
    if non_interactive:
        filtered = [tool for tool in filtered if tool.name not in _NON_INTERACTIVE_DISABLED_TOOL_NAMES]  # 无人值守剥离 ask_clarification（见 [[system-prompt-template]]）
    final_tools, setup = assemble_deferred_tools(filtered, enabled=resolved_app_config.tool_search.enabled)
    if skill_setup.describe_skill_tool:
        final_tools.append(skill_setup.describe_skill_tool)  # describe_skill 加入工具集

    return create_agent(
        model=create_chat_model(name=model_name, thinking_enabled=thinking_enabled, reasoning_effort=reasoning_effort, app_config=resolved_app_config, attach_tracing=False),
        tools=final_tools,
        middleware=build_middlewares(config, model_name=model_name, agent_name=agent_name, available_skills=available_skills, app_config=resolved_app_config, deferred_setup=setup, user_id=resolved_user_id),
        system_prompt=apply_prompt_template(
            subagent_enabled=subagent_enabled, max_concurrent_subagents=max_concurrent_subagents, agent_name=agent_name,
            available_skills=available_skills, app_config=resolved_app_config, deferred_names=setup.deferred_names,
            user_id=resolved_user_id, skill_names=skill_setup.skill_names or None,  # None=全量段；frozenset=延迟段
        ),
        state_schema=ThreadState)
```

## 关联

- SKILL.md：[../SKILL.md](../SKILL.md)
- 协议 + 存储 + per-user 完整源码：[./skill-protocol-and-storage.md](./skill-protocol-and-storage.md)
- 发现 + 工具策略 + skill_manage 完整源码：[./discover-and-manage.md](./discover-and-manage.md)
- slash 激活 + secret 绑定完整源码：[./activation-and-whitelist.md](./activation-and-whitelist.md)
- 关联 skill：[[system-prompt-template]]（缓存紧邻渲染入口 + skills_section 槽位）、[[tool-assembly-and-policy]]（白名单 + describe_skill 接入装配链）、[[e2e-request-lifecycle]]（④建图位置）
