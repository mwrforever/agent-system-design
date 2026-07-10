# Skill Protocol & Storage - 完整源码

> 本文件是 `skill-system-design` 的**协议 + 存储层**完整源码：`types.py`（数据模型）+ `parser.py`（frontmatter 解析）+ `SkillStorage` 抽象基类 + `LocalSkillStorage` + `UserScopedSkillStorage`（per-user 隔离）+ 单例工厂 + 文件权限助手 + `SkillsConfig`。SKILL.md 只放设计架构思路与伪代码，完整源码以此文件为准。代码已按插件匿名化规则映射到自定结构，去除项目字样；真实代码原注释保留以保真。

## 1. Skill 类型 + category（核心数据模型）

```python
# core/helix/skills/types.py
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path

from helix.constants import DEFAULT_SKILLS_CONTAINER_PATH

SKILL_MD_FILE = "SKILL.md"


class SkillCategory(StrEnum):
    """技能来源类别。

    - PUBLIC：平台自带技能，全局只读。
    - CUSTOM：用户自建技能，可编辑可删除，存 per-user 目录。
    - LEGACY：用户隔离迁移前的全局 custom 技能，呈现为只读（可见但不可改/不可删），
      在沙箱挂载到 /mnt/skills/legacy/<name>/。
    """

    PUBLIC = "public"
    CUSTOM = "custom"
    LEGACY = "legacy"


@dataclass(frozen=True)
class SecretRequirement:
    """技能声明的 request 级 secret（#3861）。

    name 既是 request.context.secrets 里查找的 key，也是技能激活时注入沙箱子进程的环境变量名。
    """
    name: str
    optional: bool = False


@dataclass(frozen=True)
class Skill:
    """技能元数据 + 文件路径。frontmatter 是身份来源，enabled 由 sidecar 合并。"""

    name: str
    description: str
    license: str | None
    skill_dir: Path
    skill_file: Path
    relative_path: Path  # 从 category 根到技能目录的相对路径
    category: SkillCategory
    allowed_tools: tuple[str, ...] | None = None  # None=不限制；()=显式不要工具
    enabled: bool = False  # 实际状态来自 extensions_config / _skill_states.json
    required_secrets: tuple[SecretRequirement, ...] = field(default_factory=tuple)
    # 声明的 secret 是否可在自主加载(skill_context)时绑定，还是仅 /slash 显式激活时绑定
    secrets_autonomous: bool = True

    @property
    def skill_path(self) -> str:
        """从 category 根到本技能目录的相对路径（POSIX）。"""
        path = self.relative_path.as_posix()
        return "" if path == "." else path

    def get_container_path(self, container_base_path: str = DEFAULT_SKILLS_CONTAINER_PATH) -> str:
        """沙箱内技能目录全路径：/mnt/skills/{category}/[<relative_path>]。"""
        category_base = f"{container_base_path}/{self.category}"
        skill_path = self.skill_path
        if skill_path:
            return f"{category_base}/{skill_path}"
        return category_base

    def get_container_file_path(self, container_base_path: str = DEFAULT_SKILLS_CONTAINER_PATH) -> str:
        """沙箱内 SKILL.md 全路径（模型 read_file 用这个）。"""
        return f"{self.get_container_path(container_base_path)}/SKILL.md"
```

## 2. SKILL.md 协议解析（frontmatter regex + YAML）

```python
# core/helix/skills/parser.py
import logging
import re
from pathlib import Path

import yaml

from .types import SKILL_MD_FILE, SecretRequirement, Skill, SkillCategory

logger = logging.getLogger(__name__)

# 合法 POSIX 环境变量名（required-secrets 的 name 必须匹配）
_ENV_VAR_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parse_allowed_tools(raw: object, skill_file: Path) -> tuple[str, ...] | None:
    """解析 allowed-tools frontmatter 字段。

    None=字段省略（不限制）；tuple=字段是字符串序列（含空 tuple 表示显式不要工具）。
    畸形值抛 ValueError。
    """
    if raw is None:
        return None
    if not isinstance(raw, list):
        raise ValueError(f"allowed-tools in {skill_file} must be a list of strings")

    allowed_tools: list[str] = []
    for item in raw:
        if not isinstance(item, str):
            raise ValueError(f"allowed-tools in {skill_file} must contain only strings")
        tool_name = item.strip()
        if not tool_name:
            raise ValueError(f"allowed-tools in {skill_file} cannot contain empty tool names")
        allowed_tools.append(tool_name)
    return tuple(allowed_tools)


def parse_required_secrets(raw: object, skill_file: Path) -> tuple[SecretRequirement, ...]:
    """解析 required-secrets（#3861）。条目可以是 string 或 {name, optional}。"""
    if raw is None:
        return ()
    if not isinstance(raw, list):
        raise ValueError(f"required-secrets in {skill_file} must be a list")

    secrets: list[SecretRequirement] = []
    seen: set[str] = set()
    for item in raw:
        if isinstance(item, str):
            name, optional = item.strip(), False
        elif isinstance(item, dict):
            name = str(item.get("name") or "").strip()
            optional = bool(item.get("optional", False))
        else:
            logger.warning("Ignoring malformed required-secrets entry in %s: %r", skill_file, item)
            continue

        if not _ENV_VAR_NAME_RE.match(name):
            logger.warning("Ignoring required-secrets entry with invalid env var name in %s: %r", skill_file, name)
            continue
        if name in seen:
            continue
        seen.add(name)
        secrets.append(SecretRequirement(name=name, optional=optional))
    return tuple(secrets)


def parse_secrets_autonomous(raw: object, skill_file: Path) -> bool:
    """解析 secrets-autonomous（#3914）。默认 true；畸形值 fail closed 到 false（更安全）。"""
    if raw is None:
        return True
    if isinstance(raw, bool):
        return raw
    logger.warning("Ignoring malformed secrets-autonomous value in %s: %r (autonomous binding disabled)", skill_file, raw)
    return False


def parse_skill_file(skill_file: Path, category: SkillCategory, relative_path: Path | None = None) -> Skill | None:
    """解析 SKILL.md，提取元数据。解析失败返回 None（不抛，由调用方决定是否记日志）。"""
    if not skill_file.exists() or skill_file.name != SKILL_MD_FILE:
        return None

    try:
        content = skill_file.read_text(encoding="utf-8")

        # 提取 --- 围栏间的 YAML frontmatter
        front_matter_match = re.match(r"^---\s*\n(.*?)\n---\s*\n", content, re.DOTALL)
        if not front_matter_match:
            return None

        front_matter_text = front_matter_match.group(1)

        try:
            metadata = yaml.safe_load(front_matter_text)
        except yaml.YAMLError as exc:
            logger.error("%s", _format_yaml_error(skill_file, exc, front_matter_text))
            return None

        if not isinstance(metadata, dict):
            logger.error("Front-matter in %s is not a YAML mapping", skill_file)
            return None

        # 必填字段：name + description，都必须是非空字符串
        name = metadata.get("name")
        description = metadata.get("description")

        if not name or not isinstance(name, str):
            return None
        if not description or not isinstance(description, str):
            return None

        # 规范化：剥离 YAML 可能保留的周围空白
        name = name.strip()
        description = description.strip()

        if not name or not description:
            return None

        license_text = metadata.get("license")
        if license_text is not None:
            license_text = str(license_text).strip() or None

        try:
            allowed_tools = parse_allowed_tools(metadata.get("allowed-tools"), skill_file)
        except ValueError as exc:
            logger.error("Invalid allowed-tools in %s: %s", skill_file, exc)
            return None

        try:
            required_secrets = parse_required_secrets(metadata.get("required-secrets"), skill_file)
        except ValueError as exc:
            logger.error("Invalid required-secrets in %s: %s", skill_file, exc)
            return None

        secrets_autonomous = parse_secrets_autonomous(metadata.get("secrets-autonomous"), skill_file)

        return Skill(
            name=name,
            description=description,
            license=license_text,
            skill_dir=skill_file.parent,
            skill_file=skill_file,
            relative_path=relative_path or Path(skill_file.parent.name),
            category=category,
            allowed_tools=allowed_tools,
            enabled=True,  # 实际状态来自 extensions config，load_skills 会合并
            required_secrets=required_secrets,
            secrets_autonomous=secrets_autonomous,
        )

    except Exception:
        logger.exception("Unexpected error parsing skill file %s", skill_file)
        return None


def _format_yaml_error(skill_file: Path, exc: yaml.YAMLError, source: str) -> str:
    """把 YAML front-matter 错误渲染成开发者友好的解释。

    mark.line 是 front-matter 体内的 0-based 行号；+1 转 1-based，再 +1 补上 regex 剥掉的 leading --- 围栏，
    使行号与作者在编辑器看到的一致。对最常见的 ``key: value with: colon`` 错误给引号提示。
    """
    lines = [f"Invalid YAML front-matter in {skill_file}: {exc}"]

    mark = getattr(exc, "problem_mark", None)
    source_lines = source.splitlines()
    if mark is not None and 0 <= mark.line < len(source_lines):
        offending = source_lines[mark.line]
        file_line_number = mark.line + 2  # +1 转 1-based，+1 补 --- 围栏
        lines.append(f"  line {file_line_number}: {offending}")

        # 只在确信适用时给提示，避免误导碰到无关 YAML 错误的作者
        if getattr(exc, "problem", "") == "mapping values are not allowed here" and ":" in offending:
            key, _, value = offending.partition(":")
            value = value.strip()
            if value and value[0] not in {'"', "'", "|", ">", "[", "{"}:
                escaped = value.replace("\\", "\\\\").replace('"', '\\"')
                lines.append(f'  hint: values containing ":" must be quoted, e.g. {key}: "{escaped}"')

    return "\n".join(lines)
```

## 3. SkillStorage 抽象基类（模板方法流）

```python
# core/helix/skills/storage/skill_storage.py
"""抽象 SkillStorage 基类 + 模板方法流。"""

from __future__ import annotations

import dataclasses
import logging
import re
from abc import ABC, abstractmethod
from collections.abc import Iterable
from pathlib import Path

from helix.constants import DEFAULT_SKILLS_CONTAINER_PATH
from helix.skills.types import SKILL_MD_FILE, Skill, SkillCategory  # noqa: F401

logger = logging.getLogger(__name__)

_SKILL_NAME_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


class SkillStorage(ABC):
    """技能存储后端抽象基类。

    子类实现少量存储介质相关的原子操作；本基类提供最终模板方法流
    （load_skills、history 序列化、路径助手、校验），用协议级助手组合它们。
    """

    def __init__(self, container_path: str = DEFAULT_SKILLS_CONTAINER_PATH) -> None:
        self._container_root = container_path

    # ------------------------------------------------------------------
    # 静态协议助手（非存储相关）
    # ------------------------------------------------------------------

    @staticmethod
    def validate_skill_name(name: str) -> str:
        """校验并规范化技能名，返回规范化形式。hyphen-case，≤64 字符。"""
        normalized = name.strip()
        if not _SKILL_NAME_PATTERN.fullmatch(normalized):
            raise ValueError("Skill name must be hyphen-case using lowercase letters, digits, and hyphens only.")
        if len(normalized) > 64:
            raise ValueError("Skill name must be 64 characters or fewer.")
        return normalized

    @staticmethod
    def validate_relative_path(relative_path: str, base_dir: Path) -> Path:
        """校验 relative_path 不逃逸 base_dir（跟符号链接），返回 resolved target。"""
        if not relative_path:
            raise ValueError("relative_path must not be empty.")
        resolved_base = base_dir.resolve()
        target = (resolved_base / relative_path).resolve()
        try:
            target.relative_to(resolved_base)
        except ValueError as exc:
            raise ValueError("relative_path must resolve within the skill directory.") from exc
        return target

    @staticmethod
    def validate_skill_markdown_content(name: str, content: str) -> None:
        """校验 SKILL.md 内容：解析 frontmatter 并检查 name 匹配。"""
        import tempfile

        from helix.skills.validation import _validate_skill_frontmatter

        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_skill_dir = Path(tmp_dir) / SkillStorage.validate_skill_name(name)
            temp_skill_dir.mkdir(parents=True, exist_ok=True)
            (temp_skill_dir / SKILL_MD_FILE).write_text(content, encoding="utf-8")
            is_valid, message, parsed_name = _validate_skill_frontmatter(temp_skill_dir)
            if not is_valid:
                raise ValueError(message)
            if parsed_name != name:
                raise ValueError(f"Frontmatter name '{parsed_name}' must match requested skill name '{name}'.")

    def ensure_safe_support_path(self, name: str, relative_path: str) -> Path:
        """校验并返回支撑文件的 resolved 绝对路径（write_file/remove_file 用）。

        支撑文件只能落在 references/templates/scripts/assets 四个子目录之一，防路径穿越。
        """
        _ALLOWED_SUPPORT_SUBDIRS = {"references", "templates", "scripts", "assets"}
        skill_dir = self.get_custom_skill_dir(self.validate_skill_name(name)).resolve()
        if not relative_path or relative_path.endswith("/"):
            raise ValueError("Supporting file path must include a filename.")
        relative = Path(relative_path)
        if relative.is_absolute():
            raise ValueError("Supporting file path must be relative.")
        if any(part in {"..", ""} for part in relative.parts):
            raise ValueError("Supporting file path must not contain parent-directory traversal.")
        top_level = relative.parts[0] if relative.parts else ""
        if top_level not in _ALLOWED_SUPPORT_SUBDIRS:
            raise ValueError(f"Supporting files must live under one of: {', '.join(sorted(_ALLOWED_SUPPORT_SUBDIRS))}.")
        target = (skill_dir / relative).resolve()
        allowed_root = (skill_dir / top_level).resolve()
        try:
            target.relative_to(allowed_root)
        except ValueError as exc:
            raise ValueError("Supporting file path must stay within the selected support directory.") from exc
        return target

    # ------------------------------------------------------------------
    # 抽象原子操作（存储介质相关）
    # ------------------------------------------------------------------

    @abstractmethod
    def get_skills_root_path(self) -> Path:
        """技能根的宿主绝对路径（沙箱挂载用）。"""

    def validate_skill_file_path(self, skill_file: Path) -> Path:
        """校验 skill_file 在允许的根内，返回 resolved 路径。

        默认实现检查 skill_file 在 get_skills_root_path() 下--对 LocalSkillStorage 足够
        （public 与 custom 同根）。UserScopedSkillStorage 重写为接纳 per-user custom 根
        （custom 不在全局根下）。
        """
        resolved_file = skill_file.resolve()
        resolved_root = self.get_skills_root_path().resolve()
        try:
            resolved_file.relative_to(resolved_root)
        except ValueError as exc:
            raise ValueError("Resolved skill file must stay within the configured skills root.") from exc
        return resolved_file

    @abstractmethod
    def _iter_skill_files(self) -> Iterable[tuple[SkillCategory, Path, Path]]:
        """为每个 SKILL.md yield (category, category_root, skill_md_path)。"""

    @abstractmethod
    def read_custom_skill(self, name: str) -> str:
        """读 custom 技能的 SKILL.md 内容。"""

    @abstractmethod
    def write_custom_skill(self, name: str, relative_path: str, content: str) -> None:
        """原子写 custom/<name>/<relative_path>。"""

    @abstractmethod
    async def ainstall_skill_from_archive(self, archive_path: str | Path) -> dict:
        """从 .skill ZIP 归档异步安装。"""

    def install_skill_from_archive(self, archive_path: str | Path) -> dict:
        """同步包装--委托给 ainstall_skill_from_archive。"""
        from helix.skills.installer import _run_async_install

        return _run_async_install(self.ainstall_skill_from_archive(archive_path))

    @abstractmethod
    def delete_custom_skill(self, name: str, *, history_meta: dict | None = None) -> None:
        """删除 custom 技能（校验 + 可选 history + 目录移除）。"""

    @abstractmethod
    def custom_skill_exists(self, name: str) -> bool:
        ...

    @abstractmethod
    def public_skill_exists(self, name: str) -> bool:
        ...

    @abstractmethod
    def append_history(self, name: str, record: dict) -> None:
        """为 name 追加一条 JSONL history 记录。"""

    @abstractmethod
    def read_history(self, name: str) -> list[dict]:
        """返回 name 的全部 history 记录（oldest first）。"""

    # ------------------------------------------------------------------
    # 具体路径助手（layout 是 SKILL.md 协议的一部分）
    # ------------------------------------------------------------------

    def get_container_root(self) -> str:
        return self._container_root

    def get_custom_skill_dir(self, name: str) -> Path:
        """custom/<name> 路径（不创建目录）。"""
        normalized_name = self.validate_skill_name(name)
        return self.get_skills_root_path() / SkillCategory.CUSTOM.value / normalized_name

    def get_custom_skill_file(self, name: str) -> Path:
        """custom/<name>/SKILL.md 路径。"""
        normalized_name = self.validate_skill_name(name)
        return self.get_custom_skill_dir(normalized_name) / SKILL_MD_FILE

    def get_skill_history_file(self, name: str) -> Path:
        """custom/.history/<name>.jsonl 路径（不创建父目录）。

        注意：默认实现返回全局技能根下的路径，对 LocalSkillStorage 正确，
        对 UserScopedSkillStorage 不正确--重定向 custom 路径的子类必须重写本方法。
        """
        normalized_name = self.validate_skill_name(name)
        return self.get_skills_root_path() / SkillCategory.CUSTOM.value / ".history" / f"{normalized_name}.jsonl"

    # ------------------------------------------------------------------
    # 最终模板方法流
    # ------------------------------------------------------------------

    def load_skills(self, *, enabled_only: bool = False) -> list[Skill]:
        """发现全部技能，合并 enabled 状态，排序，可选过滤。

        每次调用都重读 extensions_config，使另一进程的改动立即被看到。
        所有类别（PUBLIC/LEGACY/CUSTOM）都尊重 extensions_config 的 enabled/disabled 状态。
        CUSTOM 技能在无显式配置项时默认 enabled（新装的技能无需手动开关即激活）。
        """
        from helix.skills.parser import parse_skill_file

        skills_by_name: dict[str, Skill] = {}
        for category, category_root, md_path in self._iter_skill_files():
            skill = parse_skill_file(
                md_path,
                category=category,
                relative_path=md_path.parent.relative_to(category_root),
            )
            if skill:
                skills_by_name[skill.name] = skill

        skills = list(skills_by_name.values())

        # 从 extensions config 合并 enabled 状态（每次调用都重读）
        try:
            from helix.config.extensions_config import ExtensionsConfig

            extensions_config = ExtensionsConfig.from_file()
            skills = [dataclasses.replace(s, enabled=extensions_config.is_skill_enabled(s.name, s.category)) for s in skills]
        except Exception as e:
            logger.warning("Failed to load extensions config: %s", e)

        if enabled_only:
            skills = [s for s in skills if s.enabled]

        skills.sort(key=lambda s: s.name)
        return skills

    def ensure_custom_skill_is_editable(self, name: str) -> None:
        """只有 CUSTOM 类别技能可编辑。PUBLIC（内置）与 LEGACY（共享迁移前）只读。"""
        if self.custom_skill_exists(name):
            return
        if self.public_skill_exists(name):
            raise ValueError(f"'{name}' is a built-in skill. To customise it, create a new skill with the same name under skills/custom/.")
        raise FileNotFoundError(f"Custom skill '{name}' not found.")
```

## 4. LocalSkillStorage（本地文件系统实现）

```python
# core/helix/skills/storage/local_skill_storage.py
"""LocalSkillStorage - SkillStorage 的本地文件系统实现。"""

from __future__ import annotations

import asyncio
import errno
import json
import logging
import os
import shutil
import tempfile
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path

from helix.config.runtime_paths import resolve_path
from helix.constants import DEFAULT_SKILLS_CONTAINER_PATH
from helix.skills.permissions import make_skill_written_path_sandbox_readable
from helix.skills.storage.skill_storage import SKILL_MD_FILE, SkillStorage
from helix.skills.types import SkillCategory

logger = logging.getLogger(__name__)

# 安装临时目录清理的超时上限，防卡住的文件系统（如 NFS）阻塞安装结果的传播
_INSTALL_TMP_CLEANUP_TIMEOUT_SECONDS = 5.0


class LocalSkillStorage(SkillStorage):
    """本地文件系统后端的技能存储。

    Layout::

        <root>/public/<name>/SKILL.md
        <root>/custom/<name>/SKILL.md
        <root>/custom/.history/<name>.jsonl
    """

    def __init__(
        self,
        host_path: str | None = None,
        container_path: str = DEFAULT_SKILLS_CONTAINER_PATH,
        app_config=None,
    ) -> None:
        super().__init__(container_path=container_path)
        if host_path is None:
            from helix.config import get_app_config

            config = app_config or get_app_config()
            self._app_config = config
            self._host_root: Path = config.skills.get_skills_path()
        else:
            # 保留 app_config 原样（可能 None）。本 host_path 构造器用于测试与非 user-scoped 存储；
            # 此处急切调 get_app_config() 会破坏无配置环境（如 CI）。
            # skill_scan.enabled 开关在扫描时由 skill_scan_enabled() 懒解析，也拾取热重载配置。
            self._app_config = app_config
            self._host_root = resolve_path(host_path)

    # ------------------------------------------------------------------
    # 抽象操作实现
    # ------------------------------------------------------------------

    def get_skills_root_path(self) -> Path:
        return self._host_root

    def custom_skill_exists(self, name: str) -> bool:
        return self.get_custom_skill_file(name).exists()

    def public_skill_exists(self, name: str) -> bool:
        normalized_name = self.validate_skill_name(name)
        return (self._host_root / SkillCategory.PUBLIC.value / normalized_name / SKILL_MD_FILE).exists()

    def _iter_skill_files(self) -> Iterable[tuple[SkillCategory, Path, Path]]:
        if not self._host_root.exists():
            return
        for category in SkillCategory:
            category_path = self._host_root / category.value
            if not category_path.exists() or not category_path.is_dir():
                continue
            for current_root, dir_names, file_names in os.walk(category_path, followlinks=True):
                dir_names[:] = sorted(name for name in dir_names if not name.startswith("."))
                if SKILL_MD_FILE not in file_names:
                    continue
                yield category, category_path, Path(current_root) / SKILL_MD_FILE

    def read_custom_skill(self, name: str) -> str:
        if not self.custom_skill_exists(name):
            raise FileNotFoundError(f"Custom skill '{name}' not found.")
        return (self.get_custom_skill_dir(name) / SKILL_MD_FILE).read_text(encoding="utf-8")

    def write_custom_skill(self, name: str, relative_path: str, content: str) -> None:
        """原子写：临时文件 + os.replace，读者永不观察半截文件；落盘后重应用沙箱可读权限。"""
        target = self.validate_relative_path(relative_path, self.get_custom_skill_dir(name))
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            delete=False,
            dir=str(target.parent),
        ) as tmp_file:
            tmp_file.write(content)
            tmp_path = Path(tmp_file.name)
        tmp_path.replace(target)
        make_skill_written_path_sandbox_readable(self.get_custom_skill_dir(name), target)

    async def ainstall_skill_from_archive(self, archive_path: str | Path) -> dict:
        """从 .skill ZIP 归档安装：4 阶段管线（提取/定位根/安全扫描/原子提交）。

        每文件安全扫描是 async LLM 调用，必须在事件循环上；其周围的文件系统阶段跑在工作线程。
        """
        from helix.skills.installer import _scan_skill_archive_contents_or_raise

        logger.info("Installing skill from %s", archive_path)
        path = Path(archive_path)
        custom_dir = self._host_root / "custom"

        tmp = await asyncio.to_thread(tempfile.mkdtemp)
        try:
            skill_dir, skill_name, target = await asyncio.to_thread(self._prepare_skill_archive, path, Path(tmp), custom_dir, archive_path)

            await _scan_skill_archive_contents_or_raise(skill_dir, skill_name, app_config=self._app_config)

            await asyncio.to_thread(self._commit_skill_install, skill_dir, skill_name, custom_dir, target)
            logger.info("Skill %r installed to %s", skill_name, target)
        finally:
            try:
                await asyncio.wait_for(
                    asyncio.to_thread(self._cleanup_install_tmp, tmp),
                    timeout=_INSTALL_TMP_CLEANUP_TIMEOUT_SECONDS,
                )
            except TimeoutError:
                logger.warning("Timed out cleaning up skill install temp dir %s", tmp)

        return {
            "success": True,
            "skill_name": skill_name,
            "message": f"Skill '{skill_name}' installed successfully",
        }

    @staticmethod
    def _cleanup_install_tmp(tmp: str) -> None:
        """best-effort 清理，不掩盖安装结果，但留 trace。"""
        try:
            shutil.rmtree(tmp)
        except OSError:
            logger.warning("Failed to clean up skill install temp dir %s", tmp, exc_info=True)

    def _prepare_skill_archive(self, path: Path, tmp_path: Path, custom_dir: Path, archive_path: str | Path) -> tuple[Path, str, Path]:
        """提取并校验归档（阻塞；跑在事件循环外）。"""
        import zipfile

        from helix.skills.installer import (
            SkillAlreadyExistsError,
            resolve_skill_dir_from_archive,
            safe_extract_skill_archive,
            scan_archive_preflight_or_raise,
        )
        from helix.skills.validation import _validate_skill_frontmatter

        if not path.is_file():
            if not path.exists():
                raise FileNotFoundError(f"Skill file not found: {archive_path}")
            raise ValueError(f"Path is not a file: {archive_path}")
        if path.suffix != ".skill":
            raise ValueError("File must have .skill extension")

        custom_dir.mkdir(parents=True, exist_ok=True)

        try:
            zf = zipfile.ZipFile(path, "r")
        except FileNotFoundError:
            raise FileNotFoundError(f"Skill file not found: {archive_path}") from None
        except (zipfile.BadZipFile, IsADirectoryError):
            raise ValueError("File is not a valid ZIP archive") from None

        with zf:
            scan_archive_preflight_or_raise(path, app_config=self._app_config)
            safe_extract_skill_archive(zf, tmp_path)

        skill_dir = resolve_skill_dir_from_archive(tmp_path)

        is_valid, message, skill_name = _validate_skill_frontmatter(skill_dir)
        if not is_valid:
            raise ValueError(f"Invalid skill: {message}")
        if not skill_name or "/" in skill_name or "\\" in skill_name or ".." in skill_name:
            raise ValueError(f"Invalid skill name: {skill_name}")

        target = custom_dir / skill_name
        if target.exists():
            raise SkillAlreadyExistsError(f"Skill '{skill_name}' already exists")

        return skill_dir, skill_name, target

    def _commit_skill_install(self, skill_dir: Path, skill_name: str, custom_dir: Path, target: Path) -> None:
        """暂存并移动已校验技能到位（阻塞；跑在事件循环外）。"""
        from helix.skills.installer import _move_staged_skill_into_reserved_target

        with tempfile.TemporaryDirectory(prefix=f".installing-{skill_name}-", dir=custom_dir) as staging_root:
            staging_target = Path(staging_root) / skill_name
            shutil.copytree(skill_dir, staging_target)
            _move_staged_skill_into_reserved_target(staging_target, target)
        make_skill_written_path_sandbox_readable(custom_dir, target)

    def delete_custom_skill(self, name: str, *, history_meta: dict | None = None) -> None:
        """删除 custom 技能：校验可编辑 -> 可选写 history -> rmtree。

        history 写是 best-effort：只读 FS 错误（EACCES/EPERM/EROFS）降级为 warning，
        使删除仍能完成；其他 OSError 传播。
        """
        self.validate_skill_name(name)
        self.ensure_custom_skill_is_editable(name)
        target = self.get_custom_skill_dir(name)
        if history_meta is not None:
            prev_content = self.read_custom_skill(name)
            try:
                self.append_history(name, {**history_meta, "prev_content": prev_content})
            except OSError as e:
                if not isinstance(e, PermissionError) and e.errno not in {errno.EACCES, errno.EPERM, errno.EROFS}:
                    raise
                logger.warning(
                    "Skipping delete history write for custom skill %s due to readonly/permission failure; continuing with skill directory removal: %s",
                    name,
                    e,
                )
        if target.exists():
            shutil.rmtree(target)

    def append_history(self, name: str, record: dict) -> None:
        """追加 JSONL history 记录（append-only 审计轨迹）。"""
        self.validate_skill_name(name)
        payload = {"ts": datetime.now(UTC).isoformat(), **record}
        history_path = self.get_skill_history_file(name)
        history_path.parent.mkdir(parents=True, exist_ok=True)
        with history_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(payload, ensure_ascii=False))
            f.write("\n")

    def read_history(self, name: str) -> list[dict]:
        self.validate_skill_name(name)
        history_path = self.get_skill_history_file(name)
        if not history_path.exists():
            return []
        records: list[dict] = []
        for line in history_path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            records.append(json.loads(line))
        return records
```

## 5. UserScopedSkillStorage（per-user 隔离 + LEGACY fallback）

```python
# core/helix/skills/storage/user_scoped_skill_storage.py
"""UserScopedSkillStorage - per-user 隔离 custom 技能的 SkillStorage。

custom 技能存到 {base_dir}/users/{user_id}/skills/custom/ 而非全局 {base_dir}/skills/custom/。
public 技能仍从全局 {base_dir}/skills/public/ 读（只读）。

Layout::

    <host_root>/public/<name>/SKILL.md            <- 全局，只读
    <user_custom_root>/<name>/SKILL.md             <- per-user，读写
    <user_custom_root>/.history/<name>.jsonl       <- per-user history
    <user_skills_root>/_skill_states.json          <- per-user enabled 状态
    <global_custom_root>/<name>/SKILL.md           <- legacy fallback，只读

Fallback：用户还没有 custom 技能时，全局 skills/custom/ 的技能作为 LEGACY（只读）yield，
使其可见但不可改/不可删。这保留迁移期向后兼容，不泄漏对 legacy 技能的可变访问。
LEGACY 技能在沙箱挂载到 /mnt/skills/legacy/<name>/，使其支撑文件可被 agent 访问。

CUSTOM 与 LEGACY 技能的 enabled/disabled 状态 per-user 存 _skill_states.json（按技能名 keyed）。
PUBLIC 技能状态仍全局存 extensions_config.json。这防两用户各持同名 custom 技能时跨用户串扰。
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import logging
import os
import tempfile
from collections.abc import Iterable
from pathlib import Path

from helix.constants import DEFAULT_SKILLS_CONTAINER_PATH
from helix.skills.permissions import make_skill_written_path_sandbox_readable
from helix.skills.storage.local_skill_storage import LocalSkillStorage
from helix.skills.storage.skill_storage import SKILL_MD_FILE
from helix.skills.types import SkillCategory

logger = logging.getLogger(__name__)


class UserScopedSkillStorage(LocalSkillStorage):
    """per-user 隔离 custom 技能的存储。

    继承 LocalSkillStorage 的全部 public 行为（读 _host_root/public/）。
    custom 路径重定向到 _user_custom_root，使每用户的 custom 技能住在自己的目录树。

    设计要点：一旦用户建了第一个 custom 技能，per-user 目录存在，全局 custom fallback 不再生效--
    LEGACY 技能从该用户列表消失。这是有意的（shadow-mount 语义：用户自己的目录遮蔽全局目录）。
    """

    def __init__(
        self,
        user_id: str,
        host_path: str | None = None,
        container_path: str = DEFAULT_SKILLS_CONTAINER_PATH,
        app_config=None,
    ) -> None:
        super().__init__(host_path=host_path, container_path=container_path, app_config=app_config)

        from helix.config.paths import _validate_user_id, get_paths

        self._user_id = _validate_user_id(user_id)
        paths = get_paths()
        self._user_custom_root: Path = paths.user_custom_skills_dir(self._user_id)
        self._user_skills_root: Path = paths.user_skills_dir(self._user_id)
        self._global_custom_root: Path = self._host_root / SkillCategory.CUSTOM.value
        self._skill_states_file: Path = self._user_skills_root / "_skill_states.json"

    # ------------------------------------------------------------------
    # per-user 技能 enabled 状态（仅 CUSTOM / LEGACY）
    # ------------------------------------------------------------------

    def _read_skill_states(self) -> dict[str, dict[str, bool]]:
        """从 _skill_states.json 读 per-user enabled 状态。文件不存在或不可读返回空 dict。"""
        if not self._skill_states_file.exists():
            return {}
        try:
            with open(self._skill_states_file, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                return data
        except (json.JSONDecodeError, OSError):
            logger.warning("Failed to read skill states file %s", self._skill_states_file)
        return {}

    def _write_skill_states(self, states: dict[str, dict[str, bool]]) -> None:
        """持久化 per-user enabled 状态到 _skill_states.json。

        原子写：同目录临时文件 + Path.replace（同文件系统 POSIX 原子）。
        没有它，crash/SIGTERM/磁盘满 mid-write 会留下截断或空文件；_read_skill_states 返回 {}，
        get_skill_enabled_state 会静默重新启用用户已禁用的每个技能。
        """
        self._user_skills_root.mkdir(parents=True, exist_ok=True)
        fd, tmp_path_str = tempfile.mkstemp(
            dir=str(self._user_skills_root),
            prefix=".skill_states_",
            suffix=".json.tmp",
        )
        tmp_path = Path(tmp_path_str)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(states, f, indent=2)
            tmp_path.replace(self._skill_states_file)
        except Exception:
            try:
                tmp_path.unlink(missing_ok=True)
            except OSError:
                pass
            raise

    def get_skill_enabled_state(self, skill_name: str) -> bool:
        """返回 custom/legacy 技能的 enabled 状态。默认 True（新建即启用）。"""
        states = self._read_skill_states()
        entry = states.get(skill_name)
        if entry is None:
            return True
        return entry.get("enabled", True)

    def set_skill_enabled_state(self, skill_name: str, enabled: bool) -> None:
        """设置并持久化 custom/legacy 技能的 enabled 状态。"""
        states = self._read_skill_states()
        states[skill_name] = {"enabled": enabled}
        self._write_skill_states(states)

    # ------------------------------------------------------------------
    # 路径助手 - 重定向 custom 路径到用户目录
    # ------------------------------------------------------------------

    def get_custom_skill_dir(self, name: str) -> Path:
        """per-user custom 技能目录：<user_custom_root>/<name>/。"""
        normalized_name = self.validate_skill_name(name)
        return self._user_custom_root / normalized_name

    def get_custom_skill_file(self, name: str) -> Path:
        """per-user custom SKILL.md 路径。"""
        return self.get_custom_skill_dir(name) / SKILL_MD_FILE

    def get_skill_history_file(self, name: str) -> Path:
        """per-user custom history：<user_custom_root>/.history/<name>.jsonl。"""
        normalized_name = self.validate_skill_name(name)
        return self._user_custom_root / ".history" / f"{normalized_name}.jsonl"

    # ------------------------------------------------------------------
    # enabled 状态 - 重写为 custom/legacy 用 per-user 状态
    # ------------------------------------------------------------------

    def load_skills(self, *, enabled_only: bool = False) -> list:
        """发现全部技能并按隔离 scope 合并 enabled 状态。

        委托技能发现与 PUBLIC enabled 状态给 LocalSkillStorage.load_skills（读重写的 _iter_skill_files）。
        然后用 per-user _skill_states.json 覆盖 CUSTOM/LEGACY 的 enabled 状态，
        使两用户各持同名 custom 技能可独立 toggle。

        调 super().load_skills() 保留完整模板方法流（发现->全局 enabled 合并->过滤->排序），
        使测试中 patch LocalSkillStorage.load_skills 仍能拦截调用。
        """
        # 让父类做完整发现 + 全局 enabled 合并
        skills = super().load_skills(enabled_only=False)

        # 用 per-user 状态覆盖 CUSTOM/LEGACY 的 enabled，AND 全局 extensions_config 默认。
        # 这保留升级前对共享 custom/legacy 技能的全局禁用不被 per-user 缺项静默重新启用，
        # 同时允许 per-user 状态在两者都在时覆盖全局默认。PUBLIC 状态仅由 extensions_config 治理。
        from helix.config.extensions_config import get_extensions_config

        extensions_config = get_extensions_config()
        skills = [
            dataclasses.replace(s, enabled=self.get_skill_enabled_state(s.name) and extensions_config.is_skill_enabled(s.name, s.category.value if hasattr(s.category, "value") else s.category))
            if dataclasses.is_dataclass(s) and not isinstance(s, type) and (s.category.value if hasattr(s.category, "value") else s.category) != SkillCategory.PUBLIC.value
            else s
            for s in skills
        ]

        if enabled_only:
            skills = [s for s in skills if s.enabled]

        return skills

    # ------------------------------------------------------------------
    # 技能迭代 - public 从全局，custom 从用户目录 + fallback
    # ------------------------------------------------------------------

    def public_skill_exists(self, name: str) -> bool:
        """检查技能是否为 public 或全局 custom fallback。

        全局 skills/custom/ 含 legacy 技能，对还没有 per-user custom 的用户呈现为 LEGACY。
        本重写使那些技能被识别为"只读"，使 ensure_custom_skill_is_editable 给出有用错误而非 FileNotFoundError。
        """
        normalized_name = self.validate_skill_name(name)
        # 标准 public 检查
        if (self._host_root / SkillCategory.PUBLIC.value / normalized_name / SKILL_MD_FILE).exists():
            return True
        # 全局 custom fallback 检查（legacy 技能对所有用户可见）
        if (self._global_custom_root / normalized_name / SKILL_MD_FILE).exists():
            return True
        return False

    def ensure_custom_skill_is_editable(self, name: str) -> None:
        """重写：优雅处理全局 custom fallback 技能。

        用户试图编辑/删除 legacy 全局 custom 技能（因 fallback 呈现为 LEGACY 的）时，
        告诉他们创建自己的版本，而非抛令人困惑的 FileNotFoundError。
        """
        if self.custom_skill_exists(name):
            return
        # 同时检查 public 与全局 custom fallback
        normalized_name = self.validate_skill_name(name)
        is_global_public = (self._host_root / SkillCategory.PUBLIC.value / normalized_name / SKILL_MD_FILE).exists()
        is_global_custom_fallback = (self._global_custom_root / normalized_name / SKILL_MD_FILE).exists()
        if is_global_public:
            raise ValueError(f"'{name}' is a built-in skill. Use the skill_manage tool to create your own version - it will shadow the built-in one.")
        if is_global_custom_fallback:
            raise ValueError(f"'{name}' is a legacy shared skill (not editable). To customise it, create your own version with the same name - it will shadow the shared one.")
        raise FileNotFoundError(f"Custom skill '{name}' not found.")

    def _iter_skill_files(self) -> Iterable[tuple[SkillCategory, Path, Path]]:
        # 1. public 技能：始终从全局根
        public_path = self._host_root / SkillCategory.PUBLIC.value
        if public_path.exists() and public_path.is_dir():
            for current_root, dir_names, file_names in os.walk(public_path, followlinks=True):
                dir_names[:] = sorted(name for name in dir_names if not name.startswith("."))
                if SKILL_MD_FILE not in file_names:
                    continue
                yield SkillCategory.PUBLIC, public_path, Path(current_root) / SKILL_MD_FILE

        # 2. custom 技能：优先用户级目录
        user_custom_exists = False
        user_custom_path = self._user_custom_root
        if user_custom_path.exists() and user_custom_path.is_dir():
            for current_root, dir_names, file_names in os.walk(user_custom_path, followlinks=True):
                dir_names[:] = sorted(name for name in dir_names if not name.startswith(".") and name != ".history")
                if SKILL_MD_FILE not in file_names:
                    continue
                user_custom_exists = True
                yield SkillCategory.CUSTOM, user_custom_path, Path(current_root) / SKILL_MD_FILE

        # 3. Fallback：用户无 custom 时，从全局 custom 加载为 LEGACY（只读），
        #    使 legacy 技能可见但不可被用户编辑/删除。LEGACY 挂载到 /mnt/skills/legacy/<name>/。
        if not user_custom_exists:
            global_custom_path = self._global_custom_root
            if global_custom_path.exists() and global_custom_path.is_dir():
                for current_root, dir_names, file_names in os.walk(global_custom_path, followlinks=True):
                    dir_names[:] = sorted(name for name in dir_names if not name.startswith(".") and name != ".history")
                    if SKILL_MD_FILE not in file_names:
                        continue
                    yield SkillCategory.LEGACY, global_custom_path, Path(current_root) / SKILL_MD_FILE

    # ------------------------------------------------------------------
    # 安装 - 重定向 custom_dir 到用户目录
    # ------------------------------------------------------------------

    async def ainstall_skill_from_archive(self, archive_path: str | Path) -> dict:
        from helix.skills.installer import _scan_skill_archive_contents_or_raise

        logger.info("Installing skill from %s for user %s", archive_path, self._user_id)
        path = Path(archive_path)
        custom_dir = self._user_custom_root

        custom_dir.mkdir(parents=True, exist_ok=True)

        # 每文件安全扫描是 async LLM 调用，必须在事件循环上；其周围的文件系统阶段跑在工作线程
        tmp = await asyncio.to_thread(tempfile.mkdtemp)
        try:
            skill_dir, skill_name, target = await asyncio.to_thread(self._prepare_skill_archive, path, Path(tmp), custom_dir, archive_path)

            await _scan_skill_archive_contents_or_raise(skill_dir, skill_name)

            await asyncio.to_thread(self._commit_skill_install, skill_dir, skill_name, custom_dir, target)
            logger.info("Skill %r installed to %s for user %s", skill_name, target, self._user_id)
        finally:
            try:
                await asyncio.wait_for(
                    asyncio.to_thread(self._cleanup_install_tmp, tmp),
                    timeout=5.0,
                )
            except TimeoutError:
                logger.warning("Timed out cleaning up skill install temp dir %s", tmp)

        return {
            "success": True,
            "skill_name": skill_name,
            "message": f"Skill '{skill_name}' installed successfully for user '{self._user_id}'",
        }

    # ------------------------------------------------------------------
    # 写 - 写前确保用户 custom 目录存在
    # ------------------------------------------------------------------

    def write_custom_skill(self, name: str, relative_path: str, content: str) -> None:
        # 确保用户 custom 目录存在
        self._user_custom_root.mkdir(parents=True, exist_ok=True)
        target = self.validate_relative_path(relative_path, self.get_custom_skill_dir(name))
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            delete=False,
            dir=str(target.parent),
        ) as tmp_file:
            tmp_file.write(content)
            tmp_path = Path(tmp_file.name)
        tmp_path.replace(target)
        make_skill_written_path_sandbox_readable(self.get_custom_skill_dir(name), target)

    # ------------------------------------------------------------------
    # 公开助手
    # ------------------------------------------------------------------

    @property
    def user_id(self) -> str:
        """本 storage scope 的 user ID。"""
        return self._user_id

    def get_user_custom_root(self) -> Path:
        """本用户 custom 技能根目录的宿主路径。"""
        return self._user_custom_root

    # ------------------------------------------------------------------
    # 路径校验 - 接纳 per-user custom 根与全局根
    # ------------------------------------------------------------------

    def validate_skill_file_path(self, skill_file: Path) -> Path:
        """接纳全局根或 per-user custom 根下的文件。

        custom 技能住在 _user_custom_root，它不是 _host_root 的子路径，
        所以默认实现的单根检查会拒绝它们。本重写允许两个根。
        """
        resolved_file = skill_file.resolve()
        for allowed_root in (self._host_root.resolve(), self._user_custom_root.resolve()):
            try:
                resolved_file.relative_to(allowed_root)
                return resolved_file
            except ValueError:
                continue
        raise ValueError(f"Resolved skill file {resolved_file} must stay within either the global skills root ({self._host_root.resolve()}) or the per-user custom root ({self._user_custom_root.resolve()}).")
```

## 6. 存储单例工厂（get_or_new_skill_storage / get_or_new_user_skill_storage）

```python
# core/helix/skills/storage/__init__.py
"""SkillStorage 单例 + 反射工厂。

镜像 helix/sandbox/sandbox_provider.py 的模式。
"""

from __future__ import annotations

import logging
import threading
from collections import OrderedDict

from helix.skills.storage.local_skill_storage import LocalSkillStorage
from helix.skills.storage.skill_storage import SkillStorage
from helix.skills.storage.user_scoped_skill_storage import UserScopedSkillStorage
from helix.skills.types import SkillCategory

logger = logging.getLogger(__name__)

_default_skill_storage: SkillStorage | None = None
_default_skill_storage_config: object | None = None  # 单例所基于的 AppConfig 身份
_skill_storage_lock = threading.Lock()

# per-user 存储实例缓存上限。真实部署单进程很少超过几个并发用户；
# 64 是宽裕上限，防无界内存增长。
_MAX_USER_SCOPED_STORAGES = 64

# per-user 技能存储缓存，双检锁防并发创建竞争。
# OrderedDict 使 LRU 驱逐能经 move_to_end + popitem(last=False) 移除最久未用项。
_user_scoped_storages: OrderedDict[str, UserScopedSkillStorage] = OrderedDict()
_user_scoped_storage_lock = threading.Lock()


def get_or_new_skill_storage(**kwargs) -> SkillStorage:
    """返回 SkillStorage 实例--新建或进程单例。

    新建（永不缓存）当：
    - 提供 skills_path--作为 host_path 覆盖（类仍经 config 解析）。
    - 提供 app_config--从 app_config.skills 构造，使 per-request config（如 Gateway Depends(get_config)）
      被尊重，不污染进程级单例。

    单例（首次调用创建，之后复用）当 skills_path 与 app_config 都不给--用 get_app_config() 解析活跃配置。

    本单例用于读 public 技能（全局，只读）。user-scoped custom 操作用 get_or_new_user_skill_storage。
    """
    global _default_skill_storage, _default_skill_storage_config

    from helix.config import get_app_config
    from helix.config.skills_config import SkillsConfig

    def _make_storage(skills_config: SkillsConfig, *, host_path: str | None = None, **kwargs) -> SkillStorage:
        from helix.reflection import resolve_class

        cls = resolve_class(skills_config.use, SkillStorage)
        return cls(
            host_path=host_path if host_path is not None else str(skills_config.get_skills_path()),
            container_path=skills_config.container_path,
            **kwargs,
        )

    skills_path = kwargs.pop("skills_path", None)
    app_config = kwargs.pop("app_config", None)

    if skills_path is not None:
        if app_config is not None:
            return _make_storage(app_config.skills, host_path=str(skills_path), **kwargs)
        # 无 app_config：用默认 SkillsConfig，永不需要读 config.yaml
        from helix.config.skills_config import SkillsConfig

        return _make_storage(SkillsConfig(), host_path=str(skills_path), **kwargs)

    if app_config is not None:
        return _make_storage(app_config.skills, **kwargs)

    # 单例被手动注入（如测试）且无 config 身份（_default_skill_storage_config is None）时，
    # 跳过 get_app_config() 以避免要求磁盘上有 config.yaml
    if _default_skill_storage is not None and _default_skill_storage_config is None:
        return _default_skill_storage

    app_config_now = get_app_config()

    # 锁内双检构建，使竞争的冷启动调用者只构造一个实例，
    # 且 reset_skill_storage() 不能从并发读下夺空全局。
    # 锁内构造--镜像 get_memory_storage() 而非 sandbox_provider 的构造外再丢弃败者--
    # 因为 SkillStorage 无 teardown hook，败者的孤儿实例无法被清理。
    with _skill_storage_lock:
        if _default_skill_storage is None or _default_skill_storage_config is not app_config_now:
            _default_skill_storage = _make_storage(app_config_now.skills, **kwargs)
            _default_skill_storage_config = app_config_now
        return _default_skill_storage


def get_or_new_user_skill_storage(user_id: str, **kwargs) -> SkillStorage:
    """返回 per-user SkillStorage 实例，用于 custom 技能隔离。

    用 UserScopedSkillStorage，重定向 custom 路径到 {base_dir}/users/{user_id}/skills/custom/，
    public 读取仍从全局根。

    user_id 经 make_safe_user_id 规范化，使外部身份（如含非 [A-Za-z0-9_-] 字符的 IM channel id）
    在到达 UserScopedSkillStorage 前被安全分桶（UserScopedSkillStorage 内部调 _validate_user_id）。

    实例按规范化 user_id 缓存，双检锁防并发创建竞争。缓存超 _MAX_USER_SCOPED_STORAGES 时，
    驱逐最久未访问项（真 LRU，非 FIFO）。
    """
    from helix.config.paths import make_safe_user_id

    safe_id = make_safe_user_id(user_id)

    # 始终持锁使 move_to_end 安全--使其为真 LRU 而非 FIFO。开销可忽略，dict op 快且每 agent 创建周期调一次
    with _user_scoped_storage_lock:
        cached = _user_scoped_storages.get(safe_id)
        if cached is not None:
            _user_scoped_storages.move_to_end(safe_id)
            return cached

        cached = UserScopedSkillStorage(safe_id, **kwargs)
        _user_scoped_storages[safe_id] = cached
        # 超上限驱逐最久未用项。当前 user_id 已移到末尾，popitem(last=False) 驱逐最老/最久未访问项
        while len(_user_scoped_storages) > _MAX_USER_SCOPED_STORAGES:
            evicted_key, evicted_val = _user_scoped_storages.popitem(last=False)
            logger.info("Evicted user-scoped skill storage for safe_id=%s (cache ceiling %d)", evicted_key, _MAX_USER_SCOPED_STORAGES)
        return cached


def user_should_see_legacy_skills(user_id: str, **kwargs) -> bool:
    """返回发现是否对该用户暴露任何 LEGACY 技能。

    沙箱挂载不得比技能发现更宽松。本助手集中化该契约，使 local/AIO/remote provider 都遵循同一可见性规则。
    """
    if kwargs:
        from helix.config.paths import make_safe_user_id

        storage = UserScopedSkillStorage(make_safe_user_id(user_id), **kwargs)
    else:
        storage = get_or_new_user_skill_storage(user_id)
    return any((skill.category.value if hasattr(skill.category, "value") else skill.category) == SkillCategory.LEGACY.value for skill in storage.load_skills(enabled_only=False))


def reset_skill_storage() -> None:
    """清所有缓存存储实例（测试与热重载场景用）。"""
    global _default_skill_storage, _default_skill_storage_config
    with _skill_storage_lock:
        _default_skill_storage = None
        _default_skill_storage_config = None
    with _user_scoped_storage_lock:
        _user_scoped_storages.clear()


def reset_user_skill_storage(user_id: str | None = None) -> None:
    """清特定用户的 per-user 存储缓存，或全部用户。

    user_id 经 make_safe_user_id 规范化，使缓存 key 与 get_or_new_user_skill_storage 用的一致。
    不规范化则 IM-channel user ID（如 feishu:xxx）无法清其过期缓存项。
    """
    from helix.config.paths import make_safe_user_id

    with _user_scoped_storage_lock:
        if user_id is not None:
            safe_id = make_safe_user_id(user_id)
            _user_scoped_storages.pop(safe_id, None)
        else:
            _user_scoped_storages.clear()


__all__ = [
    "LocalSkillStorage",
    "SkillStorage",
    "UserScopedSkillStorage",
    "get_or_new_skill_storage",
    "get_or_new_user_skill_storage",
    "user_should_see_legacy_skills",
    "reset_skill_storage",
    "reset_user_skill_storage",
]
```

## 7. 文件权限助手（沙箱可读不可写）

```python
# core/helix/skills/permissions.py
"""已安装技能树的文件系统权限助手。"""

import stat
from pathlib import Path


def make_skill_path_sandbox_readable(path: Path) -> None:
    """把单个路径设为沙箱可读：去 group/other 写位，目录 555、文件 444。符号链接不动。"""
    if path.is_symlink():
        return
    mode = stat.S_IMODE(path.stat().st_mode)
    without_sandbox_write = mode & ~(stat.S_IWGRP | stat.S_IWOTH)
    if path.is_dir():
        path.chmod(without_sandbox_write | 0o555)
    elif path.is_file():
        path.chmod(without_sandbox_write | 0o444)


def make_skill_tree_sandbox_readable(target: Path) -> None:
    """递归把整棵技能树设为沙箱可读。"""
    make_skill_path_sandbox_readable(target)
    for path in target.rglob("*"):
        make_skill_path_sandbox_readable(path)


def make_skill_written_path_sandbox_readable(skill_root: Path, target: Path) -> None:
    """写入新文件后，从 skill_root 到 target 路径上每层目录 + target 本身重应用沙箱可读权限。

    路径到编辑点同步规范化，使新增嵌套目录不在只读不变量上留洞。
    """
    resolved_root = skill_root.resolve()
    resolved_target = target.resolve()
    resolved_target.relative_to(resolved_root)

    make_skill_path_sandbox_readable(resolved_root)
    current = resolved_root
    for part in resolved_target.parent.relative_to(resolved_root).parts:
        current = current / part
        make_skill_path_sandbox_readable(current)
    make_skill_path_sandbox_readable(resolved_target)
```

## 8. SkillsConfig（配置）

```python
# core/helix/config/skills_config.py
import os
from pathlib import Path

from pydantic import BaseModel, Field

from helix.config.runtime_paths import project_root, resolve_path
from helix.constants import DEFAULT_SKILLS_CONTAINER_PATH


def _legacy_skills_candidates() -> tuple[Path, ...]:
    """返回源码树的 skills 位置（monorepo 兼容）。"""
    backend_dir = Path(__file__).resolve().parents[4]
    repo_root = backend_dir.parent
    return (repo_root / "skills",)


class SkillsConfig(BaseModel):
    """技能系统配置。"""

    use: str = Field(
        default="helix.skills.storage.local_skill_storage:LocalSkillStorage",
        description="SkillStorage 实现的类路径。",
    )
    path: str | None = Field(
        default=None,
        description=("技能目录路径。未指定时默认为 caller project root 下的 skills，monorepo 兼容回退到 repo-root 位置。"),
    )
    container_path: str = Field(
        default=DEFAULT_SKILLS_CONTAINER_PATH,
        description="沙箱容器内技能挂载路径",
    )
    deferred_discovery: bool = Field(
        default=False,
        description=("启用时，技能元数据不注入 system prompt。仅技能名出现在 <skill_index>，LLM 经 describe_skill 工具按需发现。"),
    )

    def get_skills_path(self) -> Path:
        """
        解析技能目录路径。

        解析顺序：
            1. 显式 path 字段
            2. HELIX_SKILLS_PATH 环境变量
            3. caller project root（project_root()）下的 skills
            4. monorepo 兼容的 repo-root 候选（_legacy_skills_candidates）

        当 (3) 与 (4) 都不存在时，返回 project-root 默认，使调用方仍能给出稳定的"无技能"位置而不抛。
        """
        if self.path:
            return resolve_path(self.path)
        if env_path := os.getenv("HELIX_SKILLS_PATH"):
            return resolve_path(env_path)

        project_default = project_root() / "skills"
        if project_default.is_dir():
            return project_default

        for candidate in _legacy_skills_candidates():
            if candidate.is_dir():
                return candidate

        return project_default

    def get_skill_container_path(self, skill_name: str, category: str = "public") -> str:
        """获取特定技能在容器内的全路径。"""
        return f"{self.container_path}/{category}/{skill_name}"
```

## 关联

- SKILL.md：[../SKILL.md](../SKILL.md)
- 发现 + 工具策略 + skill_manage 完整源码：[./discover-and-manage.md](./discover-and-manage.md)
- slash 激活 + secret 绑定完整源码：[./activation-and-whitelist.md](./activation-and-whitelist.md)
- 缓存 + skills_section 渲染 + 装配入口完整源码：[./cache-and-prompt-rendering.md](./cache-and-prompt-rendering.md)
- 关联 skill：[[system-prompt-template]]、[[tool-assembly-and-policy]]、[[multi-user-isolation]]
