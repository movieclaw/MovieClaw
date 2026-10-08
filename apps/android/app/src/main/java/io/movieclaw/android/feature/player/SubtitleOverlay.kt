package io.movieclaw.android.feature.player

import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.playback.SubtitleCues
import io.movieclaw.android.core.playback.SubtitleStyle
import kotlinx.coroutines.delay

/**
 * 字幕叠层（**自己画文字**，iOS `SubtitleOverlay` 的对应物）。
 *
 * 之前把字幕文件交给 libass 渲染，一直在跟文件自带的样式打架：字幕组把
 * `{\bord20\shad0\3c&H000000&}` 这类覆盖写进**每一条事件**，优先级高于样式行，
 * 改样式行怎么都盖不住（"整行都有黑框"就是这么来的）。
 * iOS 的做法是**根本不用文件的样式**——把 cue 解析成纯文本，用自己的字号/位置画白字，
 * 不开背景时加一层柔和投影。结构上就不可能带上文件自带的框。
 *
 * 字号与位置都按**画面矩形**算（按视频宽高比在播放区里等比适配出来的那块），
 * 所以有没有黑边、横竖屏都不影响字幕相对画面的样子。
 */
@Composable
fun SubtitleOverlayLayer(
    /** 视频实时播放位置（毫秒，文件时间轴） */
    currentPositionMs: () -> Long,
    /** 画面（视频）尺寸：字号与位置都以它为基准 */
    videoSize: IntSize,
    cues: List<SubtitleCues.Cue>,
    enabled: Boolean,
    style: SubtitleStyle,
    /** 时间轴微调（毫秒）：**正数 = 字幕延后** */
    offsetMs: Long,
    modifier: Modifier = Modifier,
) {
    if (!enabled || cues.isEmpty() || videoSize.width <= 0 || videoSize.height <= 0) return

    var nowMs by remember { mutableLongStateOf(0L) }
    var loggedOnce by remember { mutableStateOf(false) }

    // 20fps 足够（字幕切换的粒度远粗于帧）；位置取播放器实时值，不用界面那个 500ms 采样。
    // 每 5 秒打一行「位置 / 命中几条 / cue 时间范围」——"有 cue 却不显示"只能靠它定位。
    LaunchedEffect(cues) {
        Log.i(
            "McAss",
            "字幕叠层启动：${cues.size} 条 cue（首 ${cues.firstOrNull()?.startMs} 尾 ${cues.lastOrNull()?.endMs}）offset=$offsetMs",
        )
        var tick = 0
        while (true) {
            nowMs = currentPositionMs()
            if (tick++ % 100 == 0) {
                val hit = SubtitleCues.active(cues, nowMs - offsetMs).size
                Log.i("McAss", "字幕叠层 位置=${nowMs}ms 命中=$hit 条 候选=${cues.size}")
            }
            delay(50)
        }
    }

    val active = SubtitleCues.active(cues, nowMs - offsetMs)
    if (active.isEmpty()) return

    BoxWithConstraints(modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val containerW = with(density) { maxWidth.toPx() }
        val containerH = with(density) { maxHeight.toPx() }
        if (containerW <= 0f || containerH <= 0f) return@BoxWithConstraints
        // 画面矩形：按视频宽高比等比适配并居中（与 Exo 的 ContentScale.Fit 同一口径）
        val videoAspect = videoSize.width.toFloat() / videoSize.height.toFloat()
        val containerAspect = containerW / containerH
        val rectW: Float
        val rectH: Float
        if (videoAspect >= containerAspect) {
            rectW = containerW
            rectH = containerW / videoAspect
        } else {
            rectH = containerH
            rectW = containerH * videoAspect
        }
        val topPad = (containerH - rectH) / 2f

        val fontSize = (rectH * style.fontPercent / 100f).coerceAtLeast(12f)
        val bottomPad = rectH * style.bottomPercent / 100f

        if (!loggedOnce) {
            loggedOnce = true
            Log.i(
                "McAss",
                "字幕叠层 画面=${videoSize.width}x${videoSize.height}" +
                    " 容器=${containerW.toInt()}x${containerH.toInt()}" +
                    " 画面矩形=${rectW.toInt()}x${rectH.toInt()}" +
                    " 字号=${fontSize.toInt()}px 底距=${bottomPad.toInt()}px",
            )
        }

        Column(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = with(density) { topPad.toDp() })
                .fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(Modifier.fillMaxSize()) {
                Column(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = with(density) { bottomPad.toDp() })
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
                        text = active.joinToString("\n") { it.text },
                        color = Color.White,
                        fontSize = with(density) { fontSize.toSp() },
                        fontWeight = FontWeight.Medium,
                        textAlign = TextAlign.Center,
                        // 不开背景时靠一层柔和投影压住亮画面（iOS：不做描边，所以没有黑框）
                        style = TextStyle(
                            shadow = if (style.background) null else Shadow(
                                color = Color.Black.copy(alpha = 0.85f),
                                offset = Offset(0f, 1.5f),
                                blurRadius = fontSize * 0.18f,
                            ),
                        ),
                    )
                }
            }
        }
    }
}
