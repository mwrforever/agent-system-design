# `frontend/core/workspace-changes/api.ts`

> 逐字复制的真实源码（36 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { fetch } from "@/core/api/fetcher";
import { getBackendBaseURL } from "@/core/config";

import type { WorkspaceChangesResponse } from "./types";

export async function fetchWorkspaceChanges({
  threadId,
  runId,
  includeFiles = true,
  includeDiff = true,
}: {
  threadId: string;
  runId: string;
  includeFiles?: boolean;
  includeDiff?: boolean;
}): Promise<WorkspaceChangesResponse> {
  const query = new URLSearchParams({
    include_files: includeFiles ? "true" : "false",
    include_diff: includeDiff ? "true" : "false",
  });
  const response = await fetch(
    `${getBackendBaseURL()}/api/threads/${encodeURIComponent(
      threadId,
    )}/runs/${encodeURIComponent(runId)}/workspace-changes?${query}`,
  );

  if (!response.ok) {
    const error = await response
      .json()
      .catch(() => ({ detail: "Failed to load workspace changes." }));
    throw new Error(error.detail ?? "Failed to load workspace changes.");
  }

  return response.json();
}
```
