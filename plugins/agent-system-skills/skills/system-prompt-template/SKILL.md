---
name: system-prompt-template
description: 系统提示词模板的工程化设计：全静态 SYSTEM_PROMPT_TEMPLATE（跨用户字节级一致吃满 prefix cache）、日期/记忆等动态内容改由中间件以 system-reminder 注入首条 HumanMessage、三层技能缓存（进程 + LRU + 跨副本共享重置标记）、不可信内容（SOUL.md/技能 frontmatter/子代理 description）html.escape 防框架标签伪造、子代理委派指南按并发上限生成两套。当要设计系统提示词结构、做 prompt 缓存优化、排查"提示词注入/缓存不命中/技能段落渲染不一致"时使用。
---

# 系统提示词模板设计

## 何时用

- 设计 agent 的系统提示词骨架（哪些进模板、哪些动态注入）
- 优化 LLM prefix cache 命中率
- 处理不可信内容渲染（用户可编辑的人格/技能描述）防提示词注入
- 子代理委派指南、技能清单、延迟工具清单的渲染一致性

## 设计方案（为什么这么设计）

### 1. 静态模板 + 动态 reminder 的二分

`SYSTEM_PROMPT_TEMPLATE`（prompt.py:654 起）是**纯静态**字符串模板：不含日期、不含记忆、不含任何运行时变量——跨用户、跨会话字节级一致，持续命中 provider prefix cache，直接摊薄每次 run 的冷启动成本。

动态内容（当前日期、记忆注入）**不进**系统提示词，由 `DynamicContextMiddleware`（见 [[middleware-chain-design]]）在首条 HumanMessage 前以 `<system-reminder>` 块注入。系统提示词的稳定性与上下文的时效性互不牺牲。

### 2. 模板槽位

槽位包括：`agent_name` / `soul`（自定义 agent 人格）/ `self_update_section` / `interaction_*_guidance`（交互策略）/ `skills_section`（技能清单）/ `memory_tool_section` / `deferred_tools_section`（延迟工具目录）/ `mcp_routing_hints_section` / `subagent_section`（委派指南）/ `acp_section` / `workspace_scripts_guidance` 等。每个槽位的渲染结果必须与运行时行为一致——尤其 `deferred_tools_section` 与 `DeferredToolFilterMiddleware` 共用同一 `deferred_names`（见 [[agent-graph-factory]]）。

### 3. 三层技能缓存

1. 进程级缓存
2. 按 `(id(app_config), user_id)` 的 LRU（容量 256）
3. 跨副本失效：`SharedResetMarker("skills-cache-reset")` 文件签名——任意 Gateway 副本更新技能后 `publish_skills_cache_reset`，其他副本靠签名比较自动失效（机制详见 [[config-and-hot-reload]]）

### 4. 不可信渲染点全部转义

SOUL.md、技能 frontmatter（name/description）、子代理 description 都是**用户可写内容**。直接拼进提示词等于允许注入伪造的 XML/框架标签。所有这些渲染点一律 `html.escape`。

### 5. 子代理指南按并发分形

`_build_subagent_section`（prompt.py:443）按 `max_concurrent_subagents` 生成两套完全不同的委派决策指南：n==1（串行：任务分解要考虑依赖排队）与 n>1（并行：可同时收割独立子任务）。结尾可选 `lead_prompt_overlay`（运营注入的附加提示段）。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/agents/lead_agent/prompt.py` | 1270 | 全部：模板、apply_prompt_template 渲染入口、三层缓存、转义、子代理段 |

唯一权威文件，一次读全。

## 反模式与陷阱

- ❌ 把日期/用户名/记忆写进系统提示词 → 每个请求前缀都不同，prefix cache 全 miss。改用 system-reminder 注入。
- ❌ 用户可编辑内容直接 f-string 拼接 → 提示词注入面。必须 escape。
- ❌ 技能清单单独刷新而缓存标记没发布 → 多副本渲染不一致。走 SharedResetMarker。
- ❌ `deferred_names` 与中间件白名单不同源 → 模型看到不存在的工具。

## 落地参考

**自测方向**：同 `app_config`+`user_id` 两次渲染字节级相等；不同 user 技能集不同时渲染差异只在 skills_section；`publish_skills_cache_reset` 后另一副本首次渲染即取新清单；含 `<fake>` 标签的 SOUL.md 渲染结果被转义。

**调试**：渲染产物直接打日志比对（提示词为纯函数输出，无副作用，最易做 golden 测试）。

## 进一步阅读

- [[middleware-chain-design]]（DynamicContextMiddleware 注入侧）、[[skill-system-design]]（技能清单数据源）
- [[agent-graph-factory]]（渲染时机：装配第 8 步）
