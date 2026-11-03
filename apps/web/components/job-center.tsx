"use client";

import { useLocale, useTranslations } from "next-intl";

import {
  jobTypeLabel, detailStrings, subtitleLanguageLabel, subtitleUsageSummary,
  formatInteger, formatModelDuration, originLabel, progressAmount,
  jobDetailItems, jobPhaseLabel, jobStatusLabel,
} from "@/lib/job-presentation";
import { useMessageState } from "@/lib/i18n/use-message-state";

import type { AppMessageKey } from "@/lib/i18n/translate";

import { useState } from "react";

import type { Route } from "next";
import { useRouter } from "next/navigation";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";

import {
  ActivityIcon,
  ChevronRightIcon,
  MoreIcon,
} from "@/components/icons";
import { useLlmCapability } from "@/components/llm-gate";
import { Modal } from "@/components/modal";
import { OverflowText } from "@/components/overflow-text";
import { useAgentConversations } from "@/lib/agent-conversations";
import { fetchHandoffPrompt } from "@/lib/api/handoff";
import {
  cancelJob,
  dismissJob,
  isSystemCancelled,
  retryJob,
  undismissJob,
  type JobStatus,
  type JobView,
} from "@/lib/api/jobs";
import { isDismissed, jobCancellable } from "@/lib/job-attention";

import { useJobs } from "@/lib/jobs";
import { taskActivityBadge, useTaskActivity } from "@/lib/task-activity";
import { formatDateTime, formatRelativeTime } from "@/lib/time";
import { usePermissions } from "@/lib/permissions";

export { jobTypeLabel, jobDetailItems, jobStatusLabel } from "@/lib/job-presentation";

const STATUS_STYLE: Record<JobStatus, { dot: string; border?: string }> = {
  queued: { dot: "bg-white/40" },
  running: { dot: "animate-pulse bg-[var(--info)]" },
  retry_wait: { dot: "bg-[var(--warn)]" },
  cancelling: { dot: "bg-[var(--warn)]" },
  waiting: { dot: "bg-white/40" },
  blocked: {
    dot: "bg-[var(--danger)]",
    border: "border-[var(--danger)]/20",
  },
  succeeded: { dot: "bg-[var(--ok)]" },
  failed: {
    dot: "bg-[var(--danger)]",
    border: "border-[var(--danger)]/20",
  },
  cancelled: { dot: "bg-white/30" },
};

const SUPPORTED_ACTIONS = new Set([
  "retry_job",
  "open_settings",
  "inspect_logs",
  "update_runtime",
  "handoff_agent",
]);

/** 任务中心统一状态点：紧贴标题展示状态，完整文字通过 title 与无障碍标签保留。 */
export function TaskStatusDot({
  label,
  dotClass,
}: {
  label: string;
  dotClass: string;
}) {
  const t = useTranslations();

  return (
    <span
      title={label}
      role="img"
      aria-label={t("activity.jobs.statusAria", { label })}
      className={`size-2.5 shrink-0 rounded-full ${dotClass}`}
    >
      <span className="sr-only">{label}</span>
    </span>
  );
}

interface TaskActionMenuItem {
  id: string;
  label: string;
  onSelect: () => void;
  disabled?: boolean;
  tone?: "default" | "danger";
}

/** 标准任务卡片操作入口：固定在右上角，避免不同任务类型各自发明布局。 */
export function TaskActionsMenu({
  ariaLabel,
  disabled = false,
  items,
  header,
}: {
  ariaLabel: string;
  disabled?: boolean;
  items: TaskActionMenuItem[];
  /**
   * 菜单顶部的说明（不可点）：活动页正在播放行用它放「为什么是硬件转码」——对齐原生 App
   * 长按菜单顶部的说明分组（NowPlayingRows.swift）。
   */
  header?: { title: string; body: string } | null;
}) {
  const itemClass =
    "glass-row nav-item cursor-pointer px-3 py-2 text-sub font-medium outline-none " +
    "data-[highlighted]:!bg-[var(--glass-fill-hover)] data-[disabled]:pointer-events-none " +
    "data-[disabled]:opacity-40";

  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          aria-label={ariaLabel}
          disabled={disabled}
          className="glass-row flex size-7 !w-7 items-center justify-center p-0 text-white/55 data-[state=open]:!bg-[var(--glass-fill-active)] data-[state=open]:!text-[var(--text)] disabled:opacity-40"
        >
          <MoreIcon className="size-4 max-md:size-5" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          collisionPadding={12}
          className="menu-surface z-50 min-w-[9rem] p-1"
        >
          {header && (
            <>
              <DropdownMenu.Label className="max-w-[17rem] px-3 pb-2 pt-1.5">
                <span className="block text-caption font-semibold text-white/55">{header.title}</span>
                <span className="mt-0.5 block text-caption leading-5 text-white/45">{header.body}</span>
              </DropdownMenu.Label>
              <DropdownMenu.Separator className="mx-2 mb-1 h-px bg-white/[0.08]" />
            </>
          )}
          {items.map((item) => (
            <DropdownMenu.Item
              key={item.id}
              onSelect={item.onSelect}
              disabled={item.disabled}
              className={`${itemClass} ${
                item.tone === "danger"
                  ? // 危险项字色消费 --danger：银玻璃 :root 同值（#ff6b6b）零变化，
                    // Netflix 主题取与品牌红刻意区分的状态红 #eb3942
                    "!text-[var(--danger)] data-[highlighted]:!bg-[var(--danger)]/10"
                  : "text-white/75"
              }`}
            >
              {item.label}
            </DropdownMenu.Item>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

function StatusDot({ status }: { status: JobStatus }) {
  const locale = useLocale();

  const style = STATUS_STYLE[status];
  return (
    <TaskStatusDot
      label={jobStatusLabel(status, locale)}
      dotClass={style.dot}
    />
  );
}

export function JobCard({ job, onNavigate }: { job: JobView; onNavigate: () => void }) {
  const locale = useLocale();
  const t = useTranslations();

  const router = useRouter();
  const { start: startAgent } = useAgentConversations();
  const { upsert } = useJobs();
  const { state: llmState } = useLlmCapability();
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [actionError, setActionError] = useMessageState();
  const [usageExpanded, setUsageExpanded] = useState(false);
  const [dismissOpen, setDismissOpen] = useState(false);
  const executing = job.status === "running" || job.status === "cancelling";
  const waitingProgress = job.progress.mode === "waiting";
  // 「需要处理」是**当下要不要用户动手**，不是"这件事失败过"。用户已经拍板
  // 不处理，红框与「需要处理：」前缀就该一起撤下——否则忽略了还在报警，
  // 等于没忽略。失败这个事实由状态点与摘要文案继续如实承担。
  const attention =
    (job.status === "blocked" || job.status === "failed") && !isDismissed(job);
  const cancellable = jobCancellable(job);
  // 忽略只开给失败任务：其余状态各有正确出口，不该被"藏起来"顶替。活跃任务
  // （含 blocked）要真正终结得走取消——它们仍占着去重键与资源锁，光藏掉提醒
  // 会留下一个谁也看不见、却挡着同名任务再次创建的幽灵。
  const dismissable = job.status === "failed" && !isDismissed(job);
  const dismissed = isDismissed(job);
  const percent = job.progress.percent;
  const statusStyle = STATUS_STYLE[job.status];
  const details = jobDetailItems(job, locale);
  const importedFiles =
    job.job_type === "library.ingest"
      ? detailStrings(job.progress.details, "imported_files")
      : [];
  const hasDomainAlert = details.some((item) => item.alert);
  const subtitleUsage = subtitleUsageSummary(job);
  const compact =
    (job.status === "succeeded" || job.status === "cancelled") && !hasDomainAlert;
  const cardBorder =
    statusStyle.border ?? (hasDomainAlert ? "border-amber-300/15" : "border-white/[0.08]");
  const progressAccent =
    job.status === "succeeded"
      ? "bg-[var(--ok)]"
      : job.status === "failed" || job.status === "blocked"
        ? "bg-[var(--danger)]"
        : job.status === "retry_wait" || job.status === "cancelling"
          ? "bg-[var(--warn)]"
          : "bg-[var(--info)]";
  const amount = progressAmount(job, locale);
  const phase = jobPhaseLabel(job.progress.phase, locale);
  const phaseStep =
    job.progress.phase_index != null && job.progress.phase_count != null
      ? `${job.progress.phase_index}/${job.progress.phase_count}`
      : null;
  const typeLabel = jobTypeLabel(job, locale);
  const title = job.subject || typeLabel;
  const completedSubtitleLanguage =
    job.status === "succeeded" ? subtitleLanguageLabel(job, locale) : null;
  const completedLibraryScan =
    job.job_type === "library.scan" && job.status === "succeeded";
  const summaryMessage = completedSubtitleLanguage
    ? t("activity.jobs.generatedSubtitles", { language: completedSubtitleLanguage })
    : job.error?.message ?? job.progress.message;
  const actions = (job.error?.actions ?? []).filter(
    (action) =>
      SUPPORTED_ACTIONS.has(action.type) &&
      (action.type !== "handoff_agent" ||
        llmState === "configured" ||
        llmState === "unavailable"),
  );
  if (
    job.status === "cancelled" &&
    !isSystemCancelled(job) &&
    !actions.some((action) => action.type === "retry_job")
  ) {
    actions.unshift({ type: "retry_job", label: t("activity.jobs.retryAction") });
  }

  async function runAction(type: string, target?: string) {
    setBusyAction(type);
    setActionError(null);
    try {
      if (type === "retry_job") {
        upsert(await retryJob(job.id));
        return;
      }
      if (type === "handoff_agent") {
        // 工单由后端组装：带任务事件时间线、关联条目/种子的现场自检、与界面
        // 一致的动作清单。前端只拼标题的话，Agent 看到的和用户一样少
        const { prompt } = await fetchHandoffPrompt("job", job.id);
        const sessionId = await startAgent(prompt);
        onNavigate();
        router.push(`/sessions/${sessionId}` as Route);
        return;
      }
      const section =
        type === "inspect_logs"
          ? "logs"
          : type === "update_runtime"
            ? "app"
            : target || "app";
      onNavigate();
      router.push(`/settings/${section}` as Route);
    } catch (error) {
      setActionError((error as Error).message || { key: "activity.jobs.actionFailed" });
    } finally {
      setBusyAction(null);
    }
  }

  async function dismissCurrentJob(muteSource: boolean) {
    setBusyAction("dismiss");
    setActionError(null);
    try {
      upsert(await dismissJob(job.id, muteSource));
      setDismissOpen(false);
    } catch (error) {
      setActionError((error as Error).message || { key: "activity.jobs.dismissFailed" });
    } finally {
      setBusyAction(null);
    }
  }

  async function undismissCurrentJob() {
    setBusyAction("undismiss");
    setActionError(null);
    try {
      upsert(await undismissJob(job.id));
    } catch (error) {
      setActionError((error as Error).message || { key: "activity.jobs.restoreFailed" });
    } finally {
      setBusyAction(null);
    }
  }

  async function cancelCurrentJob() {
    setBusyAction("cancel");
    setActionError(null);
    try {
      upsert(await cancelJob(job.id));
    } catch (error) {
      setActionError((error as Error).message || { key: "activity.jobs.cancelFailed" });
    } finally {
      setBusyAction(null);
    }
  }

  const menuItems: TaskActionMenuItem[] = [
    ...(cancellable
      ? [
          {
            id: "cancel",
            label: busyAction === "cancel" ? t("activity.jobs.cancellingAction") : t("activity.jobs.cancelAction"),
            onSelect: () => void cancelCurrentJob(),
          },
        ]
      : []),
    ...actions.map((action) => ({
      id: `${action.type}:${action.target ?? ""}`,
      label: busyAction === action.type ? t("activity.jobs.processingAction") : action.label,
      onSelect: () => void runAction(action.type, action.target),
    })),
    // 「忽略」排在补救动作之后：先给出路（重试 / 看日志 / 交给 Agent），
    // 最后才给出口。这是用户在此前唯一缺的那一项——失败任务没有任何办法
    // 从「需要处理」里下架，红角标于是永不熄灭（issue #221）。
    ...(dismissable
      ? [
          {
            id: "dismiss",
            label: t("activity.jobs.dismissAction"),
            onSelect: () => setDismissOpen(true),
          },
        ]
      : []),
    ...(dismissed
      ? [
          {
            id: "undismiss",
            label: busyAction === "undismiss" ? t("activity.jobs.restoringAction") : t("activity.jobs.restoreAction"),
            onSelect: () => void undismissCurrentJob(),
          },
        ]
      : []),
  ];

  return (
    // solid-card：Netflix 主题换皮钩子（globals.css netflix 块，只接管描边色/
    // 实底/投影，银玻璃下无基样式零变化）。任务中心同页下载卡已挂（
    // task-center-view.tsx），这是漏掉的同一批卡面；状态色描边变体照钩子
    // 约定让位给实底+--line 材质，状态信号仍由 StatusDot 承担。
    <article
      className={`solid-card overflow-hidden rounded-2xl border bg-[rgba(14,16,22,0.52)] ${cardBorder} ${compact ? "px-3.5 py-2.5" : "p-4"}`}
    >
      <div className="min-w-0">
        <div className="flex items-start justify-between gap-3">
          <div className="flex min-w-0 flex-1 items-center gap-2.5">
            <StatusDot status={job.status} />
            {/* 发丝描边消费 --line：银玻璃 :root 同值（白 0.08）零变化，
                Netflix 主题自动取实线灰 */}
            {job.subject && (
              <span className="shrink-0 rounded-md border border-[var(--line)] bg-white/[0.045] px-1.5 py-0.5 text-micro font-medium text-white/55">
                {typeLabel}
              </span>
            )}
            <h3 className="min-w-0 text-ui font-semibold leading-5 text-white/90">
              <OverflowText>{title}</OverflowText>
            </h3>
          </div>
          {menuItems.length > 0 && (
            <TaskActionsMenu
              ariaLabel={t("activity.jobs.moreActions", { title })}
              disabled={busyAction !== null}
              items={menuItems}
            />
          )}
        </div>

        <div
          className={`${compact ? "mt-1 text-caption leading-5" : "mt-2.5 text-sub leading-5"} ${
            attention
              ? "rounded-xl border border-[var(--danger)]/15 bg-[var(--danger)]/[0.06] px-3 py-2.5 text-[var(--danger)]"
              : compact
                ? "text-white/50"
                : "text-white/60"
          }`}
        >
          <OverflowText
            lines={compact ? 1 : 2}
            className={compact ? "break-words" : "min-h-10 break-words"}
            tooltipContent={
              <span className="whitespace-pre-wrap break-words [overflow-wrap:anywhere]">
                {attention && <span className="mr-1.5 font-semibold">{t("activity.jobs.attentionPrefix")}</span>}
                {summaryMessage}
              </span>
            }
          >
            {attention && <span className="mr-1.5 font-semibold">{t("activity.jobs.attentionPrefix")}</span>}
            {summaryMessage}
          </OverflowText>
        </div>

        {importedFiles.length > 0 && (
          <IngestImportedFiles files={importedFiles} />
        )}

        {!compact &&
          !completedLibraryScan &&
          (percent != null || executing || job.status === "retry_wait") && (
            <div className="mt-3">
              <div className="mb-1.5 flex items-center justify-between gap-3 text-caption">
                <OverflowText className="font-medium text-white/60">
                  {phase}
                  {phaseStep && <span className="ml-1.5 text-white/30">{t("activity.jobs.phaseStep", { step: phaseStep })}</span>}
                </OverflowText>
                <span className="tnum shrink-0 text-white/50">
                  {percent != null
                    ? `${Math.round(percent)}%`
                    : job.status === "retry_wait"
                      ? t("activity.jobs.continueWait")
                      : waitingProgress
                        ? t("activity.jobs.waiting")
                        : t("activity.jobs.processing")}
                </span>
              </div>
              <div className="h-1.5 overflow-hidden rounded-full bg-white/[0.07]">
                <div
                  className={`${progressAccent} h-full rounded-full transition-[width] duration-700 ${
                    percent == null
                      ? job.status === "retry_wait" || waitingProgress
                        ? "w-1/3 opacity-35"
                        : "w-1/3 animate-pulse opacity-70"
                      : ""
                  }`}
                  style={
                    percent == null
                      ? undefined
                      : { width: `${Math.min(100, Math.max(percent > 0 ? 1 : 0, percent))}%` }
                  }
                />
              </div>
              {(amount || job.status === "retry_wait") && (
                <p className="tnum mt-1.5 text-caption text-white/35">
                  {amount}
                  {amount && job.status === "retry_wait" ? " · " : ""}
                  {job.status === "retry_wait"
                    ? t("activity.jobs.attempt", { current: Math.max(1, job.attempt), total: job.max_attempts })
                    : ""}
                </p>
              )}
            </div>
        )}

        {!compact && details.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-1.5">
            {details.map((item) => (
              <span
                key={item.label}
                className={`min-w-0 max-w-full rounded-md border px-2 py-1 text-caption ${
                  item.alert
                    ? "border-amber-300/15 bg-amber-300/[0.05] text-amber-100/75"
                    : "border-white/[0.07] bg-white/[0.035] text-white/45"
                }`}
              >
                <OverflowText>{item.label}</OverflowText>
              </span>
            ))}
          </div>
        )}

        {subtitleUsage && (
          <div className="mt-3 border-t border-white/[0.06] pt-2.5">
            <button
              type="button"
              aria-expanded={usageExpanded}
              onClick={() => setUsageExpanded((expanded) => !expanded)}
              className="flex w-full items-center justify-between gap-3 rounded-lg px-1 py-1 text-caption text-white/50 transition hover:text-white/75"
            >
              <span className="flex items-center gap-1.5 font-medium">
                <ChevronRightIcon
                  className={`size-3.5 transition-transform ${usageExpanded ? "rotate-90" : ""}`}
                />
                {usageExpanded ? t("activity.jobs.collapseUsage") : t("activity.jobs.expandUsage")}
              </span>
              <OverflowText focusable={false} className="tnum text-right text-white/35">
                {t("activity.jobs.usageSummary", { tokens: formatInteger(subtitleUsage.totalTokens, locale), count: subtitleUsage.requests })}
              </OverflowText>
            </button>
            {usageExpanded && (
              <div className="mt-2.5 rounded-xl border border-white/[0.07] bg-black/15 p-3">
                <div className="grid grid-cols-4 gap-3 max-md:grid-cols-2">
                  <UsageMetric label={t("activity.jobs.totalTokens")} value={formatInteger(subtitleUsage.totalTokens, locale)} />
                  <UsageMetric label={t("activity.jobs.inputTokens")} value={formatInteger(subtitleUsage.promptTokens, locale)} />
                  <UsageMetric label={t("activity.jobs.outputTokens")} value={formatInteger(subtitleUsage.completionTokens, locale)} />
                  <UsageMetric label={t("activity.jobs.cacheTokens")} value={formatInteger(subtitleUsage.cacheReadTokens, locale)} />
                </div>
                <p className="mt-3 flex flex-wrap gap-x-3 gap-y-1 border-t border-white/[0.06] pt-2.5 text-caption text-white/35">
                  {job.provider_ref && <span>{job.provider_ref}</span>}
                  <span>{t("activity.jobs.modelRequests", { count: subtitleUsage.requests })}</span>
                  {subtitleUsage.failedRequests > 0 && (
                    <span className="text-amber-200/70">
                      {t("activity.jobs.failedRequests", { count: subtitleUsage.failedRequests })}
                    </span>
                  )}
                  <span>{t("activity.jobs.totalResponseTime", { duration: formatModelDuration(subtitleUsage.totalDurationMs, locale) })}</span>
                  <span>{t("activity.jobs.maxResponseTime", { duration: formatModelDuration(subtitleUsage.maxDurationMs, locale) })}</span>
                </p>
              </div>
            )}
          </div>
        )}

        {actionError && (
          // 错误文字保留 #ff9f9f 浅红字面量：:root --danger=#ff6b6b 与之不同值，
          // 收口会让银玻璃可见变化，待设计决策（与上方菜单危险项的同值收口
          // 性质不同——那是 :root 同值零变化）
          <p className="mt-2 text-caption leading-5 text-[#ff9f9f]">{actionError}</p>
        )}
      </div>
      <footer className={`${compact ? "mt-1.5" : "mt-3"} flex flex-wrap items-center gap-2`}>
        <OverflowText
          alwaysShowTooltip
          tooltipContent={`${originLabel(job, locale)} · ${formatDateTime(job.created_at)}`}
          className="text-micro text-white/25"
        >
          {originLabel(job, locale)} · {formatRelativeTime(job.created_at)}
        </OverflowText>
        {dismissed && (
          // 描边/填充换消费 token：--line 与 --glass-fill 的 :root 值与原字面量
          // 完全相同（白 0.08 / 白 0.04），银玻璃零变化，Netflix 主题自动换档
          <span className="ml-auto shrink-0 rounded-md border border-[var(--line)] bg-[var(--glass-fill)] px-1.5 py-0.5 text-micro text-white/40">
            {t("activity.jobs.dismissed")}</span>
        )}
      </footer>
      {dismissOpen && (
        <DismissJobDialog
          job={job}
          busy={busyAction === "dismiss"}
          onClose={() => {
            if (busyAction !== "dismiss") setDismissOpen(false);
          }}
          onConfirm={(muteSource) => void dismissCurrentJob(muteSource)}
        />
      )}
    </article>
  );
}

/** 有自动来源的任务类型：系统会周期性地重新建同样的任务，光忽略一次不管用。 */
const AUTO_RECREATED_JOB_TYPES: Record<string, AppMessageKey> = {
  "subtitle.generate": "activity.jobs.muteSubtitle",
};

/**
 * 忽略的二次确认。
 *
 * 这个弹窗真正要问的不是"你确定吗"，而是**忽略到哪一层**：
 *
 * - 只忽略这一条：任务从「需要处理」下架，但下一次入库扫描收尾还会为同一个
 *   文件建一条新的字幕任务、再失败一次——因为"本进程只自动试一次"是内存
 *   集合，重启即清零。用户会觉得忽略根本没生效（issue #221 的真实体验）。
 * - 连自动来源一起静音：这个决定写进数据库，跨重启有效。
 *
 * 因此对有自动来源的任务类型默认勾上——用户既然说了不处理，多半也不想每周
 * 再被同一件事叫醒一次；手动触发始终不受影响，随时可以自己再试。
 */
function DismissJobDialog({
  job,
  busy,
  onClose,
  onConfirm,
}: {
  job: JobView;
  busy: boolean;
  onClose: () => void;
  onConfirm: (muteSource: boolean) => void;
}) {
  const locale = useLocale();
  const t = useTranslations();

  const muteLabel = Object.hasOwn(AUTO_RECREATED_JOB_TYPES, job.job_type) ? AUTO_RECREATED_JOB_TYPES[job.job_type] : undefined;
  const [muteSource, setMuteSource] = useState(muteLabel != null);
  const title = job.subject || jobTypeLabel(job, locale);

  return (
    <Modal open onClose={busy ? () => {} : onClose} label={t("activity.jobs.dismissDialog")} topmost>
      <div className="p-6 max-md:p-5">
        <h2 className="text-title-sm font-bold text-white">{t("activity.jobs.dismissTitle")}</h2>
        <p className="mt-2 text-sub leading-6 text-[var(--text-muted)]">
          {t("activity.jobs.dismissHint")}</p>
        <p className="mt-3 break-words rounded-xl border border-white/[0.08] bg-white/[0.035] px-3.5 py-3 text-sub leading-6 text-white/75">
          {title}
        </p>
        {muteLabel && (
          <label
            className={`mt-4 flex cursor-pointer items-start gap-3 rounded-xl border px-3.5 py-3 transition ${
              muteSource
                ? "border-white/[0.16] bg-white/[0.07]"
                : "border-white/[0.08] bg-white/[0.025] hover:bg-white/[0.045]"
            }`}
          >
            <input
              type="checkbox"
              checked={muteSource}
              onChange={(event) => setMuteSource(event.target.checked)}
              className="mt-1 size-4 shrink-0 accent-white/70"
            />
            <span className="min-w-0">
              <span className="block text-ui font-semibold text-white/90">{t(muteLabel)}</span>
              <span className="mt-0.5 block text-caption leading-5 text-white/50">
                {t("activity.jobs.muteHint")}</span>
            </span>
          </label>
        )}
        <div className="mt-5 flex justify-end gap-2.5">
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="rounded-lg border border-white/10 bg-white/[0.06] px-4 py-2 text-ui text-white/80 transition hover:bg-white/[0.1] disabled:opacity-40"
          >
            {t("activity.jobs.cancel")}</button>
          <button
            type="button"
            onClick={() => onConfirm(muteSource)}
            disabled={busy}
            className="rounded-lg bg-white/90 px-4 py-2 text-ui font-medium text-black transition hover:bg-white disabled:opacity-40"
          >
            {busy ? t("activity.jobs.dismissing") : t("activity.jobs.dismiss")}
          </button>
        </div>
      </div>
    </Modal>
  );
}

/** 本次作业实际新增的文件：单文件直接展示，多文件保留首项并允许展开核对。 */
function IngestImportedFiles({ files }: { files: string[] }) {
  const t = useTranslations();

  if (files.length === 1) {
    return (
      <p className="mt-2.5 flex min-w-0 items-center gap-2 rounded-lg border border-white/[0.07] bg-white/[0.03] px-3 py-2 text-caption">
        <span className="shrink-0 text-white/40">{t("activity.jobs.importedFile")}</span>
        <OverflowText className="font-medium text-white/65">{files[0]}</OverflowText>
      </p>
    );
  }

  return (
    <details className="group mt-2.5 rounded-lg border border-white/[0.07] bg-white/[0.03]">
      <summary className="flex cursor-pointer list-none items-center gap-2 px-3 py-2 text-caption [&::-webkit-details-marker]:hidden">
        <ChevronRightIcon className="size-3.5 shrink-0 transition-transform group-open:rotate-90" />
        <span className="shrink-0 text-white/40">{t("activity.jobs.importedFiles", { count: files.length })}</span>
        <OverflowText className="font-medium text-white/65">{files[0]}</OverflowText>
      </summary>
      <ul className="space-y-1 border-t border-white/[0.06] px-3 py-2.5 text-caption text-white/55">
        {files.map((file) => (
          <li key={file} title={file} className="break-all">
            {file}
          </li>
        ))}
      </ul>
    </details>
  );
}

function UsageMetric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-micro text-white/30">{label}</p>
      <p className="tnum mt-1 text-sub font-semibold text-white/70">{value}</p>
    </div>
  );
}

/**
 * 侧栏「活动」入口（只在银玻璃渲染；Netflix 主题的侧栏只在设置里出现）。
 *
 * 角标只表达**当前最该被看见的那件事**：有失败/阻塞的任务时亮警示色，只有进行中
 * 任务时亮提示色。点击一律落活动总览——需要处理与进行中就排在总览最上面，与手机
 * 底栏页签、原生 App 同一落点。不直达 `?view=active` 二级页：那样历史里没有总览，
 * 二级页的返回键会退回上一个标签页（#1100）；已在二级页时再点也能回到总览。
 * Netflix 两段版式没有二级页，那里的入口仍按 badge.href 选中「任务」段。
 *
 * 计数走 useTaskActivity 这份共享口径，与活动页里的数字保证一致。
 */
export function JobCenter({ collapsed, active = false }: { collapsed: boolean; active?: boolean }) {
  const t = useTranslations();
  const locale = useLocale();
  const router = useRouter();
  const { isAdmin } = usePermissions();
  const activity = useTaskActivity();
  if (!isAdmin) return null;
  const { alert, count: badgeCount, hint } = taskActivityBadge(activity, locale);
  return (
    <button
      type="button"
      onClick={() => router.push("/activity" as Route)}
      data-active={active}
      title={collapsed ? t("nav.badges.activityHint", { hint }) : undefined}
      className={`glass-row nav-item py-2 max-md:py-2.5 ${collapsed ? "justify-center px-0" : "px-3"}`}
    >
      <span className="relative shrink-0">
        <ActivityIcon className="size-[18px] max-md:size-[22px]" />
        {badgeCount > 0 && (
          <span
            className={`absolute -right-1 -top-1 size-2 rounded-full ${
              alert ? "bg-[var(--danger)]" : "bg-[var(--info)]"
            }`}
          />
        )}
      </span>
      {!collapsed && (
        <>
          <span className="flex-1 text-ui font-medium">{t("nav.main.activity")}</span>
          {badgeCount > 0 && (
            <span
              className={`rounded-full px-1.5 py-0.5 text-[11px] font-semibold leading-none ${
                alert
                  ? "bg-[var(--danger)]/20 text-[var(--danger)]"
                  : "bg-[var(--info)]/20 text-[var(--info)]"
              }`}
            >
              {badgeCount}
            </span>
          )}
        </>
      )}
    </button>
  );
}
