package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * AI 字幕生成的预检与启动（服务端 `schemas/subtitle_gen.py`；iOS `TrackSubtitleGen.swift`
 * 的 `GenPreviewView` / `GenStartPayload` 同款）。全是管理员接口。
 */

/** 一条可作参考的字幕候选（服务端 `SourceCandidateView`）。 */
@Serializable
data class SubtitleGenCandidateView(
    /** embedded / external */
    val kind: String = "",
    /** 内封为序号字符串；外挂为文件名 */
    val key: String = "",
    val language: String? = null,
    val format: String? = null,
    /** original / pgs_ocr / ai / ai_bilingual */
    val provenance: String = "original",
    /** 不可用时给用户看的短原因（如「图形字幕」）；null = 可用 */
    val excluded: String? = null,
    val reasons: List<String> = emptyList(),
    val selectable: Boolean = true,
    /** 图片字幕：选中后要先做文字识别 */
    val requiresOcr: Boolean = false,
) {
    /** 服务端的中性引用：`kind:key`（即 `embedded:0` / `external:xxx.srt`） */
    val ref: String get() = "$kind:$key"
}

/** PGS 图片字幕：识别能力与「原字幕语言」确认（服务端 `PgsConversionView`）。 */
@Serializable
data class PgsConversionView(
    val candidateKey: String = "",
    val language: String? = null,
    val available: Boolean = false,
    val engine: String? = null,
    val platform: String = "",
    val architecture: String = "",
    val cached: Boolean = false,
    val message: String = "",
    val suggestions: List<String> = emptyList(),
    val ocrLanguage: String? = null,
    val ocrLanguageLabel: String? = null,
    /** true = 必须由用户指定原字幕语言（识别引擎认不出来） */
    val languageConfirmationRequired: Boolean = false,
    val languageReason: String = "",
    val languageOptions: List<PgsLanguageOption> = emptyList(),
)

@Serializable
data class PgsLanguageOption(val code: String = "", val label: String = "")

/** 预检走不通时的阻断项（服务端 `GenPreviewBlockerView`）。 */
@Serializable
data class SubtitleGenBlockerView(
    val code: String = "",
    val title: String = "",
    val message: String = "",
    val suggestions: List<String> = emptyList(),
)

/** 生成预检的响应（服务端 `GenPreviewView`）。 */
@Serializable
data class SubtitleGenPreviewView(
    val candidates: List<SubtitleGenCandidateView> = emptyList(),
    /** `kind:key`；null = 没有可用的参考字幕 */
    val chosenKey: String? = null,
    /** 用户指定、或英语优先策略实际选中的候选 */
    val selectedSourceKey: String? = null,
    val eventCount: Int = 0,
    val estimatedTokens: Long = 0,
    /** 目标语言的 AI 字幕已存在（再生成 = 覆盖） */
    val alreadyGenerated: Boolean = false,
    val warnings: List<String> = emptyList(),
    val pgsConversion: PgsConversionView? = null,
    val blocker: SubtitleGenBlockerView? = null,
    val outputFilename: String? = null,
    /** 非空 = 这条内封参考字幕还没读过，开跑后先通读整个容器（这一步不调 AI、不花钱） */
    val referenceNotice: String? = null,
    /** 旧服务端兼容：非空 = 还在抽，按 [retryAfterMs] 重拉 */
    val pending: PendingView? = null,
) {
    @Serializable
    data class PendingView(
        val message: String = "",
        val candidateKey: String = "",
        val retryAfterMs: Long = 2500,
    )
}

/** 启动生成（服务端 `GenStartPayload`）。 */
@Serializable
data class SubtitleGenStartPayload(
    val targetLanguage: String = "chs",
    val secondaryLanguage: String? = null,
    val sourceCandidateKey: String? = null,
    val convertPgs: Boolean = false,
    val pgsOcrLanguage: String? = null,
)

/** 停止任务（服务端 `JobCancelView`）：返回停止请求后的任务快照。 */
@Serializable
data class JobCancelView(
    val cancelled: Boolean = false,
    val job: JobView? = null,
)
