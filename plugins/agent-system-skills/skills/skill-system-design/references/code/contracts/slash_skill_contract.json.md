# `contracts/slash_skill_contract.json`

> 逐字复制的真实源码（18 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```json
{
  "version": 1,
  "description": "Cross-language contract fixture for the leading /skill activation gate. The backend parser (helix/skills/slash.py) and the frontend display parser (frontend/src/core/skills/slash.ts) must agree on which leading /word tokens are reserved control commands and on the exact skill-name grammar, so the transcript only renders an activation chip for text the backend would actually treat as a /skill activation.",
  "reserved_slash_skill_names": [
    "agent",
    "bootstrap",
    "context",
    "goal",
    "help",
    "memory",
    "model",
    "models",
    "new",
    "status"
  ],
  "skill_name_pattern": "^/([a-z0-9]+(?:-[a-z0-9]+)*)(?:\\s+|$)"
}
```
