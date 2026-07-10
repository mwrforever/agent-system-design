---
name: mcp-integration
description: 设计 agent 与 MCP（Model Context Protocol）多 server 集成--lazy 加载 + mtime 缓存（extensions_config.json 变更按 mtime 失效重载）、stdio/SSE/HTTP/OAuth 多传输、stdio 路径反向翻译（物理路径 -> 虚拟路径 /mnt/user-data/...，与 sandbox 路径翻译对称）、deferred promote（MCP 工具标 helix_mcp tag，经 assemble_deferred_tools 切入延迟 catalog，模型 tool_search 按需 promote）、session pool 单例生命周期（owner-task 同步化：多 server session 按 (server,user:thread) 复用 + 启停原子，规避 anyio 跨任务 cancel scope 泄漏）。当你想接入 MCP server、排查"工具调用丢状态 / OAuth 401 / 路径不可解析 / 跨任务 cancel scope 崩溃 / 配置热更新不生效 / stdio 子进程乱建文件"时调用本 skill。
---

## 何时用

- 想让 agent 通过 `extensions_config.json -> mcpServers` 接入第三方 MCP 工具集（stdio 本地子进程或 SSE/HTTP 远程 server）
- MCP server 数量多、schema 太大塞不进 LLM 上下文 -> MCP 工具标 deferred，模型经 `tool_search` 按需 promote（见 [[tool-assembly-and-policy]]）
- 有状态 MCP server（如 Playwright 浏览器自动化）跨多次工具调用需保持 session -> 持久 session pool
- stdio MCP server 返回本地文件路径，模型只认 `/mnt/user-data/...` 虚拟路径 -> 路径反向翻译
- HTTP/SSE MCP server 需要 OAuth 认证（`client_credentials` / `refresh_token` 自动刷 token）
- 排查"Gateway API 改了 extensions_config.json 但运行时没生效"（mtime 缓存失效）、"sync 调用路径跨任务 cancel scope 崩溃"（session pool owner-task）、"OAuth token 过期 401"
- 在端到端链路中定位 MCP 工具落点（④建图装配标 tag + ⑥执行调用经 session pool）

## 设计方案（为什么这么设计）

### 核心矛盾：来源杂 × 上下文窗有限 × 有状态 server × 配置热更新 × anyio 跨任务约束

MCP 集成同时背负五重压力：(a) N 个 server 工具 schema 膨胀到几百个，全绑模型上下文爆炸；(b) 有状态 server（Playwright、REPL）跨调用必须复用 session；(c) Gateway API 在独立进程改 `extensions_config.json`，运行时必须热感知；(d) stdio server 返回宿主物理路径，模型只认虚拟路径 `/mnt/user-data/...`；(e) MCP `ClientSession` 基于 anyio task group，cancel scope 必须由进入它的同一个 task 退出，而 sync 工具包装每次调用走全新 `asyncio.run`（不同 task），直接复用 session 会崩。

**解法：五层串联，每层独立可控。** lazy+mtime 缓存解决热更新与性能；多传输 + OAuth 解决接入面；session pool owner-task 模型解决跨任务 cancel scope；路径反向翻译解决虚拟路径契约；deferred promote 解决上下文爆炸。

### 1. lazy 加载 + mtime 缓存（extensions_config 频繁变更不每请求重载）

MCP 工具装载昂贵（每 server 建一个 session 做 tool discovery），但结果相对静态。若每请求重载，N 个 server × 每请求一次连接 = 不可接受。但 Gateway API 在独立进程写配置（增删 server、改传输、改 OAuth），运行时必须感知，否则要重启。

**解法：模块级单例缓存 + lazy 初始化 + mtime 失效。**

```python
# 伪代码：lazy + mtime 失效
_mcp_tools_cache: list[BaseTool] | None = None
_config_mtime: float | None = None

def get_cached_mcp_tools() -> list[BaseTool]:
    if _is_cache_stale():              # current_mtime > cached_mtime -> 过期
        reset_mcp_tools_cache()        # 清缓存 + close_all_sync + reset_session_pool
    if not _cache_initialized:
        # lazy：首次调用才连 server，启动期不连（避免慢启动 server 拖死 agent 启动）
        if loop.is_running():          # 已在运行循环（LangGraph Studio），不能嵌套 asyncio.run
            worker_thread.submit(asyncio.run(initialize_mcp_tools())).result()
        else:
            asyncio.run(initialize_mcp_tools())
        _config_mtime = _get_config_mtime()   # 记录 mtime 供后续失效判断
    return _mcp_tools_cache

def reset_mcp_tools_cache():
    _mcp_tools_cache = _cache_initialized = _config_mtime = None
    get_session_pool().close_all_sync()    # schema 已消失的工具不能持有 open session
    reset_session_pool()                   # null 单例，下次 get_session_pool() 重建
```

关键点：`get_mcp_tools()` 内部用 `ExtensionsConfig.from_file()`（非 `get_extensions_config()` 缓存单例）直读磁盘，确保 Gateway API 在另一进程写入的最新配置被读到。`reset_mcp_tools_cache()` 不仅清工具缓存，还联动关 session pool--一个 schema 已从 catalog 消失的工具不能继续持有到其 server 的 open session。

### 2. 多传输：stdio / SSE / HTTP

| 传输 | 场景 | 必填 | 可选 |
|---|---|---|---|
| **stdio** | 本地命令子进程（filesystem / Playwright / git） | `command` + `args` | `env`、`cwd`、`tool_call_timeout` |
| **sse** | 远程 server，SSE 长连接 | `url` | `headers`、`oauth` |
| **http** | 远程 server，HTTP 请求 | `url` | `headers`、`oauth` |

```python
# 伪代码：build_server_params 传输归一
def build_server_params(server_name, config) -> dict:
    transport = config.type or "stdio"     # type 与 transport 别名归一（_accept_transport_alias，type 优先）
    if transport == "stdio":
        require(config.command)            # 缺 command -> ValueError
        return {"transport": "stdio", "command": ..., "args": ..., "env"?}
    elif transport in ("sse", "http"):
        require(config.url)                # 缺 url -> ValueError
        return {"transport": transport, "url": ..., "headers"?}
    else: raise ValueError
```

**stdio 的 cwd / TMP 钉扎**：stdio server 作为本地子进程，其 `cwd` 和 `TMPDIR/TMP/TEMP` 必须钉到当前 thread 的 mounted user-data 树（`workspace/` + `workspace/.mcp/tmp/`），否则工具写 `os.tmpdir()` 落到宿主不可达 temp 路径、相对路径输出无法被 sandbox/artifact API 解析。钉扎用 `setdefault`--operator 显式配置的 `cwd`/`env` 永远不被覆盖。SSE/HTTP 无本地 cwd，跳过整个文件系统准备。

### 3. 路径反向翻译（物理路径 -> 虚拟路径 /mnt/...）

sandbox 契约规定模型只看虚拟路径 `/mnt/user-data/{workspace,uploads,outputs}/...`（见 [[sandbox-abstraction]]）。bash 工具做**正向翻译**（虚拟 -> 物理，`replace_virtual_path`）；MCP 工具做**反向翻译**（物理 -> 虚拟）。二者对称，共同维持"模型永不接触宿主路径"的不变量。

stdio MCP server 的 `cwd`/TMP 已钉在 thread user-data 树内，所以它产的文件本来就落在 sandbox/artifact API 能服务的位置--唯一缺的是虚拟前缀。`_local_uri_to_virtual_path` 做纯确定性 host->virtual 映射：不拷贝文件、不需要 trusted-root 列表、不暴露 thread 树外的文件。

```python
# 伪代码：物理路径 -> 虚拟路径
def _local_uri_to_virtual_path(uri, *, thread_id, user_id, source_base_dir) -> str | None:
    src = _local_path_from_uri(uri, base_dir=source_base_dir)   # 远程 URI (http/https/data) -> None
    if src is None: return None
    real = src.resolve()
    if not real.is_file(): return None            # 不是已存在文件，不改写（防误伤）
    user_data_root = get_paths().sandbox_user_data_dir(thread_id, user_id).resolve()
    try: relative = real.relative_to(user_data_root)
    except ValueError: return None                # 树外文件，原样保留
    return f"{VIRTUAL_PATH_PREFIX}/{relative.as_posix()}"   # -> /mnt/user-data/...
```

**保守策略（防误伤）**：ResourceLink 块（schema 保证是文件引用）无条件翻译；自由文本路径仅当候选 token 解析到树内**已存在文件**才改写（过度 regex 匹配无副作用）；裸文件名（`Saved as page.yml`）仅当与**本次调用**创建/修改的文件（调前 snapshot + 调后 diff）唯一匹配才改写；远程 URI / 树外文件返回 `None`（原样保留）。

### 4. deferred promote（MCP 工具多，延迟发现防上下文爆炸）

MCP server 接 N 个后工具 schema 几百个，全绑模型 -> 上下文窗被 schema 占满、模型选错工具概率上升、prompt 成本线性上涨。**解法：MCP 工具标 deferred tag，装配时切入延迟 catalog，模型只看名字，需要时 `tool_search` 拉完整 schema 并 promote。**

```python
# 伪代码：tag 单一真值 + deferred 切分 + 运行时 promote
MCP_TOOL_METADATA_KEY = "helix_mcp"
def tag_mcp_tool(tool):  tool.metadata["helix_mcp"] = True; return tool
def is_mcp_tool(tool):   return tool.metadata.get("helix_mcp") is True   # 不用 name 前缀推断

# ④建图: get_available_tools() -> for t in mcp_tools: tag_mcp_tool(t)
#         assemble_deferred_tools(filtered) -> deferred = [t for t in filtered if is_mcp_tool(t)]
#                                         -> DeferredToolCatalog + catalog_hash
#         fail-closed: 启用 + MCP 存活 + 无 deferred 集 -> RuntimeError，不裸绑 schema
# ⑥执行: model 调 tool_search("select:..." | "+slack send" | "notebook jupyter")
#         -> catalog.search 最多 5 个匹配 -> Command(update={"promoted": {catalog_hash, names}})
#         -> DeferredToolFilterMiddleware 按 catalog_hash 放行已提升 schema，阻截未提升
```

tag 定义（`mcp_metadata.py`）+ deferred 切分 + catalog + tool_search + filter middleware 的完整机制见 [[tool-assembly-and-policy]]；本 skill 聚焦 MCP 工具的装载、包装与 tag 的源头定义。

### 5. session pool owner-task 模型（核心难点：anyio same-task cancel-scope）

有状态 MCP server（Playwright 浏览器）跨调用必须复用 session，否则打开的页面/填好的表单全丢。naive `langchain-mcp-adapters` 设 `session=None`，每次调用起一个新 session--对无状态 server 无害，对有状态 server 致命。

**anyio 跨任务约束**：MCP `ClientSession` 基于 anyio task group，**cancel scope 必须由进入它的同一个 task 退出**。sync 工具包装（`make_sync_tool_wrapper`）每次调用走全新 `asyncio.run`（不同 task），所以 call N 进入的 session 会在 call N+1 从不同 task 退出 -> 崩（issue #3379）。

**解法：owner-task 模型 + 模块级单例。**

```python
# 伪代码：owner-task 模型（CM 进出始终在 owner task）
async def _run_session(connection, ready, close_evt):
    cm = create_session(connection)
    session = await cm.__aenter__()      # 进入 CM（cancel scope）
    await session.initialize()
    ready.set_result(session)             # 发布 live session 给调用方
    await close_evt.wait()                # 阻塞直到 shutdown signal
    # finally: await cm.__aexit__()       # same-task 退出 CM，满足 anyio 约束（cancel/error/graceful 都成立）

async def get_session(server_name, scope_key, connection) -> ClientSession:
    key = (server_name, scope_key)        # scope = f"{user_id}:{thread_id}"（per-(user,thread) 隔离）
    current_loop = asyncio.get_running_loop()
    # 阶段1: _lock 下原子决策（无 await）：复用命中 / join in-flight / 成为创建者 + LRU 逐出(MAX=256)
    #   三态复用: owning_loop is current_loop and not loop.is_closed()；跨 loop/已关 -> 逐出旧 + 建新
    #   in-flight 去重: 同 key 并发首调用 collapse 到一个创建，follower await shield(ready)
    # 阶段2: 关闭逐出项（同 loop await / 跨 loop 路由 / in-flight owner cancel=True）
    # 阶段3: await shield(ready)  -- 等 owner 发布；取消时分"owner 已失败"(只等 unwound) vs "调用方被取消"(signal+cancel)
    # 阶段4: promote in-flight -> _entries（LRU），仅当 in-flight 记录仍活
```

关键决策：
- **owner-task**：所有 shutdown 路径只 signal `close_evt`（可选 `task.cancel()`），owner task 在自己的 `finally` 块跑 `__aexit__`--same-task 保证在 cancel / error / graceful shutdown 下都成立。
- **scope 维度**：`scope_key = f"{user_id}:{thread_id}"`。用 user+thread 而非仅 thread_id--文件系统隔离是 per-(user, thread)，仅 thread_id 可能让两个 user 的碰撞 thread_id 共享一个有状态 session。
- **cancel 分叉**：调用取消时区分"owner 已报失败"（让其 `finally` 完成，不 cancel）vs"调用方被取消 mid-init"（signal close + cancel owner，因为 owner 可能阻塞在 `initialize()` 里，`close_evt` 唤不醒它）。
- **单例**：`get_session_pool()` 用 `threading.Lock`（非 `asyncio.Lock`，因为要从 async 与 sync/worker-thread 两路安全获取）保证冷启动竞态只建一个 pool。

**同步化生命周期（`close_all_sync`）**：`reset_mcp_tools_cache` 等 sync 路径需在无活跃循环或当前循环内关全部 session。关 session 语义按 owning loop 分叉：

```python
# 伪代码：close_all_sync 按 owning loop 分叉（不自死锁）
def close_all_sync():
    for loop, task, close_evt, cancel in owners:   # in-flight owner cancel=True
        if loop.is_closed(): continue
        if loop is current_running_loop:   # 不能同步等（死锁），只 signal
            close_evt.set(); if cancel: task.cancel()
        elif loop.is_running():            # 其他线程 loop：确定性 teardown
            run_coroutine_threadsafe(_shutdown(...), loop).result(timeout=5.0)
        else:                              # idle loop：run_until_complete
            loop.run_until_complete(_shutdown(...))
```

`reset_mcp_tools_cache()` -> `close_all_sync()` + `reset_session_pool()`：前者关现有 session（按 owning loop 分叉），后者 null 单例。不在当前运行 loop 同步等 teardown--那是自死锁。

### 6. MCP 工具包装（五层 compose 到一个 StructuredTool）

`_make_session_pool_tool` 把一个裸 MCP `BaseTool` 包装成 `StructuredTool`，在一个 `coroutine` 里 compose 五层：

```python
# 伪代码：_make_session_pool_tool 五层 compose
async def call_with_persistent_session(runtime, **arguments):
    # 1. scope 解析：thread_id（runtime.context/config/get_config）+ user_id（resolve_runtime_user_id）
    scope_key = f"{user_id}:{thread_id}"
    # 2. [仅 stdio] 文件系统准备（offload 线程，snapshot 遍历会阻塞 loop）：钉 cwd + TMPDIR/TMP/TEMP + 调前 snapshot
    # 3. session 获取：pool.get_session(server_name, scope_key, connection) -> 复用或新建持久 session
    # 4. interceptor 链（OAuth 注入 Authorization 头 + 自定义）-> session.call_tool
    #    interceptor 注入的 headers 经 MCP meta={"headers": ...} 转发给 stdio 调用
    # 5. 结果转换 + 路径反向翻译（offload 线程）：
    #    _convert_call_tool_result: CallToolResult -> content_and_artifact
    #    + ResourceLink.uri / 自由文本路径 / 裸文件名 -> 虚拟路径翻译
    #    [stdio + 有文本] 调后 snapshot diff -> 裸文件名关联
return StructuredTool(coroutine=call_with_persistent_session, response_format="content_and_artifact", ...)
# 包装后还给 async-only 工具补 make_sync_tool_wrapper（sync caller 才能调）
```

### 7. 失败隔离

单个 server tool discovery 失败不影响其他：`get_mcp_tools` 用 `asyncio.gather` 并行每 server 调 `load_server_tools`，单 server 异常 -> 返回空 list + warn 日志，其他 server 继续贡献工具。整个装载链最外层 try/except -> 失败返回空 list，agent 继续跑（无 MCP 工具）。

```python
# 伪代码：单 server 失败不影响其他 + 精确路由
async def load_server_tools(server_name):
    try: return await client.get_tools(server_name=server_name)
    except Exception: logger.warning(...); return []   # 坏 server 返回空 list
tools_by_server = await asyncio.gather(*(load_server_tools(name) for name in servers_config))
# 仅 stdio + 带前缀的工具走 _make_session_pool_tool；HTTP/SSE 不 pool（#3203）
# zip(servers_config.keys(), tools_by_server, strict=True) 按产出分组精确路由（不靠 name 前缀扫描）
```

### 边界

- **与 [[tool-assembly-and-policy]]**：MCP 工具是五源之一。本 skill 产出"可被装配的 MCP BaseTool 列表 + tag 定义"，装配侧（`get_available_tools` 聚集 + 去重 + 打 tag）、deferred 切分（`assemble_deferred_tools`）、catalog + tool_search、`DeferredToolFilterMiddleware` 运行时过滤归 [[tool-assembly-and-policy]]。
- **与 [[sandbox-abstraction]] / [[sandbox-tools-and-safety]]**：路径翻译对称。sandbox bash 工具做正向（虚拟 -> 物理）；MCP 工具做反向（物理 -> 虚拟）。stdio server 的 `cwd`/TMP 钉扎复用 `Paths.sandbox_work_dir` / `sandbox_user_data_dir`，与 sandbox 挂载点同源。
- **与 [[config-and-hot-reload]]**：mtime 缓存失效是 extensions_config 热更新的落点。`ExtensionsConfig.from_file()` 直读磁盘确保跨进程感知。
- **与 [[multi-user-isolation]]**：session pool scope = `(server, user_id:thread_id)`，per-user 隔离；`resolve_runtime_user_id` 与 per-user 目录同源。

### 在端到端链路中的位置

本 skill 处于端到端链路的 **④建图**（装配标 tag + deferred 切分）与 **⑥执行**（MCP 工具调用经 session pool）两跳（见 [[e2e-request-lifecycle]]）：

- **④建图** `make_lead_agent`（见 [[agent-graph-factory]]）调 `get_available_tools(...)` -> MCP 源走 `get_cached_mcp_tools()`（lazy+mtime 缓存）-> 对每个 MCP 工具 `tag_mcp_tool(t)` -> `assemble_deferred_tools` 把 MCP 工具切入 deferred catalog（`is_mcp_tool` 识别）。
- **⑥执行** lead agent 模型循环驱动 MCP 工具调用：模型先调 `tool_search` promote -> `DeferredToolFilterMiddleware` 放行 schema -> 模型调 MCP 工具 -> `_make_session_pool_tool` 包装的 coroutine 走 scope 解析 -> session pool 取/建 session -> interceptor 注入 OAuth 头 -> `session.call_tool` -> 结果经路径反向翻译返回。

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/mcp/cache.py` | `get_cached_mcp_tools`（lazy + mtime 缓存同步入口）+ `initialize_mcp_tools` + `_is_cache_stale` / `_get_config_mtime` + `reset_mcp_tools_cache`（联动 session pool 关闭） | [loading-and-transports.md](./references/code/loading-and-transports.md) §1 |
| `core/helix/mcp/client.py` | `build_server_params`（单 server 传输归一）+ `build_servers_config`（全量配置，失败隔离） | [loading-and-transports.md](./references/code/loading-and-transports.md) §2 |
| `core/helix/mcp/oauth.py` | `OAuthTokenManager`（per-server token 获取/缓存/刷新，双 grant）+ `build_oauth_tool_interceptor` + `get_initial_oauth_headers` | [loading-and-transports.md](./references/code/loading-and-transports.md) §3 |
| `core/helix/config/extensions_config.py` | `McpServerConfig` / `McpOAuthConfig` schema + `ExtensionsConfig.from_file`（直读磁盘 + env 解析）+ `get_enabled_mcp_servers` | [loading-and-transports.md](./references/code/loading-and-transports.md) §4 |
| `core/helix/mcp/session_pool.py` | `MCPSessionPool`（owner-task 持久 session 池）+ `_run_session` + `get_session`（四阶段协议）+ `close_all_sync` / `close_all` / `close_scope` / `close_server` + `get_session_pool` / `reset_session_pool` 单例 | [session-pool.md](./references/code/session-pool.md) §1 |
| `core/helix/mcp/tools.py`（包装） | `_make_session_pool_tool`（五层 compose 包装）+ `_extract_thread_id` + `get_mcp_tools`（装载编排） | [session-pool.md](./references/code/session-pool.md) §2-§3 |
| `core/helix/mcp/tools.py`（路径） | `_local_uri_to_virtual_path` / `_convert_call_tool_result` / `_rewrite_local_paths_in_text` / `_rewrite_unique_bare_filenames` / `_prepare_stdio_workspace`（路径反向翻译 + snapshot diff） | [path-translation-and-deferred.md](./references/code/path-translation-and-deferred.md) §1-§2 |
| `core/helix/tools/mcp_metadata.py` | `MCP_TOOL_METADATA_KEY = "helix_mcp"` + `tag_mcp_tool` / `is_mcp_tool`（deferred promote 的 MCP 侧源头） | [path-translation-and-deferred.md](./references/code/path-translation-and-deferred.md) §3 |
| `core/helix/tools/sync.py` | `make_sync_tool_wrapper`（async-only 工具 sync 包装，每调用走全新 `asyncio.run`--owner-task 设计根因） | [session-pool.md](./references/code/session-pool.md) §4 |

### 模块入口与索引

**装载 + 传输 + OAuth + config schema** 完整源码见 [loading-and-transports.md](./references/code/loading-and-transports.md)：含 `cache.py` 全貌（mtime 失效 + lazy init 的 event loop 陷阱处理 + reset 联动 session pool）、`client.py` 全貌、`oauth.py` 全貌（双检锁防 stampede + `expires_in` 防御性解析 + 响应字段名可配置）、`extensions_config.py` 的 `McpOAuthConfig` / `McpServerConfig` schema + `ExtensionsConfig.from_file` 直读磁盘 + env 变量解析 + `resolve_config_path` 路径解析优先级 + `extensions_config.json` 配置示例。

**路径反向翻译 + 结果转换 + tag 源头** 完整源码见 [path-translation-and-deferred.md](./references/code/path-translation-and-deferred.md)：含 `_local_path_from_uri` / `_local_uri_to_virtual_path` / `_snapshot_workspace_files` / `_changed_workspace_files` / `_prepare_stdio_workspace` / `_result_has_text_content` / `_rewrite_unique_bare_filenames` / `_rewrite_local_paths_in_text` 全貌 + `_convert_call_tool_result` 全貌（MCP `CallToolResult` -> LangChain `content_and_artifact` + ResourceLink/TextContent/ImageContent/EmbeddedResource 翻译钩子）+ `mcp_metadata.py` 全貌 + tag 写入与消费链路图。

**session pool + 工具包装 + 装载编排 + sync 包装** 完整源码见 [session-pool.md](./references/code/session-pool.md)：含 `MCPSessionPool` 完整类（`_run_session` owner task + `get_session` 四阶段协议 + `_signal_close` / `_shutdown` / `_shutdown_entry` 跨 loop 关闭路由 + `close_scope` / `close_server` / `close_all` async + `close_all_sync` 同步化 + 单例）+ `_make_session_pool_tool` 全貌 + `get_mcp_tools` 全貌（interceptor 链 + per-server gather + 精确路由）+ `make_sync_tool_wrapper` 全貌。

### 一次 run 的装配 -> MCP 调用时序

```
make_lead_agent(config)  # ④建图（见 [[agent-graph-factory]]）
  └─ get_available_tools(...)  # 五源聚集（见 [[tool-assembly-and-policy]]）
       └─ MCP 源：get_cached_mcp_tools()
            ├─ _is_cache_stale()? -> reset_mcp_tools_cache() -> close_all_sync + reset_session_pool
            ├─ lazy init（首次）：worker 线程 asyncio.run(initialize_mcp_tools())
            │    └─ get_mcp_tools(): from_file 直读 -> build_servers_config -> OAuth 头/interceptor
            │       -> gather per server（失败隔离）-> stdio 工具 _make_session_pool_tool -> 补 sync 包装
            └─ 返回缓存工具列表
       └─ for t in mcp_tools: tag_mcp_tool(t)
  └─ assemble_deferred_tools(filtered)  # is_mcp_tool 挑 MCP 工具入 deferred catalog
agent.astream(...)  # ⑥执行
  ├─ 模型调 tool_search -> catalog.search -> Command(update={"promoted": {catalog_hash, names}})
  ├─ DeferredToolFilterMiddleware 放行已提升 MCP 工具 schema
  └─ 模型调 MCP 工具 -> _make_session_pool_tool coroutine:
       ├─ scope 解析 -> scope_key = f"{user}:{thread}"
       ├─ [stdio] _prepare_stdio_workspace（offload）：钉 cwd + TMP + 调前 snapshot
       ├─ pool.get_session 四阶段：原子决策 -> 关逐出项 -> await shield(ready) -> promote
       ├─ interceptor 链（OAuth Authorization 头）-> session.call_tool
       ├─ [stdio + 有文本] 调后 snapshot diff
       └─ _convert_call_tool_result（offload）：ResourceLink/文本/裸文件名 -> 虚拟路径翻译
```

## 反模式与陷阱

- ❌ **agent 启动时 await 所有 MCP server 连接** -> 一个慢启动 server 拖死整个 agent 启动。修复：lazy 初始化，`get_cached_mcp_tools()` 首次调用才连。
- ❌ **MCP 工具 schema 全部绑定到模型** -> 上下文爆炸（300+ tools）。修复：`tool_search.enabled` 开启后 MCP 工具标 deferred，模型按需 promote。
- ❌ **stdio server 没 pin cwd / TMP** -> 工具在宿主 cwd 或 OS temp 乱建文件，sandbox/artifact API 解析不到。修复：`_prepare_stdio_workspace` 钉 `cwd` 到 `sandbox_work_dir` + `TMPDIR/TMP/TEMP` 到 `workspace/.mcp/tmp/`（`setdefault` 不覆盖 operator 配置）。
- ❌ **OAuth token 不主动刷新** -> token 在调用途中过期 -> 401。修复：`_is_expiring` 用 `expires_at - refresh_skew_seconds` 主动刷新，双检锁防 stampede。
- ❌ **路径反向翻译对全文 string-replace** -> 把无关 substring 也替换坏。修复：`_local_uri_to_virtual_path` 仅当候选解析到树内**已存在文件**才改写；ResourceLink 无条件翻译，自由文本保守翻译。
- ❌ **裸文件名当路径翻译** -> `Saved as page.yml` 可能匹配到无关的已有文件。修复：`_rewrite_unique_bare_filenames` 仅当 basename 唯一映射到**本次调用**创建/修改的文件（snapshot diff）才翻译。
- ❌ **session pool 让调用方 task 进/出 CM** -> sync 工具包装每调用走全新 `asyncio.run`（不同 task），anyio 抛"exit cancel scope in a different task"（#3379）。修复：owner-task 模型，`_run_session` 专属 task 进 CM + 等 `close_evt`，所有 shutdown 只 signal，owner 自己跑 `__aexit__`。
- ❌ **HTTP/SSE session 也 pool** -> 其传输内部用 anyio TaskGroups，无法从不同 async task 关闭，pooling 触发 cleanup RuntimeError（#3203）。修复：`get_mcp_tools` 仅对 `transport == "stdio"` 且名字带 server 前缀的工具走 `_make_session_pool_tool`，HTTP/SSE 工具不包装。
- ❌ **靠 name 前缀扫描推断工具属于哪个 server** -> 一个 server 名是另一个的前缀时（`"web"` vs `"web_scraper"`）路由到错误 server。修复：`zip(servers_config.keys(), tools_by_server, strict=True)` 按产出分组精确路由。
- ❌ **scope 仅用 thread_id** -> 两个 user 的碰撞 thread_id 共享一个有状态 session，串用户状态。修复：`scope_key = f"{user_id}:{thread_id}"`。
- ❌ **`close_all_sync` 在当前运行 loop 同步等 teardown** -> 自死锁。修复：当前 loop 只 signal `close_evt`，其他线程 loop 走 `run_coroutine_threadsafe` + 超时确定性 teardown。
- ❌ **in-flight 创建被关闭时不 cancel owner** -> owner 阻塞在 `initialize()` 里，`close_evt` 唤不醒它，session 泄漏。修复：in-flight owner 的 shutdown 路径 `cancel=True`，`finally` 仍跑 `__aexit__`。
- ❌ **调用取消时不区分"owner 已失败"vs"调用方被取消"** -> cancel 一个正在 `finally` 跑 `__aexit__` 的 owner 会打断清理。修复：`owner_already_failed = ready.done() and not ready.cancelled() and ready.exception() is not None`，已失败只等 unwound，被取消才 signal+cancel。
- ❌ **`get_session_pool` 用 `asyncio.Lock`** -> sync/worker-thread 路径（`close_all_sync`）无运行 loop 无法获取。修复：`threading.Lock`，不绑定 loop，async 与 sync 两路都安全。
- ❌ **`get_mcp_tools` 用 `get_extensions_config()` 缓存单例** -> Gateway API 在独立进程改的配置不生效。修复：`ExtensionsConfig.from_file()` 直读磁盘。
- ❌ **单 server tool discovery 失败抛异常中断全量装载** -> 一个坏 server 让所有 server 工具都不可用。修复：`asyncio.gather` + per-server try/except 返回空 list，坏 server 跳过、健康 server 继续。
- ❌ **MCP 来源用 name 前缀或路径推断** -> server 重命名工具后前缀规则失效，漏 tag -> 该 deferred 的工具被当 immediate 全 schema 绑定。修复：`tag_mcp_tool` 写 `metadata["helix_mcp"] = True` 单一真值，`is_mcp_tool` 只认这个 key。

## 落地参考（自测 / 调参 / 调试）

**调参旋钮**

| 旋钮 | 默认 | 来源 | 说明 |
|---|---|---|---|
| `mcpServers[*].enabled` | `true` | `extensions_config.json` | 是否启用该 server |
| `mcpServers[*].type` | `stdio` | `extensions_config.json` | 传输：`stdio` / `sse` / `http`（接受 `transport` 别名） |
| `mcpServers[*].command`/`args`/`env` | - | `extensions_config.json` | stdio 必填 command；env merge 进子进程 |
| `mcpServers[*].url`/`headers` | - | `extensions_config.json` | sse/http 必填 url |
| `mcpServers[*].oauth.*` | - | `extensions_config.json` | OAuth token endpoint / grant_type / client_id/secret / scope / refresh_skew_seconds |
| `mcpServers[*].tool_call_timeout` | `None` | `extensions_config.json` | 仅 stdio 生效；http/sse 用传输层超时 |
| `mcpInterceptors` | `[]` | `extensions_config.json` | 自定义 interceptor builder 路径列表 |
| `tool_search.enabled` | `false` | `config.yaml` | 开启后 MCP 工具 deferred |
| `MCPSessionPool.MAX_SESSIONS` | `256` | 源码常量 | session pool LRU 容量 |
| `MCPSessionPool.SESSION_CLOSE_TIMEOUT` | `5.0` | 源码常量 | 跨 loop 关 session 超时 |
| `HELIX_EXTENSIONS_CONFIG_PATH` | - | env | 覆盖 extensions_config.json 路径 |

**关键日志串**（排障时 grep）

- `Initializing MCP tools...` / `MCP tools initialized: N tool(s) loaded (config mtime: ...)` - lazy 初始化触发与完成
- `MCP tools not initialized, performing lazy initialization...` - 首次装配触发 lazy
- `MCP config file has been modified (mtime: X -> Y), cache is stale` - Gateway API 改了配置，下次装配失效
- `MCP cache is stale, resetting for re-initialization...` - mtime 失效触发 reset
- `Configured MCP server: {name}` / `No enabled MCP servers found` - server 配置装载
- `Skipping MCP server '{name}' after tool discovery failed` - 单 server 失败隔离
- `Successfully loaded N tool(s) from MCP servers` - 装载汇总
- `Refreshed OAuth access token for MCP server: {name}` - OAuth token 刷新
- `Created persistent MCP session for {server}/{scope}` - session pool 新建 session
- `MCP path rewrite: {real} -> {virtual}` - 路径反向翻译命中（debug 级）
- `MCP path rewrite skipped outside user-data tree: {real}` - 路径在 thread 树外，原样保留
- `MCP bare filename rewrite: {name} -> {virtual}` - 裸文件名关联命中
- `Ignoring tool_call_timeout for MCP server '{name}' because transport '{t}' is not stdio` - http/sse 配了 stdio 专属超时
- `Error closing MCP session` - owner task `__aexit__` 异常（warning 级）
- `Owning loop for MCP session is idle; signalling close best-effort. Session may leak` - idle loop 关 session 降级（warning 级）

**自测方向**

- **lazy + mtime**：首次 `get_cached_mcp_tools()` 触发 lazy init；touch `extensions_config.json`（更新 mtime）后再次调用 -> reset + 重载；删除配置文件 -> `_is_cache_stale` 返回 False（不 churn）。
- **多传输归一**：stdio 缺 command -> `ValueError`；sse 缺 url -> `ValueError`；`type` 与 `transport` 两种写法等价（`_accept_transport_alias`）。
- **失败隔离**：mock 一个 server `get_tools` 抛异常 -> 该 server 返回空 list + warn，其他 server 工具正常返回。
- **路径反向翻译**：stdio server 返回 `ResourceLink(uri="file:///path/to/workspace/shot.png")` 且文件存在 -> 翻译成 `/mnt/user-data/workspace/shot.png`；返回远程 `https://...` URI -> 原样保留；返回树外路径 -> 原样保留；自由文本 `Saved as temp/page.png` 且文件存在 -> 翻译；裸文件名 `page.yml` 仅当本次调用产物唯一匹配 -> 翻译。
- **session pool 复用**：同 `(server, user:thread)` 两次调用 -> 复用同一 session（`Created persistent MCP session` 只出现一次）；跨 thread -> 不同 session。
- **跨 loop 逐出**：同 key 在 loop A 建 session，loop B 调 `get_session` -> 逐出 A 的 session + 在 B 建 new session。
- **owner-task same-task**：sync 路径（`make_sync_tool_wrapper` 每调用全新 `asyncio.run`）多次调同一 MCP 工具 -> 不抛 "exit cancel scope in a different task"（#3379 回归）。
- **OAuth 刷新**：token 将过期（`expires_at - refresh_skew_seconds`）-> 主动刷新；并发调用同时过期 -> 双检锁 collapse 到一次刷新；`expires_in` 非整数 -> 回退 1h。
- **close_all_sync 不死锁**：在运行 loop 内调 `close_all_sync()` -> 当前 loop 的 session 只 signal、不阻塞；其他线程 loop 的 session 确定性 teardown（或超时）。
- **in-flight cancel**：`get_session` 中途取消 -> owner 阻塞在 `initialize()` 时被 cancel，`finally` 跑 `__aexit__`，不泄漏。
- **HTTP/SSE 不 pool**：http 传输工具 -> 不经 `_make_session_pool_tool`，原样返回；配 `tool_call_timeout` -> warn 提示用传输层超时。
- **deferred tag 一致性**：`get_mcp_tools()` 返回的工具经 `get_available_tools` 打 tag 后，`is_mcp_tool(t)` 全为 True；`assemble_deferred_tools` 挑出的集合 == MCP 工具集合。
- **reset 联动**：`reset_mcp_tools_cache()` -> `close_all_sync()` 关现有 session + `reset_session_pool()` null 单例；下次 `get_cached_mcp_tools()` 重建 pool + 重载工具。

## 进一步阅读

- 装载 + 传输 + OAuth + config schema 完整源码：[references/code/loading-and-transports.md](./references/code/loading-and-transports.md)
- 路径反向翻译 + 结果转换 + tag 源头完整源码：[references/code/path-translation-and-deferred.md](./references/code/path-translation-and-deferred.md)
- session pool + 工具包装 + 装载编排 + sync 包装完整源码：[references/code/session-pool.md](./references/code/session-pool.md)
- 关联 skill：[[e2e-request-lifecycle]]（④建图装配 / ⑥执行调用 在链路中的位置）、[[tool-assembly-and-policy]]（MCP 工具五源之一 + tag 写入点 + deferred 切分 + catalog + tool_search + DeferredToolFilterMiddleware）、[[sandbox-abstraction]]（虚拟路径契约 + 路径翻译对称）、[[sandbox-tools-and-safety]]（bash 正向路径翻译 `replace_virtual_path`）、[[middleware-chain-design]]（DeferredToolFilterMiddleware 链上位置第 22 项）、[[config-and-hot-reload]]（extensions_config mtime 热更新）、[[multi-user-isolation]]（session scope per-(user, thread) + `resolve_runtime_user_id`）、[[agent-graph-factory]]（`make_lead_agent` 调用点）、[[thread-state-and-reducers]]（`promoted` 通道 + `merge_promoted` reducer）
- MCP 协议：https://modelcontextprotocol.io/
- langchain-mcp-adapters：https://github.com/langchain-ai/langchain-mcp-adapters
