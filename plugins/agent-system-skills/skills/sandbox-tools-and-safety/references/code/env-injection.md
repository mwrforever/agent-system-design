# sandbox-tools-and-safety · references/code/env-injection.md

> request-scoped secret carrier（`secret_context.py`）+ bash 输出 secret 抹除（`mask_secret_values`）+ channel_user_id 命令串前缀 + GitHub App token env overlay + 本地 bash 门控（`security.py`）。代码为**真实实现**（已按插件匿名化规则映射到自定结构 `core/helix/`，去除项目字样）。原注释保留以保真；关键处补中文注解。

## 1. secret_context.py 完整（request-scoped secret carrier）

request-scoped secret 的值由调用方经 `config.context.secrets` 带入（永不进 message / tool 参数 / 命令串）。skill 在 frontmatter `required-secrets` 声明所需；`SkillActivationMiddleware` 每 turn 重算激活 skill 的注入集写入 `runtime.context["__active_skill_secrets"]`（binding point A+）；`bash_tool` 读它并经 `execute_command(env=...)` 注入子进程。

```python
# core/helix/runtime/secret_context.py
"""Request-scoped secret carrier in the run context (issue #3861).

Callers pass per-request secrets out-of-band in ``config.context.secrets`` — a
mapping of name -> value. The value never enters the prompt, tool arguments, or
the executed command string; it is injected as an environment variable into a
skill's sandbox subprocess only when an activated skill declares it via the
``required-secrets`` frontmatter field.

This module centralises the reserved key name and safe extraction so the carrier
contract lives in one place, consumed by the skill-activation middleware (to
build the per-turn injection set) and the tracing redactor (to strip it from
trace payloads).
"""

from __future__ import annotations

from typing import Any

# Reserved sub-key of the run context that holds request-scoped secrets supplied
# by the caller. Source of truth for what a skill *may* receive.
SECRETS_CONTEXT_KEY = "secrets"

# Reserved sub-key holding the secrets resolved for the currently activated skill
# (binding point A). Written by the skill-activation middleware, read by the bash
# tool. Both reserved keys are stripped from trace payloads (see tracing redactor).
ACTIVE_SECRETS_CONTEXT_KEY = "__active_skill_secrets"


def _string_pairs(raw: Any) -> dict[str, str]:
    if not isinstance(raw, dict):
        return {}
    return {key: value for key, value in raw.items() if isinstance(key, str) and isinstance(value, str)}


def extract_request_secrets(context: Any) -> dict[str, str]:
    """Return the caller-supplied request-scoped secrets mapping, or ``{}``.

    Only string-keyed, string-valued entries are kept; anything else is ignored
    so a malformed carrier can never crash secret resolution or injection.
    """
    if not isinstance(context, dict):
        return {}
    return _string_pairs(context.get(SECRETS_CONTEXT_KEY))


def read_active_secrets(context: Any) -> dict[str, str]:
    """Return the secrets resolved for the active skill (the per-run injection
    set), or ``{}``. Read by the bash tool to build the subprocess env."""
    if not isinstance(context, dict):
        return {}
    return _string_pairs(context.get(ACTIVE_SECRETS_CONTEXT_KEY))


# Private run-context keys the skill-activation middleware uses to carry secret
# bindings across a run. Only ``secrets`` / ``__active_skill_secrets`` hold
# values; the binding-source and audit keys hold names only. All are listed so
# the redaction allowlist stays a complete guard even if a future edit starts
# storing a value under one of the name-only keys.
_SLASH_SECRET_SOURCE_KEY = "__slash_skill_secret_source"
_SECRETS_BINDING_AUDIT_KEY = "__skill_secrets_binding_audit"

# Run-context keys whose values are request-scoped secrets and must be stripped
# before a context mapping is serialized anywhere observable (traces, logs).
REDACTED_CONTEXT_KEYS = frozenset(
    {
        SECRETS_CONTEXT_KEY,
        ACTIVE_SECRETS_CONTEXT_KEY,
        _SLASH_SECRET_SOURCE_KEY,
        _SECRETS_BINDING_AUDIT_KEY,
    }
)


def redact_secret_context_keys(context: Any) -> Any:
    """Return a shallow copy of ``context`` with secret-bearing keys removed.

    Defensive helper for any code path that serializes the run context into an
    observable surface. The trace-metadata builder never copies the context, so
    this is belt-and-suspenders for future call sites and custom tracer
    configurations.
    """
    if not isinstance(context, dict):
        return context
    return {key: value for key, value in context.items() if key not in REDACTED_CONTEXT_KEYS}


def redact_config_secrets(config: Any) -> Any:
    """Return a copy of a run config safe to persist or echo back to clients.

    The request config (``body.config``) is stored verbatim on the run record
    (``runs.kwargs_json``) and echoed by the run API. Strip the secret-bearing
    keys from its ``context`` so a request-scoped secret is never persisted or
    returned, while the live config that drives the run (built separately) keeps
    them. Non-dict / context-less configs pass through unchanged.
    """
    if not isinstance(config, dict):
        return config
    context = config.get("context")
    if not isinstance(context, dict):
        return config
    redacted = dict(config)
    redacted["context"] = redact_secret_context_keys(context)
    return redacted
```

## 2. mask_secret_values（bash 输出 secret 抹除）

这是 request-scoped secret 的**第五个泄漏面**（bash 工具返回 subprocess stdout，不像 MCP 工具）。skill 脚本若 echo 了注入的 secret 值（debugging、`set -x`、error dump），值会流进 tool result → prompt → trace。`mask_secret_values` 把每个非空 secret 值替换为 `[redacted]`。最长值优先（防一个值是另一个的子串时部分泄漏）；短值（`< _MIN_MASK_LENGTH`）跳过（3 字符的 token redact 更可能切碎无关输出而非保护真 secret）。

```python
# core/helix/sandbox/tools.py
_SECRET_REDACTION = "[redacted]"

# Values shorter than this are not redacted from bash output. A short secret
# value (a 2-char region code, a numeric id, a PIN) would otherwise shred
# unrelated bytes of tool output — exit codes, timestamps, sizes, paths —
# corrupting the result the model reads back. The redaction of a value this
# short is more likely noise than genuine leak protection; the secret is still
# injected into the subprocess, only the output mask skips it.
_MIN_MASK_LENGTH = 8


def mask_secret_values(output: str, injected_env: dict[str, str] | None) -> str:
    """Redact injected secret values from bash output before it re-enters context.

    Skill scripts receive request-scoped secrets as env vars (#3861). If a script
    echoes one (debugging, ``set -x``, an error dump), the value would otherwise
    flow into the tool result — and thus into the prompt and the trace. This is
    the skill-specific fifth leak surface (the bash tool returns subprocess stdout,
    unlike MCP tools). Replace each non-empty secret value with a redaction marker.
    Longest values first so a value that is a substring of another is not partially
    revealed. Values shorter than ``_MIN_MASK_LENGTH`` are skipped — a redacted
    3-char token is more likely to corrupt unrelated output than to protect a
    real secret.
    """
    if not injected_env or not output:
        return output
    for value in sorted((v for v in injected_env.values() if v and len(v) >= _MIN_MASK_LENGTH), key=len, reverse=True):
        output = output.replace(value, _SECRET_REDACTION)
    return output
```

## 3. channel_user_id 命令串前缀（_channel_identity_prefix）

IM 平台用户 id（飞书 open_id、Slack Uxxx）暴露给 sandbox 命令（#3914）。它是 **identifier 不是 secret**，故走命令串前缀（`export VAR=<quoted>; `）而非 `execute_command(env=...)` 通道——env 通道预留给 secret，且非空 env 会切 AIO 到 `bash.exec`（fresh session per call, image >= 1.9.3）。per-call `export`/`unset` 让群聊场景（一个 thread/sandbox 多个 sender）的 identity 正确，**不依赖 AIO shell 的会话语义**。

```python
import os
import shlex

# Fixed env var exposing the IM-channel platform user id (Feishu open_id,
# Slack Uxxx, ...) to sandbox commands, so skills can act on the current end
# user's channel identity (#3914). An identifier, not a secret.
CHANNEL_USER_ID_ENV = "HELIX_CHANNEL_USER_ID"

_CHANNEL_USER_ID_CONTEXT_KEY = "channel_user_id"

# body.context is client-writable on web requests, so bound the value: real
# platform ids are tens of chars; anything past this is hostile or corrupt and
# must not bloat every command string sent to the sandbox.
_CHANNEL_USER_ID_MAX_LEN = 256


def _is_windows() -> bool:
    return os.name == "nt"


def _channel_identity_prefix(runtime: Runtime) -> str | None:
    """Build the command prefix that sets or clears the channel-user-id env var.

    Returns ``None`` for a non-IM run (no ``channel_user_id`` key in context) so
    the command is left untouched. For an IM run the prefix is always emitted:

    - valid id (non-empty str within the length cap) → ``export VAR=<quoted>; ``
    - unusable id (empty / non-str / over the cap) → ``unset VAR; ``

    The id deliberately rides the command string instead of the
    ``execute_command(env=...)`` channel: a non-empty ``env`` switches
    ``AioSandbox`` to the ``bash.exec`` API (fresh session per call, image
    >= 1.9.3 required), which is reserved for request-scoped secrets. Emitting an
    explicit ``export``-or-``unset`` on every IM command makes per-call identity
    correct **without depending on the AIO shell's session semantics**: the AIO
    no-env path reuses a persistent shell session (the reason for the class lock,
    #1433), so a bare command could otherwise resolve a stale value exported by
    an earlier sender in a shared group-chat sandbox. The ``unset`` closes the
    window the length/type guard would otherwise open — a sender whose id is
    dropped inherits the previous sender's value. Values are identifiers, not
    secrets, so keeping them in the audit-visible command string is fine.
    """
    context = getattr(runtime, "context", None)
    if not isinstance(context, dict) or _CHANNEL_USER_ID_CONTEXT_KEY not in context:
        return None
    channel_user_id = context.get(_CHANNEL_USER_ID_CONTEXT_KEY)
    if isinstance(channel_user_id, str) and 0 < len(channel_user_id) <= _CHANNEL_USER_ID_MAX_LEN:
        return f"export {CHANNEL_USER_ID_ENV}={shlex.quote(channel_user_id)}; "
    return f"unset {CHANNEL_USER_ID_ENV}; "
```

## 4. GitHub App token env overlay（_github_env_from_runtime）

GitHub channel 在 `ChannelManager`（gateway 层）mint 一个短-lived installation token，经 `run_context["github_token"]` 串到 `runtime.context`。bash 工具把它作为 `GH_TOKEN`（`gh` CLI 读的名）+ `GITHUB_TOKEN`（约定名）的 per-call env overlay 注入。值可是 `str`（简单）或 zero-arg sync callable（自动 refresh， survive 过 1h TTL）。无 token 时返回 `None` 保持非 GitHub run 行为不变。

```python
def _github_env_from_runtime(runtime: Runtime) -> dict[str, str] | None:
    """Build a per-call env overlay carrying a GitHub App installation token.

    The GitHub channel mints a short-lived installation token in the
    ``ChannelManager`` (gateway layer) and threads it through ``run_context``
    so it lands in ``runtime.context["github_token"]``. We expose it to
    the agent's bash as both ``GH_TOKEN`` (what the ``gh`` CLI reads) and
    ``GITHUB_TOKEN`` (the conventional name). Returning ``None`` when no
    token is present keeps non-GitHub runs identical to before.

    The value at ``runtime.context["github_token"]`` may be either:

    * a ``str`` — the captured token, the simple shape used by tests and
      by older code paths that don't need refresh; or
    * a zero-arg sync callable returning ``str`` — a provider that re-mints
      transparently when the underlying installation token's 1h TTL is
      nearing expiry. The provider's cache logic lives gateway-side (see
      ``gateway.github.app_auth.mint_installation_token`` for the
      cache + leeway semantics); the core just calls it.

    The callable path is what lets long autonomous runs survive past the
    60-minute installation-token life: every bash invocation re-asks the
    provider, which returns the cached token until ~55 min, then mints a
    fresh one. Without this, a coder agent doing a multi-hour refactor
    would do most of the work and then 401 on the final ``git push``.

    The token still crosses the core/app boundary as opaque data — the
    core never imports the gateway-side minting code, preserving the
    dependency firewall enforced by ``tests/test_core_app_boundary.py``.
    """
    context = runtime.context if runtime.context is not None else None
    value = context.get("github_token") if context else None
    if callable(value):
        try:
            token = value()
        except Exception:
            logger.warning("github_token provider raised; skipping env overlay", exc_info=True)
            return None
    else:
        token = value
    if not isinstance(token, str) or not token:
        return None
    return {"GH_TOKEN": token, "GITHUB_TOKEN": token}
```

> `bash_tool` 把 secret 注入集与 github env overlay 合并后经 `execute_command(env=injected_env)` 注入。完整 bash_tool 见 [tools.md](./tools.md) §4。

## 5. security.py 完整（本地 bash 门控）

`LocalSandboxProvider` 跑在宿主文件系统上——没有内核级隔离。`is_host_bash_allowed()` 仅当 provider **不是** local（容器化自动放行）或 `sandbox.allow_host_bash: true`（显式 opt-in）才返回 true。`uses_local_sandbox_provider` 通过 config 字符串匹配判定 provider 类型。

```python
# core/helix/sandbox/security.py
"""Security helpers for sandbox capability gating."""

from helix.config import get_app_config

_LOCAL_SANDBOX_PROVIDER_MARKERS = (
    "helix.sandbox.local:LocalSandboxProvider",
    "helix.sandbox.local.local_sandbox_provider:LocalSandboxProvider",
)

LOCAL_HOST_BASH_DISABLED_MESSAGE = (
    "Host bash execution is disabled for LocalSandboxProvider because it is not a secure "
    "sandbox boundary. Switch to AioSandboxProvider for isolated bash access, or set "
    "sandbox.allow_host_bash: true only in a fully trusted local environment."
)

LOCAL_BASH_SUBAGENT_DISABLED_MESSAGE = (
    "Bash subagent is disabled for LocalSandboxProvider because host bash execution is not "
    "a secure sandbox boundary. Switch to AioSandboxProvider for isolated bash access, or "
    "set sandbox.allow_host_bash: true only in a fully trusted local environment."
)


def uses_local_sandbox_provider(config=None) -> bool:
    """Return True when the active sandbox provider is the host-local provider."""
    if config is None:
        config = get_app_config()

    sandbox_cfg = getattr(config, "sandbox", None)
    sandbox_use = getattr(sandbox_cfg, "use", "")
    if sandbox_use in _LOCAL_SANDBOX_PROVIDER_MARKERS:
        return True
    return sandbox_use.endswith(":LocalSandboxProvider") and "helix.sandbox.local" in sandbox_use


def is_host_bash_allowed(config=None) -> bool:
    """Return whether host bash execution is explicitly allowed.

    容器化 provider（AioSandboxProvider / BoxliteProvider）自动放行——它们有内核级隔离。
    仅 LocalSandboxProvider 受 ``sandbox.allow_host_bash`` 显式 opt-in 约束。
    """
    if config is None:
        config = get_app_config()

    sandbox_cfg = getattr(config, "sandbox", None)
    if sandbox_cfg is None:
        return False
    if not uses_local_sandbox_provider(config):
        return True
    return bool(getattr(sandbox_cfg, "allow_host_bash", False))
```

> `bash_tool` 在本地分支开头检查 `is_host_bash_allowed()`——未放行时立即返回 `LOCAL_HOST_BASH_DISABLED_MESSAGE`，不走 `execute_command`。完整 bash_tool 见 [tools.md](./tools.md) §4。
