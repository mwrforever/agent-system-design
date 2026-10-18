# `frontend/core/workspace-changes/types.ts`

> 逐字复制的真实源码（51 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
export type WorkspaceChangeStatus =
  | "created"
  | "modified"
  | "deleted"
  | "symlink_created";

export type DiffUnavailableReason =
  | "binary"
  | "large"
  | "sensitive"
  | "truncated"
  | "symlink";

export interface WorkspaceChangeSummary {
  created: number;
  modified: number;
  deleted: number;
  symlink_created: number;
  additions: number;
  deletions: number;
  truncated: boolean;
}

export interface WorkspaceFileChange {
  path: string;
  root: string;
  status: WorkspaceChangeStatus;
  binary: boolean;
  sensitive: boolean;
  size_before: number | null;
  size_after: number | null;
  sha256_before: string | null;
  sha256_after: string | null;
  diff: string;
  diff_truncated: boolean;
  diff_unavailable_reason: DiffUnavailableReason | null;
  additions: number;
  deletions: number;
  symlink: boolean;
  symlink_target_before: string | null;
  symlink_target_after: string | null;
}

export interface WorkspaceChangesResponse {
  available: boolean;
  version: number;
  summary: WorkspaceChangeSummary;
  files: WorkspaceFileChange[];
  limits: Record<string, unknown>;
}
```
