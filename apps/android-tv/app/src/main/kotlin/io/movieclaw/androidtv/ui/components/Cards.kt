package io.movieclaw.androidtv.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.tv.material3.Border
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt

/** 卡片下的说明：常驻 / 只在焦点时淡入（不占位）/ 不显示（TVCards.swift CaptionMode） */
enum class CaptionMode { Always, Focused, Hidden }

/**
 * 卡片焦点效果：对齐 tvOS `.hoverEffect(.highlight)` 的观感——放大 1.1、投影、白色细边光。
 * 图裁圆角 20、描 1pt 白 14% 内边（TVCardLabel）。
 */
@Composable
fun FocusCard(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onLongClick: (() -> Unit)? = null,
    corner: Dp = McMetrics.CardCorner,
    onFocus: (Boolean) -> Unit = {},
    content: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(corner)
    Card(
        onClick = onClick,
        onLongClick = onLongClick,
        modifier = modifier.onFocusChanged { onFocus(it.isFocused || it.hasFocus) },
        shape = CardDefaults.shape(shape),
        scale = CardDefaults.scale(focusedScale = McMetrics.FocusZoom, pressedScale = 1.04f),
        border = CardDefaults.border(
            border = Border(BorderStroke(1.pt, Color.White.copy(alpha = 0.14f)), shape = shape),
            focusedBorder = Border(BorderStroke(1.pt, Color.White.copy(alpha = 0.5f)), shape = shape),
        ),
        glow = CardDefaults.glow(focusedGlow = Glow(Color.Black.copy(alpha = 0.6f), 18.pt)),
        colors = CardDefaults.colors(containerColor = McColors.SurfaceRaised, focusedContainerColor = McColors.SurfaceRaised),
    ) { content() }
}

/** 左上角的小标签：caption2 粗体，黑 60% 胶囊，内边 12/6，离边 12 */
@Composable
fun CardBadge(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = McType.Caption2.copy(fontWeight = FontWeight.Bold),
        color = Color.White,
        modifier = modifier
            .padding(12.pt)
            .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(50))
            .padding(horizontal = 12.pt, vertical = 6.pt),
    )
}

/** 进度条：6pt 胶囊，白色填充；底轨默认黑 45%，压在暗带里时用白 30% */
@Composable
fun ProgressStrip(progress: Float, modifier: Modifier = Modifier, track: Color = Color.Black.copy(alpha = 0.45f)) {
    Box(modifier.height(6.pt).background(track, RoundedCornerShape(50))) {
        Box(Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)).height(6.pt).background(Color.White, RoundedCornerShape(50)))
    }
}

/** 卡片下的说明行（.always）：标题 callout medium 一行、可选副标题 caption 次要色、可选备注行 */
@Composable
private fun AlwaysCaption(title: String, subtitle: String?, note: String?, noteIcon: ImageVector?) {
    Column(Modifier.padding(top = McMetrics.CaptionSpacing), verticalArrangement = Arrangement.spacedBy(4.pt)) {
        Text(title, style = McType.Callout.copy(fontWeight = FontWeight.Medium), maxLines = 1, overflow = TextOverflow.Ellipsis)
        subtitle?.let { Text(it, style = McType.Caption, color = McColors.Secondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        if (note != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.pt), verticalAlignment = Alignment.CenterVertically) {
                noteIcon?.let { Icon(it, null, tint = McColors.Secondary, modifier = Modifier.size(23.pt)) }
                Text(note, style = McType.Caption, color = McColors.Secondary, maxLines = 1)
            }
        }
    }
}

/** 只在焦点时淡入的说明：「标题 · 副标题」一行，不占布局高度 */
@Composable
private fun FocusedCaption(visible: Boolean, title: String, subtitle: String?, width: Dp) {
    Box(Modifier.width(width).height(0.pt)) {
        AnimatedVisibility(visible, enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
            Text(
                buildAnnotatedString {
                    append(title)
                    if (!subtitle.isNullOrEmpty()) withStyle(SpanStyle(color = McColors.Secondary)) { append(" · $subtitle") }
                },
                style = McType.Callout.copy(fontWeight = FontWeight.Medium),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = McMetrics.CaptionSpacing).width(width * 1.6f),
            )
        }
    }
}

/** 海报卡（TVPosterCard）：2:3，默认宽 266，说明默认「焦点时」 */
@Composable
fun PosterCard(
    image: String?,
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = McMetrics.PosterWidth,
    widthPt: Float = 266f,
    subtitle: String? = null,
    caption: CaptionMode = CaptionMode.Focused,
    badge: String? = null,
    progress: Float = 0f,
    note: String? = null,
    noteIcon: ImageVector? = null,
    focusDetail: String? = null,
    dimmed: Boolean = false,
    onLongClick: (() -> Unit)? = null,
    onFocus: (Boolean) -> Unit = {},
) {
    var focused by remember { mutableStateOf(false) }
    Column(modifier.width(width)) {
        FocusCard(onClick, Modifier.fillMaxWidth().aspectRatio(2f / 3f), onLongClick, onFocus = { focused = it; onFocus(it) }) {
            Box(Modifier.fillMaxSize()) {
                RemoteImage(image, widthPt, Modifier.fillMaxSize(), zoom = McMetrics.FocusZoom, placeholder = title)
                badge?.let { CardBadge(it, Modifier.align(Alignment.TopStart)) }
                if (progress > 0f) ProgressStrip(progress, Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(12.pt))
                if (focusDetail != null) FocusDetailBand(focused, focusDetail, Modifier.align(Alignment.BottomStart))
                if (dimmed) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)))
            }
        }
        when (caption) {
            CaptionMode.Always -> AlwaysCaption(title, subtitle, note, noteIcon)
            CaptionMode.Focused -> FocusedCaption(focused, title, subtitle, width)
            CaptionMode.Hidden -> Unit
        }
    }
}

/** 影人页海报底部的焦点说明带：22 半粗、最多 2 行，渐变暗底，只在焦点时出现 */
@Composable
private fun FocusDetailBand(visible: Boolean, text: String, modifier: Modifier) {
    AnimatedVisibility(visible, modifier = modifier.fillMaxWidth(), enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
        Text(
            text,
            style = McType.size(22, FontWeight.SemiBold),
            color = Color.White,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.8f))))
                .padding(start = 18.pt, end = 18.pt, top = 48.pt, bottom = 16.pt),
        )
    }
}

/** 横版卡（TVLandscapeCard）：16:9；带 detail 时底部一条暗带（播放图标 + 进度 + 文字） */
@Composable
fun LandscapeCard(
    image: String?,
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = McMetrics.LandscapeWidth,
    widthPt: Float = 416f,
    subtitle: String? = null,
    caption: CaptionMode = CaptionMode.Focused,
    badge: String? = null,
    progress: Float = 0f,
    detail: String? = null,
    placeholder: String? = title,
    dimmed: Boolean = false,
    onLongClick: (() -> Unit)? = null,
    onFocus: (Boolean) -> Unit = {},
) {
    var focused by remember { mutableStateOf(false) }
    Column(modifier.width(width)) {
        FocusCard(onClick, Modifier.fillMaxWidth().aspectRatio(16f / 9f), onLongClick, onFocus = { focused = it; onFocus(it) }) {
            Box(Modifier.fillMaxSize()) {
                RemoteImage(image, widthPt, Modifier.fillMaxSize(), zoom = McMetrics.FocusZoom, placeholder = placeholder)
                badge?.let { CardBadge(it, Modifier.align(Alignment.TopStart)) }
                if (detail != null) {
                    Row(
                        Modifier
                            .align(Alignment.BottomStart)
                            .fillMaxWidth()
                            .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f))))
                            .padding(start = 18.pt, end = 18.pt, top = 36.pt, bottom = 14.pt),
                        horizontalArrangement = Arrangement.spacedBy(12.pt),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(McIcons.Play, null, tint = Color.White, modifier = Modifier.size(18.pt))
                        if (progress > 0f) ProgressStrip(progress, Modifier.width(64.pt), track = Color.White.copy(alpha = 0.3f))
                        Text(detail, style = McType.Caption.copy(fontWeight = FontWeight.SemiBold), color = Color.White, maxLines = 1)
                    }
                } else if (progress > 0f) {
                    ProgressStrip(progress, Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(14.pt))
                }
                if (dimmed) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)))
            }
        }
        when (caption) {
            CaptionMode.Always -> AlwaysCaption(title, subtitle, null, null)
            CaptionMode.Focused -> FocusedCaption(focused, title, subtitle, width)
            CaptionMode.Hidden -> Unit
        }
    }
}

/** 「查看全部」卡（TVSeeAllCard）：与行里海报同尺寸，白 8% 底、细边、图标 + 两行字 */
@Composable
fun SeeAllCard(count: Int?, onClick: () -> Unit, modifier: Modifier = Modifier, width: Dp = 300.pt, height: Dp = 450.pt, onFocus: (Boolean) -> Unit = {}) {
    FocusCard(onClick, modifier.width(width).height(height), onFocus = onFocus) {
        Column(
            Modifier.fillMaxSize().background(Color.White.copy(alpha = 0.08f)),
            verticalArrangement = Arrangement.spacedBy(18.pt, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(McIcons.Grid, null, tint = Color.White, modifier = Modifier.size(48.pt))
            Text("查看全部", style = McType.size(28, FontWeight.SemiBold), color = Color.White)
            count?.let { Text("$it 部", style = McType.size(22), color = Color.White.copy(alpha = 0.7f)) }
        }
    }
}

/** 白 14% 的 1pt 细边（焦点外的卡片描边） */
fun Modifier.hairline(corner: Dp = McMetrics.CardCorner) = border(1.pt, Color.White.copy(alpha = 0.14f), RoundedCornerShape(corner))
