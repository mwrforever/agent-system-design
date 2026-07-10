# 完整源码：流式 hooks + SDK 单例 client

> 本文件给出 `frontend/src/core/api/api-client.ts`（SDK 单例 client）与 `frontend/src/core/threads/hooks.ts`（`useThreadStream` + 三路乐观合并）的**完整实现**。SKILL.md 给了入口片段，本文件给全量。
>
> 真实实现已按匿名化规则映射到中立结构（包前缀 `helix.*` / env 前缀 `HELIX_*`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

## §1 SDK 单例 client（api-client.ts）

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
 * SDK ``onRequest`` 钩子：每次出站 fetch 前，从实时 ``csrf_token`` cookie 铸
 * ``X-CSRF-Token`` 头。
 *
 * 逐请求读 cookie（而非构造时烘焙进 SDK 的 ``defaultHeaders``）-> 登录/登出/
 * 改密 cookie 轮转对 SDK 透明。``/api/langgraph/*`` SDK 路径与 ``fetcher.ts``
 * 的直接 REST 端点共享 ``readCsrfCookie`` 与 ``STATE_CHANGING_METHODS``，
 * 双路径契约保持一致。
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

// 已到达终态、不可再流的 run status。重连（``joinStream``）到这种 run 要么 409，
// 要么在后端内存 stream bridge 被 reaped（worker.py 无条件调 publish_end，
// 60s 后 reap bridge）后永远阻塞在排空的条件变量上 -> pin isLoading=true，
// 提交按钮停在 stop 状态，刷新后第一条消息发不出。``joinStream`` 包装在 join
// 前短路这些情况。
//
// ``interrupted`` 在 Helix 里只由 ``RunManager.cancel()``（用户主动 stop）写入；
// resumable human-in-the-loop 路径用 ``Command(goto=END)``（ClarificationMiddleware），
// run 以 ``success`` 结束而非 ``interrupted``。故 interrupted run 没东西可流 --
// 其 state 在 checkpoint 里，由 ``useThreadHistory`` 独立拉取，恢复靠 fresh submit。
//
// ``error``/``timeout`` 也是终态，故 ~60s bridge-reap 窗口内刷新不再经 onError
// 重放缓冲的 error 事件。持久化的 error state 仍从 checkpoint 经 useThreadHistory
// 加载，只丢 toast，这是有意的（每次刷新弹旧 error toast 是噪音）。
const TERMINAL_RUN_STATUSES = new Set([
  "success",
  "error",
  "timeout",
  "interrupted",
]);

/**
 * 匹配 gateway 的 409 冲突响应。SDK 把非 2xx 响应抛为 ``HTTPError { status, message }``，
 * 其中 ``message`` 是 ``"HTTP 409: {\"detail\":\"...\"}"``，所以 409 可经数字 status
 * 或 message 子串检测。
 *
 * 每个 ``needles`` 子串都必须出现（AND 语义），让调用方用短语区分兄弟冲突分支
 * （如终态 cancel 分支 vs 仍在另一 worker 活跃的分支）。
 *
 * 在 API 暴露结构化 error code 前用字符串匹配；事实源是 gateway 路由的
 * ``_cancel_conflict_detail`` / store-only 响应。
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
 * 匹配 gateway 的终态 cancel 冲突，由 gateway 路由的 ``_cancel_conflict_detail``
 * 抛为 ``Run X is not cancellable (status: success|error|timeout)``（RunManager.cancel
 * 拒绝已终结的 run 时）。
 *
 * 兄弟分支 ``"not active on this worker and cannot be cancelled"``（多实例部署里
 * run 仍在另一 worker 待/跑）**故意不匹配** -- 那是真实 cancel 失败，必须保持可见。
 * 只终态分支才是真 no-op。
 */
export function isRunNotCancellableError(error: unknown): boolean {
  return isRunConflictError(error, "is not cancellable");
}

/**
 * 重连预检：若 run 已到终态，无东西可 rejoin。返回 ``true`` 时调用方应跳过
 * 底层 ``joinStream``，让 SDK 的 ``onSuccess`` 路径跑、``isLoading`` 翻回 false，
 * 而非永远阻塞在排空的 stream bridge 上。
 *
 * 任何错误（404 记录被驱逐、网络抖动、认证 hiccup）回退原始 join，绝不静默压制
 * 合法的活跃重连。
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

  // patch runs.stream：丢弃 SDK 不支持的 stream mode
  const originalRunStream = client.runs.stream.bind(client.runs);
  client.runs.stream = ((threadId, assistantId, payload) =>
    originalRunStream(
      threadId,
      assistantId,
      sanitizeRunStreamOptions(payload),
    )) as typeof client.runs.stream;

  // patch runs.cancel：终态 run 的 409 是 no-op，吞掉并清 stale reconnect key
  const originalCancel = client.runs.cancel.bind(client.runs);
  client.runs.cancel = (async (threadId, runId, wait, action, options) => {
    try {
      return await originalCancel(threadId, runId, wait, action, options);
    } catch (error) {
      if (isRunNotCancellableError(error)) {
        // run 已终态，cancel 是 no-op。吞 409 防止 finish 窗口期（后端翻 success
        // 但 SSE 流未排空）的 stop 点击抛未处理 rejection，并清 stale reconnect key。
        // clearReconnectRun 仅在 key 仍匹配此 runId 时移除，不碰更新 run 的 key。
        clearReconnectRun(threadId, runId);
        return;
      }
      throw error;
    }
  }) as typeof client.runs.cancel;

  // patch runs.joinStream：短路已终态 run 的重连，否则 bridge 被 reaped 后
  // 永远阻塞在排空条件变量上，pin isLoading=true，刷新后首条消息路由到 stop 而非 submit。
  const originalJoinStream = client.runs.joinStream.bind(client.runs);
  client.runs.joinStream = async function* (threadId, runId, options) {
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

// 纯静态站降级：threads.search/get/getState/getHistory 走 demo 数据，runs.stream/joinStream 空生成器
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

### §1a stream-mode.ts（sanitizeRunStreamOptions）

```ts
// frontend/src/core/api/stream-mode.ts
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

## §2 useThreadStream + 三路乐观合并（threads/hooks.ts）

```ts
// frontend/src/core/threads/hooks.ts
import type { AIMessage, Message, Run } from "@langchain/langgraph-sdk";
import type { ThreadsClient } from "@langchain/langgraph-sdk/client";
import { useStream } from "@langchain/langgraph-sdk/react";
import {
  type QueryClient,
  type InfiniteData,
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";

import type { PromptInputMessage } from "@/components/ai-elements/prompt-input";

import { getAPIClient } from "../api";
import { fetch } from "../api/fetcher";
import { getBackendBaseURL } from "../config";
import { useI18n } from "../i18n/hooks";
import { isHiddenFromUIMessage } from "../messages/utils";
import type { FileInMessage } from "../messages/utils";
import type { LocalSettings } from "../settings";
import { isSidecarThread, SIDECAR_METADATA_KEY } from "../sidecar/thread";
import { useUpdateSubtask } from "../tasks/context";
import { messageToStep } from "../tasks/steps";
import type { UploadedFileInfo } from "../uploads";
import { promptInputFilePartToFile, uploadFiles } from "../uploads";

import { branchThreadFromTurn, fetchThreadTokenUsage } from "./api";
import {
  buildThreadsSearchQueryOptions,
  DEFAULT_THREAD_SEARCH_PARAMS,
  filterThreadSearchResults,
  type ThreadSearchParams,
} from "./thread-search-query";
import { threadTokenUsageQueryKey } from "./token-usage";
import type {
  AgentThread,
  AgentThreadState,
  RunMessage,
  ThreadTokenUsageResponse,
} from "./types";

export type ToolEndEvent = {
  name: string;
  data: unknown;
};

export type ThreadStreamOptions = {
  threadId?: string | null | undefined;
  displayThreadId?: string | null | undefined;
  context: LocalSettings["context"];
  isMock?: boolean;
  onSend?: (threadId: string) => void;
  onStart?: (threadId: string, runId: string) => void;
  onFinish?: (state: AgentThreadState) => void;
  onToolEnd?: (event: ToolEndEvent) => void;
};

type SendMessageOptions = {
  additionalKwargs?: Record<string, unknown>;
  additionalInputMessages?: Message[];
  /**
   * 仅在 send 通过 in-flight guard 并真正派发时触发一次。早返回路径不触发，
   * 故调用方可安全做一次性清理（如清引用），并发 send 被丢时不丢状态。
   */
  onSent?: () => void;
};

type ThreadDeleteClient = {
  threads: {
    delete: (threadId: string) => Promise<unknown>;
    search: (query: Record<string, unknown>) => Promise<AgentThread[]>;
  };
};

type ThreadSidecarSearchClient = {
  threads: {
    search: (query: Record<string, unknown>) => Promise<AgentThread[]>;
  };
};

type RegeneratePrepareResponse = {
  input: Partial<AgentThreadState>;
  checkpoint: {
    checkpoint_ns: string;
    checkpoint_id: string;
    checkpoint_map: Record<string, unknown> | null;
  };
  metadata: Record<string, unknown>;
  target_run_id: string;
};

export function buildThreadSubmitMessages({
  text,
  additionalKwargs,
  additionalInputMessages = [],
  filesForSubmit = [],
}: {
  text: string;
  additionalKwargs?: Record<string, unknown>;
  additionalInputMessages?: Message[];
  filesForSubmit?: FileInMessage[];
}): Message[] {
  return [
    ...additionalInputMessages,
    {
      type: "human",
      content: [
        {
          type: "text",
          text,
        },
      ],
      additional_kwargs: {
        ...additionalKwargs,
        ...(filesForSubmit.length > 0 ? { files: filesForSubmit } : {}),
      },
    } as Message,
  ];
}

const EMPTY_THREAD_VALUES: AgentThreadState = {
  title: "",
  messages: [],
  artifacts: [],
  todos: [],
};

function isNonEmptyString(value: string | undefined): value is string {
  return typeof value === "string" && value.length > 0;
}

// 上下文摘要中间件的 update key（含旧版 Helix 前缀的向后兼容 shim）
const SUMMARIZATION_MIDDLEWARE_UPDATE_KEYS = new Set([
  "SummarizationMiddleware.before_model",
  "HelixSummarizationMiddleware.before_model",
]);

// 消息身份：tool 消息用 tool_call_id，其余用 message.id；用于三路合并的去重与重叠判定
function messageIdentity(message: Message): string | undefined {
  if (
    "tool_call_id" in message &&
    typeof message.tool_call_id === "string" &&
    message.tool_call_id.length > 0
  ) {
    return `tool:${message.tool_call_id}`;
  }
  if (typeof message.id === "string" && message.id.length > 0) {
    return `message:${message.id}`;
  }
  return undefined;
}

function dedupeMessagesByIdentity(messages: Message[]): Message[] {
  const lastIndexByIdentity = new Map<string, number>();
  const lastVisibleIndexByIdentity = new Map<string, number>();

  // 这是 UI 展示去重规则，不是通用 LangChain message-stream 契约。与可见消息共享身份的
  // 隐藏消息在此合并视图里当控制消息；携带独立 tracing/task 语义的隐藏消息应用独立 id
  // 或自定义 stream/state channel，而非依赖 message dedupe 保留。
  const preservedTurnDurations = new Map<string, number>();
  messages.forEach((message, index) => {
    const identity = messageIdentity(message);
    if (identity) {
      lastIndexByIdentity.set(identity, index);
      if (!isHiddenFromUIMessage(message)) {
        lastVisibleIndexByIdentity.set(identity, index);
      }
      if (message.additional_kwargs?.turn_duration !== undefined) {
        preservedTurnDurations.set(
          identity,
          message.additional_kwargs.turn_duration as number,
        );
      }
    }
  });

  return messages
    .filter((message, index) => {
      const identity = messageIdentity(message);
      if (!identity) {
        return true;
      }
      const visibleIndex = lastVisibleIndexByIdentity.get(identity);
      if (visibleIndex !== undefined) {
        return visibleIndex === index;
      }
      return lastIndexByIdentity.get(identity) === index;
    })
    .map((message) => {
      const identity = messageIdentity(message);
      if (
        identity &&
        preservedTurnDurations.has(identity) &&
        message.additional_kwargs?.turn_duration === undefined
      ) {
        return {
          ...message,
          additional_kwargs: {
            ...message.additional_kwargs,
            turn_duration: preservedTurnDurations.get(identity),
          },
        } as Message;
      }
      return message;
    });
}

function dedupeRunMessagesByIdentity(messages: RunMessage[]): RunMessage[] {
  const lastIndexByIdentity = new Map<string, number>();
  messages.forEach((message, index) => {
    const identity = messageIdentity(message.content);
    if (identity) {
      lastIndexByIdentity.set(`${message.run_id}:${identity}`, index);
    }
  });

  return messages.filter((message, index) => {
    const identity = messageIdentity(message.content);
    if (!identity) {
      return true;
    }
    return lastIndexByIdentity.get(`${message.run_id}:${identity}`) === index;
  });
}

export function getSupersededRunIds(
  runs: Run[] | undefined,
  pendingSupersededRunIds?: ReadonlySet<string>,
) {
  const ids = new Set(pendingSupersededRunIds ?? []);
  for (const run of runs ?? []) {
    if (run.status !== "success") {
      continue;
    }
    const metadata = run.metadata;
    if (metadata && typeof metadata === "object") {
      const fromRunId = Reflect.get(metadata, "regenerate_from_run_id");
      if (typeof fromRunId === "string" && fromRunId) {
        ids.add(fromRunId);
      }
    }
  }
  return ids;
}

export function removeSetItems<T>(
  values: ReadonlySet<T>,
  itemsToRemove: Iterable<T>,
) {
  const next = new Set(values);
  for (const item of itemsToRemove) {
    next.delete(item);
  }
  return next;
}

export function buildVisibleHistoryMessages(
  messageRows: RunMessage[],
  supersededRunIds: ReadonlySet<string>,
  appendedMessages: Message[],
) {
  const visibleRows = messageRows.filter(
    (message) => !supersededRunIds.has(message.run_id),
  );
  return dedupeMessagesByIdentity([
    // 把所属 run_id 带到 content 消息上，历史子代理卡 expand 时能拉持久 step history。
    // run_id 在 RunMessage wrapper 上，不这样带会被丢。
    ...visibleRows.map((message) => ({
      ...message.content,
      run_id: message.run_id,
    })),
    ...appendedMessages,
  ]);
}

export function findLatestUnloadedRunIndex(
  runs: Run[],
  loadedRunIds: ReadonlySet<string>,
): number {
  for (let i = 0; i < runs.length; i++) {
    const run = runs[i];
    if (run && !loadedRunIds.has(run.run_id)) {
      return i;
    }
  }
  return -1;
}

export const MAX_CONSECUTIVE_EMPTY_RUN_LOADS = 5;

export function shouldAutoContinueOnEmptyRun(
  fetchedMessageCount: number,
  consecutiveEmptyLoads: number,
  maxConsecutiveEmptyLoads: number = MAX_CONSECUTIVE_EMPTY_RUN_LOADS,
): boolean {
  return (
    fetchedMessageCount === 0 &&
    consecutiveEmptyLoads < maxConsecutiveEmptyLoads
  );
}

type RunMessagesPageResponse = {
  data: RunMessage[];
  has_more?: boolean;
  hasMore?: boolean;
};

export function runMessagesPageHasMore(result: RunMessagesPageResponse) {
  return result.has_more ?? result.hasMore ?? false;
}

export function getOldestRunMessageSeq(messages: RunMessage[]) {
  let oldestSeq: number | null = null;
  for (const message of messages) {
    if (typeof message.seq !== "number") {
      continue;
    }
    oldestSeq =
      oldestSeq === null ? message.seq : Math.min(oldestSeq, message.seq);
  }
  return oldestSeq;
}

export function getNextRunMessagesBeforeSeq(
  result: RunMessagesPageResponse,
): number | null | undefined {
  if (!runMessagesPageHasMore(result)) {
    return null;
  }
  return getOldestRunMessageSeq(result.data) ?? undefined;
}

export function buildRunMessagesUrl(
  baseUrl: string,
  threadId: string,
  runId: string,
  beforeSeq?: number,
) {
  const normalizedBaseUrl = baseUrl.replace(/\/$/, "");
  const path = `/api/threads/${encodeURIComponent(threadId)}/runs/${encodeURIComponent(runId)}/messages`;
  const url = new URL(
    `${normalizedBaseUrl}${path}`,
    typeof window !== "undefined" ? window.location.origin : "http://localhost",
  );
  if (beforeSeq !== undefined) {
    url.searchParams.set("before_seq", String(beforeSeq));
  }
  return normalizedBaseUrl ? url.toString() : `${url.pathname}${url.search}`;
}

/**
 * 三路乐观合并：历史 + 实时流 + 乐观消息。
 *
 * 只用可见 live 消息裁剪重叠历史。隐藏消息在此路径是 UI 控制消息，不是可观测记录；
 * 任何需作为 task/tracing 数据存活的隐藏消息应用 custom event 或独立 state channel，
 * 不参与此重叠启发式。
 */
export function mergeMessages(
  historyMessages: Message[],
  threadMessages: Message[],
  optimisticMessages: Message[],
): Message[] {
  const savedTurnDurations = new Map<string, number>();
  for (const msg of historyMessages) {
    const identity = messageIdentity(msg);
    if (identity && msg.additional_kwargs?.turn_duration !== undefined) {
      savedTurnDurations.set(
        identity,
        msg.additional_kwargs.turn_duration as number,
      );
    }
  }

  const threadMessageIds = new Set(
    threadMessages
      .filter((message) => !isHiddenFromUIMessage(message))
      .map(messageIdentity)
      .filter(isNonEmptyString),
  );

  // 重叠是 historyMessages 的连续后缀（最新历史 == 最旧线程）。从尾扫描：
  // 命中即缩 cutoff，一遇到不在 thread 里的就停 -- 之前都是非重叠。
  let cutoff = historyMessages.length;
  for (let i = historyMessages.length - 1; i >= 0; i--) {
    const msg = historyMessages[i];
    if (!msg) {
      continue;
    }
    const identity = messageIdentity(msg);
    if (identity && threadMessageIds.has(identity)) {
      cutoff = i;
    } else {
      break;
    }
  }

  const merged = dedupeMessagesByIdentity([
    ...historyMessages.slice(0, cutoff),
    ...threadMessages,
    ...optimisticMessages,
  ]);

  return merged.map((message) => {
    const identity = messageIdentity(message);
    if (
      identity &&
      savedTurnDurations.has(identity) &&
      message.additional_kwargs?.turn_duration === undefined
    ) {
      return {
        ...message,
        additional_kwargs: {
          ...message.additional_kwargs,
          turn_duration: savedTurnDurations.get(identity),
        },
      } as Message;
    }
    return message;
  });
}

/**
 * 推导上下文摘要即将丢弃、需重新归档进历史的 live turns。
 *
 * 摘要发 ``RemoveMessage(ALL)`` + 隐藏 summary + 保留尾部。当前 live thread 在第一条
 * 保留可见消息之前的所有消息都在被删；保留它们（减去已跟踪的 summary 控制消息），
 * 让 UI 仍能展示完整对话。
 */
export function computeSummarizationMovedMessages(
  currentMessages: Message[],
  summarizationMessages: Message[],
  summarizedMessageIds: ReadonlySet<string>,
): Message[] {
  const firstRetainedVisibleIdentity = summarizationMessages
    .filter((message) => message.type !== "remove")
    .filter((message) => !isHiddenFromUIMessage(message))
    .map(messageIdentity)
    .find(isNonEmptyString);

  const moved: Message[] = [];
  for (const message of currentMessages) {
    if (
      firstRetainedVisibleIdentity &&
      messageIdentity(message) === firstRetainedVisibleIdentity
    ) {
      break;
    }
    if (!summarizedMessageIds.has(message.id ?? "")) {
      moved.push(message);
    }
  }
  return moved;
}

/**
 * 把摘要救援消息覆盖到（可能 stale 的）可见历史上，合并视图永不丢它们。
 *
 * 背景：摘要后后端删所有 live 消息（``RemoveMessage(ALL)``），``onUpdateEvent`` 经
 * 异步 ``setState`` 把被删消息重新归档进历史。live thread 消息归 SDK external store，
 * 归档历史是 React state，故 render 可能观测到摘要后（缩小的）thread 在归档 setState
 * 提交之前 -- 救援消息在两个 merge 输入里都没有。在此从同步缓冲读它们，让合并在
 * 每个 render 都正确，无论两个 state channel 如何交错。
 *
 * 救援消息是最旧的 live turns，跟在已加载历史之后。只追加历史还没吸收的：历史一旦
 * 吸收了某救援消息，其 live 副本保持权威（缓冲副本是旧快照，绝不覆盖），顺序保留。
 */
export function resolvePreservedHistory(
  visibleHistory: Message[],
  pendingArchivedMessages: Message[],
): Message[] {
  if (pendingArchivedMessages.length === 0) {
    return visibleHistory;
  }
  const presentIdentities = new Set(
    visibleHistory.map(messageIdentity).filter(isNonEmptyString),
  );
  const missing = pendingArchivedMessages.filter((message) => {
    const identity = messageIdentity(message);
    // 无身份的消息故意跳过：无稳定身份无法与历史匹配去 drain/dedupe，覆盖它们会风险永久重复。
    // 它们仍经 appendMessages 归档，经正常历史路径浮现。
    return identity !== undefined && !presentIdentities.has(identity);
  });
  if (missing.length === 0) {
    return visibleHistory;
  }
  return [...visibleHistory, ...missing];
}

/**
 * 释放已被规范历史 state 吸收的归档缓冲项。让缓冲保持跨异步 gap 的瞬态桥，
 * 而非第二个长期事实源 -- 否则 stale 副本可能复活历史后来过滤掉的消息
 * （如被 supersede 或 regenerate 的 run）。
 */
export function pruneConfirmedArchivedMessages(
  pendingArchivedMessages: Message[],
  visibleHistory: Message[],
): Message[] {
  if (pendingArchivedMessages.length === 0) {
    return pendingArchivedMessages;
  }
  const confirmedIdentities = new Set(
    visibleHistory.map(messageIdentity).filter(isNonEmptyString),
  );
  return pendingArchivedMessages.filter((message) => {
    const identity = messageIdentity(message);
    return !identity || !confirmedIdentities.has(identity);
  });
}

function getMessagesAfterBaseline(
  messages: Message[],
  baselineMessageIds: ReadonlySet<string>,
): Message[] {
  return messages.filter((message) => {
    const id = messageIdentity(message);
    return !id || !baselineMessageIds.has(id);
  });
}

export function getVisibleOptimisticMessages(
  optimisticMessages: Message[],
  previousHumanMessageCount: number,
  currentHumanMessageCount: number,
): Message[] {
  if (
    optimisticMessages.some((message) => message.type === "human") &&
    currentHumanMessageCount > previousHumanMessageCount
  ) {
    return [];
  }
  return optimisticMessages;
}

export function getSummarizationMiddlewareMessages(
  data: unknown,
): Message[] | undefined {
  if (typeof data !== "object" || data === null) {
    return undefined;
  }

  for (const [key, update] of Object.entries(data)) {
    if (!SUMMARIZATION_MIDDLEWARE_UPDATE_KEYS.has(key)) {
      continue;
    }
    if (typeof update !== "object" || update === null) {
      continue;
    }

    const messages = Reflect.get(update, "messages");
    if (Array.isArray(messages)) {
      return [...messages] as Message[];
    }
  }

  return undefined;
}

export function upsertThreadInSearchCache(
  queryClient: QueryClient,
  thread: AgentThread,
) {
  queryClient.setQueriesData(
    {
      queryKey: ["threads", "search"],
      exact: false,
    },
    (oldData: Array<AgentThread> | undefined) => {
      if (!oldData) {
        return [thread];
      }

      const existingIndex = oldData.findIndex(
        (t) => t.thread_id === thread.thread_id,
      );
      if (existingIndex === -1) {
        return [thread, ...oldData];
      }

      return oldData.map((t, index) => {
        if (index !== existingIndex) {
          return t;
        }
        return {
          ...thread,
          ...t,
          metadata: {
            ...(thread.metadata ?? {}),
            ...(t.metadata ?? {}),
          },
          values: {
            ...thread.values,
            ...t.values,
          },
        };
      });
    },
  );
}

export function upsertThreadInInfiniteCache(
  queryClient: QueryClient,
  thread: AgentThread,
) {
  queryClient.setQueriesData(
    {
      queryKey: INFINITE_THREADS_QUERY_KEY_PREFIX,
      exact: false,
    },
    (oldData: InfiniteData<AgentThread[]> | undefined) => {
      if (!oldData) {
        return oldData;
      }

      const merged = oldData.pages.map((page) =>
        page.map((t) =>
          t.thread_id === thread.thread_id
            ? {
                ...thread,
                ...t,
                metadata: {
                  ...(thread.metadata ?? {}),
                  ...(t.metadata ?? {}),
                },
                values: {
                  ...thread.values,
                  ...t.values,
                },
              }
            : t,
        ),
      );

      const exists = merged.some((page) =>
        page.some((t) => t.thread_id === thread.thread_id),
      );
      if (exists) {
        return { ...oldData, pages: merged };
      }

      const firstPage = merged[0] ?? [];
      const restPages = merged.slice(1);
      return {
        ...oldData,
        pages: [[thread, ...firstPage], ...restPages],
      };
    },
  );
}

export function invalidateStoppedThreadCaches(
  queryClient: QueryClient,
  threadId: string | null | undefined,
  isMock = false,
) {
  void queryClient.invalidateQueries({ queryKey: ["threads", "search"] });
  void queryClient.invalidateQueries({
    queryKey: INFINITE_THREADS_QUERY_KEY_PREFIX,
  });

  if (!threadId || isMock) {
    return;
  }

  void queryClient.invalidateQueries({ queryKey: ["thread", threadId] });
  void queryClient.invalidateQueries({
    queryKey: ["thread", "metadata", threadId, isMock],
  });
  void queryClient.invalidateQueries({
    queryKey: threadTokenUsageQueryKey(threadId),
  });
}

export const STOP_THREAD_FINALIZATION_REFETCH_DELAY_MS = 1500;

function scheduleStoppedThreadFinalizationRefetch(
  queryClient: QueryClient,
  threadId: string | null | undefined,
  isMock = false,
) {
  if (isMock) {
    return;
  }
  globalThis.setTimeout(() => {
    invalidateStoppedThreadCaches(queryClient, threadId, isMock);
  }, STOP_THREAD_FINALIZATION_REFETCH_DELAY_MS);
}

export async function stopThreadAndInvalidateCaches(
  queryClient: QueryClient,
  stop: () => Promise<void> | void,
  threadId: string | null | undefined,
  isMock = false,
) {
  try {
    await stop();
  } finally {
    invalidateStoppedThreadCaches(queryClient, threadId, isMock);
    scheduleStoppedThreadFinalizationRefetch(queryClient, threadId, isMock);
  }
}

function getStreamErrorMessage(error: unknown): string {
  if (typeof error === "string" && error.trim()) {
    return error;
  }
  if (error instanceof Error && error.message.trim()) {
    return error.message;
  }
  if (typeof error === "object" && error !== null) {
    const message = Reflect.get(error, "message");
    if (typeof message === "string" && message.trim()) {
      return message;
    }
    const nestedError = Reflect.get(error, "error");
    if (nestedError instanceof Error && nestedError.message.trim()) {
      return nestedError.message;
    }
    if (typeof nestedError === "string" && nestedError.trim()) {
      return nestedError;
    }
  }
  return "Request failed.";
}

async function readResponseErrorMessage(
  response: Response,
  fallback = "Request failed.",
) {
  try {
    const data = await response.json();
    if (typeof data?.detail === "string" && data.detail.trim()) {
      return data.detail;
    }
  } catch {
    // 响应体非 JSON 时用 fallback。
  }
  return response.statusText || fallback;
}

function getHttpStatus(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null) {
    return undefined;
  }

  const status = Reflect.get(error, "status");
  if (typeof status === "number") {
    return status;
  }

  const response = Reflect.get(error, "response");
  if (typeof response === "object" && response !== null) {
    const responseStatus = Reflect.get(response, "status");
    if (typeof responseStatus === "number") {
      return responseStatus;
    }
  }

  return undefined;
}

function isThreadMissingError(error: unknown): boolean {
  const status = getHttpStatus(error);
  // 403 当 404 处理，避免泄露不可访问 thread 是否存在；调用方把 stale/不可访问 URL 重定向回空白 chat。
  return status === 403 || status === 404;
}

export function useThreadStream({
  threadId,
  displayThreadId,
  context,
  isMock,
  onSend,
  onStart,
  onFinish,
  onToolEnd,
}: ThreadStreamOptions) {
  const { t } = useI18n();
  const currentViewThreadId = displayThreadId ?? threadId ?? null;
  const currentViewThreadIdRef = useRef(currentViewThreadId);
  currentViewThreadIdRef.current = currentViewThreadId;
  // server stream 响应前显示的乐观消息。
  const [optimisticMessages, setOptimisticMessages] = useState<Message[]>([]);
  const [optimisticThreadId, setOptimisticThreadId] = useState<string | null>(
    null,
  );
  const [liveMessagesThreadId, setLiveMessagesThreadId] = useState<
    string | null
  >(null);
  const [pendingSupersededRunIds, setPendingSupersededRunIds] = useState<
    ReadonlySet<string>
  >(() => new Set());
  const [pendingSupersededMessageIds, setPendingSupersededMessageIds] =
    useState<ReadonlySet<string>>(() => new Set());
  const [isUploading, setIsUploading] = useState(false);
  // 跟踪当前正在流的 thread id，处理流式过程中的 thread 切换
  const [onStreamThreadId, setOnStreamThreadId] = useState(() => threadId);
  // 跨异步回调跟踪当前 thread id（不触发 re-render），且让 onUpdateEvent 能访问
  const threadIdRef = useRef<string | null>(threadId ?? null);
  const startedRef = useRef(false);
  const pendingUsageBaselineMessageIdsRef = useRef<Set<string>>(new Set());
  const listeners = useRef({
    onSend,
    onStart,
    onFinish,
    onToolEnd,
  });

  const {
    messages: history,
    hasMore: hasMoreHistory,
    loadMore: loadMoreHistory,
    loading: isHistoryLoading,
    appendMessages,
  } = useThreadHistory(onStreamThreadId ?? "", {
    enabled: !isMock,
    pendingSupersededRunIds,
  });

  // 保持 listeners ref 与最新回调同步
  useEffect(() => {
    listeners.current = { onSend, onStart, onFinish, onToolEnd };
  }, [onSend, onStart, onFinish, onToolEnd]);

  useEffect(() => {
    const normalizedThreadId = threadId ?? null;
    if (!normalizedThreadId) {
      // UI 回到全新未保存 thread 时重置。
      startedRef.current = false;
      setOnStreamThreadId(normalizedThreadId);
    } else {
      setOnStreamThreadId(normalizedThreadId);
    }
    threadIdRef.current = normalizedThreadId;
  }, [threadId]);

  const handleStreamStart = useCallback((_threadId: string, _runId: string) => {
    threadIdRef.current = _threadId;
    setOptimisticThreadId((currentOptimisticThreadId) => {
      const currentView = currentViewThreadIdRef.current;
      if (
        currentOptimisticThreadId &&
        (currentOptimisticThreadId === currentView ||
          currentOptimisticThreadId === _threadId)
      ) {
        return _threadId;
      }
      return currentOptimisticThreadId;
    });
    setLiveMessagesThreadId((currentLiveMessagesThreadId) => {
      const currentView = currentViewThreadIdRef.current;
      if (
        currentLiveMessagesThreadId &&
        (currentLiveMessagesThreadId === currentView ||
          currentLiveMessagesThreadId === _threadId)
      ) {
        return _threadId;
      }
      return currentLiveMessagesThreadId;
    });
    if (!startedRef.current) {
      listeners.current.onStart?.(_threadId, _runId);
      startedRef.current = true;
    }
    setOnStreamThreadId(_threadId);
  }, []);

  const queryClient = useQueryClient();
  const updateSubtask = useUpdateSubtask();

  const thread = useStream<AgentThreadState>({
    client: getAPIClient(isMock),
    assistantId: "lead_agent",
    threadId: onStreamThreadId,
    reconnectOnMount: true,
    fetchStateHistory: { limit: 1 },
    onCreated(meta) {
      handleStreamStart(meta.thread_id, meta.run_id);
      const now = new Date().toISOString();
      upsertThreadInSearchCache(queryClient, {
        thread_id: meta.thread_id,
        created_at: now,
        updated_at: now,
        metadata: context.agent_name ? { agent_name: context.agent_name } : {},
        status: "busy",
        values: {
          title: t.pages.newChat,
          messages: [],
          artifacts: [],
        },
        interrupts: {},
      });
      upsertThreadInInfiniteCache(queryClient, {
        thread_id: meta.thread_id,
        created_at: now,
        updated_at: now,
        metadata: context.agent_name ? { agent_name: context.agent_name } : {},
        status: "busy",
        values: {
          title: t.pages.newChat,
          messages: [],
          artifacts: [],
        },
        interrupts: {},
      });
      if (context.agent_name && !isMock) {
        void getAPIClient()
          .threads.update(meta.thread_id, {
            metadata: { agent_name: context.agent_name },
          })
          .catch(() => ({}));
      }
    },
    onLangChainEvent(event) {
      if (event.event === "on_tool_end") {
        listeners.current.onToolEnd?.({
          name: event.name,
          data: event.data,
        });
      }
    },
    onUpdateEvent(data) {
      const _messages = getSummarizationMiddlewareMessages(data);
      if (_messages && _messages.length >= 2) {
        for (const m of _messages) {
          // 向后兼容 shim：PR2 前的 thread 可能仍带旧摘要路径的合成 HumanMessage(name="summary")。
          // 新 thread 把 summary 存 ThreadState.summary_text。
          if (m.name === "summary" && m.type === "human") {
            summarizedRef.current?.add(m.id ?? "");
          }
        }
        const _movedMessages = computeSummarizationMovedMessages(
          messagesRef.current,
          _messages,
          summarizedRef.current ?? new Set<string>(),
        );
        // 同步缓冲救援消息，让合并能立即继续显示它们，尽管下面的 appendMessages
        // 只异步更新归档历史 state。
        pendingArchivedMessagesRef.current = dedupeMessagesByIdentity([
          ...pendingArchivedMessagesRef.current,
          ..._movedMessages,
        ]);
        pendingArchiveThreadIdRef.current = threadIdRef.current;
        appendMessages(_movedMessages);
        messagesRef.current = [];
      }

      const updates: Array<Partial<AgentThreadState> | null> = Object.values(
        data || {},
      );
      for (const update of updates) {
        if (update && "title" in update && update.title) {
          void queryClient.setQueriesData(
            {
              queryKey: ["threads", "search"],
              exact: false,
            },
            (oldData: Array<AgentThread> | undefined) => {
              return oldData?.map((t) => {
                if (t.thread_id === threadIdRef.current) {
                  return {
                    ...t,
                    values: {
                      ...t.values,
                      title: update.title,
                    },
                  };
                }
                return t;
              });
            },
          );
          const nextTitle: string = update.title;
          void queryClient.setQueriesData(
            {
              queryKey: INFINITE_THREADS_QUERY_KEY_PREFIX,
              exact: false,
            },
            (oldData: InfiniteData<AgentThread[]> | undefined) =>
              mapInfiniteThreadsCache(
                oldData,
                (t): AgentThread =>
                  t.thread_id === threadIdRef.current
                    ? {
                        ...t,
                        values: {
                          ...t.values,
                          title: nextTitle,
                        },
                      }
                    : t,
              ),
          );
        }
      }
    },
    onCustomEvent(event: unknown) {
      if (
        typeof event === "object" &&
        event !== null &&
        "type" in event &&
        event.type === "task_running"
      ) {
        const e = event as {
          type: "task_running";
          task_id: string;
          message: AIMessage;
          message_index?: number;
        };
        // 累积完整 step history 而非覆盖：保留 latestMessage 给折叠头 tool-call 提示，
        // 把规范化的 step（assistant turn 或 tool output）append 到 timeline。
        updateSubtask({
          id: e.task_id,
          latestMessage: e.message,
          steps: [messageToStep(e.message, e.message_index ?? 0)],
        });
        return;
      }

      if (
        typeof event === "object" &&
        event !== null &&
        "type" in event &&
        event.type === "llm_retry" &&
        "message" in event &&
        typeof event.message === "string" &&
        event.message.trim()
      ) {
        const e = event as { type: "llm_retry"; message: string };
        toast(e.message);
      }
    },
    onError(error) {
      setOptimisticMessages([]);
      setOptimisticThreadId(null);
      setLiveMessagesThreadId(null);
      setPendingSupersededRunIds(new Set());
      setPendingSupersededMessageIds(new Set());
      toast.error(getStreamErrorMessage(error));
      pendingUsageBaselineMessageIdsRef.current = new Set(
        messagesRef.current
          .map(messageIdentity)
          .filter((id): id is string => Boolean(id)),
      );
      if (threadIdRef.current && !isMock) {
        void queryClient.invalidateQueries({
          queryKey: threadTokenUsageQueryKey(threadIdRef.current),
        });
      }
    },
    onFinish(state) {
      listeners.current.onFinish?.(state.values);
      pendingUsageBaselineMessageIdsRef.current = new Set(
        messagesRef.current
          .map(messageIdentity)
          .filter((id): id is string => Boolean(id)),
      );
      invalidateStoppedThreadCaches(queryClient, threadIdRef.current, isMock);
    },
  });

  const stopThread = useCallback(async () => {
    const stoppedThreadId =
      threadIdRef.current ?? displayThreadId ?? threadId ?? null;
    await stopThreadAndInvalidateCaches(
      queryClient,
      () => thread.stop(),
      stoppedThreadId,
      isMock,
    );
  }, [displayThreadId, isMock, queryClient, thread, threadId]);

  const hasVisibleStreamState =
    Boolean(threadId) || liveMessagesThreadId === currentViewThreadId;
  const persistedMessages = useMemo(
    () =>
      hasVisibleStreamState
        ? thread.messages.filter(
            (message) =>
              !message.id || !pendingSupersededMessageIds.has(message.id),
          )
        : [],
    [hasVisibleStreamState, pendingSupersededMessageIds, thread.messages],
  );
  const visibleHistory = useMemo(
    () => (threadId ? history : []),
    [history, threadId],
  );
  const humanMessageCount = persistedMessages.filter(
    (m) => m.type === "human",
  ).length;
  const latestMessageCountsRef = useRef({ humanMessageCount });
  const sendInFlightRef = useRef(false);
  const messagesRef = useRef<Message[]>([]);
  // 上下文摘要救援消息的同步桥。归档历史 setState（经 appendMessages）与 live thread
  // external store 落在不同调度，合并读此缓冲避免在历史赶上前的 render 窗口丢救援消息。
  const pendingArchivedMessagesRef = useRef<Message[]>([]);
  // 救援缓冲所属的 thread，onUpdateEvent 填充时捕获。合并仅在此匹配所看 threadId 时
  // 覆盖缓冲，故前一 thread 的救援消息不会闪进另一 thread 或 new-chat 屏。
  const pendingArchiveThreadIdRef = useRef<string | null>(null);
  const summarizedRef = useRef<Set<string>>(null);
  // 跟踪发送前的 human message 计数，防在 server 的 human message 到达前清乐观消息
  // （如 messages-tuple 的 AI 消息先于 values 事件的 input human 消息到达）。
  const prevHumanMsgCountRef = useRef(humanMessageCount);

  latestMessageCountsRef.current = { humanMessageCount };
  summarizedRef.current ??= new Set<string>();

  // 切换 thread 时重置 thread-local 待处理 UI state，防乐观消息与 in-flight guard 跨 chat view 泄漏。
  useEffect(() => {
    startedRef.current = false;
    sendInFlightRef.current = false;
    messagesRef.current = [];
    pendingArchivedMessagesRef.current = [];
    pendingArchiveThreadIdRef.current = null;
    summarizedRef.current = new Set<string>();
    pendingUsageBaselineMessageIdsRef.current = new Set();
    setPendingSupersededRunIds(new Set());
    setPendingSupersededMessageIds(new Set());
    prevHumanMsgCountRef.current =
      latestMessageCountsRef.current.humanMessageCount;
  }, [threadId]);

  // 规范历史 state 吸收归档缓冲项后释放，让同步桥保持瞬态，永不复活历史后来过滤掉的消息
  // （如被 supersede 的 run）。
  useEffect(() => {
    pendingArchivedMessagesRef.current = pruneConfirmedArchivedMessages(
      pendingArchivedMessagesRef.current,
      visibleHistory,
    );
  }, [visibleHistory]);

  useEffect(() => {
    if (optimisticThreadId && optimisticThreadId !== currentViewThreadId) {
      setOptimisticMessages([]);
      setOptimisticThreadId(null);
    }
    if (liveMessagesThreadId && liveMessagesThreadId !== currentViewThreadId) {
      setLiveMessagesThreadId(null);
    }
  }, [currentViewThreadId, liveMessagesThreadId, optimisticThreadId]);

  // 无 baseline 的流式开始时（如重连、另一客户端发起的 run、或流式中刷新），快照当前消息，
  // 只把"新"消息当 token 用量的"pending"。
  useEffect(() => {
    if (
      thread.isLoading &&
      pendingUsageBaselineMessageIdsRef.current.size === 0
    ) {
      pendingUsageBaselineMessageIdsRef.current = new Set(
        persistedMessages
          .map(messageIdentity)
          .filter((id): id is string => Boolean(id)),
      );
    }
  }, [persistedMessages, thread.isLoading]);

  // server 消息到达时清乐观。带 human 乐观消息时等到 server 的 human 消息到达再清，
  // 避免在 input 消息出现在流之前清（input 消息可能经 values 事件在 messages-tuple 的
  // AI 消息之后到达）。
  const optimisticMessageCount = optimisticMessages.length;
  const hasHumanOptimistic = optimisticMessages.some((m) => m.type === "human");
  useEffect(() => {
    if (optimisticMessageCount === 0) return;

    const newHumanMsgArrived = humanMessageCount > prevHumanMsgCountRef.current;

    if (!hasHumanOptimistic || newHumanMsgArrived) {
      setOptimisticMessages([]);
      setOptimisticThreadId(null);
    }
  }, [hasHumanOptimistic, humanMessageCount, optimisticMessageCount]);

  const sendMessage = useCallback(
    async (
      threadId: string,
      message: PromptInputMessage,
      extraContext?: Record<string, unknown>,
      options?: SendMessageOptions,
    ) => {
      if (sendInFlightRef.current) {
        return;
      }
      sendInFlightRef.current = true;

      // send 已真正通过 in-flight guard 派发，调用方可跑不能在丢弃路径触发的一次性清理。
      options?.onSent?.();

      const text = message.text.trim();

      // 捕获发送前的 human message 计数，等待 server 的用户输入副本。
      prevHumanMsgCountRef.current = humanMessageCount;
      pendingUsageBaselineMessageIdsRef.current = new Set(
        persistedMessages
          .map(messageIdentity)
          .filter((id): id is string => Boolean(id)),
      );

      // 构造 uploading 状态的乐观文件列表
      const optimisticFiles: FileInMessage[] = (message.files ?? []).map(
        (f) => ({
          filename: f.filename ?? "",
          size: 0,
          status: "uploading" as const,
        }),
      );

      const hideFromUI = options?.additionalKwargs?.hide_from_ui === true;
      const optimisticAdditionalKwargs = {
        ...options?.additionalKwargs,
        ...(optimisticFiles.length > 0 ? { files: optimisticFiles } : {}),
      };

      const newOptimistic: Message[] = [];
      if (!hideFromUI) {
        newOptimistic.push({
          type: "human",
          id: `opt-human-${Date.now()}`,
          content: text ? [{ type: "text", text }] : "",
          additional_kwargs: optimisticAdditionalKwargs,
        });
      }

      if (optimisticFiles.length > 0 && !hideFromUI) {
        // 文件上传中的 mock AI 消息
        newOptimistic.push({
          type: "ai",
          id: `opt-ai-${Date.now()}`,
          content: t.uploads.uploadingFiles,
          additional_kwargs: { element: "task" },
        });
      }
      setOptimisticThreadId(threadId);
      setLiveMessagesThreadId(threadId);
      setOptimisticMessages(newOptimistic);

      listeners.current.onSend?.(threadId);

      let uploadedFileInfo: UploadedFileInfo[] = [];

      try {
        // 先上传文件（若有）
        if (message.files && message.files.length > 0) {
          setIsUploading(true);
          try {
            const filePromises = message.files.map((fileUIPart) =>
              promptInputFilePartToFile(fileUIPart),
            );

            const conversionResults = await Promise.all(filePromises);
            const files = conversionResults.filter(
              (file): file is File => file !== null,
            );
            const failedConversions = conversionResults.length - files.length;

            if (failedConversions > 0) {
              throw new Error(
                `Failed to prepare ${failedConversions} attachment(s) for upload. Please retry.`,
              );
            }

            if (!threadId) {
              throw new Error("Thread is not ready for file upload.");
            }

            if (files.length > 0) {
              const uploadResponse = await uploadFiles(threadId, files);
              uploadedFileInfo = uploadResponse.files;

              // 用 uploaded 状态 + 路径更新乐观 human 消息
              const uploadedFiles: FileInMessage[] = uploadedFileInfo.map(
                (info) => ({
                  filename: info.filename,
                  size: info.size,
                  path: info.virtual_path,
                  status: "uploaded" as const,
                }),
              );
              setOptimisticMessages((messages) => {
                if (messages.length > 1 && messages[0]) {
                  const humanMessage: Message = messages[0];
                  return [
                    {
                      ...humanMessage,
                      additional_kwargs: { files: uploadedFiles },
                    },
                    ...messages.slice(1),
                  ];
                }
                return messages;
              });
            }
          } catch (error) {
            const errorMessage =
              error instanceof Error
                ? error.message
                : "Failed to upload files.";
            toast.error(errorMessage);
            setOptimisticMessages([]);
            setOptimisticThreadId(null);
            setLiveMessagesThreadId(null);
            throw error;
          } finally {
            setIsUploading(false);
          }
        }

        // 构造提交的文件元数据（含在 additional_kwargs）
        const filesForSubmit: FileInMessage[] = uploadedFileInfo.map(
          (info) => ({
            filename: info.filename,
            size: info.size,
            path: info.virtual_path,
            status: "uploaded" as const,
          }),
        );

        await thread.submit(
          {
            messages: buildThreadSubmitMessages({
              text,
              additionalKwargs: options?.additionalKwargs,
              additionalInputMessages: options?.additionalInputMessages,
              filesForSubmit,
            }),
          },
          {
            threadId: threadId,
            streamSubgraphs: true,
            streamResumable: true,
            config: {
              recursion_limit: 1000,
            },
            context: {
              ...extraContext,
              ...context,
              thinking_enabled: context.mode !== "flash",
              is_plan_mode: context.mode === "pro" || context.mode === "ultra",
              subagent_enabled: context.mode === "ultra",
              reasoning_effort:
                context.reasoning_effort ??
                (context.mode === "ultra"
                  ? "high"
                  : context.mode === "pro"
                    ? "medium"
                    : context.mode === "thinking"
                      ? "low"
                      : undefined),
              thread_id: threadId,
            },
          },
        );
        void queryClient.invalidateQueries({ queryKey: ["threads", "search"] });
        void queryClient.invalidateQueries({
          queryKey: INFINITE_THREADS_QUERY_KEY_PREFIX,
        });
      } catch (error) {
        setOptimisticMessages([]);
        setOptimisticThreadId(null);
        setLiveMessagesThreadId(null);
        setIsUploading(false);
        throw error;
      } finally {
        sendInFlightRef.current = false;
      }
    },
    [
      thread,
      t.uploads.uploadingFiles,
      context,
      queryClient,
      humanMessageCount,
      persistedMessages,
    ],
  );

  const regenerateMessage = useCallback(
    async (
      threadId: string,
      messageId: string,
      supersededMessageIds: string[] = [messageId],
    ) => {
      if (sendInFlightRef.current || !threadId || !messageId) {
        return;
      }
      sendInFlightRef.current = true;
      prevHumanMsgCountRef.current = humanMessageCount;
      pendingUsageBaselineMessageIdsRef.current = new Set(
        persistedMessages
          .map(messageIdentity)
          .filter((id): id is string => Boolean(id)),
      );
      setLiveMessagesThreadId(threadId);
      listeners.current.onSend?.(threadId);
      let preparedSupersededRunId: string | null = null;
      let preparedSupersededMessageIds: string[] = [];

      try {
        const response = await fetch(
          `${getBackendBaseURL()}/api/threads/${encodeURIComponent(
            threadId,
          )}/runs/regenerate/prepare`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
            },
            credentials: "include",
            body: JSON.stringify({ message_id: messageId }),
          },
        );
        if (!response.ok) {
          throw new Error(await readResponseErrorMessage(response));
        }
        const prepared = (await response.json()) as RegeneratePrepareResponse;
        preparedSupersededRunId = prepared.target_run_id;
        preparedSupersededMessageIds = supersededMessageIds;
        setPendingSupersededRunIds((current) => {
          const next = new Set(current);
          next.add(prepared.target_run_id);
          return next;
        });
        setPendingSupersededMessageIds((current) => {
          const next = new Set(current);
          for (const id of supersededMessageIds) {
            next.add(id);
          }
          return next;
        });

        await thread.submit(prepared.input, {
          threadId,
          checkpoint: prepared.checkpoint,
          metadata: prepared.metadata,
          streamSubgraphs: true,
          streamResumable: true,
          config: {
            recursion_limit: 1000,
          },
          context: {
            ...context,
            thinking_enabled: context.mode !== "flash",
            is_plan_mode: context.mode === "pro" || context.mode === "ultra",
            subagent_enabled: context.mode === "ultra",
            reasoning_effort:
              context.reasoning_effort ??
              (context.mode === "ultra"
                ? "high"
                : context.mode === "pro"
                  ? "medium"
                  : context.mode === "thinking"
                    ? "low"
                    : undefined),
            thread_id: threadId,
          },
        });
        void queryClient.invalidateQueries({ queryKey: ["thread", threadId] });
        void queryClient.invalidateQueries({ queryKey: ["threads", "search"] });
        void queryClient.invalidateQueries({
          queryKey: INFINITE_THREADS_QUERY_KEY_PREFIX,
        });
        void queryClient.invalidateQueries({
          queryKey: threadTokenUsageQueryKey(threadId),
        });
      } catch (error) {
        setLiveMessagesThreadId(null);
        if (preparedSupersededRunId) {
          const supersededRunId = preparedSupersededRunId;
          setPendingSupersededRunIds((current) =>
            removeSetItems(current, [supersededRunId]),
          );
          setPendingSupersededMessageIds((current) =>
            removeSetItems(current, preparedSupersededMessageIds),
          );
        }
        toast.error(getStreamErrorMessage(error));
      } finally {
        sendInFlightRef.current = false;
      }
    },
    [context, humanMessageCount, persistedMessages, queryClient, thread],
  );

  // 缓存最新 thread 消息到 ref，与 incoming history 比对去重，且让 onUpdateEvent 不触发 re-render 就能访问完整消息列表。
  if (persistedMessages.length >= messagesRef.current.length) {
    messagesRef.current = persistedMessages;
  }

  const visibleOptimisticMessages = getVisibleOptimisticMessages(
    optimisticThreadId === currentViewThreadId ? optimisticMessages : [],
    prevHumanMsgCountRef.current,
    humanMessageCount,
  );

  // 摘要救援缓冲仅覆盖它捕获来源的 thread 的历史。visibleHistory 以 threadId 门控，
  // 故比较同一 prop 防缓冲闪进另一 thread 或 new-chat 屏，且在此读（而非 render 中清 ref）
  // 是 concurrent-mode 安全的。
  const rescueBuffer = pendingArchivedMessagesRef.current;
  const effectiveHistory =
    rescueBuffer.length > 0 && pendingArchiveThreadIdRef.current === threadId
      ? resolvePreservedHistory(visibleHistory, rescueBuffer)
      : visibleHistory;
  const mergedMessages = mergeMessages(
    effectiveHistory,
    persistedMessages,
    visibleOptimisticMessages,
  );
  const pendingUsageMessages = thread.isLoading
    ? getMessagesAfterBaseline(
        persistedMessages,
        pendingUsageBaselineMessageIdsRef.current,
      )
    : [];

  // 合并历史、live 流、乐观消息用于展示。
  // 历史消息可能与 thread.messages 重叠；thread.messages 优先。
  const mergedThread = {
    ...thread,
    stop: stopThread,
    values: hasVisibleStreamState ? thread.values : EMPTY_THREAD_VALUES,
    messages: mergedMessages,
  } as typeof thread;

  return {
    thread: mergedThread,
    pendingUsageMessages,
    sendMessage,
    regenerateMessage,
    isUploading,
    isHistoryLoading,
    hasMoreHistory,
    loadMoreHistory,
  } as const;
}

type ThreadHistoryOptions = {
  enabled?: boolean;
  pendingSupersededRunIds?: ReadonlySet<string>;
};

export function useThreadHistory(
  threadId: string,
  { enabled = true, pendingSupersededRunIds }: ThreadHistoryOptions = {},
) {
  const runs = useThreadRuns(threadId, { enabled });
  const threadIdRef = useRef(threadId);
  const runsRef = useRef(runs.data ?? []);
  const indexRef = useRef(-1);
  const loadingRef = useRef(false);
  const pendingLoadRef = useRef(false);
  const loadingRunIdRef = useRef<string | null>(null);
  const loadedRunIdsRef = useRef<Set<string>>(new Set());
  const runBeforeSeqRef = useRef<Map<string, number>>(new Map());
  const loadGenerationRef = useRef(0);
  const [loading, setLoading] = useState(false);
  const [messageRows, setMessageRows] = useState<RunMessage[]>([]);
  const [appendedMessages, setAppendedMessages] = useState<Message[]>([]);

  const supersededRunIds = useMemo(() => {
    return getSupersededRunIds(runs.data, pendingSupersededRunIds);
  }, [pendingSupersededRunIds, runs.data]);

  const messages = useMemo(() => {
    return buildVisibleHistoryMessages(
      messageRows,
      supersededRunIds,
      appendedMessages,
    );
  }, [appendedMessages, messageRows, supersededRunIds]);

  const loadMessages = useCallback(async () => {
    if (!enabled) {
      return;
    }
    const loadGeneration = loadGenerationRef.current;
    if (loadingRef.current) {
      const pendingRunIndex = findLatestUnloadedRunIndex(
        runsRef.current,
        loadedRunIdsRef.current,
      );
      const pendingRun = runsRef.current[pendingRunIndex];
      if (pendingRun && pendingRun.run_id !== loadingRunIdRef.current) {
        pendingLoadRef.current = true;
      }
      return;
    }
    if (runsRef.current.length === 0) {
      return;
    }

    loadingRef.current = true;
    setLoading(true);

    try {
      let consecutiveEmptyLoads = 0;
      do {
        pendingLoadRef.current = false;

        const nextRunIndex = findLatestUnloadedRunIndex(
          runsRef.current,
          loadedRunIdsRef.current,
        );
        indexRef.current = nextRunIndex;

        const run = runsRef.current[nextRunIndex];
        if (!run) {
          indexRef.current = -1;
          return;
        }

        const requestThreadId = threadIdRef.current;
        loadingRunIdRef.current = run.run_id;
        const beforeSeq = runBeforeSeqRef.current.get(run.run_id);
        const url = buildRunMessagesUrl(
          getBackendBaseURL(),
          requestThreadId,
          run.run_id,
          beforeSeq,
        );
        const result: RunMessagesPageResponse = await fetch(url, {
          method: "GET",
          headers: {
            "Content-Type": "application/json",
          },
          credentials: "include",
        }).then((res) => {
          return res.json();
        });
        if (
          loadGenerationRef.current !== loadGeneration ||
          threadIdRef.current !== requestThreadId
        ) {
          return;
        }
        const _messages = result.data.filter(
          (m) => !m.metadata.caller?.startsWith("middleware:"),
        );
        setMessageRows((prev) =>
          dedupeRunMessagesByIdentity([..._messages, ...prev]),
        );
        const nextBeforeSeq = getNextRunMessagesBeforeSeq(result);
        if (typeof nextBeforeSeq === "number") {
          runBeforeSeqRef.current.set(run.run_id, nextBeforeSeq);
          pendingLoadRef.current = true;
        } else if (nextBeforeSeq === undefined) {
          console.warn(
            `Run ${run.run_id} returned has_more without message seq values; leaving it pending for retry.`,
          );
        } else {
          runBeforeSeqRef.current.delete(run.run_id);
          loadedRunIdsRef.current.add(run.run_id);
          if (
            shouldAutoContinueOnEmptyRun(
              _messages.length,
              consecutiveEmptyLoads,
            )
          ) {
            consecutiveEmptyLoads += 1;
            pendingLoadRef.current = true;
          } else {
            consecutiveEmptyLoads = 0;
          }
        }
        indexRef.current = findLatestUnloadedRunIndex(
          runsRef.current,
          loadedRunIdsRef.current,
        );
      } while (pendingLoadRef.current);
    } catch (err) {
      console.error(err);
    } finally {
      if (loadGenerationRef.current === loadGeneration) {
        loadingRef.current = false;
        loadingRunIdRef.current = null;
        setLoading(false);
      }
    }
  }, [enabled]);
  useEffect(() => {
    const threadChanged = threadIdRef.current !== threadId;
    threadIdRef.current = threadId;

    if (!enabled || threadChanged) {
      loadGenerationRef.current += 1;
      runsRef.current = [];
      indexRef.current = -1;
      pendingLoadRef.current = false;
      loadingRunIdRef.current = null;
      loadedRunIdsRef.current = new Set();
      runBeforeSeqRef.current = new Map();
      loadingRef.current = false;
      setLoading(false);
      setMessageRows([]);
      setAppendedMessages([]);
    }

    if (!enabled) {
      return;
    }

    if (runs.data && runs.data.length > 0) {
      runsRef.current = runs.data ?? [];
      indexRef.current = findLatestUnloadedRunIndex(
        runs.data,
        loadedRunIdsRef.current,
      );
    }
    loadMessages().catch(() => {
      toast.error("Failed to load thread history.");
    });
  }, [enabled, threadId, runs.data, loadMessages]);

  const appendMessages = useCallback((_messages: Message[]) => {
    setAppendedMessages((prev) => {
      return dedupeMessagesByIdentity([...prev, ..._messages]);
    });
  }, []);
  const hasThreadId = Boolean(threadId);
  const hasUnloadedRuns = Boolean(
    runs.data?.some((run) => !loadedRunIdsRef.current.has(run.run_id)),
  );
  const isRunsLoading =
    enabled &&
    hasThreadId &&
    (runs.isLoading || (runs.isFetching && !runs.data));
  const isRunsUnresolved =
    enabled && hasThreadId && !runs.data && !runs.isError;
  const hasMore =
    enabled && hasThreadId && (indexRef.current >= 0 || hasUnloadedRuns);
  return {
    runs: runs.data,
    messages,
    loading: loading || isRunsLoading || isRunsUnresolved,
    appendMessages,
    hasMore,
    loadMore: loadMessages,
  };
}

export function useThreads(
  params: ThreadSearchParams = DEFAULT_THREAD_SEARCH_PARAMS,
) {
  const apiClient = getAPIClient();
  return useQuery<AgentThread[]>({
    ...buildThreadsSearchQueryOptions(apiClient, params),
  });
}

export const INFINITE_THREADS_PAGE_SIZE = 50;

export const INFINITE_THREADS_QUERY_KEY_PREFIX = [
  "threads",
  "searchInfinite",
] as const;

const INFINITE_THREADS_NEXT_PAGE_PARAM = Symbol(
  "helix.infiniteThreads.nextPageParam",
);

type InfiniteThreadsParams = Omit<
  Parameters<ThreadsClient["search"]>[0],
  "limit" | "offset"
>;

type InfiniteThreadsSearchClient = {
  threads: {
    search: ThreadsClient["search"];
  };
};

type InfiniteThreadsPageWithNextParam = AgentThread[] & {
  [INFINITE_THREADS_NEXT_PAGE_PARAM]?: number;
};

function annotateInfiniteThreadsPage(
  page: AgentThread[],
  nextPageParam: number | undefined,
): AgentThread[] {
  if (nextPageParam !== undefined) {
    Reflect.set(page, INFINITE_THREADS_NEXT_PAGE_PARAM, nextPageParam);
  }
  return page;
}

export async function fetchInfiniteThreadsPage(
  apiClient: InfiniteThreadsSearchClient,
  params: InfiniteThreadsParams,
  pageParam: number,
  pageSize: number = INFINITE_THREADS_PAGE_SIZE,
): Promise<AgentThread[]> {
  const threads: AgentThread[] = [];
  let offset = pageParam;
  let nextPageParam: number | undefined;

  while (threads.length < pageSize) {
    const currentLimit = pageSize - threads.length;
    const response = (await apiClient.threads.search<AgentThreadState>({
      ...params,
      limit: currentLimit,
      offset,
    })) as AgentThread[];

    threads.push(...filterThreadSearchResults(response, params));
    offset += response.length;

    if (response.length < currentLimit) {
      nextPageParam = undefined;
      break;
    }

    nextPageParam = offset;
  }

  return annotateInfiniteThreadsPage(threads, nextPageParam);
}

export function getInfiniteThreadsNextPageParam(
  lastPage: AgentThread[],
  allPages: AgentThread[][],
  pageSize: number = INFINITE_THREADS_PAGE_SIZE,
): number | undefined {
  const annotatedNextPageParam = Reflect.get(
    lastPage as InfiniteThreadsPageWithNextParam,
    INFINITE_THREADS_NEXT_PAGE_PARAM,
  );
  if (typeof annotatedNextPageParam === "number") {
    return annotatedNextPageParam;
  }

  if (lastPage.length < pageSize) {
    return undefined;
  }
  return allPages.reduce((sum, page) => sum + page.length, 0);
}

export function mapInfiniteThreadsCache(
  oldData: InfiniteData<AgentThread[]> | undefined,
  mapper: (thread: AgentThread) => AgentThread,
): InfiniteData<AgentThread[]> | undefined {
  if (!oldData) {
    return oldData;
  }
  return {
    ...oldData,
    pages: oldData.pages.map((page) => page.map(mapper)),
  };
}

export function filterInfiniteThreadsCache(
  oldData: InfiniteData<AgentThread[]> | undefined,
  predicate: (thread: AgentThread) => boolean,
): InfiniteData<AgentThread[]> | undefined {
  if (!oldData) {
    return oldData;
  }
  return {
    ...oldData,
    pages: oldData.pages.map((page) => page.filter(predicate)),
  };
}

export function useInfiniteThreads(
  params: InfiniteThreadsParams = {
    sortBy: "updated_at",
    sortOrder: "desc",
    select: ["thread_id", "updated_at", "values", "metadata"],
  },
) {
  const apiClient = getAPIClient();
  return useInfiniteQuery<
    AgentThread[],
    Error,
    InfiniteData<AgentThread[]>,
    readonly unknown[],
    number
  >({
    queryKey: [...INFINITE_THREADS_QUERY_KEY_PREFIX, params],
    initialPageParam: 0,
    queryFn: async ({ pageParam }) =>
      fetchInfiniteThreadsPage(
        apiClient,
        params,
        pageParam,
        INFINITE_THREADS_PAGE_SIZE,
      ),
    getNextPageParam: (lastPage, allPages) =>
      getInfiniteThreadsNextPageParam(lastPage, allPages),
    refetchOnWindowFocus: false,
  });
}

export function useThreadRuns(
  threadId?: string,
  { enabled = true }: { enabled?: boolean } = {},
) {
  const apiClient = getAPIClient();
  return useQuery<Run[]>({
    queryKey: ["thread", threadId],
    queryFn: async () => {
      if (!threadId) {
        return [];
      }
      const response = await apiClient.runs.list(threadId);
      return response;
    },
    enabled: enabled && Boolean(threadId),
    refetchOnWindowFocus: false,
  });
}

export function useThreadMetadata(
  threadId?: string | null,
  {
    enabled = true,
    isMock = false,
  }: { enabled?: boolean; isMock?: boolean } = {},
) {
  const apiClient = getAPIClient(isMock);
  return useQuery<AgentThread | null>({
    queryKey: ["thread", "metadata", threadId, isMock],
    queryFn: async () => {
      if (!threadId) {
        return null;
      }
      try {
        const response = await apiClient.threads.get(threadId);
        return response as AgentThread;
      } catch (error) {
        if (isThreadMissingError(error)) {
          return null;
        }
        throw error;
      }
    },
    enabled: enabled && Boolean(threadId),
    retry: false,
    refetchOnWindowFocus: false,
  });
}

export function useThreadTokenUsage(
  threadId?: string | null,
  { enabled = true }: { enabled?: boolean } = {},
) {
  return useQuery<ThreadTokenUsageResponse | null>({
    queryKey: threadTokenUsageQueryKey(threadId),
    queryFn: async () => {
      if (!threadId) {
        return null;
      }
      return fetchThreadTokenUsage(threadId);
    },
    enabled: enabled && Boolean(threadId),
    retry: false,
    refetchOnWindowFocus: false,
  });
}

export function useBranchThread() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({
      threadId,
      messageId,
      messageIds,
      title,
    }: {
      threadId: string;
      messageId: string;
      messageIds?: string[];
      title?: string;
    }) => branchThreadFromTurn(threadId, { messageId, messageIds, title }),
    onSuccess(response, { threadId }) {
      void queryClient.invalidateQueries({
        queryKey: ["thread", "metadata", response.thread_id],
      });
      void queryClient.invalidateQueries({
        queryKey: ["thread", "metadata", threadId],
      });
      void queryClient.invalidateQueries({ queryKey: ["threads", "search"] });
      void queryClient.invalidateQueries({
        queryKey: INFINITE_THREADS_QUERY_KEY_PREFIX,
      });
    },
  });
}

export function useRunDetail(threadId: string, runId: string) {
  const apiClient = getAPIClient();
  return useQuery<Run>({
    queryKey: ["thread", threadId, "run", runId],
    queryFn: async () => {
      const response = await apiClient.runs.get(threadId, runId);
      return response;
    },
    refetchOnWindowFocus: false,
  });
}

async function deleteLocalThreadData(threadId: string) {
  const response = await fetch(
    `${getBackendBaseURL()}/api/threads/${encodeURIComponent(threadId)}`,
    {
      method: "DELETE",
    },
  );

  // 404 表示 thread 已删 -- 即期望终态。前一次 apiClient.threads.delete 调同一
  // gateway handler（nginx 重写 /api/langgraph/threads/* 到 /api/threads/*），
  // 删 thread_meta 行，故这第二次 delete 的 ownership guard 404。当成功处理保持幂等。
  if (!response.ok && response.status !== 404) {
    const error = await response
      .json()
      .catch(() => ({ detail: "Failed to delete local thread data." }));
    throw new Error(error.detail ?? "Failed to delete local thread data.");
  }
}

async function deleteThreadEverywhere(
  apiClient: ThreadDeleteClient,
  threadId: string,
) {
  await apiClient.threads.delete(threadId);
  await deleteLocalThreadData(threadId);
}

export async function findSidecarThreadIdsForParent(
  apiClient: ThreadSidecarSearchClient,
  parentThreadId: string,
) {
  const threadIds: string[] = [];
  const limit = 100;
  let offset = 0;

  while (true) {
    const response = await apiClient.threads.search({
      metadata: {
        [SIDECAR_METADATA_KEY]: true,
        parent_thread_id: parentThreadId,
      },
      limit,
      offset,
      sortBy: "updated_at",
      sortOrder: "desc",
      select: ["thread_id", "metadata"],
    });

    for (const thread of response) {
      if (
        isSidecarThread(thread) &&
        thread.metadata?.parent_thread_id === parentThreadId
      ) {
        threadIds.push(thread.thread_id);
      }
    }

    if (response.length < limit) {
      break;
    }
    offset += response.length;
  }

  return threadIds;
}

async function deleteSidecarThreadsForParent(
  apiClient: ThreadDeleteClient,
  parentThreadId: string,
) {
  let sidecarThreadIds: string[];
  try {
    sidecarThreadIds = await findSidecarThreadIdsForParent(
      apiClient,
      parentThreadId,
    );
  } catch (err) {
    console.warn(
      `Failed to look up sidecar threads for parent ${parentThreadId}; skipping cascade cleanup. Orphaned sidecar threads may remain.`,
      err,
    );
    return [];
  }

  const results = await Promise.allSettled(
    sidecarThreadIds.map((threadId) =>
      deleteThreadEverywhere(apiClient, threadId),
    ),
  );

  const failedDeletions = results
    .map((result, index) =>
      result.status === "rejected"
        ? { threadId: sidecarThreadIds[index], reason: result.reason }
        : null,
    )
    .filter((entry): entry is { threadId: string; reason: unknown } =>
      Boolean(entry),
    );

  if (failedDeletions.length > 0) {
    console.warn(
      `Failed to delete ${failedDeletions.length} sidecar thread(s) for parent ${parentThreadId}; orphaned sidecar threads may remain.`,
      failedDeletions,
    );
  }

  return sidecarThreadIds.filter((_, index) => {
    return results[index]?.status === "fulfilled";
  });
}

export function useDeleteThread() {
  const queryClient = useQueryClient();
  const apiClient = getAPIClient() as ThreadDeleteClient;
  return useMutation({
    mutationFn: async ({
      threadId,
      onRemoteDeleted,
    }: {
      threadId: string;
      onRemoteDeleted?: () => void;
    }) => {
      const deletedSidecarThreadIds = await deleteSidecarThreadsForParent(
        apiClient,
        threadId,
      );
      await apiClient.threads.delete(threadId);
      onRemoteDeleted?.();
      await deleteLocalThreadData(threadId);
      return deletedSidecarThreadIds;
    },
    onSuccess(deletedSidecarThreadIds, { threadId }) {
      const deletedThreadIds = new Set([threadId, ...deletedSidecarThreadIds]);
      queryClient.setQueriesData(
        {
          queryKey: ["threads", "search"],
          exact: false,
        },
        (oldData: Array<AgentThread> | undefined) => {
          if (oldData == null) {
            return oldData;
          }
          return oldData.filter((t) => !deletedThreadIds.has(t.thread_id));
        },
      );
      queryClient.setQueriesData(
        {
          queryKey: INFINITE_THREADS_QUERY_KEY_PREFIX,
          exact: false,
        },
        (oldData: InfiniteData<AgentThread[]> | undefined) =>
          filterInfiniteThreadsCache(
            oldData,
            (t) => !deletedThreadIds.has(t.thread_id),
          ),
      );
    },

    onSettled() {
      void queryClient.invalidateQueries({ queryKey: ["threads", "search"] });
      void queryClient.invalidateQueries({
        queryKey: INFINITE_THREADS_QUERY_KEY_PREFIX,
      });
    },
  });
}

export function useRenameThread() {
  const queryClient = useQueryClient();
  const apiClient = getAPIClient();
  return useMutation({
    mutationFn: async ({
      threadId,
      title,
    }: {
      threadId: string;
      title: string;
    }) => {
      await apiClient.threads.updateState(threadId, {
        values: { title },
      });
    },
    onSuccess(_, { threadId, title }) {
      queryClient.setQueriesData(
        {
          queryKey: ["threads", "search"],
          exact: false,
        },
        (oldData: Array<AgentThread>) => {
          return oldData.map((t) => {
            if (t.thread_id === threadId) {
              return {
                ...t,
                values: {
                  ...t.values,
                  title,
                },
              };
            }
            return t;
          });
        },
      );
      queryClient.setQueriesData(
        {
          queryKey: INFINITE_THREADS_QUERY_KEY_PREFIX,
          exact: false,
        },
        (oldData: InfiniteData<AgentThread[]> | undefined) =>
          mapInfiniteThreadsCache(oldData, (t) =>
            t.thread_id === threadId
              ? {
                  ...t,
                  values: {
                    ...t.values,
                    title,
                  },
                }
              : t,
          ),
      );
    },
  });
}
```
