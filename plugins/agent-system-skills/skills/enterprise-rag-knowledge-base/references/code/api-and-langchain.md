# 完整源码：SearchService + REST API + LangChain 集成（core/helix/rag/）

> 本文件给出 RAG 检索的服务层、REST API、LangChain 集成与原生 bot 工具的完整源码。`SearchService` 是服务层入口，`/api/v1/search/{find,search,grep,glob}` 是 REST 路由，`HelixRagRetriever` 是 LangChain `BaseRetriever`，`create_rag_tools` 是 StructuredTool 工厂，`KbSearchTool` 等是原生 Tool 基座。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.rag.*`），LangChain retriever 类、工具工厂函数、工具名前缀、客户端类、URI scheme、bot 包名均已映射到中性名。原代码注释保留以保真。

## §1 SearchService 服务层（core/helix/rag/service/search_service.py）

```python
# core/helix/rag/service/search_service.py
"""
Search Service for Helix RAG.

Provides semantic search operations: search, find.
"""

from typing import TYPE_CHECKING, Any, Dict, List, Optional, Union

from helix.rag.core.uri_validation import validate_optional_kb_uris
from helix.rag.server.identity import RequestContext
from helix.rag.storage.context_fs import ContextFS
from helix.rag.exceptions import InvalidArgumentError, NotInitializedError
from helix.rag.utils import get_logger

if TYPE_CHECKING:
    from helix.rag.session import Session

logger = get_logger(__name__)


def _ensure_non_empty_query(query: str) -> None:
    if not query.strip():
        raise InvalidArgumentError("Search query must not be empty.")


class SearchService:
    """Semantic search service. 语义检索服务层。

    find() 无状态语义检索（单 TypedQuery，不走 IntentAnalyzer）；
    search() 带 session 上下文的复杂检索（走 IntentAnalyzer 拆 query）。
    两者都委托给 ContextFS.find/search -> HierarchicalRetriever.retrieve。
    """

    def __init__(self, context_fs: Optional[ContextFS] = None):
        self._context_fs = context_fs

    def set_context_fs(self, context_fs: ContextFS) -> None:
        """Set ContextFS instance (for deferred initialization)."""
        self._context_fs = context_fs

    def _ensure_initialized(self) -> ContextFS:
        """Ensure ContextFS is initialized."""
        if not self._context_fs:
            raise NotInitializedError("ContextFS")
        return self._context_fs

    async def search(
        self,
        query: str,
        ctx: RequestContext,
        target_uri: Union[str, List[str]] = "",
        peer_id: Optional[str] = None,
        session: Optional["Session"] = None,
        limit: int = 10,
        score_threshold: Optional[float] = None,
        filter: Optional[Dict] = None,
        level: Optional[List[int]] = None,
    ) -> Any:
        """Complex search with session context. 带 session 上下文的复杂检索。

        Args:
            query: Query string
            target_uri: Target directory URI(s), supports str or List[str]
            session: Session object for context
            limit: Max results
            score_threshold: Score threshold
            filter: Metadata filters
            level: Filter by level (0=abstract, 1=overview, 2=file)

        Returns:
            FindResult
        """
        _ensure_non_empty_query(query)
        target_uri = validate_optional_kb_uris(target_uri, field_name="target_uri")
        context_fs = self._ensure_initialized()

        session_info = None
        if session:
            session_info = await session.get_context_for_search(query)

        result = await context_fs.search(
            query=query,
            ctx=ctx,
            target_uri=target_uri,
            peer_id=peer_id,
            session_info=session_info,
            limit=limit,
            score_threshold=score_threshold,
            filter=filter,
            level=level,
        )
        return result

    async def find(
        self,
        query: str,
        ctx: RequestContext,
        target_uri: Union[str, List[str]] = "",
        peer_id: Optional[str] = None,
        limit: int = 10,
        score_threshold: Optional[float] = None,
        filter: Optional[Dict] = None,
        level: Optional[List[int]] = None,
    ) -> Any:
        """Semantic search without session context. 无状态语义检索。

        Args:
            query: Query string
            target_uri: Target directory URI(s), supports str or List[str]
            limit: Max results
            score_threshold: Score threshold
            filter: Metadata filters
            level: Filter by level (0=abstract, 1=overview, 2=file)

        Returns:
            FindResult
        """
        _ensure_non_empty_query(query)
        target_uri = validate_optional_kb_uris(target_uri, field_name="target_uri")
        context_fs = self._ensure_initialized()
        result = await context_fs.find(
            query=query,
            ctx=ctx,
            target_uri=target_uri,
            peer_id=peer_id,
            limit=limit,
            score_threshold=score_threshold,
            filter=filter,
            level=level,
        )
        return result
```

## §2 REST API 路由（core/helix/rag/server/routers/search.py）

```python
# core/helix/rag/server/routers/search.py
"""Search endpoints for Helix RAG HTTP Server."""

import math
from typing import Any, Dict, List, Literal, Optional, Union

from fastapi import APIRouter, Depends
from pydantic import BaseModel, model_validator

from helix.rag.core.path_variables import resolve_path_variables
from helix.rag.core.peer_id import normalize_peer_id
from helix.rag.pyagfs.exceptions import AGFSClientError, AGFSNotFoundError
from helix.rag.server.auth import get_request_context
from helix.rag.server.dependencies import get_service
from helix.rag.server.error_mapping import map_exception
from helix.rag.server.identity import RequestContext
from helix.rag.server.models import Response
from helix.rag.server.telemetry import run_operation
from helix.rag.telemetry import TelemetryRequest
from helix.rag.utils.search_filters import (
    SearchContextTypeInput,
    _resolve_levels,
    merge_search_filter,
)
from helix.rag.exceptions import InvalidArgumentError, NotFoundError


def _sanitize_floats(obj: Any) -> Any:
    """Recursively replace inf/nan with 0.0 to ensure JSON compliance.

    向量检索可能返回 inf/nan 分数，直接 json.dumps 会抛 ValueError。
    递归遍历 dict/list 把 inf/nan 替成 0.0 保证 JSON 合规。
    """
    if isinstance(obj, float):
        if math.isinf(obj) or math.isnan(obj):
            return 0.0
        return obj
    if isinstance(obj, dict):
        return {k: _sanitize_floats(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_sanitize_floats(v) for v in obj]
    return obj


router = APIRouter(prefix="/api/v1/search", tags=["search"])
TimeField = Literal["updated_at", "created_at"]


def _resolve_search_limit(limit: int, node_limit: Optional[int]) -> int:
    return node_limit if node_limit is not None else limit


def _resolve_search_filter(
    request_filter: Optional[Dict[str, Any]],
    context_type: Optional[SearchContextTypeInput],
    since: Optional[str],
    until: Optional[str],
    time_field: Optional[TimeField],
) -> Optional[Dict[str, Any]]:
    try:
        return merge_search_filter(
            request_filter,
            context_type=context_type,
            since=since,
            until=until,
            time_field=time_field,
        )
    except ValueError as exc:
        raise InvalidArgumentError(str(exc)) from exc


def _resolve_uri_or_uris(uri: Union[str, List[str]]) -> Union[str, List[str]]:
    """Resolve path variables in a single URI or list of URIs."""
    if isinstance(uri, list):
        return [resolve_path_variables(u) for u in uri]
    return resolve_path_variables(uri)


class FindRequest(BaseModel):
    """Request model for find."""

    query: str
    target_uri: Union[str, List[str]] = ""
    context_type: Optional[Union[str, List[str]]] = None
    peer_id: Optional[str] = None
    limit: int = 10
    node_limit: Optional[int] = None
    score_threshold: Optional[float] = None
    filter: Optional[Dict[str, Any]] = None
    include_provenance: bool = False
    since: Optional[str] = None
    until: Optional[str] = None
    time_field: Optional[TimeField] = None
    level: Optional[Union[int, str, List[int]]] = None
    telemetry: TelemetryRequest = False

    @model_validator(mode="after")
    def normalize_request_peer_id(self) -> "FindRequest":
        self.peer_id = normalize_peer_id(self.peer_id)
        return self


class SearchRequest(BaseModel):
    """Request model for search with session."""

    query: str
    target_uri: Union[str, List[str]] = ""
    context_type: Optional[Union[str, List[str]]] = None
    peer_id: Optional[str] = None
    session_id: Optional[str] = None
    limit: int = 10
    node_limit: Optional[int] = None
    score_threshold: Optional[float] = None
    filter: Optional[Dict[str, Any]] = None
    include_provenance: bool = False

    since: Optional[str] = None
    until: Optional[str] = None
    time_field: Optional[TimeField] = None
    level: Optional[Union[int, str, List[int]]] = None
    telemetry: TelemetryRequest = False

    @model_validator(mode="after")
    def normalize_request_peer_id(self) -> "SearchRequest":
        self.peer_id = normalize_peer_id(self.peer_id)
        return self


class GrepRequest(BaseModel):
    """Request model for grep."""

    uri: str
    exclude_uri: Optional[str] = None
    pattern: str
    case_insensitive: bool = False
    node_limit: Optional[int] = None
    level_limit: int = 5


class GlobRequest(BaseModel):
    """Request model for glob."""

    pattern: str
    uri: str = "kb://"
    node_limit: Optional[int] = None


@router.post("/find")
async def find(
    request: FindRequest,
    _ctx: RequestContext = Depends(get_request_context),
):
    """Semantic search without session context."""
    service = get_service()
    actual_limit = _resolve_search_limit(request.limit, request.node_limit)
    effective_filter = _resolve_search_filter(
        request.filter,
        request.context_type,
        request.since,
        request.until,
        request.time_field,
    )
    resolved_target_uri = _resolve_uri_or_uris(request.target_uri)
    execution = await run_operation(
        operation="search.find",
        telemetry=request.telemetry,
        fn=lambda: service.search.find(
            query=request.query,
            ctx=_ctx,
            target_uri=resolved_target_uri,
            peer_id=request.peer_id,
            limit=actual_limit,
            score_threshold=request.score_threshold,
            filter=effective_filter,
            level=_resolve_levels(request.level) or None,
        ),
    )
    result = execution.result
    if hasattr(result, "to_dict"):
        result = result.to_dict(include_provenance=request.include_provenance)
    result = _sanitize_floats(result)
    return Response(
        status="ok",
        result=result,
        telemetry=execution.telemetry,
    ).model_dump(exclude_none=True)


@router.post("/search")
async def search(
    request: SearchRequest,
    _ctx: RequestContext = Depends(get_request_context),
):
    """Semantic search with optional session context."""
    service = get_service()
    actual_limit = _resolve_search_limit(request.limit, request.node_limit)
    effective_filter = _resolve_search_filter(
        request.filter,
        request.context_type,
        request.since,
        request.until,
        request.time_field,
    )
    resolved_target_uri = _resolve_uri_or_uris(request.target_uri)

    async def _search():
        session = None
        if request.session_id:
            session = service.sessions.session(_ctx, request.session_id)
            await session.load()
        return await service.search.search(
            query=request.query,
            ctx=_ctx,
            target_uri=resolved_target_uri,
            peer_id=request.peer_id,
            session=session,
            limit=actual_limit,
            score_threshold=request.score_threshold,
            filter=effective_filter,
            level=_resolve_levels(request.level) or None,
        )

    execution = await run_operation(
        operation="search.search",
        telemetry=request.telemetry,
        fn=_search,
    )
    result = execution.result
    if hasattr(result, "to_dict"):
        result = result.to_dict(include_provenance=request.include_provenance)
    result = _sanitize_floats(result)
    return Response(
        status="ok",
        result=result,
        telemetry=execution.telemetry,
    ).model_dump(exclude_none=True)


@router.post("/grep")
async def grep(
    request: GrepRequest,
    _ctx: RequestContext = Depends(get_request_context),
):
    """Content search with pattern."""
    service = get_service()
    resolved_uri = resolve_path_variables(request.uri)
    resolved_exclude_uri = None
    if request.exclude_uri:
        resolved_exclude_uri = resolve_path_variables(request.exclude_uri)
    try:
        result = await service.fs.grep(
            resolved_uri,
            request.pattern,
            ctx=_ctx,
            exclude_uri=resolved_exclude_uri,
            case_insensitive=request.case_insensitive,
            node_limit=request.node_limit,
            level_limit=request.level_limit,
        )
    except AGFSNotFoundError:
        raise NotFoundError(resolved_uri, "file")
    except AGFSClientError as e:
        mapped = map_exception(e, resource=resolved_uri, resource_type="file")
        if mapped is not None:
            raise mapped from e
        raise
    except Exception as exc:
        mapped = map_exception(exc, resource=resolved_uri, resource_type="file")
        if mapped is not None:
            raise mapped from exc
        raise
    return Response(status="ok", result=result)


@router.post("/glob")
async def glob(
    request: GlobRequest,
    _ctx: RequestContext = Depends(get_request_context),
):
    """File pattern matching."""
    service = get_service()
    resolved_uri = resolve_path_variables(request.uri)
    try:
        result = await service.fs.glob(
            request.pattern, ctx=_ctx, uri=resolved_uri, node_limit=request.node_limit
        )
    except AGFSNotFoundError:
        raise NotFoundError(resolved_uri or request.pattern, "file")
    except AGFSClientError as e:
        mapped = map_exception(e, resource=resolved_uri or request.pattern, resource_type="file")
        if mapped is not None:
            raise mapped from e
        raise
    except Exception as exc:
        mapped = map_exception(exc, resource=request.uri, resource_type="file")
        if mapped is not None:
            raise mapped from exc
        raise
    return Response(status="ok", result=result)
```

## §3 LangChain Retriever（core/helix/rag/integrations/langchain/retrievers.py）

```python
# core/helix/rag/integrations/langchain/retrievers.py
"""LangChain retriever backed by Helix RAG retrieval."""

from __future__ import annotations

import asyncio
from typing import Any, Literal

from pydantic import ConfigDict, Field, PrivateAttr

try:
    from langchain_core.documents import Document
    from langchain_core.retrievers import BaseRetriever
except ImportError as exc:  # pragma: no cover - exercised by optional import path
    from helix.rag.integrations.langchain.client import missing_dependency

    raise missing_dependency("langchain", "langchain-core") from exc

from helix.rag.integrations.langchain.client import (
    HelixRagConnection,
    call_rag,
    ensure_client,
    item_value,
    iter_result_items,
    stringify,
)


class HelixRagRetriever(BaseRetriever):
    """Retrieve LangChain ``Document`` objects from Helix RAG contexts.

    LangChain BaseRetriever 适配：把 find/search 结果转成 Document。
    content_mode 控制返回内容深度：abstract(L0)/overview(L1)/read(全文)/auto(按 level)。
    """

    model_config = ConfigDict(arbitrary_types_allowed=True)

    client: Any = None
    url: str | None = None
    api_key: str | None = None
    account: str | None = None
    user: str | None = None
    user_id: str | None = None
    path: str | None = None
    timeout: float = 60.0
    extra_headers: dict[str, str] | None = None
    auto_initialize: bool = True

    target_uri: str | list[str] = ""
    search_mode: Literal["find", "search"] = "find"
    session_id: str | None = None
    peer_id: str | None = None
    limit: int = 10
    score_threshold: float | None = None
    filter: dict[str, Any] | None = None
    context_types: tuple[str, ...] = ("memory", "resource", "skill")
    content_mode: Literal["auto", "abstract", "overview", "read"] = "auto"
    max_content_chars: int = 12_000
    metadata_prefix: str = "helix_rag"
    tags: list[str] | None = Field(default=None, exclude=True)

    _client_cache: Any = PrivateAttr(default=None)

    def _get_client(self) -> Any:
        if self._client_cache is None:
            self._client_cache = ensure_client(
                HelixRagConnection(
                    client=self.client,
                    url=self.url,
                    api_key=self.api_key,
                    account=self.account,
                    user=self.user,
                    user_id=self.user_id,
                    path=self.path,
                    timeout=self.timeout,
                    extra_headers=self.extra_headers,
                    auto_initialize=self.auto_initialize,
                )
            )
        return self._client_cache

    def _get_relevant_documents(self, query: str, *, run_manager: Any) -> list[Document]:
        """同步检索入口：调 find/search，转结果为 Document。

        metadata_prefix="helix_rag" 使所有 RAG 元数据带统一前缀，
        避免与 LangChain 其他来源的 metadata 冲突。
        """
        client = self._get_client()
        method = "search" if self.search_mode == "search" else "find"
        result = call_rag(
            client,
            method,
            query=query,
            target_uri=self.target_uri,
            session_id=self.session_id,
            peer_id=self.peer_id,
            limit=self.limit,
            score_threshold=self.score_threshold,
            filter=self.filter,
        )
        documents: list[Document] = []
        for context_type, item in iter_result_items(result, self.context_types):
            uri = item_value(item, "uri", "")
            content = self._content_for_item(client, item)
            metadata = {
                "source": uri,
                f"{self.metadata_prefix}_uri": uri,
                f"{self.metadata_prefix}_context_type": context_type,
                f"{self.metadata_prefix}_level": item_value(item, "level"),
                f"{self.metadata_prefix}_category": item_value(item, "category"),
                f"{self.metadata_prefix}_score": item_value(item, "score"),
                f"{self.metadata_prefix}_match_reason": item_value(item, "match_reason"),
                f"{self.metadata_prefix}_abstract": item_value(item, "abstract"),
                f"{self.metadata_prefix}_overview": item_value(item, "overview"),
            }
            documents.append(Document(page_content=content, metadata=metadata))
        return documents

    async def _aget_relevant_documents(self, query: str, *, run_manager: Any) -> list[Document]:
        return await asyncio.to_thread(
            lambda: self._get_relevant_documents(query, run_manager=run_manager)
        )

    def _content_for_item(self, client: Any, item: Any) -> str:
        """按 content_mode 决定返回内容深度。

        - abstract: L0 摘要（最短）
        - overview: L1 概览（中等）
        - read:     全文（调 read API）
        - auto:     L2 文件用 read 全文，L0/L1 用 overview/abstract
        """
        uri = item_value(item, "uri", "")
        abstract = item_value(item, "abstract", "")
        overview = item_value(item, "overview", "")
        level = item_value(item, "level")

        if self.content_mode == "abstract":
            return stringify(abstract or overview, max_chars=self.max_content_chars)
        if self.content_mode == "overview":
            return stringify(overview or abstract, max_chars=self.max_content_chars)
        if self.content_mode == "read":
            return self._read_or_fallback(client, uri, overview or abstract)
        if level == 2 and uri:
            return self._read_or_fallback(client, uri, overview or abstract)
        return stringify(overview or abstract, max_chars=self.max_content_chars)

    def _read_or_fallback(self, client: Any, uri: str, fallback: Any) -> str:
        """读全文，失败回退到 overview/abstract。"""
        if uri:
            try:
                content = call_rag(client, "read", uri=uri)
                return stringify(content, max_chars=self.max_content_chars)
            except Exception:
                pass
        return stringify(fallback, max_chars=self.max_content_chars)
```

## §4 LangChain Tool 工厂（core/helix/rag/integrations/langchain/tools.py）

```python
# core/helix/rag/integrations/langchain/tools.py
"""LangChain tool factory for Helix RAG primitives."""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Annotated, Any, Iterable, Literal
from urllib.parse import urlparse
from urllib.request import url2pathname

from pydantic import BeforeValidator, Field

try:
    from langchain_core.tools import StructuredTool
except ImportError as exc:  # pragma: no cover - exercised by optional import path
    from helix.rag.integrations.langchain.client import missing_dependency

    raise missing_dependency("langchain", "langchain-core") from exc

from helix.rag.integrations.langchain.client import (
    HelixRagConnection,
    call_rag,
    compact_json,
    ensure_client,
    item_value,
    iter_result_items,
    stringify,
)

logger = logging.getLogger(__name__)


def _normalize_read_mode_input(value: Any) -> str:
    return str(value or "read").lower().strip()


KbReadMode = Literal["abstract", "overview", "read"]
KbReadModeInput = Annotated[
    KbReadMode,
    BeforeValidator(_normalize_read_mode_input),
]


def create_rag_tools(
    *,
    client: Any = None,
    url: str | None = None,
    api_key: str | None = None,
    account: str | None = None,
    user: str | None = None,
    user_id: str | None = None,
    path: str | None = None,
    timeout: float = 60.0,
    extra_headers: dict[str, str] | None = None,
    auto_initialize: bool = True,
    profile: str = "agent",
    peer_id: str | None = None,
    tool_names: Iterable[str] | None = None,
    allow_forget: bool = False,
) -> list[StructuredTool]:
    """Create LangChain tools exposing Helix RAG's common agent primitives.

    工具名统一用 ``kb_*`` 前缀，暴露 find/search/browse/read/grep/store/
    add_resource/add_skill/health/forget 等操作。按 profile 选子集：
    - retrieval: 只读检索工具 + health
    - agent:     retrieval + store/add_resource/add_skill/health
    - admin:     agent + forget
    """

    cached_client: Any = None

    def get_client() -> Any:
        nonlocal cached_client
        if cached_client is None:
            cached_client = ensure_client(
                HelixRagConnection(
                    client=client,
                    url=url,
                    api_key=api_key,
                    account=account,
                    user=user,
                    user_id=user_id,
                    path=path,
                    timeout=timeout,
                    extra_headers=extra_headers,
                    auto_initialize=auto_initialize,
                )
            )
        return cached_client

    def kb_find(
        query: Annotated[str, Field(description="Natural-language query to match semantically.")],
        target_uri: Annotated[
            str,
            Field(description="Optional kb:// URI scope to search within."),
        ] = "",
        limit: Annotated[int, Field(description="Maximum number of matches to return.")] = 8,
        min_score: Annotated[
            float | None,
            Field(description="Optional backend relevance threshold."),
        ] = None,
    ) -> str:
        """Run stateless semantic retrieval over Helix RAG targets."""

        result = call_rag(
            get_client(),
            "find",
            query=query,
            target_uri=target_uri,
            peer_id=peer_id,
            limit=limit,
            score_threshold=min_score,
        )
        return _format_retrieval_result(result)

    def kb_search(
        query: Annotated[str, Field(description="Natural-language query to match semantically.")],
        target_uri: Annotated[
            str,
            Field(description="Optional kb:// URI scope to search within."),
        ] = "",
        session_id: Annotated[
            str | None,
            Field(description="Optional session id for session-aware retrieval."),
        ] = None,
        limit: Annotated[int, Field(description="Maximum number of matches to return.")] = 8,
        min_score: Annotated[
            float | None,
            Field(description="Optional backend relevance threshold."),
        ] = None,
    ) -> str:
        """Run session-aware semantic retrieval over Helix RAG targets."""

        result = call_rag(
            get_client(),
            "search",
            query=query,
            target_uri=target_uri,
            session_id=session_id,
            peer_id=peer_id,
            limit=limit,
            score_threshold=min_score,
        )
        return _format_retrieval_result(result)

    def kb_browse(
        uri: Annotated[
            str,
            Field(description="kb:// namespace or directory URI to list."),
        ] = "kb://",
        recursive: Annotated[
            bool,
            Field(description="Whether to include nested descendants in the listing."),
        ] = False,
        pattern: Annotated[
            str | None,
            Field(description="Optional glob pattern for discovering matching kb:// URIs."),
        ] = None,
    ) -> str:
        """List child entries under a kb:// namespace or directory URI.

        Use this to inspect structure and discover file/document URIs. When
        pattern is set, the tool returns glob matches instead of a direct
        directory listing.
        """

        active_client = get_client()
        if pattern:
            result = call_rag(active_client, "glob", pattern=pattern, uri=uri)
        else:
            result = call_rag(active_client, "ls", uri=uri, recursive=recursive)
        return stringify(result, max_chars=12_000)

    def kb_read(
        uris: Annotated[
            str | list[str],
            Field(description="One or more file/document kb:// URIs to read."),
        ],
        max_chars: Annotated[
            int,
            Field(description="Maximum characters to include per URI result."),
        ] = 12_000,
        content_mode: Annotated[
            KbReadModeInput,
            Field(
                description="Content depth: abstract is shortest, overview is medium, read is full."
            ),
        ] = "read",
    ) -> str:
        """Read file/document kb:// URIs.

        Directory URIs are not readable; call kb_browse on directories to
        list children, then call kb_read on returned file/document URIs.
        """

        active_client = get_client()
        uri_list = [uris] if isinstance(uris, str) else uris
        mode = str(content_mode or "read").lower().strip()
        payload = []
        for uri in uri_list:
            try:
                content = call_rag(active_client, mode, uri=uri)
            except Exception as exc:
                if not _is_directory_read_error(exc):
                    raise
                payload.append(
                    {
                        "uri": uri,
                        "content_mode": mode,
                        "error": "directory_uri_not_readable",
                        "message": (
                            "This URI is a directory. Use kb_browse on this URI to list "
                            "children, then call kb_read on file/document URIs."
                        ),
                    }
                )
            else:
                payload.append(
                    {
                        "uri": uri,
                        "content_mode": mode,
                        "content": stringify(content, max_chars=max_chars),
                    }
                )
        return stringify(payload, max_chars=max_chars * max(1, len(uri_list)))

    def kb_grep(
        uri: Annotated[
            str,
            Field(description="File/document kb:// URI whose content should be searched."),
        ],
        pattern: Annotated[
            str,
            Field(description="Grep-style text or regex pattern to search for."),
        ],
        case_insensitive: Annotated[
            bool,
            Field(description="Whether to match pattern without case sensitivity."),
        ] = False,
        node_limit: Annotated[
            int,
            Field(description="Maximum number of matching content nodes to return."),
        ] = 20,
    ) -> str:
        """Search kb:// file content with a grep-style pattern."""

        result = call_rag(
            get_client(),
            "grep",
            uri=uri,
            pattern=pattern,
            case_insensitive=case_insensitive,
            node_limit=node_limit,
        )
        return stringify(result, max_chars=12_000)

    def kb_health() -> str:
        """Check Helix RAG health/status for diagnostics."""

        active_client = get_client()
        if hasattr(active_client, "get_status"):
            status = call_rag(active_client, "get_status")
            return stringify(_format_rag_health(status), max_chars=8_000)
        if hasattr(active_client, "is_healthy"):
            return compact_json(
                _format_rag_health({"healthy": call_rag(active_client, "is_healthy")})
            )
        return compact_json(_format_rag_health({"healthy": True}))

    def kb_forget(
        uri: Annotated[
            str,
            Field(description="kb:// URI to remove."),
        ],
        recursive: Annotated[
            bool,
            Field(description="Whether to remove descendants recursively."),
        ] = False,
    ) -> str:
        """Remove a URI from Helix RAG. Only expose this to trusted agents."""

        call_rag(get_client(), "rm", uri=uri, recursive=recursive)
        return compact_json({"removed": uri, "recursive": recursive})

    all_tools: dict[str, StructuredTool] = {
        "kb_find": StructuredTool.from_function(kb_find),
        "kb_search": StructuredTool.from_function(kb_search),
        "kb_browse": StructuredTool.from_function(kb_browse),
        "kb_read": StructuredTool.from_function(kb_read),
        "kb_grep": StructuredTool.from_function(kb_grep),
        "kb_health": StructuredTool.from_function(kb_health),
        "kb_forget": StructuredTool.from_function(kb_forget),
        # 以下工具实现见完整源码（kb_store/kb_add_resource/kb_add_skill/
        # kb_archive_search/kb_archive_expand），此处省略以聚焦检索工具
    }

    if tool_names is None:
        selected = _profile_tool_names(profile, allow_forget=allow_forget)
    else:
        selected = list(tool_names)
    return [all_tools[name] for name in selected if name in all_tools]


def _profile_tool_names(profile: str, *, allow_forget: bool) -> list[str]:
    """按 profile 选工具子集。retrieval 只读；agent 加写工具；admin 加 forget。"""
    retrieval = [
        "kb_find",
        "kb_search",
        "kb_browse",
        "kb_read",
        "kb_grep",
        "kb_archive_search",
        "kb_archive_expand",
    ]
    if profile == "retrieval":
        names = retrieval + ["kb_health"]
    elif profile == "admin":
        names = retrieval + [
            "kb_store",
            "kb_add_resource",
            "kb_add_skill",
            "kb_health",
            "kb_forget",
        ]
    else:
        names = retrieval + [
            "kb_store",
            "kb_add_resource",
            "kb_add_skill",
            "kb_health",
        ]
    if allow_forget and "kb_forget" not in names:
        names.append("kb_forget")
    return names


def _is_directory_read_error(exc: Exception) -> bool:
    """检测目录读取错误（URI 指向目录而非文件）。"""
    details = getattr(exc, "details", {}) or {}
    return (
        getattr(exc, "code", None) == "INVALID_ARGUMENT"
        and details.get("expected") == "file"
        and details.get("actual") == "directory"
    )


def _format_rag_health(status: Any) -> dict[str, Any]:
    """格式化 RAG 健康状态。"""
    state = _infer_health_state(status)
    return {
        "backend": "Helix RAG",
        "healthy": state == "healthy",
        "state": state,
        "note": "Helix RAG is the context memory backend; 向量库 is internal vector/index storage.",
        "summary": _safe_status_summary(status),
    }


def _infer_health_state(status: Any) -> str:
    if isinstance(status, dict):
        for key in ("healthy", "ok"):
            value = status.get(key)
            if isinstance(value, bool):
                return "healthy" if value else "unhealthy"
        state = str(status.get("status") or status.get("state") or "").lower()
        if state in {"ok", "healthy", "ready", "running"}:
            return "healthy"
        if state in {"error", "failed", "unhealthy"}:
            return "unhealthy"
        if state in {"degraded", "initializing", "starting", "pending"}:
            return state
    return "unknown"


def _safe_status_summary(status: Any) -> dict[str, Any]:
    if not isinstance(status, dict):
        return {"type": type(status).__name__}

    summary: dict[str, Any] = {}
    for key in ("healthy", "ok", "status", "state", "state_detail"):
        if key in status:
            value = _safe_status_value(status[key])
            if value is not None:
                summary[key] = value

    components = status.get("components") or status.get("services")
    if isinstance(components, dict | list | tuple):
        summary["component_count"] = len(components)

    return summary or {"type": "dict"}


def _safe_status_value(value: Any) -> Any:
    if value is None or isinstance(value, bool | int | float):
        return value
    if isinstance(value, str):
        lowered = value.lower()
        if "://" in lowered or "@" in lowered:
            return None
        return value if len(value) <= 64 else f"{value[:61]}..."
    return None


def _format_retrieval_result(result: Any) -> str:
    """格式化检索结果为可读文本（带 URI + score + abstract）。"""
    lines: list[str] = []
    for index, (context_type, item) in enumerate(iter_result_items(result), start=1):
        uri = item_value(item, "uri", "")
        score = item_value(item, "score")
        abstract = item_value(item, "abstract") or item_value(item, "overview") or ""
        score_text = "" if score is None else f" score={score}"
        lines.append(f"[{index}] {context_type}{score_text} {uri}\n{abstract}".strip())
    if not lines:
        return "No Helix RAG contexts matched."
    return "\n\n".join(lines)
```

## §5 原生 Bot 工具（core/helix/rag/integrations/bot/tools/file_tools.py）

> 以下源自 `bot` 集成层（代号 `helix.bot`），把 RAG 检索能力以原生 `Tool` 基座暴露给 agent。`KbFileTool` 是基类（客户端缓存 + URI 归一化），`KbSearchTool` 是核心检索工具（`min_score` 过滤 + memory/resource/skill 分组 JSON），`KbMultiReadTool` 用 `asyncio.Semaphore(10)` 并发读全文。

```python
# core/helix/rag/integrations/bot/tools/file_tools.py
"""Helix RAG 文件系统工具：read, write, list, search resources."""

import asyncio
import itertools
import json
import time
from abc import ABC
from pathlib import Path
from typing import Any, Optional

import httpx
from loguru import logger

from helix.bot.agent.tools.base import Tool, ToolContext
from helix.bot.rag_mount.rag_server import RagClient


class KbFileTool(Tool, ABC):
    """RAG 文件工具基类：客户端缓存 + URI 归一化 + memory URI 推导。"""

    _memory_commit_counter = itertools.count(1)

    def __init__(self):
        super().__init__()
        self._clients = {}

    @staticmethod
    def _has_request_connection(tool_context: ToolContext) -> bool:
        return bool(getattr(tool_context, "rag_connection", None))

    async def _get_client(self, tool_context: ToolContext):
        """获取 RagClient：有请求级连接则每次新建，否则按 workspace 缓存。"""
        if self._has_request_connection(tool_context):
            return await RagClient.create(
                tool_context.workspace_id,
                connection=tool_context.rag_connection,
            )
        cache_key = str(tool_context.workspace_id or "__default__")
        client = self._clients.get(cache_key)
        if client is None:
            client = await RagClient.create(tool_context.workspace_id)
            self._clients[cache_key] = client
        return client

    async def _release_client(self, tool_context: ToolContext, client: RagClient | None) -> None:
        if client is not None and self._has_request_connection(tool_context):
            await client.close()

    @staticmethod
    def _normalize_uri(uri: str | None) -> str:
        normalized = (uri or "").strip()
        if normalized == "kb://":
            return normalized
        return normalized.rstrip("/")

    @staticmethod
    def _dedupe_strings(values: list[str | None]) -> list[str]:
        deduped: list[str] = []
        seen: set[str] = set()
        for value in values:
            if not value:
                continue
            value = str(value).strip()
            if not value or value in seen:
                continue
            seen.add(value)
            deduped.append(value)
        return deduped

    def _is_default_memory_uri(self, client: RagClient, uri: str | None) -> bool:
        normalized = self._normalize_uri(uri)
        if normalized in {"", "kb://user/memories"}:
            return True
        try:
            return normalized == self._normalize_uri(client._memory_target_uri(None))
        except Exception:
            return False

    def _is_default_root_uri(self, uri: str | None) -> bool:
        return self._normalize_uri(uri) in {"", "kb://", "kb://user"}


class KbSearchTool(KbFileTool):
    """Tool to search RAG resources. 核心语义检索工具。

    min_score 过滤 + memory/resource/skill 分组 JSON 输出。
    支持 peer memory fanout（多用户记忆检索）。
    """

    @property
    def name(self) -> str:
        return "kb_search"

    @property
    def description(self) -> str:
        return (
            "Using query to search for resources (knowledge, code, files, workflow, etc.) in Helix RAG. "
            "Result: Only URIs and summaries are included here. To view the full content, use kb_multi_read tool. "
            "This operation performs semantic retrieval, not full character matching. "
            "Avoid duplicate calls with the same intent in the same turn, but do search again for a new user question or a follow-up that asks for a different remembered fact. "
            "For questions about the user's memory, profile, preferences, or personal facts, use this tool before concluding no relevant record exists."
        )

    @property
    def parameters(self) -> dict[str, Any]:
        return {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "The search query"},
                "target_uri": {
                    "type": "string",
                    "description": "Optional target URI to limit search scope, if is None, then search the entire range.(e.g., kb://resources/)",
                },
                "min_score": {
                    "type": "number",
                    "description": "Minimum relevance score threshold",
                    "default": 0.35,
                },
            },
            "required": ["query"],
        }

    @staticmethod
    def _extract_search_items(results: Any) -> list[dict[str, Any]]:
        """从检索结果提取统一 item 列表，兼容 dict / 对象 / list 三种形状。"""
        items: list[dict[str, Any]] = []
        group_map = {
            "memories": "memory",
            "resources": "resource",
            "skills": "skill",
        }

        if isinstance(results, dict):
            for key, item_type in group_map.items():
                group = results.get(key, [])
                if not isinstance(group, list):
                    continue
                for item in group:
                    if isinstance(item, dict):
                        items.append({**item, "type": item.get("type", item_type)})
            return items

        if (
            hasattr(results, "memories")
            or hasattr(results, "resources")
            or hasattr(results, "skills")
        ):
            for key, item_type in group_map.items():
                for item in getattr(results, key, []) or []:
                    items.append(
                        {
                            "type": item_type,
                            "uri": getattr(item, "uri", ""),
                            "abstract": getattr(item, "abstract", ""),
                            "is_leaf": getattr(item, "is_leaf", False),
                            "score": getattr(item, "score", 0.0),
                        }
                    )
            return items

        if isinstance(results, list):
            for item in results:
                if isinstance(item, dict):
                    raw_type = str(item.get("type") or item.get("context_type") or "").lower()
                    item_type = "resource"
                    if "memory" in raw_type:
                        item_type = "memory"
                    elif "skill" in raw_type:
                        item_type = "skill"
                    items.append({**item, "type": item_type})
                else:
                    raw_type = str(getattr(item, "context_type", "")).lower()
                    item_type = "resource"
                    if "memory" in raw_type:
                        item_type = "memory"
                    elif "skill" in raw_type:
                        item_type = "skill"
                    items.append(
                        {
                            "type": item_type,
                            "uri": getattr(item, "uri", ""),
                            "abstract": getattr(item, "abstract", ""),
                            "is_leaf": getattr(item, "is_leaf", False),
                            "score": getattr(item, "score", 0.0),
                        }
                    )

        return items

    @staticmethod
    def _to_float(value: Any) -> float:
        try:
            return float(value)
        except (TypeError, ValueError):
            return 0.0

    def _filter_search_items(
        self, results: Any, min_score: float
    ) -> dict[str, list[dict[str, Any]]]:
        """按 min_score 过滤并按 memory/resource/skill 分组。"""
        grouped: dict[str, list[dict[str, Any]]] = {
            "memory": [],
            "resource": [],
            "skill": [],
        }
        for item in self._extract_search_items(results):
            score = self._to_float(item.get("score", 0.0))
            if score < min_score:
                continue
            item_type = str(item.get("type", "resource")).lower()
            if item_type not in grouped:
                item_type = "resource"
            grouped[item_type].append(
                {
                    "uri": str(item.get("uri", "") or ""),
                    "abstract": str(item.get("abstract", "") or ""),
                    "is_leaf": bool(item.get("is_leaf", False)),
                    "score": score,
                }
            )
        return grouped

    @staticmethod
    def _build_group_json(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
        group_items: list[dict[str, Any]] = []
        for index, item in enumerate(items, 1):
            group_items.append(
                {
                    "index": index,
                    "uri": item["uri"],
                    "abstract": item["abstract"],
                    "is_leaf": item["is_leaf"],
                    "score": round(item["score"], 6),
                }
            )
        return group_items

    def _format_search_items_json(
        self, grouped_items: dict[str, list[dict[str, Any]]], min_score: float
    ) -> str:
        memories = self._build_group_json(grouped_items.get("memory", []))
        resources = self._build_group_json(grouped_items.get("resource", []))
        skills = self._build_group_json(grouped_items.get("skill", []))
        payload = {
            "count": len(memories) + len(resources) + len(skills),
            "memories": memories,
            "resources": resources,
            "skills": skills,
        }
        return json.dumps(payload, ensure_ascii=False, indent=2)

    async def execute(
        self,
        tool_context: "ToolContext",
        query: str,
        target_uri: Optional[str] = "",
        min_score: float = 0.35,
        **kwargs: Any,
    ) -> str:
        """执行语义检索：支持 peer memory fanout，min_score 过滤，分组 JSON 输出。"""
        client = None
        try:
            client = await self._get_client(tool_context)
            memory_owner_user_ids = getattr(tool_context, "memory_owner_user_ids", None)
            legacy_memory_user_ids = getattr(tool_context, "memory_user_ids", None)

            grouped_items = {
                "memory": [],
                "resource": [],
                "skill": [],
            }

            if (
                not target_uri
                and client.should_sender_fanout()
                and (memory_owner_user_ids or legacy_memory_user_ids)
            ):
                # peer memory fanout：对每个 user_id 检索其 memory + skill
                user_ids = memory_owner_user_ids or legacy_memory_user_ids
                search_requests = [{"target_uri": "kb://resources/", "peer_id": None}]
                for user_id in self._dedupe_strings(list(user_ids or [])):
                    memory_uri = client._memory_target_uri(user_id)
                    skill_uri = (
                        f"{memory_uri.rstrip('/')[: -len('/memories')]}/skills/"
                        if memory_uri.rstrip("/").endswith("/memories")
                        else "kb://user/skills/"
                    )
                    search_requests.extend(
                        [
                            {"target_uri": memory_uri, "peer_id": None},
                            {"target_uri": skill_uri, "peer_id": None},
                        ]
                    )
            else:
                peer_ids = self._memory_peer_ids(tool_context)
                if not target_uri:
                    search_requests = (
                        [{"target_uri": "", "peer_id": peer_ids[0]}]
                        if peer_ids
                        else [{"target_uri": "", "peer_id": None}]
                    )
                    peer_memory_uris = self._peer_memory_uris(
                        client, tool_context, peer_ids=peer_ids[1:]
                    )
                    if peer_memory_uris:
                        search_requests.extend(
                            {"target_uri": peer_uri, "peer_id": None}
                            for peer_uri in peer_memory_uris
                        )
                    else:
                        search_requests.extend(
                            {"target_uri": "kb://user/memories/", "peer_id": peer_id}
                            for peer_id in peer_ids[1:]
                        )
                elif self._is_default_memory_uri(client, target_uri) and peer_ids:
                    memory_uris = self._dedupe_strings(
                        [
                            "kb://user/memories/",
                            *self._peer_memory_uris(client, tool_context, peer_ids=peer_ids),
                        ]
                    )
                    search_requests = [
                        {"target_uri": memory_uri, "peer_id": None}
                        for memory_uri in memory_uris
                    ]
                else:
                    search_requests = [{"target_uri": target_uri, "peer_id": None}]

            for request in search_requests:
                search_kwargs = {
                    "target_uri": request["target_uri"],
                    "limit": 10,
                }
                if request.get("peer_id") is not None:
                    search_kwargs["peer_id"] = request.get("peer_id")
                results = await client.search(query, **search_kwargs)
                filtered_items = self._filter_search_items(results, min_score=min_score)
                for item_type, items in filtered_items.items():
                    grouped_items[item_type].extend(items)

            total = sum(len(items) for items in grouped_items.values())
            if total == 0:
                return f"No results found for query: {query}"

            return self._format_search_items_json(grouped_items, min_score=min_score)
        except Exception as e:
            return f"Error searching Helix RAG: {str(e)}"
        finally:
            await self._release_client(tool_context, client)


class KbMultiReadTool(KbFileTool):
    """Tool to read content from multiple RAG resources concurrently.

    用 asyncio.Semaphore(10) 并发读取多个 URI 全文，无截断。
    """

    @property
    def name(self) -> str:
        return "kb_multi_read"

    @property
    def description(self) -> str:
        return "Read full content from multiple Helix RAG resources concurrently. Returns complete content for all URIs with no truncation."

    @property
    def parameters(self) -> dict[str, Any]:
        return {
            "type": "object",
            "properties": {
                "uris": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": 'List of kb:// file URIs to read from (e.g., ["kb://resources/path/123.md", "kb://resources/path/456.md"])',
                },
            },
            "required": ["uris"],
        }

    async def execute(
        self,
        tool_context: ToolContext,
        uris: list[str],
        **kwargs: Any,
    ) -> str:
        level = "read"  # 默认获取完整内容
        client = None
        try:
            if not uris:
                return "Error: No URIs provided."

            client = await self._get_client(tool_context)
            max_concurrent = 10
            semaphore = asyncio.Semaphore(max_concurrent)

            async def read_single_uri(uri: str) -> dict:
                async with semaphore:
                    try:
                        content = await client.read_content(uri, level=level)
                        return {
                            "uri": uri,
                            "content": content,
                            "success": True,
                        }
                    except Exception as e:
                        logger.warning(f"Error reading from {uri}: {e}")
                        return {
                            "uri": uri,
                            "content": f"Error reading from Helix RAG: {str(e)}",
                            "success": False,
                        }

            # 并发读取所有URI
            read_tasks = [read_single_uri(uri) for uri in uris]
            results = await asyncio.gather(*read_tasks)

            # 构建结果
            result_lines = [f"Multi-read results for {len(uris)} resources (level: {level}):"]

            for result in results:
                uri = result["uri"]
                content = result["content"]
                success = result["success"]

                result_lines.append(f"\n--- START OF {uri} ---")
                if success:
                    result_lines.append(content)
                else:
                    result_lines.append(f"ERROR: {content}")
                result_lines.append(f"--- END OF {uri} ---")

            return "\n".join(result_lines)

        except Exception as e:
            logger.exception(f"Error in KbMultiReadTool: {e}")
            return f"Error multi-reading Helix RAG resources: {str(e)}"
        finally:
            await self._release_client(tool_context, client)


class KbGrepTool(KbFileTool):
    """Tool to search RAG resources using a regex pattern."""

    @property
    def name(self) -> str:
        return "kb_grep"

    @property
    def description(self) -> str:
        return (
            "Search RAG resources using a regex pattern (like grep)."
            "Result: Only URIs and summaries are included here. To view the full content, use kb_multi_read tool."
            "Avoid duplicate calls with the same intent in the same turn."
        )

    @property
    def parameters(self) -> dict[str, Any]:
        return {
            "type": "object",
            "properties": {
                "uri": {
                    "type": "string",
                    "description": "Optional kb:// URI to search within. Defaults to all visible roots plus current peer memory.",
                    "default": "kb://",
                },
                "pattern": {
                    "type": "string",
                    "description": "Regex pattern to search for",
                },
                "case_insensitive": {
                    "type": "boolean",
                    "description": "Case-insensitive search",
                    "default": False,
                },
            },
            "required": ["pattern"],
        }

    async def execute(
        self,
        tool_context: "ToolContext",
        pattern: str,
        uri: str = "kb://",
        case_insensitive: bool = False,
        **kwargs: Any,
    ) -> str:
        """正则内容搜索：跨多个 target URI grep 并合并结果。"""
        client = None
        try:
            client = await self._get_client(tool_context)
            matches = []
            target_uris = self._fs_retrieval_uris(client, tool_context, uri)
            for target_uri in target_uris:
                try:
                    result = await client.grep(
                        target_uri,
                        pattern,
                        case_insensitive=case_insensitive,
                    )
                except Exception as exc:
                    if len(target_uris) == 1:
                        raise
                    logger.debug(f"Skip grep target {target_uri}: {exc}")
                    continue
                if isinstance(result, dict):
                    matches.extend(result.get("matches", []))
                else:
                    matches.extend(getattr(result, "matches", []))

            if not matches:
                return f"No matches found for pattern: '{pattern}'"

            merged_results: dict[str, list[tuple[int, str]]] = {}

            for match in matches:
                if isinstance(match, dict):
                    match_uri = match.get("uri", "unknown")
                    line = match.get("line", "?")
                    content = match.get("content", "")
                else:
                    match_uri = getattr(match, "uri", "unknown")
                    line = getattr(match, "line", "?")
                    content = getattr(match, "content", "")

                if match_uri not in merged_results:
                    merged_results[match_uri] = []
                merged_results[match_uri].append((line, content))

            result_lines = [
                f"Found {len(matches)} match{'es' if len(matches) != 1 else ''} for pattern '{pattern}':"
            ]

            for match_uri, uri_matches in merged_results.items():
                uri_matches.sort(key=lambda x: int(x[0]) if str(x[0]).isdigit() else 0)
                result_lines.append(f"\n {match_uri}")
                for line, content in uri_matches:
                    result_lines.append(f"   Line {line}:")
                    result_lines.append(f"   {content}")

            return "\n".join(result_lines)
        except Exception as e:
            return f"Error searching with grep: {str(e)}"
        finally:
            await self._release_client(tool_context, client)


class KbGlobTool(KbFileTool):
    """Tool to find RAG resources using glob patterns."""

    @property
    def name(self) -> str:
        return "kb_glob"

    @property
    def description(self) -> str:
        return (
            "Find RAG resources using glob patterns (like **/*.md, *.py)."
            "Result: Only URIs and summaries are included here. To view the full content, use kb_multi_read tool."
        )

    @property
    def parameters(self) -> dict[str, Any]:
        return {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Glob pattern to match (e.g., **/*.md, *.py, src/**/*.js)",
                },
                "uri": {
                    "type": "string",
                    "description": "The whole kb:// URI to search within (e.g., kb://resources/path/)",
                    "default": "",
                },
            },
            "required": ["pattern"],
        }

    async def execute(
        self, tool_context: "ToolContext", pattern: str, uri: str = "", **kwargs: Any
    ) -> str:
        """Glob 模式匹配：跨多个 target URI glob 并合并结果。"""
        client = None
        try:
            client = await self._get_client(tool_context)
            matches = []
            count = 0
            target_uris = self._fs_retrieval_uris(client, tool_context, uri or "kb://")
            for target_uri in target_uris:
                try:
                    result = await client.glob(pattern, uri=target_uri or "kb://")
                except Exception as exc:
                    if len(target_uris) == 1:
                        raise
                    logger.debug(f"Skip glob target {target_uri}: {exc}")
                    continue

                if isinstance(result, dict):
                    batch_matches = result.get("matches", [])
                    batch_count = result.get("count", len(batch_matches))
                else:
                    batch_matches = getattr(result, "matches", [])
                    batch_count = getattr(result, "count", len(batch_matches))
                matches.extend(batch_matches)
                count += int(batch_count or 0)

            if not matches:
                return f"No files found for pattern: {pattern}"

            result_lines = [f"Found {count} file{'s' if count != 1 else ''}:"]
            for match_uri in matches:
                if isinstance(match_uri, dict):
                    match_uri = match_uri.get("uri", str(match_uri))
                result_lines.append(f" {match_uri}")

            return "\n".join(result_lines)
        except Exception as e:
            return f"Error searching with glob: {str(e)}"
        finally:
            await self._release_client(tool_context, client)
```

> **Agent 对接要点**：`SearchService` 是服务层，`find()` 无状态 / `search()` 带 session，委托 `ContextFS` -> `HierarchicalRetriever`。REST API `POST /api/v1/search/{find,search,grep,glob}` 用 `_sanitize_floats` 递归把 inf/nan 替 0.0 保证 JSON 合规。`HelixRagRetriever`（LangChain `BaseRetriever`）的 `content_mode` 控制返回 abstract/overview/read/全。`create_rag_tools` 按 profile（retrieval/agent/admin）选工具子集，`allow_forget` 才加 `kb_forget`。`KbSearchTool` 是原生 Tool 基座，`min_score` 过滤 + memory/resource/skill 分组 JSON 输出 + peer memory fanout；`KbMultiReadTool` 用 `asyncio.Semaphore(10)` 并发读全文。
