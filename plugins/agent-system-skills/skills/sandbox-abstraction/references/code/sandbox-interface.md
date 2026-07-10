# sandbox-interface · Sandbox 抽象契约

> 本文件是 `sandbox-abstraction` skill 的代码附件，给出 `Sandbox` 抽象基类与 env-var 名校验的**完整真实源码**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

## 自定路径映射

| 自定路径 | 真实职责 |
|---|---|
| `core/helix/sandbox/sandbox.py` | `Sandbox` 抽象基类 + `_validate_extra_env` env-var 名校验 |
| `core/helix/sandbox/search.py` | `GrepMatch` 数据结构、`find_glob_matches` / `find_grep_matches`（搜索实现） |

---

## 1. env-var 名校验（防御性契约）

`Sandbox.execute_command` 的 `env` 参数接受任意 `str` 键。当前没有任何实现把键拼进 shell 字符串——本地实现走 `subprocess.run(env=...)`（无 shell），AIO 实现走 `bash.exec` 的结构化 `env` 字段（无命令串拼接）。但在抽象层强制 POSIX env-var 名规则是**契约的防御纵深**：未来一个走 shell 拼接的实现不必重新推导自己的规则；一个从配置/payload/用户输入派生键的调用方会快速失败抛 `ValueError`，而非在一个未来回归拼接的实现里静默产出注入。

```python
# core/helix/sandbox/sandbox.py
import re
from abc import ABC, abstractmethod

from helix.sandbox.search import GrepMatch

# POSIX env-var name 规则：字母或下划线开头，后接字母/数字/下划线。
# 用于在 env 键到达具体沙箱实现前做校验。
# 当前没有任何实现把键拼进 shell 串——本地沙箱把 dict 交给
# subprocess.run(env=...)（无 shell），AIO 沙箱通过 bash.exec 的结构化
# env 字段转发，e2b 通过 SDK 的 envs 转发。该校验是为契约做的防御纵深：
# 未来一个把键路由进 shell 的实现不必重新推导自己的校验规则。
_ENV_NAME_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _validate_extra_env(extra_env: dict[str, str] | None) -> None:
    """拒绝不是合法 POSIX env-var 名的 env 键。

    :meth:`Sandbox.execute_command` 契约接受任意 str 键。当前没有任何实现
    把键拼进 shell 串——本地沙箱把 dict 交给 subprocess.run(env=...)（无
    shell），AIO 沙箱通过 bash.exec 的结构化 env 字段转发（无命令串拼
    接），e2b 通过 SDK 的 envs 转发。在抽象层强制 POSIX env-name 规则是
    契约的防御纵深：未来一个把键路由进 shell 的实现不必重新推导自己的
    校验规则，而从配置/payload/用户输入派生键的调用方会快速失败抛
    ValueError，而非在一个未来回归拼接的实现里静默产出利用串。

    Raises:
        ValueError: 当 extra_env 非 None 且任一键不匹配
            ^[A-Za-z_][A-Za-z0-9_]*$ 时。None 与空字典原样通过。
    """
    if not extra_env:
        return
    for key in extra_env:
        if not isinstance(key, str) or not _ENV_NAME_PATTERN.fullmatch(key):
            raise ValueError(f"extra_env key {key!r} is not a valid POSIX environment variable name (must match ^[A-Za-z_][A-Za-z0-9_]*$). This protects shell-using sandbox implementations from command injection via the key.")
```

---

## 2. Sandbox 抽象基类（完整接口）

`Sandbox` 是所有沙箱实现的统一接口。工具层（bash / read_file / write_file / str_replace / ls / glob / grep）只依赖这 8 个方法 + `id` 属性，不感知底层是宿主文件系统、Docker 容器还是 micro-VM。

```python
# core/helix/sandbox/sandbox.py
class Sandbox(ABC):
    """Abstract base class for sandbox environments"""

    _id: str

    def __init__(self, id: str):
        self._id = id

    @property
    def id(self) -> str:
        return self._id

    @abstractmethod
    def execute_command(
        self,
        command: str,
        env: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> str:
        """Execute bash command in sandbox.

        Args:
            command: The command to execute.
            env: Optional per-call environment variables to inject into the
                command's process. Used to pass request-scoped secrets (e.g. a
                short-lived end-user token for skill scripts, issue #3861, or a
                GitHub App installation token for ``git push`` / ``gh``) without
                placing them in the prompt, tool arguments, or the command
                string. When ``None`` the sandbox uses its default environment.
                Keys must be valid POSIX environment-variable names
                (``^[A-Za-z_][A-Za-z0-9_]*$``); implementations validate
                via :func:`_validate_extra_env` before use. Values are
                arbitrary strings — shell-using implementations
                ``shlex.quote`` them on splice.
            timeout: Optional per-call wall-clock timeout in seconds. Local
                sandboxes use this to bound host bash commands so long-lived
                foreground processes cannot hang a turn indefinitely. Remote/AIO
                implementations may ignore it when their backend does not expose
                an equivalent command-timeout control separate from its own API
                timeouts.

        Returns:
            The standard or error output of the command.

        Raises:
            ValueError: when an ``env`` key is not a valid env-var name.
        """
        pass

    @abstractmethod
    def read_file(self, path: str) -> str:
        """Read the content of a file.

        Args:
            path: The absolute path of the file to read.

        Returns:
            The content of the file.
        """
        pass

    @abstractmethod
    def download_file(self, path: str) -> bytes:
        """Download the binary content of a file.

        Args:
            path: The absolute path of the file to download.

        Returns:
            Raw file bytes.

        Raises:
            PermissionError: If path traversal is detected or the path is outside
                the allowed virtual prefix.
            OSError: If the file cannot be read or does not exist.  Both local
                and remote implementations must raise ``OSError`` so callers
                have a single exception type to handle.
        """
        pass

    @abstractmethod
    def list_dir(self, path: str, max_depth=2) -> list[str]:
        """List the contents of a directory.

        Args:
            path: The absolute path of the directory to list.
            max_depth: The maximum depth to traverse. Default is 2.

        Returns:
            The contents of the directory.
        """
        pass

    @abstractmethod
    def write_file(self, path: str, content: str, append: bool = False) -> None:
        """Write content to a file.

        Args:
            path: The absolute path of the file to write to.
            content: The text content to write to the file.
            append: Whether to append the content to the file. If False, the file will be created or overwritten.
        """
        pass

    @abstractmethod
    def glob(self, path: str, pattern: str, *, include_dirs: bool = False, max_results: int = 200) -> tuple[list[str], bool]:
        """Find paths that match a glob pattern under a root directory."""
        pass

    @abstractmethod
    def grep(
        self,
        path: str,
        pattern: str,
        *,
        glob: str | None = None,
        literal: bool = False,
        case_sensitive: bool = False,
        max_results: int = 100,
    ) -> tuple[list[GrepMatch], bool]:
        """Search for matches inside text files under a directory."""
        pass

    @abstractmethod
    def update_file(self, path: str, content: bytes) -> None:
        """Update a file with binary content.

        Args:
            path: The absolute path of the file to update.
            content: The binary content to write to the file.
        """
        pass
```

---

## 契约要点

| 方法 | 返回 / 语义约束 |
|---|---|
| `execute_command(command, env=None, timeout=None)` | 合并 stdout/stderr；非 0 退出附加 `Exit Code: N`；**不抛** `CalledProcessError`；`env` 键必须过 `_validate_extra_env` |
| `read_file(path)` | UTF-8 文本；找不到抛 `FileNotFoundError`；二进制抛 `UnicodeDecodeError` |
| `download_file(path)` | 必须做路径白名单校验，越界抛 `PermissionError`；过大抛 `OSError(EFBIG)` |
| `write_file(path, content, append=False)` | 自动建目录；只读 mount 抛 `OSError(EROFS)` |
| `list_dir(path, max_depth=2)` | 返回虚拟路径（容器路径），不是宿主真实路径 |
| `glob / grep` | 返回 `(matches, truncated_bool)`；matches 已反向解析回虚拟路径 |
| `update_file(path, content: bytes)` | 二进制写入版本；同样受只读 mount 控制 |

**关键不变量**：所有路径参数都是**虚拟路径**（`/mnt/user-data/...`），实现内部翻译到物理路径；返回给模型的内容也必须反向翻译回虚拟路径。模型永远看不到宿主真实路径。
