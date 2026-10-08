@file:OptIn(UnstableApi::class)

package io.movieclaw.androidtv.ui.stage

import android.content.Context
import android.net.Uri
import androidx.annotation.OptIn
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.compose.ContentFrame
import androidx.media3.ui.compose.SURFACE_TYPE_TEXTURE_VIEW
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/**
 * 大图预告（TVStagePreview.swift，docs/design/tvos-app.md §3.5）：大图停在一部片上 2 秒，剧照原地换成这部片的一段，
 * 声音 1.5 秒内渐入；放完淡回剧照、不重播（换一部或打断结束才重来）。
 * - 全局同时只有一个预告播放器，按条目 id 认：首页进详情是同一部就接着放；
 * - 0.5 秒后才建播放器并预滚到片段起点（停 2 秒以内划走的不白建）；
 * - 剧照被滚走就暂停、淡出，滚回来接着放；打开正片播放器时拆掉，关掉后重新开始；
 * - 原盘（镜像 / 目录）Exo 读不了，不放预告，只留剧照。
 */
@Stable
class StagePreview(
    private val context: Context,
    private val api: McApi,
    private val server: ServerAddress,
    private val http: OkHttpClient,
    private val userAgent: String,
    private val scope: CoroutineScope,
) {
    data class Request(val mediaItemId: Long, val source: String, val season: Long = 0, val episode: Long = 0)

    /** 当前讲的是哪一部 */
    var key by mutableStateOf<Long?>(null)
        private set
    /** 画面该不该露出来（开播且出了第一帧、没放完、可见） */
    var showing by mutableStateOf(false)
        private set
    var player by mutableStateOf<ExoPlayer?>(null)
        private set
    /** 片段进度 0～1（首页卡片行让位时那条细线） */
    val progress: Float
        get() {
            val p = player ?: return 0f
            val duration = p.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: return 0f
            return (p.currentPosition.toFloat() / duration).coerceIn(0f, 1f)
        }

    private var current: Request? = null
    private val owners = mutableMapOf<Any, Request>()
    private var cycle: Job? = null
    private var leaveJob: Job? = null
    private var interrupted = false
    /** 挂着预告画面的大图层（后出现的在后）与其中被滚走的：画面只给最后出现的那层，它没被滚走才放（同 Apple 端） */
    private val surfaces = mutableListOf<Any>()
    private val hiddenSurfaces = mutableSetOf<Any>()
    var surfaceOwner by mutableStateOf<Any?>(null)
        private set
    private val visible: Boolean
        get() = surfaceOwner?.let { it !in hiddenSurfaces } ?: false
    private var dwellDone = false
    private var loaded = false
    private var started = false
    private var ended = false
    private var framed = false

    fun show(request: Request, owner: Any) {
        leaveJob?.cancel()
        val sameTitle = key == request.mediaItemId
        if (!sameTitle) owners.clear()
        owners[owner] = request
        if (sameTitle && started && !ended) return
        if (current == request && (cycle?.isActive == true || ended)) return
        begin(request)
    }

    fun leave(owner: Any) {
        owners.remove(owner)
        if (owners.isNotEmpty()) return
        leaveJob?.cancel()
        leaveJob = scope.launch {
            delay(400)
            if (owners.isEmpty()) {
                teardown()
                key = null
                current = null
            }
        }
    }

    /** 正片播放器打开：拆掉预告；关掉之后按最后一页的请求重新开始（新的续播点） */
    fun interrupt() {
        interrupted = true
        teardown()
    }

    fun resume() {
        if (!interrupted) return
        interrupted = false
        owners.values.lastOrNull()?.let(::begin)
    }

    /** 一层大图出现在屏幕上（页面被压下去算消失） */
    fun claimSurface(token: Any) {
        surfaces.remove(token)
        surfaces.add(token)
        surfaceOwner = token
        refresh()
    }

    fun releaseSurface(token: Any) {
        surfaces.remove(token)
        hiddenSurfaces.remove(token)
        surfaceOwner = surfaces.lastOrNull()
        refresh()
    }

    /** 这一层的大图滚走了 / 滚回来了 */
    fun setSurface(token: Any, visible: Boolean) {
        if (visible) hiddenSurfaces.remove(token) else hiddenSurfaces.add(token)
        refresh()
    }

    private fun begin(request: Request) {
        teardown()
        key = request.mediaItemId
        current = request
        if (interrupted) return
        cycle = scope.launch {
            val shownAt = System.currentTimeMillis()
            val dwell = launch { delay(DWELL_MS) }
            val item = runCatching { api.reelsPreview(request.mediaItemId, request.source, request.season, request.episode) }.getOrNull() ?: return@launch
            val raw = item.play.streamUrl ?: return@launch
            if (item.play.disc != null) return@launch
            val url = server.resolve(raw) ?: return@launch
            val elapsed = System.currentTimeMillis() - shownAt
            if (elapsed < ENGINE_DELAY_MS) delay(ENGINE_DELAY_MS - elapsed)
            startPlayer(url.toString(), item.segment.startMs, item.segment.endMs)
            dwell.join()
            dwellDone = true
            startIfReady()
        }
    }

    private fun startPlayer(url: String, startMs: Long, endMs: Long) {
        val exo = ExoPlayer.Builder(context)
            .setMediaSourceFactory(DefaultMediaSourceFactory(context).setDataSourceFactory(OkHttpDataSource.Factory(http).setUserAgent(userAgent)))
            .build()
        exo.volume = 0f
        exo.repeatMode = Player.REPEAT_MODE_OFF
        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                when (state) {
                    Player.STATE_READY -> if (!loaded) {
                        loaded = true
                        startIfReady()
                    }
                    Player.STATE_ENDED -> {
                        ended = true
                        refresh()
                        val finished = exo
                        scope.launch {
                            delay(1500)
                            if (player === finished) teardown(keepEnded = true)
                        }
                    }
                }
            }

            override fun onRenderedFirstFrame() {
                framed = true
                refresh()
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) = teardown(keepEnded = true)
        })
        exo.setMediaItem(
            MediaItem.Builder()
                .setUri(Uri.parse(url))
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder().setStartPositionMs(startMs).apply { if (endMs > startMs) setEndPositionMs(endMs) }.build(),
                )
                .build(),
        )
        exo.playWhenReady = false
        exo.prepare()
        player = exo
    }

    private fun startIfReady() {
        val exo = player ?: return
        if (!dwellDone || !loaded || started || ended || !visible || interrupted) return
        started = true
        exo.play()
        // 第一帧可能在暂停预滚时就已经画出来了：开播这一刻重新算一次要不要露出画面
        refresh()
        scope.launch {
            for (step in 1..15) {
                delay(100)
                if (player !== exo) return@launch
                exo.volume = step / 15f
            }
        }
    }

    private fun refresh() {
        showing = started && framed && !ended && visible && !interrupted
        val exo = player ?: return
        if (!started || ended) {
            startIfReady()
            return
        }
        if (visible) exo.play() else exo.pause()
    }

    private fun teardown(keepEnded: Boolean = false) {
        cycle?.cancel()
        cycle = null
        player?.let { old ->
            old.pause()
            scope.launch {
                delay(500)
                old.release()
            }
        }
        player = null
        showing = false
        dwellDone = false
        loaded = false
        started = false
        framed = false
        ended = keepEnded
    }

    private companion object {
        const val DWELL_MS = 2_000L
        const val ENGINE_DELAY_MS = 500L
    }
}

/**
 * 预告画面层（TVStagePreviewLayer）：盖在剧照上、铺满 16:9；淡入 0.9 秒，放完 / 滚走淡出 1.2 秒。
 * 用 TextureView 承载，才能跟着淡入淡出（SurfaceView 是独立图层，透明度管不到）。
 */
@Composable
fun BoxScope.StagePreviewLayer(preview: StagePreview, mediaItemId: Long, visible: Boolean) {
    val token = remember { Any() }
    // 压在别的页下面的页面不算在屏幕上（同 tvOS 导航栈里被盖住的页 onDisappear）
    val pageVisible = io.movieclaw.androidtv.ui.shell.LocalPageVisible.current
    DisposableEffect(preview, pageVisible) {
        if (pageVisible) preview.claimSurface(token)
        onDispose { preview.releaseSurface(token) }
    }
    // 重新出现时 release 已把「滚走」记号清掉了，跟着再报一次
    DisposableEffect(preview, pageVisible, visible) {
        preview.setSurface(token, visible)
        onDispose { }
    }
    val mine = preview.key == mediaItemId
    val shown = mine && preview.showing
    val alpha by animateFloatAsState(if (shown) 1f else 0f, tween(if (shown) 900 else 1200), label = "preview")
    val exo = preview.player
    // 只有轮到这一层才挂画面：首页与详情页的大图同时在时，两边都挂同一个播放器会抢画面
    if (mine && exo != null && preview.surfaceOwner === token) {
        ContentFrame(
            player = exo,
            // 视频画面是一张纹理：透明度直接乘上去，不用整屏离屏（docs/perf/androidtv-home-scroll-2026-10.md）
            modifier = Modifier.fillMaxSize().graphicsLayer {
                this.alpha = alpha
                compositingStrategy = CompositingStrategy.ModulateAlpha
            },
            surfaceType = SURFACE_TYPE_TEXTURE_VIEW,
            contentScale = ContentScale.Crop,
        )
    }
}

/** 一个账号一个预告控制器（主界面里共享） */
@Composable
fun rememberStagePreview(api: McApi, server: ServerAddress, http: OkHttpClient, userAgent: String, scope: CoroutineScope): StagePreview {
    val context = LocalContext.current.applicationContext
    return remember(api, server) { StagePreview(context, api, server, http, userAgent, scope) }
}

/** 页面挂接预告：显示时声明在用，离开时让出（400 毫秒内另一页接手就不拆） */
@Composable
fun UseStagePreview(preview: StagePreview, request: StagePreview.Request?) {
    val owner = remember { Any() }
    // 页面被压在别的页下面时让出预告，回到屏幕上再接着要（首页 → 详情是同一部就接着放）
    val visible = io.movieclaw.androidtv.ui.shell.LocalPageVisible.current
    // 与画面层的认领同一拍生效、并且排在它前面（页面里先调这里）：退回来时先按这一页的规则要片段，
    // 再认领画面，不然上一页没开播的那段会抢先开播
    DisposableEffect(request, visible) {
        if (visible && request != null) preview.show(request, owner) else preview.leave(owner)
        onDispose { }
    }
    DisposableEffect(preview) { onDispose { preview.leave(owner) } }
}
