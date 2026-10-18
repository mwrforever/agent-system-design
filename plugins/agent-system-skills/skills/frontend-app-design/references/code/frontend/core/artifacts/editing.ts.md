# `frontend/core/artifacts/editing.ts`

> 逐字复制的真实源码（68 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
export interface ArtifactDraftState {
  filepath: string;
  baselineContent: string;
  baselineSha256: string | null;
  draftContent: string;
  conflict: boolean;
}

export function createArtifactDraft(filepath: string): ArtifactDraftState {
  return {
    filepath,
    baselineContent: "",
    baselineSha256: null,
    draftContent: "",
    conflict: false,
  };
}

export function reconcileArtifactDraft(
  current: ArtifactDraftState,
  loaded: { content: string; sha256: string },
): ArtifactDraftState {
  if (loaded.sha256 === current.baselineSha256) {
    return current;
  }
  if (current.draftContent !== current.baselineContent) {
    return { ...current, conflict: true };
  }
  return {
    ...current,
    baselineContent: loaded.content,
    baselineSha256: loaded.sha256,
    draftContent: loaded.content,
    conflict: false,
  };
}

export function canEditOpenedArtifact({
  filepath,
  isCodeFile,
  isWriteFile,
  isSkillFile,
  isMock,
  hasRevision,
  isStaticWebsite,
}: {
  filepath: string;
  isCodeFile: boolean;
  isWriteFile: boolean;
  isSkillFile: boolean;
  isMock: boolean;
  hasRevision: boolean;
  isStaticWebsite: boolean;
}): boolean {
  const isOutputArtifact = filepath
    .replace(/^\/+/, "")
    .startsWith("mnt/user-data/outputs/");
  return (
    isCodeFile &&
    !isWriteFile &&
    !isSkillFile &&
    !isMock &&
    hasRevision &&
    !isStaticWebsite &&
    isOutputArtifact
  );
}
```
