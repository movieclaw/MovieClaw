package io.movieclaw.androidtv.ui.components

import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.takeOrElse
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
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
)
