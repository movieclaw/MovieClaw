package io.movieclaw.android.core.playback

import android.content.Intent
import android.util.Log
import io.movieclaw.android.BuildConfig
import io.movieclaw.android.core.AppScopes
import io.movieclaw.android.core.network.ServerAddress
import io.movieclaw.android.core.notify.NotifyRouteBus
import io.movieclaw.android.core.session.SessionPhase
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.launch

/**
 * 调试包的直达参数（与 TV 版 `LaunchArgs` 同一套；故障注入实验台 scripts/perf/androidtv_faultlab 用它驱动手机包）。
 * 正式包一概不认。
 *
 *   adb shell am start -f 0x20000000 -n io.movieclaw.android/.MainActivity \
 *     --es mc_server http://10.0.2.2:8830 --es mc_user admin --es mc_pass xxx \
 *     --es mc_route '/play/17/s01e01?t=60' [--es mc_lab 场景名]
 *
 * `-f 0x20000000`（SINGLE_TOP）不能省：MainActivity 是 standard 启动模式，不带它参数到不了已在前台的实例。
 * 播放中再发：`--el mc_seek_ms <文件时间毫秒>`、`--es mc_audio embedded:1`、`--es mc_subtitle embedded:0|off`。
 * `mc_route` 以 `/play/` 开头时起播；其余值在带了账号时先登录再按页面路由打开，不带账号仍按通知路由处理
 * （见 MainActivity）。`--es mc_subscribe tmdb:movie:701` 登录后直接打开该作品的订阅抽屉。
 */
@Singleton
class DebugLaunch @Inject constructor(
    private val repository: SessionRepository,
    private val holder: PlaybackSessionHolder,
) {
    private data class PlayRoute(val mediaItemId: Long, val season: Int, val episode: Int, val startSeconds: Long?)

    private val scope = AppScopes.main("DebugLaunch")

    /** 处理了起播直达就返回 true（调用方不再把 mc_route 当通知路由） */
    fun handle(intent: Intent?): Boolean {
        if (!BuildConfig.DEBUG || intent == null) return false
        val active = (holder.state.value as? PlaybackSessionHolder.State.Playing)?.active?.controller
        intent.getLongExtra("mc_seek_ms", -1).takeIf { it >= 0 }?.let { active?.seekTo(it, exact = true, source = "lab") }
        intent.getStringExtra("mc_audio")?.let { active?.selectAudio(it) }
        intent.getStringExtra("mc_subtitle")?.let { ref -> active?.selectSubtitle(ref.takeIf { it != "off" }) }
        val server = intent.getStringExtra("mc_server")
        val user = intent.getStringExtra("mc_user")
        val pass = intent.getStringExtra("mc_pass")
        val rawRoute = intent.getStringExtra("mc_route")
        val subscribe = intent.getStringExtra("mc_subscribe")
        val route = rawRoute?.let(::playRoute)
        if (route == null) {
            // 非起播直达：带了账号就先登录，再落到页面路由（如 subscription/12）或打开订阅抽屉
            // （`--es mc_subscribe tmdb:movie:701`，iOS `-mcSubscribe` 同款；模拟器验收用）
            if (server == null || user == null || pass == null || (rawRoute == null && subscribe == null)) return false
            scope.launch {
                if (!signedIn(server, user)) {
                    runCatching { repository.login(server, user, pass) }.onFailure {
                        Log.w(TAG, "调试直达登录失败：${it.message}")
                        return@launch
                    }
                }
                rawRoute?.let(NotifyRouteBus::publish)
                subscribe?.let { io.movieclaw.android.feature.subscriptions.SubscribeSheetHost.open(it) }
            }
            return true
        }
        holder.labScenario = intent.getStringExtra("mc_lab").orEmpty()
        scope.launch {
            if (server != null && user != null && pass != null && !signedIn(server, user)) {
                runCatching { repository.login(server, user, pass) }.onFailure {
                    Log.w(TAG, "调试直达登录失败：${it.message}")
                    return@launch
                }
            }
            holder.open(
                PlayTarget(
                    mediaItemId = route.mediaItemId,
                    libraryId = 0,
                    kind = if (route.season > 0) "tv" else "movie",
                    title = "",
                    seasonNumber = route.season,
                    episodeNumber = route.episode,
                    startMs = route.startSeconds?.times(1000),
                ),
            )
            NotifyRouteBus.publish("player")
        }
        return true
    }

    /** 已经用这个账号登着这台服务器就不重登（每登一次服务端多一台「登录设备」） */
    private fun signedIn(server: String, user: String): Boolean {
        val ui = repository.ui.value
        return ui.phase == SessionPhase.READY && ui.session?.username == user &&
            ui.origin == ServerAddress.normalize(server)?.origin
    }

    /** 「/play/17/s01e01?t=60」→ 第 17 部第 1 季第 1 集从 60 秒起 */
    private fun playRoute(path: String): PlayRoute? {
        val match = Regex("""^/play/(\d+)(?:/s(\d+)e(\d+))?(?:\?t=(\d+))?$""").find(path) ?: return null
        val (id, season, episode, start) = match.destructured
        return PlayRoute(id.toLong(), season.toIntOrNull() ?: 0, episode.toIntOrNull() ?: 0, start.toLongOrNull())
    }

    private companion object {
        const val TAG = "DebugLaunch"
    }
}
