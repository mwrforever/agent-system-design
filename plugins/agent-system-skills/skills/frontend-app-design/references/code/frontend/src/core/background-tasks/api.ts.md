# `frontend/src/core/background-tasks/api.ts`

> 逐字复制的真实源码（56 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { throwGatewayApiError } from "@/core/api/errors";
import { fetch } from "@/core/api/fetcher";
import { getBackendBaseURL } from "@/core/config";

import type { BackgroundTask, BackgroundTaskDetail } from "./types";

function threadTasksUrl(threadId: string, path = ""): string {
  return `${getBackendBaseURL()}/api/threads/${encodeURIComponent(threadId)}/mcp-tasks${path}`;
}

export async function fetchBackgroundTasks(
  threadId: string,
): Promise<BackgroundTask[]> {
  const response = await fetch(`${threadTasksUrl(threadId)}?limit=20`);
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to load background tasks: ${response.statusText}`,
    );
  }
  return response.json();
}

export async function fetchBackgroundTask(
  threadId: string,
  taskId: string,
): Promise<BackgroundTaskDetail> {
  const response = await fetch(
    threadTasksUrl(threadId, `/${encodeURIComponent(taskId)}`),
  );
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to load background task: ${response.statusText}`,
    );
  }
  return response.json();
}

export async function cancelBackgroundTask(
  threadId: string,
  taskId: string,
): Promise<BackgroundTaskDetail> {
  const response = await fetch(
    threadTasksUrl(threadId, `/${encodeURIComponent(taskId)}/cancel`),
    { method: "POST" },
  );
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to cancel background task: ${response.statusText}`,
    );
  }
  return response.json();
}
```
