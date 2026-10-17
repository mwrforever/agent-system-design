# `contracts/subagent_status_contract.json`

> 逐字复制的真实源码（7 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```json
{
  "version": 2,
  "description": "Cross-language contract fixture for the structured subagent status field. Task result text is display content only and is not part of this wire contract. The optional subagent_stop_reason field (v2, #3875 Phase 2) carries why a guardrail cap ended a run early; it is ignored by older consumers that only read subagent_status.",
  "valid_status_values": ["completed", "failed", "cancelled", "timed_out", "polling_timed_out"],
  "valid_stop_reason_values": ["token_capped", "turn_capped", "loop_capped"]
}
```
