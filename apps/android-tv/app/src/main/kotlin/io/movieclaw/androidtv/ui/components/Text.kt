package io.movieclaw.androidtv.ui.components

import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorProducer
import androidx.compose.ui.graphics.takeOrElse
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.LocalTextStyle

/*
 * 文字：参数与取色规则同 androidx.tv.material3.Text（颜色 → 样式里的颜色 → LocalContentColor，样式默认 LocalTextStyle），
 * 只是直接画，不离屏。TV Material 1.1 的 Text 给每段字都无条件套了一层离屏合成（graphicsLayer Offscreen）：
 * 首页上百段字各占一块显存纹理，一行新滚进来每段字都要新建纹理、渲染一遍，标题变色、文字淡入时还要重画
 * （docs/perf/androidtv-home-scroll-2026-10.md）。普通文字离屏画一遍再原样合成，与直接画逐像素相同。
 */

@Composable
fun Text(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = Color.Unspecified,
    fontSize: TextUnit = TextUnit.Unspecified,
    fontStyle: FontStyle? = null,
    fontWeight: FontWeight? = null,
    fontFamily: FontFamily? = null,
    letterSpacing: TextUnit = TextUnit.Unspecified,
    textDecoration: TextDecoration? = null,
    textAlign: TextAlign? = null,
    lineHeight: TextUnit = TextUnit.Unspecified,
    overflow: TextOverflow = TextOverflow.Clip,
    softWrap: Boolean = true,
    maxLines: Int = Int.MAX_VALUE,
    minLines: Int = 1,
    onTextLayout: (TextLayoutResult) -> Unit = {},
    style: TextStyle = LocalTextStyle.current,
) {
    BasicText(
        text,
        modifier,
        merged(style, color, fontSize, fontStyle, fontWeight, fontFamily, letterSpacing, textDecoration, textAlign, lineHeight),
        onTextLayout,
        overflow,
        softWrap,
        maxLines,
        minLines,
    )
}

/**
 * 颜色在绘制时才取（[color] 里读动画值）：行标题这种随焦点变色的字，变色的每一帧只重画、不重组。
 * 样式里的颜色不再起作用
 */
@Composable
fun Text(
    text: String,
    color: ColorProducer,
    modifier: Modifier = Modifier,
    overflow: TextOverflow = TextOverflow.Clip,
    maxLines: Int = Int.MAX_VALUE,
    style: TextStyle = LocalTextStyle.current,
) {
    BasicText(
        text,
        modifier,
        merged(style, Color.Unspecified, TextUnit.Unspecified, null, null, null, TextUnit.Unspecified, null, null, TextUnit.Unspecified),
        overflow = overflow,
        maxLines = maxLines,
        color = color,
    )
}

@Composable
fun Text(
    text: AnnotatedString,
    modifier: Modifier = Modifier,
    color: Color = Color.Unspecified,
    fontSize: TextUnit = TextUnit.Unspecified,
    fontStyle: FontStyle? = null,
    fontWeight: FontWeight? = null,
    fontFamily: FontFamily? = null,
    letterSpacing: TextUnit = TextUnit.Unspecified,
    textDecoration: TextDecoration? = null,
    textAlign: TextAlign? = null,
    lineHeight: TextUnit = TextUnit.Unspecified,
    overflow: TextOverflow = TextOverflow.Clip,
    softWrap: Boolean = true,
    maxLines: Int = Int.MAX_VALUE,
    minLines: Int = 1,
    inlineContent: Map<String, InlineTextContent> = mapOf(),
    onTextLayout: (TextLayoutResult) -> Unit = {},
    style: TextStyle = LocalTextStyle.current,
) {
    BasicText(
        text,
        modifier,
        merged(style, color, fontSize, fontStyle, fontWeight, fontFamily, letterSpacing, textDecoration, textAlign, lineHeight),
        onTextLayout,
        overflow,
        softWrap,
        maxLines,
        minLines,
        inlineContent,
    )
}

@Composable
private fun merged(
    style: TextStyle,
    color: Color,
    fontSize: TextUnit,
    fontStyle: FontStyle?,
    fontWeight: FontWeight?,
    fontFamily: FontFamily?,
    letterSpacing: TextUnit,
    textDecoration: TextDecoration?,
    textAlign: TextAlign?,
    lineHeight: TextUnit,
): TextStyle = style.merge(
    color = color.takeOrElse { style.color.takeOrElse { LocalContentColor.current } },
    fontSize = fontSize,
    fontWeight = fontWeight,
    textAlign = textAlign ?: TextAlign.Unspecified,
    lineHeight = lineHeight,
    fontFamily = fontFamily,
    textDecoration = textDecoration,
    fontStyle = fontStyle,
    letterSpacing = letterSpacing,
).let { it.copy(fontWeight = tvWeight(it.fontWeight), localeList = it.localeList ?: ZhHans) }

/*
 * 字形与字重（同手机端用系统字体，不打包中文字体）：
 * - 语言固定简体中文：系统语言是繁体 / 英文 / 日文的盒子上，汉字与标点也按简体中文排（标点在左下、字形是大陆规范）；
 * - 字重只用常规与粗两档：电视盒子常见的 Android 9–11 系统中文字体只有常规一个字重。500 时西文数字是 Roboto Medium、
 *   汉字还是常规，「第 1 季第 60 集」数字比汉字粗一截；600 时汉字被系统加粗、西文却是 Medium / Bold 之间——一行里粗细不齐。
 *   按 500 及以下 → 常规、600 及以上 → 粗归档，中西文粗细一致（带完整字重的系统上看着也只是半粗 → 粗）
 */
private val ZhHans = LocaleList("zh-CN")

internal fun tvWeight(weight: FontWeight?): FontWeight? = when {
    weight == null -> null
    weight.weight >= 600 -> FontWeight.Bold
    else -> FontWeight.Normal
}
