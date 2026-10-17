# `frontend/src/core/skills/hooks.ts`

> 逐字复制的真实源码（45 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { enableSkill, SkillRequestError, uploadSkillArchive } from "./api";

import { loadSkills } from ".";

export function useSkills() {
  const { data, isLoading, isFetching, error, refetch } = useQuery({
    queryKey: ["skills"],
    queryFn: () => loadSkills(),
    retry: (count, err) => !(err instanceof SkillRequestError) && count < 3,
  });
  return { skills: data ?? [], isLoading, isFetching, error, refetch };
}

export function useEnableSkill() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      skillName,
      enabled,
    }: {
      skillName: string;
      enabled: boolean;
    }) => {
      await enableSkill(skillName, enabled);
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["skills"] });
    },
  });
}

export function useUploadSkillArchive() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: uploadSkillArchive,
    onSuccess: (result) => {
      if (result.success) {
        void queryClient.invalidateQueries({ queryKey: ["skills"] });
      }
    },
  });
}
```
