package io.movieclaw.android.core.playback

import io.movieclaw.android.core.AppScopes

import android.os.SystemClock
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.session.SessionRepository
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * 进播放入口页时把起播要用的连接先连好（iOS `PlaybackPreconnect.warm` 的对应物）。
 *
 * 播放的协商 / 进度 / 心跳与引擎取流都走 `@PlaybackChannel`（独立连接池），
 * 先打一次 `/health` 把 DNS、TCP、TLS 握手都做掉，点播放时省一次往返。
 *
 * 去重 20 秒一次（iOS 同款）；任何失败静默——预热不该有存在感，也不该打扰用户。
 */
@Singleton
class PlaybackPreconnect @Inject constructor(
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
) {
    private val lastAt = AtomicLong(0L)
    private val scope = AppScopes.io("PlaybackPreconnect")

    /** 入口页出现时调用（媒体库首页、条目详情页）。失败/重复调用都无害。 */
    fun warm() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastAt.get() < 20_000L) return
        val origin = sessionRepository.ui.value.origin ?: return
        lastAt.set(now)
        scope.launch {
            runCatching { apiFactory.playbackForOrigin(origin).health() }
        }
    }
}
