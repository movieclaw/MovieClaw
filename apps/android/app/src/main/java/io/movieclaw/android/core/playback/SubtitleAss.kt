package io.movieclaw.android.core.playback

import java.util.Locale

/**
 * 字幕格式适配 —— libass 只接受 **ASS/SSA**，而库里/服务端的外挂字幕大量是 **SRT**，
 * 所以喂给 libass 之前要在这里转换（mpv 内部也是先转 ASS 再交给 libass 的）。
 *
 * 默认样式取 iOS 的默认观感：**白字、无底框**、黑描边 + 轻描影、底部居中。
 * 「背景」开关打开时才走带底框的样式（iOS 的字幕样式菜单）。
 */
object SubtitleAss {

    private fun assTime(ms: Long): String {
        val t = ms.coerceAtLeast(0)
        val h = t / 3_600_000
        val m = (t % 3_600_000) / 60_000
        val s = (t % 60_000) / 1000
        val cs = (t % 1000) / 10
        return "%d:%02d:%02d.%02d".format(h, m, s, cs)
    }

    /** 简易 SRT 时间轴解析：`00:00:01,000 --> 00:00:04,000`（逗号或点都认） */
    private data class Cue(val start: Long, val end: Long, val text: String)

    private fun parseTime(raw: String): Long? {
        val clean = raw.trim().replace(',', '.')
        val parts = clean.split(":")
        if (parts.size < 3) return null
        return try {
            val h = parts[0].toLong()
            val m = parts[1].toLong()
            val sec = parts[2].toDouble()
            (h * 3600 + m * 60) * 1000 + (sec * 1000).toLong()
        } catch (_: NumberFormatException) {
            null
        }
    }

    private fun parseSrt(content: String): List<Cue> {
        val cues = mutableListOf<Cue>()
        val blocks = content.replace("\r\n", "\n").replace('\r', '\n').split(Regex("\n\\s*\n"))
        for (block in blocks) {
            val lines = block.split('\n').filter { it.isNotBlank() }
            if (lines.isEmpty()) continue
            val timeLineIdx = lines.indexOfFirst { it.contains("-->") }
            if (timeLineIdx < 0) continue
            val (a, b) = lines[timeLineIdx].split("-->").let {
                if (it.size < 2) return@let null to null
                // 先 trim 再切「位置」后缀：SRT 的右半边常以空格开头，
                // 直接 substringBefore(' ') 会把整串切成空（实机踩过：转换器输出与输入等长）
                parseTime(it[0]) to parseTime(it[1].trim().substringBefore(' '))
            }
            if (a == null || b == null) continue
            val text = lines.drop(timeLineIdx + 1).joinToString("\\N")
                .replace(Regex("<[^>]+>"), "")   // 去掉 SRT 里的 HTML 标签
            if (text.isNotBlank()) cues += Cue(a, b, text)
        }
        return cues
    }

    /** 该字幕是不是 ASS/SSA（已经是就直接用，不再转换） */
    fun isAss(bytes: ByteArray): Boolean {
        val head = String(bytes, 0, minOf(bytes.size, 512), Charsets.UTF_8)
        return head.contains("[Script Info]") || head.contains("[V4+ Styles]") || head.contains("[V4 Styles]")
    }


    /**
     * 改写 ASS 的样式行 —— **确定性做法**，不依赖 libass 的覆盖 API：
     * 解析 `[V4+ Styles]` 的 Format 行得到字段顺序，然后把每个 Style 行里的
     * 字体/字号/颜色/描边/底色/对齐/边距换成本项目的值。
     *
     * 字号按**文件自己的 PlayResY** 换算（2.8% × PlayResY），这样无论字幕文件
     * 声明的是 288 还是 1080 坐标，上屏后的视觉大小都一致；定位标签不受影响。
     */
    private fun rewriteAssStyles(text: String, style: SubtitleStyle): String {
        val playResY = Regex("PlayResY:\\s*(\\d+)").find(text)?.groupValues?.get(1)?.toIntOrNull() ?: 288
        val fontSize = (playResY * style.fontPercent / 100.0).coerceIn(8.0, 200.0)
        val marginV = playResY * style.bottomPercent / 100.0
        // 背景关：描边归零、只留一层柔和投影（iOS「不开背景时白字带柔和投影，不做描边」）——
        // 之前那版描边 2 + 透明底就是用户连着报的"字幕带黑框"。
        // 背景开：走 BorderStyle 4 的整行底框，描边退化成底框内边距。
        val outline = if (style.background) playResY * 0.0012 else 0.0
        val shadow = if (style.background) 0.0 else playResY * 0.0022
        // ASS 的 Shadow 用的就是 BackColour，所以"投影"靠它；不设就是纯透明、什么也投不出来
        val back = if (style.background) "&H99000000" else "&H7F000000"
        val borderStyle = if (style.background) "4" else "1"
        val canon = CanonicalStyle(fontSize, outline, shadow, back, borderStyle, marginV)

        val out = StringBuilder()
        var fields: List<String>? = null
        var eventFields: List<String>? = null
        var stripped = 0
        var styleNames = 0
        // 必须按**段**判断 Format 是样式段还是事件段：两者都叫 "Format:"，
        // 只按"文件里有没有 [Events]"去猜，会让样式段的 Format 被事件段吃掉，
        // 结果一条 Style 都没改写（黑框原样留着）。
        var section = ""
        for (line in text.split("\n")) {
            val trimmed = line.trim()
            if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
                section = trimmed
                // 样式段整个换成**我们自己的规范段**：只保留原样式名（事件按名字引用），
                // 字段顺序一律按 V4+ 排。原文件的 Format 与 Style 行列数对不上时，
                // 按列号写值会整体错位——BorderStyle 就停在文件自带的 4（黑框），
                // 这种"整行都有框"的片子就是这么来的。Ssa 的 [V4 Styles] 也并到这里。
                if (trimmed == "[V4+ Styles]" || trimmed == "[V4 Styles]") {
                    out.append("[V4+ Styles]").append("\n")
                    out.append(CANONICAL_STYLE_FORMAT).append("\n")
                    fields = CANONICAL_STYLE_FIELDS
                } else {
                    out.append(line).append("\n")
                }
                continue
            }
            when {
                // 样式段原来的 Format 行：已经换成我们自己的了，丢掉
                trimmed.startsWith("Format:") &&
                    (section == "[V4+ Styles]" || section == "[V4 Styles]") -> Unit
                // 事件段的 Format：Text 在第几个字段，决定从哪儿切出正文
                trimmed.startsWith("Format:") && eventFields == null && section == "[Events]" ->
                    eventFields = trimmed.removePrefix("Format:").split(",").map { it.trim() }
                trimmed.startsWith("Dialogue:") && section == "[Events]" -> {
                    val f = eventFields
                    val textIndex = f?.indexOf("Text") ?: -1
                    if (textIndex < 0) {
                        out.append(line).append("\n")
                    } else {
                        // 只切前 textIndex 个逗号，正文里的逗号原样留着
                        val parts = trimmed.split(",", limit = textIndex + 1).toMutableList()
                        if (parts.size == textIndex + 1) {
                            val before = parts[textIndex]
                            parts[textIndex] = stripBoxTags(before)
                            stripped += countBoxTags(before)
                        }
                        out.append(parts.joinToString(",")).append("\n")
                    }
                }
                trimmed.startsWith("Style:") && fields != null -> {
                    // 原样式的名字（第一列；SSA/ASS 都是）——事件全靠它引用样式
                    val name = trimmed.removePrefix("Style:").split(",").firstOrNull()?.trim().orEmpty()
                    styleNames++
                    out.append(canonicalStyleLine(name.ifEmpty { "Default" }, canon)).append("\n")
                }
                else -> out.append(line).append("\n")
            }
        }
        if (stripped > 0) {
            android.util.Log.i("McAss", "剥掉正文里的描边/底框内联标签 $stripped 处（字幕文件自带的黑框就出在这里）")
        }
        if (styleNames > 0) {
            android.util.Log.i(
                "McAss",
                "样式改写 $styleNames 条：字号 ${String.format(Locale.US, "%.1f", fontSize)}" +
                    "（PlayResY $playResY 的 ${style.fontPercent}%）· 描边 $outline · 投影 $shadow" +
                    " · 底框档 $borderStyle · 底距 ${String.format(Locale.US, "%.0f", marginV)}",
            )
        }
        return out.toString()
    }

    /**
     * 去掉**正文内联**的描边/底框/颜色覆盖。
     *
     * 改 `Style:` 行不等于样式全改了：字幕组做特效时会把 `{\bord20\shad0\3c&H000000&}` 这类
     * 覆盖直接写进每一条 Dialogue，优先级高于样式行——于是"某一行带一个黑框、另一行没有"
     * 这种一事件一例的怪相就出来了（实机截图确认）。`\r`（重置回样式）不动：它重置到的
     * 样式已经被改成干净的了。
     */
    private fun stripBoxTags(text: String): String = BOX_TAG.replace(text) { "" }

    private fun countBoxTags(text: String): Int = BOX_TAG.findAll(text).count()

    /** 我们自己的样式行：字段顺序与 [CANONICAL_STYLE_FORMAT] 严格一致，不再看原文件的排布 */
    private fun canonicalStyleLine(name: String, p: CanonicalStyle): String =
        buildString {
            append("Style: ").append(name).append(",sans-serif,")
            append(String.format(Locale.US, "%.1f", p.fontSize)).append(',')
            append("&H00FFFFFF,&H000000FF,&H00000000,").append(p.back).append(',')
            append("0,0,0,0,100,100,0,0,")
            append(p.borderStyle).append(',')
            append(String.format(Locale.US, "%.1f", p.outline)).append(',')
            append(String.format(Locale.US, "%.1f", p.shadow)).append(',')
            append("2,40,40,")
            append(String.format(Locale.US, "%.0f", p.marginV)).append(",1")
        }

    private data class CanonicalStyle(
        val fontSize: Double,
        val outline: Double,
        val shadow: Double,
        val back: String,
        val borderStyle: String,
        val marginV: Double,
    )

    private val CANONICAL_STYLE_FIELDS = listOf(
        "Name", "Fontname", "Fontsize", "PrimaryColour", "SecondaryColour", "OutlineColour",
        "BackColour", "Bold", "Italic", "Underline", "StrikeOut", "ScaleX", "ScaleY", "Spacing",
        "Angle", "BorderStyle", "Outline", "Shadow", "Alignment", "MarginL", "MarginR", "MarginV",
        "Encoding",
    )

    private val CANONICAL_STYLE_FORMAT = "Format: " + CANONICAL_STYLE_FIELDS.joinToString(", ")

    private val BOX_TAG = Regex("""\\(x?y?bord|x?y?shad|3c|4c|3a|4a|be|blur)(&H[0-9A-Fa-f]+&|[\d.]+)?""")

    /**
     * 把字幕统一成 ASS 交给 libass。
     * - 已是 ASS → 原样返回
     * - SRT → 转换
     * - 其它（VTT/SUB 等）→ 尽力按 SRT 规则解析（时间轴格式兼容 VTT 的 `00:00:01.000`）
     */
    fun toAss(bytes: ByteArray, width: Int, height: Int, style: SubtitleStyle = SubtitleStyle()): ByteArray {
        val content = String(bytes, Charsets.UTF_8)
        // ASS/SSA 也要**改写样式**：字幕文件自带的字号/重描边/底框会盖过 libass 的覆盖设置
        // （实机截图验证过），直接改文本最可靠
        if (isAss(bytes)) return rewriteAssStyles(content, style).toByteArray(Charsets.UTF_8)
        val cues = parseSrt(content)
        if (cues.isEmpty()) return bytes      // 解析不出就原样交给 libass（让它自己判断）

        // 生成的样式与 rewriteAssStyles 用同一套换算，保证 SRT 与 ASS 两条路上屏大小一致
        val fontSize = (height * style.fontPercent / 100f).toInt().coerceIn(10, 200)
        val borderStyle = if (style.background) 4 else 1
        val backColour = if (style.background) "&H99000000" else "&H7F000000"
        val outline = if (style.background) height * 0.0012f else 0f
        val shadow = if (style.background) 0f else height * 0.0022f

        val sb = StringBuilder()
        sb.append("[Script Info]\n")
        sb.append("ScriptType: v4.00+\n")
        sb.append("WrapStyle: 0\n")
        sb.append("PlayResX: ").append(width).append('\n')
        sb.append("PlayResY: ").append(height).append('\n')
        sb.append("ScaledBorderAndShadow: yes\n\n")
        sb.append("[V4+ Styles]\n")
        sb.append("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n")
        sb.append("Style: Default,sans-serif,").append(fontSize)
            .append(",&H00FFFFFF,&H000000FF,&H00000000,").append(backColour)
            .append(",0,0,0,0,100,100,0,0,").append(borderStyle)
            .append(',').append(String.format(Locale.US, "%.1f", outline))
            .append(',').append(String.format(Locale.US, "%.1f", shadow))
            .append(",2,40,40,")
            .append((height * style.bottomPercent / 100f).toInt().coerceAtLeast(0)).append(",1\n\n")
        sb.append("[Events]\n")
        sb.append("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")
        for (c in cues) {
            sb.append("Dialogue: 0,").append(assTime(c.start)).append(',').append(assTime(c.end))
                .append(",Default,,0,0,0,,").append(c.text).append('\n')
        }
        return sb.toString().toByteArray(Charsets.UTF_8)
    }
}
