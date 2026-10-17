# `frontend/src/core/capabilities/types.ts`

> 逐字复制的真实源码（54 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
export type LocalizedText = Record<string, string>;
export type PluginCategory =
  | "office"
  | "knowledge"
  | "research"
  | "business"
  | "development"
  | "custom";
export interface PluginManifest {
  schema_version: 1;
  id: string;
  version: string;
  name: LocalizedText;
  description: LocalizedText;
  setup: LocalizedText;
  category: PluginCategory;
  kind: "mcp" | "cli" | "native";
  adapter: string;
  source: string;
  icon: string | null;
  aliases: string[];
  auth_methods: string[];
  contributions: ("tools" | "skills")[];
  config_schema: {
    type: string;
    properties?: Record<
      string,
      { type: string; title?: string; format?: string }
    >;
    required?: string[];
  };
}
export interface CapabilityInstallation {
  id: string;
  plugin_id: string | null;
  adapter: string;
  name: string;
  description: string;
  reference: string;
  selectable?: boolean;
  installed: boolean;
  enabled: boolean | null;
  version: string | null;
  scope: string;
  auth_status: string;
  health: string;
  category: string | null;
  icon: string | null;
}
export interface InstallationList {
  items: CapabilityInstallation[];
  can_manage: boolean;
}
```
