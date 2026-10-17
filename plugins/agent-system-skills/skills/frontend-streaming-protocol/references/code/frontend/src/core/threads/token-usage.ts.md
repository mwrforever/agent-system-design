# `frontend/src/core/threads/token-usage.ts`

> 逐字复制的真实源码（48 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import type { TokenUsage } from "@/core/messages/usage";

import type { ThreadTokenUsageResponse } from "./types";

export function threadTokenUsageQueryKey(threadId?: string | null) {
  return ["thread-token-usage", threadId] as const;
}

export function retainThreadTokenUsagePlaceholder(
  previous: ThreadTokenUsageResponse | null | undefined,
  threadId?: string | null,
): ThreadTokenUsageResponse | undefined {
  return previous && previous.thread_id === threadId ? previous : undefined;
}

export function threadTokenUsageToTokenUsage(
  usage: ThreadTokenUsageResponse | null | undefined,
): TokenUsage | null {
  if (!usage) {
    return null;
  }
  return {
    inputTokens: usage.total_input_tokens ?? 0,
    outputTokens: usage.total_output_tokens ?? 0,
    totalTokens: usage.total_tokens ?? 0,
  };
}

export interface ContextUsage {
  tokenCount: number;
  maxContextTokens: number | null;
  percentage: number | null;
}

export function selectContextUsage(
  usage: ThreadTokenUsageResponse | null | undefined,
): ContextUsage | null {
  if (!usage?.context_usage) {
    return null;
  }
  const { token_count, max_context_tokens, percentage } = usage.context_usage;
  return {
    tokenCount: token_count ?? 0,
    maxContextTokens: max_context_tokens ?? null,
    percentage: percentage ?? null,
  };
}
```
