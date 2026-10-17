---
name: memory-system-design
description: Agent 记忆系统：MemoryManager 统一门面（检索/写入/判断/摘要钩子/预热）、Markdown 文件型主后端 HelixMem（存储 + 增量更新器，按 owner_user_id 隔离）、mem0/honcho/openviking/noop 多后端适配、signals 信号采集（何时该记）与 prescreen 预筛、MemoryMiddleware 队列式异步写入（不阻塞主循环）、事实条目 CRUD 与导入导出 API。当要给 agent 加长期记忆、选型记忆后端、设计"记什么/何时记/怎么防噪音"时使用。
---

# 记忆系统设计

## 何时用

- agent 需要跨会话/跨线程的长期记忆（用户偏好、事实、项目背景）
- 选型记忆后端（自管 Markdown / mem0 / honcho / openviking）与统一抽象
- 记忆信号采集与预筛（防什么垃圾都记）
- 记忆注入的时序（不破坏 prefix cache）

## 设计方案（为什么这么设计）

### 1. 管理器是唯一门面

`MemoryManager`（manager.py，1212 行）：检索（warm retrieval 预热）、写入、judging（该不该记）、summarization_hook、fact CRUD、导入/导出/清空。所有消费方（中间件、工具、API 路由、嵌入式客户端）只认 manager，不摸后端。

### 2. 主后端是 Markdown 文件，不是向量库

`HelixMem`（backends/helixmem/，storage.py 2176 行 + updater.py 2629 行 + core/）：记忆以 Markdown 文件落盘，按 `owner_user_id` 分目录隔离。取舍：
- 可审计（人可直接看/改/审 diff）
- 免向量库运维；检索由后端自身实现
- 增量更新器（updater）负责合并/去重/结构化更新

其余后端（mem0 728 行 / honcho 546 / openviking 1014 / noop 280）走同一抽象，配置切换。

### 3. 记什么：信号 + 预筛

`signals/`（1067 行）从会话事件提取"值得记"的信号；`prescreen/`（363 行）在写入前预筛掉噪音。**先判后记**：judging 决定候选是否成文，防止记忆库被寒暄与临时信息灌满。

### 4. 怎么注入：不进系统提示词

`MemoryMiddleware`（231 行）以**队列式异步写入**（不阻塞主循环）+ 读侧由 `DynamicContextMiddleware` 以 system-reminder 注入首条 HumanMessage（见 [[system-prompt-template]]）——记忆内容每用户不同，进系统提示词会击穿 prefix cache。

### 5. 所有权与多用户

记忆严格按 owner 隔离：`memory.owner_user_id` 配置段 + 路径按 user 分桶（见 [[multi-user-isolation]]）；IM 渠道触发的 run 记忆归属渠道绑定用户，而非消息发送者。

## 实现索引

`references/code/backend/packages/harness/helix/agents/memory/` 整目录（62 文件）：

| 关键文件 | 行数 | 职责 |
|---|---|---|
| `memory/manager.py` | 1212 | 统一门面 |
| `memory/backends/helixmem/storage.py` | 2176 | Markdown 存储 |
| `memory/backends/helixmem/updater.py` | 2629 | 增量更新器 |
| `memory/tools.py` / `judging.py` / `summarization_hook.py` | 283/132/33 | 记忆工具 / 判断 / 摘要钩子 |
| `memory/signals/` + `memory/prescreen/` | 1067+363 | 信号采集 / 预筛 |
| `memory/backends/{mem0,honcho,openviking,noop}/` | 728/546/1014/280 | 替代后端 |
| `agents/middlewares/memory_middleware.py` | 231 | 队列式异步写入 |
| `config/memory_config.py` | 308 | manager_class/mode/owner |
| `backend/app/gateway/routers/memory.py` | 635 | 记忆 API（状态/条目 CRUD/导入导出/重载） |

## 反模式与陷阱

- ❌ 记忆写进系统提示词 → prefix cache 全 miss；system-reminder 注入。
- ❌ 同步写记忆阻塞主循环 → 尾延迟劣化；队列式异步。
- ❌ 无预筛全量记 → 记忆库噪音化，检索质量坍塌；signals + prescreen + judging。
- ❌ 记忆不按 owner 隔离 → 跨用户串忆；owner_user_id + 分桶。
- ❌ 后端细节泄漏到消费方 → 换后端全改；只认 manager 门面。

## 落地参考

**调参旋钮**：`memory.manager_class`（默认 helixmem）、`memory.middleware` 模式、`memory.owner_user_id`、warm 预热开关（tiktoken 预载）。

**自测方向**：写入后跨 thread 检索可见；预筛拒掉寒暄类信号；owner A 的记忆 owner B 不可见；导入/导出往返无损；换 noop 后端全链路降级不报错。

## 进一步阅读

- [[system-prompt-template]]（注入侧）、[[middleware-chain-design]]（Memory 链位）
- [[multi-user-isolation]]、[[persistence-layer]]（记忆不落 SQL，走文件 + 各后端自管）
