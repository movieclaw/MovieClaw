package io.movieclaw.android.core.offline

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.movieclaw.android.MainActivity
import io.movieclaw.android.core.session.SessionPhase
import io.movieclaw.android.core.session.SessionRepository
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * 离线下载作业（iOS 后台下载会话的安卓对应物）：长时作业 + 前台通知，退到后台、锁屏照常下；
 * 网络策略放在约束上——只用 Wi-Fi（不计费网络）或任何网络（「使用蜂窝网络下载」），没有合适的网络时系统自动等。
 * 作业本体是 [OfflineDownloader.drive]；还剩到点才重试的失败时，按最早的时刻再排一次。
 */
class OfflineDownloadWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {

    private val entry by lazy {
        dagger.hilt.android.EntryPointAccessors.fromApplication(applicationContext, OfflineEntry::class.java)
    }

    override suspend fun doWork(): Result {
        val downloader = entry.downloader()
        val store = entry.store()
        // 后台拉起的进程（开机、到点重试、等到 Wi-Fi、被系统杀掉后重跑）里界面没跑过：先恢复登录态（同 NotifyWorker，
        // 已恢复过就是空操作），外壳（OfflineCoordinator）据此认领这个账号的本机存档。认领完才知道要下什么，
        // 不等的话 drive 拿不到账号就空跑结束，下载一直停到用户下次打开 App
        val sessions = entry.sessionRepository()
        runCatching { sessions.boot() }
        if (sessions.ui.value.phase == SessionPhase.READY) {
            withTimeoutOrNull(ADOPT_TIMEOUT_MS) { store.state.first { it.loaded } }
        }
        // 前台通知：从后台（到点重试）起跑时系统可能不让进前台，那就照普通作业跑
        runCatching { setForeground(foregroundInfo(store)) }
        val next = downloader.drive { runCatching { setForeground(foregroundInfo(store)) } }
        if (next != null) {
            val delay = (next - System.currentTimeMillis()).coerceAtLeast(0)
            schedule(applicationContext, entry.prefs().allowCellular.value, replace = false, delayMs = delay, append = true)
        }
        return Result.success()
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo(entry.store())

    private fun foregroundInfo(store: OfflineStore): ForegroundInfo {
        ensureChannel(applicationContext)
        val state = store.state.value
        val active = store.activeUnits(state)
        val summary = OfflineDownloadSummary.make(active, store.speeds.value, state.items.mapValues { it.value.title })
        val intent = PendingIntent.getActivity(
            applicationContext, 0,
            Intent(applicationContext, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("mc_route", "downloads")
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(summary.title.ifEmpty { "下载" })
            .setContentText(summary.detail)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(intent)
            .setProgress(100, ((summary.fraction ?: 0.0) * 100).toInt(), summary.fraction == null)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val WORK = "movieclaw-offline-downloads"
        private const val CHANNEL = "offline_downloads"
        private const val NOTIFICATION_ID = 0x0FF1
        /** 等本机存档认领完的上限：不认得实例号时要先问一次服务器（/health） */
        private const val ADOPT_TIMEOUT_MS = 15_000L

        /**
         * 确保作业排着：[replace] = 改了网络设置（停掉正在跑的、按新约束重排）；
         * [append] = 作业自己收尾时为剩下的活再排一次（排在自己后面，自己结束后才开始）
         */
        fun schedule(context: Context, allowCellular: Boolean, replace: Boolean, delayMs: Long = 0, append: Boolean = false) {
            val request = OneTimeWorkRequestBuilder<OfflineDownloadWorker>()
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(if (allowCellular) NetworkType.CONNECTED else NetworkType.UNMETERED)
                        .build(),
                )
                .apply { if (delayMs > 0) setInitialDelay(delayMs, TimeUnit.MILLISECONDS) }
                .build()
            val policy = when {
                replace -> ExistingWorkPolicy.REPLACE
                append -> ExistingWorkPolicy.APPEND_OR_REPLACE
                else -> ExistingWorkPolicy.KEEP
            }
            WorkManager.getInstance(context).enqueueUniqueWork(WORK, policy, request)
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL, "下载", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "下载影片到手机的进度"
                        setShowBadge(false)
                    },
                )
            }
        }
    }
}

/** 作业取单例的口子（Worker 不在 Hilt 注入图里） */
@dagger.hilt.EntryPoint
@dagger.hilt.InstallIn(dagger.hilt.components.SingletonComponent::class)
interface OfflineEntry {
    fun downloader(): OfflineDownloader
    fun store(): OfflineStore
    fun prefs(): OfflinePrefs
    fun reachability(): ServerReachability
    fun apiFactory(): io.movieclaw.android.core.network.ApiFactory
    fun sessionRepository(): SessionRepository
}
