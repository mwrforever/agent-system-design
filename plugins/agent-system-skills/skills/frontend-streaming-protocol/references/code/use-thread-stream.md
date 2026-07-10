# 完整源码：useThreadStream reducer + custom 事件归一化

> 本文件给出 `frontend/src/core/threads/hooks.ts`（`useThreadStream` 的协议级 reducer）+ `frontend/src/core/tasks/{types,steps}.ts`（custom 事件 -> step 归一化）+ `frontend/src/core/messages/utils.ts`（去重 / 消毒边界）的**完整真实源码**。
>
> 真实实现已按匿名化规则映射到中立结构，去除一切项目字样。`@langchain/langgraph-sdk` / `@tanstack/react-query` 等真实依赖名保留。原代码注释保留以保真；关键处补中文注解。
>
> 三路乐观合并的整体架构（历史 + 实时流 + 乐观 + 摘要救援缓冲）归 [[frontend-app-design]]；本文件聚焦"SDK 事件 -> message 累积 / custom 渲染"的协议级 reducer 函数。

## §1 useThreadStream（useStream 回调映射 + message 去重 + 合并）

### §1a messageIdentity + dedupeMessagesByIdentity（UI 去重，保留 last index）

```ts
// frontend/src/core/threads/hooks.ts
import type { Message } from "@langchain/langgraph-sdk";
import { isHiddenFromUIMessage } from "../messages/utils";

// 摘要 middleware 的 update key 集合（兼容新旧命名）
const SUMMARIZATION_MIDDLEWARE_UPDATE_KEYS = new Set([
  "SummarizationMiddleware.before_model",
  "HelixSummarizationMiddleware.before_model",
]);

function isNonEmptyString(value: string | undefined): value is string {
  return typeof value === "string" && value.length > 0;
}

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

  // 这是 UI 展示去重规约，不是 LangChain 通用消息流契约。与可见消息共享 identity
  // 的隐藏消息在此合并视图里被当作控制消息处理；承载独立 tracing/task 语义的
  // 隐藏消息应使用独立 id 或自定义 stream/state channel，而非依赖消息去重保留。
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
```

### §1b mergeMessages（历史 + 实时流 + 乐观 三路合并纯函数）

```ts
// frontend/src/core/threads/hooks.ts

export function mergeMessages(
  historyMessages: Message[],
  threadMessages: Message[],
  optimisticMessages: Message[],
): Message[] {
  // 只有可见的实时消息才裁剪重叠历史。隐藏消息在此路径是 UI 控制消息，不是
  // 可观测记录；任何需作为 task/tracing 数据存活的隐藏消息应走 custom 事件或
  // 独立 state channel，而非参与此重叠启发式。

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

  // 重叠是 historyMessages 的连续后缀（最新历史 == 最旧线程消息）。从尾扫描：
  // 当消息已在 thread 中时缩 cutoff，碰到不在 thread 中的即停--此前皆为非重叠。
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
```

### §1c useThreadStream 的 useStream 配置（回调映射 + custom 事件处理）

```ts
// frontend/src/core/threads/hooks.ts
import type { AIMessage, Message, Run } from "@langchain/langgraph-sdk";
import { useStream } from "@langchain/langgraph-sdk/react";
import { type QueryClient, type InfiniteData, useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";

import { getAPIClient } from "../api";
import { useI18n } from "../i18n/hooks";
import { isHiddenFromUIMessage } from "../messages/utils";
import { useUpdateSubtask } from "../tasks/context";
import { messageToStep } from "../tasks/steps";
import { threadTokenUsageQueryKey } from "./token-usage";
import type { AgentThread, AgentThreadState } from "./types";

export type ToolEndEvent = { name: string; data: unknown };

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
  // 乐观消息：server stream 响应前展示。
  const [optimisticMessages, setOptimisticMessages] = useState<Message[]>([]);
  const [optimisticThreadId, setOptimisticThreadId] = useState<string | null>(null);
  const [liveMessagesThreadId, setLiveMessagesThreadId] = useState<string | null>(null);
  const [onStreamThreadId, setOnStreamThreadId] = useState(() => threadId);
  const threadIdRef = useRef<string | null>(threadId ?? null);
  const startedRef = useRef(false);
  const listeners = useRef({ onSend, onStart, onFinish, onToolEnd });

  const queryClient = useQueryClient();
  const updateSubtask = useUpdateSubtask();

  // ... useThreadHistory / 乐观消息 state / 摘要救援缓冲等省略（见 [[frontend-app-design]]）...

  const thread = useStream<AgentThreadState>({
    client: getAPIClient(isMock),           // 单例 client（见 singleton-client.md）
    assistantId: "lead_agent",
    threadId: onStreamThreadId,
    reconnectOnMount: true,                 // mount 时靠 Last-Event-ID 续传
    fetchStateHistory: { limit: 1 },        // 拉最新 1 个 state 快照防空白
    onCreated(meta) {
      // 对应 metadata 事件 {run_id, thread_id}：写 run_id/thread_id + 乐观插 search 缓存
      handleStreamStart(meta.thread_id, meta.run_id);
      const now = new Date().toISOString();
      upsertThreadInSearchCache(queryClient, {
        thread_id: meta.thread_id,
        created_at: now,
        updated_at: now,
        metadata: context.agent_name ? { agent_name: context.agent_name } : {},
        status: "busy",
        values: { title: t.pages.newChat, messages: [], artifacts: [] },
        interrupts: {},
      });
      // ... 同样 upsertThreadInInfiniteCache ...
    },
    onLangChainEvent(event) {
      // on_tool_end 回调（非 SSE 事件，SDK 内部 LangChain callback 映射）
      if (event.event === "on_tool_end") {
        listeners.current.onToolEnd?.({ name: event.name, data: event.data });
      }
    },
    onUpdateEvent(data) {
      // 对应 updates 事件 {node: writes}：摘要救援 + title 同步缓存
      const _messages = getSummarizationMiddlewareMessages(data);
      if (_messages && _messages.length >= 2) {
        // ... 摘要救援缓冲（见 [[frontend-app-design]]）...
      }

      const updates: Array<Partial<AgentThreadState> | null> = Object.values(data || {});
      for (const update of updates) {
        if (update && "title" in update && update.title) {
          // 同步 title 到 search / infinite 缓存
          void queryClient.setQueriesData(
            { queryKey: ["threads", "search"], exact: false },
            (oldData: Array<AgentThread> | undefined) =>
              oldData?.map((thr) =>
                thr.thread_id === threadIdRef.current
                  ? { ...thr, values: { ...thr.values, title: update.title } }
                  : thr,
              ),
          );
          // ... 同样更新 infinite 缓存 ...
        }
      }
    },
    onCustomEvent(event: unknown) {
      // 对应 custom 事件：task_running 累积 step / llm_retry toast
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
        // 累积完整 step 历史而非覆盖（#3779）：latestMessage 保留折叠头提示，
        // 归一化的 step（assistant turn 或 tool output）追加到 timeline。
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
      // 对应 error 事件：清乐观 + toast
      setOptimisticMessages([]);
      setOptimisticThreadId(null);
      setLiveMessagesThreadId(null);
      toast.error(getStreamErrorMessage(error));
      // ... token-usage baseline 快照 ...
    },
    onFinish(state) {
      // 对应 end 事件（END_SENTINEL）：失效缓存
      listeners.current.onFinish?.(state.values);
      invalidateStoppedThreadCaches(queryClient, threadIdRef.current, isMock);
    },
  });

  // ... sendMessage / regenerateMessage / 三路合并返回等省略（见 [[frontend-app-design]]）...

  return { thread, sendMessage, regenerateMessage, /* ... */ } as const;
}
```

## §2 SubtaskStep + messageToStep + eventsToSteps + mergeSteps（custom 事件 -> step 归一化）

```ts
// frontend/src/core/tasks/types.ts
import type { AIMessage } from "@langchain/langgraph-sdk";
import type { SubtaskStep } from "./steps";

export interface Subtask {
  id: string;
  status: "in_progress" | "completed" | "failed";
  subagent_type: string;
  description: string;
  latestMessage?: AIMessage;
  /**
   * 子代理的完整有序 step 历史（assistant turn + tool output）。
   * 从 task_running 事件实时累积，展开历史 run 时回填（#3779）。
   * 替代旧的"仅 latestMessage"行为。
   */
  steps?: SubtaskStep[];
  prompt: string;
  result?: string;
  error?: string;
  /**
   * guardrail cap 提前结束 run 的原因（token_capped / turn_capped / loop_capped），
   * 正常 run 为 undefined。pill 状态保持正常（completed/failed）；此字段携带
   * cap 细节，供未来 badge 显示"capped"而无需解析 result 文本（#3875 Phase 2）。
   */
  stopReason?: string;
}
```

```ts
// frontend/src/core/tasks/steps.ts
/**
 * 子代理 step 模型，实时（SSE）与重载（fetch）路径共用。
 *
 * #3779：子任务卡曾只保最新子代理消息，早期步骤一闪而过、刷新全丢。SubtaskStep
 * 是归一化的可渲染子代理进度单元--一个 assistant turn（kind:"ai"，带 tool-call
 * 请求）或一个 tool result（kind:"tool"，带工具输出）。后端以同形状持久化为
 * subagent.step run-event 内容；messageToStep 为实时 task_running 事件镜像
 * 该归一化（实时事件仍携带 raw message）。
 */

export interface SubtaskStepToolCall {
  name?: string;
  args?: unknown;
}

export interface SubtaskStep {
  message_index: number;
  kind: "ai" | "tool";
  text: string;
  truncated?: boolean;
  tool_calls?: SubtaskStepToolCall[];
  tool_name?: string;
}

type RawMessage = {
  type?: string;
  content?: unknown;
  name?: string;
  tool_calls?: { name?: string; args?: unknown; [key: string]: unknown }[];
  [key: string]: unknown;
};

function contentToText(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }
  if (Array.isArray(content)) {
    return content
      .map((block) => {
        if (typeof block === "string") {
          return block;
        }
        if (block && typeof block === "object" && "text" in block) {
          const text = (block as { text?: unknown }).text;
          return typeof text === "string" ? text : "";
        }
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  return "";
}

/** 把 raw 子代理消息（实时 task_running payload）归一化为 step。 */
export function messageToStep(
  message: RawMessage,
  messageIndex: number,
): SubtaskStep {
  const kind = message.type === "tool" ? "tool" : "ai";
  const step: SubtaskStep = {
    message_index: messageIndex,
    kind,
    text: contentToText(message.content),
  };

  if (kind === "tool") {
    step.tool_name = message.name;
  } else {
    step.tool_calls = (message.tool_calls ?? []).map((call) => ({
      name: call.name,
      args: call.args,
    }));
  }

  return step;
}

/**
 * 子任务卡 timeline 渲染的 step（#3779）。按 message_index 交错子代理的
 * assistant turn 与 tool step：
 *
 * - tool step 总是保留（每行"子代理跑了 <tool>"）；
 * - AI step 仅在携带可见推理文本时保留--只请求工具的 turn（空白文本）除后续
 *   tool 行外无额外信息，故丢弃；
 * - 任务 completed 时，末尾无 tool_calls 的 AI step 是子代理最终答案，卡已
 *   作 task.result 渲染，此处丢弃避免答案显示两次。
 */
export function stepsForDisplay(
  steps: SubtaskStep[] | undefined,
  status: "in_progress" | "completed" | "failed",
): SubtaskStep[] {
  const visible = (steps ?? [])
    .filter((step) => step.kind === "tool" || step.text.trim() !== "")
    .sort((a, b) => a.message_index - b.message_index);

  if (status === "completed") {
    const last = visible[visible.length - 1];
    if (last?.kind === "ai" && !last?.tool_calls?.length) {
      return visible.slice(0, -1);
    }
  }
  return visible;
}

type RunEvent = {
  event_type?: string;
  content?: unknown;
  metadata?: { task_id?: string } & Record<string, unknown>;
};

/**
 * 把持久化 run event（GET /{rid}/events）映射为子任务的 step，
 * 只保留 taskId 的 subagent.step 事件并按 message_index 排序。持久化 content
 * 已匹配 step 形状（后端 build_subagent_step 产出），故此处仅过滤/投影/排序。
 */
export function eventsToSteps(
  events: RunEvent[],
  taskId: string,
): SubtaskStep[] {
  const steps: SubtaskStep[] = [];
  for (const event of events) {
    if (event.event_type !== "subagent.step") {
      continue;
    }
    const content = event.content as (SubtaskStep & { task_id?: string }) | undefined;
    const eventTaskId = content?.task_id ?? event.metadata?.task_id;
    if (!content || eventTaskId !== taskId) {
      continue;
    }
    steps.push({
      message_index: content.message_index,
      kind: content.kind,
      text: content.text ?? "",
      truncated: content.truncated,
      tool_calls: content.tool_calls,
      tool_name: content.tool_name,
    });
  }
  return steps.sort((a, b) => a.message_index - b.message_index);
}

/**
 * 把 incoming step 合并进 existing，按 message_index 去重（incoming 胜）并
 * 保持有序。用于调和实时 SSE step 与展开时 fetch 的 step，不重复渲染共享 index。
 */
export function mergeSteps(
  existing: SubtaskStep[],
  incoming: SubtaskStep[],
): SubtaskStep[] {
  const byIndex = new Map<number, SubtaskStep>();
  for (const step of existing) {
    byIndex.set(step.message_index, step);
  }
  for (const step of incoming) {
    byIndex.set(step.message_index, step);
  }
  return [...byIndex.values()].sort((a, b) => a.message_index - b.message_index);
}
```

## §3 isHiddenFromUIMessage + HIDDEN_CONTROL_MESSAGE_NAMES + INTERNAL_MARKER_TAGS（去重 / 消毒边界）

```ts
// frontend/src/core/messages/utils.ts
import type { Message } from "@langchain/langgraph-sdk";

/**
 * 隐藏的控制消息名集合。这些消息参与 identity 追踪（dedupeMessagesByIdentity
 * 的 lastIndexByIdentity）但不参与展示裁剪（lastVisibleIndexByIdentity）。
 */
const HIDDEN_CONTROL_MESSAGE_NAMES = new Set([
  "summary",
  "loop_warning",
  "todo_reminder",
  "todo_completion_reminder",
]);

/**
 * 判断消息是否对 UI 隐藏。
 *
 * 三条判定（任一为真即隐藏）：
 * 1. additional_kwargs.hide_from_ui === true（后端显式标记）
 * 2. message.name 在 HIDDEN_CONTROL_MESSAGE_NAMES 中（控制消息名）
 * 3. type==="human" 且内容含 <slash_skill_activation> 且剥离 uploaded_files 后为空
 *    （slash 技能激活的空壳消息）
 */
export function isHiddenFromUIMessage(message: Message) {
  const content = extractTextFromMessage(message);
  return (
    message.additional_kwargs?.hide_from_ui === true ||
    (typeof message.name === "string" &&
      HIDDEN_CONTROL_MESSAGE_NAMES.has(message.name)) ||
    (message.type === "human" &&
      content.includes("<slash_skill_activation>") &&
      stripUploadedFilesTag(content).length === 0)
  );
}

/**
 * 后端注入的已知 marker 标签。
 *
 * 主过滤是 isHiddenFromUIMessage。此列表是纵深防御：对任何因 middleware bug、
 * provider quirk 或合并冲突 regression 而漏标 hide_from_ui 的消息做兜底剥离。
 */
export const INTERNAL_MARKER_TAGS = [
  "uploaded_files",
  "slash_skill_activation",
  "system-reminder",
  "memory",
  "current_date",
] as const;

const INTERNAL_MARKER_RE = new RegExp(
  `<(${INTERNAL_MARKER_TAGS.join("|")})>[\\s\\S]*?</\\1>`,
  "g",
);

/**
 * 从消息内容剥离所有已知后端注入 marker。
 *
 * 用于 chat 导出路径（marker 泄露是隐私 regression）。UI 渲染路径应继续用
 * stripUploadedFilesTag--它们经独立 filter 接收 hide_from_ui 消息，且更窄的
 * 函数避免误剥用户可能合法输入的 meta 讨论内容（如问模型其 <memory> 系统）。
 */
export function stripInternalMarkers(content: string): string {
  return content.replace(INTERNAL_MARKER_RE, "").trim();
}
```

> `extractTextFromMessage` / `stripUploadedFilesTag` 为同模块内的纯文本工具函数（从 message content 提取文本 / 剥离 `<uploaded_files>` 标签），此处省略以聚焦去重与消毒的判定逻辑。完整实现见真实源码 `frontend/src/core/messages/utils.ts`。
