# `frontend/src/app/artifacts/view/layout.tsx`

> 逐字复制的真实源码（33 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```tsx
import "katex/dist/katex.min.css";
import "streamdown/styles.css";

import { QueryClientProvider } from "@/components/query-client-provider";
import { I18nProvider } from "@/core/i18n/context";
import { detectLocaleServer } from "@/core/i18n/server";

export const dynamic = "force-dynamic";

/**
 * Chrome-free layout for the standalone artifact window.
 *
 * Deliberately not nested under `/workspace`: this route opens in its own
 * browser window, so it wants the same rich-content styles as the chat page
 * but none of its sidebar/thread shell.
 *
 * The auth guard lives in the page rather than here. A layout cannot read
 * `searchParams`, and this route carries its whole target in the query string
 * — guarding here would redirect to /login with nothing to come back to.
 * No AuthProvider either: nothing under this route reads `useAuth`.
 */
export default async function ArtifactViewerLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const locale = await detectLocaleServer();

  return (
    <I18nProvider initialLocale={locale}>
      <QueryClientProvider>{children}</QueryClientProvider>
    </I18nProvider>
  );
}
```
