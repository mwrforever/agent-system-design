# `frontend/core/memory/normalize.ts`

> 逐字复制的真实源码（14 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { normalizeMemoryPayload } from "./import-memory";
import type { UserMemory } from "./types";

/** Normalize API/import payloads (unknown → UserMemory). Throws if invalid. */
export function normalizeUserMemory(value: unknown): UserMemory {
  const normalized = normalizeMemoryPayload(value, {
    invalidFactStrategy: "drop",
  });
  if (!normalized) {
    throw new Error("Invalid memory payload");
  }
  return normalized;
}
```
