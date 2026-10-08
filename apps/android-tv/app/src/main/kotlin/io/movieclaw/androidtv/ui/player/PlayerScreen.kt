@file:OptIn(UnstableApi::class)

package io.movieclaw.androidtv.ui.player

import android.view.KeyEvent as AndroidKeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.compose.PlayerSurface
import androidx.media3.ui.compose.SURFACE_TYPE_SURFACE_VIEW
import androidx.tv.material3.Text
import io.movieclaw.androidtv.AccountSession
import io.movieclaw.androidtv.AppGraph
import io.movieclaw.androidtv.core.playback.PlaybackController
import io.movieclaw.androidtv.core.playback.PlaybackTarget
import io.movieclaw.androidtv.ui.McColors
import io.movieclaw.androidtv.ui.McMetrics

/**
 * A0 的播放页：全屏画面 + 最简控制（确认键 播放 / 暂停，左右 ∓10 秒，返回 退出）。
 * 完整控制层（拖动预览、信息面板、跳过片头、下一集）在 A1（docs/design/androidtv-app.md §4.4）。
 */
@Composable
fun PlayerScreen(graph: AppGraph, session: AccountSession, target: PlaybackTarget, onExit: () -> Unit) {
    val context = LocalContext.current
    val controller = remember(target) {
        PlaybackController(
            context = context.applicationContext,
            api = session.api,
            server = session.server,
            http = session.http,
            identity = graph.identity,
            deviceId = session.account.deviceId,
            scope = graph.appScope,
        )
    }
    DisposableEffect(controller) {
        controller.start(target)
        onDispose { controller.release() }
    }
    val state by controller.state.collectAsState()
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(state.ended) { if (state.ended) onExit() }
    BackHandler(onBack = onExit)

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(focus)
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                when (event.nativeKeyEvent.keyCode) {
                    AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER,
                    AndroidKeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, AndroidKeyEvent.KEYCODE_MEDIA_PLAY,
                    AndroidKeyEvent.KEYCODE_MEDIA_PAUSE,
                    -> controller.togglePlayPause()
                    AndroidKeyEvent.KEYCODE_DPAD_LEFT, AndroidKeyEvent.KEYCODE_MEDIA_REWIND -> controller.seekBy(-10_000)
                    AndroidKeyEvent.KEYCODE_DPAD_RIGHT, AndroidKeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> controller.seekBy(10_000)
                    else -> return@onKeyEvent false
                }
                true
            }
            .focusable(),
    ) {
        PlayerSurface(player = controller.player, surfaceType = SURFACE_TYPE_SURFACE_VIEW, modifier = Modifier.fillMaxSize())

        val showOverlay = !state.isPlaying || state.opening || state.error != null
        if (showOverlay) {
            Column(
                Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth()
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xCC000000))))
                    .padding(horizontal = McMetrics.SafeHorizontal, vertical = McMetrics.SafeVertical),
            ) {
                Text(state.title, color = McColors.TextPrimary, fontSize = 28.sp)
                val status = when {
                    state.error != null -> state.error!!
                    state.opening -> "正在打开……"
                    else -> "${clock(state.positionMs)} / ${clock(state.durationMs)}"
                }
                Text(status, color = if (state.error != null) McColors.Danger else McColors.TextSecondary, fontSize = 18.sp)
                if (state.route.isNotEmpty()) {
                    Text("${state.route} · 档 ${state.tier}", color = McColors.TextSecondary, fontSize = 14.sp)
                }
                if (state.durationMs > 0) {
                    Box(Modifier.padding(top = 12.dp).fillMaxWidth().height(4.dp).background(McColors.Surface)) {
                        Box(
                            Modifier.fillMaxWidth((state.positionMs.toFloat() / state.durationMs).coerceIn(0f, 1f))
                                .height(4.dp).background(McColors.Silver),
                        )
                    }
                }
            }
        }
    }
}

private fun clock(ms: Long): String {
    val total = (ms / 1000).coerceAtLeast(0)
    val h = total / 3600
    val m = total % 3600 / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}
