# `contracts/knowledge_sources.v1.json`

> 逐字复制的真实源码（36 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Shared retrieval source envelope v1",
  "description": "Server-owned tool evidence; readers also require the handle and excerpt in tool content. Mixed native RAGFlow artifacts carry this array under retrieval_sources.",
  "type": "object",
  "required": ["knowledge_sources_version", "knowledge_sources"],
  "properties": {
    "knowledge_sources_version": { "const": 1, "type": "integer" },
    "knowledge_sources": {
      "type": "array",
      "maxItems": 100,
      "items": { "$ref": "#/$defs/source" }
    }
  },
  "$defs": {
    "source": {
      "type": "object",
      "required": ["id", "provider", "title", "excerpt"],
      "properties": {
        "id": { "type": "string", "pattern": "^[a-f0-9]{32}$" },
        "provider": { "type": "string", "minLength": 1, "maxLength": 100 },
        "title": { "type": "string", "minLength": 1, "maxLength": 500 },
        "excerpt": { "type": "string", "minLength": 1, "maxLength": 100000 },
        "dataset_name": { "type": "string", "maxLength": 500 },
        "url": {
          "type": "string",
          "format": "uri",
          "pattern": "^https?://",
          "description": "No username or password allowed."
        },
        "page": { "type": "integer", "minimum": 1, "maximum": 9007199254740991 }
      }
    }
  }
}
```
