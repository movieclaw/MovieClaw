package io.movieclaw.android.core.push

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import dagger.hilt.android.AndroidEntryPoint
import io.movieclaw.android.MainActivity
import io.movieclaw.android.core.AppScopes
import io.movieclaw.android.core.model.PushAckBody
import io.movieclaw.android.core.model.PushRegistrationBody
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.LiveChannel
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.identityClient
import io.movieclaw.android.core.notify.Notifier
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.core.session.TokenVault
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import retrofit2.HttpException

/*
 * 实时通知（保持连接）：不依赖谷歌 / 厂商推送，前台服务一直连着当前账号的 MovieClaw 服务器
 * （GET /push/me/stream，服务端 cloud-push.md §4.1），收到就发本地通知、记游标、确认。
 *
 * 前台服务类型选 remoteMessaging：它是 Android 14 给「保持消息连接、把消息转到本机」的类型，
 * 没有 dataSync 在 Android 15 上「每天最多 6 小时」的超时，也允许开机广播里启动
 * （Android 15 禁止开机广播拉起 dataSync 等类型）；specialUse 也能用，但要额外写用途声明，
 * 语义上不如 remoteMessaging 贴切。
 */

private val Context.pushStreamStore by preferencesDataStore(name = "mc_push_stream")

/** 开关、每个账号的游标、最近一次确认连接健康的时间（跨进程，NotifyWorker 也要读）、常驻通知显示什么 */
class PushStreamPrefs(private val context: Context) {
    suspend fun enabled(): Boolean = context.pushStreamStore.data.first()[KEY_ENABLED] ?: false

    suspend fun setEnabled(on: Boolean) {
        context.pushStreamStore.edit { it[KEY_ENABLED] = on }
    }

    suspend fun cursor(key: String): Long = context.pushStreamStore.data.first()[longPreferencesKey(key)] ?: 0L

    suspend fun saveCursor(key: String, id: Long) {
        context.pushStreamStore.edit { prefs ->
            val k = longPreferencesKey(key)
            if ((prefs[k] ?: 0L) < id) prefs[k] = id
        }
    }

    suspend fun healthyAt(): Long = context.pushStreamStore.data.first()[KEY_HEALTHY_AT] ?: 0L

    suspend fun markHealthy(now: Long = System.currentTimeMillis()) {
        context.pushStreamStore.edit { it[KEY_HEALTHY_AT] = now }
    }

    val ongoingMode: Flow<OngoingMode> = context.pushStreamStore.data.map { OngoingMode.of(it[KEY_ONGOING_MODE]) }

    /** 自定义文字（空 = 用 [OngoingNotice.DEFAULT_TEMPLATE]） */
    val ongoingTemplate: Flow<String> = context.pushStreamStore.data.map { it[KEY_ONGOING_TEMPLATE].orEmpty() }

    suspend fun setOngoing(mode: OngoingMode, template: String) {
        context.pushStreamStore.edit {
            it[KEY_ONGOING_MODE] = mode.key
            it[KEY_ONGOING_TEMPLATE] = template
        }
    }

    companion object {
        private val KEY_ENABLED = booleanPreferencesKey("enabled")
        private val KEY_HEALTHY_AT = longPreferencesKey("healthy_at")
        private val KEY_ONGOING_MODE = stringPreferencesKey("ongoing_mode")
        private val KEY_ONGOING_TEMPLATE = stringPreferencesKey("ongoing_template")

        /** 游标按「服务器 + 账号」分开：发件箱 id 只在同一台服务器的同一台设备上单调 */
        fun cursorKey(origin: String, username: String) = "cursor:$origin|$username"
    }
}

/** 连接状态（设置页显示；NotifyWorker 据此判断要不要再发轮询通知） */
sealed interface PushStreamStatus {
    data object Off : PushStreamStatus
    data object Connecting : PushStreamStatus
    data class Connected(val sinceMs: Long) : PushStreamStatus
    data class Retrying(val reason: String, val retryAtMs: Long) : PushStreamStatus
}

object PushStreamState {
    private val _status = MutableStateFlow<PushStreamStatus>(PushStreamStatus.Off)
    val status: StateFlow<PushStreamStatus> = _status.asStateFlow()

    internal fun set(value: PushStreamStatus) {
        _status.value = value
    }

    /** 当前连接上最近一帧状态快照；换连接时清空（不拿上一条连接的旧数据充数） */
    private val _snapshot = MutableStateFlow<StreamStatusSnapshot?>(null)
    val snapshot: StateFlow<StreamStatusSnapshot?> = _snapshot.asStateFlow()

    internal fun setSnapshot(value: StreamStatusSnapshot?) {
        _snapshot.value = value
    }

    /** 服务端协议里实时通知设备的「通道名」（PushRegistrationView.channel_name） */
    const val STREAM_CHANNEL = "实时连接"

    /** 实时通知断开超过这么久，本机轮询重新发通知（兜底） */
    const val POLL_FALLBACK_MS = 60 * 60 * 1000L

    /**
     * 实时通知正常时轮询不再弹通知（避免同一件事响两次）：开着、且此刻连着或最近一小时内连上过。
     * 断开期间的服务器通知重连后会补发，所以短暂断线不需要轮询顶上。
     */
    suspend fun coversPolling(context: Context, now: Long = System.currentTimeMillis()): Boolean {
        val prefs = PushStreamPrefs(context)
        if (!prefs.enabled()) return false
        return status.value is PushStreamStatus.Connected || now - prefs.healthyAt() < POLL_FALLBACK_MS
    }
}

/** 启停入口：设置页开关、开机广播、App 启动、保活任务都走这里 */
object PushStreamController {
    fun start(context: Context): Boolean = runCatching {
        ContextCompat.startForegroundService(context, Intent(context, PushStreamService::class.java))
    }.onFailure {
        // Android 12+ 后台不允许起前台服务（没加入电池优化白名单时）：等下次打开 App / 保活任务
        android.util.Log.w("McPushStream", "启动实时通知失败：${it.message}")
    }.isSuccess

    fun stop(context: Context) {
        context.stopService(Intent(context, PushStreamService::class.java))
        PushStreamState.set(PushStreamStatus.Off)
    }

    suspend fun startIfEnabled(context: Context) {
        if (!PushStreamPrefs(context).enabled()) return
        PushStreamKeepAlive.schedule(context)
        if (!PushStreamService.running) start(context)
    }
}

/** 服务器版本不支持实时通知（登记后没认成实时连接设备） */
class StreamUnsupportedException : Exception("服务器版本不支持实时通知，请先更新 MovieClaw 服务器")

/** 网络切换、账号切换打断了当前连接：立即重连，不算失败 */
private class StreamInterrupted : CancellationException("实时连接被打断")

@AndroidEntryPoint
class PushStreamService : Service() {

    @Inject lateinit var session: SessionRepository
    @Inject lateinit var apiFactory: ApiFactory
    @Inject @LiveChannel lateinit var liveClient: OkHttpClient
    @Inject lateinit var json: Json

    private val scope = AppScopes.io("PushStream")
    private var loop: Job? = null
    private val wakeups = Channel<Unit>(Channel.CONFLATED)
    @Volatile private var connection: Job? = null
    @Volatile private var connectionNetwork: Network? = null
    @Volatile private var currentNetwork: Network? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var shown: OngoingView? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        registerNetworkCallback()
        scope.launch {
            // 登录、切换账号：立刻按新账号重连
            // （正在连着的连接由 connectOnce 里的 watcher 发现身份变了自己断开）
            session.ui.map { it.origin to it.phase }.distinctUntilChanged().drop(1).collect {
                wakeups.trySend(Unit)
            }
        }
        scope.launch {
            val prefs = PushStreamPrefs(this@PushStreamService)
            combine(
                PushStreamState.status,
                PushStreamState.snapshot,
                prefs.ongoingMode,
                prefs.ongoingTemplate,
            ) { status, snapshot, mode, template -> OngoingNotice.build(mode, template, status, snapshot) }
                .collect(::updateForeground)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!enterForeground()) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (loop?.isActive != true) loop = scope.launch { run() } else wakeups.trySend(Unit)
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        networkCallback?.let { cb ->
            runCatching { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb) }
        }
        scope.cancel()
        PushStreamState.set(PushStreamStatus.Off)
        PushStreamState.setSnapshot(null)
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // 连接循环
    // ------------------------------------------------------------------

    private suspend fun run() {
        val prefs = PushStreamPrefs(this)
        if (!prefs.enabled()) {
            stopSelf()
            return
        }
        // 开机、保活任务拉起的进程里界面没跑过：自己恢复登录态（已恢复过就是空操作）
        runCatching { session.boot() }
        val backoff = Backoff()
        var registeredFor: TokenVault.Identity? = null
        while (currentCoroutineContext().isActive) {
            val origin = session.ui.value.origin
            val identity = origin?.let(session::requestIdentity)
            if (identity == null) {
                PushStreamState.set(PushStreamStatus.Retrying("还没有登录账号", 0))
                waitWake(60_000)
                continue
            }
            PushStreamState.set(PushStreamStatus.Connecting)
            val attempt = scope.async {
                if (registeredFor != identity) {
                    register(identity)
                    registeredFor = identity
                }
                connectOnce(identity, prefs, backoff)
            }
            connection = attempt
            try {
                val lastedMs = attempt.await()
                // 服务器到点正常结束（单条连接最长一小时）：马上带游标重连；
                // 连上就被关（代理不支持长连接等）不能空转，按失败退避
                if (lastedMs >= 10_000L) {
                    delay(300)
                } else {
                    val wait = backoff.next()
                    PushStreamState.set(PushStreamStatus.Retrying("连接被提前关闭", System.currentTimeMillis() + wait))
                    waitWake(wait)
                }
            } catch (e: CancellationException) {
                if (!currentCoroutineContext().isActive) throw e
                delay(300) // 被网络 / 账号切换打断：稍等片刻立即重连
            } catch (e: Throwable) {
                if (e is StreamHttpException && e.code == 409) registeredFor = null
                val wait = when {
                    e is StreamUnsupportedException -> 30 * 60_000L
                    e is HttpException && e.code() == 401 -> 10 * 60_000L
                    e is StreamHttpException && e.code == 401 -> 10 * 60_000L
                    else -> backoff.next()
                }
                PushStreamState.set(PushStreamStatus.Retrying(reasonOf(e), System.currentTimeMillis() + wait))
                waitWake(wait)
            } finally {
                connection = null
            }
        }
    }

    private suspend fun waitWake(ms: Long) {
        withTimeoutOrNull(ms) { wakeups.receive() }
    }

    private suspend fun register(identity: TokenVault.Identity) {
        val api = apiFactory.forIdentity(identity.origin, identity)
        val permission = if (NotificationManagerCompat.from(this).areNotificationsEnabled()) "authorized" else "denied"
        val view = api.pushRegister(PushRegistrationBody(permission = permission, stream = true)).dataOrThrow()
        if (view.channelName != PushStreamState.STREAM_CHANNEL) throw StreamUnsupportedException()
    }

    /** 一次连接，服务器正常结束时返回连着的时长（毫秒） */
    private suspend fun connectOnce(identity: TokenVault.Identity, prefs: PushStreamPrefs, backoff: Backoff): Long = coroutineScope {
        val origin = identity.origin
        val base = apiFactory.apiBaseOf(origin) ?: "$origin/api/v1"
        // 心跳 25 秒一次：90 秒没有任何字节就当连接已死（NAT 掐断、换网），断开重连
        val client = identityClient(liveClient, identity).newBuilder()
            .readTimeout(90, TimeUnit.SECONDS)
            .build()
        val api = apiFactory.forIdentity(origin, identity)
        val key = PushStreamPrefs.cursorKey(origin, identity.username)
        var cursor = prefs.cursor(key)
        PushStreamState.setSnapshot(null)
        val outer = this
        val watcher = launch {
            // 切换 / 退出账号：断开，外层循环按新账号重连
            session.ui.first { !session.isCurrentIdentity(identity) }
            outer.cancel(StreamInterrupted())
        }
        val ticker = launch {
            while (true) {
                delay(5 * 60_000L)
                if (PushStreamState.status.value is PushStreamStatus.Connected) prefs.markHealthy()
            }
        }
        connectionNetwork = currentNetwork
        var openedAt = 0L
        try {
            PushStreamConnection.open(client, base, cursor, json).collect { signal ->
                when (signal) {
                    StreamSignal.Opened -> {
                        openedAt = System.currentTimeMillis()
                        backoff.reset()
                        prefs.markHealthy()
                        PushStreamState.set(PushStreamStatus.Connected(System.currentTimeMillis()))
                    }
                    is StreamSignal.Status -> PushStreamState.setSnapshot(signal.snapshot)
                    is StreamSignal.Notification -> {
                        val item = signal.item
                        if (item.id <= cursor) return@collect // 已经显示过（重连时的重复）
                        if (!StreamNotifications.isStale(item, System.currentTimeMillis() / 1000)) show(item)
                        cursor = item.id
                        prefs.saveCursor(key, cursor)
                        prefs.markHealthy()
                        val upTo = cursor
                        // 确认失败也不要紧：游标已存，下次连接带 since 不会重复显示，下一条再一并确认
                        launch { runCatching { api.pushAck(PushAckBody(upTo)).dataOrThrow() } }
                    }
                }
            }
        } finally {
            watcher.cancel()
            ticker.cancel()
        }
        if (openedAt == 0L) 0L else System.currentTimeMillis() - openedAt
    }

    private fun show(item: StreamNotification) {
        val landing = StreamNotifications.landingFor(item.deeplink)
        val text = listOfNotNull(item.subtitle, item.body).filter { it.isNotBlank() }.joinToString("\n")
        Notifier.post(
            this,
            StreamNotifications.notificationId(item),
            StreamNotifications.channelFor(item.event),
            item.title,
            text,
            landing.tab.orEmpty(),
            route = landing.route,
            silent = StreamNotifications.silent(item),
        )
    }

    private fun reasonOf(e: Throwable): String = when (e) {
        is StreamUnsupportedException -> e.message.orEmpty()
        is StreamHttpException -> if (e.code == 401) "登录已失效，请重新登录" else e.message.orEmpty()
        is HttpException -> if (e.code() == 401) "登录已失效，请重新登录" else "服务器返回 HTTP ${e.code()}"
        is java.io.IOException -> "连不上服务器"
        else -> e.message ?: "连接失败"
    }

    // ------------------------------------------------------------------
    // 网络变化：换网立即重连，断网立即放弃当前连接（不干等 90 秒读超时）
    // ------------------------------------------------------------------

    private fun registerNetworkCallback() {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                currentNetwork = network
                val active = connection
                if (active != null && connectionNetwork != null && connectionNetwork != network) {
                    active.cancel(StreamInterrupted())
                }
                if (PushStreamState.status.value !is PushStreamStatus.Connected) wakeups.trySend(Unit)
            }

            override fun onLost(network: Network) {
                if (currentNetwork == network) currentNetwork = null
                if (connectionNetwork == network) connection?.cancel(StreamInterrupted())
            }
        }
        runCatching { manager.registerDefaultNetworkCallback(callback) }.onSuccess { networkCallback = callback }
    }

    // ------------------------------------------------------------------
    // 前台通知：自己一个低重要性渠道，静音、不显示角标；内容见 OngoingNotice
    // ------------------------------------------------------------------

    private fun enterForeground(): Boolean = runCatching {
        val view = shown ?: OngoingNotice.build(OngoingMode.SMART, "", PushStreamState.status.value, null)
        val notification = buildForeground(view)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(FOREGROUND_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else {
            startForeground(FOREGROUND_ID, notification)
        }
    }.onFailure { android.util.Log.w("McPushStream", "无法进入前台：${it.message}") }.isSuccess

    private fun updateForeground(view: OngoingView) {
        if (view == shown || !running) return
        shown = view
        runCatching {
            getSystemService(NotificationManager::class.java)?.notify(FOREGROUND_ID, buildForeground(view))
        }
    }

    private fun buildForeground(view: OngoingView): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager != null && manager.getNotificationChannel(CH_STREAM) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CH_STREAM, "实时通知连接", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "保持与服务器的连接，这条常驻通知可以在系统设置里隐藏"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }
        return ongoingNotification(this, view).build()
    }

    companion object {
        const val CH_STREAM = "mc_stream"
        private const val FOREGROUND_ID = 0x4D43_5354 // "MCST"

        /** 常驻通知（只用原生模板）：标题 / 正文、进度条、展开列表、「打开下载」 */
        internal fun ongoingNotification(context: Context, view: OngoingView): Notification.Builder {
            fun open(requestCode: Int, extra: Pair<String, String>) = PendingIntent.getActivity(
                context,
                requestCode,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra(extra.first, extra.second)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val downloads = open(FOREGROUND_ID + 1, "mc_tab" to Notifier.TAB_ACTIVITY)
            val builder = Notification.Builder(context, CH_STREAM)
                .setSmallIcon(io.movieclaw.android.R.drawable.ic_mc_notify)
                .setContentTitle(view.title)
                .setContentText(view.text)
                .setOngoing(true)
                .setShowWhen(false)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                // 自己单独一组：不给系统和其他通知自动合并，否则要点两次才展开、按钮也被收起
                .setGroup("mc_stream_ongoing")
                .setContentIntent(if (view.openDownloads) downloads else open(FOREGROUND_ID, "mc_route" to "settings/NOTIFY"))
            if (view.progress != null) builder.setProgress(100, view.progress, view.indeterminate)
            if (view.lines.isNotEmpty()) {
                builder.setStyle(
                    Notification.InboxStyle().setBigContentTitle(view.title).also { style -> view.lines.forEach(style::addLine) },
                )
            }
            if (view.openDownloads) {
                builder.addAction(
                    Notification.Action.Builder(
                        android.graphics.drawable.Icon.createWithResource(context, io.movieclaw.android.R.drawable.ic_mc_notify),
                        "打开下载",
                        downloads,
                    ).build(),
                )
            }
            return builder
        }

        /** 本进程里服务是否在跑（保活任务据此决定要不要拉起） */
        @Volatile var running: Boolean = false
            private set
    }
}

/** 开机 / 应用更新后：开着实时通知就拉起服务 */
class PushStreamBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in BOOT_ACTIONS) return
        val pending = goAsync()
        AppScopes.io("PushStreamBoot").launch {
            try {
                PushStreamController.startIfEnabled(context.applicationContext)
            } finally {
                pending.finish()
            }
        }
    }

    private companion object {
        val BOOT_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            // 部分国产系统的快速开机
            "android.intent.action.QUICKBOOT_POWERON",
        )
    }
}

/** 保活：每 15 分钟看一眼，服务被系统杀掉了就拉起来（后台拉起需要电池优化白名单） */
object PushStreamKeepAlive {
    private const val WORK_NAME = "mc-push-stream-keepalive"

    fun schedule(context: Context) {
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<PushStreamKeepAliveWorker>(15, TimeUnit.MINUTES).build(),
        )
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
    }
}

class PushStreamKeepAliveWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        if (PushStreamPrefs(applicationContext).enabled() && !PushStreamService.running) {
            PushStreamController.start(applicationContext)
        }
        return Result.success()
    }
}
