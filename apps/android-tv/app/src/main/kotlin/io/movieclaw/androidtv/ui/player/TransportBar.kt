package io.movieclaw.androidtv.ui.player

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.tv.material3.Text
import io.movieclaw.androidtv.core.playback.PlayerFormat
import io.movieclaw.androidtv.core.playback.PlayerState
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt

/**
 * 播放器底部的进度条（Apple 端 TVTransportBar.swift，同 tvOS 系统播放器）：片名一行、进度条（已缓冲 / 已播放 / 拖动时的播放头）、
 * 左边当前时间、右边剩余时间。按住左右键拖动时播放头上方出现缩略图与落点时间。
 */
@Composable
fun TransportBar(state: PlayerState, scrubMs: Long?, trickplay: TrickplayImages, modifier: Modifier = Modifier) {
    val duration = state.durationMs ?: 0
    val position = scrubMs ?: state.positionMs
    val buffered = state.bufferedEndMs ?: 0
    Column(modifier, verticalArrangement = Arrangement.spacedBy(18.pt)) {
        Text(
            state.titleLine,
            style = McType.Headline,
            color = Color.White.copy(alpha = 0.9f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        BoxWithConstraints(Modifier.fillMaxWidth().height(30.pt), contentAlignment = Alignment.CenterStart) {
            val width = maxWidth
            val played = width * fraction(position, duration)
            Box(Modifier.fillMaxWidth().height(BAR).clip(CircleShape).background(Color.White.copy(alpha = 0.22f))) {
                Box(Modifier.width(width * fraction(buffered, duration)).height(BAR).clip(CircleShape).background(Color.White.copy(alpha = 0.35f)))
                Box(Modifier.width(played).height(BAR).clip(CircleShape).background(Color.White))
            }
            if (scrubMs != null) {
                Box(Modifier.offset(x = played - 13.pt).size(26.pt).background(Color.White, CircleShape))
                // 预览贴着播放头、但不超出两端；底边在进度条上方 24pt
                val x = (played - 160.pt).coerceIn(0.pt, (width - 320.pt).coerceAtLeast(0.pt))
                ScrubPreview(
                    state, scrubMs, trickplay,
                    Modifier.abovePlacement(x, gapAboveCenter = BAR / 2 + 24.pt),
                )
            }
        }
        Row(Modifier.fillMaxWidth()) {
            Text(PlayerFormat.clockMs(position), style = TIME, color = Color.White.copy(alpha = 0.8f))
            Spacer(Modifier.weight(1f))
            Text("-" + PlayerFormat.clockMs((duration - position).coerceAtLeast(0)), style = TIME, color = Color.White.copy(alpha = 0.8f))
        }
    }
}

private val BAR = 10.pt

/** callout 等宽数字（tvOS `.monospacedDigit()`） */
private val TIME = McType.Callout.copy(fontFeatureSettings = "tnum")

private fun fraction(value: Long, total: Long): Float = if (total <= 0) 0f else (value.coerceIn(0, total).toFloat() / total)

/** 把预览放在进度条中线上方（本节点是零尺寸、落在中线左端）：底边距中线 [gapAboveCenter]，左边距 [x]，不占布局高度 */
private fun Modifier.abovePlacement(x: Dp, gapAboveCenter: Dp): Modifier = layout { measurable, _ ->
    val placeable = measurable.measure(Constraints(maxWidth = 320.pt.roundToPx()))
    layout(0, 0) {
        placeable.place(x.roundToPx(), -gapAboveCenter.roundToPx() - placeable.height)
    }
}

/** 拖动落点的缩略图（服务端下发的雪碧图，没有就只显示时间）与时间 */
@Composable
private fun ScrubPreview(state: PlayerState, fileMs: Long, trickplay: TrickplayImages, modifier: Modifier) {
    Column(modifier.width(320.pt), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.pt)) {
        trickplay.tile(state.trickplay, fileMs)?.let { image ->
            Image(
                image,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .width(320.pt)
                    .shadow(12.pt, RoundedCornerShape(12.pt))
                    .clip(RoundedCornerShape(12.pt)),
            )
        }
        Text(
            PlayerFormat.clockMs(fileMs),
            style = McType.Title3.copy(
                fontWeight = FontWeight.SemiBold,
                fontFeatureSettings = "tnum",
                shadow = Shadow(Color.Black.copy(alpha = 0.5f), blurRadius = 6f),
            ),
            color = Color.White,
        )
    }
}
