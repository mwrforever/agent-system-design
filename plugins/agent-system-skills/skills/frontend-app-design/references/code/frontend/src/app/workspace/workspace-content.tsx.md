# `frontend/src/app/workspace/workspace-content.tsx`

> 逐字复制的真实源码（55 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```tsx
import { cookies } from "next/headers";
import { Toaster } from "sonner";

import { QueryClientProvider } from "@/components/query-client-provider";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
import { CommandPalette } from "@/components/workspace/command-palette";
import { GatewayOfflineBanner } from "@/components/workspace/gateway-offline-banner";
import { ModelLoadErrorBanner } from "@/components/workspace/model-load-error-banner";
import { SettingsDialogHost } from "@/components/workspace/settings";
import { WorkspaceSettingsDeepLink } from "@/components/workspace/workspace-settings-deep-link";
import { WorkspaceSidebar } from "@/components/workspace/workspace-sidebar";
import { ExtensionPageBootstrap } from "@/core/extensions/hooks";
import { UserPreferencesBoundary } from "@/core/settings/user-preferences-boundary";

function parseSidebarOpenCookie(
  value: string | undefined,
): boolean | undefined {
  if (value === "true") return true;
  if (value === "false") return false;
  return undefined;
}

export async function WorkspaceContent({
  children,
  gatewayUnavailable = false,
}: Readonly<{
  children: React.ReactNode;
  gatewayUnavailable?: boolean;
}>) {
  const cookieStore = await cookies();
  const initialSidebarOpen = parseSidebarOpenCookie(
    cookieStore.get("sidebar_state")?.value,
  );

  return (
    <QueryClientProvider>
      <UserPreferencesBoundary>
        <ExtensionPageBootstrap />
        <SidebarProvider className="h-screen" defaultOpen={initialSidebarOpen}>
          <WorkspaceSidebar />
          <SidebarInset className="min-w-0">
            <GatewayOfflineBanner gatewayUnavailable={gatewayUnavailable} />
            <ModelLoadErrorBanner gatewayUnavailable={gatewayUnavailable} />
            {children}
          </SidebarInset>
        </SidebarProvider>
        <CommandPalette />
        <SettingsDialogHost />
        <WorkspaceSettingsDeepLink />
        <Toaster position="top-center" />
      </UserPreferencesBoundary>
    </QueryClientProvider>
  );
}
```
