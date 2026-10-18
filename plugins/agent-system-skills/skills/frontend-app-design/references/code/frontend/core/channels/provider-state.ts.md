# `frontend/core/channels/provider-state.ts`

> 逐字复制的真实源码（40 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import type { Translations } from "@/core/i18n/locales/types";

import type { ChannelProvider } from "./types";

/**
 * The provider's name in the UI language ("企业微信", not the backend's
 * English "WeCom"), the same label the thread origin markers use. Providers
 * without a localized label keep the backend `display_name`.
 */
export function channelProviderName(
  provider: Pick<ChannelProvider, "provider" | "display_name">,
  t: Pick<Translations, "threads">,
): string {
  const localized: Record<string, string> = t.threads.origin.providers;
  return Object.hasOwn(localized, provider.provider)
    ? localized[provider.provider]!
    : provider.display_name;
}

export function providerCanConnect(provider: ChannelProvider): boolean {
  return (
    (provider.connectable ?? (provider.enabled && provider.configured)) &&
    provider.connection_status !== "connected"
  );
}

export function providerNeedsRuntimeConfig(provider: ChannelProvider): boolean {
  return (
    provider.enabled &&
    !provider.configured &&
    (provider.credential_fields?.length ?? 0) > 0
  );
}

export function providerCanEditRuntimeConfig(
  provider: ChannelProvider,
): boolean {
  return provider.enabled && (provider.credential_fields?.length ?? 0) > 0;
}
```
