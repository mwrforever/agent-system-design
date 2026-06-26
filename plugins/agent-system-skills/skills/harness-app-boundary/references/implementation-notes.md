# Implementation Notes — harness-app-boundary

## 1. 两层定义：发布物 vs 应用壳

整个仓库被刻意切成两层，**包名映射**就是边界条约：

```
<repo-root>/
├── packages/harness/                   ← 可独立发布的代理框架包
│   ├── pyproject.toml                  ← name = "<framework-pkg>"
│   └── <framework-pkg>/                ← import 前缀，如 import_framework.*
│       ├── agents/  subagents/  sandbox/  tools/  skills/
│       ├── mcp/  models/  memory/  runtime/  persistence/
│       ├── config/  reflection/  tracing/  community/
│       ├── tui/                         ← optional dep（textual）
│       └── client.py                    ← EmbeddedClient
├── <app-pkg>/                           ← 不发布的应用层
│   ├── gateway/                         ← FastAPI 路由 + lifespan
│   └── channels/                        ← IM 适配器（Feishu/Slack/Telegram/...）
├── pyproject.toml                       ← uv workspace 根
├── uv.lock
└── tests/test_harness_boundary.py       ← CI 边界守护
```

**依赖方向唯一**：`<app-pkg>.*` → `<framework-pkg>.*` 允许；反向禁止。Gateway 的 FastAPI router、
IM 通道、auth 都属于 app 层，可以自由 `from <framework-pkg>.agents import make_lead_agent`；
反过来 harness 永远不能写 `from <app-pkg>.gateway.routers.uploads import ...`——这条线一旦松
就意味着框架不可独立打包。

## 2. CI 守护：AST 扫描，不靠人盯

`test_harness_does_not_import_app` 不靠 review，它直接 walk `<framework-pkg>/` 下每个 `.py` 文件
的 AST，凡命中 `ast.Import` 或 `ast.ImportFrom` 且 module 以 `<app-pkg>.` 开头就计入 violations，
最后 `assert not violations` 报错时把违例文件名 + 行号 + 模块名打全。骨架是这样的：

```python
HARNESS_ROOT = Path(__file__).parent.parent / "packages" / "harness" / "<framework-pkg>"
BANNED_PREFIXES = ("<app-pkg>.",)

def _collect_imports(filepath):
    tree = ast.parse(filepath.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                yield (node.lineno, alias.name)
        elif isinstance(node, ast.ImportFrom) and node.module:
            yield (node.lineno, node.module)

def test_harness_does_not_import_app():
    violations = []
    for py in sorted(HARNESS_ROOT.rglob("*.py")):
        for lineno, module in _collect_imports(py):
            if any(module == p.rstrip(".") or module.startswith(p) for p in BANNED_PREFIXES):
                violations.append(f"{py}:{lineno}  imports {module}")
    assert not violations
```

这意味着：

- **新增模块没有任何免检通道**：放进 `<framework-pkg>/` 就要服从边界，没有 skip-marker。
- **AST 而非字符串扫**：注释、字符串字面量、文档里出现 `<app-pkg>.` 不会误报；只看真正的
  import 语句。
- **检测点是 module 路径而非文件路径**：即便有人把 `<framework-pkg>/tui/app.py` 通过相对
  导入摸进来，只要 import 字符串本身写的是 `<app-pkg>.X` 就会被抓。
- **`==` 与 `startswith` 双重匹配**：裸名（少见）与 `<app-pkg>.foo.bar` 都命中。

实战中只要 PR 里出现「framework 模块想要 FastAPI Request / Gateway state」就是边界设计错了，
应该把数据通过函数参数从 app 层传进 harness，而不是反向 import。CI 把这条规则机器化执行——
是这条边界能长期不漂的根本原因。

## 3. EmbeddedClient：第二条等价跑道

`<framework-pkg>/client.py::EmbeddedClient` 提供了 Gateway 的纯进程内对偶——同样调用
`make_lead_agent`、同样吃 `build_middlewares`、同样写 `threads_meta`，但**不需要起 FastAPI / nginx**。
对外暴露的最小协议：

- `chat(message, thread_id=None) -> str`：同步累计 `messages` 帧 delta 后返回最终 AI 文本。
- `stream(message, thread_id=None) -> Iterator[StreamEvent]`：透传 LangGraph 的
  `stream_mode=["values", "messages", "custom"]`，外加一个收尾 `end` 事件（带去重后的 usage）。
- `reset_agent()`：清掉 agent / skills / mcp / model 缓存——`update_mcp_config` 与
  `update_skill` 内部会自动调用。
- 配套 Gateway-镜像方法：`list_models / get_model / list_skills / install_skill /
  get_mcp_config / update_mcp_config / get_memory / upload_files / get_artifact / ...`，
  返回 schema 与 Gateway Pydantic response model 严格一致——`TestGatewayConformance`
  套件用 Pydantic 反向校验防漂移：Gateway 加了必填字段而 EmbeddedClient 没补，CI 直接红。

**EmbeddedClient 与 Gateway 跑同一份 `make_lead_agent` + `build_middlewares`**，所以任何中间件
变更同时影响两条路径——这是有意的，框架行为不能因为入口不同而分叉。常见的「我加个开关只
影响 Gateway」需求基本都应该改成「给 `build_middlewares` 加可选参数，两条路径都吃」。

EmbeddedClient 的 stream 路径还有一个边界友好的细节：它注入 tracing callbacks 与 Langfuse
metadata 的方式与 Gateway worker 完全一致（共用 `inject_langfuse_metadata`），所以 trace 在
两条路径下的形状一样，运维查问题不需要分两套心智模型。

## 4. TUI：嵌入式的 UI 壳，验证边界的活样本

`<framework-pkg>/tui/` 是 Textual 终端 UI，但它**只通过 EmbeddedClient 调框架**，自身是
framework 内部模块的纯消费者：

- `[project.scripts]` 在 `packages/harness/pyproject.toml` 里登记 `<cli> = "<framework-pkg>.tui.cli:main"`，
  装包之后即得到独立可执行命令。
- `textual` 是 optional dep（`<framework-pkg>[tui]`），core 安装保持精简；缺 textual 时 CLI 自动
  退化为 headless help（`--print` / `--json` 子模式仍然工作），不报错。
- **绝对 import** 而非相对：`from <framework-pkg>.tui.app import run_tui`——边界测试只检查
  import 字符串前缀，相对 import 写法虽然语义等价但容易在重构时把 `app` 拼到字符串里被误判。
- 模块内部分层严格：`cli.py`（pure，`plan_launch()` 决策）、`view_state.py`（pure，
  `reduce(state, action)`）、`runtime.py`（pure，`translate(StreamEvent) -> [Action]`）、
  `app.py`（Textual 唯一接触点）——前三层零 textual 依赖，可直接单测；textual pilot 只
  覆盖 `app.py`。
- `tui/persistence.py::ThreadMetaWriter` 用 harness 自带的 `init_engine_from_config` +
  `make_thread_store` 直接写 `threads_meta` SQL 表——**这是同进程不经 Gateway 也能让 Web UI
  侧栏看到对话**的关键。所有 DB 工作跑在 daemon 线程的单一 asyncio event loop 上
  （`_LoopThread`，`asyncio.run_coroutine_threadsafe(coro, loop).result(timeout=15)`），因为
  SQLAlchemy async engine 绑死创建它的 loop，跨 loop 用必报
  `Task got Future attached to a different loop`。
- ThreadMetaWriter 所有方法 `try / except Exception: pass`——最大努力写入：
  `threads_meta` 是可见性便利，不能成为对话失败的理由；DB 不可用时退化为 no-op。

TUI 本身就是边界纪律的活样本：它能跑 = harness 能脱离 app 工作。

## 5. 关键不变量

1. **依赖单向**：`<app-pkg>` → `<framework-pkg>` 允许，反向禁止；CI 用 AST 扫强制。
2. **同一份 agent 工厂**：EmbeddedClient 与 Gateway worker 共用 `make_lead_agent` +
   `build_middlewares`，**禁止任何一方维护副本**——双份逻辑是质量警报。
3. **EmbeddedClient 写 `threads_meta`**：让 TUI / 嵌入式创建的 thread 在 Web UI 侧栏可见，
   避免「我刚跑过的对话哪儿去了」割裂感。
4. **TUI 绝对 import**：`from <framework-pkg>.tui.app import run_tui`，规避边界测试误中。
5. **单一异步 engine**：harness 的 `init_engine_from_config` 与 Gateway lifespan 用同一个；
   同进程多个 engine 绑不同 loop 必然跨 loop 报错。
6. **数据通过函数参数过界**：harness 需要 user_id / thread_id 时由 app 层通过参数 /
   `RunnableConfig.configurable` 传入，绝不能反向 `import` Gateway 的 Request 对象。

## 6. 常见踩坑 + 调试入口

踩坑：

1. **Harness 文件偷偷 `from <app-pkg>.gateway.deps import current_user`**：CI 必拦；解决方案
   是把 user_id 作为参数从 app 层传进来，或者用 harness 自己的 `runtime.user_context`。
2. **业务逻辑跑进 `<app-pkg>/`**：FastAPI router 里有大段 agent 编排，框架变成空壳。审 PR
   时看 `<framework-pkg>` 是否在变厚，应该越来越厚才对。
3. **EmbeddedClient 抄一份 `build_middlewares`**：表面上「只是为了 TUI 加个开关」，实际
   双份漂移；正确做法是给原函数加可选参数，两条路径都吃。
4. **TUI 不写 `threads_meta`**：用户跑完 TUI 切去 Web UI 找不到刚才的对话。
5. **同进程多个异步 engine 绑不同 loop**：典型症状是 SQLAlchemy 报
   `Task got Future attached to a different loop`，原因往往是 TUI 起了自己的 engine。
6. **跨进程共享内存状态**：Gateway `RunManager` / `StreamBridge` 是 in-process 单例，所以
   docker-compose 里 `gateway` service 默认 `--workers 1`；想多 worker 必须先有共享存储
   （Redis 等）替换它们。

调试入口：

- `pytest <repo-root>/backend/tests/test_harness_boundary.py -v` —— 边界违例直接列文件 +
  module + lineno。
- TUI 启动后看 `threads_meta` 表 / Web UI 侧栏，5 秒内有新行即说明嵌入式持久化通畅。
- `<framework-pkg>/__init__.py` grep `<app-pkg>` 必须零命中；任何外露 API 应在
  `<framework-pkg>.agents` / `<framework-pkg>.client` 等子模块里。
- 跨 loop 异常时检查 `init_engine_from_config` 是否被调用了两次：harness 与 app 各起一次
  就出问题。

[[agent-graph-factory]] [[config-and-hot-reload]] [[packaging-and-deployment]] [[gateway-runs-and-sse]] [[embedded-client-and-tui]]
