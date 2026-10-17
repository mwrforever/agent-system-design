# `contracts/thread_origin_contract.json`

> 逐字复制的真实源码（13 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```json
{
  "version": 1,
  "description": "Cross-language contract fixture for the server-owned run and thread origin. The Gateway stamps metadata[key] = {\"kind\": <one of kinds>, \"provider\"?: ..., \"namespace\"?: ...} on runs started by a server-side launcher, and on the thread when it creates one (backend/packages/harness/helix/runtime/run_origin.py); runs.origin_kind holds the kind. The frontend reads the same key to pick a thread's origin marker. Not to be confused with scheduled_origin_key in scheduled_goal_notes_contract.json, which marks the scheduled prompt message inside a run.",
  "key": "helix_origin",
  "kinds": [
    "extension",
    "github",
    "im_channel",
    "mcp_notification",
    "schedule"
  ]
}
```
