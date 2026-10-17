# `frontend/src/app/showcase/[thread_id]/layout.tsx`

> 逐字复制的真实源码（35 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```tsx
import "katex/dist/katex.min.css";
import "streamdown/styles.css";

import { Toaster } from "sonner";

import { QueryClientProvider } from "@/components/query-client-provider";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
import { ChatProviders } from "@/components/workspace/chats/chat-providers";
import { AuthProvider } from "@/core/auth/AuthProvider";
import { I18nProvider } from "@/core/i18n/context";
import { detectLocaleServer } from "@/core/i18n/server";

export default async function PublicShowcaseLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const locale = await detectLocaleServer();

  return (
    <I18nProvider initialLocale={locale}>
      <AuthProvider initialUser={null} initialAuthUnknown>
        <QueryClientProvider>
          <SidebarProvider className="h-screen" defaultOpen={false}>
            <SidebarInset className="min-w-0">
              <ChatProviders>{children}</ChatProviders>
            </SidebarInset>
          </SidebarProvider>
          <Toaster position="top-center" />
        </QueryClientProvider>
      </AuthProvider>
    </I18nProvider>
  );
}
```
