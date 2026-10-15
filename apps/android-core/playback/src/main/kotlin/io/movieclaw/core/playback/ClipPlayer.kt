@file:OptIn(UnstableApi::class)

package io.movieclaw.core.playback

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import okhttp3.OkHttpClient

/**
 * 一条片段（刷片、预告）的播放器：与正片同一套引擎配置（[UnifiedExo]：FFmpeg 音频软解、解码器黑名单、缓冲上限），
 * 直出原文件时挂片源字节缓存（[SourceByteCache]）。
 *
 * 只管「把这条放起来」：没有会话协议、兜底阶梯与进度上报——片段放不了就换下一条，换条、预起、预取的编排在调用方。
 * 字幕由调用方叠层画（服务端给的是片段窗口的字幕文件），引擎不画任何文本轨。所有方法在主线程调。
 */
class ClipPlayer(
    private val context: Context,
    http: OkHttpClient,
    userAgent: String,
    denylist: DecoderDenylist,
    /** 预起的下一条用 [UnifiedExo.Buffer.Standby]：只装载到起点 */
    buffer: UnifiedExo.Buffer = UnifiedExo.Buffer.Main,
) {
    /** 片段的一次装载 */
    data class Source(
        val url: String,
        val hls: Boolean,
        /** 引擎起播位置（播放器时间） */
        val startMs: Long,
        /** 装载后直接播；预起的下一条传 false：停在起点，滑过去才播 */
        val autoplay: Boolean = true,
        /** 起播要放的内封音轨序号（容器顺序）；null = 容器默认轨 */
        val audioIndex: Int? = null,
        /** 片源字节缓存的键（[SourceByteCache.key]）；HLS 与没有键的不挂缓存 */
        val cacheKey: String? = null,
    )

    private val network: DataSource.Factory = OkHttpDataSource.Factory(http).setUserAgent(userAgent)

    val player: ExoPlayer = UnifiedExo.build(context, network, denylist, ass = null, buffer = buffer).apply {
        trackSelectionParameters = trackSelectionParameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).build()
    }

    /** 带宽估计（bits/s），没采样到是 null：等待态的「↓ x.x MB/s」用 */
    @Volatile
    var bandwidthBps: Long? = null
        private set

    /** 起播要落的音轨：轨道解析出来后落一次就清掉，之后用户换轨不会被拉回去 */
    private var pendingAudioIndex: Int? = null

    init {
        player.addAnalyticsListener(object : AnalyticsListener {
            override fun onBandwidthEstimate(eventTime: AnalyticsListener.EventTime, totalLoadTimeMs: Int, totalBytesLoaded: Long, bitrateEstimate: Long) {
                bandwidthBps = bitrateEstimate.takeIf { it > 0 }
            }
        })
        player.addListener(object : Player.Listener {
            override fun onTracksChanged(tracks: Tracks) {
                val want = pendingAudioIndex ?: return
                val groups = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
                if (groups.isEmpty()) return
                pendingAudioIndex = null
                val group = groups.getOrNull(want)?.takeIf { !it.isSelected && it.isSupported(true) } ?: return
                player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
                    .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, 0)).build()
            }
        })
    }

    fun open(source: Source) {
        pendingAudioIndex = source.audioIndex
        val item = MediaItem.Builder().setUri(Uri.parse(source.url))
        val media = if (source.hls) {
            HlsMediaSource.Factory(network).createMediaSource(item.setMimeType(MimeTypes.APPLICATION_M3U8).build())
        } else {
            // 直出原文件：带键就挂字节缓存（放过的与预取的字节都在本地）
            val key = source.cacheKey
            val upstream = if (key != null) SourceByteCache.playbackFactory(context, network) else network
            ProgressiveMediaSource.Factory(upstream).createMediaSource(item.setCustomCacheKey(key).build())
        }
        player.setMediaSource(media, source.startMs.coerceAtLeast(0))
        player.playWhenReady = source.autoplay
        player.prepare()
    }

    /** 预取用的网络数据源（与播放同一个连接池与 User-Agent）：交给 [SourceByteCache.prefetch] */
    val prefetchSource: DataSource.Factory get() = network

    fun positionMs(): Long = player.currentPosition

    fun durationMs(): Long = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0L

    fun setPlaying(playing: Boolean) {
        player.playWhenReady = playing
    }

    fun seekTo(ms: Long) = player.seekTo(ms.coerceAtLeast(0))

    fun seekBy(deltaMs: Long) = seekTo(player.currentPosition + deltaMs)

    fun setSpeed(speed: Float) = player.setPlaybackSpeed(speed)

    fun release() = player.release()
}
