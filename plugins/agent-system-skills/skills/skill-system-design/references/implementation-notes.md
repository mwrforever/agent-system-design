# Skill System — Implementation Notes

## 1. Layout, Discovery & Metadata

A Skill is a directory containing one `SKILL.md` file plus optional support
trees (`scripts/`, `references/`, `templates/`). Discovery walks two roots:

```
<skill-root>/public/<name>/SKILL.md          # committed, read-only baseline
<skill-root>/custom/<name>/SKILL.md          # operator/agent-managed
<skill-root>/custom/.history/<name>.jsonl    # append-only audit trail
```

The storage layer iterates each category root with `os.walk` (follow-symlinks
on, dotfiles filtered) and yields every directory whose immediate file list
contains `SKILL.md`. A nested `SKILL.md` inside a skill is **not** a
sub-skill — installation rejects it outright (see §3).

`SKILL.md` opens with YAML front-matter fenced by `---`. The parser extracts
the fenced block with a single regex, runs `yaml.safe_load`, and requires:

| Field           | Type        | Required | Notes                              |
| --------------- | ----------- | -------- | ---------------------------------- |
| `name`          | string      | yes      | stripped, non-empty                |
| `description`   | string      | yes      | stripped, non-empty                |
| `license`       | string      | no       | normalised to `None` if blank      |
| `allowed-tools` | list[str]   | no       | `None` ≠ `[]` (see §5)             |

YAML errors are not silent. The parser translates `problem_mark` (0-based,
front-matter local) into the editor's 1-based file line by adding 2 — one for
the `---` fence stripped before `safe_load` ran, one for the off-by-one. The
common `key: value with: colon` mistake gets an extra hint suggesting
quoting. Any malformed front-matter → the skill is silently dropped from the
catalog with an `error` log; the rest of the directory keeps loading.

## 2. Enabled State Layering

Discovery returns `Skill(enabled=True)` unconditionally. The real toggle
lives in a sidecar JSON document that maps skill name → `{enabled: bool}`.
Storage merges the two: front-matter is the source of truth for *what* a
skill is, the sidecar is the source of truth for *whether it counts right
now*. This keeps the on-disk skill directory immutable while operator/UI
toggles remain a single-file write — which is what the catalog hash and the
System Prompt block depend on (see [[system-prompt-template]] and
[[tool-assembly-and-policy]]).

Public and custom categories share the same enabled-state namespace but
have different write semantics: public skills are read-only on disk
(committed by operators), custom skills are owner-writable and carry
edit history. Toggling either category goes through the same sidecar
update path, so the UI does not need to know which category a skill
lives in to flip it on or off.

## 3. Installation Pipeline (`.skill` archives)

A `.skill` file is a plain ZIP. Installation is a four-phase pipeline; each
phase has one responsibility and one failure mode.

**Phase 1 — extract safely.** The extractor:

* Rejects absolute paths (POSIX *or* Windows-style) and any member whose
  POSIX-normalised path contains `..`.
* Skips entries whose ZIP external mode bits report `S_ISLNK` — symlinks are
  never materialised.
* Resolves every destination against the extraction root and re-checks
  `is_relative_to(root)` after `joinpath`, blocking traversal even when the
  normalised name looks clean.
* Streams file bodies in 64 KiB chunks with a running byte counter; total
  uncompressed size > 512 MiB raises and aborts. This is the zip-bomb cap.

**Phase 2 — locate the skill root.** Items starting with `.` or named
`__MACOSX` are filtered before deciding whether the archive wraps the skill
in a single top-level directory or dumps it loose.

**Phase 3 — content security scan.** The installer enumerates every file
under the skill root (off the event loop, via `asyncio.to_thread`). For each:

* `SKILL.md` at the root is always scanned (non-executable).
* A nested `SKILL.md` anywhere else raises immediately — no sub-skills.
* Files under `scripts/` are scanned as **executable** (stricter rubric).
* Files under `references/` and `templates/` are scanned only when the
  extension is one of `.md`, `.markdown`, `.rst`, `.txt`, `.json`, `.yaml`,
  `.yml` — the prompt-input surface.
* Everything else is left untouched (binary assets, fonts, fixtures).

Each scan is an async LLM call that must return a JSON object
`{"decision": "allow|warn|block", "reason": "..."}`. Markdown code fences
and brace-balanced extraction recover the JSON when providers wrap output in
prose. Rules:

* `block` → fail the install with the scanner's reason.
* Executable files require `allow`; `warn` is not enough.
* If the model never responded, the fallback is `block` for executables and
  `block` for non-executables alike — fail closed.
* Any non-UTF-8 file under the scan surface is rejected as a scan failure.

**Phase 4 — atomic commit.** The skill is copied to a staging directory
inside the target's parent (`.installing-<name>-…`), then `mkdir(0o700)` on
the real target reserves the slot atomically — `FileExistsError` from that
`mkdir` is translated to a typed `SkillAlreadyExistsError` (no overwrite).
Children are moved in one by one, then the whole tree is reset to
sandbox-readable mode (`555` dirs, `444` files, with group/other write bits
masked off). On any failure between reserve and finalise, the partially
populated target is removed in `finally`. The staging temp dir is cleaned
up with a 5-second timeout so a stalled filesystem cannot block the
install's success/failure propagation.

## 4. Slash Activation

The `/skill-name task…` syntax is a strict prefix grammar:

```
^/([a-z0-9]+(?:-[a-z0-9]+)*)(\s+|$)
```

Note the absence of `\s*` before the slash — leading whitespace disqualifies.
A reserved name set (`new`, `help`, `bootstrap`, `status`, `models`,
`memory`) is filtered before any skill lookup so channel commands never
collide with installed skills.

Activation runs as a `wrap_model_call` middleware. The async path offloads
the *resolution* (filesystem read + hash + escape) into a worker thread but
keeps the message rewrite on the event loop. The middleware:

1. Walks messages back-to-front to find the latest user-visible
   `HumanMessage` (skips `name="summary"` and `hide_from_ui=True`).
2. Bails out if the message *immediately before* the target is already an
   activation reminder for the same target id — re-runs on the same turn
   never re-inject the skill body.
3. Looks up the skill in storage (with disabled skills included) so it can
   distinguish "not installed" from "installed but disabled" and return
   distinct `AIMessage` failure responses.
4. Validates that the resolved `SKILL.md` path is still inside the
   configured skills root *after* resolving symlinks. Anything escaping
   the root is rejected with a load-safety message.
5. Reads the body, computes `sha256`, HTML-escapes every interpolated field
   (skill name, category, container path, hash, content, remaining text),
   and inserts a synthetic `HumanMessage` immediately before the user's
   message with `hide_from_ui=True` and a stable id
   `<target_id>__slash_activation`. Run-journal audit records the activation
   under the `skill_activation` channel.

The injected reminder is a single `<slash_skill_activation>` XML block. It
does not modify the static system prompt, so prefix-cache reuse across the
conversation is preserved.

## 5. Allowed-Tools Policy

`allowed-tools` is the per-skill tool catalog gate. The reducer is
deliberately non-symmetric: as long as **no** active skill declares the
field, the system stays in legacy "allow everything" mode (`None`). The
moment **any** skill declares the field — even as `[]` — the union of every
declaring skill's list becomes the whitelist, and any skill that omitted
the field contributes nothing. This is what makes `allowed-tools: []`
meaningful ("this skill needs no tools") without forcing every legacy
skill in the catalog to be re-authored.

The filter is applied at tool-assembly time against the live Tool Catalog;
unknown names are dropped silently. See [[tool-assembly-and-policy]] for
how this composes with deferred catalogs.

## 6. Filesystem Permissions & Edit History

Installed trees are world-readable, owner-writable. After install, every
directory is `chmod`'d to `mode & ~(S_IWGRP|S_IWOTH) | 0o555` and every file
to `mode & ~(S_IWGRP|S_IWOTH) | 0o444`. Symlinks are left alone (they would
already have been skipped during extraction). When an agent later writes
into a custom skill via the storage API, the writer applies the same mask
along the path from `skill_root` down to the new file — the path *to* the
edit is normalised in lockstep so that adding a new nested directory does
not leave a hole in the read-only invariant.

Agent-initiated edits go through the custom-skill writer, which:

* Validates the relative path against the skill directory (no `..`, no
  absolute paths, no escape via symlink).
* Writes to a sibling temp file and `os.replace`s into place — readers
  never observe a partial file.
* Re-applies the sandbox-readable mask.

Deletes append a JSON-lines record to `<custom>/.history/<name>.jsonl` with
the previous content before `rmtree` runs. The history write is best-effort:
read-only-FS errors (`EACCES`, `EPERM`, `EROFS`) are downgraded to a warning
so the deletion still completes; any other `OSError` propagates.

Related: [[system-prompt-template]] · [[tool-assembly-and-policy]] · [[middleware-chain-design]] · [[harness-app-boundary]] · [[config-and-hot-reload]]
