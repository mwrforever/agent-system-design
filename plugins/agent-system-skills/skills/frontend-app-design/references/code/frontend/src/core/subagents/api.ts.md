# `frontend/src/core/subagents/api.ts`

> 逐字复制的真实源码（72 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
import { fetch } from "@/core/api/fetcher";
import { getBackendBaseURL } from "@/core/config";

import type {
  CreateManagedSubagentRequest,
  Subagent,
  UpdateManagedSubagentRequest,
} from "./types";

async function errorDetail(res: Response, fallback: string): Promise<string> {
  const body = (await res.json().catch(() => ({}))) as { detail?: unknown };
  if (typeof body.detail === "string") return body.detail;
  if (Array.isArray(body.detail)) {
    const messages = body.detail
      .map((item) =>
        item && typeof item === "object" && "msg" in item
          ? String(item.msg)
          : null,
      )
      .filter((message): message is string => message !== null);
    if (messages.length > 0) return messages.join("; ");
  }
  return fallback;
}

export async function listSubagents(): Promise<Subagent[]> {
  const res = await fetch(`${getBackendBaseURL()}/api/subagents`);
  if (!res.ok)
    throw new Error(await errorDetail(res, "Failed to load subagents"));
  const body = (await res.json()) as { subagents: Subagent[] };
  return body.subagents;
}

export async function createManagedSubagent(
  request: CreateManagedSubagentRequest,
): Promise<Subagent> {
  const res = await fetch(`${getBackendBaseURL()}/api/subagents`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(request),
  });
  if (!res.ok)
    throw new Error(await errorDetail(res, "Failed to create subagent"));
  return res.json() as Promise<Subagent>;
}

export async function updateManagedSubagent(
  name: string,
  request: UpdateManagedSubagentRequest,
): Promise<Subagent> {
  const res = await fetch(
    `${getBackendBaseURL()}/api/subagents/${encodeURIComponent(name)}`,
    {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(request),
    },
  );
  if (!res.ok)
    throw new Error(await errorDetail(res, "Failed to update subagent"));
  return res.json() as Promise<Subagent>;
}

export async function deleteManagedSubagent(name: string): Promise<void> {
  const res = await fetch(
    `${getBackendBaseURL()}/api/subagents/${encodeURIComponent(name)}`,
    { method: "DELETE" },
  );
  if (!res.ok)
    throw new Error(await errorDetail(res, "Failed to delete subagent"));
}
```
