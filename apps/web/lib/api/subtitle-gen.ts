import { request } from "@/lib/http";
import type { JobView } from "@/lib/api/jobs";

/** 后端统一响应信封（见 movieclaw_api.schemas.response.ApiResponse） */
interface ApiEnvelope<T> {
  success: boolean;
  code: string;
  message: string;
  data: T;
}

async function unwrap<T>(promise: Promise<ApiEnvelope<T>>): Promise<T> {
  return (await promise).data;
}

/**
 * AI 字幕生成（docs/design/subtitle-ai-translate.md）：选源 → 同步质检 →
 * LLM 翻译 → 机检 → 落盘外挂 sidecar。管理员专属（消费 LLM 配额）。
 */

/** 一个候选参考字幕的打分结论（预检确认框展示）。 */
export interface SubtitleSourceCandidate {
  /** audio = 没有任何可用字幕时，由本地语音模型从这条音轨识别台词（docs/design/subtitle-asr.md） */
  kind: "embedded" | "external" | "audio";
  key: string;
  language: string | null;
  format: string | null;
  provenance: "original" | "pgs_ocr" | "asr" | "ai" | "ai_bilingual";
  /** 非空 = 被排除原因（forced/目标语言/图形轨） */
  excluded: string | null;
  /** 打分明细："为什么选了这条"要能看懂 */
  reasons: string[];
  /** 文本轨可直接选，PGS 可选后进入 OCR。 */
  selectable: boolean;
  requires_ocr: boolean;
}

export interface SubtitleGenerationPreview {
  candidates: SubtitleSourceCandidate[];
  /** "kind:key"；null = 没有可用参考 */
  chosen_key: string | null;
  /** 用户指定或默认英语策略实际选中的候选，PGS 也会有值。 */
  selected_source_key: string | null;
  event_count: number;
  estimated_tokens: number;
  /** 目标语言 AI 字幕已存在（再生成 = 覆盖） */
  already_generated: boolean;
  warnings: string[];
  /** 仅有 PGS 图形字幕时的转换候选与服务端运行环境检测。 */
  pgs_conversion: {
    candidate_key: string;
    language: string | null;
    available: boolean;
    engine: string | null;
    platform: string;
    architecture: string;
    cached: boolean;
    message: string;
    suggestions: string[];
    /** PGS 图片里的语言；与最终翻译目标语言无关。 */
    ocr_language: string | null;
    ocr_language_label: string | null;
    language_confirmation_required: boolean;
    language_reason: string;
    language_options: Array<{ code: string; label: string }>;
  } | null;
  /** 无法生成时的稳定原因与可执行建议；可生成时为 null。 */
  blocker: {
    code: string;
    title: string;
    message: string;
    suggestions: string[];
  } | null;
  /** 规范化后的最终外挂字幕文件名。 */
  output_filename: string | null;
  /**
   * 非空 = 参考字幕还没读取过（内封轨首次使用）：确认后由任务第一步读取。
   * 此时 event_count 为 0，estimated_tokens 按片长粗估。
   */
  reference_notice: string | null;
}

export interface CalibrateResult {
  ok: boolean;
  message: string;
  scale: number | null;
  offset_ms: number | null;
  score: number | null;
  message_key?: string | null;
  params?: Record<string, unknown>;
}

/**
 * 生成预检：选源结果 + 成本估算（确认框素材，不动 LLM）。
 *
 * 后端保证这个接口只读数据库与现成产物，**不会**读视频：内封轨没读过就照常
 * 选中、按片长粗估，读取交给生成任务第一步（issue #432 及其后续）。所以这里
 * 可以放心给一个短超时——超过它就是真的不对劲，而不是「文件大，再等等」。
 */
const PREVIEW_TIMEOUT_MS = 20_000;

export function previewSubtitleGeneration(
  fileId: number,
  targetLanguage = "chs",
  secondaryLanguage: string | null = null,
  sourceCandidateKey: string | null = null,
  signal?: AbortSignal,
  retranscribe = false,
): Promise<SubtitleGenerationPreview> {
  const query = new URLSearchParams({ target_language: targetLanguage });
  if (secondaryLanguage) query.set("secondary_language", secondaryLanguage);
  if (sourceCandidateKey) query.set("source_candidate_key", sourceCandidateKey);
  if (retranscribe) query.set("retranscribe", "true");
  return unwrap(
    request<ApiEnvelope<SubtitleGenerationPreview>>(
      `/libraries/files/${fileId}/subtitles/generation-preview?${query}`,
      { signal },
      { timeoutMs: PREVIEW_TIMEOUT_MS },
    ),
  );
}

/** 发起生成（后台执行，不在请求里读视频；相同文件与输出语言已在跑时返回已有任务）。 */
export function generateSubtitles(
  fileId: number,
  targetLanguage = "chs",
  options: {
    convertPgs?: boolean;
    pgsOcrLanguage?: string | null;
    secondaryLanguage?: string | null;
    sourceCandidateKey?: string | null;
    /** 参考选的是音轨时不用上次的识别结果，重新识别（默认复用） */
    retranscribe?: boolean;
  } = {},
): Promise<JobView> {
  const {
    convertPgs = false,
    pgsOcrLanguage = null,
    secondaryLanguage = null,
    sourceCandidateKey = null,
    retranscribe = false,
  } = options;
  return unwrap(
    request<ApiEnvelope<JobView>>(
      `/libraries/files/${fileId}/subtitles/generations`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          target_language: targetLanguage,
          secondary_language: secondaryLanguage,
          source_candidate_key: sourceCandidateKey,
          convert_pgs: convertPgs,
          pgs_ocr_language: pgsOcrLanguage,
          retranscribe,
        }),
      },
    ),
  );
}

/** 一键校准外挂字幕时间轴（零 LLM 成本；校准后覆盖写回）。 */
export function calibrateSubtitleTiming(
  fileId: number,
  filename: string,
): Promise<CalibrateResult> {
  return unwrap(
    request<ApiEnvelope<CalibrateResult>>(
      `/libraries/files/${fileId}/subtitles/timing-calibration`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ filename }),
      },
    ),
  );
}
