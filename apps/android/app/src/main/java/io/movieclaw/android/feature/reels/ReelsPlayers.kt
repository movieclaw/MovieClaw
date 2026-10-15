@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package io.movieclaw.android.feature.reels

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.Player
import androidx.media3.datasource.okhttp.OkHttpDataSource
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.BuildInfo
import io.movieclaw.android.core.playback.CorePlaybackPrefs
import io.movieclaw.android.core.playback.PlaybackNetwork
import io.movieclaw.android.core.model.ReelItemView
import io.movieclaw.android.core.playback.ReelsQuality
import io.movieclaw.android.core.playback.SubtitleCues
import io.movieclaw.core.model.generated.PlaybackSessionRequest
import io.movieclaw.core.network.ClientIdentity
import io.movieclaw.core.network.generated.McApi
import io.movieclaw.core.playback.CapabilityProbe
import io.movieclaw.core.playback.ClipPlayer
import io.movieclaw.core.playback.SourceByteCache
import io.movieclaw.core.playback.UnifiedExo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 一条片段怎么放：直出与转码两条路统一成同一个形状。
 *
 * - **直出**（局域网默认）：服务端按文件签发的令牌，播原片字节；引擎起点就是片段起点，
 *   终点就是片段终点，播放器位置 = 原片时间。
 * - **转码**（外网 / 显式限了画质）：借正片的播放会话说一份 720p 流；会话从起点开始，
 *   流时间 0 = 原片 `segment.startMs`。播放器位置 + [fileOffsetMs] = 原片时间。
 */
data class ReelSource(
    val url: String,
    val hls: Boolean,
    /** 引擎起播位置（播放器时间） */
    val playerStartMs: Long,
    /** 引擎停下的位置（播放器时间） */
    val playerEndMs: Long,
    /** 播放器时间 → 原片时间 的偏移（用于进度、字幕、事件） */
    val fileOffsetMs: Long,
    val cacheKey: String?,
    val audioRef: String?,
    /** 服务端会话 id（转码 / 光盘换封装）；直出为 null。离开这条时要停掉，播放中每 15 秒续命 */
    val sessionId: String? = null,
    /** 关闭/心跳沿用建会话时的账号快照，切账号后不能重新取当前客户端。 */
    val sessionApi: McApi? = null,
)

/**
 * 刷片的播放器池 —— iOS `ReelsStore`（player / standby / prefetchTasks）的对应物。
 *
 * 三件事：
 *  1. **字节预取**：当前条出画后，把后几条的 `play.prefetch` 范围下进片源字节缓存
 *     （非计费网络 3 条，计费 1 条；第一条全量，后面的只取文件头与索引）；
 *  2. **预起下一条**：局域网直出时，当前条出画 1 秒且下一条字节就绪后，另建一个引擎
 *     把下一条装载到片段起点停着，滑过去只需「播放」（省掉建引擎、探测、出第一帧）；
 *  3. **画质**：按「网络环境 × 用户选的档位」决定直出还是借转码会话，会话播放中续命。
 *
 * 每一条的播放器是统一引擎的 [ClipPlayer]（与正片同一套 Exo 配置：FFmpeg 音频软解、解码器黑名单、字节缓存）。
 *
 * 为什么播放器由这里（而不是每一页）持有：预起的那条属于**下一条**，而它的引擎是在
 * 当前这条还活着的时候建的——放在页面里就会随当前页被滑走而一起销毁。这里按节点换手，
 * 页面只负责把画面挂上去。
 */
class ReelsPlayers(
    private val context: Context,
    private val apiFactory: ApiFactory,
    /** 统一引擎的本机偏好（与正片共用一份解码器黑名单） */
    private val prefs: CorePlaybackPrefs,
    private val scope: CoroutineScope,
    private val originProvider: () -> String?,
    /** 本机 device id（会话归属与活动页的「正在播放」用，同正片） */
    private val deviceIdProvider: suspend () -> String? = { null },
    /** 事件上报（impression / first_frame / complete / leave / fail …） */
    private val onEvent: (ReelItemView, String, Long?, Long?, Long?, String?) -> Unit,
) {

    /* ---------------- 界面要读的状态（Compose state） ---------------- */

    /** 当前条已出画（它的画面可以直接显示；没出画时页面垫封面） */
    var frameReadyId by mutableStateOf<String?>(null)
        private set

    /** 预起的下一条已经装载好（滑过去直接播） */
    var standbyReadyId by mutableStateOf<String?>(null)
        private set

    var playing by mutableStateOf(false)
        private set

    /** 放到片段终点停下了（页面上给重播键） */
    var ended by mutableStateOf(false)
        private set

    /** 播放器位置（**原片时间**，含 fileOffsetMs） */
    var positionMs by mutableLongStateOf(0L)
        private set

    var failMessage by mutableStateOf<String?>(null)
        private set

    /** 这一条的字幕（服务端给的窗口文件，文件时间轴） */
    var cues by mutableStateOf<List<SubtitleCues.Cue>>(emptyList())
        private set

    /** 画面该挂哪个播放器：当前条的（页面用 state 读它，换条会重组重绑） */
    var currentEngine by mutableStateOf<ClipPlayer?>(null)
        private set

    /* ---------------- 内部 ---------------- */

    private class Clip(
        val item: ReelItemView,
        val engine: ClipPlayer,
        val source: ReelSource,
        var pollJob: Job? = null,
        var subtitleJob: Job? = null,
        var hasFirstFrame: Boolean = false,
        var startedAtMs: Long = 0L,
        var watchedMs: Long = 0L,
        /** 换条时刻（出画事件的分母） */
        var impressionAtMs: Long = 0L,
    )

    /** 换条序号：连滑两条时把先落地那次作废（见 settle 注释） */
    private var settleSeq = 0
    private var settleJob: Job? = null
    // 延后释放的播放器池（拆播放器在主线程要几十毫秒，让开滑动收尾）
    private val pendingTeardowns = DeferredReelReleases<ClipPlayer>(scope) { it.release() }

    private var current: Clip? = null
    private var standby: Clip? = null
    private var standbyJob: Job? = null
    private var pingJob: Job? = null

    /** 预取任务：键 = "条目id#full|light"（同 iOS） */
    private val prefetchJobs = mutableMapOf<String, Job>()

    private var qualityCap: Int = ReelsQuality.AUTO
    private var network: PlaybackNetwork = PlaybackNetwork.UNKNOWN

    /** openSource 失败的原因：光盘类开不出会话要说清，不能都说成「缺少取流地址」 */
    private var openFailureReason: String? = null

    /** 当前服务器的播放通道（生成的接口 + 取流用的 OkHttp）；换服务器 / 换账号时按 origin 现取 */
    private fun channel(origin: String) = apiFactory.corePlayback(origin)

    /**
     * 片段取流与字节预取用的 OkHttp：与播放通道共用连接池，但**调度上限单独放宽**。Media3 的 OkHttp 数据源走异步调度，
     * OkHttp 默认每台服务器同时只放 5 个请求；刷片同时挂着当前条、预起的下一条、最多 3 路预取与还没拆完的上一条，
     * 再加上同一通道的接口请求，名额一满新请求就得排队等长连接读完（旧版走 HttpURLConnection，没有这个上限）。
     */
    private val mediaHttp = mutableMapOf<String, okhttp3.OkHttpClient>()

    private fun mediaHttp(origin: String): okhttp3.OkHttpClient = mediaHttp.getOrPut(origin) {
        channel(origin).http.newBuilder()
            .dispatcher(okhttp3.Dispatcher().apply { maxRequests = 64; maxRequestsPerHost = 32 })
            .build()
    }

    private val denylist by lazy { prefs.decoderDenylist() }

    private fun newClip(origin: String, buffer: UnifiedExo.Buffer) =
        ClipPlayer(context, mediaHttp(origin), BuildInfo.USER_AGENT, denylist, buffer)

    fun setQuality(cap: Int) {
        qualityCap = cap
    }

    fun setNetwork(n: PlaybackNetwork) {
        network = n
    }

    fun currentItemId(): String? = current?.item?.id

    fun engineFor(itemId: String): ClipPlayer? {
        if (current?.item?.id == itemId) return current?.engine
        // 预起的那条：**装载好就把画面给它**——页面挂上 surface 它才出得了第一帧；
        // 等 standbyReadyId 再给就成了鸡生蛋（没 surface 永远不出帧）
        if (standby?.item?.id == itemId) return standby?.engine
        return null
    }

    fun isPlaying(): Boolean = playing

    /* ---------------- 换条（滑动停稳后调用） ---------------- */

    /**
     * 当前条换成 [item]：下一条预起好了就直接接着播，否则现起（必要时先协商转码会话）。
     * 旧引擎先停声、500ms 后再拆（拆引擎在主线程要几十毫秒，不能赶在滑动收尾那一刻）。
     *
     * **换条序号 (`settleSeq`)**：协商 / 建引擎是异步的，用户连滑两条时会同时有两次
     * settle 在飞。没有这道闸，先落地的那次会把引擎挂上 current，后落地的那次再覆盖
     * 一次——**第一个引擎就成了没人管还在出声的孤儿**（实机反馈过「画面这一部、声音
     * 另一部」）。现在：序号对不上就把这次整个作废（引擎都不建）。
     */
    fun settle(item: ReelItemView, index: Int, items: List<ReelItemView>) {
        if (current?.item?.id == item.id) return
        settleSeq += 1
        settleJob?.cancel()
        val seq = settleSeq
        leaveCurrent(deferTeardown = true)
        val impressionAt = android.os.SystemClock.elapsedRealtime()
        onEvent(item, "impression", null, null, item.segment.startMs, null)

        val ready = standby?.takeIf { it.item.id == item.id && it.source.playerStartMs >= 0 }
        if (ready != null) {
            standby = null
            standbyReadyId = null
            adopt(ready, item, impressionAt)
            ready.engine.setPlaying(true)
            // 预起时静音：转正还原音量
            ready.engine.player.volume = 1f
            playing = true
            ended = false
            android.util.Log.i("McReels", "接上预起：${item.title.name}")
            if (ready.hasFirstFrame) {
                frameReadyId = item.id
                afterFirstFrame(item, index, items)
            }
        } else {
            dropStandby()
            settleJob = scope.launch {
                // 失败原因分开报：光盘类开不出会话要说清（"缺少取流地址"会把光盘说错）
                val source = openSource(item) ?: run {
                    failMessage = openFailureReason ?: "这一条缺少取流地址"
                    onEvent(
                        item, "fail", null, null, null,
                        if (openFailureReason != null) "disc_unsupported" else "no_stream_url",
                    )
                    return@launch
                }
                if (seq != settleSeq) {
                    android.util.Log.i("McReels", "作废一次换条（已滑走）：${item.title.name}")
                    closeSession(source.sessionId, source.sessionApi)
                    return@launch
                }
                lastOpenWasTranscoded = source.sessionId != null
                val origin = originProvider() ?: return@launch
                val engine = newClip(origin, UnifiedExo.Buffer.Main)
                val clip = Clip(item = item, engine = engine, source = source)
                current = clip
                currentEngine = engine
                // 换条时先把显示位置归到新片段的窗口起点：引擎本来就会被 seek 到这里（playerStartMs），
                // 但外网起播要等几秒才报第一个位置，这期间字幕叠层与进度条会拿**上一条**的旧值去查
                // ——实机日志：王国的位置还是 968176（疑犯追踪的起点）、瑞克和莫蒂的还是 1703702（王国的起点），
                // 一条 cue 都命不中
                positionMs = item.segment.startMs
                frameReadyId = null
                failMessage = null
                ended = false
                attach(clip, impressionAt)
                android.util.Log.i(
                    "McReels",
                    "起播 ${item.title.name}：${if (source.sessionId == null) "直出" else "转码"} " +
                        "起=${source.playerStartMs}ms 停=${source.playerEndMs}ms " +
                        "url=${source.url.substringBefore('?').take(90)}",
                )
                // 冷起播补两段：和引擎的打开、探测并行（iOS `boostColdStart`）
                boostColdStart(item, source)
                engine.open(clipSource(source))
                // **这里必须把播放状态置真**：引擎是 autoplay 起播的，漏了这一步就会
                // 「画面在放、状态却是暂停」——一进页面就顶着暂停键，全屏里点一下还弹不起来
                // （只有「接上预起」那条分支置过，这条漏了）
                playing = true
                startPing(source.sessionId, source.sessionApi)
            }
        }
        schedulePrefetch(index)
    }

    private fun clipSource(source: ReelSource, autoplay: Boolean = true) = ClipPlayer.Source(
        url = source.url,
        hls = source.hls,
        startMs = source.playerStartMs,
        autoplay = autoplay,
        audioIndex = source.audioRef?.removePrefix("embedded:")?.toIntOrNull(),
        cacheKey = source.cacheKey,
    )

    /**
     * 这一条要放什么：直出（局域网默认）还是转码（外网 / 限了画质）。
     * 转码走正片的 `POST /playback/sessions`，`startMs` 直接给片段起点——服务端从那儿切。
     */
    private suspend fun openSource(item: ReelItemView): ReelSource? {
        val origin = originProvider() ?: return null
        openFailureReason = null
        // 光盘片源（v0.32 起「大图预告」与「片段」也放开原盘 / 镜像 / DVD / TS / AVI）：本机引擎读不了盘内结构，
        // 与正片同一条路——开服务端会话，服务端读出正片后换封装或转码（不申报 disc_image / disc_folder）
        val disc = item.play.disc != null
        val cap = ReelsQuality.effectiveCap(qualityCap, network)
        if (cap == null && !disc) return directSource(item, origin)
        return runCatching {
            val api = channel(origin).api
            val view = api.playbackSessionStart(
                PlaybackSessionRequest(
                    fileId = item.segment.fileId.takeIf { it > 0 },
                    mediaItemId = item.title.mediaItemId.takeIf { it > 0 },
                    seasonNumber = (item.title.episode?.season ?: 0).toLong(),
                    episodeNumber = (item.title.episode?.episode ?: 0).toLong(),
                    // 统一引擎的如实申报（与正片同一份探测）：限了上限时服务端据此压码率
                    capability = CapabilityProbe(context, denylist::isDenied).probe(),
                    maxHeight = cap?.toLong(),
                    deviceId = runCatching { deviceIdProvider() }.getOrNull(),
                    startMs = item.segment.startMs,
                    client = ClientIdentity.PHONE_KIND,
                )
            )
            val raw = if (view.timeline == "file") (view.masterUrl ?: view.streamUrl) else view.streamUrl
            if (raw.isNullOrEmpty()) {
                closeSession(view.sessionId, api)
                if (disc) {
                    openFailureReason = view.decision.reason.ifEmpty { "这张光盘没法播放" }
                    return@runCatching null
                }
                return@runCatching directSource(item, origin)
            }
            val url = if (raw.startsWith("http")) raw else origin.trimEnd('/') + raw
            // 服务端也可能直出（源本来就在上限之内）：没有 session_id 就是直出语义
            val direct = view.sessionId == null
            // 时间轴两种语义（服务端 `PlaybackSessionView.timeline`）：
            //  · session = 流从 0 起，「文件时间 = 服务端 start_ms + 播放位置」；
            //  · file    = VOD 预生成列表，分片时间戳就是文件绝对时间——**客户端要自己
            //              seek 到片段起点**（服务端字段说明原话：「前端应把播放器 seek 到这里」）。
            // 原来这里不论哪种都按 0 起播：file 模式下会从片子开头放，还把 fileOffset 重复
            // 计进显示位置（外网片段的失败就卡在这条路上）。
            val fileTimeline = view.timeline == "file"
            val engineStartMs = if (direct || fileTimeline) item.segment.startMs else 0L
            val engineEndMs =
                if (direct || fileTimeline) item.segment.endMs else (item.segment.endMs - item.segment.startMs)
            android.util.Log.i(
                "McReels",
                "会话 ${item.title.name}：时间轴=${view.timeline} 服务端起点=${view.startMs}ms " +
                    "起=${engineStartMs}ms 停=${engineEndMs}ms 会话=${view.sessionId ?: "直出"} " +
                    "硬件=${view.hwBackend ?: "软转"} 源=${view.source?.resolution ?: "?"}·" +
                    "${view.source?.videoCodec ?: "?"}" +
                    (view.source?.hdr?.takeIf { it.isNotBlank() }?.let { "·$it" } ?: "") +
                    "·" + (view.source?.bitRate?.let { "${it / 1000}kbps" } ?: "码率?"),
            )
            ReelSource(
                url = url,
                hls = fileTimeline || url.substringBefore('?').endsWith(".m3u8"),
                playerStartMs = engineStartMs,
                playerEndMs = engineEndMs,
                fileOffsetMs = if (direct || fileTimeline) 0L else item.segment.startMs,
                cacheKey = if (direct) SourceByteCache.key(item.segment.fileId, item.play.sizeBytes, origin) else null,
                audioRef = item.play.audioOrdinal?.let { "embedded:$it" },
                sessionId = view.sessionId,
                sessionApi = api,
            )
        }.getOrElse { error ->
            if (error is CancellationException) throw error
            if (disc) {
                openFailureReason = "光盘片源开不出播放会话：${error.message ?: "未知原因"}"
                return null
            }
            directSource(item, origin)
        }
    }

    private fun directSource(item: ReelItemView, origin: String): ReelSource? {
        val raw = item.play.streamUrl ?: return null
        val url = if (raw.startsWith("http")) raw else origin.trimEnd('/') + raw
        return ReelSource(
            url = url,
            hls = url.substringBefore('?').endsWith(".m3u8"),
            playerStartMs = item.segment.startMs,
            playerEndMs = item.segment.endMs,
            fileOffsetMs = 0L,
            cacheKey = SourceByteCache.key(item.segment.fileId, item.play.sizeBytes, origin),
            audioRef = item.play.audioOrdinal?.let { "embedded:$it" },
        )
    }

    /** 把引擎的监听、位置轮询、字幕挂上（新建的与预起后接手的都走这里） */
    private fun attach(clip: Clip, impressionAt: Long) {
        val engine = clip.engine
        clip.impressionAtMs = impressionAt
        engine.player.addListener(object : Player.Listener {
            override fun onRenderedFirstFrame() = markFirstFrame(clip, impressionAt)

            /** 首帧回调万一漏了（surface 刚挂上就追帧），画面尺寸一到也算出了画 */
            override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) markFirstFrame(clip, impressionAt)
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                if (current !== clip) return
                failMessage = error.message ?: error.errorCodeName
                onEvent(clip.item, "fail", clip.watchedMs, null, positionMs, error.errorCodeName)
            }
        })

        startPolling(clip)

        // 字幕：窗口抽取的那一小段（整轨要 NAS 通读整个文件，等不到）
        val sub = subtitleUrlFor(clip.item)
        if (sub != null) {
            clip.subtitleJob = scope.launch {
                val bytes = withContext(Dispatchers.IO) {
                    runCatching { java.net.URL(sub).openStream().use { it.readBytes() } }.getOrNull()
                } ?: return@launch
                if (current === clip) cues = SubtitleCues.parse(bytes)
            }
        }
    }

    /** 重播重新建立终点与字幕位置监控。 */
    private fun startPolling(clip: Clip) {
        clip.pollJob?.cancel()
        val engine = clip.engine
        clip.pollJob = scope.launch {
            while (isActive) {
                delay(250)
                val enginePos = engine.positionMs()
                positionMs = enginePos + clip.source.fileOffsetMs
                // 状态与引擎对账：任何一处漏置都能在这里收敛（读 playWhenReady——isPlaying() 在
                // 缓冲期会短暂为假，会让暂停键闪一下）
                val want = engine.player.playWhenReady
                if (want != playing && !(ended && !want)) playing = want
                if (clip.hasFirstFrame && clip.startedAtMs > 0) {
                    clip.watchedMs = android.os.SystemClock.elapsedRealtime() - clip.startedAtMs
                }
                if (enginePos >= clip.source.playerEndMs) {
                    engine.setPlaying(false)
                    playing = false
                    ended = true
                    onEvent(clip.item, "complete", clip.watchedMs, null, clip.item.segment.endMs, null)
                    break
                }
            }
        }
    }

    /** 出画：首帧回调与画面尺寸回调共用一个落点 */
    private fun markFirstFrame(clip: Clip, impressionAt: Long) {
        // 旧条目的回调晚到时不认（换条/预起转正后 current 已易主）
        if (current !== clip || clip.hasFirstFrame) return
        clip.hasFirstFrame = true
        clip.startedAtMs = android.os.SystemClock.elapsedRealtime()
        frameReadyId = clip.item.id
        onEvent(
            clip.item, "first_frame", null,
            clip.startedAtMs - impressionAt, clip.item.segment.startMs, null,
        )
        android.util.Log.i(
            "McReels",
            "出画 ${clip.item.title.name}：等 ${clip.startedAtMs - impressionAt}ms",
        )
        val index = pendingItems.indexOfFirst { it.id == clip.item.id }
        if (index >= 0) afterFirstFrame(clip.item, index, pendingItems)
    }

    /** 这一条的字幕窗口文件（服务端给的相对路径，含令牌） */
    private fun subtitleUrlFor(item: ReelItemView): String? {
        val raw = item.play.subtitle?.url ?: return null
        if (raw.startsWith("http")) return raw
        val origin = originProvider() ?: return null
        return origin.trimEnd('/') + raw
    }

    /** 换画质档位：当前这条按新档位重开（同正片播放器换档的语义） */
    fun reloadCurrent() {
        val clip = current ?: return
        val item = clip.item
        val index = pendingItems.indexOfFirst { it.id == item.id }
        leaveCurrent(deferTeardown = false)
        if (index >= 0) settle(item, index, pendingItems)
    }

    /** 出画之后：排字节预取，再排下一条的预起 */
    private fun afterFirstFrame(item: ReelItemView, index: Int, items: List<ReelItemView>) {
        schedulePrefetch(index)
        scheduleStandby(index, items)
    }

    // 当前信息流（预起与预取都按它算「下一条」）
    private var pendingItems: List<ReelItemView> = emptyList()

    fun setItems(items: List<ReelItemView>) {
        pendingItems = items
    }

    /* ---------------- 收藏播放控制 ---------------- */

    fun togglePause() {
        val clip = current ?: return
        if (ended) {
            replay()
            return
        }
        playing = !playing
        clip.engine.setPlaying(playing)
    }

    fun pause() {
        if (!playing) return
        playing = false
        current?.engine?.setPlaying(false)
    }

    /** 回到页面：当前这条从片段起点重新起播（iOS `resume`） */
    fun resume() {
        val clip = current ?: return
        if (playing) return
        clip.engine.seekTo(clip.source.playerStartMs)
        ended = false
        playing = true
        clip.engine.setPlaying(true)
        startPolling(clip)
    }

    fun replay() {
        val clip = current ?: return
        clip.engine.seekTo(clip.source.playerStartMs)
        ended = false
        playing = true
        clip.engine.setPlaying(true)
        clip.startedAtMs = android.os.SystemClock.elapsedRealtime()
        clip.watchedMs = 0L
        startPolling(clip)
    }

    fun seekBy(deltaMs: Long) {
        val clip = current ?: return
        clip.engine.seekBy(deltaMs)
    }

    fun setSpeed(speed: Float) {
        current?.engine?.setSpeed(speed)
    }

    // 从当前位置「看全片」：给正片播放器的起点（原片时间）
    fun filePositionMs(): Long = current?.let { it.engine.positionMs() + it.source.fileOffsetMs } ?: 0L

    /** 当前条的带宽估计（bits/s）：等待态那行「↓ x.x MB/s」用（iOS 同一个读数） */
    fun bandwidthBps(): Long? = current?.engine?.bandwidthBps

    /* ---------------- 收尾 ---------------- */

    /** 页面切走 / 退出：停声、拆引擎、停会话、取消预取 */
    fun release() {
        settleSeq += 1
        settleJob?.cancel()
        settleJob = null
        pendingTeardowns.flush()
        leaveCurrent(deferTeardown = false)
        dropStandby()
        prefetchJobs.values.forEach { it.cancel() }
        prefetchJobs.clear()
        pingJob?.cancel()
        pingJob = null
        stopSession()
    }

    private fun leaveCurrent(deferTeardown: Boolean) {
        val clip = current ?: return
        if (!ended && clip.hasFirstFrame) {
            onEvent(clip.item, "leave", clip.watchedMs, null, positionMs, null)
        }
        pingJob?.cancel()
        pingJob = null
        stopSession()
        current = null
        currentEngine = null
        playing = false
        ended = false
        frameReadyId = null
        cues = emptyList()
        clip.pollJob?.cancel()
        clip.subtitleJob?.cancel()
        val engine = clip.engine
        android.util.Log.i("McReels", "收引擎：${clip.item.title.name}")
        if (deferTeardown) {
            engine.setPlaying(false)
            pendingTeardowns.defer(engine)
        } else {
            engine.release()
        }
    }

    /* ---------------- 字节预取 ---------------- */

    /** 最近一次打开是不是走了转码：预取范围对转码没用（服务端读原文件），对直出才有用 */
    private var lastOpenWasTranscoded = false

    private fun schedulePrefetch(index: Int) {
        // 原来这里只看档位（外网=有转码档就整段跳过），但**服务端会话满时会拒建、客户端回落直出**
        // （实机日志：灵笼在外网就是直出），那种条目跳过预取就要等 2.4 秒才出画。
        // 改成按最近一次的真实落法判断：真在转码才跳过。
        if (lastOpenWasTranscoded) return
        val window = if (isMetered()) 1 else 3
        val targets = pendingItems.drop(index + 1).take(window)
        val keep = targets.map { it.id }.toSet()
        prefetchJobs.entries.filterNot { it.key.substringBefore('#') in keep }.forEach { (key, job) ->
            job.cancel()
            prefetchJobs.remove(key)
        }
        targets.forEachIndexed { position, item ->
            // 下一条全量；再往后只取文件头与索引（起点后几秒动辄几十 MB，滑不到就白下了）
            val full = position == 0
            val key = "${item.id}#${if (full) "full" else "light"}"
            if (prefetchJobs.containsKey(key) || prefetchJobs.containsKey("${item.id}#full")) return@forEachIndexed
            val raw = item.play.streamUrl ?: return@forEachIndexed
            val url = if (raw.startsWith("http")) raw else (originProvider()?.trimEnd('/') ?: return@forEachIndexed) + raw
            val origin = originProvider() ?: return@forEachIndexed
            val cacheKey = SourceByteCache.key(item.segment.fileId, item.play.sizeBytes, origin) ?: return@forEachIndexed
            val ranges = item.play.prefetch
                .filter { full || it.purpose != "start" }
                .map { it.offset to it.length }
            if (ranges.isEmpty()) return@forEachIndexed
            prefetchJobs[key] = scope.launch {
                SourceByteCache.prefetch(context, prefetchUpstream(origin), url, cacheKey, ranges)
            }
        }
    }

    /**
     * 冷起播补两段（iOS `boostColdStart` 的对应物）：这一条**没有任何预取**时就地补——
     * 各开一个请求把「索引」与「起点头 1MB」下进片源字节缓存，和引擎的打开、探测并行；
     * 引擎随后要读的那两段已经在本地。只补原文件直出（转码走服务端，补不进这条缓存），
     * 也只在真冷起播时补（预起/预取过的条目已经在缓存里了）。
     *
     * 不登记进 `prefetchJobs`：那是「下一条」的调度表，`schedulePrefetch` 会把它不在
     * 窗口里的条目取消掉——补当前条的动作要躲开那轮清理。
     */
    private fun boostColdStart(item: ReelItemView, source: ReelSource) {
        val cacheKey = source.cacheKey ?: return
        if (prefetchJobs.containsKey("${item.id}#full") || prefetchJobs.containsKey("${item.id}#light")) return
        val indexRanges = item.play.prefetch.filter { it.purpose == "index" }.map { it.offset to it.length }
        val startRanges = item.play.prefetch
            .filter { it.purpose == "start" }
            .map { it.offset to it.length.coerceAtMost(1L * 1024 * 1024) }
        val ranges = indexRanges + startRanges
        if (ranges.isEmpty()) return
        val origin = originProvider() ?: return
        scope.launch { SourceByteCache.prefetch(context, prefetchUpstream(origin), source.url, cacheKey, ranges) }
    }

    /** 预取用播放同一个连接池与 User-Agent */
    private fun prefetchUpstream(origin: String) = OkHttpDataSource.Factory(mediaHttp(origin)).setUserAgent(BuildInfo.USER_AGENT)

    private fun isMetered(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
            ?: return false
        return cm.isActiveNetworkMetered
    }

    /** 粗算这一条的码率（bps）：整片字节 ÷ 片长；缺一个就返回 null（判不了就当不高） */
    private fun approxBitrateBps(item: ReelItemView): Long? {
        val size = item.play.sizeBytes ?: return null
        val minutes = item.title.runtimeMinutes?.takeIf { it > 0 } ?: return null
        return size * 8 / (minutes * 60L)
    }

    /* ---------------- 预起下一条 ---------------- */

    /**
     * 局域网直出才预起（外网/转码档位下预起会白占一路带宽与解码器）。等 1 秒让开滑动收尾，
     * 且下一条的字节已预取完（本地读，装载很快）。
     *
     * 高码率（>40 Mbps）不预起：这类文件同时开两个解码器容易抢不过（不少机型只有一个 4K
     * 解码实例），内存也紧——字节已经预取好了，滑过去现起引擎也就是几百毫秒。
     */
    private fun scheduleStandby(index: Int, items: List<ReelItemView>) {
        standbyJob?.cancel()
        val next = items.getOrNull(index + 1) ?: return
        if (standby?.item?.id == next.id) return
        // 光盘片源不预起：要服务端开会话换封装，预起会白占一路服务端名额
        if (next.play.disc != null) return
        if (ReelsQuality.effectiveCap(qualityCap, network) != null) return
        if (network == PlaybackNetwork.AWAY) return
        if (approxBitrateBps(next)?.let { it > 40_000_000L } == true) {
            android.util.Log.i("McReels", "跳过高码率预起：${next.title.name}")
            return
        }
        val origin = originProvider() ?: return
        val fullKey = "${next.id}#full"
        standbyJob = scope.launch {
            delay(1000)
            prefetchJobs[fullKey]?.join()
            if (current?.item?.id == next.id) return@launch
            val source = directSource(next, origin) ?: return@launch
            // 预起的那条用小缓冲档（12MB / 4 秒封顶）+ 静音：它只为「滑过去立刻动」存在，
            // 不能跟当前条抢内存（4K 下两条默认缓冲就是 OOM，实机抓到过）
            val engine = newClip(origin, UnifiedExo.Buffer.Standby)
            engine.player.volume = 0f
            val clip = Clip(item = next, engine = engine, source = source)
            standby = clip
            standbyReadyId = null
            engine.player.addListener(object : Player.Listener {
                private fun ready() {
                    if (standby !== clip) return
                    standbyReadyId = clip.item.id
                    // 预起那条在后台就出了画：接上时 settle / adopt 据此直接撤掉封面。它的首帧回调不会再来第二次，
                    // 不在这里记下，接上之后页面会一直垫着封面转圈（画面其实在底下放着）
                    clip.hasFirstFrame = true
                }
                override fun onRenderedFirstFrame() = ready()
                override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                    if (videoSize.width > 0 && videoSize.height > 0) ready()
                }
            })
            // 装载到片段起点停着：不播（滑过去才「播放」）
            engine.open(clipSource(source, autoplay = false))
            android.util.Log.i("McReels", "预起下一条：${next.title.name}")
        }
    }

    private fun dropStandby() {
        standbyJob?.cancel()
        standbyJob = null
        val clip = standby ?: return
        standby = null
        standbyReadyId = null
        android.util.Log.i("McReels", "丢掉预起：${clip.item.title.name}")
        clip.pollJob?.cancel()
        clip.subtitleJob?.cancel()
        clip.engine.release()
    }

    /** 预起好的那条转正当前：把监听与轮询接上（iOS `adopt`） */
    private fun adopt(clip: Clip, item: ReelItemView, impressionAt: Long) {
        current = clip
        currentEngine = clip.engine
        frameReadyId = if (clip.hasFirstFrame) item.id else null
        failMessage = null
        cues = emptyList()
        positionMs = clip.engine.positionMs() + clip.source.fileOffsetMs
        if (clip.hasFirstFrame) {
            clip.startedAtMs = android.os.SystemClock.elapsedRealtime()
            clip.watchedMs = 0L
            onEvent(item, "first_frame", null, null, item.segment.startMs, null)
        }
        // 轮询与字幕在 adopt 之后才需要（预起阶段不产生事件）
        clip.pollJob?.cancel()
        clip.subtitleJob?.cancel()
        attach(clip, impressionAt)
    }

    /* ---------------- 转码会话续命 ---------------- */

    private var liveSessionId: String? = null
    private var liveSessionApi: McApi? = null

    private fun startPing(sessionId: String?, api: McApi?) {
        pingJob?.cancel()
        if (sessionId == null) {
            liveSessionId = null
            return
        }
        liveSessionId = sessionId
        liveSessionApi = api
        pingJob = scope.launch {
            while (isActive) {
                delay(15_000)
                val sessionApi = api ?: continue
                // 三态同 iOS：只有服务端明确说没了才当没了，请求本身失败不算
                runCatching { sessionApi.playbackSessionPing(sessionId) }
            }
        }
    }

    private suspend fun closeSession(id: String?, api: McApi?) {
        if (id == null || api == null) return
        withContext(NonCancellable) {
            withTimeoutOrNull(5_000) {
                runCatching { api.playbackSessionStop(id) }
            }
        }
    }

    private fun stopSession() {
        val id = liveSessionId ?: return
        liveSessionId = null
        val api = liveSessionApi
        liveSessionApi = null
        // 页面销毁后也要关闭远程会话，独立收尾任务限时五秒。
        CoroutineScope(Dispatchers.Main.immediate).launch { closeSession(id, api) }
    }
}
