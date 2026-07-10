# 完整源码：回调构造 + provider 配置 + 请求级关联 id

> 本文件给出 tracing 链路的**入口三层**完整实现：回调工厂（`factory.py`）、provider 配置（`config/tracing_config.py`）、请求级关联 id（`trace_context.py`）。SKILL.md 仅给出伪代码与架构思路，完整源码以此处为准。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`），去除一切项目字样。原代码注释保留以保真。

## 1. 回调工厂（factory.py）

```python
# core/helix/tracing/factory.py
from __future__ import annotations

from typing import Any

from helix.config import (
    get_enabled_tracing_providers,
    get_tracing_config,
    validate_enabled_tracing_providers,
)


def _create_langsmith_tracer(config) -> Any:
    from langchain_core.tracers.langchain import LangChainTracer

    return LangChainTracer(project_name=config.project)


def _create_langfuse_handler(config) -> Any:
    from langfuse import Langfuse
    from langfuse.langchain import CallbackHandler as LangfuseCallbackHandler

    # langfuse>=4 通过 client 单例初始化项目级凭证；
    # LangChain callback 随后附着到该已配置的 client。
    Langfuse(
        secret_key=config.secret_key,
        public_key=config.public_key,
        host=config.host,
    )
    return LangfuseCallbackHandler(public_key=config.public_key)


def build_tracing_callbacks() -> list[Any]:
    """为所有显式启用的 tracing provider 构造回调。"""
    validate_enabled_tracing_providers()
    enabled_providers = get_enabled_tracing_providers()
    if not enabled_providers:
        return []

    tracing_config = get_tracing_config()
    callbacks: list[Any] = []

    for provider in enabled_providers:
        if provider == "langsmith":
            try:
                callbacks.append(_create_langsmith_tracer(tracing_config.langsmith))
            except Exception as exc:  # pragma: no cover - 经测试 monkeypatch 覆盖
                raise RuntimeError(f"LangSmith tracing initialization failed: {exc}") from exc
        elif provider == "langfuse":
            try:
                callbacks.append(_create_langfuse_handler(tracing_config.langfuse))
            except Exception as exc:  # pragma: no cover - 经测试 monkeypatch 覆盖
                raise RuntimeError(f"Langfuse tracing initialization failed: {exc}") from exc

    return callbacks
```

## 2. provider 配置（config/tracing_config.py）

```python
# core/helix/config/tracing_config.py
import os
import threading

from pydantic import BaseModel, Field

_config_lock = threading.Lock()


class LangSmithTracingConfig(BaseModel):
    """LangSmith tracing 配置。"""

    enabled: bool = Field(...)
    api_key: str | None = Field(...)
    project: str = Field(...)
    endpoint: str = Field(...)

    @property
    def is_configured(self) -> bool:
        return self.enabled and bool(self.api_key)

    def validate(self) -> None:
        if self.enabled and not self.api_key:
            raise ValueError("LangSmith tracing is enabled but LANGSMITH_API_KEY (or LANGCHAIN_API_KEY) is not set.")


class LangfuseTracingConfig(BaseModel):
    """Langfuse tracing 配置。"""

    enabled: bool = Field(...)
    public_key: str | None = Field(...)
    secret_key: str | None = Field(...)
    host: str = Field(...)

    @property
    def is_configured(self) -> bool:
        return self.enabled and bool(self.public_key) and bool(self.secret_key)

    def validate(self) -> None:
        if not self.enabled:
            return
        missing: list[str] = []
        if not self.public_key:
            missing.append("LANGFUSE_PUBLIC_KEY")
        if not self.secret_key:
            missing.append("LANGFUSE_SECRET_KEY")
        if missing:
            raise ValueError(f"Langfuse tracing is enabled but required settings are missing: {', '.join(missing)}")


class TracingConfig(BaseModel):
    """支持的 tracing provider 配置。"""

    langsmith: LangSmithTracingConfig = Field(...)
    langfuse: LangfuseTracingConfig = Field(...)

    @property
    def is_configured(self) -> bool:
        return bool(self.enabled_providers)

    @property
    def explicitly_enabled_providers(self) -> list[str]:
        enabled: list[str] = []
        if self.langsmith.enabled:
            enabled.append("langsmith")
        if self.langfuse.enabled:
            enabled.append("langfuse")
        return enabled

    @property
    def enabled_providers(self) -> list[str]:
        enabled: list[str] = []
        if self.langsmith.is_configured:
            enabled.append("langsmith")
        if self.langfuse.is_configured:
            enabled.append("langfuse")
        return enabled

    def validate_enabled(self) -> None:
        self.langsmith.validate()
        self.langfuse.validate()


_tracing_config: TracingConfig | None = None


_TRUTHY_VALUES = {"1", "true", "yes", "on"}


def _env_flag_preferred(*names: str) -> bool:
    """返回第一个存在且非空的 env var 的布尔值。"""
    for name in names:
        value = os.environ.get(name)
        if value is not None and value.strip():
            return value.strip().lower() in _TRUTHY_VALUES
    return False


def _first_env_value(*names: str) -> str | None:
    """从候选名中返回首个非空 env 值。"""
    for name in names:
        value = os.environ.get(name)
        if value and value.strip():
            return value.strip()
    return None


def get_tracing_config() -> TracingConfig:
    """从环境变量获取当前 tracing 配置。"""
    global _tracing_config
    if _tracing_config is not None:
        return _tracing_config
    with _config_lock:
        if _tracing_config is not None:
            return _tracing_config
        _tracing_config = TracingConfig(
            langsmith=LangSmithTracingConfig(
                enabled=_env_flag_preferred("LANGSMITH_TRACING", "LANGCHAIN_TRACING_V2", "LANGCHAIN_TRACING"),
                api_key=_first_env_value("LANGSMITH_API_KEY", "LANGCHAIN_API_KEY"),
                project=_first_env_value("LANGSMITH_PROJECT", "LANGCHAIN_PROJECT") or "helix",
                endpoint=_first_env_value("LANGSMITH_ENDPOINT", "LANGCHAIN_ENDPOINT") or "https://api.smith.langchain.com",
            ),
            langfuse=LangfuseTracingConfig(
                enabled=_env_flag_preferred("LANGFUSE_TRACING"),
                public_key=_first_env_value("LANGFUSE_PUBLIC_KEY"),
                secret_key=_first_env_value("LANGFUSE_SECRET_KEY"),
                host=_first_env_value("LANGFUSE_BASE_URL") or "https://cloud.langfuse.com",
            ),
        )
        return _tracing_config


def get_enabled_tracing_providers() -> list[str]:
    """返回已启用且配置完整的 tracing provider。"""
    return get_tracing_config().enabled_providers


def get_explicitly_enabled_tracing_providers() -> list[str]:
    """返回配置显式启用的 provider（即使不完整）。"""
    return get_tracing_config().explicitly_enabled_providers


def validate_enabled_tracing_providers() -> None:
    """校验所有显式启用的 provider 都已完整配置。"""
    get_tracing_config().validate_enabled()


def is_tracing_enabled() -> bool:
    """检查是否有任何 tracing provider 已启用且完整配置。"""
    return get_tracing_config().is_configured


def reset_tracing_config() -> None:
    """丢弃缓存的 TracingConfig，使下次调用重建。

    公共 API，使测试不必直接触碰私有 _tracing_config 模块属性。
    未来内部重命名会静默破坏直接 mutate 该属性的调用方。
    """
    global _tracing_config
    with _config_lock:
        _tracing_config = None
```

## 3. 请求级关联 id（trace_context.py）

```python
# core/helix/trace_context.py
"""请求 trace context 辅助。

此处存储的值是 Helix 的请求级关联 id。它独立于 Langfuse 自己的 trace id，
也独立于 Helix run id。
"""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar, Token
from typing import Final

TRACE_ID_HEADER: Final[str] = "X-Trace-Id"
HELIX_TRACE_METADATA_KEY: Final[str] = "helix_trace_id"
_MAX_TRACE_ID_LENGTH: Final[int] = 512

_current_trace_id: Final[ContextVar[str | None]] = ContextVar("helix_current_trace_id", default=None)


def generate_trace_id() -> str:
    """返回一个新鲜的 header 安全 trace id。"""
    return uuid.uuid4().hex


def normalize_trace_id(value: object) -> str | None:
    """返回安全的 trace id 字符串，value 不可用时返回 None。

    仅接受可打印 ASCII（0x20-0x7E）。拒绝 0x7E 以上码点，因为 trace id 会
    往返经过 HTTP 响应头，Starlette 以 latin-1 编码：>0xFF 码点会在
    MutableHeaders.__setitem__ 内抛 UnicodeEncodeError（在响应体派发前就
    强制 500），而 C1 控制符（0x80-0x9F）技术上可编码但会被加固型中间代理
    （nginx / envoy / cloudfront）剥离或拒绝，静默破坏响应。C0 控制符
    （<0x20）与 DEL（0x7F）因同样的 header 安全原因 + 日志注入防御被拒绝。
    """
    if not isinstance(value, str):
        return None
    trace_id = value.strip()
    if not trace_id or len(trace_id) > _MAX_TRACE_ID_LENGTH:
        return None
    if any(ord(ch) < 32 or ord(ch) > 126 for ch in trace_id):
        return None
    return trace_id


def set_current_trace_id(trace_id: str) -> Token[str | None]:
    """把 trace_id 绑定到当前执行上下文。"""
    normalized = normalize_trace_id(trace_id)
    if normalized is None:
        normalized = generate_trace_id()
    return _current_trace_id.set(normalized)


def reset_current_trace_id(token: Token[str | None]) -> None:
    """恢复 token 捕获的 trace context。"""
    _current_trace_id.reset(token)


def get_current_trace_id() -> str | None:
    """返回当前绑定的请求 trace id（若有）。"""
    return _current_trace_id.get()


@contextmanager
def request_trace_context(trace_id: str | None = None) -> Iterator[str]:
    """在请求或入口点期间绑定一个请求 trace id。"""
    normalized = normalize_trace_id(trace_id) or generate_trace_id()
    token = _current_trace_id.set(normalized)
    try:
        yield normalized
    finally:
        _current_trace_id.reset(token)


@contextmanager
def ensure_trace_context(trace_id: str | None = None) -> Iterator[str]:
    """绑定 trace_id，继承当前 trace，或创建新的。"""
    normalized = normalize_trace_id(trace_id) or get_current_trace_id() or generate_trace_id()
    token = _current_trace_id.set(normalized)
    try:
        yield normalized
    finally:
        _current_trace_id.reset(token)
```
