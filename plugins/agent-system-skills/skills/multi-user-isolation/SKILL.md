---
name: multi-user-isolation
description: 多用户数据隔离链路：user_context contextvar 身份传播与三源归一（LangGraph config/context/auth）、get_effective_user_id 兜底（无认证落 default 桶）、Paths 路径安全（thread/user/integration/project id 校验防穿越 + 按用户分桶）、secret_context 密钥提取/脱敏与斜杠技能 owner-token 隔离、run 来源标记契约。当平台从单用户转多用户、排查"用户串数据/串记忆/串技能"、设计身份在异步任务间的传播时使用。
---

# 多用户隔离

## 何时用

- 单用户系统改多用户：身份如何贯穿全链路
- 排查"用户 A 看到用户 B 的数据/记忆/技能/沙箱"
- 异步 worker（调度器/渠道/子代理）里身份如何恢复
- 密钥与 owner-token 的隔离

## 设计方案（为什么这么设计）

### 1. 身份三源归一

`runtime/user_context.py`（295 行）：
- `set_current_user` / `get_current_user` / `require_current_user`：contextvar 传播（同请求内隐式可用，异步任务边界显式携带）
- `resolve_user_id`：**三源归一**——LangGraph `config`（configurable/context 注入）→ `runtime` 对象 → 认证态；`get_effective_user_id()` 兜底：无认证模式落 `default` 桶（而不是散落到根目录）

任何存储取数前先过归一函数——散落的 `user_id or "default"` 判断是串数据的头号来源。

### 2. 路径即边界

`config/paths.py`（556 行）：所有宿主路径由 `Paths` 类统一派生；`thread_id` / `user_id` / `integration_id` / `project_id` **入路径前强制校验**（防路径穿越——`../` 或分隔符注入把 A 的 id 变成 B 的目录）。目录结构按域分桶：

```
<helix_home>/threads/{thread_id}/{workspace,uploads,outputs}
<helix_home>/users/{user_id}/{skills,memory,mcp,...}
```

消费方（技能存储、记忆后端、个人 MCP、沙箱挂载、上传）全部走 Paths，不自拼路径。

### 3. 密钥上下文与 owner-token

`runtime/secret_context.py`（248 行）：
- 密钥提取/脱敏：进入日志与错误信息的密钥先剥离
- **斜杠技能 owner-token 隔离**：技能激活携带的敏感 token 只对该 owner 生效，跨 owner 的 run 拿不到

### 4. 来源标记

`runtime/run_origin.py` + `contracts/thread_origin_contract.json`：每个 run/thread 记录来源（extension / github / im_channel / mcp_notification / schedule）。非交互来源的 run 天然受限（见 [[e2e-request-lifecycle]] 信任边界），审计时能回答"这个动作是谁发起的"。

### 5. 异步边界的身份恢复

调度器、IM 渠道、子代理、MCP 任务 worker 都在请求上下文之外跑：身份经内部令牌（[[auth]]）或 config 注入显式携带，进 worker 后先 `set_current_user` 再干活——忘了这步，worker 里的所有"当前用户"读取都会落 default 桶。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/harness/helix/runtime/user_context.py` | 295 | 身份传播与三源归一 |
| `references/code/backend/packages/harness/helix/runtime/secret_context.py` | 248 | 密钥提取/脱敏/owner-token 隔离 |
| `references/code/backend/packages/harness/helix/runtime/run_origin.py` | 80 | 来源标记 |
| `references/code/backend/packages/harness/helix/config/paths.py` | 556 | 路径派生 + id 校验 + 分桶 |
| `references/code/contracts/thread_origin_contract.json` | 12 | 来源词表 |

分桶消费方：[[skill-system-design]]（user 技能）、[[memory-system-design]]（owner 记忆）、[[mcp-integration]]（个人 MCP）、[[sandbox-abstraction]]（沙箱归属）。

## 反模式与陷阱

- ❌ 各处自行 `user_id or "default"` → 归一口径漂移；统一 resolve_user_id。
- ❌ id 直接拼路径 → 穿越/串桶；Paths 校验后派生。
- ❌ worker 里不恢复身份 → default 桶串数据；入口 set_current_user。
- ❌ 技能 token 不分 owner → 跨用户凭证借用；owner-token 隔离。
- ❌ 来源不标记 → 审计与信任边界失效；run_origin 契约。

## 落地参考

**自测方向**：`user_id="../other"` 被路径校验拒绝；两个用户各自 resolve 后落到不同桶目录；调度器触发的 run 内 `get_current_user` 是配置的 owner 而非 default；密钥不出现于日志。

## 进一步阅读

- [[auth]]（身份的源头）、[[e2e-request-lifecycle]]（run-context 信任边界）
- [[workspace-and-projects]]（线程目录的实际使用方）
