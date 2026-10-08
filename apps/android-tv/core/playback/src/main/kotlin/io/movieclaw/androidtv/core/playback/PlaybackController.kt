@file:OptIn(UnstableApi::class)

package io.movieclaw.androidtv.core.playback

import android.content.Context
import android.net.Uri
import android.os.SystemClock
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.Cue
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.extractor.DefaultExtractorsFactory
import io.github.peerless2012.ass.media.AssHandler
import io.github.peerless2012.ass.media.AssHandlerConfig
import io.github.peerless2012.ass.media.kt.withAssMkvSupport
import io.github.peerless2012.ass.media.kt.withAssSupport
import io.github.peerless2012.ass.media.parser.AssSubtitleParserFactory
import io.github.peerless2012.ass.media.type.AssRenderType
import io.github.peerless2012.ass.media.widget.AssSubtitleView
import androidx.media3.exoplayer.mediacodec.MediaCodecDecoderException
import androidx.media3.exoplayer.mediacodec.MediaCodecRenderer
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import androidx.media3.session.MediaSession
import io.movieclaw.androidtv.core.model.generated.PlaybackClientLogPayload
import io.movieclaw.androidtv.core.model.generated.PlaybackMetricPayload
import io.movieclaw.androidtv.core.model.generated.PlaybackPolicyPayload
import io.movieclaw.androidtv.core.model.generated.PlaybackProgressRequest
import io.movieclaw.androidtv.core.model.generated.PlaybackSessionRequest
import io.movieclaw.androidtv.core.model.generated.PlaybackSessionView
import io.movieclaw.androidtv.core.model.generated.PlaybackStateView
import io.movieclaw.androidtv.core.network.ApiException
import io.movieclaw.androidtv.core.network.ClientIdentity
import io.movieclaw.androidtv.core.network.ImageUrls
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.UnreachableException
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * 播放控制器：会话协议 + 状态机 + Exo 编排（对照 Apple 端 Shared/Player/PlaybackController.swift，docs/design/androidtv-app.md §4）。
 *
 * ## 起播链路
 * 「决策 → 开会话 → 装载 Exo → 缓冲 → 出画」四段异步，中间随时可能插进来 seek、换轨、降档、切集。每次去后端要地址
 * 都带一个递增的 [attempt] 序号：响应回来时已被超越，就把刚拉起的会话当场掐掉，绝不让它变成占着转码名额的孤儿。
 *
 * ## 播放方式
 * 申报 Exo 能直接解封装的容器 + `local_tracks`：服务端能直连就给原文件（档 0，Range + 令牌），内封音轨 / 字幕在本机切；
 * 放不了时给服务端 HLS（换封装 / 转码），失败逐级降档（[FailurePolicy]）。
 *
 * ## 时间轴
 * Exo 只认「流时间」。文件时间 = [originMs] + 流时间：原文件直连与 VOD 列表（timeline=file）参照点是 0；
 * 会话相对列表（timeline=session）参照点是会话起点 `start_ms`。
 *
 * 所有方法都在主线程调（[scope] 是主线程的应用级协程）；[scope] 比播放页活得久，退出时的 stop 上报和关会话在页面销毁后发完。
 */
class PlaybackController(
    context: Context,
    private val api: McApi,
    private val server: ServerAddress,
    private val http: OkHttpClient,
    private val identity: ClientIdentity,
    private val deviceId: String,
    /** 账号令牌：系统「正在播放」取封面要带（图片接口要登录） */
    token: String,
    prefs: PrefsStore,
    scope: CoroutineScope,
    private val target: PlaybackTarget,
    capabilityOverride: CapabilityProbe? = null,
    /** 调试包：每秒往 logcat（PlaybackProbe）打一行状态，给故障注入实验台判定用 */
    private val probe: Boolean = false,
    /** 实验室场景名（调试参数 mc_lab）：这些播放的记录打上标签，统计默认排除 */
    private val lab: String = "",
) {
    private val denylist = DecoderDenylist(prefs, identity.appVersion)
    private val capability = capabilityOverride ?: CapabilityProbe(context, denylist::isDenied)
    private val deviceFacts = DeviceFacts(context)

    /** 最近一次 Exo 报错里出错的解码器（名字, MIME）：确定这一路解不了时拉黑它 */
    private var failedDecoder: Pair<String, String>? = null
    private val engineFacts = EngineFacts()
    private val reportStore = PlaybackReportStore(prefs, context.filesDir)
    private val job = SupervisorJob(scope.coroutineContext[Job])
    private val scope = CoroutineScope(scope.coroutineContext + job)

    private val _state = MutableStateFlow(PlayerState(unit = PlaybackUnit(target.mediaItemId, target.seasonNumber, target.episodeNumber)))
    val state: StateFlow<PlayerState> = _state.asStateFlow()
    private val s: PlayerState get() = _state.value
    private inline fun set(block: PlayerState.() -> PlayerState) {
        _state.value = _state.value.block()
    }

    /** Exo 自己画的字幕（直连原文件时的内封 / 外挂轨）：变化频繁，单独一路，免得整个控制层跟着重组 */
    private val _cues = MutableStateFlow<List<Cue>>(emptyList())
    val cues: StateFlow<List<Cue>> = _cues.asStateFlow()

    // ---- 引擎 ----

    /** 这一秒收到的字节（转圈下的「↓ 速度」、看门狗的「还有没有字节在进来」） */
    private val bytesLoaded = AtomicLong(0)
    private val bandwidth = DefaultBandwidthMeter.Builder(context).build()

    private val dataSource: DataSource.Factory = OkHttpDataSource.Factory(http)
        .setUserAgent(identity.userAgent)
        .setTransferListener(object : TransferListener {
            override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
            override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
            override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
                if (isNetwork) bytesLoaded.addAndGet(bytesTransferred.toLong())
            }
            override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) = Unit
        })

    /**
     * ASS / SSA 特效字幕走 libass（ass-media，MIT；§4.3）：叠加层渲染（OVERLAY_OPEN_GL），保留定位、样式与动画，
     * 不进视频管线——HDR / 杜比视界输出不受影响、不挡界面线程。渲染像素封顶 1080p：4K 电视上省 CPU，字幕仍清楚
     */
    private val ass = AssHandler(AssRenderType.OVERLAY_OPEN_GL, AssHandlerConfig(maxRenderPixels = 1920 * 1080))
    private val assParsers = AssSubtitleParserFactory(ass)

    private val exo: ExoPlayer = ExoPlayer.Builder(
        context,
        DefaultRenderersFactory(context)
            // 扩展（FFmpeg 音频软解）排在系统解码器之后：系统能解、或能透传给电视 / 功放的（AC3 / E-AC-3 全景声 /
            // TrueHD）照旧走系统，FFmpeg 只兜底两者都不行的。PREFER 会让 FFmpeg 抢先解成 PCM，透传就没了
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)
            // 这台机器上实测坏过的解码器不再选（DecoderDenylist）
            .setMediaCodecSelector { mime, secure, tunneling ->
                MediaCodecSelector.DEFAULT.getDecoderInfos(mime, secure, tunneling).filterNot { denylist.isDenied(it.name) }
            }
            .withAssSupport(ass),
    )
        .setMediaSourceFactory(
            // MKV 里的 ASS 轨与外挂的 .ass 都交给 libass 解析（其余字幕照旧走 Exo）
            DefaultMediaSourceFactory(dataSource, DefaultExtractorsFactory().withAssMkvSupport(assParsers, ass))
                .setSubtitleParserFactory(assParsers),
        )
        .setBandwidthMeter(bandwidth)
        // 缓冲字节上限跟着本进程的堆走（Exo 的缓冲在 Java 堆里）：默认上限约 130 MB，小堆的盒子放高码率片直接
        // 内存溢出（Android 6 镜像堆上限 48 MB，《老友记》播放即崩）
        .setLoadControl(
            DefaultLoadControl.Builder()
                .setTargetBufferBytes(BufferBudget.targetBytes(Runtime.getRuntime().maxMemory()))
                .setPrioritizeTimeOverSizeThresholds(false)
                .build(),
        )
        .setAudioAttributes(
            AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
            true,
        )
        .build()
        .also(ass::init)

    /** ASS 字幕的叠加层（界面放在画面上方、与画面同大小） */
    fun assOverlay(context: Context): android.view.View = AssSubtitleView(context, ass)

    /** 交给画面与系统媒体会话的播放器：系统 / 语音助手的播放、暂停、快进都绕回控制器（用户意图、上报都要走同一条路） */
    val player: Player = object : ForwardingPlayer(exo) {
        override fun play() = this@PlaybackController.play()
        override fun pause() = this@PlaybackController.pause()
        override fun setPlayWhenReady(playWhenReady: Boolean) = if (playWhenReady) play() else pause()
        // 系统给的是 Exo 的流时间，换回文件时间
        override fun seekTo(positionMs: Long) = this@PlaybackController.seekTo(originMs + positionMs, exact = true, source = "media_key")
        override fun seekTo(mediaItemIndex: Int, positionMs: Long) = this@PlaybackController.seekTo(originMs + positionMs, exact = true, source = "media_key")
        override fun seekForward() = this@PlaybackController.seekBy(10_000)
        override fun seekBack() = this@PlaybackController.seekBy(-10_000)
        override fun getSeekForwardIncrement(): Long = 10_000
        override fun getSeekBackIncrement(): Long = 10_000
        override fun seekToNext() = playNext()
        override fun seekToNextMediaItem() = playNext()
        override fun seekToPrevious() = playPrevious()
        override fun seekToPreviousMediaItem() = playPrevious()
        override fun getMediaMetadata(): MediaMetadata = metadata
        override fun hasNextMediaItem(): Boolean = s.nextEpisode != null
        override fun hasPreviousMediaItem(): Boolean = s.previousEpisode != null
        override fun isCommandAvailable(command: Int): Boolean = command in EXTRA_COMMANDS || super.isCommandAvailable(command)
        override fun getAvailableCommands(): Player.Commands =
            super.getAvailableCommands().buildUpon().addAll(*EXTRA_COMMANDS.toIntArray()).build()
    }

    /** 系统「正在播放」的信息（条目信息、分集清单到了之后补上；换集跟着换） */
    private var metadata: MediaMetadata = MediaMetadata.EMPTY

    private val mediaSession: MediaSession? = runCatching {
        MediaSession.Builder(context, player)
            .setId("movieclaw-player-${System.identityHashCode(this)}")
            .setBitmapLoader(
                DataSourceBitmapLoader.Builder(context)
                    .setDataSourceFactory(OkHttpDataSource.Factory(http).setDefaultRequestProperties(mapOf("Authorization" to "Bearer $token")))
                    .build(),
            )
            .build()
    }.onFailure { Log.w(TAG, "系统媒体会话建不起来", it) }.getOrNull()

    // ---- 单元与会话 ----

    private val unit: PlaybackUnit get() = s.unit
    private var session: PlaybackSessionView? = null
    private var activeSessionId: String? = null
    private var attempt = 0
    private var failedTiers = sortedSetOf<Long>()
    private var failureCount = 0
    private var consentGranted = false
    /** 装载过媒体（对应 Apple 端 engine != nil）；换集时清掉 */
    private var mediaLoaded = false
    private var playsOriginalFile = false
    private var originMs = 0L
    /** 本机本单元解不了原文件：改走服务端流（只有「解不了」才设，网络问题从不设） */
    private var nativeFailed = false
    private val nativeRetries = NativeRetryBudget()
    /** 片源探活地址（原文件直连时） */
    private var sourceProbeUrl: String? = null
    /** 正在处理上一次失败（探片源、等片源回来）：这期间再报的失败都不处理，新请求发出时清掉 */
    private var failureInFlight = false
    /** 心跳发现会话没了、但用户正暂停着：等他点播放再重开 */
    private var deadSession = false

    // ---- 选择 ----

    private var subtitleTouched = false
    private var rememberedSubtitle: String? = null
    /** 要服务端烧录的字幕（图形字幕放服务端流时）；"off" = 撤下烧录 */
    private var requestedSubtitle: String? = null
    private var requestedAudio: String? = null
    /** 起播音轨要不要在 Exo 读到轨后显式选（服务端挑的不是容器默认轨，或用户选过） */
    private var pendingInitialAudio: Int? = null
    private var tracksKnown = false
    private val qualityMemory = QualityMemory(prefs)
    private var qualityFromMemory = false
    private var memoryNoticeChecked = false
    val network: PlaybackNetwork = PlaybackNetwork.current(server.origin.host)

    // ---- 计时、看门狗 ----

    private var overrideConsumed = false
    private var reportedStart = false
    private var lastDownlinkBps: Double? = null
    private var loadingBps: Double? = null
    private var resourceTick = 0
    private var lastSecondAt = 0L
    private val stallWatch = StallWatch()
    private var qualitySuggestion = QualitySuggestion()
    private val frameDrops = FrameDropTracker()
    private val networkRestarts = NetworkRestartBudget()
    private val prematureEnd = PrematureEndGuard()
    private val reconnectBackoff = ReconnectBackoff()
    /** 已发出、还没落地的 seek：这段等待不算卡顿，看门狗也不把它当停顿 */
    private var seekStartedAt: Long? = null
    private var backgrounded = false
    private var lastScrubFollowAt = 0L
    private var scrubFollowJob: Job? = null
    private var record: PlaybackRecord? = null
    private var closed = false
    private var started = false

    private var startJob: Job? = null
    private var pingJob: Job? = null
    private var progressJob: Job? = null
    private var tickJob: Job? = null
    private var trickplayJob: Job? = null
    private var noticeJob: Job? = null
    private var qualityOfferJob: Job? = null

    /** 上报串行队列：start / progress / stop 按发出顺序到达（stop 先到、进度后到，服务端会把刚结束的会话「复活」） */
    private val reports = Channel<suspend () -> Unit>(Channel.UNLIMITED)

    init {
        // 画质按「这部片 + 网络环境」取上次的选择
        val remembered = qualityMemory.quality(target.mediaItemId, network)
        set { copy(quality = remembered) }
        qualityFromMemory = remembered != null
        exo.addListener(ExoListener())
        exo.addAnalyticsListener(engineFacts)
        this.scope.launch {
            for (work in reports) runCatching { work() }
        }
        flushStoredReports()
    }

    // ======================================================================
    // 生命周期
    // ======================================================================

    fun start() {
        if (started) return
        started = true
        startUnit(unit)
        scope.launch { loadInfo() }
        startTickLoop()
    }

    /** 退出播放器：补一次 stop 上报与质量记录、释放服务端会话、销毁播放器 */
    fun close() {
        if (closed) return
        endRecord()
        leaveUnit()
        closed = true
        startJob?.cancel()
        tickJob?.cancel()
        trickplayJob?.cancel()
        noticeJob?.cancel()
        qualityOfferJob?.cancel()
        scrubFollowJob?.cancel()
        mediaSession?.release()
        exo.release()
        // 等队列里的上报发完再收掉协程
        reports.trySend { job.cancel() }
        reports.close()
    }

    private suspend fun loadInfo() {
        try {
            val info = api.playbackItemInfo(target.mediaItemId)
            set { copy(info = info) }
            updateMediaMetadata()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 条目信息拿不到几乎必然意味着会话也开不了（同一套可见性判据）：整页换成原因 +「返回」，停掉正在起的播放
            set { copy(infoError = e.message ?: "打不开这部片") }
            attempt += 1
            startJob?.cancel()
            exo.pause()
            record?.noteError(e.message ?: "", "item_info", recordStage)
            endRecord(forceOutcome = "failed")
            leaveUnit()
            return
        }
        loadEpisodes()
    }

    private suspend fun loadEpisodes() {
        if (!unit.isEpisode) {
            set { copy(episodes = emptyList()) }
            return
        }
        val episodes = runCatching { api.playbackItemEpisodes(unit.mediaItemId, unit.season).episodes }.getOrDefault(emptyList())
        set { copy(episodes = episodes) }
        updateMediaMetadata()
    }

    // ======================================================================
    // 单元切换
    // ======================================================================

    /** 开始播放一个单元（首次进入、上一集 / 下一集） */
    private fun startUnit(next: PlaybackUnit) {
        val seasonChanged = next.season != unit.season
        endRecord()
        if (mediaLoaded || session != null) leaveUnit()
        exo.stop()
        exo.clearMediaItems()
        mediaLoaded = false
        tracksKnown = false
        pendingInitialAudio = null
        session = null
        activeSessionId = null
        subtitleTouched = false
        rememberedSubtitle = null
        requestedAudio = null
        requestedSubtitle = null
        nativeFailed = false
        nativeRetries.reset()
        sourceProbeUrl = null
        failedTiers = sortedSetOf()
        failureCount = 0
        networkRestarts.reset()
        reconnectBackoff.reset()
        prematureEnd.reset()
        consentGranted = false
        deadSession = false
        qualityOfferJob?.cancel()
        qualitySuggestion = QualitySuggestion()
        _cues.value = emptyList()
        // startMs 只覆盖进入播放器的第一个单元；其余交给服务端按观看状态定起点
        val start = if (overrideConsumed) null else target.startMs
        overrideConsumed = true
        set {
            copy(
                unit = next, speedLabel = null, hasSession = false, segments = null, pendingDecision = null,
                subtitles = SubtitleTracks(), selectedSubtitle = null, audioOptions = emptyList(), currentAudio = null,
                trickplay = null, durationMs = null, bufferedEndMs = null, nextDismissed = false, autoNextProgress = 0.0,
                qualityOffer = null, wantsPlay = true, positionMs = start ?: 0, overlaySubtitleUrl = null,
                engineSubtitles = false, videoWidth = 0, videoHeight = 0,
            )
        }
        loadingBps = null
        beginRecord("tap")
        resetWatchdogs()
        request(startMs = start, next = Phase.Deciding)
        if (seasonChanged && started) scope.launch { loadEpisodes() }
        updateMediaMetadata()
    }

    /** 离开当前单元：停止上报（带轨记忆）+ 释放会话 */
    private fun leaveUnit() {
        pingJob?.cancel()
        progressJob?.cancel()
        if (reportedStart) {
            reportedStart = false
            val body = progressBody("stop", s.positionMs, paused = null)
            enqueueReport { api.playbackProgress(body) }
        }
        // 关会话也走上报队列：退出播放器时它要在协程收掉之前发完
        activeSessionId?.let { sid -> enqueueReport { api.playbackSessionStop(sid) } }
        activeSessionId = null
    }

    fun playNext() {
        val next = s.nextEpisode ?: return
        startUnit(PlaybackUnit(unit.mediaItemId, unit.season, next.episodeNumber))
    }

    fun playPrevious() {
        noteUserActivity()
        val previous = s.previousEpisode ?: return
        startUnit(PlaybackUnit(unit.mediaItemId, unit.season, previous.episodeNumber))
    }

    // ======================================================================
    // 自动播下一集 / 跳过
    // ======================================================================

    /** 倒计时走一步：卡片显示期间由界面每 0.1 秒调一次。暂停时不走；播完照走——片尾短于倒计时时不能卡在最后一帧 */
    fun advanceAutoNext(byMs: Long) {
        if (!s.autoNextArmed) {
            if (s.autoNextProgress != 0.0) set { copy(autoNextProgress = 0.0) }
            return
        }
        if (s.paused && s.phase != Phase.Ended) return
        val progress = minOf(1.0, s.autoNextProgress + byMs.toDouble() / SkipSegments.AUTO_NEXT_MS)
        if (progress < 1) {
            set { copy(autoNextProgress = progress) }
            return
        }
        set { copy(autoNextProgress = 0.0, autoNextStreak = autoNextStreak + 1) }
        playNext()
    }

    /** 有人在操作：不算「没人管的连播」，连播计数清零 */
    fun noteUserActivity() {
        if (s.autoNextStreak != 0) set { copy(autoNextStreak = 0) }
    }

    /** 返回键收起「下一集」卡片：这一集里不再出现 */
    fun dismissUpNext() = set { copy(nextDismissed = true, autoNextProgress = 0.0) }

    fun skipCurrentSegment() {
        noteUserActivity()
        val segment = s.skipSegment ?: return
        seekTo(segment.endMs, exact = true, source = "skip")
    }

    // ======================================================================
    // 起播（决策 / 降档 / 换会话）
    // ======================================================================

    /** 去后端要一个能播的地址。[next]：Deciding（新请求）/ SessionStarting（换会话）/ Degrading（降档） */
    private fun request(startMs: Long?, next: Phase) {
        record?.mark("session_request")
        record?.event("request", "开会话（${next.name}${startMs?.let { " @${it / 1000}s" } ?: ""}）")
        attempt += 1
        failureInFlight = false
        val myAttempt = attempt
        set { copy(phase = next, errorMessage = null, errorSuggestion = null, pendingDecision = null) }
        exo.pause()
        startJob?.cancel()
        val body = sessionBody(startMs)
        startJob = scope.launch { performRequest(body, startMs, myAttempt) }
    }

    private fun sessionBody(startMs: Long?): PlaybackSessionRequest {
        val first = unit == PlaybackUnit(target.mediaItemId, target.seasonNumber, target.episodeNumber)
        // 本机解不了原文件：标掉档 0，服务端改给 HLS（Apple 端是换成系统播放器的能力申报，效果相同）
        val tiers = if (nativeFailed) failedTiers + 0L else failedTiers
        return PlaybackSessionRequest(
            // 指定版本只对进入播放器的那个单元有效：切到别的集还带着它，会去请求上一集的文件
            fileId = if (first) target.fileId else null,
            mediaItemId = unit.mediaItemId,
            seasonNumber = unit.season,
            episodeNumber = unit.episode,
            capability = capability.probe(),
            failedTiers = tiers.toList().takeIf { it.isNotEmpty() },
            audioTrack = requestedAudio,
            // Exo 直连时自己画内封 / 外挂字幕，不需要服务端烧录：默认显式传 off，挡住记忆轨触发的烧录
            subtitleTrack = requestedSubtitle ?: "off",
            maxHeight = s.quality?.toLong(),
            downlinkBps = lastDownlinkBps?.toLong(),
            startMs = startMs,
            attemptId = record?.id,
            client = ClientIdentity.KIND,
            deviceId = deviceId,
        )
    }

    private suspend fun performRequest(body: PlaybackSessionRequest, startMs: Long?, myAttempt: Int) {
        val opened = try {
            api.playbackSessionStart(body)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (myAttempt != attempt) return
            val transient = isTransient(e)
            if (s.phase == Phase.SessionStarting && reportedStart && transient) {
                val wait = reconnectBackoff.nextDelayMs()
                if (wait != null) {
                    // 播放中重开时服务端暂时连不上（多半在重启）：隔几秒自动再试，不直接落到错误页
                    record?.beginReconnect("开会话失败：${e.message}")
                    log("reconnect-retry", "reason" to str(e.message), "delay_s" to JsonPrimitive(wait / 1000))
                    flash("连接中断，正在重连…")
                    delay(wait)
                    if (myAttempt != attempt || closed) return
                    request(s.positionMs, Phase.SessionStarting)
                    return
                }
            }
            fail(e.message ?: "打不开这部片", null, if (transient) "network" else "server")
            return
        }
        if (myAttempt != attempt || closed) {
            // 请求已被超越：响应里可能带着刚拉起的转码会话，此后没人认领，当场掐掉
            opened.sessionId?.let { sid -> scope.launch { runCatching { api.playbackSessionStop(sid) } } }
            return
        }
        handleSession(opened, startMs)
    }

    private fun isTransient(e: Exception): Boolean = when (e) {
        is UnreachableException -> true
        is ApiException -> e.status in setOf(502, 503, 504)
        else -> e is java.io.IOException
    }

    private fun handleSession(opened: PlaybackSessionView, requestedStartMs: Long?) {
        val decision = opened.decision
        when (decision.outcome) {
            "consent" -> {
                val wanted = requestedSubtitle
                if (wanted != null && wanted != "off") {
                    // 烧录撞上软件转码同意：自动退回不烧录，不打断观看；图形字幕画不了，菜单里不能还挂着选中态
                    val dropped = s.subtitles.options.firstOrNull { it.ref == wanted }
                    requestedSubtitle = "off"
                    if (dropped?.kind == "pgs") {
                        subtitleTouched = true
                        set { copy(selectedSubtitle = null) }
                        flash("图形字幕需要服务端转码压制，当前未开启软件转码，已关闭字幕")
                    }
                    request(s.positionMs, Phase.SessionStarting)
                    return
                }
                if (consentGranted) {
                    fail(
                        "软件转码开关已保存，但服务端仍在请求开启确认",
                        "开关可能没有生效（例如服务端刚重启）。请退出重试；若反复出现，请查看服务端日志排查。",
                    )
                    return
                }
                record?.beginUserWait()
                set { copy(pendingDecision = decision, phase = Phase.Consent) }
                return
            }
            "rejected" -> {
                fail(decision.reason, decision.suggestion, "rejected")
                return
            }
            else -> consentGranted = false
        }
        val fileId = decision.fileId ?: return fail("服务端没有给出可播放的文件", null)

        // 旧会话（换轨 / 换画质 / 降档之前那条）：新会话已就位，释放它
        activeSessionId?.takeIf { it != opened.sessionId }?.let { old -> scope.launch { runCatching { api.playbackSessionStop(old) } } }

        val token = tokenIn(opened.streamUrl)
        val original = decision.tier == 0L && token != null
        val url = if (original) {
            // 直连原文件：服务端为换封装起的会话用不上，立刻释放（不心跳）
            opened.sessionId?.let { sid -> scope.launch { runCatching { api.playbackSessionStop(sid) } } }
            activeSessionId = null
            server.resolve("/api/v1/playback/files/$fileId/stream?token=$token")
        } else {
            // 服务端流吃不带字幕组的 stream_url：文字字幕由叠加层画（时间轴按文件时间，会话相对列表也对得上）
            activeSessionId = opened.sessionId
            opened.streamUrl?.let(server::resolve)
        } ?: return fail("服务端没有给出播放地址", null)

        playsOriginalFile = original
        originMs = if (original || opened.timeline == "file") 0 else opened.startMs
        record?.let { r ->
            r.mark("session_ready")
            if (r.firstFrameAt == null) {
                r.startPositionMs = opened.startMs
                r.resumed = requestedStartMs == null && opened.startMs > 0
            }
            r.tier = decision.tier ?: -1
            r.degradedFrom = decision.degradedFrom
            r.libraryFileId = fileId
            r.hwBackend = opened.hwBackend ?: ""
            r.route = PlaybackRoute.of(original, decision.tier, degraded = decision.degradedFrom != null || failedTiers.isNotEmpty() || nativeFailed, userCapped = qualityLimited)
        }
        session = opened
        sourceProbeUrl = if (original) url.toString() else null

        // 轨道
        val subtitles = SubtitleTracks.plan(decision.subtitles, opened.subtitleUrls)
        val audioOptions = AudioOption.plan(decision.audioTracks)
        val currentAudio = requestedAudio ?: decision.audio?.trackRef
        var selected = s.selectedSubtitle
        val burned = decision.video?.burnSubtitle
        if (burned != null) {
            selected = burned
        } else if (!subtitleTouched) {
            rememberedSubtitle = opened.watch?.subtitleTrack
            selected = subtitles.initialSelection(rememberedSubtitle)
        }
        val position = if (requestedStartMs == null || s.positionMs == 0L) opened.startMs else s.positionMs
        set {
            copy(
                hasSession = true, segments = opened.segments, subtitles = subtitles, audioOptions = audioOptions,
                currentAudio = currentAudio, selectedSubtitle = selected, positionMs = position,
                durationMs = opened.watch?.durationMs ?: durationMs, phase = Phase.Buffering,
            )
        }
        Log.i(TAG, "起播 item=${unit.mediaItemId} 档=${decision.tier} ${if (original) "原文件直连" else "服务端流"} start=${opened.startMs}")

        // 起播音轨：用户这次选过、或服务端挑的不是容器默认轨 → Exo 读到轨后显式选它；挑的就是默认轨时交给 Exo 自己选
        pendingInitialAudio = null
        val chosen = decision.audio?.trackRef
        if (original && chosen != null) {
            val index = embeddedIndexOf(chosen)
            val containerDefault = audioOptions.firstOrNull { it.isDefault }?.ref ?: audioOptions.firstOrNull()?.ref
            if (index != null && (requestedAudio != null || chosen != containerDefault)) pendingInitialAudio = index
        }

        // 装载
        qualitySuggestion.restartGrace()
        resetWatchdogs()
        tracksKnown = false
        _cues.value = emptyList()
        val item = MediaItem.Builder()
            .setUri(Uri.parse(url.toString()))
            .setMediaMetadata(metadata)
            .apply {
                if (!original) {
                    setMimeType(MimeTypes.APPLICATION_M3U8)
                    // 会话相对列表是边转边长的 EVENT 列表，Exo 会当直播追「直播点」把播放速度调到 1.03 倍：钉死原速
                    setLiveConfiguration(MediaItem.LiveConfiguration.Builder().setMinPlaybackSpeed(1f).setMaxPlaybackSpeed(1f).build())
                }
            }
            .setSubtitleConfigurations(if (original) externalSubtitles(subtitles) else emptyList())
            .build()
        exo.trackSelectionParameters = exo.trackSelectionParameters.buildUpon()
            .clearOverrides()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            .build()
        engineFacts.reset()
        EngineLog.add("player", "装载 ${if (original) "原文件" else "服务端流"} 档 ${decision.tier} 起点 ${position / 1000}s")
        exo.setMediaItem(item, (position - originMs).coerceAtLeast(0))
        exo.playWhenReady = s.wantsPlay
        exo.prepare()
        mediaLoaded = true
        loadingBps = null
        lastSecondAt = SystemClock.elapsedRealtime()
        bytesLoaded.set(0)
        applySubtitle()
        deadSession = false
        startPingLoop()
        loadTrickplay(fileId, token)
    }

    /** 外挂字幕旁挂给 Exo（直连时）：文本轨要服务端转成 VTT（SRT 等编码五花八门），ASS 取原文件保留定位；图形外挂轨 Exo 读不了 */
    private fun externalSubtitles(tracks: SubtitleTracks): List<MediaItem.SubtitleConfiguration> =
        tracks.options.filter { it.ref.startsWith(EXTERNAL) && it.kind != "pgs" && it.path.isNotEmpty() }.mapNotNull { option ->
            val (mime, suffix) = if (option.kind == "ass") MimeTypes.TEXT_SSA to "" else MimeTypes.TEXT_VTT to "&format=vtt"
            val url = server.resolve(option.path + suffix) ?: return@mapNotNull null
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(url.toString()))
                .setId(option.ref)
                .setMimeType(mime)
                .setLanguage(option.language)
                .setLabel(option.displayTitle)
                .build()
        }

    private fun fail(message: String, suggestion: String?, category: String = "unknown") {
        Log.w(TAG, "播放出错：$message｜${suggestion ?: "-"}")
        EngineLog.add("player", "错误页：$message")
        record?.noteError(message, category, recordStage)
        exo.pause()
        session = null
        set { copy(phase = Phase.Error, errorMessage = message, errorSuggestion = suggestion, hasSession = false) }
    }

    private fun failSourceMissing() = fail(
        "服务器上找不到这个文件", "文件可能被移动、删除，或存放它的磁盘没有挂上。检查后点「重试」。", "source_missing",
    )

    /** 本机放不了原文件：本单元改走服务端 HLS */
    private fun nativeFallback(reason: String) {
        nativeFailed = true
        record?.noteFallback("改走服务端流：$reason")
        log("engine-fallback", "from" to str("exo"), "reason" to str(reason), "media_item_id" to JsonPrimitive(unit.mediaItemId))
        flash("本机解不了这个文件，改由服务端转换后播放")
        request(s.positionMs, Phase.SessionStarting)
    }

    // ---- 重试 / 同意 ----

    /** 错误页上点重试：上一次播放以失败收尾，这是新的一次 */
    fun retry() {
        endRecord()
        beginRecord("retry")
        failedTiers = sortedSetOf()
        failureCount = 0
        networkRestarts.reset()
        reconnectBackoff.reset()
        nativeRetries.reset()
        request(s.positionMs, Phase.Deciding)
    }

    /** 同意弹窗「开启并播放」：写入全局开关后重新决策。失败抛出，弹窗显示原因 */
    suspend fun grantConsent() {
        val saved = api.playbackPolicySet(PlaybackPolicyPayload(softwareTranscodeEnabled = true))
        // 保存接口回显的是落库后的取值：不是 true 说明开关根本没生效，不能假装成功
        if (!saved.softwareTranscodeEnabled) throw IllegalStateException("软件转码开关保存后未生效，请重试或查看服务端日志")
        consentGranted = true
        record?.endUserWait()
        request(s.positionMs, Phase.Deciding)
    }

    // ======================================================================
    // 引擎事件
    // ======================================================================

    private inner class ExoListener : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) onPlaying()
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (!playWhenReady) onPaused()
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_BUFFERING -> onBuffering()
                Player.STATE_READY -> {
                    seekStartedAt = null
                    // 以暂停状态起播 / 暂停中拖动：就绪后回到正常态，否则转圈不消
                    if (!exo.playWhenReady && s.phase == Phase.Buffering) set { copy(phase = Phase.Playing, paused = true) }
                    record?.let { r ->
                        r.mark("media_prepared")
                        // 原地跳转、原地换轨：就绪即落地（换会话式的等新流首帧）
                        if (r.firstFrameAt != null) {
                            r.seekPresented()
                            r.switchPresented()
                        }
                    }
                }
                Player.STATE_ENDED -> onEnded()
                else -> Unit
            }
        }

        override fun onRenderedFirstFrame() {
            val r = record ?: return
            if (r.firstFrameAt == null) {
                r.noteFirstFrame()
                noteDelivery()
            } else {
                // 换会话后新流的首帧：换会话式的跳转、换轨在这一刻落地
                r.seekPresented()
                r.switchPresented()
                noteDelivery()
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            failedDecoder = failingDecoder(error)
            val status = (error.cause as? HttpDataSource.InvalidResponseCodeException)?.responseCode
            val cause = FailurePolicy.classify(error.errorCode, status, playsOriginalFile)
            val reason = "播放失败：${error.errorCodeName}" + (status?.let { "（HTTP $it）" } ?: "")
            Log.w(TAG, reason, error)
            engineReportedFailure(reason, cause)
        }

        override fun onTracksChanged(tracks: Tracks) = handleTracks(tracks)

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            set { copy(videoWidth = (videoSize.width * videoSize.pixelWidthHeightRatio).toInt(), videoHeight = videoSize.height) }
        }

        override fun onCues(cueGroup: CueGroup) {
            _cues.value = cueGroup.cues
        }
    }

    private fun onPlaying() {
        val wasPaused = s.paused
        seekStartedAt = null
        set { copy(paused = false) }
        val phase = s.phase
        if (phase != Phase.Buffering && phase != Phase.Playing && phase != Phase.Ended) return
        record?.notePlaying()
        record?.endReconnect()
        set { copy(phase = Phase.Playing) }
        failureCount = 0
        networkRestarts.reachedPlaying()
        reconnectBackoff.reset()
        if (!memoryNoticeChecked) {
            // 出画这一刻提示（转圈时提示会被忽略）；只在打开播放器后第一次出画时判一次，自动连播下一集不再提示
            memoryNoticeChecked = true
            rememberedChoiceNotice()?.let(::flash)
            reportStartup()
        }
        if (!reportedStart) {
            reportStart()
        } else if (wasPaused) {
            // 只在从暂停恢复时补报一次；缓冲结束、状态抖动回到播放不报（10 秒一次的进度循环照常）
            sendProgress(paused = false)
        }
    }

    private fun onPaused() {
        seekStartedAt = null
        set { copy(paused = true) }
        if (s.phase == Phase.Buffering && exo.playbackState == Player.STATE_READY) set { copy(phase = Phase.Playing) }
        // 换会话 / 降档时控制器自己按的暂停不上报：那不是用户暂停
        if (reportedStart && !s.phase.isBusy) sendProgress(paused = true)
    }

    private fun onBuffering() {
        if (s.phase == Phase.Playing) {
            // 卡顿不看引擎报不报缓冲，按播放头判（tickPosition → PlaybackRecord.samplePlayhead）
            set { copy(phase = Phase.Buffering) }
        }
    }

    private fun onEnded() {
        val phase = s.phase
        if (phase != Phase.Buffering && phase != Phase.Playing) return
        if (prematureEnd.shouldResume(s.positionMs, s.durationMs)) {
            // 离片尾还远就报播完：取流断了，从当前位置重开，不进「已播完」——否则弹出下一集并把进度报成停在半路
            log("premature-end", "engine" to str("exo"), "position_ms" to JsonPrimitive(s.positionMs),
                "duration_ms" to (s.durationMs?.let(::JsonPrimitive) ?: JsonNull))
            request(s.positionMs, Phase.SessionStarting)
            return
        }
        // 离片尾 5 秒内才吸附到片长，否则按真实位置上报——片长会让服务端直接标「已看」
        val duration = s.durationMs
        set { copy(phase = Phase.Ended, paused = true, positionMs = if (duration != null && duration - positionMs <= 5000) duration else positionMs) }
        if (reportedStart) sendProgress(paused = true)
    }

    /** 异常链里出错的解码器：初始化失败（DecoderInitializationException）或解码中出错（MediaCodecDecoderException） */
    private fun failingDecoder(error: Throwable): Pair<String, String>? {
        var current: Throwable? = error
        while (current != null) {
            when (current) {
                is MediaCodecRenderer.DecoderInitializationException -> current.codecInfo?.let { return it.name to it.mimeType }
                is MediaCodecDecoderException -> current.codecInfo?.let { return it.name to it.mimeType }
            }
            current = current.cause
        }
        return null
    }

    /** Exo 报的失败。直连原文件时报「解不了」，先探片源取不取得到：起播那一刻断线、超时 Exo 也只知道「打不开」 */
    private fun engineReportedFailure(reason: String, cause: FailureCause) {
        val phase = s.phase
        if (failureInFlight || (phase != Phase.Buffering && phase != Phase.Playing && phase != Phase.Ended) || session == null) return
        val probe = sourceProbeUrl
        if (!playsOriginalFile || (cause != FailureCause.Decode && cause != FailureCause.DecodeFinal) || probe == null) {
            engineFailed(reason, cause)
            return
        }
        failureInFlight = true
        val failedAttempt = attempt
        scope.launch {
            val verdict = probeSource(probe)
            if (failedAttempt != attempt || closed) return@launch
            failureInFlight = false
            when (verdict) {
                SourceProbe.Verdict.Reachable -> engineFailed(reason, cause)
                SourceProbe.Verdict.Missing -> engineFailed(reason, FailureCause.SourceMissing)
                is SourceProbe.Verdict.Unreachable -> engineFailed("取不到片源（${verdict.why}）：$reason", FailureCause.Network)
            }
        }
    }

    /** 播放链路失败：按 [FailurePolicy] 走——网络问题等片源回来原地重开，一时的问题原位重开，确定解不了才换流 / 降档 */
    private fun engineFailed(reason: String, cause: FailureCause) {
        val phase = s.phase
        val session = session
        if (failureInFlight || (phase != Phase.Buffering && phase != Phase.Playing && phase != Phase.Ended) || session == null) return
        log("playback-error", "engine" to str("exo"), "reason" to str(reason), "tier" to (session.decision.tier?.let(::JsonPrimitive) ?: JsonNull))
        val response = FailurePolicy.decide(
            FailurePolicy.Input(
                cause = cause,
                playsOriginalFile = playsOriginalFile,
                restartAllowed = cause == FailureCause.Network && networkRestarts.allowRestart(),
                // 额度只在真要用时才扣
                nativeRetryAllowed = playsOriginalFile && cause == FailureCause.Decode && nativeRetries.allowRetry(SystemClock.elapsedRealtime()),
            ),
        )
        Log.w(TAG, "失败处置 cause=$cause original=$playsOriginalFile → $response｜$reason")
        // 确定这一路本机解不了（原位重试也救不回来、要改走服务端）：出错的解码器以后不再选
        val decodeGaveUp = response == FailurePolicy.Response.FallbackToServerStream ||
            (response == FailurePolicy.Response.StepDownTier && playsOriginalFile)
        if (decodeGaveUp && (cause == FailureCause.Decode || cause == FailureCause.DecodeFinal)) {
            failedDecoder?.let { (name, mime) -> denylist.deny(name, mime, reason) }
        }
        EngineLog.add("player", "失败处置 $cause → $response：$reason")
        if (response != FailurePolicy.Response.FailSourceMissing && response != FailurePolicy.Response.FailNetwork) {
            record?.noteEngineFailure(reason, cause.name)
        }
        when (response) {
            FailurePolicy.Response.Reconnect -> {
                record?.beginReconnect(reason)
                log("network-restart", "reason" to str(reason), "attempt" to JsonPrimitive(networkRestarts.consecutive))
                val probe = sourceProbeUrl
                if (playsOriginalFile && probe != null) awaitSourceThenReconnect(probe) else request(s.positionMs, Phase.SessionStarting)
            }
            FailurePolicy.Response.RetryNative -> {
                log("native-retry", "reason" to str(reason))
                flash("播放出了点问题，正在原位重开")
                request(s.positionMs, Phase.SessionStarting)
            }
            FailurePolicy.Response.FailSourceMissing -> {
                log("source-missing", "reason" to str(reason))
                failSourceMissing()
            }
            FailurePolicy.Response.FailNetwork -> {
                log("network-restart-exhausted", "reason" to str(reason))
                fail("连接中断，重连了几次都没成功（$reason）", "检查网络后点「重试」，会从刚才的位置接着放。", "network")
            }
            FailurePolicy.Response.FallbackToServerStream -> nativeFallback(reason)
            FailurePolicy.Response.StepDownTier -> {
                if (cause == FailureCause.Network) log("network-restart-exhausted", "reason" to str(reason))
                stepDownTier(reason, session)
            }
        }
    }

    /** 原文件直连断了：等片源取得到再原位重开。一直取不到按 2、4、8、15、15、15 秒再探，还不行落错误页 */
    private fun awaitSourceThenReconnect(probe: String) {
        failureInFlight = true
        val myAttempt = attempt
        record?.beginReconnect("直连片源断了")
        set { copy(phase = Phase.SessionStarting) }
        flash("连接中断，正在重连…")
        scope.launch {
            val backoff = ReconnectBackoff()
            while (true) {
                val verdict = probeSource(probe)
                if (myAttempt != attempt || closed) return@launch
                when (verdict) {
                    SourceProbe.Verdict.Reachable -> {
                        request(s.positionMs, Phase.SessionStarting)
                        return@launch
                    }
                    SourceProbe.Verdict.Missing -> {
                        failureInFlight = false
                        failSourceMissing()
                        return@launch
                    }
                    is SourceProbe.Verdict.Unreachable -> {
                        val wait = backoff.nextDelayMs()
                        if (wait == null) {
                            failureInFlight = false
                            log("network-restart-exhausted", "reason" to str(verdict.why))
                            fail("连接中断，重连了几次都没成功（${verdict.why}）", "检查网络后点「重试」，会从刚才的位置接着放。", "network")
                            return@launch
                        }
                        delay(wait)
                        if (myAttempt != attempt || closed) return@launch
                    }
                }
            }
        }
    }

    /** 服务端这一档放不了：逐级降档；连败两次说明「逐级试」的假设不成立，兜底档以下全标失败一步到位 */
    private fun stepDownTier(reason: String, session: PlaybackSessionView) {
        val tier = session.decision.tier ?: return fail(reason, null)
        failedTiers.add(tier)
        if (failureCount + 1 >= 2) (0L until 4L).forEach { failedTiers.add(it) }
        failureCount += 1
        record?.noteFallback("档 $tier 放不了：$reason")
        if (tier >= 4) {
            fail(reason, "可以换一个版本重试；若反复出现，把出错的时间告诉管理员——服务器上留有这次播放的诊断记录。", "decode")
            return
        }
        request(s.positionMs, Phase.Degrading)
    }

    /** 取一个字节（Range: bytes=0-0），5 秒超时 */
    private suspend fun probeSource(url: String): SourceProbe.Verdict = withContext(Dispatchers.IO) {
        try {
            val client = http.newBuilder().callTimeout(5, TimeUnit.SECONDS).build()
            client.newCall(Request.Builder().url(url).header("Range", "bytes=0-0").build()).execute().use { SourceProbe.verdict(it.code) }
        } catch (e: Exception) {
            SourceProbe.Verdict.Unreachable(e.message ?: e.javaClass.simpleName)
        }
    }

    // ======================================================================
    // 轨道（Exo 读到之后）
    // ======================================================================

    private fun handleTracks(tracks: Tracks) {
        if (!mediaLoaded || tracks.isEmpty) return
        tracksKnown = true
        // Exo 遇到解不了的轨不报错、只是不选它（会变成有声无画 / 有画无声）：整路视频 / 音频都没有能用的解码器就按「解不了」处理
        val video = tracks.groups.filter { it.type == C.TRACK_TYPE_VIDEO }
        val audio = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
        if (video.isNotEmpty() && video.none { it.isSupported(true) }) {
            engineReportedFailure("本机没有能解这路视频的解码器", FailureCause.DecodeFinal)
            return
        }
        if (audio.isNotEmpty() && audio.none { it.isSupported(true) }) {
            engineReportedFailure("本机没有能解这路音频的解码器", FailureCause.DecodeFinal)
            return
        }
        if (!playsOriginalFile) return
        // 起播音轨：服务端挑的轨交给 Exo（只做一次）
        pendingInitialAudio?.let { index ->
            pendingInitialAudio = null
            audioGroups(tracks).getOrNull(index)?.takeIf { !it.isSelected && it.isSupported(true) }?.let { group ->
                exo.trackSelectionParameters = exo.trackSelectionParameters.buildUpon()
                    .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, 0)).build()
            }
        }
        adoptEngineTracks(tracks)
        applySubtitle()
    }

    private fun audioGroups(tracks: Tracks = exo.currentTracks) = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }

    /** 内封字幕轨（不含旁挂的外挂轨），按容器顺序：第 N 条对应 embedded:N */
    private fun embeddedTextGroups(tracks: Tracks = exo.currentTracks) = tracks.groups.filter { group ->
        group.type == C.TRACK_TYPE_TEXT && group.getTrackFormat(0).id?.contains(EXTERNAL) != true
    }

    private fun textGroupFor(option: SubtitleOption, tracks: Tracks = exo.currentTracks): Tracks.Group? {
        val index = option.embeddedIndex
        return if (index != null) {
            embeddedTextGroups(tracks).getOrNull(index)
        } else {
            tracks.groups.firstOrNull { it.type == C.TRACK_TYPE_TEXT && it.getTrackFormat(0).id?.contains(option.ref) == true }
        }
    }

    /** Exo 读到、服务端清单里没有的轨补进菜单（隐藏字幕、服务端不提供的图形字幕；服务端一条音轨都没给时的音轨） */
    private fun adoptEngineTracks(tracks: Tracks) {
        val text = embeddedTextGroups(tracks).map { group ->
            val format = group.getTrackFormat(0)
            EngineTrack(
                title = format.label, language = format.language,
                codec = format.sampleMimeType ?: format.codecs ?: "",
                isDefault = format.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0,
                isForced = format.selectionFlags and C.SELECTION_FLAG_FORCED != 0,
            )
        }
        s.subtitles.adoptEngineSubtitles(text)?.let { adopted ->
            var selected = s.selectedSubtitle
            if (!subtitleTouched && selected == null && session?.decision?.video?.burnSubtitle == null) {
                selected = adopted.initialSelection(rememberedSubtitle)
            }
            set { copy(subtitles = adopted, selectedSubtitle = selected) }
        }
        if (s.audioOptions.isEmpty()) {
            val engineAudio = audioGroups(tracks).map { group ->
                val format = group.getTrackFormat(0)
                EngineTrack(
                    title = format.label, language = format.language,
                    codec = audioCodecName(format.sampleMimeType),
                    isDefault = format.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0,
                    channels = format.channelCount.takeIf { it > 0 },
                )
            }
            val options = AudioOption.engineOptions(engineAudio)
            if (options.isNotEmpty()) set { copy(audioOptions = options) }
        }
        if (s.currentAudio == null) {
            val active = audioGroups(tracks).indexOfFirst { it.isSelected }
            if (active >= 0) set { copy(currentAudio = "embedded:$active") }
        }
    }

    // ======================================================================
    // 播放控制
    // ======================================================================

    fun togglePlay() {
        noteUserActivity()
        if (!mediaLoaded) return
        if (s.phase == Phase.Ended) {
            set { copy(wantsPlay = true) }
            seekTo(0, exact = true)
            exo.play()
            return
        }
        if (!exo.playWhenReady) {
            set { copy(wantsPlay = true) }
            // 用户暂停攒过缓冲再接着看：卡顿提示从恢复这一刻重新计
            qualitySuggestion.restartGrace()
            if (deadSession) {
                // 会话在暂停期间被回收了：从当前位置重开
                request(s.positionMs, Phase.SessionStarting)
                return
            }
            exo.play()
        } else {
            set { copy(wantsPlay = false) }
            exo.pause()
        }
    }

    fun play() {
        if (!exo.playWhenReady || s.phase == Phase.Ended) togglePlay()
    }

    fun pause() {
        if (exo.playWhenReady && s.phase != Phase.Ended) togglePlay()
    }

    /** 相对跳转（左右键、媒体键）：按关键帧，快 */
    fun seekBy(deltaMs: Long) = seekTo(s.positionMs + deltaMs, exact = false, source = "dpad")

    /** 跳到文件时间（毫秒）。[source] 记进播放记录：scrub（拖动）/ dpad / skip / media_key */
    fun seekTo(raw: Long, exact: Boolean = true, source: String = "scrub") {
        // 先夹进片长之内：越过片尾的落点会开出一个什么也转不出来的会话
        var targetMs = raw.coerceAtLeast(0)
        val duration = s.durationMs
        if (duration != null && duration > 1000) targetMs = minOf(targetMs, duration - 1000)
        scrubFollowJob?.cancel()
        val phase = s.phase
        if (!mediaLoaded || session == null || phase == Phase.SessionStarting || phase == Phase.Deciding || phase == Phase.Degrading) {
            // 会话正在重开的空档：改走换会话，新会话直接从目标位置起
            if (phase.isBusy && session == null && (phase != Phase.Deciding || s.positionMs > 0)) {
                record?.beginSeek(source, s.positionMs, targetMs, buffered = false, paused = !s.wantsPlay, restart = true)
                set { copy(positionMs = targetMs) }
                request(targetMs, Phase.SessionStarting)
            }
            return
        }
        val buffered = targetMs >= s.positionMs - 1000 && targetMs <= (s.bufferedEndMs ?: 0)
        val restart = session?.timeline == "session" && activeSessionId != null && !withinSessionBuffer(targetMs)
        record?.beginSeek(source, s.positionMs, targetMs, buffered = buffered, paused = !s.wantsPlay, restart = restart)
        if (restart) {
            // 会话相对列表只覆盖已转出的部分：落点在区间外才换会话，区间内原地跳
            set { copy(positionMs = targetMs) }
            request(targetMs, Phase.SessionStarting)
            return
        }
        set { copy(positionMs = targetMs, phase = if (phase == Phase.Ended) Phase.Buffering else phase) }
        seekStartedAt = SystemClock.elapsedRealtime()
        qualitySuggestion.restartGrace()
        stallWatch.reset()
        frameDrops.reset()
        exo.setSeekParameters(if (exact) SeekParameters.EXACT else SeekParameters.CLOSEST_SYNC)
        exo.seekTo((targetMs - originMs).coerceAtLeast(0))
    }

    private fun withinSessionBuffer(fileMs: Long): Boolean {
        val buffered = s.bufferedEndMs ?: return false
        return fileMs in originMs..buffered
    }

    /** 拖动途中让画面跟着走：落点在缓冲里时 10Hz 跟随，原文件直连拖出缓冲时停住 60ms 后跟一次，其余松手才跳 */
    fun scrubFollow(fileMs: Long) {
        val phase = s.phase
        if (!mediaLoaded || session == null || (phase != Phase.Playing && phase != Phase.Buffering && phase != Phase.Ended)) return
        val cheap = fileMs >= s.positionMs - 1000 && fileMs <= (s.bufferedEndMs ?: 0)
        val now = SystemClock.elapsedRealtime()
        val plan = ScrubFollow.plan(now, lastScrubFollowAt, cheap, reachable = fileMs >= originMs, settleOnly = playsOriginalFile)
        scrubFollowJob?.cancel()
        when (plan) {
            ScrubFollow.Plan.Skip -> Unit
            ScrubFollow.Plan.Follow -> {
                lastScrubFollowAt = now
                followTo(fileMs)
            }
            is ScrubFollow.Plan.Deferred -> scrubFollowJob = scope.launch {
                delay(plan.ms)
                lastScrubFollowAt = SystemClock.elapsedRealtime()
                followTo(fileMs)
            }
        }
    }

    private fun followTo(fileMs: Long) {
        exo.setSeekParameters(SeekParameters.CLOSEST_SYNC)
        exo.seekTo((fileMs - originMs).coerceAtLeast(0))
    }

    /** 拖动结束 / 取消：别让排队中的跟随在松手之后再跳一次 */
    fun cancelScrubFollow() {
        scrubFollowJob?.cancel()
    }

    // ======================================================================
    // 音轨 / 字幕 / 画质
    // ======================================================================

    /** 换音轨：直连原文件时 Exo 原地切换；否则带着当前位置重开会话（服务端流的音轨在开会话时就定死了） */
    fun selectAudio(ref: String) {
        noteUserActivity()
        // 选的就是正在放的那条：什么都不用做，也不算一次切换
        if (ref != s.currentAudio) {
            record?.noteTrackChange("audio", s.currentAudio, ref)
            record?.beginSwitch("audio", s.currentAudio, ref)
        }
        requestedAudio = ref
        val index = embeddedIndexOf(ref)
        val group = if (playsOriginalFile && index != null) audioGroups().getOrNull(index) else null
        if (group != null && group.isSupported(true)) {
            exo.trackSelectionParameters = exo.trackSelectionParameters.buildUpon()
                .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, 0)).build()
            set { copy(currentAudio = ref) }
            sendProgress(paused = s.paused)
            return
        }
        if (ref == session?.decision?.audio?.trackRef) return
        set { copy(wantsPlay = true, currentAudio = ref) }
        request(s.positionMs, Phase.SessionStarting)
    }

    private val burnedSubtitle: String? get() = session?.decision?.video?.burnSubtitle

    /** Exo 自己画得了这条轨：直连原文件时的内封轨（Exo 读得到的）与文本外挂轨 */
    private fun exoRenders(option: SubtitleOption?): Boolean {
        if (option == null || !playsOriginalFile || burnedSubtitle != null) return false
        if (option.ref.startsWith(EXTERNAL)) return option.kind != "pgs"
        if (option.embeddedIndex == null) return false
        // 轨还没读到时先按能画算（读到后 applySubtitle 再核对一次）
        return !tracksKnown || textGroupFor(option) != null
    }

    fun selectSubtitle(ref: String?) {
        noteUserActivity()
        val previous = s.selectedSubtitle
        val changing = ref != previous
        if (changing) record?.noteTrackChange("subtitle", previous, ref)
        subtitleTouched = true
        set { copy(selectedSubtitle = ref) }
        val option = ref?.let { r -> s.subtitles.options.firstOrNull { it.ref == r } }
        val wantBurn = option?.kind == "pgs" && !exoRenders(option)
        if (!wantBurn) {
            if (changing) record?.beginSwitch("subtitle", previous, ref, immediate = burnedSubtitle == null)
            applySubtitle()
            if (burnedSubtitle != null) {
                // 在放烧录过的服务端流：撤下烧录（直连能放的话服务端会直接给回原文件）
                requestedSubtitle = "off"
                set { copy(wantsPlay = true) }
                request(s.positionMs, Phase.SessionStarting)
            }
            if (reportedStart) sendProgress(paused = s.paused)
            return
        }
        if (burnedSubtitle == ref) return
        // 图形字幕（PGS）放服务端流时画不了：服务端转码压制进画面（约一秒切换）
        record?.beginSwitch("subtitle", previous, ref)
        requestedSubtitle = ref
        set { copy(wantsPlay = true) }
        request(s.positionMs, Phase.SessionStarting)
    }

    /** 当前字幕交给谁画：Exo（直连）/ 叠加层（服务端流的文本轨，或 Exo 读不到的内封文本轨）/ 不画（烧录、图形） */
    private fun applySubtitle() {
        val option = s.selectedSubtitle?.let { ref -> s.subtitles.options.firstOrNull { it.ref == ref } }
        val group = if (exoRenders(option) && tracksKnown) option?.let { textGroupFor(it) } else null
        val builder = exo.trackSelectionParameters.buildUpon().clearOverridesOfType(C.TRACK_TYPE_TEXT)
        if (group != null) {
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, 0))
        } else {
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            _cues.value = emptyList()
        }
        exo.trackSelectionParameters = builder.build()
        val engine = exoRenders(option)
        val overlay = if (option != null && !engine && burnedSubtitle == null && option.kind != "pgs" && option.path.isNotEmpty()) {
            server.resolve(option.path + "&format=vtt")?.toString()
        } else {
            null
        }
        set { copy(engineSubtitles = engine, overlaySubtitleUrl = overlay) }
    }

    /** 上报用的字幕记忆：只报用户这次动过的（"off" = 用户明确关掉）；不报时服务端保持原记忆 */
    private val subtitleMemory: String? get() = if (subtitleTouched) s.selectedSubtitle ?: "off" else null

    fun selectQuality(maxHeight: Int?) {
        noteUserActivity()
        qualityFromMemory = false
        // 上限不低于片源等于没限：记成「原画」，下次打开照样直连原文件
        val sourceHeight = sourceHeight() ?: Int.MAX_VALUE
        qualityMemory.remember(maxHeight?.takeIf { it < sourceHeight }, unit.mediaItemId, network)
        switchQuality(maxHeight)
    }

    /** 语义是上限：视频直通且源不超所选档就不用重开 */
    private fun switchQuality(maxHeight: Int?) {
        if (maxHeight == s.quality) return
        record?.noteBehavior("quality_change", s.quality?.toString() ?: "original", maxHeight?.toString() ?: "original")
        record?.beginSwitch("quality", s.quality?.toString() ?: "original", maxHeight?.toString() ?: "original")
        set { copy(quality = maxHeight) }
        val copying = playsOriginalFile || session?.decision?.video?.action == "copy"
        val height = exo.videoSize.height
        if (copying && (maxHeight == null || (height in 1..maxHeight))) return
        set { copy(wantsPlay = true) }
        failedTiers = sortedSetOf()
        failureCount = 0
        request(s.positionMs, Phase.Deciding)
    }

    private fun sourceHeight(): Int? = session?.source?.resolution?.filter(Char::isDigit)?.toIntOrNull()

    /** 画质上限真的在限：片源比上限高（还不知道片源多高时按在限算） */
    private val qualityLimited: Boolean get() = s.quality?.let { (sourceHeight() ?: Int.MAX_VALUE) > it } ?: false

    fun acceptQualityOffer() {
        val offer = s.qualityOffer ?: return
        log("quality-suggestion-accepted", "suggested_height" to JsonPrimitive(offer.maxHeight))
        dismissQualityOffer()
        selectQuality(offer.maxHeight)
    }

    fun dismissQualityOffer() {
        qualityOfferJob?.cancel()
        set { copy(qualityOffer = null) }
    }

    // ======================================================================
    // 前后台
    // ======================================================================

    /** 切到后台：先把位置报上去（之后可能被系统回收）、暂停；回到前台探一次活（后台期间会话可能已被回收） */
    fun setBackgrounded(background: Boolean) {
        if (backgrounded == background) return
        backgrounded = background
        if (background) {
            // 电视上切走就不看了：按用户暂停处理（回来时停在暂停态，片名和进度条都在）
            pause()
            if (reportedStart) sendProgress(paused = true)
        } else {
            qualitySuggestion.restartGrace()
            activeSessionId?.let { sid -> scope.launch { ping(sid) } }
        }
        resetWatchdogs()
    }

    // ======================================================================
    // 心跳 / 进度
    // ======================================================================

    private fun reportStart() {
        reportedStart = true
        val body = progressBody("start", null, paused = null)
        enqueueReport { handleProgressResponse(api.playbackProgress(body)) }
        startProgressLoop()
    }

    private fun startPingLoop() {
        pingJob?.cancel()
        val sid = activeSessionId ?: return
        pingJob = scope.launch {
            while (isActive) {
                delay(PING_INTERVAL_MS)
                ping(sid)
            }
        }
    }

    private suspend fun ping(sid: String) {
        val alive = try {
            api.playbackSessionPing(sid)
            true
        } catch (e: ApiException) {
            if (e.status == 404) false else null
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // 这次请求本身失败（断网 / 5xx）：不能据此判定会话没了
            null
        }
        if (alive != false || sid != activeSessionId) return
        if (s.phase != Phase.Playing && s.phase != Phase.Buffering) return
        if (!exo.playWhenReady && !s.wantsPlay) {
            // 用户自己暂停着：不替他白烧一路转码，等他点播放再重开
            deadSession = true
            return
        }
        request(s.positionMs, Phase.SessionStarting)
    }

    private fun startProgressLoop() {
        progressJob?.cancel()
        progressJob = scope.launch {
            while (isActive) {
                delay(PROGRESS_INTERVAL_MS)
                if (s.phase == Phase.Playing) sendProgress(paused = !exo.playWhenReady)
            }
        }
    }

    private fun sendProgress(paused: Boolean?) {
        if (!reportedStart) return
        val body = progressBody("progress", s.positionMs, paused)
        enqueueReport { handleProgressResponse(api.playbackProgress(body)) }
    }

    private fun progressBody(event: String, positionMs: Long?, paused: Boolean?) = PlaybackProgressRequest(
        mediaItemId = unit.mediaItemId,
        seasonNumber = unit.season,
        episodeNumber = unit.episode,
        event = event,
        positionMs = positionMs,
        // 音轨只报用户点选的：服务端默认挑选、Exo 自己挑的同语言轨报了会被当成用户的选择记下
        audioTrack = requestedAudio,
        subtitleTrack = subtitleMemory,
        // 带上正在放的版本：多版本时服务端据此判断报上来的轨是不是这个版本的默认挑选
        fileId = session?.decision?.fileId,
        deviceId = deviceId,
        paused = paused,
    )

    private fun enqueueReport(work: suspend () -> Unit) {
        reports.trySend(work)
    }

    /** 管理员在活动页结束了本次播放：退出并说明（服务端同时进入拒绝窗口，不能走「会话没了就重开」） */
    private fun handleProgressResponse(state: PlaybackStateView) {
        if (!state.endedByAdmin || s.phase == Phase.Error || closed) return
        exo.pause()
        leaveUnit()
        fail("管理员已结束本次播放", "稍后可以重新开始播放；观看进度已经保存。")
    }

    // ======================================================================
    // 读数循环（4Hz 位置 / 1Hz 速度与看门狗）
    // ======================================================================

    private fun startTickLoop() {
        tickJob?.cancel()
        tickJob = scope.launch {
            var tick = 0
            while (isActive) {
                delay(250)
                tickPosition()
                tick += 1
                if (tick % 4 == 0) {
                    tickSecond()
                    if (probe) logProbe()
                }
            }
        }
    }

    private fun tickPosition() {
        sampleStall()
        val phase = s.phase
        if (!mediaLoaded || session == null || (phase != Phase.Buffering && phase != Phase.Playing)) return
        val stream = exo.currentPosition
        val file = originMs + stream
        // 起播 seek 落地前 Exo 报的是 0：别让进度条先闪回片头
        val keep = stream < 50 && s.positionMs > 2000 && phase == Phase.Buffering
        val engineDuration = exo.duration.takeIf { it != C.TIME_UNSET && it > 0 }
        val buffered = originMs + exo.bufferedPosition
        set {
            copy(
                positionMs = if (keep) positionMs else file,
                durationMs = durationMs ?: engineDuration?.let { originMs + it },
                bufferedEndMs = buffered,
                paused = !exo.playWhenReady,
            )
        }
        if (phase == Phase.Playing && exo.isPlaying) record?.let { it.watchedMs += 250 }
    }

    /**
     * 卡顿按播放头判（playback-qoe.md §3.2）：用户想看、出过画、不在后台、没在跳转或换轨，播放头 0.5 秒不走算一次——
     * 断线重连、换会话期间画面停着也算。原因在卡顿开始时判。
     */
    private fun sampleStall() {
        val r = record ?: return
        val phase = s.phase
        val eligible = r.firstFrameAt != null && s.wantsPlay && !backgrounded && !r.seekPending && seekStartedAt == null &&
            phase != Phase.Ended && phase != Phase.Error && phase != Phase.Consent && phase != Phase.Idle
        r.samplePlayhead(s.positionMs, eligible) {
            val ahead = (s.bufferedEndMs ?: 0) - s.positionMs
            when {
                phase == Phase.SessionStarting || phase == Phase.Deciding -> "session_restart"
                phase == Phase.Degrading -> "fallback"
                ahead >= 3000 -> "decode"
                (loadingBps ?: 0.0) <= 0 -> "network"
                else -> "slow_link"
            }
        }
    }

    private fun tickSecond() {
        resourceTick += 1
        if (resourceTick % 10 == 0) sampleResources()
        if (!mediaLoaded) return
        val now = SystemClock.elapsedRealtime()
        val elapsed = (now - lastSecondAt).coerceAtLeast(1)
        lastSecondAt = now
        val bytes = bytesLoaded.getAndSet(0)
        loadingBps = bytes * 8 * 1000.0 / elapsed
        // 带宽估计另记：申报给服务端的 downlink_bps 要的是线路能力，缓冲满了也保持上次实测值
        if (bytes > 0) {
            lastDownlinkBps = bandwidth.bitrateEstimate.toDouble()
            record?.noteDownlink(bandwidth.bitrateEstimate.toDouble())
        }
        set { copy(speedLabel = PlayerFormat.loadingSpeed(loadingBps)) }
        val fps = engineFacts.videoFormat?.frameRate?.takeIf { it > 0 } ?: session?.source?.frameRate?.toFloat()
        if (fps != s.contentFrameRate) set { copy(contentFrameRate = fps) }
        runWatchdogs()
        feedQualitySuggestion()
    }

    /** 实验台读的一行状态（`adb logcat -s PlaybackProbe`）：阶段、文件时间播放头、界面上的提示与错误 */
    private fun logProbe() {
        val st = s
        val fields = linkedMapOf<String, JsonElement>(
            "unit" to JsonPrimitive("${st.unit.mediaItemId}/${st.unit.season}/${st.unit.episode}"),
            "ph" to JsonPrimitive(st.phase.name),
            "pos" to JsonPrimitive(st.positionMs),
            "dur" to (st.durationMs?.let(::JsonPrimitive) ?: JsonNull),
            "buf" to (st.bufferedEndMs?.let(::JsonPrimitive) ?: JsonNull),
            "playing" to JsonPrimitive(mediaLoaded && exo.isPlaying),
            "want" to JsonPrimitive(st.wantsPlay),
            "tier" to (session?.decision?.tier?.let(::JsonPrimitive) ?: JsonNull),
            "orig" to JsonPrimitive(playsOriginalFile),
            "notice" to (st.notice?.let(::JsonPrimitive) ?: JsonNull),
            "err" to (st.errorMessage?.let(::JsonPrimitive) ?: JsonNull),
            "offer" to JsonPrimitive(st.qualityOffer != null),
            "stall" to JsonPrimitive(record?.stalling == true),
            "q" to (st.quality?.let(::JsonPrimitive) ?: JsonNull),
            "bps" to (loadingBps?.let { JsonPrimitive(it.toLong()) } ?: JsonNull),
        )
        Log.i(PROBE_TAG, JsonObject(fields).toString())
    }

    private fun resetWatchdogs() {
        stallWatch.reset()
        frameDrops.reset()
    }

    /** 每秒一次：卡顿归因（解码卡死 / 连接断了；线路慢不算失败）与直通掉帧。命中就走 [engineFailed] 的兜底规则 */
    private fun runWatchdogs() {
        val phase = s.phase
        if (session == null || (phase != Phase.Buffering && phase != Phase.Playing) || backgrounded || failureInFlight) return
        val deadLimit = if (playsOriginalFile) StallWatch.DIRECT_DEAD_SECONDS else StallWatch.SERVER_DEAD_SECONDS
        val time = exo.currentPosition / 1000.0
        val ahead = ((exo.bufferedPosition - exo.currentPosition) / 1000.0).coerceAtLeast(0.0)
        when (
            stallWatch.sample(
                time = time, bufferedAhead = ahead, paused = !exo.playWhenReady, ended = phase == Phase.Ended,
                seeking = seekStartedAt != null, receiving = (loadingBps ?: 0.0) > 0, deadLimit = deadLimit,
            )
        ) {
            StallWatch.Verdict.Ok -> Unit
            StallWatch.Verdict.Nudge -> {
                log("stall-nudge", "position_ms" to JsonPrimitive(s.positionMs))
                exo.setSeekParameters(SeekParameters.EXACT)
                exo.seekTo(exo.currentPosition + StallWatch.NUDGE_STEP_MS)
                exo.play()
            }
            StallWatch.Verdict.DecodeStalled -> {
                engineFailed(StallWatch.reason(StallWatch.Verdict.DecodeStalled, deadLimit), FailureCause.Decode)
                return
            }
            StallWatch.Verdict.Dead -> {
                engineFailed(StallWatch.reason(StallWatch.Verdict.Dead, deadLimit), FailureCause.Network)
                return
            }
        }
        // 掉帧只在视频直通时判：转码档已经是 h264，再掉帧说明连转码产物都放不动，继续降档只会更糟
        val copying = playsOriginalFile || session?.decision?.video?.action == "copy"
        if (!copying || phase != Phase.Playing || !exo.playWhenReady || seekStartedAt != null) return
        val counters = exo.videoDecoderCounters ?: return
        counters.ensureUpdated()
        val dropped = counters.droppedBufferCount.toLong()
        val total = dropped + counters.renderedOutputBufferCount + counters.skippedOutputBufferCount
        val ratio = frameDrops.sample(dropped, total) ?: return
        if (ratio >= FrameDropTracker.RATIO) {
            frameDrops.reset()
            engineFailed("直通播放持续掉帧（${Math.round(ratio * 100)}%），正在换转码重试", FailureCause.Decode)
        }
    }

    /** 每秒一次，只在用户想看时喂；条件满足就给一次换低画质的提议（换不换由用户定） */
    private fun feedQualitySuggestion() {
        val phase = s.phase
        if (!s.wantsPlay || backgrounded || (phase != Phase.Buffering && phase != Phase.Playing) || session == null) return
        val seeking = seekStartedAt != null
        qualitySuggestion.tick(stalled = phase == Phase.Buffering || seeking, seeking = seeking, loadingBps = loadingBps)
        if (s.qualityOffer != null || qualitySuggestion.offered) return
        val bitrate = QualitySuggestion.streamBitrate(exo.videoFormat?.bitrate, exo.audioFormat?.bitrate, session?.source?.bitRate)
        val source = sourceHeight()
        val currentHeight = s.quality?.let { cap -> source?.let { minOf(it, cap) } ?: cap } ?: source
        val offer = qualitySuggestion.offer(bitrate, currentHeight) ?: return
        log(
            "quality-suggestion", "measured_bps" to JsonPrimitive(offer.measuredBps.toLong()),
            "required_bps" to JsonPrimitive(offer.requiredBps.toLong()), "suggested_height" to JsonPrimitive(offer.maxHeight),
            "engine" to str("exo"),
        )
        set { copy(qualityOffer = offer) }
        // 20 秒没理会就收起（本单元不再提）：它只是个建议，不该一直挡着画面
        qualityOfferJob?.cancel()
        qualityOfferJob = scope.launch {
            delay(20_000)
            set { copy(qualityOffer = null) }
        }
    }

    // ======================================================================
    // 缩略图 / 提示 / 系统媒体信息
    // ======================================================================

    /** 进度条缩略图索引：开会话时服务端才在后台生成，没就绪就隔 30 秒再问（最多 6 次，失败无所谓） */
    private fun loadTrickplay(fileId: Long, token: String?) {
        trickplayJob?.cancel()
        if (token == null) return
        trickplayJob = scope.launch {
            repeat(6) {
                val index = runCatching { api.playbackFileTrickplay(fileId, token) }.getOrNull()
                if (index?.ready == true) {
                    set { copy(trickplay = index) }
                    return@launch
                }
                delay(30_000)
            }
        }
    }

    /** 雪碧图的完整地址（服务端给的是带令牌的根相对路径） */
    fun resolve(path: String): String? = server.resolve(path)?.toString()

    /** 当前文件时间（毫秒）：叠加层字幕 10Hz 读 */
    fun currentFileMs(): Long = originMs + exo.currentPosition

    /** 这次沿用了哪些**不是默认**的记忆（画质、音轨、字幕），拼成开播提示；都是默认的返回 null */
    private fun rememberedChoiceNotice(): String? {
        val session = session ?: return null
        val qualityLimit = if (qualityFromMemory && qualityLimited) s.quality else null
        var audio: String? = null
        val remembered = session.watch?.audioTrack
        if (requestedAudio == null && remembered != null && remembered == s.currentAudio && remembered != AudioOption.defaultRef(s.audioOptions)) {
            s.audioOptions.firstOrNull { it.ref == remembered }?.let { option ->
                audio = RememberedChoices.shortLabel(option.label, s.audioOptions.map { it.label })
            }
        }
        var subtitle: String? = null
        if (!subtitleTouched && burnedSubtitle == null && rememberedSubtitle != null &&
            s.selectedSubtitle != s.subtitles.initialSelection(null)
        ) {
            subtitle = s.selectedSubtitle?.let { ref ->
                s.subtitles.options.firstOrNull { it.ref == ref }?.let { RememberedChoices.shortLabel(it.label, s.subtitles.options.map { o -> o.label }) }
            } ?: "关闭"
        }
        return RememberedChoices.notice(qualityLimit, network, audio, subtitle)
    }

    fun flash(message: String) {
        set { copy(notice = message) }
        noticeJob?.cancel()
        noticeJob = scope.launch {
            delay(4000)
            set { copy(notice = null) }
        }
    }

    /** 系统「正在播放」的标题、副标题（季集或年份）、封面（剧集用本集剧照，没有用海报） */
    private fun mediaMetadata(): MediaMetadata {
        val state = s
        val artwork = (state.currentEpisode?.stillUrl?.takeIf { it.isNotEmpty() } ?: state.info?.posterUrl)
            ?.let { ImageUrls.build(server, it, 400) }
        return MediaMetadata.Builder()
            .setTitle(state.title)
            .setArtist(state.episodeLabel ?: state.info?.year?.toString() ?: "")
            .setMediaType(if (state.unit.isEpisode) MediaMetadata.MEDIA_TYPE_TV_SHOW else MediaMetadata.MEDIA_TYPE_MOVIE)
            .apply { artwork?.let { setArtworkUri(Uri.parse(it.toString())) } }
            .build()
    }

    /** 条目信息、分集清单到了之后刷新（媒体会话下次读播放器状态时取到；不重换媒体项，免得打断播放） */
    private fun updateMediaMetadata() {
        if (!closed) metadata = mediaMetadata()
    }

    // ======================================================================
    // 播放记录 / 客户端日志
    // ======================================================================

    private fun beginRecord(origin: String) {
        record = PlaybackRecord(unit, origin, SystemClock.elapsedRealtime(), SystemClock::elapsedRealtime, lab)
        EngineLog.add("player", "开始播放 ${unit.mediaItemId}/${unit.season}/${unit.episode}（$origin）")
    }

    private fun endRecord(forceOutcome: String? = null) {
        val r = record ?: return
        record = null
        val outcome = forceOutcome ?: r.outcome(s.phase == Phase.Error, s.phase == Phase.Ended, s.positionMs, s.durationMs)
        noteDelivery(r)
        r.noteLeaving()
        val payload = recordPayload(r, outcome)
        reportStore.clearRunning()
        reportStore.enqueue(payload)
        enqueueReport {
            api.playbackMetricReport(payload)
            reportStore.remove(payload.attemptId)
        }
    }

    /** 完整记录：明细、设备快照，值得的时候附引擎日志尾巴 */
    private fun recordPayload(r: PlaybackRecord, outcome: String): PlaybackMetricPayload {
        val counters = runCatching { exo.videoDecoderCounters?.also { it.ensureUpdated() } }.getOrNull()
        val denied = denylist.entries()
        r.device = if (denied.isEmpty()) {
            deviceFacts.snapshot
        } else {
            JsonObject(deviceFacts.snapshot + ("denied_decoders" to JsonObject(denied.mapValues { JsonPrimitive("${it.value.mime}：${it.value.reason}") })))
        }
        val context = JsonObject(
            mapOf(
                "app_version" to JsonPrimitive(identity.appVersion),
                "os" to JsonPrimitive(android.os.Build.VERSION.RELEASE),
                "model" to JsonPrimitive("${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}"),
                "network" to JsonPrimitive(network.key),
                "interface" to JsonPrimitive(deviceFacts.networkInterface()),
            ),
        )
        return r.payload(
            outcome = outcome, network = network, appVersion = identity.appVersion,
            networkInterface = deviceFacts.networkInterface(), context = context,
            positionMs = s.positionMs, durationMs = s.durationMs,
            droppedFrames = counters?.droppedBufferCount?.toLong(),
            totalFrames = counters?.let { (it.renderedOutputBufferCount + it.droppedBufferCount + it.skippedOutputBufferCount).toLong() },
            logTail = if (r.wantsLogTail(outcome)) EngineLog.tail() else null,
        )
    }

    /** 每 10 秒：资源读数，并把「正在播放」快照存到本机（闪退 / 被杀后下次按异常退出补报） */
    private fun sampleResources() {
        val r = record ?: return
        r.sampleResources(deviceFacts.memoryMb(), deviceFacts.thermal())
        if (r.firstFrameAt != null || s.phase.isBusy) {
            // 平时不带日志尾巴（快照几 KB）；出过问题才带上——崩溃时另有崩溃栈与日志尾巴同步写下
            runCatching { reportStore.saveRunning(recordPayload(r, "exited")) }
        }
    }

    /** 上次没收尾的播放（闪退）与没发出去的记录：补发 */
    private fun flushStoredReports() {
        val abnormal = reportStore.takeAbnormal()
        abnormal?.let(reportStore::enqueue)
        val pending = reportStore.queued()
        if (pending.isEmpty()) return
        enqueueReport {
            for (payload in pending) {
                runCatching { api.playbackMetricReport(payload) }.onSuccess { reportStore.remove(payload.attemptId) }
            }
        }
    }

    /** 规格快照（playback-qoe.md §3.3）：源、实际解码与输出、音频交付方式、字幕呈现、当前输出设备 */
    private fun noteDelivery(r: PlaybackRecord? = record) {
        val rec = r ?: return
        val opened = session ?: return
        val decision = opened.decision
        val track = decision.audioTracks.firstOrNull { it.ref == (s.currentAudio ?: decision.audio?.trackRef) }
        val sourceCodec = (track?.codec ?: decision.audio?.codec)?.lowercase()
        val displayHdr = deviceFacts.displayHdr()
        val decoded = engineFacts.videoRange
        val audioDelivery = when {
            playsOriginalFile -> if (engineFacts.audioPassthrough) "passthrough" else "decoded"
            decision.audio?.action == "copy" -> if (engineFacts.audioPassthrough) "server_copy_passthrough" else "server_copy"
            else -> "server_transcode"
        }
        val subtitleMode = when {
            burnedSubtitle != null -> "burned"
            s.selectedSubtitle == null -> "none"
            s.engineSubtitles -> "engine"
            s.overlaySubtitleUrl != null -> "overlay"
            else -> "none"
        }
        rec.noteDelivery(
            buildJsonObject {
                put("route", rec.route)
                put("tier", decision.tier ?: -1)
                put("user_capped", qualityLimited)
                put("video", buildJsonObject {
                    put("source_format", hdrKey(opened.source?.hdr))
                    // 显示器不支持 HDR 时电视自己把 HDR 映射成 SDR 输出
                    put("output_format", decoded?.let { if (it != "sdr" && !displayHdr) "sdr" else it })
                    put("codec", opened.source?.videoCodec)
                    put("action", decision.video?.action)
                    put("tone_map", decision.video?.toneMap == true)
                    put("decoder", engineFacts.videoDecoder)
                    put("decoder_hw", engineFacts.videoDecoder?.let { !it.startsWith("c2.android") && !it.startsWith("OMX.google") })
                    put("decoded", engineFacts.videoFormat?.let(EngineFacts::describe))
                    put("source_fps", opened.source?.frameRate)
                })
                put("audio", buildJsonObject {
                    put("source_codec", sourceCodec)
                    put("source_channels", track?.channels)
                    put("source_lossless", sourceCodec in LOSSLESS_CODECS)
                    put("delivery", audioDelivery)
                    put("output_codec", engineFacts.audioOutputEncoding?.let(EngineFacts::encodingName))
                    put("output_channels", engineFacts.audioOutputChannels)
                    put("decoder", engineFacts.audioDecoder)
                    put("tunneling", engineFacts.audioTunneling)
                    put("underruns", engineFacts.audioUnderruns)
                })
                put("subtitle", buildJsonObject { put("mode", subtitleMode) })
                put("output", buildJsonObject {
                    put("audio_route", deviceFacts.audioRoute())
                    put("display_hdr", displayHdr)
                    put("display_mode", deviceFacts.currentDisplay())
                })
            },
        )
    }

    private val recordStage: String
        get() = when {
            record?.firstFrameAt != null -> "playback"
            session == null -> "negotiation"
            else -> "startup"
        }

    private fun reportStartup() {
        val r = record ?: return
        log(
            "startup", "engine" to str("exo"), "tier" to (session?.decision?.tier?.let(::JsonPrimitive) ?: JsonNull),
            "original" to JsonPrimitive(playsOriginalFile), "start_ms" to JsonPrimitive(s.positionMs),
            "media_item_id" to JsonPrimitive(unit.mediaItemId), "file_id" to (session?.decision?.fileId?.let(::JsonPrimitive) ?: JsonNull),
            "first_frame_ms" to (r.firstFrameMs?.let { JsonPrimitive(it) } ?: JsonNull),
        )
    }

    /** 客户端事件日志（服务端按天日志）：一律带上播放编号，与服务端的「播放会话就绪」等行串起来 */
    private fun log(event: String, vararg detail: Pair<String, JsonElement>) {
        EngineLog.add("log", "$event ${JsonObject(detail.toMap())}")
        record?.event(event, detail.joinToString(" ") { (k, v) -> "$k=$v" })
        val map = detail.toMap().toMutableMap()
        record?.id?.let { map["attempt_id"] = JsonPrimitive(it) }
        scope.launch { runCatching { api.playbackClientLog(PlaybackClientLogPayload(event, JsonObject(map))) } }
    }

    private fun str(value: String?): JsonElement = value?.let(::JsonPrimitive) ?: JsonNull

    companion object {
        private const val TAG = "Playback"
        const val PROBE_TAG = "PlaybackProbe"

        /** 无损音频编码（规格损失判定：经 HDMI 输出时无损变有损算损失） */
        val LOSSLESS_CODECS = setOf("truehd", "mlp", "flac", "alac", "pcm_s16le", "pcm_s24le", "pcm_bluray", "pcm_dvd", "dts-hd ma")

        /** 台账的 HDR 标签 → 规格快照的口径 */
        fun hdrKey(label: String?): String = when (label?.lowercase()?.replace(" ", "")) {
            null, "" -> "sdr"
            "dolbyvision" -> "dolbyvision"
            "hdr10+" -> "hdr10plus"
            "hlg" -> "hlg"
            else -> "hdr10"
        }
        const val PROGRESS_INTERVAL_MS = 10_000L
        const val PING_INTERVAL_MS = 15_000L

        private val EXTRA_COMMANDS = listOf(
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
            Player.COMMAND_SEEK_FORWARD, Player.COMMAND_SEEK_BACK,
        )

        /** 从已签名的地址里取 token（缩略图、原文件直连复用同一份授权） */
        fun tokenIn(path: String?): String? {
            if (path == null) return null
            val query = path.substringAfter('?', "")
            return query.split('&').firstOrNull { it.startsWith("token=") }?.removePrefix("token=")?.takeIf { it.isNotEmpty() }
        }
    }
}

/** Exo 的音频 MIME → 服务端口径的编码名（菜单里显示成大写，如 AC3 / EAC3 / TRUEHD） */
internal fun audioCodecName(mime: String?): String = when (mime) {
    null -> ""
    MimeTypes.AUDIO_AAC -> "aac"
    MimeTypes.AUDIO_MPEG -> "mp3"
    MimeTypes.AUDIO_AC3 -> "ac3"
    MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "eac3"
    MimeTypes.AUDIO_TRUEHD -> "truehd"
    MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_DTS_EXPRESS -> "dts"
    else -> mime.substringAfter('/')
}
