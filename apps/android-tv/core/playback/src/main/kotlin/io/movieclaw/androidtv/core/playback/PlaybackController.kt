@file:OptIn(UnstableApi::class)

package io.movieclaw.androidtv.core.playback

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.movieclaw.androidtv.core.model.generated.PlaybackProgressRequest
import io.movieclaw.androidtv.core.model.generated.PlaybackSessionRequest
import io.movieclaw.androidtv.core.model.generated.PlaybackSessionView
import io.movieclaw.androidtv.core.network.ApiException
import io.movieclaw.androidtv.core.network.ClientIdentity
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/** 要播的那一集 / 那部片。电影的季、集都是 0。 */
data class PlaybackTarget(
    val mediaItemId: Long,
    val seasonNumber: Long = 0,
    val episodeNumber: Long = 0,
    val fileId: Long? = null,
    val title: String = "",
)

data class PlaybackUiState(
    val title: String = "",
    val opening: Boolean = true,
    val isPlaying: Boolean = false,
    val buffering: Boolean = true,
    val ended: Boolean = false,
    /** 片源时间轴上的位置（不是播放器内部时间：服务端 HLS 会话可能从中途起切） */
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val error: String? = null,
    /** 起播路径，诊断与端到端验收用：「原文件直连」或「服务端 HLS」 */
    val route: String = "",
    val tier: Long? = null,
)

/**
 * 一次播放：开会话 → 选地址交给 Exo → 进度 / 心跳上报 → 失败逐级降档（docs/design/androidtv-app.md §4）。
 *
 * [scope] 要比播放页活得久（应用级）：退出播放时的「stop」上报和关会话要在页面销毁后发完。
 */
class PlaybackController(
    context: Context,
    private val api: McApi,
    private val server: ServerAddress,
    http: OkHttpClient,
    identity: ClientIdentity,
    private val deviceId: String,
    scope: CoroutineScope,
    private val capability: CapabilityProbe = CapabilityProbe(context),
) {
    private val job = SupervisorJob(scope.coroutineContext[Job])
    private val scope = CoroutineScope(scope.coroutineContext + job)
    private val _state = MutableStateFlow(PlaybackUiState())
    val state: StateFlow<PlaybackUiState> = _state.asStateFlow()

    val player: ExoPlayer = ExoPlayer.Builder(
        context,
        DefaultRenderersFactory(context)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
            .setEnableDecoderFallback(true),
    )
        .setMediaSourceFactory(
            DefaultMediaSourceFactory(context)
                .setDataSourceFactory(OkHttpDataSource.Factory(http).setUserAgent(identity.userAgent)),
        )
        .setAudioAttributes(
            AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
            true,
        )
        .build()

    private lateinit var target: PlaybackTarget
    private var session: PlaybackSessionView? = null
    /** 片源时间 = [offsetMs] + 播放器时间（只有从中途起切的 HLS 会话才非 0） */
    private var offsetMs = 0L
    private val failedTiers = mutableSetOf<Long>()
    private var audioRef: String? = null
    private var audioApplied = false
    private var startReported = false
    private var released = false
    private var loops: Job? = null

    init {
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                _state.update {
                    it.copy(buffering = playbackState == Player.STATE_BUFFERING, ended = playbackState == Player.STATE_ENDED)
                }
                if (playbackState == Player.STATE_READY) _state.update { it.copy(opening = false) }
                if (playbackState == Player.STATE_ENDED) report("stop")
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                _state.update { it.copy(isPlaying = isPlaying) }
                if (isPlaying && !startReported) {
                    startReported = true
                    report("start")
                } else if (!isPlaying && startReported && player.playbackState == Player.STATE_READY) {
                    report("progress", paused = true)
                }
            }

            override fun onTracksChanged(tracks: Tracks) = applyAudioTrack(tracks)

            override fun onPlayerError(error: PlaybackException) = fallBack(error)
        })
    }

    fun start(target: PlaybackTarget) {
        this.target = target
        _state.update { it.copy(title = target.title) }
        scope.launch {
            if (target.title.isBlank()) {
                // 从深链 / 调试参数直达时没有片名，向服务端补一个
                runCatching { api.playbackItemInfo(target.mediaItemId).title }
                    .onSuccess { title -> _state.update { it.copy(title = title) } }
            }
            open(startMs = null)
        }
    }

    fun togglePlayPause() {
        if (player.isPlaying) player.pause() else player.play()
    }

    fun seekBy(deltaMs: Long) {
        val duration = player.duration.takeIf { it != C.TIME_UNSET } ?: Long.MAX_VALUE
        player.seekTo((player.currentPosition + deltaMs).coerceIn(0, duration))
        tick()
    }

    /** 退出播放：上报 stop、关服务端会话、释放播放器。 */
    fun release() {
        if (released) return
        released = true
        val sessionId = session?.sessionId
        val stop = progressRequest("stop", paused = null)
        loops?.cancel()
        player.release()
        scope.launch {
            runCatching { api.playbackProgress(stop) }
            if (sessionId != null) runCatching { api.playbackSessionStop(sessionId) }
            job.cancel()
        }
    }

    private suspend fun open(startMs: Long?) {
        _state.update { it.copy(opening = true, error = null) }
        val previous = session?.sessionId
        val opened = try {
            api.playbackSessionStart(
                PlaybackSessionRequest(
                    fileId = target.fileId,
                    mediaItemId = target.mediaItemId,
                    seasonNumber = target.seasonNumber,
                    episodeNumber = target.episodeNumber,
                    capability = capability.probe(),
                    failedTiers = failedTiers.toList().takeIf { it.isNotEmpty() },
                    deviceId = deviceId,
                    startMs = startMs,
                    client = ClientIdentity.KIND,
                ),
            )
        } catch (e: Exception) {
            fail(e.message ?: "打不开这部片")
            return
        }
        if (previous != null) runCatching { api.playbackSessionStop(previous) }
        val decision = opened.decision
        when (decision.outcome) {
            "plan" -> Unit
            "consent" -> return fail("这部片需要服务器软件转码。${decision.reason}\n请管理员在网页「设置 → 播放」里开启软件转码后再试")
            else -> return fail(listOfNotNull(decision.reason, decision.suggestion).joinToString("\n"))
        }
        val url = (opened.masterUrl ?: opened.streamUrl)?.let(server::resolve)
            ?: return fail("服务器没有给出播放地址")
        session = opened
        audioRef = decision.audio?.trackRef
        audioApplied = false
        val hls = opened.sessionId != null
        offsetMs = if (hls && opened.timeline == "session") opened.startMs else 0
        val item = MediaItem.Builder()
            .setUri(Uri.parse(url.toString()))
            .apply { if (hls) setMimeType(MimeTypes.APPLICATION_M3U8) }
            .setSubtitleConfigurations(externalSubtitles(opened))
            .build()
        _state.update {
            it.copy(
                route = if (hls) "服务端 HLS" else "原文件直连",
                tier = decision.tier,
                durationMs = opened.watch?.durationMs ?: it.durationMs,
            )
        }
        Log.i(TAG, "起播 item=${target.mediaItemId} tier=${decision.tier} route=${_state.value.route} start=${opened.startMs}")
        player.setMediaItem(item, if (hls) opened.startMs - offsetMs else opened.startMs)
        player.prepare()
        player.play()
        startLoops()
    }

    /** 外挂字幕（`external:*`）旁挂给 Exo；内封字幕直连时 Exo 自己从容器里读，HLS 会话在 master 里。 */
    private fun externalSubtitles(session: PlaybackSessionView): List<MediaItem.SubtitleConfiguration> =
        session.decision.subtitles.zip(session.subtitleUrls).mapNotNull { (plan, raw) ->
            if (!plan.trackRef.startsWith("external:")) return@mapNotNull null
            val (mime, suffix) = when (plan.kind) {
                "vtt" -> MimeTypes.TEXT_VTT to "&format=vtt"
                "ass" -> MimeTypes.TEXT_SSA to ""
                else -> return@mapNotNull null
            }
            val url = server.resolve(raw + suffix) ?: return@mapNotNull null
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(url.toString()))
                .setMimeType(mime)
                .setLanguage(plan.language)
                .setLabel(plan.title)
                .setSelectionFlags(if (plan.isDefault) C.SELECTION_FLAG_DEFAULT else 0)
                .build()
        }

    /** 计划里选的音轨（`embedded:N`，N 是文件里第几条音轨）在本机选中——申报了 local_tracks，服务端没为它重封装。 */
    private fun applyAudioTrack(tracks: Tracks) {
        if (audioApplied || session?.sessionId != null) return
        val index = audioRef?.removePrefix("embedded:")?.toIntOrNull() ?: return
        val groups = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
        if (groups.isEmpty()) return
        audioApplied = true
        val group = groups.getOrNull(index) ?: return
        if (group.isSelected) return
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, 0))
            .build()
    }

    /** 播放出错：带上失败的档位重开会话，从当前位置接着放。 */
    private fun fallBack(error: PlaybackException) {
        val tier = session?.decision?.tier
        Log.w(TAG, "播放出错 tier=$tier：${error.errorCodeName}", error)
        if (tier == null || tier >= MAX_TIER || released) {
            fail("播放失败：${error.errorCodeName}")
            return
        }
        failedTiers += tier
        val position = filePosition()
        scope.launch { open(startMs = position) }
    }

    private fun startLoops() {
        loops?.cancel()
        loops = scope.launch {
            launch {
                while (isActive) {
                    tick()
                    delay(500)
                }
            }
            launch {
                while (isActive) {
                    delay(PROGRESS_INTERVAL_MS)
                    if (player.isPlaying) report("progress", paused = false)
                }
            }
            val sessionId = session?.sessionId ?: return@launch
            launch {
                while (isActive) {
                    delay(PING_INTERVAL_MS)
                    try {
                        api.playbackSessionPing(sessionId)
                    } catch (e: ApiException) {
                        // 会话被服务端回收（超时、重启）：在当前位置重开
                        if (e.status == 404) open(startMs = filePosition())
                        return@launch
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    private fun tick() {
        val duration = player.duration.takeIf { it != C.TIME_UNSET }?.let { it + offsetMs }
        _state.update { it.copy(positionMs = filePosition(), durationMs = duration ?: it.durationMs) }
    }

    private fun filePosition(): Long = offsetMs + player.currentPosition.coerceAtLeast(0)

    private fun report(event: String, paused: Boolean? = null) {
        if (!::target.isInitialized || released) return
        val request = progressRequest(event, paused)
        scope.launch {
            runCatching { api.playbackProgress(request) }.onSuccess { state ->
                if (state.endedByAdmin) fail("管理员结束了这次播放")
            }
        }
    }

    private fun progressRequest(event: String, paused: Boolean?) = PlaybackProgressRequest(
        mediaItemId = target.mediaItemId,
        seasonNumber = target.seasonNumber,
        episodeNumber = target.episodeNumber,
        event = event,
        positionMs = if (event == "start") null else filePosition(),
        audioTrack = audioRef,
        fileId = session?.decision?.fileId,
        deviceId = deviceId,
        paused = paused,
    )

    private fun fail(message: String) {
        player.stop()
        _state.update { it.copy(opening = false, buffering = false, error = message) }
    }

    private companion object {
        const val TAG = "Playback"
        const val PROGRESS_INTERVAL_MS = 10_000L
        const val PING_INTERVAL_MS = 15_000L
        /** 档 4 软件转码之后没有更低的档了 */
        const val MAX_TIER = 4L
    }
}
