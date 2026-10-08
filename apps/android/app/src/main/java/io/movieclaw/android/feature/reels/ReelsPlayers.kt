@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package io.movieclaw.android.feature.reels

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.Player
import io.movieclaw.android.core.api.McApi
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.playback.PlaybackNetwork
import io.movieclaw.android.core.model.PlaybackSessionRequest
import io.movieclaw.android.core.model.ReelItemView
import io.movieclaw.android.core.playback.BufferProfile
import io.movieclaw.android.core.playback.DeviceCapability
import io.movieclaw.android.core.playback.EngineSource
import io.movieclaw.android.core.playback.ExoEngine
import io.movieclaw.android.core.playback.IsoBridge
import io.movieclaw.android.core.playback.PlayerEngine
import io.movieclaw.android.core.playback.ReelsQuality
import io.movieclaw.android.core.playback.SourceByteCache
import io.movieclaw.android.core.playback.SubtitleCues
import io.movieclaw.android.core.playback.mpv.MpvEngine
import io.movieclaw.android.core.playback.mpv.MpvNative
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
    /** 转码会话 id；直出为 null。离开这条时要停掉，播放中每 15 秒续命 */
    val sessionId: String? = null,
    /** 光盘交付方式（服务端 `play.disc`）；非空 = 这条是光盘镜像，url 已是 IsoBridge 的本地流 */
    val disc: String? = null,
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
 * 为什么播放器由这里（而不是每一页）持有：预起的那条属于**下一条**，而它的引擎是在
 * 当前这条还活着的时候建的——放在页面里就会随当前页被滑走而一起销毁。这里按节点换手，
 * 页面只负责把画面挂上去。
 */
class ReelsPlayers(
    private val context: Context,
    private val apiFactory: ApiFactory,
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

    /** 画面该挂哪个引擎：当前条的引擎（页面用 state 读它，换引擎会重组重绑；光盘镜像是 mpv） */
    var currentEngine by mutableStateOf<PlayerEngine?>(null)
        private set

    /* ---------------- 内部 ---------------- */

    private class Clip(
        val item: ReelItemView,
        val engine: PlayerEngine,
        val source: ReelSource,
        var pollJob: Job? = null,
        var subtitleJob: Job? = null,
        var hasFirstFrame: Boolean = false,
        var startedAtMs: Long = 0L,
        var watchedMs: Long = 0L,
        /** 换条时刻（出画事件的分母）：存进 Clip 是因为重播/继续会重开轮询，
         *  而轮询里要判 mpv 的「位置一动就算出画」（attach 之后才有值） */
        var impressionAtMs: Long = 0L,
    )

    /** 换条序号：连滑两条时把先落地那次作废（见 settle 注释） */
    private var settleSeq = 0
    private var settleJob: Job? = null
    // 延后释放的引擎池：Exo 与 mpv（光盘镜像）都走这里统一收（泛型取 PlayerEngine）
    private val pendingTeardowns = DeferredReelReleases<PlayerEngine>(scope) { it.release() }

    private var current: Clip? = null
    private var standby: Clip? = null
    private var standbyJob: Job? = null
    private var pingJob: Job? = null

    /** 预取任务：键 = "条目id#full|light"（同 iOS） */
    private val prefetchJobs = mutableMapOf<String, Job>()

    private var qualityCap: Int = ReelsQuality.AUTO
    private var network: PlaybackNetwork = PlaybackNetwork.UNKNOWN

    /** openSource 失败的原因：光盘类读不出来要说清是哪一步，不能都说成「缺少取流地址」 */
    private var openFailureReason: String? = null

    fun setQuality(cap: Int) {
        qualityCap = cap
    }

    fun setNetwork(n: PlaybackNetwork) {
        network = n
    }

    fun currentItemId(): String? = current?.item?.id

    fun engineFor(itemId: String): PlayerEngine? {
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
        // 逐段计时（与播放器页同一套，日志 `McPlayer: 起播分段`）：点/滑到这条 → 决策+会话 → 引擎 → 首帧
        io.movieclaw.android.core.playback.PlaybackStartupTrace.start()
        onEvent(item, "impression", null, null, item.segment.startMs, null)

        val ready = standby?.takeIf { it.item.id == item.id && it.source.playerStartMs >= 0 }
        if (ready != null) {
            standby = null
            standbyReadyId = null
            adopt(ready, item, impressionAt)
            ready.engine.setPlaying(true)
            // 预起只可能是 Exo（光盘镜像不预起，见 scheduleStandby）：还原音量
            (ready.engine as? ExoEngine)?.player?.volume = 1f
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
                // 失败原因分开报：光盘类读不出来要说清是哪一步（"缺少取流地址"会把镜像说错）
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
                    // 作废的这次可能已经开过镜像的原生会话：顺手关掉，别留一个没人读的盘
                    if (source.disc != null) IsoBridge.closeOwner(this@ReelsPlayers)
                    return@launch
                }
                io.movieclaw.android.core.playback.PlaybackStartupTrace.mark("决策+会话")
                lastOpenWasTranscoded = source.sessionId != null
                // 光盘镜像是 mpv 的活：Exo 读不了盘内 192 字节包的 m2ts（正片链路同一条判据，
                // 实测 Exo 会白等 5 秒才失败回退）；其余照旧 Exo（硬解最优）
                val engine: PlayerEngine =
                    if (source.disc == "image") MpvEngine(context)
                    else ExoEngine(context, BufferProfile.Normal)
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
                engine.open(engineSource(source, item), emptyList())
                // **这里必须把播放状态置真**：引擎是 autoplay 起播的，漏了这一步就会
                // 「画面在放、状态却是暂停」——一进页面就顶着暂停键，全屏里点一下还弹不起来
                // （只有「接上预起」那条分支置过，这条漏了）
                playing = true
                startPing(source.sessionId, source.sessionApi)
            }
        }
        schedulePrefetch(index)
    }

    private fun engineSource(source: ReelSource, item: ReelItemView, autoplay: Boolean = true) = EngineSource(
        url = source.url,
        hls = source.hls,
        startPositionMs = source.playerStartMs,
        autoplay = autoplay,
        initialAudioRef = source.audioRef,
        cacheKey = source.cacheKey,
        title = item.title.name,
        subtitle = item.title.episode?.name,
        artworkUrl = item.title.posterUrl,
    )

    /**
     * 这一条要放什么：直出（局域网默认）还是转码（外网 / 限了画质）。
     * 转码走正片的 `POST /playback/sessions`，`startMs` 直接给片段起点——服务端从那儿切。
     */
    private suspend fun openSource(item: ReelItemView): ReelSource? {
        val origin = originProvider() ?: return null
        openFailureReason = null
        // 光盘片源（v0.32 起「大图预告」与「片段」也放开原盘 / 镜像 / DVD / TS / AVI）：
        // 按交付方式装载，与正片同一套（docs/design/disc-direct-play.md）。不进下面的会话
        // 协商——限了画质也救不了光盘（服务端读不出盘内结构，转不了码），协商只会白跑一趟
        item.play.disc?.let { return discSource(item, origin) }
        val cap = ReelsQuality.effectiveCap(qualityCap, network)
        if (cap == null) return directSource(item, origin)
        return runCatching {
            val api = apiFactory.forOrigin(origin)
            val view = api.startPlaybackSession(
                PlaybackSessionRequest(
                    fileId = item.segment.fileId.takeIf { it > 0 },
                    mediaItemId = item.title.mediaItemId.takeIf { it > 0 },
                    seasonNumber = item.title.episode?.season ?: 0,
                    episodeNumber = item.title.episode?.episode ?: 0,
                    // 限了上限就不报 universal：报了服务端会把原文件直通回来，上限形同虚设
                    capability = DeviceCapability.probe(context, universal = false),
                    maxHeight = cap,
                    deviceId = runCatching { deviceIdProvider() }.getOrNull(),
                    startMs = item.segment.startMs,
                    client = "android",
                )
            ).dataOrThrow().let { it }
            val raw = if (view.timeline == "file") (view.masterUrl ?: view.streamUrl) else view.streamUrl
            if (raw.isNullOrEmpty()) {
                closeSession(view.sessionId, api)
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

    /**
     * 光盘片源：按 `play.disc` 的交付方式装载（与正片同一套）。
     *
     *  · `image`（光盘镜像）：走 IsoBridge——服务端只按 Range 供原字节，盘内结构（UDF →
     *    BDMV/STREAM 正片 m2ts）在本机读出来，交给 mpv（只有它能放这种盘流）；
     *  · `folder`（原盘目录 BDMV / VIDEO_TS）：本机内核读不了远端目录结构（与申报的
     *    `discFolder=false` 同一条边界），明确失败、换下一条，而不是拿原字节硬播；
     *  · 其余值：按普通文件回落（新服务端字段出现新值时不至于整条播不了）。
     *
     * 服务端对光盘不给预取范围、也不给音轨/字幕序号（盘内轨清单它读不出）——
     * 音轨交给 mpv 按盘上默认轨起播，字幕本条不开（服务端同款注释）。
     */
    private suspend fun discSource(item: ReelItemView, origin: String): ReelSource? {
        when (item.play.disc) {
            "image" -> Unit
            "folder" -> {
                openFailureReason = "原盘目录暂不支持播放"
                return null
            }
            else -> return directSource(item, origin)
        }
        if (!MpvNative.available) {
            openFailureReason = "本机内核不支持光盘镜像"
            return null
        }
        val raw = item.play.streamUrl ?: return null
        val url = if (raw.startsWith("http")) raw else origin.trimEnd('/') + raw
        // 开卷 + 扫目录是几十次远端小读（真机几百毫秒到秒级），必须离开主线程；
        // owner 传本播放器实例：旧会话的异步收尾只关自己开的卷，不会误关换条后新开的盘
        val local = withContext(Dispatchers.IO) { IsoBridge.open(url, this@ReelsPlayers) }
        if (local == null) {
            openFailureReason = "光盘镜像读取失败"
            return null
        }
        android.util.Log.i("McReels", "光盘镜像装载：${item.title.name} → $local")
        return ReelSource(
            url = local,
            hls = false,
            playerStartMs = item.segment.startMs,
            playerEndMs = item.segment.endMs,
            fileOffsetMs = 0L,
            // 镜像的字节由 IsoBridge 的原生预读窗口管，不进片源字节缓存（与正片一致）
            cacheKey = null,
            audioRef = item.play.audioOrdinal?.let { "embedded:$it" },
            disc = "image",
        )
    }

    /** 把引擎的监听、位置轮询、字幕挂上（新建的与预起后接手的都走这里） */
    private fun attach(clip: Clip, impressionAt: Long) {
        val engine = clip.engine
        clip.impressionAtMs = impressionAt
        // Exo 有首帧/错误回调；mpv（光盘镜像）没有——首帧靠位置轮询（与正片链路
        // 同一判据：PlaybackController「firstFrameMs == null && positionMs() > 0」）
        if (engine is ExoEngine) {
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
        }

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
                if (engine is MpvEngine && !clip.hasFirstFrame && enginePos > 0) {
                    markFirstFrame(clip, clip.impressionAtMs)
                }
                positionMs = enginePos + clip.source.fileOffsetMs
                // 状态与引擎对账：任何一处漏置都能在这里收敛（Exo 读 playWhenReady——它在
                // 缓冲期会短暂为假，读 isPlaying() 会让暂停键闪一下；mpv 读 isPlaying()，
                // 它读的就是我们设的 pause 属性，同义）
                val want = when (engine) {
                    is ExoEngine -> runCatching { engine.player.playWhenReady }.getOrDefault(playing)
                    else -> engine.isPlaying()
                }
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

    /** 出画：Exo 的首帧回调与 mpv 的位置轮询两条路共用一个落点 */
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
        io.movieclaw.android.core.playback.PlaybackStartupTrace.mark("首帧")
        io.movieclaw.android.core.playback.PlaybackStartupTrace.finish()
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

    /** 当前条的带宽估计（bits/s）：等待态那行「↓ x.x MB/s」用（iOS 同一个读数）；mpv（光盘）没有这个读数 */
    fun bandwidthBps(): Long? = (current?.engine as? ExoEngine)?.bandwidthBps

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
        // 光盘镜像：IsoBridge 的原生会话是全局的，必须**同步**关——换条是先 leave（关）再
        // open（开），延迟到 500ms 后拆引擎时再关会把下一条刚开的镜像一起关掉；
        // closeOwner 只在当前卷还是本播放器开的那种才关（旧会话的异步收尾不误关新盘）
        if (clip.source.disc != null) IsoBridge.closeOwner(this@ReelsPlayers)
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
                SourceByteCache.prefetch(context, url, cacheKey, ranges)
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
        scope.launch { SourceByteCache.prefetch(context, source.url, cacheKey, ranges) }
    }

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
        // 光盘片源不预起：装载要开卷（IsoBridge 秒级）、解码器也只有 mpv 那份，白占
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
            val engine = ExoEngine(context, BufferProfile.Compact)
            engine.player.volume = 0f
            val clip = Clip(item = next, engine = engine, source = source)
            standby = clip
            standbyReadyId = null
            engine.player.addListener(object : Player.Listener {
                private fun ready() {
                    if (standby === clip) standbyReadyId = clip.item.id
                }
                override fun onRenderedFirstFrame() = ready()
                override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                    if (videoSize.width > 0 && videoSize.height > 0) ready()
                }
            })
            // 装载到片段起点停着：不播（滑过去才「播放」）
            engine.open(engineSource(source, next, autoplay = false), emptyList())
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
                runCatching { sessionApi.pingPlaybackSession(sessionId) }
            }
        }
    }

    private suspend fun closeSession(id: String?, api: McApi?) {
        if (id == null || api == null) return
        withContext(NonCancellable) {
            withTimeoutOrNull(5_000) {
                runCatching { api.stopPlaybackSession(id) }
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
