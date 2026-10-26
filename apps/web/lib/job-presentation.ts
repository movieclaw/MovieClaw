import type { JobView } from "./api/jobs";
import { appTranslator, type AppMessageKey } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";
import { formatNumber } from "./i18n/format.ts";
import { formatBytes, formatDuration } from "./format.ts";

const JOB_TYPE_LABELS: Record<string, AppMessageKey> = {
  "subtitle.generate": "activity.jobTypes.subtitleGenerate",
  "library.scan": "activity.jobTypes.libraryScan",
  "library.metadata.refresh": "activity.jobTypes.libraryMetadata",
  "media.metadata.refresh": "activity.jobTypes.mediaMetadata",
  "library.chapter_images": "activity.jobTypes.chapters",
  "library.skip_segments": "activity.jobTypes.skipSegments",
  "media.skip_segments": "activity.jobTypes.skipSegments",
  "reels.clips": "activity.jobTypes.reelClips",
  "library.organize": "activity.jobTypes.organize",
  "library.transfer": "activity.jobTypes.transfer",
  "library.ingest": "activity.jobTypes.ingest",
  "drive.upload": "activity.jobTypes.upload",
};

/** 任务类型的显示名：内置类型用本地文案，插件任务用服务端给的名字，都没有显示原始类型 */
export function jobTypeLabel(job: Pick<JobView, "job_type" | "job_type_label">, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  return Object.hasOwn(JOB_TYPE_LABELS, job.job_type) ? t(JOB_TYPE_LABELS[job.job_type]) : job.job_type_label || job.job_type;
}

const JOB_STATUS_LABELS: Record<string, AppMessageKey> = {
  queued: "activity.jobStatus.queued",
  running: "activity.jobStatus.running",
  retry_wait: "activity.jobStatus.retryWait",
  cancelling: "activity.jobStatus.cancelling",
  waiting: "activity.jobStatus.waiting",
  blocked: "activity.jobStatus.blocked",
  succeeded: "activity.jobStatus.succeeded",
  failed: "activity.jobStatus.failed",
  cancelled: "activity.jobStatus.cancelled",
};

const JOB_PHASE_LABELS: Record<string, AppMessageKey> = {
  queued: "activity.jobPhase.queued",
  preparing: "activity.jobPhase.preparing",
  ocr: "activity.jobPhase.ocr",
  syncing: "activity.jobPhase.syncing",
  glossary: "activity.jobPhase.glossary",
  translating: "activity.jobPhase.translating",
  validating: "activity.jobPhase.validating",
  compressing: "activity.jobPhase.compressing",
  writing: "activity.jobPhase.writing",
  refreshing: "activity.jobPhase.refreshing",
  walking: "activity.jobPhase.walking",
  ingesting: "activity.jobPhase.ingesting",
  probing: "activity.jobPhase.probing",
  assets: "activity.jobPhase.assets",
  analyzing: "activity.jobPhase.analyzing",
  organizing: "activity.jobPhase.organizing",
  transferring: "activity.jobPhase.transferring",
  identifying: "activity.jobPhase.identifying",
  waiting_library: "activity.jobPhase.waitingLibrary",
  waiting_stable: "activity.jobPhase.waitingStable",
  finalizing: "activity.jobPhase.finalizing",
  retry_wait: "activity.jobPhase.retryWait",
  blocked: "activity.jobPhase.blocked",
  completed: "activity.jobPhase.completed",
  cancelled: "activity.jobPhase.cancelled",
};

const LANGUAGE_LABELS: Record<string, AppMessageKey> = {
  chs: "activity.jobLanguages.chs",
  cht: "activity.jobLanguages.cht",
  eng: "activity.jobLanguages.eng",
  jpn: "activity.jobLanguages.jpn",
  kor: "activity.jobLanguages.kor",
  fre: "activity.jobLanguages.fre",
  ger: "activity.jobLanguages.ger",
  spa: "activity.jobLanguages.spa",
  ita: "activity.jobLanguages.ita",
  por: "activity.jobLanguages.por",
  rus: "activity.jobLanguages.rus",
  tha: "activity.jobLanguages.tha",
};

function detailNumber(details: Record<string, unknown>, key: string): number | null {
  const value = details[key];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function detailString(details: Record<string, unknown>, key: string): string | null {
  const value = details[key];
  return typeof value === "string" && value ? value : null;
}

export function detailStrings(details: Record<string, unknown>, key: string): string[] {
  const value = details[key];
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is string => typeof item === "string" && item.length > 0);
}

function detailCount(details: Record<string, unknown>, key: string): number {
  const value = details[key];
  if (Array.isArray(value)) return value.length;
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function jobString(job: JobView, key: string): string | null {
  return detailString(job.progress.details, key) ?? detailString(job.input_data, key);
}

/** 字幕任务的目标语言来自已确认输入，运行期 details 只作为更新后的优先快照。 */
export function subtitleLanguageLabel(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  const t = appTranslator(locale);
  if (job.job_type !== "subtitle.generate") return null;
  const target = jobString(job, "target_language");
  if (!target) return null;
  const primary = languageLabel(target, locale);
  const secondary = jobString(job, "secondary_language");
  return secondary
    ? t("activity.jobs.bilingual", { primary, secondary: languageLabel(secondary, locale) })
    : primary;
}

interface SubtitleUsageSummary {
  requests: number;
  failedRequests: number;
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
  cacheReadTokens: number;
  totalDurationMs: number;
  maxDurationMs: number;
}

export function subtitleUsageSummary(job: JobView): SubtitleUsageSummary | null {
  if (job.job_type !== "subtitle.generate") return null;
  const summary = {
    requests: detailNumber(job.usage, "request_count") ?? 0,
    failedRequests: detailNumber(job.usage, "failed_request_count") ?? 0,
    promptTokens: detailNumber(job.usage, "prompt_tokens") ?? 0,
    completionTokens: detailNumber(job.usage, "completion_tokens") ?? 0,
    totalTokens: detailNumber(job.usage, "total_tokens") ?? 0,
    cacheReadTokens: detailNumber(job.usage, "cache_read_tokens") ?? 0,
    totalDurationMs: detailNumber(job.usage, "total_duration_ms") ?? 0,
    maxDurationMs: detailNumber(job.usage, "max_duration_ms") ?? 0,
  };
  return summary.requests > 0 || summary.totalTokens > 0 || summary.totalDurationMs > 0
    ? summary
    : null;
}

export function formatInteger(value: number, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  return formatNumber(value, undefined, locale);
}

export function formatModelDuration(milliseconds: number, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  if (milliseconds <= 0) return "—";
  if (milliseconds < 1000) return t("activity.jobs.milliseconds", { count: Math.round(milliseconds) });
  return formatDuration(Math.max(1, Math.round(milliseconds / 1000)), locale);
}

export function originLabel(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const origin =
    job.origin === "cli"
      ? "CLI"
      : job.origin === "agent"
        ? t("activity.jobs.originAgent")
        : job.origin === "plugin"
          ? t("activity.jobs.originPlugin")
          : job.origin === "scheduler" || job.origin === "system"
            ? t("activity.jobs.originSystem")
            : t("activity.jobs.originWeb");
  return job.actor_name ? `${origin} · ${job.actor_name}` : origin;
}

export function progressAmount(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  const t = appTranslator(locale);
  const { current, total } = job.progress;
  if (current == null || total == null) return null;
  if (job.job_type === "library.ingest") {
    return `${formatBytes(current)} / ${formatBytes(total)}`;
  }
  const unit =
    job.job_type === "subtitle.generate" ? "subtitles"
      : job.job_type === "library.scan" || job.job_type === "library.organize" ? "files"
        : job.job_type === "media.metadata.refresh" ? "images"
          : job.job_type === "library.metadata.refresh" ? "items"
            : job.job_type === "library.transfer" ? "paths" : "other";
  return t("activity.jobs.progress", { current, total, unit });
}

/** 元数据刷新的图片记账（details.images）：新下载 / 沿用 / 收编 / 本地缩图 / 失败 / 抓帧 / 字节数 */
function imageTally(details: Record<string, unknown>) {
  const raw = details.images;
  const value = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  return {
    downloaded: detailNumber(value, "downloaded") ?? 0,
    reused: detailNumber(value, "reused") ?? 0,
    // 不联网取到的图：从媒体目录收编同一张图 / 从本地更大档位缩出来（services/asset_reuse.py）
    adopted: detailNumber(value, "adopted") ?? 0,
    derived: detailNumber(value, "derived") ?? 0,
    failed: detailNumber(value, "failed") ?? 0,
    grabbed: detailNumber(value, "grabbed") ?? 0,
    bytes: detailNumber(value, "bytes") ?? 0,
  };
}

export function jobDetailItems(job: JobView, locale: AppLocale = requestLocale() ?? "zh-Hans"): Array<{ label: string; alert?: boolean }> {
  const t = appTranslator(locale);
  const details = job.progress.details;
  const items: Array<{ label: string; alert?: boolean }> = [];

  if (job.job_type === "subtitle.generate") {
    const language = subtitleLanguageLabel(job, locale);
    const doneEvents = detailNumber(details, "done_events");
    const totalEvents = detailNumber(details, "total_events");
    const parallelism = detailNumber(details, "parallelism");
    const rateLimits = detailNumber(details, "rate_limit_count");
    // subtitleLanguageLabel 出来的已经是翻译后的标签，不要再拿去查一次语言码表
    if (language) items.push({ label: language });
    if (doneEvents != null && totalEvents) {
      items.push({ label: t("activity.jobs.subtitleEvents", { current: doneEvents, total: totalEvents }) });
    }
    if (details.uses_ocr === true) items.push({ label: "PGS OCR" });
    if (parallelism && parallelism > 1) items.push({ label: t("activity.jobs.parallelism", { count: parallelism }) });
    if (rateLimits) items.push({ label: t("activity.jobs.rateLimitRetries", { count: rateLimits }), alert: true });
  } else if (job.job_type === "library.scan") {
    const identified = detailNumber(details, "identified");
    const unidentified = detailNumber(details, "unidentified");
    const probed = detailNumber(details, "probed");
    const missing = detailNumber(details, "marked_missing");
    const errors = detailCount(details, "errors");
    if (identified) items.push({ label: t("activity.jobs.identified", { count: identified }) });
    if (probed) items.push({ label: t("activity.jobs.probed", { count: probed }) });
    if (unidentified) items.push({ label: t("activity.jobs.unidentified", { count: unidentified }), alert: true });
    if (missing) items.push({ label: t("activity.jobs.missing", { count: missing }), alert: true });
    if (errors) items.push({ label: t("activity.jobs.issues", { count: errors }), alert: true });
  } else if (job.job_type.includes("metadata.refresh")) {
    // 正在刷新哪部、到哪一步已写在摘要文案里（「正在刷新「XX」：下载图片 120 / 480」），
    // 这里只补失败与图片记账。失败排在前面：标签最多显示 4 个
    const failed = detailNumber(details, "failed");
    if (failed) items.push({ label: t("activity.jobs.unfinishedItems", { count: failed }), alert: true });
    const images = imageTally(details);
    if (images.failed) items.push({ label: t("activity.jobs.failedImages", { count: images.failed }), alert: true });
    if (images.downloaded) {
      items.push({ label: t("activity.jobs.downloadedImages", { count: images.downloaded, size: formatBytes(images.bytes) }) });
    }
    if (images.reused) items.push({ label: t("activity.jobs.reusedImages", { count: images.reused }) });
    if (images.adopted) items.push({ label: t("activity.jobs.adoptedImages", { count: images.adopted }) });
    if (images.derived) items.push({ label: t("activity.jobs.derivedImages", { count: images.derived }) });
    if (images.grabbed) items.push({ label: t("activity.jobs.grabbedImages", { count: images.grabbed }) });
  } else if (job.job_type === "library.organize") {
    const errors = detailCount(details, "errors");
    if (errors) items.push({ label: t("activity.jobs.issues", { count: errors }), alert: true });
  } else if (job.job_type === "library.transfer") {
    const moved = detailNumber(details, "bytes_moved");
    const totalBytes = detailNumber(details, "total_bytes");
    if (moved) items.push({ label: t("activity.jobs.movedBytes", { size: formatBytes(moved) }) });
    else if (totalBytes) items.push({ label: t("activity.jobs.totalBytes", { size: formatBytes(totalBytes) }) });
    if (details.cross_device === true) items.push({ label: t("activity.jobs.crossDevice") });
  } else if (job.job_type === "library.ingest") {
    const fileName = detailString(details, "file_name");
    if (fileName) items.push({ label: fileName });
  }

  return items.slice(0, 4);
}

export function jobStatusLabel(status: string, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  return Object.hasOwn(JOB_STATUS_LABELS, status) ? appTranslator(locale)(JOB_STATUS_LABELS[status]) : status;
}
export function jobPhaseLabel(phase: string, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  return Object.hasOwn(JOB_PHASE_LABELS, phase) ? appTranslator(locale)(JOB_PHASE_LABELS[phase]) : phase;
}
function languageLabel(code: string, locale: AppLocale): string {
  return Object.hasOwn(LANGUAGE_LABELS, code) ? appTranslator(locale)(LANGUAGE_LABELS[code]) : code;
}
