package io.movieclaw.androidtv.core.playback

/** 一条字幕。时间是**文件时间**（秒）：服务端从整个文件抽出 / 转换的字幕，时间轴与原片一致 */
data class SubtitleCue(val start: Double, val end: Double, val text: String)

/**
 * WebVTT 解析（服务端已把 SRT / ASS 统一转成 VTT，对照 Apple 端 SubtitleOverlay.swift WebVTT）。
 * 富文本标签一律剥掉、cue 设置（line / position）忽略——位置由播放器统一控制，与网页一致。
 */
object WebVtt {
    private val TAG = Regex("<[^>]*>")

    fun parse(raw: String): List<SubtitleCue> {
        val cues = mutableListOf<SubtitleCue>()
        for (block in raw.replace("\r\n", "\n").split("\n\n")) {
            val lines = block.split("\n")
            val timing = lines.indexOfFirst { it.contains("-->") }
            if (timing < 0) continue
            val parts = lines[timing].split("-->")
            if (parts.size != 2) continue
            val start = timestamp(parts[0]) ?: continue
            val end = timestamp(parts[1].trim().split(" ").first()) ?: continue
            val text = lines.drop(timing + 1)
                .joinToString("\n") { it.replace(TAG, "") }
                .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&nbsp;", " ")
                .trim()
            if (text.isNotEmpty()) cues += SubtitleCue(start, end, text)
        }
        return cues.sortedBy { it.start }
    }

    /** `hh:mm:ss.mmm` 或 `mm:ss.mmm` */
    fun timestamp(raw: String): Double? {
        val parts = raw.trim().replace(",", ".").split(":")
        if (parts.size !in 2..3) return null
        var seconds = 0.0
        for (part in parts) seconds = seconds * 60 + (part.toDoubleOrNull() ?: return null)
        return seconds
    }

    /** 当前该显示的 cue（可能多条重叠，最多 3 条） */
    fun active(cues: List<SubtitleCue>, time: Double): List<SubtitleCue> {
        var low = 0
        var high = cues.size
        while (low < high) {
            val mid = (low + high) / 2
            if (cues[mid].start <= time) low = mid + 1 else high = mid
        }
        val result = ArrayDeque<SubtitleCue>()
        var index = low - 1
        while (index >= 0 && result.size < 3) {
            val cue = cues[index]
            if (cue.end > time) result.addFirst(cue)
            if (time - cue.start > 30) break
            index -= 1
        }
        return result.toList()
    }
}
