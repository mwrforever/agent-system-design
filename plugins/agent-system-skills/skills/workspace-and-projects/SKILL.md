---
name: workspace-and-projects
description: 线程工作区与项目资料体系：上传安全（文件名规范化/占用去重/O_NOFOLLOW 防符号链接原子写入/staging 残留清理/沙箱权限位）、工作区变更追踪（快照扫描 sha256/mtime/文本采样 → unified diff → 事件下发前端）、项目上下文与文档架（staging→原子落位/sha256 寻址/自动转 Markdown 单飞转换/摘要生成队列/回收站保留期清扫）、blob 存储抽象（LocalFs 后端）、工件归档与断点下载路由。当要实现安全文件上传、工作区 diff 汇报、项目文档管理时使用。
---

# 工作区、上传与项目

## 何时用

- 用户上传文件给 agent（安全写入/去重/清理）
- "agent 这轮改了哪些文件"的追踪与展示
- 项目资料库（文档入库/检索/摘要/回收站）
- 产物（artifact）的存储、打包、断点下载

## 设计方案（为什么这么设计）

### 1. 上传：校验 + 原子 + 无符号链接

`uploads/manager.py`（766 行）三件套：
- `normalize_filename` + `claim_unique_filename`：规范化与占用名去重
- `open_upload_file_no_symlink`：POSIX `O_NOFOLLOW|O_CREAT[|O_EXCL]` + fstat 校验常规文件且 `st_nlink==1`；Windows 双 lstat+fstat 缩小 TOCTOU 窗口；`exclusive=True` 原子占名
- 上传先落 `.upload-*.part` staging，校验后原子替换；`cleanup_stale_upload_staging_files` 按 inode 共享判定并发 part 清残留（崩溃不自锁）
- `apply_upload_sandbox_permits`：给沙箱补权限位（挂载只读问题的解）
- 伴生登记 `companions.py`：转换产物（如 pdf→md）与源文件关联

### 2. 工作区变更：快照 diff，不是文件监听

`workspace_changes/`（scanner 397 + diff 221 + recorder 239）：run 前后扫描线程工作区根（大小/mtime/sha256/文本采样，跳过敏感路径与符号链接）→ `compare_snapshots` 产出变更清单 + unified diff → 以 `workspace_changes` 事件下发（契约见 [[observability-tracing]]）。**快照对比而非 inotify**：无平台依赖、天然覆盖跨进程写入、可补扫。文本采样原子发布（`_publish_text_atomically`）供前端无锁读。

### 3. 项目：上下文注入 + 文档架 + 摘要 + 回收站

`projects/`：
- `context.py`：项目上下文解析并渲染成块注入会话首条消息（项目 = 会话的资料前缀）
- `documents.py`（643）：文档上传 staging → 原子落位 → **sha256 寻址**（同内容唯一份）→ 非 Markdown 自动转换（`utils/file_conversion.py` 单飞防并发重复转换）
- `summaries.py`：SummaryGenerator 排队用 LLM 生成文档摘要（异步，不阻塞上传）
- `trash.py`：软删除 + 保留期清扫 + 恢复/彻底清除

### 4. blob 存储与工件路由

`storage/contract.py::BlobStore`（kind 校验、错误层级）+ `manager.py` 后端扫描 + LocalFs 实现——大对象走 blob 抽象，DB 只存引用。工件 API：`artifacts.py`（GET 断点 Range + PUT SHA-256 校验原子替换）、`artifact_archive.py` 打包、uploads/projects/trash 路由族。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/uploads/manager.py` + `companions.py` | 766+116 | 上传安全 |
| `references/code/workspace_changes/{scanner,diff,recorder,api,types}.py` | 397/221/239/80/117 | 变更追踪 |
| `references/code/projects/{documents,context,summaries,trash,tools}.py` | 643/332/369/336/209 | 项目资料 |
| `references/code/storage/{contract,manager}.py` + `backends/local_fs/local_fs_store.py` | 198/223/260 | blob 抽象 |
| `references/code/utils/{atomic_write,file_io,file_conversion,host_paths}.py` | 46/109/239/60 | 原子写/文件线程池/转换 |
| `references/code/app/gateway/routers/{uploads,artifacts,projects,project_documents,project_thread_files,trash}.py` + `artifact_archive.py` | 510/624/214/505/160/244+270 | HTTP 面 |
| `references/code/config/{projects,blob_storage,tool_artifact,agent_storage}_config.py` | 158/120/38/38 | 配置 |

## 反模式与陷阱

- ❌ 上传直接写目标名 → 半文件可见；part staging + 原子替换。
- ❌ 符号链接不防 → 逃出上传目录写任意文件；O_NOFOLLOW + nlink 校验。
- ❌ 文件监听做变更追踪 → 平台差异 + 跨进程漏事件；快照 diff。
- ❌ 文档按文件名寻址 → 同内容多份；sha256 寻址。
- ❌ 转换无单飞 → 同文档并发转 N 次；单飞锁。
- ❌ 删除即物理清 → 误删无救；软删除 + 保留期。

## 落地参考

**调参旋钮**：`uploads`（50MiB/文件、100MiB/线程总量）、`projects`（shelf/trash 保留期/摘要）、`blob_storage`、`tool_artifacts`。

**自测方向**：路径穿越名被规范化/拒绝；并发同 part 清理不误删；run 后 diff 事件与真实文件变更一致；同内容文档仅一份 blob；断点续传 Range 正确；回收站到期清扫。

## 进一步阅读

- [[multi-user-isolation]]（上传目录按线程/用户分桶）、[[sandbox-tools-and-safety]]（沙箱侧读写同一批文件）
- [[frontend-app-design]]（前端 artifacts 渲染与上传校验）
