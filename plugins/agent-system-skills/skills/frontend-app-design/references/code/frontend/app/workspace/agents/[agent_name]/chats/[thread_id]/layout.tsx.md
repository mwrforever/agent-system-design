# `frontend/app/workspace/agents/[agent_name]/chats/[thread_id]/layout.tsx`

> 逐字复制的真实源码（12 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```tsx
"use client";

import { ChatProviders } from "@/components/workspace/chats/chat-providers";

export default function AgentChatLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return <ChatProviders>{children}</ChatProviders>;
}
```
