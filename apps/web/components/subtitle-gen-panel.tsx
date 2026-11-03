"use client";

import { useLocale, useTranslations } from "next-intl";

import { formatList, formatNumber } from "@/lib/i18n/format";
import { appTranslator } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";

/**
 * 字幕规格行里的 AI 翻译入口。
 *
 * 交互分成两个明确阶段：点击后先同步预检（不调用 LLM），在弹窗里讲清
 * 参考字幕、目标语言、输出文件与预计成本；用户确认后才启动后台任务。
 * 后台状态只读取全站 Job Provider；SSE 即时更新、低频轮询兜底，Web、CLI
 * 与 Agent 发起的任务在这里呈现完全一致。
 */

import { useCallback, useEffect, useRef, useState } from "react";

import type { Route } from "next";
import { useRouter } from "next/navigation";

import { BrandLoader } from "@/components/brand-loader";
import { Modal } from "@/components/modal";
import { LlmCapabilityGate } from "@/components/llm-gate";
import { Tooltip } from "@/components/tooltip";
import { WandIcon } from "@/components/icons";
import { useAgentConversations } from "@/lib/agent-conversations";
import type { LibraryItemFile } from "@/lib/api/libraries";
import {
  generateSubtitles,
  previewSubtitleGeneration,
  type SubtitleGenerationPreview,
  type SubtitleSourceCandidate,
} from "@/lib/api/subtitle-gen";
import { cancelJob, type JobStatus, type JobView } from "@/lib/api/jobs";
import { usePermissions } from "@/lib/permissions";
import { useJobs } from "@/lib/jobs";

const OUTPUT_LANGUAGES = [
  { token: "chs" }, { token: "cht" }, { token: "eng" }, { token: "jpn" },
  { token: "kor" }, { token: "fre" }, { token: "ger" }, { token: "spa" },
  { token: "ita" }, { token: "por" }, { token: "rus" }, { token: "tha" },
] as const;
type OutputLanguage = (typeof OUTPUT_LANGUAGES)[number]["token"];

function outputLanguageLabel(token: string | null | undefined, locale: AppLocale): string {
  const t = appTranslator(locale);
  return OUTPUT_LANGUAGES.some((language) => language.token === token)
    ? languageLabel(token ?? null, locale)
    : token ?? t("library.subtitleGeneration.subtitle");
}

function outputLabel(target: string, secondary: string | null, locale: AppLocale): string {
  const t = appTranslator(locale);
  const primary = outputLanguageLabel(target, locale);
  return secondary ? t("library.subtitleGeneration.bilingual", { primary, secondary: outputLanguageLabel(secondary, locale) }) : primary;
}

function nextSecondary(target: string, current: string): OutputLanguage {
  if (target !== current) return current as OutputLanguage;
  return OUTPUT_LANGUAGES.find((language) => language.token !== target)?.token ?? "eng";
}

function isAiSubtitle(filename: string | null): boolean {
  if (!filename) return false;
  return filename
    .toLowerCase()
    .split(".")
    .some((part) => part === "ai" || part === "asr" || part.startsWith("ai-"));
}

/*
 * 与字幕语言芯片同一副骨架（h-7、7px 圆角、caption 字号），只靠描边把
 * 「可点的动作」与「只读的标签」区分开。
 *
 * 原来这里用的是主按钮银色（.btn-accent）：条目页真正的主行动是下方那枚
 * 白色播放键，规格行里再放一枚亮银胶囊等于页面上有两个主按钮在抢视线，
 * 而生成字幕是低频操作。降为次级描边按钮后，层级变成
 * 播放（白）> AI 生成字幕（描边）> 语言芯片（无边填充）。
 */
const AI_BADGE_BASE =
  "tnum inline-flex h-7 shrink-0 items-center gap-1.5 rounded-[7px] border px-2.5 " +
  "text-caption font-medium leading-none transition-[background-color,border-color,color] " +
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-ring)] " +
  "disabled:pointer-events-none disabled:opacity-50 max-md:h-8";
const AI_BADGE_IDLE =
  "border-white/[0.16] text-white/75 hover:border-white/30 hover:bg-white/[0.08] hover:text-white";
const AI_BADGE_RUNNING =
  "border-[var(--info)]/30 bg-[var(--info)]/[0.12] text-[var(--info)] " +
  "hover:border-[var(--info)]/45 hover:bg-[var(--info)]/[0.18]";
const AI_BADGE_FAILED =
  "border-[#ff9f9f]/25 bg-[#ff9f9f]/[0.07] text-[#ffb4b4] " +
  "hover:border-[#ff9f9f]/40 hover:bg-[#ff9f9f]/[0.12]";
const CANCEL_BUTTON =
  "rounded-lg border border-white/10 bg-white/[0.06] px-4 py-2 text-ui text-white/80 " +
  "transition hover:bg-white/[0.1] disabled:pointer-events-none disabled:opacity-40";
const CONFIRM_BUTTON =
  "rounded-lg bg-[#8fdcff] px-4 py-2 text-ui font-semibold text-[#071018] transition " +
  "hover:bg-[#b4e9ff] disabled:pointer-events-none disabled:opacity-40";
const AGENT_BUTTON =
  "rounded-lg border border-[var(--info)]/35 bg-[var(--info)]/[0.08] px-4 py-2 text-ui " +
  "font-medium text-[var(--info)] transition hover:bg-[var(--info)]/[0.14] " +
  "disabled:pointer-events-none disabled:opacity-40";

function errorMessage(error: unknown, locale: AppLocale): string {
  const t = appTranslator(locale);
  return error instanceof Error ? error.message : t("library.subtitleGeneration.requestFailed");
}

function languageLabel(language: string | null, locale: AppLocale): string {
  const t = appTranslator(locale);
  const labels: Record<string, string> = {
    chi: t("media.languages.chinese"),
    chs: t("media.languages.simplifiedChinese"),
    cht: t("media.languages.traditionalChinese"),
    eng: t("media.languages.english"),
    fre: t("media.languages.french"),
    fra: t("media.languages.french"),
    ger: t("media.languages.german"),
    ita: t("media.languages.italian"),
    jpn: t("media.languages.japanese"),
    kor: t("media.languages.korean"),
    por: t("media.languages.portuguese"),
    rus: t("media.languages.russian"),
    spa: t("media.languages.spanish"),
    tha: t("media.languages.thai"),
  };
  return language ? (labels[language] ?? language.toUpperCase()) : t("library.subtitleGeneration.unknownLanguage");
}

function formatLabel(format: string | null, locale: AppLocale): string {
  const t = appTranslator(locale);
  if (!format) return t("library.subtitleGeneration.unknownFormat");
  const labels: Record<string, string> = {
    hdmv_pgs_subtitle: "PGS",
    dvd_subtitle: "VobSub",
    subrip: "SRT",
    srt: "SRT",
    ass: "ASS",
    ssa: "SSA",
    webvtt: "VTT",
    vtt: "VTT",
  };
  return labels[format.toLowerCase()] ?? format.toUpperCase();
}

function candidateLabel(candidate: SubtitleSourceCandidate, locale: AppLocale): string {
  const t = appTranslator(locale);
  const location =
    candidate.kind === "embedded"
      ? t("library.subtitleGeneration.embedded")
      : candidate.kind === "audio"
        ? t("library.subtitleGeneration.audio")
        : t("library.subtitleGeneration.external");
  const identity =
    candidate.kind === "embedded" || candidate.kind === "audio"
      ? t("library.subtitleGeneration.track", { index: Number(candidate.key) + 1 })
      : candidate.key;
  const conversion = candidate.requires_ocr ? t("library.subtitleGeneration.ocrSuffix") : "";
  const provenanceLabels: Record<SubtitleSourceCandidate["provenance"], string> = {
    original: t("library.subtitleGeneration.original"),
    pgs_ocr: t("library.subtitleGeneration.pgsOcr"),
    asr: t("library.subtitleGeneration.asr"),
    ai: t("library.subtitleGeneration.ai"),
    ai_bilingual: t("library.subtitleGeneration.aiBilingual"),
  };
  return t("library.subtitleGeneration.candidate", {
    language: languageLabel(candidate.language, locale), format: formatLabel(candidate.format, locale),
    provenance: provenanceLabels[candidate.provenance], location, identity, conversion,
  });
}

function candidateKey(candidate: SubtitleSourceCandidate): string {
  return `${candidate.kind}:${candidate.key}`;
}

function tokenEstimate(tokens: number, locale: AppLocale): string {
  const t = appTranslator(locale);
  if (tokens < 1000) return t("library.subtitleGeneration.tokenEstimate", { amount: formatNumber(tokens, undefined, locale) });
  return t("library.subtitleGeneration.tokenEstimateK", { amount: formatNumber(tokens / 1000, { minimumFractionDigits: tokens < 10_000 ? 1 : 0, maximumFractionDigits: tokens < 10_000 ? 1 : 0 }, locale) });
}

const PROGRESS_STAGES = [
  { phases: ["preparing", "extracting", "ocr", "transcribing", "syncing"], labelKey: "library.subtitleGeneration.prepareStage" },
  { phases: ["glossary"], labelKey: "library.subtitleGeneration.glossaryStage" },
  { phases: ["translating"], labelKey: "library.subtitleGeneration.translateStage" },
  { phases: ["validating", "compressing"], labelKey: "library.subtitleGeneration.qualityStage" },
  { phases: ["writing", "refreshing"], labelKey: "library.subtitleGeneration.saveStage" },
] as const;

interface SubtitleProgress {
  phase: string;
  message: string;
  percent: number | null;
  done_blocks: number;
  total_blocks: number;
  done_events: number;
  total_events: number;
  active_blocks: number[];
  parallelism: number;
  oldest_active_seconds: number;
  last_completed_seconds_ago: number | null;
  validation_retries: number;
  rate_limit_count: number;
  model_requests: number;
  model_tokens: number;
  uses_ocr: boolean;
  /** 来源是音轨识别（本地语音模型），第一步显示为「识别台词」 */
  uses_asr: boolean;
  /** 本机正在为播放转码，识别暂停中 */
  transcribe_paused: boolean;
  /** 读取阶段还在排队等别的文件读完（同一时间只通读一个视频） */
  extract_queued: boolean;
  target_language: string | null;
  secondary_language: string | null;
  source_candidate_key: string | null;
  elapsed_seconds: number;
}

const RUNNING_JOB_STATUSES = new Set<JobStatus>([
  "queued",
  "running",
  "retry_wait",
  "cancelling",
  "waiting",
]);

function detailNumber(details: Record<string, unknown>, key: string): number {
  const value = details[key];
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function detailString(details: Record<string, unknown>, key: string): string | null {
  const value = details[key];
  return typeof value === "string" && value ? value : null;
}

function subtitleProgress(job: JobView | null): SubtitleProgress | null {
  if (!job) return null;
  const details = job.progress.details;
  const activeBlocks = Array.isArray(details.active_blocks)
    ? details.active_blocks.filter((value): value is number => typeof value === "number")
    : [];
  const startedAt = job.started_at ? Date.parse(job.started_at) : Number.NaN;
  return {
    phase: job.progress.phase,
    message: job.progress.message,
    percent: job.progress.percent,
    done_blocks: detailNumber(details, "done_blocks"),
    total_blocks: detailNumber(details, "total_blocks"),
    done_events: detailNumber(details, "done_events"),
    total_events: detailNumber(details, "total_events"),
    active_blocks: activeBlocks,
    parallelism: detailNumber(details, "parallelism"),
    oldest_active_seconds: detailNumber(details, "oldest_active_seconds"),
    last_completed_seconds_ago:
      typeof details.last_completed_seconds_ago === "number"
        ? details.last_completed_seconds_ago
        : null,
    validation_retries: detailNumber(details, "validation_retries"),
    rate_limit_count: detailNumber(details, "rate_limit_count"),
    model_requests: detailNumber(job.usage, "request_count"),
    model_tokens: detailNumber(job.usage, "total_tokens"),
    uses_ocr: details.uses_ocr === true,
    uses_asr: details.uses_asr === true,
    transcribe_paused: details.transcribe_paused === true,
    extract_queued: details.extract_queued === true,
    target_language:
      detailString(details, "target_language") ??
      (typeof job.input_data.target_language === "string" ? job.input_data.target_language : null),
    secondary_language:
      detailString(details, "secondary_language") ??
      (typeof job.input_data.secondary_language === "string"
        ? job.input_data.secondary_language
        : null),
    source_candidate_key:
      detailString(details, "source_candidate_key") ??
      (typeof job.input_data.source_candidate_key === "string"
        ? job.input_data.source_candidate_key
        : null),
    elapsed_seconds: Number.isFinite(startedAt)
      ? Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
      : 0,
  };
}

function progressPercent(progress: SubtitleProgress | null): number | null {
  if (!progress || progress.percent === null) return null;
  return Math.min(100, Math.floor(progress.percent));
}

function progressStageIndex(progress: SubtitleProgress): number {
  const index = PROGRESS_STAGES.findIndex((stage) =>
    (stage.phases as readonly string[]).includes(progress.phase ?? "preparing"),
  );
  return index >= 0 ? index : 0;
}

function formatElapsed(seconds: number, locale: AppLocale): string {
  const t = appTranslator(locale);
  const safeSeconds = Math.max(0, Math.floor(seconds || 0));
  if (safeSeconds < 60) return t("library.subtitleGeneration.elapsedSeconds", { count: safeSeconds });
  const minutes = Math.floor(safeSeconds / 60);
  if (minutes < 60) return t("library.subtitleGeneration.elapsedMinutes", { minutes, seconds: safeSeconds % 60 });
  return t("library.subtitleGeneration.elapsedHours", { hours: Math.floor(minutes / 60), minutes: minutes % 60 });
}

function sourceKeyLabel(key: string | null, locale: AppLocale): string | null {
  const t = appTranslator(locale);
  if (!key) return null;
  if (key.startsWith("embedded:")) {
    const index = Number(key.slice("embedded:".length));
    return Number.isFinite(index) ? t("library.subtitleGeneration.sourceTrack", { index: index + 1 }) : t("library.subtitleGeneration.sourceEmbedded");
  }
  if (key.startsWith("audio:")) {
    const index = Number(key.slice("audio:".length));
    return Number.isFinite(index) ? t("library.subtitleGeneration.sourceAudio", { index: index + 1 }) : key;
  }
  return key.startsWith("external:") ? key.slice("external:".length) : key;
}

function runningBadgeText(progress: SubtitleProgress | null, locale: AppLocale): string {
  const t = appTranslator(locale);
  const phaseLabels: Record<string, string> = {
    preparing: t("library.subtitleGeneration.preparing"),
    ocr: t("library.subtitleGeneration.recognizing"),
    syncing: t("library.subtitleGeneration.syncing"),
    glossary: t("library.subtitleGeneration.glossary"),
    validating: t("library.subtitleGeneration.validating"),
    compressing: t("library.subtitleGeneration.compressing"),
    writing: t("library.subtitleGeneration.writing"),
    refreshing: t("library.subtitleGeneration.refreshing"),
  };
  if (progress?.phase === "translating") {
    const percent = progressPercent(progress);
    return percent === null ? t("library.subtitleGeneration.translating") : `AI ${percent}%`;
  }
  if (progress?.phase === "transcribing") {
    if (progress.transcribe_paused) return t("library.subtitleGeneration.transcribePaused");
    const percent = progressPercent(progress);
    return percent === null ? t("library.subtitleGeneration.transcribing") : t("library.subtitleGeneration.transcribePercent", { percent });
  }
  if (progress?.phase === "extracting") {
    if (progress.extract_queued) return t("library.subtitleGeneration.queuedRead");
    const percent = progressPercent(progress);
    return percent === null ? t("library.subtitleGeneration.reading") : t("library.subtitleGeneration.readPercent", { percent });
  }
  return phaseLabels[progress?.phase ?? "preparing"] ?? t("library.subtitleGeneration.generating");
}

function ProgressDetails({
  progress,
  compact = false,
}: {
  progress: SubtitleProgress;
  compact?: boolean;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const percent = progressPercent(progress);
  const currentStage = progressStageIndex(progress);
  const activeBlocks = progress.active_blocks ?? [];
  const doneEvents = progress.done_events ?? 0;
  const totalEvents = progress.total_events ?? 0;
  const reference = sourceKeyLabel(progress.source_candidate_key, locale);

  return (
    <div className={compact ? "space-y-2.5" : "space-y-3.5"}>
      <div className="flex items-start justify-between gap-3">
        <p className="font-semibold text-[var(--info)]">{progress.message || t("library.subtitleGeneration.preparingTask")}</p>
        {percent !== null && <span className="tnum shrink-0 font-semibold text-[var(--info)]">{percent}%</span>}
      </div>
      <div className="h-1.5 overflow-hidden rounded-full bg-white/[0.08]">
        <div
          className={`h-full rounded-full bg-[var(--info)] transition-all ${percent === null ? "w-1/3 animate-pulse" : ""}`}
          style={percent === null ? undefined : { width: `${percent}%` }}
        />
      </div>
      <div className="flex flex-wrap gap-x-4 gap-y-1 text-caption text-[var(--text-muted)]">
        {progress.total_blocks > 0 && (
          <span className="tnum">{t("library.subtitleGeneration.blocks", { done: progress.done_blocks, total: progress.total_blocks })}</span>
        )}
        {totalEvents > 0 && <span className="tnum">{t("library.subtitleGeneration.events", { done: doneEvents, total: totalEvents })}</span>}
        {reference && <span className="max-w-full truncate" title={reference}>{t("library.subtitleGeneration.reference", { reference })}</span>}
        {progress.model_requests > 0 && (
          <span className="tnum">
            {t("library.subtitleGeneration.calls", { count: progress.model_requests })}
            {progress.model_tokens > 0 ? t("library.subtitleGeneration.modelTokens", { count: progress.model_tokens }) : ""}
          </span>
        )}
        <span className="tnum">{t("library.subtitleGeneration.elapsed", { elapsed: formatElapsed(progress.elapsed_seconds ?? 0, locale) })}</span>
      </div>
      {activeBlocks.length > 0 && (
        <p className="text-caption text-[var(--info)]/85">
          {t("library.subtitleGeneration.activeBlocks", {
            parallel: progress.parallelism > 1 ? "yes" : "no", limit: progress.parallelism,
            blocks: formatList(activeBlocks.map(String), locale),
            waiting: progress.oldest_active_seconds > 0 ? "yes" : "no",
            elapsed: formatElapsed(progress.oldest_active_seconds, locale),
          })}
        </p>
      )}
      {(progress.rate_limit_count > 0 || progress.validation_retries > 0) && (
        <p className="text-caption leading-5 text-[#ffd89a]">
          {progress.rate_limit_count > 0
            ? t("library.subtitleGeneration.rateLimits", { count: progress.rate_limit_count })
            : ""}
          {progress.validation_retries > 0
            ? t("library.subtitleGeneration.validationRetries", { count: progress.validation_retries })
            : ""}
        </p>
      )}
      <ol className={compact ? "space-y-1" : "space-y-1.5"} aria-label={t("library.subtitleGeneration.stages")}>
        {PROGRESS_STAGES.map((stage, index) => {
          const completed = index < currentStage;
          const current = index === currentStage;
          const label =
            index === 0 && progress.uses_asr
              ? t("library.subtitleGeneration.asrStage")
              : index === 0 && progress.uses_ocr
                ? t("library.subtitleGeneration.ocrStage")
                : t(stage.labelKey);
          return (
            <li
              key={stage.labelKey}
              className={`flex items-center gap-2 text-caption ${
                current
                  ? "font-medium text-[var(--info)]"
                  : completed
                    ? "text-white/70"
                    : "text-white/35"
              }`}
            >
              <span
                className={`flex size-4 shrink-0 items-center justify-center rounded-full border text-[9px] ${
                  current
                    ? "border-[var(--info)] bg-[var(--info)]/15"
                    : completed
                      ? "border-[var(--ok)]/60 bg-[var(--ok)]/10 text-[#7cf0a4]"
                      : "border-white/15"
                }`}
              >
                {completed ? "✓" : index + 1}
              </span>
              <span>{label}</span>
              {current && <span className="ml-auto text-[var(--text-muted)]">{t("library.subtitleGeneration.inProgress")}</span>}
            </li>
          );
        })}
      </ol>
    </div>
  );
}

export function SubtitleGenPanel({
  file,
  onChanged,
}: {
  file: LibraryItemFile;
  /** 产物落盘后回调（详情页借此重拉字幕清单，新字幕立刻可见） */
  onChanged?: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const router = useRouter();
  const { start: startAgent } = useAgentConversations();
  const { isAdmin } = usePermissions();
  const { latestFor, upsert } = useJobs();
  const [targetLanguage, setTargetLanguage] = useState<OutputLanguage>("chs");
  const [bilingual, setBilingual] = useState(false);
  const [secondaryLanguage, setSecondaryLanguage] = useState<OutputLanguage>("eng");
  const [sourceCandidateKey, setSourceCandidateKey] = useState<string | null>(null);
  const [preview, setPreview] = useState<SubtitleGenerationPreview | null>(null);
  const [pgsOcrLanguage, setPgsOcrLanguage] = useState("");
  // 识别过的音轨默认复用上次的结果；用户勾了才重新识别（随每次预检重置）
  const [retranscribe, setRetranscribe] = useState(false);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [dialogMode, setDialogMode] = useState<"preview" | "status">("preview");
  const [previewing, setPreviewing] = useState(false);
  const [starting, setStarting] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [agentStarting, setAgentStarting] = useState(false);
  const [requestError, setRequestError] = useState<string | null>(null);
  const previewRequestRef = useRef(0);
  const previewAbortRef = useRef<AbortController | null>(null);
  const sharedJob = latestFor("library_file", file.id, "subtitle.generate");
  const sharedJobId = sharedJob?.id;
  const sharedJobStatus = sharedJob?.status;
  const progress = subtitleProgress(sharedJob);
  const running = sharedJobStatus ? RUNNING_JOB_STATUSES.has(sharedJobStatus) : false;
  const hasTerminalIssue =
    sharedJobStatus === "blocked" ||
    sharedJobStatus === "failed" ||
    sharedJobStatus === "cancelled";
  const previousJobRef = useRef({ id: sharedJobId, status: sharedJobStatus });

  // 只在当前页面亲眼看到同一任务从活跃态变为成功时刷新字幕台账；初次挂载
  // 读到历史成功任务不触发多余请求。依赖只用 primitive，避免对象替换抖动。
  useEffect(() => {
    const previous = previousJobRef.current;
    if (
      sharedJobId &&
      previous.id === sharedJobId &&
      previous.status &&
      RUNNING_JOB_STATUSES.has(previous.status) &&
      sharedJobStatus === "succeeded"
    ) {
      onChanged?.();
    }
    previousJobRef.current = { id: sharedJobId, status: sharedJobStatus };
  }, [onChanged, sharedJobId, sharedJobStatus]);

  /**
   * 收掉在途预检：作废所有未回来的响应并中断请求。
   *
   * 预检现在只读数据库与现成产物、永远秒回（内封轨没读过就交给任务第一步），
   * 不再需要轮询；换轨、改语言、关弹窗时仍把上一条掐掉，免得旧响应覆盖新选择。
   */
  const cancelPreview = useCallback(() => {
    previewRequestRef.current += 1;
    previewAbortRef.current?.abort();
    previewAbortRef.current = null;
  }, []);

  const loadPreview = useCallback(async (
    target: string,
    secondary: string | null,
    sourceKey: string | null = null,
    again = false,
  ) => {
    cancelPreview();
    const requestId = previewRequestRef.current;
    const controller = new AbortController();
    previewAbortRef.current = controller;

    setDialogMode("preview");
    setDialogOpen(true);
    setPreview(null);
    setPgsOcrLanguage("");
    setRetranscribe(again);
    setRequestError(null);
    setPreviewing(true);

    const isCurrent = () => previewRequestRef.current === requestId;

    try {
      const result = await previewSubtitleGeneration(
        file.id, target, secondary, sourceKey, controller.signal, again,
      );
      if (!isCurrent()) return;
      setPreview(result);
      setSourceCandidateKey(result.selected_source_key);
      setPgsOcrLanguage(result.pgs_conversion?.ocr_language ?? "");
      setPreviewing(false);
    } catch (error) {
      // 主动取消（换轨/关弹窗/离开页面）不是错误，别弹红框
      if (!isCurrent() || controller.signal.aborted) return;
      setRequestError(errorMessage(error, locale));
      setPreviewing(false);
    }
  }, [file.id, cancelPreview, locale]);

  // 弹窗关闭即收掉在途预检：否则用户关掉后徽章会一直卡在「正在检查」。
  useEffect(() => {
    if (dialogOpen) return;
    cancelPreview();
    setPreviewing(false);
  }, [dialogOpen, cancelPreview]);

  // 组件卸载（用户直接离开详情页）同样要中断在途请求
  useEffect(() => () => cancelPreview(), [cancelPreview]);

  const openAction = useCallback(() => {
    if (running || hasTerminalIssue) {
      setDialogMode("status");
      setDialogOpen(true);
      return;
    }
    void loadPreview(targetLanguage, bilingual ? secondaryLanguage : null);
  }, [bilingual, hasTerminalIssue, loadPreview, running, secondaryLanguage, targetLanguage]);

  const onStart = useCallback(async () => {
    setStarting(true);
    setRequestError(null);
    const convertPgs =
      preview?.blocker?.code === "pgs_conversion_required" &&
      preview.pgs_conversion?.available === true;
    try {
      const started = await generateSubtitles(file.id, targetLanguage, {
        convertPgs,
        pgsOcrLanguage: convertPgs ? pgsOcrLanguage || null : null,
        secondaryLanguage: bilingual ? secondaryLanguage : null,
        sourceCandidateKey,
        retranscribe: retranscribe && sourceCandidateKey?.startsWith("audio:") === true,
      });
      upsert(started);
      setDialogOpen(false);
    } catch (error) {
      // 确认到真正入队之间文件可能变化，错误留在弹窗里让用户看清。
      setRequestError(errorMessage(error, locale));
    } finally {
      setStarting(false);
    }
  }, [
    bilingual,
    file.id,
    pgsOcrLanguage,
    preview,
    retranscribe,
    secondaryLanguage,
    sourceCandidateKey,
    targetLanguage,
    upsert,
    locale,
  ]);

  const onStop = useCallback(async () => {
    setStopping(true);
    setRequestError(null);
    try {
      if (!sharedJobId) return;
      upsert(await cancelJob(sharedJobId));
    } catch (error) {
      setRequestError(errorMessage(error, locale));
    } finally {
      setStopping(false);
    }
  }, [sharedJobId, upsert, locale]);

  // 状态弹窗是在给一个已经存在的任务收尾，语言与参考源以任务入参为准（Agent、
  // CLI 发起的任务在这里也看得到）；预检弹窗还没有任务，用弹窗里当前的选择。
  const jobTargetLanguage = progress?.target_language ?? null;
  const jobSecondaryLanguage = progress?.secondary_language ?? null;
  const jobSourceKey = progress?.source_candidate_key ?? null;

  /*
   * 「交给 Agent 处理」必须把用户已经做出的选择一起带走。
   *
   * 早先的提示词只有文件与失败原因，Agent 拿不到语言选择，只能按默认参数重跑
   * 一轮单语：用户勾的是双语，拿回来的却是单语文件，白花一轮 LLM 配额，还要
   * 再解释一遍（issue #433）。语言与参考字幕是用户已经拍板的事，不该让 Agent
   * 去猜，所以除了人话的「期望输出」，再给一行可直接执行的 CLI 参数。
   */
  const handOffToAgent = useCallback(
    async (reason: string) => {
      setAgentStarting(true);
      setRequestError(null);
      const conversion = preview?.pgs_conversion;
      const jobLanguage = dialogMode === "status" ? jobTargetLanguage : null;
      const target = jobLanguage ?? targetLanguage;
      const secondary = jobLanguage
        ? jobSecondaryLanguage
        : bilingual
          ? secondaryLanguage
          : null;
      const sourceKey = jobLanguage ? jobSourceKey : sourceCandidateKey;
      const prompt = [
        t("library.subtitleGeneration.agentIntro"),
        t("library.subtitleGeneration.agentFile", { name: file.file_name }),
        t("library.subtitleGeneration.agentId", { id: file.id }),
        t("library.subtitleGeneration.agentPath", { path: file.file_path }),
        t("library.subtitleGeneration.agentOutput", { output: outputLabel(target, secondary, locale) }),
        t("library.subtitleGeneration.agentArguments", { arguments:
          `--target-language ${target}` +
          (secondary ? ` --secondary-language ${secondary}` : "") +
          (sourceKey ? ` --source-candidate-key ${sourceKey}` : ""),
        }),
        t("library.subtitleGeneration.agentIssue", { reason }),
        conversion
          ? t("library.subtitleGeneration.agentEnvironment", { platform: conversion.platform, architecture: conversion.architecture, engine: conversion.engine ? ` · ${conversion.engine}` : t("library.subtitleGeneration.noEngine") })
          : null,
        conversion?.message ? t("library.subtitleGeneration.agentDiagnostic", { message: conversion.message }) : null,
        ...(preview?.blocker?.suggestions.map((suggestion) => t("library.subtitleGeneration.agentSuggestion", { suggestion })) ?? []),
        t("library.subtitleGeneration.agentInstructions"),
      ]
        .filter(Boolean)
        .join("\n");

      try {
        const id = await startAgent(prompt);
        setDialogOpen(false);
        router.push(`/sessions/${id}` as Route);
      } catch (error) {
        setRequestError(t("library.subtitleGeneration.agentFailed", { message: errorMessage(error, locale) }));
      } finally {
        setAgentStarting(false);
      }
    },
    [
      bilingual,
      dialogMode,
      file.file_name,
      file.file_path,
      file.id,
      jobSecondaryLanguage,
      jobSourceKey,
      jobTargetLanguage,
      preview,
      router,
      secondaryLanguage,
      sourceCandidateKey,
      startAgent,
      targetLanguage,
      locale,
      t,
    ],
  );

  if (!isAdmin || file.missing) return null;

  const jobSucceeded = sharedJobStatus === "succeeded";
  const resultMessage =
    sharedJob?.error?.message ??
    (typeof sharedJob?.result?.message === "string" ? sharedJob.result.message : null) ??
    t("library.subtitleGeneration.ended");
  const generated = file.subtitle_streams.some(
    (subtitle) => subtitle.external && isAiSubtitle(subtitle.file_name),
  );
  const chosen = preview?.candidates.find(
    (candidate) => candidateKey(candidate) === preview.chosen_key,
  );
  const selectedCandidate = preview?.candidates.find(
    (candidate) => candidateKey(candidate) === preview.selected_source_key,
  );
  // 识别过的文件（有识别外挂）选中音轨时，才有「重新识别」可选
  const canRetranscribe =
    selectedCandidate?.kind === "audio" &&
    preview?.candidates.some(
      (candidate) => candidate.kind === "external" && candidate.provenance === "asr",
    ) === true;
  const pgsConversion = preview?.pgs_conversion;
  const canPreparePgs =
    preview?.blocker?.code === "pgs_conversion_required" &&
    pgsConversion?.available === true;
  const pgsLanguageReady =
    !pgsConversion?.language_confirmation_required || Boolean(pgsOcrLanguage);
  const canConvertPgs = canPreparePgs && pgsLanguageReady;

  let badgeClass = AI_BADGE_IDLE;
  // 已经生成过也不改口称「新建 AI 版本」：那是在讲实现（又加一个文件），
  // 用户要的答案始终是同一句「让 AI 给这个片子做字幕」。
  let badgeText = t("media.subtitles.generateBadge");
  if (previewing) {
    badgeText = t("media.subtitles.checkingBadge");
  } else if (running) {
    badgeClass = AI_BADGE_RUNNING;
    badgeText = runningBadgeText(progress, locale);
  } else if (generated || jobSucceeded) {
    // 生成成功过的文件即便带着历史失败记录，也不该再顶着红色的未完成态
    badgeClass = AI_BADGE_IDLE;
  } else if (hasTerminalIssue) {
    badgeClass = AI_BADGE_FAILED;
    badgeText = t("media.subtitles.unfinishedBadge");
  }
  const runningTarget = progress?.target_language || targetLanguage;
  const runningSecondary = progress?.secondary_language ?? null;
  const activeOutputLabel = outputLabel(runningTarget, runningSecondary, locale);
  const badgeLabel = running ? `${activeOutputLabel} · ${badgeText}` : badgeText;

  const runningTooltip = running && progress ? <ProgressDetails progress={progress} compact /> : null;

  const actionButton = (
    <button
      type="button"
      className={`${AI_BADGE_BASE} ${badgeClass}`}
      disabled={previewing}
      aria-label={running ? t("library.subtitleGeneration.badgeRunning", { label: badgeLabel, message: progress?.message || t("library.subtitleGeneration.running") }) : badgeLabel}
      onClick={openAction}
    >
      {running ? (
        <span className="size-1.5 animate-pulse rounded-full bg-current" />
      ) : (
        <WandIcon className="size-3.5" />
      )}
      <span>{badgeLabel}</span>
    </button>
  );

  return (
    <>
      {/* 生成前直接进确认弹窗，不用 tooltip 重复解释；只有后台任务运行时，
          固定状态按钮才承载进度 tooltip。打开状态弹窗后立即卸掉 tooltip，
          避免浮层残留在 Modal 上方。 */}
      {running || hasTerminalIssue ? (
        !dialogOpen ? (
          <Tooltip content={runningTooltip} maxWidth={460}>
            {actionButton}
          </Tooltip>
        ) : (
          actionButton
        )
      ) : (
        <LlmCapabilityGate feature={t("media.subtitles.generationFeature")} noticeVariant="inline">
          {actionButton}
        </LlmCapabilityGate>
      )}

      <Modal
        open={dialogOpen}
        onClose={() => !starting && !agentStarting && setDialogOpen(false)}
        label={dialogMode === "status" ? t("library.subtitleGeneration.statusTitle") : t("library.subtitleGeneration.generateTitle")}
        width="lg"
        panelClassName="max-h-[88vh] overflow-y-auto"
      >
        <div className="p-5 max-md:p-4">
          <div className="flex items-start gap-3">
            <span className="flex size-9 shrink-0 items-center justify-center rounded-lg border border-[var(--info)]/30 bg-[var(--info)]/[0.12] text-caption font-bold text-[#a9e2ff]">
              AI
            </span>
            <div>
              <h2 className="text-title-sm font-bold text-white">
                {dialogMode === "status"
                  ? running
                    ? t("library.subtitleGeneration.generatingOutput", { output: activeOutputLabel })
                    : t("library.subtitleGeneration.taskTitle")
                  : t("library.subtitleGeneration.generateTitle")}
              </h2>
              <p className="mt-1 text-sub leading-5 text-[var(--text-muted)]">
                {dialogMode === "status"
                  ? running
                    ? t("library.subtitleGeneration.backgroundHint")
                    : t("library.subtitleGeneration.resultHint")
                  : preview?.chosen_key?.startsWith("audio:") && preview.estimated_tokens === 0
                    ? t("library.subtitleGeneration.asrConfirmHint")
                    : t("library.subtitleGeneration.confirmHint")}
              </p>
            </div>
          </div>

          {dialogMode === "status" ? (
            <div className="mt-6 space-y-4">
              {running && progress ? (
                <>
                  <div className="rounded-xl border border-[var(--info)]/25 bg-[var(--info)]/[0.07] p-4">
                    <ProgressDetails progress={progress} />
                  </div>
                  {requestError && (
                    <p className="rounded-xl border border-[#ff9f9f]/30 bg-[#ff9f9f]/[0.08] px-3.5 py-2.5 text-sub leading-5 text-[#ffb4b4]">
                      {requestError}
                    </p>
                  )}
                  <div className="flex justify-end gap-2.5">
                    <button type="button" className={CANCEL_BUTTON} onClick={() => setDialogOpen(false)}>
                      {t("common.close")}
                    </button>
                    <button
                      type="button"
                      className="rounded-lg border border-[#ff9f9f]/30 bg-[#ff9f9f]/[0.08] px-4 py-2 text-ui text-[#ffb4b4] transition hover:bg-[#ff9f9f]/[0.14] disabled:opacity-40"
                      disabled={stopping}
                      onClick={() => void onStop()}
                    >
                      {stopping ? t("library.subtitleGeneration.stopping") : t("library.subtitleGeneration.stop")}
                    </button>
                  </div>
                </>
              ) : (
                <>
                  <div
                    className={`rounded-xl border p-4 ${
                      jobSucceeded
                        ? "border-[var(--ok)]/30 bg-[var(--ok)]/[0.08] text-[#7cf0a4]"
                        : "border-[#ff9f9f]/30 bg-[#ff9f9f]/[0.08] text-[#ffb4b4]"
                    }`}
                  >
                    {/* 结束态也报一句目标输出：Agent、CLI 发起的任务用户没在这个
                        弹窗里选过语言，不写出来就看不出生成的到底是单语还是双语 */}
                    <p className="text-ui font-semibold">
                      {jobSucceeded
                        ? t("library.subtitleGeneration.completed", { output: activeOutputLabel })
                        : t("library.subtitleGeneration.incomplete", { output: activeOutputLabel })}
                    </p>
                    <p className="mt-1.5 text-sub leading-5 opacity-85">
                      {resultMessage}
                    </p>
                  </div>
                  {requestError && (
                    <p className="rounded-xl border border-[#ff9f9f]/30 bg-[#ff9f9f]/[0.08] px-3.5 py-2.5 text-sub leading-5 text-[#ffb4b4]">
                      {requestError}
                    </p>
                  )}
                  <div className="flex justify-end gap-2.5">
                    {!jobSucceeded && (
                      <>
                        <button
                          type="button"
                          className={CONFIRM_BUTTON}
                          onClick={() =>
                            void loadPreview(
                              targetLanguage,
                              bilingual ? secondaryLanguage : null,
                            )
                          }
                        >
                          {t("library.subtitleGeneration.retryPreview")}
                        </button>
                        <button
                          type="button"
                          className={AGENT_BUTTON}
                          disabled={agentStarting}
                          onClick={() => void handOffToAgent(resultMessage)}
                        >
                          {agentStarting ? t("library.subtitleGeneration.handingOff") : t("library.subtitleGeneration.handoff")}
                        </button>
                      </>
                    )}
                    <button type="button" className={CANCEL_BUTTON} onClick={() => setDialogOpen(false)}>
                      {t("common.close")}
                    </button>
                  </div>
                </>
              )}
            </div>
          ) : (
            <div className="mt-5">
              <div className="mb-4 rounded-xl border border-white/[0.08] bg-white/[0.035] p-3.5">
                <p className="mb-3 text-sub font-semibold text-white/85">{t("library.subtitleGeneration.outputLanguage")}</p>
                <div className="grid grid-cols-2 gap-3 max-md:grid-cols-1">
                  <label className="block">
                    <span className="mb-1.5 block text-caption text-[var(--text-muted)]">
                      {bilingual ? t("library.subtitleGeneration.firstLanguage") : t("library.subtitleGeneration.targetLanguage")}
                    </span>
                    <select
                      value={targetLanguage}
                      disabled={starting}
                      onChange={(event) => {
                        const target = event.target.value as OutputLanguage;
                        const secondary = nextSecondary(target, secondaryLanguage);
                        setTargetLanguage(target);
                        setSecondaryLanguage(secondary);
                        void loadPreview(target, bilingual ? secondary : null);
                      }}
                      className="w-full rounded-lg border border-white/10 bg-[#151820] px-3 py-2 text-ui text-white outline-none focus:border-[var(--info)]/60 disabled:opacity-50"
                    >
                      {OUTPUT_LANGUAGES.map((language) => (
                        <option key={language.token} value={language.token}>
                          {outputLanguageLabel(language.token, locale)}
                        </option>
                      ))}
                    </select>
                  </label>

                  {bilingual && (
                    <label className="block">
                      <span className="mb-1.5 block text-caption text-[var(--text-muted)]">
                        {t("library.subtitleGeneration.secondLanguage")}
                      </span>
                      <select
                        value={secondaryLanguage}
                        disabled={starting}
                        onChange={(event) => {
                          const secondary = event.target.value as OutputLanguage;
                          setSecondaryLanguage(secondary);
                          void loadPreview(targetLanguage, secondary);
                        }}
                        className="w-full rounded-lg border border-white/10 bg-[#151820] px-3 py-2 text-ui text-white outline-none focus:border-[var(--info)]/60 disabled:opacity-50"
                      >
                        {OUTPUT_LANGUAGES.map((language) => (
                          <option
                            key={language.token}
                            value={language.token}
                            disabled={language.token === targetLanguage}
                          >
                            {outputLanguageLabel(language.token, locale)}
                          </option>
                        ))}
                      </select>
                    </label>
                  )}
                </div>
                <label className="mt-3 inline-flex cursor-pointer items-center gap-2 text-sub text-white/75">
                  <input
                    type="checkbox"
                    checked={bilingual}
                    disabled={starting}
                    onChange={(event) => {
                      const enabled = event.target.checked;
                      const secondary = nextSecondary(targetLanguage, secondaryLanguage);
                      setBilingual(enabled);
                      setSecondaryLanguage(secondary);
                      void loadPreview(targetLanguage, enabled ? secondary : null);
                    }}
                    className="size-4 accent-[var(--info)]"
                  />
                  {t("library.subtitleGeneration.generateBilingual")}
                </label>
                {bilingual && (
                  <p className="mt-2 text-caption text-[var(--text-faint)]">
                    {t("library.subtitleGeneration.bilingualHint")}
                  </p>
                )}
              </div>

              {previewing && (
                <div className="flex items-center gap-3 rounded-xl border border-white/[0.08] bg-white/[0.04] px-4 py-4">
                  <BrandLoader className="size-5" />
                  <p className="text-ui font-medium text-white">
                    {t("library.subtitleGeneration.checking")}
                  </p>
                </div>
              )}

              {!previewing && preview && preview.candidates.length > 0 && (
                <div className="mb-4 rounded-xl border border-white/[0.08] bg-white/[0.035] p-3.5">
                  <label className="block">
                    <span className="mb-1.5 block text-sub font-semibold text-white/85">
                      {t("library.subtitleGeneration.referenceLanguage")}
                    </span>
                    <select
                      value={sourceCandidateKey ?? ""}
                      disabled={starting || !preview.candidates.some((candidate) => candidate.selectable)}
                      onChange={(event) =>
                        void loadPreview(
                          targetLanguage,
                          bilingual ? secondaryLanguage : null,
                          event.target.value || null,
                        )
                      }
                      className="w-full rounded-lg border border-white/10 bg-[#151820] px-3 py-2 text-ui text-white outline-none focus:border-[var(--info)]/60 disabled:opacity-50"
                    >
                      {!sourceCandidateKey && <option value="">{t("library.subtitleGeneration.noReference")}</option>}
                      {preview.candidates.map((candidate) => (
                        <option
                          key={candidateKey(candidate)}
                          value={candidateKey(candidate)}
                          disabled={!candidate.selectable}
                        >
                          {candidateLabel(candidate, locale)}
                          {!candidate.selectable ? t("library.subtitleGeneration.excluded", { reason: candidate.excluded ?? t("library.subtitleGeneration.unsupported") }) : ""}
                        </option>
                      ))}
                    </select>
                  </label>
                  <p className="mt-2 text-caption leading-5 text-[var(--text-faint)]">
                    {t("library.subtitleGeneration.sourceHint")}
                  </p>
                  {selectedCandidate?.requires_ocr && (
                    <p className="mt-1.5 text-caption text-[var(--warn)]/85">
                      {t("library.subtitleGeneration.imageSelected")}
                    </p>
                  )}
                  {canRetranscribe && (
                    <label className="mt-3 flex cursor-pointer items-start gap-2 text-sub text-white/75">
                      <input
                        type="checkbox"
                        checked={retranscribe}
                        disabled={starting}
                        onChange={(event) =>
                          void loadPreview(
                            targetLanguage,
                            bilingual ? secondaryLanguage : null,
                            sourceCandidateKey,
                            event.target.checked,
                          )
                        }
                        className="mt-0.5 size-4 shrink-0 accent-[var(--info)]"
                      />
                      <span>
                        {t("library.subtitleGeneration.retranscribe")}
                        <span className="mt-0.5 block text-caption leading-5 text-[var(--text-faint)]">
                          {t("library.subtitleGeneration.retranscribeHint")}
                        </span>
                      </span>
                    </label>
                  )}
                </div>
              )}

              {!previewing && requestError && (
                <div className="rounded-xl border border-[#ff9f9f]/30 bg-[#ff9f9f]/[0.08] px-4 py-3 text-sub leading-6 text-[#ffb4b4]">
                  {requestError}
                </div>
              )}

              {!previewing && canPreparePgs && pgsConversion && (
                <div className="space-y-3.5">
                  <div className="rounded-xl border border-[var(--warn)]/30 bg-[var(--warn)]/[0.08] p-3.5">
                    <p className="text-ui font-semibold text-[var(--warn)]">
                      {pgsConversion.language_confirmation_required
                        ? t("library.subtitleGeneration.chooseOriginal")
                        : t("library.subtitleGeneration.recognizeFirst")}
                    </p>
                    <p className="mt-1 text-sub leading-5 text-[var(--warn)]/85">
                      {t("library.subtitleGeneration.imageHint", { output: outputLabel(targetLanguage, bilingual ? secondaryLanguage : null, locale) })}
                    </p>
                  </div>
                  <div className="rounded-xl border border-white/[0.08] bg-white/[0.035] px-3.5 py-3 text-sub leading-5 text-[var(--text-muted)]">
                    {pgsConversion.language_confirmation_required ? (
                      <label className="block">
                        <span className="mb-1.5 block font-medium text-white/85">{t("library.subtitleGeneration.originalLanguage")}</span>
                        <select
                          value={pgsOcrLanguage}
                          onChange={(event) => setPgsOcrLanguage(event.target.value)}
                          className="w-full rounded-lg border border-white/10 bg-[#151820] px-3 py-2 text-ui text-white outline-none focus:border-[var(--info)]/60"
                        >
                          <option value="">{t("library.subtitleGeneration.chooseLanguage")}</option>
                          {pgsConversion.language_options.map((option) => (
                            <option key={option.code} value={option.code}>
                              {option.label}
                            </option>
                          ))}
                        </select>
                        <span className="mt-1.5 block text-caption text-[var(--text-faint)]">
                          {t("library.subtitleGeneration.actualLanguageHint")}
                        </span>
                      </label>
                    ) : (
                      <p className="text-white/75">
                        {t("library.subtitleGeneration.detectedLanguage", { language: pgsConversion.ocr_language_label ?? t("library.subtitleGeneration.autoDetected") })}
                      </p>
                    )}
                    <p className="mt-2 border-t border-white/[0.07] pt-2">
                      {t("library.subtitleGeneration.ocrHint")}
                    </p>
                  </div>
                </div>
              )}

              {!previewing && preview?.blocker && !canPreparePgs && (
                <div className="space-y-3.5">
                  <div className="rounded-xl border border-[#ff9f9f]/30 bg-[#ff9f9f]/[0.08] p-3.5">
                    <p className="text-ui font-semibold text-[#ffb4b4]">{preview.blocker.title}</p>
                    <p className="mt-1 text-sub leading-5 text-[#ffb4b4]/85">
                      {preview.blocker.message}
                    </p>
                  </div>
                  {preview.blocker.suggestions.length > 0 && (
                    <div>
                      <p className="mb-1.5 text-sub font-medium text-white/85">{t("library.subtitleGeneration.suggestions")}</p>
                      <ul className="list-disc space-y-1 pl-5 text-sub leading-5 text-white/75">
                        {preview.blocker.suggestions.map((suggestion) => (
                          <li key={suggestion}>{suggestion}</li>
                        ))}
                      </ul>
                    </div>
                  )}
                  {pgsConversion && (
                    <details className="rounded-xl border border-white/[0.08] bg-white/[0.025] px-3.5 py-2.5 text-sub text-[var(--text-muted)]">
                      <summary className="cursor-pointer select-none text-white/70">{t("library.subtitleGeneration.diagnostics")}</summary>
                      <div className="mt-2 space-y-1 border-t border-white/[0.07] pt-2 leading-5">
                        <p>
                          {t("library.subtitleGeneration.environment", { platform: pgsConversion.platform, architecture: pgsConversion.architecture,
                            engine: pgsConversion.engine ? ` · ${pgsConversion.engine}` : t("library.subtitleGeneration.noEngine"),
                          })}
                        </p>
                        {pgsConversion.message !== preview.blocker.message && (
                          <p>{pgsConversion.message}</p>
                        )}
                      </div>
                    </details>
                  )}
                </div>
              )}

              {!previewing && preview && !preview.blocker && chosen && (
                <div className="space-y-3.5">
                  <div className="rounded-xl border border-white/[0.08] bg-white/[0.04] p-3.5">
                    <div className="flex flex-wrap items-center gap-2 text-ui font-semibold text-white">
                      <span>{candidateLabel(chosen, locale)}</span>
                      <span className="text-[var(--text-faint)]">→</span>
                      <span className="text-[var(--info)]">
                        {outputLabel(targetLanguage, bilingual ? secondaryLanguage : null, locale)}
                      </span>
                    </div>
                    <p className="tnum mt-1.5 text-sub text-[var(--text-muted)]">
                      {/* 复用上次的识别结果时既有说明又有确切条数：按条数估，不算「按片长粗估」 */}
                      {chosen.kind === "audio" && preview.estimated_tokens === 0
                        ? t("library.subtitleGeneration.noAiCost")
                        : preview.reference_notice && preview.event_count === 0
                          ? preview.estimated_tokens > 0
                            ? t("library.subtitleGeneration.runtimeEstimate", { estimate: tokenEstimate(preview.estimated_tokens, locale) })
                            : t("library.subtitleGeneration.afterReadEstimate")
                          : t("library.subtitleGeneration.dialogueEstimate", { count: preview.event_count, estimate: tokenEstimate(preview.estimated_tokens, locale) })}
                    </p>
                  </div>

                  {/* 内封字幕首次使用：说清楚任务第一步要通读整个视频、可能要几分钟、
                      这一步不花钱，用户才不会把「读取中」当成卡住。 */}
                  {preview.reference_notice && (
                    <p className="rounded-lg border border-[var(--info)]/25 bg-[var(--info)]/[0.07] px-3 py-2 text-sub leading-5 text-[var(--info)]/90">
                      {preview.reference_notice}
                    </p>
                  )}

                  <p className="text-sub leading-5 text-[var(--text-muted)]">
                    {t.rich("library.subtitleGeneration.outputHint", { filename: () => (
                      <span className="tnum ml-1 break-all text-white/80">
                        {preview.output_filename ?? t("library.subtitleGeneration.defaultFilename")}
                      </span>
                    ) })}
                  </p>

                  {preview.already_generated && (
                    <p className="rounded-lg border border-[var(--warn)]/25 bg-[var(--warn)]/[0.07] px-3 py-2 text-sub text-[var(--warn)]/90">
                      {t("library.subtitleGeneration.overwrite")}
                    </p>
                  )}
                </div>
              )}

              {!previewing && (
                <div className="mt-5 flex justify-end gap-2.5">
                  <button type="button" className={CANCEL_BUTTON} onClick={() => setDialogOpen(false)}>
                    {(preview?.blocker && !canPreparePgs) || requestError ? t("common.close") : t("common.cancel")}
                  </button>
                  {((preview?.blocker && !canPreparePgs) || (!preview && requestError)) && (
                    <button
                      type="button"
                      className={CONFIRM_BUTTON}
                      onClick={() =>
                        void loadPreview(
                          targetLanguage,
                          bilingual ? secondaryLanguage : null,
                        )
                      }
                    >
                      {t("library.subtitleGeneration.recheck")}
                    </button>
                  )}
                  {((preview?.blocker && !canPreparePgs) || requestError) && (
                    <button
                      type="button"
                      className={AGENT_BUTTON}
                      disabled={agentStarting}
                      onClick={() =>
                        void handOffToAgent(
                          requestError ?? preview?.blocker?.message ?? t("library.subtitleGeneration.preflightFailed"),
                        )
                      }
                    >
                      {agentStarting ? t("library.subtitleGeneration.handingOff") : t("library.subtitleGeneration.handoff")}
                    </button>
                  )}
                  {canPreparePgs && (
                    <button
                      type="button"
                      className={CONFIRM_BUTTON}
                      disabled={starting || !canConvertPgs}
                      onClick={() => void onStart()}
                    >
                      {starting
                        ? t("library.subtitleGeneration.starting")
                        : t("library.subtitleGeneration.startOutput", { output: outputLabel(targetLanguage, bilingual ? secondaryLanguage : null, locale) })}
                    </button>
                  )}
                  {preview && !preview.blocker && chosen && (
                    <button
                      type="button"
                      className={CONFIRM_BUTTON}
                      disabled={starting}
                      onClick={() => void onStart()}
                    >
                      {starting
                        ? t("library.subtitleGeneration.starting")
                        : t("library.subtitleGeneration.confirmOutput", { output: outputLabel(targetLanguage, bilingual ? secondaryLanguage : null, locale) })}
                    </button>
                  )}
                </div>
              )}
            </div>
          )}
        </div>
      </Modal>
    </>
  );
}
