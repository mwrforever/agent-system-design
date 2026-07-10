# Path Translation & Deferred Tag 完整源码

> 本文件是 `mcp-integration` SKILL.md 的代码附件，收录路径反向翻译全貌、MCP 结果转换全貌、deferred tag 源头定义的**完整真实源码**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。

## 文件清单

| 自定路径 | 内容 |
|---|---|
| `core/helix/mcp/tools.py`（路径翻译部分） | `_local_path_from_uri` / `_local_uri_to_virtual_path` / `_snapshot_workspace_files` / `_changed_workspace_files` / `_prepare_stdio_workspace` / `_result_has_text_content` / `_rewrite_unique_bare_filenames` / `_rewrite_local_paths_in_text` |
| `core/helix/mcp/tools.py`（结果转换） | `_convert_call_tool_result`（MCP `CallToolResult` -> LangChain `content_and_artifact` + 翻译钩子） |
| `core/helix/tools/mcp_metadata.py` | `MCP_TOOL_METADATA_KEY` + `tag_mcp_tool` / `is_mcp_tool`（deferred promote 的 MCP 侧源头） |

---

## 1. 路径反向翻译全貌

```python
# core/helix/mcp/tools.py（路径翻译部分）
from __future__ import annotations

import asyncio
import logging
import re
from collections.abc import Iterable, Mapping
from datetime import timedelta
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

from langchain_core.tools import BaseTool, StructuredTool
from langgraph.config import get_config

from helix.config.extensions_config import ExtensionsConfig
from helix.config.paths import VIRTUAL_PATH_PREFIX, Paths, get_paths
from helix.mcp.client import build_servers_config
from helix.mcp.oauth import build_oauth_tool_interceptor, get_initial_oauth_headers
from helix.mcp.session_pool import get_session_pool
from helix.reflection import resolve_variable
from helix.runtime.user_context import resolve_runtime_user_id
from helix.tools.sync import make_sync_tool_wrapper
from helix.tools.types import Runtime

logger = logging.getLogger(__name__)

# stdio MCP 子进程的 temp 目录子路径。把进程 temp dir 钉在挂载的 user-data 树内，
# 让写 os.tmpdir() / tempfile.gettempdir() 的工具产物落在 sandbox/artifact API 能解析的位置
_MCP_TMP_SUBDIR = ".mcp/tmp"

# 匹配自由文本里嵌入的本地文件引用。有些 server（如 Playwright browser_take_screenshot）
# 把保存的文件仅作为文本/markdown 链接返回，而非 ResourceLink 块。引用可能是绝对路径、
# file:// URI、或相对 server 进程 cwd 的路径（如 temp/page.yml、./shot.png）。每个匹配仅在
# 解析到 thread 的 user-data 树内已存在文件时才改写，所以过度匹配无副作用（原样保留）。
_LOCAL_PATH_IN_TEXT_RE = re.compile(r"(?:file://)?/[^\s'\"<>|*?]+|(?:\.{0,2}/|[\w.-]+/)[^\s'\"<>|*?]+")

# 结尾的标点/markup（非路径组成部分）
_TEXT_PATH_TRAILING_CHARS = ".,;:!?)]}>\"'`"

_FILE_SNAPSHOT = dict[Path, tuple[int, int]]


def _local_path_from_uri(uri: str, *, base_dir: Path | None = None) -> Path | None:
    """URI 指向本地文件 -> 返回绝对 Path；远程 URI / 不可解析 -> None。

    接受裸路径与 file:// URI。远程 URI（http/https/data）返回 None，调用方原样保留。
    相对路径仅在提供 base_dir 时解析。
    """
    if not uri:
        return None
    parsed = urlparse(uri)
    if parsed.scheme == "file":
        raw = unquote(parsed.path)
    elif parsed.scheme == "":
        raw = uri
    else:
        return None
    if not raw:
        return None
    path = Path(raw)
    if not path.is_absolute():
        if base_dir is None:
            return None
        path = base_dir / path
    return path


def _local_uri_to_virtual_path(
    uri: str,
    *,
    thread_id: str,
    user_id: str,
    source_base_dir: Path | None = None,
) -> str | None:
    """把本地文件引用翻译成 /mnt/user-data/... 虚拟路径。

    stdio MCP server 的 cwd/temp 已钉在 thread 的 mounted user-data 树内（见
    _make_session_pool_tool），所以它产的文件本就落在 sandbox/artifact API 能服务的位置--
    唯一缺的是虚拟前缀。本函数做纯确定性 host->virtual 映射：不拷贝、不需要 trusted-root
    列表、不暴露 thread 树外文件。

    返回 None（调用方原样保留）当：URI 远程 / 不可解析 / 指向 thread user-data 树外 / 不是已存在文件。
    相对引用按 source_base_dir（server 的 cwd）解析。
    """
    src = _local_path_from_uri(uri, base_dir=source_base_dir)
    if src is None:
        return None

    try:
        real = src.resolve()
    except OSError:
        return None
    if not real.is_file():
        return None  # 不是已存在文件，不改写（防误伤）

    try:
        user_data_root = get_paths().sandbox_user_data_dir(thread_id, user_id=user_id).resolve()
    except OSError:
        return None

    try:
        relative = real.relative_to(user_data_root)
    except ValueError:
        # 文件在 thread user-data 挂载树外，无法表达为虚拟路径，原样保留
        logger.debug("MCP path rewrite skipped outside user-data tree: %s", real)
        return None

    virtual_path = f"{VIRTUAL_PATH_PREFIX}/{relative.as_posix()}"
    logger.debug("MCP path rewrite: %s -> %s", real, virtual_path)
    return virtual_path


def _snapshot_workspace_files(root: Path) -> _FILE_SNAPSHOT:
    """返回 root 下常规文件的轻量 snapshot（mtime_ns + size 签名）。"""
    snapshot: _FILE_SNAPSHOT = {}
    if not root.exists():
        return snapshot

    try:
        candidates = root.rglob("*")
        for path in candidates:
            try:
                stat = path.stat()
            except OSError:
                continue
            if path.is_file():
                snapshot[path] = (stat.st_mtime_ns, stat.st_size)
    except OSError:
        return snapshot
    return snapshot


def _changed_workspace_files(root: Path, before: _FILE_SNAPSHOT) -> list[Path]:
    """返回 root 下自 before 之后创建或修改的文件。"""
    after = _snapshot_workspace_files(root)
    return [path for path, signature in after.items() if before.get(path) != signature]


def _prepare_stdio_workspace(paths: Paths, *, thread_id: str, user_id: str) -> tuple[Path, Path, _FILE_SNAPSHOT]:
    """为钉扎的 stdio MCP 子进程准备 thread workspace。

    把所有同步文件系统工作（建目录、temp 准备、调前 snapshot）打包到一个 helper，
    让调用方能经 asyncio.to_thread offload 出事件循环。返回 workspace cwd、钉扎的 temp dir、
    调前文件 snapshot。
    """
    paths.ensure_thread_dirs(thread_id, user_id=user_id)
    source_base_dir = paths.sandbox_work_dir(thread_id, user_id=user_id)
    tmp_dir = source_base_dir / _MCP_TMP_SUBDIR
    try:
        tmp_dir.mkdir(parents=True, exist_ok=True)
        tmp_dir.chmod(0o700)
    except OSError:
        logger.warning("Failed to prepare MCP temp dir: %s", tmp_dir, exc_info=True)
    before_files = _snapshot_workspace_files(source_base_dir)
    return source_base_dir, tmp_dir, before_files


def _result_has_text_content(call_tool_result: Any) -> bool:
    """MCP 结果带任何文本内容 -> True。

    调后 snapshot diff 仅喂给自由文本里的裸文件名关联。结果无文本块时无东西可改写，
    调用方可跳过第二次递归遍历。
    """
    from mcp.types import EmbeddedResource, TextContent, TextResourceContents

    content = getattr(call_tool_result, "content", None)
    if not content:
        return False
    for item in content:
        if isinstance(item, TextContent):
            return True
        if isinstance(item, EmbeddedResource) and isinstance(item.resource, TextResourceContents):
            return True
    return False


def _rewrite_unique_bare_filenames(
    text: str,
    *,
    changed_files: Iterable[Path],
    thread_id: str,
    user_id: str,
    source_base_dir: Path | None = None,
) -> str:
    """仅在本次调用产出的文件中唯一匹配时，改写裸文件名。

    `Saved as page-2026.yml` 结构上不是路径。唯一安全解读是把文件名与本次工具调用创建/修改
    的文件关联，仅当 basename 映射到 thread 的 mounted user-data 树内恰好一个文件时才改写。
    """
    candidates: dict[str, list[str]] = {}
    for path in changed_files:
        virtual_path = _local_uri_to_virtual_path(
            str(path),
            thread_id=thread_id,
            user_id=user_id,
            source_base_dir=source_base_dir,
        )
        if virtual_path is None:
            continue
        candidates.setdefault(path.name, []).append(virtual_path)

    unique = {name: paths[0] for name, paths in candidates.items() if len(set(paths)) == 1}
    if not unique:
        if candidates:
            logger.debug("MCP bare filename rewrite skipped: no unique candidate in %s", sorted(candidates))
        else:
            logger.debug("MCP bare filename rewrite skipped: no snapshot candidates")
        return text

    rewritten = text
    for name in sorted(unique, key=len, reverse=True):
        # 不在更长的路径/词内改写。允许结尾句号，但不允许 ".bak" 或另一个路径段。
        pattern = re.compile(rf"(?<![\w./-]){re.escape(name)}(?!(?:[\w/-]|\.[\w]))")
        rewritten_text, count = pattern.subn(unique[name], rewritten)
        if count:
            logger.debug("MCP bare filename rewrite: %s -> %s", name, unique[name])
        rewritten = rewritten_text
    return rewritten


def _rewrite_local_paths_in_text(
    text: str,
    *,
    thread_id: str,
    user_id: str,
    source_base_dir: Path | None = None,
    changed_files: Iterable[Path] | None = None,
) -> str:
    """尽力改写自由文本里的本地文件引用。

    有些 server（如 Playwright browser_take_screenshot）把保存的文件仅作为自由文本返回
    （`Took the screenshot and saved it as temp/page-2026.png`），而非 ResourceLink。自由文本
    不是可靠协议，所以本函数刻意保守：每个候选 token 交给 _local_uri_to_virtual_path，仅当
    它解析到 thread 的 user-data 树内已存在文件时才改写。非真实路径（或指向他处）的 token
    原样保留，所以过度 regex 匹配无副作用。
    """
    translated_by_source: dict[str, str | None] = {}

    def _replace(match: re.Match[str]) -> str:
        token = match.group(0)
        # 路径可能结束一个句子（"saved as temp/a.png."）：剥尾部标点，改写后恢复。
        stripped = token.rstrip(_TEXT_PATH_TRAILING_CHARS)
        trailing = token[len(stripped):]
        if stripped not in translated_by_source:
            translated_by_source[stripped] = _local_uri_to_virtual_path(
                stripped,
                thread_id=thread_id,
                user_id=user_id,
                source_base_dir=source_base_dir,
            )
        rewritten = translated_by_source[stripped]
        if rewritten is None:
            return token
        return f"{rewritten}{trailing}"

    rewritten = _LOCAL_PATH_IN_TEXT_RE.sub(_replace, text)
    if changed_files is None:
        return rewritten
    return _rewrite_unique_bare_filenames(
        rewritten,
        changed_files=changed_files,
        thread_id=thread_id,
        user_id=user_id,
        source_base_dir=source_base_dir,
    )
```

---

## 2. MCP 结果转换全貌（CallToolResult -> LangChain content_and_artifact + 翻译钩子）

```python
# core/helix/mcp/tools.py（_convert_call_tool_result 全貌）
def _convert_call_tool_result(
    call_tool_result: Any,
    *,
    thread_id: str | None = None,
    user_id: str | None = None,
    source_base_dir: Path | None = None,
    changed_files: Iterable[Path] | None = None,
) -> Any:
    """把 MCP CallToolResult 转成 LangChain content_and_artifact 格式。

    实现与 adapter 相同的转换逻辑，不依赖私有的
    langchain_mcp_adapters.tools._convert_call_tool_result 符号。

    提供 thread_id 与 user_id 时，ResourceLink 块或纯文本（如 Playwright MCP 保存的截图）
    引用的本地文件，其引用从宿主路径翻译成 /mnt/user-data/... 虚拟路径，使 sandbox 与
    artifact API 能解析。文件本身不拷贝--stdio server 的 cwd/temp 钉在挂载树内，本就在
    可服务位置。远程 URI 与 thread user-data 树外的文件原样保留。
    """
    from langchain_core.messages import ToolMessage
    from langchain_core.messages.content import create_file_block, create_image_block, create_text_block
    from langchain_core.tools import ToolException
    from mcp.types import EmbeddedResource, ImageContent, ResourceLink, TextContent, TextResourceContents

    # ToolMessage 直接透传（interceptor 短路）
    if isinstance(call_tool_result, ToolMessage):
        return call_tool_result, None

    # LangGraph Command 直接透传（装了 langgraph 时）
    try:
        from langgraph.types import Command

        if isinstance(call_tool_result, Command):
            return call_tool_result, None
    except ImportError:
        # langgraph 可选；不可用时继续标准 MCP 内容转换
        pass

    def _resolve_link_url(uri: str) -> str:
        # ResourceLink：schema 保证是文件引用，无条件翻译
        if thread_id is None or user_id is None:
            return uri
        rewritten = _local_uri_to_virtual_path(uri, thread_id=thread_id, user_id=user_id, source_base_dir=source_base_dir)
        return rewritten if rewritten is not None else uri

    def _resolve_text(text: str) -> str:
        # 有些 server（如 Playwright）把保存的文件仅作为纯文本返回，无 ResourceLink 可挂。
        # 扫描文本里的本地路径并翻译，使产物经 sandbox/artifact API 可读。
        if thread_id is None or user_id is None:
            return text
        return _rewrite_local_paths_in_text(
            text,
            thread_id=thread_id,
            user_id=user_id,
            source_base_dir=source_base_dir,
            changed_files=changed_files,
        )

    # 把 MCP content 块转 LangChain content 块
    lc_content = []
    for item in call_tool_result.content:
        if isinstance(item, TextContent):
            lc_content.append(create_text_block(text=_resolve_text(item.text)))
        elif isinstance(item, ImageContent):
            lc_content.append(create_image_block(base64=item.data, mime_type=item.mimeType))
        elif isinstance(item, ResourceLink):
            mime = item.mimeType or None
            url = _resolve_link_url(str(item.uri))
            if mime and mime.startswith("image/"):
                lc_content.append(create_image_block(url=url, mime_type=mime))
            else:
                lc_content.append(create_file_block(url=url, mime_type=mime))
        elif isinstance(item, EmbeddedResource):
            from mcp.types import BlobResourceContents

            res = item.resource
            if isinstance(res, TextResourceContents):
                lc_content.append(create_text_block(text=_resolve_text(res.text)))
            elif isinstance(res, BlobResourceContents):
                mime = res.mimeType or None
                if mime and mime.startswith("image/"):
                    lc_content.append(create_image_block(base64=res.blob, mime_type=mime))
                else:
                    lc_content.append(create_file_block(base64=res.blob, mime_type=mime))
            else:
                lc_content.append(create_text_block(text=str(res)))
        else:
            lc_content.append(create_text_block(text=str(item)))

    if call_tool_result.isError:
        error_parts = [item["text"] for item in lc_content if isinstance(item, dict) and item.get("type") == "text"]
        raise ToolException("\n".join(error_parts) if error_parts else str(lc_content))

    artifact = None
    if call_tool_result.structuredContent is not None:
        artifact = {"structured_content": call_tool_result.structuredContent}

    return lc_content, artifact
```

---

## 3. deferred promote 的 MCP 侧源头（tag 定义）

```python
# core/helix/tools/mcp_metadata.py
"""Single source of truth for the MCP-tool metadata tag.

一个工具是"MCP 来源"当且仅当它带 ``helix_mcp`` metadata 标记。tag 在工具装载处
（tools.py 的 get_available_tools）写入，由 deferred 工具装配（tool_search.py 的
assemble_deferred_tools）与 agent 构建点（agent.py）读取。把 key、tagger、predicate
放在这里，让魔法字符串只活在一处，读者 import 公开 predicate 而非私有跨模块 helper。

设计为叶子模块：只依赖 BaseTool，任何模块（含工具装载器）都能 import 它而不引入环。
"""

from __future__ import annotations

from langchain.tools import BaseTool

MCP_TOOL_METADATA_KEY = "helix_mcp"


def tag_mcp_tool(tool: BaseTool) -> BaseTool:
    """标记 tool 为 MCP 来源。原地变更并返回（支持链式）。"""
    tool.metadata = {**(tool.metadata or {}), MCP_TOOL_METADATA_KEY: True}
    return tool


def is_mcp_tool(tool: BaseTool) -> bool:
    """tool 带有 tag_mcp_tool 写的 MCP 来源标记时返回 True。"""
    return (getattr(tool, "metadata", None) or {}).get(MCP_TOOL_METADATA_KEY) is True
```

### tag 的写入与消费链路

tag 的写入点（`get_available_tools` 装配时对每个 MCP 工具调 `tag_mcp_tool`）与消费点（`assemble_deferred_tools` 用 `is_mcp_tool` 挑 MCP 工具入 deferred catalog、`DeferredToolFilterMiddleware` 运行时过滤）归 [[tool-assembly-and-policy]]。本文件只提供 tag 的**源头定义**（key + tagger + predicate），是 deferred promote 机制识别 MCP 工具的单一真值。

```
get_available_tools()                          # 装配主体（见 [[tool-assembly-and-policy]]）
  └─ mcp_tools = get_cached_mcp_tools()        # 本 skill 产出（已包装的 MCP BaseTool 列表）
  └─ for t in mcp_tools: tag_mcp_tool(t)       # 写 metadata["helix_mcp"] = True
        ↓
filter_tools_by_skill_allowed_tools(...)        # 白名单收缩
        ↓
assemble_deferred_tools(filtered, enabled)      # deferred 切分（见 [[tool-assembly-and-policy]]）
  └─ deferred = [t for t in filtered if is_mcp_tool(t)]   # 读 metadata["helix_mcp"]
  └─ DeferredToolCatalog(tuple(deferred))
  └─ DeferredToolSetup(tool_search_tool, deferred_names, catalog_hash)
        ↓
DeferredToolFilterMiddleware                    # 运行时过滤（见 [[tool-assembly-and-policy]]）
  └─ 每模型调用：按 state["promoted"] 放行已提升 MCP 工具 schema
  └─ 阻截未提升 MCP 工具的直接调用
```
