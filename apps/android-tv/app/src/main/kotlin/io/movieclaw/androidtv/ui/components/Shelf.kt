package io.movieclaw.androidtv.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.focusable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.foundation.shape.RoundedCornerShape
import io.movieclaw.androidtv.ui.theme.ptSp
import androidx.tv.material3.Button
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt

/**
 * 一行（TVShelf）：标题 32 半粗，这一行有焦点时亮起（0.2 秒）；下面横排卡片，间距 32、左右 80、上下 20，不裁切。
 * 整行是一个焦点组：上下切行时落在几何上最近的卡片。
 */
@Composable
fun Shelf(
    title: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    state: LazyListState = rememberLazyListState(),
    spacing: Dp = McMetrics.CardSpacing,
    titleAlpha: Float = 1f,
    content: LazyListScope.() -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val color by animateColorAsState(if (focused) McColors.Text else McColors.Secondary, tween(200), label = "shelf-title")
    Column(modifier.onFocusChanged { focused = it.hasFocus }, verticalArrangement = Arrangement.spacedBy(8.pt)) {
        Row(Modifier.padding(horizontal = McMetrics.Edge), horizontalArrangement = Arrangement.spacedBy(16.pt), verticalAlignment = Alignment.Bottom) {
            Text(title, style = McType.size(32, FontWeight.SemiBold), color = color.copy(alpha = color.alpha * titleAlpha), maxLines = 1)
            detail?.let { Text(it, style = McType.Callout, color = McColors.Secondary) }
        }
        TvScrollSpec(80) {
            LazyRow(
                state = state,
                modifier = Modifier.fillMaxWidth().focusGroup(),
                contentPadding = PaddingValues(horizontal = McMetrics.Edge, vertical = 20.pt),
                horizontalArrangement = Arrangement.spacedBy(spacing),
                content = content,
            )
        }
    }
}

/**
 * 整页状态（TVStateView）：80pt 图标、title2 半粗标题、callout 次要色说明（最宽 1100）、可选按钮。
 * 没有按钮时整块可聚焦，焦点不会被困在侧边栏里。
 */
@Composable
fun StateView(
    icon: ImageVector,
    title: String,
    modifier: Modifier = Modifier,
    message: String? = null,
    action: String? = null,
    height: Dp? = null,
    onAction: () -> Unit = {},
) {
    Box(
        modifier.fillMaxWidth().then(if (height != null) Modifier.height(height) else Modifier.fillMaxSize())
            .then(if (action == null) Modifier.focusable() else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Column(Modifier.padding(80.pt), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.pt)) {
            Icon(icon, null, tint = McColors.Secondary, modifier = Modifier.size(80.pt))
            Text(title, style = McType.Title2.copy(fontWeight = FontWeight.SemiBold), textAlign = TextAlign.Center)
            message?.let { Text(it, style = McType.Callout, color = McColors.Secondary, textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 1100.pt)) }
            action?.let {
                Button(onClick = onAction, modifier = Modifier.padding(top = 12.pt)) { Text(it, style = McType.Headline) }
            }
        }
    }
}

/** 片源标签（TVMediaBadgeView）：18 粗体窄字、高 30、圆角 5；实心白底黑字 / 白描边 */
@Composable
fun MediaBadge(text: String, filled: Boolean) {
    val shape = RoundedCornerShape(5.pt)
    Box(
        Modifier
            .height(30.pt)
            .then(if (filled) Modifier.background(Color.White.copy(alpha = 0.9f), shape) else Modifier.border(2.pt, Color.White.copy(alpha = 0.8f), shape))
            .padding(horizontal = 8.pt),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            style = McType.size(18, FontWeight.Bold).copy(letterSpacing = 0.6f.ptSp),
            color = if (filled) Color.Black else Color.White.copy(alpha = 0.92f),
        )
    }
}
