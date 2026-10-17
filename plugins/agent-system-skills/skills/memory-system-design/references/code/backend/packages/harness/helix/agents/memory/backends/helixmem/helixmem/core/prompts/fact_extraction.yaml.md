# `backend/packages/harness/helix/agents/memory/backends/helixmem/helixmem/core/prompts/fact_extraction.yaml`

> 逐字复制的真实源码（31 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```yaml
format: text
version: "1.0"
template: |-
  Extract factual information about the user from this message.

  Message:
  {message}

  Extract facts in this JSON format:
  {{
    "facts": [
      {{ "content": "...", "category": "preference|knowledge|context|behavior|cognitive|goal|correction", "confidence": 0.0-1.0 }}
    ]
  }}

  Categories:
  - preference: User preferences (likes/dislikes, styles, tools)
  - knowledge: User's expertise or knowledge areas
  - context: Background context (location, job, projects)
  - behavior: Behavioral patterns
  - cognitive: Stable reasoning, response-structure, and collaboration habits
  - goal: User's goals or objectives
  - correction: Explicit corrections or mistakes to avoid repeating

  Rules:
  - Only extract clear, specific facts
  - Confidence should reflect certainty (explicit statement = 0.9+, implied = 0.6-0.8)
  - Skip vague or temporary information

  Return ONLY valid JSON.
```
