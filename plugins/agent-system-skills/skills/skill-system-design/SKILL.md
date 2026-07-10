---
name: skill-system-design
description: 设计 agent 的"技能系统"--磁盘 SKILL.md 协议（YAML frontmatter + 6 段骨架 + references/ 渐进加载）、per-user 技能存储（PUBLIC/CUSTOM/LEGACY 三层 + 隔离）、异步加载缓存（启动预热 + 写后失效）、/skill-name 显式激活（中间件注入隐藏 HumanMessage）、allowed-tools 白名单收缩、skill_manage 自演化工具、describe_skill 延迟发现。让用户/社区/AI 自身写 Markdown 就能扩展 agent 行为而不改代码。当你想加自定义工作流、排查技能不加载/不激活、调白名单、做技能自演化时调用本 skill。
---

## 何时用

- 想让用户/社区/AI 自身写 Markdown 就能"教会"agent 新工作流（不改代码）
- 内置（PUBLIC 只读）+ 用户自定义（CUSTOM per-user 读写）+ 迁移期（LEGACY 只读）三层共存
- 想支持"用户输入 `/skill-name` 显式触发"某个技能
- 想限制每个技能能调的工具集（最小权限白名单）
- 想让 agent 在完成任务后自己创建/修补技能（自演化）
- 排查"技能没加载"、"`/skill` 没激活"、"白名单收掉了想用的工具"、"技能串到别的用户"

## 设计方案（为什么这么设计）

### 核心矛盾：可扩展性 vs prefix-cache vs 安全隔离

技能系统要同时满足三个互相拉扯的目标：

1. **可扩展**：用户、社区、甚至 AI 自身都能新增工作流，且**不改代码**--技能就是磁盘上的 Markdown 目录。
2. **prefix-cache 友好**：技能内容（工作流正文）**不能进静态 system prompt**。100 个技能的全量正文会撑爆 prompt，且每新增一个技能都让所有会话的 prefix cache miss。
3. **安全隔离**：自定义技能是用户私有数据，必须 per-user 隔离；技能里可能声明所需 secrets，绑定时机要受控；AI 自己写技能要过安全扫描。

**解法：协议 + 分层存储 + 缓存 + 两条激活路径 + 白名单 + 自演化工具**，六者各司其职，在端到端链路 ④建图 -> ⑤中间件 -> ⑥执行 三跳上落地（见 [[e2e-request-lifecycle]]）。

### 关键不变量

1. **frontmatter 是"是什么"，sidecar 是"开没开"**：SKILL.md 的 YAML frontmatter 是技能身份的唯一事实源（name/description/allowed-tools/required-secrets）；enabled 状态**不写进** frontmatter，而是存 sidecar（PUBLIC 全局 `extensions_config.json`，CUSTOM/LEGACY per-user `_skill_states.json`）。git 拉新代码不强制开启新技能，不同 deployment 的开关互不干扰。
2. **技能正文永不进静态 prompt**：模型先看**索引**（`<skill_index>` 仅 name，或 `<available_skills>` 含 description+location），按需 `read_file` 全文。`/skill` 显式激活也走**隐藏 HumanMessage** 注入，不碰 SystemMessage、不碰静态 prompt -> prefix cache 持续命中（与 [[system-prompt-template]] 双通道一致）。
3. **CUSTOM 技能 per-user 隔离**：`UserScopedSkillStorage` 把 custom 写到 `users/{user_id}/skills/custom/`，public 读全局。两个用户各建同名 custom 技能互不可见、互不可改。enabled 状态也 per-user，防跨用户串扰。
4. **allowed-tools 非对称收窄**：无任何技能声明 `allowed-tools` -> 全量工具（legacy 兼容）；一旦**任一**技能声明（哪怕 `[]`），所有声明技能的并集成为白名单，未声明的技能贡献空集。这让 `allowed-tools: []`（"此技能不需工具"）有意义，不必强制重写所有旧技能。
5. **`/skill` 激活是 run 级承诺**：用户显式 `/skill-name` 后，该技能对整个 run 的后续所有 model call 生效（不只当前 turn）；中间件在**最新一条** user 消息前注入一次，幂等（target_id 检查防重复注入）。

### 1. SKILL.md 协议：frontmatter + 6 段骨架 + references/ 渐进加载

一个技能 = 一个目录 + `SKILL.md` + 可选支撑树（`references/`、`templates/`、`scripts/`、`assets/`）。`SKILL.md` 开头是 YAML frontmatter（`---` 围栏），解析器用单条 regex 提取，`yaml.safe_load` 解析：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | string | 是 | hyphen-case，小写字母/数字/连字符，≤64 字符 |
| `description` | string | 是 | 触发条件 + 核心要点（模型靠它判断是否加载） |
| `license` | string | 否 | 空白归一为 `None` |
| `allowed-tools` | list[str] | 否 | `None`（不限制）≠ `[]`（显式不要工具） |
| `required-secrets` | list | 否 | 每项是 string 或 `{name, optional}` |
| `secrets-autonomous` | bool | 否 | 默认 true；false 表示 secrets 仅 `/skill` 显式激活时绑定 |

**渐进加载两条路径**（由 `skills.deferred_discovery` 配置切换）：

```python
# 伪代码：两条渐进加载路径
if deferred_discovery:  # 延迟发现路径
    prompt += <skill_index>仅技能名（逗号分隔）  # 100 个名字 vs 100 段 description，省 token
    模型用 describe_skill(name) 工具按需取元数据 -> 再 read_file(SKILL.md) 全文
else:  # 全量元数据路径（默认）
    prompt += <available_skills>每个 enabled 技能的 name+description+location
    prompt += <disabled_skills>明确禁止使用的技能清单
    模型看 description 即可判断匹配 -> read_file(SKILL.md) 全文
# 为何不只走延迟发现：技能少时全量路径更直接（少一次工具调用）；技能多时延迟才划算。配置开关让部署方按规模选。
```

**6 段骨架**（`何时用 / 设计方案 / 实现索引 / 反模式 / 落地参考 / 进一步阅读`）是本插件 **organ skill** 的内部约定（见 [../../CONVENTIONS.md](../../CONVENTIONS.md) §4），外部社区技能不强制；但 frontmatter + Markdown 正文 + `references/` 渐进加载是所有技能共享的协议。

### 2. per-user 技能存储：三层 category + 隔离

`SkillCategory` 三层：

- **PUBLIC**：仓库自带，全局只读，`<root>/public/<name>/SKILL.md`。enabled 状态在全局 `extensions_config.json`。
- **CUSTOM**：用户自建，per-user 读写，`users/{user_id}/skills/custom/<name>/SKILL.md`。enabled 状态在 per-user `_skill_states.json`。
- **LEGACY**：迁移期的全局 custom 技能。当某用户**还没有**任何 per-user custom 技能时，全局 `skills/custom/` 的技能作为 LEGACY 对该用户可见（只读）；一旦用户建了第一个 custom 技能，LEGACY 消失（shadow-mount 语义：用户目录遮蔽全局目录）。

**为何 per-user**：自定义技能是用户私有工作流（可能含业务逻辑、专有提示），跨用户可见是数据泄露；且 `skill_manage` 允许 AI 写技能，不隔离则一个用户的 AI 能改另一个用户的技能。`UserScopedSkillStorage` 继承 `LocalSkillStorage`（复用 public 读取与模板方法流），仅重定向 custom 路径 + 重载 enabled 状态合并。

`SkillStorage` 是**抽象基类 + 模板方法**：子类实现少量原子操作（`_iter_skill_files` / `read_custom_skill` / `write_custom_skill` / `delete_custom_skill` / `ainstall_skill_from_archive` 等），基类提供最终流程（`load_skills` 发现->合并 enabled->过滤->排序；路径校验；frontmatter 校验；history 序列化）。这让 per-user 与全局两种后端共享协议级逻辑。

### 3. 异步加载缓存：启动预热 + 写后失效

`load_skills()` 是**扫盘 + YAML 解析 + sidecar 合并**，阻塞 IO，不能每 run 同步跑（饿死事件循环）。缓存分三层：

```python
# 伪代码：三层缓存 + 失效
# 1) enabled-skills 列表缓存：get_enabled_skills_for_config(app_config, user_id)
#    按 (id(app_config), user_id) 缓存技能列表，LRU 256 项。冷 miss 时不阻塞，返回 []，后台线程预热好后下一次调用命中。
# 2) 后台预热线程：prime_enabled_skills_cache() / warm_enabled_skills_cache(timeout=5s)
#    启动 daemon 线程跑 _load_enabled_skills_sync()，用版本号 + threading.Event 协调：
#    失效时版本号 +1，线程发现版本号变了就重跑，保证缓存最终收敛到最新版本。
# 3) prompt 段 LRU：_get_cached_skills_prompt_section 按 skill_signature 缓存渲染后的 <skill_system> XML，maxsize=32。

# 失效时机：
skill_manage 写技能后 -> refresh_user_skills_system_prompt_cache_async(user_id) -> invalidate_user_skill_cache(user_id)
    # 只清该用户的缓存项 + prompt 段 LRU，不影响其他用户
安装/卸载/全局开关 -> clear_skills_system_prompt_cache() -> _invalidate_enabled_skills_cache()
    # 清全部缓存 + 版本号 +1 + 起后台重载
```

这套缓存归 `core/helix/agents/lead/prompt.py`（见 [[system-prompt-template]] 的 enabled-skills 缓存段），本 skill 只定义存储与发现；缓存的"入口"在 prompt 模块，因为它紧邻 `apply_prompt_template` 的调用点。

### 4. `/skill-name` 显式激活 vs 隐式匹配

两条激活路径并存：

- **隐式匹配**（模型自主）：模型看 prompt 里的 `<skill_index>` / `<available_skills>`，自己判断哪个技能匹配任务，调 `describe_skill`（延迟路径）或直接 `read_file`（全量路径）加载全文，按技能工作流执行（[[e2e-request-lifecycle]] ⑥执行）。
- **显式激活**（用户触发）：用户消息以 `/skill-name` 开头，`SkillActivationMiddleware`（中间件链第 14 项，见 [[middleware-chain-design]]）在 `wrap_model_call` 检测到，把 SKILL.md **全文**注入为一条隐藏 `HumanMessage`（`hide_from_ui=True`），插在目标 user 消息前。

```python
# 伪代码：显式激活注入流程（完整源码见 references/code/activation-and-whitelist.md）
def awrap_model_call(request, handler):
    # 1. 从后往前找最新一条可见 user 消息（跳过 summary + hide_from_ui）
    target = _find_activation_target(request.messages)  # 幂等：前一条已是同 target_id 激活提醒则跳过
    if target is None: return handler(request)
    # 2. 解析 /skill-name -> 区分 未安装/已禁用/不在白名单 三种失败 -> 返 AIMessage failure_message
    resolution = _resolve_activation(target.content)
    if resolution.failure_message: return AIMessage(resolution.failure_message)
    # 3. 读 SKILL.md 全文 + sha256 hash + html.escape -> 包进 <slash_skill_activation> XML
    activation_msg = HumanMessage(_build_activation_reminder(activation), hide_from_ui=True,
                                  id=f"{target.id}__slash_activation")  # 后缀防递归 swap
    request.messages.insert(target_index, activation_msg)  # 插在 target user 消息前
    # 4. run 级 secret 绑定（slash source 持久化到 run context，每 call 重算绑定集）
    _resolve_secret_bindings(request, activation)
    return handler(request.override(messages=...))
```

**为何显式走 HumanMessage 而非 SystemMessage**：保持 [[system-prompt-template]] 的角色分离--框架权威数据走 SystemMessage，用户可影响数据走 HumanMessage。技能正文是"用户选择的工作流"，属用户可影响范畴；且不碰静态 prompt，prefix cache 不受影响。技能正文 XML-escape 后包在 `<slash_skill_activation>` 标签里，防注入。

**严格 regex + reserved 过滤**：`^/([a-z0-9]+(?:-[a-z0-9]+)*)(?:\s+|$)`--无前导空白（防复制粘贴误触发），只认 hyphen-case。`RESERVED_SLASH_SKILL_NAMES = {bootstrap, goal, help, memory, models, new, status}` 是 composer 控制命令，绝不当技能名；该集合与前端 `slash.ts` 镜像，由 `contracts/slash_skill_contract.json` 契约测试钉死。

**幂等 + 最新消息 + run 级承诺**：中间件从后往前找最新一条可见 user 消息，检查其前一条是否已是同 target_id 的激活提醒，是则跳过（同一 turn 不重复注入）。激活是 **run 级承诺**：注入一次后，该技能的 `required_secrets` 对 run 内后续所有 model call 持续绑定（slash source 存在 run context，每 call 重算绑定集，按 path 匹配 live registry 防 confused deputy）。

### 5. allowed-tools 白名单收缩

`filter_tools_by_skill_allowed_tools(tools, skills, always_allowed=SKILL_LOADING_TOOL_NAMES)` 在 ④建图装配工具时跑：

```python
# 伪代码：非对称白名单收窄（完整源码见 references/code/discover-and-manage.md §2）
def allowed_tool_names_for_skills(skills) -> set[str] | None:
    if not skills: return None  # legacy 全量
    allowed, has_explicit = set(), False
    for skill in skills:
        if skill.allowed_tools is None: continue       # 未声明：跳过（贡献空集）
        has_explicit = True
        allowed.update(skill.allowed_tools)            # 声明 [] -> 贡献空集但置 has_explicit
    return allowed if has_explicit else None           # 全未声明 -> None（全量）

def filter_tools_by_skill_allowed_tools(tools, skills, always_allowed):
    allowed = allowed_tool_names_for_skills(skills)
    if allowed is None: return tools                    # legacy 兼容：不收窄
    return [t for t in tools if t.name in allowed | always_allowed]  # always_allowed 含 read_file
```

`always_allowed` 含 `read_file`（技能加载自身全文需要它，不能被白名单收掉）。未知工具名静默丢弃（与 [[tool-assembly-and-policy]] 工具目录对齐）。

**非对称语义的设计意图**：如果"任一技能声明就收窄、未声明的贡献全量"，那一个声明 `allowed-tools: []` 的技能会收掉别人的一切；如果"必须所有技能都声明才收窄"，则一个旧技能不声明就永远不生效。当前设计（声明即收窄、未声明贡献空）让 `[]` = "此技能不需要工具"有意义，且旧技能不声明只是不贡献工具，不破坏他人的限制。

### 6. skill_manage 自演化

`skill_manage` 工具（`action: create|patch|edit|delete|write_file|remove_file`）让 AI 在完成任务后把学到的工作流沉淀为技能：

```python
# 伪代码：skill_manage 写流程（完整源码见 references/code/discover-and-manage.md §4）
async def _skill_manage_impl(runtime, action, name, content=None, path=None, find=None, replace=None):
    name = SkillStorage.validate_skill_name(name)            # hyphen-case 校验
    user_id = resolve_runtime_user_id(runtime)               # per-user 隔离的 user_id
    lock = _get_lock(user_id, name)                          # (user_id, skill_name) 粒度 asyncio.Lock 防并发写
    storage = get_or_new_user_skill_storage(user_id)         # per-user 存储
    async with lock:
        # create/edit/write_file: validate_skill_markdown_content(name, content)  # 临时目录解析 frontmatter，确认 name 一致
        # 安全扫描双层：_scan_static_candidate_or_raise（临时副本静态扫描）+ _scan_or_raise（LLM 扫描）
        #   scripts/ 下按 executable 更严（必须 allow，warn 不够）；block 即拒绝写
        # 原子写：write_custom_skill -> 临时文件 + os.replace（读者永不观察半截文件）+ chmod 沙箱可读（555 目录/444 文件）
        # append-only 历史：append_history(name, {action, prev_content, new_content, scanner 决策})
        # 写后失效：refresh_user_skills_system_prompt_cache_async(user_id) -> 下一 run 看到新技能
    # 技能不是 deliverable：prompt 明令禁止把 SKILL.md 写到 /mnt/user-data/outputs（那是交付物目录）
```

### 7. 在端到端链路中的位置

```
④建图  _make_lead_agent:
        ├─ get_enabled_skills_for_config(app_config, user_id)  ← 命中缓存或后台预热
        ├─ filter_tools_by_skill_allowed_tools(raw_tools, skills, always_allowed={read_file})  ← 白名单收窄
        ├─ build_skill_search_setup(skills, enabled=deferred_discovery)  ← 产出 describe_skill 工具 + skill_names
        └─ apply_prompt_template(skill_names=skill_setup.skill_names)  ← 渲染 <skill_index> 或 <available_skills> 进 {skills_section}
⑤中间件 SkillActivationMiddleware（第14项）wrap_model_call:
        └─ 最新 user 消息以 /skill-name 开头 -> 注入 SKILL.md 全文为隐藏 HumanMessage（run 级承诺）
⑥执行   模型 loop:
        ├─ 隐式: describe_skill(name) -> read_file(SKILL.md) -> 按工作流调工具（受白名单约束）
        ├─ 显式: 已注入 -> 直接按工作流调工具
        └─ 自演化: skill_manage(action="create"|"patch", ...) -> 写后失效缓存 -> 下一 run 可见
```

反向引用：[[e2e-request-lifecycle]] ⑥执行（"技能作为模型可读工作流"）、④建图（白名单收窄 + skills_section）。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/skills/types.py` | `Skill` dataclass + `SkillCategory` 枚举 + `SecretRequirement` | [skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md) §1 |
| `core/helix/skills/parser.py` | `parse_skill_file`：frontmatter regex + `yaml.safe_load` + allowed-tools/secrets 解析 + `_format_yaml_error` | [skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md) §2 |
| `core/helix/skills/storage/skill_storage.py` | `SkillStorage` 抽象基类 + 模板方法流（`load_skills` / 路径校验 / history） | [skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md) §3 |
| `core/helix/skills/storage/local_skill_storage.py` | `LocalSkillStorage`：本地文件系统实现（public + global custom + 安装管线） | [skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md) §4 |
| `core/helix/skills/storage/user_scoped_skill_storage.py` | `UserScopedSkillStorage`：per-user custom 隔离 + LEGACY fallback + per-user enabled 状态 | [skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md) §5 |
| `core/helix/skills/storage/__init__.py` | `get_or_new_skill_storage` / `get_or_new_user_skill_storage`（单例 + LRU 缓存） | [skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md) §6 |
| `core/helix/skills/permissions.py` | `make_skill_written_path_sandbox_readable`：沙箱可读权限（555/444） | [skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md) §7 |
| `core/helix/config/skills_config.py` | `SkillsConfig`：`deferred_discovery` / `container_path` / `path` / `use` | [skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md) §8 |
| `core/helix/skills/catalog.py` | `SkillCatalog`：不可变可搜索目录（select:/+/regex 三种查询） | [discover-and-manage.md](./references/code/discover-and-manage.md) §1 |
| `core/helix/skills/tool_policy.py` | `filter_tools_by_skill_allowed_tools`：非对称白名单收窄 + `SKILL_LOADING_TOOL_NAMES` | [discover-and-manage.md](./references/code/discover-and-manage.md) §2 |
| `core/helix/skills/describe.py` | `describe_skill` 工具 + `build_skill_search_setup` + `get_skill_index_prompt_section`（延迟 `<skill_index>`） | [discover-and-manage.md](./references/code/discover-and-manage.md) §3 |
| `core/helix/tools/skill_manage_tool.py` | `skill_manage` 工具：create/patch/edit/delete/write_file/remove_file + 双层安全扫描 | [discover-and-manage.md](./references/code/discover-and-manage.md) §4 |
| `core/helix/skills/slash.py` | `parse_slash_skill_reference` + `resolve_slash_skill`：严格 slash 解析 + reserved 过滤 | [activation-and-whitelist.md](./references/code/activation-and-whitelist.md) §1 |
| `core/helix/agents/middlewares/skill_activation_middleware.py` | `SkillActivationMiddleware`：`/skill` 注入 + run 级 secret 绑定 + 审计 | [activation-and-whitelist.md](./references/code/activation-and-whitelist.md) §2 |
| `core/helix/agents/lead/prompt.py`（技能相关段） | enabled-skills 缓存 + `get_skills_prompt_section`（全量段）+ 自演化文案 + 失效入口 | [cache-and-prompt-rendering.md](./references/code/cache-and-prompt-rendering.md) §1-§3 |
| `core/helix/agents/lead/agent.py`（`_make_lead_agent`） | ④建图装配串联：加载技能 -> 白名单收窄 -> describe_skill -> skills_section | [cache-and-prompt-rendering.md](./references/code/cache-and-prompt-rendering.md) §4 |

### 模块入口与索引

四个 `references/code/` 模块文件各自自洽（SKILL.md 不再内联完整源码）：

- **[skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md)** -- 协议 + 存储层。`parse_skill_file` 入口：regex 提取 `---` 围栏 -> `yaml.safe_load` -> 校验 name/description 非空 -> 解析 allowed-tools（`None`≠`[]`）/ required-secrets（string 或 `{name,optional}`）/ secrets-autonomous（默认 true，畸形 fail closed）-> 返回 `Skill(enabled=True)`（实际状态由 `load_skills` 合并 sidecar）。`SkillStorage.load_skills` 模板方法：`_iter_skill_files` 发现 -> `ExtensionsConfig.is_skill_enabled` 合并 -> 可选过滤 -> 按 name 排序。`UserScopedSkillStorage` 重写 `_iter_skill_files`（public 全局 + custom per-user + LEGACY fallback）与 `load_skills`（per-user `_skill_states.json` 覆盖 CUSTOM/LEGACY enabled）。

- **[discover-and-manage.md](./references/code/discover-and-manage.md)** -- 发现 + 工具策略 + 管理。`SkillCatalog.search` 三种查询：`select:` 精确 / `+required rank` 必含 / free-text regex（名匹配分高于描述，MAX_RESULTS=5）。`build_skill_search_setup`：`enabled` 且有技能时构造 `describe_skill` 闭包工具 + `skill_names` frozenset。`skill_manage` 6 动作共享 `_scan_or_raise`（静态+LLM 双层，executable 要求 allow）+ `_scan_static_candidate_or_raise`（临时副本预检）+ `(user_id, name)` 粒度锁 + 写后 `refresh_user_skills_system_prompt_cache_async`。

- **[activation-and-whitelist.md](./references/code/activation-and-whitelist.md)** -- slash 激活 + secret 绑定。`SkillActivationMiddleware.awrap_model_call`：`_find_activation_target`（最新可见 user 消息 + 幂等检查）-> `_resolve_activation`（区分未安装/已禁用/不在白名单）-> `_build_activation_reminder`（`html.escape` 全字段包 `<slash_skill_activation>` XML）-> 插入隐藏 HumanMessage（`id={target}__slash_activation`）-> `_resolve_secret_bindings`（slash source + in-context source 每 call 重算，按 `posixpath.normpath` 匹配 live registry 防 confused deputy #3938，registry 每 call 重载防 enable/disable 后仍注入）。中间件第 14 项，实现 `wrap_model_call`/`awrap_model_call`（解析 offload 到线程）。

- **[cache-and-prompt-rendering.md](./references/code/cache-and-prompt-rendering.md)** -- 缓存 + skills_section 渲染 + 装配入口。`get_enabled_skills_for_config`：`(id(app_config), user_id)` LRU 256，miss 不阻塞返 `[]` + 后台预热。`_refresh_enabled_skills_cache_worker`：版本号 + `threading.Event` 协调，失效期间收到新 invalidation 则循环重算收敛到最新。`_get_cached_skills_prompt_section`：按 skill_signature LRU 32 缓存渲染后 XML。`get_skills_prompt_section`：有 `skill_names` 走延迟 `<skill_index>`，无则全量 `<available_skills>` + `<disabled_skills>`。`_make_lead_agent`：加载技能 -> `filter_tools_by_skill_allowed_tools`（always_allowed 含 `read_file`）-> `build_skill_search_setup` -> `apply_prompt_template(skill_names=...)`。

## 反模式与陷阱

- ❌ **`/skill-name` 解析允许前导空白** -> 用户复制粘贴带空格无意触发激活。修复：regex `^/` 锚定开头，无 `\s*`。
- ❌ **把 SKILL.md 内容注入到静态 system prompt 模板** -> prefix cache 永久 miss + 模型把用户输入当指令（注入风险）。修复：走隐藏 HumanMessage（显式激活）或 read_file（隐式加载），都不碰静态 prompt。
- ❌ **enabled 状态写入 SKILL.md frontmatter** -> 不同 deployment 状态不一致；git 拉新代码强制开启新技能。修复：enabled 存 sidecar（PUBLIC 全局 `extensions_config.json`，CUSTOM/LEGACY per-user `_skill_states.json`），frontmatter 只记身份。
- ❌ **安装/写技能时不做安全扫描** -> 恶意 `.skill` 携带 `Ignore all previous instructions...` 或恶意 `scripts/`。修复：静态 + LLM 双层扫描，executable 要求 `allow`，`block` 拒绝写。
- ❌ **`load_skills` 同步阻塞事件循环** -> ASGI handler 抖动、SSE 心跳饿死。修复：后台线程预热 + 缓存，请求路径只读缓存（miss 返回 `[]` 不阻塞）。
- ❌ **per-user custom 技能存全局目录** -> 两用户同名技能互相可见/可改，数据泄露。修复：`UserScopedSkillStorage` 重定向 custom 到 `users/{user_id}/skills/custom/`，enabled 状态 per-user。
- ❌ **`allowed-tools` 对称语义（未声明=全量或必须全声明）** -> `[]` 失去"不需要工具"语义，或一个旧技能卡死白名单。修复：非对称--任一声明即收窄，未声明贡献空集。
- ❌ **slash 激活每 turn 重复注入** -> 历史堆出 N 条激活提醒。修复：`_has_existing_activation_for_target` 按 target_id 幂等检查。
- ❌ **secret 绑定按 skill name 匹配** -> confused deputy：custom `foo` shadow public `foo`，引用 public/foo 会绑 custom foo 的 secret。修复：按 normalized container file path 匹配 live registry（#3938）。
- ❌ **secret 绑定结果缓存** -> operator 禁用技能后下一 call 仍注入（enable/disable 不改 SKILL.md mtime）。修复：`_load_skill_registry_by_path` 每 call 重载（仅在 caller 供 secrets 时跑，代价可控）。
- ❌ **`skill_manage` 写后不清缓存** -> 下一 run 看不到新技能。修复：每个写动作调 `refresh_user_skills_system_prompt_cache_async(user_id)`。
- ❌ **把 SKILL.md 写到 `/mnt/user-data/outputs`** -> 技能被当交付物，丢失且不入技能目录。修复：prompt 明令禁止，技能只能由 `skill_manage` 存 per-user 目录。
- ❌ **`_skill_states.json` 非原子写** -> crash/磁盘满 mid-write 留截断或空文件，`_read_skill_states` 返回 `{}` 静默重新启用用户已禁用的技能。修复：同目录临时文件 + `Path.replace`。
- ✅ **SKILL.md 注入为隐藏 HumanMessage 而非 SystemMessage** --保持角色分离（框架权威 vs 用户可影响），与 [[system-prompt-template]] 双通道一致。
- ✅ **Slash 严格 regex + reserved 显式过滤 + 前后端契约测试** --防控制命令与技能名碰撞。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `skills.deferred_discovery` | app config | true=延迟发现（`<skill_index>` + describe_skill）；false=全量元数据（`<available_skills>`） |
| `skills.container_path` | app config | 沙箱挂载根，默认 `/mnt/skills` |
| `skills.path` / `HELIX_SKILLS_PATH` | app config / env | 宿主技能目录（public + global custom） |
| `skill_evolution.enabled` | app config | 是否装 `skill_manage` 工具 + 渲染自演化文案 |
| `_ENABLED_SKILLS_BY_CONFIG_CACHE_MAXSIZE` | 常量（256） | per-(config,user) 缓存上限，超出 LRU 驱逐 |
| `_MAX_USER_SCOPED_STORAGES` | 常量（64） | per-user 存储实例缓存上限 |
| `available_skills` | agent config | agent 级技能白名单（None=全部） |

**关键日志串**

- `SkillActivationMiddleware: activating slash skill %s category=%s path=%s hash=%s` - ⑤ 显式激活生效
- `Skill %s is active but required secrets are missing from the request context: %s` - secret 绑定缺值（warn）
- `Skill %s declared empty allowed-tools` - 白名单收窄时某技能声明 `[]`
- `Failed to load enabled skills for prompt injection` - 后台预热异常（不致命，回退 `[]`）
- `Timed out waiting %.1fs for enabled skills cache warm-up` - 启动预热超时（5s）
- `Installing skill from %s for user %s` - per-user 安装
- `Skill %r installed to %s for user %s` - 安装完成
- `Evicted user-scoped skill storage for safe_id=%s (cache ceiling %d)` - per-user 存储 LRU 驱逐

**调试入口**

| 现象 | 看哪里 |
|---|---|
| 技能没进 prompt | `get_enabled_skills_for_config` 是否命中缓存；`load_skills(enabled_only=True)` 是否返回空；`available_skills` 白名单是否过滤掉 |
| `/skill` 没激活 | `parse_slash_skill_reference` 是否返回 None（前导空白/reserved）；`_resolve_activation` 的 failure_message（未安装/已禁用/不在白名单）；`_has_existing_activation_for_target` 是否误判已注入 |
| 白名单收掉了想用的工具 | `allowed_tool_names_for_skills` 是否有技能声明了 `allowed-tools`；`always_allowed` 是否含 `read_file`；该工具名是否在并集里 |
| 自定义技能串到别的用户 | `get_or_new_user_skill_storage(user_id)` 的 user_id 是否正确（`resolve_runtime_user_id`）；`_user_custom_root` 是否指向对的目录 |
| `skill_manage` 写后下一 run 看不到 | `refresh_user_skills_system_prompt_cache_async(user_id)` 是否调用；`invalidate_user_skill_cache` 是否清了对应 user_id 的 key |
| secret 没绑定 | `_load_skill_registry_by_path` 是否每 call 重载；`_resolve_registry_skill` 是否按 path 匹配；`secrets_autonomous` 是否 false（in-context 路径被 opt-out） |

**自测方向**

- **frontmatter 解析**：合法/缺字段/畸形 YAML/`allowed-tools` 非 list/`required-secrets` 畸形 entry，断言分别返回 Skill / None / None / ValueError。
- **per-user 隔离**：两用户各建同名 custom 技能，断言互不可见、互不可改；一用户禁用不影响另一用户。
- **LEGACY fallback**：用户无 custom 时全局 custom 作 LEGACY 可见；建第一个 custom 后 LEGACY 消失。
- **白名单非对称**：无声明->全量；一个声明 `[]`、一个声明 `["bash"]`->并集 `{bash}` + `read_file`；全不声明->全量。
- **slash 激活幂等**：同一 turn 两次 `wrap_model_call`，断言只注入一条激活提醒。
- **slash 失败语义**：未安装/已禁用/不在白名单分别返回不同 `AIMessage` failure_message。
- **缓存失效**：`skill_manage(create)` 后，`get_enabled_skills_for_config` 对该 user_id 返回新技能；其他 user_id 不受影响。
- **延迟发现**：`deferred_discovery=true` 时 prompt 含 `<skill_index>` 仅名字；`describe_skill` 返回元数据含 location。
- **secret 按 path 绑定**：custom `foo` shadow public `foo`，slash 激活 public/foo 路径，断言不绑 custom foo 的 secret（confused deputy 防护）。
- **安全扫描**：SKILL.md 含 prompt 注入 payload，断言 `create` 被 block；`scripts/` 下非 allow，断言 `write_file` 拒绝。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 协议 + 存储 + per-user 完整源码：[references/code/skill-protocol-and-storage.md](./references/code/skill-protocol-and-storage.md)
- 发现 + 工具策略 + skill_manage 完整源码：[references/code/discover-and-manage.md](./references/code/discover-and-manage.md)
- slash 激活 + secret 绑定完整源码：[references/code/activation-and-whitelist.md](./references/code/activation-and-whitelist.md)
- 缓存 + skills_section 渲染 + 装配入口完整源码：[references/code/cache-and-prompt-rendering.md](./references/code/cache-and-prompt-rendering.md)
- 关联 skill：[[system-prompt-template]]（skills_section 槽位 + enabled-skills 缓存）、[[tool-assembly-and-policy]]（白名单接入装配链）、[[middleware-chain-design]]（SkillActivationMiddleware 第 14 项）、[[multi-user-isolation]]（per-user 目录）、[[e2e-request-lifecycle]]（④建图 + ⑤中间件 + ⑥执行位置）
