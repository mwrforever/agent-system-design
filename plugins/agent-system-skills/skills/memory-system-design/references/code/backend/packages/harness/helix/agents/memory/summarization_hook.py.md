# `backend/packages/harness/helix/agents/memory/summarization_hook.py`

> 逐字复制的真实源码（34 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
"""Hooks fired before summarization removes messages from state."""

from __future__ import annotations

from helix.agents.memory import get_memory_manager
from helix.agents.middlewares.memory_middleware import redact_queued_messages
from helix.agents.middlewares.summarization_middleware import SummarizationEvent
from helix.config.memory_config import get_memory_config
from helix.config.pii_redaction_config import PiiRedactionConfig
from helix.runtime.user_context import resolve_runtime_user_id


def memory_flush_hook(event: SummarizationEvent, pii_redaction_config: PiiRedactionConfig | None = None) -> None:
    """Flush messages about to be summarized into the memory queue.

    Thin, backend-agnostic entry: only the ``enabled`` + ``thread_id`` gate
    and ``user_id`` resolution live here. The backend (via
    ``manager.add_nowait``) does the filtering, human/AI validation, and
    correction/reinforcement detection. The queued payload is redacted at
    this boundary (#3190 vector 5): compaction removes these messages from
    state right after, so the later after-agent redaction cannot repair a
    raw batch queued here.
    """
    if not get_memory_config().enabled or not event.thread_id:
        return

    user_id = resolve_runtime_user_id(event.runtime)
    get_memory_manager().add_nowait(
        event.thread_id,
        redact_queued_messages(list(event.messages_to_summarize), pii_redaction_config),
        agent_name=event.agent_name,
        user_id=user_id,
    )
```
