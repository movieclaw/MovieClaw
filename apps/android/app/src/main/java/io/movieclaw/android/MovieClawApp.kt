package io.movieclaw.android

import io.movieclaw.android.core.AppScopes

import android.app.Application
import dagger.hilt.android.HiltAndroidApp
import io.movieclaw.android.core.designsystem.ImageLoaders
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

@HiltAndroidApp
class MovieClawApp : Application() {

    @Inject
    lateinit var imageLoaders: ImageLoaders

    private val scope = AppScopes.default("MovieClawApp")

    override fun onCreate() {
        super.onCreate()
        // 播放质量记录（含上次异常退出的补报）由统一引擎在下一次起播时补发（core PlaybackReportStore）
        // 实时通知（core/push）：用户开着就随 App 启动拉起前台服务（开机由 PushStreamBootReceiver 拉起）
        scope.launch { io.movieclaw.android.core.push.PushStreamController.startIfEnabled(this@MovieClawApp) }
    }
}
