---
name: enterprise-rag-knowledge-base
description: 企业知识检索接入的真实形态：RetrievalProvider 协议 + KnowledgeCapabilities 能力协商（search/catalog/documents × scope 能力矩阵）、scope 三模式（disabled/selected/全部）、统一 knowledge_search 工具（content_and_artifact 双输出）、引用格式化与来源脱敏（knowledge_sources.v1 信封 ≤100 条）、RAGFlow 与 LightRAG 两个外部服务客户端适配、检索范围准入。当要把企业知识库/文档库接进 agent、设计 provider 插件式检索抽象、做引用与来源回填时使用。注意：本项目不含自研向量检索/重排内核——检索能力全部外置到 provider。
---

# 知识检索集成（Provider 协议）

## 何时用

- 把企业已有知识服务（RAGFlow、LightRAG 或自建）接进 agent
- 设计"检索能力协商"抽象：不同 provider 支持的面不同
- 检索范围（scope）治理：哪些知识源对哪个会话可见
- 引用与来源回填（模型回答带证据）

## 设计方案（为什么这么设计）

### 1. 内核是协议薄层，不是检索引擎

`knowledge/`（全模块仅 491 行）只定义协议与编排：
- `contract.py`：`RetrievalProvider` 协议 + `KnowledgeCapabilities`（search/catalog/documents × dataset_filter/document_filter 能力位）+ `RetrievalHit` 等数据类型
- `providers.py::resolve_knowledge_provider`：按配置解析 provider（RAGFlow / LightRAG / 扩展注册），`validate_scope_capabilities` 做**能力协商**——配置要求的 scope 超出 provider 能力位即启动失败（fail-fast 而非运行期降级）
- `tools.py`：`knowledge_search` 工具，`response_format="content_and_artifact"`——正文给模型、来源清单走 artifact 通道（前端引用渲染见 [[frontend-streaming-protocol]] 的 citations）

**为什么薄**：企业里检索服务已经存在且各自演化（RAGFlow 有数据集目录，LightRAG 没有）；把差异封进能力位，agent 侧只依赖统一工具面。

### 2. Scope 三模式

`knowledge_scope.py`（194 行）：`disabled` / `selected`（显式数据集清单）/ 全部。scope 是**消息级边界**——`KnowledgeScopeMiddleware`（见 [[middleware-chain-design]]）在每次模型调用前把当前 scope 固化进请求，网关侧 `knowledge_scope_admission.py` 做准入校验（不可信客户端不能指定越权 scope）。

### 3. 引用：信封 + 脱敏 + 裁剪

`sources.py`：命中结果格式化为 `knowledge_sources.v1` 信封（id/provider/title/excerpt，上限 100 条），excerpt 脱敏 + 长度裁剪后**才**进入模型可见面。契约文件 `contracts/knowledge_sources.v1.json` 冻结字段——前端 citations 解析器与之共译。

### 4. 两个现成客户端

- `community/ragflow/`（tools 653 + client 206）：数据集目录遍历、检索、文档过滤
- `community/lightrag/`（tools 178 + client 169）：轻量检索

自建 provider 实现协议即可接入（或经扩展注册，见 [[extension-plugin-system]] 的 knowledge 示例）。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/knowledge/contract.py` | 123 | 协议 + 能力位 + 数据类型 |
| `references/code/knowledge/providers.py` | 106 | 解析 + 能力协商 + search_provider |
| `references/code/knowledge/sources.py` | 155 | 引用格式化/脱敏/裁剪 |
| `references/code/knowledge/tools.py` | 75 | knowledge_search 工具 |
| `references/code/knowledge_scope.py` | 194 | scope 语义（三模式） |
| `references/code/mcp_scope.py` | 95 | MCP 侧 scope 对偶 |
| `references/code/community/ragflow/tools.py` + `client.py` | 653+206 | RAGFlow 适配 |
| `references/code/community/lightrag/tools.py` + `client.py` | 178+169 | LightRAG 适配 |
| `references/code/contracts/knowledge_sources.v1.json` | 35 | 引用信封契约 |
| `references/code/app/gateway/routers/knowledge.py` + `knowledge_scope_admission.py` | 112+141 | 能力面 API + scope 准入 |

## 反模式与陷阱

- ❌ 在 agent 框架内自建向量检索内核 → 与既有企业服务重复且难运维；协议 + provider。
- ❌ scope 由客户端自由指定 → 越权读；网关准入校验。
- ❌ 命中全文直接进上下文 → 爆窗口 + 泄内部格式；excerpt 裁剪脱敏 + artifact 走旁路。
- ❌ provider 不声明能力位 → 配置期无法发现问题；能力协商 fail-fast。
- ❌ 引用字段前后端各自定义 → 解析漂移；v1 契约冻结。

## 落地参考

**调参旋钮**：`knowledge_base` 配置段（provider 选择/端点）；scope 在会话/请求层指定；命中上限 100。

**自测方向**：provider 缺 catalog 能力但配置要求数据集目录 → 启动即失败；selected scope 外数据集不可检索；检索结果正文与 artifact 分离；信封 schema 校验通过。

## 进一步阅读

- [[extension-plugin-system]]（扩展注册自定义 RetrievalProvider 的示例）
- [[frontend-app-design]] / [[frontend-streaming-protocol]]（引用渲染与证据解析）
