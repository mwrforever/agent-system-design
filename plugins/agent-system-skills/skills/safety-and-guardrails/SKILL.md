---
name: safety-and-guardrails
description: 工具调用安全体系：三层授权（Layer1 装配期过滤 + Layer2 调用时强制 + 插件页面/动作过滤）、RBAC 内置 provider、GuardrailMiddleware 调用前判定（deny 返回 error ToolMessage，fail_closed）、TypeSafe 远程策略引擎客户端（探针/缓存/严格 JSON）、authz↔guardrails 适配器共享 Principal、注入防御与 PII 脱敏中间件、read-before-write 写前必读门、沙箱执行授权、技能激活授权。当要给工具/插件/沙箱加权限体系、做内容安全（PII/提示注入）时使用。
---

# 安全护栏与授权

## 何时用

- 设计"谁能调哪个工具"的权限体系（静态过滤 + 动态判定两层）
- 工具调用前的护栏拦截（deny 的语义与降级）
- PII 脱敏、用户消息注入防御、写文件前必读
- 接远程策略引擎（TypeSafe）

## 设计方案（为什么这么设计）

### 1. 三层授权，共享一个 Principal

`apply_tool_authorization`（authz/tool_filter.py:22）是装配期一站式入口（Layer1：不可用的工具根本不进 schema）；`filter_tools_by_authorization`（enforcement.py:22）做调用清单过滤；`GuardrailMiddleware`（guardrails/middleware.py:25）在**每次工具调用前**强制判定（Layer2）。两层共享同一 `Principal`（`build_principal_from_context`）与同一 provider 实例——判定口径一致，不会出现"装配期放行、调用期拒绝"的口径漂移。第三层 `plugin_authz.py` 过滤插件页面/动作。

### 2. deny 的语义：error ToolMessage，不炸 run

`GuardrailMiddleware._build_denied_message` 把拒绝转为工具错误消息还给模型——模型可以改道（换工具/换参数），run 不中断。**fail_closed**：护栏 provider 异常按拒绝处理（安全默认），不按放行。

### 3. 请求带全上下文

`_build_request` 组装 `GuardrailRequest`：tool_input / user_id / run_id / authz_attributes / tool_provenance（工具来源溯源，见 [[tool-assembly-and-policy]]）/ tool_identity。策略判定需要"谁、在哪个 run、用什么身份、调一个来自哪的工具"——缺来源的判定面必然被插件工具绕过。

### 4. 内置与远程两套 provider

- `builtin.py::AllowlistProvider`：最简单的白名单。
- `authz/rbac.py::RbacAuthorizationProvider`（280 行）：编译策略（`_CompiledPolicy`）后的 RBAC。
- `guardrails/typesafe.py`（433 行）+ `typesafe/client.py`（556 行）：TypeSafe 远程决策服务（Question/AnswerSet 协议、有界读取、重试、严格 JSON 解析）。远程策略也要 fail_closed。

### 5. 内容安全三中间件

| 中间件 | 位置 | 职责 |
|---|---|---|
| `input_sanitization_middleware.py`（506） | wrap_model_call 最外层 | 用户消息注入防御（收窄提示注入面） |
| `pii_redaction_middleware.py`（551） | wrap_model_call 外层 | 模型边界的 PII 脱敏（进出双向） |
| `read_before_write_middleware.py`（563） | 追尾链 | 写文件前必须先读过（防盲写覆盖用户文件） |

### 6. 沙箱与技能授权

`authz/sandbox_authz.py`（187 行）：bash 命令执行前的授权判定；`authz/skill_filter.py`（237 行）：技能激活授权（哪些技能对该用户/该 run 可激活）。与 `AuthorizationOutcome`（outcome.py：contextvar 式 put/pop）配合，判定结果可被审计链路读取（见 [[observability-tracing]]）。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/harness/helix/authz/tool_filter.py` + `enforcement.py` | 72+82 | Layer1 一站式入口 |
| `references/code/backend/packages/harness/helix/authz/rbac.py` | 280 | RBAC provider |
| `references/code/backend/packages/harness/helix/authz/skill_filter.py` / `sandbox_authz.py` / `plugin_authz.py` | 237/187/398 | 技能/沙箱/插件授权 |
| `references/code/backend/packages/harness/helix/authz/{provider,principal,adapter,outcome,runtime,plugin_targets,activation_decisions}.py` | — | 协议/身份/桥接/结果 |
| `references/code/backend/packages/harness/helix/guardrails/middleware.py` | 279 | Layer2 调用前判定 |
| `references/code/backend/packages/harness/helix/guardrails/typesafe.py` + `typesafe/client.py` + `connection.py` | 433+556+279 | 远程策略引擎 |
| `references/code/backend/packages/harness/helix/agents/middlewares/{input_sanitization,pii_redaction,read_before_write}_middleware.py` | 506+551+563 | 内容安全三件套 |
| `references/code/backend/app/gateway/authz.py` | 1080 | 网关侧 Permissions/require_permission/模型授权/沙箱授权 |
| `references/code/backend/packages/harness/helix/config/{authorization,guardrails,pii_redaction,verification,read_before_write}_config.py` | — | 配置段 |

## 反模式与陷阱

- ❌ 只做装配期过滤 → 中途激活的技能/动态晋升的工具绕过；调用前强制层。
- ❌ 护栏异常按放行处理 → 故障窗口全通；fail_closed。
- ❌ 判定只看 tool_name → 插件工具与内置同名即绕过；带 provenance 与 identity。
- ❌ PII 脱敏放链内层 → 脱敏前的内容已进日志/预算统计；放外层。
- ❌ deny 抛异常中断 run → 模型无法改道；转 error ToolMessage。

## 落地参考

**调参旋钮**：`authorization.enabled`、`guardrails` provider、`pii_redaction`、`verification`、`read_before_write`。

**自测方向**：无权限工具不进 schema；调用前判定 deny 后模型收到可读错误并可改道；provider 抛异常时按拒绝；插件页面/动作按授权过滤；脱敏后内容不含 PII 模式。

## 进一步阅读

- [[auth]]（认证在前授权在后）、[[tool-assembly-and-policy]]（provenance）
- [[middleware-chain-design]]（三个安全中间件的链位）
