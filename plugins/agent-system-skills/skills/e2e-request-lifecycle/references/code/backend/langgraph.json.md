# `backend/langgraph.json`

> 逐字复制的真实源码（21 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```json
{
  "$schema": "https://langgra.ph/schema.json",
  "python_version": "3.12",
  "dependencies": [
    "."
  ],
  "env": "../.env",
  "graphs": {
    "lead_agent": "helix.agents:make_lead_agent"
  },
  "auth": {
    "path": "./app/gateway/langgraph_auth.py:auth"
  },
  "http": {
    "app": "./app/gateway/langgraph_studio.py:langgraph_app"
  },
  "checkpointer": {
    "path": "./packages/harness/helix/runtime/checkpointer/async_provider.py:make_checkpointer"
  }
}
```
