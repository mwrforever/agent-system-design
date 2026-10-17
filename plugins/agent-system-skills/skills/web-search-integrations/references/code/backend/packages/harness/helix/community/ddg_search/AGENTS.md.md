# `backend/packages/harness/helix/community/ddg_search/AGENTS.md`

> 逐字复制的真实源码（22 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

# DuckDuckGo Search

`web_search` distinguishes a search that matched nothing from one that never
ran. `_search_text` returns `[]` only for a genuinely empty result set, which
`ddgs` reports as `DDGSException("No results found.")`, and raises
`DDGSearchError` for every execution failure: rate limits, timeouts, blocked
HTML (vqd extraction), SDK errors, and the missing `ddgs` dependency. Building
the client is part of the boundary too: keep `DDGS(timeout=30)` inside the
`try` so proxy or client-setup failures surface as the same structured error
instead of escaping raw.
`web_search_tool` answers a failure with
`{"error": "DuckDuckGo search failed: <exception type>: <message>", "query": ...}`
and keeps `{"error": "No results found", "query": ...}` for the empty result.
Keep the exception type and message in the error text: `tool_result_meta`
classifies on it, and an outage downgraded to "No results found" reads as
`no_results` (rewrite the query) instead of transient or config recovery.

`tests/test_ddg_search_tools.py` exercises the real tool by patching
`sys.modules["ddgs"]` with a fake `DDGS` whose `__init__` or `text()` raises -
never the normalizer or the tool's final output. Keep the SDK's "No results
found." sentinel mapped back to the empty-search response.
