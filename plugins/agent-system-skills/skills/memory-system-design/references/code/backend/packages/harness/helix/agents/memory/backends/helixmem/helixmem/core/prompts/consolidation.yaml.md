# `backend/packages/harness/helix/agents/memory/backends/helixmem/helixmem/core/prompts/consolidation.yaml`

> 逐字复制的真实源码（27 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
format: text
version: "1.0"
template: |-
  ## Memory Consolidation

  The following fact categories have accumulated many individual entries.
  Review each group and identify facts that can be synthesized into a single,
  richer consolidated fact that preserves all key information.

  {consolidation_groups}

  For each group, decide:
  - CONSOLIDATE: Multiple facts can be merged into one richer fact.
    Specify the source fact IDs and the consolidated content.
  - SKIP: Facts are distinct enough to remain separate.

  Add consolidation decisions to "factsToConsolidate" in your output JSON.
  Each entry: {{"sourceIds": ["fact_id_1", "fact_id_2"], "consolidated": {{"content": "...", "category": "...", "confidence": 0.9, "scope": "user|thread|project", "durability": "durable|temporary", "authority": "descriptive|transactional"}}}}

  Rules:
  - The consolidated fact must preserve ALL key details from source facts
  - Only consolidate facts that describe the same aspect of the user
  - Classify every consolidated fact. It is eligible only when it is user-scoped, durable, descriptive, and safe to inject into unrelated future threads.
  - Confidence of consolidated fact = max of source confidences
  - Be conservative - when in doubt, keep facts separate
  - Maximum {max_groups} consolidation groups per cycle
```
