# tool-assembly-and-policy · 装配主体与配套源码

> 约定：以下代码为**真实实现**（已按插件匿名化规则映射到自定结构，去除项目字样）。真实代码的原注释保留以保真；关键处补中文注解。本文件收录装配主入口 `get_available_tools`（第 1 节）及其调用的配套函数与常量（第 2 节起）。

## 1. 装配主入口（五源聚集 + 能力门 + 去重）

```python
# core/helix/tools/tools.py
import logging

from langchain.tools import BaseTool

from helix.config import get_app_config
from helix.config.app_config import AppConfig
from helix.reflection import resolve_variable
from helix.sandbox.security import is_host_bash_allowed
from helix.tools.builtins import ask_clarification_tool, present_file_tool, task_tool, view_image_tool
from helix.tools.mcp_metadata import tag_mcp_tool
from helix.tools.sync import make_sync_tool_wrapper

logger = logging.getLogger(__name__)

# 始终装载的最小 builtin 集：任何 agent 都应得到这两个。
# ask_clarification 由链尾 ClarificationMiddleware 拦截转 Command(goto=END)（见 [[system-prompt-template]]）。
BUILTIN_TOOLS = [
    present_file_tool,
    ask_clarification_tool,
]

# 仅在 subagent_enabled=True 时追加。暴露给 LLM 的只有派发器 task；
# 状态轮询 task_status 由后端内部处理，不再暴露（见 [[subagent-delegation]]）。
SUBAGENT_TOOLS = [
    task_tool,
]


def _is_host_bash_tool(tool: object) -> bool:
    """识别一个 config 描述符是否代表宿主 bash 执行面（host-bash 门用）。"""
    group = getattr(tool, "group", None)
    use = getattr(tool, "use", None)
    if group == "bash":
        return True
    if use == "helix.sandbox.tools:bash_tool":
        return True
    return False


def _ensure_sync_invocable_tool(tool: BaseTool) -> BaseTool:
    """给 async-only 工具补一个 sync 包装：sync caller（如某些 agent 路径）才能 invoke 它。"""
    if getattr(tool, "func", None) is None and getattr(tool, "coroutine", None) is not None:
        tool.func = make_sync_tool_wrapper(tool.coroutine, tool.name)
    return tool


def get_available_tools(
    groups: list[str] | None = None,
    include_mcp: bool = True,
    model_name: str | None = None,
    subagent_enabled: bool = False,
    *,
    app_config: AppConfig | None = None,
) -> list[BaseTool]:
    """装配所有可用工具。

    Note: MCP 工具应在应用启动时由 helix.mcp.initialize_mcp_tools() 初始化；
    本函数读取的是 lazy + mtime 失效的缓存。

    Args:
        groups: 可选，按 tool_groups 过滤（agent 级声明式收缩）。
        include_mcp: 是否包含 MCP 工具（默认 True）。
        model_name: 可选，决定是否追加视觉工具。
        subagent_enabled: 是否包含子代理 task 工具。

    Returns:
        去重后的 BaseTool 列表。
    """
    config = app_config or get_app_config()
    tool_configs = [tool for tool in config.tools if groups is None or tool.group in groups]

    # host-bash 门：本地 LocalSandboxProvider 激活时，默认不暴露宿主 bash。
    if not is_host_bash_allowed(config):
        tool_configs = [tool for tool in tool_configs if not _is_host_bash_tool(tool)]

    # ① config-defined：反射加载（"module.path:variable_name"）
    loaded_tools_raw = [(cfg, resolve_variable(cfg.use, BaseTool)) for cfg in tool_configs]

    # config.name 与 tool 对象自身 .name 不一致时告警：
    # 这是 #1803 的根因--LLM 在 schema 里看到一个 name，运行时 router 认另一个，报"not a valid tool"。
    for cfg, loaded in loaded_tools_raw:
        if cfg.name != loaded.name:
            logger.warning(
                "Tool name mismatch: config name %r does not match tool .name %r (use: %s). "
                "The tool's own .name will be used for binding.",
                cfg.name, loaded.name, cfg.use,
            )

    loaded_tools = [_ensure_sync_invocable_tool(t) for _, t in loaded_tools_raw]

    # ② builtin：最小集 + 条件追加
    builtin_tools = BUILTIN_TOOLS.copy()
    skill_evolution_config = getattr(config, "skill_evolution", None)
    if getattr(skill_evolution_config, "enabled", False):
        from helix.tools.skill_manage_tool import skill_manage_tool
        builtin_tools.append(skill_manage_tool)

    # subagent 门：仅运行时启用时追加 task（子代理不传 task，防无限嵌套）
    if subagent_enabled:
        builtin_tools.extend(SUBAGENT_TOOLS)
        logger.info("Including subagent tools (task)")

    # 视觉门：仅模型支持 vision 时追加 view_image
    if model_name is None and config.models:
        model_name = config.models[0].name
    model_config = config.get_model_config(model_name) if model_name else None
    if model_config is not None and model_config.supports_vision:
        builtin_tools.append(view_image_tool)
        logger.info(f"Including view_image_tool for model '{model_name}' (supports_vision=True)")

    # ③ MCP：lazy + mtime 缓存。读 ExtensionsConfig.from_file()（非 config.extensions）
    # 以拿到 Gateway API 在另一进程写入的最新配置。
    # 给 MCP 工具打单一真值 tag，供后续 assemble_deferred_tools（policy 过滤之后）识别。
    mcp_tools = []
    if include_mcp:
        try:
            from helix.config.extensions_config import ExtensionsConfig
            from helix.mcp.cache import get_cached_mcp_tools

            extensions_config = ExtensionsConfig.from_file()
            if extensions_config.get_enabled_mcp_servers():
                mcp_tools = get_cached_mcp_tools()
                if mcp_tools:
                    logger.info(f"Using {len(mcp_tools)} cached MCP tool(s)")
                    # Tag MCP 来源：deferred 装配在 agent 构造点（policy 过滤之后）做，
                    # 届时靠这个 tag 识别，不建 ContextVar / 注册表。
                    for t in mcp_tools:
                        tag_mcp_tool(t)
        except ImportError:
            logger.warning("MCP module not available. Install 'langchain-mcp-adapters' package to enable MCP tools.")
        except Exception as e:
            logger.error(f"Failed to get cached MCP tools: {e}")

    # ④ ACP：配置了外部 ACP 代理时构造 invoke_acp_agent
    acp_tools: list[BaseTool] = []
    try:
        from helix.tools.builtins.invoke_acp_agent_tool import build_invoke_acp_agent_tool

        if app_config is None:
            from helix.config.acp_config import get_acp_agents
            acp_agents = get_acp_agents()
        else:
            acp_agents = getattr(config, "acp_agents", {}) or {}
        if acp_agents:
            acp_tools.append(build_invoke_acp_agent_tool(acp_agents))
            logger.info(f"Including invoke_acp_agent tool ({len(acp_agents)} agent(s): {list(acp_agents.keys())})")
    except Exception as e:
        logger.warning(f"Failed to load ACP tool: {e}")

    logger.info(f"Total tools loaded: {len(loaded_tools)}, built-in tools: {len(builtin_tools)}, "
                f"MCP tools: {len(mcp_tools)}, ACP tools: {len(acp_tools)}")

    # 合并 + 按 name 去重：config-loaded 优先，其次 builtin、MCP、ACP。
    # 重复 name 会让 LLM 收到歧义/拼接的 function schema（#1803）。
    all_tools = [_ensure_sync_invocable_tool(t) for t in loaded_tools + builtin_tools + mcp_tools + acp_tools]
    seen_names: set[str] = set()
    unique_tools: list[BaseTool] = []
    for t in all_tools:
        if t.name not in seen_names:
            unique_tools.append(t)
            seen_names.add(t.name)
        else:
            logger.warning(
                "Duplicate tool name %r detected and skipped - check your config.yaml and MCP server registrations (issue #1803).",
                t.name,
            )
    return unique_tools
```

## 2. 反射加载（resolve_variable + 可执行 install hint）

```python
# core/helix/reflection/resolvers.py
from importlib import import_module

# 已知 provider 缺失时的 install 包名映射（module_root -> package name）
MODULE_TO_PACKAGE_HINTS = {
    "langchain_google_genai": "langchain-google-genai",
    "langchain_anthropic": "langchain-anthropic",
    "langchain_openai": "langchain-openai",
    "langchain_deepseek": "langchain-deepseek",
}


def _build_missing_dependency_hint(module_path: str, err: ImportError) -> str:
    """模块 import 失败时构造可执行的 install 提示。"""
    module_root = module_path.split(".", 1)[0]
    missing_module = getattr(err, "name", None) or module_root

    # 优先用已知 provider 的包名提示，即便是被传递依赖触发的 ImportError（如 google 包缺失）
    package_name = MODULE_TO_PACKAGE_HINTS.get(module_root)
    if package_name is None:
        package_name = MODULE_TO_PACKAGE_HINTS.get(missing_module, missing_module.replace("_", "-"))

    return f"Missing dependency '{missing_module}'. Install it with `uv add {package_name}` (or `pip install {package_name}`), then restart the agent platform."


def resolve_variable[T](
    variable_path: str,
    expected_type: type[T] | tuple[type, ...] | None = None,
) -> T:
    """从路径解析变量。

    Args:
        variable_path: 变量路径（如 "parent_package.sub_package.module:variable_name"）。
        expected_type: 可选，用 isinstance 校验解析结果。

    Returns:
        解析出的变量。

    Raises:
        ImportError: 模块路径非法 / 属性不存在 / 模块 import 失败（含可执行 install hint）。
        ValueError: expected_type 校验失败。
    """
    try:
        module_path, variable_name = variable_path.rsplit(":", 1)
    except ValueError as err:
        raise ImportError(
            f"{variable_path} doesn't look like a variable path. "
            f"Example: parent_package_name.sub_package_name.module_name:variable_name"
        ) from err

    try:
        module = import_module(module_path)
    except ImportError as err:
        module_root = module_path.split(".", 1)[0]
        err_name = getattr(err, "name", None)
        if isinstance(err, ModuleNotFoundError) or err_name == module_root:
            hint = _build_missing_dependency_hint(module_path, err)
            raise ImportError(f"Could not import module {module_path}. {hint}") from err
        # 非缺失模块的其他 ImportError：保留原始 message
        raise ImportError(f"Error importing module {module_path}: {err}") from err

    try:
        variable = getattr(module, variable_name)
    except AttributeError as err:
        raise ImportError(f"Module {module_path} does not define a {variable_name} attribute/class") from err

    # 类型校验
    if expected_type is not None:
        if not isinstance(variable, expected_type):
            type_name = (expected_type.__name__ if isinstance(expected_type, type)
                         else " or ".join(t.__name__ for t in expected_type))
            raise ValueError(f"{variable_path} is not an instance of {type_name}, got {type(variable).__name__}")

    return variable


def resolve_class[T](class_path: str, base_class: type[T] | None = None) -> type[T]:
    """从路径解析类（并校验是否继承自 base_class）。

    与 resolve_variable 类似，但解析的是类对象本身而非实例。
    """
    cls = resolve_variable(class_path, expected_type=type)
    if base_class is not None and not issubclass(cls, base_class):
        raise ValueError(f"{class_path} is not a subclass of {base_class.__name__}")
    return cls
```

## 3. async-only 工具的 sync 包装

```python
# core/helix/tools/sync.py（节选：sync 包装器）
# 某些 agent 路径（sync caller）需要直接 invoke 工具，但工具只定义了 async coroutine。
# 本包装器给这类工具补一个 .func，在 sync 上下文里桥接到 coroutine。

import asyncio
from concurrent.futures import ThreadPoolExecutor

_sync_executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="helix-tool-sync")


def make_sync_tool_wrapper(coro_func, tool_name: str):
    """为 async-only 工具构造一个 sync 包装函数，挂到 tool.func。

    桥接方式：在独立线程里跑一个新事件循环驱动 coroutine，
    避免阻塞调用方的事件循环（若调用方本身在 async 上下文）。
    """

    def _sync_call(*args, **kwargs):
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        if loop is None:
            # 调用方无事件循环：直接 asyncio.run
            return asyncio.run(coro_func(*args, **kwargs))
        # 调用方在运行中的事件循环里：提交到独立线程避免嵌套循环
        future = _sync_executor.submit(asyncio.run, coro_func(*args, **kwargs))
        return future.result()

    _sync_call.__name__ = f"{tool_name}_sync"
    return _sync_call
```

## 4. MCP 来源单一真值标记

```python
# core/helix/tools/mcp_metadata.py
"""MCP-tool metadata tag 的单一事实源。

一个工具"来自 MCP"当且仅当它携带 ``helix_mcp`` metadata flag。
tag 在工具装载处（tools.py）写入，在 deferred 装配（tool_search.py）与 agent 构造点（agent.py）读取。
key / tagger / predicate 都收敛到这里，magic string 只活在一处，读取方 import 公开 predicate
而非跨模块私有 helper。

设计为叶子模块：只依赖 BaseTool，任何模块（含工具装载器）都能 import 它而不会产生环。
"""

from __future__ import annotations

from langchain.tools import BaseTool

MCP_TOOL_METADATA_KEY = "helix_mcp"


def tag_mcp_tool(tool: BaseTool) -> BaseTool:
    """把 tool 标记为 MCP 来源。原地改写并返回它（支持链式调用）。"""
    tool.metadata = {**(tool.metadata or {}), MCP_TOOL_METADATA_KEY: True}
    return tool


def is_mcp_tool(tool: BaseTool) -> bool:
    """当 tool 携带 tag_mcp_tool 写入的 MCP 来源 tag 时返回 True。"""
    return (getattr(tool, "metadata", None) or {}).get(MCP_TOOL_METADATA_KEY) is True
```

> 重要：禁止用工具 name 前缀（如 `mcp__server__tool`）或目录路径推断 MCP 来源--MCP server 重命名工具后前缀规则会漏 tag，导致该延迟的工具被当成 immediate 全 schema 绑定。永远只认这个 metadata key。

## 5. MCP lazy + mtime 失效缓存

```python
# core/helix/mcp/cache.py
"""MCP 工具缓存，避免重复装载。"""

import asyncio
import logging
import os

from langchain_core.tools import BaseTool

logger = logging.getLogger(__name__)

_mcp_tools_cache: list[BaseTool] | None = None
_cache_initialized = False
_initialization_lock = asyncio.Lock()
_config_mtime: float | None = None  # 跟踪 extensions config 文件的修改时间


def _get_config_mtime() -> float | None:
    """取 extensions config 文件的 mtime（用于失效判定）。"""
    from helix.config.extensions_config import ExtensionsConfig

    config_path = ExtensionsConfig.resolve_config_path()
    if config_path and config_path.exists():
        return os.path.getmtime(config_path)
    return None


def _is_cache_stale() -> bool:
    """配置文件被改过 -> 缓存过期。"""
    global _config_mtime

    if not _cache_initialized:
        return False  # 还没初始化，不算过期

    current_mtime = _get_config_mtime()
    # 当前或上次都拿不到 mtime：保守起见认为没过期
    if _config_mtime is None or current_mtime is None:
        return False

    if current_mtime > _config_mtime:
        logger.info(f"MCP config file has been modified (mtime: {_config_mtime} -> {current_mtime}), cache is stale")
        return True

    return False


async def initialize_mcp_tools() -> list[BaseTool]:
    """初始化并缓存 MCP 工具。应在应用启动时调一次。

    从所有启用的 MCP server 拉取 LangChain 工具列表。
    """
    global _mcp_tools_cache, _cache_initialized, _config_mtime

    async with _initialization_lock:
        if _cache_initialized:
            logger.info("MCP tools already initialized")
            return _mcp_tools_cache or []

        from helix.mcp.tools import get_mcp_tools

        logger.info("Initializing MCP tools...")
        _mcp_tools_cache = await get_mcp_tools()
        _cache_initialized = True
        _config_mtime = _get_config_mtime()  # 记录 config mtime
        logger.info(f"MCP tools initialized: {len(_mcp_tools_cache)} tool(s) loaded (config mtime: {_config_mtime})")

        return _mcp_tools_cache


def get_cached_mcp_tools() -> list[BaseTool]:
    """取缓存的 MCP 工具，未初始化则 lazy 初始化。

    保证 FastAPI 与 LangGraph Studio 两条上下文都能用 MCP 工具。
    同时检测 config 文件改动，需要时重新初始化--确保 Gateway API（另一进程）
    对 extensions_config.json 的写入能立即在 Gateway 内嵌 LangGraph runtime 反映出来。
    """
    global _cache_initialized

    # config 文件改过 -> 重置缓存，触发重新初始化
    if _is_cache_stale():
        logger.info("MCP cache is stale, resetting for re-initialization...")
        reset_mcp_tools_cache()

    if not _cache_initialized:
        logger.info("MCP tools not initialized, performing lazy initialization...")
        try:
            # 尝试在当前事件循环里初始化
            loop = asyncio.get_event_loop()
            if loop.is_running():
                # 循环已运行（如 LangGraph Studio）：在新线程里开新循环跑
                import concurrent.futures

                with concurrent.futures.ThreadPoolExecutor() as executor:
                    future = executor.submit(asyncio.run, initialize_mcp_tools())
                    future.result()
            else:
                # 无运行中的循环：用当前循环
                loop.run_until_complete(initialize_mcp_tools())
        except RuntimeError:
            # 无事件循环：开一个
            try:
                asyncio.run(initialize_mcp_tools())
            except Exception:
                logger.exception("Failed to lazy-initialize MCP tools")
                return []
        except Exception:
            logger.exception("Failed to lazy-initialize MCP tools")
            return []

    return _mcp_tools_cache or []


def reset_mcp_tools_cache() -> None:
    """重置 MCP 工具缓存（测试 / 想重载时用）。

    同时关闭持久 MCP session，下次 get_mcp_tools() 会用（可能更新的）连接配置重建。
    close_all_sync() 按拥有循环挑正确策略：
      * 归当前运行循环所有的 session：只发信号（owner task 在循环交还控制后跑 __aexit__）
      * 归其他线程循环的 session：确定性 teardown
      * 空闲/已关闭循环：处理或跳过
    这里故意不等待当前运行循环的 teardown 完成：那是自死锁（循环只能在本 sync 调用返回后跑 teardown）。
    """
    global _mcp_tools_cache, _cache_initialized, _config_mtime
    _mcp_tools_cache = None
    _cache_initialized = False
    _config_mtime = None

    try:
        from helix.mcp.session_pool import get_session_pool

        get_session_pool().close_all_sync()
    except Exception:
        logger.debug("Could not close MCP session pool on cache reset", exc_info=True)

    from helix.mcp.session_pool import reset_session_pool

    reset_session_pool()
    logger.info("MCP tools cache reset")
```

> MCP 多 server 集成（`MultiServerMCPClient`、stdio/SSE/HTTP 传输、OAuth、stdio 路径翻译、per-thread session 作用域）的完整细节见 [[mcp-integration]]，本 skill 只讲装配来源。

## 6. ACP 外部代理工具构造

```python
# core/helix/tools/builtins/invoke_acp_agent_tool.py（节选：构造器签名）
from langchain_core.tools import BaseTool


def build_invoke_acp_agent_tool(acp_agents: dict[str, dict]) -> BaseTool:
    """当 config.yaml -> acp_agents 非空时，构造 invoke_acp_agent 工具。

    Args:
        acp_agents: ACP 代理配置映射（name -> config，含 launcher 命令、描述等）。

    Returns:
        包装了所有已配置 ACP 代理的单个 BaseTool。模型调用时按参数路由到对应代理。

    装配点：get_available_tools 的第 ④ 源。ACP 代理使用 per-thread 工作区
    /mnt/acp-workspace/（见 [[sandbox-abstraction]]）；ACP launcher 必须是真正的
    ACP adapter（如 npx -y @zed-industries/codex-acp），裸 codex CLI 不兼容。
    """
    # ...构造闭包工具，描述里列出所有可用代理及其能力...
    ...
```

## 7. builtin 工具导出清单

```python
# core/helix/tools/builtins/__init__.py
from .clarification_tool import ask_clarification_tool
from .present_file_tool import present_file_tool
from .setup_agent_tool import setup_agent
from .task_tool import task_tool
from .update_agent_tool import update_agent
from .view_image_tool import view_image_tool

__all__ = [
    "setup_agent",
    "update_agent",
    "present_file_tool",
    "ask_clarification_tool",
    "view_image_tool",
    "task_tool",
]
```

builtin 工具职责速查（各项深度归对应 organ skill）：

| 工具 | 装载条件 | 职责 | 深度 |
|---|---|---|---|
| `present_files` | 始终（`BUILTIN_TOOLS`） | 把 `/mnt/user-data/outputs` 下产物展示给用户 | [[sandbox-tools-and-safety]] |
| `ask_clarification` | 始终（`BUILTIN_TOOLS`） | 请求澄清；链尾 ClarificationMiddleware 拦截转 `Command(goto=END)` | [[system-prompt-template]] |
| `view_image` | `model_config.supports_vision` | 读图为 base64 注入 | [[middleware-chain-design]]（ViewImageMiddleware） |
| `task` | `subagent_enabled` | 委派子代理（独立图 + 独立事件循环） | [[subagent-delegation]] |
| `setup_agent` | `is_bootstrap=True`（agent 工厂里追加） | 引导模式持久化新 agent 的 SOUL.md + config | [[agent-graph-factory]] |
| `update_agent` | `agent_name` 且非 webhook 通道（agent 工厂里追加） | 自定义 agent 自更新 SOUL.md / config | [[agent-graph-factory]] |
| `skill_manage_tool` | `skill_evolution.enabled` | skill 进化管理 | [[skill-system-design]] |

## 8. tools 包入口（懒导出）

```python
# core/helix/tools/__init__.py
from .tools import get_available_tools

__all__ = ["get_available_tools", "skill_manage_tool"]


def __getattr__(name: str):
    # skill_manage_tool 懒加载：避免轻量子模块 import 时拉进整条 skill_evolution 依赖图
    if name == "skill_manage_tool":
        from .skill_manage_tool import skill_manage_tool
        return skill_manage_tool
    raise AttributeError(name)
```
