# `contracts/skill_review/package_snapshot.v1.schema.json`

> 逐字复制的真实源码（51 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://helix.dev/contracts/skill_review/package_snapshot.v1.schema.json",
  "title": "Helix Skill Package Snapshot v1",
  "type": "object",
  "required": ["schema_version", "subject", "limits", "files", "truncated", "reader_errors"],
  "properties": {
    "schema_version": { "const": "helix.skill-package-snapshot.v1" },
    "subject": {
      "type": "object",
      "required": ["source", "display_ref"],
      "properties": {
        "source": { "type": "string" },
        "category": { "type": ["string", "null"] },
        "name_hint": { "type": ["string", "null"] },
        "display_ref": { "type": "string" }
      },
      "additionalProperties": true
    },
    "limits": {
      "type": "object",
      "required": ["max_files", "max_file_bytes", "max_total_bytes"],
      "properties": {
        "max_files": { "type": "integer", "minimum": 1 },
        "max_file_bytes": { "type": "integer", "minimum": 1 },
        "max_total_bytes": { "type": "integer", "minimum": 1 }
      }
    },
    "files": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["path", "kind", "size", "sha256"],
        "properties": {
          "path": { "type": "string" },
          "kind": { "enum": ["text", "binary", "symlink"] },
          "size": { "type": "integer", "minimum": 0 },
          "sha256": { "type": "string" },
          "content": { "type": ["string", "null"] },
          "content_base64": { "type": "string", "contentEncoding": "base64" },
          "target": { "type": "string" }
        },
        "additionalProperties": true
      }
    },
    "truncated": { "type": "boolean" },
    "reader_errors": { "type": "array", "items": { "type": "object" } }
  },
  "additionalProperties": true
}
```
