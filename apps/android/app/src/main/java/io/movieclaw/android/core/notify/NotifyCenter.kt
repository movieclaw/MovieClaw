package io.movieclaw.android.core.notify

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import io.movieclaw.android.MainActivity
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.first

/*
 * 系统通知（纯客户端，服务端零改动）。
 *
 * 服务端没有面向成员的通用事件流（只有 agent / jobs / search 三条 SSE），也没有 APNs 那套推送通道
 * （那条链路要服务端配云中继），所以这里走 Android 自己的办法：WorkManager 每 15 分钟（系统允许的
 * 最短周期）拉一次现有接口（下载任务 / 今日预告 / 最近入库），与本机存的上一次快照**差分**，
 * 只在状态真的翻转时发本地通知。App 没开也能收到，代价是最长 15 分钟延迟、且依赖系统调度。
 *
 * 与 iOS 的差别要如实说：iOS 走 APNs 是即时推送（且有 4 类事件的服务端语义），
 * 这里是本机轮询；通知文案沿用两端同源的那套状态词（下载中 / 整理中 / 等待资源 / 新入库…）。
 */

private val Context.notifyStore by preferencesDataStore(name = "mc_notify")

/** 通知的本机设置与上一次快照（键名自用，不进服务端） */
class NotifyPrefs(private val context: Context) {
    data class Snapshot(
        val enabled: Boolean = false,
        val download: Boolean = true,
        val arrival: Boolean = true,
        val subscription: Boolean = true,
        val task: Boolean = true,
        /** 上一次抓到的状态（差分基线）：见 [encode] */
        val baseline: String = "",
    )

    suspend fun read(): Snapshot = context.notifyStore.data.first().let { p ->
        Snapshot(
            enabled = p[KEY_ENABLED] ?: false,
            download = p[KEY_DOWNLOAD] ?: true,
            arrival = p[KEY_ARRIVAL] ?: true,
            subscription = p[KEY_SUBSCRIPTION] ?: true,
            task = p[KEY_TASK] ?: true,
            baseline = p[KEY_BASELINE] ?: "",
        )
    }

    suspend fun setEnabled(on: Boolean) = context.notifyStore.edit { it[KEY_ENABLED] = on }
    suspend fun setChannel(download: Boolean, arrival: Boolean, subscription: Boolean, task: Boolean) =
        context.notifyStore.edit {
            it[KEY_DOWNLOAD] = download
            it[KEY_ARRIVAL] = arrival
            it[KEY_SUBSCRIPTION] = subscription
            it[KEY_TASK] = task
        }

    suspend fun saveBaseline(value: String) = context.notifyStore.edit { it[KEY_BASELINE] = value }

    private companion object {
        val KEY_ENABLED = booleanPreferencesKey("enabled")
        val KEY_DOWNLOAD = booleanPreferencesKey("channel_download")
        val KEY_ARRIVAL = booleanPreferencesKey("channel_arrival")
        val KEY_SUBSCRIPTION = booleanPreferencesKey("channel_subscription")
        val KEY_TASK = booleanPreferencesKey("channel_task")
        val KEY_BASELINE = stringPreferencesKey("baseline")
    }
}

/** 差分基线编解码：`d<任务id>:<状态>,…|j<作业id>:<状态>,…|a<订阅id>:<季>:<集>,…|r<订阅id>:<季>:<集>,…` 四段 */
object NotifySnapshot {
    data class State(
        val downloads: Map<String, String> = emptyMap(),
        val jobs: Map<String, String> = emptyMap(),
        val arrivals: Set<String> = emptySet(),
        val recent: Set<String> = emptySet(),
    )

    fun encode(state: State): String = listOf(
        state.downloads.entries.joinToString(",") { "${it.key}:${it.value}" },
        state.jobs.entries.joinToString(",") { "${it.key}:${it.value}" },
        state.arrivals.joinToString(","),
        state.recent.joinToString(","),
    ).joinToString("|")

    private fun decodePairs(raw: String?): Map<String, String> =
        raw.orEmpty().split(',').mapNotNull { item ->
            val i = item.lastIndexOf(':')
            if (i <= 0) null else item.substring(0, i) to item.substring(i + 1)
        }.toMap()

    fun decode(raw: String?): State {
        if (raw.isNullOrEmpty()) return State()
        val parts = raw.split('|')
        return State(
            downloads = decodePairs(parts.getOrNull(0)),
            jobs = decodePairs(parts.getOrNull(1)),
            arrivals = parts.getOrNull(2).orEmpty().split(',').filter { it.isNotEmpty() }.toSet(),
            recent = parts.getOrNull(3).orEmpty().split(',').filter { it.isNotEmpty() }.toSet(),
        )
    }
}

/** 通知点按要直接进的那一条（`item/{库}/{条目}` 或 `subscription/{id}`）；由 MainActivity 投递、AppNav 消费 */
object NotifyRouteBus {
    private val _requested = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    val requested: kotlinx.coroutines.flow.StateFlow<String?> = _requested

    fun publish(route: String) {
        _requested.value = route
    }

    fun consume() {
        _requested.value = null
    }
}

/** 通知渠道与投递（4 条，与设置页的 4 个开关一一对应） */
object Notifier {
    const val CH_DOWNLOAD = "mc_download"
    const val CH_ARRIVAL = "mc_arrival"
    const val CH_SUBSCRIPTION = "mc_subscription"
    const val CH_TASK = "mc_task"

    /** 点按落到哪个底栏页（activity / subscriptions） */
    const val TAB_ACTIVITY = "ACTIVITY"
    const val TAB_SUBSCRIPTIONS = "SUBSCRIPTIONS"

    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        listOf(
            Triple(CH_DOWNLOAD, "下载", "下载完成或失败"),
            Triple(CH_ARRIVAL, "入库", "整理完成、新内容进库"),
            Triple(CH_SUBSCRIPTION, "订阅更新", "今天有可看的"),
            Triple(CH_TASK, "系统与任务", "后台任务的提醒"),
        ).forEach { (id, name, desc) ->
            if (manager.getNotificationChannel(id) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(id, name, NotificationManager.IMPORTANCE_DEFAULT).apply { description = desc },
                )
            }
        }
    }

    @Suppress("MissingPermission")
    fun post(context: Context, id: Int, channel: String, title: String, text: String, tab: String, route: String? = null) {
        ensureChannels(context)
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("mc_tab", tab)
            // 有具体落点就直接进那一条（item/{库}/{条目} 或 subscription/{id}）
            route?.let { putExtra("mc_route", it) }
        }
        val pending = PendingIntent.getActivity(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, channel)
            .setSmallIcon(io.movieclaw.android.R.drawable.ic_mc_notify)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        NotificationManagerCompat.from(context).notify(id, notification)
    }
}

/** 周期检查的排程：开启时装，关闭时撤（15 分钟是系统允许的最短周期） */
object NotifyScheduler {
    private const val WORK_NAME = "mc-notify-poll"

    fun schedule(context: Context) {
        val request = PeriodicWorkRequestBuilder<NotifyWorker>(15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
    }
}

/** 差分检查：只在「上一次没有、这一次有了」时发通知；首次运行只落基线，不轰炸 */
class NotifyWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val prefs = NotifyPrefs(applicationContext)
        val settings = prefs.read()
        if (!settings.enabled) return Result.success()
        val entry = EntryPointAccessors.fromApplication(applicationContext, NotifyEntryPoint::class.java)
        val origin = entry.sessionRepository().ui.value.origin ?: return Result.success()
        val api = entry.apiFactory().forOrigin(origin)

        val tasks = runCatching { api.downloadTasks().dataOrThrow().items }.getOrDefault(emptyList())
        val jobs = runCatching { api.jobs().dataOrThrow().items }.getOrDefault(emptyList())
        val arrivals = runCatching { api.todayArrivalsFull().dataOrThrow() }.getOrDefault(emptyList())
        val recent = runCatching { api.recentArrivals().dataOrThrow() }.getOrDefault(emptyList())
        // 订阅表只为拼「直接进那一条」的落点（item/{库}/{条目}）用，拉不到就退回订阅详情
        val subs = runCatching { api.subscriptions().dataOrThrow() }.getOrDefault(emptyList())
        val subsById = subs.associateBy { it.id }

        val now = NotifySnapshot.State(
            downloads = tasks.filter { it.infoHash.isNotBlank() || it.id.isNotBlank() }
                .associate { it.id to it.state },
            jobs = jobs.associate { it.id to it.status },
            arrivals = arrivals.filter { it.daysAhead == 0 }
                .map { "${it.subscriptionId}:${it.seasonNumber}:${it.episodeNumber}" }.toSet(),
            recent = recent.map { "${it.subscriptionId}:${it.seasonNumber}:${it.episodeNumber}" }.toSet(),
        )
        val before = NotifySnapshot.decode(settings.baseline)
        val firstRun = settings.baseline.isEmpty()

        /** 有具体作品就落到条目详情，否则退回订阅详情 */
        fun routeFor(subscriptionId: Long): String {
            val sub = subsById[subscriptionId]
            val libraryId = sub?.libraryId ?: 0L
            val mediaItemId = sub?.media?.mediaItemId ?: 0L
            return if (libraryId > 0 && mediaItemId > 0) "item/$libraryId/$mediaItemId" else "subscription/$subscriptionId"
        }

        if (!firstRun) {
            if (settings.download || settings.task) {
                tasks.forEach { task ->
                    val was = before.downloads[task.id]
                    val terminal = task.state == "completed" || task.state == "error" || task.state == "missing"
                    if (was != null && was != task.state && terminal) {
                        val title = if (task.state == "completed") "下载完成" else "下载失败"
                        val text = task.mediaTitle ?: task.name ?: "下载任务"
                        Notifier.post(
                            applicationContext,
                            ("dl:" + task.id).hashCode(),
                            if (task.state == "completed") Notifier.CH_DOWNLOAD else Notifier.CH_TASK,
                            title, text, Notifier.TAB_ACTIVITY,
                        )
                    }
                }
            }
            if (settings.task) {
                // 后台作业（扫描 / 洗版 / 入库…）：failed=真失败，blocked=必须人工处理（服务端语义，都不是「重试中」）
                jobs.forEach { job ->
                    val was = before.jobs[job.id]
                    val bad = job.status == "failed" || job.status == "blocked"
                    if (was != null && was != job.status && bad) {
                        val text = listOfNotNull(
                            job.subject?.takeIf { it.isNotBlank() },
                            job.jobType.takeIf { it.isNotBlank() },
                            job.error?.message?.takeIf { it.isNotBlank() },
                        ).joinToString(" · ")
                        Notifier.post(
                            applicationContext,
                            ("job:" + job.id).hashCode(),
                            Notifier.CH_TASK,
                            if (job.status == "failed") "后台任务失败" else "后台任务需要处理",
                            text.ifBlank { "在活动页查看详情" },
                            Notifier.TAB_ACTIVITY,
                        )
                    }
                }
            }
            if (settings.arrival) {
                (now.recent - before.recent).take(3).forEach { key ->
                    val id = key.substringBefore(':').toLongOrNull() ?: return@forEach
                    val title = recent.firstOrNull { it.subscriptionId == id }?.media?.title ?: "新内容入库"
                    Notifier.post(
                        applicationContext,
                        ("arr:" + key).hashCode(),
                        Notifier.CH_ARRIVAL,
                        "已入库", title, Notifier.TAB_ACTIVITY, route = routeFor(id),
                    )
                }
            }
            if (settings.subscription) {
                (now.arrivals - before.arrivals).take(3).forEach { key ->
                    val id = key.substringBefore(':').toLongOrNull() ?: return@forEach
                    val title = arrivals.firstOrNull { it.subscriptionId == id }?.mediaTitle ?: "今天更新"
                    Notifier.post(
                        applicationContext,
                        ("today:" + key).hashCode(),
                        Notifier.CH_SUBSCRIPTION,
                        "今天有可看的", title, Notifier.TAB_SUBSCRIPTIONS, route = routeFor(id),
                    )
                }
            }
        }

        prefs.saveBaseline(NotifySnapshot.encode(now))
        return Result.success()
    }
}

/** Worker 跑在 Hilt 之外，用 EntryPoint 取容器里的单例 */
@EntryPoint
@InstallIn(SingletonComponent::class)
interface NotifyEntryPoint {
    fun apiFactory(): ApiFactory
    fun sessionRepository(): SessionRepository
}
