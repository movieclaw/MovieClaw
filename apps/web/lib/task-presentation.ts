import { appTranslator, type AppMessageKey } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";
import type { DownloadTask } from "./api/downloaders";
import type { JobView, JobStatus } from "./api/jobs";
import { formatBytes } from "./format.ts";
import { jobTypeLabel, jobStatusLabel } from "./job-presentation.ts";
import { isDismissed, jobNeedsAttention, ACTIVE_FEED_JOB_STATUSES } from "./job-attention.ts";
import { contentMissingLabel } from "./download-attention.ts";
import { formatTimelineDayLabel, timelineDayKey } from "./time.ts";


const ACTIVE_JOB_ACTIONS: Record<string, AppMessageKey> = {
  "subtitle.generate": "activity.runningJobs.subtitles",
  "library.scan": "activity.runningJobs.scan",
  "library.metadata.refresh": "activity.runningJobs.libraryMetadata",
  "media.metadata.refresh": "activity.runningJobs.mediaMetadata",
  "library.chapter_images": "activity.runningJobs.chapters",
  "library.skip_segments": "activity.runningJobs.skipSegments",
  "media.skip_segments": "activity.runningJobs.skipSegments",
  "reels.clips": "activity.runningJobs.clips",
  "library.organize": "activity.runningJobs.organize",
  "library.transfer": "activity.runningJobs.transfer",
  "library.ingest": "activity.runningJobs.ingest",
  "drive.upload": "activity.runningJobs.upload",
};


const COMPLETED_JOB_ACTIONS: Record<string, AppMessageKey> = {
  "subtitle.generate": "activity.finishedJobs.subtitles",
  "library.scan": "activity.finishedJobs.scan",
  "library.metadata.refresh": "activity.finishedJobs.metadata",
  "media.metadata.refresh": "activity.finishedJobs.metadata",
  "library.chapter_images": "activity.finishedJobs.chapters",
  "library.skip_segments": "activity.finishedJobs.skipSegments",
  "media.skip_segments": "activity.finishedJobs.skipSegments",
  "reels.clips": "activity.finishedJobs.clips",
  "library.organize": "activity.finishedJobs.organize",
  "library.transfer": "activity.finishedJobs.transfer",
  "library.ingest": "activity.finishedJobs.ingest",
  "drive.upload": "activity.finishedJobs.upload",
};


function jobDetailString(job: JobView, key: string): string | null {
  const detail = job.progress.details[key] ?? job.input_data[key];
  return typeof detail === "string" && detail ? detail : null;
}


function jobDetailNumber(job: JobView, key: string): number | null {
  const detail = job.progress.details[key];
  return typeof detail === "number" && Number.isFinite(detail) ? detail : null;
}


/** Feed 主标题优先使用执行结果确认过的作品名，避免把长 release 名当业务标题。 */
export function jobFeedIdentity(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  const t = appTranslator(locale);
  const titleParam = job.progress.message_params?.title;
  const structuredTitle = typeof titleParam === "string" && titleParam ? titleParam : null;
  // Existing unmarked histories keep their original quote-based title fallback.
  const quotedTitle = job.progress.message.match(/《([^》]+)》/)?.[1] ?? null;
  const title = structuredTitle || quotedTitle || jobDetailString(job, "media_title") || jobDetailString(job, "title") || job.subject;
  if (!title) return null;
  // i18n-ignore: legacy built-in subject; custom subjects and plugin names remain raw.
  if (job.job_type === "library.search-index.refresh" && title === "更新媒体库搜索索引") return t("activity.tasks.refreshSearchIndex");
  // i18n-ignore: legacy built-in subject; custom subjects remain raw.
  if (job.job_type === "library.duplicate-scan" && title === "重复文件") return t("library.manage.duplicates");
  if (/^[《「].+[》」]$/.test(title)) return title;
  if (job.job_type === "library.scan") return t("activity.tasks.libraryTitle", { title });
  if (job.job_type === "library.ingest" || job.job_type === "subtitle.generate" || job.job_type.includes("metadata.refresh")) return t("activity.tasks.mediaTitle", { title });
  return title;
}


export function jobProgressAmount(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  const t = appTranslator(locale);
  const { current, total } = job.progress;
  if (current == null || total == null) return null;
  if (job.job_type === "library.ingest") return t("activity.tasks.processedBytes", { current: formatBytes(current), total: formatBytes(total) });
  const unit = job.job_type === "subtitle.generate" ? "subtitles" : job.job_type === "library.scan" ? "files" : job.job_type === "media.metadata.refresh" ? "images" : job.job_type === "library.metadata.refresh" ? "items" : "other";
  return t("activity.tasks.processedProgress", { current, total, unit });
}


export function jobOriginLabel(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const origin =
    job.origin === "cli"
      ? t("activity.tasks.originCli")
      : job.origin === "agent"
        ? t("activity.tasks.originAgent")
        : job.origin === "scheduler" || job.origin === "system"
          ? t("activity.jobs.originSystem")
          : t("activity.tasks.originWeb");
  return job.actor_name ? `${origin} · ${job.actor_name}` : origin;
}


export function activeJobStatus(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  if (job.status === "running") {
    return Object.hasOwn(ACTIVE_JOB_ACTIONS, job.job_type) ? t(ACTIVE_JOB_ACTIONS[job.job_type]) : t("activity.tasks.working");
  }
  return jobStatusLabel(job.status, locale);
}


export function historicalJobTitle(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const identity = jobFeedIdentity(job, locale);
  const action = Object.hasOwn(COMPLETED_JOB_ACTIONS, job.job_type) ? t(COMPLETED_JOB_ACTIONS[job.job_type]) : null;
  return t("activity.tasks.historicalTitle", { identity: identity || jobTypeLabel(job, locale), hasAction: identity && action ? "yes" : "no", action: action ?? "", result: job.status });
}


export function historicalJobSummary(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  if (job.job_type === "library.scan") {
    const identified = jobDetailNumber(job, "identified");
    const unidentified = jobDetailNumber(job, "unidentified");
    const parts = [
      identified != null ? t("activity.jobs.identified", { count: identified }) : null,
      unidentified != null ? t("activity.jobs.unidentified", { count: unidentified }) : null,
    ].filter((item): item is string => item != null);
    if (parts.length > 0) return parts.join(" · ");
  }
  if (job.status === "failed" && isDismissed(job)) {
    return job.error?.message || job.progress.message || t("activity.tasks.failedDismissed");
  }
  return job.progress.message || (job.status === "cancelled" ? t("activity.tasks.cancelled") : t("activity.tasks.completed"));
}


interface HistoryDayGroup {
  key: string;
  label: string;
  jobs: JobView[];
}


export function groupHistoricalJobs(jobs: JobView[], locale: AppLocale = requestLocale() ?? "zh-Hans"): HistoryDayGroup[] {
  const groups = new Map<string, HistoryDayGroup>();
  for (const job of jobs) {
    const timestamp = job.finished_at || job.created_at;
    const key = timelineDayKey(timestamp);
    const existing = groups.get(key);
    if (existing) {
      existing.jobs.push(job);
    } else {
      groups.set(key, { key, label: formatTimelineDayLabel(timestamp, undefined, locale), jobs: [job] });
    }
  }
  return [...groups.values()];
}


/**
 * 按逐集工单汇总任务的交付进度；没有订阅上下文（手动/外部任务）时为 null。
 *
 * 补缺下载数「已入库」，洗版数「已替换」。洗版单元在投递那一刻就全是
 * imported（库里有旧版本），继续按 imported 汇总会让刚投递的种子直接显示
 * 「已入库 16/16 集、入库完成」，与 0% 的下载进度自相矛盾（真实教训）。
 */
function ingestUnitSummary(
  task: DownloadTask,
): { done: number; total: number; upgrade: boolean } | null {
  const subscription = task.subscriptions[0];
  if (!subscription || subscription.units.length === 0) return null;
  const upgrade = subscription.purpose === "upgrade";
  return {
    done: subscription.units.filter((unit) => (upgrade ? unit.replaced : unit.status === "imported"))
      .length,
    total: subscription.units.length,
    upgrade,
  };
}


/** 多集资源分批交付时的「已入库/已替换 N/M 集」；单集与电影没有分批语义，返回 null。 */
function partialIngestLabel(task: DownloadTask, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  const t = appTranslator(locale);
  const summary = ingestUnitSummary(task);
  if (summary == null || summary.total <= 1) return null;
  return t("activity.lifecycle.partialUnits", { upgrade: summary.upgrade ? "yes" : "no", done: summary.done, total: summary.total });
}


export type LifecycleTone = "done" | "current" | "waiting" | "attention" | "future";


interface LifecycleStep {
  label: string;
  detail: string;
  tone: LifecycleTone;
}


/**
 * 下载完成后**还没发生**的那几步，按后端推导的落点如实展开。
 *
 * 取代原来那句「等待入库 · 下一步」——它对每条任务都一样，等于没说。后端的
 * plan 来自投递/预检共用的 resolve_save_path，所以这里预告的搬运方式与落点
 * 就是真正会发生的事；推不出落点时才退回原来的兜底话术。
 *
 * 只在"什么都还没开始"时使用：一旦入库 Job 出现，事实源就是 Job 本身，
 * 步骤链收回到观测态，不再拿预测覆盖已经发生的事。
 */
function plannedSteps(
  task: DownloadTask,
  { downloaded, upgrade, keepOld }: { downloaded: boolean; upgrade: boolean; keepOld: boolean }, locale: AppLocale = requestLocale() ?? "zh-Hans"
): LifecycleStep[] {
  const t = appTranslator(locale);
  const plan = task.plan;
  if (!plan) {
    return [
      { label: downloaded ? t("activity.lifecycle.waitImport") : t("activity.lifecycle.waitDownload"), detail: t("activity.lifecycle.next"), tone: "future" },
    ];
  }
  if (plan.mode === "downloader_default") {
    // 唯一需要用户动手的分支：说清楚"不会自动发生"，别让它看着像在等
    return [
      {
        label: t("activity.lifecycle.noAutoImport"),
        detail: t("activity.lifecycle.noAutoImportHint"),
        tone: "attention",
      },
    ];
  }
  // 库未定：命中的是按 kind 的自动路由规则，识别出作品后才按收藏范围选库
  const libraryText = plan.library_name
    ? t("activity.lifecycle.namedLibrary", { name: plan.library_name })
    : t("activity.lifecycle.matchedLibrary");
  const steps: LifecycleStep[] = [];

  if (plan.mode === "watch") {
    // 搬运方式完全由监听规则的策略决定，不猜：拿不到策略时只说"整理"，绝不
    // 默认成某一种——复制与硬链接对磁盘占用的含义完全不同

    // 路径归搬运步骤、库名归入库步骤：各自回答"文件去哪"与"算进哪个库"，
    // 同一条链里不重复同一个库名
    steps.push({
      label: t("activity.lifecycle.pendingTransfer", { strategy: plan.strategy ?? "other" }),
      detail: plan.dest_path ? t("activity.lifecycle.transferTarget", { strategy: plan.strategy ?? "other", hasPath: "yes", path: plan.dest_path }) : t("activity.lifecycle.transferTarget", { strategy: plan.strategy ?? "other", hasPath: "no", path: "" }),
      tone: "future",
    });
  }

  if (!plan.enters_library) {
    // 自定义目录规则：整理完就结束了，后面没有入库这一步
    steps.push({
      label: t("activity.lifecycle.noDirectImport"),
      detail: t("activity.lifecycle.noDirectImportHint"),
      tone: "future",
    });
    return steps;
  }

  steps.push({
    label: t("activity.lifecycle.pendingImport"),
    detail:
      plan.mode === "inplace" && plan.dest_path
        ? t("activity.lifecycle.scanIntoLibrary", { library: libraryText, path: plan.dest_path })
        : t("activity.lifecycle.importAndScrape", { library: libraryText }),
    tone: "future",
  });

  // 洗版的终点不是入库：新版本入库后还要比对档位，确认更优才替换掉旧版本
  // （校验不通过会保留旧版本），是与入库分开的一次真实事件
  if (upgrade) {
    steps.push({
      label: t("activity.lifecycle.pendingReplace"),
      detail: t("activity.lifecycle.verifyReplacement", { library: libraryText }),
      tone: "future",
    });
    // 替换真正对磁盘做的事：默认把旧版本移入回收站等待过期清理；开了收藏家
    // 模式则多版本共存。这一步决定的是"要不要多占一份空间"，不能不说
    steps.push(
      keepOld
        ? {
            label: t("activity.lifecycle.keepOld"),
            detail: t("activity.lifecycle.keepOldHint"),
            tone: "future",
          }
        : {
            label: t("activity.lifecycle.pendingRecycle"),
            detail: t("activity.lifecycle.pendingRecycleHint"),
            tone: "future",
          },
    );
  }
  return steps;
}

export function downloadLifecycleSteps(task: DownloadTask, ingestJob: JobView | null, locale: AppLocale = requestLocale() ?? "zh-Hans"): LifecycleStep[] {
  const t = appTranslator(locale);
  // 下载轴只认下载器：存在入库 Job 不等于下载完成——边下边入库会在 19% 时就
  // 搬走已完整落盘的那一集
  const downloaded = task.state === "completed";
  const downloadAttention = task.state === "error" || task.state === "missing";
  const downloadWaiting = ["stalled", "paused", "queued", "unknown"].includes(task.state);
  const percent = task.progress == null ? null : Math.floor(task.progress * 100);
  const source = task.downloader_name || t("activity.tasks.downloader");
  let downloadStep: LifecycleStep;
  if (downloadAttention) {
    downloadStep = {
      label: downloadStateMeta(task.state, locale).label,
      // error 是下载器里这条任务出了问题（多半是文件缺失），下载器本身并没有坏，
      // 不能说"等待下载器恢复"——那会把用户引去检查一个正常的下载器
      detail: task.state === "missing" ? t("activity.lifecycle.waitAssociation") : t("activity.lifecycle.handleInDownloader"),
      tone: "attention",
    };
  } else if (downloaded) {
    downloadStep = {
      label: t("activity.lifecycle.downloadComplete"),
      detail: task.size_bytes == null ? t("activity.lifecycle.filesReady") : formatBytes(task.size_bytes),
      tone: "done",
    };
  } else {
    downloadStep = {
      label: downloadStateMeta(task.state, locale).label,
      detail: percent == null ? t("activity.lifecycle.readProgress") : `${percent}%`,
      tone: downloadWaiting ? "waiting" : "current",
    };
  }

  // 入库进度来自工单而非 Job：分批入库的两批之间没有 Job，但「已入库 2/10
  // 集」依然成立，这一步不能因为 Job 消失就退回「等待入库」
  const partialLabel = partialIngestLabel(task, locale);
  const summary = ingestUnitSummary(task);
  const missingLabel = contentMissingLabel(task, locale);
  // 拿不到工单上下文（手动/外部任务）时不做分批判断，沿用 Job 的结论
  const fullyDelivered = summary == null || summary.done >= summary.total;
  // 洗版任务的终点是"旧版本被换掉"，入库只是中间态：新文件入库后还要经过
  // 档位校验才算替换成功，因此这一列整体改说替换
  const upgrade = summary?.upgrade === true;

  // 二选一：要么已经开始了（ingestStep，观测态），要么还没开始（futureSteps，预测态）
  let ingestStep: LifecycleStep | null = null;
  let futureSteps: LifecycleStep[] | null = null;
  if (ingestJob && jobNeedsAttention(ingestJob)) {
    ingestStep = {
      label: t("activity.lifecycle.importAttention"),
      detail: ingestJob.error?.message || ingestJob.progress.message,
      tone: "attention",
    };
  } else if (ingestJob?.status === "failed" && isDismissed(ingestJob)) {
    // 忽略了不等于没发生：这一步仍要如实讲清入库到此为止，只是不再报警，
    // 否则会掉进最后的"什么都还没开始"，把已经失败的事说成还没开始。
    ingestStep = {
      label: t("activity.lifecycle.importDismissed"),
      detail: t("activity.lifecycle.importDismissedHint"),
      tone: "waiting",
    };
  } else if (ingestJob?.status === "running") {
    ingestStep = {
      label: t("activity.lifecycle.importing"),
      detail: ingestJob.progress.message,
      tone: "current",
    };
  } else if (ingestJob && ACTIVE_FEED_JOB_STATUSES.has(ingestJob.status)) {
    ingestStep = {
      label: ingestStateMeta(ingestJob.status, locale).label,
      detail: ingestJob.progress.message,
      tone: "waiting",
    };
  } else if (missingLabel != null) {
    // 种子里根本没有这一集：继续等这个任务没有意义，说清事实并交代去向
    ingestStep = {
      label: t("activity.lifecycle.contentMismatch"),
      detail: t("activity.lifecycle.contentMissing", {
        hasPartial: partialLabel ? "yes" : "no", partial: partialLabel ?? "", label: missingLabel,
      }),
      tone: "attention",
    };
  } else if (
    (ingestJob?.status === "succeeded" && !upgrade) ||
    (summary != null && summary.done > 0)
  ) {
    // 整包下完且全部交付才算走完；分批推进期间如实说明还差几集。洗版下
    // 入库成功 ≠ 替换完成，Job succeeded 不能单独把这一步点亮
    const done = downloaded && fullyDelivered;
    ingestStep = {
      label: done
        ? upgrade
          ? t("activity.lifecycle.replaceComplete")
          : t("activity.lifecycle.importComplete")
        : upgrade
          ? t("activity.lifecycle.partialReplace")
          : t("activity.lifecycle.partialImport"),
      detail: done
        ? upgrade
          ? t("activity.lifecycle.allReplaced")
          : (ingestJob?.progress.message ?? t("activity.lifecycle.allImported"))
        : upgrade
          ? t("activity.lifecycle.partialReplaceWait", { hasPartial: partialLabel == null ? "no" : "yes", partial: partialLabel ?? "" })
          : t("activity.lifecycle.partialImportWait", { hasPartial: partialLabel == null ? "no" : "yes", partial: partialLabel ?? "" }),
      tone: done ? "done" : "waiting",
    };
  } else if (ingestJob?.status === "cancelled") {
    ingestStep = {
      label: t("activity.lifecycle.importCancelled"),
      detail: t("activity.lifecycle.waitReprocess"),
      tone: "waiting",
    };
  } else if (task.landing_error) {
    ingestStep = {
      label: t("activity.lifecycle.cannotImport"),
      detail: t("activity.lifecycle.filesInvisible"),
      tone: "attention",
    };
  } else if (upgrade) {
    ingestStep = {
      label: downloaded ? t("activity.lifecycle.waitReplace") : t("activity.lifecycle.waitDownload"),
      detail: downloaded ? t("activity.lifecycle.verifyAfterImport") : t("activity.lifecycle.next"),
      tone: "future",
    };
  } else {
    // 什么都还没开始：把剩下的路按真实配置展开，而不是笼统说"下一步"
    futureSteps = plannedSteps(task, {
      downloaded,
      upgrade,
      keepOld: task.subscriptions[0]?.upgrade_keep_old === true,
    }, locale);
  }

  const steps: LifecycleStep[] = [
    { label: t("activity.lifecycle.dispatched"), detail: source, tone: "done" },
    downloadStep,
    ...(futureSteps ?? [ingestStep!]),
  ];
  return steps;
}


export function downloadTaskNote(
  task: DownloadTask,
  ingestJob: JobView | null, locale: AppLocale = requestLocale() ?? "zh-Hans"
): string | null {
  const t = appTranslator(locale);
  const missingLabel = contentMissingLabel(task, locale);
  if (missingLabel != null) {
    // 内容核验的结论优先于入库 Job：Job 成功搬完了包里存在的集，但用户等的
    // 那一集根本不在包里，这时说"入库已完成"是误导
    return t("activity.lifecycle.contentMissingHint", { label: missingLabel });
  }
  if (ingestJob?.status === "succeeded") {
    // 边下边入库：这一批搬完不代表整个种子搬完，剩下的集会在各自下完后
    // 自动接着入库——不能笼统说「入库已完成」
    const summary = ingestUnitSummary(task);
    if (summary != null && summary.done < summary.total) {
      return summary.upgrade
        ? t("activity.lifecycle.partialReplaceHint", { done: summary.done, total: summary.total })
        : t("activity.lifecycle.partialImportHint", { done: summary.done, total: summary.total });
    }
    if (summary?.upgrade) {
      return task.state !== "completed"
        ? t("activity.lifecycle.partialReplacedHint")
        : t("activity.lifecycle.replaceSyncPending");
    }
    if (task.state !== "completed") return t("activity.lifecycle.partialImportedHint");
    return t("activity.lifecycle.importSyncPending");
  }
  if (ingestJob?.status === "cancelled") {
    return t("activity.lifecycle.previousImportCancelled");
  }
  if (ingestJob && ["blocked", "failed"].includes(ingestJob.status)) {
    return ingestJob.error?.message ?? ingestJob.progress.message;
  }
  if (
    ingestJob &&
    ["queued", "running", "retry_wait", "cancelling", "waiting"].includes(ingestJob.status)
  ) {
    return ingestJob.progress.message;
  }
  if (task.landing_error) {
    // 与侧栏「待处理事项」同一句话：下载完成但 movieclaw 看不到文件。放在最前，
    // 否则下面会按 completed 说"等待自动入库"，和红灯自相矛盾
    return task.landing_error;
  }
  if (task.state === "error") {
    // 下载器给出的具体原因（文件缺失 / errorString）必须放在最前——它回答的是
    // "错在哪"；换源提示只是"还能怎么办"，不能把原因盖掉。外部任务再补一句
    // 它不归 MovieClaw 管，免得用户在这里找不到处理入口
    const reason = task.error_message || t("activity.lifecycle.downloaderError");
    if (task.source === "external") return t("activity.lifecycle.externalError", { reason });
    return task.rescue_message ? t("activity.lifecycle.rescueError", { reason, rescue: task.rescue_message }) : reason;
  }
  if (task.rescue_message) return task.rescue_message;
  if (task.state === "missing") {
    return t("activity.lifecycle.missingTaskHint");
  }
  if (task.state === "completed") return t("activity.lifecycle.completedTaskHint");
  if (task.state === "paused") return t("activity.lifecycle.pausedTaskHint");
  if (task.state === "queued") return t("activity.lifecycle.queuedTaskHint");
  if (task.state === "checking") return t("activity.lifecycle.checkingTaskHint");
  if (task.state === "stalled") return t("activity.lifecycle.stalledTaskHint");
  if (task.state === "unknown") return t("activity.lifecycle.unknownTaskHint");
  return null;
}



/**
 * 一个任务状态的展示三件套。``color`` 走内联样式（进度条与状态文字共用），
 * ``dot`` 是状态点的 class。
 *
 * 取色只从 globals.css 的状态四档里挑（--ok / --info / --warn / --danger），
 * 「没有 / 不会发生」不占状态色，用本表既有的中性灰。判断口径见 globals.css：
 * 颜色说的是「系统状态」还是「你该做什么」，只有后者用 --danger。
 *
 * 同一档里的多个状态长得一样是刻意的——「下载中」和「校验中」都是正在进行，
 * 区别由 label 承担；用色相去暗示它们是两类不同的东西，只会稀释颜色的信号。
 */
interface TaskStateMeta {
  label: string;
  color: string;
  dot: string;
}


type TaskStateDefinition = Omit<TaskStateMeta, "label"> & { label: AppMessageKey };

const DOWNLOAD_STATE_META: Record<DownloadTask["state"], TaskStateDefinition> = {
  downloading: {
    label: "activity.downloadState.downloading",
    color: "var(--info)",
    dot: "animate-pulse bg-[var(--info)]",
  },
  stalled: {
    label: "activity.downloadState.stalled",
    color: "var(--warn)",
    dot: "bg-[var(--warn)]",
  },
  paused: {
    label: "activity.downloadState.paused",
    color: "var(--warn)",
    dot: "bg-[var(--warn)]",
  },
  queued: {
    label: "activity.downloadState.queued",
    color: "#cbd5e1",
    dot: "bg-white/40",
  },
  checking: {
    label: "activity.downloadState.checking",
    color: "var(--info)",
    dot: "animate-pulse bg-[var(--info)]",
  },
  completed: {
    label: "activity.downloadState.completed",
    color: "var(--ok)",
    dot: "bg-[var(--ok)]",
  },
  error: {
    label: "activity.downloadState.error",
    color: "var(--danger)",
    dot: "bg-[var(--danger)]",
  },
  missing: {
    label: "activity.downloadState.missing",
    color: "var(--danger)",
    dot: "bg-[var(--danger)]",
  },
  unknown: {
    label: "activity.downloadState.unknown",
    color: "#cbd5e1",
    dot: "bg-white/40",
  },
};


const INGEST_STATE_META: Record<JobStatus, TaskStateDefinition> = {
  queued: { label: "activity.ingestState.queued", color: "#cbd5e1", dot: "bg-white/40" },
  running: { label: "activity.ingestState.running", color: "var(--ok)", dot: "animate-pulse bg-[var(--ok)]" },
  retry_wait: { label: "activity.ingestState.retryWait", color: "var(--warn)", dot: "bg-[var(--warn)]" },
  cancelling: { label: "activity.ingestState.cancelling", color: "var(--warn)", dot: "bg-[var(--warn)]" },
  waiting: { label: "activity.ingestState.waiting", color: "#cbd5e1", dot: "bg-white/40" },
  blocked: { label: "activity.ingestState.blocked", color: "var(--danger)", dot: "bg-[var(--danger)]" },
  succeeded: { label: "activity.ingestState.succeeded", color: "var(--ok)", dot: "bg-[var(--ok)]" },
  failed: { label: "activity.ingestState.blocked", color: "var(--danger)", dot: "bg-[var(--danger)]" },
  // 已取消是终态，不会再有进展：归到本表的中性灰，和「等待入库 / 等待条件」
  // 一样不占状态色——它们的区别本来就该由 label 说清楚。
  cancelled: { label: "activity.ingestState.cancelled", color: "#cbd5e1", dot: "bg-white/40" },
};

export function downloadStateMeta(state: DownloadTask["state"], locale: AppLocale = requestLocale() ?? "zh-Hans"): TaskStateMeta {
  const t = appTranslator(locale);
  const definition = DOWNLOAD_STATE_META[state];
  return { ...definition, label: t(definition.label) };
}
export function ingestStateMeta(status: JobStatus, locale: AppLocale = requestLocale() ?? "zh-Hans"): TaskStateMeta {
  const t = appTranslator(locale);
  const definition = INGEST_STATE_META[status];
  return { ...definition, label: t(definition.label) };
}
