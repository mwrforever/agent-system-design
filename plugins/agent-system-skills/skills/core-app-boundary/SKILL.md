---
name: core-app-boundary
description: 设计 agent 系统的"框架层 / 应用层"双层包分层——core 框架层可独立发布，gateway / channels / scheduler 应用层可换皮不动核；单向依赖由 CI 边界测试守护；嵌入式客户端与 TUI 复用同一 agent 组件，绕过 HTTP 直入图执行。当你要把 agent 框架独立发布、让 TUI/定时任务/其它后端嵌入式使用同一 agent、防止框架代码与 web 框架代码耦合、给框架加 CI import 防火墙、或做团队代码所有权切分时调用本 skill。
---

## 何时用

- 你的 agent 项目同时是"产品"和"想独立发布的框架"
- 想让 TUI / 定时任务 / 其它后端嵌入式使用同一 agent，不经过 HTTP
- 防止前期野蛮生长把框架代码和 web 框架代码搅在一起
- 团队大了想按层切分代码所有权
- 想给框架加一层 CI 防火墙，自动阻止反向 import

## 设计方案（为什么这么设计）

### 核心矛盾：可发布的框架 vs 必须绑定传输的应用层

agent 框架（图工厂、中间件链、工具、沙箱、技能、记忆、模型工厂、运行时、持久化、追踪）本身不关心请求是从 HTTP、IM、cron 还是终端来的——它只消费 `RunnableConfig` + 消息，产出流式事件。但应用层（FastAPI Gateway、IM 通道、定时任务 poller）必须把框架绑到具体传输上：HTTP/SSE、飞书/Slack 长连接、cron 触发器。两层混在一起，框架就被钉死在某个 web 框架上，既无法独立发布，也无法被 TUI/嵌入式场景复用。

### 解法：双层包 + 单向依赖

- **Core 层**（第 1 层，可发布，`helix.*`）：纯 Python 库，含 agent / 工具 / 沙箱 / 技能 / 记忆 / 模型工厂 / 运行时 / 持久化 / 反射 / 追踪 / TUI / 嵌入式客户端——全套自给自足，零 web 框架依赖。
- **应用层**（第 2 层，不发布）：`gateway/`（FastAPI + 路由）、`channels/`（IM 集成）、`scheduler/`（任务 poller）。三者各自把 Core 绑到一种传输。
- **方向硬规则**：应用层 → Core 允许；Core → 应用层**一律禁止**。Core 不得 `import gateway.*` / `channels.*` / `scheduler.*`。

### 关键不变量（违反则框架不可独立发布）

1. **import 方向单向**：Core 任何文件出现 `from gateway.` / `from channels.` / `from scheduler.` → 框架被应用层污染，无法脱离 web 框架发布。CI 边界测试盯死这条。
2. **单一 agent 工厂**：嵌入式客户端、TUI、Gateway 三条入口都通过同一 `create_agent()` + `build_middlewares()` 构造图——不各抄一份中间件装配，否则三条路径会漂移。
3. **同源数据**：嵌入式 / Gateway / IM 通道 / TUI 读同一份 `config.yaml`、同一个数据库、同一套文件系统目录。TUI 写的 thread 在 Web UI 也能列出。
4. **持久化最小依赖**：Core 自带一个最薄的 `init_engine_from_config()`，独立于 FastAPI `app.state`，让嵌入式场景能在不启动 Gateway 的情况下写 `threads_meta` 让 Web UI 列出。
5. **TUI 控制台脚本与 Core 同包**：`helix` console script 由 Core 包的 `[project.scripts]` 提供；`textual` 是可选 extra，缺失时降级为 headless help。

### CI 边界测试：AST 扫描守护 import 方向

边界不能只靠约定——人会犯错。CI 跑一个 AST 扫描测试：遍历 Core 包下所有 `.py`，解析每条 `import` / `from ... import`，命中 `gateway.` / `channels.` / `scheduler.` 前缀即失败。用 AST（非 regex）是为了覆盖多行 import 与别名。

```python
# 伪代码：CI 边界测试的核心逻辑
BANNED_PREFIXES = ("gateway.", "channels.", "scheduler.")

def test_core_does_not_import_app():
    offenders = {}
    for py_file in CORE_ROOT.rglob("*.py"):
        for lineno, module in _collect_imports(py_file):   # ast.walk 解析每条 import
            if module.startswith(BANNED_PREFIXES):
                offenders[py_file] = module                # 命中即记录
    assert not offenders, f"Core depends on app layer:\n{offenders}"
```

### 嵌入式客户端 = 平行的同步消费路径（非 Gateway 包装）

嵌入式客户端 `HelixClient` **不是** Gateway `run_agent` worker 的薄封装。Gateway worker 是 `async def` + `agent.astream()` + `StreamBridge`（跨 HTTP 的 `Last-Event-ID` 重放、心跳、多订阅者扇出）；嵌入式客户端是**同步生成器** + `agent.stream()`，让调用方写 `for event in client.stream(...)` 不碰 asyncio。两条路径服务于不同受众，**不能共享执行**：

- async vs sync：桥接需要每次调用起一个事件循环 + 线程。
- Gateway 事件经 JSON 序列化走 SSE 线缆；嵌入式客户端直接把进程内流事件作为 Python 数据结构吐出（`StreamEvent.data` 是 plain `dict`），省掉 JSON/SSE 层。
- `StreamBridge` 是跨 HTTP 边界解耦生产者/消费者的 asyncio 队列；单进程内单消费者直接迭代，不需要。

所以 `HelixClient.stream()` 是同一个 `create_agent()` 工厂的**平行同步消费者**，不是 Gateway 的包装。两条路径应保持订阅的 LangGraph `stream_mode` 一致；该不变量由回归测试（而非共享常量）锁定，因为 Graph / Platform SDK / HTTP 三层各自命名不同（`messages` vs `messages-tuple`），无法字面共享字符串。

### TUI：同一客户端 + threads_meta 写入让 Web UI 可见

TUI 没有自己独立的 agent——它就是 `HelixClient` 之上的 Textual UI 外壳。`helix` console script（Core 包的 `[project.scripts]`）按 TTY 状态决定开终端 UI 还是跑 headless one-shot；`textual` 缺失时降级为 headless help，不崩溃。

Web UI 从 `threads_meta` SQL 表（user-scoped）列会话，不读 checkpointer。嵌入式 run 只写 checkpointer，TUI 线程会从 Web UI 侧栏消失。`tui/persistence.py` 通过 Core 自带的 `init_engine_from_config()` 写一行 `threads_meta`（默认用户）进 Gateway 读的同一数据库——**无需启动 Gateway 进程**。best-effort：`memory` 后端下是 no-op。所有 DB 工作跑在一个长生命周期的后台事件循环上（SQLAlchemy async engine 绑定到创建它的 loop）。

### 在端到端链路中的位置（横切架构边界）

本 skill 是**横切** skill——它不对应链路上某一段，而是约束整条链路的**架构骨架**。在 [[e2e-request-lifecycle]] 中，入站（`gateway` 路由 / `channels` IM 适配）→ Core 图执行（中间件链 + 节点）→ 出站（SSE / IM 回写），Core 是**所有**请求路径的共同执行核；嵌入式客户端与 TUI 是绕过 HTTP/IM、直入 Core 图执行的额外入口。单向依赖保证无论入口怎么加，执行核永远可独立发布、可被任意入口复用。

一个具体的链路联动：定时任务（`scheduler/`）按 cron 触发后，仍通过 Gateway 的 run 生命周期派发（而非另起一套执行栈），最终进入 Core 图——`context.non_interactive` 在图工厂剥离 `ask_clarification`，见 [[e2e-request-lifecycle]] 与 [[scheduled-tasks]]。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `tests/test_core_boundary.py` | CI AST 扫描：Core 包不得 import `gateway.` / `channels.` / `scheduler.` | [boundary-and-ci-test.md](./references/code/boundary-and-ci-test.md) |
| `core/helix/client.py` | `HelixClient`：进程内同步驱动同一 agent 图，`chat()` / `stream()` / 配置查询全套 | [embedded-client.md](./references/code/embedded-client.md) |
| `core/helix/tui/cli.py` | `plan_launch()`（纯决策）+ `main()`：TTY → TUI，否则 headless；绝对 import 避免边界测试误判 | [tui.md](./references/code/tui.md) §1 |
| `core/helix/tui/persistence.py` | `ThreadMetaWriter` + `_LoopThread`：写 `threads_meta` 让 TUI 会话在 Web UI 可见 | [tui.md](./references/code/tui.md) §2 |
| `core/helix/tui/session.py` | `Session`：构造 `HelixClient` + checkpointer + writer；`--continue` / `--resume` 线程解析 | [tui.md](./references/code/tui.md) §3 |
| `core/helix/persistence/engine.py` | `init_engine_from_config()`：嵌入式/TUI 用的最薄持久化入口，独立于 FastAPI `app.state` | [tui.md](./references/code/tui.md) §2 引用 |
| `core/pyproject.toml` | `[project.scripts] helix`；`[project.optional-dependencies] tui = ["textual>=0.80"]` | [tui.md](./references/code/tui.md) §4 |

### 模块入口与索引

**CI 边界测试**（完整源码见 [boundary-and-ci-test.md](./references/code/boundary-and-ci-test.md)）：
- `_collect_imports`：`ast.walk` 解析每条 import，返回 `(lineno, module)`；`SyntaxError` 兜底返回空列表（不因语法错误文件中断扫描）。
- `test_core_does_not_import_app`：遍历 Core 包所有 `.py`，命中 `BANNED_PREFIXES = ("gateway.", "channels.", "scheduler.")` 即收集为 violation；断言无 violation，失败信息含相对路径 + 行号 + 被禁模块名。
- 注意：TUI 的 `cli.py` 用**绝对 import** `from helix.tui.app import run_tui`（非 `from .app`），因为边界测试按字面记录 import 模块名，`app` 会被误判为禁用的顶层 `app` 包。

**嵌入式客户端**（完整源码见 [embedded-client.md](./references/code/embedded-client.md)）：
- `HelixClient.__init__`：载配置但惰性创建 agent（首次调用才建）。`agent_name` 用正则校验。`environment` 落到 Langfuse tag（默认读 `HELIX_ENV` / `ENVIRONMENT` env）。
- `_ensure_agent`：按 `(model_name, thinking, plan_mode, subagent, agent_name, frozenset(available_skills))` 做 cache key，key 变化才重建 agent；调同一 `build_middlewares()` + `apply_prompt_template()` + `assemble_deferred_tools()`，与 `make_lead_agent` 同源。`attach_tracing=False`——`stream()` 在图根注入 tracing callbacks，避免重复 span。
- `stream()`：同步生成器，订 `stream_mode=["values","messages","custom"]`；trace id 绑定按每个 `next()` 步 set/reset（不在 `yield` 间持有），避免跨请求泄漏与 `Token was created in a different Context`。
- `chat()`：按消息 id 累积 delta 列表一次性 join（避免长响应 O(n²)），返回**最后**一条 AI 消息的完整文本。
- 配置查询方法（`list_models` / `list_skills` / `get_mcp_config` 等）返回 dict 与 Gateway Pydantic response 模型**同构**，由 `TestGatewayConformance` 回归测试锁定。

**TUI**（完整源码见 [tui.md](./references/code/tui.md)）：
- `cli.py::plan_launch`：纯决策函数——给定 argv / TTY / env，决定开 TUI / headless `--print` / `--json` / help。无 IO、无 client 构造，全单元测试覆盖。
- `cli.py::main`：把 `LaunchPlan` 接到 `HelixClient` + 惰性导入 Textual app（只在真开 UI 时）；headless one-shot 跳过持久化（不起后台 loop / engine 仅为丢弃）。
- `cli.py::_run_tui`：`from helix.tui.app import run_tui` 绝对 import 避开边界测试；`ModuleNotFoundError` 且 name == `textual` 时降级为安装提示 + headless help。
- `persistence.py::ThreadMetaWriter`：所有方法吞异常——持久化可见性是便利，绝不应打断对话；`memory` 后端或初始化失败降级为 no-op。
- `persistence.py::_LoopThread`：daemon 线程跑单一 asyncio loop；所有 DB 工作通过 `run_coroutine_threadsafe` 上这个 loop，避免每次调用 `asyncio.run` 绑定到一次性 loop。

## 反模式与陷阱

- ❌ **Core 文件里 `from gateway.gateway.deps import get_run_manager`** → 框架不可独立发布，CI 边界测试直接红。修复：把共享逻辑下沉到 Core，或用依赖反转（应用层把回调注入 Core）。
- ❌ **应用层把业务逻辑写到自己里而不是 Core** → Core 是空壳，用户 fork 后还得改应用层。修复：应用层只做传输适配，业务逻辑全进 Core。
- ❌ **嵌入式客户端单独抄一份 `build_middlewares`** → 双份代码漂移，中间件顺序 / 新中间件两边不一致。修复：嵌入式客户端必须 import 同一个 `build_middlewares` 工厂。
- ❌ **TUI 不写 `threads_meta`** → Web UI 看不到 TUI 的会话，用户体验割裂。修复：`ThreadMetaWriter` best-effort 写入。
- ❌ **同一进程多个 SQLAlchemy async engine 绑到不同 event loop** → 跨 loop 用 engine 报错或连接泄漏。修复：一个长生命周期后台 loop（`_LoopThread`）承接所有 DB 工作。
- ❌ **TUI 的 `cli.py` 用 `from .app import run_tui`（相对 import）** → 边界测试按字面记录模块名 `app`，误判为禁用的顶层 `app` 包。修复：绝对 import `from helix.tui.app import run_tui`。
- ❌ **`stream()` 在 `yield` 间持有 trace id ContextVar 绑定** → 跨 yield 泄漏 id 到调用方 context，且 GC 关闭废弃生成器时抛 `Token was created in a different Context`。修复：每个 `next()` 步 set/reset。
- ✅ 嵌入式 / Gateway / TUI 都通过 `create_agent` + `build_middlewares` 同一工厂
- ✅ 边界测试盯死 import 方向，CI 每条 PR 跑

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `[project.scripts] helix` | Core `pyproject.toml` | console script 入口；`textual` 缺失时降级 |
| `[project.optional-dependencies] tui` | Core `pyproject.toml` | `textual>=0.80`，可选 extra 保持 Core 安装精简 |
| `HELIX_ENV` / `ENVIRONMENT` | env | 嵌入式/TUI 的部署环境标签，落到 Langfuse `env:<value>` tag |
| `HELIX_TUI` | env | 真值时强制开 TUI（等价 `--tui`） |
| `checkpointer` | `HelixClient.__init__` | 多轮对话必需；不传则每次调用 stateless |
| `init_engine_from_config` backend | config `database.backend` | `memory` → 持久化 no-op；`sqlite` / `postgres` → threads_meta 写入 |

**关键日志串**

- `Agent created: agent_name=..., model=..., thinking=...` — 嵌入式 agent 首次创建 / config key 变化后重建
- `Persistence engine initialized: backend=...` — 持久化引擎初始化（含嵌入式路径）
- `Auto-created PostgreSQL database: ...` — Postgres 库不存在时自动建库
- `The terminal UI needs the optional 'textual' dependency.` — TUI 降级提示（textual 缺失）

**自测方向**

- **边界测试本体**：在 Core 包内故意加一条 `from gateway.foo import bar`，断言 `test_core_does_not_import_app` 失败信息含该文件 + 行号；删掉后通过。
- **AST 覆盖**：构造多行 import + 别名 import 的样本，断言 `_collect_imports` 全部捕获。
- **绝对 import 误判**：`cli.py` 用 `from helix.tui.app import run_tui` 时边界测试不命中（`app` 不出现在 import 模块名里）。
- **嵌入式 / Gateway 同构**：`TestGatewayConformance` 把 `HelixClient` 每个返回 dict 的方法喂进对应 Gateway Pydantic 模型，新增必填字段即 `ValidationError`。
- **stream_mode 一致性**：`test_messages_mode_emits_token_deltas` 锁定嵌入式订阅的 stream_mode 与 Gateway worker 一致。
- **trace id 不泄漏**：`test_stream_does_not_leak_trace_id_to_caller_context_between_yields` + `test_stream_abandoned_generator_close_does_not_raise_cross_context`。
- **threads_meta 往返**：TUI 写入后 Web UI 侧栏可见；`memory` 后端下 no-op 不报错。
- **textual 缺失降级**：mock `ModuleNotFoundError(name='textual')`，断言 console script 打印安装提示 + headless help，非 forced 时退出码 0，forced 时退出码 1。

## 进一步阅读

- CI 边界测试完整源码：[references/code/boundary-and-ci-test.md](./references/code/boundary-and-ci-test.md)
- 嵌入式客户端完整源码：[references/code/embedded-client.md](./references/code/embedded-client.md)
- TUI（CLI + persistence + session + pyproject）完整源码：[references/code/tui.md](./references/code/tui.md)
- 关联 skill：[[e2e-request-lifecycle]]（横切位置：所有入口共用 Core 执行核）、[[agent-graph-factory]]（单一 `create_agent` 工厂）、[[middleware-chain-design]]（同一 `build_middlewares`）、[[packaging-and-deployment]]（monorepo 发布）、[[config-and-hot-reload]]（同源 `config.yaml`）、[[scheduled-tasks]]（scheduler 通过 Gateway run 生命周期进入 Core 图）、[[observability-tracing]]（嵌入式与 Gateway 在图根同构注入 tracing）
