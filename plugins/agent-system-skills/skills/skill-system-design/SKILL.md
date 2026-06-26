---
name: skill-system-design
description: 设计 agent 的 "skill 协议" ——磁盘 SKILL.md 文件、异步加载缓存、/skill-name 显式激活、allowed-tools 白名单收窄。让用户/社区/AI 自身可以扩展 agent 行为而不改代码。
---

## 何时用

- 想让用户/社区写 Markdown 就能"教会"agent 新工作流（不改代码）
- 内置 + 用户自定义两个层级共存（公共 vs 私有）
- 想支持"用户输入 `/skill-name` 显式触发"
- 想限制每个 skill 能调的工具集（最小权限）

## 设计思想

1. **skill = 目录 + SKILL.md**：YAML frontmatter（`name` / `description` / `allowed-tools` / `license` / `version`）+ Markdown 工作流。文件路径就是"何时用 / 怎么做"。
2. **两层目录**：`skills/public/` 仓库自带（公共、只读）+ `skills/custom/` 用户安装的（gitignore）。
3. **enabled 与发现分离**：发现 = 扫盘解析；启用状态在另一份 `extensions_config.json`。这样 git 拉新代码不强制开启新 skill。
4. **异步加载 + 缓存 + 失效**：用 `asyncio.to_thread` 加载，避免阻塞 event loop；后台线程预热缓存；`PUT /api/skills` 或 `POST /install` 触发 `clear_skills_system_prompt_cache()`。
5. **`/skill-name` 显式激活**：用 regex 严格匹配，跳过 reserved 命令（`/new` `/help` 等），中间件**只在最新一条 user 消息上**注入 SKILL.md 全文（隐藏 HumanMessage），仅当 turn 生效。
6. **`allowed-tools` 白名单**：每个 skill 可声明它需要的工具；agent 装配时取并集后**收窄**整体工具集（[[tool-assembly-and-policy]]）。

## 实现模板

### 解析

```python
@dataclass
class Skill:
    name: str
    description: str
    license: str | None
    skill_dir: Path
    skill_file: Path
    relative_path: Path
    category: Literal["public", "custom"]
    allowed_tools: list[str] | None = None
    enabled: bool = False

    def get_container_file_path(self, base="/mnt/skills") -> str:
        return f"{base}/{self.category}/{self.relative_path.as_posix()}/SKILL.md"


def parse_skill_file(path: Path, category: str) -> Skill | None:
    """SKILL.md = `---\\n<yaml>\\n---\\n<markdown>`."""
    text = path.read_text(encoding="utf-8")
    m = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    if not m: return None
    meta = yaml.safe_load(m.group(1)) or {}
    if "name" not in meta or "description" not in meta: return None
    return Skill(
        name=meta["name"], description=meta["description"],
        license=meta.get("license"),
        skill_dir=path.parent, skill_file=path,
        relative_path=path.parent.relative_to(_root_for(category)),
        category=category, allowed_tools=parse_allowed_tools(meta.get("allowed-tools")),
    )
```

### Slash 解析

```python
_SLASH_RE = re.compile(r"^/([a-z0-9]+(?:-[a-z0-9]+)*)(?:\s+|$)")
RESERVED = frozenset({"new", "help", "memory", "models", "status", "bootstrap"})

def parse_slash_skill(text: str):
    """严格匹配 /skill-name；保留命令返回 None."""
    m = _SLASH_RE.match(text)
    if not m: return None
    name = m.group(1)
    if name in RESERVED: return None
    return SlashRef(name=name, remaining_text=text[m.end():].lstrip())
```

### 激活中间件

```python
class SkillActivationMiddleware(AgentMiddleware):
    """检测最近一条 user 消息是否以 /skill-name 开头，注入 SKILL.md 隐藏 HumanMessage."""
    def __init__(self, *, available_skills=None, app_config=None):
        self.available = set(available_skills) if available_skills is not None else None

    async def abefore_model(self, state, runtime):
        last_user = _last_real_user_message(state["messages"])
        if last_user is None: return None
        if last_user.additional_kwargs.get("slash_skill_activation_target_id"):
            return None       # 已注入过

        ref = parse_slash_skill(_text_of(last_user))
        if ref is None: return None
        if self.available is not None and ref.name not in self.available: return None

        skills = await asyncio.to_thread(get_or_new_skill_storage().load_skills,
                                          enabled_only=True)
        skill = next((s for s in skills if s.name == ref.name), None)
        if skill is None: return None

        content = await asyncio.to_thread(skill.skill_file.read_text, encoding="utf-8")
        hidden = HumanMessage(
            content=f"<system-reminder>The user explicitly invoked `/{ref.name}`. "
                    f"Follow this skill precisely.\n\n<skill name=\"{ref.name}\">\n"
                    f"{content}\n</skill></system-reminder>",
            additional_kwargs={
                "hide_from_ui": True,
                "slash_skill_activation": True,
                "slash_skill_activation_target_id": last_user.id,
                "skill_content_hash": hashlib.sha1(content.encode()).hexdigest()[:12],
            },
        )
        return {"messages": _insert_before(state["messages"], last_user.id, hidden)}
```

### 工具白名单收窄

```python
def filter_tools_by_skill_allowed_tools(tools, skills):
    declared = [s.allowed_tools for s in skills if s.allowed_tools is not None]
    if not declared: return tools
    allowed = set().union(*declared) | _ALWAYS_AVAILABLE
    return [t for t in tools if t.name in allowed]
```

### 启用 / 安装 API

```python
@router.put("/{name}")
async def update_skill(name: str, body: SkillUpdateRequest):
    update_extensions_config(skills={name: {"enabled": body.enabled}})
    clear_skills_system_prompt_cache()   # ⭐ 触发后台重新加载
    return {"name": name, "enabled": body.enabled}


@router.post("/install")
async def install_skill(file: UploadFile):
    """.skill 压缩包解压到 skills/custom/<name>/，默认 disabled."""
    path = save_upload_to_tmp(file)
    security_scan(path)                  # 静态扫描可疑 prompt 注入
    name = extract_skill_archive(path, dest=Path("skills/custom"))
    set_skill_enabled(name, False)
    clear_skills_system_prompt_cache()
    return {"name": name, "enabled": False}
```

## 反模式

- ❌ `/skill-name` 解析允许前导空白 → 用户复制粘贴时无意触发
- ❌ 把 SKILL.md 内容注入到 system prompt 模板 → prefix cache miss + 模型把用户输入当指令（注入风险）
- ❌ enabled 状态写入 SKILL.md frontmatter → 用户跑不同 deployment 时状态不一致
- ❌ 安装时不做安全扫描 → 恶意 .skill 携带 `Ignore all previous instructions...`
- ❌ 加载阻塞 event loop → ASGI 抖动
- ✅ SKILL.md 注入为**隐藏 HumanMessage** 而非 SystemMessage——保持「系统/用户」角色分离的安全模型
- ✅ Slash 严格 regex；reserved 命令显式过滤

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[tool-assembly-and-policy]] [[system-prompt-template]] [[middleware-chain-design]]
