# sandbox-tools-and-safety · references/code/path-translation-and-locks.md

> 双向路径翻译核心 + `(sandbox.id, path)` 串行锁 + 本地 bash 命令路径白名单。代码为**真实实现**（已按插件匿名化规则映射到自定结构 `core/helix/`，去除项目字样）。原注释保留以保真；关键处补中文注解。

## 1. 串行锁（file_operation_lock.py 完整）

```python
# core/helix/sandbox/file_operation_lock.py
import threading
import weakref

from helix.sandbox.sandbox import Sandbox

# Use WeakValueDictionary to prevent memory leak in long-running processes.
# Locks are automatically removed when no longer referenced by any thread.
_LockKey = tuple[str, str]
_FILE_OPERATION_LOCKS: weakref.WeakValueDictionary[_LockKey, threading.Lock] = weakref.WeakValueDictionary()
_FILE_OPERATION_LOCKS_GUARD = threading.Lock()


def get_file_operation_lock_key(sandbox: Sandbox, path: str) -> tuple[str, str]:
    sandbox_id = getattr(sandbox, "id", None)
    if not sandbox_id:
        sandbox_id = f"instance:{id(sandbox)}"
    return sandbox_id, path


def get_file_operation_lock(sandbox: Sandbox, path: str) -> threading.Lock:
    lock_key = get_file_operation_lock_key(sandbox, path)
    with _FILE_OPERATION_LOCKS_GUARD:
        lock = _FILE_OPERATION_LOCKS.get(lock_key)
        if lock is None:
            lock = threading.Lock()
            _FILE_OPERATION_LOCKS[lock_key] = lock
        return lock
```

## 2. 路径工具基础

```python
# core/helix/sandbox/tools.py
import posixpath
import re
from pathlib import Path

from helix.config.paths import VIRTUAL_PATH_PREFIX  # "/mnt/user-data"

_ACP_WORKSPACE_VIRTUAL_PATH = "/mnt/acp-workspace"


def _path_variants(path: str) -> set[str]:
    """同一路径的正斜杠 / 反斜杠变体（Windows / POSIX 风格都匹配）。"""
    return {path, path.replace("\\", "/"), path.replace("/", "\\")}


def _path_separator_for_style(path: str) -> str:
    return "\\" if "\\" in path and "/" not in path else "/"


def _join_path_preserving_style(base: str, relative: str) -> str:
    """拼接路径，保留 base 的分隔符风格（POSIX `/` 或 Windows `\\`）。"""
    if not relative:
        return base
    separator = _path_separator_for_style(base)
    normalized_relative = relative.replace("\\" if separator == "/" else "/", separator).lstrip("/\\")
    stripped_base = base.rstrip("/\\")
    return f"{stripped_base}{separator}{normalized_relative}"
```

## 3. 正向翻译：虚拟路径 → 宿主路径

`_thread_virtual_to_actual_mappings` 从 `thread_data` 构建 `{虚拟前缀: 宿主路径}` 映射；当 workspace/uploads/outputs 共享同一 parent 时也映射虚拟根（`/mnt/user-data` → 共同 parent）。`replace_virtual_path` 按**最长前缀优先**匹配，避免 `/mnt/user-data` 吃掉 `/mnt/user-data/workspace` 的精细映射。

```python
def _thread_virtual_to_actual_mappings(thread_data: ThreadDataState) -> dict[str, str]:
    """Build virtual-to-actual path mappings for a thread."""
    mappings: dict[str, str] = {}

    workspace = thread_data.get("workspace_path")
    uploads = thread_data.get("uploads_path")
    outputs = thread_data.get("outputs_path")

    if workspace:
        mappings[f"{VIRTUAL_PATH_PREFIX}/workspace"] = workspace
    if uploads:
        mappings[f"{VIRTUAL_PATH_PREFIX}/uploads"] = uploads
    if outputs:
        mappings[f"{VIRTUAL_PATH_PREFIX}/outputs"] = outputs

    # Also map the virtual root when all known dirs share the same parent.
    actual_dirs = [Path(p) for p in (workspace, uploads, outputs) if p]
    if actual_dirs:
        common_parent = str(Path(actual_dirs[0]).parent)
        if all(str(path.parent) == common_parent for path in actual_dirs):
            mappings[VIRTUAL_PATH_PREFIX] = common_parent

    return mappings


def replace_virtual_path(path: str, thread_data: ThreadDataState | None) -> str:
    """Replace virtual /mnt/user-data paths with actual thread data paths.

    Mapping:
        /mnt/user-data/workspace/* -> thread_data['workspace_path']/*
        /mnt/user-data/uploads/* -> thread_data['uploads_path']/*
        /mnt/user-data/outputs/* -> thread_data['outputs_path']/*

    Args:
        path: The path that may contain virtual path prefix.
        thread_data: The thread data containing actual paths.

    Returns:
        The path with virtual prefix replaced by actual path.
    """
    if thread_data is None:
        return path

    mappings = _thread_virtual_to_actual_mappings(thread_data)
    if not mappings:
        return path

    # Longest-prefix-first replacement with segment-boundary checks.
    for virtual_base, actual_base in sorted(mappings.items(), key=lambda item: len(item[0]), reverse=True):
        if path == virtual_base:
            return actual_base
        if path.startswith(f"{virtual_base}/"):
            rest = path[len(virtual_base) :].lstrip("/")
            result = _join_path_preserving_style(actual_base, rest)
            if path.endswith("/") and not result.endswith(("/", "\\")):
                result += _path_separator_for_style(actual_base)
            return result

    return path


def replace_virtual_paths_in_command(command: str, thread_data: ThreadDataState | None) -> str:
    """Replace /mnt/user-data virtual paths in a command string for local sandbox.

    Skills paths (/mnt/skills) and ACP workspace paths (/mnt/acp-workspace)
    are NOT replaced here — LocalSandbox._resolve_paths_in_command() resolves
    them via PathMapping at execution time, which uses the correct user_id
    from sandbox acquire. Pre-resolving with _resolve_skills_path /
    _resolve_acp_workspace_path uses get_effective_user_id() from contextvar
    which may differ from the sandbox mapping's user_id.

    Args:
        command: The command string that may contain virtual paths.
        thread_data: The thread data containing actual paths.

    Returns:
        The command with user-data virtual paths replaced.
    """
    result = command

    # Skills, ACP workspace, and custom mount paths are resolved by
    # LocalSandbox._resolve_paths_in_command() via PathMapping.

    # Replace user-data paths
    if VIRTUAL_PATH_PREFIX in result and thread_data is not None:
        pattern = re.compile(rf"{re.escape(VIRTUAL_PATH_PREFIX)}(/[^\s\"';&|<>()]*)?")

        def replace_user_data_match(match: re.Match) -> str:
            return replace_virtual_path(match.group(0), thread_data).replace("\\", "/")

        result = pattern.sub(replace_user_data_match, result)

    return result


def _apply_cwd_prefix(command: str, thread_data: ThreadDataState | None) -> str:
    """Prepend 'cd <workspace> &&' so relative paths are anchored to the thread workspace."""
    if thread_data and (workspace := thread_data.get("workspace_path")):
        return f"cd {shlex.quote(workspace)} && {command}"
    return command
```

## 4. 反向遮蔽：宿主路径 → 虚拟路径

反向遮蔽（`mask_local_paths_in_output`）把工具输出里的宿主绝对路径替换回 `/mnt/user-data/...` / `/mnt/skills/...` / `/mnt/acp-workspace/...`。正则按 source 集合编译一次并 LRU 缓存（`_compiled_mask_patterns`）——`mask_local_paths_in_output` 每个 glob/grep match 调一次，不缓存会反复 `re.escape` + `re.compile` + `Path.resolve`（一次系统调用）。

```python
from functools import lru_cache


def _thread_actual_to_virtual_mappings(thread_data: ThreadDataState) -> dict[str, str]:
    """Build actual-to-virtual mappings for output masking."""
    return {actual: virtual for virtual, actual in _thread_virtual_to_actual_mappings(thread_data).items()}


@lru_cache(maxsize=512)
def _compiled_mask_patterns(sources: tuple[tuple[str, str], ...]) -> tuple[tuple[re.Pattern[str], str, str], ...]:
    """Compile the host→virtual masking patterns once per source set.

    ``sources`` is an ordered tuple of ``(host_base, virtual_base)`` pairs
    (skills, then ACP workspace, then per-thread user-data mappings sorted by
    host-path length, longest first). The patterns derive only from
    config-stable + per-thread inputs, so they're cached and reused instead of
    being rebuilt — ``re.escape`` + ``re.compile`` + ``Path.resolve`` (a
    syscall) — on every call. ``mask_local_paths_in_output`` runs once per
    glob/grep match, so without this the same patterns are recompiled per
    match.
    """
    compiled: list[tuple[re.Pattern[str], str, str]] = []
    for host_base, virtual_base in sources:
        seen: set[str] = set()
        # Same base set as ``_path_variants(raw) | _path_variants(resolved)``;
        # ordered deterministically so the cached tuple is stable (variants of
        # one host map to the same virtual and don't overlap after substitution,
        # so order within a source is irrelevant to the result).
        for root in (str(Path(host_base)), str(Path(host_base).resolve())):
            for variant in sorted(_path_variants(root)):
                if variant in seen:
                    continue
                seen.add(variant)
                escaped = re.escape(variant).replace(r"\\", r"[/\\]")
                compiled.append((re.compile(escaped + r"(?:[/\\][^\s\"';&|<>()]*)?"), variant, virtual_base))
    return tuple(compiled)


def mask_local_paths_in_output(output: str, thread_data: ThreadDataState | None) -> str:
    """Mask host absolute paths from local sandbox output using virtual paths.

    Handles user-data paths (per-thread), skills paths (global + per-user
    custom), and ACP workspace paths (per-thread).
    """
    # Build the ordered (host_base, virtual_base) source list. Order is
    # preserved from the original implementation: skills, then per-user
    # custom skills, then ACP workspace, then user-data mappings (longest
    # host path first). Custom mount host paths are masked by
    # LocalSandbox._reverse_resolve_paths_in_output().
    sources: list[tuple[str, str]] = []

    skills_host = _get_skills_host_path()
    if skills_host:
        sources.append((skills_host, _get_skills_container_path()))

    # Per-user custom skills: mask host paths under the user's custom
    # skills directory back to /mnt/skills/custom. The sandbox's
    # _reverse_resolve_path handles this for its own operations, but
    # mask_local_paths_in_output serves as a safety net for edge cases
    # where host paths appear in output that bypassed sandbox resolution.
    try:
        from helix.config.paths import get_paths
        from helix.runtime.user_context import get_effective_user_id

        user_id = get_effective_user_id()
        user_custom_dir = get_paths().user_custom_skills_dir(user_id)
        if user_custom_dir.exists():
            skills_container = _get_skills_container_path()
            sources.append((str(user_custom_dir), f"{skills_container}/custom"))
    except Exception:
        pass

    acp_host = _get_acp_workspace_host_path(_extract_thread_id_from_thread_data(thread_data))
    if acp_host:
        sources.append((acp_host, _ACP_WORKSPACE_VIRTUAL_PATH))

    if thread_data is not None:
        mappings = _thread_actual_to_virtual_mappings(thread_data)
        for actual_base, virtual_base in sorted(mappings.items(), key=lambda item: len(item[0]), reverse=True):
            sources.append((actual_base, virtual_base))

    if not sources:
        return output

    result = output
    for pattern, base, virtual in _compiled_mask_patterns(tuple(sources)):

        def replace_match(match: re.Match, _base: str = base, _virtual: str = virtual) -> str:
            matched_path = match.group(0)
            if matched_path == _base:
                return _virtual
            relative = matched_path[len(_base) :].lstrip("/\\")
            return f"{_virtual}/{relative}" if relative else _virtual

        result = pattern.sub(replace_match, result)

    return result
```

> `_get_skills_host_path` / `_get_skills_container_path` / `_get_acp_workspace_host_path` / `_extract_thread_id_from_thread_data` 是 config 读取辅助（带成功缓存 + 失败不缓存语义，见 `tools.py`）。它们决定 source 集合的 host_base，但不是翻译算法的核心——算法核心是上面的 `_compiled_mask_patterns` + `replace_match`。

## 5. 路径校验（虚拟路径白名单 + 穿越拒绝）

```python
def _reject_path_traversal(path: str) -> None:
    """Reject paths that contain '..' segments to prevent directory traversal."""
    # Normalise to forward slashes, then check for '..' segments.
    normalised = path.replace("\\", "/")
    for segment in normalised.split("/"):
        if segment == "..":
            raise PermissionError("Access denied: path traversal detected")


def validate_local_tool_path(path: str, thread_data: ThreadDataState | None, *, read_only: bool = False) -> None:
    """Validate that a virtual path is allowed for local-sandbox access.

    This function is a security gate — it checks whether *path* may be
    accessed and raises on violation.  It does **not** resolve the virtual
    path to a host path; callers are responsible for resolution via
    ``resolve_and_validate_user_data_path`` or ``_resolve_skills_path``.

    Allowed virtual-path families:
      - ``/mnt/user-data/*``  — always allowed (read + write)
      - ``/mnt/skills/*``     — allowed only when *read_only* is True
      - ``/mnt/acp-workspace/*`` — allowed only when *read_only* is True
      - Custom mount paths (from config.yaml) — respects per-mount ``read_only`` flag

    Args:
        path: The virtual path to validate.
        thread_data: Thread data (must be present for local sandbox).
        read_only: When True, skills and ACP workspace paths are permitted.

    Raises:
        SandboxRuntimeError: If thread data is missing.
        PermissionError: If the path is not allowed or contains traversal.
    """
    if thread_data is None:
        raise SandboxRuntimeError("Thread data not available for local sandbox")

    _reject_path_traversal(path)

    # Skills paths — read-only access only
    if _is_skills_path(path):
        if not read_only:
            raise PermissionError(f"Write access to skills path is not allowed: {path}")
        return

    # ACP workspace paths — read-only access only
    if _is_acp_workspace_path(path):
        if not read_only:
            raise PermissionError(f"Write access to ACP workspace is not allowed: {path}")
        return

    # User-data paths
    if path.startswith(f"{VIRTUAL_PATH_PREFIX}/"):
        return

    # Custom mount paths — respect read_only config
    if _is_custom_mount_path(path):
        mount = _get_custom_mount_for_path(path)
        if mount and mount.read_only and not read_only:
            raise PermissionError(f"Write access to read-only mount is not allowed: {path}")
        return

    raise PermissionError(f"Only paths under {VIRTUAL_PATH_PREFIX}/, {_get_skills_container_path()}/, {_ACP_WORKSPACE_VIRTUAL_PATH}/, or configured mount paths are allowed")


def _validate_resolved_user_data_path(resolved: Path, thread_data: ThreadDataState) -> None:
    """Verify that a resolved host path stays inside allowed per-thread roots.

    Raises PermissionError if the path escapes workspace/uploads/outputs.
    """
    allowed_roots = [
        Path(p).resolve()
        for p in (
            thread_data.get("workspace_path"),
            thread_data.get("uploads_path"),
            thread_data.get("outputs_path"),
        )
        if p is not None
    ]

    if not allowed_roots:
        raise SandboxRuntimeError("No allowed local sandbox directories configured")

    for root in allowed_roots:
        try:
            resolved.relative_to(root)
            return
        except ValueError:
            continue

    raise PermissionError("Access denied: path traversal detected")


def _resolve_and_validate_user_data_path(path: str, thread_data: ThreadDataState) -> str:
    """Resolve a /mnt/user-data virtual path and validate it stays in bounds.

    Returns the resolved host path string.
    """
    resolved_str = replace_virtual_path(path, thread_data)
    resolved = Path(resolved_str).resolve()
    _validate_resolved_user_data_path(resolved, thread_data)
    return str(resolved)
```

## 6. 本地 bash 命令路径白名单（validate_local_bash_command_paths）

这是 `sandbox.allow_host_bash: true` opt-in 之后的 best-effort 兜底。它**不是隔离边界**——注释反复强调只是"显式 opt-in 后的兜底"，真正隔离靠容器化 provider。它拒绝：`file://` URL、`..` 穿越段、`$(cd /etc)` 命令替换、未在白名单的宿主绝对路径、`/` 根路径参数。白名单包括：`/mnt/user-data/*`、`/mnt/skills/*`、`/mnt/acp-workspace/*`、自定义 mount、MCP filesystem allowed_paths、系统路径前缀（`/bin/` `/usr/bin/` `/dev/` 等）。

```python
_ABSOLUTE_PATH_PATTERN = re.compile(r"(?<![:\w])(?<!:/)/(?:[^\s\"'`;&|<>()]+)")
# A ``{...}`` block holding a single identifier-like placeholder (e.g. ``{id}``
# in a REST template or ``{port}`` in an f-string). Bash brace expansion such as
# ``{passwd,shadow}`` or ``{,.bak}`` does NOT match (commas/dots/empty inner).
_IDENTIFIER_BRACE_BLOCK_PATTERN = re.compile(r"\{([^{}]*)\}")
_IDENTIFIER_PATTERN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_FILE_URL_PATTERN = re.compile(r"\bfile://\S+", re.IGNORECASE)
_URL_WITH_SCHEME_PATTERN = re.compile(r"^[a-z][a-z0-9+.-]*://", re.IGNORECASE)
_URL_IN_COMMAND_PATTERN = re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s\"'`;&|<>()]+", re.IGNORECASE)
_DOTDOT_PATH_SEGMENT_PATTERN = re.compile(r"(?:^|[/\\=])\.\.(?:$|[/\\])")
_LOCAL_BASH_SYSTEM_PATH_PREFIXES = (
    "/bin/",
    "/usr/bin/",
    "/usr/sbin/",
    "/sbin/",
    "/opt/homebrew/bin/",
    "/dev/",
)
_LOCAL_BASH_CWD_COMMANDS = {"cd", "pushd"}
_LOCAL_BASH_COMMAND_WRAPPERS = {"command", "builtin"}
_LOCAL_BASH_COMMAND_PREFIX_KEYWORDS = {"!", "{", "case", "do", "elif", "else", "for", "if", "select", "then", "time", "until", "while"}
_LOCAL_BASH_COMMAND_END_KEYWORDS = {"}", "done", "esac", "fi"}
_LOCAL_BASH_ROOT_PATH_COMMANDS = {
    "awk", "cat", "cp", "du", "find", "grep", "head", "less", "ln", "ls",
    "more", "mv", "rm", "sed", "tail", "tar",
}
_SHELL_COMMAND_SEPARATORS = {";", "&&", "||", "|", "|&", "&", "(", ")"}
_SHELL_REDIRECTION_OPERATORS = {
    "<", ">", "<<", ">>", "<<<", "<>", ">&", "<&", "&>", "&>>", ">|",
}


def _is_non_file_url_token(token: str) -> bool:
    """Return True for URL tokens that should not be interpreted as paths."""
    values = [token]
    if "=" in token:
        values.append(token.split("=", 1)[1])

    for value in values:
        match = _URL_WITH_SCHEME_PATTERN.match(value)
        if match and not value.lower().startswith("file://"):
            return True
    return False


def _non_file_url_spans(command: str) -> list[tuple[int, int]]:
    spans = []
    for match in _URL_IN_COMMAND_PATTERN.finditer(command):
        if not match.group().lower().startswith("file://"):
            spans.append(match.span())
    return spans


def _is_in_spans(position: int, spans: list[tuple[int, int]]) -> bool:
    return any(start <= position < end for start, end in spans)


def _has_dotdot_path_segment(token: str) -> bool:
    if _is_non_file_url_token(token):
        return False
    return bool(_DOTDOT_PATH_SEGMENT_PATTERN.search(token))


def _split_shell_tokens(command: str) -> list[str]:
    try:
        normalized = command.replace("\r\n", "\n").replace("\r", "\n").replace("\n", " ; ")
        lexer = shlex.shlex(normalized, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        # The shell will reject malformed quoting later; keep validation
        # best-effort instead of turning syntax errors into security messages.
        return command.split()


def _is_shell_command_separator(token: str) -> bool:
    return token in _SHELL_COMMAND_SEPARATORS


def _is_shell_redirection_operator(token: str) -> bool:
    return token in _SHELL_REDIRECTION_OPERATORS


def _is_shell_assignment(token: str) -> bool:
    name, separator, _ = token.partition("=")
    if not separator or not name:
        return False
    return bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name))


def _is_allowed_local_bash_absolute_path(path: str, allowed_paths: list[str], *, allow_system_paths: bool) -> bool:
    # Check for MCP filesystem server allowed paths
    if any(path.startswith(allowed_path) or path == allowed_path.rstrip("/") for allowed_path in allowed_paths):
        _reject_path_traversal(path)
        return True

    if path == VIRTUAL_PATH_PREFIX or path.startswith(f"{VIRTUAL_PATH_PREFIX}/"):
        _reject_path_traversal(path)
        return True

    # Allow skills container path (resolved by tools.py before passing to sandbox)
    if _is_skills_path(path):
        _reject_path_traversal(path)
        return True

    # Allow ACP workspace path (path-traversal check only)
    if _is_acp_workspace_path(path):
        _reject_path_traversal(path)
        return True

    # Allow custom mount container paths
    if _is_custom_mount_path(path):
        _reject_path_traversal(path)
        return True

    if allow_system_paths and any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in _LOCAL_BASH_SYSTEM_PATH_PREFIXES):
        return True

    return False


def _next_cd_target(tokens: list[str], start_index: int) -> tuple[str | None, int]:
    index = start_index
    while index < len(tokens):
        token = tokens[index]
        if _is_shell_command_separator(token):
            return None, index
        if _is_shell_redirection_operator(token):
            index += 2
            continue
        if token == "--":
            index += 1
            continue
        if token in {"-L", "-P", "-e", "-@"}:
            index += 1
            continue
        if token.startswith("-") and token != "-":
            index += 1
            continue
        return token, index + 1
    return None, index


def _validate_local_bash_cwd_target(command_name: str, target: str | None, allowed_paths: list[str]) -> None:
    if target is None or target == "-":
        raise PermissionError(f"Unsafe working directory change in command: {command_name}. Use paths under {VIRTUAL_PATH_PREFIX}")
    if target.startswith(("$", "`")):
        raise PermissionError(f"Unsafe working directory change in command: {command_name} {target}. Use paths under {VIRTUAL_PATH_PREFIX}")
    if target.startswith("~"):
        raise PermissionError(f"Unsafe working directory change in command: {command_name} {target}. Use paths under {VIRTUAL_PATH_PREFIX}")
    if target.startswith("/"):
        _reject_path_traversal(target)
        if not _is_allowed_local_bash_absolute_path(target, allowed_paths, allow_system_paths=False):
            raise PermissionError(f"Unsafe working directory change in command: {command_name} {target}. Use paths under {VIRTUAL_PATH_PREFIX}")


def _validate_local_bash_root_path_args(command_name: str, tokens: list[str], start_index: int) -> None:
    if command_name not in _LOCAL_BASH_ROOT_PATH_COMMANDS:
        return

    index = start_index
    while index < len(tokens):
        token = tokens[index]
        if _is_shell_command_separator(token):
            return
        if _is_shell_redirection_operator(token):
            index += 2
            continue
        if token == "/" and not _is_non_file_url_token(token):
            raise PermissionError(f"Unsafe absolute paths in command: /. Use paths under {VIRTUAL_PATH_PREFIX}")
        index += 1


def _validate_local_bash_shell_tokens(command: str, allowed_paths: list[str]) -> None:
    """Conservatively reject relative path escapes missed by absolute-path scanning."""
    if re.search(r"\$\([^)]*\b(?:cd|pushd)\b", command):
        raise PermissionError(f"Unsafe working directory change in command substitution. Use paths under {VIRTUAL_PATH_PREFIX}")

    tokens = _split_shell_tokens(command)

    for token in tokens:
        if _is_shell_command_separator(token) or _is_shell_redirection_operator(token):
            continue
        if _has_dotdot_path_segment(token):
            raise PermissionError("Access denied: path traversal detected")

    at_command_start = True
    index = 0
    while index < len(tokens):
        token = tokens[index]

        if _is_shell_command_separator(token):
            at_command_start = True
            index += 1
            continue

        if _is_shell_redirection_operator(token):
            index += 1
            continue

        if at_command_start and _is_shell_assignment(token):
            index += 1
            continue

        command_name = token.rsplit("/", 1)[-1]
        if at_command_start and command_name in _LOCAL_BASH_COMMAND_PREFIX_KEYWORDS | _LOCAL_BASH_COMMAND_END_KEYWORDS:
            index += 1
            continue

        if not at_command_start:
            index += 1
            continue

        at_command_start = False
        if command_name in _LOCAL_BASH_COMMAND_WRAPPERS and index + 1 < len(tokens):
            wrapped_name = tokens[index + 1].rsplit("/", 1)[-1]
            if wrapped_name in _LOCAL_BASH_CWD_COMMANDS:
                target, next_index = _next_cd_target(tokens, index + 2)
                _validate_local_bash_cwd_target(wrapped_name, target, allowed_paths)
                index = next_index
                continue
            _validate_local_bash_root_path_args(wrapped_name, tokens, index + 2)

        if command_name not in _LOCAL_BASH_CWD_COMMANDS:
            _validate_local_bash_root_path_args(command_name, tokens, index + 1)
            index += 1
            continue

        target, next_index = _next_cd_target(tokens, index + 1)
        _validate_local_bash_cwd_target(command_name, target, allowed_paths)
        index = next_index


def _braces_are_identifier_placeholders_only(fragment: str) -> bool:
    """Return True only if every ``{...}`` block is a single identifier placeholder.

    Identifier-only blocks (``{id}``, ``{port}``) come from REST templates and
    f-strings and are text. Bash brace expansion (``{passwd,shadow}``, ``{,.bak}``,
    ``{etc,var}``) reconstitutes real host paths at runtime, so it must NOT be
    exempted. Stray, empty, or nested braces are rejected too (each ``{``/``}``
    must belong to one balanced single-placeholder block).

    ``${VAR}`` shell variable expansion (e.g. ``/home/${USER}/.ssh/id_rsa``) also
    expands to a real host path at runtime, so a ``${`` anywhere disqualifies the
    fragment even though the inner name is identifier-shaped.
    """
    if "${" in fragment:
        return False
    blocks = _IDENTIFIER_BRACE_BLOCK_PATTERN.findall(fragment)
    # Every brace must be part of a balanced ``{...}`` block (no stray/nested braces).
    if fragment.count("{") != len(blocks) or fragment.count("}") != len(blocks):
        return False
    return all(_IDENTIFIER_PATTERN.fullmatch(inner) for inner in blocks)


def _is_non_path_literal_fragment(fragment: str) -> bool:
    """Return True if a ``/segment`` match is almost certainly text, not a path.

    The absolute-path scan runs over the raw command string, so it also matches
    ``/segment`` sequences sitting inside string literals, f-strings, and
    templates (e.g. ``python -c "print(f'/端口{port}')"`` or a REST template
    like ``/devices/{id}/port``). Non-ASCII characters and single identifier-like
    ``{placeholder}`` braces do not appear in real host filesystem paths a command
    would open, so treating such fragments as text removes those false positives.

    Bash brace expansion (``cat /etc/{passwd,shadow}``) is deliberately NOT
    exempted: it expands to plain host paths at runtime, so only braces that are
    single identifier placeholders are treated as text (see
    :func:`_braces_are_identifier_placeholders_only`).

    This guard is best-effort, not a security boundary (see
    :func:`validate_local_bash_command_paths`): plain ASCII host paths such as
    ``/etc/passwd`` contain none of these markers and are still rejected.
    """
    if any(ord(ch) > 127 for ch in fragment):
        return True
    if "{" in fragment or "}" in fragment:
        return _braces_are_identifier_placeholders_only(fragment)
    return False


def validate_local_bash_command_paths(command: str, thread_data: ThreadDataState | None) -> None:
    """Validate absolute paths in local-sandbox bash commands.

    This validation is only a best-effort guard for the explicit
    ``sandbox.allow_host_bash: true`` opt-in. It is not a secure sandbox
    boundary and must not be treated as isolation from the host filesystem.

    In local mode, commands must use virtual paths under /mnt/user-data for
    user data access. Skills paths under /mnt/skills, ACP workspace paths
    under /mnt/acp-workspace, and custom mount container paths (configured in
    config.yaml) are allowed (path-traversal checks only; write prevention
    for bash commands is not enforced here).
    A small allowlist of common system path prefixes is kept for executable
    and device references (e.g. /bin/sh, /dev/null).
    """
    if thread_data is None:
        raise SandboxRuntimeError("Thread data not available for local sandbox")

    # Block file:// URLs which bypass the absolute-path regex but allow local file exfiltration
    file_url_match = _FILE_URL_PATTERN.search(command)
    if file_url_match:
        raise PermissionError(f"Unsafe file:// URL in command: {file_url_match.group()}. Use paths under {VIRTUAL_PATH_PREFIX}")

    unsafe_paths: list[str] = []
    allowed_paths = _get_mcp_allowed_paths()
    _validate_local_bash_shell_tokens(command, allowed_paths)
    url_spans = _non_file_url_spans(command)

    for match in _ABSOLUTE_PATH_PATTERN.finditer(command):
        if _is_in_spans(match.start(), url_spans):
            continue
        absolute_path = match.group()
        if _is_non_path_literal_fragment(absolute_path):
            continue
        if _is_allowed_local_bash_absolute_path(absolute_path, allowed_paths, allow_system_paths=True):
            continue

        unsafe_paths.append(absolute_path)

    if unsafe_paths:
        unsafe = ", ".join(sorted(dict.fromkeys(unsafe_paths)))
        raise PermissionError(f"Unsafe absolute paths in command: {unsafe}. Use paths under {VIRTUAL_PATH_PREFIX}")
```

> 配套辅助 `_is_skills_path` / `_is_acp_workspace_path` / `_is_custom_mount_path` / `_get_custom_mount_for_path` / `_get_mcp_allowed_paths` 是 config 读取 + 前缀判断辅助（见 `tools.py`），决定某路径是否落在允许的虚拟前缀内。完整 skills 路径解析（`_resolve_skills_path` / `_is_disabled_skill_path` / `_extract_skill_name_from_skills_path`）属 `[[skill-system-design]]` 的 disabled-skill 访问控制，本 skill 引用不展开。
