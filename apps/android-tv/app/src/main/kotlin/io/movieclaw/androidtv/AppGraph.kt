package io.movieclaw.androidtv

import android.app.Application
import android.os.Build
import android.provider.Settings
import io.movieclaw.androidtv.core.network.ClientIdentity
import io.movieclaw.androidtv.core.network.OkHttpTransport
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.generated.McApi
import io.movieclaw.androidtv.core.session.Account
import io.movieclaw.androidtv.core.session.AccountStore
import io.movieclaw.androidtv.core.session.LoginService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * 手写的依赖图（docs/design/androidtv-app.md §1 不上 Hilt）。登录前的东西在这里，
 * 和账号有关的在 [AccountSession] 里——切换账号就整个换掉。
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
        .readTimeout(30, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().header("User-Agent", identity.userAgent).build())
        }
        .build()

    val accounts = AccountStore(app)

    val login = LoginService(
        http = http,
        store = accounts,
        identity = identity,
        // 「设置 → 设备名称」里用户起的名字（如「客厅电视」），Android 7.1 以下没有这一项
        deviceName = (if (Build.VERSION.SDK_INT >= 25) Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME) else null)
            ?: Build.MODEL,
    )

    private val _session = MutableStateFlow(accounts.current?.let(::sessionFor))
    val session: StateFlow<AccountSession?> = _session.asStateFlow()

    fun activate(account: Account) {
        accounts.select(account.id)
        _session.value = sessionFor(account)
    }

    fun signOut() {
        val current = _session.value ?: return
        accounts.remove(current.account.id)
        _session.value = null
    }

    private fun sessionFor(account: Account): AccountSession? {
        val token = accounts.token(account.id) ?: return null
        return AccountSession(account, token, http)
    }
}

/** 一个已登录账号的一切：服务器地址、带令牌的接口。 */
class AccountSession(val account: Account, val token: String, val http: OkHttpClient) {
    val server: ServerAddress = account.server
    val api = McApi(OkHttpTransport(server.apiBase, http) { token })
}
