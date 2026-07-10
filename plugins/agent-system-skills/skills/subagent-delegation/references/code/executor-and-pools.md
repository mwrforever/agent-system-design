# 执行器全文：scheduler 线程池 + 持久 isolated event loop + `_aexecute`

> 真实实现（已按插件匿名化规则映射到自定结构 `helix.*`，去除项目字样）。原注释保留以保真，关键处补中文注解。本文件对应 `core/helix/subagents/executor.py`。

```python
# core/helix/subagents/executor.py
"""Subagent execution engine."""

import asyncio
import atexit
import logging
import os
import threading
import uuid
from collections.abc import Callable, Coroutine
from concurrent.futures import Future, ThreadPoolExecutor
from concurrent.futures import TimeoutError as FuturesTimeoutError
from contextvars import Context, copy_context
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import TYPE_CHECKING, Any

from langchain.agents import create_agent
from langchain.tools import BaseTool
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_core.runnables import RunnableConfig
from langgraph.errors import GraphRecursionError

from helix.agents.thread_state import SandboxState, ThreadDataState, ThreadState
from helix.config import get_app_config
from helix.config.app_config import AppConfig
from helix.models import create_chat_model
from helix.skills.tool_policy import filter_tools_by_skill_allowed_tools
from helix.skills.types import Skill
from helix.subagents.config import SubagentConfig, resolve_subagent_model_name
from helix.subagents.step_events import capture_new_step_messages
from helix.subagents.token_collector import SubagentTokenCollector
from helix.trace_context import HELIX_TRACE_METADATA_KEY
from helix.tracing import build_tracing_callbacks, inject_langfuse_metadata
from helix.utils.messages import message_content_to_text

if TYPE_CHECKING:
    # 懒导入 tool_search 会触发 tools/builtins/__init__ -> task_tool ->
    # `from helix.subagents import SubagentExecutor`，重新进入仍在初始化的本包；
    # 这里仅类型标注，保持精确而不触发循环。
    from helix.tools.builtins.tool_search import DeferredToolSetup

logger = logging.getLogger(__name__)


_previous_shutdown_isolated_subagent_loop = globals().get("_shutdown_isolated_subagent_loop")
if callable(_previous_shutdown_isolated_subagent_loop):
    atexit.unregister(_previous_shutdown_isolated_subagent_loop)
    _previous_shutdown_isolated_subagent_loop()


class SubagentStatus(Enum):
    """子代理执行状态。"""

    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    TIMED_OUT = "timed_out"

    @property
    def is_terminal(self) -> bool:
        return self in {
            type(self).COMPLETED,
            type(self).FAILED,
            type(self).CANCELLED,
            type(self).TIMED_OUT,
        }


@dataclass
class SubagentResult:
    """单次子代理执行的可观察容器。

    Attributes:
        task_id: 本次执行的唯一标识（由 task() 工具的 tool_call_id 复用）。
        trace_id: 分布式追踪 id（串联父子日志）。
        status: 当前执行状态。
        result: 最终结果文本（completed 时）。
        error: 错误消息（failed 时）。
        stop_reason: 护栏 cap 提前结束的原因（``token_capped`` / ``turn_capped``
            / ``loop_capped``），干净运行为 ``None``。被截断的 run 仍保持正常
            status——产出可用输出时为 ``completed``（部分成果保留在 result 上），
            否则为 ``failed``——并把 cap 原因带在这里，让主代理能区分"完成"与"被截断"。
        started_at / completed_at: 起止时间。
        ai_messages: 执行期间产生的完整 AI 消息（dict 形态）。
    """

    task_id: str
    trace_id: str
    status: SubagentStatus
    result: str | None = None
    error: str | None = None
    stop_reason: str | None = None
    started_at: datetime | None = None
    completed_at: datetime | None = None
    ai_messages: list[dict[str, Any]] | None = None
    token_usage_records: list[dict[str, int | str | None]] = field(default_factory=list)
    usage_reported: bool = False
    cancel_event: threading.Event = field(default_factory=threading.Event, repr=False)
    _state_lock: threading.Lock = field(default_factory=threading.Lock, init=False, repr=False)

    def __post_init__(self):
        if self.ai_messages is None:
            self.ai_messages = []

    def try_set_terminal(
        self,
        status: SubagentStatus,
        *,
        result: str | None = None,
        error: str | None = None,
        stop_reason: str | None = None,
        completed_at: datetime | None = None,
        ai_messages: list[dict[str, Any]] | None = None,
        token_usage_records: list[dict[str, int | str | None]] | None = None,
    ) -> bool:
        """单次终态写入（首个 terminal 胜出，晚到写入静默丢弃）。

        后台 timeout / 取消 / 执行 worker 会竞态写终态——首个 terminal 转换胜出，
        晚到的 terminal 写入不得改变 status 或载荷字段，避免账目被覆盖。
        """
        if not status.is_terminal:
            raise ValueError(f"Status {status} is not terminal")

        with self._state_lock:
            if self.status.is_terminal:
                return False

            if result is not None:
                self.result = result
            if error is not None:
                self.error = error
            if stop_reason is not None:
                self.stop_reason = stop_reason
            if ai_messages is not None:
                self.ai_messages = ai_messages
            if token_usage_records is not None:
                self.token_usage_records = token_usage_records
            self.completed_at = completed_at or datetime.now()
            self.status = status
            return True


def _extract_final_result(final_state: Any, *, trace_id: str, name: str) -> str:
    """从 streamed 子代理 state 抽出人类可读的最终结果字符串。

    找最后一条 ``AIMessage``，用共享助手 :func:`message_content_to_text` 字符串化
    其 content；无 AIMessage 时退化到最后一条任意类型消息。无任何内容时返回
    哨兵 ``"No response generated"``，调用方绝不会把"缺结果"与"合法空结果"混淆。

    正常完成路径与 max_turns 路径共用：``recursion_limit`` 中断 run 时，
    ``final_state`` 持有限制触发前最后一个 streamed chunk，这里恢复部分成果。
    """
    if final_state is None:
        logger.warning(f"[trace={trace_id}] Subagent {name} no final state")
        return "No response generated"

    messages = final_state.get("messages", [])
    logger.info(f"[trace={trace_id}] Subagent {name} final messages count: {len(messages)}")

    last_ai_message = None
    for msg in reversed(messages):
        if isinstance(msg, AIMessage):
            last_ai_message = msg
            break

    if last_ai_message is not None:
        text = message_content_to_text(last_ai_message.content)
        return text if text else "No response generated"

    if messages:
        last_message = messages[-1]
        logger.warning(f"[trace={trace_id}] Subagent {name} no AIMessage found, using last message: {type(last_message)}")
        raw_content = last_message.content if hasattr(last_message, "content") else str(last_message)
        text = message_content_to_text(raw_content)
        return text if text else "No response generated"

    logger.warning(f"[trace={trace_id}] Subagent {name} no messages in final state")
    return "No response generated"


# 进程级后台任务结果存储
_background_tasks: dict[str, SubagentResult] = {}
_background_tasks_lock = threading.Lock()

# scheduler 线程池：后台任务的调度与编排（唯一的 ThreadPoolExecutor）
_scheduler_pool = ThreadPoolExecutor(max_workers=3, thread_name_prefix="subagent-scheduler-")

# 持久 isolated event loop：从已运行父 loop 触发的子代理执行在此跑。
# 复用一个长生命周期 loop，避免每次执行新建 loop 又关闭绑定其上的 async 资源。
_isolated_subagent_loop: asyncio.AbstractEventLoop | None = None
_isolated_subagent_loop_thread: threading.Thread | None = None
_isolated_subagent_loop_started: threading.Event | None = None
_isolated_subagent_loop_lock = threading.Lock()


def _run_isolated_subagent_loop(
    loop: asyncio.AbstractEventLoop,
    started_event: threading.Event,
) -> None:
    """在专用 daemon 线程内跑持久 isolated 子代理 loop。"""
    asyncio.set_event_loop(loop)
    loop.call_soon(started_event.set)
    try:
        loop.run_forever()
    finally:
        started_event.clear()


def _shutdown_isolated_subagent_loop() -> None:
    """停止并关闭持久 isolated 子代理 loop。"""
    global _isolated_subagent_loop, _isolated_subagent_loop_thread, _isolated_subagent_loop_started

    with _isolated_subagent_loop_lock:
        loop = _isolated_subagent_loop
        thread = _isolated_subagent_loop_thread
        _isolated_subagent_loop = None
        _isolated_subagent_loop_thread = None
        _isolated_subagent_loop_started = None

    if loop is None:
        return

    if loop.is_running():
        loop.call_soon_threadsafe(loop.stop)

    if thread is not None and thread.is_alive() and thread is not threading.current_thread():
        thread.join(timeout=1)

    thread_stopped = thread is None or not thread.is_alive()
    loop_stopped = not loop.is_running()

    if not loop.is_closed():
        if thread_stopped and loop_stopped:
            loop.close()
        else:
            logger.warning(
                "Skipping close of isolated subagent loop because shutdown did not complete within timeout (thread_alive=%s, loop_running=%s)",
                thread is not None and thread.is_alive(),
                loop.is_running(),
            )


atexit.register(_shutdown_isolated_subagent_loop)


def _get_isolated_subagent_loop() -> asyncio.AbstractEventLoop:
    """返回 isolated 子代理执行用的持久 event loop（懒启动）。"""
    global _isolated_subagent_loop, _isolated_subagent_loop_thread, _isolated_subagent_loop_started
    with _isolated_subagent_loop_lock:
        thread_is_alive = _isolated_subagent_loop_thread is not None and _isolated_subagent_loop_thread.is_alive()
        loop_is_usable = _isolated_subagent_loop is not None and not _isolated_subagent_loop.is_closed() and _isolated_subagent_loop.is_running() and thread_is_alive

        if not loop_is_usable:
            loop = asyncio.new_event_loop()
            started_event = threading.Event()
            thread = threading.Thread(
                target=_run_isolated_subagent_loop,
                args=(loop, started_event),
                name="subagent-persistent-loop",
                daemon=True,
            )
            thread.start()
            if not started_event.wait(timeout=5):
                loop.call_soon_threadsafe(loop.stop)
                thread.join(timeout=1)
                loop.close()
                raise RuntimeError("Timed out starting isolated subagent event loop")
            _isolated_subagent_loop = loop
            _isolated_subagent_loop_thread = thread
            _isolated_subagent_loop_started = started_event

        if _isolated_subagent_loop is None:
            raise RuntimeError("Isolated subagent event loop is not initialized")
        return _isolated_subagent_loop


def _submit_to_isolated_loop_in_context(
    context: Context,
    coro_factory: Callable[[], Coroutine[Any, Any, SubagentResult]],
) -> Future[SubagentResult]:
    """把协程投递到 isolated loop，同时保留 ContextVar 状态。

    ⭐ 跨线程 marshal 核心：在父 ContextVar 快照（context）内执行
    run_coroutine_threadsafe，确保子协程在 isolated loop 上恢复时
    user_id 等 ContextVar 不丢。
    """
    return context.run(
        lambda: asyncio.run_coroutine_threadsafe(
            coro_factory(),
            _get_isolated_subagent_loop(),
        )
    )


def _filter_tools(
    all_tools: list[BaseTool],
    allowed: list[str] | None,
    disallowed: list[str] | None,
) -> list[BaseTool]:
    """按子代理配置过滤工具集（白名单 + 黑名单）。"""
    filtered = all_tools

    # 白名单
    if allowed is not None:
        allowed_set = set(allowed)
        filtered = [t for t in filtered if t.name in allowed_set]

    # 黑名单
    if disallowed is not None:
        disallowed_set = set(disallowed)
        filtered = [t for t in filtered if t.name not in disallowed_set]

    return filtered


class SubagentExecutor:
    """子代理执行器。"""

    def __init__(
        self,
        config: SubagentConfig,
        tools: list[BaseTool],
        app_config: AppConfig | None = None,
        parent_model: str | None = None,
        sandbox_state: SandboxState | None = None,
        thread_data: ThreadDataState | None = None,
        thread_id: str | None = None,
        trace_id: str | None = None,
        user_id: str | None = None,
        user_role: str | None = None,
        oauth_provider: str | None = None,
        oauth_id: str | None = None,
        run_id: str | None = None,
        channel_user_id: str | None = None,
        helix_trace_id: str | None = None,
    ):
        """初始化执行器。

        Args:
            config: 子代理配置。
            tools: 全量可用工具（将被过滤）。
            app_config: 已解析的 AppConfig。None 时 ``_create_agent`` 回退到
                ``get_app_config()``（与主代理工厂一致）。
            parent_model: 父代理模型名（用于继承）。
            sandbox_state: 父代理沙箱状态。
            thread_data: 父代理线程数据。
            thread_id: 沙箱操作用的线程 id。
            trace_id: 父追踪 id（分布式追踪）。
            user_id: 从父工具运行时上下文捕获的 user_id（tracing 层 None 时
                回退 DEFAULT_USER_ID）。
            user_role: 认证用户角色——传播给子代理的 GuardrailMiddleware，
                让委派的工具调用按角色感知策略评估。
            oauth_provider: 外部身份提供方（SSO 认证时）。
            oauth_id: 外部身份提供方的主主体 id。
            run_id: 父 run id，让委派的 guardrail 决策归属到与主代理相同的 run。
            channel_user_id: IM 通道发送方身份（task_tool 派发时捕获）。
            helix_trace_id: 请求级关联 id，从父 run 传播用于 Langfuse metadata 关联。
        """
        self.config = config
        self.app_config = app_config
        self.parent_model = parent_model
        # 仅在无需加载 config.yaml 时及早解析；否则延迟到 _create_agent
        if config.model != "inherit" or parent_model is not None or app_config is not None:
            self.model_name: str | None = resolve_subagent_model_name(config, parent_model, app_config=app_config)
        else:
            self.model_name = None
        self.sandbox_state = sandbox_state
        self.thread_data = thread_data
        self.thread_id = thread_id
        # 顶层调用未提供时生成 trace_id
        self.trace_id = trace_id or str(uuid.uuid4())[:8]
        self.user_id = user_id
        # 父运行时上下文传播的 guardrail 归属字段
        self.user_role = user_role
        self.oauth_provider = oauth_provider
        self.oauth_id = oauth_id
        self.run_id = run_id
        # IM 通道发送方身份：群聊一个线程跨多个发送方，委派的 bash 命令必须
        # 导出派发 turn 的 id，而不是 none。
        self.channel_user_id = channel_user_id
        self.helix_trace_id = helix_trace_id

        self._base_tools = _filter_tools(
            tools,
            config.tools,
            config.disallowed_tools,
        )
        self.tools = self._base_tools
        # 暴露 ``consume_stop_reason`` 的护栏中间件（当前为
        # ``TokenBudgetMiddleware`` 与 ``LoopDetectionMiddleware``），在
        # ``_create_agent`` 中捕获，``_aexecute`` 在 run 后读取以暴露哪个 cap
        # 触发了（token_capped / loop_capped）（#3875 Phase 2）。收集为 list——
        # 每个护栏都要查，而非只查第一个——因为 v2 契约宣称不止一个 cap 原因。
        self._stop_reason_middlewares: list[Any] = []

        logger.info(f"[trace={self.trace_id}] SubagentExecutor initialized: {config.name} with {len(self.tools)} tools")

    def _create_agent(self, tools: list[BaseTool] | None = None, *, deferred_setup: "DeferredToolSetup | None" = None):
        """创建 agent 实例（checkpointer=False，一次性）。

        ``deferred_setup``（在 ``_build_initial_state`` 中组装）携带延迟 MCP 工具
        名 + catalog hash，让子代理获得与主代理相同的 DeferredToolFilterMiddleware。
        ``None`` 为 no-op。
        """
        app_config = self.app_config or get_app_config()
        if self.model_name is None:
            self.model_name = resolve_subagent_model_name(self.config, self.parent_model, app_config=app_config)
        model = create_chat_model(name=self.model_name, thinking_enabled=False, app_config=app_config, attach_tracing=False)

        from helix.agents.middlewares.tool_error_handling_middleware import build_subagent_runtime_middlewares

        # 复用主代理的中间件组合。``agent_name`` 让 builder 解析 per-agent
        # token_budget 覆盖。
        middlewares = build_subagent_runtime_middlewares(
            app_config=app_config,
            model_name=self.model_name,
            lazy_init=True,
            deferred_setup=deferred_setup,
            agent_name=self.config.name,
        )
        # ⭐ 收集所有暴露 ``consume_stop_reason`` 的护栏中间件
        # （TokenBudgetMiddleware、LoopDetectionMiddleware），让 _aexecute 在
        # run 后读取以暴露哪个 cap 触发了。duck-typed（``hasattr``）所以本文件
        # 无需 import 中间件类；list（非 ``next(...)``）确保每个护栏都被查，
        # 后续新增的自动被纳入。
        self._stop_reason_middlewares = [m for m in middlewares if hasattr(m, "consume_stop_reason")]

        # system_prompt 放进初始 state messages（见 _build_initial_state），
        # 避免某些 LLM API 不支持的多 SystemMessage。
        return create_agent(
            model=model,
            tools=tools if tools is not None else self.tools,
            middleware=middlewares,
            system_prompt=None,
            state_schema=ThreadState,
            checkpointer=False,
        )

    def _consume_guard_stop_reason(self) -> str | None:
        """pop 并返回上次 run 期间被护栏 cap 设置的 stop 原因。

        逐个检查暴露 ``consume_stop_reason`` 的护栏中间件（``_create_agent``
        中收集），返回首个非 ``None`` 原因——``"token_capped"``（token 预算硬停）、
        ``"loop_capped"``（循环检测强制停止），否则 ``None``。每个护栏的 cap
        不抛异常（run 仍以最终答案完成），所以这是 executor 得知某次完成实际被
        截断的方式。通常每次 run 至多一个护栏触发，但检查全部保持契约的完整
        cap 词汇可达。
        """
        for mw in self._stop_reason_middlewares:
            reason = mw.consume_stop_reason(self.run_id)
            if reason is not None:
                return reason
        return None

    async def _load_skills(self) -> list[Skill]:
        """按 config.skills 加载启用的 skill 元数据。"""
        if self.config.skills is not None and len(self.config.skills) == 0:
            logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} skills=[] — skipping skill loading")
            return []

        try:
            from helix.skills.storage import get_or_new_skill_storage

            storage_kwargs = {"app_config": self.app_config} if self.app_config is not None else {}
            storage = await asyncio.to_thread(get_or_new_skill_storage, **storage_kwargs)
            # asyncio.to_thread 避免阻塞 event loop（LangGraph ASGI 要求）
            all_skills = await asyncio.to_thread(storage.load_skills, enabled_only=True)
            logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} loaded {len(all_skills)} enabled skills from disk")
        except Exception:
            logger.exception(f"[trace={self.trace_id}] Failed to load skills for subagent {self.config.name}")
            raise

        if not all_skills:
            logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} no enabled skills found")
            return []

        # 按 config.skills 白名单过滤
        if self.config.skills is not None:
            allowed = set(self.config.skills)
            return [s for s in all_skills if s.name in allowed]
        return all_skills

    def _apply_skill_allowed_tools(self, skills: list[Skill]) -> list[BaseTool]:
        return filter_tools_by_skill_allowed_tools(self._base_tools, skills)

    async def _load_skill_messages(self, skills: list[Skill]) -> list[SystemMessage]:
        """把 skill 内容作为对话项（SystemMessage）注入。

        每个 subagent 每 session 加载自己的 skill，作为对话项（developer message）
        注入，而非 system prompt 文本。config.skills 白名单控制加载哪些：
        - None: 加载所有启用 skill
        - []: 不加载
        - ["skill-a", "skill-b"]: 只加载这些
        """
        if not skills:
            return []

        messages = []
        for skill in skills:
            try:
                content = await asyncio.to_thread(skill.skill_file.read_text, encoding="utf-8")
                content = content.strip()
                if content:
                    messages.append(SystemMessage(content=f'<skill name="{skill.name}">\n{content}\n</skill>'))
                    logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} loaded skill: {skill.name}")
            except Exception:
                logger.debug(f"[trace={self.trace_id}] Failed to read skill {skill.name}", exc_info=True)

        return messages

    async def _build_initial_state(self, task: str) -> tuple[dict[str, Any], list[BaseTool], "DeferredToolSetup"]:
        """构造 agent 执行的初始 state。

        合并 system_prompt + skill 内容 + deferred 段到单条 SystemMessage（某些
        LLM API 拒收多条 SystemMessage），追加 HumanMessage(task)，并透传父
        sandbox / thread_data。
        """
        # 懒导入：见模块顶部 TYPE_CHECKING 注释——导入 tool_search 会运行
        # tools/builtins/__init__，在本包自身初始化期间重入。
        from helix.tools.builtins.tool_search import assemble_deferred_tools, get_deferred_tools_prompt_section

        # skill 作为对话项加载（Codex 模式）
        skills = await self._load_skills()
        filtered_tools = self._apply_skill_allowed_tools(skills)
        # 策略过滤之后（fail-closed）再组装延迟 tool_search，镜像主代理路径，
        # 让子代理不再绑定全量 MCP schema。生成的 tool_search 助手刻意不
        # 受子代理名级 allow/deny（config.tools / disallowed_tools）约束：
        # 它的 catalog 已由过滤后的列表构建，绝不可能暴露策略拒绝的工具。
        enabled = (self.app_config or get_app_config()).tool_search.enabled
        final_tools, deferred_setup = assemble_deferred_tools(filtered_tools, enabled=enabled)
        skill_messages = await self._load_skill_messages(skills)

        # 把 system_prompt 和 skill 合并为单条 SystemMessage。
        # 某些 LLM API 以 "System message must be at the beginning." 拒收多条。
        system_parts: list[str] = []
        if self.config.system_prompt:
            system_parts.append(self.config.system_prompt)
        for skill_msg in skill_messages:
            system_parts.append(skill_msg.content)
        # 在 prompt 中列出延迟 MCP 工具名；其 schema 在 tool_search 提升前
        # 保持保留。空集 -> "" -> 不追加任何内容。
        deferred_section = get_deferred_tools_prompt_section(deferred_names=deferred_setup.deferred_names)
        if deferred_section:
            system_parts.append(deferred_section)

        messages: list[Any] = []
        if system_parts:
            messages.append(SystemMessage(content="\n\n".join(system_parts)))

        # 然后是真正的任务
        messages.append(HumanMessage(content=task))

        state: dict[str, Any] = {
            "messages": messages,
        }

        # 透传父沙箱与线程数据
        if self.sandbox_state is not None:
            state["sandbox"] = self.sandbox_state
        if self.thread_data is not None:
            state["thread_data"] = self.thread_data

        return state, final_tools, deferred_setup

    async def _aexecute(self, task: str, result_holder: SubagentResult | None = None) -> SubagentResult:
        """异步执行任务（真正的协程主体，跑在 isolated loop 上）。

        Args:
            task: 子代理任务描述。
            result_holder: 可选的预创建结果对象（异步执行时实时更新）。

        Returns:
            带执行结果的 SubagentResult。
        """
        if result_holder is not None:
            # 使用提供的结果持有者（异步执行带实时更新）
            result = result_holder
        else:
            # 同步执行创建新结果
            task_id = str(uuid.uuid4())[:8]
            result = SubagentResult(
                task_id=task_id,
                trace_id=self.trace_id,
                status=SubagentStatus.RUNNING,
                started_at=datetime.now(),
            )
        ai_messages = result.ai_messages
        if ai_messages is None:
            ai_messages = []
            result.ai_messages = ai_messages
        # streamed AI 消息的 O(1) 去重。``stream_mode="values"`` 每个 super-step
        # 重新 yield 全 state，所以同一条尾部消息每个 chunk 都被重新检查；
        # id-keyed set 保持该检查 O(1)，而非重扫 append-only ``ai_messages``
        # 列表（每 chunk O(n) -> 整个 run O(n²)，max_turns=150 的深度研究
        # 子代理会达到该规模）。
        seen_message_ids: set[str] = {mid for msg in ai_messages if (mid := msg.get("id"))}
        # append-only 消息历史游标，每个 ``values`` chunk 只重扫新增尾部
        # （见 capture_new_step_messages）。
        processed_message_count = 0

        collector: SubagentTokenCollector | None = None
        try:
            state, final_tools, deferred_setup = await self._build_initial_state(task)
            agent = self._create_agent(final_tools, deferred_setup=deferred_setup)

            # 子代理 LLM 调用的 token 收集器
            collector_caller = f"subagent:{self.config.name}"
            collector = SubagentTokenCollector(caller=collector_caller)

            # 带 thread_id（沙箱访问）和 recursion_limit 的 config
            run_config: RunnableConfig = {
                "recursion_limit": self.config.max_turns,
                "callbacks": [collector],
                "tags": [collector_caller],
            }

            # 在 graph 层注入 tracing callback，使单次子代理 run 产生一个 trace，
            # 所有 node / LLM / tool 调用作为子 span。镜像主代理模式：graph 层
            # tracing 配合模型层 attach_tracing=False 避免双重计数。
            tracing_callbacks = build_tracing_callbacks()
            if tracing_callbacks:
                existing_callbacks = list(run_config.get("callbacks") or [])
                run_config["callbacks"] = [*existing_callbacks, *tracing_callbacks]

            # 归一子代理名用于 tracing（与主代理命名形态一致：小写、仅连字符）。
            # 内联因无共享助手——runtime/runs/naming.py 只处理主代理 run。
            if self.config.name:
                normalized_name = self.config.name.strip().lower().replace("_", "-")
                assistant_id = f"subagent:{normalized_name}"
            else:
                assistant_id = "subagent"

            # 注入 Langfuse trace-attribute metadata，让子代理 trace 关联到
            # 父 thread 并携带正确的 session/user id。
            inject_langfuse_metadata(
                run_config,
                thread_id=self.thread_id,
                user_id=self.user_id,
                assistant_id=assistant_id,
                model_name=self.model_name,
                environment=os.environ.get("HELIX_ENV") or os.environ.get("ENVIRONMENT"),
                helix_trace_id=self.helix_trace_id,
            )

            context: dict[str, Any] = {}
            if self.thread_id:
                run_config["configurable"] = {"thread_id": self.thread_id}
                context["thread_id"] = self.thread_id
            if self.app_config is not None:
                context["app_config"] = self.app_config
            # 传播 guardrail 归属，让委派的工具调用按父 run 身份评估
            # （角色感知策略、审计）。user_id 复用解析的 tracing id；每条
            # 认证/IM 路径上这等于父 context 值。
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

            logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} starting async execution with max_turns={self.config.max_turns}")

            # 用 stream 而非 invoke 获取实时更新
            final_state = None

            # 预检：streaming 开始前已取消则立即退出
            if result.cancel_event.is_set():
                logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} cancelled before streaming")
                result.try_set_terminal(
                    SubagentStatus.CANCELLED,
                    error="Cancelled by user",
                    token_usage_records=collector.snapshot_records(),
                )
                return result

            async for chunk in agent.astream(state, config=run_config, context=context, stream_mode="values"):  # type: ignore[arg-type]
                # 协作式取消：检查父是否请求停止。
                # 注意：取消只在 astream 迭代边界被检测，单次迭代内的长时
                # 工具调用不会被中断，直到下一个 chunk yield。
                if result.cancel_event.is_set():
                    logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} cancelled by parent")
                    result.try_set_terminal(
                        SubagentStatus.CANCELLED,
                        error="Cancelled by user",
                        token_usage_records=collector.snapshot_records(),
                    )
                    return result

                final_state = chunk

                # 捕获自上一 chunk 起追加的每一步消息（助手 turn 和工具输出）。
                # 单个 super-step 在模型一 turn 发多个 tool_call 时会追加多条
                # ToolMessage，所以只捕获 messages[-1] 会丢掉除最后一条以外
                # 的所有输出（#3779）。去重/序列化在 capture_step_message 内。
                messages = chunk.get("messages", [])
                previous_count = len(ai_messages)
                processed_message_count = capture_new_step_messages(messages, ai_messages, seen_message_ids, processed_message_count)
                if len(ai_messages) > previous_count:
                    logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} captured {len(ai_messages) - previous_count} step message(s); total #{len(ai_messages)}")

            logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} completed async execution")
            token_usage_records = collector.snapshot_records()
            final_result = _extract_final_result(final_state, trace_id=self.trace_id, name=self.config.name)
            # 护栏硬停（token 预算或循环检测）不抛异常——它剥除 tool_calls 让
            # run 以最终答案完成。``consume_stop_reason`` 告诉我们是否发生了
            # 该情况，以便我们把 completed 结果标记为 cap 原因（token_capped /
            # loop_capped）冒泡给主代理（#3875 Phase 2）。
            stop_reason = self._consume_guard_stop_reason()
            result.try_set_terminal(
                SubagentStatus.COMPLETED,
                result=final_result,
                stop_reason=stop_reason,
                token_usage_records=token_usage_records,
            )

        except GraphRecursionError:
            # run_config 上的 ``recursion_limit`` == ``self.config.max_turns``
            # （上面设置）。命中意味着子代理耗尽 turn 预算。走 additive
            # ``stop_reason`` 通道（#3875 Phase 2）而非专用 status 枚举（会破坏
            # v1 契约消费者）。若 run streamed 出可用的部分成果，surface 为
            # ``completed``；否则 ``failed``。两条路径主代理都能区分"超预算"
            # 与"子代理坏了"，无需解析结果文本。
            #
            # 优先采用护栏的 stop 原因（若本次已触发）：token-budget / loop
            # 硬停剥除 tool_calls 强制最终答案，若 ``recursion_limit`` 随后在
            # 答案落地前的下一 super-step 触发，则护栏才是约束瓶颈——而非
            # turn 预算。此处咨询护栏（与上面正常完成路径同样的查找）保持
            # 两条路径一致，并 pop 原因避免在 dict 中孤立。
            max_turns = self.config.max_turns
            logger.warning(f"[trace={self.trace_id}] Subagent {self.config.name} reached max_turns={max_turns} (GraphRecursionError); recovering partial result")
            messages = (final_state or {}).get("messages", [])
            usable_partial: str | None = None
            for m in reversed(messages):
                if isinstance(m, AIMessage):
                    text = message_content_to_text(m.content).strip()
                    if text:
                        usable_partial = text
                    break
            records = collector.snapshot_records() if collector is not None else None
            stop_reason = self._consume_guard_stop_reason() or "turn_capped"
            if usable_partial is not None:
                result.try_set_terminal(
                    SubagentStatus.COMPLETED,
                    result=usable_partial,
                    stop_reason=stop_reason,
                    token_usage_records=records,
                )
            else:
                result.try_set_terminal(
                    SubagentStatus.FAILED,
                    error=f"Reached max_turns={max_turns}",
                    stop_reason=stop_reason,
                    token_usage_records=records,
                )

        except Exception as e:
            logger.exception(f"[trace={self.trace_id}] Subagent {self.config.name} async execution failed")
            result.try_set_terminal(
                SubagentStatus.FAILED,
                error=str(e),
                token_usage_records=collector.snapshot_records() if collector is not None else None,
            )

        return result

    def _execute_in_isolated_loop(self, task: str, result_holder: SubagentResult | None = None) -> SubagentResult:
        """在持久 isolated event loop 上执行子代理。

        同步 ``execute()`` 路径在调用方已在 event loop 内时使用此方法。由于
        ``execute()`` 是同步 API，本路径在真正协程跑于长生命周期 isolated loop
        上时阻塞调用方。复用该 loop 使共享 async 客户端不被绑定到每次执行
        关闭的短命 loop 上。
        """
        future: Future[SubagentResult] | None = None
        parent_context = copy_context()
        try:
            future = _submit_to_isolated_loop_in_context(
                parent_context,
                lambda: self._aexecute(task, result_holder),
            )
            return future.result(timeout=self.config.timeout_seconds)
        except FuturesTimeoutError:
            if result_holder is not None:
                result_holder.cancel_event.set()
            if future is not None:
                future.cancel()
            raise
        except Exception:
            if future is None:
                logger.debug(
                    f"[trace={self.trace_id}] Failed to submit subagent {self.config.name} to the isolated event loop",
                    exc_info=True,
                )
            else:
                logger.debug(
                    f"[trace={self.trace_id}] Subagent {self.config.name} failed while executing on the isolated event loop",
                    exc_info=True,
                )
            raise

    def execute(self, task: str, result_holder: SubagentResult | None = None) -> SubagentResult:
        """同步执行任务（async 执行的包装）。

        在新 event loop 中跑 async 执行，允许在线程池内使用异步工具（如 MCP）。

        当从已在运行的 event loop 内调用（如父代理是 async），本方法同步等待
        持久 isolated loop，避免与 httpx 客户端等共享 async 原语的事件循环冲突。
        """
        try:
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                loop = None

            if loop is not None and loop.is_running():
                logger.debug(f"[trace={self.trace_id}] Subagent {self.config.name} detected running event loop, using isolated loop")
                return self._execute_in_isolated_loop(task, result_holder)

            # 标准路径：无运行 event loop，用 asyncio.run
            return asyncio.run(self._aexecute(task, result_holder))
        except Exception as e:
            logger.exception(f"[trace={self.trace_id}] Subagent {self.config.name} execution failed")
            # 无结果则创建带错误的结果
            if result_holder is not None:
                result = result_holder
            else:
                result = SubagentResult(
                    task_id=str(uuid.uuid4())[:8],
                    trace_id=self.trace_id,
                    status=SubagentStatus.RUNNING,
                )
            result.try_set_terminal(SubagentStatus.FAILED, error=str(e))
            return result

    def execute_async(self, task: str, task_id: str | None = None) -> str:
        """后台启动任务执行（非阻塞入口）。

        Args:
            task: 子代理任务描述。
            task_id: 可选的 task id。未提供则生成随机 UUID。

        Returns:
            用于稍后检查状态的 task id。
        """
        # 使用提供的 task_id 或生成新的
        if task_id is None:
            task_id = str(uuid.uuid4())[:8]

        # 创建初始 pending 结果
        result = SubagentResult(
            task_id=task_id,
            trace_id=self.trace_id,
            status=SubagentStatus.PENDING,
        )

        logger.info(f"[trace={self.trace_id}] Subagent {self.config.name} starting async execution, task_id={task_id}, timeout={self.config.timeout_seconds}s")

        with _background_tasks_lock:
            _background_tasks[task_id] = result

        parent_context = copy_context()

        # 投递到 scheduler 线程池
        def run_task():
            with _background_tasks_lock:
                _background_tasks[task_id].status = SubagentStatus.RUNNING
                _background_tasks[task_id].started_at = datetime.now()
                result_holder = _background_tasks[task_id]

            try:
                # 直接投递执行到持久 isolated loop，使后台路径不通过 execute()
                # 创建临时 loop。
                execution_future = _submit_to_isolated_loop_in_context(
                    parent_context,
                    lambda: self._aexecute(task, result_holder),
                )
                try:
                    # 带超时等待执行
                    execution_future.result(timeout=self.config.timeout_seconds)
                except FuturesTimeoutError:
                    logger.error(f"[trace={self.trace_id}] Subagent {self.config.name} execution timed out after {self.config.timeout_seconds}s")
                    # 信号协作式取消并取消 future
                    result_holder.cancel_event.set()
                    result_holder.try_set_terminal(
                        SubagentStatus.TIMED_OUT,
                        error=f"Execution timed out after {self.config.timeout_seconds} seconds",
                    )
                    execution_future.cancel()
            except Exception as e:
                logger.exception(f"[trace={self.trace_id}] Subagent {self.config.name} async execution failed")
                with _background_tasks_lock:
                    task_result = _background_tasks[task_id]
                task_result.try_set_terminal(SubagentStatus.FAILED, error=str(e))

        _scheduler_pool.submit(run_task)
        return task_id


MAX_CONCURRENT_SUBAGENTS = 3


def request_cancel_background_task(task_id: str) -> None:
    """信号一个运行中的后台任务停止。

    设置任务的 cancel_event，由 ``_aexecute`` 在 ``agent.astream()`` 迭代期间
    协作式检查。这让子代理线程——无法通过 ``Future.cancel()`` 强杀——在下一个
    迭代边界停止。

    Args:
        task_id: 要取消的 task id。
    """
    with _background_tasks_lock:
        result = _background_tasks.get(task_id)
        if result is not None:
            result.cancel_event.set()
            logger.info("Requested cancellation for background task %s", task_id)


def get_background_task_result(task_id: str) -> SubagentResult | None:
    """获取后台任务的结果。"""
    with _background_tasks_lock:
        return _background_tasks.get(task_id)


def list_background_tasks() -> list[SubagentResult]:
    """列出所有后台任务。"""
    with _background_tasks_lock:
        return list(_background_tasks.values())


def cleanup_background_task(task_id: str) -> None:
    """从后台任务中移除一个已完成的任务。

    由 task_tool 在轮询完并返回结果后调用，防止已完成任务累积导致内存泄漏。

    仅移除处于终态（COMPLETED/FAILED/TIMED_OUT）的任务，避免与仍在更新该任务
    条目的后台执行器竞态。

    Args:
        task_id: 要移除的 task id。
    """
    with _background_tasks_lock:
        result = _background_tasks.get(task_id)
        if result is None:
            # 无需清理；可能已被移除。
            logger.debug("Requested cleanup for unknown background task %s", task_id)
            return

        # 只清理终态任务，避免与仍在更新该条目的后台执行器竞态。
        if result.status.is_terminal or result.completed_at is not None:
            del _background_tasks[task_id]
            logger.debug("Cleaned up background task: %s", task_id)
        else:
            logger.debug(
                "Skipping cleanup for non-terminal background task %s (status=%s)",
                task_id,
                result.status.value if hasattr(result.status, "value") else result.status,
            )
```

## 关键不变量（从源码提炼）

1. **`tool_call_id == task_id`**：`execute_async(prompt, task_id=tool_call_id)` 复用，token 用量、状态、trace 全部按同一 id 关联。
2. **`try_set_terminal` 单次终态写入**：`_state_lock` 临界区内先校验 `status.is_terminal`，已终态返回 `False`；后台 timeout、执行 worker、cancel 路径竞态写时首个胜出。
3. **cross-thread marshal 必须包 `copy_context()`**：`_submit_to_isolated_loop_in_context` 内 `context.run(run_coroutine_threadsafe(...))`，否则 user_id 在 isolated loop 上退化默认值。
4. **`checkpointer=False`**：子代理一次性，不 resume，隔离父 checkpointer。
5. **`_consume_guard_stop_reason` duck-typed 收集**：`[m for m in middlewares if hasattr(m, "consume_stop_reason")]`，新增护栏零执行器改动。
6. **`GraphRecursionError` 优先采纳护栏原因**：`self._consume_guard_stop_reason() or "turn_capped"`——若 token/loop 硬停先触发又撞 recursion，护栏才是真瓶颈。

## 相关文件

- `core/helix/subagents/registry.py`：`get_subagent_config`（builtin → custom → per-agent override 三层解析）、`get_available_subagent_names`（按沙箱 host-bash 可见性过滤 `bash`）。
- `core/helix/subagents/config.py`：`SubagentConfig`（`max_turns=50` 默认，builtin 覆盖；`disallowed_tools` 默认 `["task"]`；`timeout_seconds=900` builtin 由全局 `subagents.timeout_seconds=1800` 覆盖）、`resolve_subagent_model_name`（`"inherit"` → 父模型 → `app_config.models[0]`）。
- `core/helix/subagents/builtins/general_purpose.py`：`general-purpose`（`max_turns=150`、`disallowed_tools=["task","ask_clarification","present_files"]`、`model="inherit"`）。
