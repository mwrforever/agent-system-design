# Activation & Secret Binding - 完整源码

> 本文件是 `skill-system-design` 的 **slash 激活 + secret 绑定层**完整源码：`slash.py`（严格 regex + reserved 解析）+ `SkillActivationMiddleware`（`/skill` 注入隐藏 HumanMessage + run 级 secret 绑定 + 审计记录）+ 中间件链位置。SKILL.md 只放设计架构思路与伪代码，完整源码以此文件为准。代码已按插件匿名化规则映射到自定结构；真实代码原注释保留以保真。

## 1. `/skill-name` slash 解析（严格 regex + reserved）

```python
# core/helix/skills/slash.py
from __future__ import annotations

import re
from dataclasses import dataclass

from helix.constants import DEFAULT_SKILLS_CONTAINER_PATH
from helix.skills.types import Skill

# composer 控制命令，拥有前导 slash，绝不当作 /skill 激活。
# 该集合与前端 slash.ts 镜像，由 contracts/slash_skill_contract.json 契约测试钉死，
# 单侧改 reserved 命令或语法会 fail CI。
RESERVED_SLASH_SKILL_NAMES = frozenset({"bootstrap", "goal", "help", "memory", "models", "new", "status"})
_SLASH_SKILL_RE = re.compile(r"^/([a-z0-9]+(?:-[a-z0-9]+)*)(?:\s+|$)")


@dataclass(frozen=True, slots=True)
class SlashSkillReference:
    """解析后的 slash-skill 命令：技能名 + 剩余任务文本。"""
    name: str
    remaining_text: str


@dataclass(frozen=True, slots=True)
class ResolvedSlashSkill:
    """slash-skill 激活解析结果（已对 enabled + 白名单校验）。"""
    skill: Skill
    remaining_text: str
    container_file_path: str


def parse_slash_skill_reference(text: str) -> SlashSkillReference | None:
    """解析严格 /skill-name task 语法，忽略 reserved 控制命令。前导空白不合规则返回 None。"""
    match = _SLASH_SKILL_RE.match(text)
    if not match:
        return None
    name = match.group(1)
    if name in RESERVED_SLASH_SKILL_NAMES:
        return None
    return SlashSkillReference(
        name=name,
        remaining_text=text[match.end() :].lstrip(),
    )


def resolve_slash_skill(
    text: str,
    skills: list[Skill],
    *,
    available_skills: set[str] | None = None,
    container_base_path: str = DEFAULT_SKILLS_CONTAINER_PATH,
) -> ResolvedSlashSkill | None:
    """把文本解析为 enabled + 白名单内的技能激活（找不到返回 None）。"""
    reference = parse_slash_skill_reference(text)
    if reference is None:
        return None
    if available_skills is not None and reference.name not in available_skills:
        return None

    skill = next((candidate for candidate in skills if candidate.name == reference.name and candidate.enabled), None)
    if skill is None:
        return None

    return ResolvedSlashSkill(
        skill=skill,
        remaining_text=reference.remaining_text,
        container_file_path=skill.get_container_file_path(container_base_path),
    )
```

## 2. SkillActivationMiddleware（完整：激活注入 + secret 绑定 + 审计）

```python
# core/helix/agents/middlewares/skill_activation_middleware.py
"""技能激活中间件：显式 slash + 上下文内 secret 绑定。"""

from __future__ import annotations

import asyncio
import hashlib
import html
import logging
import posixpath
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, override

from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelRequest, ModelResponse
from langchain_core.messages import AIMessage, HumanMessage

from helix.runtime.secret_context import (
    _SECRETS_BINDING_AUDIT_KEY,
    _SLASH_SECRET_SOURCE_KEY,
    ACTIVE_SECRETS_CONTEXT_KEY,
    extract_request_secrets,
)
from helix.skills.slash import parse_slash_skill_reference, resolve_slash_skill
from helix.skills.storage import get_or_new_skill_storage, get_or_new_user_skill_storage
from helix.skills.storage.skill_storage import SkillStorage
from helix.skills.types import SKILL_MD_FILE, SecretRequirement, Skill, SkillCategory
from helix.utils.messages import get_original_user_content_text

if TYPE_CHECKING:
    from helix.config.app_config import AppConfig

logger = logging.getLogger(__name__)

_SLASH_SKILL_ACTIVATION_KEY = "slash_skill_activation"
_SLASH_SKILL_ACTIVATION_TARGET_ID_KEY = "slash_skill_activation_target_id"
_SUMMARY_MESSAGE_NAME = "summary"

# _SECRETS_BINDING_AUDIT_KEY: 最后一次审计的绑定（仅技能名与 secret 名，绝不含值），
# 使未变更的绑定不被每 call 重复记录。
# _SLASH_SECRET_SOURCE_KEY: 最新 slash 激活作为 secret source，仅持被激活技能的规范容器路径
# （绝不持其声明的 secrets - 那些每 call 从 live registry 读，#3938）。注入集每 model call 重算，
# 但 slash 激活的技能必须在 run 余下部分保持绑定 - 模型的工具循环在单次激活调用后发很多 model call
# （#3861 语义）。两者都在 secret_context，由 REDACTED_CONTEXT_KEYS 一处覆盖。


@dataclass(frozen=True, slots=True)
class _Activation:
    skill_name: str
    category: str
    container_file_path: str
    skill_content: str
    content_hash: str
    remaining_text: str
    editable: bool
    required_secrets: tuple[SecretRequirement, ...] = ()


@dataclass(frozen=True, slots=True)
class _ActivationResolution:
    activation: _Activation | None = None
    failure_message: str | None = None


def is_slash_skill_activation_reminder(message: object) -> bool:
    """判断消息是否为隐藏的 slash-skill 激活上下文。"""
    return isinstance(message, HumanMessage) and bool(message.additional_kwargs.get(_SLASH_SKILL_ACTIVATION_KEY))


def _is_user_activation_target(message: object) -> bool:
    if not isinstance(message, HumanMessage):
        return False
    if message.name == _SUMMARY_MESSAGE_NAME:
        return False
    if message.additional_kwargs.get("hide_from_ui"):
        return False
    return True


class SkillActivationMiddleware(AgentMiddleware):
    """用户显式输入 /skill-name 时，注入完整 SKILL.md 内容。"""

    def __init__(
        self,
        *,
        available_skills: set[str] | None = None,
        app_config: AppConfig | None = None,
        user_id: str | None = None,
    ) -> None:
        super().__init__()
        self._available_skills = set(available_skills) if available_skills is not None else None
        self._app_config = app_config
        self._user_id = user_id

    def _storage(self) -> SkillStorage:
        if self._user_id is not None:
            return get_or_new_user_skill_storage(self._user_id, app_config=self._app_config)
        if self._app_config is not None:
            return get_or_new_skill_storage(app_config=self._app_config)
        return get_or_new_skill_storage()

    @staticmethod
    def _read_skill_content(skill_file: Path, skills_root: Path, *, storage: SkillStorage | None = None) -> str:
        if skill_file.name != SKILL_MD_FILE:
            raise ValueError(f"Expected {SKILL_MD_FILE}, got {skill_file.name}")
        # 用 storage 的路径校验（若有）- UserScopedSkillStorage 的 custom 在 per-user 目录，
        # 不是全局根的子路径，简单 relative_to 检查会拒绝它们。
        # storage 是 mock（如测试）无 validate_skill_file_path 时回退 relative_to 检查。
        if storage is not None and hasattr(storage, "validate_skill_file_path"):
            resolved_file = storage.validate_skill_file_path(skill_file)
        else:
            resolved_file = skill_file.resolve()
            resolved_root = skills_root.resolve()
            try:
                resolved_file.relative_to(resolved_root)
            except ValueError as exc:
                raise ValueError("Resolved skill file must stay within the configured skills root.") from exc
        if not resolved_file.is_file():
            raise FileNotFoundError(resolved_file)
        return resolved_file.read_text(encoding="utf-8")

    def _resolve_activation(self, text: str) -> _ActivationResolution | None:
        reference = parse_slash_skill_reference(text)
        if reference is None:
            return None

        storage = self._storage()
        skills = storage.load_skills(enabled_only=False)
        skill = next((candidate for candidate in skills if candidate.name == reference.name), None)
        if skill is None:
            return _ActivationResolution(failure_message=f"Skill `/{reference.name}` is not installed.")
        if not skill.enabled:
            return _ActivationResolution(failure_message=f"Skill `/{reference.name}` is installed but disabled. Enable it before using slash activation.")
        if self._available_skills is not None and reference.name not in self._available_skills:
            return _ActivationResolution(failure_message=f"Skill `/{reference.name}` is not available for this agent.")

        resolved = resolve_slash_skill(
            text,
            skills,
            available_skills=self._available_skills,
            container_base_path=storage.get_container_root(),
        )
        if resolved is None:
            return _ActivationResolution(failure_message=f"Skill `/{reference.name}` could not be resolved.")

        try:
            skill_content = self._read_skill_content(resolved.skill.skill_file, storage.get_skills_root_path(), storage=storage)
        except (OSError, ValueError):
            logger.exception("Failed to read slash-activated skill %s", resolved.skill.name)
            return _ActivationResolution(failure_message=f"Skill `/{reference.name}` could not be loaded safely. Please check the skill installation.")

        content_hash = hashlib.sha256(skill_content.encode("utf-8")).hexdigest()
        # CUSTOM 可编辑；PUBLIC 与 LEGACY 只读
        editable = resolved.skill.category == SkillCategory.CUSTOM
        return _ActivationResolution(
            activation=_Activation(
                skill_name=resolved.skill.name,
                category=str(resolved.skill.category),
                container_file_path=resolved.container_file_path,
                skill_content=skill_content,
                content_hash=content_hash,
                remaining_text=resolved.remaining_text,
                editable=editable,
                required_secrets=tuple(resolved.skill.required_secrets or ()),
            )
        )

    @staticmethod
    def _build_activation_reminder(activation: _Activation) -> str:
        user_request = activation.remaining_text or ("No additional task text was provided after the slash skill command. Ask the user what they want to do with this skill if the next step is unclear.")
        escaped_user_request = html.escape(user_request, quote=False)
        escaped_skill_content = html.escape(activation.skill_content, quote=False)
        escaped_skill_name = html.escape(activation.skill_name, quote=True)
        escaped_category = html.escape(activation.category, quote=True)
        escaped_path = html.escape(activation.container_file_path, quote=True)
        escaped_content_hash = html.escape(activation.content_hash, quote=True)
        editable_str = "true" if activation.editable else "false"
        return f"""<slash_skill_activation>
The user explicitly activated the `{activation.skill_name}` skill for this turn.
Treat the task text as:
<user_request>
{escaped_user_request}
</user_request>

Follow this skill before choosing a general workflow. Load supporting resources from the same skill directory only when needed.

<skill name="{escaped_skill_name}" category="{escaped_category}" path="{escaped_path}" sha256="{escaped_content_hash}" editable="{editable_str}">
<skill_content encoding="xml-escaped">
{escaped_skill_content}
</skill_content>
</skill>
</slash_skill_activation>"""

    @staticmethod
    def _has_existing_activation_for_target(messages: list, target_index: int, target: HumanMessage) -> bool:
        if target_index <= 0:
            return False

        if target.id:
            for previous in messages[:target_index]:
                if not is_slash_skill_activation_reminder(previous):
                    continue
                target_id = previous.additional_kwargs.get(_SLASH_SKILL_ACTIVATION_TARGET_ID_KEY)
                if target_id == target.id or previous.id == f"{target.id}__slash_activation":
                    return True

        previous = messages[target_index - 1]
        return is_slash_skill_activation_reminder(previous)

    def _find_activation_target(self, messages: list) -> tuple[int, HumanMessage, _ActivationResolution] | None:
        if not messages:
            return None

        target_index = next((idx for idx in range(len(messages) - 1, -1, -1) if _is_user_activation_target(messages[idx])), None)
        if target_index is None:
            return None

        target = messages[target_index]
        if target is None:
            return None
        if self._has_existing_activation_for_target(messages, target_index, target):
            return None

        content = get_original_user_content_text(target.content, target.additional_kwargs)
        resolution = self._resolve_activation(content)
        if resolution is None:
            return None
        return target_index, target, resolution

    @staticmethod
    def _record_activation(request: ModelRequest, activation: _Activation, *, hook: str) -> None:
        """把激活事件记入 run journal（audit channel: skill_activation）。"""
        runtime = getattr(request, "runtime", None)
        context = getattr(runtime, "context", None)
        journal = context.get("__run_journal") if isinstance(context, dict) else None
        if journal is None:
            return
        try:
            journal.record_middleware(
                "skill_activation",
                name="SkillActivationMiddleware",
                hook=hook,
                action="activate",
                changes={
                    "skill_name": activation.skill_name,
                    "category": activation.category,
                    "path": activation.container_file_path,
                    "content_hash": activation.content_hash,
                },
            )
        except Exception:
            logger.debug("Failed to record slash skill activation audit event", exc_info=True)

    def _prepare_model_request(self, request: ModelRequest, *, hook: str) -> tuple[ModelRequest | AIMessage | None, _Activation | None]:
        target_and_resolution = self._find_activation_target(list(request.messages))
        if target_and_resolution is None:
            return None, None

        target_index, target, resolution = target_and_resolution
        if resolution.failure_message:
            return AIMessage(content=resolution.failure_message), None

        activation = resolution.activation
        if activation is None:
            return None, None

        logger.info(
            "SkillActivationMiddleware: activating slash skill %s category=%s path=%s hash=%s",
            activation.skill_name,
            activation.category,
            activation.container_file_path,
            activation.content_hash,
        )
        self._record_activation(request, activation, hook=hook)
        activation_msg = self._make_activation_message(target, self._build_activation_reminder(activation))
        messages = list(request.messages)
        messages.insert(target_index, activation_msg)
        return request.override(messages=messages), activation

    def _handle_model_request(self, request: ModelRequest, *, hook: str) -> ModelRequest | AIMessage:
        prepared, activation = self._prepare_model_request(request, hook=hook)
        if isinstance(prepared, AIMessage):
            return prepared
        effective = prepared if prepared is not None else request
        self._resolve_secret_bindings(effective, activation, hook=hook)
        return effective

    def _resolve_secret_bindings(self, request: ModelRequest, activation: _Activation | None, *, hook: str) -> None:
        """重算 per-run secret 注入集（绑定点 A+，#3861/#3914）。

        每 model call union 的来源：

        - 本 run 最近一次 slash 激活（作为 source 持久化到 run context，使激活调用后的整个工具循环
          保持绑定 - 新 slash 激活替换它）。slash source 在激活时校验一次（enabled + 白名单检查
          在 _resolve_activation），故意不每 call 重校验：slash 是用户做的 run 级承诺，随 run 消亡；
        - 模型在 thread 早先加载的技能（ThreadState.skill_context），每 call 对 live registry 重校验：
          enabled、本 agent runtime 允许、未用 secrets-autonomous: false opt-out。slash 激活免 opt-out
          - 它是 opt-out 旨在保留的显式仪式路径。

        集每 call 重算并 REPLACE，故从 skill_context 驱逐的技能、或停止供值的 caller，下一 call 自动失绑定。
        注入值始终来自 caller 的 request（context.secrets）- 永非宿主环境（env_policy.build_sandbox_env
        在注入前 scrub）- 故技能永不能收割宿主平台凭证。Secret 值永不记日志；audit journal 仅记名。
        """
        runtime = getattr(request, "runtime", None)
        context = getattr(runtime, "context", None)
        if not isinstance(context, dict):
            return

        # slash source 仅记被激活技能的规范容器路径 - 绝不记其声明的 secrets。
        # 两 source 读时都按 path 对 live registry 技能解析，故 caller 伪造的 source
        # （context 是 caller 可合并的）永不能注入真实、enabled、白名单内技能未声明的 secrets（#3938）。
        if activation is not None:
            context[_SLASH_SECRET_SOURCE_KEY] = {"path": activation.container_file_path}

        request_secrets = extract_request_secrets(context)
        sources: list[tuple[str, tuple[SecretRequirement, ...]]] = []
        if request_secrets:
            registry = self._load_skill_registry_by_path()
            if registry is not None:
                # slash source：免 secrets-autonomous opt-out（显式仪式），但仍 enabled + 白名单检查
                slash_source = context.get(_SLASH_SECRET_SOURCE_KEY)
                slash_path = slash_source.get("path") if isinstance(slash_source, dict) else None
                slash_skill = self._resolve_registry_skill(registry, slash_path, require_autonomous=False)
                if slash_skill is not None:
                    sources.append((slash_skill.name, tuple(slash_skill.required_secrets)))
                sources.extend(self._in_context_secret_sources(request, registry))

        injected: dict[str, str] = {}
        bound_skills: set[str] = set()
        missing: dict[str, list[str]] = {}
        for skill_name, requirements in sources:
            for req in requirements:
                if req.name in request_secrets:
                    injected[req.name] = request_secrets[req.name]
                    bound_skills.add(skill_name)
                elif not req.optional:
                    missing.setdefault(skill_name, []).append(req.name)

        if injected:
            context[ACTIVE_SECRETS_CONTEXT_KEY] = injected
        else:
            context.pop(ACTIVE_SECRETS_CONTEXT_KEY, None)

        audit_state = {
            "skills": sorted(bound_skills),
            "secrets": sorted(injected),
            "missing": {name: sorted(values) for name, values in sorted(missing.items())},
        }
        previous = context.get(_SECRETS_BINDING_AUDIT_KEY)
        if previous == audit_state:
            return  # 未变更，不重复记录
        if previous is None and not injected and not missing:
            return
        context[_SECRETS_BINDING_AUDIT_KEY] = audit_state
        for skill_name, names in sorted(missing.items()):
            logger.warning(
                "Skill %s is active but required secrets are missing from the request context: %s",
                skill_name,
                ", ".join(names),
            )
        self._record_secret_binding(context, audit_state, hook=hook)

    def _load_skill_registry_by_path(self) -> dict[str, Skill] | None:
        """按规范容器文件路径 key 加载 live 技能 registry。

        每 call 故意重载（不缓存）：load_skills 重读 extensions_config 的 enabled 状态，
        使 operator 禁用技能在下一 model call 即撤销其 secret 绑定。按文件 mtime 缓存会错过
        enable/disable toggle（不动 SKILL.md）并在禁用后继续注入 - 用速度换即时撤销安全属性。
        代价是有门的：唯一 caller 仅在 caller 供 secrets 时跑。

        路径规范化，使非规范 container_path 配置（如尾斜杠）仍匹配 skill_context 捕获的规范路径（#3938）。
        registry 加载失败返回 None - slash 与 in-context 两 source 该 call 都不绑（fail closed）。
        这是刻意的可用性换安全权衡：run 中瞬态 registry 读失败使该 call 丢注入，而非信任过期 caller 数据。
        """
        try:
            storage = self._storage()
            skills = storage.load_skills(enabled_only=False)
            container_root = storage.get_container_root()
        except Exception:
            logger.exception("Failed to load skills while resolving secret bindings")
            return None
        return {posixpath.normpath(skill.get_container_file_path(container_root)): skill for skill in skills}

    def _resolve_registry_skill(self, registry: dict[str, Skill], path: object, *, require_autonomous: bool) -> Skill | None:
        """把容器路径解析为可绑 secret 的 live registry 技能，或 None。

        严格按规范容器文件路径匹配 - 绝不按名。按名回退会是 confused deputy：Helix 允许 custom 技能
        shadow 同名 public/legacy（load_skills 按名去重，custom 胜），故引用 public/foo 可能绑 custom foo
        的 secrets。不解析的路径 simply 不绑（安全方向），也对 caller 伪造路径 fail closed（#3938）。

        门控：技能必须 enabled、声明 secrets、在本 agent 白名单内。require_autonomous 额外强制
        secrets-autonomous opt-out 用于 in-context 路径；slash 路径传 False，因显式激活正是 opt-out
        旨在保留的仪式。
        """
        if not isinstance(path, str) or not path:
            return None
        skill = registry.get(posixpath.normpath(path))
        if skill is None or not skill.enabled or not skill.required_secrets:
            return None
        if require_autonomous and not skill.secrets_autonomous:
            return None
        if self._available_skills is not None and skill.name not in self._available_skills:
            return None
        return skill

    def _in_context_secret_sources(self, request: ModelRequest, registry: dict[str, Skill]) -> list[tuple[str, tuple[SecretRequirement, ...]]]:
        """把 ThreadState.skill_context 条目映射为声明 secret 的 source。

        条目是模型在本 thread 实际加载的技能引用。每条对 live registry 重校验，使被禁用、卸载、
        opt-out 或移出 agent 白名单的技能立即停止绑定。
        """
        state = getattr(request, "state", None) or {}
        try:
            entries = state.get("skill_context") or []
        except AttributeError:
            return []

        sources: list[tuple[str, tuple[SecretRequirement, ...]]] = []
        seen: set[str] = set()
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            skill = self._resolve_registry_skill(registry, entry.get("path"), require_autonomous=True)
            if skill is None or skill.name in seen:
                continue
            seen.add(skill.name)
            sources.append((skill.name, tuple(skill.required_secrets)))
        return sources

    @staticmethod
    def _record_secret_binding(context: dict, audit_state: dict, *, hook: str) -> None:
        """把 secret 绑定事件记入 run journal（audit channel: skill_secrets）。"""
        journal = context.get("__run_journal")
        if journal is None:
            return
        try:
            journal.record_middleware(
                "skill_secrets",
                name="SkillActivationMiddleware",
                hook=hook,
                action="bind_secrets",
                changes=audit_state,
            )
        except Exception:
            logger.debug("Failed to record skill secret binding audit event", exc_info=True)

    @staticmethod
    def _make_activation_message(target: HumanMessage, activation_content: str) -> HumanMessage:
        stable_id = target.id or str(uuid.uuid4())
        additional_kwargs = {
            "hide_from_ui": True,
            _SLASH_SKILL_ACTIVATION_KEY: True,
        }
        if target.id:
            additional_kwargs[_SLASH_SKILL_ACTIVATION_TARGET_ID_KEY] = target.id
        return HumanMessage(
            content=activation_content,
            id=f"{stable_id}__slash_activation",
            additional_kwargs=additional_kwargs,
        )

    @override
    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelResponse | AIMessage:
        prepared = self._handle_model_request(request, hook="wrap_model_call")
        if isinstance(prepared, AIMessage):
            return prepared
        return handler(prepared)

    @override
    async def awrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], Awaitable[ModelResponse]],
    ) -> ModelResponse | AIMessage:
        prepared = await asyncio.to_thread(self._handle_model_request, request, hook="awrap_model_call")
        if isinstance(prepared, AIMessage):
            return prepared
        return await handler(prepared)
```

## 3. 中间件链位置

`SkillActivationMiddleware` 是 lead agent 中间件链的**第 14 项**（见 [[middleware-chain-design]]），在 `build_middlewares`（`core/helix/agents/lead/agent.py`）中续装：

```python
# core/helix/agents/lead/agent.py（build_middlewares 技能激活段）
middlewares = build_lead_runtime_middlewares(app_config=resolved_app_config, lazy_init=True)  # 1-12
middlewares.append(DynamicContextMiddleware(agent_name=agent_name, app_config=resolved_app_config))      # 13
middlewares.append(SkillActivationMiddleware(available_skills=available_skills, user_id=user_id))        # 14
middlewares.append(DurableContextMiddleware(...))                                                         # 15
# ...
```

它实现 `wrap_model_call` / `awrap_model_call`（非 `before_model`），因为激活需在**最终 model call 载荷**上插入消息，且要读 `request.messages` 找最新 user 消息。`awrap_model_call` 把解析（文件读 + hash + escape）offload 到工作线程，消息改写在事件循环。

## 关联

- SKILL.md：[../SKILL.md](../SKILL.md)
- 协议 + 存储 + per-user 完整源码：[./skill-protocol-and-storage.md](./skill-protocol-and-storage.md)
- 发现 + 工具策略 + skill_manage 完整源码：[./discover-and-manage.md](./discover-and-manage.md)
- 缓存 + skills_section 渲染 + 装配入口完整源码：[./cache-and-prompt-rendering.md](./cache-and-prompt-rendering.md)
- 关联 skill：[[middleware-chain-design]]（第 14 项位置）、[[system-prompt-template]]（缓存 + skills_section）、[[e2e-request-lifecycle]]（⑤中间件位置）
