# `contracts/skill_review/waiver_manifest.v1.schema.json`

> 逐字复制的真实源码（39 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://helix.dev/contracts/skill_review/waiver_manifest.v1.schema.json",
  "title": "Helix Skill Review Waiver Manifest v1",
  "type": "object",
  "required": ["schema_version", "waivers"],
  "properties": {
    "schema_version": { "const": "helix.skill-review-waivers.v1" },
    "waivers": {
      "type": "array",
      "maxItems": 256,
      "items": {
        "type": "object",
        "required": ["package", "source", "rule_id", "path", "line", "evidence", "file_sha256", "reason", "expires_on"],
        "properties": {
          "package": { "type": "string", "pattern": "^skills/public/", "minLength": 15 },
          "source": { "type": "string", "minLength": 1 },
          "rule_id": { "type": "string", "minLength": 1 },
          "path": { "type": "string", "minLength": 1 },
          "line": { "type": "integer", "minimum": 1 },
          "evidence": { "type": "string", "minLength": 1 },
          "file_sha256": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" },
          "preapproved_file_sha256s": {
            "type": "array",
            "maxItems": 8,
            "uniqueItems": true,
            "items": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" }
          },
          "reason": { "type": "string", "minLength": 20 },
          "expires_on": { "type": "string", "format": "date" },
          "approved_in": { "type": "string", "minLength": 1 }
        },
        "additionalProperties": false
      }
    }
  },
  "additionalProperties": false
}
```
