# `frontend/src/app/api/memory/route.ts`

> 逐字复制的真实源码（38 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import type { NextRequest } from "next/server";

const BACKEND_BASE_URL =
  process.env.NEXT_PUBLIC_BACKEND_BASE_URL ?? "http://127.0.0.1:8001";

function buildBackendUrl(request: NextRequest, pathname: string) {
  const url = new URL(pathname, BACKEND_BASE_URL);
  url.search = request.nextUrl.search;
  return url;
}

async function proxyRequest(request: NextRequest, pathname: string) {
  const headers = new Headers(request.headers);
  headers.delete("host");
  headers.delete("connection");
  headers.delete("content-length");

  const hasBody = !["GET", "HEAD"].includes(request.method);
  const response = await fetch(buildBackendUrl(request, pathname), {
    method: request.method,
    headers,
    body: hasBody ? await request.arrayBuffer() : undefined,
  });

  return new Response(await response.arrayBuffer(), {
    status: response.status,
    headers: response.headers,
  });
}

export async function GET(request: NextRequest) {
  return proxyRequest(request, "/api/memory");
}

export async function DELETE(request: NextRequest) {
  return proxyRequest(request, "/api/memory");
}
```
