# `frontend/src/core/artifacts/delimited-preview-types.ts`

> 逐字复制的真实源码（22 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
export const DELIMITED_INPUT_LIMIT = 1_048_576;
export const DELIMITED_RECORD_LIMIT = 202;
export const DELIMITED_COLUMN_LIMIT = 50;
export const DELIMITED_TIMEOUT_MS = 5_000;

export interface DelimitedPreviewInput {
  content: string;
  delimiter: "," | "\t";
  truncated: boolean;
}

export interface DelimitedPreviewResult {
  rows: string[][];
  columnCount: number;
  limited: boolean;
  unevenRows: boolean;
}

export type DelimitedPreviewResponse =
  | { result: DelimitedPreviewResult }
  | { error: string };
```
