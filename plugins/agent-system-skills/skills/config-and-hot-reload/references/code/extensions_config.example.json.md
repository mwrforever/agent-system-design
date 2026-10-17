# `extensions_config.example.json`

> 逐字复制的真实源码（96 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```json
{
  "middlewares": [],
  "mcpInterceptors": [
    "my_package.mcp.auth:build_auth_interceptor"
  ],
  "mcpServers": {
    "github": {
      "enabled": false,
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-github"
      ],
      "env": {
        "GITHUB_TOKEN": "$GITHUB_TOKEN"
      },
      "tool_name_prefix": true,
      "session_init_timeout": 60,
      "tool_call_timeout": 60,
      "description": "GitHub MCP server for repository operations"
    },
    "parallel-search": {
      "enabled": false,
      "type": "http",
      "url": "https://search.parallel.ai/mcp",
      "headers": {
        "User-Agent": "helix"
      },
      "description": "Optional anonymous Parallel Search tools for web search and fetching requested URLs"
    },
    "openviking": {
      "enabled": false,
      "type": "http",
      "url": "http://127.0.0.1:1933/mcp",
      "headers": {
        "X-API-Key": "$OPENVIKING_API_KEY"
      },
      "description": "Official OpenViking tools for explicit memory and resource operations"
    },
    "postgres": {
      "enabled": false,
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-postgres",
        "postgresql://localhost/mydb"
      ],
      "env": {},
      "description": "PostgreSQL database access",
      "routing": {
        "mode": "prefer",
        "priority": 50,
        "keywords": [
          "database",
          "SQL",
          "table",
          "订单",
          "用户"
        ]
      },
      "tools": {
        "query": {
          "routing": {
            "mode": "prefer",
            "priority": 100,
            "keywords": [
              "查库",
              "订单表",
              "指标"
            ]
          }
        }
      }
    },
    "long-running-reports": {
      "enabled": false,
      "type": "http",
      "url": "https://reports.example.com/mcp",
      "description": "Example ordinary MCP background-task contract",
      "session_init_timeout": 60,
      "tool_call_timeout": 60,
      "task_toolsets": [
        {
          "name": "report-generation",
          "submit_tool": "submit_report",
          "status_tool": "get_report_status",
          "cancel_tool": "cancel_report"
        }
      ]
    }
  },
  "skills": {}
}
```
