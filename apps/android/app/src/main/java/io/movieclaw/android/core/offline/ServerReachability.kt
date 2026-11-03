package io.movieclaw.android.core.offline

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.AppScopes
import io.movieclaw.android.core.network.GeneralChannel
import io.movieclaw.android.core.network.ServerRoutes
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/** 一次请求的结果在「能不能和我家服务器说上话」这件事上算什么证据（docs/design/offline-download.md §2.2） */
enum class ReachabilityOutcome {
    /** 收到了带服务器标记头的响应（任何状态码，含 401、500） */
    SUCCESS,
    /** 明确连不上：拒绝连接、主机不可达、TLS / 证书错误（门户劫持）、不是我家服务器回的 */
    HARD,
    /** 可能只是慢：超时、连接中断、DNS 失败 */
    SOFT,
    /** 不算：主动取消 */
    IGNORED;

    companion object {
        fun of(error: java.io.IOException): ReachabilityOutcome {
            var cause: Throwable? = error
            while (cause != null) {
                when (cause) {
                    // 超时、DNS 失败（信号差的蜂窝网上 DNS 也会超时）都只算「可能只是慢」
                    is java.net.SocketTimeoutException, is java.net.UnknownHostException -> return SOFT
                    is java.net.ConnectException, is java.net.NoRouteToHostException, is javax.net.ssl.SSLException -> return HARD
                }
                cause = cause.cause
            }
            return if (error.message?.contains("Canceled", ignoreCase = true) == true) IGNORED else SOFT
        }

        /** 所有 /api/v1 响应都带 spec 指纹头：没有它的是门户页、反向代理的错误页、外地同 IP 的别的设备 */
        fun of(response: okhttp3.Response): ReachabilityOutcome =
            if (response.header("x-movieclaw-spec-hash") != null) SUCCESS else HARD
    }
}

/**
 * 判不可达的两条规则（满足其一）：连续硬失败至少两次、从第一次起 ≥3 秒；连续三次失败（软的也算）、
 * 从第一个失败请求**发出**起 ≥30 秒（= 服务器已经 30 秒没回过任何话）。中间任何一次成功都要重新建一个（清零）。
 * 纯逻辑，单元测试按时刻喂事件（iOS `ReachabilityJudge` 逐条对应）
 */
class ReachabilityJudge {
    private var streakStart: Long? = null
    private var streakCount = 0
    private var hardStart: Long? = null
    private var hardCount = 0

    /** 记一次失败（毫秒时刻），返回这串失败是否已足以判定「连不上」。[startedAt] 是这个请求发出的时刻 */
    fun failure(hard: Boolean, now: Long, startedAt: Long? = null): Boolean {
        val sent = minOf(startedAt ?: now, now)
        streakStart = minOf(streakStart ?: sent, sent)
        streakCount += 1
        if (hard) {
            if (hardStart == null) hardStart = now
            hardCount += 1
        } else {
            hardStart = null
            hardCount = 0
        }
        val twoHard = hardCount >= 2 && now - (hardStart ?: now) >= HARD_GAP_MS
        val long = streakCount >= SOFT_COUNT && now - (streakStart ?: now) >= SOFT_SPAN_MS
        return twoHard || long
    }

    companion object {
        const val HARD_GAP_MS = 3_000L
        const val SOFT_SPAN_MS = 30_000L
        const val SOFT_COUNT = 3
    }
}

/**
 * 页面请求的旁听口（装在通用 / 播放通道的 OkHttp 上）：把每个发往服务器的请求结果交给可达性，不发额外请求。
 * 不计：SSE（实时通道不装它）、图片、视频字节、离线下载的内容请求。
 */
object ReachabilityTap {
    @Volatile var listener: ((url: okhttp3.HttpUrl, outcome: ReachabilityOutcome, startedAt: Long) -> Unit)? = null

    private fun counts(request: Request): Boolean {
        val path = request.url.encodedPath
        if (!path.contains("/api/v1/")) return false
        if (path.contains("/images/") || path.endsWith("/stream") || path.contains("/offline/files/") ||
            (path.contains("/offline/exports/") && path.endsWith("/content")) || path.contains("/events")
        ) return false
        return request.header("Accept")?.contains("text/event-stream") != true
    }

    val interceptor = Interceptor { chain ->
        val request = chain.request()
        val tap = listener
        if (tap == null || !counts(request)) return@Interceptor chain.proceed(request)
        val startedAt = System.currentTimeMillis()
        try {
            val response = chain.proceed(request)
            tap(request.url, ReachabilityOutcome.of(response), startedAt)
            response
        } catch (e: java.io.IOException) {
            tap(request.url, if (chain.call().isCanceled()) ReachabilityOutcome.IGNORED else ReachabilityOutcome.of(e), startedAt)
            throw e
        }
    }
}

/**
 * 连通性判断与离线模式（docs/design/offline-download.md §2；iOS `ServerReachability` 逐条对应）。
 *
 * 两层分开：**可达性**只回答「现在能不能和我家服务器说上话」；**模式**（在线 / 离线）决定媒体库显示什么。
 * 播放不看模式——本机副本在线时也优先播。
 *
 * 证据：所有页面请求的结果在 OkHttp 出口旁听（[ReachabilityTap]，不发额外请求）；只有出了问题才探测 `/health`
 * （探测本身也走同一个出口，结果照样经旁听进来）；网络通路看系统的默认网络回调。
 *
 * 网慢不会误切：任何一次成功立即清零；只有超时这类软失败时，要连续三次失败、跨度满 30 秒、期间没有任何成功才算不可达；
 * 就算判了不可达，使用途中也不自动切，只在首页提示条上给按钮。
 * 自动进离线只有两种情况：没有网络通路（飞行模式）；冷启动或久别回前台后的 60 秒内判定不可达。
 */
@Singleton
class ServerReachability @Inject constructor(
    @ApplicationContext private val context: Context,
    @GeneralChannel private val client: OkHttpClient,
) {
    enum class Status { REACHABLE, SUSPECT, UNREACHABLE }
    enum class Mode { ONLINE, OFFLINE }

    private val scope = AppScopes.main("ServerReachability")

    private val _status = MutableStateFlow(Status.REACHABLE)
    val status: StateFlow<Status> = _status.asStateFlow()

    private val _mode = MutableStateFlow(Mode.ONLINE)
    val mode: StateFlow<Mode> = _mode.asStateFlow()

    /** 自动回到在线的次数（外壳据此弹「已连上服务器」、补传观看记录、对账下载） */
    private val _reconnects = MutableStateFlow(0)
    val reconnects: StateFlow<Int> = _reconnects.asStateFlow()

    val isOffline: Boolean get() = _mode.value == Mode.OFFLINE

    /** 本机有没有能播的下载（一部都没下过时永远不进离线）：由 [OfflineStore] 设 */
    @Volatile var hasDownloads: () -> Boolean = { false }

    @Volatile private var origin: String? = null
    private var judge = ReachabilityJudge()
    private var probeJob: Job? = null
    private var lastForegroundAt = 0L
    /** 这个时刻之前判定不可达会自动进离线（冷启动、久别回前台后的 60 秒） */
    private var autoWindowUntil = System.currentTimeMillis() + AUTO_WINDOW_MS
    private var backgroundedAt: Long? = null
    private var pathSatisfied = true
    private var unreachableBackoff = 0
    /** 最近一次成功（冷启动检查：3 秒内没有任何请求成功才探一下） */
    private var lastSuccessAt = 0L

    private val probeClient: OkHttpClient by lazy {
        client.newBuilder().callTimeout(5, TimeUnit.SECONDS).connectTimeout(5, TimeUnit.SECONDS).build()
    }

    init {
        pathSatisfied = currentPathSatisfied()
        ReachabilityTap.listener = { url, outcome, startedAt ->
            if (outcome != ReachabilityOutcome.IGNORED) scope.launch { observe(url, outcome, startedAt) }
        }
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        runCatching {
            cm?.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    scope.launch { pathChanged(true) }
                }

                override fun onLost(network: Network) {
                    // 默认网络丢了不一定是全断（Wi-Fi 换蜂窝之间也会先 lost）：以此刻的实况为准
                    scope.launch { pathChanged(currentPathSatisfied()) }
                }
            })
        }
    }

    private fun currentPathSatisfied(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return true
        val caps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) } ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    // ── 输入 ──

    /** 当前服务器（换账号、换服务器时）：之前的证据作废 */
    fun track(origin: String) {
        val normalized = origin.trimEnd('/')
        if (this.origin == normalized) return
        this.origin = normalized
        judge = ReachabilityJudge()
        _status.value = if (pathSatisfied) Status.REACHABLE else Status.UNREACHABLE
        if (_status.value == Status.UNREACHABLE) evaluateMode(pathDown = true)
        launchCheck()
    }

    /** 冷启动 / 久别回前台：3 秒内页面请求都没成功就主动探一下（黑洞时页面请求要 60 秒才报失败） */
    private fun launchCheck() {
        val checkFrom = System.currentTimeMillis()
        val origin = origin ?: return
        scope.launch {
            delay(3_000)
            if (lastSuccessAt < checkFrom && this@ServerReachability.origin == origin) probeOnce()
        }
    }

    private fun matchesCurrent(url: okhttp3.HttpUrl): Boolean {
        val origin = origin ?: return false
        // 当前服务器 = 登录地址或当前选中的入口（内外双地址）
        val bases = listOfNotNull(origin, ServerRoutes.baseFor(origin)) + ServerRoutes.alternates
        return bases.any { base ->
            val b = base.toHttpUrlOrNull() ?: return@any false
            b.host == url.host && b.port == url.port && b.scheme == url.scheme
        }
    }

    private fun observe(url: okhttp3.HttpUrl, outcome: ReachabilityOutcome, startedAt: Long) {
        if (!matchesCurrent(url)) return
        when (outcome) {
            ReachabilityOutcome.SUCCESS -> markReachable()
            ReachabilityOutcome.HARD, ReachabilityOutcome.SOFT -> {
                // 回前台之前发出的请求：App 挂起时系统掐断了连接，回来报的错不说明网络坏了
                if (startedAt < lastForegroundAt) return
                noteFailure(outcome == ReachabilityOutcome.HARD, startedAt)
            }
            ReachabilityOutcome.IGNORED -> Unit
        }
    }

    private fun pathChanged(satisfied: Boolean) {
        val was = pathSatisfied
        pathSatisfied = satisfied
        if (!satisfied) {
            // 没有任何网络通路（飞行模式、没 Wi-Fi 也没蜂窝）：不用探，确定连不上
            setUnreachable(pathDown = true)
        } else if (!was) {
            // 通路回来了：不急着当成在线，探一下
            judge = ReachabilityJudge()
            if (_status.value == Status.UNREACHABLE) _status.value = Status.SUSPECT
            probe(0)
        }
    }

    /** 回到前台：后台超过 10 分钟算「久别回来」，重新给 60 秒自动进离线的窗口 */
    fun noteForeground() {
        lastForegroundAt = System.currentTimeMillis()
        val since = backgroundedAt
        if (since != null && System.currentTimeMillis() - since >= LONG_AWAY_MS) {
            autoWindowUntil = System.currentTimeMillis() + AUTO_WINDOW_MS
            launchCheck()
        }
        backgroundedAt = null
        if (_status.value != Status.REACHABLE) probe(0)
    }

    fun noteBackground() {
        backgroundedAt = System.currentTimeMillis()
        probeJob?.cancel()
        probeJob = null
    }

    // ── 判定 ──

    private fun markReachable() {
        lastSuccessAt = System.currentTimeMillis()
        judge = ReachabilityJudge()
        unreachableBackoff = 0
        probeJob?.cancel()
        probeJob = null
        if (_status.value != Status.REACHABLE) _status.value = Status.REACHABLE
        if (_mode.value == Mode.OFFLINE) {
            setMode(Mode.ONLINE)
            _reconnects.value += 1
        }
    }

    private fun noteFailure(hard: Boolean, startedAt: Long) {
        val conclusive = judge.failure(hard, System.currentTimeMillis(), startedAt)
        if (_status.value == Status.REACHABLE) {
            _status.value = Status.SUSPECT
            probe(0)
        }
        if (conclusive && _status.value != Status.UNREACHABLE) setUnreachable(pathDown = false)
    }

    private fun setUnreachable(pathDown: Boolean) {
        if (_status.value != Status.UNREACHABLE) {
            _status.value = Status.UNREACHABLE
            unreachableBackoff = 0
        }
        evaluateMode(pathDown)
        if (!pathDown) probe(nextBackoff())
    }

    /** 判定为不可达后要不要自动进离线：没有通路（意图明确）或还在自动窗口里；本机一部都没下过就不进 */
    private fun evaluateMode(pathDown: Boolean) {
        if (_mode.value != Mode.ONLINE || _status.value != Status.UNREACHABLE || !hasDownloads()) return
        if (pathDown || !pathSatisfied || System.currentTimeMillis() < autoWindowUntil) setMode(Mode.OFFLINE)
    }

    /** 本机目录读完了 / 有了第一部下载：冷启动时可能先判了不可达、目录后到 */
    fun catalogChanged() {
        scope.launch { evaluateMode(pathDown = !pathSatisfied) }
    }

    private fun setMode(mode: Mode) {
        OfflineImages.offline = mode == Mode.OFFLINE
        _mode.value = mode
    }

    // ── 手动 ──

    /** 首页提示条「看手机上的 N 部」：用户点了才切 */
    fun enterOffline() {
        if (!hasDownloads()) return
        setMode(Mode.OFFLINE)
        if (_status.value == Status.REACHABLE) _status.value = Status.SUSPECT
        probe(nextBackoff())
    }

    /** 离线提示条「重新连接」：立即探一次 */
    fun reconnect() {
        unreachableBackoff = 0
        probe(0)
    }

    // ── 探测 ──

    private fun nextBackoff(): Long {
        val steps = longArrayOf(30_000, 60_000, 120_000, 300_000)
        val delayMs = steps[minOf(unreachableBackoff, steps.size - 1)]
        unreachableBackoff += 1
        return delayMs
    }

    /** `/health`，5 秒超时；结果经旁听回来（探测请求带标记头才算成功） */
    private suspend fun probeOnce() {
        val origin = origin ?: return
        val base = ServerRoutes.baseFor(origin) ?: origin
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            runCatching {
                probeClient.newCall(Request.Builder().url(base.trimEnd('/') + "/api/v1/health").build()).execute().close()
            }
        }
    }

    /** 存疑时每次探完隔 2 秒再探（每次最多 5 秒）；不可达时按 30 秒 → 1 → 2 → 5 分钟退避 */
    private fun probe(delayMs: Long) {
        if (origin == null || !pathSatisfied) return
        probeJob?.cancel()
        probeJob = scope.launch {
            if (delayMs > 0) delay(delayMs)
            while (isActive) {
                if (_status.value == Status.REACHABLE) return@launch
                probeOnce()
                if (!isActive || _status.value == Status.REACHABLE) return@launch
                val wait = if (_status.value == Status.SUSPECT) 2_000L else nextBackoff()
                delay(wait)
            }
        }
    }

    private companion object {
        const val AUTO_WINDOW_MS = 60_000L
        const val LONG_AWAY_MS = 600_000L
    }
}
