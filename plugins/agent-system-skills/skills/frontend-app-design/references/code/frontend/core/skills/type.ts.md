# `frontend/core/skills/type.ts`

> 逐字复制的真实源码（18 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
export interface Skill {
  name: string;
  description: string;
  category: string;
  license: string;
  enabled: boolean;
  editable: boolean;
}

export interface SkillLoadDiagnostic {
  package: string;
  path: "SKILL.md";
  code: "invalid_frontmatter";
  hint?: "quote_colon_value" | null;
  line?: number | null;
  column?: number | null;
}
```
