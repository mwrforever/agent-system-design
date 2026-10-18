# `frontend/core/features/hooks.ts`

> 逐字复制的真实源码（136 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { useQuery } from "@tanstack/react-query";

import {
  DEFAULT_SCHEDULED_TASKS_FEATURE,
  DEFAULT_THREAD_ACTIVITY_FEATURE,
  fetchBrowserControlEnabled,
  fetchConversationReferencesCapability,
  fetchKnowledgeBaseFeature,
  fetchMcpTasksEnabled,
  fetchScheduledTasksFeature,
  fetchSubagentBatchesCapability,
  fetchThreadActivityFeature,
} from "./api";

export function useBrowserControlEnabled() {
  const { data, isPending } = useQuery({
    queryKey: ["features", "browser_control"],
    queryFn: () => fetchBrowserControlEnabled(),
    staleTime: 0,
    refetchOnMount: true,
    retry: false,
  });

  return {
    enabled: data ?? false,
    isLoading: isPending,
  };
}

export function useMcpTasksEnabled() {
  const { data, isPending } = useQuery({
    queryKey: ["features", "mcp_tasks"],
    queryFn: () => fetchMcpTasksEnabled(),
    staleTime: 0,
    refetchOnMount: true,
    retry: false,
  });

  return {
    enabled: data ?? false,
    isLoading: isPending,
  };
}

export function useSubagentBatchesCapability() {
  const { data, isPending } = useQuery({
    queryKey: ["features", "subagent_batches"],
    queryFn: () => fetchSubagentBatchesCapability(),
    staleTime: 0,
    refetchOnMount: true,
    retry: false,
  });
  return {
    repositoryAvailable: data?.repositoryAvailable ?? false,
    workerRunning: data?.workerRunning ?? false,
    maxRunning: data?.maxRunning ?? 0,
    isLoading: isPending,
  };
}

export function useConversationReferencesCapability() {
  const { data, isPending, isSuccess, error, refetch } = useQuery({
    queryKey: ["features", "conversation_references"],
    queryFn: () => fetchConversationReferencesCapability(),
    staleTime: 0,
    refetchOnMount: true,
    retry: false,
  });
  return {
    enabled: isSuccess && (data?.enabled ?? false),
    maxReferences: data?.maxReferences ?? 0,
    isLoading: isPending,
    isSuccess,
    error,
    refetch,
  };
}

export function useKnowledgeBaseEnabled() {
  const { data, isPending } = useQuery({
    queryKey: ["features", "knowledge_base"],
    queryFn: fetchKnowledgeBaseFeature,
    staleTime: 0,
    refetchOnMount: true,
    retry: false,
  });
  return {
    scopeSelectionEnabled: data?.scopeSelectionEnabled ?? false,
    isLoading: isPending,
  };
}

/**
 * Scheduled-task availability. While loading, or when the request fails, the
 * defaults apply (available and running, chat tool off), so the page never
 * flashes an "unavailable" state on a working server.
 */
export function useScheduledTasksFeature() {
  const { data, isPending } = useQuery({
    queryKey: ["features", "scheduled_tasks"],
    queryFn: fetchScheduledTasksFeature,
    staleTime: 0,
    refetchOnMount: true,
    retry: false,
  });
  const feature = data ?? DEFAULT_SCHEDULED_TASKS_FEATURE;
  return {
    available: feature.available,
    running: feature.running,
    toolEnabled: feature.toolEnabled,
    groupNotifications: feature.groupNotifications,
    minIntervalSeconds: feature.minIntervalSeconds,
    isLoading: isPending,
  };
}

/**
 * Thread activity (origin markers' live refresh, read markers, unread). Off
 * while loading, on error and on servers without the block, so nothing polls
 * or posts against a backend that lacks the endpoints.
 */
export function useThreadActivityFeature() {
  const { data, isPending } = useQuery({
    queryKey: ["features", "thread_activity"],
    queryFn: fetchThreadActivityFeature,
    staleTime: 0,
    refetchOnMount: true,
    retry: false,
  });
  const feature = data ?? DEFAULT_THREAD_ACTIVITY_FEATURE;
  return {
    available: feature.available,
    isLoading: isPending,
  };
}
```
