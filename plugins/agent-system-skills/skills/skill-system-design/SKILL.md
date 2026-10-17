---
name: skill-system-design
description: Agent 技能系统全套：SKILL.md 解析与 frontmatter 校验（allowed-tools/required-secrets）、public/custom/managed 三级存储与 per-user 隔离、三级投影（public→user→thread 原子换目录 + manifest 签名校验）、zip 安装安全（防 zip-slip/符号链接 + LLM 内容扫描 + 静态扫描门禁）、斜杠激活与激活策略中间件（allowed-tools 运行时执行）、describe_skill 检索工具与意图排序目录、技能演化（LLM 自改）、skillscan 自动蒸馏流水线、技能包评审四件套契约。当要实现 Claude Code 式技能系统、技能市场/安装/审计时使用。
---

# 技能系统设计

## 何时用

- 实现 SKILL.md 技能的发现/解析/加载/激活全流程
- 技能包安装与安全门禁（不可信来源）
- 技能对工具白名单的运行时约束
- 技能自动生成（从代码库蒸馏）与就绪度评审

## 设计方案（为什么这么设计）

### 1. 解析与存储分离，存储三级 + per-user

- `parser.py::parse_skill_file`：frontmatter 解析（name/description/allowed-tools/required-secrets），诊断信息挂 diagnostics 而非静默丢弃。
- `SkillStorage(ABC)` + `LocalSkillStorage` + `UserScopedSkillStorage`：public（随仓库分发）/ custom（用户自建，gitignored）/ managed（管理式集成包）三级；custom 按 user_id 分桶（见 [[multi-user-isolation]]）。`validate_skill_name` / `validate_relative_path` / `ensure_safe_support_path` 防路径逃逸与符号链接。

### 2. 投影：staging → 原子换目录 + 签名

`projection.py`（868 行）：技能不直接从存储目录给沙箱用，而是**投影**到线程可见目录（`ensure_thread_skill_projection`）：staging 拷贝 → manifest 记录 `source_signature`/`view_signature` → 原子换目录；`skill_projection_mutation` + read lock 保证并发读不被换目录撕裂；`_validate_projected_skill_symlinks` 复核投影结果。签名 = 配置文件指纹（mtime/size/hash，`file_signature.py`），用于缓存失效判断——**不是密码学签名**。

### 3. 安装三道门

`installer.py`：zip-slip 成员检查（`is_unsafe_zip_member`）+ 符号链接成员拒绝 + `safe_extract_skill_archive`；`security_scanner.py::scan_skill_content`（LLM 内容扫描）+ 静态扫描器；`scan_archive_preflight_or_raise` 预检门。技能是"会被模型执行的指令包"，安装面按不可信输入对待。

### 4. 激活与策略：两个中间件

- `SkillActivationMiddleware`（1004 行）：斜杠 `/skill-name` 显式激活（词法由 `slash_skill_contract.json` 冻结），激活态写入 `skill_context` 通道（reducer 见 [[thread-state-and-reducers]]）。
- `SkillToolPolicyMiddleware`（529 行）：激活技能的 `allowed-tools` 在**每次工具调用前**执行——装配期的 `filter_tools_by_skill_allowed_tools` 只是第一道，运行时策略才是权威（技能中途激活不必重建图）。

### 5. 发现：describe_skill + 意图排序

技能多时不全量塞提示词：`describe.py::build_skill_search_setup` 注入 `describe_skill` 检索工具 + 技能索引段；`catalog.py::SkillCatalog._rank_by_intent` 多因子意图排序。提示词侧消费见 [[system-prompt-template]]。

### 6. 演化、蒸馏与评审

- `skill_manage_tool.py`：技能演化（LLM 按使用反馈自改技能内容，`skill_evolution` 配置段开关）。
- `skillscan/orchestrator.py`（1984 行）：从代码库自动蒸馏 skill 的流水线（扫描→候选→生成→校验）。
- `review/`（analyzer/readers/resource_graph/renderer）+ `review_skill_package_tool` + `contracts/skill_review/` 四个 schema（package_snapshot/review_facts/review_report/waiver_manifest）：就绪度评审——readiness/assurance/维度/证据/建议动作，豁免须 manifest（rule_id+file_sha256+过期时间）。

## 实现索引

`references/code/backend/packages/harness/helix/skills/` 整目录（50 文件）+ 中间件/工具/契约（路径前缀同上）：

| 关键文件 | 行数 | 职责 |
|---|---|---|
| `skills/projection.py` | 868 | 三级投影 + manifest + 原子换目录 |
| `skills/skillscan/orchestrator.py` | 1984 | 自动蒸馏流水线 |
| `skills/export.py` | 482 | 安全导出（manifest/预算/硬链接防护） |
| `skills/storage/skill_storage.py` + `user_scoped_skill_storage.py` | 396+471 | 存储 ABC + per-user |
| `skills/installer.py` | 331 | zip 安全解包 + 门禁 |
| `skills/parser.py` | 289 | frontmatter 解析 |
| `skills/describe.py` + `catalog.py` | 251+177 | 检索工具 + 意图排序 |
| `skills/security_scanner.py` | 176 | LLM 内容扫描 |
| `skills/review/*`（6 文件） | — | 评审器全家桶 |
| `agents/middlewares/skill_activation_middleware.py` / `skill_tool_policy_middleware.py` / `skill_context.py` | 1004/529/215 | 激活与运行时策略 |
| `tools/skill_manage_tool.py` / `builtins/review_skill_package_tool.py` | 302/201 | 演化 / 评审工具 |
| `contracts/slash_skill_contract.json` + `contracts/skill_review/`（4 schema） | — | 词法与评审契约 |
| `backend/app/gateway/routers/skills.py` + `skill_export.py` | 1156+188 | 技能 API（列表/安装/回滚/历史/导出） |

## 反模式与陷阱

- ❌ 技能目录直接挂给沙箱 → 用户可写 = 可被模型改后执行；投影 + 只读挂载。
- ❌ zip 解包不查成员路径 → zip-slip 任意写；预检 + 安全解包。
- ❌ allowed-tools 只在装配期过滤 → 中途激活失效；运行时策略中间件。
- ❌ 技能 frontmatter 直接拼提示词 → 注入面；escape（见 [[system-prompt-template]]）。
- ❌ 豁免无凭据 → 评审豁免漂移；waiver manifest 带 hash 与过期。

## 落地参考

**调参旋钮**：`skills.container_path`（如 `/mnt/skills`）、`skills.deferred_discovery`、`skill_scan`、`skill_evolution`。

**自测方向**：zip-slip 包被拒；并发投影读不被换目录撕裂；斜杠激活后 allowed-tools 即时生效；per-user 技能互不可见；评审报告 schema 校验通过。

## 进一步阅读

- [[multi-user-isolation]]（user 桶）、[[sandbox-abstraction]]（skills projection 挂载）
- [[config-and-hot-reload]]（技能缓存失效标记）
