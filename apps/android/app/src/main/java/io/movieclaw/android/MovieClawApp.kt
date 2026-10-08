package io.movieclaw.android

import io.movieclaw.android.core.AppScopes

import android.app.Application
import dagger.hilt.android.HiltAndroidApp
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.playback.PlaybackQoe
import io.movieclaw.android.core.session.SessionPhase
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

@HiltAndroidApp
class MovieClawApp : Application() {

    @Inject
    lateinit var imageLoaders: ImageLoaders

    @Inject
    lateinit var qoe: PlaybackQoe

    @Inject
    lateinit var session: SessionRepository

    private val scope = AppScopes.default("MovieClawApp")

    override fun onCreate() {
        super.onCreate()
        // QoE:补报上次异常退出的播放 + 冲刷未发出去的队列(全程 best-effort)
        qoe.recoverAbnormalExit()
        qoe.flushPending()
        // 冷启动那次冲刷可能还没拿到令牌（401 就收工，见 PlaybackQoe.flushPending），
        // 所以会话一进入 READY 再冲一次：不补这一下，未登录期间攒下的报告得等下次冷启动
        scope.launch {
            session.ui.map { it.phase }.distinctUntilChanged().collect { phase ->
                if (phase == SessionPhase.READY) qoe.flushPending()
            }
        }
    }
}
