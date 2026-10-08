package io.movieclaw.android.core.playback

/**
 * 字幕统一解析成「纯文本 cue」——iOS `SubtitleOverlay.WebVTT` 的对应物。
 *
 * iOS 的做法值得照抄：**字幕文件自带的样式一律不要**。原话是
 *   「富文本标签一律剥掉（同 Web `plainCueText`）：字幕文件是用户丢进媒体库的任意文本，
 *     斜体这点观感不值得引入一个富文本解析器；cue 设置（line/position）也忽略——
 *     位置由播放器的『字幕位置』统一控制，与网页一致。」
 *
 * 这也解释了为什么"黑框"怎么改样式都去不掉：字幕组把描边/底框直接写进了每一条事件里
 * （`{\bord20\shad0\3c&H000000&}`），优先级高于样式行。iOS 根本不喂文件给渲染器，
 * 所以从结构上就不可能带上文件自带的框。
 *
 * 支持 SRT / WebVTT / ASS / SSA；解析不出 cue 返回空列表（调用方回落引擎自带渲染）。
 */
object SubtitleCues {

    data class Cue(val startMs: Long, val endMs: Long, val text: String)

    /** HTML 富文本标签（SRT/VTT 里常见） */
    private val HTML_TAG = Regex("<[^>]*>")

    /** ASS/SSA 的覆盖块 {\bord20\shad0...} / {\pos(..)} 等 */
    private val ASS_BLOCK = Regex("\\{[^}]*\\}")

    fun parse(bytes: ByteArray): List<Cue> {
        val text = String(bytes, Charsets.UTF_8)
        return if (text.contains("[Events]") && text.contains("Dialogue:")) parseAss(text) else parseSrtOrVtt(text)
    }

    // ---------- ASS / SSA ----------

    private fun parseAss(text: String): List<Cue> {
        var section = ""
        var fields: List<String>? = null
        val out = mutableListOf<Cue>()
        for (raw in text.split("\n")) {
            val line = raw.trim()
            if (line.startsWith("[") && line.endsWith("]")) {
                section = line
                continue
            }
            if (section != "[Events]") continue
            if (line.startsWith("Format:")) {
                fields = line.removePrefix("Format:").split(",").map { it.trim() }
                continue
            }
            if (!line.startsWith("Dialogue:")) continue
            val f = fields ?: continue
            // 正文里可能有逗号：按 Format 的 Text 列切，只切前 n 个逗号
            val textIndex = f.indexOf("Text").takeIf { it >= 0 } ?: continue
            val parts = line.removePrefix("Dialogue:").trim().split(",", limit = textIndex + 1)
            if (parts.size < textIndex + 1) continue
            val start = parseAssTime(parts.getOrNull(f.indexOf("Start"))) ?: continue
            val end = parseAssTime(parts.getOrNull(f.indexOf("End"))) ?: continue
            val body = parts[textIndex].plainDialogue()
            if (body.isNotEmpty()) out.add(Cue(start, end, body))
        }
        return out.sortedBy { it.startMs }
    }

    /** `H:MM:SS.CC`（ASS 的时间轴，百分秒） */
    private fun parseAssTime(raw: String?): Long? {
        val s = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val parts = s.split(":")
        if (parts.size !in 2..3) return null
        var seconds = 0.0
        for (part in parts) {
            val v = part.toDoubleOrNull() ?: return null
            seconds = seconds * 60 + v
        }
        return (seconds * 1000).toLong()
    }

    // ---------- SRT / WebVTT ----------

    private fun parseSrtOrVtt(text: String): List<Cue> {
        val normalized = text.replace("\r\n", "\n").replace("\r", "\n")
        val out = mutableListOf<Cue>()
        for (block in normalized.split("\n\n")) {
            val lines = block.split("\n")
            val timingIndex = lines.indexOfFirst { it.contains("-->") }
            if (timingIndex < 0) continue
            val timing = lines[timingIndex].split("-->")
            if (timing.size != 2) continue
            val start = parseClock(timing[0]) ?: continue
            // 结束时间后面可能跟着 cue 设置（VTT 的 `line:84%` / `align:start`），只取第一个词
            val end = parseClock(timing[1].trim().split(" ").firstOrNull()) ?: continue
            val body = lines.drop(timingIndex + 1)
                .joinToString("\n")
                .plainDialogue()
            if (body.isNotEmpty()) out.add(Cue(start, end, body))
        }
        return out.sortedBy { it.startMs }
    }

    /** `hh:mm:ss.mmm` / `hh:mm:ss,mmm` / `mm:ss.mmm` */
    private fun parseClock(raw: String?): Long? {
        val s = raw?.trim()?.replace(',', '.')?.takeIf { it.isNotEmpty() } ?: return null
        val parts = s.split(":")
        if (parts.size !in 2..3) return null
        var seconds = 0.0
        for (part in parts) {
            val v = part.toDoubleOrNull() ?: return null
            seconds = seconds * 60 + v
        }
        return (seconds * 1000).toLong()
    }

    /**
     * 一行/一段字幕文本的清洗：剥富文本标签、还原实体、把 ASS 的换行转成真换行。
     * 与 Web `plainCueText`、iOS `WebVTT.parse` 同一口径。
     */
    private fun String.plainDialogue(): String =
        ASS_BLOCK.replace(this) { "" }          // 二次保险：SRT 里也有塞 ASS 标签的
            .let { HTML_TAG.replace(it, "") }
            .replace("\\N", "\n")
            .replace("\\n", "\n")
            .replace("\\h", " ")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&nbsp;", " ")
            .trim()

    /**
     * 当前该显示的 cue（可能多条重叠，最多 3 条——iOS `WebVTT.active` 同款上限）。
     * [timeMs] 已经扣掉过时间轴偏移。
     */
    fun active(cues: List<Cue>, timeMs: Long): List<Cue> {
        if (cues.isEmpty()) return emptyList()
        var low = 0
        var high = cues.size
        while (low < high) {
            val mid = (low + high) / 2
            if (cues[mid].startMs <= timeMs) low = mid + 1 else high = mid
        }
        val result = mutableListOf<Cue>()
        var index = low - 1
        while (index >= 0 && result.size < 3) {
            val cue = cues[index]
            if (cue.endMs > timeMs) result.add(0, cue)
            if (timeMs - cue.startMs > 30_000) break
            index--
        }
        return result
    }
}
