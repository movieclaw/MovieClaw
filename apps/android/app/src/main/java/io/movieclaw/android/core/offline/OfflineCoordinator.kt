package io.movieclaw.android.core.offline

import android.app.Activity
import android.app.Application
import android.os.Bundle
import io.movieclaw.android.core.AppScopes
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.session.SessionPhase
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * 离线下载的外壳接线（iOS 在 `MainTabView` / `AppModel` 里做的那几件事）：
 * - 登录 / 切账号：可达性跟踪这台服务器，本机目录换成这个账号的存档；退出时清空内存（存档留在盘上）；
 * - 回前台 / 退后台：可达性重新给证据窗口；回前台对一次下载的账、补传观看记录；
 * - 自动回到在线：再认一次服务器（离线冷启动时还不知道实例号）、对账、补传、刷新存档的展示数据。
 */
@Singleton
class OfflineCoordinator @Inject constructor(
    private val sessions: SessionRepository,
    private val store: OfflineStore,
    private val downloader: OfflineDownloader,
    private val reachability: ServerReachability,
    private val apiFactory: ApiFactory,
    private val feedback: io.movieclaw.android.core.designsystem.FeedbackBus,
) {
    private val scope = AppScopes.main("OfflineCoordinator")
    private var started = false
    private var startedActivities = 0

    fun start(app: Application) {
        if (started) return
        started = true
        reachability.hasDownloads = { store.downloadedItemIds.value.isNotEmpty() }
        store.onCatalogChanged = { reachability.catalogChanged() }

        scope.launch {
            sessions.ui
                .map { ui -> if (ui.phase == SessionPhase.READY) ui.origin?.let { o -> ui.session?.username?.let { o to it } } else null }
                .distinctUntilChanged()
                .collect { identity ->
                    if (identity == null) {
                        store.reset()
                        return@collect
                    }
                    val (origin, username) = identity
                    reachability.track(origin)
                    if (store.owner?.username != username || store.owner?.origin != origin.trimEnd('/')) store.reset()
                    store.adopt(origin, username)
                    afterOnline()
                }
        }
        // 自动回到在线：外壳弹「已连上服务器」由界面做，这里补齐数据
        scope.launch {
            reachability.reconnects.drop(1).collect {
                feedback.success("已连上服务器")
                afterOnline(readopt = true)
            }
        }
        // 冷启动离线、后来第一次连上（状态从存疑 / 不可达回到可达）：同样补齐
        scope.launch {
            reachability.status.map { it == ServerReachability.Status.REACHABLE }.distinctUntilChanged().drop(1)
                .filter { it }.collect { afterOnline(readopt = true) }
        }

        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                if (startedActivities++ == 0) {
                    reachability.noteForeground()
                    downloader.kick("foreground")
                    flushViewings()
                }
            }

            override fun onActivityStopped(activity: Activity) {
                if (--startedActivities == 0) reachability.noteBackground()
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }

    private fun afterOnline(readopt: Boolean = false) {
        val ui = sessions.ui.value
        val origin = ui.origin ?: return
        val username = ui.session?.username ?: return
        scope.launch {
            if (readopt) store.readoptIfNeeded(origin, username)
            downloader.kick("reconnected")
            flushViewings()
            store.launchIO { store.refreshArchivedMetadataIfNeeded { reachability.isOffline } }
        }
    }

    fun flushViewings() {
        val key = store.key ?: return
        val origin = store.owner?.origin ?: return
        if (reachability.isOffline) return
        OfflineViewingUploader.flush(apiFactory.forOrigin(origin), key)
    }
}
