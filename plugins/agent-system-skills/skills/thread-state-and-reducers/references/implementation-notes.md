# Implementation Notes — thread-state-and-reducers

> 适用范围：基于 LangGraph 的 `TypedDict + Annotated reducer` 状态模型。
> 配合 [[agent-graph-factory]] 使用：`create_agent(state_schema=ThreadState)`。

---

## 1. 组件矩阵

| 通用组件名 | 真实职责 | 关键 API / 签名 |
|---|---|---|
| `ThreadState` | 继承自 LangChain `AgentState` 的根状态 schema | 必须传入 `create_agent(state_schema=ThreadState)`，否则 reducers 失效 |
| `merge_sandbox(existing, new)` | 沙盒 ID 幂等合并 reducer | 同 ID 直通；不同 ID **抛 ValueError 而非静默选一**（fail-closed） |
| `merge_artifacts(existing, new)` | 产物路径列表合并去重 | 用 `dict.fromkeys` 保序去重，兼容多节点同步并发追加 |
| `merge_viewed_images(existing, new)` | 已查看图像字典合并 | 特例：传入 `{}` 表示**清空**，非合并 |
| `merge_todos(existing, new)` | TodoList 最后非 None 覆盖 | `new is None` 表示节点未触动，保留 `existing` |
| `merge_promoted(existing, new)` | MCP 工具按目录哈希分代合并 | `catalog_hash` 变化即整代替换；同代名称并集去重 |
| `SandboxState` / `ThreadDataState` / `ViewedImageData` / `PromotedTools` | 嵌套 `TypedDict`，保证 JSON 可序列化 | 全部使用 `NotRequired[...]` 标记可选 |
| `Annotated[T, reducer]` | LangGraph 识别 reducer 的语法糖 | 不使用 `Annotated` 的字段默认走“最后写入覆盖” |

### 字段一览

| 字段 | 类型注解 | 是否带 reducer |
|---|---|---|
| `messages` | 继承自 `AgentState` | ✓（`add_messages`） |
| `sandbox` | `Annotated[NotRequired[SandboxState \| None], merge_sandbox]` | ✓ |
| `thread_data` | `NotRequired[ThreadDataState \| None]` | ✗ |
| `title` | `NotRequired[str \| None]` | ✗ |
| `artifacts` | `Annotated[list[str], merge_artifacts]` | ✓ |
| `todos` | `Annotated[list \| None, merge_todos]` | ✓ |
| `uploaded_files` | `NotRequired[list[dict] \| None]` | ✗ |
| `viewed_images` | `Annotated[dict, merge_viewed_images]` | ✓ |
| `promoted` | `Annotated[PromotedTools \| None, merge_promoted]` | ✓ |

---

## 2. 关键调用时序

### 时序 A：节点返回 → reducer 应用

```
Node.handler(state)
  └─> 返回 dict（部分字段）或 Command(update=dict)
        └─ langgraph 取 state_schema 的 __annotations__
              对每个字段：
                if has Annotated[..., reducer]:  reducer(state[field], update[field])
                else:                            update[field]  # Last-Write-Wins
              合并结果写入 checkpoint
```

### 时序 B：并发节点同步合并（典型场景：两个工具同帧返回沙盒 ID）

```
ToolA returns {"sandbox": {"sandbox_id": "thread:abc"}}
ToolB returns {"sandbox": {"sandbox_id": "thread:abc"}}
                              │
                              ▼
   merge_sandbox(existing={"sandbox_id":"thread:abc"},
                 new={"sandbox_id":"thread:abc"})
                 → 同 id，返回 existing
                 → checkpoint 单一来源真理

# 若 B 返回 "thread:xyz"：
   merge_sandbox(...) → ValueError → 整个 superstep 失败，回滚
```

### 时序 C：跨代 MCP 工具升级（promoted 重置）

```
回合 N：catalog_hash="h1", promoted.names=["read_file","ls"]
配置更新 → MCP server 列表变化
回合 N+1：节点 emit {"promoted": {"catalog_hash":"h2","names":["search"]}}
  merge_promoted(existing={hash:"h1",names:[…]}, new={hash:"h2",names:["search"]})
    → hash 不同 → 整代替换 → {"catalog_hash":"h2","names":["search"]}
    → 防止旧名继续触发 DeferredToolFilterMiddleware 误放行
```

---

## 3. 数据契约 / 类型签名

```python
from typing import TypedDict, NotRequired, Annotated
from langchain.agents import AgentState

class SandboxState(TypedDict):
    sandbox_id: NotRequired[str | None]

class ThreadDataState(TypedDict):
    workspace_path: NotRequired[str | None]
    uploads_path: NotRequired[str | None]
    outputs_path: NotRequired[str | None]

class ViewedImageData(TypedDict):
    base64: str
    mime_type: str

class PromotedTools(TypedDict):
    catalog_hash: str
    names: list[str]

def merge_sandbox(existing, new):
    if new is None: return existing
    if existing is None: return new
    if existing.get("sandbox_id") == new.get("sandbox_id"):
        return existing
    raise ValueError("Conflicting sandbox state updates")

def merge_artifacts(existing, new):
    if existing is None: return new or []
    if new is None: return existing
    return list(dict.fromkeys(existing + new))

def merge_viewed_images(existing, new):
    if existing is None: return new or {}
    if new is None: return existing
    if len(new) == 0: return {}            # 显式清空协议
    return {**existing, **new}

def merge_todos(existing, new):
    return existing if new is None else new

def merge_promoted(existing, new):
    if not new: return existing
    if existing is None or existing["catalog_hash"] != new["catalog_hash"]:
        return {"catalog_hash": new["catalog_hash"],
                "names": list(dict.fromkeys(new["names"]))}
    return {"catalog_hash": existing["catalog_hash"],
            "names": list(dict.fromkeys(existing["names"] + new["names"]))}

class ThreadState(AgentState):
    sandbox: Annotated[NotRequired[SandboxState | None], merge_sandbox]
    thread_data: NotRequired[ThreadDataState | None]
    title: NotRequired[str | None]
    artifacts: Annotated[list[str], merge_artifacts]
    todos: Annotated[list | None, merge_todos]
    uploaded_files: NotRequired[list[dict] | None]
    viewed_images: Annotated[dict[str, ViewedImageData], merge_viewed_images]
    promoted: Annotated[PromotedTools | None, merge_promoted]
```

---

## 4. 关键不变量

1. **所有带 reducer 的字段必须用 `Annotated[T, fn]`** — 漏标即退化为 Last-Write-Wins。违反后果：并发节点同步更新会静默丢数据（最严重的是 `artifacts` 被覆盖为单元素列表）。
2. **`merge_sandbox` fail-closed** — 不同 sandbox_id 必须抛错而非选一。违反后果：同 thread 跨沙盒读写，数据写在隔离环境之外。
3. **reducer 必须纯函数 + 幂等** — 不得有 I/O / 锁 / 时间依赖。违反后果：LangGraph 在重放 checkpoint 时结果不一致，断点恢复失败。
4. **`new is None` 表示“节点未触动该字段”，必须保留 `existing`** — `merge_todos / merge_artifacts / merge_promoted` 都遵守此协议。违反后果：单个节点 partial update 会误清空状态。
5. **`viewed_images` 的清空必须用 `{}` 而非 `None`** — `None` 在协议里语义是“未触动”。违反后果：清空意图被吃掉，图像反复注入。
6. **`promoted.catalog_hash` 变化即整代替换** — 不可并集。违反后果：MCP server 变更后，旧工具名残留触发 `DeferredToolFilterMiddleware` 错误放行。
7. **`messages` 不要自定义 reducer** — 继承 `AgentState` 的 `add_messages` 已处理 ID-swap / Remove。违反后果：tool_call 配对、`RemoveMessage` 语义全部失效。
8. **schema 类必须 JSON 可序列化** — `TypedDict` + 基础类型；禁止存放 `bytes` / 自定义对象。违反后果：checkpointer（SQL/Redis）持久化失败。

---

## 5. 常见踩坑

1. **写成 `Annotated[list, merge_xxx]` 但 import 错 reducer** — 静默使用了同名占位函数。修复：用 `from … import merge_artifacts as _ma`，模块顶部一处导入。
2. **节点想清空 `artifacts` 但返回 `[]`** — 合并去重后还是 `existing`。修复：约定“清空”必须走显式 `Command(update={"artifacts": REMOVE_SENTINEL})` 或新增清空 reducer 分支。
3. **`merge_viewed_images` 误传 `None`** — 期望清空但被当成未触动。修复：调用方明确写 `{}`，并在 reducer 文档上加红字注释。
4. **`merge_sandbox` 抛错被上层 `try/except` 吞掉** — 隔离失效但日志没痕迹。修复：上层 except 必须 `logger.exception` 后重新抛出。
5. **直接 `state["artifacts"].append(x)`** — 节点内 in-place 修改，不会触发 reducer。修复：返回 `{"artifacts": [x]}` 让 reducer 接管。
6. **`promoted.names` 存了字符串以外的对象** — checkpointer 反序列化失败。修复：reducer 入口处 `assert all(isinstance(n, str) for n in new["names"])`。
7. **新增字段忘记加 reducer 但有并发写** — bug 仅在压测时偶现。修复：CI 加一条 lint 规则，凡 `ThreadState` 字段类型为 `list/dict/set` 且无 `Annotated` 即报错。
8. **`uploaded_files` 想去重却没 reducer** — 现状是 Last-Write-Wins，依赖上游中间件每次给完整列表。修复：要么补 reducer，要么在 SKILL 里显式说明该字段由上传中间件独占写。
9. **节点返回 `Command(update={"sandbox": {...}}, goto=END)`** — 退出时仍触发 reducer。若 update 与既有 ID 冲突，整个退出失败。修复：退出帧的字段应只携带必要值。

---

## 6. 调参旋钮 + 调试入口

| 旋钮 | 位置 | 说明 |
|---|---|---|
| `state_schema` | `create_agent(state_schema=ThreadState)` | 必须显式传入 |
| `checkpointer` | 图编译选项 | 决定 reducers 结果是否跨进程持久化 |
| `REMOVE_ALL_MESSAGES` | `langgraph.graph.message` | 配合 `add_messages` 做整段清理 |
| 字段是否 `NotRequired` | `TypedDict` 声明 | 决定初始状态可否缺省 |

**关键日志串**：

- `Conflicting sandbox state updates: <a> != <b>` — `merge_sandbox` 触发的隔离冲突，必须当作 P0 事件告警。
- `Reducer applied: field=artifacts existing=… new=…` — 建议在开发期临时打 DEBUG 日志，定位合并去重行为。
- `RemoveMessage applied: id=…` — `add_messages` 删除路径，summarization 之后频繁出现。

**测试方向**：

- 表驱动测试每个 reducer 的 4 个分支：(existing=None,new=None) / (existing=None,new=val) / (val,None) / (val1,val2)。
- 并发 superstep：两个节点同步返回 `{"artifacts": ["a"]}`、`{"artifacts": ["b"]}` → 期望最终 `["a","b"]`。
- `merge_sandbox` 冲突路径：断言 `pytest.raises(ValueError)`。
- `merge_promoted` 分代隔离：先用 hash="h1" 写入，再用 hash="h2" 写入，断言最终只剩 h2 的 names。
- Checkpointer round-trip：写入后读出，所有字段保持等价（特别是 `viewed_images` 的 base64 编码）。
- `viewed_images` 清空协议：`{}` 清空 vs `None` 保留，分别断言。

---

相关 skill：[[agent-graph-factory]] · [[middleware-chain-design]] · [[context-window-management]] · [[tool-assembly-and-policy]] · [[sandbox-abstraction]]
