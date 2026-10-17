# `frontend/src/core/mcp/types.ts`

> 逐字复制的真实源码（11 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
export interface MCPServerConfig extends Record<string, unknown> {
  enabled: boolean;
  description: string;
  /** Display-only metadata; never passed to the MCP transport. */
  presentation?: Record<string, unknown>;
}

export interface MCPConfig {
  mcp_servers: Record<string, MCPServerConfig>;
}
```
