# `backend/packages/harness/helix/agents/__init__.py`

> 逐字复制的真实源码（51 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
from typing import TYPE_CHECKING, Any

from .features import Next, Prev, RuntimeFeatures

if TYPE_CHECKING:
    from langchain_core.runnables import RunnableConfig

__all__ = [
    "create_helix_agent",
    "RuntimeFeatures",
    "Next",
    "Prev",
    "make_lead_agent",
    "SandboxState",
    "DeltaThreadState",
    "ThreadState",
]


def make_lead_agent(config: "RunnableConfig") -> Any:
    """Build the lead graph while keeping package-root imports lightweight.

    LangGraph Server resolves configured graph factories directly from a
    module's ``__dict__``, so this entrypoint must be a concrete module-level
    function rather than a value supplied only through ``__getattr__``.
    """
    from .lead_agent import make_lead_agent as factory
    from .lead_agent.prompt import prime_enabled_skills_cache

    prime_enabled_skills_cache()
    return factory(config)


def __getattr__(name: str):
    if name == "create_helix_agent":
        from .factory import create_helix_agent

        globals()[name] = create_helix_agent
        return create_helix_agent
    if name in {"DeltaThreadState", "SandboxState", "ThreadState"}:
        from .thread_state import DeltaThreadState, SandboxState, ThreadState

        exports = {
            "DeltaThreadState": DeltaThreadState,
            "SandboxState": SandboxState,
            "ThreadState": ThreadState,
        }
        globals().update(exports)
        return exports[name]
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
```
