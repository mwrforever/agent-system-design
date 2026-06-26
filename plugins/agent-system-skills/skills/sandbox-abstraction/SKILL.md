---
name: sandbox-abstraction
description: 设计 agent 的沙箱执行环境——Sandbox / SandboxProvider 抽象、虚拟路径契约、per-thread LRU 实例、Local vs Docker 双实现策略。
---

## 何时用

- 你要让 LLM 执行 shell 命令、读写文件
- 需要"开发期跑本地、生产期跑 Docker"二者切换且**模型无感知**
- 多用户 / 多线程需要文件系统隔离
- 想让 agent 看到的路径稳定（不暴露宿主机绝对路径）

## 设计思想

1. **虚拟路径契约**：模型只看到 `/mnt/user-data/{workspace,uploads,outputs}` / `/mnt/skills` / `/mnt/acp-workspace`。底层是本地目录还是 Docker volume 不暴露。
2. **抽象 + Provider 模式**：`Sandbox` 是接口（`execute_command` / `read_file` / `write_file` / `list_dir` / `glob` / `grep` / `download_file` / `update_file`）；`SandboxProvider` 管生命周期（`acquire` / `acquire_async` / `get` / `release`）。
3. **per-thread sandbox + LRU**：以 `(user_id, thread_id)` 为 key，长期缓存（默认 256 条 LRU）；同一线程跨 turn 复用，避免反复创建。
4. **本地 = 路径翻译**：本地实现持有 `PathMapping(container, host, read_only)` 列表，正向翻译命令 + 反向翻译输出。
5. **Docker = volume mount**：AIO 实现把同名虚拟路径直接 bind-mount 进容器，零翻译。仍保留翻译层做 defense-in-depth。
6. **release 通常 no-op**：跨 turn 复用比反复创建划算；资源在进程退出 / LRU 淘汰时回收。

## 实现模板

### 抽象基类

```python
# sandbox/sandbox.py
from abc import ABC, abstractmethod

class Sandbox(ABC):
    def __init__(self, id: str):
        self._id = id

    @property
    def id(self) -> str: return self._id

    @abstractmethod
    def execute_command(self, command: str) -> str: ...
    @abstractmethod
    def read_file(self, path: str) -> str: ...
    @abstractmethod
    def write_file(self, path: str, content: str, append: bool = False) -> None: ...
    @abstractmethod
    def list_dir(self, path: str, max_depth: int = 2) -> list[str]: ...
    @abstractmethod
    def glob(self, path: str, pattern: str, *, max_results: int = 200) -> tuple[list[str], bool]: ...
    @abstractmethod
    def grep(self, path: str, pattern: str, *, glob: str | None = None,
             literal: bool = False, case_sensitive: bool = False,
             max_results: int = 100) -> tuple[list, bool]: ...
    @abstractmethod
    def download_file(self, path: str) -> bytes: ...
    @abstractmethod
    def update_file(self, path: str, content: bytes) -> None: ...
```

### Provider 抽象

```python
class SandboxProvider(ABC):
    @abstractmethod
    def acquire(self, thread_id: str | None, *, user_id: str | None = None) -> str:
        """返回 sandbox_id；幂等：同 (user, thread) 多次调用返回同一 id."""

    async def acquire_async(self, thread_id, *, user_id=None) -> str:
        """异步包装，默认 to_thread——本地版避免阻塞 event loop."""
        return await asyncio.to_thread(self.acquire, thread_id, user_id=user_id)

    @abstractmethod
    def get(self, sandbox_id: str) -> Sandbox: ...

    @abstractmethod
    def release(self, sandbox_id: str) -> None: ...
```

### 本地实现（路径翻译 + LRU）

```python
@dataclass(frozen=True)
class PathMapping:
    container_path: str        # /mnt/user-data/workspace
    local_path: str            # ~/.agent-framework/users/u_42/threads/t_xx/user-data/workspace
    read_only: bool = False


class LocalSandboxProvider(SandboxProvider):
    DEFAULT_LRU = 256

    def __init__(self):
        self._static_mappings = self._setup_static_mappings()  # /mnt/skills, 自定义 mounts
        self._thread_sandboxes: OrderedDict[tuple[str, str], LocalSandbox] = OrderedDict()
        self._lock = threading.Lock()

    def acquire(self, thread_id, *, user_id=None):
        if thread_id is None:
            return self._get_or_create_generic()        # 旧 id: "local"
        user_id = user_id or get_effective_user_id()
        key = (user_id, thread_id)
        with self._lock:
            sb = self._thread_sandboxes.get(key)
            if sb is not None:
                self._thread_sandboxes.move_to_end(key)
                return sb.id
            mappings = self._static_mappings + self._build_thread_mappings(thread_id, user_id)
            sb = LocalSandbox(id=f"local:{user_id}:{thread_id}", path_mappings=mappings)
            self._thread_sandboxes[key] = sb
            if len(self._thread_sandboxes) > self.DEFAULT_LRU:
                self._thread_sandboxes.popitem(last=False)
            return sb.id


class LocalSandbox(Sandbox):
    def __init__(self, id, path_mappings):
        super().__init__(id)
        self.path_mappings = path_mappings
        self._agent_written_paths: set[str] = set()  # read_file 反向翻译只对 agent 写过的 path 做

    def execute_command(self, command: str) -> str:
        translated = self._translate_command(command)             # /mnt/.. → host path
        result = subprocess.run(self._shell_args(translated),
                                capture_output=True, text=True, timeout=120,
                                cwd=str(self._default_cwd()))
        out = (result.stdout or "") + (result.stderr or "")
        return self._reverse_translate(out)                       # host path → /mnt/..
```

## 反模式

- ❌ 把宿主机绝对路径直接传给模型 → 模型把它写进生成的脚本 → 部署到 Docker 立刻 broken
- ❌ Provider `acquire()` 同步阻塞 → ASGI event loop 卡住（用 `to_thread` 包装）
- ❌ 每次工具调用都 `acquire/release` → Docker 容器反复创建销毁，速度极差
- ❌ 不带 LRU 上限 → 长跑进程缓存爆掉内存
- ❌ Provider 假定 `user_id` 永远在 ContextVar → Timer 线程拿不到（参考 [[memory-system-design]] 的同款坑）
- ✅ acquire 显式接受 `user_id=` 参数；ContextVar 仅作 fallback
- ✅ `release` 是 no-op，依赖 LRU + 进程退出回收

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[sandbox-tools-and-safety]] [[thread-state-and-reducers]] [[multi-user-isolation]]
