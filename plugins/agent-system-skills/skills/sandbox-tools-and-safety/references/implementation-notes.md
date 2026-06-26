# sandbox-tools-and-safety · implementation-notes

Sandbox 之上的工具层把 **VirtualPath**、**写串行化**、**只读 mount**、**Host-Bash 命令路径校验**、**输出反向解析与脱敏** 等一系列安全约束实装成 `bash / ls / read_file / write_file / str_replace / glob / grep` 这些 LLM 可调用的工具。本文记录把这层工具体系搬运到新项目时必须复刻的算法、不变量与配置旋钮。

## 一、组件矩阵

| 组件 | 角色 | 关键关注点 |
|---|---|---|
| `bash` 工具 | 在沙箱里执行 shell 命令 | 本地 Provider 默认禁用；启用后强制 cwd 锁到 workspace，命令里的绝对路径必须是允许集合 |
| `ls` 工具 | 列目录（最多 2 层） | 输入路径走 `validate_local_tool_path(read_only=True)`；输出走 `mask_local_paths_in_output` |
| `read_file` 工具 | 读 UTF-8 文本 | 二进制必须以可执行错误信息提示 LLM 换工具（pandas/openpyxl/view_image） |
| `write_file` 工具 | 写文本，默认覆盖；`append=True` 追加 | 单次非追加调用 ≤ 80 KB（可通过环境变量覆盖）；同路径串行化锁 |
| `str_replace` 工具 | 文件内字符串替换 | 默认要求 `old_str` 在文件中恰好出现一次；同路径锁 |
| `glob / grep` 工具 | 路径模式 / 文件内容搜索 | 强制 ignore 大量构建/缓存目录；`grep` 跳过二进制、超长行（防 ReDoS）、超大文件 |
| `validate_local_tool_path` | VirtualPath 白名单 + 路径穿越拒绝 | 只读类别（skills、ACP workspace）写访问直接拒绝 |
| `replace_virtual_path / replace_virtual_paths_in_command` | VirtualPath → 宿主路径 | 长前缀优先；保留路径结尾的 `/`；按宿主路径分隔风格 |
| `mask_local_paths_in_output` | 宿主路径 → VirtualPath（输出反向脱敏） | 编译模式按 source 集合 LRU 缓存；不会改用户上传/外部工具产物中已存在的路径 |
| `validate_local_bash_command_paths` | 本地 host-bash 路径白名单 | 解析 shell tokens（`shlex.shlex(punctuation_chars=True)`）；`cd/pushd` 单独校验目标 |
| `_is_non_path_literal_fragment` | 非路径文本兜底 | 非 ASCII 段、单 identifier 占位（`{id}`）视为文本；`${VAR}` / brace expansion 不豁免 |
| `get_file_operation_lock` | `(sandbox.id, path)` 维度的写锁 | `WeakValueDictionary` + guard lock；锁失活后自动回收 |
| `_truncate_*_output` 系列 | 输出截断保护 token 预算 | bash 中间截断（首尾各半）；read_file/ls 头部保留；marker 长度按最坏情况计 |
| `ensure_sandbox_initialized(_async)` | 工具入口的 lazy acquire | 把 `sandbox_id` 写回 `runtime.state["sandbox"]`，由中间件做持久化 |

## 二、关键调用时序

### `write_file(path, content, append=False)` 全链路

```text
write_file_tool
  ├─ if not append and len(content.utf8) > _effective_write_file_max_bytes:
  │      return 可执行的错误（建议 str_replace 或分段 append）
  ├─ ensure_sandbox_initialized(runtime)
  ├─ ensure_thread_directories_exist(runtime)   # 本地 Provider 才建目录
  ├─ if is_local_sandbox(runtime):
  │      validate_local_tool_path(path, thread_data)             # 拒绝穿越 / 非允许前缀
  │      path = _resolve_and_validate_user_data_path(path, td)   # 解析回宿主，并验证仍在三大目录里
  ├─ with get_file_operation_lock(sandbox, path):
  │      sandbox.write_file(path, content, append)
  │        ├─ 解析 content 中的 VirtualPath → 宿主路径（content-aware，转 /）
  │        ├─ os.makedirs(dirname, exist_ok=True)
  │        ├─ open(mode='a' if append else 'w', utf-8) → write
  │        └─ self._agent_written_paths.add(resolved)
  └─ return "OK"  /  错误时走 _format_write_file_error（中段截断 + mask）
```

### `bash(command)` 全链路（本地 Provider, allow_host_bash=true）

```text
bash_tool
  ├─ ensure_sandbox_initialized(runtime)
  ├─ if not is_host_bash_allowed(): return 拒绝消息（本地 Provider 默认走这条）
  ├─ ensure_thread_directories_exist(runtime)
  ├─ thread_data = get_thread_data(runtime)
  ├─ validate_local_bash_command_paths(command, thread_data)
  │     ├─ 拒绝 file:// URL
  │     ├─ _validate_local_bash_shell_tokens（拒绝 .. 段、$(cd ...)、危险 cwd 切换、命令名为 / 等）
  │     └─ for match in _ABSOLUTE_PATH_PATTERN.finditer(command):
  │            跳过 URL span / 非路径文本片段 → 否则必须在允许集合里
  ├─ command = replace_virtual_paths_in_command(command, thread_data)
  ├─ command = "cd <workspace> && " + command
  ├─ output = sandbox.execute_command(command)
  ├─ output = mask_local_paths_in_output(output, thread_data)   # 反向脱敏宿主路径
  └─ return _truncate_bash_output(output, max_chars)
```

### `mask_local_paths_in_output` 内部

```text
1. 收集 sources: [(skills_host, skills_virtual), (acp_host, acp_virtual),
                  *user_data 映射按宿主路径长度倒序]
2. _compiled_mask_patterns(sources)（LRU 512）→ tuple[(regex, base, virtual), ...]
3. 对每个 (regex, base, virtual)：替换为 virtual 或 virtual/<相对部分>
```

## 三、数据契约

### 工具签名与必填位置
- 所有沙箱工具的第一个字段都是 `description`（要求 LLM"先解释为什么这么干"）
- 第二个字段才是 `path` / `command`，且 LLM 文档串里强调 "ALWAYS PROVIDE THIS PARAMETER SECOND"
- 出错统一以 `"Error: <kind>: <detail>"` 字符串形式返回，**不要抛出**——抛出会被 ToolNode 转成不可恢复的 ToolMessage 异常

### VirtualPath 命名空间
| 前缀 | 用途 | 写权限 |
|---|---|---|
| `/mnt/user-data/workspace` | 当前线程的可读可写工作区 | 写 |
| `/mnt/user-data/uploads` | 用户上传 | 写 |
| `/mnt/user-data/outputs` | Agent 产物（暴露给用户的下载入口） | 写 |
| `/mnt/skills/...` | 全局 skills（公共 + 自定义） | 只读 |
| `/mnt/acp-workspace` | 外部 ACP agent 的工作区映射 | 只读（lead agent 视角） |
| 自定义 mount | 由配置决定 `read_only` | 视 mount |

### `GrepMatch`
```python
@dataclass(frozen=True)
class GrepMatch:
    path: str         # 已经反向解析回 VirtualPath
    line_number: int  # 1-based
    line: str         # 已截断到 DEFAULT_LINE_SUMMARY_LENGTH（默认 200）
```

### 工具输出截断 marker
- `bash`：`"\n... [middle truncated: N chars skipped] ...\n"`（首尾各半）
- `read_file`：`"\n... [truncated: showing first K of N chars. Use start_line/end_line ...]"`
- `ls`：`"\n... [truncated: showing first K of N chars. Use a more specific path ...]"`
- `write_file` 错误：中间截断 + `"... [write_file error truncated: S chars skipped] ..."`

### 异常分支
| 工具 | 抛出的异常 → 返回字符串映射 |
|---|---|
| `read_file` | FileNotFoundError → `File not found`；UnicodeDecodeError → 提示改用 view_image/pandas/openpyxl；PermissionError → `Permission denied reading file`；IsADirectoryError → `Path is a directory, not a file` |
| `write_file` | PermissionError → `Permission denied writing to file`；IsADirectoryError → `Path is a directory`；OSError → `_format_write_file_error`（中段截断 + mask） |
| `ls` | FileNotFoundError → `Directory not found`；PermissionError → `Permission denied` |
| `glob/grep` | FileNotFoundError → `Directory not found`；NotADirectoryError → `Path is not a directory`；re.error → `Invalid regex pattern` |
| `bash` | SandboxError / PermissionError 都包装成 `Error: <msg>` |

### `ignore` 集合
`search.IGNORE_PATTERNS` 默认覆盖 git、构建产物、IDE、缓存目录、临时文件等 ~50 项。`should_ignore_name(name)` 与 `should_ignore_path(path)` 单次目录遍历执行 O(1) 的 normalized name 查表 + 一次合并 glob 正则匹配。复刻时**必须**预编译"非 glob 名 → 集合 / glob 名 → 合并正则"两条快速路径，否则 `os.walk` 每个 entry 都触发 ~50 次 `fnmatch.fnmatch`。

## 四、不变量

1. **VirtualPath 与宿主路径单向流动**：进工具 → 解析为宿主；离工具 → 反向脱敏。任何路径出现在返回给 LLM 的字符串里都必须是 VirtualPath（除非该路径来自用户上传 / 第三方工具自己生成）。
2. **同路径写串行化**：`with get_file_operation_lock(sandbox, path)` 包裹 `write_file` 与 `str_replace` 整段读改写；锁键是 `(sandbox.id, path)`，不同沙箱同 VirtualPath 不会互相阻塞。
3. **路径穿越早早拒绝**：`_reject_path_traversal` 在 VirtualPath 阶段就拒绝任何 `..` 段；解析后还要再 `_validate_resolved_user_data_path` 一次（解析过程可能引入符号链接逃逸）。
4. **只读 mount 双重检查**：在 `validate_local_tool_path(read_only=False)` 这一层就要按映射的 `read_only` 拒掉；底层 `LocalSandbox.write_file` 再用 `_is_resolved_path_read_only` 兜底（嵌套 mount 时取最具体的）。
5. **`write_file` 80 KB 上限只对非追加生效**：上限来自 LLM streaming chunk-gap timeout 经验值；`append=True` 不受限，长文档必须靠 append-in-chunks 或 `str_replace` 修订。
6. **`read_file` 反向重写仅对 agent 自己写过的文件生效**：用户上传文件 / 外部工具产物，路径不能被静默替换（语义可能改变）；这是 `_agent_written_paths` 集合的唯一目的。
7. **Host-Bash 命令路径校验是 best-effort，不是隔离边界**：注释里反复强调它只是"显式 opt-in 后的兜底"，真正的隔离要靠容器化 Provider。
8. **shell token 解析失败不能升级成安全错误**：`_split_shell_tokens` 在 shlex 抛 `ValueError` 时回退到 `command.split()`，让真实的 shell 自己去报语法错；否则恶意/正常的引号错误会变成"路径校验失败"，难排查。
9. **非路径文本兜底要保守**：非 ASCII / 单 identifier 占位视为文本是 OK 的；brace expansion (`{passwd,shadow}`) 与 `${VAR}` 必须**不**豁免——它们运行期会展开成真实宿主路径。
10. **输出截断 marker 长度按最坏情况计算**：截断逻辑保证"返回字符串总长 ≤ max_chars"，包括 marker；不要先截后拼，要先算 marker 上界再决定 kept。
11. **`description` 必填**：每个 sandbox 工具的第一个字段都是 `description`，并在 docstring 里强制 "ALWAYS PROVIDE THIS PARAMETER FIRST"。原因是审计日志需要"为什么这么干"，而 LLM 在无强制时经常空着；用 `Field(..., description=...)` 强约束。
12. **错误不抛只返回字符串**：所有工具都把 `Error: ...` 作为正常返回值；抛出会被 ToolNode 转成 graph 致命错误，丧失"让模型自己纠错"的机会。

## 五、常见踩坑

- **直接把宿主路径返回给 LLM**：`mask_local_paths_in_output` 必须在每个本地 Provider 工具的返回路径上调一次；漏一处就把宿主目录结构泄露给模型上下文。
- **同时持有 sandbox 写锁与外部锁**：`get_file_operation_lock` 是非可重入的 `threading.Lock`，递归调用同路径写会死锁。`str_replace` 在锁内做"读 → replace → 写"是单进单出。
- **WeakValueDictionary 锁回收过早**：在 `with` 上下文外把锁对象保留下来很容易让 GC 没法回收；只在表达式里用 `with get_file_operation_lock(...)`，别 `lock = get_file_operation_lock(...)` 长期持有。
- **`glob` 不忽略大目录**：必须复用 `should_ignore_name`，否则 `node_modules` 一过就是几十万条目，工具 timeout / token 爆。
- **`grep` 不限文件大小**：`DEFAULT_MAX_FILE_SIZE_BYTES` 默认 1MB，超过就跳过；不限的话扫到一个 10MB 压缩 JSON 就卡死。
- **`grep` 不跳过超长行**：minified JS / 无换行 SQL dump 会触发 ReDoS；默认按 `line_summary_length * 10` 限制。
- **VirtualPath 替换没按长度倒序**：`/mnt/user-data` 比 `/mnt/user-data/workspace` 短，按字典序匹配会让 workspace 永远走不到精细映射。
- **`bash` 没强制 cwd**：相对路径在不同工具调用之间不一致（用户最近一次 `cd` 在新进程里不会保留），必须前缀 `cd <workspace> &&`。
- **`bash` 校验放过了 `eval` / `$(...)` 内的路径**：`_validate_local_bash_shell_tokens` 有专门一行盯 `$(...cd|pushd...)`；新模式（如 `<( ... )` 进程替换）出现时要补。
- **二进制误读**：`read_file` 遇到二进制 raise `UnicodeDecodeError`，并返回**给 LLM**的提示必须是"请改用 view_image / pandas / openpyxl"——直接抛栈给 LLM 它会重复同样的错误。
- **错误信息泄露**：`_sanitize_error` 在本地 Provider 路径里要调 `mask_local_paths_in_output`，否则异常文本会把宿主路径带回去。
- **path traversal 单层判断**：只在 VirtualPath 阶段 reject `..` 是不够的；解析回宿主后还要 `relative_to(allowed_root)` 二次验证，否则符号链接逃逸还是可能命中只读区外的目录。
- **brace expansion 当成文本豁免**：`{passwd,shadow}` 看起来像占位符，实际是 shell 展开成两条路径；只允许"单 identifier"占位文本豁免，多元素 / 空元素一律不豁免。
- **写大文件后立刻 read_file 触发反向重写**：`_agent_written_paths` 只在 `write_file` 路径写入；用 `update_file`（二进制）写的文件不会自动加入集合，read 时不会反向重写，行为不一致，调用方要心里有数。
- **`grep` 跨 symlink 越界**：`find_grep_matches` 显式 `is_symlink() → continue`，复刻时漏掉这一行就会沿 symlink 走出 root（部分 OS 上还会陷入循环）。

## 六、调参旋钮 + 调试入口

### 配置旋钮
- `sandbox.allow_host_bash`：是否给本地 Provider 启用 host-bash
- `sandbox.bash_output_max_chars` / `ls_output_max_chars` / `read_file_output_max_chars`：输出截断阈值（默认 20000 / 20000 / 50000）
- `sandbox.mounts[]`：每条 `{host_path, container_path, read_only}`；保留前缀（`/mnt/user-data`、`/mnt/skills`、`/mnt/acp-workspace`）冲突会被拒绝
- 环境变量 `<FRAMEWORK_PREFIX>_WRITE_FILE_MAX_BYTES`（按你的框架前缀命名）：覆盖 80 KB 单次写上限，0 / 负值关闭
- `tools.<glob|grep>.max_results`：装配级别的搜索结果上限（与函数入参取 min）
- `MCP filesystem allowed_paths`：通过 MCP filesystem server 注册的额外 host 允许路径（仅 host-bash 校验认）

### 运行期旋钮
- 工具入参 `start_line / end_line`（read_file）、`max_results`（glob/grep）、`replace_all`（str_replace）、`append`（write_file）
- `runtime.state["thread_directories_created"]`：幂等标记，避免每次 tool call 都 `os.makedirs`

### 调试入口
1. `is_local_sandbox(runtime)` 返回 False → 工具会跳过 VirtualPath 校验与脱敏；容器化 Provider 已经在容器里挂好 VirtualPath
2. `validate_local_bash_command_paths` 抛出的 `PermissionError`：消息里的 `Unsafe absolute paths in command: ...` 直接给出违例 token，逐项核对
3. `_compiled_mask_patterns.cache_info()`：脱敏正则的 LRU 命中率；非常低意味着 thread_data 的 ordering 不稳定
4. 单元层：构造 `runtime` mock（`state` / `context`）后直接调 `bash_tool.func(runtime, "...", "...")`；写一组用例覆盖 file://、`..`、`$(cd /etc)`、brace expansion、`${HOME}`、Unicode 文本路径
5. 故意把 `_thread_actual_to_virtual_mappings` 的某一项删掉做端到端冒烟：确认有任何"绕过脱敏"的窗口会让 mask 失败时立刻可见
6. 在 `get_file_operation_lock` 加 `acquire/release` 计数日志：调试同路径写争用 / 死锁
7. 单测 `_truncate_*_output` 系列：固定 max_chars 为各种边界（0、marker 长度、total - 1、total）验证总长不溢
8. 把 `_get_skills_container_path._cached`、`_get_skills_host_path._cached`、`_get_acp_workspace_host_path._cached`、`_get_custom_mounts._cached` 在测试 setup 里清空：避免上一次 fixture 的配置渗进当次断言

### 相关 skill
- [[sandbox-abstraction]]
- [[multi-user-isolation]]
- [[safety-and-guardrails]]
- [[tool-assembly-and-policy]]
- [[skill-system-design]]
