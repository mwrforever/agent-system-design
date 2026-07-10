# 完整源码：SDK 单例 client + CSRF 双提交 + stream mode 消毒

> 本文件给出 `frontend/src/core/api/api-client.ts`（SDK 单例 client + onRequest CSRF + runs.stream/cancel/joinStream patch）+ `frontend/src/core/api/stream-mode.ts`（stream mode 白名单消毒）+ `frontend/src/core/api/fetcher.ts`（直接 REST 路径 CSRF 双提交）的**完整真实源码**。
>
> 真实实现已按匿名化规则映射到中立结构，去除一切项目字样。`@langchain/langgraph-sdk` 等真实依赖名保留。原代码注释保留以保真；关键处补中文注解。
>
> CSRF 双路径对称契约（SDK `onRequest` 与 `fetcher.ts:fetch` 共享 `readCsrfCookie` + `STATE_CHANGING_METHODS`）是本模块核心；gateway 侧 `CSRFMiddleware` 见 [[auth]]。

## §1 api-client.ts（SDK 单例 client + onRequest CSRF + 方法 patch）

```ts
// frontend/src/core/api/api-client.ts
"use client";

import { Client as LangGraphClient } from "@langchain/langgraph-sdk/client";

import { getLangGraphBaseURL } from "../config";
import { isStaticWebsiteOnly } from "../static-mode";
import {
  loadStaticDemoThread,
  loadStaticDemoThreads,
  staticDemoThreadState,
} from "../threads/static-demo";
import type { AgentThreadState } from "../threads/types";

import { isStateChangingMethod, readCsrfCookie } from "./fetcher";
import { sanitizeRunStreamOptions } from "./stream-mode";

/**
 * SDK ``onRequest`` hook that mints the ``X-CSRF-Token`` header from the
 * live ``csrf_token`` cookie just before each outbound fetch.
 *
 * Reading the cookie per-request (rather than baking it into the SDK's
 * ``defaultHeaders`` at construction) handles login / logout / password
 * change cookie rotation transparently. Both the ``/api/langgraph/*`` SDK
 * path and the direct REST endpoints in ``fetcher.ts:fetchWithAuth``
 * share :func:`readCsrfCookie` and :const:`STATE_CHANGING_METHODS` so
 * the contract stays in lockstep.
 */
function injectCsrfHeader(_url: URL, init: RequestInit): RequestInit {
  if (!isStateChangingMethod(init.method ?? "GET")) {
    return init;
  }
  const token = readCsrfCookie();
  if (!token) return init;
  const headers = new Headers(init.headers);
  if (!headers.has("X-CSRF-Token")) {
    headers.set("X-CSRF-Token", token);
  }
  return { ...init, headers };
}

// 已到达终态、不可再流的 run status。重连（joinStream）到这种 run 要么 409，
// 要么在后端内存 stream bridge 被 reaped（worker.py 无条件调 publish_end，
// 60s 后 reap bridge）后永远阻塞在排空的条件变量上 -> pin isLoading=true，
// 提交按钮停在 stop 状态，刷新后第一条消息发不出。joinStream 包装在 join
// 前短路这些情况。
//
// interrupted 在 Helix 里只由 RunManager.cancel()（用户主动 stop）写入；
// resumable human-in-the-loop 路径用 Command(goto=END)（ClarificationMiddleware），
// run 以 success 结束而非 interrupted。故 interrupted run 没东西可流--
// 其 state 在 checkpoint 里，由 useThreadHistory 独立拉取，恢复靠 fresh submit。
//
// error/timeout 也是终态，故 ~60s bridge-reap 窗口内刷新不再经 onError
// 重放缓冲的 error 事件--瞬态 error toast（getStreamErrorMessage）被丢弃。
// 持久化 error state 仍经 checkpoint 由 useThreadHistory 加载，故只丢 toast；
// 这是刻意的，因为每次刷新弹 stale error toast 是噪音而非信号。
const TERMINAL_RUN_STATUSES = new Set([
  "success",
  "error",
  "timeout",
  "interrupted",
]);

/**
 * gateway 409 conflict 响应的共享匹配器。SDK 把非 2xx 响应 surface 为
 * HTTPError { status, message }，其中 message 为
 * "HTTP 409: {\"detail\":\"...\"}"，故 409 可经数字 status 或 message 子串检测。
 *
 * 每个传入的 needles 子串都必须出现；此 AND 语义让调用方按短语区分兄弟冲突
 * 分支（如终态 cancel 分支 vs 仍在另一 worker 活跃的分支）。
 *
 * 匹配字符串直到 API 暴露结构化错误码；事实源是 _cancel_conflict_detail /
 * gateway/gateway/routers/thread_runs.py 中的 store-only 响应。
 */
function isRunConflictError(error: unknown, ...needles: string[]): boolean {
  const status =
    typeof error === "object" && error !== null
      ? Reflect.get(error, "status")
      : undefined;
  const message =
    typeof error === "string"
      ? error
      : error instanceof Error
        ? error.message
        : typeof error === "object" && error !== null
          ? String(Reflect.get(error, "message") ?? "")
          : "";

  return (
    (status === 409 || message.includes("HTTP 409")) &&
    needles.every((needle) => message.includes(needle))
  );
}

// store-only run 无法流（本 worker 无内存 stream bridge）：重连无东西可 rejoin。
export function isInactiveRunStreamError(error: unknown): boolean {
  return isRunConflictError(
    error,
    "not active on this worker",
    "cannot be streamed",
  );
}

/**
 * 匹配 gateway 的终态 cancel conflict，由 gateway/gateway/routers/thread_runs.py
 * 的 _cancel_conflict_detail 在 RunManager.cancel 拒绝已结束 run 时抛出
 * "Run X is not cancellable (status: success|error|timeout)"。
 *
 * 兄弟分支 "not active on this worker and cannot be cancelled"（多实例部署中
 * run 仍在另一 worker pending/running）刻意不匹配--那是真实 cancel 失败，
 * 必须保持可见。只有终态分支是真正的 no-op。
 */
export function isRunNotCancellableError(error: unknown): boolean {
  return isRunConflictError(error, "is not cancellable");
}

/**
 * 重连预检：若 run 已达终态，无东西可 rejoin。返回 true 时调用方应跳过
 * 底层 joinStream，让 SDK 的 onSuccess 路径跑、isLoading 翻回 false--
 * 而非永远阻塞在排空的 stream bridge 上。
 *
 * 任何错误（404 记录被驱逐、网络抖动、auth 故障等）回退到原始 join，
 * 故合法的活跃重连永不被静默压制。
 */
async function shouldSkipReconnect(
  client: LangGraphClient,
  threadId: string,
  runId: string,
): Promise<boolean> {
  try {
    const run = await client.runs.get(threadId, runId);
    return TERMINAL_RUN_STATUSES.has(run.status);
  } catch {
    return false;
  }
}

export function clearReconnectRun(
  threadId: string | null | undefined,
  runId: string,
): void {
  if (typeof window === "undefined" || !threadId) return;

  const key = `lg:stream:${threadId}`;
  try {
    const storage = window.sessionStorage;
    if (storage.getItem(key) === runId) {
      storage.removeItem(key);
    }
  } catch {
    // 忽略 storage 访问失败，重连清理永不抛。
  }
}

function createCompatibleClient(isMock?: boolean): LangGraphClient {
  if (isStaticWebsiteOnly() && !isMock) {
    return createStaticClient();
  }

  const apiUrl = getLangGraphBaseURL(isMock);
  console.log(`Creating API client with base URL: ${apiUrl}`);
  const client = new LangGraphClient({
    apiUrl,
    onRequest: injectCsrfHeader,
  });

  // patch runs.stream：经 sanitizeRunStreamOptions 丢弃 SDK 不支持的 stream mode
  const originalRunStream = client.runs.stream.bind(client.runs);
  client.runs.stream = ((threadId, assistantId, payload) =>
    originalRunStream(
      threadId,
      assistantId,
      sanitizeRunStreamOptions(payload),
    )) as typeof client.runs.stream;

  // patch runs.cancel：吞终态 409（run 已结束，cancel 是 no-op）
  const originalCancel = client.runs.cancel.bind(client.runs);
  client.runs.cancel = (async (threadId, runId, wait, action, options) => {
    try {
      return await originalCancel(threadId, runId, wait, action, options);
    } catch (error) {
      if (isRunNotCancellableError(error)) {
        // run 已达终态，cancel 是 no-op。吞 409 使 finish 窗口（后端翻 success
        // 但 SSE 未排空）的 stop 点击不冒泡为未处理 rejection，并清过期 reconnect
        // key。clearReconnectRun 仅在 key 仍匹配此 runId 时删除，故永不碰
        // 更新 run 的 key。
        clearReconnectRun(threadId, runId);
        return;
      }
      throw error;
    }
  }) as typeof client.runs.cancel;

  // patch runs.joinStream：终态短路 + 吞 inactive 409
  const originalJoinStream = client.runs.joinStream.bind(client.runs);
  client.runs.joinStream = async function* (threadId, runId, options) {
    // 短路对已结束 run 的重连：否则后端 stream bridge 被 reaped 后永远阻塞
    // 在排空的条件变量上，pin isLoading=true 使刷新后首条消息路由到 stop 而非 submit。
    if (threadId && (await shouldSkipReconnect(client, threadId, runId))) {
      clearReconnectRun(threadId, runId);
      return;
    }
    try {
      yield* originalJoinStream(
        threadId,
        runId,
        sanitizeRunStreamOptions(options),
      );
    } catch (error) {
      if (isInactiveRunStreamError(error)) {
        clearReconnectRun(threadId, runId);
        return;
      }
      throw error;
    }
  } as typeof client.runs.joinStream;

  return client;
}

function createStaticClient(): LangGraphClient {
  const apiUrl =
    typeof window === "undefined"
      ? "http://localhost:3000"
      : window.location.origin;
  const client = new LangGraphClient({ apiUrl });

  client.threads.search = (async (query) => {
    return loadStaticDemoThreads(query);
  }) as typeof client.threads.search;

  client.threads.get = (async (threadId) => {
    return loadStaticDemoThread(threadId);
  }) as typeof client.threads.get;

  client.threads.getState = (async (threadId) => {
    return staticDemoThreadState(await loadStaticDemoThread(threadId));
  }) as typeof client.threads.getState;

  client.threads.getHistory = (async (threadId) => {
    return [staticDemoThreadState(await loadStaticDemoThread(threadId))];
  }) as typeof client.threads.getHistory;

  client.threads.update = (async (threadId) => {
    return loadStaticDemoThread(threadId);
  }) as typeof client.threads.update;

  client.runs.list = (async () => []) as typeof client.runs.list;
  client.runs.stream = async function* () {
    /* empty */
  } as typeof client.runs.stream;
  client.runs.joinStream = async function* () {
    /* empty */
  } as typeof client.runs.joinStream;

  return client as LangGraphClient<AgentThreadState>;
}

// 进程内单例：Map<cacheKey, Client>，"default" 与 "mock" 两个 key
const _clients = new Map<string, LangGraphClient>();
export function getAPIClient(isMock?: boolean): LangGraphClient {
  const cacheKey = isMock ? "mock" : "default";
  let client = _clients.get(cacheKey);

  if (!client) {
    client = createCompatibleClient(isMock);
    _clients.set(cacheKey, client);
  }

  return client;
}
```

## §2 stream-mode.ts（stream mode 白名单消毒 + 去重警告）

```ts
// frontend/src/core/api/stream-mode.ts

// 与网关对齐的 stream mode 白名单
const SUPPORTED_RUN_STREAM_MODES = new Set([
  "values",
  "messages",
  "messages-tuple",
  "updates",
  "events",
  "debug",
  "tasks",
  "checkpoints",
  "custom",
] as const);

// 已警告过的不支持 mode 集合（模块级 Set，去重防控制台刷屏）
const warnedUnsupportedStreamModes = new Set<string>();

export function warnUnsupportedStreamModes(
  modes: string[],
  warn: (message: string) => void = console.warn,
) {
  const unseenModes = modes.filter((mode) => {
    if (warnedUnsupportedStreamModes.has(mode)) {
      return false;
    }
    warnedUnsupportedStreamModes.add(mode);
    return true;
  });

  if (unseenModes.length === 0) {
    return;
  }

  warn(
    `[helix] Dropped unsupported LangGraph stream mode(s): ${unseenModes.join(", ")}`,
  );
}

export function sanitizeRunStreamOptions<T>(options: T): T {
  if (
    typeof options !== "object" ||
    options === null ||
    !("streamMode" in options)
  ) {
    return options;
  }

  const streamMode = options.streamMode;
  if (streamMode == null) {
    return options;
  }

  const requestedModes = Array.isArray(streamMode) ? streamMode : [streamMode];
  const sanitizedModes = requestedModes.filter((mode) =>
    SUPPORTED_RUN_STREAM_MODES.has(mode),
  );

  // 全员合法直接 return 原对象（避免无谓 alloc）
  if (sanitizedModes.length === requestedModes.length) {
    return options;
  }

  const droppedModes = requestedModes.filter(
    (mode) => !SUPPORTED_RUN_STREAM_MODES.has(mode),
  );
  warnUnsupportedStreamModes(droppedModes);

  return {
    ...options,
    streamMode: Array.isArray(streamMode) ? sanitizedModes : sanitizedModes[0],
  };
}
```

## §3 fetcher.ts（直接 REST 路径 CSRF 双提交 + credentials + 401 跳登录）

```ts
// frontend/src/core/api/fetcher.ts
import { buildLoginUrl } from "@/core/auth/types";

/** gateway CSRFMiddleware 检查的 HTTP 方法。 */
export type StateChangingMethod = "POST" | "PUT" | "DELETE" | "PATCH";

export const STATE_CHANGING_METHODS: ReadonlySet<StateChangingMethod> = new Set(
  ["POST", "PUT", "DELETE", "PATCH"],
);

/** gateway should_check_csrf 决策的镜像。 */
export function isStateChangingMethod(method: string): boolean {
  return (STATE_CHANGING_METHODS as ReadonlySet<string>).has(
    method.toUpperCase(),
  );
}

const CSRF_COOKIE_PREFIX = "csrf_token=";

/**
 * 读取 gateway 在登录时下发的 csrf_token cookie。
 *
 * SSR 安全：document 未定义时返回 null，使同一 helper 可从 server component
 * 导入而无需 guard。
 *
 * 用 String.split 而非 regex 绕开 ESLint 的 prefer-regexp-exec 规则；
 * cookie 值的 ; 分隔符由 gateway（非浏览器）设置，格式稳定。
 */
export function readCsrfCookie(): string | null {
  if (typeof document === "undefined") return null;
  for (const pair of document.cookie.split("; ")) {
    if (pair.startsWith(CSRF_COOKIE_PREFIX)) {
      return decodeURIComponent(pair.slice(CSRF_COOKIE_PREFIX.length));
    }
  }
  return null;
}

/**
 * 带 credentials + 自动 CSRF 保护的 fetch。
 *
 * 每个 API 调用都需的两个集中契约：
 *
 * 1. credentials: "include" 使 HttpOnly access_token cookie 伴随跨-origin
 *    SSR 路由请求。
 * 2. X-CSRF-Token header（状态变更方法 POST/PUT/DELETE/PATCH），从 csrf_token
 *    cookie 回显。gateway 的 CSRFMiddleware 强制 Double Submit Cookie 比较，
 *    缺 header 返回 403--静默破坏每个用裸 fetch() 而非此包装的调用点。
 *
 * 401 自动跳 /login。调用方传入的 header 保留；helper 仅在 header 不存在时
 * ADD CSRF header，显式覆盖优先。
 */
export async function fetch(
  input: RequestInfo | string,
  init?: RequestInit,
): Promise<Response> {
  const url = typeof input === "string" ? input : input.url;

  // 状态变更方法注入 CSRF。GET/HEAD/OPTIONS/TRACE 跳过，逐字镜像 gateway 的
  // should_check_csrf 逻辑。
  let headers = init?.headers;
  if (isStateChangingMethod(init?.method ?? "GET")) {
    const token = readCsrfCookie();
    if (token) {
      // 新建 Headers 实例避免 mutate 调用方传入的对象。
      const merged = new Headers(headers);
      if (!merged.has("X-CSRF-Token")) {
        merged.set("X-CSRF-Token", token);
      }
      headers = merged;
    }
  }

  const res = await globalThis.fetch(url, {
    ...init,
    headers,
    credentials: "include",
  });

  if (res.status === 401) {
    window.location.href = buildLoginUrl(window.location.pathname);
    throw new Error("Unauthorized");
  }

  return res;
}

/**
 * 为 CSRF 保护请求构造 header。
 *
 * 新代码优先用 fetch（fetchWithAuth）--它在状态变更方法上自动注入 header。
 * 此 helper 供需手动组合 header 的 legacy 调用点使用（如 next/server route
 * handler 内自建 Headers 对象的场景）。
 *
 * 按 RFC-001：Double Submit Cookie 模式。
 */
export function getCsrfHeaders(): HeadersInit {
  const token = readCsrfCookie();
  return token ? { "X-CSRF-Token": token } : {};
}
```

> **CSRF 双路径对称契约要点**：
> - SDK 路径（`useStream` -> `client.runs.stream` / `threads.update` / `runs.cancel`）：经 `createCompatibleClient` 的 `onRequest: injectCsrfHeader` 注入（§1）。
> - 直接 REST 路径（`/api/scheduled-tasks/*`、`/runs/regenerate/prepare` 等）：经 `fetcher.ts:fetch` 注入（§3）。
> - 两路径**共享** `readCsrfCookie()` + `isStateChangingMethod()` + `STATE_CHANGING_METHODS`，"哪些方法要注入"与"cookie 怎么读"只有一份事实源。
> - `STATE_CHANGING_METHODS = new Set(["POST","PUT","DELETE","PATCH"])` 与 gateway `should_check_csrf`（`request.method not in ("POST","PUT","DELETE","PATCH")`）逐字对齐--GET/HEAD/OPTIONS/TRACE 豁免。
> - 逐请求读 cookie（非构造时烘焙进 `defaultHeaders`）-> 登录/登出/改密 cookie 轮转对 SDK 透明，无需重建 client。
