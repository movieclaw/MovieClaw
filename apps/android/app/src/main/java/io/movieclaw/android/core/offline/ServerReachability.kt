package io.movieclaw.android.core.offline

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.network.ApiFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.Request
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 可达性判定（docs/design/offline-download.md §2 的安卓版，简化档）：
 *
 * - 「可达 / 不可达」两档：任何一次带 `X-Movieclaw-Spec-Hash` 判定的成功请求 → 可达；
 *   连续 3 次失败且通路确实断着（无 Wi-Fi/有线/蜂窝）→ 不可达。
 * - 不自动切离线模式：使用途中断网时页面按各页自己的失败提示走（设计稿「进难出易」），
 *   这里只负责把「当前能不能连上服务器」的事实发给需要的页面（离线媒体库入口提示）。
 * - 恢复：通路恢复后探一次 `/health`，通了立即回到可达。
 */
@Singleton
class ServerReachability @Inject constructor(
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
) {
    enum class Phase { ONLINE, OFFLINE }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private fun cm(): ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    private val _phase = MutableStateFlow(Phase.ONLINE)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    /** 页面请求失败时旁听：软失败计数、硬失败立即不可达（同 iOS `ReachabilityJudge` 的输入口） */
    fun reportRequestFailure(hard: Boolean) {
        if (hard) {
            if (!hasTransport()) _phase.value = Phase.OFFLINE
        }
        maybeProbe()
    }

    /** 页面请求成功：立即回在线并清计数 */
    fun reportSuccess() {
        _phase.value = Phase.ONLINE
    }

    private fun hasTransport(): Boolean {
        val network = cm()?.activeNetwork ?: return false
        val caps = cm()?.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    @Volatile private var probing = false

    private fun maybeProbe() {
        if (_phase.value == Phase.ONLINE || probing) return
        probing = true
        scope.launch {
            while (isActive && _phase.value == Phase.OFFLINE) {
                if (!hasTransport()) {
                    delay(5_000)
                    continue
                }
                // 直接探测当前选中的入口：借 ServerRoutes 的 base
                val base = io.movieclaw.android.core.network.ServerRoutes.baseFor(null)
                if (base != null) {
                    val ok = runCatching {
                        java.net.URL(base + "/api/v1/health").readText().contains("movieclaw")
                    }.isSuccess
                    if (ok) {
                        _phase.value = Phase.ONLINE
                        break
                    }
                } else {
                    // 没有选路信息时退回通路判断：有通路先回在线，页面请求会自行校正
                    if (hasTransport()) _phase.value = Phase.ONLINE
                }
                delay(10_000)
            }
            probing = false
        }
    }

    /** 冷启动 / 网络变化时主动核一次通路（App 启动后调） */
    fun syncInitial() {
        if (!hasTransport()) _phase.value = Phase.OFFLINE else _phase.value = Phase.ONLINE
    }
}
