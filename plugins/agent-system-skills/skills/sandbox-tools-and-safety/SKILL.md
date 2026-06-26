---
name: sandbox-tools-and-safety
description: 设计 agent 暴露给 LLM 的文件系统工具——bash / read_file / write_file / str_replace。覆盖双向路径翻译、按 (sandbox,path) 串行锁、写入体积上限、本地 bash 默认禁用、错误兜底。
---

## 何时用

- 你要给 LLM 暴露 `bash` / `read_file` / `write_file` / `str_replace` / `glob` / `grep` 工具
- 多个工具调用可能并发改同一个文件（多 task() 同时 str_replace）
- 担心 LLM 在宿主机上 `rm -rf /` 之类的事故
- LLM 一次性 write_file 几百 KB 把模型流卡断

## 设计思想

1. **工具薄一层**：每个 `@tool` 装饰函数只做 (a) 参数校验 (b) 调 `ensure_sandbox_initialized(runtime).method(...)` (c) 包装返回。业务在 `LocalSandbox` 里。
2. **双向路径翻译**：模型输入 `/mnt/...` → 翻译为 host path 给底层；底层输出 host path → 反向翻译回 `/mnt/...`。**反向**只对"agent 写过的文件"做，避免误改用户上传文件里的真实路径字符串。
3. **按 `(sandbox_id, path)` 串行**：`str_replace` / 同路径并发 `write_file` 用 `file_operation_lock` 锁，避免 LLM 并行调用互相覆盖。
4. **`write_file` 体积上限**：80KB 默认上限（issue #3189），oversized 单 shot 写会触发 LLM 流 chunk 超时；用 `append=True` 分段写。
5. **本地 bash 默认禁用**：宿主机 bash 太危险；只有 AIO Docker 沙箱或显式 env 开关才放行。
6. **异常 → ToolMessage(status="error")**：靠 `ToolErrorHandlingMiddleware` 统一兜底，单个工具不抛异常。

## 实现模板

### `bash` 工具

```python
@tool("bash", parse_docstring=True)
def bash_tool(runtime: Runtime, description: str, command: str) -> str:
    """Execute a shell command inside the sandbox.

    Args:
        description: A short (3-5 word) description for logs.
        command: The shell command to execute.
    """
    if not is_host_bash_allowed():
        return LOCAL_HOST_BASH_DISABLED_MESSAGE
    sandbox = ensure_sandbox_initialized(runtime)
    return sandbox.execute_command(command)
```

### `write_file` + 体积上限

```python
_WRITE_FILE_MAX_BYTES = 80 * 1024

@tool("write_file", parse_docstring=True)
def write_file_tool(runtime: Runtime, path: str, content: str,
                    append: bool = False) -> str:
    """Write content to a file. For long content, use append=True to extend.

    Args:
        path: Absolute path (use /mnt/user-data/... paths).
        content: Text content to write.
        append: If True, append to existing file. Default False = overwrite.
    """
    if not append and len(content.encode("utf-8")) > _WRITE_FILE_MAX_BYTES:
        return (f"Error: content exceeds {_WRITE_FILE_MAX_BYTES} bytes. "
                f"Split into smaller pieces and use append=True for sections after the first.")
    sandbox = ensure_sandbox_initialized(runtime)
    sandbox.write_file(path, content, append=append)
    return f"File {'appended' if append else 'written'}: {path}"
```

### `str_replace` + 同路径串行锁

```python
@tool("str_replace", parse_docstring=True)
def str_replace_tool(runtime: Runtime, path: str,
                     old_string: str, new_string: str,
                     replace_all: bool = False) -> str:
    """Replace a substring in a file. By default fails on multiple matches.

    Args:
        path: Absolute path to file.
        old_string: Exact string to replace; must be unique unless replace_all=True.
        new_string: Replacement string.
        replace_all: If True, replace every occurrence.
    """
    sandbox = ensure_sandbox_initialized(runtime)
    # ⭐ 按 (sandbox, path) 维度串行
    with get_file_operation_lock((sandbox.id, path)):
        content = sandbox.read_file(path)
        count = content.count(old_string)
        if count == 0:
            return f"Error: old_string not found in {path}"
        if count > 1 and not replace_all:
            return f"Error: old_string occurs {count} times. Pass replace_all=True or refine."
        new_content = content.replace(old_string, new_string,
                                       -1 if replace_all else 1)
        sandbox.write_file(path, new_content, append=False)
    return f"Replaced in {path} ({count} occurrence{'s' if count != 1 else ''})"
```

### 串行锁实现

```python
# sandbox/file_operation_lock.py
_lock_table: WeakValueDictionary[tuple[str, str], threading.Lock] = WeakValueDictionary()
_table_lock = threading.Lock()

def get_file_operation_lock(key: tuple[str, str]) -> threading.Lock:
    """以 (sandbox_id, path) 为 key，跨工具共享同一把锁."""
    with _table_lock:
        lock = _lock_table.get(key)
        if lock is None:
            lock = threading.Lock()
            _lock_table[key] = lock
        return lock
```

### Bash 安全开关

```python
# sandbox/security.py
LOCAL_HOST_BASH_DISABLED_MESSAGE = (
    "host bash is disabled for safety. Switch sandbox.use to a Docker-isolated "
    "provider, or set <FRAMEWORK_PREFIX>_ALLOW_LOCAL_BASH=1 (development only)."
)

def is_host_bash_allowed(app_config=None) -> bool:
    """Local bash 默认禁用；Docker 沙箱 provider / 显式 env 才放行."""
    app_config = app_config or get_app_config()
    if app_config.sandbox.use.endswith(".DockerSandboxProvider"):
        return True
    # 环境变量名建议加你的框架前缀，避免与第三方冲突
    return os.environ.get("AGENT_FRAMEWORK_ALLOW_LOCAL_BASH") == "1"
```

## 反模式

- ❌ `bash_tool` 不检查 `is_host_bash_allowed` → 默认 dev 模式直接 host 执行
- ❌ `str_replace` 不锁同路径 → 两个并行 task() 都用 str_replace 改同一文件 → 第二个覆盖第一个的修改
- ❌ 单次 `write_file` 几百 KB → LLM 输出 tool_call JSON 时超 stream_chunk_timeout
- ❌ 工具内部抛 raise → 整个 run 崩；应该 return error string 或让 `ToolErrorHandlingMiddleware` 转为 error ToolMessage
- ❌ `read_file` 反向翻译时对所有路径都改 → 用户上传的 PDF 里有 `/usr/bin` 字样会被改坏
- ✅ 反向翻译只对 `_agent_written_paths` 集合内的路径做
- ✅ `bash` / `write_file` / `str_replace` 所有"危险"工具都在 `SandboxAuditMiddleware` 里留审计

## 落地参考

本 skill 在生产实施时的关键组件清单、调参旋钮、常见踩坑与调试要点，详见同目录下的：

- [references/implementation-notes.md](./references/implementation-notes.md)

该文档与本 SKILL.md 同步维护，全部使用通用术语；插件可独立分发，不依赖任何宿主项目目录结构。

## 进一步阅读

- 关联 skill：[[sandbox-abstraction]] [[safety-and-guardrails]] [[middleware-chain-design]]
