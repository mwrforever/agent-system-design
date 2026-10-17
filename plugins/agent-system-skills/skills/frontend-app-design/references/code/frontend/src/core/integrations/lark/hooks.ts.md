# `frontend/src/core/integrations/lark/hooks.ts`

> 逐字复制的真实源码（65 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import {
  completeLarkAuthorization,
  completeLarkConfiguration,
  installLarkIntegration,
  loadLarkIntegrationStatus,
  setLarkAppCredentials,
  startLarkAuthorization,
  startLarkConfiguration,
} from "./api";
import { cacheLarkMutationStatus, larkIntegrationQueryKey } from "./cache";

export function useLarkIntegrationStatus() {
  return useQuery({
    queryKey: larkIntegrationQueryKey,
    queryFn: ({ signal }) => loadLarkIntegrationStatus(signal),
  });
}

export function useInstallLarkIntegration() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: installLarkIntegration,
    onSuccess: async (result) => {
      await cacheLarkMutationStatus(queryClient, result.status);
      await queryClient.invalidateQueries({
        queryKey: larkIntegrationQueryKey,
      });
      await queryClient.invalidateQueries({ queryKey: ["skills"] });
      await queryClient.invalidateQueries({ queryKey: ["capabilities"] });
    },
  });
}

export function useStartLarkAuthorization() {
  return useMutation({
    mutationFn: startLarkAuthorization,
  });
}

export function useStartLarkConfiguration() {
  return useMutation({
    mutationFn: startLarkConfiguration,
  });
}

export function useCompleteLarkConfiguration() {
  return useMutation({
    mutationFn: completeLarkConfiguration,
  });
}

export function useSetLarkAppCredentials() {
  return useMutation({
    mutationFn: setLarkAppCredentials,
  });
}

export function useCompleteLarkAuthorization() {
  return useMutation({
    mutationFn: completeLarkAuthorization,
  });
}
```
