# Memory System — Implementation Notes

## 1. Two-Tier Model: Hot State vs. Cold Memory

Conversation messages are hot state — they live in graph state and decay
with the thread. The memory system is the cold tier: an LLM-curated,
per-owner JSON document that survives across threads and gets re-injected
into the prompt on every turn. The two tiers never share a writer. Hot
state is mutated by reducers on the graph; cold memory is mutated only by
the async memory updater described in §3.

Memory documents have three top-level sections:

* `user` — `workContext`, `personalContext`, `topOfMind` (short summaries,
  each timestamped).
* `history` — `recentMonths`, `earlierContext`, `longTermBackground`
  (rolling historical context).
* `facts` — list of discrete facts with `id`, `content`, `category`,
  `confidence`, `createdAt`, `source`.

Sections are addressed by string keys, not positional. The updater only
overwrites a section when the model returns `{shouldUpdate: true, summary:
…}` for it; everything else is left as-is across update cycles. This makes
incremental updates idempotent: re-running the same update on the same
document produces the same document, modulo the timestamp on touched
sections.

## 2. Enqueue Path: `after_agent` Middleware

The Memory Middleware fires once per turn in the `after_agent` hook. It:

1. Resolves `thread_id` from runtime context, falling back to LangGraph's
   `configurable` block. No `thread_id` → no enqueue.
2. Filters the message log down to user inputs and final assistant
   responses (tool calls are stripped — they are mechanism, not signal).
3. Refuses to enqueue unless **both** a user turn and an assistant turn
   are present in the filtered log. A bare user message with no assistant
   response is not actionable memory.
4. Runs lightweight correction/reinforcement signal detection over the
   filtered log; `reinforcement` is suppressed when `correction` already
   fired (corrections are the stronger signal). These flags propagate into
   the update prompt as explicit hints, biasing the LLM toward recording
   the corrected behaviour with confidence ≥ 0.95 or the reinforced
   behaviour with confidence ≥ 0.9.
5. **Captures `user_id` from the contextvar on the request thread** and
   bakes it into the conversation context object.

Step 5 is non-negotiable. The processing pool runs on a `threading.Timer`
callback, and `ContextVar` values do not propagate across raw threads. If
`user_id` is not snapshotted at enqueue time, the timer thread will read
the unbound default (`"default"`) and write the wrong owner's memory file.
The same constraint also rules out resolving `agent_name` lazily on the
worker thread — anything that varies per request must be captured here.

## 3. Debounce Queue & Update Loop

The Memory Queue is a singleton with one debounce timer. Each enqueue:

* Computes a debounce identity `(thread_id, user_id, agent_name)`. Existing
  entries with the same identity are **replaced**, not appended — the latest
  conversation snapshot supersedes earlier ones, but `correction_detected`
  and `reinforcement_detected` flags are OR-merged so signals raised early
  in the window are not lost.
* Resets the debounce timer to `debounce_seconds` (default 30s).
* `add_nowait` and `flush_nowait` schedule with delay 0 instead, for
  immediate flushes (tests, graceful shutdown, IM channel turn boundaries).

The timer itself is a `threading.Timer` marked daemon. That has a sharp
edge: queued messages may be lost if the host process exits before
`_process_queue` completes. The trade-off is accepted because memory
updates are best-effort cold-tier writes; a missed update at shutdown is
strictly less harmful than a non-daemon thread blocking process exit.

When the timer fires, the worker takes the lock, sets `_processing = True`,
snapshots and clears the queue, then drops the lock before doing the LLM
work. If a flush is requested while processing is already in flight, the
worker reschedules itself with delay 0 — the in-flight worker will pick up
whatever was newly enqueued on its next iteration. Between updates, the
worker sleeps 0.5s to dodge provider rate limits. Per-context failures are
caught and logged so a single bad conversation does not poison the rest of
the batch.

## 4. LLM Update: Sync Path on a Dedicated Pool

The updater deliberately uses the **synchronous** `model.invoke()` path,
even when invoked from an async caller. The reason is provider connection
pooling: the lead-agent's async `httpx.AsyncClient` is globally cached by
`langchain_*` modules; if the memory updater also ran on the same loop, an
in-flight memory call could share a connection with a live agent stream and
cause cross-loop reuse errors when the loop closes.

The flow is:

1. If a running loop is detected, submit `_do_update_memory_sync` to a
   dedicated `concurrent.futures.ThreadPoolExecutor` (4 workers, registered
   to shut down via `atexit`). Otherwise run inline.
2. The sync worker builds the prompt: `current_memory` (JSON-serialised),
   the filtered conversation text, and a correction/reinforcement hint
   block when those flags were set. Returns immediately if memory is
   disabled, messages are empty, or the conversation has no extractable
   text.
3. Calls `model.invoke()` with `run_name="memory_agent"` for traceability.
4. Parses the response with a JSON-extracting scanner that walks every `{`
   in the text, runs `JSONDecoder.raw_decode`, and accepts the first object
   that contains all four required keys: `user`, `history`, `newFacts`,
   `factsToRemove`. This survives providers that wrap JSON in thinking
   traces or markdown fences.
5. Normalises the parsed payload (clamps confidence to a finite float,
   drops malformed facts, refuses partial updates that combine
   `factsToRemove` with malformed `newFacts`).
6. Deep-copies the current memory, applies the diff, runs the
   upload-mention scrub (see §5), and persists atomically.

The save path resolves the owner-scoped path lazily through the storage
provider, so per-user isolation falls out of the same plumbing the rest of
the harness uses.

## 5. Fact Lifecycle, Dedup, Upload Scrub & Manual CRUD

**Curated fact lifecycle** (the path the LLM update follows):

* Incoming facts whose `confidence` is below the configured threshold
  (default 0.7) are dropped before they reach the store.
* Content is whitespace-normalised then case-folded into a fact key. New
  facts with a key already present in the document are dropped — duplicate
  prevention is the writer's responsibility, not the model's.
* `factsToRemove` is applied first so a fact being re-asserted in
  `newFacts` does not get removed by its own update.
* When the total exceeds `max_facts` (default 100), the list is sorted by
  `confidence` descending and truncated. The keep-policy is purely
  confidence-based — recency is not a tiebreaker.
* Sync IDs are `fact_<8-hex>` UUIDs minted server-side; clients never
  supply fact IDs on insert. `source` carries the originating `thread_id`
  (or `"unknown"`).

**Upload-mention scrub.** After every successful update, the writer runs a
narrow regex pass over every section's `summary` and over every fact's
`content`. Sentences that describe a file-*upload event* (matching
patterns like `upload(ed) <doc>`, the literal uploads-virtual-path prefix,
or the `<uploaded_files>` marker) are stripped. The regex is deliberately
narrow: phrases like "user works with CSV files" or "prefers PDF export"
must survive untouched, because they describe enduring preferences, not
session-scoped events. This keeps the agent from hallucinating that an
old uploaded file still exists in a new session — uploads are
session-scoped state; persisting them in cold memory would be a
correctness bug, not a feature.

**Manual CRUD vs. curated.** The store also exposes manual entry points
(create / update / delete fact) for operator/UI surfaces. They validate
confidence to a finite `[0, 1]`, refuse empty content, and tag the fact
with `source="manual"`. They do **not** apply the dedup or the
`max_facts` cap — manual edits are assumed to be intentional. Both paths
share the same atomic save (temp-file + rename) and the same
cache-invalidation hook on the storage provider, so the two writers
cannot observe a torn document.

## 6. Injection Budget

The reader side keeps a token-budgeted view of the cold memory. The
injector renders all sections plus the top-N facts (sorted by confidence
descending) and progressively drops facts to fit `max_injection_tokens`
(default 2000). Token counting has two modes:

* `tiktoken` (default, accurate). The encoding is loaded lazily, cached,
  and protected by a "loading" sentinel so concurrent callers fall back to
  estimation rather than each triggering a blocking BPE download. Load
  failures are cached with a timestamp; subsequent calls within a cooldown
  window skip tiktoken entirely instead of re-triggering the failure path.
* `char` (network-free). A CJK-aware character estimator. Choose this in
  network-restricted deployments where the tiktoken data download is
  unreliable.

The injection is wired into the System Prompt as a `<memory>` block. The
static system prompt is intentionally not rewritten — the dynamic block
is injected as a `<system-reminder>` on the first user message of the
turn so that prefix-cache reuse across turns is preserved. See
[[multi-user-isolation]] for owner resolution and [[context-window-management]]
for how the injection budget composes with summarisation.

Related: [[middleware-chain-design]] · [[multi-user-isolation]] · [[system-prompt-template]] · [[context-window-management]] · [[observability-tracing]]
