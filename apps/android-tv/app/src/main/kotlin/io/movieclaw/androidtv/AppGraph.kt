package io.movieclaw.androidtv

import android.app.Application
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.compositionLocalOf
import io.movieclaw.androidtv.core.model.generated.SessionView
import io.movieclaw.androidtv.core.network.ClientIdentity
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.generated.McApi
import io.movieclaw.androidtv.core.session.AppModel
import io.movieclaw.androidtv.core.session.LocalStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * 手写的依赖图（docs/design/androidtv-app.md §1 不上 Hilt）。和账号有关的都从 [model] 现取，
 * 切换账号时界面整棵重建（AppRoot 按账号做 key）。
 */
class AppGraph(app: Application) {
    val identity = ClientIdentity(
        appVersion = BuildConfig.VERSION_NAME,
        buildNumber = BuildConfig.VERSION_CODE.toLong(),
        model = Build.MODEL,
        osVersion = Build.VERSION.RELEASE,
    )

    /** 比页面活得久的协程：退出播放时的上报要在页面销毁后发完 */
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().header("User-Agent", identity.userAgent).build())
        }
        .build()

    val store = LocalStore(app)

    /** 「设置 → 设备名称」里用户起的名字（如「客厅电视」），Android 7.1 以下没有这一项 */
    val deviceName: String =
        (if (Build.VERSION.SDK_INT >= 25) Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME) else null)
            ?: Build.MODEL

    val model = AppModel(store, http, identity, deviceName)

    /** 系统首页「继续观看」 */
    val watchNext = io.movieclaw.androidtv.system.WatchNextPublisher(app, http)

    /** 待处理的深链（「继续观看」点进来、或冷启动带的），主界面取走后清空 */
    val deepLinks = kotlinx.coroutines.flow.MutableStateFlow<io.movieclaw.androidtv.system.DeepLink?>(null)
}

/** 一个已登录账号的一切：服务器、令牌、带令牌的接口、会话（权限）。 */
class AccountSession(val server: ServerAddress, val token: String, val session: SessionView, val api: McApi) {
    val key: String get() = "$server#${session.username}"
}

val LocalGraph = compositionLocalOf<AppGraph> { error("LocalGraph 未提供") }
val LocalSession = compositionLocalOf<AccountSession> { error("LocalSession 未提供") }
