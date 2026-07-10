# Session Pool & Tool Wrapping 完整源码

> 本文件是 `mcp-integration` SKILL.md 的代码附件，收录 session pool 单例生命周期全貌、MCP 工具包装全貌、装载编排全貌、sync 包装（owner-task 设计根因）的**完整真实源码**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

## 文件清单

| 自定路径 | 内容 |
|---|---|
| `core/helix/mcp/session_pool.py` | `MCPSessionPool` 完整类（owner-task 模型 + 四阶段 get_session + 跨 loop 关闭路由 + 同步化生命周期 + 单例） |
| `core/helix/mcp/tools.py`（包装部分） | `_extract_thread_id` + `_make_session_pool_tool`（五层 compose 包装）+ `get_mcp_tools`（装载编排全貌） |
| `core/helix/tools/sync.py` | `make_sync_tool_wrapper`（async-only 工具的 sync 包装，session pool owner-task 设计的根因） |

---

## 1. session_pool.py -- 持久 MCP session 池全貌

```python
# core/helix/mcp/session_pool.py
"""Persistent MCP session pool for stateful tool calls.

When MCP tools are loaded via langchain-mcp-adapters with ``session=None``,
each tool call creates a new MCP session. For stateful servers like Playwright,
this means browser state (opened pages, filled forms) is lost between calls.

This module provides a session pool that maintains persistent MCP sessions,
scoped by ``(server_name, scope_key)`` - typically scope_key is the thread_id -
so that consecutive tool calls share the same session and server-side state.
Sessions are evicted in LRU order when the pool reaches capacity.

Lifecycle model (owner task)
----------------------------
An MCP ``ClientSession`` is implemented on top of an ``anyio`` task group, and
anyio enforces that a cancel scope must be exited from the *same task* that
entered it. Calling ``cm.__aexit__`` from any task other than the one that ran
``cm.__aenter__`` raises::

    RuntimeError: Attempted to exit cancel scope in a different task than it
    was entered in

The sync-tool path (``make_sync_tool_wrapper``) drives each call through a fresh
``asyncio.run`` event loop, so a session entered while answering one call would
otherwise be exited while answering another - from a different task - and crash
(GitHub issue #3379).

To make this impossible, every pooled session is owned by a dedicated
``_run_session`` task. That task enters the context manager, hands the live
session back to the caller, and then *waits* on a close event. All shutdown
paths only ever **signal** that event; the owner task performs ``__aexit__``
itself, guaranteeing enter and exit always happen in the same task.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from collections import OrderedDict
from typing import Any

from mcp import ClientSession

logger = logging.getLogger(__name__)


class MCPSessionPool:
    """Manages persistent MCP sessions scoped by ``(server_name, scope_key)``."""

    MAX_SESSIONS = 256
    SESSION_CLOSE_TIMEOUT = 5.0  # seconds to wait when closing a session on a foreign loop

    def __init__(self) -> None:
        # Each entry: (session, owning_loop, owner_task, close_event).
        self._entries: OrderedDict[
            tuple[str, str],
            tuple[
                ClientSession,
                asyncio.AbstractEventLoop,
                asyncio.Task[Any],
                asyncio.Event,
            ],
        ] = OrderedDict()
        # In-flight creations, keyed by (server, scope). Lets concurrent callers
        # on the same loop share a single creation instead of each spawning a
        # duplicate session. Value: (loop, ready_future, owner_task, close_event).
        self._inflight: dict[
            tuple[str, str],
            tuple[
                asyncio.AbstractEventLoop,
                asyncio.Future[ClientSession],
                asyncio.Task[Any],
                asyncio.Event,
            ],
        ] = {}
        # threading.Lock is not bound to any event loop, so it is safe to
        # acquire from both async paths and sync/worker-thread paths.
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    # Session owner task
    # ------------------------------------------------------------------

    async def _run_session(
        self,
        connection: dict[str, Any],
        ready: asyncio.Future[ClientSession],
        close_evt: asyncio.Event,
    ) -> None:
        """Own a single MCP session for its entire lifetime.

        Enters the session context manager, initializes it, publishes the live
        session via ``ready``, then blocks until ``close_evt`` is set. The
        context manager is *always* exited from this task, satisfying anyio's
        cancel-scope same-task requirement.
        """
        from langchain_mcp_adapters.sessions import create_session

        cm = create_session(connection)
        try:
            session = await cm.__aenter__()
        except BaseException as e:
            # Never entered the cancel scope, so there is nothing to exit.
            if not ready.done():
                ready.set_exception(e)
            return

        # The context manager is now entered. From here on __aexit__ MUST run in
        # this task - on init failure, on cancellation, or on the close signal -
        # to satisfy anyio's same-task cancel-scope requirement and to avoid
        # leaking the session/subprocess.
        try:
            await session.initialize()
            if not ready.done():
                ready.set_result(session)
            await close_evt.wait()
        except BaseException as e:
            if not ready.done():
                ready.set_exception(e)
        finally:
            try:
                await cm.__aexit__(None, None, None)
            except Exception:
                logger.warning("Error closing MCP session", exc_info=True)

    async def get_session(
        self,
        server_name: str,
        scope_key: str,
        connection: dict[str, Any],
    ) -> ClientSession:
        """Get or create a persistent MCP session.

        If an existing session was created in a different (or closed) event
        loop, it is evicted and replaced with a fresh one owned by a task on
        the current loop.

        Args:
            server_name: MCP server name.
            scope_key: Isolation key (typically thread_id).
            connection: Connection configuration for ``create_session``.

        Returns:
            An initialized ``ClientSession``.
        """
        key = (server_name, scope_key)
        current_loop = asyncio.get_running_loop()

        # Phase 1: inspect/mutate the registry under the thread lock (no awaits).
        # Decide one of three outcomes atomically: return an existing session,
        # join an in-flight creation, or become the creator for this key.
        # Each item: (loop, owner_task, close_event, cancel). ``cancel`` is True
        # for in-flight creations, whose owner may be blocked inside
        # ``initialize()`` where close_evt cannot wake it - it must be cancelled.
        evicted: list[tuple[asyncio.AbstractEventLoop, asyncio.Task[Any], asyncio.Event, bool]] = []
        join: asyncio.Future[ClientSession] | None = None
        ready: asyncio.Future[ClientSession] | None = None
        close_evt: asyncio.Event | None = None
        task: asyncio.Task[Any] | None = None
        with self._lock:
            if key in self._entries:
                session, loop, ent_task, ent_close = self._entries[key]
                if loop is current_loop and not loop.is_closed():
                    self._entries.move_to_end(key)
                    return session
                # Session belongs to a different/closed event loop - evict it.
                self._entries.pop(key)
                evicted.append((loop, ent_task, ent_close, False))

            inflight = self._inflight.get(key)
            if inflight is not None and inflight[0] is current_loop and not inflight[0].is_closed():
                # Another caller on this loop is already creating the session;
                # wait for the same result instead of building a duplicate.
                join = inflight[1]
            else:
                if inflight is not None:
                    # Stale in-flight creation owned by a different/closed loop.
                    # Drop the record and tear its owner down; because that owner
                    # may be blocked inside initialize() (where close_evt cannot
                    # wake it), it must be cancelled. We then create a fresh
                    # session here.
                    self._inflight.pop(key)
                    evicted.append((inflight[0], inflight[2], inflight[3], True))
                # Become the creator: publish an in-flight record before any
                # await so concurrent callers join us instead of racing.
                ready = current_loop.create_future()
                close_evt = asyncio.Event()
                task = current_loop.create_task(self._run_session(connection, ready, close_evt))
                self._inflight[key] = (current_loop, ready, task, close_evt)

            # Evict LRU entries when at capacity.
            while len(self._entries) >= self.MAX_SESSIONS:
                oldest_key, (_, loop, ent_task, ent_close) = next(iter(self._entries.items()))
                self._entries.pop(oldest_key)
                evicted.append((loop, ent_task, ent_close, False))

        # Phase 2: shut down evicted sessions/creations. Same-loop owners are
        # awaited so they finish deterministically; foreign-loop owners are
        # routed to their own loop. In every case the owner task - never this
        # one - runs __aexit__. In-flight owners are cancelled (cancel=True) so a
        # blocking initialize() cannot leave them hung.
        for loop, ent_task, ent_close, cancel in evicted:
            if loop is current_loop and not loop.is_closed():
                await self._shutdown(ent_close, ent_task, cancel)
            elif cancel:
                await self._shutdown_entry(loop, ent_task, ent_close, cancel=True)
            else:
                self._signal_close(loop, ent_close)

        # Phase 2b: a concurrent creation for this key is already in progress on
        # this loop - share its result rather than create a duplicate session.
        if join is not None:
            return await asyncio.shield(join)

        assert ready is not None and close_evt is not None and task is not None

        # Phase 3: wait for our owner task to publish the initialized session.
        try:
            session = await asyncio.shield(ready)
        except BaseException:
            # Two distinct cases reach here:
            #
            # 1. The owner task failed (e.g. connect/initialize error) and
            #    reported it via ready.set_exception(). It is *already* in its
            #    finally block running cm.__aexit__ in its own task, so we must
            #    NOT cancel it - doing so would interrupt that cleanup. We only
            #    wait for it to finish unwinding.
            # 2. This call itself was cancelled (CancelledError). Because of the
            #    shield, `ready` is still pending and the owner task is alive and
            #    blocked. We signal close and cancel it so it exits the cancel
            #    scope in its own task, then wait for it to finish.
            #
            # The session is never registered yet, so nobody else can close it;
            # waiting here guarantees we never leak a session or owner task.
            owner_already_failed = ready.done() and not ready.cancelled() and ready.exception() is not None
            if not owner_already_failed:
                close_evt.set()
                task.cancel()
            try:
                await asyncio.shield(task)
            except BaseException:
                logger.debug("Owner task ended during get_session unwind", exc_info=True)
            with self._lock:
                if self._inflight.get(key) == (current_loop, ready, task, close_evt):
                    self._inflight.pop(key)
            raise

        # Phase 4: promote the in-flight creation to a registered entry - but
        # only if our in-flight record is still the live one. A concurrent
        # close_* / close_all may have removed it while we were initializing; in
        # that case we must NOT resurrect the session into _entries. Instead we
        # own the teardown: signal our owner task and wait for it to run
        # __aexit__ in its own task, then surface the cancellation.
        with self._lock:
            still_ours = self._inflight.get(key) == (current_loop, ready, task, close_evt)
            if still_ours:
                self._inflight.pop(key)
                self._entries[key] = (session, current_loop, task, close_evt)
        if not still_ours:
            await self._shutdown(close_evt, task)
            raise asyncio.CancelledError("MCP session pool was closed while the session was being created")
        logger.info("Created persistent MCP session for %s/%s", server_name, scope_key)
        return session

    # ------------------------------------------------------------------
    # Cleanup helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _signal_close(loop: asyncio.AbstractEventLoop, close_evt: asyncio.Event) -> None:
        """Ask an owner task to shut down without waiting.

        ``asyncio.Event.set`` is not thread-safe, so it is scheduled on the
        owning loop. A closed loop means the owner task is already gone.
        """
        if loop.is_closed():
            return
        try:
            loop.call_soon_threadsafe(close_evt.set)
        except RuntimeError:
            # Loop was closed between the is_closed() check and now.
            pass

    async def _shutdown(
        self,
        close_evt: asyncio.Event,
        task: asyncio.Task[Any],
        cancel: bool = False,
    ) -> None:
        """Signal an owner task and wait for it to finish (runs on its loop).

        ``cancel=True`` is used for in-flight creations: the owner task may be
        blocked inside ``initialize()`` where ``close_evt`` cannot wake it, so it
        must be cancelled. Its ``finally`` block still runs ``__aexit__`` in its
        own task, satisfying anyio's same-task cancel-scope requirement.
        """
        close_evt.set()
        if cancel:
            task.cancel()
        try:
            await task
        except (Exception, asyncio.CancelledError):
            logger.debug("Owner task ended during shutdown", exc_info=True)

    async def _shutdown_entry(
        self,
        loop: asyncio.AbstractEventLoop,
        task: asyncio.Task[Any],
        close_evt: asyncio.Event,
        cancel: bool = False,
    ) -> None:
        """Shut down one entry, routing the close to its owning loop."""
        if loop.is_closed():
            return
        current_loop = asyncio.get_running_loop()
        if loop is current_loop:
            await self._shutdown(close_evt, task, cancel)
        elif loop.is_running():
            future = asyncio.run_coroutine_threadsafe(self._shutdown(close_evt, task, cancel), loop)
            try:
                await asyncio.wrap_future(future)
            except Exception:
                logger.warning("Error closing MCP session on owning loop", exc_info=True)
        else:
            # Owning loop exists but is neither the current loop nor running.
            # We are inside an async context here, so run_until_complete() would
            # raise "Cannot run the event loop while another loop is running";
            # and the loop may belong to another thread, where driving it from
            # here is unsafe. This branch is not expected in practice - a
            # session's owning loop is either the long-lived gateway loop (which
            # is running) or a short-lived asyncio.run loop (which is closed and
            # caught above). Fall back to a best-effort thread-safe signal so the
            # owner task tears down if/when its loop runs again.
            logger.warning("Owning loop for MCP session is idle; signalling close best-effort. Session may leak until the loop runs again.")
            self._signal_close(loop, close_evt)
            if cancel:
                try:
                    loop.call_soon_threadsafe(task.cancel)
                except RuntimeError:
                    pass

    async def close_scope(self, scope_key: str) -> None:
        """Close all sessions for a given scope (e.g. thread_id)."""
        with self._lock:
            keys = [k for k in self._entries if k[1] == scope_key]
            entries = [(self._entries.pop(k)) for k in keys]
            inflight_keys = [k for k in self._inflight if k[1] == scope_key]
            inflight = [self._inflight.pop(k) for k in inflight_keys]
        for _session, loop, task, close_evt in entries:
            await self._shutdown_entry(loop, task, close_evt)
        for loop, _ready, task, close_evt in inflight:
            await self._shutdown_entry(loop, task, close_evt, cancel=True)

    async def close_server(self, server_name: str) -> None:
        """Close all sessions for a given server."""
        with self._lock:
            keys = [k for k in self._entries if k[0] == server_name]
            entries = [(self._entries.pop(k)) for k in keys]
            inflight_keys = [k for k in self._inflight if k[0] == server_name]
            inflight = [self._inflight.pop(k) for k in inflight_keys]
        for _session, loop, task, close_evt in entries:
            await self._shutdown_entry(loop, task, close_evt)
        for loop, _ready, task, close_evt in inflight:
            await self._shutdown_entry(loop, task, close_evt, cancel=True)

    async def close_all(self) -> None:
        """Close every managed session."""
        with self._lock:
            entries = list(self._entries.values())
            self._entries.clear()
            inflight = list(self._inflight.values())
            self._inflight.clear()
        for _session, loop, task, close_evt in entries:
            await self._shutdown_entry(loop, task, close_evt)
        for loop, _ready, task, close_evt in inflight:
            await self._shutdown_entry(loop, task, close_evt, cancel=True)

    def close_all_sync(self) -> None:
        """Close all sessions on their owning event loops (synchronous).

        Each session is closed by its owner task on the loop it was created in,
        avoiding cross-loop and cross-task errors. Safe to call from any thread
        without an active event loop.

        Closing semantics differ by where the owning loop runs:

        * Owning loop is idle, or running on another thread - this call blocks
          until teardown completes (or ``SESSION_CLOSE_TIMEOUT`` elapses).
        * Owning loop is the one currently running on *this* thread - we cannot
          block on it without deadlocking, so teardown is only *signalled* here
          and completes asynchronously once control returns to that loop. The
          caller must therefore keep that loop running afterwards; if it stops
          the loop immediately, the owner task's ``__aexit__`` may not run. When
          a deterministic close is required from inside a running loop, ``await
          close_all()`` instead.
        """
        with self._lock:
            entries = list(self._entries.values())
            self._entries.clear()
            inflight = list(self._inflight.values())
            self._inflight.clear()

        # Entries are initialized (gentle close_evt path). In-flight creations
        # may be blocked mid-init, so they are cancelled to unblock teardown.
        owners = [(loop, task, close_evt, False) for _s, loop, task, close_evt in entries]
        owners += [(loop, task, close_evt, True) for loop, _r, task, close_evt in inflight]
        try:
            current_running_loop = asyncio.get_running_loop()
        except RuntimeError:
            current_running_loop = None
        for loop, task, close_evt, cancel in owners:
            if loop.is_closed():
                continue
            try:
                if loop is current_running_loop:
                    # We are executing inside this loop's thread, so synchronously
                    # waiting on run_coroutine_threadsafe(...).result() would
                    # deadlock until timeout. Signal the owner task directly and
                    # let it finish once this synchronous call returns control to
                    # the running loop.
                    close_evt.set()
                    if cancel:
                        task.cancel()
                elif loop.is_running():
                    # Schedule the shutdown on the owning loop from this thread.
                    future = asyncio.run_coroutine_threadsafe(self._shutdown(close_evt, task, cancel), loop)
                    future.result(timeout=self.SESSION_CLOSE_TIMEOUT)
                else:
                    loop.run_until_complete(self._shutdown(close_evt, task, cancel))
            except Exception:
                logger.debug("Error closing MCP session during sync close", exc_info=True)


# ------------------------------------------------------------------
# Module-level singleton
# ------------------------------------------------------------------

_pool: MCPSessionPool | None = None
_pool_lock = threading.Lock()


def get_session_pool() -> MCPSessionPool:
    """Return the global session-pool singleton."""
    global _pool
    # Build and return under the lock so racing cold-start callers construct
    # exactly one pool and reset_session_pool() can't null the global between
    # reading it and returning it (which previously could hand back None). The
    # critical section is tiny and never awaits, so a threading.Lock is safe to
    # hold from both the async and sync/worker-thread paths.
    with _pool_lock:
        if _pool is None:
            _pool = MCPSessionPool()
        return _pool


def reset_session_pool() -> None:
    """Reset the singleton (used in tests and the MCP cache reset path)."""
    global _pool
    with _pool_lock:
        _pool = None
```

---

## 2. _make_session_pool_tool -- MCP 工具五层 compose 包装全貌

```python
# core/helix/mcp/tools.py（_make_session_pool_tool + _extract_thread_id 全貌）
def _extract_thread_id(runtime: Runtime | None) -> str:
    """从注入的 tool runtime 或 LangGraph config 提取 thread_id。"""
    if runtime is not None:
        tid = runtime.context.get("thread_id") if runtime.context else None
        if tid is not None:
            return str(tid)
        config = runtime.config or {}
        tid = config.get("configurable", {}).get("thread_id")
        if tid is not None:
            return str(tid)

    try:
        tid = get_config().get("configurable", {}).get("thread_id")
        return str(tid) if tid is not None else "default"
    except RuntimeError:
        return "default"


def _make_session_pool_tool(
    tool: BaseTool,
    server_name: str,
    connection: dict[str, Any],
    tool_interceptors: list[Any] | None = None,
    tool_call_timeout: float | None = None,
) -> BaseTool:
    """Wrap an MCP tool so it reuses a persistent session from the pool.

    Replaces the per-call session creation with pool-managed sessions scoped
    by ``(server_name, user_id:thread_id)``.  This ensures stateful MCP servers
    (e.g. Playwright) keep their state across tool calls within the same thread
    while staying isolated per user.

    The configured ``tool_interceptors`` (OAuth, custom) are preserved and
    applied on every call before invoking the pooled session.
    """
    # Strip the server-name prefix to recover the original MCP tool name.
    original_name = tool.name
    prefix = f"{server_name}_"
    if original_name.startswith(prefix):
        original_name = original_name[len(prefix):]

    pool = get_session_pool()

    async def call_with_persistent_session(
        runtime: Runtime | None = None,
        **arguments: Any,
    ) -> Any:
        thread_id = _extract_thread_id(runtime)
        user_id = resolve_runtime_user_id(runtime)
        # Scope the pooled session by user *and* thread. Filesystem isolation is
        # per-(user_id, thread_id), so a thread_id alone could otherwise let two
        # users with a colliding thread_id share one stateful MCP session.
        scope_key = f"{user_id}:{thread_id}"
        session_connection = dict(connection)
        # cwd/temp pinning and the workspace snapshot only matter for stdio
        # servers, which run as local subprocesses writing to a real filesystem.
        # SSE/HTTP servers have no local cwd to pin, so skip the filesystem work
        # entirely for them (avoids needless dir creation and recursive walks).
        is_stdio = session_connection.get("transport", "stdio") == "stdio"
        source_base_dir: Path | None = None
        process_cwd: Path | None = None
        before_files: _FILE_SNAPSHOT | None = None
        if is_stdio:
            paths = get_paths()
            # Bundle the synchronous filesystem prep (dir creation, temp-dir
            # setup, pre-call snapshot) and run it off the event loop - the
            # snapshot walks the whole workspace and would otherwise block.
            source_base_dir, tmp_dir, before_files = await asyncio.to_thread(_prepare_stdio_workspace, paths, thread_id=thread_id, user_id=user_id)
            # Stdio MCP servers resolve relative output links against their
            # process cwd. Keep that cwd inside the thread's mounted user-data
            # tree so files produced by tools like Playwright land where the
            # sandbox/artifact API can serve them and their references can be
            # translated to virtual paths.
            configured_cwd = session_connection.get("cwd", str(source_base_dir))
            session_connection["cwd"] = str(configured_cwd)
            process_cwd = Path(configured_cwd)
            # Pin the subprocess temp dir under the same mounted tree. Tools that
            # default to the OS temp dir (Node's os.tmpdir(), Python's tempfile,
            # many CLIs) then write inside user-data instead of an unreachable
            # host path - the tool-agnostic counterpart to fixing the cwd. Merge
            # rather than replace any operator-provided env.
            session_env = dict(session_connection.get("env") or {})
            session_env.setdefault("TMPDIR", str(tmp_dir))
            session_env.setdefault("TMP", str(tmp_dir))
            session_env.setdefault("TEMP", str(tmp_dir))
            session_connection["env"] = session_env
        session = await pool.get_session(server_name, scope_key, session_connection)

        # Build common call_tool kwargs once - only add keys when needed so
        # existing call-sites that assert on exact arguments are not affected.
        call_kwargs: dict[str, Any] = {}
        if tool_call_timeout:
            call_kwargs["read_timeout_seconds"] = timedelta(seconds=tool_call_timeout)

        if tool_interceptors:
            from langchain_mcp_adapters.interceptors import MCPToolCallRequest

            async def base_handler(request: MCPToolCallRequest) -> Any:
                # Preserve interceptor-injected headers for stdio MCP calls by
                # forwarding them through MCP call meta.
                kwargs = dict(call_kwargs)
                if request.headers:
                    if isinstance(request.headers, Mapping):
                        kwargs["meta"] = {"headers": dict(request.headers)}
                    else:
                        logger.warning("Ignoring MCP interceptor headers with unsupported type: %s", type(request.headers).__name__)
                return await session.call_tool(
                    request.name,
                    request.args,
                    **kwargs,
                )

            handler = base_handler
            for interceptor in reversed(tool_interceptors):
                outer = handler

                async def wrapped(req: Any, _i: Any = interceptor, _h: Any = outer) -> Any:
                    return await _i(req, _h)

                handler = wrapped

            request = MCPToolCallRequest(
                name=original_name,
                args=arguments,
                server_name=server_name,
                runtime=runtime,
            )
            call_tool_result = await handler(request)
        else:
            call_tool_result = await session.call_tool(
                original_name,
                arguments,
                **call_kwargs,
            )

        # The after-call snapshot diff only feeds bare-filename correlation in
        # free text, so skip the second recursive walk when there is no text
        # content to rewrite. Both the diff and the per-token path resolution
        # inside _convert_call_tool_result touch the filesystem, so run them off
        # the event loop.
        changed_files: list[Path] | None = None
        if is_stdio and before_files is not None and _result_has_text_content(call_tool_result):
            changed_files = await asyncio.to_thread(_changed_workspace_files, source_base_dir, before_files)
        return await asyncio.to_thread(
            _convert_call_tool_result,
            call_tool_result,
            thread_id=thread_id,
            user_id=user_id,
            source_base_dir=process_cwd,
            changed_files=changed_files,
        )

    return StructuredTool(
        name=tool.name,
        description=tool.description,
        args_schema=tool.args_schema,
        coroutine=call_with_persistent_session,
        response_format="content_and_artifact",
        metadata=tool.metadata,
    )
```

---

## 3. get_mcp_tools -- 装载编排全貌

```python
# core/helix/mcp/tools.py（get_mcp_tools 全貌）
async def get_mcp_tools() -> list[BaseTool]:
    """Get all tools from enabled MCP servers.

    Tools using stdio transport are wrapped with persistent-session logic so
    consecutive calls within the same thread reuse the same MCP session.
    HTTP/SSE tools are returned unwrapped to avoid cross-task TaskGroup
    cleanup errors.

    Returns:
        List of LangChain tools from all enabled MCP servers.
    """
    try:
        from langchain_mcp_adapters.client import MultiServerMCPClient
    except ImportError:
        logger.warning("langchain-mcp-adapters not installed. Install it to enable MCP tools: pip install langchain-mcp-adapters")
        return []

    # NOTE: 用 ExtensionsConfig.from_file()（非 get_extensions_config() 缓存单例）直读磁盘，
    # 确保 Gateway API（独立进程）改的配置在初始化 MCP 工具时立即生效。
    extensions_config = ExtensionsConfig.from_file()
    servers_config = build_servers_config(extensions_config)

    if not servers_config:
        logger.info("No enabled MCP servers configured")
        return []

    try:
        # Create the multi-server MCP client
        logger.info(f"Initializing MCP client with {len(servers_config)} server(s)")

        # Inject initial OAuth headers for server connections (tool discovery/session init)
        initial_oauth_headers = await get_initial_oauth_headers(extensions_config)
        for server_name, auth_header in initial_oauth_headers.items():
            if server_name not in servers_config:
                continue
            if servers_config[server_name].get("transport") in ("sse", "http"):
                existing_headers = dict(servers_config[server_name].get("headers", {}))
                existing_headers["Authorization"] = auth_header
                servers_config[server_name]["headers"] = existing_headers

        tool_interceptors: list[Any] = []
        oauth_interceptor = build_oauth_tool_interceptor(extensions_config)
        if oauth_interceptor is not None:
            tool_interceptors.append(oauth_interceptor)

        # Load custom interceptors declared in extensions_config.json
        # Format: "mcpInterceptors": ["pkg.module:builder_func", ...]
        raw_interceptor_paths = (extensions_config.model_extra or {}).get("mcpInterceptors")
        if isinstance(raw_interceptor_paths, str):
            raw_interceptor_paths = [raw_interceptor_paths]
        elif not isinstance(raw_interceptor_paths, list):
            if raw_interceptor_paths is not None:
                logger.warning(f"mcpInterceptors must be a list of strings, got {type(raw_interceptor_paths).__name__}; skipping")
            raw_interceptor_paths = []
        for interceptor_path in raw_interceptor_paths:
            try:
                builder = resolve_variable(interceptor_path)
                interceptor = builder()
                if callable(interceptor):
                    tool_interceptors.append(interceptor)
                    logger.info(f"Loaded MCP interceptor: {interceptor_path}")
                elif interceptor is not None:
                    logger.warning(f"Builder {interceptor_path} returned non-callable {type(interceptor).__name__}; skipping")
            except Exception as e:
                logger.warning(
                    f"Failed to load MCP interceptor {interceptor_path}: {e}",
                    exc_info=True,
                )

        client = MultiServerMCPClient(
            servers_config,
            tool_interceptors=tool_interceptors,
            tool_name_prefix=True,
        )

        async def load_server_tools(server_name: str) -> list[BaseTool]:
            try:
                return await client.get_tools(server_name=server_name)
            except Exception as e:
                logger.warning(
                    f"Skipping MCP server '{server_name}' after tool discovery failed: {e}",
                    exc_info=True,
                )
                return []

        # Get tools from each server independently so one broken MCP server does
        # not prevent healthy servers from contributing their tools.
        tools_by_server = await asyncio.gather(*(load_server_tools(name) for name in servers_config))
        tools = [tool for server_tools in tools_by_server for tool in server_tools]
        logger.info(f"Successfully loaded {len(tools)} tool(s) from MCP servers")

        # Wrap each tool with persistent-session logic.
        # Only pool stdio sessions. HTTP/SSE transports use anyio TaskGroups
        # internally which cannot be closed from a different async task, so
        # pooling them causes RuntimeError on cleanup (see #3203).
        wrapped_tools: list[BaseTool] = []
        # Route each tool by the server that actually produced it: tools_by_server[i]
        # corresponds to the i-th server in servers_config. Inferring the source server by
        # scanning servers_config for a name prefix is ambiguous when one server name is a
        # prefix of another (e.g. "web" vs "web_scraper" -> "web_scraper_search".startswith(
        # "web_") matches "web" first), which pools the tool under the wrong server. Using the
        # source grouping makes routing exact; the prefix guard preserves the previous
        # behavior of leaving unprefixed tools unwrapped.
        for source_name, server_tools in zip(servers_config.keys(), tools_by_server, strict=True):
            transport = servers_config[source_name].get("transport", "stdio")
            server_cfg = extensions_config.mcp_servers.get(source_name)
            for tool in server_tools:
                if tool.name.startswith(f"{source_name}_") and transport == "stdio":
                    _timeout = server_cfg.tool_call_timeout if server_cfg else None
                    wrapped_tools.append(_make_session_pool_tool(tool, source_name, servers_config[source_name], tool_interceptors, tool_call_timeout=_timeout))
                else:
                    if transport != "stdio" and server_cfg and server_cfg.tool_call_timeout is not None:
                        logger.warning(
                            "Ignoring tool_call_timeout for MCP server '%s' because transport '%s' is not stdio; configure HTTP/SSE transport-level timeouts instead.",
                            source_name,
                            transport,
                        )
                    wrapped_tools.append(tool)

        # Patch tools to support sync invocation, as the Helix client streams synchronously
        for tool in wrapped_tools:
            if getattr(tool, "func", None) is None and getattr(tool, "coroutine", None) is not None:
                tool.func = make_sync_tool_wrapper(tool.coroutine, tool.name)

        return wrapped_tools

    except Exception as e:
        logger.error(f"Failed to load MCP tools: {e}", exc_info=True)
        return []
```

---

## 4. make_sync_tool_wrapper -- owner-task 设计的根因

```python
# core/helix/tools/sync.py
"""Utilities for invoking async tools from synchronous agent paths."""

import asyncio
import atexit
import concurrent.futures
import contextvars
import functools
import logging
from collections.abc import Callable
from typing import Any, get_type_hints

from langchain_core.runnables import RunnableConfig

logger = logging.getLogger(__name__)

# Shared thread pool for sync tool invocation in async environments.
_SYNC_TOOL_EXECUTOR = concurrent.futures.ThreadPoolExecutor(max_workers=10, thread_name_prefix="tool-sync")

atexit.register(lambda: _SYNC_TOOL_EXECUTOR.shutdown(wait=False))


def _get_runnable_config_param(func: Callable[..., Any]) -> str | None:
    """返回期待 LangChain RunnableConfig 的 coroutine 参数名。"""
    if isinstance(func, functools.partial):
        func = func.func

    try:
        type_hints = get_type_hints(func)
    except Exception:
        return None

    for name, type_ in type_hints.items():
        if type_ is RunnableConfig:
            return name
    return None


def make_sync_tool_wrapper(coro: Callable[..., Any], tool_name: str) -> Callable[..., Any]:
    """为异步工具 coroutine 构造同步包装。

    Args:
        coro: 支撑 LangChain 工具的 async callable。
        tool_name: 错误日志用的工具名。

    Returns:
        适合 ``BaseTool.func`` 的 sync callable。

    Notes:
        若 ``coro`` 声明了 ``RunnableConfig`` 参数，本包装暴露 ``config: RunnableConfig``
        让 LangChain 注入运行时 config，再转发给 coroutine 检测到的 config 参数。

        本包装刻意不合成动态函数签名。未来的 async 工具若有名为 ``config`` 的正常用户参数、
        且 ``RunnableConfig`` 参数另起他名（如 ``run_config``），可能与 LangChain 注入的
        ``config`` 参数碰撞。使用该签名前重命名该用户字段或扩展本 helper。

    设计关联（session pool owner-task 模型的根因）：
        本包装每次调用走全新 ``asyncio.run`` 事件循环（不同 task）。MCP ClientSession 基于
        anyio task group，cancel scope 必须由进入它的同一个 task 退出。若 session 由某次
        调用的 task 进入、另一次调用的 task 退出，anyio 抛 "exit cancel scope in a different
        task"（issue #3379）。session pool 的 owner-task 模型（_run_session 专属 task 进/出 CM）
        即为规避此约束而设计。
    """
    config_param = _get_runnable_config_param(coro)

    def run_coroutine(*args: Any, **kwargs: Any) -> Any:
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        try:
            if loop is not None and loop.is_running():
                context = contextvars.copy_context()
                future = _SYNC_TOOL_EXECUTOR.submit(context.run, lambda: asyncio.run(coro(*args, **kwargs)))
                return future.result()
            return asyncio.run(coro(*args, **kwargs))
        except Exception as e:
            logger.error("Error invoking tool %r via sync wrapper: %s", tool_name, e, exc_info=True)
            raise

    if config_param:

        def sync_wrapper(*args: Any, config: RunnableConfig = None, **kwargs: Any) -> Any:
            if config is not None or config_param not in kwargs:
                kwargs[config_param] = config
            return run_coroutine(*args, **kwargs)

        return sync_wrapper

    def sync_wrapper(*args: Any, **kwargs: Any) -> Any:
        return run_coroutine(*args, **kwargs)

    return sync_wrapper
```
