# provider-and-lru · Provider 生命周期 + per-thread LRU + 路径翻译

> 本文件是 `sandbox-abstraction` skill 的代码附件，给出 `SandboxProvider` 抽象、进程级单例、`LocalSandboxProvider`（per-thread LRU + path_mappings）、`PathMapping`、以及 `LocalSandbox` 路径翻译核心的**完整真实源码**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

## 自定路径映射

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/sandbox/sandbox_provider.py` | `SandboxProvider` 抽象 + 进程级单例（双检锁 + plugin code 跑锁外） |
| `core/helix/sandbox/local/local_sandbox_provider.py` | `LocalSandboxProvider`：静态 mappings + per-thread mappings + LRU + acquire/get/release |
| `core/helix/sandbox/local/local_sandbox.py` | `PathMapping` + `LocalSandbox`：路径翻译核心 + execute_command + read/write_file |

---

## 1. SandboxProvider 抽象 + 进程级单例

`SandboxProvider` 管生命周期（`acquire` / `acquire_async` / `get` / `release` / `reset`），与 `Sandbox`（管执行/IO）正交。进程级单例 `_default_sandbox_provider` 由 `_provider_lock` 守护——但锁只管引用替换，所有 plugin 回调（`__init__` / `reset` / `shutdown` / `resolve_class`）必须跑在锁外，否则插件代码能死锁整个进程。

```python
# core/helix/sandbox/sandbox_provider.py
import asyncio
import threading
from abc import ABC, abstractmethod

from helix.config import get_app_config
from helix.reflection import resolve_class
from helix.sandbox.sandbox import Sandbox


class SandboxProvider(ABC):
    """Abstract base class for sandbox providers"""

    uses_thread_data_mounts: bool = False
    needs_upload_permission_adjustment: bool = True

    @abstractmethod
    def acquire(self, thread_id: str | None = None, *, user_id: str | None = None) -> str:
        """Acquire a sandbox environment and return its ID.

        Returns:
            The ID of the acquired sandbox environment.
        """
        pass

    async def acquire_async(self, thread_id: str | None = None, *, user_id: str | None = None) -> str:
        """Acquire a sandbox without blocking the event loop.

        大多数沙箱 provider 暴露同步生命周期 API，因为本地
        Docker/provisioner 操作是阻塞的。异步运行时应调用本方法，使那些
        阻塞操作跑在 worker 线程而非拖住事件循环。
        """
        return await asyncio.to_thread(self.acquire, thread_id, user_id=user_id)

    @abstractmethod
    def get(self, sandbox_id: str) -> Sandbox | None:
        """Get a sandbox environment by ID."""
        pass

    @abstractmethod
    def release(self, sandbox_id: str) -> None:
        """Release a sandbox environment."""
        pass

    def reset(self) -> None:
        """Clear cached state that survives provider instance replacement."""
        pass


_default_sandbox_provider: SandboxProvider | None = None
# 守护对 _default_sandbox_provider 的一切读写。该单例可从多于一个 OS 线程
# 触达（例如主事件循环和跑自己 loop 的 IM channel 线程），所以一个裸的
# check-then-create 会双重初始化 provider，而一个未同步的 reset/shutdown
# 与 get 竞争可能交给调用方 None 或一个撕裂实例。下面全局的每一次访问都
# 取这把锁，包括 get_sandbox_provider() 里的 read+return。
#
# 这把锁只管引用替换。Provider 回调（__init__、reset()、shutdown()）以及
# resolve_class() 里的动态 import 跑在锁*外*：它们是插件提供的
# （config.sandbox.use 解析到任意类），可能慢，更糟的是可能重入这些生命
# 周期函数。持非可重入 threading.Lock 跨它们会自死锁这类 provider，也会
# 在慢拆除期间阻塞每一个并发 get()。把回调挡在锁外可同时避免两者。
_provider_lock = threading.Lock()


def get_sandbox_provider(**kwargs) -> SandboxProvider:
    """Get the sandbox provider singleton.

    返回缓存的单例实例。用 reset_sandbox_provider() 清缓存，或用
    shutdown_sandbox_provider() 正确拆除并清空。

    Returns:
        A sandbox provider instance.
    """
    global _default_sandbox_provider
    # Fast path：一次加锁读，使并发的 reset/shutdown 不能在 check 与 return
    # 之间把全局置 None。
    with _provider_lock:
        if _default_sandbox_provider is not None:
            return _default_sandbox_provider

    # Cold start。在锁外 resolve + 构造：import 与 provider 构造器是插件
    # 代码，不可跑在非可重入锁下。构造可能与另一调用方竞争；我们在锁内
    # 调和。
    config = get_app_config()
    cls = resolve_class(config.sandbox.use, SandboxProvider)
    provider = cls(**kwargs)

    with _provider_lock:
        if _default_sandbox_provider is None:
            _default_sandbox_provider = provider
            return provider
        # 输掉安装竞争：另一线程先到。winner 在同一锁下读，所以它永远是
        # 活实例，绝不 None。
        winner = _default_sandbox_provider

    # 丢弃我们刚建的实例（锁外）。对有副作用构造器的 provider（例如
    # AioSandboxProvider 启动一个 idle-checker 线程），这会拆除孤儿使其
    # 不泄漏——issue #3721。
    if hasattr(provider, "shutdown"):
        provider.shutdown()
    return winner


def reset_sandbox_provider() -> None:
    """Reset the sandbox provider singleton.

    清缓存实例但不调 shutdown。下次 get_sandbox_provider() 会建新实例。
    适合测试或切换配置时使用。

    Provider 可覆写 reset() 清理它跨实例存活的模块级状态（例如
    LocalSandboxProvider 缓存的 LocalSandbox 单例）。没有它，配置/mount
    变更不会在下次 acquire() 时生效。

    注意：若 provider 有活跃沙箱，它们会变孤儿。用
    shutdown_sandbox_provider() 做完整清理。
    """
    global _default_sandbox_provider
    # 锁内摘引用，锁外跑 provider 的 reset() 回调（见 _provider_lock 注释）。
    with _provider_lock:
        provider = _default_sandbox_provider
        _default_sandbox_provider = None
    if provider is not None:
        provider.reset()


def shutdown_sandbox_provider() -> None:
    """Shutdown and reset the sandbox provider.

    在清空单例前正确拆除 provider（释放所有沙箱）。应用关闭或需要完全
    重置沙箱系统时调用。
    """
    global _default_sandbox_provider
    # 锁内摘引用，锁外跑（可能慢的）shutdown() 回调（见 _provider_lock 注释）。
    with _provider_lock:
        provider = _default_sandbox_provider
        _default_sandbox_provider = None
    if provider is not None and hasattr(provider, "shutdown"):
        provider.shutdown()


def set_sandbox_provider(provider: SandboxProvider) -> None:
    """Set a custom sandbox provider instance.

    允许为测试注入自定义或 mock provider。

    注意：此前安装的 provider 被替换但不拆除；调用方拥有它覆盖实例的生命
    周期。

    Args:
        provider: The SandboxProvider instance to use.
    """
    global _default_sandbox_provider
    with _provider_lock:
        _default_sandbox_provider = provider
```

### Provider 能力旗标

| 旗标 | 默认 | 语义 |
|---|---|---|
| `uses_thread_data_mounts: bool` | `False` | `True` 表示 `/mnt/user-data/{...}` 走 per-thread 物理挂载（本地 provider 自建目录；容器化 provider 通过 bind mount 生效）。读取该旗标的中间件据此决定是否需要额外建目录。 |
| `needs_upload_permission_adjustment: bool` | `True` | 上传中间件是否需要为新写入的文件调整权限位（容器化 provider 通常需要 chown，本地 provider 一般不需要）。 |

---

## 2. PathMapping + LocalSandbox 路径翻译核心

`PathMapping` 是虚拟路径到物理路径的单条映射。`LocalSandbox` 持有一个列表，在命令/内容进入时正向翻译（虚拟到物理），在输出返回时反向翻译（物理到虚拟）。匹配按 `container_path` 长度倒序（最长前缀优先），保证 `/mnt/user-data/workspace` 精细映射不会被 `/mnt/user-data` 父级映射抢先。

```python
# core/helix/sandbox/local/local_sandbox.py
import errno
import logging
import os
import re
import signal
import subprocess
import threading
from dataclasses import dataclass
from functools import cached_property
from pathlib import Path
from typing import NamedTuple

from helix.config.paths import VIRTUAL_PATH_PREFIX
from helix.sandbox.env_policy import build_sandbox_env
from helix.sandbox.sandbox import Sandbox, _validate_extra_env
from helix.sandbox.search import GrepMatch, find_glob_matches, find_grep_matches

logger = logging.getLogger(__name__)

# 单条宿主 bash 命令的默认墙钟超时（秒）。一个阻塞前台命令（例如未后台
# 化启动的 server）在这段时间后被终止，使 agent 的 turn 不会无限挂起。
# 可通过 execute_command(timeout=...) 按 call 覆盖，对 bash 工具可通过
# config.yaml 的 sandbox.bash_command_timeout 覆盖。
DEFAULT_COMMAND_TIMEOUT_SECONDS = 600


@dataclass(frozen=True)
class PathMapping:
    """A path mapping from a container path to a local path with optional read-only flag."""

    container_path: str
    local_path: str
    read_only: bool = False


class ResolvedPath(NamedTuple):
    path: str
    mapping: PathMapping | None


class LocalSandbox(Sandbox):
    def __init__(self, id: str, path_mappings: list[PathMapping] | None = None):
        """
        Initialize local sandbox with optional path mappings.

        Args:
            id: Sandbox identifier
            path_mappings: List of path mappings with optional read-only flag.
                          Skills directory is read-only by default.
        """
        super().__init__(id)
        self.path_mappings = path_mappings or []
        # 追踪通过 write_file 写入的文件，使 read_file 只对 agent 生成内容
        # 做反向路径解析。
        self._agent_written_paths: set[str] = set()

    # path_mappings 在 __init__ 一次性设置且不再变更，所以下面这些有序视
    # 图与编译后的路径改写 pattern 对沙箱生命周期是稳定的。缓存它们避免
    # 在每次 bash/read_file/write_file 调用（agent 热路径）上重新排序与重
    # 新编译这些正则。

    @cached_property
    def _command_pattern(self) -> re.Pattern[str] | None:
        """Compiled matcher for container paths in shell commands (shell-aware boundaries)."""
        mappings = sorted(self.path_mappings, key=lambda m: len(m.container_path), reverse=True)
        if not mappings:
            return None
        # 前瞻 (?=/|$|...) 确保只在路径段边界匹配，防止 /mnt/skills 匹配
        # 进 /mnt/skills-extra。
        patterns = [re.escape(m.container_path) + r"(?=/|$|[\s\"';&|<>()])(?:/[^\s\"';&|<>()]*)?" for m in mappings]
        return re.compile("|".join(f"({p})" for p in patterns))

    @cached_property
    def _content_pattern(self) -> re.Pattern[str] | None:
        """Compiled matcher for container paths in plain file content (text boundaries)."""
        mappings = sorted(self.path_mappings, key=lambda m: len(m.container_path), reverse=True)
        if not mappings:
            return None
        patterns = [re.escape(m.container_path) + r"(?=/|$|[^\w./-])(?:/[^\s\"';&|<>()]*)?" for m in mappings]
        return re.compile("|".join(f"({p})" for p in patterns))

    @cached_property
    def _reverse_output_patterns(self) -> list[re.Pattern[str]]:
        """Compiled matchers for local paths in command output (longest local path first)."""
        return [re.compile(re.escape(self._resolved_local_paths[m]) + r"(?:[/\][^\s\"';&|<>()]*)?") for m in self._mappings_by_local_specificity]

    @cached_property
    def _resolved_local_paths(self) -> dict[PathMapping, str]:
        """Filesystem-resolved local root per mapping. Path.resolve() 碰磁盘，
        且被挂载目录不会移动，所以 resolve 一次后复用。"""
        return {m: str(Path(m.local_path).resolve()) for m in self.path_mappings}

    @cached_property
    def _mappings_by_container_specificity(self) -> list[PathMapping]:
        """Mappings ordered most-specific-container-first (for forward resolution)."""
        return sorted(self.path_mappings, key=lambda m: len(m.container_path.rstrip("/") or "/"), reverse=True)

    @cached_property
    def _mappings_by_local_specificity(self) -> list[PathMapping]:
        """Mappings ordered longest-local-path-first (for reverse resolution)."""
        return sorted(self.path_mappings, key=lambda m: len(m.local_path), reverse=True)
```

### 正向解析（虚拟到物理）+ 只读判定

```python
    def _is_read_only_path(self, resolved_path: str) -> bool:
        """Check if a resolved path is under a read-only mount.

        当多个映射匹配（嵌套 mount）时，选最具体的映射（即 local_path 是
        resolved path 最长前缀的那个），与 _resolve_path 处理容器路径的方式
        对称。
        """
        resolved = str(Path(resolved_path).resolve())

        best_mapping: PathMapping | None = None
        best_prefix_len = -1

        for mapping in self.path_mappings:
            local_resolved = self._resolved_local_paths[mapping]
            if resolved == local_resolved or resolved.startswith(local_resolved + os.sep):
                prefix_len = len(local_resolved)
                if prefix_len > best_prefix_len:
                    best_prefix_len = prefix_len
                    best_mapping = mapping

        if best_mapping is None:
            return False

        return best_mapping.read_only

    def _find_path_mapping(self, path: str) -> tuple[PathMapping, str] | None:
        path_str = str(path)

        for mapping in self._mappings_by_container_specificity:
            container_path = mapping.container_path.rstrip("/") or "/"
            if container_path == "/":
                if path_str.startswith("/"):
                    return mapping, path_str.lstrip("/")
                continue

            if path_str == container_path or path_str.startswith(container_path + "/"):
                relative = path_str[len(container_path) :].lstrip("/")
                return mapping, relative

        return None

    def _resolve_path_with_mapping(self, path: str) -> ResolvedPath:
        """Resolve container path to actual local path using mappings."""
        path_str = str(path)

        mapping_match = self._find_path_mapping(path_str)
        if mapping_match is None:
            return ResolvedPath(path_str, None)

        mapping, relative = mapping_match
        local_root = Path(self._resolved_local_paths[mapping])
        resolved_path = (local_root / relative).resolve() if relative else local_root

        try:
            resolved_path.relative_to(local_root)
        except ValueError as exc:
            raise PermissionError(errno.EACCES, "Access denied: path escapes mounted directory", path_str) from exc

        return ResolvedPath(str(resolved_path), mapping)

    def _resolve_path(self, path: str) -> str:
        return self._resolve_path_with_mapping(path).path

    def _is_resolved_path_read_only(self, resolved: ResolvedPath) -> bool:
        return bool(resolved.mapping and resolved.mapping.read_only) or self._is_read_only_path(resolved.path)
```

### 反向解析（物理到虚拟）

```python
    def _reverse_resolve_path(self, path: str) -> str:
        """Reverse resolve local path back to container path using mappings."""
        normalized_path = path.replace("\\", "/")
        path_str = str(Path(normalized_path).resolve())

        # 逐映射尝试（local path 最长优先，以获得更具体的匹配）
        for mapping in self._mappings_by_local_specificity:
            local_path_resolved = self._resolved_local_paths[mapping]
            if path_str == local_path_resolved or path_str.startswith(local_path_resolved + "/"):
                # 用容器路径替换 local path 前缀
                relative = path_str[len(local_path_resolved) :].lstrip("/")
                resolved = f"{mapping.container_path}/{relative}" if relative else mapping.container_path
                return resolved

        # 无映射，返回原路径
        return path_str

    def _reverse_resolve_paths_in_output(self, output: str) -> str:
        """Reverse resolve local paths back to container paths in output string."""
        # pattern 每沙箱编译一次（local path 最长优先，以正确前缀匹配）并跨
        # 调用复用。
        result = output
        for pattern in self._reverse_output_patterns:

            def replace_match(match: re.Match) -> str:
                matched_path = match.group(0)
                return self._reverse_resolve_path(matched_path)

            result = pattern.sub(replace_match, result)

        return result

    def _resolve_paths_in_command(self, command: str) -> str:
        """Resolve container paths to local paths in a command string."""
        pattern = self._command_pattern
        if pattern is None:
            return command

        def replace_match(match: re.Match) -> str:
            matched_path = match.group(0)
            # 规范为正斜杠，使 bash 不把 Windows 反斜杠序列当转义。
            return self._resolve_path(matched_path).replace("\\", "/")

        return pattern.sub(replace_match, command)

    def _resolve_paths_in_content(self, content: str) -> str:
        """Resolve container paths to local paths in arbitrary file content.

        与 _resolve_paths_in_command（用 shell 感知边界字符）不同，本方法
        把内容当纯文本，解析容器路径前缀的每一次出现。解析后的路径规范为
        正斜杠，避免 Windows 宿主上的反斜杠转义问题（例如 C:\Users..
        破坏 Python 字符串字面量）。
        """
        pattern = self._content_pattern
        if pattern is None:
            return content

        def replace_match(match: re.Match) -> str:
            matched_path = match.group(0)
            resolved = self._resolve_path(matched_path)
            # 规范为正斜杠，使 Windows 反斜杠路径不在源文件里造非法转义序列。
            return resolved.replace("\\", "/")

        return pattern.sub(replace_match, content)
```

---

## 3. execute_command + read_file / write_file（env_policy 集成点）

`execute_command` 是 env_policy 的集成点：先 `_validate_extra_env` 校验键名，再 `build_sandbox_env(env)` 继承 `os.environ` 减去 secret-looking 名 + 叠加注入的 request-scoped secrets，最后翻译命令里的虚拟路径并执行。输出反向翻译回虚拟路径。

```python
    def execute_command(
        self,
        command: str,
        env: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> str:
        # 校验 env 键 against POSIX env-var 规则。防御纵深：
        # subprocess.run(env=...) 不走 shell，所以键里的元字符实际不会
        # 注入——但公共 Sandbox.execute_command 契约与 AIO 沙箱共享，后者
        # 确实把键拼进 export <k>=<v>。在两个实现上强制同一规则，保持契约
        # 一致并迫使任何新调用方使用安全键名。
        _validate_extra_env(env)
        # 执行前解析命令里的容器路径
        resolved_command = self._resolve_paths_in_command(command)
        shell = self._get_shell()
        if timeout is None:
            timeout = DEFAULT_COMMAND_TIMEOUT_SECONDS

        # 继承 os.environ 减去平台 secrets，再叠加注入的 request-scoped
        # secrets（#3861）。始终显式传 env，使平台凭证绝不泄漏进 skill 子
        # 进程。
        sandbox_env = build_sandbox_env(env)
        timed_out = False
        if os.name == "nt":
            # Windows 分支：PowerShell / cmd.exe / msys shell 派遣（省略
            # Windows 分支细节——与 POSIX 同语义，仅 shell 参数不同；完整
            # 实现见源文件）
            if self._is_powershell(shell):
                args = [shell, "-NoProfile", "-Command", resolved_command]
            elif self._is_cmd_shell(shell):
                args = [shell, "/c", resolved_command]
            else:
                args = [shell, "-c", resolved_command]
            result = subprocess.run(args, shell=False, capture_output=True, text=True,
                                     timeout=timeout, env=sandbox_env)
            stdout, stderr, returncode = result.stdout, result.stderr, result.returncode
        else:
            args = [shell, "-c", resolved_command]
            stdout, stderr, returncode, timed_out = self._run_posix_command(args, timeout, sandbox_env)

        output = stdout
        if stderr:
            output += f"\nStd Error:\n{stderr}" if output else stderr
        if timed_out:
            notice = self._format_timeout_notice(timeout)
            output += f"\n{notice}" if output else notice
        elif returncode != 0:
            output += f"\nExit Code: {returncode}"

        final_output = output if output else "(no output)"
        # 反向解析输出里的 local path 回容器路径
        return self._reverse_resolve_paths_in_output(final_output)
```

> `_run_posix_command` 是 POSIX 有界管道捕获 runner：用 daemon 排空线程排空 stdout/stderr 管道同时在内存里只保留有界输出；`stdin=/dev/null` 使读 stdin 的命令立即 EOF；`start_new_session` 把命令放进独立进程组，超时时整组 SIGKILL（含子进程）。该实现属于执行安全细节，深度归 `[[sandbox-tools-and-safety]]`。

### read_file / write_file（正向 + 反向翻译 + 只读 mount 执行）

```python
    def read_file(self, path: str) -> str:
        resolved_path = self._resolve_path(path)
        try:
            with open(resolved_path, encoding="utf-8") as f:
                content = f.read()
            # 只对先前 write_file 写入的文件（agent 生成内容）做反向路径
            # 解析。用户上传文件、外部工具输出及其他非 agent 内容不应被
            # 静默改写——见 PR #1935 讨论。
            if resolved_path in self._agent_written_paths:
                content = self._reverse_resolve_paths_in_output(content)
            return content
        except OSError as e:
            # 用原路径 re-raise 以获更清晰错误信息，隐藏内部 resolved 路径
            raise type(e)(e.errno, e.strerror, path) from None

    def write_file(self, path: str, content: str, append: bool = False) -> None:
        resolved = self._resolve_path_with_mapping(path)
        resolved_path = resolved.path
        if self._is_resolved_path_read_only(resolved):
            raise OSError(errno.EROFS, "Read-only file system", path)
        try:
            dir_path = os.path.dirname(resolved_path)
            if dir_path:
                os.makedirs(dir_path, exist_ok=True)
            # 用 content-specific resolver（正斜杠安全）解析内容里的容器路径
            resolved_content = self._resolve_paths_in_content(content)
            mode = "a" if append else "w"
            with open(resolved_path, mode, encoding="utf-8") as f:
                f.write(resolved_content)
            # 追踪此路径，使 read_file 知道在读取时反向解析。只有 agent 写
            # 入的文件会被反向解析；用户上传与外部工具输出保持不动。
            self._agent_written_paths.add(resolved_path)
        except OSError as e:
            # 用原路径 re-raise 以获更清晰错误信息，隐藏内部 resolved 路径
            raise type(e)(e.errno, e.strerror, path) from None
```

---

## 4. LocalSandboxProvider（per-thread LRU + path_mappings）

`LocalSandboxProvider` 是本地文件系统实现的 provider。核心职责：以 `(user_id, thread_id)` 为 key 缓存 `LocalSandbox` 实例（LRU，默认 256），每个实例的 `path_mappings` 把 `/mnt/user-data/{workspace,uploads,outputs}`、`/mnt/acp-workspace`、`/mnt/skills/{public,custom,legacy}` 映射到该 thread 的宿主目录。`acquire(thread_id)` 返回 `local:{user_id}:{thread_id}`，幂等。

```python
# core/helix/sandbox/local/local_sandbox_provider.py
import logging
import threading
from collections import OrderedDict
from pathlib import Path

from helix.sandbox.local.local_sandbox import LocalSandbox, PathMapping
from helix.sandbox.sandbox import Sandbox
from helix.sandbox.sandbox_provider import SandboxProvider
from helix.skills.storage import user_should_see_legacy_skills

logger = logging.getLogger(__name__)

# 模块级别名，向后兼容直接读 local_sandbox_provider._singleton 的旧调用方/
# 测试。新代码读 provider 实例属性（_generic_sandbox / _thread_sandboxes）。
_singleton: LocalSandbox | None = None

# acquire 中创建的 per-thread mappings 必须预留的虚拟前缀——config.yaml 的
# 自定义 mount 不得与之重叠。
_USER_DATA_VIRTUAL_PREFIX = "/mnt/user-data"
_ACP_WORKSPACE_VIRTUAL_PREFIX = "/mnt/acp-workspace"

# 内存中保留的 per-thread LocalSandbox 实例的默认上限。每个缓存实例很轻
# （一个小 Python 对象 + PathMapping 列表 + 用于反向 resolve 的
# agent-written path 集合），但长跑 gateway 中 thread_id 数量无界。超出
# 上限时丢弃最久未用的条目；该 thread 下次 acquire(thread_id) 重建沙箱，
# 代价是丢失累积的 _agent_written_paths（read_file 回退到无反向解析，与
# 全新 run 同行为）。
DEFAULT_MAX_CACHED_THREAD_SANDBOXES = 256


class LocalSandboxProvider(SandboxProvider):
    """Local-filesystem sandbox provider with per-thread path scoping.

    早期版本返回单个全进程 LocalSandbox（id "local"）。该单例无法在公共
    Sandbox API 边界兑现 /mnt/user-data/... 契约，因为对应宿主目录是
    per-thread（{base_dir}/users/{user_id}/threads/{thread_id}/user-data/）。

    本 provider 现为每个 thread_id 产出一个新 LocalSandbox，其
    path_mappings 含 /mnt/user-data/{workspace,uploads,outputs} 与
    /mnt/acp-workspace 的 thread-scoped 条目，镜像 AioSandboxProvider 把
    这些路径 bind-mount 进 docker 容器的方式。遗留 acquire() / acquire(None)
    仍返回 id "local" 的 generic singleton，供无 thread 上下文的调用方（与
    测试）使用。

    Thread-safety：acquire、get、reset 可能从多个线程调用（Gateway 工具
    派遣、子代理 worker 池、后台 memory updater……），故所有缓存状态变更
    通过一把 provider 级 threading.Lock 串行化。与 AioSandboxProvider 同
    模式。

    Memory bound：_thread_sandboxes 是一个 LRU 缓存，上限
    max_cached_threads（默认 DEFAULT_MAX_CACHED_THREAD_SANDBOXES）。超出
    时下次 acquire 淘汰最久未用条目；被淘汰 thread 的下次 acquire 重建新
    沙箱（仅丢失 _agent_written_paths 反向解析提示，优雅降级 read_file
    输出）。
    """

    uses_thread_data_mounts = True
    needs_upload_permission_adjustment = False

    def __init__(self, max_cached_threads: int = DEFAULT_MAX_CACHED_THREAD_SANDBOXES):
        """Initialize the local sandbox provider with static path mappings.

        Args:
            max_cached_threads: LRU 缓存中保留的 per-thread 沙箱上限。
                超出时下次 acquire 淘汰最久未用条目。
        """
        self._path_mappings = self._setup_path_mappings()
        self._generic_sandbox: LocalSandbox | None = None
        self._thread_sandboxes: OrderedDict[tuple[str, str], LocalSandbox] = OrderedDict()
        self._max_cached_threads = max_cached_threads
        self._lock = threading.Lock()
```

### 静态 mappings（进程级，所有 thread 共享）

`_setup_path_mappings` 构造**进程级**静态映射：公共 skills 目录 + config.yaml 的自定义 mounts。自定义 mounts 不得与保留前缀（`/mnt/user-data`、`/mnt/skills/*`、`/mnt/acp-workspace`）冲突，冲突直接拒绝并告警。

```python
    def _setup_path_mappings(self) -> list[PathMapping]:
        """
        Setup static path mappings shared by every sandbox this provider yields.

        Static mappings cover the **public** skills directory and any custom
        mounts from ``config.yaml`` — both are process-wide and identical for
        every thread.  Per-thread ``/mnt/user-data/...``, ``/mnt/acp-workspace``
        and ``/mnt/skills/custom`` mappings are appended inside
        :meth:`_build_thread_path_mappings` because they depend on
        ``thread_id`` and the effective ``user_id``.

        Returns:
            List of static path mappings
        """
        mappings: list[PathMapping] = []

        # 映射 skills：public + legacy + custom 的分挂载
        try:
            from helix.config import get_app_config

            config = get_app_config()
            skills_path = config.skills.get_skills_path()
            container_path = config.skills.container_path

            # 公共 skills：全局只读——静态，所有 thread 共享
            public_skills_path = skills_path / "public"
            if public_skills_path.exists():
                mappings.append(
                    PathMapping(
                        container_path=f"{container_path}/public",
                        local_path=str(public_skills_path),
                        read_only=True,
                    )
                )

            # 注意：legacy skills mount 不在此处，因为它只对尚无 per-user
            # custom skills 的用户暴露（镜像 UserScopedSkillStorage 的可见性
            # 规则）。对所有用户挂载会让有 per-user custom skills 的用户仍能
            # read_file("/mnt/skills/legacy/<name>/SKILL.md") 读到列表层告知
            # 不存在的内容。见 PR #3889——legacy mount 现在在知道 user_id 后
            # 于 _build_thread_path_mappings 中构造。

            # 注意：custom skills mount 不在此处，因为它是 per-user 的，必须
            # 在 _build_thread_path_mappings 中按 thread 动态构造。之前在
            # init 时挂 get_effective_user_id() 的静态 mount 是错误的：后续
            # 每个用户的沙箱都会把 /mnt/skills/custom 解析到 init 时用户的
            # 目录。

            # 映射 sandbox config 的自定义 mounts
            _RESERVED_CONTAINER_PREFIXES = [
                f"{container_path}/public",
                f"{container_path}/custom",
                f"{container_path}/legacy",
                _ACP_WORKSPACE_VIRTUAL_PREFIX,
                _USER_DATA_VIRTUAL_PREFIX,
            ]
            sandbox_config = config.sandbox
            if sandbox_config and sandbox_config.mounts:
                for mount in sandbox_config.mounts:
                    host_path = Path(mount.host_path)
                    container_path = mount.container_path.rstrip("/") or "/"

                    if not host_path.is_absolute():
                        logger.warning(
                            "Mount host_path must be absolute, skipping: %s -> %s",
                            mount.host_path,
                            mount.container_path,
                        )
                        continue

                    if not container_path.startswith("/"):
                        logger.warning(
                            "Mount container_path must be absolute, skipping: %s -> %s",
                            mount.host_path,
                            mount.container_path,
                        )
                        continue

                    # 拒绝与保留容器路径冲突的 mount
                    if any(container_path == p or container_path.startswith(p + "/") for p in _RESERVED_CONTAINER_PREFIXES):
                        logger.warning(
                            "Mount container_path conflicts with reserved prefix, skipping: %s",
                            mount.container_path,
                        )
                        continue
                    # 确认 host path 存在再添加映射。
                    #
                    # host_path 相对运行本 provider 的进程的文件系统解析——
                    # make dev 时是宿主机，make up 时是 gateway 容器，故任
                    # 何未 bind-mount 进 gateway 镜像的 host path 在此缺失。
                    # 静默跳过会造成高调试成本的静默失败（沙箱 skill / 工具
                    # 读到空目录而非配置的 mount），故升级为 ERROR 并含可操
                    # 作指引。见 #3244。
                    if host_path.exists():
                        mappings.append(
                            PathMapping(
                                container_path=container_path,
                                local_path=str(host_path.resolve()),
                                read_only=mount.read_only,
                            )
                        )
                    else:
                        logger.error(
                            "sandbox.mounts entry %s -> %s ignored: host_path %s does not exist from the "
                            "perspective of the gateway process. In Docker deployments (make up / docker-compose), "
                            "this path must also be bind-mounted into the gateway container — add a matching "
                            "volume entry under services.gateway.volumes in docker/docker-compose.yaml (and use "
                            "the in-container path here), or run in local mode (make dev) where the gateway sees "
                            "the host filesystem directly.",
                            mount.host_path,
                            mount.container_path,
                            mount.host_path,
                        )
        except Exception as e:
            # 配置加载失败时记日志但不中断
            logger.warning("Could not setup path mappings: %s", e, exc_info=True)

        return mappings
```

### 小工具：user_id 解析 + sandbox_id 编解码

```python
    @staticmethod
    def _effective_acquire_user_id(user_id: str | None) -> str:
        from helix.runtime.user_context import get_effective_user_id

        return user_id or get_effective_user_id()

    @staticmethod
    def _thread_key(thread_id: str, user_id: str) -> tuple[str, str]:
        return (user_id, thread_id)

    @staticmethod
    def _sandbox_id_for_thread(thread_id: str, user_id: str) -> str:
        return f"local:{user_id}:{thread_id}"

    @staticmethod
    def _key_from_sandbox_id(sandbox_id: str) -> tuple[str, str] | None:
        if not sandbox_id.startswith("local:"):
            return None
        value = sandbox_id[len("local:") :]
        user_id, separator, thread_id = value.partition(":")
        if not separator or not user_id or not thread_id:
            return None
        return (user_id, thread_id)
```

### per-thread mappings（虚拟路径到 thread 宿主目录）

`_build_thread_path_mappings` 构造**每线程**映射：`/mnt/user-data` 父级 + `{workspace,uploads,outputs}` 子级 + `/mnt/acp-workspace` + per-user custom/legacy skills。物理路径来自 `get_paths()`（`users/{user_id}/threads/{thread_id}/user-data/...`）。`ensure_thread_dirs` 在此建目录（mode 0o777，使容器 UID 可写）。

```python
    @staticmethod
    def _build_thread_path_mappings(thread_id: str, *, user_id: str | None = None) -> list[PathMapping]:
        """Build per-thread path mappings for /mnt/user-data, /mnt/acp-workspace,
        and /mnt/skills/custom.

        在提供时使用显式解析的 user id，为遗留调用方回退到
        get_effective_user_id。custom skills 是 per-user（只读）挂载，因为
        agent 通过 skill_manage_tool 在宿主文件系统（而非沙箱内）写自定义
        skills。
        """
        from helix.config import get_app_config
        from helix.config.paths import get_paths

        paths = get_paths()
        effective_user_id = LocalSandboxProvider._effective_acquire_user_id(user_id)
        paths.ensure_thread_dirs(thread_id, user_id=effective_user_id)

        mappings = [
            # 聚合父级映射，使 ls /mnt/user-data 及其他父级操作与 AIO 内部
            # 行为一致（那里父目录是真实的且含三个子目录）。下面的更长子路径
            # 映射仍对 /mnt/user-data/workspace/... 获胜，因为
            # _find_path_mapping 按 container_path 长度排序。
            PathMapping(
                container_path=_USER_DATA_VIRTUAL_PREFIX,
                local_path=str(paths.sandbox_user_data_dir(thread_id, user_id=effective_user_id)),
                read_only=False,
            ),
            PathMapping(
                container_path=f"{_USER_DATA_VIRTUAL_PREFIX}/workspace",
                local_path=str(paths.sandbox_work_dir(thread_id, user_id=effective_user_id)),
                read_only=False,
            ),
            PathMapping(
                container_path=f"{_USER_DATA_VIRTUAL_PREFIX}/uploads",
                local_path=str(paths.sandbox_uploads_dir(thread_id, user_id=effective_user_id)),
                read_only=False,
            ),
            PathMapping(
                container_path=f"{_USER_DATA_VIRTUAL_PREFIX}/outputs",
                local_path=str(paths.sandbox_outputs_dir(thread_id, user_id=effective_user_id)),
                read_only=False,
            ),
            PathMapping(
                container_path=_ACP_WORKSPACE_VIRTUAL_PREFIX,
                local_path=str(paths.acp_workspace_dir(thread_id, user_id=effective_user_id)),
                read_only=False,
            ),
        ]

        # per-user custom skills mount（只读）。必须 per-thread，因为
        # /mnt/skills/custom 对不同用户解析到不同宿主目录。
        try:
            config = get_app_config()
            skills_container_path = config.skills.container_path
            user_custom_path = paths.user_custom_skills_dir(effective_user_id)
            user_custom_path.mkdir(parents=True, exist_ok=True)

            mappings.append(
                PathMapping(
                    container_path=f"{skills_container_path}/custom",
                    local_path=str(user_custom_path),
                    read_only=True,
                )
            )
        except Exception as exc:
            logger.warning("Could not setup per-thread custom skills mount: %s", exc, exc_info=True)

        # legacy（迁移前 global-custom）skills：仅对尚无 per-user custom
        # skills 的用户挂载，镜像 UserScopedSkillStorage._iter_skill_files
        # 的可见性规则。有自己 per-user custom skills 的用户在列表/prompt 中
        # 看不到 LEGACY，也必须不能通过沙箱读到它——否则列表层与沙箱层对
        # 可见性不一致，而沙箱层是更宽松的那一个。
        try:
            config = get_app_config()
            skills_container_path = config.skills.container_path
            user_custom_path = paths.user_custom_skills_dir(effective_user_id)
            legacy_skills_path = config.skills.get_skills_path() / "custom"
            if user_should_see_legacy_skills(effective_user_id, host_path=str(config.skills.get_skills_path())) and legacy_skills_path.exists():
                mappings.append(
                    PathMapping(
                        container_path=f"{skills_container_path}/legacy",
                        local_path=str(legacy_skills_path),
                        read_only=True,
                    )
                )
        except Exception as exc:
            logger.warning("Could not setup per-thread legacy skills mount: %s", exc, exc_info=True)

        return mappings
```

### acquire / get / release / reset / shutdown（LRU 生命周期）

`acquire` 是 LRU 核心：fast path（锁内命中即提升并返回）→ 锁外做文件系统 IO（`ensure_thread_dirs`）→ 回锁内 re-check（防并发竞争）并插入。`release` 对本地 provider 是 no-op——跨 turn 复用比反复创建划算，资源在 LRU 淘汰或 `reset` 时回收。

```python
    def acquire(self, thread_id: str | None = None, *, user_id: str | None = None) -> str:
        """Return a sandbox id scoped to *thread_id* (or the generic singleton).

        - thread_id=None 保留 id "local" 的遗留 singleton，供无 thread 上下
          文的调用方（如遗留测试、脚本）使用。
        - thread_id="abc" 产出 id "local:abc" 的 per-thread LocalSandbox，
          其 path_mappings 把 /mnt/user-data/... 解析到该 thread 的宿主目
          录。

        Thread-safe under concurrent invocation: 缓存 check + insert 由
        self._lock 守护，故两个在同一 thread_id 上竞争的调用方永远观察到
        同一 LocalSandbox 实例。
        """
        global _singleton

        if thread_id is None:
            with self._lock:
                if self._generic_sandbox is None:
                    self._generic_sandbox = LocalSandbox("local", path_mappings=list(self._path_mappings))
                    _singleton = self._generic_sandbox
                return self._generic_sandbox.id

        effective_user_id = self._effective_acquire_user_id(user_id)
        key = self._thread_key(thread_id, effective_user_id)

        # 锁内 fast path。
        with self._lock:
            cached = self._thread_sandboxes.get(key)
            if cached is not None:
                # 标记为最近使用，使频繁触碰的 thread 在淘汰中存活。
                self._thread_sandboxes.move_to_end(key)
                return cached.id

        # _build_thread_path_mappings 碰文件系统（ensure_thread_dirs）；
        # IO 期间释放锁。
        new_mappings = list(self._path_mappings) + self._build_thread_path_mappings(thread_id, user_id=effective_user_id)

        with self._lock:
            # 锁外 IO 后 re-check：另一调用方可能在我们算 mappings 时已填充
            # 缓存。
            cached = self._thread_sandboxes.get(key)
            if cached is None:
                cached = LocalSandbox(self._sandbox_id_for_thread(thread_id, effective_user_id), path_mappings=new_mappings)
                self._thread_sandboxes[key] = cached
                self._evict_until_within_cap_locked()
            else:
                self._thread_sandboxes.move_to_end(key)
            return cached.id

    def _evict_until_within_cap_locked(self) -> None:
        """LRU-evict cached thread sandboxes once the cap is exceeded.

        Caller MUST hold self._lock.
        """
        while len(self._thread_sandboxes) > self._max_cached_threads:
            evicted_key, _ = self._thread_sandboxes.popitem(last=False)
            logger.info(
                "Evicting LocalSandbox cache entry for user/thread %s/%s (cap=%d)",
                evicted_key[0],
                evicted_key[1],
                self._max_cached_threads,
            )

    def get(self, sandbox_id: str) -> Sandbox | None:
        if sandbox_id == "local":
            with self._lock:
                generic = self._generic_sandbox
            if generic is None:
                self.acquire()
                with self._lock:
                    return self._generic_sandbox
            return generic
        if isinstance(sandbox_id, str) and sandbox_id.startswith("local:"):
            key = self._key_from_sandbox_id(sandbox_id)
            if key is None:
                return None
            with self._lock:
                cached = self._thread_sandboxes.get(key)
                if cached is not None:
                    # 通过 get 触碰一个 thread（tools.py 每次工具调用查一次
                    # 沙箱）在 LRU 序中提升它，使活跃 thread 不在负载下被淘
                    # 汰。
                    self._thread_sandboxes.move_to_end(key)
                return cached
        return None

    def release(self, sandbox_id: str) -> None:
        # LocalSandbox 无资源可释放；保留缓存实例使 _agent_written_paths
        # （用于 read 时反向解析 agent 写入的文件内容）跨 turn 存活。acquire
        # 里的 LRU 淘汰与显式 reset() / shutdown() 是仅有的丢弃缓存条目的
        # 路径。
        #
        # 注意：SandboxMiddleware 刻意不调用本方法，以允许沙箱在同 thread
        # 的多个 turn 间复用。
        pass

    def reset(self) -> None:
        """Drop all cached LocalSandbox instances.

        reset_sandbox_provider() 调用本方法以确保配置 / mount 变更在下次
        acquire() 时生效。同时重置模块级 _singleton 别名，使读它的旧调用
        方/测试看到新状态。
        """
        global _singleton
        with self._lock:
            self._generic_sandbox = None
            self._thread_sandboxes.clear()
            _singleton = None

    def shutdown(self) -> None:
        # LocalSandboxProvider 除缓存的 LocalSandbox 实例外无额外资源，故
        # shutdown 使用与 reset 相同的清理路径。
        self.reset()
```

### sandbox_id 编码契约

| 形态 | 含义 | 谁产出 |
|---|---|---|
| `"local"` | 遗留 generic singleton（无 thread 上下文） | `acquire(None)` |
| `"local:{user_id}:{thread_id}"` | per-thread 本地沙箱 | `acquire(thread_id, user_id=...)` |

`is_local_sandbox(runtime)` 判定函数必须同时接受两种形态：

```python
# core/helix/sandbox/tools.py
def is_local_sandbox(runtime: Runtime | None) -> bool:
    """Check if the current sandbox is a local sandbox.

    接受 generic id "local"（无 thread 上下文 acquire）与 per-thread id
    格式 "local:{user_id}:{thread_id}"（LocalSandboxProvider.acquire 在
    已知 thread 后产出）。
    """
    if runtime is None or runtime.state is None:
        return False
    sandbox_state = runtime.state.get("sandbox")
    if sandbox_state is None:
        return False
    sandbox_id = sandbox_state.get("sandbox_id")
    if not isinstance(sandbox_id, str):
        return False
    return sandbox_id == "local" or sandbox_id.startswith("local:")
```

### provider 类型判定（config 字符串匹配，非 isinstance）

```python
# core/helix/sandbox/security.py
_LOCAL_SANDBOX_PROVIDER_MARKERS = (
    "helix.sandbox.local:LocalSandboxProvider",
    "helix.sandbox.local.local_sandbox_provider:LocalSandboxProvider",
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
```
