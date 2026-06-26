# Implementation Notes — Multi-User Isolation

> 多用户隔离的实现核心：ContextVar + 三态 user_id 哨兵 + 用户分桶目录 +
> 持久化层 WHERE 子句。路径以占位形式给出。
>
> 工具运行如何拿到 user_id 跨边界存活、IM 频道如何把外部账号绑定到内部用户、
> filesystem 分桶与 sandbox virtual path 的关系——这三个问题决定了
> 任何"多租户隔离"是真隔离还是漏勺。

---

## 一、隔离层组件

| 组件 | 位置 | 职责 |
|------|------|------|
| `_current_user` ContextVar | `<harness-pkg>/runtime/user_context.py` | 请求级用户身份载体，asyncio task-local |
| `set_current_user / reset_current_user` | 同上 | 鉴权中间件入口/出口配对调用 |
| `get_effective_user_id()` | 同上 | 返回 str id 或 `DEFAULT_USER_ID="default"`，永不抛 |
| `require_current_user()` | 同上 | 强制取用户，未设置抛 RuntimeError |
| `resolve_runtime_user_id(runtime)` | 同上 | 工具/中间件优先从 `ToolRuntime.context["user_id"]` 取 |
| `AUTO` 哨兵 + `resolve_user_id()` | 同上 | 仓储层 user_id 参数的三态语义 |
| `inject_authenticated_user_context()` | `<app-pkg>/gateway/services.py` | 把 server-side 鉴权身份写入 run config.context |
| 用户分桶目录 | 文件系统 | `<data-root>/users/{user_id}/...` 物理隔离 |

---

## 二、ContextVar 的三态语义

`ContextVar` 在 asyncio 下是 task-local，FastAPI 每个请求在独立 task 中运行，
天然隔离。`asyncio.create_task` 与 `asyncio.to_thread` 继承父 task 上下文，
这正是后台落盘需要的语义。如果一定要让后台任务**不**看到前台用户，
显式用 `contextvars.copy_context()` 拿干净副本。

仓储方法统一签名：`user_id: str | None | _AutoSentinel = AUTO`，
对应三种行为：

1. **`AUTO`（默认）**：从 ContextVar 读；未设置则抛 `RuntimeError`。
   这是请求处理路径的常态——能让仓储调用点保持干净，不传 user_id。
2. **显式 `str`**：用传入值，覆盖 ContextVar。测试 / 管理员越权 / IM 频道
   把外部平台用户翻译成内部用户时用。
3. **显式 `None`**：跳过 WHERE 子句。仅供迁移脚本和管理 CLI 使用——
   错误调用会泄漏跨用户数据，所以 `resolve_user_id` 的 docstring 把它
   定义成"显式不安全"。

UUID/str 边界：`User.id` 在 API 表面是 `UUID`，但持久化层 `user_id`
列是 `VARCHAR(64)`，aiosqlite 拒绝绑定 raw UUID。`resolve_user_id`
在边界 `str(user.id)` 一次性转换，避免 INSERT 静默回滚导致 worker 卡死。

**`CurrentUser` Protocol 反向依赖**：本模块定义 `CurrentUser` 为 `typing.Protocol`
（结构化类型，要求 `.id: str`）而**不**直接 import 鉴权层的具体 User 类。
这条 import 方向保证了底层 persistence 层永远不依赖 app 层。任何带 `.id`
属性的对象都能塞进 ContextVar，让测试可以塞 mock 也不破坏类型契约。

---

## 三、用户分桶目录

物理布局：

```
<data-root>/users/{user_id}/
├── memory.json                          # 用户级记忆
├── agents/{agent_name}/                 # 自定义 Agent 定义
│   ├── SOUL.md
│   ├── config.yaml
│   └── memory.json                      # 该 Agent 在该用户下的独立记忆
└── threads/{thread_id}/
    └── user-data/
        ├── workspace/
        ├── uploads/
        └── outputs/
```

`user_id` 通过 `get_effective_user_id()` 解析，无鉴权模式下回退到字面量
`"default"`（常量 `DEFAULT_USER_ID`）。Sandbox 把这些物理路径映射成
虚拟路径 `/mnt/user-data/{workspace,uploads,outputs}` 暴露给 Agent，
Agent 永远看不到真实 user_id——这是横向防护的关键。

历史数据迁移：runtime 旧布局 `<data-root>/threads/...` 与
`<data-root>/agents/...` 仍作为 read-only fallback 保留，
配套独立的 `migrate_user_isolation.py` 脚本支持 `--dry-run` 与
`--user-id` 把无主数据指派给特定用户。

**`make_safe_user_id` 规约**：从外部输入（OAuth provider id、IM 平台 user id）
派生 user_id 时必须做规范化——剥离不安全字符、限制长度、保持目录名跨平台
合法。同一外部身份在多次解析下必须产出相同 safe id，否则会出现两个用户
桶指向同一逻辑人物，数据被分裂。

---

## 四、写路径：从 HTTP 边界到 Tool 运行

完整链路：

1. **鉴权中间件**调用 `set_current_user(user)` 拿到 reset token
2. **HTTP 路由**通过 `Depends(get_current_user)` 取出，路由内调用业务
3. **`inject_authenticated_user_context(config, request)`** 把 `user_id` /
   `user_role` / `oauth_provider` / `oauth_id` 写入 `config["context"]`
4. **`run_agent()`** 构造 `runtime_ctx = _build_runtime_context(...)`，
   永远以 `thread_id`/`run_id` 作为强制键，调用方 context 走 `setdefault` 补充
5. **`Runtime(context=runtime_ctx, store=store)`** 被注入到 langgraph 1.1+
   的 `__pregel_runtime`，工具运行时通过 `ToolRuntime.context` 拿到
6. **工具/中间件** 调用 `resolve_runtime_user_id(runtime)` ——
   优先 runtime.context，回退 ContextVar，最后 DEFAULT_USER_ID

为什么不能只靠 ContextVar？因为工具执行可能发生在请求 handler 返回**之后**
（后台 task 已切换执行上下文），而 `runtime.context` 是 Runtime 对象的属性，
跨边界存活。这条路径专为 `setup_agent`、`update_agent`、memory 写入这类
需要持久化用户态的工具准备。

**internal system role 的旁路**：服务间调用（IM channel worker 调网关）
用 internal auth token 走过来，鉴权中间件认出 `system_role=INTERNAL_SYSTEM_ROLE`
后**不**注入 user_id——避免内部系统把自己的 id 误填进 context。真正的
owner_user_id 由请求体或受信 header 显式带入。

---

## 五、读路径：写背景任务里的 user 捕获

后台线程（`threading.Timer`、worker pool）不继承 asyncio 的 ContextVar。
典型例子：`MemoryQueue` 的 debounced flush 在 timer 线程里执行，
原 user_id 在 ContextVar 里已丢失。

实现选择是**在 enqueue 时捕获 user_id，跨线程边界传值**——而非到 flush 时再读
（彼时 ContextVar 必为空）。同样的模式用于：

- IM 频道：把外部平台用户翻译成内部用户后，显式传给 `runs.create(user_id=...)`
  而非依赖 ContextVar
- 内部系统调用：`X-Internal-Owner-User-Id` header 携带 owner_user_id，
  路由侧 `_resolve_memory_user_id(request)` 通过 `get_trusted_internal_owner_user_id`
  验证 internal_auth 通过后才采信此 header

任何"我能在 ContextVar 里读到 user_id"的假设在跨边界场景下都不成立，
显式传值是唯一可靠路径。

---

## 六、设计权衡与陷阱

1. **`AUTO` 哨兵的报错友好性**：仓储调用 `resolve_user_id(AUTO)` 在
   ContextVar 未设置时抛的错明确指出三条出路（"传 user_id / 在鉴权中间件
   设置 / 显式 None 跳过过滤"），让 stack trace 直接指向解决方案。

2. **`store-only` 跨用户可见性**：list/get 的持久化 hydration 路径**必须**
   把 `user_id` 透传给 RunStore.get/list_by_thread，否则用户 A 能列出用户 B
   的历史 Run。

3. **DEFAULT_USER_ID 的双刃**：单用户/无鉴权模式下数据全落 `users/default/`，
   后续开启鉴权时如果忘了迁移脚本，所有历史数据看起来都"属于默认用户"。

4. **绝对路径 opt-out**：配置 `memory.storage_path` 写绝对路径会跳过用户分桶。
   这是兼容老安装的逃生口，但破坏了隔离，文档要明确警告。

5. **IM 频道的 owner vs sender**：消息发送者（`channel_user_id`）与
   平台内部用户（`owner_user_id`）必须区分。IM 频道连接表把外部账号
   绑定到内部 owner，后续消息以 owner 身份运行 Run，文件、记忆、artifact
   全部落 owner 桶。

6. **跨用户复制工具**：禁止任何"用户 A 拷贝到用户 B"的工具自动化路径。
   admin 手动迁移由 CLI 完成（带 `--user-id=None` 显式越权语义），
   绝不能让 Agent 触发。

7. **`UUID` ↔ `str` 边界**：仅在 `resolve_user_id` 与 `_user_id_from_context`
   两个地方做 `str(user.id)` 转换。其他持久化层（`run_events.user_id`、
   `users.id` 关联键）默认收到 str，绕过 aiosqlite 的 raw UUID 拒绝。
   任何"我直接传 UUID 应该也行"的尝试都会在 SQLite 路径上静默回滚
   ——insert 无报错但 SELECT 找不到记录。

8. **`copy_context()` 与后台任务**：默认 `asyncio.create_task()` 继承父
   context，user_id 一同继承，这通常是想要的。但**事件订阅 / 全局调度器**
   场景必须显式 `contextvars.copy_context().run(fn)` 拿空 context，否则
   一个 admin 触发的全局任务会以 admin 身份持续写所有用户的桶。

9. **审计 trail 的 user 维度**：RunEventStore 的 trace 类记录默认带
   `user_id`（从 ContextVar 读），这条 trail 是排查"哪个用户在何时
   触发了哪个工具"的唯一信源。如果工具运行已脱离 ContextVar 边界
   （后台 timer），写入会 fallback 到 `None`——审计盲点。
   解决办法是让此类工具显式 `set_current_user(captured_user)` 在
   timer thread 入口重建 ContextVar。

---

[[gateway-runs-and-sse]] · [[thread-meta-and-history]] · [[config-and-hot-reload]] · [[upload-pipeline]] · [[memory-system]]
