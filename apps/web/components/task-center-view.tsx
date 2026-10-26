"use client";

import { jobFeedIdentity, jobProgressAmount, jobOriginLabel, activeJobStatus, historicalJobTitle, historicalJobSummary, groupHistoricalJobs, downloadTaskNote, downloadLifecycleSteps, downloadStateMeta, ingestStateMeta, type LifecycleTone } from "@/lib/task-presentation";

import { useLocale, useTranslations } from "next-intl";
import type { AppMessageKey } from "@/lib/i18n/translate";

import { useEffect, useMemo, useRef, useState } from "react";

import type { Route } from "next";
import Link from "next/link";

import {
  jobTypeLabel,
  JobCard,
  jobDetailItems,
  TaskActionsMenu,
  TaskStatusDot,
} from "@/components/job-center";
import {
  boostCleanupNote,
  SpeedStat,
  useBoostCleanup,
  useBoostPool,
} from "@/components/activity-boost";
import { BrandLoader } from "@/components/brand-loader";
import { useToast } from "@/components/feedback";
import { HandoffButton } from "@/components/handoff-button";
import {
  ArrowDownIcon,
  ChevronRightIcon,
  CheckIcon,
  ClockIcon,
  DownloadIcon,
  FilmIcon,
  GearIcon,
  InfoIcon,
  TvIcon,
  XIcon,
} from "@/components/icons";
import { Modal } from "@/components/modal";
import { OverflowText } from "@/components/overflow-text";
import { PosterImage } from "@/components/poster-image";
import {
  deleteDownloadTask,
  replaceDownloadTask,
  type DownloadTask,
  type DownloadTaskSource,
} from "@/lib/api/downloaders";
import { useDownloadTasks } from "@/lib/download-tasks";
import { formatBytes, formatDuration } from "@/lib/format";
import { imageUrl } from "@/lib/image-proxy";
import { summarizeEpisodeUnits } from "@/lib/episode-units";
import {
  buildIngestHistoryDetail,
  type IngestHistoryDetail,
} from "@/lib/ingest-history";
import { shouldOfferInlineReplacement } from "@/lib/download-task-actions";
import {
  cancelJob,
  dismissAllFailedJobs,
  isSystemCancelled,
  retryJob,
  undismissJob,
  type JobView,
} from "@/lib/api/jobs";
import { isDismissed, jobNeedsAttention } from "@/lib/job-attention";
import { useJobs } from "@/lib/jobs";
import type { TaskCenterViewName } from "@/lib/task-center";
import {
  downloadTaskNeedsAttention,
  useTaskActivity,
  type DownloadTaskGroup,
} from "@/lib/task-activity";
import {
  formatClockTime,
  formatRelativeTime,
} from "@/lib/time";

const VIEW_LABELS: { id: TaskCenterViewName; label: AppMessageKey }[] = [
  { id: "all", label: "activity.nav.all" },
  { id: "active", label: "activity.nav.active" },
  { id: "attention", label: "activity.nav.attention" },
  { id: "history", label: "activity.nav.history" },
];

/**
 * 任务卡片上的各种动作（删种、换种、取消、重试、忽略 / 撤销忽略）及其进行中状态。
 *
 * 任务视角（TaskCenterView）与银玻璃的活动总览（activity-overview.tsx 的「需要处理」
 * 分组）共用同一套：两处渲染的是同一批卡片，动作与回执不能各写一份。删除确认框随 hook
 * 一起返回（`deleteDialog`），调用方挂进自己的树里即可。
 */
export function useTaskCenterActions() {
  const t = useTranslations();

  const [deletingTaskId, setDeletingTaskId] = useState<string | null>(null);
  const [replacingTaskId, setReplacingTaskId] = useState<string | null>(null);
  const [cancellingJobId, setCancellingJobId] = useState<string | null>(null);
  const [retryingJobId, setRetryingJobId] = useState<string | null>(null);
  const [bulkDismissing, setBulkDismissing] = useState(false);
  const [undismissingJobId, setUndismissingJobId] = useState<string | null>(null);
  const [pendingDeleteTask, setPendingDeleteTask] = useState<DownloadTask | null>(null);
  const toast = useToast();
  const { upsert } = useJobs();
  const { refresh } = useDownloadTasks();

  async function removeDownloadTask(task: DownloadTask, deleteFiles: boolean) {
    if (task.downloader_id == null || deletingTaskId != null) return;

    setDeletingTaskId(task.id);
    try {
      const result = await deleteDownloadTask(task.downloader_id, task.info_hash, deleteFiles);
      toast.success(
        result.delete_files ? t("activity.taskCenter.removedFiles") : t("activity.taskCenter.removedKeepFiles"),
      );
      setPendingDeleteTask(null);
      refresh();
    } catch (caught) {
      toast.error((caught as Error).message || t("activity.taskCenter.removeFailed"));
    } finally {
      setDeletingTaskId(null);
    }
  }

  async function replaceStalledTask(task: DownloadTask) {
    if (task.downloader_id == null || replacingTaskId != null) return;
    setReplacingTaskId(task.id);
    try {
      await replaceDownloadTask(task.downloader_id, task.info_hash);
      toast.success(t("activity.taskCenter.replacementStarted"));
      refresh();
    } catch (caught) {
      toast.error((caught as Error).message || t("activity.taskCenter.replacementFailed"));
    } finally {
      setReplacingTaskId(null);
    }
  }

  async function cancelBackgroundJob(job: JobView) {
    if (cancellingJobId != null) return;
    setCancellingJobId(job.id);
    try {
      upsert(await cancelJob(job.id));
      toast.success(t("activity.taskCenter.cancelRequested"));
    } catch (caught) {
      toast.error((caught as Error).message || t("activity.taskCenter.cancelFailed"));
    } finally {
      setCancellingJobId(null);
    }
  }

  async function dismissAllFailed() {
    if (bulkDismissing) return;
    setBulkDismissing(true);
    try {
      const dismissed = await dismissAllFailedJobs();
      for (const job of dismissed) upsert(job);
      toast.success(
        dismissed.length > 0
          ? t("activity.taskCenter.dismissedCount", { count: dismissed.length })
          : t("activity.taskCenter.dismissNone"),
      );
    } catch (caught) {
      toast.error((caught as Error).message || t("activity.taskCenter.dismissAllFailed"));
    } finally {
      setBulkDismissing(false);
    }
  }

  async function restoreDismissedJob(job: JobView) {
    if (undismissingJobId != null) return;
    setUndismissingJobId(job.id);
    try {
      upsert(await undismissJob(job.id));
      toast.success(t("activity.taskCenter.restoredAttention"));
    } catch (caught) {
      toast.error((caught as Error).message || t("activity.taskCenter.restoreFailed"));
    } finally {
      setUndismissingJobId(null);
    }
  }

  async function retryHistoricalJob(job: JobView) {
    if (retryingJobId != null) return;
    setRetryingJobId(job.id);
    try {
      upsert(await retryJob(job.id));
      toast.success(t("activity.taskCenter.requeued"));
    } catch (caught) {
      toast.error((caught as Error).message || t("activity.taskCenter.retryFailed"));
    } finally {
      setRetryingJobId(null);
    }
  }

  const deleteDialog = pendingDeleteTask && (
    <DeleteDownloadTaskDialog
      task={pendingDeleteTask}
      busy={deletingTaskId === pendingDeleteTask.id}
      onClose={() => {
        if (deletingTaskId == null) setPendingDeleteTask(null);
      }}
      onConfirm={(deleteFiles) => void removeDownloadTask(pendingDeleteTask, deleteFiles)}
    />
  );

  return {
    deletingTaskId,
    replacingTaskId,
    cancellingJobId,
    retryingJobId,
    bulkDismissing,
    undismissingJobId,
    /** 删种先弹确认（是否连数据一起删），确认框见 deleteDialog */
    requestDelete: setPendingDeleteTask,
    replaceStalledTask: (task: DownloadTask) => void replaceStalledTask(task),
    cancelBackgroundJob: (job: JobView) => void cancelBackgroundJob(job),
    dismissAllFailed: () => void dismissAllFailed(),
    restoreDismissedJob: (job: JobView) => void restoreDismissedJob(job),
    retryHistoricalJob: (job: JobView) => void retryHistoricalJob(job),
    deleteDialog,
  };
}

export type TaskCenterActions = ReturnType<typeof useTaskCenterActions>;

/**
 * 「需要处理」的完整卡片（下载组卡片 + 作业卡片）：每种故障的补救动作不同（换种、重试、
 * 交给 AI、删除、忽略），压成一行反而要多点一层，所以任务视角与活动总览都用完整卡片。
 */
export function TaskAttentionCards({ actions }: { actions: TaskCenterActions }) {
  const { ingestJobsByHash, attentionDownloadGroups, standaloneAttentionJobs } = useTaskActivity();
  return (
    <>
      {attentionDownloadGroups.map((group) => (
        <DownloadTaskGroupCard
          key={group.key}
          group={group}
          ingestJobsByHash={ingestJobsByHash}
          deletingTaskId={actions.deletingTaskId}
          replacingTaskId={actions.replacingTaskId}
          onDelete={actions.requestDelete}
          onReplace={actions.replaceStalledTask}
        />
      ))}
      {standaloneAttentionJobs.map((job) => (
        <JobCard key={job.id} job={job} onNavigate={() => undefined} />
      ))}
    </>
  );
}

/**
 * 任务视角：统一“观察入口”，不制造统一状态表。
 * Job 状态来自 MovieClaw 数据库，下载状态来自下载器实时快照，订阅关系仅按
 * infohash 投影视图；各自的取消、重试和入库生命周期仍由原领域负责。
 *
 * 页头与一级视角切换由 ActivityView 承担，本组件只渲染状态 tab 与任务内容。
 *
 * `subPage`：银玻璃活动总览的二级页（进行中 / 已结束）。页名已在顶栏（桌面是页内标题行），状态 tab 不再出现；
 * 刷流有自己的二级页（activity-boost.tsx），这里不再摆刷流分组。
 */
export function TaskCenterView({
  view,
  onViewChange,
  subPage = false,
}: {
  view: TaskCenterViewName;
  onViewChange?: (view: TaskCenterViewName) => void;
  subPage?: boolean;
}) {
  const t = useTranslations();
  const locale = useLocale();

  // 选项卡在窄屏横向滚动：深链直达靠后的视图（如媒体库）时，激活项可能整个
  // 落在可视区之外，用户会以为该视图不存在。挂载与切换时把它滚进来。
  const activeTabRef = useRef<HTMLButtonElement | null>(null);
  useEffect(() => {
    activeTabRef.current?.scrollIntoView({ block: "nearest", inline: "center" });
  }, [view]);
  const actions = useTaskCenterActions();
  const {
    sources,
    loading,
    error,
    refreshedAt,
    refresh,
  } = useDownloadTasks();

  // 页面按“是否需要用户行动”组织，而不是按底层执行器分类。归类与计数由
  // useTaskActivity 统一承担——侧栏角标、一级切换器和这里的状态选项卡必须
  // 用同一份口径，否则同一屏上会出现互相矛盾的数字（见 lib/task-activity）。
  // 每个分区内部仍沿用 Provider 的更新时间倒序，保留最重要的任务在前。
  const {
    ingestJobsByHash,
    activeDownloadGroups,
    boostTasks,
    standaloneAttentionJobs,
    standaloneActiveJobs,
    standaloneHistoricalJobs,
    attentionTotal,
    activeTotal,
  } = useTaskActivity();
  const showAttention = view === "all" || view === "attention";
  const showActive = view === "all" || view === "active";
  const showBoost = showActive && !subPage && boostTasks.length > 0;
  const showHistory = view === "all" || view === "history";
  const hasContentBeforeHistory =
    (showAttention && attentionTotal > 0) || (showActive && activeTotal > 0);
  const visibleCount =
    (showAttention ? attentionTotal : 0) +
    (showActive ? activeTotal : 0) +
    (showBoost ? 1 : 0) +
    (showHistory ? standaloneHistoricalJobs.length : 0);
  const failedSources = sources.filter((source) => source.status !== "active");
  const viewCounts: Partial<Record<TaskCenterViewName, number>> = {
    attention: attentionTotal,
    active: activeTotal,
    history: standaloneHistoricalJobs.length,
  };

  return (
    <>
        {/* 一切正常时的"自动更新正常 / 下载器 N/N 可用"是纯噪音，占掉首屏一整条；
            出问题时下面的 SourceWarning 会指名道姓说清哪个下载器怎么了并给出设置入口，
            比一句"0/1 可用"信息量更大，所以这条状态条整体去掉，只保留告警 */}
        {(failedSources.length > 0 || error) && (
          <SourceWarning sources={failedSources} error={error} />
        )}

        {!subPage && (
          <div className="mt-6 flex items-center gap-3 border-b border-white/[0.08] max-md:mt-5">
            <div className="scroll-thin flex min-w-0 flex-1 gap-1 overflow-x-auto pb-2">
              {VIEW_LABELS.map((item) => (
                <button
                  key={item.id}
                  type="button"
                  ref={view === item.id ? activeTabRef : undefined}
                  aria-pressed={view === item.id}
                  onClick={() => onViewChange?.(item.id)}
                  className={`shrink-0 rounded-full px-3.5 py-1.5 text-ui font-medium transition ${
                    view === item.id
                      ? "bg-white/[0.14] text-white"
                      : "text-[var(--text-muted)] hover:bg-white/[0.06] hover:text-white"
                  }`}
                >
                  {t(item.label)}
                  {item.id !== "all" && (viewCounts[item.id] ?? 0) > 0 && (
                    <span className="tnum ml-1.5 text-caption text-white/45">
                      {viewCounts[item.id]}
                    </span>
                  )}
                </button>
              ))}
            </div>
            <p className="shrink-0 pb-2 text-caption text-[var(--text-faint)] max-md:hidden">
              {refreshedAt
                ? t("activity.taskCenter.updatedWhen", { when: formatRelativeTime(new Date(refreshedAt).toISOString(), locale) })
                : loading
                  ? t("activity.taskCenter.readingDownloaders")
                  : t("activity.taskCenter.waitRefresh")}
            </p>
          </div>
        )}

        {showAttention && attentionTotal > 0 && (
          <TaskAttentionSection
            count={attentionTotal}
            canDismissAll={standaloneAttentionJobs.some((job) => job.status === "failed")}
            dismissingAll={actions.bulkDismissing}
            onDismissAll={actions.dismissAllFailed}
          >
            <TaskAttentionCards actions={actions} />
          </TaskAttentionSection>
        )}

        {showActive && activeTotal > 0 && (
          <TaskTimelineSection title={t("activity.taskCenter.now")} count={activeTotal} className={subPage ? "mt-4" : "mt-7"}>
            {activeDownloadGroups.map((group) => (
              <TaskTimelineItem
                key={group.key}
                tone={downloadGroupTimelineTone(group, ingestJobsByHash)}
              >
                <DownloadTaskGroupFeed
                  group={group}
                  ingestJobsByHash={ingestJobsByHash}
                  deletingTaskId={actions.deletingTaskId}
                  replacingTaskId={actions.replacingTaskId}
                  onDelete={actions.requestDelete}
                  onReplace={actions.replaceStalledTask}
                />
              </TaskTimelineItem>
            ))}
            {standaloneActiveJobs.map((job) => (
              <TaskTimelineItem
                key={job.id}
                tone={jobTimelineTone(job)}
              >
                <ActiveJobFeedItem
                  job={job}
                  cancelling={actions.cancellingJobId === job.id}
                  onCancel={() => actions.cancelBackgroundJob(job)}
                />
              </TaskTimelineItem>
            ))}
          </TaskTimelineSection>
        )}

        {/* 刷流做种分组：默认折叠，头部常显实时汇总（速度 / 已上传 / 已下载）。
            这些种子没有入库流转语义，不进时间线，也不参与关注判定 */}
        {showBoost && (
          <BoostTaskSection tasks={boostTasks} onChanged={refresh} />
        )}

        {showHistory && standaloneHistoricalJobs.length > 0 && (
          <TaskHistorySection
            jobs={standaloneHistoricalJobs}
            initiallyOpen={view === "history"}
            separated={hasContentBeforeHistory}
            retryingJobId={actions.retryingJobId}
            onRetry={actions.retryHistoricalJob}
            undismissingJobId={actions.undismissingJobId}
            onUndismiss={actions.restoreDismissedJob}
          />
        )}

        {visibleCount === 0 && !loading && <EmptyView view={view} />}

        {loading && visibleCount === 0 && (
          <div className="flex items-center justify-center gap-2.5 py-20 text-ui text-[var(--text-muted)]">
            <BrandLoader className="size-5" />
            {t("activity.taskCenter.loading")}</div>
        )}

      {actions.deleteDialog}
    </>
  );
}

/** 删除任务的二次确认：安全默认只移除任务，是否删除数据文件由用户显式选择。 */
function DeleteDownloadTaskDialog({
  task,
  busy,
  onClose,
  onConfirm,
}: {
  task: DownloadTask;
  busy: boolean;
  onClose: () => void;
  onConfirm: (deleteFiles: boolean) => void;
}) {
  const t = useTranslations();

  const [deleteFiles, setDeleteFiles] = useState(false);
  const downloaderName = task.downloader_name || t("activity.taskCenter.downloaderFallback", { id: String(task.downloader_id) });

  return (
    <Modal open onClose={busy ? () => {} : onClose} label={t("activity.taskCenter.deleteDialog")} topmost>
      <div className="p-6 max-md:p-5">
        <h2 className="text-title-sm font-bold text-white">{t("activity.taskCenter.deleteTitle")}</h2>
        <p className="mt-2 text-sub leading-6 text-[var(--text-muted)]">
          {t("activity.taskCenter.deleteHint", { name: downloaderName })}
        </p>
        <p className="mt-3 break-words rounded-xl border border-white/[0.08] bg-white/[0.035] px-3.5 py-3 text-sub leading-6 text-white/75">
          {task.name || task.info_hash}
        </p>
        <label
          className={`mt-4 flex cursor-pointer items-start gap-3 rounded-xl border px-3.5 py-3 transition ${
            deleteFiles
              ? "border-[#ff6b6b]/35 bg-[#ff6b6b]/[0.08]"
              : "border-white/[0.08] bg-white/[0.025] hover:bg-white/[0.045]"
          }`}
        >
          <input
            type="checkbox"
            checked={deleteFiles}
            onChange={(event) => setDeleteFiles(event.target.checked)}
            className="mt-1 size-4 shrink-0 accent-[#ff6b6b]"
          />
          <span className="min-w-0">
            <span className="block text-ui font-semibold text-white/90">{t("activity.taskCenter.deleteFiles")}</span>
            <span className="mt-0.5 block text-caption leading-5 text-white/50">
              {t("activity.taskCenter.deleteFilesHint")}</span>
          </span>
        </label>
        {task.source === "subscription" && (
          <p className="mt-3 text-caption leading-5 text-amber-100/65">
            {t("activity.taskCenter.keepSubscriptionHint")}</p>
        )}
        <div className="mt-5 flex justify-end gap-2.5">
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="rounded-lg border border-white/10 bg-white/[0.06] px-4 py-2 text-ui text-white/80 transition hover:bg-white/[0.1] disabled:opacity-40"
          >
            {t("common.cancel")}</button>
          <button
            type="button"
            onClick={() => onConfirm(deleteFiles)}
            disabled={busy}
            className="rounded-lg bg-red-500/85 px-4 py-2 text-ui font-medium text-white transition hover:bg-red-500 disabled:opacity-40"
          >
            {busy ? t("activity.taskCenter.deleting") : deleteFiles ? t("activity.taskCenter.deleteWithFiles") : t("activity.taskCenter.deleteKeepFiles")}
          </button>
        </div>
      </div>
    </Modal>
  );
}

export function SourceWarning({ sources, error }: { sources: DownloadTaskSource[]; error: string | null }) {
  const t = useTranslations();
  const locale = useLocale();

  const message = error
    ? error
    : sources
        .map((source) => t("activity.taskCenter.sourceWarning", { name: source.name, hasMessage: source.message ? "yes" : "no", message: source.message ?? "" }))
        .join(locale === "zh-Hans" ? "；" : "; ");
  return (
    <div className="mt-4 flex items-start gap-3 rounded-xl border border-amber-400/25 bg-amber-500/10 px-4 py-3 text-sub leading-6 text-amber-100">
      <InfoIcon className="mt-0.5 size-4 shrink-0" />
      <p className="min-w-0 flex-1">{message}</p>
      <Link
        href={"/settings/downloaders" as Route}
        className="shrink-0 font-semibold text-amber-50 hover:underline"
      >
        {t("activity.taskCenter.checkSettings")}</Link>
    </div>
  );
}

/** 需要用户行动的任务脱离普通时间流置顶，避免失败记录被持续刷新的进度淹没。 */
function TaskAttentionSection({
  count,
  canDismissAll,
  dismissingAll,
  onDismissAll,
  children,
}: {
  count: number;
  /** 有没有"已经失败、还没被忽略"的任务；没有就不摆一个点了没反应的按钮。 */
  canDismissAll: boolean;
  dismissingAll: boolean;
  onDismissAll: () => void;
  children: React.ReactNode;
}) {
  const t = useTranslations();

  return (
    <section className="mt-6" aria-labelledby="attention-tasks-title">
      <div className="mb-3 flex items-center gap-2.5">
        <span className="size-2 rounded-full bg-[var(--danger)] ring-4 ring-[var(--danger)]/10" />
        <h2 id="attention-tasks-title" className="text-ui font-semibold text-[var(--danger)]">
          {t("activity.taskCenter.attentionTitle")}</h2>
        <span className="tnum rounded-full bg-[var(--danger)]/10 px-2 py-0.5 text-caption text-[var(--danger)]">
          {count}
        </span>
        {/* 故障常常成批：一次扫描收尾可能建出几十个字幕任务，配置错了就几十条
            一起失败，逐条点忽略是灾难。整体动作压成次要文字按钮，不跟每张卡
            自己的「重试」抢视觉。 */}
        {canDismissAll && (
          <button
            type="button"
            onClick={onDismissAll}
            disabled={dismissingAll}
            className="ml-auto shrink-0 rounded-lg px-2.5 py-1 text-caption font-medium text-white/40 transition hover:bg-white/[0.05] hover:text-white/70 disabled:cursor-wait disabled:opacity-40"
          >
            {dismissingAll ? t("activity.taskCenter.dismissing") : t("activity.taskCenter.dismissAll")}
          </button>
        )}
      </div>
      <div className="space-y-2.5 rounded-2xl border border-[var(--danger)]/20 bg-[var(--danger)]/[0.035] p-3.5 max-md:p-3">
        {children}
      </div>
    </section>
  );
}

/**
 * 统一时间线只负责排列视图，不合并领域状态。下载卡仍读取下载器快照，JobCard
 * 仍读取 Job；时间轴仅把它们放入同一条用户可扫描的阅读路径。
 */
function TaskTimelineSection({
  title,
  count,
  className = "mt-7",
  children,
}: {
  title: string;
  count: number;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <section className={className} aria-labelledby="active-tasks-title">
      <div className="mb-3 flex items-center gap-3">
        <h2 id="active-tasks-title" className="text-ui font-semibold text-white/65">
          {title}
        </h2>
        <span className="tnum text-caption text-white/30">{count}</span>
        <span aria-hidden="true" className="h-px min-w-8 flex-1 bg-white/[0.09]" />
      </div>
      <div>{children}</div>
    </section>
  );
}

/**
 * 时间轴条目。原本桌面端在最左预留一条 3.75rem 的时刻沟槽，结果整段内容被推离
 * 左边界近 100px，与分组标题、上方的筛选标签全部错开；"现在"区的下载过程更没有
 * 单一时刻，那一列直接是空白。
 *
 * 现在只保留圆点轨道：条目与分组标题左对齐，桌面与移动端缩进一致。需要显示时刻
 * 的条目（历史记录）自己把时间排进内容里，避免为一列时间牺牲整段的对齐。
 */
function TaskTimelineItem({
  tone = "active",
  children,
}: {
  /** partial：完成了但有没办成的部分（如刷新时几张图没下到），琥珀色对勾 */
  tone?: "active" | "waiting" | "success" | "partial" | "cancelled";
  children: React.ReactNode;
}) {
  const completed = tone === "success" || tone === "partial" || tone === "cancelled";
  const dotClass =
    tone === "waiting"
      ? "bg-[var(--warn)] ring-[var(--warn)]/25"
      : tone === "partial"
        ? "bg-[var(--warn)] text-[#1a1203] ring-[var(--warn)]/20"
        : tone === "success"
        ? "bg-[var(--ok)] text-[#07120b] ring-[var(--ok)]/20"
        : tone === "cancelled"
          ? "bg-white/20 text-white/60 ring-white/10"
          : "bg-[var(--info)] ring-[var(--info)]/30";
  return (
    <div className="grid grid-cols-[1.5rem_minmax(0,1fr)] gap-x-2 last:[&_[data-timeline-line]]:hidden max-md:grid-cols-[1.25rem_minmax(0,1fr)] max-md:gap-x-2.5">
      <span className="relative flex self-stretch justify-center" aria-hidden="true">
        <span
          className={`absolute top-[0.7rem] z-10 flex items-center justify-center rounded-full border-2 border-[#0b0f17] ring-2 ${
            completed ? "size-4" : "mt-0.5 size-2.5"
          } ${dotClass}`}
        >
          {(tone === "success" || tone === "partial") && <CheckIcon className="size-2.5" />}
          {tone === "cancelled" && <XIcon className="size-2.5" />}
        </span>
        <span
          data-timeline-line
          className="absolute bottom-0 top-[1.65rem] w-px bg-white/[0.12]"
        />
      </span>
      <div className="min-w-0 pb-4">{children}</div>
    </div>
  );
}

function jobTimelineTone(job: JobView): "active" | "waiting" {
  return job.status === "running" ? "active" : "waiting";
}

function ActiveJobFeedItem({
  job,
  cancelling,
  onCancel,
}: {
  job: JobView;
  cancelling: boolean;
  onCancel: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const percent = job.progress.percent;
  const amount = jobProgressAmount(job, locale);
  const cancellable = job.status !== "cancelling";
  const title = jobFeedIdentity(job, locale) || jobTypeLabel(job, locale);
  // 元数据刷新的图片记账（新下载 / 沿用 / 失败）；其余类型的过程信息已在摘要里
  const details = job.job_type.includes("metadata.refresh") ? jobDetailItems(job, locale) : [];
  return (
    <article className="min-w-0 py-1.5">
      <div className="flex min-w-0 items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <h3 className="text-ui font-semibold leading-5 text-white/90">
            <OverflowText>{title}</OverflowText>
          </h3>
          <p className="mt-1 flex flex-wrap items-center gap-x-1.5 text-sub text-white/60">
            <span className="font-medium text-white/70">{activeJobStatus(job, locale)}</span>
            {percent != null && (
              <>
                <span aria-hidden="true" className="text-white/25">·</span>
                <span className="tnum">{Math.round(percent)}%</span>
              </>
            )}
          </p>
        </div>
        {cancellable && (
          <button
            type="button"
            onClick={onCancel}
            disabled={cancelling}
            className="shrink-0 rounded-lg px-2.5 py-1.5 text-caption font-medium text-white/45 transition hover:bg-white/[0.06] hover:text-white/75 disabled:cursor-wait disabled:opacity-45"
          >
            {cancelling ? t("activity.jobs.cancellingAction") : t("activity.jobs.cancelAction")}
          </button>
        )}
      </div>
      {job.progress.message && (
        <OverflowText lines={2} className="mt-1.5 text-caption leading-5 text-white/42">
          {job.progress.message}
        </OverflowText>
      )}
      {details.length > 0 && (
        <div className="mt-1.5 flex flex-wrap gap-1.5">
          {details.map((item) => (
            <span
              key={item.label}
              className={`tnum rounded-md px-1.5 py-0.5 text-caption ${
                item.alert ? "bg-[var(--warn)]/12 text-[var(--warn)]" : "bg-white/[0.06] text-white/55"
              }`}
            >
              {item.label}
            </span>
          ))}
        </div>
      )}
      {(percent != null || job.status === "running") && (
        <div className="mt-2.5 h-1.5 overflow-hidden rounded-full bg-white/[0.07]">
          <div
            className={`h-full rounded-full bg-[var(--info)] transition-[width] duration-700 ${
              percent == null ? "w-1/3 animate-pulse opacity-65" : ""
            }`}
            style={
              percent == null
                ? undefined
                : { width: `${Math.min(100, Math.max(percent > 0 ? 1 : 0, percent))}%` }
            }
          />
        </div>
      )}
      {amount && <p className="tnum mt-1.5 text-caption text-white/38">{amount}</p>}
      <p className="mt-2 text-caption text-white/30">
        {jobOriginLabel(job, locale)}
        <span aria-hidden="true"> · </span>
        {job.started_at ? t("activity.taskCenter.startedAt", { time: formatClockTime(job.started_at, locale) }) : t("activity.taskCenter.createdAt", { time: formatClockTime(job.created_at, locale) })}
      </p>
    </article>
  );
}

function HistoricalJobFeedItem({
  job,
  time,
  retrying,
  onRetry,
  undismissing,
  onUndismiss,
}: {
  job: JobView;
  /** 完成时刻。不再占用左侧独立列，跟摘要同行显示，让条目与分组标题左对齐。 */
  time: string;
  retrying: boolean;
  onRetry: () => void;
  undismissing: boolean;
  onUndismiss: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();

  // 忽略必须能反悔——用户是在信息不全时按下的它（"先不管这个"），
  // 撤销入口就得留在他能找回这条记录的地方，而不是只能靠重试再造一条新任务。
  const dismissed = job.status === "failed" && isDismissed(job);
  const ingestDetail = buildIngestHistoryDetail(job, locale);
  return (
    <article className="group/history min-w-0 py-1.5">
      <div className="flex min-w-0 items-start gap-3">
        <div className="min-w-0 flex-1">
          <h3 className="text-ui font-medium leading-5 text-white/78">
            <OverflowText>{historicalJobTitle(job, locale)}</OverflowText>
          </h3>
          <div className="mt-1 flex min-w-0 items-baseline gap-2 text-caption leading-5 text-white/40">
            <span className="tnum shrink-0 text-white/32">{time}</span>
            <OverflowText lines={2} className="min-w-0 flex-1">
              {ingestDetail?.summary ?? historicalJobSummary(job, locale)}
            </OverflowText>
          </div>
          {ingestDetail && <IngestHistoryFiles detail={ingestDetail} />}
        </div>
        {dismissed && (
          <button
            type="button"
            onClick={onUndismiss}
            disabled={undismissing}
            className="shrink-0 rounded-lg px-2.5 py-1.5 text-caption font-medium text-white/35 transition hover:bg-white/[0.05] hover:text-white/65 disabled:cursor-wait disabled:opacity-40"
          >
            {undismissing ? t("activity.jobs.restoringAction") : t("activity.jobs.restoreAction")}
          </button>
        )}
        {job.status === "cancelled" && !isSystemCancelled(job) && (
          <button
            type="button"
            onClick={onRetry}
            disabled={retrying}
            className="shrink-0 rounded-lg px-2.5 py-1.5 text-caption font-medium text-white/35 transition hover:bg-white/[0.05] hover:text-white/65 disabled:cursor-wait disabled:opacity-40"
          >
            {retrying ? t("activity.taskCenter.retrying") : t("activity.jobs.retryAction")}
          </button>
        )}
      </div>
    </article>
  );
}

/** 入库历史默认只占一行，需要核对时再展开真实文件名与目标媒体库。 */
function IngestHistoryFiles({ detail }: { detail: IngestHistoryDetail }) {
  const t = useTranslations();

  if (detail.fileGroups.length === 0 && detail.context == null) return null;
  const fileCount = detail.fileGroups.reduce((total, group) => total + group.files.length, 0);
  return (
    <details className="group/files mt-1.5 max-w-full text-caption">
      <summary className="flex w-fit max-w-full cursor-pointer list-none items-center gap-1.5 rounded-md py-1 pr-1 text-white/32 transition hover:text-white/60 [&::-webkit-details-marker]:hidden">
        <ChevronRightIcon className="size-3.5 shrink-0 transition-transform group-open/files:rotate-90" />
        <span>{t("activity.taskCenter.fileDetails")}</span>
        {fileCount > 0 && <span className="tnum text-white/22">{t("activity.taskCenter.fileCount", { count: fileCount })}</span>}
      </summary>
      <div className="mt-1.5 hidden rounded-lg border border-white/[0.06] bg-white/[0.025] px-3 py-2.5 group-open/files:block">
        {detail.context && <p className="mb-2 text-white/38">{detail.context}</p>}
        <div className="space-y-2.5">
          {detail.fileGroups.map((group) => (
            <section key={group.label} aria-label={group.label}>
              <p className="mb-1 text-micro font-medium text-white/35">
                {group.label} · {t("activity.taskCenter.fileCount", { count: group.files.length })}
              </p>
              <ul className="space-y-1 text-white/52">
                {group.files.map((file) => (
                  <li key={file} title={file} className="break-all leading-5">
                    {file}
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      </div>
    </details>
  );
}

/** 历史按本地日期拆成轻量 Feed，首组默认展开，避免完成卡片占满纵向空间。 */
/**
 * 刷流做种分组：默认折叠的 <details>，头部常显最值得关心的实时汇总——
 * ↑/↓ 总速度与已上传/已下载总量；展开后逐种子一行（站点 + 名称 + 状态 +
 * 各自的速度与累计上传）。刷流种子没有媒体身份与入库流转，刻意不渲染
 * 生命周期，也不提供逐条删除（汰换归引擎管）。
 *
 * 关闭刷流不会删种：残留种子继续满速做种、引擎不再汰换，一直占着磁盘。所以头部按
 * 来源站点的开关状态写「刷流已关闭 / 已暂停」，展开后底部给整体清理入口
 * （docs/design/site-protection-ratio-boost.md §2.9）：保留期内的默认到期后自动删，
 * 勾选才立即全删（可能被记 H&R）；还开着刷流的站点会一并关闭。
 */
function BoostTaskSection({ tasks, onChanged }: { tasks: DownloadTask[]; onChanged: () => void }) {
  const t = useTranslations();
  const locale = useLocale();

  const { pool, setPool } = useBoostPool(tasks);
  const { cleaning, cleanup } = useBoostCleanup({ onPool: setPool, onChanged });
  const poolSites = new Map((pool?.sites ?? []).map((site) => [site.site_id, site]));
  const taskStates = new Map((pool?.tasks ?? []).map((task) => [task.info_hash.toLowerCase(), task]));
  // 站点状态未知（概况没取到）时按运行中处理，不替用户下「已关闭」的结论
  const modeOf = (task: DownloadTask) => {
    if (!pool) return "running";
    const site = poolSites.get(task.site_id ?? "");
    if (!site?.boost_enabled) return "off";
    return site.boost_paused ? "paused" : "running";
  };
  const offCount = tasks.filter((t) => modeOf(t) === "off").length;
  const pausedCount = tasks.filter((t) => modeOf(t) === "paused").length;
  const scheduledCount = (pool?.tasks ?? []).filter((t) => t.cleanup_scheduled).length;
  const boostMode = offCount === tasks.length ? "off" : pausedCount === tasks.length ? "paused" : "running";
  const label = boostMode === "off" ? t("activity.boost.off") : boostMode === "paused" ? t("activity.boost.paused") : t("activity.boost.heading");

  const sum = (pick: (task: DownloadTask) => number | null) =>
    tasks.reduce((total, task) => total + (pick(task) ?? 0), 0);
  const upSpeed = sum((t) => t.upspeed_bytes);
  const downSpeed = sum((t) => t.dlspeed_bytes);
  const uploaded = sum((t) => t.uploaded_bytes);
  const downloaded = sum((t) => t.completed_bytes);
  // 刷流列表最想回答的是"现在哪些种子在出力"，所以按上行速度倒序，正在上传的
  // 永远浮在最前；速度相同（绝大多数是 0）时用累计上传量兜底，让贡献大的靠前，
  // 也让静默种子之间的顺序在刷新之间保持稳定。
  const sorted = useMemo(
    () =>
      [...tasks].sort(
        (a, b) =>
          (b.upspeed_bytes ?? 0) - (a.upspeed_bytes ?? 0) ||
          (b.uploaded_bytes ?? 0) - (a.uploaded_bytes ?? 0),
      ),
    [tasks],
  );

  return (
    <section className="mt-3" aria-label={t("activity.boost.heading")}>
      <details className="group border-b border-white/[0.07] py-3.5 last:border-b-0">
        <summary className="flex cursor-pointer list-none flex-wrap items-center gap-x-3 gap-y-1 rounded-lg py-1 text-ui transition [&::-webkit-details-marker]:hidden">
          <span
            className={`font-semibold ${boostMode === "off" ? "text-white/60" : boostMode === "paused" ? "text-[var(--warn)]" : "text-[var(--accent)]"}`}
          >
            {label}
          </span>
          <span className="tnum text-caption text-white/60">
            {t("activity.boost.summary", { count: tasks.length, mode: boostMode, off: offCount, paused: pausedCount, scheduled: scheduledCount, showOff: boostMode === "running" && offCount > 0 ? "yes" : "no", showPaused: boostMode !== "paused" && pausedCount > 0 ? "yes" : "no", showScheduled: scheduledCount > 0 ? "yes" : "no" })}
          </span>
          {/* 实时汇总：速度是"现在"，总量是"战果"——都放头部，折叠时也一眼可见。
              上传走 --ok 绿（刷流的战果就是上传量），下载走 --info 蓝，数值带淡辉光
              从灰色标签里跳出来；标签本身保持浅灰，让数字成为视觉焦点。
              窄屏这四项塞不进标题行，整块换到第二行（order-2 + w-full）独占一行，
              避免和"展开"挤在一起互相把对方顶出去。第二行再排成 2×2 网格：速度一行、
              总量一行——四项自由换行时"已下载"会随速度值的宽窄时而落单成第三行，
              网格让分组头部的高度和对齐不随数字长短抖动。 */}
          <span className="tnum flex flex-wrap items-center gap-x-3 text-caption text-white/45 max-md:order-2 max-md:grid max-md:w-full max-md:grid-cols-2 max-md:gap-y-1">
            {/* 上下行速度常显：为 0 时退成灰色占位，让"现在没在下载"也是一条信息 */}
            <SpeedStat direction="up" bytesPerSecond={upSpeed} glow placeholder="↑ 0 B/s" />
            <SpeedStat direction="down" bytesPerSecond={downSpeed} glow placeholder="↓ 0 B/s" />
            <span>
              {t("activity.boost.uploaded")}<span className="font-semibold text-[var(--ok)]">{formatBytes(uploaded)}</span>
            </span>
            <span>
              {t("activity.boost.downloaded")}<span className="font-semibold text-[var(--info)]">{formatBytes(downloaded)}</span>
            </span>
          </span>
          {/* 展开态文案和箭头必须同进同退，所以包在一个不可换行的组里：上一版两者是
              summary 的兄弟节点，窄屏换行时箭头会被单独甩到下一行成为孤儿。
              窄屏 order-1 让它跟在"N 个种子"后面停在标题行右端。 */}
          <span className="ml-auto flex shrink-0 items-center gap-1 whitespace-nowrap text-caption text-white/30 max-md:order-1">
            <span className="group-open:hidden">{t("activity.taskCenter.expand")}</span>
            <span className="hidden group-open:inline">{t("activity.taskCenter.collapse")}</span>
            <ChevronRightIcon className="size-4 transition-transform group-open:rotate-90" />
          </span>
        </summary>
        <div className="mt-2 divide-y divide-white/[0.05]">
          {sorted.map((task) => (
            <BoostTaskRow
              key={task.id}
              task={task}
              cleanupNote={boostCleanupNote(taskStates.get(task.info_hash.toLowerCase()), locale)}
            />
          ))}
        </div>
        <div className="mt-3 flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
          <p className="text-caption text-white/35">
            {offCount > 0
              ? t("activity.boost.offHint")
              : t("activity.boost.managedHint")}
          </p>
          <button
            type="button"
            onClick={() => void cleanup()}
            disabled={cleaning}
            className="shrink-0 rounded-lg px-2 py-1 text-caption font-medium text-[var(--danger)] transition hover:bg-[var(--danger)]/10 disabled:opacity-50"
          >
            {cleaning ? t("activity.boost.cleaning") : t("activity.boost.cleanupAction")}
          </button>
        </div>
      </details>
    </section>
  );
}

/**
 * 刷流单行。数字列走固定宽度而不是跟着内容伸缩——上一版把站点、名称、数字全塞进
 * 一个 flex 行，每行数字个数不同就把名称挤成不同长度，180 行下来像没对齐的乱码。
 *
 * 现在的分工：站点与名称占左半区（名称吃掉全部剩余宽度），上行速度 / 累计上传 /
 * 体积三列右对齐且逐行等宽；缺值补破折号，保证列不塌陷。窄屏时数字整块换到第二行，
 * 让名称在小屏也有完整宽度。
 *
 * 下行速度刻意不占固定列：刷流种子绝大多数只做种不下载，给它留一列的结果是整张列表
 * 挂着一排毫无信息量的破折号，还把上行速度挤到要换行。它改成和进度百分比一起跟在
 * 名称后面，只在真的在下载时出现。
 */
function BoostTaskRow({ task, cleanupNote }: { task: DownloadTask; cleanupNote?: string | null }) {
  const t = useTranslations();

  const downloading = task.state === "downloading";
  const percent = task.progress == null ? null : Math.floor(task.progress * 100);
  const showDownloadNote = (downloading && percent != null) || (task.dlspeed_bytes ?? 0) > 0;
  const name = (
    <OverflowText className="min-w-0 flex-1 text-ui text-white/80">
      {task.name || task.info_hash}
    </OverflowText>
  );
  return (
    <div className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 py-2">
      <div className="flex w-[4.5rem] shrink-0">
        {task.site_name && (
          <span className="truncate rounded-full bg-white/[0.06] px-2 py-0.5 text-caption font-medium text-white/55">
            {task.site_name}
          </span>
        )}
      </div>
      {task.page_url ? (
        <a
          href={task.page_url}
          target="_blank"
          rel="noreferrer"
          className="flex min-w-0 flex-1 hover:text-white"
          title={t("activity.taskCenter.siteDetails")}
        >
          {name}
        </a>
      ) : (
        name
      )}
      {/* 窄屏字号比桌面大一档（--text-caption 11px → 13px），5.5rem 装不下
          "↑ 63.95 KB/s"，速度会被折成两行。窄屏改用按内容需求配比的弹性列
          （速度 : 累计 : 体积 ≈ 9 : 10 : 7），列宽随屏宽缩放而比例不变——既保住逐行
          对齐，也让 360px 的小屏和 430px 的大屏都留有余量；nowrap 再兜一道底 */}
      <div className="tnum grid shrink-0 grid-cols-[5.5rem_7rem_5rem] items-center gap-x-3 whitespace-nowrap text-right text-caption text-white/40 max-md:w-full max-md:grid-cols-[9fr_10fr_7fr] max-md:gap-x-2">
        <SpeedStat direction="up" bytesPerSecond={task.upspeed_bytes} placeholder="—" />
        <span>
          {task.uploaded_bytes != null && task.uploaded_bytes > 0
            ? t("activity.boost.uploadedTotal", { size: formatBytes(task.uploaded_bytes) })
            : "—"}
        </span>
        <span>{task.size_bytes != null ? formatBytes(task.size_bytes) : "—"}</span>
      </div>
      {/* 下载中的刷流种子是少数，进度与下行速度不占固定列，另起一行挂在数字列下方：
          既不因为多出两个值把逐行对齐搞乱，也保证 ↑ 永远排在 ↓ 前面，和分组汇总
          头部（↑ 速度 → ↓ 速度 → 已上传 → 已下载）的"上传在前"口径一致 */}
      {showDownloadNote && (
        <div className="flex w-full items-center justify-end gap-x-2 text-caption text-white/35">
          {downloading && percent != null && <span className="tnum">{percent}%</span>}
          <SpeedStat direction="down" bytesPerSecond={task.dlspeed_bytes} />
        </div>
      )}
      {cleanupNote && <div className="w-full text-caption text-[var(--warn)]/80">{cleanupNote}</div>}
    </div>
  );
}

function TaskHistorySection({
  jobs,
  initiallyOpen,
  separated,
  retryingJobId,
  onRetry,
  undismissingJobId,
  onUndismiss,
}: {
  jobs: JobView[];
  initiallyOpen: boolean;
  separated: boolean;
  retryingJobId: string | null;
  onRetry: (job: JobView) => void;
  undismissingJobId: string | null;
  onUndismiss: (job: JobView) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const groups = groupHistoricalJobs(jobs, locale);
  return (
    <section
      className={separated ? "mt-6 border-t border-white/[0.1]" : "mt-3"}
      aria-label={t("activity.taskCenter.historyRegion")}
    >
      {groups.map((group, index) => (
        <details
          key={group.key}
          open={initiallyOpen || index === 0 || undefined}
          className="group border-b border-white/[0.07] py-3.5 last:border-b-0"
        >
          <summary className="flex cursor-pointer list-none items-center gap-2 rounded-lg py-1 text-ui text-white/55 transition hover:text-white/80 [&::-webkit-details-marker]:hidden">
            <span className="font-semibold">{group.label}</span>
            <span className="tnum text-caption text-white/30">{t("activity.taskCenter.itemCount", { count: group.jobs.length })}</span>
            <span className="ml-auto text-caption text-white/30 group-open:hidden">{t("activity.taskCenter.expand")}</span>
            <span className="ml-auto hidden text-caption text-white/30 group-open:inline">{t("activity.taskCenter.collapse")}</span>
            <ChevronRightIcon className="size-4 transition-transform group-open:rotate-90" />
          </summary>
          <div className="mt-3">
            {group.jobs.map((job) => (
              <TaskTimelineItem
                key={job.id}
                tone={
                  job.status !== "succeeded"
                    ? "cancelled"
                    : jobDetailItems(job, locale).some((item) => item.alert)
                      ? "partial"
                      : "success"
                }
              >
                <HistoricalJobFeedItem
                  job={job}
                  time={formatClockTime(job.finished_at || job.created_at, locale)}
                  retrying={retryingJobId === job.id}
                  onRetry={() => onRetry(job)}
                  undismissing={undismissingJobId === job.id}
                  onUndismiss={() => onUndismiss(job)}
                />
              </TaskTimelineItem>
            ))}
          </div>
        </details>
      ))}
    </section>
  );
}

/**
 * 一个下载任务有两条独立进度轴：下载轴的事实源永远是下载器，入库轴的事实源
 * 是逐集工单状态。入库 Job 只是「此刻正在搬」的瞬时装饰——边下边入库时，两
 * 批搬运之间没有任何 Job 存活，用「有没有 Job」当状态源会把「整季只下了
 * 19%、其中先入库 1 集」显示成「下载完成 + 入库完成 100%」（真实事故）。
 *
 * 因此只有两种情况允许入库轴接管卡片主状态：整包已下完（入库确实是此刻唯一
 * 在推进的事），或入库受阻需要人处理（必须顶到最前，不能被下载进度盖住）。
 */
function ingestOwnsTaskState(task: DownloadTask, ingestJob: JobView | null): boolean {
  if (ingestJob == null || ingestJob.status === "cancelled") return false;
  // 用户已经忽略的失败入库不再顶到最前——他要的正是"别再拿这件事挡着我"，
  // 卡片交回下载轴如实讲进度。
  if (jobNeedsAttention(ingestJob)) return true;
  return task.state === "completed";
}

/** 这条任务是不是洗版（要洗的集本来就在库里，进度讲的是替换而非入库）。 */
function isUpgradeTask(task: DownloadTask): boolean {
  return task.subscriptions[0]?.purpose === "upgrade";
}

/**
 * 洗版任务的身份标。洗版与补缺下载在任务中心同形，但读法完全不同——库里
 * 已有这些集、这个种子是来换掉它们的，没有这个标就只能靠文案猜。青色沿用
 * 订阅详情页的洗版专属色，跨页面同一概念同一颜色。
 */
function UpgradeTaskBadge({ task }: { task: DownloadTask }) {
  const t = useTranslations();

  if (!isUpgradeTask(task)) return null;
  return (
    <span
      title={t("activity.taskCenter.upgradeHint")}
      className="shrink-0 rounded-full border border-[#2dd4bf]/30 bg-[#2dd4bf]/[0.12] px-1.5 py-0.5 text-[11px] font-semibold leading-none text-[#2dd4bf]"
    >
      {t("activity.taskCenter.upgrade")}</span>
  );
}

function downloadGroupTimelineTone(
  group: DownloadTaskGroup,
  ingestJobsByHash: Map<string, JobView>,
): "active" | "waiting" {
  const executing = group.tasks.some((task) => {
    const ingestJob = ingestJobsByHash.get(task.info_hash.toLowerCase());
    return ingestJob?.status === "running" || ["downloading", "checking"].includes(task.state);
  });
  return executing ? "active" : "waiting";
}

/** “现在”区域使用过程行，不再把下载卡片原样塞进时间轴。 */
function DownloadTaskGroupFeed({
  group,
  ingestJobsByHash,
  deletingTaskId,
  replacingTaskId,
  onDelete,
  onReplace,
}: {
  group: DownloadTaskGroup;
  ingestJobsByHash: Map<string, JobView>;
  deletingTaskId: string | null;
  replacingTaskId: string | null;
  onDelete: (task: DownloadTask) => void;
  onReplace: (task: DownloadTask) => void;
}) {
  const t = useTranslations();

  const grouped = group.mediaItemId != null;
  const firstSubscription = group.tasks.flatMap((task) => task.subscriptions)[0];
  return (
    <article className="min-w-0 py-1.5">
      {grouped && (
        <div className="mb-2 flex min-w-0 items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            <h3 className="flex min-w-0 items-center gap-2 text-ui font-semibold leading-5 text-white/90">
              <span className="shrink-0 rounded-full border border-[var(--info)]/25 bg-[var(--info)]/[0.12] px-1.5 py-0.5 text-[11px] font-semibold leading-none text-[var(--info)]">
                {t("activity.taskCenter.live")}</span>
              <OverflowText className="flex-1">{group.title}</OverflowText>
            </h3>
            <p className="mt-1 text-caption text-white/35">
              {group.kind === "tv" ? t("media.kind.tv") : t("media.kind.movie")}
              <span aria-hidden="true"> · </span>
              {t("activity.taskCenter.releaseCount", { count: group.tasks.length })}
            </p>
          </div>
          {firstSubscription && (
            <Link
              href={`/subscriptions/${firstSubscription.id}` as Route}
              className="shrink-0 rounded-lg px-2.5 py-1.5 text-caption font-medium text-white/40 transition hover:bg-white/[0.06] hover:text-white/70"
            >
              {t("activity.taskCenter.viewSubscription")}</Link>
          )}
        </div>
      )}
      <div
        className={
          grouped
            ? "divide-y divide-white/[0.06] border-l border-white/[0.1] pl-3.5"
            : ""
        }
      >
        {group.tasks.map((task) => (
          <DownloadTaskFeedItem
            key={task.id}
            task={task}
            ingestJob={ingestJobsByHash.get(task.info_hash.toLowerCase()) ?? null}
            grouped={grouped}
            deleting={deletingTaskId === task.id}
            replacing={replacingTaskId === task.id}
            onDelete={onDelete}
            onReplace={onReplace}
          />
        ))}
      </div>
    </article>
  );
}

function DownloadTaskFeedItem({
  task,
  ingestJob,
  grouped,
  deleting,
  replacing,
  onDelete,
  onReplace,
}: {
  task: DownloadTask;
  ingestJob: JobView | null;
  grouped: boolean;
  deleting: boolean;
  replacing: boolean;
  onDelete: (task: DownloadTask) => void;
  onReplace: (task: DownloadTask) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const ingestOwnsState = ingestOwnsTaskState(task, ingestJob);
  const meta =
    ingestOwnsState && ingestJob
      ? ingestStateMeta(ingestJob.status, locale)
      : downloadStateMeta(task.state, locale);
  const downloadPercent = task.progress == null ? null : Math.floor(task.progress * 100);
  const percent =
    ingestOwnsState && ingestJob
      ? ingestJob.progress.percent == null
        ? null
        : Math.floor(ingestJob.progress.percent)
      : downloadPercent;
  const title = grouped
    ? task.name || task.media_title || task.info_hash
    : task.media_title || task.name || task.info_hash;
  // 有关联入库 Job 时不再单独出一行文字说明：入库阶段与解释由底部生命
  // 周期承担，覆盖集标签会标注已入库进度，feed 行只保留下载态/换源提示
  const note = ingestJob != null ? null : downloadTaskNote(task, null, locale);
  const showReplace = shouldOfferInlineReplacement(task);
  const firstSubscription = task.subscriptions[0];
  // 种子名前用站点徽标回答"这个资源从哪来"；画面规格、片源与文件尺寸紧随
  // 其后，弥补高度同质化的 release 名。状态与进度由底部生命周期承担，不再
  // 重复；速度与剩余时间单独一行，专注实时传输信息。
  // Remux 与片源是两个字段（Remux 的片源仍是 UHD Blu-ray），排在片源之后
  // 单列一项，与搜索结果页的 Remux 徽标同口径
  const specs = [
    task.resolution,
    task.media_source,
    task.remux ? "Remux" : null,
    task.size_bytes != null ? formatBytes(task.size_bytes) : null,
  ].filter((item): item is string => item != null);
  // 下行速度只在真正下载时有意义；上行（做种）在下载中和等待入库期间都可能存在
  const downSpeed =
    !ingestOwnsState &&
    task.state === "downloading" &&
    task.dlspeed_bytes != null &&
    task.dlspeed_bytes > 0
      ? task.dlspeed_bytes
      : null;
  const upSpeed = task.upspeed_bytes != null && task.upspeed_bytes > 0 ? task.upspeed_bytes : null;
  const etaSeconds = !ingestOwnsState ? task.eta_seconds : null;

  return (
    <div className={grouped ? "py-2.5 first:pt-1 last:pb-1" : ""}>
      <div className="flex min-w-0 items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <h3
            className={`flex min-w-0 items-center gap-2 ${
              grouped ? "text-sub" : "text-ui"
            } font-semibold leading-5 text-white/88`}
          >
            {!grouped && (
              <span className="shrink-0 rounded-full border border-[var(--info)]/25 bg-[var(--info)]/[0.12] px-1.5 py-0.5 text-[11px] font-semibold leading-none text-[var(--info)]">
                {t("activity.taskCenter.live")}</span>
            )}
            {task.site_name && (
              <span className="shrink-0 rounded-full border border-white/[0.14] bg-white/[0.06] px-1.5 py-0.5 text-[11px] font-medium leading-none text-white/55">
                {task.site_name}
              </span>
            )}
            <OverflowText className="flex-1">{title}</OverflowText>
          </h3>
          {/* 覆盖集号紧跟标题：先答"这个种子给的是哪几集"，再看规格与速度。
              洗版标紧贴集号——它限定的正是这些集的性质（换掉而非新增） */}
          {firstSubscription && (
            <div className="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-caption">
              <UpgradeTaskBadge task={task} />
              <EpisodeUnitsLabel
                units={firstSubscription.units}
                purpose={firstSubscription.purpose}
              />
            </div>
          )}
          {specs.length > 0 && (
            <p className="mt-1.5 flex flex-wrap items-center gap-x-1.5 text-caption text-white/88">
              {specs.map((spec, index) => (
                <span key={spec} className="flex items-center gap-x-1.5">
                  {index > 0 && (
                    <span aria-hidden="true" className="text-white/25">·</span>
                  )}
                  {spec}
                </span>
              ))}
            </p>
          )}
        </div>
        {(task.page_url != null || task.downloader_id != null) && (
          <DownloadTaskActionsMenu
            task={task}
            deleting={deleting}
            replacing={replacing}
            onDelete={onDelete}
          />
        )}
      </div>
      {note && (
        <OverflowText lines={2} className="mt-1.5 text-caption leading-5 text-white/42">
          {note}
        </OverflowText>
      )}
      {percent != null && task.state !== "missing" && (
        <div className="mt-2.5 h-1.5 overflow-hidden rounded-full bg-white/[0.07]">
          <div
            className="h-full rounded-full transition-[width] duration-700"
            style={{
              width: `${Math.min(100, Math.max(percent > 0 ? 1 : 0, percent))}%`,
              backgroundColor: meta.color,
            }}
          />
        </div>
      )}
      {/* 实时传输单独一行：下行/上行速度与剩余时间；文件尺寸已并入规格行 */}
      {(downSpeed != null || upSpeed != null || etaSeconds != null) && (
        <div className="mt-1.5 flex flex-wrap items-center gap-x-2.5 gap-y-1 text-caption text-white/38">
          <SpeedStat direction="down" bytesPerSecond={downSpeed} />
          <SpeedStat direction="up" bytesPerSecond={upSpeed} />
          {etaSeconds != null && <span>{t("activity.taskCenter.remaining", { duration: formatDuration(etaSeconds, locale) })}</span>}
        </div>
      )}
      <DownloadLifecycle task={task} ingestJob={ingestJob} variant="feed" />
      {showReplace && (
        <button
          type="button"
          onClick={() => onReplace(task)}
          disabled={replacing}
          className="mt-2 rounded-lg border border-[var(--danger)]/25 bg-[var(--danger)]/[0.07] px-2.5 py-1.5 text-caption font-semibold text-[#fee2e2] transition hover:bg-[var(--danger)]/[0.13] disabled:cursor-wait disabled:opacity-50"
        >
          {replacing ? t("activity.taskCenter.replacing") : t("activity.taskCenter.replaceNow")}
        </button>
      )}
    </div>
  );
}

function DownloadTaskGroupCard({
  group,
  ingestJobsByHash,
  deletingTaskId,
  replacingTaskId,
  onDelete,
  onReplace,
}: {
  group: DownloadTaskGroup;
  ingestJobsByHash: Map<string, JobView>;
  deletingTaskId: string | null;
  replacingTaskId: string | null;
  onDelete: (task: DownloadTask) => void;
  onReplace: (task: DownloadTask) => void;
}) {
  const t = useTranslations();

  if (group.mediaItemId == null) {
    const task = group.tasks[0];
    return (
      <DownloadTaskCard
        task={task}
        ingestJob={ingestJobsByHash.get(task.info_hash.toLowerCase()) ?? null}
        deleting={deletingTaskId === task.id}
        replacing={replacingTaskId === task.id}
        onDelete={onDelete}
        onReplace={onReplace}
      />
    );
  }

  const isTv = group.kind === "tv";
  const firstSubscription = group.tasks.flatMap((task) => task.subscriptions)[0];
  return (
    <article className="solid-card overflow-hidden rounded-2xl border border-white/[0.08] bg-[rgba(14,16,22,0.52)] backdrop-blur-xl">
      {/* 影片身份集中在紧凑顶部，种子列表另起整行占满卡片宽度。海报不再
          作为贯穿整组的左栏，长种子名、状态和操作按钮因此有完整横向空间。 */}
      <div className="flex items-center gap-3.5 border-b border-white/[0.07] px-4 py-3 max-md:px-3.5">
        <div className="w-10 shrink-0 max-md:w-9">
          <div className="aspect-[2/3] overflow-hidden rounded-lg bg-[var(--poster-placeholder)] ring-1 ring-white/10">
            <PosterImage
              src={imageUrl(group.posterUrl)}
              width={40}
              alt={t("activity.taskCenter.posterAria", { title: group.title })}
              className="size-full"
              fallback={
                <div className="flex size-full items-center justify-center bg-gradient-to-b from-white/[0.07] to-[#11141c] text-white/25">
                  {isTv ? <TvIcon className="size-4" /> : <FilmIcon className="size-4" />}
                </div>
              }
            />
          </div>
        </div>
        <div className="min-w-0 flex-1">
          <h3 className="min-w-0 text-ui font-semibold text-white/90">
            <OverflowText>{group.title}</OverflowText>
          </h3>
          <p className="mt-0.5 text-caption text-white/40">
            {isTv ? t("media.kind.tv") : t("media.kind.movie")}
            <span aria-hidden="true"> · </span>
            {t("activity.taskCenter.releaseCount", { count: group.tasks.length })}
          </p>
        </div>
        {firstSubscription && (
          <Link
            href={`/subscriptions/${firstSubscription.id}` as Route}
            className="shrink-0 rounded-lg border border-white/10 px-3 py-1.5 text-caption font-medium text-white/60 transition hover:bg-white/[0.06] hover:text-white"
          >
            {t("activity.taskCenter.viewSubscription")}</Link>
        )}
      </div>
      <div className="space-y-2 p-3.5 max-md:p-3">
        {group.tasks.map((task) => (
          <DownloadTaskCard
            key={task.id}
            task={task}
            ingestJob={ingestJobsByHash.get(task.info_hash.toLowerCase()) ?? null}
            grouped
            deleting={deletingTaskId === task.id}
            replacing={replacingTaskId === task.id}
            onDelete={onDelete}
            onReplace={onReplace}
          />
        ))}
      </div>
    </article>
  );
}

function DownloadTaskCard({
  task,
  ingestJob,
  grouped = false,
  deleting,
  replacing,
  onDelete,
  onReplace,
}: {
  task: DownloadTask;
  ingestJob: JobView | null;
  grouped?: boolean;
  deleting: boolean;
  replacing: boolean;
  onDelete: (task: DownloadTask) => void;
  onReplace: (task: DownloadTask) => void;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const ingestOwnsCardState = ingestOwnsTaskState(task, ingestJob);
  const meta =
    ingestOwnsCardState && ingestJob
      ? ingestStateMeta(ingestJob.status, locale)
      : downloadStateMeta(task.state, locale);
  const title = grouped
    ? task.name || task.media_title || task.info_hash
    : task.media_title || task.name || task.info_hash;
  const torrentName = !grouped && task.name && task.name !== title ? task.name : null;
  const sourceLabel =
    task.source === "subscription"
      ? t("activity.taskCenter.subscriptionSource")
      : task.source === "manual"
        ? t("activity.taskCenter.manualSource")
        : t("activity.taskCenter.downloaderSource");
  const percent = task.progress == null ? null : Math.floor(task.progress * 100);
  const displayPercent = ingestOwnsCardState
    ? ingestJob?.progress.percent == null
      ? null
      : Math.floor(ingestJob.progress.percent)
    : percent;
  const progressLabel = ingestOwnsCardState ? t("activity.taskCenter.importProgress") : t("activity.taskCenter.downloadProgress");
  const firstSubscription = task.subscriptions[0];
  const showInlineReplace = shouldOfferInlineReplacement(task);
  // 与侧栏角标、「需要处理」分区同一口径（download-attention）：外部任务只观察不报警
  const needsAttention = downloadTaskNeedsAttention(task, ingestJob);
  const taskNote = downloadTaskNote(task, ingestJob, locale);
  const showDownloadRuntime = !ingestOwnsCardState && task.state === "downloading";

  return (
    <article
      className={
        grouped
          ? "rounded-xl border border-white/[0.06] bg-black/15 p-3"
          : "solid-card rounded-2xl border border-white/[0.08] bg-[rgba(14,16,22,0.5)] p-4 backdrop-blur-xl max-md:p-3.5"
      }
    >
      <div className="min-w-0">
        <div className="flex items-start justify-between gap-3">
          <div className="flex min-w-0 flex-1 items-center gap-2.5">
            <TaskStatusDot label={meta.label} dotClass={meta.dot} />
            <h3 className="min-w-0 text-ui font-semibold leading-5 text-white/90">
              <OverflowText>{title}</OverflowText>
            </h3>
          </div>
          {(task.page_url != null || task.downloader_id != null) && (
            <DownloadTaskActionsMenu
              task={task}
              deleting={deleting}
              replacing={replacing}
              onDelete={onDelete}
            />
          )}
        </div>
        {(torrentName || taskNote) && (
          <div
            className={`mt-2.5 text-sub leading-5 ${
              needsAttention
                ? "rounded-xl border border-[var(--danger)]/15 bg-[var(--danger)]/[0.06] px-3 py-2.5 text-[var(--danger)]"
                : "text-white/60"
            }`}
          >
            <div className="flex min-w-0 flex-wrap items-center gap-x-2.5 gap-y-2">
              <div className="min-w-0 flex-1 basis-[28rem]">
                <OverflowText
                  lines={2}
                  className="break-words"
                  tooltipContent={
                    <span className="whitespace-pre-wrap break-words [overflow-wrap:anywhere]">
                      {needsAttention && <span className="mr-1.5 font-semibold">{t("activity.jobs.attentionPrefix")}</span>}
                      {torrentName && <span>{torrentName}</span>}
                      {torrentName && taskNote && <span aria-hidden="true"> · </span>}
                      {taskNote}
                    </span>
                  }
                >
                  {needsAttention && <span className="mr-1.5 font-semibold">{t("activity.jobs.attentionPrefix")}</span>}
                  {torrentName && <span>{torrentName}</span>}
                  {torrentName && taskNote && <span aria-hidden="true"> · </span>}
                  {taskNote}
                </OverflowText>
              </div>
              {showInlineReplace && (
                <button
                  type="button"
                  onClick={() => onReplace(task)}
                  disabled={replacing}
                  className="shrink-0 rounded-lg border border-[var(--danger)]/30 bg-[var(--danger)]/[0.1] px-3 py-1.5 text-caption font-semibold text-[#fee2e2] transition hover:border-[var(--danger)]/45 hover:bg-[var(--danger)]/[0.16] disabled:cursor-wait disabled:opacity-55"
                >
                  {replacing ? t("activity.taskCenter.replacing") : t("activity.taskCenter.replaceNow")}
                </button>
              )}
            </div>
          </div>
        )}
        {firstSubscription && (
          <div className="mt-2.5 flex flex-wrap items-start gap-x-2 gap-y-1.5 text-caption">
            <UpgradeTaskBadge task={task} />
            <EpisodeUnitsLabel units={firstSubscription.units} purpose={firstSubscription.purpose} />
          </div>
        )}
        <div className="mt-2.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-caption text-white/40">
          <span>{sourceLabel}</span>
          <span>{task.downloader_name || t("activity.taskCenter.missingAllClients")}</span>
          {task.size_bytes != null && <span>{formatBytes(task.size_bytes)}</span>}
        </div>
      </div>
      {displayPercent != null && task.state !== "missing" && (
        <div className="mt-3">
          <div className="mb-1.5 grid grid-cols-[minmax(0,1fr)_auto] items-start gap-x-3 text-caption">
            <div className="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-0.5">
              <span className="font-medium text-white/55">{progressLabel}</span>
              {showDownloadRuntime && task.dlspeed_bytes != null && task.dlspeed_bytes > 0 && (
                <>
                  <span aria-hidden="true" className="text-white/25">
                    ·
                  </span>
                  <SpeedStat direction="down" bytesPerSecond={task.dlspeed_bytes} />
                </>
              )}
              {showDownloadRuntime && task.eta_seconds != null && (
                <>
                  <span aria-hidden="true" className="text-white/25">
                    ·
                  </span>
                  <span className="text-white/45">
                    {t("activity.taskCenter.remaining", { duration: formatDuration(task.eta_seconds, locale) })}
                  </span>
                </>
              )}
            </div>
            <span className="tnum shrink-0 font-semibold text-white/65">
              {Math.min(100, Math.max(0, displayPercent))}%
            </span>
          </div>
          <div className="h-1.5 overflow-hidden rounded-full bg-white/[0.08]">
            <div
              className="h-full rounded-full transition-[width] duration-700"
              style={{
                width: `${Math.min(100, Math.max(displayPercent > 0 ? 1 : 0, displayPercent))}%`,
                backgroundColor: meta.color,
              }}
            />
          </div>
        </div>
      )}
      <DownloadLifecycle task={task} ingestJob={ingestJob} />
      {/* 出错的是下载器里的**这条任务**，不是下载器本身：以前这里只给"检查下载器"
          入口，用户点过去看到连接正常、更不知道该做什么。能在 MovieClaw 里完成的
          动作只有删掉它——订阅任务删掉后巡检会把工单退回重新寻找资源；错误原因和
          去下载器重新校验的提示由上方备注说明。下载完成但 movieclaw 看不到文件
          （landing_error）时同理：修路径映射是首选，实在找不回文件就删掉重下。
          任务缺失（missing）时下载器里已经没有它，巡检会自动退回工单，不需要
          用户动手，因此不再给任何按钮 */}
      {/* 需要处理的任务一律给「交给 AI 分析」作为第二出口：确定性动作（删除/换种）
          仍是第一按钮；用户不知道该选哪个时，AI 拿到的是带现场自检的完整工单 */}
      {downloadTaskNeedsAttention(task, ingestJob) && (
        <footer className="mt-3 flex flex-wrap items-center justify-end gap-2 border-t border-white/[0.06] pt-3">
          <HandoffButton kind="download" refId={task.info_hash} className="text-caption" />
          {(task.state === "error" || task.landing_error != null) && task.downloader_id != null && (
            <button
              type="button"
              onClick={() => onDelete(task)}
              disabled={deleting}
              className="rounded-lg border border-[var(--danger)]/25 bg-[var(--danger)]/[0.07] px-3 py-1.5 text-caption font-medium text-[var(--danger)] transition hover:bg-[var(--danger)]/[0.14] disabled:cursor-wait disabled:opacity-55"
            >
              {deleting ? t("activity.taskCenter.deletingShort") : t("activity.taskCenter.deleteDownload")}
            </button>
          )}
        </footer>
      )}
    </article>
  );
}

const LIFECYCLE_DOT_STYLE: Record<LifecycleTone, string> = {
  done: "bg-[var(--ok)]",
  current: "animate-pulse bg-[var(--info)] ring-2 ring-[var(--info)]/15",
  waiting: "bg-[var(--warn)] ring-2 ring-[var(--warn)]/10",
  attention: "bg-[var(--danger)] ring-2 ring-[var(--danger)]/15",
  future: "border border-white/25",
};

const LIFECYCLE_LABEL_STYLE: Record<LifecycleTone, string> = {
  done: "text-white/60",
  current: "text-[var(--info)]",
  waiting: "text-amber-100/70",
  attention: "text-[var(--danger)]",
  future: "text-white/30",
};

const LIFECYCLE_DETAIL_STYLE: Record<LifecycleTone, string> = {
  done: "text-white/30",
  current: "text-white/30",
  waiting: "text-amber-100/40",
  attention: "text-[var(--danger)]/70",
  future: "text-white/30",
};

/**
 * 把下载器状态与关联入库 Job 投影成同一条业务过程。这里不生成新状态：每一步
 * 都能回溯到下载快照或 Job，因此刷新、重试与回退仍由原领域负责。
 */
function DownloadLifecycle({
  task,
  ingestJob,
  variant = "card",
}: {
  task: DownloadTask;
  ingestJob: JobView | null;
  variant?: "card" | "feed";
}) {
  const t = useTranslations();
  const locale = useLocale();

  const steps = downloadLifecycleSteps(task, ingestJob, locale);
  const feed = variant === "feed";

  return (
    <ol
      aria-label={t("activity.taskCenter.lifecycleAria")}
      className={
        feed
          ? "mt-3 space-y-1.5"
          : // 手机与桌面同一形态：竖排时间线（对齐 iOS App）。步骤数随落点配置变化
            // （监听规则多一步搬运、洗版再多一步替换），横排到 5～6 列会把说明挤成省略号
            "mt-3 grid grid-cols-1 gap-2 border-t border-white/[0.06] pt-3"
      }
    >
      {steps.map((step, index) => (
        <li
          key={`${step.label}:${step.detail}`}
          className="relative flex min-w-0 items-start gap-2"
        >
          {index < steps.length - 1 && (
            <span
              aria-hidden="true"
              className="absolute bottom-[-0.5rem] left-[0.21875rem] top-3 w-px bg-white/[0.1]"
            />
          )}
          <span
            aria-hidden="true"
            className={`mt-1.5 size-2 shrink-0 rounded-full ${LIFECYCLE_DOT_STYLE[step.tone]}`}
          />
          <span className={feed ? "flex min-w-0 flex-wrap items-baseline gap-x-2" : "min-w-0"}>
            <span className={`text-caption font-medium ${LIFECYCLE_LABEL_STYLE[step.tone]}`}>
              {step.label}
            </span>
            <OverflowText
              lines={step.tone === "attention" ? 2 : 1}
              className={`${feed ? "text-caption" : "mt-0.5 text-micro"} ${LIFECYCLE_DETAIL_STYLE[step.tone]}`}
            >
              {step.detail}
            </OverflowText>
          </span>
        </li>
      ))}
    </ol>
  );
}

/** 打开种子页与删除收进右上角菜单；查看订阅由分组标题承担，不在此重复。 */
function DownloadTaskActionsMenu({
  task,
  deleting,
  replacing,
  onDelete,
}: {
  task: DownloadTask;
  deleting: boolean;
  replacing: boolean;
  onDelete: (task: DownloadTask) => void;
}) {
  const t = useTranslations();

  return (
    <TaskActionsMenu
      ariaLabel={t("activity.jobs.moreActions", { title: task.name || task.info_hash })}
      disabled={deleting || replacing}
      items={[
        ...(task.page_url
          ? [
              {
                id: "torrent-page",
                label: t("activity.taskCenter.torrentPage"),
                onSelect: () => {
                  window.open(task.page_url!, "_blank", "noopener,noreferrer");
                },
              },
            ]
          : []),
        ...(task.downloader_id != null
          ? [
              {
                id: "delete",
                label: deleting ? t("activity.taskCenter.deletingShort") : t("activity.taskCenter.deleteAction"),
                onSelect: () => onDelete(task),
                disabled: deleting,
                tone: "danger" as const,
              },
            ]
          : []),
      ]}
    />
  );
}

/**
 * 多集资源默认显示连续区间，同一标签内并列入库进度；点击后按季查看完整
 * 集号，已入库的集标绿。原生 details 保留了键盘与读屏交互，也不会为了
 * 这块纯展示状态引入额外 React 状态。
 *
 * 收起态刻意做成"带展开箭头的文字"而非按钮：它是行内的一条事实，和规格、
 * 速度同级，做成描边填充的胶囊会盖过标题。可点击性交给箭头与 hover 提亮，
 * 键盘焦点另给焦点环（去掉背景后默认 outline 不再可辨）。
 */
function EpisodeUnitsLabel({
  units,
  purpose,
}: {
  units: DownloadTask["subscriptions"][number]["units"];
  purpose: DownloadTask["subscriptions"][number]["purpose"];
}) {
  const t = useTranslations();
  const locale = useLocale();

  const summary = summarizeEpisodeUnits(units, locale);
  if (!summary) return null;
  // 洗版口径：绿色标的是"已经被这个种子换掉的集"。沿用 imported 会把要洗
  // 的集全标绿（它们本来就在库里），读起来像任务已完成
  const upgrade = purpose === "upgrade";
  const doneKeys = new Set(
    units
      .filter((unit) => (upgrade ? unit.replaced : unit.status === "imported"))
      .map((unit) => `${unit.season_number}:${unit.episode_number}`),
  );
  const doneCount = doneKeys.size;
  const doneWord = upgrade ? t("activity.taskCenter.replaced") : t("activity.taskCenter.imported");
  if (summary.kind === "movie" || summary.episodeCount <= 1) {
    return (
      <span className="tnum">
        {summary.label}
        {summary.kind === "episodes" && doneCount > 0 && (
          <span className="text-[var(--ok)]">{t("activity.taskCenter.singleDone", { label: doneWord })}</span>
        )}
      </span>
    );
  }

  return (
    <details className="group min-w-0 max-w-full open:basis-full open:w-full">
      <summary
        aria-label={t("activity.taskCenter.episodeCoverageAria", { count: summary.episodeCount, episodes: summary.fullLabel, hasDone: doneCount > 0 ? "yes" : "no", upgrade: upgrade ? "yes" : "no", done: doneCount })}
        className="flex w-fit max-w-full cursor-pointer list-none items-center gap-1 rounded text-white/88 transition-colors hover:text-white focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-[var(--accent-ring)] [&::-webkit-details-marker]:hidden"
      >
        <OverflowText
          focusable={false}
          placement="top-start"
          className="tnum"
          tooltipContent={
            <span className="tnum break-words [overflow-wrap:anywhere]">{summary.fullLabel}</span>
          }
        >
          {summary.label}
        </OverflowText>
        {doneCount > 0 && (
          <span className="tnum shrink-0 text-[var(--ok)]">
            {upgrade ? t("activity.taskCenter.doneEpisodes", { upgrade: "yes", count: doneCount }) : t("activity.taskCenter.doneEpisodes", { upgrade: "no", count: doneCount })}
          </span>
        )}
        <ChevronRightIcon className="size-3 shrink-0 rotate-90 opacity-45 transition-transform group-open:-rotate-90" />
      </summary>
      <div className="mt-2 max-w-xl space-y-2.5 rounded-xl border border-white/[0.07] bg-white/[0.035] px-3 py-2.5">
        {summary.seasons.map((season) => (
          <div key={season.seasonNumber}>
            <div className="mb-1.5 flex items-center gap-2 font-medium text-white/65">
              <span className="tnum">S{String(season.seasonNumber).padStart(2, "0")}</span>
              <span className="font-normal text-white/35">{t("activity.taskCenter.seasonEpisodes", { count: season.episodes.length })}</span>
            </div>
            <div className="flex flex-wrap gap-1.5">
              {season.episodes.map((episode) => {
                const done = doneKeys.has(`${season.seasonNumber}:${episode}`);
                return (
                  <span
                    key={episode}
                    title={done ? doneWord : undefined}
                    className={`tnum rounded-md px-1.5 py-0.5 text-micro ${
                      done
                        ? "bg-[var(--ok)]/[0.16] text-[var(--ok)]"
                        : "bg-white/[0.055] text-white/60"
                    }`}
                  >
                    E{String(episode).padStart(2, "0")}
                  </span>
                );
              })}
            </div>
          </div>
        ))}
        {summary.seasons.length > 1 && (
          <p className="border-t border-white/[0.06] pt-2 text-right text-micro text-white/35">
            {t("activity.taskCenter.totalEpisodes", { count: summary.episodeCount })}
          </p>
        )}
      </div>
    </details>
  );
}

// ---------------------------------------------------------------------------
// 活动总览（银玻璃）的一行摘要：完整过程与全部操作在二级页，行上只露一眼能看懂的
// 标题 · 一行状态 · 进度条（原生 App 的 ActivityDashboardRows.swift）。放在这里是因为
// 状态口径（DOWNLOAD_STATE_META / ingestOwnsTaskState / 作业标题）都是任务视角的私有逻辑。
// ---------------------------------------------------------------------------

/** 一行摘要里的细进度条 */
function RowProgress({ percent, color }: { percent: number; color: string }) {
  return (
    <div className="mt-1.5 h-1 overflow-hidden rounded-full bg-white/[0.08]">
      <div
        className="h-full rounded-full transition-[width] duration-700"
        style={{ width: `${Math.min(100, Math.max(percent > 0 ? 1 : 0, percent))}%`, backgroundColor: color }}
      />
    </div>
  );
}

/**
 * 进行中的下载（按作品合并的一组）：下载完成后改报入库进度——下载与入库是同一件事的两段。
 * 「下载中 · ↓ 12.4 MB/s · 剩 6 分钟」；入库时「正在入库 · 整理文件」。
 */
export function ActiveDownloadRow({
  group,
  ingestJobsByHash,
}: {
  group: DownloadTaskGroup;
  ingestJobsByHash: Map<string, JobView>;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const task = group.tasks[0];
  const ingestJob = ingestJobsByHash.get(task.info_hash.toLowerCase()) ?? null;
  const ingesting = ingestOwnsTaskState(task, ingestJob) && ingestJob != null;
  const meta = ingesting ? ingestStateMeta(ingestJob.status, locale) : downloadStateMeta(task.state, locale);
  const percent = ingesting
    ? ingestJob.progress.percent
    : task.progress == null
      ? null
      : task.progress * 100;
  const status = [
    meta.label,
    ...(ingesting
      ? [ingestJob.progress.message]
      : [
          (task.dlspeed_bytes ?? 0) > 0 ? `↓ ${formatBytes(task.dlspeed_bytes ?? 0)}/s` : null,
          task.state === "downloading" && (task.eta_seconds ?? 0) > 0
            ? t("activity.taskCenter.remainingShort", { duration: formatDuration(task.eta_seconds ?? 0, locale) })
            : null,
        ]),
  ].filter(Boolean);
  const Icon = ingesting || task.state === "completed" ? DownloadIcon : task.state === "downloading" ? ArrowDownIcon : ClockIcon;
  return (
    <>
      <span className="grid w-6 shrink-0 place-items-center" style={{ color: meta.color }}>
        <Icon className="size-[18px]" />
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex items-baseline gap-2">
          <span className="min-w-0 truncate text-ui font-semibold text-[var(--text)]">{group.title}</span>
          {group.tasks.length > 1 && (
            <span className="shrink-0 text-caption text-[var(--text-faint)]">{t("activity.taskCenter.resourceCount", { count: group.tasks.length })}</span>
          )}
          {percent != null && (
            <span className="tnum ml-auto shrink-0 text-sub font-semibold text-[var(--text-muted)]">
              {Math.floor(percent)}%
            </span>
          )}
        </span>
        <span className="tnum mt-0.5 block truncate text-sub text-[var(--text-muted)]">{status.join(" · ")}</span>
        {percent != null && <RowProgress percent={percent} color={meta.color} />}
      </span>
    </>
  );
}

/** 进行中的后台作业（扫描、生成字幕、整理入库……） */
export function ActiveJobRow({ job }: { job: JobView }) {
  const locale = useLocale();

  const percent = job.progress.percent;
  const status = [activeJobStatus(job, locale), job.progress.message].filter(Boolean);
  return (
    <>
      <span className="grid w-6 shrink-0 place-items-center text-[var(--info)]">
        <GearIcon className="size-[18px]" />
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex items-baseline gap-2">
          <span className="min-w-0 truncate text-ui font-semibold text-[var(--text)]">
            {jobFeedIdentity(job, locale) || jobTypeLabel(job, locale)}
          </span>
          {percent != null && (
            <span className="tnum ml-auto shrink-0 text-sub font-semibold text-[var(--text-muted)]">
              {Math.round(percent)}%
            </span>
          )}
        </span>
        <span className="mt-0.5 block truncate text-sub text-[var(--text-muted)]">{status.join(" · ")}</span>
        {percent != null && <RowProgress percent={percent} color="var(--info)" />}
      </span>
    </>
  );
}

/** 最近完成一行：结果图标 · 标题 / 摘要 · 右侧相对时间 */
export function FinishedJobRow({ job }: { job: JobView }) {
  const locale = useLocale();

  const succeeded = job.status === "succeeded";
  return (
    <>
      <span
        className={`grid w-6 shrink-0 place-items-center ${succeeded ? "text-[var(--ok)]" : "text-[var(--text-faint)]"}`}
      >
        {succeeded ? <CheckIcon className="size-[18px]" /> : <XIcon className="size-[18px]" />}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-ui font-semibold text-[var(--text)]">{historicalJobTitle(job, locale)}</span>
        <span className="mt-0.5 block truncate text-sub text-[var(--text-muted)]">
          {buildIngestHistoryDetail(job, locale)?.summary ?? historicalJobSummary(job, locale)}
        </span>
      </span>
      <span className="shrink-0 text-sub text-[var(--text-faint)]">
        {formatRelativeTime(job.finished_at || job.created_at, locale)}
      </span>
    </>
  );
}

function EmptyView({ view }: { view: TaskCenterViewName }) {
  const t = useTranslations();

  const copy: Record<TaskCenterViewName, { title: string; note: string }> = {
    all: { title: t("activity.taskCenter.emptyAll"), note: t("activity.taskCenter.emptyAllHint") },
    attention: { title: t("activity.taskCenter.emptyAttention"), note: t("activity.taskCenter.emptyAttentionHint") },
    active: { title: t("activity.taskCenter.emptyActive"), note: t("activity.taskCenter.emptyActiveHint") },
    history: {
      title: t("activity.taskCenter.emptyHistory"),
      note: t("activity.taskCenter.emptyHistoryHint"),
    },
  };
  return (
    <div className="solid-card mt-8 rounded-2xl border border-white/[0.07] bg-black/20 px-6 py-16 text-center backdrop-blur-xl">
      <p className="text-title-sm font-semibold text-white/75">{copy[view].title}</p>
      <p className="mt-2 text-ui text-[var(--text-muted)]">{copy[view].note}</p>
    </div>
  );
}
