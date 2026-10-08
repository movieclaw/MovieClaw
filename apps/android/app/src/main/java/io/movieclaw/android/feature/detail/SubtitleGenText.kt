package io.movieclaw.android.feature.detail

import io.movieclaw.android.core.model.SubtitleGenCandidateView

/**
 * AI 字幕生成的文案与格式化（逐字照 iOS `TrackGenText` / Web `subtitle-gen-panel.tsx`，
 * 「同一条轨在三端叫同一个名字」）。这些是**用户可见文案**，不要在别处另写一套。
 */
internal object SubtitleGenText {

    /** 可选的输出语言（12 项，token → 中文名；与服务端 tasks.py 同一张表） */
    val outputLanguages: List<Pair<String, String>> = listOf(
        "chs" to "简体中文", "cht" to "繁体中文", "eng" to "英语", "jpn" to "日语",
        "kor" to "韩语", "fre" to "法语", "ger" to "德语", "spa" to "西班牙语",
        "ita" to "意大利语", "por" to "葡萄牙语", "rus" to "俄语", "tha" to "泰语",
    )

    private val outputLanguageNames = outputLanguages.toMap()

    /** 候选字幕的语言码 → 中文名（比输出语言多几个别名；未收录的原样大写） */
    private val candidateLanguageNames = mapOf(
        "chi" to "中文", "chs" to "简体中文", "cht" to "繁体中文", "eng" to "英语",
        "fre" to "法语", "fra" to "法语", "ger" to "德语", "ita" to "意大利语",
        "jpn" to "日语", "kor" to "韩语", "por" to "葡萄牙语", "rus" to "俄语",
        "spa" to "西班牙语", "tha" to "泰语",
    )

    private val formatNames = mapOf(
        "hdmv_pgs_subtitle" to "PGS", "dvd_subtitle" to "VobSub",
        "subrip" to "SRT", "srt" to "SRT", "ass" to "ASS", "ssa" to "SSA",
        "webvtt" to "VTT", "vtt" to "VTT",
    )

    private val provenanceNames = mapOf(
        "original" to "原始字幕", "pgs_ocr" to "图片字幕识别结果",
        "ai" to "AI 字幕", "ai_bilingual" to "AI 双语成品",
    )

    /** 五阶段清单（当前节点右侧标「进行中」）；OCR 任务首阶段改名 */
    val stages = listOf("准备并检查字幕", "统一人名与术语", "翻译对白", "检查字幕质量", "保存并更新字幕")
    const val stageOcr = "识别并检查图片字幕"

    private val phaseStages = mapOf(
        "preparing" to 0, "extracting" to 0, "ocr" to 0, "syncing" to 0,
        "glossary" to 1, "translating" to 2, "validating" to 3, "compressing" to 3,
        "writing" to 4, "refreshing" to 4,
    )

    /** 当前阶段下标（未命中记 0，同 iOS） */
    fun stageIndex(phase: String): Int = phaseStages[phase] ?: 0

    fun outputLanguage(token: String): String = outputLanguageNames[token] ?: token.uppercase()

    /** 输出语言标签：单选=语言名；双语=`{主} + {次}双语` */
    fun outputLabel(target: String, secondary: String?): String = if (secondary.isNullOrBlank()) {
        outputLanguage(target)
    } else {
        "${outputLanguage(target)} + ${outputLanguage(secondary)}双语"
    }

    /** 候选字幕的显示名：`{语言} · {格式} · {来源} · {内封|外挂} {身份}[ · 需先识别]` */
    fun candidateLabel(candidate: SubtitleGenCandidateView): String {
        val language = candidateLanguageNames[candidate.language?.lowercase()]
            ?: candidate.language?.takeIf { it.isNotBlank() }?.uppercase() ?: "未知语言"
        val format = formatNames[candidate.format?.lowercase()]
            ?: candidate.format?.takeIf { it.isNotBlank() }?.uppercase() ?: "未知格式"
        val provenance = provenanceNames[candidate.provenance] ?: candidate.provenance
        val identity = if (candidate.kind == "embedded") {
            "内封 轨道 ${candidate.key.toIntOrNull()?.plus(1) ?: candidate.key}"
        } else {
            "外挂 ${candidate.key}"
        }
        val ocr = if (candidate.requiresOcr) " · 需先识别" else ""
        return "$language · $format · $provenance · $identity$ocr"
    }

    /** 参考字幕引用的短名（进度行用）：内封轨道 N / 文件名 */
    fun sourceKeyLabel(key: String?): String {
        if (key.isNullOrBlank()) return "—"
        if (key.startsWith("embedded:")) {
            val index = key.removePrefix("embedded:").toIntOrNull()
            return if (index == null) "内封字幕" else "内封轨道 ${index + 1}"
        }
        if (key.startsWith("external:")) return key.removePrefix("external:")
        return key
    }

    /** 运行中徽章的文案（phase + percent；逐字照 iOS `runningBadgeText`） */
    fun runningBadgeText(phase: String, percent: Float?, extractQueued: Boolean): String {
        val p = percent?.takeIf { it.isFinite() }?.coerceIn(0f, 100f)?.toInt()
        return when (phase) {
            "translating" -> if (p != null) "AI $p%" else "翻译中"
            "extracting" -> when {
                extractQueued -> "排队读取"
                p != null -> "读取 $p%"
                else -> "读取字幕"
            }
            "preparing" -> "准备中"
            "ocr" -> "识别中"
            "syncing" -> "同步检查"
            "glossary" -> "术语分析"
            "validating" -> "质量检查"
            "compressing" -> "质量优化"
            "writing" -> "保存中"
            "refreshing" -> "更新中"
            else -> "生成中"
        }
    }

    /** token 估算：约 1,234 token / 约 12.3k token / 约 45k token */
    fun tokenEstimate(tokens: Long): String = when {
        tokens < 1_000 -> "约 ${grouped(tokens)} token"
        tokens < 10_000 -> "约 ${"%.1f".format(tokens / 1000.0)}k token"
        else -> "约 ${tokens / 1000}k token"
    }

    /** 时长：45 秒 / 3 分 20 秒 / 2 小时 5 分 */
    fun duration(seconds: Long): String = when {
        seconds < 60 -> "$seconds 秒"
        seconds < 3_600 -> "${seconds / 60} 分 ${seconds % 60} 秒"
        else -> "${seconds / 3_600} 小时 ${(seconds % 3_600) / 60} 分"
    }

    /** 千分位（对白条数、token 数） */
    fun grouped(value: Long): String = "%,d".format(value)

    /** 文件名是不是 AI 字幕产物（`{stem}.ai.srt` / `.ai-xxx.srt`；同 iOS/网页） */
    fun isAiSubtitle(fileName: String): Boolean = fileName.lowercase()
        .split('.')
        .any { it == "ai" || it.startsWith("ai-") }
}
