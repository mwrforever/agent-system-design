---
name: sandbox-tools-and-safety
description: 沙箱内文件与命令工具的全套实现（3144 行单文件）：bash/ls/glob/grep/read_file/write_file/str_replace 七工具 + 路径安全体系（虚拟路径替换、工具路径校验、bash 命令词法级路径校验）、输出宿主路径掩码、有界输出捕获、CRLF 自适应替换、分页读取与截断标记。当要实现"模型可用的安全文件操作工具"、防路径穿越/命令注入/宿主路径泄漏，或排查工具被诱导读写沙箱外文件时使用。
---

# 沙箱工具与路径安全

## 何时用

- 实现 agent 的 bash / 文件读写工具（安全是第一设计约束）
- 防路径穿越（工具参数、bash 命令内、输出文本三个面）
- 输出脱敏（宿主路径掩码）
- 大文件读取的分页/截断策略

## 设计方案（为什么这么设计）

`sandbox/tools.py`（3144 行）是全部文件类工具的实现体，YAML 用 `use: helix.sandbox.tools:bash_tool` 等字符串引用（见 [[tool-assembly-and-policy]]）。安全设计三面：

### 1. 输入面：路径必须过三道校验

- `replace_virtual_path`（:741）：入参路径先映射到沙箱内合法位置（虚拟路径→真实路径只此一处出口）
- `validate_local_tool_path`（:1006）：read/write/str_replace 的目标路径校验（基目录内、禁符号链接逃逸、只读挂载禁写）
- `validate_local_bash_command_paths`（:1425）：**对 bash 命令做 shell 词法分析**，校验其中出现的绝对路径与 `cd` 目标——`cat /etc/passwd`、`cd /; tar ...` 这类把穿越藏进命令串的姿势在此拦截。字符串黑名单拦不住变体，词法分析才拦得住。

### 2. 输出面：宿主路径必须掩码

`mask_local_paths_in_output`（:849）：任何工具输出（含 bash stdout/stderr）里的宿主真实路径按 `path_patterns` 正则替换回虚拟路径。工具报错信息是最常见的泄漏通道。

### 3. 行为面：无状态、有界、自适应

- bash 每命令独立子进程（无持久 shell，见 [[sandbox-abstraction]]）；`_BoundedPipeCapture` 有界捕获
- `read_file_tool`（:2848）分页 + 截断标记（模型必须能感知"被截断"）
- `str_replace_tool`（:3069）CRLF 自适应匹配（Windows 内容不因行尾差异 miss）
- `ensure_sandbox_initialized`（:1714/1828）：工具首次使用前惰性确保沙箱就绪

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/harness/helix/sandbox/tools.py` | 3144 | 七工具 + 三面安全体系（唯一权威文件） |

配套契约：`sandbox/read_file_contract.py` 在 [[sandbox-abstraction]] 的目录里。

## 反模式与陷阱

- ❌ 用正则黑名单拦 bash 路径 → `ca""t`、`$(echo ...)` 绕过；词法分析。
- ❌ 工具异常直接抛给模型 → 报错串带宿主路径；掩码后再给。
- ❌ read_file 无截断标记 → 模型把半文件当全文件用。
- ❌ str_replace 不处理 CRLF → Windows 产物永远 miss。
- ❌ 校验只做字符串前缀匹配（`startswith(base)`） → `/base-evil` 绕过；解析后逐段比较。

## 落地参考

**自测方向**：`read_file("/mnt/user-data/../../../etc/passwd")` 拒绝；`bash("cat /etc/shadow")` 词法拦截；输出含宿主路径断言已掩码；CRLF 文件 str_replace 成功；超限 read 断言截断标记。

**调试日志串**：路径校验拒绝、掩码命中均有日志。

## 进一步阅读

- [[sandbox-abstraction]]（工具跑在哪）、[[read-before-write]] 语义见 [[safety-and-guardrails]]
- [[workspace-and-projects]]（uploads 的同类原子写模式）
