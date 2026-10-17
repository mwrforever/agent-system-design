# `frontend/src/core/integrations/lark/cache.ts`

> 逐字复制的真实源码（46 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { type QueryClient } from "@tanstack/react-query";

import { type LarkIntegrationStatus } from "./types";

export const larkIntegrationQueryKey = ["integrations", "lark"] as const;

type LarkIntegrationQueryClient = Pick<
  QueryClient,
  "cancelQueries" | "setQueryData" | "invalidateQueries"
>;

function hasUnprobedRuntime(status: LarkIntegrationStatus): boolean {
  return !status.sandbox_runtime_probed;
}

export async function cacheLarkMutationStatus(
  queryClient: LarkIntegrationQueryClient,
  status: LarkIntegrationStatus,
): Promise<void> {
  // Await the cancel so an in-flight status read fully settles before the
  // mutation snapshot lands: a fire-and-forget cancel loses to a GET whose
  // fetch already resolved but whose cache write is still queued, and that
  // stale write would clobber the fresher mutation status.
  await queryClient.cancelQueries({ queryKey: larkIntegrationQueryKey });
  queryClient.setQueryData<LarkIntegrationStatus>(
    larkIntegrationQueryKey,
    (current) =>
      current && hasUnprobedRuntime(status)
        ? {
            ...status,
            sandbox_runtime_mode: current.sandbox_runtime_mode,
            sandbox_runtime_probed: current.sandbox_runtime_probed,
            sandbox_runtime_ready: current.sandbox_runtime_ready,
            sandbox_runtime_detail: current.sandbox_runtime_detail,
          }
        : status,
  );
  if (hasUnprobedRuntime(status)) {
    // Unprobed means the response came from a backend that predates the
    // field. The cancelled in-flight GET carried the authoritative runtime
    // fields, so refetch instead of risking the conservative fallback
    // lingering until the next focus/remount.
    void queryClient.invalidateQueries({ queryKey: larkIntegrationQueryKey });
  }
}
```
