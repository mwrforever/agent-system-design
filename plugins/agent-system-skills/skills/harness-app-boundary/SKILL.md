---
name: harness-app-boundary
description: 设计 agent 系统的 "框架层 / 应用层" 双包分层——单向依赖、CI 守护边界、嵌入式客户端复用同一图。让 agent 框架可独立发布，应用层（Gateway / IM 通道 / TUI）可换皮不动核。
---

## 何时用

- 你的 agent 项目同时是"产品"和"想发布的框架"
- 想让 TUI / 定时任务 / 其他后端嵌入式使用同一 agent，不经过 HTTP
- 防止前期野蛮生长把 framework 代码和 web 框架代码搅在一起
- 团队大了想分代码所有权

## 设计思想

1. **两层包，单向依赖**：
   - **Harness 层**（可发布）：纯 Python 库，含 agent / 工具 / 沙箱 / Skill / Memory / 模型工厂 / 运行时调度 / 持久化 / 反射 / 追踪 / TUI 全套。
   - **App 层**（不发布）：FastAPI Gateway + IM 通道适配。
   - `app/*` 可以 `from harness.* import ...`；`harness/*` **不能** `from app.* import ...`。
2. **CI 强制边界**：写一个 AST 扫描测试，任何 `harness/` 文件 import `app.*` → 失败。
3. **嵌入式客户端 = 直接调图**：`HarnessClient.chat()` / `.stream()` 在进程内驱动同一 LangGraph 图，无需 FastAPI。`chat()` 把流式 delta 累积成完整 AIMessage 文本返回；`stream()` 透出原始 `StreamEvent`。
4. **同源数据**：嵌入式 / Gateway / IM 通道都用同一 `config.yaml` + 同一 SQLite/Postgres + 同一文件系统目录。TUI 写的 thread 在 Web UI 也能看到。
5. **持久化最小依赖**：harness 自带一个最薄的 `init_engine_from_config()`，独立于 Gateway，让嵌入式场景可以写 `threads_meta` 让 Web UI 列出。

## 实现模板

### 包结构

```
<repo-root>/
├── packages/harness/                ← 可发布 (agent-harness)
│   ├── pyproject.toml
│   └── agent_framework/
│       ├── agents/                   # 图工厂 + 中间件 + ThreadState
│       ├── subagents/
│       ├── sandbox/
│       ├── tools/
│       ├── skills/
│       ├── mcp/
│       ├── models/
│       ├── memory/
│       ├── runtime/                  # RunManager / StreamBridge / Journal
│       ├── persistence/              # SQLAlchemy ORM + alembic
│       ├── config/                   # AppConfig + hot reload
│       ├── reflection/
│       ├── tracing/
│       ├── community/                # 可选社区工具
│       ├── tui/                      # Textual 终端 UI
│       └── client.py                 # ⭐ HarnessClient
└── app/                              ← 不发布
    ├── gateway/
    └── channels/
```

### 嵌入式客户端

```python
# harness/client.py
class HarnessClient:
    """在进程内驱动 lead_agent 图，无需 HTTP."""

    def __init__(self, *, config_path: Path | None = None,
                 checkpointer=None, agent_name: str | None = None):
        self.app_config = get_app_config(path=config_path)
        self.checkpointer = checkpointer or get_default_checkpointer()
        self.agent_name = agent_name
        self._agent = None

    def _build_agent(self, context: dict):
        from agent_framework.agents.lead_agent.agent import make_lead_agent
        config = {"configurable": {**context}, "context": {**context}}
        return make_lead_agent(config)

    def chat(self, message: str, thread_id: str | None = None) -> str:
        """同步：累积 messages delta，返回最终 AI 文本."""
        full_text = ""
        message_id = None
        for ev in self.stream(message, thread_id):
            if ev.event == "messages":
                chunk, _meta = ev.data
                if chunk.get("type") == "ai" and chunk.get("id"):
                    if message_id is None or chunk["id"] == message_id:
                        message_id = chunk["id"]
                        full_text += chunk.get("content", "")
            elif ev.event == "end":
                break
        return full_text

    def stream(self, message: str, thread_id: str | None = None) -> Iterator[StreamEvent]:
        thread_id = thread_id or new_uuid()
        agent = self._build_agent({"thread_id": thread_id,
                                    "agent_name": self.agent_name})
        if self.checkpointer:
            agent.checkpointer = self.checkpointer
        for chunk in agent.stream(
            {"messages": [{"type": "human", "content": message}]},
            config={"configurable": {"thread_id": thread_id}},
            stream_mode=["values", "messages", "custom"],
        ):
            yield _to_stream_event(chunk)
        yield StreamEvent(id="", event="end", data=None)

    def reset_agent(self):
        """配置或 skill 改了后强制下次重新构造."""
        self._agent = None
```

### 边界守护测试

```python
# tests/test_harness_boundary.py
import ast, pathlib

def _imports_from_app(path: pathlib.Path) -> list[str]:
    tree = ast.parse(path.read_text())
    bad = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            if node.module and node.module.startswith("app."):
                bad.append(node.module)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.startswith("app."):
                    bad.append(alias.name)
    return bad


def test_harness_does_not_import_app():
    """Harness 不得依赖 App 层."""
    harness_root = pathlib.Path("packages/harness/agent_framework")
    offenders: dict[str, list[str]] = {}
    for py in harness_root.rglob("*.py"):
        bad = _imports_from_app(py)
        if bad:
            offenders[str(py)] = bad
    assert not offenders, f"Harness depends on app.* — forbidden:\n{offenders}"
```

### Console 脚本（TUI / 嵌入式入口）

```toml
# packages/harness/pyproject.toml
[project]
name = "agent-harness"
version = "0.1.0"

[project.scripts]
agent_framework = "agent_framework.tui.cli:main"

[project.optional-dependencies]
tui = ["textual>=0.50"]
```

`tui/cli.py` 内：

```python
def main():
    """TTY → TUI；否则打印 headless help."""
    if not sys.stdin.isatty():
        print(headless_help()); return
    try:
        from agent_framework.tui.app import run_tui     # ⭐ 绝对 import 避开 boundary test 误判
    except ImportError:
        print("Textual not installed. Run: pip install agent-harness[tui]"); return
    run_tui()
```

### 独立 init_engine

```python
# harness/persistence/engine.py
async def init_engine_from_config(config: AppConfig):
    """嵌入式 / TUI 用的最薄入口；不依赖 FastAPI app.state."""
    engine = create_async_engine(config.database.dsn)
    await bootstrap_schema(engine, backend=config.database.backend)
    return engine
```

## 反模式

- ❌ Harness 文件里 `from app.gateway.deps import get_run_manager` → 框架不可独立发布
- ❌ App 层把"业务逻辑"写到自己里而不是 Harness → 框架是空壳，用户 fork 后还得改 Gateway
- ❌ 嵌入式客户端单独抄一份 build_middlewares → 双份代码漂移
- ❌ TUI 不写 threads_meta → Web UI 看不到 TUI 的会话，用户体验割裂
- ❌ 同一进程多个 SQLAlchemy 异步 engine 绑定到不同 event loop → 跨 loop 报错
- ✅ 嵌入式 / Gateway / TUI 都通过 `make_lead_agent` 同一工厂
- ✅ 边界测试盯死 import 方向

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[agent-graph-factory]] [[config-and-hot-reload]] [[packaging-and-deployment]]
