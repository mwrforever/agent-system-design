# `task` 工具 + 状态契约全文：`tool_call_id=task_id` + additive `stop_reason`

> 真实实现（已按插件匿名化规则映射到自定结构 `helix.*`，去除项目字样）。原注释保留以保真，关键处补中文注解。本文件对应 `core/helix/tools/builtins/task_tool.py` 与 `core/helix/subagents/status_contract.py`。

## 1. `task` 工具全文

```python
# core/helix/tools/builtins/task_tool.py
"""委派任务给子代理的 task 工具。"""

import asyncio
import logging
import uuid
from dataclasses import replace
from typing import TYPE_CHECKING, Annotated, Any, cast

from langchain.tools import InjectedToolCallId, tool
from langchain_core.callbacks import BaseCallbackManager
from langchain_core.messages import ToolMessage
from langgraph.config import get_stream_writer
from langgraph.types import Command

from helix.config import get_app_config
from helix.runtime.user_context import resolve_runtime_user_id
from helix.sandbox.security import LOCAL_BASH_SUBAGENT_DISABLED_MESSAGE, is_host_bash_allowed
from helix.subagents import SubagentExecutor, get_available_subagent_names, get_subagent_config
from helix.subagents.config import resolve_subagent_model_name
from helix.subagents.executor import (
    SubagentStatus,
    cleanup_background_task,
    get_background_task_result,
    request_cancel_background_task,
)
from helix.subagents.status_contract import (
    SubagentStatusValue,
    SubagentStopReasonValue,
    format_subagent_result_message,
    make_subagent_additional_kwargs,
)
from helix.tools.types import Runtime
from helix.trace_context import HELIX_TRACE_METADATA_KEY, get_current_trace_id, normalize_trace_id

if TYPE_CHECKING:
    from helix.config.app_config import AppConfig

logger = logging.getLogger(__name__)

# 按 tool_call_id 缓存子代理 token 用量，让 TokenUsageMiddleware 能把它
# 回填到触发它的 AIMessage 的 usage_metadata。
_subagent_usage_cache: dict[str, dict[str, int]] = {}


def _token_usage_cache_enabled(app_config: "AppConfig | None") -> bool:
    if app_config is None:
        try:
            app_config = get_app_config()
        except FileNotFoundError:
            return False
    return bool(getattr(getattr(app_config, "token_usage", None), "enabled", False))


def _cache_subagent_usage(tool_call_id: str, usage: dict | None, *, enabled: bool = True) -> None:
    if enabled and usage:
        _subagent_usage_cache[tool_call_id] = usage


def pop_cached_subagent_usage(tool_call_id: str) -> dict | None:
    return _subagent_usage_cache.pop(tool_call_id, None)


def _is_subagent_terminal(result: Any) -> bool:
    """返回一个后台子代理结果是否可安全清理。"""
    return result.status in {SubagentStatus.COMPLETED, SubagentStatus.FAILED, SubagentStatus.CANCELLED, SubagentStatus.TIMED_OUT} or getattr(result, "completed_at", None) is not None


async def _await_subagent_terminal(task_id: str, max_polls: int) -> Any | None:
    """轮询直到后台子代理到达终态，或轮询次数耗尽。"""
    for _ in range(max_polls):
        result = get_background_task_result(task_id)
        if result is None:
            return None
        if _is_subagent_terminal(result):
            return result
        await asyncio.sleep(5)
    return None


async def _deferred_cleanup_subagent_task(task_id: str, trace_id: str, max_polls: int) -> None:
    """持续轮询一个已取消的子代理直到可安全移除。"""
    cleanup_poll_count = 0
    while True:
        result = get_background_task_result(task_id)
        if result is None:
            return
        if _is_subagent_terminal(result):
            cleanup_background_task(task_id)
            return
        if cleanup_poll_count >= max_polls:
            logger.warning(f"[trace={trace_id}] Deferred cleanup for task {task_id} timed out after {cleanup_poll_count} polls")
            return
        await asyncio.sleep(5)
        cleanup_poll_count += 1


def _log_cleanup_failure(cleanup_task: asyncio.Task[None], *, trace_id: str, task_id: str) -> None:
    if cleanup_task.cancelled():
        return

    exc = cleanup_task.exception()
    if exc is not None:
        logger.error(f"[trace={trace_id}] Deferred cleanup failed for task {task_id}: {exc}")


def _schedule_deferred_subagent_cleanup(task_id: str, trace_id: str, max_polls: int) -> None:
    logger.debug(f"[trace={trace_id}] Scheduling deferred cleanup for cancelled task {task_id}")
    cleanup_task = asyncio.create_task(_deferred_cleanup_subagent_task(task_id, trace_id, max_polls))
    cleanup_task.add_done_callback(lambda task: _log_cleanup_failure(task, trace_id=trace_id, task_id=task_id))


def _find_usage_recorder(runtime: Any) -> Any | None:
    """在 runtime config 中找带 ``record_external_llm_usage_records`` 的回调。

    LangChain 可能以三种形态传 ``config["callbacks"]``：

    - ``None``（无回调注册）：无 recorder。
    - 纯 ``list[BaseCallbackHandler]``：直接迭代。
    - ``BaseCallbackManager`` 实例（如 async 工具 run 上的 ``AsyncCallbackManager``）：
      manager 不可迭代，先解包 ``.handlers``。

    其他形态（如未包 list 的单个 handler）无法安全迭代；视作"无 recorder"。
    """
    if runtime is None:
        return None
    config = getattr(runtime, "config", None)
    if not isinstance(config, dict):
        return None
    callbacks = config.get("callbacks")
    if isinstance(callbacks, BaseCallbackManager):
        callbacks = callbacks.handlers
    if not callbacks:
        return None
    if not isinstance(callbacks, list):
        return None
    for cb in callbacks:
        if hasattr(cb, "record_external_llm_usage_records"):
            return cb
    return None


def _summarize_usage(records: list[dict] | None) -> dict | None:
    """把 token 用量记录汇总为 SSE 事件的紧凑 dict。"""
    if not records:
        return None
    return {
        "input_tokens": sum(r.get("input_tokens", 0) or 0 for r in records),
        "output_tokens": sum(r.get("output_tokens", 0) or 0 for r in records),
        "total_tokens": sum(r.get("total_tokens", 0) or 0 for r in records),
    }


def _report_subagent_usage(runtime: Any, result: Any) -> None:
    """把子代理 token 用量上报给父 RunJournal（若可用）。

    每个子代理任务必须只上报一次（由 usage_reported 守护）。
    """
    if getattr(result, "usage_reported", True):
        return
    records = getattr(result, "token_usage_records", None) or []
    if not records:
        return
    journal = _find_usage_recorder(runtime)
    if journal is None:
        logger.debug("No usage recorder found in runtime callbacks — subagent token usage not recorded")
        return
    try:
        journal.record_external_llm_usage_records(records)
        result.usage_reported = True
    except Exception:
        logger.warning("Failed to report subagent token usage", exc_info=True)


def _get_runtime_app_config(runtime: Any) -> "AppConfig | None":
    context = getattr(runtime, "context", None)
    if isinstance(context, dict):
        app_config = context.get("app_config")
        if app_config is not None:
            return cast("AppConfig", app_config)
    return None


def _merge_skill_allowlists(parent: list[str] | None, child: list[str] | None) -> list[str] | None:
    """返回在父策略下生效的子代理 skill 白名单。"""
    if parent is None:
        return child
    if child is None:
        return list(parent)

    parent_set = set(parent)
    return [skill for skill in child if skill in parent_set]


def _task_result_command(
    *,
    tool_call_id: str,
    status: SubagentStatusValue,
    result: str | None = None,
    error: str | None = None,
    stop_reason: SubagentStopReasonValue | None = None,
) -> Command:
    # ⭐ 文本里折入 (capped: ...) 提示；additional_kwargs 盖 subagent_status +
    # subagent_stop_reason（additive，旧消费者忽略后者）
    content, metadata_error = format_subagent_result_message(status, result=result, error=error, stop_reason=stop_reason)
    return Command(
        update={
            "messages": [
                ToolMessage(
                    content=content,
                    tool_call_id=tool_call_id,
                    name="task",
                    additional_kwargs=make_subagent_additional_kwargs(status, result=result, error=metadata_error, stop_reason=stop_reason),
                )
            ]
        }
    )


@tool("task", parse_docstring=True)
async def task_tool(
    runtime: Runtime,
    description: str,
    prompt: str,
    subagent_type: str,
    tool_call_id: Annotated[str, InjectedToolCallId],
) -> str | Command:
    """Delegate a task to a specialized subagent that runs in its own context.

    Subagents help you:
    - Preserve context by keeping exploration and implementation separate
    - Handle complex multi-step tasks autonomously
    - Execute commands or operations in isolated contexts

    Built-in subagent types:
    - **general-purpose**: A capable agent for complex, multi-step tasks that require
      both exploration and action. Use when the task requires complex reasoning,
      multiple dependent steps, or would benefit from isolated context.
    - **bash**: Command execution specialist for running bash commands. This is only
      available when host bash is explicitly allowed or when using an isolated shell
      sandbox such as `AioSandboxProvider`.

    Additional custom subagent types may be defined in config.yaml under
    `subagents.custom_agents`. Each custom type can have its own system prompt,
    tools, skills, model, and timeout configuration. If an unknown subagent_type
    is provided, the error message will list all available types.

    When to use this tool:
    - Complex tasks requiring multiple steps or tools
    - Tasks that produce verbose output
    - When you want to isolate context from the main conversation
    - Parallel research or exploration tasks

    When NOT to use this tool:
    - Simple, single-step operations (use tools directly)
    - Tasks requiring user interaction or clarification

    Args:
        description: A short (3-5 word) description of the task for logging/display. ALWAYS PROVIDE THIS PARAMETER FIRST.
        prompt: The task description for the subagent. Be specific and clear about what needs to be done. ALWAYS PROVIDE THIS PARAMETER SECOND.
        subagent_type: The type of subagent to use. ALWAYS PROVIDE THIS PARAMETER THIRD.
    """
    runtime_app_config = _get_runtime_app_config(runtime)
    cache_token_usage = _token_usage_cache_enabled(runtime_app_config)
    available_subagent_names = get_available_subagent_names(app_config=runtime_app_config) if runtime_app_config is not None else get_available_subagent_names()

    # 获取子代理配置
    config = get_subagent_config(subagent_type, app_config=runtime_app_config) if runtime_app_config is not None else get_subagent_config(subagent_type)
    if config is None:
        available = ", ".join(available_subagent_names)
        error = f"Unknown subagent type '{subagent_type}'. Available: {available}"
        return _task_result_command(
            tool_call_id=tool_call_id,
            status="failed",
            error=error,
        )
    if subagent_type == "bash":
        host_bash_allowed = is_host_bash_allowed(runtime_app_config) if runtime_app_config is not None else is_host_bash_allowed()
        if not host_bash_allowed:
            return _task_result_command(
                tool_call_id=tool_call_id,
                status="failed",
                error=LOCAL_BASH_SUBAGENT_DISABLED_MESSAGE,
            )

    # 构建 config 覆盖
    overrides: dict = {}

    # skill 由 SubagentExecutor 每 session 加载（对齐 Codex 模式：每个子代理
    # 按 config 加载自己的 skill，作为对话项注入），不再追加到 system_prompt。

    # 从 runtime 抽取父上下文
    sandbox_state = None
    thread_data = None
    thread_id = None
    parent_model = None
    trace_id = None
    user_id = None
    helix_trace_id = None
    metadata: dict = {}

    if runtime is not None:
        sandbox_state = runtime.state.get("sandbox")
        thread_data = runtime.state.get("thread_data")
        thread_id = runtime.context.get("thread_id") if runtime.context else None
        if thread_id is None:
            thread_id = runtime.config.get("configurable", {}).get("thread_id")

        # 尝试从 configurable 取父模型
        metadata = runtime.config.get("metadata", {})
        parent_model = metadata.get("model_name")

        # 获取或生成 trace_id（分布式追踪）
        trace_id = metadata.get("trace_id") or str(uuid.uuid4())[:8]

    # 获取 user_id（标准解析顺序）
    user_id = resolve_runtime_user_id(runtime)

    # 传播认证运行时上下文，让 GuardrailMiddleware 按与主代理相同的身份/归属
    # 评估委派的工具调用。来自 inject_authenticated_user_context 写入的服务端
    # context（run_id 由 run worker 写）；缺失时保持 None（如内部认证 run），
    # 让 guardrail 行为不变。否则角色感知策略会静默错误归属委派给子代理的
    # 工具调用（user_role=None）。
    parent_context = runtime.context if runtime is not None else None
    parent_context = parent_context if isinstance(parent_context, dict) else {}
    user_role = parent_context.get("user_role")
    oauth_provider = parent_context.get("oauth_provider")
    oauth_id = parent_context.get("oauth_id")
    run_id = parent_context.get("run_id")
    # IM 通道发送方身份：群聊一个线程跨多个发送方，委派的 bash 命令需要
    # 派发 turn 的 channel_user_id。
    channel_user_id = parent_context.get("channel_user_id")
    helix_trace_id = normalize_trace_id(parent_context.get(HELIX_TRACE_METADATA_KEY)) or normalize_trace_id(metadata.get(HELIX_TRACE_METADATA_KEY)) or get_current_trace_id()

    parent_available_skills = metadata.get("available_skills")
    if parent_available_skills is not None:
        overrides["skills"] = _merge_skill_allowlists(list(parent_available_skills), config.skills)

    if overrides:
        config = replace(config, **overrides)

    # 获取可用工具（排除 task 工具以防嵌套）
    # 懒导入避免循环依赖
    from helix.tools import get_available_tools

    # 继承父代理的 tool_groups，让子代理尊重相同限制
    parent_tool_groups = metadata.get("tool_groups")
    resolved_app_config = runtime_app_config
    if config.model == "inherit" and parent_model is None and resolved_app_config is None:
        resolved_app_config = get_app_config()
    effective_model = resolve_subagent_model_name(config, parent_model, app_config=resolved_app_config)

    # 子代理不应启用子代理工具（防递归嵌套）
    available_tools_kwargs = {
        "model_name": effective_model,
        "groups": parent_tool_groups,
        "subagent_enabled": False,
    }
    if resolved_app_config is not None:
        available_tools_kwargs["app_config"] = resolved_app_config
    tools = get_available_tools(**available_tools_kwargs)

    # 创建执行器
    executor_kwargs = {
        "config": config,
        "tools": tools,
        "parent_model": parent_model,
        "sandbox_state": sandbox_state,
        "thread_data": thread_data,
        "thread_id": thread_id,
        "trace_id": trace_id,
        "user_id": user_id,
        "user_role": user_role,
        "oauth_provider": oauth_provider,
        "oauth_id": oauth_id,
        "run_id": run_id,
        "channel_user_id": channel_user_id,
        "helix_trace_id": helix_trace_id,
    }
    if resolved_app_config is not None:
        executor_kwargs["app_config"] = resolved_app_config
    executor = SubagentExecutor(**executor_kwargs)

    # 后台执行（始终 async 以防阻塞）
    # ⭐ 用 tool_call_id 作 task_id，可追溯性更好
    task_id = executor.execute_async(prompt, task_id=tool_call_id)

    # 在后端轮询完成（免去 LLM 自己 poll）
    poll_count = 0
    last_status = None
    last_message_count = 0  # 已发送的 AI 消息数
    # 轮询超时：执行超时 + 60s 余量，每 5s 检查
    max_poll_count = (config.timeout_seconds + 60) // 5

    logger.info(f"[trace={trace_id}] Started background task {task_id} (subagent={subagent_type}, timeout={config.timeout_seconds}s, polling_limit={max_poll_count} polls)")

    writer = get_stream_writer()
    # 发送 Task Started 消息
    writer({"type": "task_started", "task_id": task_id, "description": description})

    try:
        while True:
            result = get_background_task_result(task_id)

            if result is None:
                logger.error(f"[trace={trace_id}] Task {task_id} not found in background tasks")
                writer({"type": "task_failed", "task_id": task_id, "error": "Task disappeared from background tasks"})
                cleanup_background_task(task_id)
                error = f"Task {task_id} disappeared from background tasks"
                return _task_result_command(
                    tool_call_id=tool_call_id,
                    status="failed",
                    error=error,
                )

            # 记录状态变化用于调试
            if result.status != last_status:
                logger.info(f"[trace={trace_id}] Task {task_id} status: {result.status.value}")
                last_status = result.status

            # 检查新 AI 消息并发送 task_running 事件
            ai_messages = result.ai_messages or []
            current_message_count = len(ai_messages)
            if current_message_count > last_message_count:
                # 为每条新消息发 task_running 事件
                for i in range(last_message_count, current_message_count):
                    message = ai_messages[i]
                    writer(
                        {
                            "type": "task_running",
                            "task_id": task_id,
                            "message": message,
                            "message_index": i + 1,  # 1-based 索引
                            "total_messages": current_message_count,
                        }
                    )
                    logger.info(f"[trace={trace_id}] Task {task_id} sent message #{i + 1}/{current_message_count}")
                last_message_count = current_message_count

            # 检查任务完成、失败或超时
            usage = _summarize_usage(getattr(result, "token_usage_records", None))
            if result.status == SubagentStatus.COMPLETED:
                _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
                _report_subagent_usage(runtime, result)
                writer({"type": "task_completed", "task_id": task_id, "result": result.result, "usage": usage})
                logger.info(f"[trace={trace_id}] Task {task_id} completed after {poll_count} polls")
                cleanup_background_task(task_id)
                # ⭐ stop_reason 携带护栏 cap（token_capped / turn_capped）当 run
                # 被提前结束但仍产出最终答案——成果像干净成功一样保留在 result_brief。
                return _task_result_command(
                    tool_call_id=tool_call_id,
                    status="completed",
                    result=result.result,
                    stop_reason=result.stop_reason,
                )
            elif result.status == SubagentStatus.FAILED:
                _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
                _report_subagent_usage(runtime, result)
                writer({"type": "task_failed", "task_id": task_id, "error": result.error, "usage": usage})
                logger.error(f"[trace={trace_id}] Task {task_id} failed: {result.error}")
                cleanup_background_task(task_id)
                # turn-capped run 无可用输出时 surface 为 failed + stop_reason=turn_capped；
                # cap 注记让主代理区分"超预算"与"子代理坏了"。
                return _task_result_command(
                    tool_call_id=tool_call_id,
                    status="failed",
                    error=result.error,
                    stop_reason=result.stop_reason,
                )
            elif result.status == SubagentStatus.CANCELLED:
                _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
                _report_subagent_usage(runtime, result)
                writer({"type": "task_cancelled", "task_id": task_id, "error": result.error, "usage": usage})
                logger.info(f"[trace={trace_id}] Task {task_id} cancelled: {result.error}")
                cleanup_background_task(task_id)
                return _task_result_command(
                    tool_call_id=tool_call_id,
                    status="cancelled",
                    error=result.error,
                )
            elif result.status == SubagentStatus.TIMED_OUT:
                _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
                _report_subagent_usage(runtime, result)
                writer({"type": "task_timed_out", "task_id": task_id, "error": result.error, "usage": usage})
                logger.warning(f"[trace={trace_id}] Task {task_id} timed out: {result.error}")
                cleanup_background_task(task_id)
                return _task_result_command(
                    tool_call_id=tool_call_id,
                    status="timed_out",
                    error=result.error,
                )

            # 仍在运行，等待下一次轮询
            await asyncio.sleep(5)
            poll_count += 1

            # 轮询超时安全网（以防线程池超时未生效）
            # 设为执行超时 + 60s 余量，5s 轮询间隔
            # 捕获后台任务卡住的边缘情况
            if poll_count > max_poll_count:
                timeout_minutes = config.timeout_seconds // 60
                logger.error(f"[trace={trace_id}] Task {task_id} polling timed out after {poll_count} polls (should have been caught by thread pool timeout)")
                _report_subagent_usage(runtime, result)
                usage = _summarize_usage(getattr(result, "token_usage_records", None))
                _cache_subagent_usage(tool_call_id, usage, enabled=cache_token_usage)
                writer({"type": "task_timed_out", "task_id": task_id, "usage": usage})
                # 任务可能仍在后台运行。信号协作式取消并调度延迟清理，待后台
                # 线程到达终态后从 _background_tasks 移除条目。
                request_cancel_background_task(task_id)
                _schedule_deferred_subagent_cleanup(task_id, trace_id, max_poll_count)
                message = f"Task polling timed out after {timeout_minutes} minutes. This may indicate the background task is stuck. Status: {result.status.value}"
                return _task_result_command(
                    tool_call_id=tool_call_id,
                    status="polling_timed_out",
                    error=message,
                )
    except asyncio.CancelledError:
        # 信号后台子代理线程协作式停止。
        request_cancel_background_task(task_id)

        # shielded 等待子代理到达终态，使最终 token 用量快照在父 worker
        # 持久化 get_completion_data() 之前上报给父 RunJournal。
        terminal_result = None
        try:
            terminal_result = await asyncio.shield(_await_subagent_terminal(task_id, max_poll_count))
        except asyncio.CancelledError:
            pass

        # 上报子代理收集到的用量（即使超时）。
        final_result = terminal_result or get_background_task_result(task_id)
        if final_result is not None:
            _report_subagent_usage(runtime, final_result)
        if final_result is not None and _is_subagent_terminal(final_result):
            cleanup_background_task(task_id)
        else:
            _schedule_deferred_subagent_cleanup(task_id, trace_id, max_poll_count)
        _subagent_usage_cache.pop(tool_call_id, None)
        raise
    except Exception:
        _subagent_usage_cache.pop(tool_call_id, None)
        raise
```

## 2. 状态契约全文（additive `stop_reason`）

```python
# core/helix/subagents/status_contract.py
"""后端↔前端的结构化子代理结果元数据契约。

``task`` 工具结果文本是模型可见的展示内容。运行时消费者读取
``ToolMessage.additional_kwargs`` 内的结构化事实：

- ``subagent_status``：``SUBAGENT_STATUS_VALUES`` 之一。
- ``subagent_stop_reason``（可选）：护栏 cap 提前结束 run 时，取
  ``SUBAGENT_STOP_REASON_VALUES`` 之一（``token_capped`` / ``turn_capped``
  / ``loop_capped``）。Additive（#3875 Phase 2）：被截断但仍产出最终答案
  的 run 保持 ``status=completed`` 并把 cap 带这里；无可用输出的被截断 run
  为 ``status=failed`` + ``stop_reason``。旧前端忽略未知字段。
- ``subagent_error``（可选）：后端记录的人类可读错误 blob。
- ``subagent_result_brief`` / ``subagent_result_sha256``（可选）：
  有界的完成结果元数据 + 完整结果的摘要。

共享 fixture ``contracts/subagent_status_contract.json`` 跨 Python 和
TypeScript 钉死枚举值。
"""

from __future__ import annotations

import hashlib
import re
from collections.abc import Mapping
from typing import Literal, NotRequired, TypedDict

SUBAGENT_STATUS_KEY = "subagent_status"
SUBAGENT_STOP_REASON_KEY = "subagent_stop_reason"
SUBAGENT_ERROR_KEY = "subagent_error"
SUBAGENT_RESULT_BRIEF_KEY = "subagent_result_brief"
SUBAGENT_RESULT_SHA256_KEY = "subagent_result_sha256"
SUBAGENT_METADATA_TEXT_MAX_CHARS = 2000

#: 生产者总是发 ``hashlib.sha256(...).hexdigest()`` —— 64 个小写十六进制字符。
#: 读取侧强制同样形态，损坏的中继值无法冒充摘要。
_SHA256_HEX_RE = re.compile(r"[0-9a-f]{64}")

SubagentStatusValue = Literal[
    "completed",
    "failed",
    "cancelled",
    "timed_out",
    "polling_timed_out",
]

#: ``subagent_status`` 可取的每个值。镜像共享 fixture 的 ``valid_status_values``
#: 数组；契约测试把它们互相钉死。被截断的 run 不获得自己的 status 值
#: （#3875 Phase 2）：产出输出的 cap 为 ``completed``，无输出的为 ``failed``，
#: 原因带在 additive ``subagent_stop_reason`` 字段上，旧消费者继续工作。
SUBAGENT_STATUS_VALUES: tuple[SubagentStatusValue, ...] = (
    "completed",
    "failed",
    "cancelled",
    "timed_out",
    "polling_timed_out",
)

#: 护栏 cap 为何提前结束 run。带在 additive ``subagent_stop_reason`` 字段，
#: 绝不作为 status 枚举值。
SubagentStopReasonValue = Literal["token_capped", "turn_capped", "loop_capped"]

SUBAGENT_STOP_REASON_VALUES: tuple[SubagentStopReasonValue, ...] = (
    "token_capped",
    "turn_capped",
    "loop_capped",
)

#: 触发 cap 时折入模型可见结果文本的人类可读标签，如
#: ``Task Succeeded (capped: token budget). Result: ...``。
_STOP_REASON_LABELS: dict[SubagentStopReasonValue, str] = {
    "token_capped": "token budget",
    "turn_capped": "turn budget",
    "loop_capped": "repeated tool-call loop",
}

#: 在 ``subagent_result_brief`` / ``subagent_result_sha256`` 中携带可恢复结果的
#: 状态。仅 ``completed``——被截断但产出可用部分成果的 run surface 为
#: ``completed``（+ ``stop_reason``），其成果在线上以与干净成功相同的方式
#: 保留。其他非 completed 状态只携带 ``subagent_error``。
_RESULT_BEARING_STATUSES: frozenset[SubagentStatusValue] = frozenset({"completed"})

#: 读取侧归一化：之前出现在已 checkpoint 的线程历史但已不再产生的 status 值。
#: ``max_turns_reached`` 由 Phase 1（#3949）发出，存在于持久化的
#: ``ToolMessage.additional_kwargs``；#3980 从生产者和契约 fixture 移除，但
#: 读取侧仍把它映射到 Phase 2 的 cap 等价物，使历史数据终态解析（cap 在
#: ``stop_reason`` 上）而非在 delegation ledger 中搁浅为 ``in_progress``。
#: 前端 ``subtask-result.ts`` 保持并行 deprecated alias 同理。
_LEGACY_STATUS_NORMALIZATION: dict[str, SubagentStopReasonValue] = {
    "max_turns_reached": "turn_capped",
}


class StructuredSubagentResult(TypedDict):
    status: SubagentStatusValue
    stop_reason: NotRequired[SubagentStopReasonValue]
    result_brief: NotRequired[str]
    result_sha256: NotRequired[str]
    error: NotRequired[str]


def _bound_metadata_text(text: str, cap: int = SUBAGENT_METADATA_TEXT_MAX_CHARS) -> str:
    cleaned = text.strip()
    if len(cleaned) <= cap:
        return cleaned
    marker = "\n...\n"
    if cap <= len(marker):
        return cleaned[:cap]
    head = cap * 2 // 3
    tail = cap - head - len(marker)
    if tail <= 0:
        return cleaned[:cap]
    return f"{cleaned[:head]}{marker}{cleaned[-tail:]}"


def make_subagent_additional_kwargs(
    status: SubagentStatusValue,
    *,
    result: str | None = None,
    error: str | None = None,
    stop_reason: SubagentStopReasonValue | None = None,
) -> dict[str, str]:
    """构建中间件盖戳的 ``additional_kwargs`` 载荷。

    error 为空时丢弃该字段，使 JSON 线上格式永不携带误导性的空
    ``subagent_error: ""``。``stop_reason`` 仅在护栏 cap 结束 run 时盖戳
    （见 :data:`SUBAGENT_STOP_REASON_VALUES`）。

    Raises:
        ValueError: ``status`` 不在 :data:`SUBAGENT_STATUS_VALUES`，或
            ``stop_reason`` 不在 :data:`SUBAGENT_STOP_REASON_VALUES`。不接受
            任意字符串：拼写错误会在生产者边界大声失败，而非作为缺失元数据
            静默泄漏给消费者。
    """
    if status not in SUBAGENT_STATUS_VALUES:
        raise ValueError(f"invalid subagent status {status!r}; expected one of {SUBAGENT_STATUS_VALUES}")
    if stop_reason is not None and stop_reason not in SUBAGENT_STOP_REASON_VALUES:
        raise ValueError(f"invalid subagent stop_reason {stop_reason!r}; expected one of {SUBAGENT_STOP_REASON_VALUES}")
    payload: dict[str, str] = {SUBAGENT_STATUS_KEY: status}
    if status in _RESULT_BEARING_STATUSES and isinstance(result, str) and result.strip():
        payload[SUBAGENT_RESULT_BRIEF_KEY] = _bound_metadata_text(result)
        payload[SUBAGENT_RESULT_SHA256_KEY] = hashlib.sha256(result.encode("utf-8")).hexdigest()
    # 仅 ``completed``（干净成功，或被截断但其部分成果保留的 run）抑制 error
    # blob；其他状态都携带它。
    if status != "completed" and isinstance(error, str) and error.strip():
        payload[SUBAGENT_ERROR_KEY] = _bound_metadata_text(error)
    if stop_reason is not None:
        payload[SUBAGENT_STOP_REASON_KEY] = stop_reason
    return payload


def format_subagent_result_message(
    status: SubagentStatusValue,
    *,
    result: str | None = None,
    error: str | None = None,
    stop_reason: SubagentStopReasonValue | None = None,
) -> tuple[str, str | None]:
    """返回模型可见的 task 内容 + 归一化的 metadata error。

    ``stop_reason`` 被设置时，一段简短的 ``(capped: ...)`` 注记折入文本，
    使主代理无需解析 metadata 即可看到 run 被护栏 cap 结束。产出可用成果的
    被截断 run 为 ``status=completed``（+ 部分结果）；无可用输出的为
    ``status=failed``。
    """
    result_text = "" if result is None else str(result)
    error_text = str(error).strip() if isinstance(error, str) else ""
    capped = _STOP_REASON_LABELS.get(stop_reason) if stop_reason is not None else None

    if status == "completed":
        if capped:
            return f"Task Succeeded (capped: {capped}). Result: {result_text}", None
        return f"Task Succeeded. Result: {result_text}", None

    if status == "cancelled":
        detail = error_text or "Task cancelled by user."
        if detail == "Task cancelled by user.":
            return detail, detail
        return f"Task cancelled by user. Error: {detail}", detail

    if status == "timed_out":
        detail = error_text or "Task timed out."
        if detail == "Task timed out.":
            return detail, detail
        return f"Task timed out. Error: {detail}", detail

    if status == "polling_timed_out":
        detail = error_text or "Task polling timed out."
        return detail, detail

    # ``failed`` —— 包括产出无可用输出的 turn-capped run
    # （``stop_reason=turn_capped``）：折入 cap 注记让主代理区分坏子代理与
    # 单纯耗尽 turn 预算的子代理。
    detail = error_text or "Task failed."
    if capped:
        if detail == "Task failed.":
            return f"Task failed (capped: {capped}).", detail
        return f"Task failed (capped: {capped}). Error: {detail}", detail
    if detail == "Task failed.":
        return detail, detail
    return f"Task failed. Error: {detail}", detail


def read_subagent_result_metadata(
    additional_kwargs: Mapping[str, object] | None,
) -> StructuredSubagentResult | None:
    """读取侧归一化（含 legacy ``max_turns_reached`` -> ``turn_capped``）。"""
    if not additional_kwargs:
        return None
    raw_status = additional_kwargs.get(SUBAGENT_STATUS_KEY)
    # legacy checkpointed 值（#3949）不再产生（#3980）但存在于持久化历史。
    # 有效性检查前归一化，使其终态解析而非返回 ``None``（会让 delegation
    # entry 搁浅为 ``in_progress``）。legacy ``max_turns_reached`` 携带恢复的
    # 部分成果，所以仍有 ``result_brief`` 的载荷映射到 Phase 2
    # ``completed + turn_capped`` 形态（部分成果线上保留）；无结果的映射到
    # ``failed + turn_capped``。
    legacy_stop_reason = _LEGACY_STATUS_NORMALIZATION.get(raw_status) if isinstance(raw_status, str) else None
    if legacy_stop_reason is not None:
        raw_result_brief = additional_kwargs.get(SUBAGENT_RESULT_BRIEF_KEY)
        status = "completed" if (isinstance(raw_result_brief, str) and raw_result_brief.strip()) else "failed"
    elif raw_status in SUBAGENT_STATUS_VALUES:
        status = raw_status
    else:
        return None
    payload: StructuredSubagentResult = {"status": status}
    raw_result = additional_kwargs.get(SUBAGENT_RESULT_BRIEF_KEY)
    raw_hash = additional_kwargs.get(SUBAGENT_RESULT_SHA256_KEY)
    raw_error = additional_kwargs.get(SUBAGENT_ERROR_KEY)
    if status in _RESULT_BEARING_STATUSES and isinstance(raw_result, str) and raw_result.strip():
        payload["result_brief"] = _bound_metadata_text(raw_result)
        if isinstance(raw_hash, str) and _SHA256_HEX_RE.fullmatch(raw_hash):
            payload["result_sha256"] = raw_hash
    if status != "completed" and isinstance(raw_error, str) and raw_error.strip():
        payload["error"] = _bound_metadata_text(raw_error)
    # 线上显式 stop_reason 胜出；否则用合成的 legacy 原因。
    raw_stop_reason = additional_kwargs.get(SUBAGENT_STOP_REASON_KEY)
    if isinstance(raw_stop_reason, str) and raw_stop_reason in SUBAGENT_STOP_REASON_VALUES:
        payload["stop_reason"] = raw_stop_reason
    elif legacy_stop_reason is not None:
        payload["stop_reason"] = legacy_stop_reason
    return payload
```

## 关键不变量（从源码提炼）

1. **`tool_call_id` 一以贯之**：`execute_async(prompt, task_id=tool_call_id)` → `_subagent_usage_cache[tool_call_id]` → 终端 `ToolMessage(tool_call_id=tool_call_id)`，单 id 串起用量、状态、trace。
2. **后端代模型轮询**：模型不自己 poll；`task_tool` 内 5s 轮询，`task_running` 事件增量推送（`message_index` 1-based）。
3. **additive 冒泡**：`SubagentResult.stop_reason` → `_task_result_command(stop_reason=...)` → `format_subagent_result_message`（文本折 `(capped: ...)`）+ `make_subagent_additional_kwargs`（盖 `subagent_stop_reason` 键）。
4. **取消传播 `asyncio.CancelledError`**：`request_cancel_background_task` → `shield(_await_subagent_terminal)` 等终态上报 usage → 延迟清理。
5. **legacy 归一（读侧）**：`max_turns_reached` → `turn_capped`，有 `result_brief` 映射 `completed`，否则 `failed`，使持久化历史不会搁浅为 `in_progress`。
