# `frontend/core/subagents/types.ts`

> 逐字复制的真实源码（38 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
export type SubagentSource = "builtin" | "config" | "managed";

export interface Subagent {
  name: string;
  display_name: string | null;
  description: string;
  system_prompt: string | null;
  tools: string[] | null;
  disallowed_tools: string[] | null;
  skills: string[] | null;
  model: string;
  max_turns: number;
  timeout_seconds: number;
  enabled: boolean;
  source: SubagentSource;
  editable: boolean;
  conflict: boolean;
  config_overrides: Record<string, unknown>;
}

export interface CreateManagedSubagentRequest {
  name: string;
  display_name?: string | null;
  description: string;
  system_prompt: string;
  tools?: string[] | null;
  disallowed_tools?: string[] | null;
  skills?: string[] | null;
  model?: string;
  max_turns?: number;
  timeout_seconds?: number;
  enabled?: boolean;
}

export type UpdateManagedSubagentRequest = Partial<
  Omit<CreateManagedSubagentRequest, "name">
>;
```
