# `frontend/core/artifacts/delimited-preview.worker.ts`

> 逐字复制的真实源码（16 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { parseDelimitedPreview } from "./delimited-preview";
import {
  type DelimitedPreviewInput,
  type DelimitedPreviewResponse,
} from "./delimited-preview-types";

self.onmessage = (event: MessageEvent<DelimitedPreviewInput>) => {
  let response: DelimitedPreviewResponse;
  try {
    response = { result: parseDelimitedPreview(event.data) };
  } catch {
    response = { error: "Unable to reliably preview this delimited file" };
  }
  self.postMessage(response);
};
```
