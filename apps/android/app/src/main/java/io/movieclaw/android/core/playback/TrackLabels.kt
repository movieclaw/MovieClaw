package io.movieclaw.android.core.playback

/**
 * 语言代码 → 中文名（对应 Web `lib/language-labels.ts` / iOS `LanguageLabel`）：
 * **同一条轨在详情页与播放器里必须叫同一个名字**，否则用户会觉得"跟服务端不一致"。
 */
object LanguageLabel {
    private val labels = mapOf(
        "chs" to "简体中文", "cht" to "繁体中文", "chi" to "中文", "zho" to "中文", "cmn" to "中文",
        "yue" to "粤语", "eng" to "英语", "jpn" to "日语", "kor" to "韩语", "fre" to "法语",
        "fra" to "法语", "ger" to "德语", "deu" to "德语", "spa" to "西班牙语", "rus" to "俄语",
        "ita" to "意大利语", "por" to "葡萄牙语", "tha" to "泰语", "hin" to "印地语",
    )

    /** 未知语言（und）与空值返回 null，由调用方决定占位文案 */
    fun of(code: String?): String? {
        val c = code?.trim().orEmpty()
        if (c.isEmpty() || c.equals("und", ignoreCase = true)) return null
        return labels[c.lowercase()] ?: c
    }
}

/**
 * 播放器里一条可选轨的名字与可用性，与 iOS `PlayerTracks` 同口径：
 *   · 音轨：`语言 · 编码 · 声道`（语言放最前——用户找的是"国语还是日语"）
 *   · 字幕：`语言 · 类型`（文本/特效/图形），语言缺失时退回轨引用
 *   · 放不了/拿不到的轨**不藏起来**，而是置灰写明原因：点了没反应比置灰更让人困惑
 */
object TrackLabels {

    private val channelLabels = mapOf(1 to "单声道", 2 to "立体声", 6 to "5.1", 8 to "7.1")

    private val subtitleKindLabels = mapOf("vtt" to "文本", "ass" to "特效", "ssa" to "特效", "pgs" to "图形")

    fun audio(language: String?, codec: String?, channels: Int?, ref: String): String {
        val name = LanguageLabel.of(language) ?: refLabel(ref, "音轨", "未知音轨")
        val rest = buildList {
            if (!codec.isNullOrBlank()) add(codec.uppercase())
            if (channels != null && channels > 0) add(channelLabels[channels] ?: "${channels} 声道")
        }
        return (listOf(name) + rest).joinToString(" · ")
    }

    /**
     * 字幕轨的名字。**优先用文件自带的标题**（服务端把 `title` 贯通到客户端，iOS / 网页同口径）：
     * 文件里常写「简体中文」「简英双语」「SDH」这类比语言码更准的名字；没有标题才退回
     * 语言码 → 轨引用。强制轨在末尾打「强制」（iOS `SubtitleOption.detail` 同款）。
     */
    fun subtitle(
        language: String?,
        kind: String?,
        ref: String,
        isAi: Boolean,
        title: String? = null,
        isForced: Boolean = false,
    ): String {
        val name = title?.trim()?.takeIf { it.isNotEmpty() }
            ?: LanguageLabel.of(language)
            ?: refLabel(ref, "内封轨", "未知语言")
        val kindLabel = subtitleKindLabels[kind?.lowercase()]
        return (
            listOfNotNull(name, kindLabel) +
                listOfNotNull(if (isAi) "AI 生成" else null, if (isForced) "强制" else null)
            ).joinToString(" · ")
    }

    /** 没有语言标记时的兜底名：外挂轨用文件名，内封轨用序号 */
    private fun refLabel(ref: String, embeddedPrefix: String, fallback: String): String = when {
        ref.startsWith("external:") -> ref.removePrefix("external:")
        ref.startsWith("embedded:") -> "$embeddedPrefix ${ref.removePrefix("embedded:")}"
        else -> fallback
    }
}
