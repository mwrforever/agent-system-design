# `frontend/src/app/workspace/page.tsx`

> 逐字复制的真实源码（12 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```tsx
import { redirect } from "next/navigation";

import { DEMO_THREAD_IDS } from "@/core/threads/static-demo";
import { env } from "@/env";

export default function WorkspacePage() {
  if (env.NEXT_PUBLIC_STATIC_WEBSITE_ONLY === "true") {
    return redirect(`/workspace/chats/${DEMO_THREAD_IDS[0]}`);
  }
  return redirect("/workspace/chats/new");
}
```
