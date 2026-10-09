package io.movieclaw.androidtv.ui.player

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.em
import androidx.media3.common.text.Cue
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.core.playback.SubtitleCue
import io.movieclaw.androidtv.core.playback.SubtitleStyle
import io.movieclaw.androidtv.core.playback.WebVtt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 字幕层（Apple 端 SubtitleOverlay.swift）：锚定**画面矩形**（按视频宽高比 aspect-fit 出来的那块），
 * 字号是画面高度的 5.2%、文字中心距画面底边 8% + 一个字高；白字中等粗细居中，黑 60% 柔和投影，不描边
 * （中文笔画轮廓互相重叠，描边会在交叉处描出黑缝）。
 *
 * 两路来源同一套样子：服务端流的文本字幕（[overlayUrl]，VTT，10Hz 按文件时间取 cue），
 * 直连原文件时 Exo 自己解出的 cue（[engineCues]；图形字幕是位图，按 cue 给的比例位置贴在画面矩形里）。
 */
@Composable
fun SubtitleLayer(
    overlayUrl: String?,
    engineCues: List<Cue>,
    videoWidth: Int,
    videoHeight: Int,
    http: OkHttpClient,
    fileTimeMs: () -> Long,
    modifier: Modifier = Modifier,
) {
    var cues by remember { mutableStateOf<List<SubtitleCue>>(emptyList()) }
    var overlayText by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(overlayUrl) {
        cues = emptyList()
        overlayText = null
        val url = overlayUrl ?: return@LaunchedEffect
        // 内封轨首次要服务端通读整个容器抽出来（大文件可达数十秒），超时放宽到 5 分钟
        cues = withContext(Dispatchers.IO) {
            runCatching {
                val client = http.newBuilder().readTimeout(300, TimeUnit.SECONDS).callTimeout(300, TimeUnit.SECONDS).build()
                client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                    if (response.code != 200) emptyList() else WebVtt.parse(response.body.string())
                }
            }.getOrDefault(emptyList())
        }
        while (isActive) {
            overlayText = WebVtt.active(cues, fileTimeMs() / 1000.0).joinToString("\n") { it.text }.ifEmpty { null }
            delay(100)
        }
    }

    BoxWithConstraints(modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val boxW = constraints.maxWidth.toFloat()
        val boxH = constraints.maxHeight.toFloat()
        val rect = videoRect(boxW, boxH, videoWidth, videoHeight)
        val fontPx = max(12f * density.density * 0.5f, rect.height * SubtitleStyle.FONT_SCALE_PERCENT / 100)
        val text = overlayText ?: engineCues.mapNotNull { it.text?.toString()?.trim()?.takeIf(String::isNotEmpty) }
            .joinToString("\n").ifEmpty { null }
        if (text != null) {
            SubtitleText(text, fontPx, rect)
        }
        for (cue in engineCues) {
            val bitmap = cue.bitmap ?: continue
            BitmapCue(cue, bitmap.asImageBitmap(), rect, density.density)
        }
    }
}

/** 画面矩形：视频按宽高比放进播放区（还不知道视频尺寸时按整块算） */
private fun videoRect(boxW: Float, boxH: Float, videoW: Int, videoH: Int): Rect {
    if (videoW <= 0 || videoH <= 0) return Rect(0f, 0f, boxW, boxH)
    val scale = minOf(boxW / videoW, boxH / videoH)
    val w = videoW * scale
    val h = videoH * scale
    return Rect((boxW - w) / 2, (boxH - h) / 2, (boxW + w) / 2, (boxH + h) / 2)
}

@Composable
private fun SubtitleText(text: String, fontPx: Float, rect: Rect) {
    val density = LocalDensity.current
    val style = with(density) {
        TextStyle(
            color = Color.White,
            fontSize = fontPx.toSp(),
            fontWeight = FontWeight.Medium,
            textAlign = TextAlign.Center,
            lineHeight = 1.1.em,
            lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None),
            // 投影半径 3pt（1pt = 0.5dp）
            shadow = Shadow(Color.Black.copy(alpha = 0.6f), Offset.Zero, blurRadius = 1.5f * density.density),
        )
    }
    Layout(content = { Text(text, style = style) }) { measurables, constraints ->
        val width = (rect.width * 0.9f).roundToInt().coerceAtLeast(1)
        val placeable = measurables.first().measure(Constraints(maxWidth = width))
        // 文字块中心落在「画面底边 − 8% 画面高 − 一个字号」处（同 Apple 端）
        val centerY = rect.bottom - rect.height * SubtitleStyle.BOTTOM_PERCENT / 100 - fontPx
        layout(constraints.maxWidth, constraints.maxHeight) {
            placeable.place(IntOffset((rect.center.x - placeable.width / 2f).roundToInt(), (centerY - placeable.height / 2f).roundToInt()))
        }
    }
}

/** 图形字幕（PGS 等）：cue 给的是相对画面的位置、宽度（与可选的高度）比例 */
@Composable
private fun BitmapCue(cue: Cue, image: androidx.compose.ui.graphics.ImageBitmap, rect: Rect, density: Float) {
    val width = if (cue.size != Cue.DIMEN_UNSET) cue.size * rect.width else image.width.toFloat()
    val height = if (cue.bitmapHeight != Cue.DIMEN_UNSET) cue.bitmapHeight * rect.height else width * image.height / max(1, image.width)
    val position = if (cue.position != Cue.DIMEN_UNSET) cue.position else 0.5f
    val line = if (cue.line != Cue.DIMEN_UNSET && cue.lineType == Cue.LINE_TYPE_FRACTION) cue.line else 0.9f
    val x = rect.left + position * rect.width - when (cue.positionAnchor) {
        Cue.ANCHOR_TYPE_MIDDLE -> width / 2
        Cue.ANCHOR_TYPE_END -> width
        else -> 0f
    }
    val y = rect.top + line * rect.height - when (cue.lineAnchor) {
        Cue.ANCHOR_TYPE_MIDDLE -> height / 2
        Cue.ANCHOR_TYPE_END -> height
        else -> 0f
    }
    Box(
        Modifier
            .offset { IntOffset(x.roundToInt(), y.roundToInt()) }
            .size(Dp(width / density), Dp(height / density)),
    ) {
        Image(image, contentDescription = null, contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
    }
}
