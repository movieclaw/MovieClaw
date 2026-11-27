/**
 * 一条 Job **此刻属于哪一档**：要你处理 / 进行中 / 已结束。
 *
 * 从 `task-activity` 里单拎出来，是因为这三个判定必须只有一份实现——侧栏角标、
 * 活动页一级切换器、任务视角内部的状态选项卡都读它，各算各的就会出现同一屏上
 * 侧栏 3、进行中 2 的自相矛盾（那正是 task-activity 存在的理由）。这里不碰
 * React、不发请求，因此可以直接单测。
 */

import type { JobStatus, JobView } from "@/lib/api/jobs";

/** 需要用户判断的 Job 状态；与任务视角「需要处理」同口径。 */
export const ATTENTION_JOB_STATUSES = new Set<JobStatus>(["blocked", "failed"]);
export const ACTIVE_FEED_JOB_STATUSES = new Set<JobStatus>([
  "queued",
  "running",
  "retry_wait",
  "cancelling",
  "waiting",
]);
export const HISTORY_JOB_STATUSES = new Set<JobStatus>(["succeeded", "cancelled"]);

/** 失败任务是否已被用户忽略：判定口径只此一处，计数与渲染都读它。 */
export function isDismissed(job: Pick<JobView, "dismissed_at">): boolean {
  return job.dismissed_at != null;
}

/**
 * 这条 Job 是不是**现在**要用户动手。
 *
 * 光看状态不够：`failed` 是终态，取消对它无效，于是它会永远赖在「需要处理」
 * 里，侧栏红角标永不熄灭——用户手上没有任何让它闭嘴的动作（issue #221）。
 * 「忽略」补上了这个出口：任务仍然是失败（日志、重试、事件时间线一概不动），
 * 但用户已经拍板不处理，就不该继续被算成待办。
 */
export function jobNeedsAttention(job: Pick<JobView, "status" | "dismissed_at">): boolean {
  return ATTENTION_JOB_STATUSES.has(job.status) && !isDismissed(job);
}

/** 已经了结的 Job：正常终态，加上被用户忽略的失败任务。 */
export function jobIsHistorical(job: Pick<JobView, "status" | "dismissed_at">): boolean {
  return HISTORY_JOB_STATUSES.has(job.status) || (job.status === "failed" && isDismissed(job));
}

/** 详情入口视为终态异常的状态集合（忽略后不再视为未完成问题）。 */
export const TERMINAL_ISSUE_JOB_STATUSES = new Set<JobStatus>([
  "blocked",
  "failed",
  "cancelled",
]);

function parseTimestamp(value: string | null | undefined): number {
  if (!value) return Number.NEGATIVE_INFINITY;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : Number.NEGATIVE_INFINITY;
}

/**
 * 选出某个资源当前的最新任务（用于详情页状态与按钮联动，见 #1337）。
 *
 * 跳过用户已忽略的失败任务，活跃运行态优先，同档按 `created_at` 倒序
 * （与服务端 `GET /jobs` 一致，避免历史库中因忽略刷新过 `updated_at` 的旧失败反超新任务）。
 */
export function selectLatestResourceJob<
  T extends Pick<
    JobView,
    "job_type" | "status" | "dismissed_at" | "created_at" | "updated_at" | "resources"
  >,
>(
  jobs: readonly T[],
  resourceType: string,
  resourceId: string | number,
  jobType?: string,
): T | null {
  const targetId = String(resourceId);
  let best: T | null = null;
  let bestActive = false;
  let bestCreated = Number.NEGATIVE_INFINITY;
  let bestUpdated = Number.NEGATIVE_INFINITY;
  for (const job of jobs) {
    if (isDismissed(job)) continue;
    if (jobType && job.job_type !== jobType) continue;
    if (
      !job.resources.some(
        (resource) =>
          resource.resource_type === resourceType && resource.resource_id === targetId,
      )
    ) {
      continue;
    }
    const active = ACTIVE_FEED_JOB_STATUSES.has(job.status);
    const created = parseTimestamp(job.created_at);
    const updated = parseTimestamp(job.updated_at);
    if (
      best === null ||
      (active && !bestActive) ||
      (active === bestActive &&
        (created > bestCreated || (created === bestCreated && updated > bestUpdated)))
    ) {
      best = job;
      bestActive = active;
      bestCreated = created;
      bestUpdated = updated;
    }
  }
  return best;
}

/** 详情页字幕生成按钮是否应显示「AI 未完成」红态：已忽略或已有成品时不再报未完成。 */
export function subtitleGenShowsTerminalIssue(
  job: Pick<JobView, "status" | "dismissed_at"> | null | undefined,
  generated: boolean,
): boolean {
  if (!job || generated || job.status === "succeeded" || isDismissed(job)) return false;
  return TERMINAL_ISSUE_JOB_STATUSES.has(job.status);
}

/** 点击详情页字幕生成按钮后的落点：运行中或需展示未完成态进状态弹窗，否则进预检。 */
export function subtitleGenOpenMode(
  job: Pick<JobView, "status" | "dismissed_at"> | null | undefined,
  generated: boolean,
): "status" | "preview" {
  if (job && ACTIVE_FEED_JOB_STATUSES.has(job.status)) return "status";
  if (subtitleGenShowsTerminalIssue(job, generated)) return "status";
  return "preview";
}

/**
 * 用户此刻能不能取消这条 Job。
 *
 * `blocked` 同样可取消：它仍占着去重键，忽略接口不对它开放，取消就是它唯一
 * 的直接出口。此前卡片漏了这一项，确实无法自动解决的 blocked 只能去 CLI 取消
 * （issue #1050）。`cancelling` 已在收尾，不再重复给入口。
 */
export function jobCancellable(job: Pick<JobView, "status">): boolean {
  if (job.status === "cancelling") return false;
  return job.status === "blocked" || ACTIVE_FEED_JOB_STATUSES.has(job.status);
}
