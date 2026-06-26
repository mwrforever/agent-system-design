---
name: mcp-integration
description: 设计 agent 与 MCP（Model Context Protocol）多 server 的集成——lazy 初始化 + mtime 缓存、stdio / SSE / HTTP / OAuth 三种 transport、stdio 路径回译、deferred + tool_search 按需 promote。
---

## 何时用

- 想让用户通过 `mcpServers` 配置接入第三方工具集（Anthropic / 社区生态）
- MCP server 数量多，schema 太大塞不进 LLM 上下文
- HTTP MCP server 需要 OAuth 认证
- stdio MCP server 输出本地文件路径，需要回译成虚拟路径

## 设计思想

1. **MultiServerMCPClient 统一管理**：用 `langchain-mcp-adapters` 把 N 个 server 合并成一个 tool list。
2. **lazy 初始化**：agent 工厂里 `get_cached_mcp_tools()`，首次使用时才连 server；启动期不连。
3. **mtime 缓存**：以 `extensions_config.json` 文件 mtime 为 cache key；文件改了下次自动失效。
4. **三种 transport**：
   - **stdio**：本地命令子进程；需要 pin cwd 到 thread workspace + TMP 到 workspace/.mcp/tmp/
   - **SSE / HTTP**：远程 server；支持 OAuth `client_credentials` / `refresh_token` 自动刷
5. **stdio 路径回译**：MCP 工具返回的 `ResourceLink` / 文本里的本地路径，如果落在 thread 的 user-data 树内，回译成 `/mnt/user-data/...`；否则保留。
6. **deferred + tool_search 配合**：MCP 工具是 deferred 默认成员（schema 不绑定到模型）；模型用 `tool_search(name="...")` 显式 promote 后才能调用 → 见 [[tool-assembly-and-policy]]。
7. **失败隔离**：单个 server 连接失败不影响其他；返回 error 工具，agent 继续。

## 实现模板

### 配置（extensions_config.json）

```json
{
  "mcpServers": {
    "filesystem": {
      "enabled": true,
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/mnt/user-data/workspace"]
    },
    "github": {
      "enabled": true,
      "type": "http",
      "url": "https://api.example.com/mcp",
      "headers": {"X-Client": "agent_framework"},
      "oauth": {
        "token_endpoint": "https://auth.example.com/token",
        "grant_type": "client_credentials",
        "client_id": "$GH_CLIENT_ID",
        "client_secret": "$GH_CLIENT_SECRET"
      }
    }
  }
}
```

### 缓存 + 加载

```python
_mcp_cache: dict[str, tuple[float, list[BaseTool]]] = {}    # path → (mtime, tools)
_mcp_lock = asyncio.Lock()


async def get_cached_mcp_tools(*, app_config=None) -> list[BaseTool]:
    config_path = (app_config or get_app_config()).extensions_config_path
    mtime = config_path.stat().st_mtime
    cached = _mcp_cache.get(str(config_path))
    if cached and cached[0] == mtime:
        return cached[1]

    async with _mcp_lock:
        cached = _mcp_cache.get(str(config_path))
        if cached and cached[0] == mtime: return cached[1]
        tools = await _load_mcp_tools(config_path)
        _mcp_cache[str(config_path)] = (mtime, tools)
        return tools


async def _load_mcp_tools(config_path) -> list[BaseTool]:
    config = json.loads(config_path.read_text())
    enabled = {k: v for k, v in config.get("mcpServers", {}).items() if v.get("enabled")}
    client = MultiServerMCPClient(enabled)
    try:
        raw_tools = await client.get_tools()
    except Exception:
        logger.exception("MCP tool discovery failed")
        return []
    return [_wrap_with_path_translation(t) for t in raw_tools]
```

### stdio 子进程 pin cwd / TMP

```python
def _prepare_stdio_env(server_cfg: dict, thread_id: str, user_id: str) -> dict:
    """stdio server 启动时把 cwd / TMPDIR 钉到 thread workspace，避免污染外部目录."""
    workspace = thread_workspace_dir(user_id, thread_id)   # users/<u>/threads/<t>/user-data/workspace
    mcp_tmp = workspace / ".mcp/tmp"
    mcp_tmp.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ)
    env.setdefault("TMPDIR", str(mcp_tmp))
    env.setdefault("TMP",    str(mcp_tmp))
    env.setdefault("TEMP",   str(mcp_tmp))
    # operator 显式配置的 cwd / env 永远不覆盖
    if server_cfg.get("cwd") is None:
        server_cfg["cwd"] = str(workspace)
    return env
```

### OAuth 自动刷 token

```python
class OAuthTokenSource:
    def __init__(self, cfg):
        self.cfg = cfg
        self._token: str | None = None
        self._expires_at: float = 0
        self._lock = asyncio.Lock()

    async def headers(self) -> dict[str, str]:
        async with self._lock:
            if not self._token or time.time() > self._expires_at - 30:
                await self._refresh()
            return {"Authorization": f"Bearer {self._token}"}

    async def _refresh(self):
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.post(self.cfg["token_endpoint"], data={
                "grant_type": self.cfg["grant_type"],
                "client_id": resolve_env(self.cfg["client_id"]),
                "client_secret": resolve_env(self.cfg["client_secret"]),
            })
            r.raise_for_status()
            payload = r.json()
        self._token = payload["access_token"]
        self._expires_at = time.time() + int(payload.get("expires_in", 3600))
```

### 路径回译

```python
def _translate_mcp_output(text: str, sandbox: Sandbox) -> str:
    """MCP 工具返回里的本地路径若落在 thread user-data，回译成 /mnt/user-data/..."""
    for mapping in sandbox.path_mappings:
        if mapping.local_path in text:
            text = text.replace(mapping.local_path, mapping.container_path)
    return text


def _wrap_with_path_translation(tool: BaseTool) -> BaseTool:
    orig = tool.arun
    async def wrapped(*args, **kwargs):
        result = await orig(*args, **kwargs)
        if isinstance(result, str):
            sandbox = ensure_sandbox_initialized()
            return _translate_mcp_output(result, sandbox)
        return result
    tool.arun = wrapped
    return tool
```

## 反模式

- ❌ agent 启动时 await 所有 MCP server 连接 → 一个 server 慢启动拖死整个 agent
- ❌ MCP 工具 schema 全部绑定到模型 → context 爆炸（300+ tools 不可用）
- ❌ stdio server 没 pin cwd → 在用户当前工作目录乱建文件
- ❌ OAuth token 不刷新 → 一小时后所有 MCP 调用 401
- ❌ 路径回译对全文 string-replace → 把无关 substring 也替换坏
- ✅ MCP server 失败 → 返回空 list + 记日志，让其他 server 继续工作
- ✅ token endpoint 抓异常时 fail-closed，不让明文 401 露出

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[tool-assembly-and-policy]] [[config-and-hot-reload]] [[sandbox-tools-and-safety]]
- MCP 协议：https://modelcontextprotocol.io/
