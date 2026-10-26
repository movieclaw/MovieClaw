package io.movieclaw.android.feature.player

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.media3.common.text.Cue
import io.movieclaw.android.core.playback.SubtitleStyle
import io.movieclaw.core.playback.SubtitleCue
import io.movieclaw.core.playback.WebVtt
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * 服务端给的文本字幕（VTT，文件时间轴）此刻该显示的文字：下载一次、20Hz 按播放位置取 cue。
 * 这一路能按用户的时间轴微调（**正数 = 字幕延后**）。
 */
@Composable
fun rememberVttText(url: String?, http: OkHttpClient, fileTimeMs: () -> Long, offsetSeconds: Float): String? {
    var text by remember { mutableStateOf<String?>(null) }
    val offsetMs by rememberUpdatedState((offsetSeconds * 1000f).toLong())
    LaunchedEffect(url) {
        text = null
        if (url == null) return@LaunchedEffect
        // 内封轨首次要服务端通读整个容器抽出来（大文件可达数十秒），超时放宽到 5 分钟
        val cues: List<SubtitleCue> = withContext(Dispatchers.IO) {
            runCatching {
                val client = http.newBuilder().readTimeout(300, TimeUnit.SECONDS).callTimeout(300, TimeUnit.SECONDS).build()
                client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                    if (response.code != 200) emptyList() else WebVtt.parse(response.body.string())
                }
            }.getOrDefault(emptyList())
        }
        // 20Hz 足够（字幕切换的粒度远粗于帧）
        while (isActive) {
            text = WebVtt.active(cues, (fileTimeMs() - offsetMs) / 1000.0).joinToString("\n") { it.text }.ifEmpty { null }
            delay(50)
        }
    }
    return text
}

/**
 * 字幕叠层（**自己画文字**，iOS `SubtitleOverlay` 的对应物）：不用字幕文件自带的样式（字幕组写进每条事件的
 * `{\bord20\shad0…}` 会带出黑框），按用户的字号 / 位置 / 背景画白字。
 *
 * 来源（统一引擎的分工，见 core PlaybackController.applySubtitle）：
 *  · [text]：服务端给的文本字幕此刻的文字（正片的 [rememberVttText]、刷片的窗口字幕），优先；
 *  · [engineCues]：直连原文件时 Exo 自己解出的 cue——文字照样画（时机由引擎定，时间轴微调不生效），
 *    图形字幕（PGS）是位图，按 cue 给的比例贴在画面里。
 * ASS 特效字幕不走这里：统一引擎交给 libass 画在它自己的叠加层上。
 *
 * 字号与位置都按**画面矩形**算（按视频宽高比在播放区里等比适配出来的那块）。
 */
@Composable
fun SubtitleOverlayLayer(
    text: String?,
    engineCues: List<Cue>,
    videoWidth: Int,
    videoHeight: Int,
    style: SubtitleStyle,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val rect = videoRect(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat(), videoWidth, videoHeight)
        val shown = text ?: engineCues.mapNotNull { it.text?.toString()?.trim()?.takeIf(String::isNotEmpty) }
            .joinToString("\n").ifEmpty { null }
        if (shown != null) {
            val fontPx = (rect.height * style.fontPercent / 100f).coerceAtLeast(12f)
            val bottomPx = constraints.maxHeight - rect.bottom + rect.height * style.bottomPercent / 100f
            Column(
                Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = with(density) { bottomPx.toDp() })
                    .then(
                        if (style.background) {
                            Modifier
                                .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(6.dp))
                                .padding(horizontal = 8.dp, vertical = 3.dp)
                        } else {
                            Modifier
                        },
                    ),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = shown,
                    color = Color.White,
                    fontSize = with(density) { fontPx.toSp() },
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                    // 不开背景时靠一层柔和投影压住亮画面（iOS：不做描边，所以没有黑框）
                    style = TextStyle(
                        shadow = if (style.background) null else Shadow(
                            color = Color.Black.copy(alpha = 0.85f),
                            offset = Offset(0f, 1.5f),
                            blurRadius = fontPx * 0.18f,
                        ),
                    ),
                )
            }
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

/** 图形字幕（PGS 等）：cue 给的是相对画面的位置、宽度（与可选的高度）比例（与 TV 版同一套摆法） */
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
