package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.generated.AudioTrackView
import io.movieclaw.androidtv.core.model.generated.SubtitlePlanView

// 轨道清单与菜单文案：逐条对照 Apple 端 Shared/Player/PlayerTracks.swift 与 TVPlayerPanel.swift 的 TVSubtitleSections。

/** 语言代码 → 中文名（同 Web `lib/language-labels.ts`：同一条轨在详情页与播放器里叫同一个名字） */
object LanguageLabel {
    private val labels = mapOf(
        "chs" to "简体中文", "cht" to "繁体中文", "chi" to "中文", "zho" to "中文", "cmn" to "中文",
        "yue" to "粤语", "eng" to "英语", "jpn" to "日语", "kor" to "韩语", "fre" to "法语", "fra" to "法语",
        "ger" to "德语", "deu" to "德语", "spa" to "西班牙语", "rus" to "俄语", "ita" to "意大利语",
        "por" to "葡萄牙语", "tha" to "泰语", "hin" to "印地语",
    )

    /** 未知语言（und）与空值返回 null，由调用方决定占位文案；认不出的代码原样给 */
    fun of(code: String?): String? {
        if (code.isNullOrEmpty() || code == "und") return null
        return labels[code.lowercase()] ?: code
    }
}

/** 字幕菜单里的一条可选轨。[ref] 是中性轨引用（embedded:N / external:文件名），同时用作轨记忆的值 */
data class SubtitleOption(
    val ref: String,
    val label: String,
    /** vtt（文本）/ ass（特效）/ pgs（图形） */
    val kind: String,
    /** 服务端地址（已带签名 token，原格式）；引擎自己读到的内封轨为空 */
    val path: String,
    val language: String?,
    val isDefault: Boolean,
    val isAi: Boolean,
    val title: String? = null,
    val isForced: Boolean = false,
) {
    /** 内封轨的数组下标（embedded:N → N）；外挂轨为 null */
    val embeddedIndex: Int? get() = embeddedIndexOf(ref)

    val displayTitle: String
        get() {
            title?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
            embeddedIndex?.let { return "内封轨 ${it + 1}" }
            if (ref.startsWith(EXTERNAL)) return ref.removePrefix(EXTERNAL)
            return label
        }

    val detail: String
        get() {
            val parts = mutableListOf(LanguageLabel.of(language) ?: "未知语言", FORMATS[kind] ?: kind)
            val index = embeddedIndex
            if (index != null) {
                parts += if (displayTitle == "内封轨 ${index + 1}") "内封" else "内封轨 ${index + 1}"
            } else if (ref.startsWith(EXTERNAL)) {
                parts += "外挂"
            }
            if (isAi) parts += "AI 翻译"
            if (isDefault) parts += "默认"
            if (isForced) parts += "强制"
            return parts.joinToString(" · ")
        }

    private companion object {
        val FORMATS = mapOf("vtt" to "WebVTT", "ass" to "ASS", "pgs" to "PGS 图形", "text" to "文本")
    }
}

/** 拿不到的轨（连同中文原因）：菜单里置灰展示，而不是给一个点了没反应的选项 */
data class UnavailableSubtitle(val ref: String, val label: String, val reason: String)

/** 引擎（Exo）读到的一条内封轨，用来把服务端清单里没有的轨补进菜单 */
data class EngineTrack(
    val title: String?,
    val language: String?,
    /** 字幕：MIME（application/pgs、text/x-ssa、application/cea-608……）；音轨：编码名 */
    val codec: String,
    val isDefault: Boolean = false,
    val isForced: Boolean = false,
    val channels: Int? = null,
)

data class SubtitleTracks(
    val options: List<SubtitleOption> = emptyList(),
    val unavailable: List<UnavailableSubtitle> = emptyList(),
) {
    /** 选哪条轨：优先上次记住的（"off" = 用户明确关掉，必须尊重），其次服务端裁决的默认轨；都没有就不自动开 */
    fun initialSelection(remembered: String?): String? {
        if (remembered == "off") return null
        if (remembered != null && options.any { it.ref == remembered }) return remembered
        return options.firstOrNull { it.isDefault }?.ref
    }

    /**
     * 把 Exo 读到、清单里还没有的内封字幕轨补进来（服务端不提供的 DVB / VobSub、视频里带的隐藏字幕）。
     * Exo 自己读容器、自己画内封字幕，这些轨不需要服务端地址。内封轨按编号排在前、外挂轨在后（同服务端口径）。
     * 返回补过之后的清单（没变返回 null）
     */
    fun adoptEngineSubtitles(tracks: List<EngineTrack>): SubtitleTracks? {
        var options = options
        var unavailable = unavailable
        var changed = false
        tracks.forEachIndexed { index, track ->
            val ref = "embedded:$index"
            val existing = options.indexOfFirst { it.ref == ref }
            if (existing >= 0) {
                val option = options[existing]
                val title = track.title?.trim()?.takeIf { it.isNotEmpty() }
                var updated = option
                if (option.title.isNullOrBlank() && title != null) {
                    updated = updated.copy(title = title, label = "$title · ${KIND_LABELS[option.kind] ?: option.kind}")
                }
                if (track.isForced && !option.isForced) updated = updated.copy(isForced = true)
                if (updated != option) {
                    options = options.toMutableList().also { it[existing] = updated }
                    changed = true
                }
                return@forEachIndexed
            }
            if (unavailable.any { it.ref == ref }) return@forEachIndexed
            val cea608 = track.codec.contains("cea-608") || track.codec.contains("cea-708")
            val title = track.title?.trim()?.takeIf { it.isNotEmpty() }
            val name = title ?: if (cea608) "隐藏字幕（CC）" else LanguageLabel.of(track.language) ?: "内封轨 ${index + 1}"
            val kind = engineKind(track.codec)
            options = options + SubtitleOption(
                ref = ref, label = "$name · ${KIND_LABELS[kind] ?: kind}", kind = kind, path = "",
                language = track.language, isDefault = track.isDefault, isAi = false,
                title = if (cea608) name else title, isForced = track.isForced,
            )
            changed = true
        }
        if (!changed) return null
        val embedded = options.filter { it.embeddedIndex != null }.sortedBy { it.embeddedIndex }
        return SubtitleTracks(embedded + options.filter { it.embeddedIndex == null }, unavailable)
    }

    companion object {
        val KIND_LABELS = mapOf("vtt" to "文本", "ass" to "特效", "pgs" to "图形")

        /** 把决策里的字幕计划配上取流地址（与 subtitle_urls 严格一一对应，少一个就当那条没有地址） */
        fun plan(plans: List<SubtitlePlanView>, urls: List<String>): SubtitleTracks {
            val options = mutableListOf<SubtitleOption>()
            val unavailable = mutableListOf<UnavailableSubtitle>()
            plans.forEachIndexed { index, plan ->
                val label = trackLabel(plan)
                when {
                    index >= urls.size -> unavailable += UnavailableSubtitle(plan.trackRef, label, "服务端没有给出这条轨的地址")
                    plan.kind !in setOf("vtt", "ass", "pgs") ->
                        unavailable += UnavailableSubtitle(plan.trackRef, label, "暂不支持的字幕格式：${plan.kind}")
                    else -> options += SubtitleOption(
                        ref = plan.trackRef, label = label, kind = plan.kind, path = urls[index],
                        language = plan.language, isDefault = plan.isDefault, isAi = plan.isAi,
                        title = plan.title, isForced = plan.isForced == true,
                    )
                }
            }
            return SubtitleTracks(options, unavailable)
        }

        private fun trackLabel(plan: SubtitlePlanView): String {
            val name = plan.title?.trim()?.takeIf { it.isNotEmpty() } ?: LanguageLabel.of(plan.language) ?: refLabel(plan.trackRef)
            return "$name · ${KIND_LABELS[plan.kind] ?: plan.kind}"
        }

        /** 没有语言标记时的兜底名：外挂轨用文件名，内封轨用序号 */
        private fun refLabel(ref: String): String {
            if (ref.startsWith(EXTERNAL)) return ref.removePrefix(EXTERNAL)
            embeddedIndexOf(ref)?.let { return "内封轨 ${it + 1}" }
            return "未知语言"
        }

        /** Exo 报的 MIME 归到菜单的三类：图形（位图字幕）、特效（ASS）、其余都算文本 */
        fun engineKind(mime: String): String = when {
            mime.contains("pgs") || mime.contains("vobsub") || mime.contains("dvbsubs") -> "pgs"
            mime.contains("ssa") || mime.contains("ass") -> "ass"
            else -> "vtt"
        }
    }
}

/** 音轨菜单项（同 Web `lib/player/audio-tracks.ts`）。只有一条轨时返回空——没得选的菜单是纯噪音 */
data class AudioOption(
    val ref: String,
    val label: String,
    val isDefault: Boolean,
    /** 放不了的原因：菜单里置灰并写明，不给选 */
    val unavailableReason: String? = null,
) {
    val embeddedIndex: Int? get() = embeddedIndexOf(ref)

    companion object {
        const val UNRECOGNIZED_REASON = "音频编码无法识别（常见于菁彩声 Audio Vivid），没有可用的解码器"
        private val CHANNEL_LABELS = mapOf(1 to "单声道", 2 to "立体声", 6 to "5.1", 8 to "7.1")

        /** 不经用户选择时会放的轨（同服务端 `_preferred_audio`）：放得了的轨里标了默认的，没有就第一条 */
        fun defaultRef(options: List<AudioOption>): String? {
            val playable = options.filter { it.unavailableReason == null }
            val pool = playable.ifEmpty { options }
            return (pool.firstOrNull { it.isDefault } ?: pool.firstOrNull())?.ref
        }

        fun plan(tracks: List<AudioTrackView>): List<AudioOption> {
            if (tracks.size < 2) return emptyList()
            val anyRecognized = tracks.any { !unrecognized(it.codec) }
            return tracks.map {
                AudioOption(
                    ref = it.ref,
                    label = label(it.ref, it.language, it.codec, it.channels?.toInt()),
                    isDefault = it.isDefault,
                    unavailableReason = if (anyRecognized && unrecognized(it.codec)) UNRECOGNIZED_REASON else null,
                )
            }
        }

        /** 服务端一条音轨都没给时，整份用 Exo 读到的内封音轨 */
        fun engineOptions(tracks: List<EngineTrack>): List<AudioOption> {
            if (tracks.size < 2) return emptyList()
            return tracks.mapIndexed { index, track ->
                val ref = "embedded:$index"
                AudioOption(ref, label(ref, track.language, track.codec, track.channels), track.isDefault)
            }
        }

        /** 探测认不出编码的轨（服务端记为空、none）：本机与服务端转码都没有它的解码器 */
        private fun unrecognized(codec: String?): Boolean {
            val c = codec?.lowercase()
            return c.isNullOrEmpty() || c == "none" || c == "unknown"
        }

        /** 语言 · 编码 · 声道（语言放最前：用户找的是「国语还是日语」） */
        fun label(ref: String, language: String?, codec: String?, channels: Int?): String {
            val name = LanguageLabel.of(language)
                ?: if (ref.startsWith(EMBEDDED)) "音轨 ${ref.removePrefix(EMBEDDED)}" else "未知音轨"
            val rest = mutableListOf<String>()
            if (!codec.isNullOrEmpty()) rest += codec.uppercase()
            if (channels != null && channels > 0) rest += CHANNEL_LABELS[channels] ?: "$channels 声道"
            return (listOf(name) + rest).joinToString(" · ")
        }
    }
}

/** 轨道标签「语言 · 编码 · 声道」拆成主标题 + 一行小字 */
object TrackText {
    fun split(label: String): Pair<String, String?> {
        val parts = label.split(" · ")
        val rest = parts.drop(1).joinToString(" · ")
        return (parts.firstOrNull() ?: label) to rest.ifEmpty { null }
    }
}

/** 字幕栏的分组：关闭 → 正在使用 → 中文 → 英语 → 其他语言（多时折叠）。纯函数，便于单测 */
object SubtitleSections {
    sealed interface Row {
        val id: String

        data object Off : Row {
            override val id = "off"
        }

        data class Option(val option: SubtitleOption) : Row {
            override val id get() = option.ref
        }

        data class Unavailable(val item: UnavailableSubtitle) : Row {
            override val id get() = "x-${item.ref}"
        }

        /** 折叠起来的「其他语言」：条数 + 前几种语言名 */
        data class More(val count: Int, val names: String) : Row {
            override val id = "more"
        }
    }

    /** [id] 是固定身份（off / current / zh / en / other）：标题会在「正在使用」与「之前在用」间变，身份不能跟着变 */
    data class Section(val id: String, val title: String?, val rows: List<Row>)

    enum class Group { Chinese, English, Other }

    /** 轨道总数超过这么多、且「其他语言」至少这么多条时才折叠（少的时候全摆出来更直接） */
    const val COLLAPSE_TOTAL = 8
    const val COLLAPSE_OTHERS = 3

    /**
     * [selected]：排在「正在使用」里的那条（面板打开那一刻的选择）；[live]：此刻实际选中的。
     * 面板开着时换了字幕，这一组不挪位置（焦点不能丢），标题改叫「之前在用」
     */
    fun build(tracks: SubtitleTracks, selected: String?, live: String?, expanded: Boolean): List<Section> {
        val sections = mutableListOf(Section("off", null, listOf(Row.Off)))
        val current = tracks.options.firstOrNull { it.ref == selected }
        if (current != null) sections += Section("current", if (selected == live) "正在使用" else "之前在用", listOf(Row.Option(current)))
        val rest = tracks.options.filter { it.ref != current?.ref }
        val chinese = rest.filter { group(it.language) == Group.Chinese }
        val english = rest.filter { group(it.language) == Group.English }
        val others = rest.filter { group(it.language) == Group.Other }
        if (chinese.isNotEmpty()) sections += Section("zh", "中文", chinese.map(Row::Option))
        if (english.isNotEmpty()) sections += Section("en", "英语", english.map(Row::Option))
        var otherRows: List<Row> = others.map(Row::Option) + tracks.unavailable.map(Row::Unavailable)
        val total = tracks.options.size + tracks.unavailable.size
        if (!expanded && total > COLLAPSE_TOTAL && otherRows.size >= COLLAPSE_OTHERS) {
            val names = (others.map { TrackText.split(it.label).first } + tracks.unavailable.map { TrackText.split(it.label).first }).distinct()
            val shown = names.take(4).joinToString(" · ")
            otherRows = listOf(Row.More(otherRows.size, if (names.size > 4) "$shown …" else shown))
        }
        if (otherRows.isNotEmpty()) sections += Section("other", "其他语言", otherRows)
        return sections
    }

    /** 展开后焦点要落的那一条：其他语言的第一条 */
    fun firstOther(tracks: SubtitleTracks, selected: String?): SubtitleOption? =
        tracks.options.firstOrNull { it.ref != selected && group(it.language) == Group.Other }

    /** 语言标记 → 分组（各种写法：zh / chi / zho / chs / cht / zh-Hans / cmn / yue……） */
    fun group(language: String?): Group {
        val code = language?.lowercase()
        if (code.isNullOrEmpty()) return Group.Other
        if (code.startsWith("zh") || code in setOf("chi", "zho", "chs", "cht", "cmn", "yue", "chinese")) return Group.Chinese
        if (code.startsWith("en") || code == "english") return Group.English
        return Group.Other
    }
}

internal const val EMBEDDED = "embedded:"
internal const val EXTERNAL = "external:"

internal fun embeddedIndexOf(ref: String): Int? = if (ref.startsWith(EMBEDDED)) ref.removePrefix(EMBEDDED).toIntOrNull() else null
