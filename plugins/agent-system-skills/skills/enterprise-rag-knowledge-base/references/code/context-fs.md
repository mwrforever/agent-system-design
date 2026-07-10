# 完整源码：ContextFS 文件系统范式（core/helix/rag/storage/context_fs.py）

> 本文件给出 `ContextFS` 的核心方法源码。`ContextFS` 是 RAG 知识库的文件系统抽象层：把目录当节点、`kb://` URI 当路径，提供 `abstract()`/`overview()`/`read()`/`write()`/`find()`/`search()`/`grep()`/`glob()` 一等 API。检索入口 `find()`/`search()` 内部构造 `TypedQuery` 调 `HierarchicalRetriever.retrieve`。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.rag.*`），文件系统类、URI scheme、URI 工具类均已映射到中性名。原代码注释保留以保真。

## 单例初始化与 ContextFS 类定义

```python
# core/helix/rag/storage/context_fs.py
"""
ContextFS: Helix RAG 文件系统抽象层

封装 AGFS 绑定客户端，提供基于 kb:// URI 的文件操作接口。
Responsibilities:
- URI conversion (kb:// <-> /local/)
- L0/L1 reading (.abstract.md, .overview.md)
- Relation management (.relations.json)
- Semantic search (vector retrieval + rerank)
- Vector sync (sync vector store on rm/mv)
"""

import asyncio
import contextvars
import hashlib
import json
import os
import re
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import PurePath
from typing import TYPE_CHECKING, Any, Dict, List, Optional, Union

from helix.rag.core.namespace import canonicalize_uri
from helix.rag.core.namespace import (
    is_accessible as namespace_is_accessible,
)
from helix.rag.core.retrieval_targets import resolve_retrieval_targets
from helix.rag.pyagfs import AsyncAGFSClient
from helix.rag.pyagfs.exceptions import (
    AGFSClientError,
    AGFSDirectoryNotEmptyError,
    AGFSHTTPError,
    AGFSNotSupportedError,
)
from helix.rag.resource.watch_storage import is_watch_task_control_uri
from helix.rag.server.error_mapping import is_not_found_error, map_exception
from helix.rag.server.identity import RequestContext, Role
from helix.rag.storage.expr import PathScope
from helix.rag.storage.internal_names import (
    MULTIWRITE_PATH_LOCK_FILE,
    STORAGE_INTERNAL_ENTRY_NAMES,
)
from helix.rag.telemetry import get_current_telemetry
from helix.rag.utils.time_utils import format_iso8601, get_current_timestamp, parse_iso_datetime
from helix.rag.exceptions import (
    FailedPreconditionError,
    InvalidArgumentError,
    NotFoundError,
    PermissionDeniedError,
)
from helix.rag.session.user_id import UserIdentifier
from helix.rag.utils.logger import get_logger
from helix.rag.utils.uri import KbURI

if TYPE_CHECKING:
    from helix.rag.storage.transaction.lock_handle import LockHandle
    from helix.rag.storage.vector_index_backend import VectorIndexBackend
    from helix.rag.config import RerankConfig, RetrievalConfig

logger = get_logger(__name__)

# Sentinel node_limit for internal callers that MUST enumerate an entire
# directory. ``ls()`` defaults to ``node_limit=1000`` to protect agent-facing
# context from being flooded, but internal system operations (parse merge,
# temp->final sync, summary DAG, vectorization) must see every child or they
# silently drop entries beyond the cap - e.g. a >1000-doc directory ingest only
# materializes its first 1000 subdirectories. Pass this explicitly at those
# call sites.
LS_ALL_NODES = 2**31 - 1


def _ensure_non_empty_search_query(query: str) -> None:
    if not query.strip():
        raise InvalidArgumentError("Search query must not be empty.")


def _get_cpu_count() -> int:
    """Return the number of CPUs available to this process."""
    if hasattr(os, "process_cpu_count"):
        return os.process_cpu_count() or 1
    try:
        return len(os.sched_getaffinity(0))
    except (AttributeError, NotImplementedError):
        return os.cpu_count() or 1


def _get_abstract_worker_count() -> int:
    default = max(4, min(12, min(32, _get_cpu_count() + 4) // 2))
    env_val = os.getenv("HELIX_RAG_FILE_OPS_CONCURRENCY")
    if env_val is not None:
        try:
            return max(1, int(env_val))
        except ValueError:
            pass
    return max(1, default)


_ABSTRACT_WORKER_COUNT = _get_abstract_worker_count()


# ========== Dataclass ==========


@dataclass
class RelationEntry:
    """Relation table entry. 关系表条目，维护在 .relations.json 中。"""

    id: str
    uris: List[str]
    reason: str = ""
    created_at: str = field(default_factory=get_current_timestamp)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "uris": self.uris,
            "reason": self.reason,
            "created_at": self.created_at,
        }

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "RelationEntry":
        return RelationEntry(**data)


# ========== Singleton Pattern ==========

_instance: Optional["ContextFS"] = None


def init_context_fs(
    agfs: Any,
    query_embedder: Optional[Any] = None,
    rerank_config: Optional["RerankConfig"] = None,
    vector_store: Optional["VectorIndexBackend"] = None,
    retrieval_config: Optional["RetrievalConfig"] = None,
    timeout: int = 10,
    enable_recorder: bool = False,
    encryptor: Optional[Any] = None,
) -> "ContextFS":
    """Initialize ContextFS singleton.

    Args:
        agfs: Pre-initialized AGFS client (HTTP or Binding)
        query_embedder: Embedder instance
        rerank_config: Rerank configuration
        retrieval_config: Retrieval ranking configuration
        vector_store: Vector store instance
        enable_recorder: Whether to enable IO recording
        encryptor: FileEncryptor instance for encryption/decryption
    """
    global _instance

    _instance = ContextFS(
        agfs=agfs,
        query_embedder=query_embedder,
        rerank_config=rerank_config,
        vector_store=vector_store,
        retrieval_config=retrieval_config,
        encryptor=encryptor,
    )

    if enable_recorder:
        _enable_context_fs_recorder(_instance)

    return _instance


def get_context_fs() -> "ContextFS":
    """Get ContextFS singleton."""
    if _instance is None:
        raise RuntimeError("ContextFS not initialized. Call init_context_fs() first.")
    return _instance


# ========== ContextFS Main Class ==========


class ContextFS:
    """AGFS-based Helix RAG 文件系统。

    APIs are divided into two categories:
    - AGFS basic commands (direct forwarding): read, ls, write, mkdir, rm, mv, grep, stat
    - ContextFS specific capabilities: abstract, overview, find, search, relations, link, unlink

    Uses Rust binding mode: Use AGFSBindingClient to directly use AGFS implementation
    """

    def __init__(
        self,
        agfs: Any,
        query_embedder: Optional[Any] = None,
        rerank_config: Optional["RerankConfig"] = None,
        vector_store: Optional["VectorIndexBackend"] = None,
        retrieval_config: Optional["RetrievalConfig"] = None,
        timeout: int = 10,
        encryptor: Optional[Any] = None,
    ):
        self.agfs = agfs
        self._async_agfs = AsyncAGFSClient(agfs)
        self.query_embedder = query_embedder
        self.rerank_config = rerank_config
        self.vector_store = vector_store
        self.retrieval_config = retrieval_config
        self._encryptor = encryptor
        self._bound_ctx: contextvars.ContextVar[Optional[RequestContext]] = contextvars.ContextVar(
            "contextfs_bound_ctx", default=None
        )

    @staticmethod
    def _default_ctx() -> RequestContext:
        return RequestContext(user=UserIdentifier.the_default_user(), role=Role.ROOT)

    def _ctx_or_default(self, ctx: Optional[RequestContext]) -> RequestContext:
        if ctx is not None:
            return ctx
        bound = self._bound_ctx.get()
        return bound or self._default_ctx()

    @contextmanager
    def bind_request_context(self, ctx: RequestContext):
        """Temporarily bind ctx for legacy internal call paths without explicit ctx param."""
        token = self._bound_ctx.set(ctx)
        try:
            yield
        finally:
            self._bound_ctx.reset(token)

    @staticmethod
    def _normalize_uri(uri: str) -> str:
        """Normalize short-format URIs to the canonical kb:// form."""
        if uri.startswith("kb://"):
            return uri
        return KbURI.normalize(uri)

    @classmethod
    def _normalized_uri_parts(cls, uri: str) -> tuple[str, List[str]]:
        """Normalize a URI and reject ambiguous or platform-specific path traversal forms."""
        normalized = cls._normalize_uri(uri)
        parts = [p for p in normalized[len("kb://") :].strip("/").split("/") if p]

        for part in parts:
            if part in {".", ".."}:
                raise PermissionDeniedError(
                    f"Unsafe URI traversal segment '{part}' in {normalized}",
                    resource=normalized,
                )
            if "\\" in part:
                raise PermissionDeniedError(
                    f"Unsafe URI path separator '\\\\' in component '{part}' of {normalized}",
                    resource=normalized,
                )
            if len(part) >= 2 and part[1] == ":" and part[0].isalpha():
                raise PermissionDeniedError(
                    f"Unsafe URI drive-prefixed component '{part}' in {normalized}",
                    resource=normalized,
                )

        return normalized, parts
```

## L0/L1 读取：abstract() / overview()

```python
# core/helix/rag/storage/context_fs.py（ContextFS 方法续）

    async def _read_abstract_file(
        self,
        path: str,
        uri: str,
        ctx: Optional[RequestContext] = None,
    ) -> str:
        """Read and decrypt/decode .abstract.md from a known directory path.

        不做 stat 或 isDir 检查——调用方需保证 path 指向目录。
        """
        file_path = f"{path}/.abstract.md"
        try:
            content_bytes = self._handle_agfs_read(await self._async_agfs.read(file_path))
        except Exception as exc:
            if not is_not_found_error(exc):
                mapped = map_exception(exc, resource=uri)
                if mapped is not None:
                    raise mapped from exc
                raise
            return f"# {uri} [Directory abstract is not ready]"

        return self._decode_bytes(content_bytes)

    async def abstract(
        self,
        uri: str,
        ctx: Optional[RequestContext] = None,
    ) -> str:
        """Read directory's L0 summary (.abstract.md).

        如果 caller 指向文件，回退到父目录，使端点对文件/目录 URI 均可用。
        """
        self._ensure_access(uri, ctx)
        path = self._uri_to_path(uri, ctx=ctx)
        try:
            info = await self._async_agfs.stat(path)
        except Exception as exc:
            mapped = map_exception(exc, resource=uri)
            if mapped is not None:
                raise mapped from exc
            raise
        if not info.get("isDir", info.get("is_dir")):
            parent_path = path.rsplit("/", 1)[0] or "/"
            parent_uri = self._path_to_uri(parent_path, ctx=ctx)
            logger.info(
                "content/abstract: %s is a file, falling back to parent directory %s",
                uri,
                parent_uri,
            )
            return await self.abstract(parent_uri, ctx=ctx)
        return await self._read_abstract_file(path, uri, ctx=ctx)

    async def overview(
        self,
        uri: str,
        ctx: Optional[RequestContext] = None,
    ) -> str:
        """Read directory's L1 overview (.overview.md).

        如果 caller 指向文件，回退到父目录。.overview.md 不存在时返回占位文本。
        """
        self._ensure_access(uri, ctx=ctx)
        path = self._uri_to_path(uri, ctx=ctx)
        try:
            info = await self._async_agfs.stat(path)
        except Exception as exc:
            mapped = map_exception(exc, resource=uri)
            if mapped is not None:
                raise mapped from exc
            raise
        if not info.get("isDir", info.get("is_dir")):
            parent_path = path.rsplit("/", 1)[0] or "/"
            parent_uri = self._path_to_uri(parent_path, ctx=ctx)
            logger.info(
                "content/overview: %s is a file, falling back to parent directory %s",
                uri,
                parent_uri,
            )
            return await self.overview(parent_uri, ctx=ctx)
        file_path = f"{path}/.overview.md"
        try:
            content_bytes = self._handle_agfs_read(await self._async_agfs.read(file_path))
        except Exception as exc:
            if not is_not_found_error(exc):
                mapped = map_exception(exc, resource=uri)
                if mapped is not None:
                    raise mapped from exc
                raise
            # Fallback to default if .overview.md doesn't exist
            return f"# {uri}\n\n[Directory overview is not ready]"

        return self._decode_bytes(content_bytes)
```

## 语义检索入口：find() / search()

```python
# core/helix/rag/storage/context_fs.py（ContextFS 方法续）

    async def find(
        self,
        query: str,
        target_uri: Union[str, List[str]] = "",
        limit: int = 10,
        score_threshold: Optional[float] = None,
        filter: Optional[Dict] = None,
        ctx: Optional[RequestContext] = None,
        level: Optional[List[int]] = None,
        peer_id: Optional[str] = None,
    ):
        """Semantic search. 无状态语义检索（不走 IntentAnalyzer）。

        Args:
            query: Search query
            target_uri: Target directory URI(s), supports str or List[str]
            limit: Return count
            score_threshold: Score threshold
            filter: Metadata filter

        Returns:
            FindResult（按 memory/resource/skill 分组）
        """
        _ensure_non_empty_search_query(query)
        telemetry = get_current_telemetry()
        from helix.rag.retrieve.hierarchical_retriever import HierarchicalRetriever
        from helix.rag.retrieve import (
            ContextType,
            FindResult,
            TypedQuery,
        )

        real_ctx = self._ctx_or_default(ctx)
        retrieval_targets = resolve_retrieval_targets(target_uri, real_ctx, peer_id)

        for target_dir in retrieval_targets.target_directories:
            self._ensure_access(target_dir, ctx)

        storage = self._get_vector_store()
        if not storage:
            raise RuntimeError("Vector store not initialized. Call Helix.initialize() first.")

        embedder = self._get_embedder()
        if not embedder:
            raise RuntimeError("Embedder not configured.")

        retriever = HierarchicalRetriever(
            storage=storage,
            embedder=embedder,
            rerank_config=self.rerank_config,
            retrieval_config=self.retrieval_config,
        )

        typed_query = TypedQuery(
            query=query,
            context_type=None,
            intent="",
            target_directories=retrieval_targets.target_directories,
        )

        logger.debug(
            "[ContextFS.find] Calling retriever.retrieve with "
            f"ctx.account_id={real_ctx.account_id}, ctx.user={real_ctx.user}"
        )

        result = await retriever.retrieve(
            typed_query,
            ctx=real_ctx,
            limit=limit,
            score_threshold=score_threshold,
            scope_dsl=filter,
            level=level,
        )

        # Convert QueryResult to FindResult（按 context_type 分组）
        memories, resources, skills = [], [], []
        for ctx in result.matched_contexts:
            if ctx.context_type == ContextType.MEMORY:
                memories.append(ctx)
            elif ctx.context_type == ContextType.RESOURCE:
                resources.append(ctx)
            elif ctx.context_type == ContextType.SKILL:
                skills.append(ctx)

        find_result = FindResult(
            memories=memories,
            resources=resources,
            skills=skills,
        )
        telemetry.set("vector.returned", find_result.total)
        return find_result

    async def search(
        self,
        query: str,
        target_uri: Union[str, List[str]] = "",
        session_info: Optional[Dict] = None,
        limit: int = 10,
        score_threshold: Optional[float] = None,
        filter: Optional[Dict] = None,
        ctx: Optional[RequestContext] = None,
        level: Optional[List[int]] = None,
        peer_id: Optional[str] = None,
    ):
        """Complex search with session context. 带 session 上下文的复杂检索。

        有 session 上下文时走 IntentAnalyzer 拆 query -> 多条 TypedQuery 并发检索；
        无 session 上下文时直接构造单条 TypedQuery。
        """
        _ensure_non_empty_search_query(query)
        telemetry = get_current_telemetry()
        from helix.rag.retrieve.hierarchical_retriever import HierarchicalRetriever
        from helix.rag.retrieve.intent_analyzer import IntentAnalyzer
        from helix.rag.retrieve import (
            ContextType,
            FindResult,
            QueryPlan,
            TypedQuery,
        )

        real_ctx = self._ctx_or_default(ctx)
        retrieval_targets = resolve_retrieval_targets(target_uri, real_ctx, peer_id)
        primary_target_uri = retrieval_targets.first_explicit_directory

        session_summary = (
            str(session_info.get("latest_archive_overview") or "") if session_info else ""
        )
        current_messages = session_info.get("current_messages") if session_info else None

        query_plan: Optional[QueryPlan] = None
        for target_dir in retrieval_targets.target_directories:
            self._ensure_access(target_dir, ctx)

        # When target_uri exists, read its abstract as optional query-planning context.
        target_abstract = ""
        if primary_target_uri:
            try:
                with telemetry.measure("search.target_abstract"):
                    target_abstract = await self.abstract(primary_target_uri, ctx=ctx)
            except Exception:
                target_abstract = ""

        # With session context: intent analysis
        if session_summary or current_messages:
            analyzer = IntentAnalyzer(max_recent_messages=5)
            with telemetry.measure("search.intent_analysis"):
                query_plan = await analyzer.analyze(
                    compression_summary=session_summary or "",
                    messages=current_messages or [],
                    current_message=query,
                    target_abstract=target_abstract,
                )
            typed_queries = query_plan.queries
            for tq in typed_queries:
                tq.target_directories = retrieval_targets.target_directories
        else:
            # No session context: create query directly
            typed_queries = [
                TypedQuery(
                    query=query,
                    context_type=None,
                    intent="",
                    priority=1,
                    target_directories=retrieval_targets.target_directories,
                )
            ]
        telemetry.set("search.typed_queries_count", len(typed_queries))

        # Concurrent execution
        storage = self._get_vector_store()
        embedder = self._get_embedder()
        retriever = HierarchicalRetriever(
            storage=storage,
            embedder=embedder,
            rerank_config=self.rerank_config,
            retrieval_config=self.retrieval_config,
        )

        async def _execute(tq: TypedQuery):
            real_ctx = self._ctx_or_default(ctx)
            logger.debug(
                "[ContextFS.search._execute] Calling retriever.retrieve with "
                f"ctx.account_id={real_ctx.account_id}, ctx.user={real_ctx.user}"
            )
            return await retriever.retrieve(
                tq,
                ctx=real_ctx,
                limit=limit,
                score_threshold=score_threshold,
                scope_dsl=filter,
                level=level,
            )

        query_results = await asyncio.gather(*[_execute(tq) for tq in typed_queries])

        # Aggregate results to FindResult
        memories, resources, skills = [], [], []
        for result in query_results:
            for ctx in result.matched_contexts:
                if ctx.context_type == ContextType.MEMORY:
                    memories.append(ctx)
                elif ctx.context_type == ContextType.RESOURCE:
                    resources.append(ctx)
                elif ctx.context_type == ContextType.SKILL:
                    skills.append(ctx)

        find_result = FindResult(
            memories=memories,
            resources=resources,
            skills=skills,
            query_plan=query_plan,
            query_results=query_results,
        )
        telemetry.set("vector.returned", find_result.total)
        return find_result
```

## 内容检索：grep() / glob()

```python
# core/helix/rag/storage/context_fs.py（ContextFS 方法续）

    async def grep(
        self,
        uri: str,
        pattern: str,
        exclude_uri: Optional[str] = None,
        case_insensitive: bool = False,
        node_limit: Optional[int] = None,
        level_limit: int = 5,
        ctx: Optional[RequestContext] = None,
    ) -> Dict:
        """Content search by pattern or keywords. 正则内容搜索。

        AGFS 层透明地对加密和明文文件 grep（配置加密层时按 account_id 解密）。

        Args:
            uri: kb:// URI
            pattern: Regular expression pattern to search for
            exclude_uri: Optional URI prefix to exclude from search
            case_insensitive: Whether to perform case-insensitive matching
            node_limit: Maximum number of results to return
            level_limit: Maximum depth level to traverse (default: 5)

        Returns:
            Dict with matches, count, match_count, files_scanned
        """
        self._ensure_access(uri, ctx)
        await self.stat(uri, ctx=ctx)

        return await self._grep_with_agfs(
            uri=uri,
            pattern=pattern,
            exclude_uri=exclude_uri,
            case_insensitive=case_insensitive,
            node_limit=node_limit,
            level_limit=level_limit,
            ctx=ctx,
        )

    async def _grep_with_agfs(
        self,
        uri: str,
        pattern: str,
        exclude_uri: Optional[str] = None,
        case_insensitive: bool = False,
        node_limit: Optional[int] = None,
        level_limit: int = 5,
        ctx: Optional[RequestContext] = None,
    ) -> Dict:
        """Grep using agfs native implementation. 优化的非加密文件路径。

        优先把过滤条件下推到 agfs 后端：
        - exclude_uri -> exclude_path
        - level_limit -> level_limit
        """
        path = self._uri_to_path(uri, ctx=ctx)

        excluded_path = None
        if exclude_uri:
            normalized_excluded_uri = self._normalize_uri(exclude_uri).rstrip("/")
            self._ensure_access(normalized_excluded_uri, ctx)
            excluded_path = self._uri_to_path(normalized_excluded_uri, ctx=ctx)

        try:
            result = await self._async_agfs.grep(
                path=path,
                pattern=pattern,
                recursive=True,
                case_insensitive=case_insensitive,
                stream=False,
                node_limit=node_limit,
                exclude_path=excluded_path,
                level_limit=level_limit,
            )
        except (AttributeError, AGFSNotSupportedError, NotImplementedError):
            # Capability missing: let the outer caller fall back to the ContextFS implementation.
            logger.warning("agfs grep unavailable, falling back to ContextFS implementation")
            raise

        matches = result.get("matches", [])
        results = []
        files_scanned_set = set()

        for match in matches:
            match_file = match.get("file", "")
            if not match_file:
                continue

            agfs_file_path = self._resolve_grep_match_agfs_path(path, match_file)
            file_uri = self._path_to_uri(agfs_file_path, ctx=ctx)
            files_scanned_set.add(file_uri)

            results.append(
                {
                    "line": match.get("line", match.get("line_number", 0)),
                    "uri": file_uri,
                    "content": match.get("content", ""),
                }
            )

            if node_limit and len(results) >= node_limit:
                break

        # Prefer backend-provided scanned file count if available; otherwise fall back to
        # counting files that produced at least one match (best-effort).
        backend_files_scanned = result.get("files_scanned")
        if isinstance(backend_files_scanned, int) and backend_files_scanned >= 0:
            files_scanned = backend_files_scanned
        else:
            files_scanned = len(files_scanned_set)

        return {
            "matches": results,
            "count": len(results),
            "match_count": len(results),
            "files_scanned": files_scanned,
        }

    async def glob(
        self,
        pattern: str,
        uri: str = "kb://",
        node_limit: Optional[int] = None,
        ctx: Optional[RequestContext] = None,
    ) -> Dict:
        """File pattern matching, supports **/*.md recursive."""
        entries = await self.tree(uri, node_limit=1000000, level_limit=None, ctx=ctx)
        base_uri = uri.rstrip("/")
        matches = []
        for entry in entries:
            rel_path = entry.get("rel_path", "")
            if PurePath(rel_path).match(pattern):
                matches.append(f"{base_uri}/{rel_path}")
        # Now apply node limit to the filtered matches
        if node_limit is not None and node_limit > 0:
            matches = matches[:node_limit]
        return {"matches": matches, "count": len(matches)}
```

## URI 转换与访问控制

```python
# core/helix/rag/storage/context_fs.py（ContextFS 方法续）

    # Maximum bytes for a single filename component (filesystem limit is typically 255)
    _MAX_FILENAME_BYTES = 255

    @staticmethod
    def _shorten_component(component: str, max_bytes: int = 255) -> str:
        """Shorten a path component if its UTF-8 encoding exceeds max_bytes."""
        if len(component.encode("utf-8")) <= max_bytes:
            return component
        hash_suffix = hashlib.sha256(component.encode("utf-8")).hexdigest()[:8]
        # Trim to fit within max_bytes after adding hash suffix
        prefix = component
        target = max_bytes - len(f"_{hash_suffix}".encode("utf-8"))
        while len(prefix.encode("utf-8")) > target and prefix:
            prefix = prefix[:-1]
        return f"{prefix}_{hash_suffix}"

    def _uri_to_path(self, uri: str, ctx: Optional[RequestContext] = None) -> str:
        """Map virtual URI to account-isolated AGFS path.

        纯前缀替换：kb://{remainder} -> /local/{account_id}/{remainder}。
        无隐式 space 注入——URI 必须显式包含 space 段。
        """
        real_ctx = self._ctx_or_default(ctx)
        account_id = real_ctx.account_id
        canonical_uri = canonicalize_uri(uri, real_ctx)
        _, parts = self._normalized_uri_parts(canonical_uri)
        if not parts:
            return f"/local/{account_id}"

        safe_parts = [self._shorten_component(p, self._MAX_FILENAME_BYTES) for p in parts]
        return f"/local/{account_id}/{'/'.join(safe_parts)}"

    _ROOT_PATH = "/local"

    def _path_to_uri(self, path: str, ctx: Optional[RequestContext] = None) -> str:
        """/local/{account}/... -> kb://...

        纯前缀替换：剥离 /local/{account_id}/ 并前缀 kb://。无隐式 space 剥离。
        """
        if path.startswith("kb://"):
            return path
        elif path.startswith("/local/"):
            inner = path[7:].strip("/")
            if not inner:
                return "kb://"
            real_ctx = self._ctx_or_default(ctx)
            parts = [p for p in inner.split("/") if p]
            if parts and parts[0] == real_ctx.account_id:
                parts = parts[1:]
            if not parts:
                return "kb://"
            return f"kb://{'/'.join(parts)}"
        elif path.startswith("/"):
            return f"kb:/{path}"
        else:
            return f"kb://{path}"

    def _is_accessible(self, uri: str, ctx: RequestContext) -> bool:
        """Check whether a URI is visible/accessible under current request context.

        ACL 规则：
        - ROOT 角色：全可见
        - resources scope：全可见
        - temp scope：仅当前 user space 可见（+ legacy temp URI 兼容）
        - upload scope：仅 ROOT
        - _system scope：不可见
        - 其他：走 namespace ACL
        """
        normalized_uri, parts = self._normalized_uri_parts(uri)
        if ctx.role == Role.ROOT:
            return True
        if not parts:
            return True
        if is_watch_task_control_uri(normalized_uri):
            return False

        scope = parts[0]
        if scope == "resources":
            return True
        if scope == "temp":
            if len(parts) == 1:
                return True
            if parts[1] == ctx.user.user_space_name():
                return True
            return self._is_legacy_temp_uri_parts(parts)
        if scope == "upload":
            return ctx.role == Role.ROOT
        if scope == "_system":
            return False
        return namespace_is_accessible(normalized_uri, ctx)

    def _ensure_access(self, uri: str, ctx: Optional[RequestContext]) -> None:
        """访问前校验 ACL，不通过抛 PermissionDeniedError。"""
        real_ctx = self._ctx_or_default(ctx)
        normalized_uri, _ = self._normalized_uri_parts(uri)
        if not self._is_accessible(normalized_uri, real_ctx):
            raise PermissionDeniedError(f"Access denied for {uri}", resource=normalized_uri)

    def _decode_bytes(self, data: bytes) -> str:
        """Robustly decode bytes to string. 多编码兜底（utf-8/gbk/latin-1）。"""
        if not data:
            return ""
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            try:
                # Try common encoding for Windows/legacy files in China
                return data.decode("gbk")
            except UnicodeDecodeError:
                try:
                    return data.decode("latin-1")
                except UnicodeDecodeError:
                    return data.decode("utf-8", errors="replace")
```

## 基础文件读写：read() / write()

```python
# core/helix/rag/storage/context_fs.py（ContextFS 方法续）

    async def read(
        self,
        uri: str,
        offset: int = 0,
        size: int = -1,
        ctx: Optional[RequestContext] = None,
    ) -> bytes:
        """Read file. 读取文件字节（加密层在 AGFS 内透明解密）。"""
        self._ensure_access(uri, ctx)
        path = self._uri_to_path(uri, ctx=ctx)

        # Decryption + offset/size slicing now happen inside the agfs encryption layer
        # (when configured); the plaintext stack reads bytes directly. Either way, pass the
        # offset/size through and let the Rust layer return the requested slice.
        result = await self._async_agfs.read(path, offset, size)
        if isinstance(result, bytes):
            raw = result
        elif result is not None and hasattr(result, "content"):
            raw = result.content
        else:
            raw = b""

        return raw

    async def write(
        self,
        uri: str,
        data: Union[bytes, str],
        ctx: Optional[RequestContext] = None,
    ) -> str:
        """Write file. 写文件（加密层在 AGFS 内按 account_id 透明加密）。"""
        self._ensure_mutable_access(uri, ctx)
        path = self._uri_to_path(uri, ctx=ctx)
        if isinstance(data, str):
            data = data.encode("utf-8")

        # Encryption (when configured) happens inside the agfs layer keyed by account_id.
        return await self._async_agfs.write(path, data)

    async def write_context(
        self,
        uri: str,
        content: Union[str, bytes] = "",
        abstract: str = "",
        overview: str = "",
        content_filename: str = "content.md",
        is_leaf: bool = False,
        ctx: Optional[RequestContext] = None,
    ) -> None:
        """Write context to AGFS (L0/L1/L2). 写入完整上下文（content + abstract + overview）。"""

        self._ensure_access(uri, ctx)
        path = self._uri_to_path(uri, ctx=ctx)

        try:
            await self._ensure_parent_dirs(path, ctx=ctx)
            try:
                await self._async_agfs.mkdir(path)
            except Exception as e:
                if "exist" not in str(e).lower():
                    raise

            if content:
                content_uri = f"{uri}/{content_filename}"
                await self.write_file(content_uri, content, ctx=ctx)

            if abstract:
                abstract_uri = f"{uri}/.abstract.md"
                await self.write_file(abstract_uri, abstract, ctx=ctx)

            if overview:
                overview_uri = f"{uri}/.overview.md"
                await self.write_file(overview_uri, overview, ctx=ctx)

        except Exception as e:
            logger.error(f"[ContextFS] Failed to write {uri}: {e}")
            raise IOError(f"Failed to write {uri}: {e}")

    def _get_vector_store(self) -> Optional["VectorIndexBackend"]:
        """Get vector store instance."""
        return self.vector_store

    def _get_embedder(self) -> Any:
        """Get embedder instance."""
        return self.query_embedder
```

> **ContextFS 设计要点**：`kb://` URI 是用户面路径，`/local/{account_id}/...` 是物理路径，`_uri_to_path`/`_path_to_uri` 做纯前缀替换实现 account 隔离。`find()` 是无状态检索入口（单 TypedQuery），`search()` 是带 session 的复杂入口（IntentAnalyzer 拆 query 后 `asyncio.gather` 并发检索）。所有检索最终委托给 `HierarchicalRetriever.retrieve`。`abstract()`/`overview()` 读 L0/L1 摘要文件，文件 URI 自动回退父目录。`grep()` 把过滤条件下推 AGFS 后端，`glob()` 在 tree 基础上做 `PurePath.match`。
