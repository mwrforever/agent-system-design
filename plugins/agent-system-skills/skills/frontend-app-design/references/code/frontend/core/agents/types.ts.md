# `frontend/core/agents/types.ts`

> 逐字复制的真实源码（67 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import type { KnowledgeScopeSnapshot } from "@/core/knowledge";

export interface AgentModelSettings {
  temperature?: number | null;
  max_tokens?: number | null;
}

export type ReasoningEffort = "low" | "medium" | "high";

export interface Agent {
  name: string;
  display_name?: string | null;
  description: string;
  model: string | null;
  tool_groups: string[] | null;
  skills: string[] | null;
  mcp_plugins?: string[] | null;
  knowledge_scope?: KnowledgeScopeSnapshot | null;
  allowed_subagents?: string[] | null;
  model_settings?: AgentModelSettings | null;
  thinking_enabled?: boolean | null;
  reasoning_effort?: ReasoningEffort | null;
  soul?: string | null;
}

export interface CreateAgentRequest {
  name: string;
  display_name?: string | null;
  description?: string;
  model?: string | null;
  tool_groups?: string[] | null;
  skills?: string[] | null;
  mcp_plugins?: string[] | null;
  knowledge_scope?: KnowledgeScopeSnapshot | null;
  allowed_subagents?: string[] | null;
  model_settings?: AgentModelSettings | null;
  thinking_enabled?: boolean | null;
  reasoning_effort?: ReasoningEffort | null;
  soul?: string;
}

export interface PortableAgentDefinition extends CreateAgentRequest {
  name: string;
  memory_enabled?: boolean;
}

export interface AgentPackage {
  format: "helix.custom-agent";
  version: 1;
  agent: PortableAgentDefinition;
}

export interface UpdateAgentRequest {
  display_name?: string | null;
  description?: string | null;
  model?: string | null;
  tool_groups?: string[] | null;
  skills?: string[] | null;
  mcp_plugins?: string[] | null;
  knowledge_scope?: KnowledgeScopeSnapshot | null;
  allowed_subagents?: string[] | null;
  model_settings?: AgentModelSettings | null;
  thinking_enabled?: boolean | null;
  reasoning_effort?: ReasoningEffort | null;
  soul?: string | null;
}
```
