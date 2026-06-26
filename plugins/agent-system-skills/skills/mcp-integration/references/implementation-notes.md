# MCP Integration — Implementation Notes

## 1. Transports & Server Params

MCP servers are described by a per-server config block in the extensions
configuration file. The transport builder normalises three transports:

| Transport | Required fields                | Optional             |
| --------- | ------------------------------ | -------------------- |
| `stdio`   | `command`, plus `args`         | `env`                |
| `sse`     | `url`                          | `headers`, `oauth`   |
| `http`    | `url`                          | `headers`, `oauth`   |

A missing transport defaults to `stdio`. The builder raises on missing
required fields per transport — failures during build are logged per
server and *do not abort the whole catalog load*, so one misconfigured
server cannot blackhole the rest of the registry. The result is a
`{server_name: params}` dict fed to the multi-server MCP client.

For `stdio`, the harness additionally pins the subprocess `cwd` to the
caller's thread workspace and points `TMPDIR/TMP/TEMP` at a workspace-local
`.mcp/tmp/` directory — unless the operator already supplied either. This
keeps any files an `stdio` MCP server writes inside the thread's owner
scope, where the rest of the file pipeline can find them. SSE and HTTP
transports skip that filesystem prep entirely.

## 2. Tool Catalog Cache (mtime-driven)

MCP tool loading is expensive (a session per server) and the result is
relatively static, so the harness caches the assembled tool list in a
module-level singleton with **lazy initialisation** and **mtime-based
invalidation**:

* The cache stores `(tools, config_mtime)` after the first successful
  load. Subsequent calls compare the current `mtime` of the extensions
  config file against the stored value.
* `current > cached` → cache is stale → fully reset and reload. This is the
  channel by which "Operator edits the config → next request sees the new
  servers" works without a restart.
* `current is None` or `cached is None` → assume not stale (the file is
  missing or unreadable; don't churn the cache).

Initialisation is guarded by an `asyncio.Lock` so concurrent first-callers
collapse into one initialisation. The lazy path also handles the case where
the cache is hit from a running event loop: rather than nesting an
`asyncio.run`, it submits the init coroutine to a worker thread.

Resetting the cache also tears down the persistent session pool (§3),
because a tool whose schema vanished from the catalog must not keep an
open session to its server. The reset is split into a synchronous signal
phase (safe to call from any context, including a running loop on the
session's own thread) and a deterministic teardown for foreign loops —
see §3 for why those two paths are not interchangeable.

## 3. Persistent Session Pool

A naive `langchain-mcp-adapters` setup runs every tool call with
`session=None`, which means each call spins up a fresh MCP session — fine
for stateless servers, fatal for stateful ones (browser automation, REPLs,
anything with on-server scratch state). The session pool keys sessions on
`(server_name, scope_key)` — typically `scope_key = thread_id` — and
shares them across consecutive tool calls in the same thread.

The non-obvious bits all stem from one fact: an MCP `ClientSession` is
implemented on top of an `anyio` task group, and **anyio requires that the
cancel scope be exited from the same task that entered it.** If task A
calls `cm.__aenter__()` and task B calls `cm.__aexit__()`, anyio raises:

> Attempted to exit cancel scope in a different task than it was entered in.

That guarantee is otherwise easy to violate: the sync-tool wrapper drives
each call through a fresh `asyncio.run` event loop, so a session entered
during call N would be exited during call N+1 on a different task.

The pool's design fixes this by introducing an **owner task** per session:

* Each session has a dedicated `_run_session` task. That task enters the
  context manager, runs `initialize()`, publishes the live session on a
  `ready` future, and then awaits a `close_event`.
* Callers never invoke `__aexit__` themselves. They `set()` the close
  event (and optionally cancel the owner task); the owner runs `__aexit__`
  in its own task in its `finally` block. Same-task guarantee preserved
  under cancel, error, and graceful shutdown.

Other invariants that fall out of this:

* The pool entries map records `(session, owning_loop, owner_task,
  close_event)`. A reuse hit only succeeds when the entry's
  `owning_loop is current_loop` and the loop is still open. Cross-loop
  hits evict the entry and create a fresh one.
* Concurrent first-callers for the same key collapse onto a single
  in-flight creation via a `(loop, ready_future, owner_task, close_event)`
  record in `_inflight`; followers `await shield(ready)` instead of
  spawning duplicates.
* On call cancellation, the pool distinguishes "owner reported failure"
  (let its `finally` complete) from "this caller was cancelled mid-init"
  (signal close *and* cancel the owner task because it may be blocked
  inside `initialize()` where the close event cannot wake it).
* Eviction is LRU at `MAX_SESSIONS = 256`. Closing an entry on a foreign
  loop routes through `run_coroutine_threadsafe` with a 5s timeout; the
  sync close path on the *current* running loop only signals, because
  synchronously blocking on the current loop would deadlock.

## 4. OAuth Token Manager (HTTP/SSE)

Servers with `oauth.enabled = true` are routed through a token manager
that supports two grant types: `client_credentials` and `refresh_token`.
Behaviour:

* One `asyncio.Lock` per server name guards the refresh path. Cached
  tokens are checked under the lock to collapse stampedes when multiple
  tool calls expire-and-refresh at the same time.
* "Expiring" means `expires_at <= now + refresh_skew_seconds`. Tokens are
  refreshed proactively rather than reactively, so a tool call cannot
  land on a token that expires mid-flight.
* The response field names (`access_token`, `token_type`, `expires_in`)
  are configurable per server — non-standard providers can map their JSON
  fields directly without code changes.
* `expires_in` parsing is defensive: non-integer values fall back to 1 h.
  A missing `token_field` raises immediately; nothing is cached on error.

The manager is wired into MCP through a **tool interceptor**: every
outbound tool call gets the current Authorization header injected into
`request.headers` before being forwarded. Initial server connection
headers are computed once at load time for transports that need an
`Authorization` header to *open* the session, not just to call tools.

## 5. Path Translation for `stdio` File Outputs

`stdio` MCP servers commonly return file references — either typed
`ResourceLink` results or free-text paths in tool outputs. The harness
does **not** copy returned files. Instead, when a returned path resolves
to an existing file inside the thread's mounted user-data tree, it is
deterministically translated to the virtual `/mnt/user-data/...` prefix
the agent uses; anything outside that tree is passed through unchanged.

The translation is conservative on free-text matches: it only fires when
the candidate string actually resolves to an existing file. This prevents
false positives on prose that mentions a literal path that does not exist
on disk. Typed `ResourceLink` results are translated unconditionally
because the schema guarantees they are file references.

This is a deliberate trade-off: it keeps storage costs flat and matches
the file pipeline used by the rest of the system, at the cost of being
useless for servers that emit transient files outside the thread tree.

## 6. Deferred Tool Catalog (`tool_search` integration)

When the Tool Catalog grows large, sending every MCP tool schema to the
model wastes context. The harness supports a "deferred" mode where MCP
schemas are withheld until promoted via a `tool_search` tool:

* The Deferred Tool Filter Middleware is constructed with a frozen
  `deferred_names` set and a `catalog_hash` computed over the deferred
  catalog at assembly time. Both are injected at construction — there is
  no ContextVar — so the middleware's view is stable across the run.
* On every `wrap_model_call`, the middleware reads
  `state["promoted"]` (a `{catalog_hash, names}` dict) and filters
  `request.tools` down to: non-deferred tools + tools whose name appears
  in `promoted.names` *and* whose `promoted.catalog_hash` matches the
  middleware's own hash. A stale persisted promotion against a now-renamed
  tool simply does not match — fail-closed. The catalog hash also pins
  the promotion to a specific assembly: if a config edit changes which
  tools are deferred, the old promotion record is invalidated.
* The middleware also wraps `tool_call`. If the model fabricates a call
  to a deferred-but-not-yet-promoted tool, the wrapper short-circuits
  with a `ToolMessage(status="error")` telling it to call `tool_search`
  first, carrying back the original `tool_call_id` so the graph can
  reconcile the orphaned call. ToolNode still has the tool registered for
  execution — only the *schema visibility* is gated.
* Both sync and async variants exist (`wrap_model_call` /
  `awrap_model_call`, `wrap_tool_call` / `awrap_tool_call`) because the
  surrounding graph can dispatch either path depending on the model
  binding.

See [[tool-assembly-and-policy]] for how `deferred_names` is computed and
[[thread-state-and-reducers]] for the `promoted` field's reducer
semantics.

Related: [[tool-assembly-and-policy]] · [[thread-state-and-reducers]] · [[config-and-hot-reload]] · [[sandbox-tools-and-safety]] · [[multi-user-isolation]]
