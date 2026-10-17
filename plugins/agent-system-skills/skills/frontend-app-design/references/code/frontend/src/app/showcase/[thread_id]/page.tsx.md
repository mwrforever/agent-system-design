# `frontend/src/app/showcase/[thread_id]/page.tsx`

> 逐字复制的真实源码（23 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```tsx
import { notFound } from "next/navigation";

import ChatPage from "@/components/workspace/chats/chat-page";
import { DEMO_THREAD_IDS, isDemoThreadId } from "@/core/threads/static-demo";

export const dynamicParams = false;

export function generateStaticParams() {
  return DEMO_THREAD_IDS.map((thread_id) => ({ thread_id }));
}

export default async function PublicShowcasePage({
  params,
}: {
  params: Promise<{ thread_id: string }>;
}) {
  const { thread_id: threadId } = await params;
  if (!isDemoThreadId(threadId)) {
    notFound();
  }
  return <ChatPage />;
}
```
