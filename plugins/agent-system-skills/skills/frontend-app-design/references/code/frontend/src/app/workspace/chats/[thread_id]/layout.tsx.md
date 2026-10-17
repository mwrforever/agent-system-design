# `frontend/src/app/workspace/chats/[thread_id]/layout.tsx`

> 逐字复制的真实源码（19 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```tsx
import { ChatProviders } from "@/components/workspace/chats/chat-providers";
import { isStaticWebsiteOnly } from "@/core/static-mode";
import { DEMO_THREAD_IDS } from "@/core/threads/static-demo";

export function generateStaticParams() {
  if (!isStaticWebsiteOnly()) {
    return [];
  }
  return DEMO_THREAD_IDS.map((thread_id) => ({ thread_id }));
}

export default function ChatLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return <ChatProviders>{children}</ChatProviders>;
}
```
