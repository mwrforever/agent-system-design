# `frontend/src/core/trash/types.ts`

> 逐字复制的真实源码（37 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import type { ProjectDocument } from "../projects/types";

/**
 * Origin snapshot written when a document is trashed (spec §6.1): display
 * label plus the restore-target hint for ``POST /api/trash/documents/{id}/restore``.
 */
export type TrashOrigin = {
  project_id: string;
  project_name: string;
};

/** One trashed shelf row as returned by ``GET /api/trash/documents``. */
export type TrashDocument = ProjectDocument & {
  trashed_at: string;
  trash_origin: TrashOrigin | null;
};

/**
 * Restore result (spec §8.2): ``merged`` means the target already had an
 * active row with the same content; ``document`` is then the surviving
 * active row, not the (deleted) trash row.
 */
export type RestoreOutcome = "restored" | "merged";

export type RestoreDocumentResult = {
  outcome: RestoreOutcome;
  document: ProjectDocument;
};

/**
 * Result of ``POST /api/trash/purge`` (empty trash): how many trashed
 * documents were permanently deleted.
 */
export type EmptyTrashResult = {
  purged: number;
};
```
