# `frontend/core/i18n/context.tsx`

> 逐字复制的真实源码（64 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```tsx
"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";

import type { Locale } from "@/core/i18n";
import type { Translations } from "@/core/i18n/locales";
import { useSyncLocalePreference } from "@/core/settings/user-preferences";

import { clientTranslations } from "./client-translations";

export interface I18nContextType {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: Translations;
}

export const I18nContext = createContext<I18nContextType | null>(null);

export function I18nProvider({
  children,
  initialLocale,
}: {
  children: ReactNode;
  initialLocale: Locale;
}) {
  const [locale, setLocale] = useState<Locale>(initialLocale);
  const [t, setTranslations] = useState<Translations>(
    clientTranslations[initialLocale],
  );

  const handleSetLocale = useCallback((newLocale: Locale) => {
    setLocale(newLocale);
    setTranslations(clientTranslations[newLocale]);
  }, []);

  useEffect(() => {
    document.documentElement.lang = locale;
  }, [locale]);

  // The account's notification language follows the UI language.
  useSyncLocalePreference(locale);

  return (
    <I18nContext.Provider value={{ locale, setLocale: handleSetLocale, t }}>
      {children}
    </I18nContext.Provider>
  );
}

export function useI18nContext() {
  const context = useContext(I18nContext);
  if (!context) {
    throw new Error("useI18n must be used within I18nProvider");
  }
  return context;
}
```
