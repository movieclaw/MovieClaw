package io.movieclaw.android.core.playback

import io.movieclaw.android.core.AppScopes

import android.os.SystemClock
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.session.SessionRepository
import java.net.HttpURLConnection
import java.net.URL
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
 * 两条都连：
 *  · **API 通道**——播放的协商 / 进度 / 心跳走 `@PlaybackChannel`（独立连接池），
 *    先打一次 `/health` 把 DNS、TCP、TLS 握手都做掉，点播放时省一次往返；
 *  · **引擎通道**——Exo 的数据源是 Media3 `DefaultHttpDataSource`（底层是
 *    HttpURLConnection，**不走 OkHttp 的连接池**），所以另开一条 HEAD 请求，把
 *    同一个 host:port 的 DNS 与一条 keep-alive 连接备好；读完不 disconnect，
 *    连接就留在 JVM 的 keep-alive 缓存里，引擎随后的取流能直接复用。
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
            // ① API 通道
            runCatching { apiFactory.playbackForOrigin(origin).health() }
            // ② 引擎通道（DNS + keep-alive）
            runCatching {
                val conn = (URL("${origin.trimEnd('/')}/api/v1/health").openConnection() as HttpURLConnection).apply {
                    requestMethod = "HEAD"
                    connectTimeout = 5_000
                    readTimeout = 5_000
                }
                try {
                    conn.responseCode
                    // 读完（HEAD 无正文）让连接回到 keep-alive 缓存；**不要 disconnect()**，那会把它关掉
                    conn.inputStream?.use { it.readBytes() }
                } catch (_: Exception) {
                    runCatching { conn.disconnect() }
                }
            }
        }
    }
}
