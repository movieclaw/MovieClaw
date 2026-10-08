package io.movieclaw.android.core.designsystem

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 轻量 Markdown 渲染(对齐 iOS AgentMarkdown 的视觉规格):
 *   标题按级别缩放、列表带序号栏、引用左侧 3dp 竖条、代码块带复制按钮、
 *   表格首行浅底、行内粗体/斜体/行内码/链接/删除线。
 * 只覆盖 AI 回复真正会用的子集,不追求完整 CommonMark。
 */

private sealed interface MdBlock {
    data class Heading(val level: Int, val text: String) : MdBlock
    data class Paragraph(val text: String) : MdBlock
    data class Bullets(val items: List<Pair<Int, String>>) : MdBlock
    data class Ordered(val items: List<Pair<Int, String>>) : MdBlock
    data class Code(val language: String?, val code: String) : MdBlock
    data class Quote(val lines: List<String>) : MdBlock
    data class Table(val header: List<String>, val rows: List<List<String>>) : MdBlock
    data object Rule : MdBlock
}

private fun parseMd(source: String): List<MdBlock> {
    val lines = source.replace("\r\n", "\n").split("\n")
    val blocks = mutableListOf<MdBlock>()
    var index = 0

    while (index < lines.size) {
        val line = lines[index]
        val trimmed = line.trim()

        when {
            trimmed.isEmpty() -> index++

            trimmed.startsWith("```") -> {
                val language = trimmed.removePrefix("```").trim().ifEmpty { null }
                val body = mutableListOf<String>()
                index++
                while (index < lines.size && !lines[index].trim().startsWith("```")) {
                    body.add(lines[index])
                    index++
                }
                index++ // 跳过结束围栏
                blocks += MdBlock.Code(language, body.joinToString("\n"))
            }

            trimmed == "---" || trimmed == "***" || trimmed == "___" -> {
                blocks += MdBlock.Rule
                index++
            }

            trimmed.startsWith("#") -> {
                val level = trimmed.takeWhile { it == '#' }.length.coerceIn(1, 4)
                blocks += MdBlock.Heading(level, trimmed.drop(level).trim())
                index++
            }

            trimmed.startsWith(">") -> {
                val quoted = mutableListOf<String>()
                while (index < lines.size && lines[index].trim().startsWith(">")) {
                    quoted += lines[index].trim().removePrefix(">").trim()
                    index++
                }
                blocks += MdBlock.Quote(quoted)
            }

            trimmed.startsWith("|") && index + 1 < lines.size && isTableSeparator(lines[index + 1]) -> {
                val header = splitTableRow(trimmed)
                index += 2
                val rows = mutableListOf<List<String>>()
                while (index < lines.size && lines[index].trim().startsWith("|")) {
                    rows += splitTableRow(lines[index].trim())
                    index++
                }
                blocks += MdBlock.Table(header, rows)
            }

            isBullet(trimmed) -> {
                val items = mutableListOf<Pair<Int, String>>()
                while (index < lines.size && isBullet(lines[index].trim())) {
                    val raw = lines[index]
                    val depth = (raw.length - raw.trimStart().length) / 2
                    items += depth to raw.trim().drop(1).trim()
                    index++
                }
                blocks += MdBlock.Bullets(items)
            }

            isOrdered(trimmed) -> {
                val items = mutableListOf<Pair<Int, String>>()
                while (index < lines.size && isOrdered(lines[index].trim())) {
                    val dot = lines[index].trim().indexOfFirst { it == '.' || it == ')' }
                    val number = lines[index].trim().take(dot).toIntOrNull() ?: (items.size + 1)
                    items += number to lines[index].trim().drop(dot + 1).trim()
                    index++
                }
                blocks += MdBlock.Ordered(items)
            }

            else -> {
                val paragraph = mutableListOf<String>()
                while (index < lines.size) {
                    val candidate = lines[index].trim()
                    if (candidate.isEmpty() || candidate.startsWith("```") || candidate.startsWith("#") ||
                        candidate.startsWith(">") || isBullet(candidate) || isOrdered(candidate) ||
                        candidate == "---" || (candidate.startsWith("|") && index + 1 < lines.size && isTableSeparator(lines[index + 1]))
                    ) {
                        break
                    }
                    paragraph += candidate
                    index++
                }
                if (paragraph.isNotEmpty()) blocks += MdBlock.Paragraph(paragraph.joinToString("\n"))
            }
        }
    }
    return blocks
}

private fun isBullet(line: String) = line.startsWith("- ") || line.startsWith("* ") || line.startsWith("+ ")
private fun isOrdered(line: String): Boolean {
    val dot = line.indexOfFirst { it == '.' || it == ')' }
    return dot in 1..3 && line.take(dot).all { it.isDigit() } && line.length > dot + 1 && line[dot + 1] == ' '
}

private fun isTableSeparator(line: String): Boolean {
    val trimmed = line.trim()
    return trimmed.startsWith("|") && trimmed.replace("|", "").replace("-", "").replace(":", "")
        .replace(" ", "").isEmpty()
}

private fun splitTableRow(line: String): List<String> =
    line.trim().trim('|').split('|').map { it.trim() }

/** 行内样式:粗体 / 斜体 / 行内码 / 链接 / 删除线 */
@Composable
private fun inlineMarkdown(
    text: String,
    base: TextStyle,
    codeColor: Color,
    linkColor: Color,
): AnnotatedString {
    return remember(text, base, codeColor, linkColor) {
        buildAnnotatedString {
            var i = 0
            while (i < text.length) {
                when {
                    text.startsWith("**", i) -> {
                        val end = text.indexOf("**", i + 2)
                        if (end > i) {
                            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) {
                                append(text.substring(i + 2, end))
                            }
                            i = end + 2
                        } else {
                            append(text[i]); i++
                        }
                    }
                    text.startsWith("~~", i) -> {
                        val end = text.indexOf("~~", i + 2)
                        if (end > i) {
                            withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) {
                                append(text.substring(i + 2, end))
                            }
                            i = end + 2
                        } else {
                            append(text[i]); i++
                        }
                    }
                    text.startsWith("`", i) -> {
                        val end = text.indexOf('`', i + 1)
                        if (end > i) {
                            withStyle(
                                SpanStyle(
                                    fontFamily = FontFamily.Monospace,
                                    background = codeColor,
                                    fontSize = base.fontSize * 0.92f,
                                )
                            ) {
                                append(text.substring(i + 1, end))
                            }
                            i = end + 1
                        } else {
                            append(text[i]); i++
                        }
                    }
                    text.startsWith("[", i) -> {
                        val close = text.indexOf(']', i)
                        val open = if (close > 0) text.indexOf('(', close) else -1
                        val end = if (open > 0) text.indexOf(')', open) else -1
                        if (close > 0 && open == close + 1 && end > open) {
                            val label = text.substring(i + 1, close)
                            val url = text.substring(open + 1, end)
                            withLink(
                                androidx.compose.ui.text.LinkAnnotation.Url(
                                    url = url,
                                    styles = androidx.compose.ui.text.TextLinkStyles(
                                        SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)
                                    ),
                                )
                            ) {
                                append(label)
                            }
                            i = end + 1
                        } else {
                            append(text[i]); i++
                        }
                    }
                    (text.startsWith("*", i) || text.startsWith("_", i)) -> {
                        val marker = text[i]
                        val end = text.indexOf(marker, i + 1)
                        if (end > i + 1) {
                            withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                                append(text.substring(i + 1, end))
                            }
                            i = end + 1
                        } else {
                            append(text[i]); i++
                        }
                    }
                    else -> {
                        append(text[i]); i++
                    }
                }
            }
        }
    }
}

@Composable
private fun CodeBlock(language: String?, code: String, baseSize: TextUnit) {
    val context = LocalContext.current
    var copied by remember(code) { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .border(1.dp, Color.White.copy(alpha = 0.07f), RoundedCornerShape(10.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                language ?: "代码",
                style = McType.caption2,
                color = TextFaint,
                modifier = Modifier.weight(1f),
            )
            Box(
                Modifier
                    .size(28.dp)
                    .clip(RoundedCornerShape(7.dp))
                    .background(Color(0xFF1C1C20).copy(alpha = 0.9f))
                    .clickable {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("code", code))
                        copied = true
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (copied) "✓" else "⧉",
                    style = McType.caption2,
                    color = if (copied) Success else TextMuted,
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            code,
            style = McType.footnote.copy(
                fontFamily = FontFamily.Monospace,
                fontSize = baseSize * 0.85f,
                lineHeight = baseSize * 1.3f,
            ),
            color = Color.White.copy(alpha = 0.9f),
            modifier = Modifier.horizontalScroll(rememberScrollState()),
        )
    }
}

@Composable
private fun MdTable(
    table: MdBlock.Table,
    bodyStyle: TextStyle,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .border(1.dp, Color.White.copy(alpha = 0.07f), RoundedCornerShape(10.dp)),
    ) {
        Row(Modifier.background(Color.White.copy(alpha = 0.04f))) {
            table.header.forEach { cell ->
                Text(
                    inlineMarkdown(cell, bodyStyle, Color.White.copy(alpha = 0.09f), Accent),
                    style = bodyStyle.copy(fontSize = bodyStyle.fontSize * 0.9f, fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.weight(1f).padding(horizontal = 12.dp, vertical = 7.dp),
                )
            }
        }
        table.rows.forEach { row ->
            Row {
                row.forEach { cell ->
                    Text(
                        inlineMarkdown(cell, bodyStyle, Color.White.copy(alpha = 0.09f), Accent),
                        style = bodyStyle.copy(fontSize = bodyStyle.fontSize * 0.9f),
                        modifier = Modifier.weight(1f).padding(horizontal = 12.dp, vertical = 7.dp),
                    )
                }
            }
        }
    }
}

/** Markdown 文本:baseSize 为正文基准字号,其余按 iOS 比例缩放 */
@Composable
fun MarkdownText(
    markdown: String,
    modifier: Modifier = Modifier,
    baseSize: TextUnit = 15.sp,
) {
    val blocks = remember(markdown) { parseMd(markdown) }
    val bodyStyle = McType.subheadline.copy(fontSize = baseSize, color = Color.White.copy(alpha = 0.92f))
    val codeBg = Color.White.copy(alpha = 0.09f)

    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        blocks.forEach { block ->
            when (block) {
                is MdBlock.Heading -> {
                    val scale = when (block.level) {
                        1 -> 1.5f
                        2 -> 1.3f
                        3 -> 1.15f
                        else -> 1.05f
                    }
                    Text(
                        inlineMarkdown(block.text, bodyStyle, codeBg, Accent),
                        style = bodyStyle.copy(
                            fontSize = baseSize * scale,
                            fontWeight = FontWeight.SemiBold,
                            color = TextPrimary,
                        ),
                    )
                }

                is MdBlock.Paragraph -> Text(
                    inlineMarkdown(block.text, bodyStyle, codeBg, Accent),
                    style = bodyStyle.copy(lineHeight = baseSize * 1.45f),
                )

                is MdBlock.Bullets -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    block.items.forEach { (depth, item) ->
                        Row(Modifier.padding(start = (depth * 14).dp)) {
                            Text("•", style = bodyStyle, color = Color.White.copy(alpha = 0.6f))
                            Spacer(Modifier.width(8.dp))
                            Text(
                                inlineMarkdown(item, bodyStyle, codeBg, Accent),
                                style = bodyStyle.copy(lineHeight = baseSize * 1.45f),
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }

                is MdBlock.Ordered -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    block.items.forEach { (number, item) ->
                        Row {
                            Text(
                                "$number.",
                                style = bodyStyle.copy(fontSize = baseSize * 0.85f),
                                color = Color.White.copy(alpha = 0.6f),
                                modifier = Modifier.widthIn(min = (baseSize.value * 1.4f).dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                inlineMarkdown(item, bodyStyle, codeBg, Accent),
                                style = bodyStyle.copy(lineHeight = baseSize * 1.45f),
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }

                is MdBlock.Quote -> Row(Modifier.fillMaxWidth()) {
                    Box(
                        Modifier
                            .width(3.dp)
                            .heightIn(min = 18.dp)
                            .background(Color.White.copy(alpha = 0.14f), RoundedCornerShape(2.dp)),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        inlineMarkdown(block.lines.joinToString("\n"), bodyStyle, codeBg, Accent),
                        style = bodyStyle.copy(color = TextMuted, lineHeight = baseSize * 1.45f),
                        modifier = Modifier.weight(1f),
                    )
                }

                is MdBlock.Code -> CodeBlock(language = block.language, code = block.code, baseSize = baseSize)

                is MdBlock.Table -> MdTable(block, bodyStyle)

                MdBlock.Rule -> Box(
                    Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .background(Color.White.copy(alpha = 0.1f)),
                )
            }
        }
    }
}
