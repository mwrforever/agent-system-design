# `frontend/src/core/background-tasks/hooks.ts`

> 逐字复制的真实源码（86 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { useI18n } from "@/core/i18n/hooks";

import {
  cancelBackgroundTask,
  fetchBackgroundTask,
  fetchBackgroundTasks,
} from "./api";
import {
  isActiveBackgroundTask,
  shouldPollBackgroundTaskDetail,
} from "./types";

export const backgroundTasksQueryKey = (threadId: string) =>
  ["background-tasks", threadId] as const;

export const backgroundTaskQueryKey = (threadId: string, taskId: string) =>
  [...backgroundTasksQueryKey(threadId), taskId] as const;

export function useBackgroundTasks(
  threadId: string,
  options: { enabled?: boolean } = {},
) {
  return useQuery({
    queryKey: backgroundTasksQueryKey(threadId),
    queryFn: () => fetchBackgroundTasks(threadId),
    enabled: options.enabled !== false && Boolean(threadId),
    refetchInterval: (query) =>
      query.state.data?.some(isActiveBackgroundTask) ? 3000 : 15000,
    refetchIntervalInBackground: false,
  });
}

export function useBackgroundTask(
  threadId: string,
  taskId: string,
  options: { enabled?: boolean } = {},
) {
  return useQuery({
    queryKey: backgroundTaskQueryKey(threadId, taskId),
    queryFn: () => fetchBackgroundTask(threadId, taskId),
    enabled: options.enabled !== false && Boolean(threadId) && Boolean(taskId),
    refetchInterval: (query) =>
      query.state.data && shouldPollBackgroundTaskDetail(query.state.data)
        ? 3000
        : false,
    refetchIntervalInBackground: false,
  });
}

export function useCancelBackgroundTask(threadId: string) {
  const queryClient = useQueryClient();
  const { t } = useI18n();
  return useMutation({
    mutationFn: (taskId: string) => cancelBackgroundTask(threadId, taskId),
    onSuccess: (task) => {
      queryClient.setQueryData(
        backgroundTaskQueryKey(threadId, task.task_id),
        task,
      );
      queryClient.setQueryData(
        backgroundTasksQueryKey(threadId),
        (current: unknown) =>
          Array.isArray(current)
            ? current.map((item) =>
                typeof item === "object" &&
                item !== null &&
                "task_id" in item &&
                item.task_id === task.task_id
                  ? task
                  : item,
              )
            : current,
      );
      void queryClient.invalidateQueries({
        queryKey: backgroundTasksQueryKey(threadId),
      });
    },
    onError: (error: Error) => {
      toast.error(`${t.backgroundTasks.cancelFailed}: ${error.message}`);
    },
  });
}
```
