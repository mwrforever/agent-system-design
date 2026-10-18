# `frontend/core/workspace-changes/hooks.ts`

> 逐字复制的真实源码（58 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { useQuery } from "@tanstack/react-query";

import { fetchWorkspaceChanges } from "./api";
import type { WorkspaceChangesResponse } from "./types";

export function workspaceChangesQueryKey(
  threadId: string | undefined,
  runId: string | undefined,
  includeFiles: boolean,
  includeDiff: boolean,
) {
  return [
    "workspace-changes",
    threadId,
    runId,
    includeFiles,
    includeDiff,
  ] as const;
}

export function useWorkspaceChanges({
  threadId,
  runId,
  includeFiles = true,
  includeDiff = true,
  enabled = true,
}: {
  threadId?: string;
  runId?: string;
  includeFiles?: boolean;
  includeDiff?: boolean;
  enabled?: boolean;
}) {
  return useQuery<WorkspaceChangesResponse>({
    queryKey: workspaceChangesQueryKey(
      threadId,
      runId,
      includeFiles,
      includeDiff,
    ),
    queryFn: () => {
      if (!threadId || !runId) {
        throw new Error("threadId and runId are required");
      }
      return fetchWorkspaceChanges({
        threadId,
        runId,
        includeFiles,
        includeDiff,
      });
    },
    enabled: enabled && Boolean(threadId) && Boolean(runId),
    retry: false,
    staleTime: 5 * 60 * 1000,
    refetchOnWindowFocus: false,
  });
}
```
