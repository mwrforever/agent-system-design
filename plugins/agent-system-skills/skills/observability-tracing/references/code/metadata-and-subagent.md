# 完整源码：metadata 注入 + subagent 归父 session + subagent token 收集

> 本文件给出 tracing 链路的**归并层**完整实现：Langfuse trace-attribute metadata 构造/注入（`tracing/metadata.py`）、subagent 执行器中归并父 session 的注入段（`subagents/executor.py` 相关节选）、subagent token 收集器（`subagents/token_collector.py` 完整）。SKILL.md 仅给出伪代码与架构思路，完整源码以此处为准。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*`），去除一切项目字样。原代码注释保留以保真。

## 1. Langfuse trace-attribute metadata（tracing/metadata.py）

```python
# core/helix/tracing/metadata.py
"""Langfuse trace-attribute metadata 构造器。

Langfuse v4 的 langchain.CallbackHandler 从 RunnableConfig.metadata 中提升
一组固定保留 key 到根 trace：

- langfuse_session_id -> 分组 trace（LangGraph thread -> Langfuse Session）
- langfuse_user_id    -> trace user_id（驱动 Users 页）
- langfuse_trace_name -> 人类可读 trace 名
- langfuse_tags       -> trace 标签

见 langfuse/langchain/CallbackHandler.py::_parse_langfuse_trace_attributes
与 https://langfuse.com/docs/observability/features/sessions 的契约。
此处构造器存在，使 gateway/run worker 能注入正确 metadata 而不把 Langfuse
内部细节泄漏到调用点。
"""

from __future__ import annotations

from typing import Any

from helix.config import get_enabled_tracing_providers
from helix.trace_context import HELIX_TRACE_METADATA_KEY, get_current_trace_id, normalize_trace_id

# 延迟导入以避免循环导入：helix.runtime 急切导入 run worker，后者又需要 helix.tracing。
_DEFAULT_TRACE_NAME = "lead-agent"


def build_langfuse_trace_metadata(
    *,
    thread_id: str | None,
    user_id: str | None = None,
    assistant_id: str | None = None,
    model_name: str | None = None,
    environment: str | None = None,
    helix_trace_id: str | None = None,
) -> dict[str, Any]:
    """返回供 RunnableConfig.metadata 使用的 Langfuse trace-attribute metadata。

    Langfuse 不在启用的 tracing provider 中时返回 {}，使调用方可以无条件
    merge 结果而不影响 LangSmith 或其他 tracer。

    Args:
        thread_id: LangGraph thread id；映射到 langfuse_session_id。
        user_id: 有效 user id；None 时回退 DEFAULT_USER_ID，使无认证模式下
            Langfuse Users 页仍可用。
        assistant_id: 可选 agent 标识；缺省 "lead-agent"。
        model_name: 模型名；以 model:<name> 形式进 langfuse_tags。
        environment: 部署环境（如 "production"）；以 env:<value> 形式进
            langfuse_tags。
        helix_trace_id: 可选的 Helix 请求 trace id；缺省时回退当前请求
            trace context。
    """
    if "langfuse" not in get_enabled_tracing_providers():
        return {}

    from helix.runtime.user_context import DEFAULT_USER_ID

    metadata: dict[str, Any] = {
        "langfuse_session_id": thread_id,
        "langfuse_user_id": user_id or DEFAULT_USER_ID,
        "langfuse_trace_name": assistant_id or _DEFAULT_TRACE_NAME,
    }
    request_trace_id = normalize_trace_id(helix_trace_id) or get_current_trace_id()
    if request_trace_id:
        metadata[HELIX_TRACE_METADATA_KEY] = request_trace_id

    tags: list[str] = []
    if environment:
        tags.append(f"env:{environment}")
    if model_name:
        tags.append(f"model:{model_name}")
    if tags:
        metadata["langfuse_tags"] = tags

    return metadata


def inject_langfuse_metadata(
    config: dict,
    *,
    thread_id: str | None,
    user_id: str | None = None,
    assistant_id: str | None = None,
    model_name: str | None = None,
    environment: str | None = None,
    helix_trace_id: str | None = None,
) -> None:
    """把 Langfuse trace-attribute metadata merge 进 config["metadata"]。

    由 run worker（runtime/runs/worker.py）与嵌入式 client（client.py）共享，
    使两条路径不会漂移。

    调用方提供的 metadata 经 setdefault 胜出——例如前端为
    langfuse_session_id 设的上游值保持不动。config dict 原地修改；Langfuse
    不在启用的 tracing provider 中时为 no-op。
    """
    langfuse_metadata = build_langfuse_trace_metadata(
        thread_id=thread_id,
        user_id=user_id,
        assistant_id=assistant_id,
        model_name=model_name,
        environment=environment,
        helix_trace_id=helix_trace_id,
    )
    if not langfuse_metadata:
        return

    merged_metadata = dict(config.get("metadata") or {})
    for key, value in langfuse_metadata.items():
        merged_metadata.setdefault(key, value)
    config["metadata"] = merged_metadata
```

## 2. subagent 归父 session 注入段（subagents/executor.py 节选）

> `SubagentExecutor` 完整实现见 [[subagent-delegation]]。此处仅摘录与 tracing 归并直接相关的部分：构造函数的 trace 字段、`_create_agent` 的 `attach_tracing=False`、`_aexecute` 的回调挂图根 + `inject_langfuse_metadata` 归父 + `helix_trace_id` 透传。

```python
# core/helix/subagents/executor.py（tracing 相关节选）
"""Subagent 执行引擎。"""

import asyncio
import os
from contextvars import copy_context
from typing import Any

from langchain_core.runnables import RunnableConfig

from helix.models import create_chat_model
from helix.trace_context import HELIX_TRACE_METADATA_KEY
from helix.tracing import build_tracing_callbacks, inject_langfuse_metadata


class SubagentExecutor:
    """subagent 执行器。"""

    def __init__(
        self,
        config,
        tools,
        *,
        thread_id: str | None = None,
        trace_id: str | None = None,
        user_id: str | None = None,
        user_role: str | None = None,
        oauth_provider: str | None = None,
        oauth_id: str | None = None,
        run_id: str | None = None,
        channel_user_id: str | None = None,
        helix_trace_id: str | None = None,
        # ...其余参数省略
    ):
        # ...
        self.thread_id = thread_id
        # 顶层调用未提供时生成 trace_id（用于分布式 tracing 关联日志）
        self.trace_id = trace_id or str(uuid.uuid4())[:8]
        self.user_id = user_id
        # 从父运行时上下文传播的 guardrail 归因
        self.user_role = user_role
        self.oauth_provider = oauth_provider
        self.oauth_id = oauth_id
        self.run_id = run_id
        # task_tool 派发时捕获的 IM-channel 发送者身份：群聊跨发送者共享一个
        # thread，故委派的 bash 命令必须导出派发 turn 的 id，而非空。
        self.channel_user_id = channel_user_id
        self.helix_trace_id = helix_trace_id
        # ...

    def _create_agent(self, tools=None, *, deferred_setup=None):
        """创建 agent 实例。"""
        app_config = self.app_config or get_app_config()
        if self.model_name is None:
            self.model_name = resolve_subagent_model_name(self.config, self.parent_model, app_config=app_config)
        # ⭐ in-graph 模型必须 attach_tracing=False，与 lead agent 同源，
        # 避免重复 span + langfuse_* 属性被剥离
        model = create_chat_model(
            name=self.model_name, thinking_enabled=False, app_config=app_config, attach_tracing=False
        )
        # ...中间件装配、create_agent 调用省略
        return create_agent(model=model, tools=..., middleware=..., system_prompt=None,
                            state_schema=ThreadState, checkpointer=False)

    async def _aexecute(self, task: str, result_holder=None):
        """异步执行一个任务。"""
        # ...state 构建省略
        collector_caller = f"subagent:{self.config.name}"
        collector = SubagentTokenCollector(caller=collector_caller)

        # 带 thread_id（沙箱访问）与 recursion_limit 的 config
        run_config: RunnableConfig = {
            "recursion_limit": self.config.max_turns,
            "callbacks": [collector],
            "tags": [collector_caller],
        }

        # ⭐ 在图级注入 tracing 回调，使单个 subagent run 产出一条 trace，
        # 所有 node / LLM / tool 调用作为子 span。镜像 lead agent 模式：
        # 图级 tracing 配合模型 attach_tracing=False 避免重复 trace。
        tracing_callbacks = build_tracing_callbacks()
        if tracing_callbacks:
            existing_callbacks = list(run_config.get("callbacks") or [])
            run_config["callbacks"] = [*existing_callbacks, *tracing_callbacks]

        # 归一化 subagent 名以匹配 lead-agent 命名形状（小写、仅连字符）。
        # 内联因为没有共享 helper——runtime/runs/naming.py 只处理 lead-agent run。
        if self.config.name:
            normalized_name = self.config.name.strip().lower().replace("_", "-")
            assistant_id = f"subagent:{normalized_name}"
        else:
            assistant_id = "subagent"

        # ⭐ 注入 Langfuse trace-attribute metadata，使 subagent trace 链到
        # 父 thread 并携带正确的 session/user id。
        inject_langfuse_metadata(
            run_config,
            thread_id=self.thread_id,          # 父 thread -> 同一 Langfuse Session
            user_id=self.user_id,              # 父 user
            assistant_id=assistant_id,         # subagent:<name>
            model_name=self.model_name,
            environment=os.environ.get("HELIX_ENV") or os.environ.get("ENVIRONMENT"),
            helix_trace_id=self.helix_trace_id,  # 请求级关联 id 透传
        )

        context: dict[str, Any] = {}
        if self.thread_id:
            run_config["configurable"] = {"thread_id": self.thread_id}
            context["thread_id"] = self.thread_id
        # 传播 guardrail 归因，使委派的 tool 调用按父 run 身份评估
        context["user_id"] = self.user_id
        context["user_role"] = self.user_role
        context["oauth_provider"] = self.oauth_provider
        context["oauth_id"] = self.oauth_id
        context["run_id"] = self.run_id
        if self.channel_user_id:
            context["channel_user_id"] = self.channel_user_id
        if self.helix_trace_id:
            context[HELIX_TRACE_METADATA_KEY] = self.helix_trace_id
        context["is_subagent"] = True

        # ...astream 驱动、step message 捕获、token_usage_records 快照省略
        async for chunk in agent.astream(state, config=run_config, context=context, stream_mode="values"):
            # ...cooperative cancellation + capture_new_step_messages 省略
            pass

        token_usage_records = collector.snapshot_records()
        # ...try_set_terminal(COMPLETED, token_usage_records=token_usage_records) 省略
```

## 3. subagent token 收集器（subagents/token_collector.py 完整）

```python
# core/helix/subagents/token_collector.py
"""在 subagent 内收集 LLM token 用量的 callback handler。

每次 subagent 执行创建自己的 collector。subagent 完成后，收集到的记录通过
RunJournal.record_external_llm_usage_records 转交给父 RunJournal。
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from langchain_core.callbacks import BaseCallbackHandler


class SubagentTokenCollector(BaseCallbackHandler):
    """在 subagent 内收集 LLM token 用量的轻量 callback handler。"""

    def __init__(self, caller: str):
        super().__init__()
        self.caller = caller
        self._records: list[dict[str, int | str | None]] = []
        self._counted_run_ids: set[str] = set()

    def on_llm_end(
        self,
        response: Any,
        *,
        run_id: Any,
        tags: list[str] | None = None,
        **kwargs: Any,
    ) -> None:
        rid = str(run_id)
        if rid in self._counted_run_ids:
            return

        for generation in response.generations:
            for gen in generation:
                if not hasattr(gen, "message"):
                    continue
                usage = getattr(gen.message, "usage_metadata", None)
                usage_dict = dict(usage) if usage else {}
                input_tk = usage_dict.get("input_tokens", 0) or 0
                output_tk = usage_dict.get("output_tokens", 0) or 0
                total_tk = usage_dict.get("total_tokens", 0) or 0
                if total_tk <= 0:
                    total_tk = input_tk + output_tk
                if total_tk <= 0:
                    continue
                # prompt-cache 命中（cache-aware 成本核算需要）
                details = usage_dict.get("input_token_details") or {}
                cache_read_tk = 0
                if isinstance(details, Mapping):
                    try:
                        cache_read_tk = max(int(details.get("cache_read") or 0), 0)
                    except (TypeError, ValueError):
                        cache_read_tk = 0
                # 捕获实际产生此响应的模型，使父 journal 能按真实模型分桶而非
                # lead agent 的 resolved model
                response_metadata = getattr(gen.message, "response_metadata", None) or {}
                model_name: str | None = None
                if isinstance(response_metadata, Mapping):
                    model_name = response_metadata.get("model_name") or response_metadata.get("model")
                self._counted_run_ids.add(rid)
                record: dict[str, int | str | None] = {
                    "source_run_id": rid,
                    "caller": self.caller,
                    "model_name": model_name,
                    "input_tokens": input_tk,
                    "output_tokens": output_tk,
                    "total_tokens": total_tk,
                }
                # 稀疏，与 journal 的 per-model 桶一致：仅当 provider 实际上报
                # cache 命中时才写该 key
                if cache_read_tk > 0:
                    record["cache_read_tokens"] = cache_read_tk
                self._records.append(record)
                return

    def snapshot_records(self) -> list[dict[str, int | str | None]]:
        """返回累积用量记录的副本。"""
        return list(self._records)
```
