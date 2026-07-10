---
name: sandbox-tools-and-safety
description: 设计 agent 暴露给 LLM 的沙箱文件系统工具--bash / read_file / write_file / str_replace / ls。覆盖双向路径翻译（defense-in-depth）、按 (sandbox.id, path) 串行锁、read-before-write 门（hash 盖戳）、env 注入（request-scoped secrets 走 execute_command(env=...) 而非命令串）、本地 bash 默认禁用、进程组墙钟超时、输出脱敏（宿主路径反向遮蔽 + secret 值抹除）。完整真实代码见 references/code/（5 个工具 + 路径翻译核心 + 串行锁 + env 注入）。当你要给 agent 加文件系统/bash 工具、排查并发写互相覆盖/secret 落命令串/宿主路径暴露/写大文件流超时/本地 bash 误启用、或定位沙箱工具在端到端链路⑥执行的位置时调用本 skill。
---

## 何时用

- 你要给 LLM 暴露 `bash` / `read_file` / `write_file` / `str_replace` / `ls` 工具
- 多个工具调用（或多个 `task()` 子代理）可能并发改同一个文件--需要串行锁防互相覆盖
- 担心 request-scoped secret（ERP token 等）落进命令串 / audit 日志 / trace
- 担心宿主真实路径暴露给模型（破坏可移植性 + 泄漏宿主拓扑）
- 排查"本地 bash 默认禁用"、"墙钟超时杀了整个进程组"、"写大文件触发流 chunk 超时"
- 想理解沙箱工具在端到端链路中的位置（⑥执行），或它与沙箱抽象层的边界

> 本 skill 讲沙箱**工具实现与安全**（5 个工具 + 双向路径翻译 + 并发文件锁 + env 注入 + read-before-write 门 + 输出脱敏）。沙箱抽象 / 生命周期 / Provider / 虚拟路径契约 / `env_policy.build_sandbox_env` 在 `[[sandbox-abstraction]]` 讲--本 skill 引用不重复。

## 设计方案（为什么这么设计）

### 核心矛盾：模型要能动手，但要锁死爆炸半径

agent 必须能执行 shell 命令、读写文件--否则它只能"说不能做"。但模型生成的命令和路径不可信（可能 `rm -rf`、可能硬编码宿主绝对路径），且单次 turn 里模型可能并行发起多个写同一文件的工具调用（或多个 `task()` 子代理同时 `str_replace` 同一文件）。工具层必须把不可信输入翻译成隔离环境内的安全执行，并把并发写串行化。

### 解法：薄工具层 + 六道安全闸

每个 `@tool` 函数只做三件事：(a) 参数校验 + 路径翻译；(b) 调 `sandbox.method(...)`；(c) 包装返回（反向遮蔽 + 截断 + 错误兜底）。业务逻辑全在 `Sandbox` 实现里（见 `[[sandbox-abstraction]]`）。工具层叠了六道安全闸：

| 闸 | 守什么 | 怎么守 |
|---|---|---|
| 双向路径翻译 | 模型不接触宿主真实路径 | 进工具正向翻译（虚拟->物理），离工具反向遮蔽（物理->虚拟） |
| `(sandbox.id, path)` 串行锁 | 并发写同一文件不互相覆盖 | `WeakValueDictionary` 锁表，锁内做"读-改-写"原子段 |
| read-before-write 门 | 模型不基于过时假设盲写 | `read_file` 盖 content hash 戳；写前校验最新戳 == 当前 hash |
| env 注入走 `execute_command(env=...)` | secret 不落命令串/日志/trace | request-scoped secret 经 env 参数进子进程，绝不 `export` 进命令串 |
| 本地 bash 默认禁用 | host 非安全边界 | `is_host_bash_allowed()` 默认 false；容器化 provider 自动放行 |
| 进程组墙钟超时 | 长任务不阻塞 turn | `bash_command_timeout`（默认 600s）超时 SIGKILL 整个进程组 |

### 双向路径翻译：为何 defense-in-depth（即使容器化 provider 不需要）

`[[sandbox-abstraction]]` 的虚拟路径契约规定模型只看 `/mnt/user-data/{workspace,uploads,outputs}`、`/mnt/skills/...`、`/mnt/acp-workspace`。三种 provider 各自把虚拟路径映射到物理：

- **LocalSandbox**：宿主文件系统，`/mnt/user-data/...` 在 host 上**不存在**--必须正向翻译为 host 路径才能读写。
- **AioSandbox（Docker）**：把 thread 目录 bind-mount 进容器**同名虚拟路径**，容器内 `/mnt/user-data/...` 原生存在--**零翻译也能跑**。
- **Boxlite（micro-VM）**：同理 mount 进 micro-VM。

既然 AIO 不需要翻译，为何工具层仍保留 `replace_virtual_path` / `replace_virtual_paths_in_command`？

1. **本地 provider 必需**：`is_local_sandbox(runtime)` 命中时，路径不翻译则 host 上找不到文件。
2. **反向遮蔽（`mask_local_paths_in_output`）始终必需**：容器内进程可能输出绝对路径（`pwd`、错误栈、`realpath`），若直接回给模型，既泄漏宿主拓扑，又让模型把它写进生成的脚本--部署到别的 provider 立刻 broken。反向遮蔽把宿主路径统一回 `/mnt/user-data/...`。
3. **双保险**：路径契约在工具层（`tools.py`）和 provider 层（`PathMapping`）各守一次。任何一层漏了，另一层兜底。

> 边界：本 skill 讲 `tools.py` 里的翻译函数（按 `thread_data` 的最长前缀优先匹配）。`PathMapping` 在 `LocalSandbox` 内部的翻译（按 acquire 时的 `user_id`）归 `[[sandbox-abstraction]]`。两者 `user_id` 来源不同（前者 contextvar，后者 acquire 时传入），故 skills / acp-workspace 路径**只由 PathMapping 解析**，`replace_virtual_path` 不碰。

### 按 (sandbox.id, path) 串行锁：为何这个维度

写文件有"读-改-写"模式（`str_replace` 读旧内容 -> 替换 -> 写回）。若两个并发调用进同一文件：

- 锁全局 -> 不相关文件互相阻塞，吞吐崩塌。
- 锁只按 `path` -> 两个**隔离沙箱**（不同 thread）的同名虚拟路径写会互相阻塞--但它们写的是不同物理文件，本不该串行。
- **锁按 `(sandbox.id, path)`** -> 精确到"哪个沙箱的哪个路径"。隔离沙箱的同名虚拟路径不争用（`sandbox.id` 不同）；同一沙箱内同路径并发写串行（`str_replace` 之间、`write_file` 与 `str_replace` 之间）。

`WeakValueDictionary` 让锁随 key 失活自动回收--长跑 gateway 进程中 `thread_id` 无界增长，锁表不会撑爆内存。guard lock（`_FILE_OPERATION_LOCKS_GUARD`）只保护"get-or-create"那一瞬，锁内不碰文件 IO。

> `str_replace` 在锁内做完整"读 -> replace -> 写"；`write_file` 在锁内做"写"。两者同路径并发时，写者等读者-写者释放，不会互相覆盖。

### 进程组墙钟超时：为何不只是 SIGTERM 主进程

模型可能起一个长任务（`python -m http.server`、`npm run dev`）。不 background 的话，命令阻塞整个 turn 直到超时。问题在于：SIGTERM 主进程**不杀子进程**--server fork 出的 worker、`npm` 起的 node 进程会变成孤儿继续占端口、吃 CPU。

解法在 `LocalSandbox.execute_command`（见 `[[sandbox-abstraction]]`）：命令跑在自己的**进程组**里，墙钟超时（`sandbox.bash_command_timeout`，默认 600s）到了对**整个进程组** SIGKILL。工具层只负责读取该配置并传入：

```python
command_timeout = sandbox_cfg.bash_command_timeout if sandbox_cfg else None
output = sandbox.execute_command(command, env=injected_env, timeout=command_timeout)
```

`bash_tool` 的 docstring 还**强约束模型 background 长任务**：`your-command > /mnt/user-data/workspace/server.log 2>&1 &`，从源头减少触发超时的场景。输出经 bounded pipe-drain 线程捕获，stdin 是 `/dev/null`--background 进程立即返回，不阻塞 turn（实现细节归 `[[sandbox-abstraction]]`）。

### env 注入走 execute_command(env=...) 而非命令串：为何

request-scoped secret（`required-secrets` 声明的 ERP token 等，见 `[[tool-assembly-and-policy]]`）要进 skill 子进程，有两条通道：

| 通道 | secret 是否落命令串 | audit 日志 | trace | 命令历史 |
|---|---|---|---|---|
| 命令串前缀 `export TOKEN=xxx; cmd` | **是** | **是** | **是** | **是** |
| `execute_command(env={...})` | 否 | 否 | 否 | 否 |

选后者。`read_active_secrets(runtime.context)` 读出激活 skill 绑定的 secret 集，经 `execute_command(env=injected_env)` 注入。子进程看到环境变量，但命令串 / audit / trace / 历史里都不出现值--这是 `[[sandbox-abstraction]]` 的 `env_policy.build_sandbox_env` 之外的**第五个泄漏面**（bash 工具返回 subprocess stdout，不像 MCP 工具）。

AIO 实现走 `bash.exec` API（`POST /v1/bash/exec`，image >= 1.9.3，fresh session per call）。**image 不支持时 fail-fast**--不回退到命令串前缀，因为没有任何回退能保住 secret 不落命令串（#3921）。

### channel_user_id 例外：为何走命令串前缀

`HELIX_CHANNEL_USER_ID` 暴露 IM 平台用户 id（飞书 open_id、Slack Uxxx）给 sandbox 命令（#3914）。它是 **identifier 不是 secret**，所以走命令串前缀（`export VAR=<quoted>; `）而非 env 通道。原因有二：

1. **env 通道预留给 secret**：非空 `env` 会切 AIO 到 `bash.exec`（fresh session per call）。把 identifier 也塞进去会让所有 IM 命令都走重路径。
2. **per-call 正确性**：AIO 的 no-env 路径**复用持久 shell 会话**（#1433 的类锁原因），bare 命令会继承**上一个 sender** export 的值（群聊场景：一个 thread/sandbox 多个 sender）。每次命令带显式 `export`（有效 id）或 `unset`（空/非 str/超 256 字符）让 per-call identity 正确，**不依赖 AIO shell 的会话语义**。`unset` 关闭长度/类型守卫的窗口--被丢弃的 id 不会继承上一个 sender 的值。

### read-before-write 门：hash 盖戳

模型若不先读就改文件，会基于过时假设盲写（覆盖别人刚写的、丢掉并发修改）。解法是 `ReadBeforeWriteMiddleware`（中间件链第 10 项，见 `[[middleware-chain-design]]`）：

- **盖戳**：`read_file` 通过共享函数 `read_current_file_content` 读内容--中间件在 `read_file` 的 ToolMessage 上盖该文件当前内容的 hash 戳。
- **校验**：`write_file`（覆盖/追加已存在文件）和 `str_replace` 写前检查--该路径**最新 hash 戳**必须 == 文件当前 hash。不匹配 -> 拒绝（`recoverable_by_model=True`）。
- **失效**：任何写使该路径的旧戳失效；连续修改之间必须重读。戳活在 messages 上，**摘要压掉 read 结果自动失效**--不需要显式清理。

`read_current_file_content` 被 `read_file_tool` 和 `ReadBeforeWriteMiddleware` 共享（#3857），保证门 hash 的**正好是 read 工具看到的字节**--两条路径用同一套解析规则（虚拟路径翻译 + disabled skill 检查 + 路径穿越拒绝）。

### 本地 bash 默认禁用：为何 host 不是安全边界

`LocalSandboxProvider` 跑在宿主文件系统上--没有内核级隔离。模型生成的 `rm -rf /` 会真的删宿主。`is_host_bash_allowed()` 默认 false，返回拒绝消息：

> Host bash execution is disabled for LocalSandboxProvider because it is not a secure sandbox boundary. Switch to AioSandboxProvider for isolated bash access, or set sandbox.allow_host_bash: true only in a fully trusted local environment.

仅当 `sandbox.allow_host_bash: true`（显式 opt-in）才放行。即便放行，`validate_local_bash_command_paths` 仍做 best-effort 命令路径白名单（拒绝 `/etc/passwd` 等宿主敏感路径、`file://` URL、`..` 穿越、`$(cd /etc)` 命令替换）--但注释反复强调它**不是隔离边界**，真正隔离靠容器化 provider。

### 与 `[[sandbox-abstraction]]` 的边界

| 本 skill（工具 + 安全） | `[[sandbox-abstraction]]`（抽象 + 生命周期） |
|---|---|
| `bash` / `read_file` / `write_file` / `str_replace` / `ls` 工具实现 | `Sandbox` / `SandboxProvider` 抽象接口 |
| `replace_virtual_path` / `replace_virtual_paths_in_command`（按 `thread_data`） | `PathMapping`（按 acquire 时 `user_id`） |
| `mask_local_paths_in_output` 反向遮蔽宿主路径 | per-thread LRU + path_mappings |
| `file_operation_lock` 并发文件锁（`(sandbox.id, path)` 串行化） | acquire / get / release / reset / shutdown 生命周期 |
| `read_active_secrets` + `execute_command(env=...)` 注入 | `env_policy.build_sandbox_env` 消毒 `os.environ` |
| `is_host_bash_allowed` 本地 bash 门控 | 进程组墙钟超时 + bounded pipe-drain（在 `LocalSandbox.execute_command`） |
| read-before-write 门（hash 校验，与 `[[middleware-chain-design]]` 共治） | Sandbox 单例 + `acquire_async` |

### 在端到端链路中的位置：⑥执行

本 skill 处于 `[[e2e-request-lifecycle]]` 的 **⑥执行** 跳。lead agent 的模型循环驱动工具调用：模型 emit tool_call -> LangGraph `ToolNode` 调度 -> 工具函数读 `runtime.state["sandbox"]`（由 ⑤中间件第 5 项 `SandboxMiddleware` lazy acquire 写入）-> 经虚拟路径在隔离环境执行 -> 返回脱敏/截断后的字符串作为 `ToolMessage.content`。

```text
⑤中间件第 5项 SandboxMiddleware（lazy_init=True）
  └─ wrap_tool_call：首次 tool call 时 ensure_sandbox_initialized
       └─ provider.acquire_async(thread_id, user_id=...) -> sandbox_id
       └─ Command(update={"sandbox": {"sandbox_id": ...}}) 写回 state
⑥执行 lead agent loop（本 skill）
  └─ bash_tool / read_file_tool / write_file_tool / str_replace_tool / ls_tool
       └─ ensure_sandbox_initialized(runtime) -> provider.get(sandbox_id) -> Sandbox 实例
       └─ is_local_sandbox? -> 正向翻译 + 宿主路径校验 : 虚拟路径原生
       └─ sandbox.execute_command(..., env=injected_env, timeout=...) / read_file / write_file
       └─ 反向遮蔽 + secret 抹除 + 截断 -> ToolMessage.content
⑦流式  ToolMessage 经 astream -> SSE 事件 -> 前端渲染
```

## 实现索引

### 文件清单（自定结构映射）

| 自定路径 | 真实职责 | references/code 模块 |
|---|---|---|
| `core/helix/sandbox/tools.py` | 5 个 `@tool` + `ensure_sandbox_initialized(_async)` + `read_current_file_content` + 路径翻译 + 输出截断/脱敏 + channel_user_id 前缀 + github env overlay | [tools.md](./references/code/tools.md) + [path-translation-and-locks.md](./references/code/path-translation-and-locks.md) §3-§4 + [env-injection.md](./references/code/env-injection.md) §2-§4 |
| `core/helix/sandbox/file_operation_lock.py` | `(sandbox.id, path)` 维度的 `WeakValueDictionary` 锁表 | [path-translation-and-locks.md](./references/code/path-translation-and-locks.md) §1 |
| `core/helix/sandbox/security.py` | 本地 bash 门控（`is_host_bash_allowed` / `LOCAL_HOST_BASH_DISABLED_MESSAGE` / `uses_local_sandbox_provider`） | [env-injection.md](./references/code/env-injection.md) §5 |
| `core/helix/runtime/secret_context.py` | request-scoped secret carrier（`SECRETS_CONTEXT_KEY` / `read_active_secrets` / 红线抹除） | [env-injection.md](./references/code/env-injection.md) §1 |

### 模块入口伪代码（完整源码见 references/code/）

每个 `@tool` 函数只做三件事：(a) 参数校验 + 路径翻译；(b) 调 `sandbox.method(...)`；(c) 包装返回（反向遮蔽 + 截断 + 错误兜底）。下面是 5 个工具的决策骨架，完整实现（含完整 docstring / SIZE POLICY / READ-BEFORE-WRITE 文案）见 [tools.md](./references/code/tools.md)：

```python
# 伪代码：5 个工具的决策骨架（完整实现见 references/code/tools.md）
def bash_tool(runtime, description, command):
    sandbox = ensure_sandbox_initialized(runtime)
    injected_env = read_active_secrets(runtime.context) or None       # secret 走 env 通道
    injected_env |= _github_env_from_runtime(runtime)                 # GitHub token overlay
    identity_prefix = _channel_identity_prefix(runtime)               # identifier 走命令串前缀
    if is_local_sandbox(runtime):
        if not is_host_bash_allowed():  return LOCAL_HOST_BASH_DISABLED_MESSAGE
        validate_local_bash_command_paths(command, thread_data)       # opt-in 后 best-effort 白名单
        command = replace_virtual_paths_in_command(command, thread_data)  # 正向翻译（虚拟->宿主）
        command = _apply_cwd_prefix(command, thread_data)             # cd <workspace> &&
        if identity_prefix and not _is_windows():  command = identity_prefix + command
        output = sandbox.execute_command(command, env=injected_env, timeout=bash_command_timeout)
        return _truncate_bash_output(mask_secret_values(mask_local_paths_in_output(output, thread_data), injected_env))
    # AIO/Boxlite：虚拟路径原生存在，跳过翻译/cwd；仍走 identity_prefix + mask_secret_values
    return _truncate_bash_output(mask_secret_values(sandbox.execute_command(command, env=injected_env)))

def write_file_tool(runtime, description, path, content, append=False):
    if not append and len(content) > _effective_write_file_max_bytes():   # 80KB 上限（#3189）
        return "Error: ... exceeds ... limit. Split via str_replace or append=True"
    sandbox = ensure_sandbox_initialized(runtime)
    if is_local_sandbox(runtime):
        validate_local_tool_path(path, thread_data)                  # 虚拟路径白名单 + 穿越拒绝
        path = replace_virtual_path(path, thread_data)               # 正向翻译（custom mount 交 Sandbox）
    with get_file_operation_lock(sandbox, path):        # (sandbox.id, path) 串行锁
        sandbox.write_file(path, content, append)
    return "OK"   # 异常分支化捕获 -> "Error: ..."（不 raise，让模型自纠错）

def str_replace_tool(runtime, description, path, old_str, new_str, replace_all=False):
    sandbox = ensure_sandbox_initialized(runtime)
    if is_local_sandbox(runtime):
        validate_local_tool_path(path, thread_data)
        path = replace_virtual_path(path, thread_data)
    with get_file_operation_lock(sandbox, path):        # 锁内做完整"读 -> 替换 -> 写"原子段
        content = sandbox.read_file(path)
        if old_str not in content:  return "Error: String to replace not found"
        content = content.replace(old_str, new_str, (0 if replace_all else 1))
        sandbox.write_file(path, content)
    return "OK"

def read_file_tool(runtime, description, path, start_line=None, end_line=None):
    if _is_disabled_skill_path(path, user_id):  return "Error: Skill '...' is disabled"   # fail closed
    content = read_current_file_content(runtime, path)   # 与 ReadBeforeWriteMiddleware 共享（#3857）
    return _truncate_read_file_output(content, read_file_output_max_chars)

def ls_tool(runtime, description, path):
    if _is_disabled_skill_path(path, user_id):  return "Error: Skill '...' is disabled"
    sandbox = ensure_sandbox_initialized(runtime)
    if is_local_sandbox(runtime):
        validate_local_tool_path(path, thread_data, read_only=True)
        path = replace_virtual_path(path, thread_data)
    output = "\n".join(sandbox.list_dir(path))
    return _truncate_ls_output(mask_local_paths_in_output(output, thread_data))
```

### 模块索引（完整真实代码）

- **[references/code/tools.md](./references/code/tools.md)**：5 个工具完整实现（含完整 docstring / SIZE POLICY / READ-BEFORE-WRITE 文案）+ `ensure_sandbox_initialized(_async)` + `read_current_file_content` + `_apply_cwd_prefix` + `_truncate_*_output` 系列 + `_format_write_file_error` + `_effective_write_file_max_bytes` + `_sanitize_error`
- **[references/code/path-translation-and-locks.md](./references/code/path-translation-and-locks.md)**：`file_operation_lock.py` 完整（§1）+ `replace_virtual_path` / `replace_virtual_paths_in_command`（§3）+ `mask_local_paths_in_output` / `_compiled_mask_patterns`（LRU 缓存，§4）+ `_thread_virtual_to_actual_mappings` / `validate_local_tool_path` / `validate_local_bash_command_paths`（§5-§6）
- **[references/code/env-injection.md](./references/code/env-injection.md)**：`secret_context.py` 完整（§1）+ `mask_secret_values`（§2）+ `_channel_identity_prefix`（§3）+ `_github_env_from_runtime`（§4）+ `security.py` 完整（§5）

## 反模式与陷阱

- ❌ **`str_replace` 不锁同路径** -> 两个并行 `task()` 子代理都 `str_replace` 同一文件，第二个覆盖第一个的修改（read-then-write 竞争）。修复：锁键 `(sandbox.id, path)`，锁内做完整"读 -> 替换 -> 写"。
- ❌ **锁键只用 `path`** -> 两个隔离沙箱（不同 thread）的同名虚拟路径写互相阻塞，但它们写的是不同物理文件。修复：锁键带 `sandbox.id`，隔离沙箱不争用。
- ❌ **锁表用普通 dict 不用 WeakValueDictionary** -> 长跑 gateway 进程 `thread_id` 无界增长，锁实例永远不释放，内存撑爆。修复：`WeakValueDictionary`，锁随 key 失活自动回收。
- ❌ **长期持有锁对象引用**（`lock = get_file_operation_lock(...); lock.acquire(); ...`）-> WeakValueDictionary 的锁无法被 GC 回收。修复：只在 `with get_file_operation_lock(...)` 表达式里用，不绑定到变量。
- ❌ **secret 走命令串前缀** `export TOKEN=xxx; cmd` -> 值落 audit 日志、trace、命令历史、checkpointer。修复：`execute_command(env={...})` 注入；AIO image 不支持 `bash.exec` 时 fail-fast，不回退命令串。
- ❌ **反向遮蔽漏调一处** -> 宿主真实路径泄漏给模型，模型把它写进生成的脚本，部署到别的 provider 立刻 broken。修复：每个本地 provider 工具的返回路径都调 `mask_local_paths_in_output`；错误信息经 `_sanitize_error` 同样遮蔽。
- ❌ **`mask_secret_values` redact 短值** -> 2 字符的 region code、PIN 被 redact 会切碎无关输出（exit code、timestamp、size）。修复：`_MIN_MASK_LENGTH = 8`，跳过过短的值。
- ❌ **单次 `write_file` 几百 KB** -> tool_call JSON 要连续流式发射，超过 stream_chunk_timeout 的安全窗口，触发 chunk-gap 超时（issue #3189）。修复：80KB 上限（仅非追加）；长文档用 `append=True` 分段或 `str_replace` 增量改。
- ❌ **`bash_tool` 不检查 `is_host_bash_allowed`** -> 本地 dev 模式默认 host 执行，模型生成的 `rm -rf` 真删宿主。修复：本地 provider 默认禁用，仅 `sandbox.allow_host_bash: true` 显式 opt-in 才放行。
- ❌ **`validate_local_bash_command_paths` 当作隔离边界** -> 它只是 opt-in 后的 best-effort 兜底，恶意构造的命令（`eval`、`<( ... )` 进程替换）可能绕过。修复：真正隔离靠容器化 provider；host bash 只在可信环境 opt-in。
- ❌ **工具内部抛 raise** -> `ToolNode` 把异常转成 graph 致命错误，整个 run 崩，丧失"让模型自己纠错"的机会。修复：所有工具把 `Error: ...` 作为正常返回值，分支化捕获 `FileNotFoundError` / `PermissionError` / `UnicodeDecodeError` 等给可操作提示。
- ❌ **路径翻译没按长度倒序** -> `/mnt/user-data` 比 `/mnt/user-data/workspace` 短，按字典序匹配会让 workspace 永远走不到精细映射。修复：按 `virtual_base` 长度倒序匹配。
- ❌ **`read_current_file_content` 与 `ReadBeforeWriteMiddleware` 用两套读取逻辑** -> 门 hash 的字节与 read 工具看到的字节不一致，门误判。修复：共享同一函数（#3857）。
- ❌ **反向遮蔽对用户上传文件也改** -> 用户上传的 PDF 里有 `/usr/bin` 字样被改坏，语义变化。修复：反向遮蔽只对 thread 的 workspace/uploads/outputs/skills/acp-workspace 路径做；用户内容的路径串不动。

## 落地参考（调参旋钮 / 调试日志串 / 自测方向）

**调参旋钮**

| 旋钮 | 来源 | 说明 |
|---|---|---|
| `sandbox.allow_host_bash` | `config.yaml` | 本地 provider 是否放行 host bash（默认 false--非安全边界） |
| `sandbox.bash_command_timeout` | `config.yaml` | 单条 bash 命令墙钟超时（默认 600s）；超时 SIGKILL 整个进程组 |
| `sandbox.bash_output_max_chars` / `ls_output_max_chars` / `read_file_output_max_chars` | `config.yaml` | 输出截断阈值（默认 20000 / 20000 / 50000）；0 禁用截断 |
| `HELIX_WRITE_FILE_MAX_BYTES` | env | 覆盖 80KB 单次非追加写上限；0/负值关闭（用 env 而非 config 是为了让测试/运行期微调无需重启） |
| `read_before_write.enabled` | `config.yaml` | read-before-write 门总开关（默认 on） |
| `start_line` / `end_line` / `max_results` / `replace_all` / `append` | 工具入参 | 运行期旋钮（行范围、搜索结果上限、替换模式、追加模式） |

**关键日志串**

- `Error: Host bash execution is disabled for LocalSandboxProvider ...` - 本地 bash 门控拦截（默认 dev 模式常见）
- `Error: Unsafe absolute paths in command: /etc/passwd, ...` - `validate_local_bash_command_paths` 拒绝宿主敏感路径，违例 token 直接列出
- `Error: write_file content (N bytes) exceeds the 81920-byte single-call limit ...` - 80KB 上限触发，含可操作建议
- `Error: String to replace not found in file: ...` - `str_replace` 的 `old_str` 不在文件中
- `Error: Skill '...' is disabled. Access to its files is blocked.` - disabled skill 文件访问拦截（fail closed）
- `Error: cannot read '...' as text - it appears to be a binary file ...` - 二进制文件误读，提示改用 pandas/openpyxl/view_image
- `... [middle truncated: N chars skipped] ...`（bash）/ `... [truncated: showing first K of N chars ...]`（read_file/ls）- 输出截断 marker

**调试入口**

| 现象 | 看哪里 |
|---|---|
| 工具返回宿主真实路径 | `mask_local_paths_in_output` 是否在返回路径上调过；`_compiled_mask_patterns` 的 source 集合是否含对的 thread mapping |
| 并发写互相覆盖 | `get_file_operation_lock` 的 key 是否含 `sandbox.id`；`str_replace` 是否在锁内做完整读-改-写 |
| secret 泄漏到 trace / 日志 | `execute_command` 是否始终经 `env=` 注入而非命令串；`mask_secret_values` 是否在 bash 输出上跑过；`redact_config_secrets` 是否抹掉了 `runs.kwargs_json` |
| 写大文件后流超时 | `_effective_write_file_max_bytes` 是否生效；模型是否用 `append=True` 分段或 `str_replace` 增量改 |
| 本地 dev 模式 host bash 误启用 | `sandbox.allow_host_bash` 是否被显式设 true；`is_host_bash_allowed` 的 provider 判定 |
| 长任务阻塞 turn | 命令是否 background（`> log 2>&1 &`）；`bash_command_timeout` 是否合理；进程组 SIGKILL 是否覆盖子进程 |
| read-before-write 门误判 | `read_current_file_content` 是否被 read 工具与中间件共享；hash 戳是否在摘要后失效 |
| LRU 锁表泄漏 | 是否用了 `WeakValueDictionary`；是否长期持有锁对象引用 |

**自测方向**

- **串行锁维度**：`get_file_operation_lock(sandbox_a, path)` 与 `get_file_operation_lock(sandbox_b, path)` 返回不同锁实例（`sandbox.id` 不同）；同 sandbox 同 path 返回同一锁。
- **并发写不覆盖**：两线程并发 `str_replace` 同文件不同 `old_str`，断言两次替换都生效（锁内串行）。
- **80KB 上限**：`write_file(append=False, content="x"*81921)` 返回错误含 "exceeds"；`append=True` 同长度不受限。
- **env 注入**：mock `runtime.context["__active_skill_secrets"] = {"TOKEN": "v"}`，断言 `execute_command(env={"TOKEN": "v"})` 被调；命令串不含 "TOKEN" 或 "v"。
- **secret 抹除**：bash 输出含注入的 secret 值，断言返回字符串里该值被 `[redacted]` 替换；短值（<8 chars）不替换。
- **反向遮蔽**：本地 bash 输出含 workspace 宿主绝对路径，断言返回字符串里只有 `/mnt/user-data/workspace/...`。
- **本地 bash 门控**：`sandbox.allow_host_bash: false` 时 `bash_tool` 返回 `LOCAL_HOST_BASH_DISABLED_MESSAGE`；`true` 时放行。
- **路径白名单**：`validate_local_bash_command_paths` 对 `cat /etc/passwd`、`curl file:///etc/shadow`、`cat /mnt/user-data/../../etc/passwd`、`$(cd /etc)` 都抛 `PermissionError`；对 `cat /mnt/user-data/workspace/app.py`、`/bin/ls`、`python -c "print('/devices/{id}/port')"` 都放行。
- **错误兜底**：`read_file` 读不存在的文件返回 `Error: File not found`；读二进制返回 `Error: cannot read ... as text`；不抛异常。
- **read-before-write 共享**：`read_current_file_content` 被 `read_file_tool` 和 `ReadBeforeWriteMiddleware` 调用，两者对同路径返回字节级一致。
- **截断总长**：`_truncate_*_output(s, max_chars)` 对边界 max_chars（0、marker 长度、total-1、total）返回字符串总长 ≤ max_chars（含 marker）。

## 进一步阅读

- 共享约定（代号 / 结构 / 匿名化映射 / 6 段骨架）：[../../CONVENTIONS.md](../../CONVENTIONS.md)
- 代码附件：
  - [references/code/tools.md](./references/code/tools.md)：5 个工具完整实现 + `ensure_sandbox_initialized` + `read_current_file_content` + 输出截断/错误格式化
  - [references/code/path-translation-and-locks.md](./references/code/path-translation-and-locks.md)：双向路径翻译核心 + `file_operation_lock.py` 完整 + 命令路径白名单
  - [references/code/env-injection.md](./references/code/env-injection.md)：`secret_context.py` 完整 + `mask_secret_values` + channel_user_id 前缀 + github env overlay + `security.py` 本地 bash 门控
- 关联 skill：
  - `[[e2e-request-lifecycle]]`：本 skill 处于⑥执行跳；工具返回的 ToolMessage 经⑦流式 -> ⑧渲染
  - `[[sandbox-abstraction]]`：沙箱抽象 / 生命周期 / Provider / 虚拟路径契约 / `env_policy` / 进程组超时实现（本 skill 讲工具层，不重复抽象细节）
  - `[[middleware-chain-design]]`：`SandboxMiddleware`（第 5 项 lazy acquire）+ `SandboxAuditMiddleware`（第 9 项审计）+ `ReadBeforeWriteMiddleware`（第 10 项 hash 门）
  - `[[tool-assembly-and-policy]]`：工具装配（沙箱工具从 config 加载）+ `required-secrets` 声明与绑定
  - `[[safety-and-guardrails]]`：`GuardrailMiddleware` 工具调用授权 + `InputSanitizationMiddleware`
  - `[[multi-user-isolation]]`：`(user_id, thread_id)` 物理目录隔离（路径翻译的物理落点依赖该隔离方案）
  - `[[skill-system-design]]`：disabled skill 文件访问拦截（fail closed）
