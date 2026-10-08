@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package io.movieclaw.android.core.playback

import android.content.Context
import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSourceFactory
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.SingleSampleMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import io.movieclaw.android.core.network.BuildInfo

/**
 * 引擎缓冲档 —— **内存上限只在这里管**。
 *
 * Media3 默认按「最多缓冲 50 秒视频」算，不看字节：4K remux 码率 60~100 Mbps 时一个
 * 播放器就能吃掉几百 MB Java 堆。实机在片段页抓到过 OOM 崩溃（两条 ExoPlayer 线程同时
 * 报 `OutOfMemoryError: … target footprint 268435456`，堆只有 256MB），表现先是整机
 * GC 抖动「转圈卡一会」，随后进程被杀。
 *
 * · [Normal]：正片与片段的当前条（96MB / 最长 15 秒——LAN 上 15 秒缓冲足够，1080p 下
 *   时间上限先生效，4K 下字节上限先生效）；
 * · [Compact]：预起的下一条（12MB / 最长 4 秒——装载到片段起点停着就好，不往前多吃，
 *   这也是 iOS「预起后停止往前下载」的对应物）。
 */
enum class BufferProfile(val label: String, val targetBytes: Int, val minMs: Int, val maxMs: Int) {
    Normal("normal", 96 * 1024 * 1024, 5_000, 15_000),
    Compact("compact", 12 * 1024 * 1024, 2_000, 4_000),
}

/**
 * Exo 内核:硬解主力(省电、低延迟)+ 服务端 HLS 的唯一消费者。
 * 直连走 ProgressiveMediaSource,HLS 走 HlsMediaSource;流 URL 带签名 token 免鉴权头。
 */
class ExoEngine(
    private val context: Context,
    profile: BufferProfile = BufferProfile.Normal,
) : PlayerEngine {

    val player: ExoPlayer = ExoPlayer.Builder(context)
        .setLoadControl(
            androidx.media3.exoplayer.DefaultLoadControl.Builder()
                .setTargetBufferBytes(profile.targetBytes)
                .setBufferDurationsMs(profile.minMs, profile.maxMs, 1_000, 2_000)
                // 先看字节上限：高码率片不能按时间把堆撑爆（默认 true 是时间优先）
                .setPrioritizeTimeOverSizeThresholds(false)
                .build()
        )
        .build()
        .also { android.util.Log.i("McPlayer", "引擎缓冲档=${profile.label} 上限=${profile.targetBytes / 1024 / 1024}MB") }

    /** 解码类错误回调:直连失败时 PlaybackController 据此自动切 MPV(网络错误不切) */
    var onDecodeError: ((Long) -> Unit)? = null

    /**
     * 起播要落的那条音轨（`embedded:N`）。轨道要等 prepare 之后才有，
     * 所以这里存着，在 `onTracksChanged` 里落一次就清掉——**只落一次**：
     * 之后用户自己换轨（`selectAudioIndex`）不再被它拉回去。
     */
    private var pendingInitialAudioRef: String? = null

    /** 真实吞吐采样:数据源每传一段字节就记一次(降质建议的「实测带宽」来源) */
    private val transferMeter = TransferMeter()

    private val httpFactory = DefaultHttpDataSource.Factory()
        .setAllowCrossProtocolRedirects(true)
        .setConnectTimeoutMs(15_000)
        .setReadTimeoutMs(30_000)
        .setTransferListener(transferMeter)
        .setUserAgent(BuildInfo.USER_AGENT)

    /** 近 windowMs 的实测吞吐(bps);样本不足返回 null */
    fun measuredBps(windowMs: Long = 30_000L): Double? = transferMeter.measuredBps(windowMs)

    init {
        // 加载速度读数（iOS `LoadingSpeedMeter` 的近似物）：直接取 Exo 的带宽估计（bits/s），
        // 等待态那行「↓ x.x MB/s」用它——和播放器自己选码率用的是同一个量
        player.addAnalyticsListener(object : androidx.media3.exoplayer.analytics.AnalyticsListener {
            override fun onBandwidthEstimate(
                eventTime: androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime,
                elapsedMs: Int,
                bytes: Long,
                bitrateEstimate: Long,
            ) {
                bandwidthBps = bitrateEstimate.takeIf { it > 0 }
            }
        })
        player.addListener(object : Player.Listener {
            /**
             * 轨道解析出来之后把**计划里的那条音轨**落下（iOS `selectInitialAudio` 的对应物）。
             * 只在与当前选中不同时才动，且只做一次：容器标注的默认轨恰好就是计划那条时
             * 不必多此一举，用户之后的手动换轨也不会被拉回去。
             */
            override fun onTracksChanged(tracks: androidx.media3.common.Tracks) {
                val want = pendingInitialAudioRef?.removePrefix("embedded:")?.toIntOrNull()
                    ?: run { pendingInitialAudioRef = null; return }   // 不是内封序号式引用：不必落轨
                val groups = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
                if (groups.isEmpty()) return          // 还没解析出音轨：等下一次回调
                pendingInitialAudioRef = null
                if (groups.getOrNull(want)?.isSelected == true) return   // 本来就放这条
                android.util.Log.i("McPlayer", "起播落轨: 音轨 embedded:$want（容器默认不是它）")
                selectAudioIndex(want)
            }

            override fun onPlayerError(error: PlaybackException) {
                // IO_UNSPECIFIED 既可能是传输问题（换内核没意义），也可能是**数据根本不是
                // Exo 解析器能吃的**（cause 链里是 IllegalStateException/ParserException，
                // 例如 `Top bit not zero: -1024` —— 实机在服务端换封装流上抓到过，表现是
                // 画面起不来、日志只说"不在兜底集合"）。后者换 mpv 就能放，所以按 cause 判定。
                val fallback = error.errorCode in DECODE_ERROR_CODES ||
                    (error.errorCode == PlaybackException.ERROR_CODE_IO_UNSPECIFIED && isFormatLikeError(error))
                android.util.Log.w(
                    "McPlayer",
                    "player error code=${error.errorCode} name=${error.errorCodeName} " +
                        "msg=${error.message} -> ${if (fallback) "切换到 mpv 内核" else "仅记录（不在兜底集合）"}",
                )
                // 把 cause 链打出来：IO 类错误里通常写着失败的具体 URL 与底层异常
                var c: Throwable? = error.cause
                var depth = 0
                while (c != null && depth < 3) {
                    android.util.Log.w("McPlayer", "  cause[$depth] ${c::class.java.simpleName}: ${c.message}")
                    c = c.cause
                    depth++
                }
                if (fallback) onDecodeError?.invoke(error.errorCode.toLong())
            }
        })
    }

    override fun open(source: EngineSource, sidecars: List<Sidecar>) {
        pendingInitialAudioRef = source.initialAudioRef
        val mediaItem = MediaItem.Builder()
            .setUri(source.url)
            .setCustomCacheKey(if (source.hls) null else source.cacheKey)
            .setMediaMetadata(mediaMetadataOf(source))
            .build()
        val factory: MediaSourceFactory = if (source.hls) {
            HlsMediaSource.Factory(httpFactory)
        } else {
            // 数据源链：CuesServing（MKV 精简索引，命中就绕过网络）→ 字节缓存 → 网络。
            // 缓存键由调用方给（文件 id + 大小）：正片与刷片放过的字节彼此复用。
            val upstream: DataSource.Factory = if (source.cacheKey != null) {
                SourceByteCache.playbackFactory(this.context, httpFactory)
            } else {
                httpFactory
            }
            val dsFactory: DataSource.Factory = source.matroskaCues
                ?.let { cues -> DataSource.Factory { CuesServingDataSource(upstream.createDataSource(), cues) } }
                ?: upstream
            ProgressiveMediaSource.Factory(dsFactory)
        }
        val primary = factory.createMediaSource(mediaItem)
        val startPosition = source.startPositionMs.coerceAtLeast(0L)
        if (sidecars.isEmpty()) {
            player.setMediaSource(primary, startPosition)
        } else {
            val sources = listOf(primary) + sidecars.mapIndexed { index, sidecar ->
                val configuration = MediaItem.SubtitleConfiguration.Builder(Uri.parse(sidecar.url))
                    .setMimeType(sidecar.mime)
                    .setLanguage(sidecar.language)
                    .setId("sidecar:$index")
                    .build()
                SingleSampleMediaSource.Factory(httpFactory).createMediaSource(configuration, C.TIME_UNSET)
            }
            player.setMediaSource(MergingMediaSource(*sources.toTypedArray()), startPosition)
        }
        player.prepare()
        player.playWhenReady = true
    }

    override fun setSubtitleRendering(enabled: Boolean) {
        // Media3 没有 Player.setTrackTypeDisabled：走轨道选择参数
        player.trackSelectionParameters = player.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, !enabled)
            .build()
    }

    override fun selectAudioIndex(index: Int) {
        val group = player.currentTracks.groups
            .filter { it.type == C.TRACK_TYPE_AUDIO }
            .getOrNull(index)
            ?.mediaTrackGroup ?: return
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, false)
            .setOverrideForType(TrackSelectionOverride(group, 0))
            .build()
    }

    override fun selectTextIndex(index: Int?) {
        val builder = player.trackSelectionParameters.buildUpon()
        if (index == null) {
            builder.clearOverridesOfType(C.TRACK_TYPE_TEXT)
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        } else {
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            player.currentTracks.groups
                .filter { it.type == C.TRACK_TYPE_TEXT }
                .getOrNull(index)
                ?.mediaTrackGroup
                ?.let { builder.setOverrideForType(TrackSelectionOverride(it, 0)) }
        }
        player.trackSelectionParameters = builder.build()
    }

    override fun positionMs(): Long = runCatching { player.currentPosition }.getOrDefault(0L)

    /** 带宽估计（bits/s），没采样到就是 null；等待态显示「↓ x.x MB/s」（iOS 同一种读数） */
    @Volatile
    var bandwidthBps: Long? = null
        private set

    override fun durationMs(): Long = runCatching { player.duration }.getOrDefault(0L).takeIf { it > 0 } ?: 0L

    override fun isPlaying(): Boolean = runCatching { player.isPlaying }.getOrDefault(false)

    override fun setPlaying(playing: Boolean) {
        player.playWhenReady = playing
    }

    override fun seekTo(playerMs: Long) {
        player.seekTo(playerMs.coerceAtLeast(0L))
    }

    override fun seekBy(deltaMs: Long) {
        player.seekTo(player.currentPosition + deltaMs)
    }

    override fun setSpeed(speed: Float) {
        player.setPlaybackSpeed(speed)
    }

    override fun isBuffering(): Boolean =
        player.playbackState == androidx.media3.common.Player.STATE_BUFFERING

    override fun release() {
        player.release()
    }

    /**
     * cause 链里有没有"解析/格式"类的失败：`UnexpectedLoaderException` 只是外壳，
     * 真正的异常挂在它的 cause 上，所以要往下钻几层看类型名。
     */
    private fun isFormatLikeError(error: PlaybackException): Boolean {
        var c: Throwable? = error
        var depth = 0
        while (c != null && depth < 6) {
            val name = c::class.java.simpleName
            if (c is IllegalStateException ||
                name.contains("Parser") || name.contains("Format") || name.contains("Unsupported")
            ) {
                return true
            }
            c = c.cause
            depth++
        }
        return false
    }

    private companion object {
        val DECODE_ERROR_CODES = setOf(
            // 解码器层
            PlaybackException.ERROR_CODE_DECODING_FAILED,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
            PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
            // 解析/容器层：Exo 报的「Source error」多半落在这里（DV/HEVC/特殊封装），
            // 之前不在集合里 → 既不切 mpv 也不提示，表现成「点击播放没反应」（实机日志抓到过）
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
            PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED,
            PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
        )
    }
}

/** 通知/锁屏展示用的媒体元数据(Exo 与 MPV 代理共用) */
internal fun mediaMetadataOf(source: EngineSource): MediaMetadata =
    MediaMetadata.Builder()
        .setTitle(source.title)
        .setSubtitle(source.subtitle)
        .setArtist(source.subtitle ?: source.title)
        .apply { source.artworkUrl?.let { setArtworkUri(Uri.parse(it)) } }
        .build()

/** 累计数据源字节数与时间戳,给出一段窗口内的实测吞吐 */
internal class TransferMeter : TransferListener {
    private data class Sample(val at: Long, val bytes: Long)

    private val samples = ArrayDeque<Sample>()

    @Synchronized
    override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, byteCount: Int) {
        if (!isNetwork || byteCount <= 0) return
        val now = System.currentTimeMillis()
        samples.addLast(Sample(now, byteCount.toLong()))
        while (samples.isNotEmpty() && now - samples.first().at > WINDOW_MS) samples.removeFirst()
    }

    @Synchronized
    fun measuredBps(windowMs: Long): Double? {
        val now = System.currentTimeMillis()
        val recent = samples.filter { now - it.at <= windowMs }
        if (recent.size < 3) return null
        val bytes = recent.sumOf { it.bytes }
        val spanMs = (now - recent.first().at).coerceAtLeast(1_000L)
        return bytes * 8.0 * 1000.0 / spanMs
    }

    override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
    override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
    override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit

    private companion object {
        const val WINDOW_MS = 60_000L
    }
}
