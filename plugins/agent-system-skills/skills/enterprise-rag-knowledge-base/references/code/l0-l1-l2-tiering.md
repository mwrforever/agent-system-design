# 完整源码：L0/L1/L2 三层知识库索引与构建管线

> 本文件给出三层知识库的核心类型定义与构建管线源码。`ContextLevel` 定义 L0/L1/L2 语义层级，`Context` 是贯穿全系统的统一上下文对象，`CollectionSchemas` 定义向量库 schema，`TreeBuilder` 与 `SemanticProcessor` 构成 v5.0 异步构建管线。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.rag.*`），去除一切项目字样。原代码注释保留以保真。

## §1 ContextLevel 枚举与 Context 统一上下文（core/helix/rag/core/context.py）

```python
# core/helix/rag/core/context.py
"""Helix RAG 统一上下文类。"""

from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, List, Optional
from uuid import uuid4

from helix.rag.core.namespace import context_type_for_uri, owner_fields_for_uri
from helix.rag.utils.time_utils import format_iso8601, parse_iso_datetime
from helix.rag.session.user_id import UserIdentifier
from helix.rag.utils.uri import KbURI


class ResourceContentType(str, Enum):
    """Resource content type"""

    TEXT = "text"
    IMAGE = "image"
    VIDEO = "video"
    AUDIO = "audio"
    BINARY = "binary"


class ContextType(str, Enum):
    """Context type"""

    SKILL = "skill"
    MEMORY = "memory"
    RESOURCE = "resource"


class ContextLevel(int, Enum):
    """Context level (L0/L1/L2) for vector indexing

    三层语义层级：
    - L0 ABSTRACT: 目录的一句话摘要（.abstract.md），rerank 输入用这层
    - L1 OVERVIEW: 目录的中等粒度概览（.overview.md）
    - L2 DETAIL:   文件完整内容（文件路径本身）
    """

    ABSTRACT = 0  # L0: abstract
    OVERVIEW = 1  # L1: overview
    DETAIL = 2  # L2: detail/content


class Vectorize:
    text: str = ""
    # images: list of image references (data URIs or URLs) for multimodal embedding
    images: List[str] = []

    def __init__(self, text: str = "", images: Optional[List[str]] = None):
        self.text = text
        self.images = list(images) if images else []


class Context:
    """
    统一上下文类，覆盖 resource / memory / skill 三种 context_type。

    核心字段：
    - uri: kb:// 形式的唯一标识
    - parent_uri: 父目录 URI（用于层级检索的分数传播）
    - abstract: L0 摘要文本
    - level: ContextLevel (0/1/2)
    - active_count: 访问计数（用于热度评分）
    - updated_at: 最后更新时间（用于热度衰减）
    - context_type: resource / memory / skill
    - account_id / owner_user_id / owner_space: 多租户隔离字段
    """

    def __init__(
        self,
        uri: str,
        parent_uri: Optional[str] = None,
        temp_uri: Optional[str] = None,
        is_leaf: bool = False,
        abstract: str = "",
        context_type: Optional[str] = None,
        category: Optional[str] = None,
        created_at: Optional[datetime] = None,
        updated_at: Optional[datetime] = None,
        active_count: int = 0,
        related_uri: Optional[List[str]] = None,
        meta: Optional[Dict[str, Any]] = None,
        level: int | ContextLevel | None = None,
        session_id: Optional[str] = None,
        user: Optional[UserIdentifier] = None,
        account_id: Optional[str] = None,
        owner_user_id: Optional[str] = None,
        owner_space: Optional[str] = None,
        id: Optional[str] = None,
    ):
        """初始化 Context 对象。"""
        self.id = id or str(uuid4())
        self.uri = uri
        self.parent_uri = parent_uri
        self.temp_uri = temp_uri
        self.is_leaf = is_leaf
        self.abstract = abstract
        self.context_type = context_type or context_type_for_uri(uri)
        self.category = category or self._derive_category()
        self.created_at = created_at or datetime.now(timezone.utc)
        self.updated_at = updated_at or self.created_at
        self.active_count = active_count
        self.related_uri = related_uri or []
        self.meta = meta or {}
        try:
            self.level = int(level) if level is not None else None
        except (TypeError, ValueError):
            self.level = None
        self.session_id = session_id
        self.user = user
        self.account_id = account_id or (user.account_id if user else "default")
        owner_fields = owner_fields_for_uri(
            uri,
            user=user,
            account_id=self.account_id,
        )
        self.owner_user_id = (
            owner_user_id if owner_user_id is not None else owner_fields["owner_user_id"]
        )
        self.owner_space = owner_space or self._derive_owner_space(user)
        self.vector: Optional[List[float]] = None
        self.vectorize = Vectorize(abstract)

    def _derive_owner_space(self, user: Optional[UserIdentifier]) -> str:
        """Best-effort owner space derived from URI and user."""
        if not user:
            return ""
        if self.uri.startswith("kb://user/") or self.uri.startswith("kb://session/"):
            return user.user_id
        return ""

    def _derive_category(self) -> str:
        """Derive category from URI using substring matching."""
        if "/patterns" in self.uri:
            return "patterns"
        elif "/cases" in self.uri:
            return "cases"
        elif "/profile" in self.uri:
            return "profile"
        elif "/preferences" in self.uri:
            return "preferences"
        elif "/entities" in self.uri:
            return "entities"
        elif "/events" in self.uri:
            return "events"
        return ""

    def get_context_type(self) -> str:
        """Get the type of this context (alias for context_type)."""
        return self.context_type

    def set_vectorize(self, vectorize: Vectorize):
        self.vectorize = vectorize

    def get_vectorization_text(self) -> str:
        """Get text for vectorization."""
        return self.vectorize.text

    def get_vectorization_images(self) -> List[str]:
        """Get image references (data URIs or URLs) for multimodal vectorization."""
        return self.vectorize.images

    def update_activity(self):
        """Update activity statistics. 更新访问计数与时间，用于热度评分。"""
        self.active_count += 1
        self.updated_at = datetime.now(timezone.utc)

    def to_dict(self) -> Dict[str, Any]:
        """Convert context to dictionary format for storage."""
        created_at_str = format_iso8601(self.created_at) if self.created_at else None
        updated_at_str = format_iso8601(self.updated_at) if self.updated_at else None

        data = {
            "id": self.id,
            "uri": self.uri,
            "parent_uri": self.parent_uri,
            "temp_uri": self.temp_uri,
            "is_leaf": self.is_leaf,
            "abstract": self.abstract,
            "context_type": self.context_type,
            "category": self.category,
            "created_at": created_at_str,
            "updated_at": updated_at_str,
            "active_count": self.active_count,
            "vector": self.vector,
            "meta": self.meta,
            "related_uri": self.related_uri,
            "session_id": self.session_id,
            "account_id": self.account_id,
            "owner_user_id": self.owner_user_id,
            "owner_space": self.owner_space,
        }
        if self.level is not None:
            data["level"] = int(self.level)

        if self.user:
            data["user"] = self.user.to_dict()

        # Add skill-specific fields from meta
        if self.context_type == "skill":
            data["name"] = self.meta.get("name", "")
            data["description"] = self.meta.get("description", "")

        return data

    @staticmethod
    def _derive_parent_uri(uri: str) -> Optional[str]:
        """Best-effort parent URI derivation for records persisted without parent_uri."""
        try:
            parent = KbURI(uri).parent
        except Exception:
            return None
        return parent.uri if parent else None

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Context":
        """Create a context object from dictionary."""
        user_data = data.get("user")
        user_obj = UserIdentifier.from_dict(user_data) if isinstance(user_data, dict) else user_data
        obj = cls(
            uri=data["uri"],
            parent_uri=data.get("parent_uri") or cls._derive_parent_uri(data["uri"]),
            temp_uri=data.get("temp_uri"),
            is_leaf=data.get("is_leaf", False),
            abstract=data.get("abstract", ""),
            context_type=data.get("context_type"),
            category=data.get("category"),
            created_at=(
                parse_iso_datetime(data["created_at"])
                if isinstance(data.get("created_at"), str)
                else data.get("created_at")
            ),
            updated_at=(
                parse_iso_datetime(data["updated_at"])
                if isinstance(data.get("updated_at"), str)
                else data.get("updated_at")
            ),
            active_count=data.get("active_count", 0),
            related_uri=data.get("related_uri", []),
            meta=data.get("meta", {}),
            level=(
                data.get("level")
                if data.get("level") is not None
                else data.get("meta", {}).get("level")
                if isinstance(data.get("meta"), dict)
                else None
            ),
            session_id=data.get("session_id"),
            user=user_obj,
            account_id=data.get("account_id"),
            owner_user_id=data.get("owner_user_id"),
            owner_space=data.get("owner_space"),
        )
        obj.id = data.get("id", obj.id)
        obj.vector = data.get("vector")
        return obj
```

## §2 向量库 Collection Schema（core/helix/rag/storage/collection_schemas.py）

```python
# core/helix/rag/storage/collection_schemas.py
"""
Collection schema definitions for Helix RAG.

提供集中式 schema 定义与 collection 创建工厂函数。
"""

import asyncio
import hashlib
import json
import threading
import time
from contextlib import nullcontext
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from helix.rag.models.embedder.base import EmbedResult, embed_compat
from helix.rag.server.identity import RequestContext, Role
from helix.rag.storage.errors import (
    CollectionNotFoundError,
    EmbeddingConfigurationError,
    EmbeddingRebuildRequiredError,
)
from helix.rag.storage.queuefs.embedding_msg import EmbeddingMsg
from helix.rag.storage.queuefs.named_queue import DequeueHandlerBase
from helix.rag.storage.vector_index_backend import VectorIndexBackend
from helix.rag.telemetry import bind_telemetry, resolve_telemetry
from helix.rag.telemetry.request_wait_tracker import get_request_wait_tracker
from helix.rag.utils.circuit_breaker import (
    CircuitBreaker,
    CircuitBreakerOpen,
    classify_api_error,
)
from helix.rag.utils.model_retry import ERROR_CLASS_INPUT_TOO_LARGE, ERROR_CLASS_PERMANENT
from helix.rag.session.user_id import UserIdentifier
from helix.rag.utils import get_logger
from helix.rag.config.helix_rag_config import HelixRagConfig

logger = get_logger(__name__)
EMBEDDING_META_MARKER = "\n\n[helix.rag.embedding]\n"


@dataclass
class RequestQueueStats:
    processed: int = 0
    requeue_count: int = 0
    error_count: int = 0


class CollectionSchemas:
    """
    集中式 collection schema 定义。

    context_collection 定义统一上下文 collection 的字段：
    - id (string, primary key)
    - uri (path 类型，支持路径前缀过滤)
    - context_type (string: resource/memory/skill)
    - vector (vector, dense)
    - sparse_vector (sparse_vector)
    - level (int64: 0=L0/1=L1/2=L2)
    - active_count (int64: 访问计数，用于热度评分)
    - account_id / owner_user_id (多租户隔离)
    """

    @staticmethod
    def context_collection(
        name: str, vector_dim: int, description: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Get the schema for the unified context collection.

        Args:
            name: Collection name
            vector_dim: Dimension of the dense vector field

        Returns:
            Schema definition for the context collection
        """
        fields = [
            {"FieldName": "id", "FieldType": "string", "IsPrimaryKey": True},
            {"FieldName": "uri", "FieldType": "path"},
            # type 字段：当前版本未使用，保留用于未来扩展
            {"FieldName": "type", "FieldType": "string"},
            # context_type 字段：区分上下文的大类
            # 枚举值："resource"（资源，默认）, "memory"（记忆）, "skill"（技能）
            {"FieldName": "context_type", "FieldType": "string"},
            {"FieldName": "vector", "FieldType": "vector", "Dim": vector_dim},
            {"FieldName": "sparse_vector", "FieldType": "sparse_vector"},
            {"FieldName": "created_at", "FieldType": "date_time"},
            {"FieldName": "updated_at", "FieldType": "date_time"},
            {"FieldName": "active_count", "FieldType": "int64"},
        ]
        fields.extend(
            [
                # level 字段：区分 L0/L1/L2 层级
                #   - 0 = L0（abstract，摘要）
                #   - 1 = L1（overview，概览）
                #   - 2 = L2（detail/content，详情/内容，默认）
                # URI 命名规则：
                #   - level=0: {目录}/.abstract.md
                #   - level=1: {目录}/.overview.md
                #   - level=2: {文件路径}
                {"FieldName": "level", "FieldType": "int64"},
                {"FieldName": "name", "FieldType": "string"},
                {"FieldName": "description", "FieldType": "string"},
                {"FieldName": "tags", "FieldType": "string"},
                {"FieldName": "abstract", "FieldType": "string"},
                {"FieldName": "account_id", "FieldType": "string"},
                {"FieldName": "owner_user_id", "FieldType": "string"},
            ]
        )
        scalar_index = [
            "uri",
            "type",
            "context_type",
            "created_at",
            "updated_at",
            "active_count",
        ]
        scalar_index.extend(
            [
                "level",
                "name",
                "tags",
                "account_id",
                "owner_user_id",
            ]
        )
        return {
            "CollectionName": name,
            "Description": description or "Unified context collection",
            "Fields": fields,
            "ScalarIndex": scalar_index,
        }


def _get_active_embedding_model_config(config: "HelixRagConfig") -> Any:
    """从配置中取出当前生效的 embedding 模型配置（hybrid > dense > sparse）。"""
    embedding_cfg = config.embedding
    if embedding_cfg.hybrid is not None:
        return embedding_cfg.hybrid
    if embedding_cfg.dense is not None:
        return embedding_cfg.dense
    if embedding_cfg.sparse is not None:
        return embedding_cfg.sparse
    raise ValueError("No active embedding model configuration found")


def _build_embedding_metadata(config: "HelixRagConfig") -> Dict[str, Any]:
    """构造 embedding 元数据，写入 collection description 用于后续模型变更检测。"""
    model_cfg = _get_active_embedding_model_config(config)
    provider = (
        getattr(model_cfg, "provider", None) or getattr(model_cfg, "backend", None) or ""
    ).lower()
    model = getattr(model_cfg, "model", None) or ""
    dimension = config.embedding.dimension
    model_path = getattr(model_cfg, "model_path", None)
    model_identity = model

    if provider == "local":
        try:
            from helix.rag.models.embedder.local_embedders import get_local_model_identity

            resolved_identity = get_local_model_identity(model, model_path=model_path)
            model_identity = str(hashlib.sha256(resolved_identity.encode("utf-8")).hexdigest())
        except Exception:
            model_identity = model

    return {
        "provider": provider,
        "model": model,
        "dimension": dimension,
        "model_identity": model_identity,
    }


def _encode_collection_description(
    base_description: str,
    embedding_meta: Dict[str, Any],
) -> str:
    """把 embedding 元数据编码进 collection description，用特殊 marker 分隔。"""
    description = (base_description or "Unified context collection").strip()
    meta_json = json.dumps(embedding_meta, sort_keys=True, ensure_ascii=False)
    return f"{description}{EMBEDDING_META_MARKER}{meta_json}"


def _decode_collection_description(
    description: Optional[str],
) -> tuple[str, Optional[Dict[str, Any]]]:
    """从 collection description 中解码 embedding 元数据。"""
    text = description or ""
    if EMBEDDING_META_MARKER not in text:
        return text, None

    base, meta_json = text.split(EMBEDDING_META_MARKER, 1)
    try:
        payload = json.loads(meta_json.strip())
    except json.JSONDecodeError:
        logger.warning("Failed to parse collection embedding metadata from description")
        return text, None
    return base.strip(), payload if isinstance(payload, dict) else None


async def init_context_collection(storage) -> bool:
    """
    Initialize the context collection with proper schema.

    如果 collection 已存在但 embedding 元数据不匹配当前配置，且已有数据，
    则抛 EmbeddingRebuildRequiredError 要求重建（防止向量维度/模型不一致导致召回错乱）。

    Args:
        storage: Storage interface instance

    Returns:
        True if collection was created, False if already exists
    """
    from helix.rag.config import get_helix_rag_config

    config = get_helix_rag_config()
    name = config.storage.vectordb.name
    vector_dim = config.embedding.dimension
    if not name:
        raise ValueError("Vector DB collection name is required")
    collection_name = name
    embedding_meta = _build_embedding_metadata(config)
    vectordb_cfg = config.storage.vectordb
    uses_volcengine_data_plane = bool(
        vectordb_cfg.backend == "volcengine"
        and getattr(getattr(vectordb_cfg, "volcengine", None), "api_key", None)
    )
    if uses_volcengine_data_plane:
        # Volcengine 向量库数据面后端：collection/index/schema 须带外预建，跳过自动 bootstrap
        logger.info(
            "Skip collection bootstrap for volcengine data-plane backend; "
            "collection/index/schema must be pre-created out of band"
        )
        return False
    schema = CollectionSchemas.context_collection(
        collection_name,
        vector_dim,
        description=_encode_collection_description("Unified context collection", embedding_meta),
    )
    created = await storage.create_collection(collection_name, schema)
    if created:
        return True

    existing_meta = None
    if hasattr(storage, "get_collection_meta"):
        existing_meta = await storage.get_collection_meta()

    if not existing_meta:
        raise EmbeddingConfigurationError(
            "Existing collection metadata is unavailable; cannot validate embedding compatibility"
        )

    base_description, existing_embedding_meta = _decode_collection_description(
        existing_meta.get("Description")
    )
    if existing_embedding_meta == embedding_meta:
        return False

    existing_count = await storage.count() if hasattr(storage, "count") else 0
    if existing_embedding_meta is None and existing_count == 0:
        if hasattr(storage, "update_collection_description"):
            await storage.update_collection_description(
                _encode_collection_description(
                    base_description or "Unified context collection",
                    embedding_meta,
                )
            )
            return False

    if existing_embedding_meta is None:
        logger.warning(
            "Existing collection has %d vector(s) but no embedding metadata "
            "(created by an older version). Backfilling with current config and continuing.",
            existing_count,
        )
        if hasattr(storage, "update_collection_description"):
            await storage.update_collection_description(
                _encode_collection_description(
                    base_description or "Unified context collection",
                    embedding_meta,
                )
            )
        return False

    if existing_count == 0 and hasattr(storage, "update_collection_description"):
        await storage.update_collection_description(
            _encode_collection_description(
                base_description or "Unified context collection",
                embedding_meta,
            )
        )
        return False

    raise EmbeddingRebuildRequiredError(
        "Existing collection embedding metadata does not match current configuration. "
        "Rebuild is required before using the current embedding model."
    )
```

### TextEmbeddingHandler：向量化队列消费者（deterministic ID seed）

`TextEmbeddingHandler` 是 embedding 队列的消费者，把文本消息转成向量写入向量库。关键方法 `_seed_uri_for_id` 按 level 拼 deterministic id seed，保证同一语义层（L0/L1/L2）幂等 upsert。

```python
# core/helix/rag/storage/collection_schemas.py（TextEmbeddingHandler 节选）
class TextEmbeddingHandler(DequeueHandlerBase):
    """
    Text embedding handler that converts text messages to embedding vectors
    and writes results to vector database.

    支持 dense 和 sparse 向量，基于配置决定。带熔断器：API 持续失败时
    开路并重入队，避免拖垮整个向量化管线。
    """

    def __init__(self, vector_db: VectorIndexBackend):
        """Initialize the text embedding handler.

        Args:
            vector_db: VectorIndexBackend instance for writing to vector database
        """
        from helix.rag.config import get_helix_rag_config

        self._vector_db = vector_db
        self._embedder = None
        config = get_helix_rag_config()
        self._collection_name = config.storage.vectordb.name
        self._vector_dim = config.embedding.dimension
        self._initialize_embedder(config)
        breaker_cfg = config.embedding.circuit_breaker
        self._circuit_breaker = CircuitBreaker(
            failure_threshold=breaker_cfg.failure_threshold,
            reset_timeout=breaker_cfg.reset_timeout,
            max_reset_timeout=breaker_cfg.max_reset_timeout,
        )
        self._breaker_open_last_log_at = 0.0
        self._breaker_open_suppressed_count = 0
        self._breaker_open_log_interval = 30.0

    def _initialize_embedder(self, config: "HelixRagConfig"):
        """Initialize the embedder instance from config."""
        self._embedder = config.embedding.get_embedder()

    @staticmethod
    def _seed_uri_for_id(uri: str, level: Any) -> str:
        """Build deterministic id seed URI from canonical uri + hierarchy level.

        按 level 拼接 .abstract.md / .overview.md 后缀，保证同一语义层
        产生相同的 id seed -> md5 成相同 point id -> upsert 幂等。
        """
        try:
            level_int = int(level)
        except (TypeError, ValueError):
            level_int = 2

        if level_int == 0:
            return uri if uri.endswith("/.abstract.md") else f"{uri}/.abstract.md"
        if level_int == 1:
            return uri if uri.endswith("/.overview.md") else f"{uri}/.overview.md"
        return uri

    async def on_dequeue(self, data: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        """Process dequeued message and add embedding vector(s).

        流程：
        1. 解析 EmbeddingMsg，取出 context_data
        2. 熔断器检查：开路则重入队（有 queue manager）或丢弃（无）
        3. embed_compat 产 EmbedResult（dense + sparse）
        4. 校验 dense 向量维度
        5. 拼 deterministic id（account_id:seed_uri 的 md5）
        6. upsert 到向量库
        """
        if not data:
            return None

        embedding_msg: Optional[EmbeddingMsg] = None
        # （telemetry 绑定、熔断器检查等中间逻辑见源码，此处展示 embed + upsert 关键路径）

        # Generate embedding vector(s)
        if self._embedder:
            result: EmbedResult = await embed_compat(
                self._embedder, embedding_msg.message, is_query=False
            )

            # Add dense vector
            if result.dense_vector:
                inserted_data["vector"] = result.dense_vector
                # Validate vector dimension
                if len(result.dense_vector) != self._vector_dim:
                    error_msg = self._embedding_error_msg(
                        embedding_msg,
                        "Dense vector dimension mismatch: "
                        f"expected {self._vector_dim}, got {len(result.dense_vector)}",
                    )
                    logger.error(error_msg)
                    return None

            # Add sparse vector if present
            if result.sparse_vector:
                inserted_data["sparse_vector"] = result.sparse_vector
                logger.debug(
                    f"Generated sparse vector with {len(result.sparse_vector)} terms"
                )

        # Write to vector database
        # Ensure vector DB has deterministic IDs per semantic layer.
        uri = inserted_data.get("uri")
        account_id = inserted_data.get("account_id", "default")
        if uri:
            seed_uri = self._seed_uri_for_id(uri, inserted_data.get("level", 2))
            id_seed = f"{account_id}:{seed_uri}"
            inserted_data["id"] = hashlib.md5(id_seed.encode("utf-8")).hexdigest()

        user = UserIdentifier(
            account_id=account_id,
            user_id="default",
        )
        ctx = RequestContext(user=user, role=Role.ROOT)
        record_id = await self._vector_db.upsert(inserted_data, ctx=ctx)
        return inserted_data
```

## §3 TreeBuilder：v5.0 URI 元数据构建（core/helix/rag/parse/tree_builder.py）

```python
# core/helix/rag/parse/tree_builder.py
"""
Tree Builder for Helix RAG.

把解析后的文档树转成 Context 对象，带正确的 L0/L1/L2 内容与 URI 结构。

v5.0 Architecture:
1. Parser: parse + create directory structure in temp ContextFS
2. TreeBuilder: build final URI metadata and keep temp references
3. ResourceProcessor: source commit from temp to final ContextFS path
4. SemanticProcessor: async generate L0/L1 + vectorize

IMPORTANT (v5.0 Architecture):
- Parser creates directory structure directly, no LLM calls
- TreeBuilder does not move files; source commit is handled after URI metadata is built
- SemanticProcessor handles all semantic generation asynchronously
- Temporary directory approach eliminates memory pressure and enables concurrency
- Resource objects are lightweight (no content fields)
- Content splitting is handled by Parser, not TreeBuilder
"""

from typing import Optional

from helix.rag.core.building_tree import BuildingTree
from helix.rag.core.context import Context
from helix.rag.core.namespace import is_content_root_uri
from helix.rag.parse.parsers.media.utils import get_media_base_uri, get_media_type
from helix.rag.server.identity import RequestContext
from helix.rag.storage.context_fs import get_context_fs
from helix.rag.utils import parse_code_hosting_url
from helix.rag.utils import get_logger
from helix.rag.utils.uri import KbURI

logger = get_logger(__name__)


class TreeBuilder:
    """
    Builds context tree from parsed documents (v5.0).

    New v5.0 Architecture:
    - Parser creates directory structure in temp ContextFS (no LLM calls)
    - TreeBuilder builds final URI metadata while preserving temp URIs
    - ResourceProcessor commits temp content to the final source path
    - SemanticProcessor handles semantic generation asynchronously

    Process flow:
    1. Parser creates directory structure with files in temp ContextFS
    2. TreeBuilder.finalize_from_temp() returns final URI and temp URI metadata
    3. ResourceProcessor performs source commit with short path locks
    4. SemanticProcessor generates .abstract.md and .overview.md asynchronously
    5. SemanticProcessor directly vectorizes and inserts to collection

    Key changes from v4.0:
    - Semantic generation moved from Parser to SemanticQueue
    - ResourceProcessor enqueues directories for async processing
    - Direct vectorization in SemanticProcessor (no EmbeddingQueue)
    """

    def __init__(self):
        """Initialize TreeBuilder."""
        pass

    def _get_base_uri(
        self, scope: str, source_path: Optional[str] = None, source_format: Optional[str] = None
    ) -> str:
        """Get base URI for scope, with special handling for media files."""
        # Check if it's a media file first
        if scope == "resources":
            media_type = get_media_type(source_path, source_format)
            if media_type:
                return get_media_base_uri(media_type)
            return "kb://resources"
        if scope == "user":
            # user resources go to memories (no separate resources dir)
            return "kb://user"
        raise ValueError(f"unsupported tree scope: {scope}")

    # ============================================================================
    # v5.0 Methods (temporary directory + SemanticQueue architecture)
    # ============================================================================

    async def resolve_target_uri(
        self,
        *,
        ctx: RequestContext,
        doc_name: str,
        scope: str = "resources",
        to_uri: Optional[str] = None,
        parent_uri: Optional[str] = None,
        source_path: Optional[str] = None,
        source_format: Optional[str] = None,
        create_parent: bool = False,
    ) -> tuple[str, Optional[str]]:
        """Resolve the final target URI and optional unique-name candidate.

        将文档名清洗为 URI 安全段，解析最终落盘 URI（to_uri 优先 / parent_uri 次之 /
        按 scope 自动推导 base）。仓库类资源自动用 org/repo 作名。
        """
        final_doc_name = KbURI.sanitize_segment(doc_name)
        if source_path and source_format == "repository":
            parsed_org_repo = parse_code_hosting_url(source_path)
            if parsed_org_repo:
                final_doc_name = parsed_org_repo

        auto_base_uri = self._get_base_uri(scope, source_path, source_format)
        base_uri = parent_uri or auto_base_uri
        use_to_as_parent = bool(to_uri and is_content_root_uri(to_uri, ctx, kind="resource"))
        if to_uri and not use_to_as_parent:
            return to_uri, None

        effective_parent_uri = (parent_uri or to_uri) if use_to_as_parent else parent_uri
        if effective_parent_uri:
            effective_parent_uri = effective_parent_uri.rstrip("/")
        if effective_parent_uri:
            context_fs = get_context_fs()
            try:
                parent_exists = await context_fs.exists(effective_parent_uri, ctx=ctx)
                if not parent_exists:
                    if create_parent:
                        logger.info(
                            "Creating missing parent directory: %s", effective_parent_uri
                        )
                        await context_fs.mkdir(effective_parent_uri, exist_ok=True, ctx=ctx)
                    else:
                        raise ValueError(
                            f"Parent URI does not exist: {effective_parent_uri}"
                        )
            except Exception as exc:
                raise ValueError(
                    f"Failed to verify parent URI {effective_parent_uri}: {exc}"
                ) from exc
        # （后续 final URI 拼接与 unique-name 候选逻辑见源码）
```

## §4 SemanticProcessor：自底向上生成 L0/L1（core/helix/rag/storage/queuefs/semantic_processor.py）

```python
# core/helix/rag/storage/queuefs/semantic_processor.py
"""SemanticProcessor: Processes messages from SemanticQueue, generates .abstract.md and .overview.md.

自底向上生成目录的 L0 摘要与 L1 概览，完成后入向量化队列。
"""

import asyncio
import json
import threading
from contextlib import nullcontext
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple

from helix.rag.observability.context import (
    bind_root_observability_context,
    reset_root_observability_context,
)
from helix.rag.parse.parsers.constants import (
    CODE_EXTENSIONS,
    DOCUMENTATION_EXTENSIONS,
    FILE_TYPE_CODE,
    FILE_TYPE_DOCUMENTATION,
    FILE_TYPE_OTHER,
)
from helix.rag.parse.image_rewrite import (
    IMAGE_MAPPINGS_FILENAME,
    rewrite_image_uris,
)
from helix.rag.parse.parsers.media.utils import (
    generate_audio_summary,
    generate_image_summary,
    generate_video_summary,
    get_media_type,
)
from helix.rag.prompts import render_prompt
from helix.rag.server.identity import RequestContext, Role
from helix.rag.storage.errors import LockAcquisitionError
from helix.rag.storage.queuefs.named_queue import DequeueHandlerBase
from helix.rag.storage.queuefs.semantic_dag import DagStats, SemanticDagExecutor
from helix.rag.storage.queuefs.semantic_lock import SemanticLockScope
from helix.rag.storage.queuefs.semantic_msg import SemanticMsg, build_semantic_coalesce_key
from helix.rag.storage.queuefs.semantic_queue import is_semantic_msg_stale
from helix.rag.storage.queuefs.semantic_sidecar import write_semantic_sidecars
from helix.rag.storage.transaction import NO_LOCK, LockLease
from helix.rag.storage.context_fs import LS_ALL_NODES, get_context_fs
from helix.rag.telemetry import bind_telemetry, bind_telemetry_stage, resolve_telemetry
from helix.rag.telemetry.request_wait_tracker import get_request_wait_tracker
from helix.rag.telemetry.span_models import create_root_span_attributes
from helix.rag.utils.circuit_breaker import (
    CircuitBreaker,
    CircuitBreakerOpen,
    classify_api_error,
)
from helix.rag.utils.model_retry import ERROR_CLASS_INPUT_TOO_LARGE, ERROR_CLASS_PERMANENT
from helix.rag.session.user_id import UserIdentifier
from helix.rag.utils import KbURI
from helix.rag.config import get_helix_rag_config
from helix.rag.utils.logger import get_logger

logger = get_logger(__name__)


@dataclass
class DiffResult:
    """Directory diff result for sync operations."""

    added_files: List[str] = field(default_factory=list)
    deleted_files: List[str] = field(default_factory=list)
    updated_files: List[str] = field(default_factory=list)
    added_dirs: List[str] = field(default_factory=list)
    deleted_dirs: List[str] = field(default_factory=list)

    def to_changes(self) -> Dict[str, List[str]]:
        return {
            "added": self.added_files + self.added_dirs,
            "modified": self.updated_files,
            "deleted": self.deleted_files + self.deleted_dirs,
        }


class RequestQueueStats:
    processed: int = 0
    requeue_count: int = 0
    error_count: int = 0


class SemanticProcessor(DequeueHandlerBase):
    """
    Semantic processor, generates .abstract.md and .overview.md bottom-up.

    Processing flow:
    1. Concurrently generate summaries for files in directory
    2. Collect .abstract.md from subdirectories
    3. Generate .abstract.md and .overview.md for this directory
    4. Enqueue to EmbeddingQueue for vectorization

    关键设计：
    - 自底向上：先处理子目录，收集子目录的 .abstract.md，再生成当前目录的 L0/L1
    - DAG 并发：SemanticDagExecutor 控制目录间依赖与并发
    - 熔断 + 重入队：API 失败时按错误分类（INPUT_TOO_LARGE 丢弃 / PERMANENT 丢弃 / 瞬态重入队）
    - 语义锁：SemanticLockScope 防止同一目录并发处理冲突
    """

    _stats_lock = threading.Lock()
    _dag_stats_by_telemetry_id: Dict[str, DagStats] = {}
    _dag_stats_by_uri: Dict[str, DagStats] = {}
    _dag_stats_order: List[Tuple[str, str]] = []
    _request_stats_by_telemetry_id: Dict[str, RequestQueueStats] = {}
    # （完整 SemanticProcessor 实现：on_dequeue / _process_directory /
    #  _generate_abstract / _generate_overview / 向量化入队逻辑见源码）
```

> **构建管线总结**：Parser 建目录结构（无 LLM）-> `TreeBuilder` 建 URI 元数据 -> `ResourceProcessor` 提交 temp 到 final -> `SemanticProcessor` 自底向上异步生成 `.abstract.md`(L0) + `.overview.md`(L1) -> `TextEmbeddingHandler` 向量化并 upsert 到向量库（deterministic ID 按 level 拼 seed）。三层索引（L0/L1/L2）在向量库中通过 `level` 字段区分，检索时按 `level` 过滤返回。
