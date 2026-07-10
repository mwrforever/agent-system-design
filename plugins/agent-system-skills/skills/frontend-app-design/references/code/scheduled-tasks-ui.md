# 完整源码：scheduled-tasks REST 四件套

> 本文件给出定时任务管理页的 REST 四件套完整实现：`frontend/src/core/scheduled-tasks/types.ts`（类型）+ `frontend/src/core/scheduled-tasks/api.ts`（REST 调用）+ `frontend/src/core/scheduled-tasks/hooks.ts`（TanStack Query 封装）+ `frontend/src/app/workspace/scheduled-tasks/page.tsx`（页面组件）。后端 `ScheduledTaskService` poller + lease + cron/once + non_interactive 剥离见 [[scheduled-tasks]]。
>
> 真实实现已按匿名化规则映射到中立结构，去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

## §1 types.ts（类型定义）

```ts
// frontend/src/core/scheduled-tasks/types.ts
export type ScheduledTask = {
  id: string;
  thread_id: string | null;
  context_mode: "fresh_thread_per_run" | "reuse_thread";
  title: string;
  prompt: string;
  schedule_type: "once" | "cron";
  schedule_spec: Record<string, unknown>;
  timezone: string;
  status:
    | "enabled"
    | "paused"
    | "running"
    | "completed"
    | "failed"
    | "cancelled";
  next_run_at: string | null;
  last_run_at: string | null;
  last_run_id: string | null;
  last_thread_id: string | null;
  last_error: string | null;
  run_count: number;
  created_at: string;
  updated_at: string;
};

export type ScheduledTaskRun = {
  id: string;
  task_id: string;
  thread_id: string;
  run_id: string | null;
  scheduled_for: string;
  trigger: "scheduled" | "manual";
  status:
    | "queued"
    | "running"
    | "success"
    | "failed"
    | "skipped"
    | "interrupted";
  error: string | null;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
};
```

## §2 api.ts（REST 调用，全走 fetcher.ts:fetch 自动 CSRF）

```ts
// frontend/src/core/scheduled-tasks/api.ts
import { throwGatewayApiError } from "@/core/api/errors";
import { fetch } from "@/core/api/fetcher";      // 自动 CSRF + credentials:include + 401 跳登录
import { getBackendBaseURL } from "@/core/config";

import type { ScheduledTask, ScheduledTaskRun } from "./types";

function scheduledTasksUrl(path: string): string {
  return `${getBackendBaseURL()}/api/scheduled-tasks${path}`;
}

export async function fetchScheduledTasks(): Promise<ScheduledTask[]> {
  const response = await fetch(scheduledTasksUrl(""));   // GET，无需 CSRF
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to load scheduled tasks: ${response.statusText}`,
    );
  }
  return response.json();
}

export async function fetchThreadScheduledTasks(
  threadId: string,
): Promise<ScheduledTask[]> {
  const response = await fetch(
    `${getBackendBaseURL()}/api/threads/${encodeURIComponent(threadId)}/scheduled-tasks`,
  );
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to load thread scheduled tasks: ${response.statusText}`,
    );
  }
  return response.json();
}

export async function fetchScheduledTaskRuns(
  taskId: string,
): Promise<ScheduledTaskRun[]> {
  const response = await fetch(
    scheduledTasksUrl(`/${encodeURIComponent(taskId)}/runs`),
  );
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to load scheduled task runs: ${response.statusText}`,
    );
  }
  return response.json();
}

export type ScheduledTaskPayload = {
  context_mode: "fresh_thread_per_run" | "reuse_thread";
  thread_id?: string | null;
  title: string;
  prompt: string;
  schedule_type: "once" | "cron";
  schedule_spec: Record<string, unknown>;
  timezone: string;
};

export async function createScheduledTask(
  payload: ScheduledTaskPayload,
): Promise<ScheduledTask> {
  const response = await fetch(scheduledTasksUrl(""), {     // POST，fetcher 自动塞 X-CSRF-Token
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to create scheduled task: ${response.statusText}`,
    );
  }
  return response.json();
}

export async function updateScheduledTask(
  taskId: string,
  payload: Partial<Omit<ScheduledTaskPayload, "thread_id" | "schedule_type">>,
): Promise<ScheduledTask> {
  const response = await fetch(
    scheduledTasksUrl(`/${encodeURIComponent(taskId)}`),
    {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    },
  );
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to update scheduled task: ${response.statusText}`,
    );
  }
  return response.json();
}

export async function pauseScheduledTask(
  taskId: string,
): Promise<ScheduledTask> {
  const response = await fetch(
    scheduledTasksUrl(`/${encodeURIComponent(taskId)}/pause`),
    { method: "POST" },
  );
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to pause scheduled task: ${response.statusText}`,
    );
  }
  return response.json();
}

export async function resumeScheduledTask(
  taskId: string,
): Promise<ScheduledTask> {
  const response = await fetch(
    scheduledTasksUrl(`/${encodeURIComponent(taskId)}/resume`),
    { method: "POST" },
  );
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to resume scheduled task: ${response.statusText}`,
    );
  }
  return response.json();
}

export async function triggerScheduledTask(
  taskId: string,
): Promise<{ id: string; triggered: boolean }> {
  const response = await fetch(
    scheduledTasksUrl(`/${encodeURIComponent(taskId)}/trigger`),
    { method: "POST" },
  );
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to trigger scheduled task: ${response.statusText}`,
    );
  }
  return response.json();
}

export async function deleteScheduledTask(
  taskId: string,
): Promise<{ id: string; deleted: boolean }> {
  const response = await fetch(
    scheduledTasksUrl(`/${encodeURIComponent(taskId)}`),
    {
      method: "DELETE",
    },
  );
  if (!response.ok) {
    await throwGatewayApiError(
      response,
      `Failed to delete scheduled task: ${response.statusText}`,
    );
  }
  return response.json();
}
```

## §3 hooks.ts（TanStack Query 封装）

```ts
// frontend/src/core/scheduled-tasks/hooks.ts
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { useI18n } from "@/core/i18n/hooks";

import {
  createScheduledTask,
  deleteScheduledTask,
  fetchScheduledTaskRuns,
  fetchScheduledTasks,
  fetchThreadScheduledTasks,
  pauseScheduledTask,
  resumeScheduledTask,
  triggerScheduledTask,
  updateScheduledTask,
  type ScheduledTaskPayload,
} from "./api";

// 任务列表：15s 轮询，后台 tab 不轮询
export function useScheduledTasks() {
  return useQuery({
    queryKey: ["scheduled-tasks"],
    queryFn: fetchScheduledTasks,
    refetchInterval: 15000,
    refetchIntervalInBackground: false,
  });
}

export function useThreadScheduledTasks(threadId: string | null | undefined) {
  return useQuery({
    queryKey: ["scheduled-tasks", "thread", threadId],
    queryFn: () => fetchThreadScheduledTasks(threadId ?? ""),
    enabled: Boolean(threadId),
  });
}

// 运行历史：同样 15s 轮询
export function useScheduledTaskRuns(taskId: string | null | undefined) {
  return useQuery({
    queryKey: ["scheduled-tasks", "runs", taskId],
    queryFn: () => fetchScheduledTaskRuns(taskId ?? ""),
    enabled: Boolean(taskId),
    refetchInterval: 15000,
    refetchIntervalInBackground: false,
  });
}

// 创建 mutation：成功后失效列表缓存；失败 toast
export function useCreateScheduledTask() {
  const queryClient = useQueryClient();
  const { t } = useI18n();
  return useMutation({
    mutationFn: (payload: ScheduledTaskPayload) => createScheduledTask(payload),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["scheduled-tasks"] });
    },
    onError: (error: Error) => {
      toast.error(`${t.scheduledTasks.errors.create}: ${error.message}`);
    },
  });
}

// 更新 mutation：成功后失效列表 + thread 过滤视图缓存
export function useUpdateScheduledTask(taskId: string) {
  const queryClient = useQueryClient();
  const { t } = useI18n();
  return useMutation({
    mutationFn: (
      payload: Partial<
        Omit<ScheduledTaskPayload, "thread_id" | "schedule_type">
      >,
    ) => updateScheduledTask(taskId, payload),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["scheduled-tasks"] });
      void queryClient.invalidateQueries({
        queryKey: ["scheduled-tasks", "thread"],
      });
    },
    onError: (error: Error) => {
      toast.error(`${t.scheduledTasks.errors.update}: ${error.message}`);
    },
  });
}

export function usePauseScheduledTask() {
  const queryClient = useQueryClient();
  const { t } = useI18n();
  return useMutation({
    mutationFn: (taskId: string) => pauseScheduledTask(taskId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["scheduled-tasks"] });
      void queryClient.invalidateQueries({
        queryKey: ["scheduled-tasks", "thread"],
      });
    },
    onError: (error: Error) => {
      toast.error(`${t.scheduledTasks.errors.pause}: ${error.message}`);
    },
  });
}

export function useResumeScheduledTask() {
  const queryClient = useQueryClient();
  const { t } = useI18n();
  return useMutation({
    mutationFn: (taskId: string) => resumeScheduledTask(taskId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["scheduled-tasks"] });
      void queryClient.invalidateQueries({
        queryKey: ["scheduled-tasks", "thread"],
      });
    },
    onError: (error: Error) => {
      toast.error(`${t.scheduledTasks.errors.resume}: ${error.message}`);
    },
  });
}

// 触发 mutation：额外失效 runs 查询，让运行历史立刻刷新
export function useTriggerScheduledTask() {
  const queryClient = useQueryClient();
  const { t } = useI18n();
  return useMutation({
    mutationFn: (taskId: string) => triggerScheduledTask(taskId),
    onSuccess: (_result, taskId) => {
      void queryClient.invalidateQueries({ queryKey: ["scheduled-tasks"] });
      void queryClient.invalidateQueries({
        queryKey: ["scheduled-tasks", "thread"],
      });
      void queryClient.invalidateQueries({
        queryKey: ["scheduled-tasks", "runs", taskId],
      });
    },
    onError: (error: Error) => {
      toast.error(`${t.scheduledTasks.errors.trigger}: ${error.message}`);
    },
  });
}

export function useDeleteScheduledTask() {
  const queryClient = useQueryClient();
  const { t } = useI18n();
  return useMutation({
    mutationFn: (taskId: string) => deleteScheduledTask(taskId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["scheduled-tasks"] });
      void queryClient.invalidateQueries({
        queryKey: ["scheduled-tasks", "thread"],
      });
    },
    onError: (error: Error) => {
      toast.error(`${t.scheduledTasks.errors.delete}: ${error.message}`);
    },
  });
}
```

## §4 page.tsx（页面组件：表单 + 列表 + 详情 + 运行历史 + 删除确认）

```tsx
// frontend/src/app/workspace/scheduled-tasks/page.tsx
"use client";

import { useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import {
  ScheduledTaskScheduleInput,
  type ScheduleValue,
} from "@/components/workspace/scheduled-task-schedule-input";
import {
  WorkspaceBody,
  WorkspaceContainer,
  WorkspaceHeader,
} from "@/components/workspace/workspace-container";
import { useI18n } from "@/core/i18n/hooks";
import {
  useCreateScheduledTask,
  useUpdateScheduledTask,
  useDeleteScheduledTask,
  usePauseScheduledTask,
  useResumeScheduledTask,
  useScheduledTaskRuns,
  useScheduledTasks,
  useTriggerScheduledTask,
  useThreadScheduledTasks,
} from "@/core/scheduled-tasks/hooks";
import { RECIPES, type Recipe } from "@/core/scheduled-tasks/recipes";
import type {
  ScheduledTask,
  ScheduledTaskRun,
} from "@/core/scheduled-tasks/types";
import { cn } from "@/lib/utils";

const NONE = "-";

function formatTimestamp(value: string | null, locale: string): string {
  if (!value) {
    return NONE;
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  // locale 感知的短格式如 "2026-07-03 09:00"。未来时间（next_run_at）渲染为绝对时间，
  // 而非相对 "ago" 字符串。
  const intlLocale = locale === "zh-CN" ? "zh-CN" : "en-US";
  return new Intl.DateTimeFormat(intlLocale, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

export default function ScheduledTasksPage() {
  const { t, locale } = useI18n();
  const st = t.scheduledTasks;
  const searchParams = useSearchParams();
  const threadId = searchParams.get("thread_id");    // ?thread_id= 过滤：只看该 thread 的任务
  const allTasksQuery = useScheduledTasks();
  const threadTasksQuery = useThreadScheduledTasks(threadId);
  const data = threadId ? threadTasksQuery.data : allTasksQuery.data;
  const queryError = threadId ? threadTasksQuery.error : allTasksQuery.error;
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [contextMode, setContextMode] = useState<
    "fresh_thread_per_run" | "reuse_thread"
  >(threadId ? "reuse_thread" : "fresh_thread_per_run");
  const [targetThreadId, setTargetThreadId] = useState(threadId ?? "");
  const [title, setTitle] = useState("");
  const [prompt, setPrompt] = useState("");
  const [createSchedule, setCreateSchedule] = useState<ScheduleValue>({
    schedule_type: "cron",
    schedule_spec: { cron: "0 9 * * *" },
    timezone: "",
  });
  const [statusFilter, setStatusFilter] = useState<
    "all" | "enabled" | "paused" | "running" | "completed" | "failed"
  >("all");
  const [typeFilter, setTypeFilter] = useState<"all" | "once" | "cron">("all");
  const [formError, setFormError] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [editTitle, setEditTitle] = useState("");
  const [editPrompt, setEditPrompt] = useState("");
  const [editSchedule, setEditSchedule] = useState<ScheduleValue>({
    schedule_type: "cron",
    schedule_spec: { cron: "0 9 * * *" },
    timezone: "UTC",
  });
  const [createNonce, setCreateNonce] = useState(0);   // 提交/recipe 后重建 schedule 输入组件以重置内部状态
  const filteredData = (data ?? []).filter((task) => {
    const statusPass = statusFilter === "all" || task.status === statusFilter;
    const typePass = typeFilter === "all" || task.schedule_type === typeFilter;
    return statusPass && typePass;
  });
  const selectedTask =
    filteredData.find((task) => task.id === selectedTaskId) ?? filteredData[0];
  const taskRunsQuery = useScheduledTaskRuns(selectedTask?.id);
  const createTask = useCreateScheduledTask();
  const updateTask = useUpdateScheduledTask(selectedTask?.id ?? "");
  const pauseTask = usePauseScheduledTask();
  const resumeTask = useResumeScheduledTask();
  const triggerTask = useTriggerScheduledTask();
  const deleteTask = useDeleteScheduledTask();

  const scheduleTypeLabel = (v: string) =>
    v === "cron"
      ? st.scheduleType.cron
      : v === "once"
        ? st.scheduleType.once
        : v;
  const statusLabel = (v: string) =>
    (st.status as Record<string, string>)[v] ?? v;
  const contextModeLabel = (v: string) =>
    v === "fresh_thread_per_run"
      ? st.context.fresh
      : v === "reuse_thread"
        ? st.context.reuse
        : v;
  const runTriggerLabel = (v: string) =>
    (st.runTrigger as Record<string, string>)[v] ?? v;
  const runStatusLabel = (v: string) =>
    (st.runStatus as Record<string, string>)[v] ?? v;
  const taskSummary = (task: ScheduledTask) =>
    `${scheduleTypeLabel(task.schedule_type)} · ${statusLabel(task.status)}`;
  const runSummary = (run: ScheduledTaskRun) =>
    `${runTriggerLabel(run.trigger)} · ${runStatusLabel(run.status)}`;
  const applyRecipe = (recipe: Recipe) => {
    const labels = st.recipes[recipe.titleKey];
    setTitle(labels.title);
    setPrompt(recipe.prompt);
    setCreateSchedule(recipe.schedule);
    setContextMode("fresh_thread_per_run");
    setCreateNonce((n) => n + 1);
  };

  useEffect(() => {
    document.title = `${t.sidebar.scheduledTasks} - ${t.pages.appName}`;
  }, [t.pages.appName, t.sidebar.scheduledTasks]);

  // 选中的 task 被过滤掉后回退到首个
  useEffect(() => {
    if (!selectedTaskId) {
      return;
    }
    const stillVisible = filteredData.some(
      (task) => task.id === selectedTaskId,
    );
    if (!stillVisible) {
      setSelectedTaskId(filteredData[0]?.id ?? null);
      setEditing(false);
    }
  }, [filteredData, selectedTaskId]);

  // 选中 task 变化时同步编辑表单（仅依赖 id，防后台 refetch 同 task 新对象引用 wipe 进行中编辑）
  useEffect(() => {
    if (!selectedTask) {
      setEditing(false);
      return;
    }
    setEditTitle(selectedTask.title);
    setEditPrompt(selectedTask.prompt);
    const spec = selectedTask.schedule_spec as {
      cron?: string;
      run_at?: string;
    };
    setEditSchedule({
      schedule_type: selectedTask.schedule_type,
      schedule_spec: {
        cron: typeof spec.cron === "string" ? spec.cron : undefined,
        run_at: typeof spec.run_at === "string" ? spec.run_at : undefined,
      },
      timezone: selectedTask.timezone || "UTC",
    });
    // 仅依赖 id，防后台 refetch（同 task、新对象引用）wipe 进行中编辑。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedTask?.id]);

  return (
    <WorkspaceContainer>
      <WorkspaceHeader />
      <WorkspaceBody>
        <div className="mx-auto flex w-full max-w-(--container-width-md) flex-col gap-4 p-6">
          <h1 className="text-2xl font-semibold">{t.sidebar.scheduledTasks}</h1>
          {/* 创建表单 */}
          <div
            className="grid gap-2 rounded-lg border p-4"
            data-testid="scheduled-task-create-form"
          >
            <div className="font-medium">{st.create.title}</div>
            {/* Recipe 快捷填充 */}
            <div
              className="flex flex-wrap items-center gap-1"
              data-testid="schedule-recipes"
            >
              <span className="text-muted-foreground text-sm">
                {st.recipes.label}:
              </span>
              {RECIPES.map((recipe) => (
                <Button
                  key={recipe.id}
                  variant="outline"
                  size="sm"
                  onClick={() => applyRecipe(recipe)}
                >
                  <span aria-hidden>{recipe.icon}</span>
                  {st.recipes[recipe.titleKey].title}
                </Button>
              ))}
            </div>
            {/* context_mode 切换：fresh_thread_per_run / reuse_thread */}
            <div className="flex gap-2">
              <Button
                variant={
                  contextMode === "fresh_thread_per_run" ? "default" : "outline"
                }
                size="sm"
                onClick={() => setContextMode("fresh_thread_per_run")}
              >
                {st.context.fresh}
              </Button>
              <Button
                variant={contextMode === "reuse_thread" ? "default" : "outline"}
                size="sm"
                onClick={() => setContextMode("reuse_thread")}
              >
                {st.context.reuse}
              </Button>
            </div>
            {contextMode === "reuse_thread" && (
              <Input
                value={targetThreadId}
                onChange={(event) => setTargetThreadId(event.target.value)}
                placeholder={st.context.threadIdPlaceholder}
              />
            )}
            <Input
              value={title}
              onChange={(event) => setTitle(event.target.value)}
              placeholder={st.create.taskTitle}
            />
            <Textarea
              rows={4}
              value={prompt}
              onChange={(event) => setPrompt(event.target.value)}
              placeholder={st.create.prompt}
            />
            <ScheduledTaskScheduleInput
              key={createNonce}
              initial={createSchedule}
              onChange={setCreateSchedule}
            />
            {formError && (
              <div className="text-destructive text-sm">{formError}</div>
            )}
            <Button
              onClick={() => {
                // 提交前校验必填
                const hasSchedule =
                  Boolean(createSchedule.schedule_spec.cron) ||
                  Boolean(createSchedule.schedule_spec.run_at);
                if (
                  !title ||
                  !prompt ||
                  !hasSchedule ||
                  (contextMode === "reuse_thread" && !targetThreadId)
                ) {
                  setFormError(st.create.fillRequired);
                  return;
                }
                setFormError(null);
                createTask.mutate(
                  {
                    context_mode: contextMode,
                    thread_id:
                      contextMode === "reuse_thread" ? targetThreadId : null,
                    title,
                    prompt,
                    schedule_type: createSchedule.schedule_type,
                    schedule_spec: createSchedule.schedule_spec,
                    timezone: createSchedule.timezone || "UTC",
                  },
                  {
                    onSuccess: () => {
                      // 清表单让后续任务从空白开始
                      setTitle("");
                      setPrompt("");
                      setTargetThreadId("");
                      setContextMode("fresh_thread_per_run");
                      setCreateSchedule({
                        schedule_type: "cron",
                        schedule_spec: { cron: "0 9 * * *" },
                        timezone: "",
                      });
                      setCreateNonce((n) => n + 1);
                    },
                  },
                );
              }}
              disabled={
                !title ||
                !prompt ||
                (!createSchedule.schedule_spec.cron &&
                  !createSchedule.schedule_spec.run_at) ||
                (contextMode === "reuse_thread" && !targetThreadId) ||
                createTask.isPending
              }
            >
              {st.create.submit}
            </Button>
          </div>
          {threadId && (
            <div className="text-muted-foreground text-sm">
              {st.detail.filteredByThread.replace("{id}", threadId)}
            </div>
          )}
          {queryError ? (
            <div
              className="text-destructive text-sm"
              data-testid="scheduled-task-load-error"
            >
              {st.detail.loadFailed}: {queryError.message}
            </div>
          ) : null}
          {/* 状态/类型过滤栏 */}
          <div className="flex flex-wrap gap-2">
            <Button
              variant={statusFilter === "all" ? "default" : "outline"}
              size="sm"
              onClick={() => setStatusFilter("all")}
            >
              {st.filters.allStatuses}
            </Button>
            <Button
              variant={statusFilter === "enabled" ? "default" : "outline"}
              size="sm"
              onClick={() => setStatusFilter("enabled")}
            >
              {st.filters.enabled}
            </Button>
            <Button
              variant={statusFilter === "paused" ? "default" : "outline"}
              size="sm"
              onClick={() => setStatusFilter("paused")}
            >
              {st.filters.paused}
            </Button>
            <Button
              variant={statusFilter === "completed" ? "default" : "outline"}
              size="sm"
              onClick={() => setStatusFilter("completed")}
            >
              {st.filters.completed}
            </Button>
            <Button
              variant={statusFilter === "failed" ? "default" : "outline"}
              size="sm"
              onClick={() => setStatusFilter("failed")}
            >
              {st.filters.failed}
            </Button>
            <Button
              variant={typeFilter === "all" ? "default" : "outline"}
              size="sm"
              onClick={() => setTypeFilter("all")}
            >
              {st.filters.allTypes}
            </Button>
            <Button
              variant={typeFilter === "cron" ? "default" : "outline"}
              size="sm"
              onClick={() => setTypeFilter("cron")}
            >
              {st.filters.cron}
            </Button>
            <Button
              variant={typeFilter === "once" ? "default" : "outline"}
              size="sm"
              onClick={() => setTypeFilter("once")}
            >
              {st.filters.once}
            </Button>
          </div>
          {/* 列表 + 详情双栏 */}
          <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_320px]">
            <div
              data-testid="scheduled-task-list"
              className="flex flex-col gap-3"
            >
              {filteredData.map((task) => {
                const isSelected = selectedTask?.id === task.id;
                return (
                  <button
                    type="button"
                    key={task.id}
                    onClick={() => setSelectedTaskId(task.id)}
                    data-testid={`scheduled-task-item-${task.id}`}
                    className={cn(
                      "rounded-lg border p-4 text-left",
                      isSelected ? "border-foreground" : "border-border",
                    )}
                  >
                    <div className="font-medium">{task.title}</div>
                    <div className="text-muted-foreground text-sm">
                      {taskSummary(task)}
                    </div>
                  </button>
                );
              })}
            </div>
            <div
              className="rounded-lg border p-4"
              data-testid="scheduled-task-detail"
            >
              {selectedTask ? (
                <div className="flex flex-col gap-3">
                  <div className="flex items-start justify-between gap-3">
                    <div className="text-lg font-semibold">
                      {selectedTask.title}
                    </div>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => setEditing((value) => !value)}
                    >
                      {editing ? st.actions.cancelEdit : st.actions.edit}
                    </Button>
                  </div>
                  <div className="text-muted-foreground text-sm">
                    {st.detail.contextMode}:{" "}
                    {contextModeLabel(selectedTask.context_mode)}
                  </div>
                  <div className="text-muted-foreground text-sm">
                    {selectedTask.context_mode === "reuse_thread"
                      ? `${st.detail.thread}: ${selectedTask.thread_id ?? NONE}`
                      : `${st.detail.lastThread}: ${selectedTask.last_thread_id ?? NONE}`}
                  </div>
                  <div className="text-muted-foreground text-sm">
                    {st.detail.schedule}:{" "}
                    {scheduleTypeLabel(selectedTask.schedule_type)}
                  </div>
                  <div className="text-muted-foreground text-sm">
                    {st.detail.nextRun}:{" "}
                    {formatTimestamp(selectedTask.next_run_at, locale)}
                  </div>
                  <div className="text-muted-foreground text-sm">
                    {st.detail.lastRun}:{" "}
                    {formatTimestamp(selectedTask.last_run_at, locale)}
                  </div>
                  <div className="text-muted-foreground text-sm">
                    {st.detail.lastRunId}: {selectedTask.last_run_id ?? NONE}
                  </div>
                  <div className="text-muted-foreground text-sm">
                    {st.detail.lastError}: {selectedTask.last_error ?? NONE}
                  </div>
                  {/* 编辑表单（schedule_type 锁定，不可改） */}
                  {editing ? (
                    <div className="flex flex-col gap-2 rounded-lg border p-3">
                      <Input
                        value={editTitle}
                        onChange={(event) => setEditTitle(event.target.value)}
                        placeholder={st.edit.titlePlaceholder}
                      />
                      <Textarea
                        rows={4}
                        value={editPrompt}
                        onChange={(event) => setEditPrompt(event.target.value)}
                        placeholder={st.edit.promptPlaceholder}
                      />
                      <ScheduledTaskScheduleInput
                        key={selectedTask.id}
                        initial={editSchedule}
                        onChange={setEditSchedule}
                        scheduleTypeLocked
                      />
                      <Button
                        size="sm"
                        onClick={() =>
                          updateTask.mutate({
                            title: editTitle,
                            prompt: editPrompt,
                            schedule_spec: editSchedule.schedule_spec,
                            timezone: editSchedule.timezone || "UTC",
                          })
                        }
                        disabled={updateTask.isPending}
                      >
                        {st.edit.submit}
                      </Button>
                    </div>
                  ) : (
                    <div className="text-sm">{selectedTask.prompt}</div>
                  )}
                  {/* 动作栏：暂停/恢复 + 手动触发 + 删除 */}
                  <div className="flex flex-wrap gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() =>
                        selectedTask.status === "paused"
                          ? resumeTask.mutate(selectedTask.id)
                          : pauseTask.mutate(selectedTask.id)
                      }
                    >
                      {selectedTask.status === "paused"
                        ? st.actions.resume
                        : st.actions.pause}
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => triggerTask.mutate(selectedTask.id)}
                    >
                      {st.actions.trigger}
                    </Button>
                    <Button
                      variant="destructive"
                      size="sm"
                      onClick={() => setDeleteOpen(true)}
                    >
                      {st.actions.delete}
                    </Button>
                  </div>
                  {/* 运行历史 */}
                  <div data-testid="scheduled-task-runs">
                    {(taskRunsQuery.data ?? []).length === 1
                      ? st.detail.runsCountOne.replace(
                          "{count}",
                          String((taskRunsQuery.data ?? []).length),
                        )
                      : st.detail.runsCount.replace(
                          "{count}",
                          String((taskRunsQuery.data ?? []).length),
                        )}
                  </div>
                  <div
                    className="flex flex-col gap-2"
                    data-testid="scheduled-task-run-list"
                  >
                    {(taskRunsQuery.data ?? []).length > 0 ? (
                      (taskRunsQuery.data ?? []).map((run) => (
                        <div
                          key={run.id}
                          className="rounded-md border p-3 text-sm"
                        >
                          <div className="font-medium">{runSummary(run)}</div>
                          <div className="text-muted-foreground text-xs">
                            {run.run_id ?? NONE}
                          </div>
                          <div className="text-muted-foreground text-xs">
                            {formatTimestamp(run.scheduled_for, locale)}
                          </div>
                          {run.error && (
                            <div className="text-destructive text-xs">
                              {run.error}
                            </div>
                          )}
                        </div>
                      ))
                    ) : (
                      <div className="text-muted-foreground text-sm">
                        {st.detail.noRuns}
                      </div>
                    )}
                  </div>
                </div>
              ) : (
                <div className="text-muted-foreground text-sm">
                  {st.detail.noSelection}
                </div>
              )}
            </div>
          </div>
        </div>
      </WorkspaceBody>

      {/* 删除确认 Dialog（沿用 agent-card 的确认模式） */}
      <Dialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{st.actions.delete}</DialogTitle>
            <DialogDescription>{st.deleteConfirm}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setDeleteOpen(false)}
              disabled={deleteTask.isPending}
            >
              {t.common.cancel}
            </Button>
            <Button
              variant="destructive"
              onClick={() => {
                if (selectedTask) {
                  deleteTask.mutate(selectedTask.id, {
                    onSuccess: () => setDeleteOpen(false),
                  });
                }
              }}
              disabled={deleteTask.isPending}
            >
              {deleteTask.isPending ? t.common.loading : st.actions.delete}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </WorkspaceContainer>
  );
}
```
