# tool-assembly-and-policy · 白名单 + reducer + config schema 完整源码

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。本文件收录 skill 白名单收缩（第 6 节）、promotion 持久化 reducer、config schema、skill `allowed-tools` frontmatter 形态--把"工具集被什么约束"的全貌收敛在一处。

## 1. promotion 持久化 reducer（merge_promoted）

延迟工具的提升状态（哪些延迟工具已经被 `tool_search` 拉过 schema）持久化在 `ThreadState.promoted` 通道，靠 `merge_promoted` reducer 合并。reducer 按 `catalog_hash` 作用域--hash 变了 wholesale replace，防漂移（见 SKILL.md 设计方案段）。

```python
# core/helix/agents/thread_state.py（节选：PromotedTools + merge_promoted）
from typing import Annotated, TypedDict


class PromotedTools(TypedDict):
    """延迟工具的提升状态（持久化在 ThreadState.promoted 通道）。

    catalog_hash 作用域：catalog 漂移后 reducer 丢弃旧 names。
    """
    catalog_hash: str
    names: list[str]


def merge_promoted(existing: PromotedTools | None, new: PromotedTools | None) -> PromotedTools | None:
    """延迟工具提升的 reducer，按 catalog hash 作用域。

    - new None/empty -> 保留 existing（节点没动 promotion）。
    - catalog_hash 变了 -> wholesale replace，丢弃旧 names（防止持久化的裸 name 在 catalog 漂移后暴露另一个工具）。
    - 同 catalog_hash -> 并集 names，去重，保序。
    """
    if not new:
        return existing
    if existing is None or existing.get("catalog_hash") != new["catalog_hash"]:
        return {
            "catalog_hash": new["catalog_hash"],
            "names": list(dict.fromkeys(new["names"])),
        }
    return {
        "catalog_hash": existing["catalog_hash"],
        "names": list(dict.fromkeys(existing["names"] + new["names"])),
    }
```

在 ThreadState 通道声明（见 [[thread-state-and-reducers]]）：

```python
# core/helix/agents/thread_state.py（节选：通道声明）
class ThreadState(AgentState):
    # ... 其他通道 ...
    # promoted: 延迟工具提升状态，catalog_hash 作用域。
    # 不走 Last-Write-Wins：merge_promoted 做并集 + 漂移保护。
    promoted: Annotated[PromotedTools | None, merge_promoted]
    # ...
```

## 2. tool_search 开关（ToolSearchConfig）

```python
# core/helix/config/tool_search_config.py
"""tool_search（延迟工具装载）的配置。"""

from pydantic import BaseModel, Field


class ToolSearchConfig(BaseModel):
    """tool_search（延迟工具装载）的配置。

    开启时，MCP 工具不直接装入 agent 上下文，而是在 system prompt 里按 name 列出，
    运行时经 tool_search 工具发现。
    """

    enabled: bool = Field(
        default=False,
        description="Defer tools and enable tool_search",
    )


# 模块级缓存（AppConfig 加载时由 load_tool_search_config_from_dict 刷新）
_tool_search_config: ToolSearchConfig | None = None


def get_tool_search_config() -> ToolSearchConfig:
    """取 tool search 配置，未加载时返回默认实例。"""
    global _tool_search_config
    if _tool_search_config is None:
        _tool_search_config = ToolSearchConfig()
    return _tool_search_config


def load_tool_search_config_from_dict(data: dict) -> ToolSearchConfig:
    """从 dict 加载 tool search 配置（AppConfig 加载时调）。"""
    global _tool_search_config
    _tool_search_config = ToolSearchConfig.model_validate(data)
    return _tool_search_config
```

AppConfig 集成点：

```python
# core/helix/config/app_config.py（节选：集成点）
from helix.config.tool_search_config import ToolSearchConfig, load_tool_search_config_from_dict

class AppConfig(BaseModel):
    # ...
    # tool_search: 延迟工具装载开关。默认 ToolSearchConfig(enabled=False)。
    tool_search: ToolSearchConfig = Field(default_factory=ToolSearchConfig,
                                          description="Tool search / deferred loading configuration")
    # ...

    @classmethod
    def from_file(cls, path):
        # ... 解析 config.yaml ...
        # 把加载到的 dict 喂给 module 级缓存（get_tool_search_config 读它）
        load_tool_search_config_from_dict(config.tool_search.model_dump())
        return config
```

## 3. 工具配置 schema（ToolConfig / ToolGroupConfig）

```python
# core/helix/config/tool_config.py
from pydantic import BaseModel, ConfigDict, Field


class ToolGroupConfig(BaseModel):
    """config.yaml -> tool_groups[*] 的 schema：一个工具组的声明。"""

    name: str = Field(..., description="Unique name for the tool group")
    model_config = ConfigDict(extra="allow")


class ToolConfig(BaseModel):
    """config.yaml -> tools[*] 的 schema：一个工具的声明。

    use 字段形如 "helix.sandbox.tools:bash_tool"，由 resolve_variable(cfg.use, BaseTool) 反射加载。
    group 配合 agent 的 tool_groups 分组过滤（agent 级声明式收缩）。
    extra='allow' 让具体工具的自定义参数（max_results / base_url / api_key 等）原样留存，
    由具体工具实现自行读取。
    """

    name: str = Field(..., description="Unique name for the tool")
    group: str = Field(..., description="Group name for the tool")
    use: str = Field(
        ...,
        description="Variable name of the tool provider(e.g. helix.sandbox.tools:bash_tool)",
    )
    model_config = ConfigDict(extra="allow")
```

`extra="allow"` 的意义：`max_results` / `base_url` / `api_key` 这类 provider 专属参数直接挂在 ToolConfig 上，无需改 schema；具体工具实现按需读取自己的字段。`$VAR` 形式的值在加载时由 config 层统一解析为环境变量值。

AppConfig 持有：

```python
# core/helix/config/app_config.py（节选：tools / tool_groups 字段）
class AppConfig(BaseModel):
    # tool_groups: 可用工具组（声明式，agent 用 tool_groups 引用）
    tool_groups: list[ToolGroupConfig] = Field(default_factory=list, description="Available tool groups")
    # tools: 工具声明（反射加载）
    tools: list[ToolConfig] = Field(default_factory=list)
    # ...
```

## 4. config.yaml `tools` / `tool_groups` 真实示例

```yaml
# config.example.yaml（节选）

# 声明工具组（agent 的 tool_groups 按这些 name 引用）
tool_groups:
  - name: web
  - name: file:read
  - name: file:write
  - name: bash

tools:
  # config-defined 工具：反射加载 use 字段
  - name: web_search
    group: web                                          # 归属组（配合 agent tool_groups 过滤）
    use: helix.community.ddg_search.tools:web_search_tool
    max_results: 5                                      # provider 专属参数（extra='allow' 留存）
    # backend: auto
    # region: wt-wt

  - name: web_fetch
    group: web
    use: helix.community.jina_ai.tools:web_fetch_tool

  # bash / read_file / write_file / str_replace 由沙箱提供，通过 use 反射加载
  # （见 [[sandbox-tools-and-safety]]）

# tool_search 开关：开启后 MCP 工具延迟，模型按需 tool_search promote
tool_search:
  enabled: false
```

自定义 agent 用 `tool_groups` 收缩（per-agent config.yaml）：

```yaml
# 用户的自定义 agent config.yaml（节选）
name: research-bot
description: 只做 web 研究，不碰文件写入
model: null
tool_groups: [web, file:read]    # 只装载这两个组的 config 工具（+ builtin 不受影响）
skills: [web-research]
```

## 5. skill `allowed-tools` frontmatter 形态

skill 在 `SKILL.md` frontmatter 声明白名单（见 [[skill-system-design]]）：

```yaml
# skills/public/some-skill/SKILL.md frontmatter
---
name: some-skill
description: 一个示例 skill
license: MIT
allowed-tools:        # 字符串列表（或 {name, optional} 映射的 required-secrets，那是另一字段）
  - web_search        # 只允许这些工具；未列的一律剥离
  - web_fetch
  - read_file         # read_file 即使没列也永远放行（SKILL_LOADING_TOOL_NAMES）
  - present_files
---

# skill 正文...
```

parser 解析为 `Skill.allowed_tools: tuple[str, ...] | None`（`None` 表示未声明、不参与收缩）：

```python
# core/helix/skills/types.py（节选：Skill dataclass）
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path


@dataclass(frozen=True)
class Skill:
    """一个 skill 的元数据 + 文件路径。"""

    name: str
    description: str
    license: str | None
    skill_dir: Path
    skill_file: Path
    relative_path: Path
    category: SkillCategory  # 'public' / 'custom' / 'legacy'
    allowed_tools: tuple[str, ...] | None = None   # 白名单；None = 不参与收缩（legacy allow-all）
    enabled: bool = False
    required_secrets: tuple[SecretRequirement, ...] = field(default_factory=tuple)
    secrets_autonomous: bool = True
```

收缩语义（`filter_tools_by_skill_allowed_tools`，完整实现见本文 §6）：

| 场景 | 行为 |
|---|---|
| 全部 skill `allowed_tools=None` | 不收缩（legacy allow-all，向后兼容） |
| 任一 skill 声明了 `allowed-tools` | 激活收缩：取**并集**（非交集） |
| 未声明的 legacy skill 与已声明共存 | legacy 不贡献工具，也不禁用他人显式限制 |
| `allowed-tools: []`（空） | 该 skill 声明"我不要任何工具"，但与其它 skill 的声明并集后可能仍有工具 |
| `read_file` / 框架常驻 | 永远放行（`SKILL_LOADING_TOOL_NAMES`），否则 skill 激活后无法加载自身 SKILL.md |

## 6. skill 白名单收缩（filter_tools_by_skill_allowed_tools）

```python
# core/helix/skills/tool_policy.py
import logging
from typing import Protocol

from helix.skills.types import Skill

logger = logging.getLogger(__name__)


class NamedTool(Protocol):
    name: str


# 框架常驻工具：白名单收缩时永远放行。
# read_file 是加载 SKILL.md 正文必备，否则 skill 激活后自相矛盾。
SKILL_LOADING_TOOL_NAMES = frozenset({"read_file"})


def allowed_tool_names_for_skills(skills: list[Skill]) -> set[str] | None:
    """返回显式声明的 skill allowed-tools 的并集。

    None 表示 legacy allow-all 行为：仅当没有任何 skill 声明 allowed-tools 时返回。
    一旦有 skill 声明该字段，未声明的 legacy skill 不贡献工具，也不禁用他人的显式限制。
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
    """按 skill allowed-tools 收缩工具集（取并集，非交集）。

    全部 skill 均未声明 allowed-tools -> 不收缩（向后兼容 legacy allow-all）。
    """
    allowed = allowed_tool_names_for_skills(skills)
    if allowed is None:
        return tools

    allowed_with_framework_tools = allowed | set(always_allowed_tool_names)
    return [tool for tool in tools if tool.name in allowed_with_framework_tools]
```

## 7. 调用约束（filter -> assemble 顺序）

装配主体的两个后处理阶段有严格顺序约束（违反会引发真实 bug）：

```
raw_tools = get_available_tools(groups, model_name, subagent_enabled, app_config)
  │
  ├─ filtered = filter_tools_by_skill_allowed_tools(raw_tools + extra_tools, skills,
  │                                                  always_allowed_tool_names=SKILL_LOADING_TOOL_NAMES)
  │     # 白名单收缩（并集 + 框架常驻）。必须在 assemble_deferred_tools 之前：
  │     # 否则被策略禁的工具会进 deferred catalog，tool_search 能 promote 它们。
  │
  └─ final_tools, deferred_setup = assemble_deferred_tools(filtered, enabled=app_config.tool_search.enabled)
        # deferred 切分（fail-closed）。必须在白名单之后：
        # catalog 只含 policy 通过的 MCP 工具。
```

两个顺序约束互锁：

- **filter 先，assemble 后**：catalog 永不暴露 agent 不被允许的工具（`assemble_deferred_tools` 文档强约束 "Call AFTER tool-policy filtering"）。
- **assemble fail-closed**：检测到"启用 + MCP 存活 + 无 deferred 集"抛 `RuntimeError`，宁可硬错也不裸绑 schema--这是所有 agent-build 路径（lead / 嵌入式 client / subagent）共享的保证。

子代理路径同样遵守（见 [[subagent-delegation]]）：

```python
# core/helix/subagents/executor.py（节选：_build_initial_state 内的装配顺序）
from helix.tools.builtins.tool_search import assemble_deferred_tools, get_deferred_tools_prompt_section

# 1. 加载 skill（白名单来源）
skills = await self._load_skills()
# 2. 白名单收缩（filter 先）
filtered_tools = self._apply_skill_allowed_tools(skills)
# 3. deferred 切分（assemble 后；fail-closed，与 lead 同一保证）
enabled = (self.app_config or get_app_config()).tool_search.enabled
final_tools, deferred_setup = assemble_deferred_tools(filtered_tools, enabled=enabled)
# 4. 渲染 <available-deferred-tools>（与 deferred_setup.deferred_names 同源）
deferred_section = get_deferred_tools_prompt_section(deferred_names=deferred_setup.deferred_names)
# 5. 喂给 _create_agent，构造 DeferredToolFilterMiddleware（catalog_hash 同源）
```

子代理的 `task` 工具本身被排除在白名单外（子代理不传 `task`，防无限嵌套委派）；子代理每次 run 拿到全新 `ThreadState`，promotion 隔离 per-run。
