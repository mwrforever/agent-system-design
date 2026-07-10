# Discover & Manage - 完整源码

> 本文件是 `skill-system-design` 的**发现 + 工具策略 + 管理层**完整源码：`SkillCatalog`（不可变可搜索目录）+ `tool_policy.py`（allowed-tools 非对称白名单收窄）+ `describe.py`（describe_skill 工具 + 延迟发现 `<skill_index>`）+ `skill_manage_tool.py`（自演化 6 动作）+ 安装管线要点。SKILL.md 只放设计架构思路与伪代码，完整源码以此文件为准。代码已按插件匿名化规则映射到自定结构；真实代码原注释保留以保真。

## 1. SkillCatalog（不可变可搜索目录）

```python
# core/helix/skills/catalog.py
"""技能目录 - 运行时延迟技能发现。

镜像 tool_search.py 的 DeferredToolCatalog：不可变、可搜索的目录，让 LLM 按需发现技能元数据，
而非把每个技能的完整描述烤进 system prompt。

agent 在 <skill_index> 看到技能名，但不能读其元数据，除非调 describe_skill。
这保持 system prompt 紧凑且 prefix-cache 友好，同时仍给模型自主技能发现能力。
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from functools import cached_property

from helix.skills.types import Skill

logger = logging.getLogger(__name__)

MAX_RESULTS = 5


def _compile_catalog_regex(pattern: str) -> re.Pattern[str]:
    """大小写不敏感编译 pattern，失败回退字面匹配。

    搜索查询来自模型，故非法 regex（如不平衡括号）必须降级为字面子串匹配而非抛。
    """
    try:
        return re.compile(pattern, re.IGNORECASE)
    except re.error:
        return re.compile(re.escape(pattern), re.IGNORECASE)


# NOTE: frozen=True 不加 slots=True 保留 __dict__，使下方 @cached_property 字段能缓存
# （它们写 instance.__dict__，绕过 frozen 的 __setattr__）。勿加 slots=True，否则 hash/names 运行时坏。
@dataclass(frozen=True)
class SkillCatalog:
    """不可变技能目录。纯搜索，无变更。

    查询形式（镜像 DeferredToolCatalog.search）：

    - "select:data-analysis,deep-research" - 按名精确匹配。
    - "+podcast gen" - 要求 name 含 *podcast*，按 *gen* 排序。
    - "chart visualization" - 对 name + description 做 regex 匹配。
    """

    skills: tuple[Skill, ...]

    @cached_property
    def names(self) -> frozenset[str]:
        """所有技能名（插入序）。"""
        return frozenset(s.name for s in self.skills)

    def search(self, query: str) -> list[Skill]:
        """把 query 匹配技能名与描述。返回最多 MAX_RESULTS 个，按相关性排序。"""
        query = query.strip()
        if not query:
            return []

        # ── 精确选择 ────────────────────────────────────────────
        if query.startswith("select:"):
            wanted = {n.strip() for n in query[7:].split(",")}
            return [s for s in self.skills if s.name in wanted]

        # ── 必含前缀搜索 ─────────────────────────────────────────
        if query.startswith("+"):
            parts = query[1:].split(None, 1)
            if not parts:
                return []  # 裸 "+" 无必含 token
            required = parts[0].lower()
            candidates = [s for s in self.skills if required in s.name.lower()]
            if len(parts) > 1:
                pattern = _compile_catalog_regex(parts[1])
                candidates.sort(
                    key=lambda s: _catalog_regex_score(pattern, s),
                    reverse=True,
                )
            return candidates[:MAX_RESULTS]

        # ── 自由文本 regex 搜索 ─────────────────────────────────
        regex = _compile_catalog_regex(query)
        scored: list[tuple[int, Skill]] = []
        for s in self.skills:
            searchable = f"{s.name} {s.description or ''}"
            if regex.search(searchable):
                # 名匹配比仅描述匹配分高
                scored.append((2 if regex.search(s.name) else 1, s))
        scored.sort(key=lambda x: x[0], reverse=True)
        return [s for _, s in scored][:MAX_RESULTS]


def _catalog_regex_score(pattern: re.Pattern[str], s: Skill) -> int:
    """数 name + description 上的 regex 命中数用于排序。"""
    return len(pattern.findall(f"{s.name} {s.description or ''}"))
```

## 2. allowed-tools 白名单收窄（非对称语义）

```python
# core/helix/skills/tool_policy.py
import logging
from typing import Protocol

from helix.skills.types import Skill

logger = logging.getLogger(__name__)


class NamedTool(Protocol):
    name: str


# 技能加载自身全文需要的工具，白名单收窄时始终保留
SKILL_LOADING_TOOL_NAMES = frozenset({"read_file"})


def allowed_tool_names_for_skills(skills: list[Skill]) -> set[str] | None:
    """返回所有技能 declared allowed-tools 的并集。

    None = legacy 全量模式（无任何技能声明时返回）。
    一旦任一技能声明该字段，未声明的技能贡献空集而非全量--这是让 allowed-tools: [] 有意义的关键。
    """
    if not skills:
        return None

    allowed: set[str] = set()
    has_explicit_declaration = False
    for skill in skills:
        if skill.allowed_tools is None:
            continue
        has_explicit_declaration = True
        if not skill.allowed_tools:
            logger.info("Skill %s declared empty allowed-tools", skill.name)
        allowed.update(skill.allowed_tools)

    if not has_explicit_declaration:
        return None
    return allowed


def filter_tools_by_skill_allowed_tools[ToolT: NamedTool](
    tools: list[ToolT],
    skills: list[Skill],
    *,
    always_allowed_tool_names: set[str] | frozenset[str] = frozenset(),
) -> list[ToolT]:
    """用技能白名单收窄工具集。allowed=None 时不收窄（legacy 兼容）。"""
    allowed = allowed_tool_names_for_skills(skills)
    if allowed is None:
        return tools

    allowed_with_framework_tools = allowed | set(always_allowed_tool_names)
    return [tool for tool in tools if tool.name in allowed_with_framework_tools]
```

## 3. describe_skill 工具 + 延迟发现索引

```python
# core/helix/skills/describe.py
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import TYPE_CHECKING, Annotated

from langchain_core.messages import ToolMessage
from langchain_core.tools import InjectedToolCallId, tool
from langgraph.types import Command

if TYPE_CHECKING:
    from langchain.tools import BaseTool

from helix.constants import DEFAULT_SKILLS_CONTAINER_PATH
from helix.skills.catalog import SkillCatalog
from helix.skills.types import SkillCategory

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class SkillSearchSetup:
    """一次 agent 建图的技能发现装配结果。

    - Empty (None, frozenset())：无技能或延迟发现关闭，回退全量元数据 prompt 段。
    - Populated：describe_skill 工具加入工具集，skill_names 渲染进 <skill_index>。
    """
    describe_skill_tool: BaseTool | None
    skill_names: frozenset[str]


def build_describe_skill_tool(
    catalog: SkillCatalog,
    *,
    container_base_path: str = DEFAULT_SKILLS_CONTAINER_PATH,
) -> BaseTool:
    """把 describe_skill 构造为 catalog 上的闭包工具。无状态变更（不像 tool_search 会提升延迟工具）。"""

    @tool
    def describe_skill(
        name: str,
        tool_call_id: Annotated[str, InjectedToolCallId],
    ) -> Command:
        """Fetch usage metadata for installed skills so you can decide whether to load them.

        Skills appear by name in <skill_index> in the system prompt.  Until
        fetched, only the name is known.  This tool matches a query against
        installed skills and returns their full metadata - description, allowed
        tools, and file location - so you can decide whether to load the
        SKILL.md via read_file.

        Query forms:
          - "select:data-analysis,deep-research" -- fetch these exact skills (no cap)
          - "chart visualization" -- keyword search, best matches (up to 5)
          - "+podcast gen" -- require "podcast" in the name, rank by remaining terms (up to 5)
        """
        matched = catalog.search(name)
        if not matched:
            content = f"No skills matched: {name}"
        else:
            content = _render_skill_metadata(matched, container_base_path)

        return Command(
            update={
                "messages": [
                    ToolMessage(
                        content=content,
                        tool_call_id=tool_call_id,
                        name="describe_skill",
                    )
                ],
            }
        )

    return describe_skill


def build_skill_search_setup(
    skills: list,
    *,
    enabled: bool,
    container_base_path: str = DEFAULT_SKILLS_CONTAINER_PATH,
) -> SkillSearchSetup:
    """从过滤后的技能列表构建延迟发现装配。enabled=False 或无技能时返回空 setup。"""
    if not enabled or not skills:
        return SkillSearchSetup(None, frozenset())

    catalog = SkillCatalog(tuple(skills))
    return SkillSearchSetup(
        describe_skill_tool=build_describe_skill_tool(catalog, container_base_path=container_base_path),
        skill_names=catalog.names,
    )


def _render_skill_metadata(skills: list, container_base_path: str) -> str:
    """渲染技能元数据块（description + 可编辑性 + 允许工具 + 文件位置）。"""
    blocks: list[str] = []
    for s in skills:
        mutability = "[custom, editable]" if s.category == SkillCategory.CUSTOM else "[built-in]"
        tools_line = ", ".join(s.allowed_tools) if s.allowed_tools else "(all)"
        location = s.get_container_file_path(container_base_path)
        blocks.append(f"## Skill: {s.name}\n- Description: {s.description} {mutability}\n- Allowed tools: {tools_line}\n- Location: {location}")
    return "\n\n".join(blocks)


def get_skill_index_prompt_section(
    *,
    skill_names: frozenset[str] = frozenset(),
    container_base_path: str = DEFAULT_SKILLS_CONTAINER_PATH,
    skill_evolution_section: str = "",
) -> str:
    """生成 <skill_system>，含仅名字的 <skill_index>（延迟发现路径）。无技能时返回空串。"""
    if not skill_names:
        return ""

    names = ", ".join(sorted(skill_names))
    evolution = f"\n{skill_evolution_section}" if skill_evolution_section else ""

    return f"""<skill_system>
You have access to skills that provide optimized workflows for specific tasks.

**Skill Discovery:**
1. Check <skill_index> for a skill name that matches your task
2. Call describe_skill(name) to fetch its description and capabilities
3. If the skill matches, call read_file on the returned location to load full instructions
4. Follow the skill's instructions precisely

**Explicit Slash Skill Activation:**
- If the user starts a request with `/<skill-name>`, that skill was explicitly requested.
- The runtime injects the activated skill content; do not call `read_file` for that SKILL.md again unless the injected skill references supporting resources you need.
{evolution}
<skill_index>
{names}
</skill_index>

Skills are located at: {container_base_path}
</skill_system>"""
```

## 4. skill_manage 工具（完整 6 动作 + 全部助手）

```python
# core/helix/tools/skill_manage_tool.py
"""创建与演化自定义技能的工具。"""

from __future__ import annotations

import asyncio
import json
import logging
import shutil
import tempfile
from pathlib import Path
from typing import Any, NoReturn
from weakref import WeakValueDictionary

from langchain.tools import tool

from helix.agents.lead_agent.prompt import refresh_user_skills_system_prompt_cache_async
from helix.runtime.user_context import resolve_runtime_user_id
from helix.skills.security_scanner import scan_skill_content
from helix.skills.security_static_scanner import (
    StaticFinding,
    StaticScanBlockedError,
    StaticScannerError,
    enforce_static_scan,
)
from helix.skills.storage import get_or_new_user_skill_storage
from helix.skills.storage.skill_storage import SkillStorage
from helix.skills.types import SKILL_MD_FILE
from helix.tools.sync import make_sync_tool_wrapper
from helix.tools.types import Runtime

logger = logging.getLogger(__name__)

# 锁粒度：(user_id, skill_name)，防跨用户阻塞
_skill_locks: WeakValueDictionary[tuple[str, str], asyncio.Lock] = WeakValueDictionary()


def _get_lock(user_id: str, name: str) -> asyncio.Lock:
    key = (user_id, name)
    lock = _skill_locks.get(key)
    if lock is None:
        lock = asyncio.Lock()
        _skill_locks[key] = lock
    return lock


def _get_thread_id(runtime: Runtime | None) -> str | None:
    """从 runtime.context 或 runtime.config 取 thread_id（写 history 用）。"""
    if runtime is None:
        return None
    if runtime.context and runtime.context.get("thread_id"):
        return runtime.context.get("thread_id")
    return runtime.config.get("configurable", {}).get("thread_id")


def _history_record(*, action: str, file_path: str, prev_content: str | None, new_content: str | None, thread_id: str | None, scanner: dict[str, Any]) -> dict[str, Any]:
    """构造一条 JSONL history 记录（append-only 审计轨迹）。"""
    return {
        "action": action,
        "author": "agent",
        "thread_id": thread_id,
        "file_path": file_path,
        "prev_content": prev_content,
        "new_content": new_content,
        "scanner": scanner,
    }


async def _scan_or_raise(content: str, *, executable: bool, location: str, static_findings: list[StaticFinding] | None = None) -> dict[str, Any]:
    """双层安全扫描：静态 + LLM。block 即拒绝；executable 要求 allow（warn 不够）。"""
    result = await scan_skill_content(content, executable=executable, location=location, static_findings=static_findings or [])
    if result.decision == "block":
        raise ValueError(f"Security scan blocked the write: {result.reason}")
    if executable and result.decision != "allow":
        raise ValueError(f"Security scan rejected executable content: {result.reason}")
    return {"decision": result.decision, "reason": result.reason}


def _raise_static_block(error: StaticScanBlockedError) -> NoReturn:
    payload = {
        "skill_name": error.skill_name,
        "findings": error.findings,
    }
    raise ValueError(f"{error} Findings: {json.dumps(payload, ensure_ascii=False)}") from error


def _raise_static_scan_failure(name: str, error: StaticScannerError) -> NoReturn:
    raise ValueError(f"Static security scan failed for skill '{name}': {error}") from error


async def _scan_static_candidate_or_raise(name: str, updates: dict[str, str], skill_storage: SkillStorage | None = None) -> list[StaticFinding]:
    """在临时副本上跑静态扫描（写前预检）。

    把现有技能目录复制到临时目录（若有 skill_storage），写入待测 updates，再 enforce_static_scan。
    这样不污染真实技能目录即可检测组合后的静态风险。
    """
    def _scan_candidate() -> list[StaticFinding]:
        with tempfile.TemporaryDirectory() as tmp:
            skill_dir = Path(tmp) / name
            if skill_storage is None:
                skill_dir.mkdir(parents=True)
            else:
                shutil.copytree(skill_storage.get_custom_skill_dir(name), skill_dir)
            for relative_path, content in updates.items():
                target = skill_dir / relative_path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content, encoding="utf-8")
            return enforce_static_scan(skill_dir, skill_name=name)

    try:
        return await asyncio.to_thread(_scan_candidate)
    except StaticScanBlockedError as e:
        _raise_static_block(e)
    except StaticScannerError as e:
        _raise_static_scan_failure(name, e)


async def _to_thread(func, /, *args, **kwargs):
    return await asyncio.to_thread(func, *args, **kwargs)


async def _skill_manage_impl(
    runtime: Runtime,
    action: str,
    name: str,
    content: str | None = None,
    path: str | None = None,
    find: str | None = None,
    replace: str | None = None,
    expected_count: int | None = None,
) -> str:
    """管理 skills/custom/ 下的自定义技能。

    Args:
        action: create / patch / edit / delete / write_file / remove_file 之一。
        name: 技能名（hyphen-case）。
        content: create/edit/write_file 的新文件内容。
        path: write_file/remove_file 的支撑文件路径。
        find/replace: patch 的查找/替换文本。
        expected_count: patch 期望的替换次数（可选，防误替换）。
    """
    name = SkillStorage.validate_skill_name(name)
    user_id = resolve_runtime_user_id(runtime)  # per-user 隔离的 user_id
    lock = _get_lock(user_id, name)
    thread_id = _get_thread_id(runtime)
    skill_storage = get_or_new_user_skill_storage(user_id)  # per-user 存储

    async with lock:
        if action == "create":
            if await _to_thread(skill_storage.custom_skill_exists, name):
                raise ValueError(f"Custom skill '{name}' already exists.")
            if content is None:
                raise ValueError("content is required for create.")
            await _to_thread(skill_storage.validate_skill_markdown_content, name, content)
            static_findings = await _scan_static_candidate_or_raise(name, {SKILL_MD_FILE: content})
            scan = await _scan_or_raise(content, executable=False, location=f"{name}/{SKILL_MD_FILE}", static_findings=static_findings)
            scan["static_findings"] = static_findings
            await _to_thread(skill_storage.write_custom_skill, name, SKILL_MD_FILE, content)
            await _to_thread(
                skill_storage.append_history,
                name,
                _history_record(action="create", file_path=SKILL_MD_FILE, prev_content=None, new_content=content, thread_id=thread_id, scanner=scan),
            )
            await refresh_user_skills_system_prompt_cache_async(user_id)
            return f"Created custom skill '{name}'."

        if action == "edit":
            # 全量替换 SKILL.md（与 patch 的 diff 语义互补；用于大改）
            await _to_thread(skill_storage.ensure_custom_skill_is_editable, name)
            if content is None:
                raise ValueError("content is required for edit.")
            await _to_thread(skill_storage.validate_skill_markdown_content, name, content)
            static_findings = await _scan_static_candidate_or_raise(name, {SKILL_MD_FILE: content})
            scan = await _scan_or_raise(content, executable=False, location=f"{name}/{SKILL_MD_FILE}", static_findings=static_findings)
            scan["static_findings"] = static_findings
            skill_file = skill_storage.get_custom_skill_file(name)
            prev_content = await _to_thread(skill_file.read_text, encoding="utf-8")
            await _to_thread(skill_storage.write_custom_skill, name, SKILL_MD_FILE, content)
            await _to_thread(
                skill_storage.append_history,
                name,
                _history_record(action="edit", file_path=SKILL_MD_FILE, prev_content=prev_content, new_content=content, thread_id=thread_id, scanner=scan),
            )
            await refresh_user_skills_system_prompt_cache_async(user_id)
            return f"Updated custom skill '{name}'."

        if action == "patch":
            await _to_thread(skill_storage.ensure_custom_skill_is_editable, name)
            if find is None or replace is None:
                raise ValueError("find and replace are required for patch.")
            skill_file = skill_storage.get_custom_skill_file(name)
            prev_content = await _to_thread(skill_file.read_text, encoding="utf-8")
            occurrences = prev_content.count(find)
            if occurrences == 0:
                raise ValueError("Patch target not found in SKILL.md.")
            if expected_count is not None and occurrences != expected_count:
                raise ValueError(f"Expected {expected_count} replacements but found {occurrences}.")
            replacement_count = expected_count if expected_count is not None else 1
            new_content = prev_content.replace(find, replace, replacement_count)
            await _to_thread(skill_storage.validate_skill_markdown_content, name, new_content)
            static_findings = await _scan_static_candidate_or_raise(name, {SKILL_MD_FILE: new_content})
            scan = await _scan_or_raise(new_content, executable=False, location=f"{name}/{SKILL_MD_FILE}", static_findings=static_findings)
            scan["static_findings"] = static_findings
            await _to_thread(skill_storage.write_custom_skill, name, SKILL_MD_FILE, new_content)
            await _to_thread(
                skill_storage.append_history,
                name,
                _history_record(action="patch", file_path=SKILL_MD_FILE, prev_content=prev_content, new_content=new_content, thread_id=thread_id, scanner=scan),
            )
            await refresh_user_skills_system_prompt_cache_async(user_id)
            return f"Patched custom skill '{name}' ({replacement_count} replacement(s) applied, {occurrences} match(es) found)."

        if action == "delete":
            await _to_thread(
                skill_storage.delete_custom_skill,
                name,
                history_meta=_history_record(
                    action="delete",
                    file_path=SKILL_MD_FILE,
                    prev_content=None,
                    new_content=None,
                    thread_id=thread_id,
                    scanner={"decision": "allow", "reason": "Deletion requested."},
                ),
            )
            await refresh_user_skills_system_prompt_cache_async(user_id)
            return f"Deleted custom skill '{name}'."

        if action == "write_file":
            # 写支撑文件（references/templates/scripts/assets 下）。scripts/ 按 executable 更严扫描
            await _to_thread(skill_storage.ensure_custom_skill_is_editable, name)
            if path is None or content is None:
                raise ValueError("path and content are required for write_file.")
            target = await _to_thread(skill_storage.ensure_safe_support_path, name, path)
            exists = await _to_thread(target.exists)
            prev_content = await _to_thread(target.read_text, encoding="utf-8") if exists else None
            executable = "scripts/" in path or path.startswith("scripts/")
            static_findings = await _scan_static_candidate_or_raise(name, {path: content}, skill_storage)
            scan = await _scan_or_raise(content, executable=executable, location=f"{name}/{path}", static_findings=static_findings)
            scan["static_findings"] = static_findings
            await _to_thread(skill_storage.write_custom_skill, name, path, content)
            await _to_thread(
                skill_storage.append_history,
                name,
                _history_record(action="write_file", file_path=path, prev_content=prev_content, new_content=content, thread_id=thread_id, scanner=scan),
            )
            await refresh_user_skills_system_prompt_cache_async(user_id)
            return f"Wrote '{path}' for custom skill '{name}'."

        if action == "remove_file":
            await _to_thread(skill_storage.ensure_custom_skill_is_editable, name)
            if path is None:
                raise ValueError("path is required for remove_file.")
            target = await _to_thread(skill_storage.ensure_safe_support_path, name, path)
            if not await _to_thread(target.exists):
                raise FileNotFoundError(f"Supporting file '{path}' not found for skill '{name}'.")
            prev_content = await _to_thread(target.read_text, encoding="utf-8")
            await _to_thread(target.unlink)
            await _to_thread(
                skill_storage.append_history,
                name,
                _history_record(action="remove_file", file_path=path, prev_content=prev_content, new_content=None, thread_id=thread_id, scanner={"decision": "allow", "reason": "Deletion requested."}),
            )
            await refresh_user_skills_system_prompt_cache_async(user_id)
            return f"Removed '{path}' from custom skill '{name}'."

        # 未知 action：先检查是否是只读技能，给出更精确错误
        if await _to_thread(skill_storage.public_skill_exists, name):
            # public_skill_exists 覆盖 PUBLIC 与 LEGACY；UserScopedSkillStorage 重写
            # 在 ensure_custom_skill_is_editable 中按类别给不同消息
            raise ValueError(f"'{name}' is a read-only skill (built-in or legacy shared). To customise it, create your own version with the same name.")
        raise ValueError(f"Unsupported action '{action}'.")


@tool("skill_manage", parse_docstring=True)
async def skill_manage_tool(
    runtime: Runtime,
    action: str,
    name: str,
    content: str | None = None,
    path: str | None = None,
    find: str | None = None,
    replace: str | None = None,
    expected_count: int | None = None,
) -> str:
    """Manage custom skills under skills/custom/.

    Args:
        action: One of create, patch, edit, delete, write_file, remove_file.
        name: Skill name in hyphen-case.
        content: New file content for create, edit, or write_file.
        path: Supporting file path for write_file or remove_file.
        find: Existing text to replace for patch.
        replace: Replacement text for patch.
        expected_count: Optional expected number of replacements for patch.
    """
    return await _skill_manage_impl(
        runtime=runtime,
        action=action,
        name=name,
        content=content,
        path=path,
        find=find,
        replace=replace,
        expected_count=expected_count,
    )


# 同步包装：供非异步工具调用路径使用
skill_manage_tool.func = make_sync_tool_wrapper(_skill_manage_impl, "skill_manage")
```

## 5. 安装管线要点（`.skill` 归档）

`ainstall_skill_from_archive`（见 [./skill-protocol-and-storage.md](./skill-protocol-and-storage.md) §4/§5）是 4 阶段管线：

1. **安全提取**：拒绝对路径（POSIX/Windows）与含 `..` 的成员；跳过符号链接（`S_ISLNK` mode 位）；joinpath 后再 `is_relative_to(root)` 校验；64 KiB 流式 + 512 MiB 总量上限（zip-bomb cap）。
2. **定位技能根**：过滤 `.` 开头与 `__MACOSX`；判断单顶层目录 vs 散放。
3. **内容安全扫描**（`_scan_skill_archive_contents_or_raise`）：根 `SKILL.md` 总扫（non-executable）；嵌套 `SKILL.md` 立即拒（无子技能）；`scripts/` 下按 executable 更严；`references/`/`templates/` 仅扫 `.md/.markdown/.rst/.txt/.json/.yaml/.yml`；其余不动。每文件 async LLM 调用返回 `{"decision": "allow|warn|block", "reason": "..."}`；`block` 即拒；executable 要求 `allow`；无响应 fail closed 为 `block`；非 UTF-8 拒。
4. **原子提交**：暂存目录（`.installing-<name>-…`）+ `mkdir(0o700)` 占位（`FileExistsError` -> `SkillAlreadyExistsError`，不覆盖）；逐项移入；整树 `chmod` 沙箱可读（555 目录 / 444 文件，去 group/other 写位）；失败 `finally` 清半截目标；暂存 tmp 5s 超时清理。

## 关联

- SKILL.md：[../SKILL.md](../SKILL.md)
- 协议 + 存储 + per-user 完整源码：[./skill-protocol-and-storage.md](./skill-protocol-and-storage.md)
- slash 激活 + secret 绑定完整源码：[./activation-and-whitelist.md](./activation-and-whitelist.md)
- 缓存 + skills_section 渲染 + 装配入口完整源码：[./cache-and-prompt-rendering.md](./cache-and-prompt-rendering.md)
- 关联 skill：[[tool-assembly-and-policy]]（白名单接入装配链）、[[system-prompt-template]]（skills_section 槽位）
