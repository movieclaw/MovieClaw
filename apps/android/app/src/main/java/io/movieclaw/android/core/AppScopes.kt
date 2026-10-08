package io.movieclaw.android.core

import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * 应用级协程作用域的兜底：任何未捕获异常只记录、不杀进程。
 *
 * 起因（实机）：切账号后在蜂窝网络下连不上内网服务器地址，某个 `launch` 里的
 * `SocketTimeoutException` 没人兜 → 进程直接死（三次连崩：23:37:00 / 23:37:43 / 23:38:16，
 * 全是 `StandaloneCoroutine{Cancelling}, Dispatchers.Main.immediate`）。
 * 网络不通是**正常工况**（没 WiFi、信号差、服务器重启、VPN 抖动），不该让 App 退出；
 * 这层兜底保证这类异常最多丢一次刷新，同时把现场打进日志（`McCrash:`），
 * 便于回头定位那一处漏兜的调用点（找到后仍应就地补 try/runCatching，这层只是保险）。
 */
object AppScopes {
    private fun handler(name: String) = CoroutineExceptionHandler { _, e ->
        android.util.Log.e(
            "McCrash",
            "未捕获异常（已兜住，进程保留）[$name] ${e::class.java.simpleName}: ${e.message}",
            e,
        )
    }

    fun main(name: String) = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate + handler(name))

    fun io(name: String) = CoroutineScope(SupervisorJob() + Dispatchers.IO + handler(name))

    fun default(name: String) = CoroutineScope(SupervisorJob() + Dispatchers.Default + handler(name))
}
