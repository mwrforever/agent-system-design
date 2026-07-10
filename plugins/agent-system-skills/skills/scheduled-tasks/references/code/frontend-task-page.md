# 完整源码：前端任务页（类型契约 + REST 客户端 + React Query hooks + cron 纯函数 + 页面）

> 本文件给出调度任务前端管理的**完整实现**：`types.ts`（类型契约）+ `api.ts`（REST 客户端）+ `hooks.ts`（React Query hooks）+ `cron.ts`（cron 预设/解析/描述纯函数）+ `page.tsx`（任务管理页结构）。
>
> 前端是 `schedules.py` 纯计算（见 [schedules-calc.md](./schedules-calc.md)）的第三个复用点：`cron.ts` 提供本地 `describeSchedule` 预演展示，不依赖后端往返。类型契约 `ScheduledTask`/`ScheduledTaskRun` 与后端 DB 行/REST 响应一一对应。
>
> 真实实现已按匿名化规则映射到中立结构（前端 `frontend/src/...`），去除一切项目字样。原代码注释保留以保真；关键处补中文注解。

---

## 1. 类型契约：types.ts

```typescript
// frontend/src/core/scheduled-tasks/types.ts
// 调度任务 + 调度任务运行记录的类型契约，与后端 DB 行/REST 响应一一对应。

export type ScheduledTask = {
  id: string;
  thread_id: string | null;
  context_mode: "fresh_thread_per_run" | "reuse_thread";
  title: string;
  prompt: string;
  schedule_type: "once" | "cron";
  schedule_spec: Record<string, unknown>;
  timezone: string;
  status: "enabled" | "paused" | "running" | "completed" | "failed" | "cancelled";
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
  status: "queued" | "running" | "success" | "failed" | "skipped" | "interrupted";
  error: string | null;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
};
```

---

## 2. REST 客户端：api.ts

```typescript
// frontend/src/core/scheduled-tasks/api.ts
// REST 客户端：fetch/create/update/pause/resume/trigger/delete + runs + thread 维度 list。

function scheduledTasksUrl(path: string): string {
  return `${getBackendBaseURL()}/api/scheduled-tasks${path}`;
}

export async function fetchScheduledTasks(): Promise<ScheduledTask[]> {
  const response = await fetch(scheduledTasksUrl(""));
  if (!response.ok) {
    await throwGatewayApiError(response, `Failed to load scheduled tasks: ${response.statusText}`);
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

export async function createScheduledTask(payload: ScheduledTaskPayload): Promise<ScheduledTask> {
  const response = await fetch(scheduledTasksUrl(""), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    await throwGatewayApiError(response, `Failed to create scheduled task: ${response.statusText}`);
  }
  return response.json();
}

export async function triggerScheduledTask(
  taskId: string,
): Promise<{ id: string; triggered: boolean }> {
  const response = await fetch(scheduledTasksUrl(`/${encodeURIComponent(taskId)}/trigger`), { method: "POST" });
  if (!response.ok) {
    await throwGatewayApiError(response, `Failed to trigger scheduled task: ${response.statusText}`);
  }
  return response.json();
}

// updateScheduledTask / pauseScheduledTask / resumeScheduledTask /
// deleteScheduledTask / fetchScheduledTaskRuns / fetchThreadScheduledTasks 同构
```

> `throwGatewayApiError` 是网关 REST 错误统一处理：解析响应体里的 error detail，抛出带状态码与业务文案的异常，供 hooks 的 `onError` 展示 toast。其余端点（update/pause/resume/delete/runs/thread-list）结构与上述 `fetchScheduledTasks`/`createScheduledTask` 同构：拼 URL -> fetch -> `response.ok` 检查 -> 失败抛 `throwGatewayApiError` -> 成功返回 `response.json()`。

---

## 3. React Query hooks：hooks.ts

```typescript
// frontend/src/core/scheduled-tasks/hooks.ts
// React Query hooks：useScheduledTasks（列表 15s 轮询）+ useTriggerScheduledTask 等。

export function useScheduledTasks() {
  return useQuery({
    queryKey: ["scheduled-tasks"],
    queryFn: fetchScheduledTasks,
    refetchInterval: 15000,              // 15s 轮询：任务状态/next_run_at 会变
    refetchIntervalInBackground: false,
  });
}

export function useTriggerScheduledTask() {
  const queryClient = useQueryClient();
  const { t } = useI18n();
  return useMutation({
    mutationFn: (taskId: string) => triggerScheduledTask(taskId),
    onSuccess: (_result, taskId) => {
      // 触发后失效任务列表 + 该任务运行历史，让它们重新拉取
      void queryClient.invalidateQueries({ queryKey: ["scheduled-tasks"] });
      void queryClient.invalidateQueries({ queryKey: ["scheduled-tasks", "runs", taskId] });
    },
    onError: (error: Error) => {
      toast.error(`${t.scheduledTasks.errors.trigger}: ${error.message}`);
    },
  });
}
```

> `useScheduledTasks` 的 `refetchInterval: 15000` 是前端轮询：任务状态（enabled/paused/running/completed/failed）、`next_run_at`、`last_run_at` 都会随调度推进变化，15s 轮询让列表保持新鲜。`refetchIntervalInBackground: false` 避免标签页不可见时空轮询。`useTriggerScheduledTask` 触发成功后失效列表 + 运行历史两个 queryKey，让它们重新拉取。其余 hooks（`useCreateScheduledTask`/`useUpdateScheduledTask`/`usePauseScheduledTask`/`useResumeScheduledTask`/`useDeleteScheduledTask`/`useScheduledTaskRuns`）同构：`useMutation` + `onSuccess` 失效相关 queryKey + `onError` toast。

---

## 4. cron 纯函数：cron.ts

`frontend/src/core/scheduled-tasks/cron.ts` 提供前端 cron 预设序列化/解析/时区转换纯函数，与后端 `schedules.py` 的纯计算对应：

- **`serializeCron`**：把前端表单的 cron 预设（如"每天 9:00"、"每周一 10:00"）序列化为 5 字段 cron 表达式字符串。
- **`parseCron`**：把 5 字段 cron 表达式解析回结构化预设（供编辑表单回填）。
- **`zonedLocalToUtcIso`**：把用户在任务时区选择的本地墙上时间转成 UTC ISO 8601 字符串（once 任务的 `run_at`）。
- **`describeSchedule`**：本地预演描述调度（"每天 09:00 (Asia/Shanghai)"），不依赖后端往返，用于列表/详情展示。

这些纯函数与后端 `schedules.py` 的 `next_run_at`/`normalize_cron_expression`/`validate_timezone` 对应：前端用同一套时区/cron 规则做本地预演，避免每次展示都往返后端。但**调度决策（认领/触发）仍由后端 poller 独占**--前端 `cron.ts` 仅展示用，不参与调度决策。

---

## 5. 任务管理页：page.tsx

`frontend/src/app/workspace/scheduled-tasks/page.tsx` 是上述 hooks 的消费侧，组织为四区：

1. **创建表单**：title/prompt/schedule 输入 + recipe 预设（常用 cron 模板快捷填充）+ context_mode 切换（fresh_thread_per_run / reuse_thread，后者需选 thread）+ timezone 选择。提交调 `useCreateScheduledTask`。
2. **列表**：按 status（enabled/paused/running/completed/failed/cancelled）/type（once/cron）过滤，展示 title/schedule/next_run_at/status/last_run_at。`useScheduledTasks` 15s 轮询保持新鲜。
3. **详情**：编辑（patch 改规格重算 next_run_at）/ 暂停（pause）/ 恢复（resume）/ 触发（trigger -> 409 toast 提示在途）/ 删除（delete）。`_ensure_task_mutable` 在后端拒绝对 running 任务的改动，前端据 409 提示。
4. **运行历史**：`useScheduledTaskRuns(taskId)` 15s 轮询，展示该任务的 `task_run` 行列表（trigger/status/error/started_at/finished_at），按 `created_at` 倒序。

> 关联：REST 路由四件套见 [rest-router.md](./rest-router.md)；cron 纯计算后端对应见 [schedules-calc.md](./schedules-calc.md)；前端设计系统见 [[frontend-app-design]]。
