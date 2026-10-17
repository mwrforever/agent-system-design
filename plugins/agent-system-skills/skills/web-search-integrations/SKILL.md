---
name: web-search-integrations
description: 联网搜索工具集成模式：17+ 家搜索 provider 的统一接入范式（use: 字符串注册、凭据集中管理 provider_credentials、结果条数上限 search_max_results、URL 安全防线 url_safety 234 行：私有网段/协议/端口校验防 SSRF），附 Tavily/DuckDuckGo/Brave/Serer/Jina/crawl4ai 六个完整实现。当要给 agent 加联网搜索/网页抓取、接入新的搜索 API、防内网 SSRF 时使用。
---

# 搜索工具集成

## 何时用

- 给 agent 加 web 搜索/抓取工具（选 provider 或新接一家）
- 多 provider 的凭据与配置统一管理
- URL 安全校验（防 agent 被 SSRF 引到内网）

## 设计方案（为什么这么设计）

### 1. 统一接入范式

17+ 家 provider（tavily/ddg/brave/searxng/serper/serply/sofya/tencent wsa/unbrowse/webz/youcom/exa/fastcrw/firecrawl/groundroute/image search/infoquest/jina/crawl4ai）全部同构：
- 工具类放 `community/<provider>/tools.py`，`config.yaml → tools` 以 `use:` 字符串引用（见 [[tool-assembly-and-policy]]）
- 凭据统一走 `provider_credentials.py`（不散落各家）
- 结果条数统一 `search_max_results.py` 收口（防某家返回巨量结果爆上下文）

### 2. URL 安全是搜索工具的底线

`url_safety.py`（234 行）：对工具要访问的 URL 做校验——私有网段（127/8、10/8、172.16/12、169.254/16、::1 等）、危险协议、敏感端口拒绝。**为什么必须**：搜索结果/用户输入的 URL 可能指向内网元数据服务（169.254.169.254）——agent 平台的 SSRF 面比自己写爬虫大得多，校验必须在工具层统一做而不是靠每家 provider 自觉。

### 3. 六个完整实现（模式样本）

Tavily（API 搜索）、DuckDuckGo（免 key，目录 `ddg_search`）、Brave、Serper（Google 代理）、Jina（阅读器）、crawl4ai（站点抓取）——新接一家时抄最接近的一家改即可。

## 实现索引

| 文件 | 行数 | 职责 |
|---|---|---|
| `references/code/backend/packages/harness/helix/community/url_safety.py` | 234 | SSRF 防线 |
| `references/code/backend/packages/harness/helix/community/provider_credentials.py` | — | 凭据集中管理 |
| `references/code/backend/packages/harness/helix/community/search_max_results.py` | — | 条数收口 |
| `references/code/backend/packages/harness/helix/community/{tavily,ddg_search,brave,serper,jina_ai,crawl4ai}/**` | — | 六家完整实现 |

其余 provider 未随语料复制（同构模式，接法一致）。

## 反模式与陷阱

- ❌ 每家自己管 key → 配置漂移；provider_credentials 统一。
- ❌ 搜索结果条数不设上限 → 上下文爆炸；统一收口。
- ❌ 抓取 URL 不校验 → SSRF 打内网；url_safety 强制。
- ❌ 工具描述不写结果格式 → 模型解析各家 JSON 摸黑；描述即契约。

## 落地参考

**自测方向**：内网/元数据地址 URL 被拒；无 key 的 ddg 可用；条数上限生效；新 provider 按 use: 注册即入装配管线。

## 进一步阅读

- [[tool-assembly-and-policy]]（use: 反射与装配）、[[safety-and-guardrails]]（工具授权层）
- [[enterprise-rag-knowledge-base]]（同为 community 目录下的外部能力接入）
