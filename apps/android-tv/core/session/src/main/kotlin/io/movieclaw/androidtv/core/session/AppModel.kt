package io.movieclaw.androidtv.core.session

import io.movieclaw.androidtv.core.model.generated.DeviceClientInfo
import io.movieclaw.androidtv.core.model.generated.DeviceLoginRequest
import io.movieclaw.androidtv.core.model.generated.SessionView
import io.movieclaw.androidtv.core.network.ApiException
import io.movieclaw.androidtv.core.network.ClientIdentity
import io.movieclaw.androidtv.core.network.OkHttpTransport
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.UnreachableException
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * 登录 / 切换状态机：逐项对齐 Apple 端 `Shared/App/AppModel.swift`。
 *
 * - 冷启动有令牌和会话快照就直接进主界面（不转圈），随后在后台 `/auth/me` 确认身份；
 * - 「谁在看」切换 = 换一枚令牌，可以跨服务器，不用密码；
 * - 退出登录在服务端注销这台设备（连不上就记下来以后补发），同服务器还有别的账号就自动切过去；
 * - 当前令牌收到 401：删掉它，回登录页并预填用户名。
 */
class AppModel(
    private val store: LocalStore,
    private val http: OkHttpClient,
    private val identity: ClientIdentity,
    private val deviceName: String,
) {
    sealed interface Phase {
        data object Launching : Phase
        data object NeedsServer : Phase
        data object NeedsSetup : Phase
        data object NeedsLogin : Phase
        data object ChooseAccount : Phase
        data object Unreachable : Phase
        data class Ready(val session: SessionView) : Phase
    }

    private val _phase = MutableStateFlow<Phase>(Phase.Launching)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    /** 当前服务器；为空表示本机还没登录过任何服务器 */
    var server: ServerAddress? = store.currentOrigin?.let(ServerAddress::parse)
        private set
    /** 当前账号的设备令牌 */
    var token: String? = null
        private set

    private val _savedServers = MutableStateFlow(store.savedServers)
    val savedServers: StateFlow<List<SavedServer>> = _savedServers.asStateFlow()

    /** 连不上服务器的原因：「连不上」卡片的说明 */
    var launchError: String? = null
        private set
    /** 登录过期的账号：登录卡片据此预填用户名、提示「登录已失效」 */
    var expiredUsername: String? = null
        private set

    private var needsRevalidation = false

    val session: SessionView? get() = (_phase.value as? Phase.Ready)?.session

    /** 别的服务器上已登录的账号（当前服务器除外）：欢迎页「选择账号」用 */
    val accountsOnOtherServers: List<SavedAccount>
        get() = _savedServers.value.filter { it.origin != server?.toString() }
            .flatMap { saved -> saved.accounts.map { SavedAccount(saved.address, it) } }

    /** 某台服务器上全部账号（谁在看页） */
    val allAccounts: List<SavedAccount>
        get() = _savedServers.value.flatMap { saved -> saved.accounts.map { SavedAccount(saved.address, it) } }

    fun hasToken(username: String, address: ServerAddress) = store.token(address, username) != null

    fun tokenFor(address: ServerAddress, username: String) = store.token(address, username)

    init {
        val current = server
        if (current != null && _savedServers.value.none { it.origin == current.toString() }) {
            persist(SavedServers.touching(_savedServers.value, current, null))
        }
        val active = current?.let { c -> _savedServers.value.firstOrNull { it.origin == c.toString() }?.activeAccount }
        if (current != null && active != null) {
            token = store.token(current, active.username)
            val cached = store.cachedSession(current, active.username)
            if (token != null && cached != null) {
                _phase.value = Phase.Ready(cached)
                needsRevalidation = true
            }
        }
    }

    /** 带当前令牌的接口（401 会把人打回登录页） */
    fun api(address: ServerAddress = requireNotNull(server), bearer: String? = token): McApi =
        McApi(OkHttpTransport(address.apiBase, http, { bearer }) { rejected -> sessionExpired(address, rejected) })

    private fun anonymous(address: ServerAddress) = McApi(OkHttpTransport(address.apiBase, http))

    // ---- 启动与重连 ----

    /** 冷启动：调试参数优先；有服务器就恢复会话，否则进欢迎页片头 */
    suspend fun restore(debugServer: String? = null, debugUser: String? = null, debugPass: String? = null) {
        val debug = debugServer?.let(ServerAddress::parse)
        if (debug != null && debugUser != null) {
            val saved = store.token(debug, debugUser)
            val me = saved?.let { runCatching { api(debug, it).authMe() }.getOrNull() }
            if (me != null) return activate(debug, me, saved)
            if (debugPass != null && runCatching { signIn(debug, debugUser, debugPass) }.getOrNull() == SignInResult.SignedIn) return
        }
        if (_phase.value is Phase.Ready) return
        if (server == null) {
            _phase.value = Phase.NeedsServer
            return
        }
        reconnect()
    }

    /** 冷启动用快照进了主界面之后，在后台向服务器确认身份 */
    suspend fun revalidate() {
        val address = server ?: return
        val bearer = token ?: return
        val current = session ?: return
        if (!needsRevalidation) return
        needsRevalidation = false
        val fresh = runCatching { api(address, bearer).authMe() }.getOrNull() ?: return
        if (fresh.username == current.username && token == bearer) update(fresh)
    }

    /** 连当前服务器、恢复它上面的会话：冷启动与「连不上」卡片的「重试」共用 */
    suspend fun reconnect() {
        val address = server ?: return
        try {
            if (!anonymous(address).authBootstrapStatus().initialized) {
                _phase.value = Phase.NeedsSetup
                return
            }
            val bearer = token
            if (bearer == null) {
                launchError = null
                expiredUsername = activeAccount(address)?.username
                _phase.value = Phase.NeedsLogin
                return
            }
            activate(address, api(address, bearer).authMe(), bearer)
        } catch (e: ApiException) {
            if (!e.isUnauthorized) {
                launchError = e.message
                _phase.value = Phase.Unreachable
                return
            }
            val username = activeAccount(address)?.username
            username?.let { store.deleteToken(address, it) }
            token = null
            launchError = null
            expiredUsername = username
            _phase.value = Phase.NeedsLogin
        } catch (e: UnreachableException) {
            launchError = e.message
            _phase.value = Phase.Unreachable
        }
    }

    // ---- 登录 ----

    enum class SignInResult { SignedIn, NeedsSetup }

    /** 账号密码登录：测通服务器后换设备令牌，全部成功才记下服务器并进入 */
    suspend fun signIn(address: ServerAddress, username: String, password: String): SignInResult {
        val api = anonymous(address)
        if (!probe(api, address)) return SignInResult.NeedsSetup
        val login = try {
            api.authDeviceLogin(
                DeviceLoginRequest(
                    username = username.trim(),
                    password = password,
                    client = DeviceClientInfo(
                        kind = ClientIdentity.KIND,
                        installationId = store.installationId,
                        name = deviceName,
                        platform = identity.platform,
                        clientVersion = identity.appVersion,
                    ),
                ),
            )
        } catch (e: ApiException) {
            throw when (e.status) {
                404, 405 -> LoginException(serverTooOld(null))
                // 服务端还不认识 androidtv 这种设备类型（升级前的版本）
                422 -> LoginException("这台服务器还不认识Android TV 版 App：服务器版本太旧，请把服务器升级到最新版本后再登录（错误码 422）")
                else -> LoginException(e.message ?: "登录失败")
            }
        }
        store.saveToken(login.token, address, login.session.username)
        activate(address, login.session, login.token)
        return SignInResult.SignedIn
    }

    /** 配对码登录：兑换到的令牌直接进入批准者的账号 */
    suspend fun signIn(address: ServerAddress, pairedToken: String) {
        val session = api(address, pairedToken).authMe()
        store.saveToken(pairedToken, address, session.username)
        activate(address, session, pairedToken)
    }

    /** 测通服务器：健康的 MovieClaw、版本够新，返回它是否已完成初始化 */
    private suspend fun probe(api: McApi, address: ServerAddress): Boolean {
        val health = try {
            api.healthCheck()
        } catch (e: ApiException) {
            throw LoginException("该地址能访问，但不是 MovieClaw 服务器（请填写浏览器打开 MovieClaw 时地址栏里的地址）", e)
        }
        if (health.status != "ok") throw LoginException("服务器状态异常：${health.status}")
        val version = health.version
        if (version != null && !Versions.atLeast(version, MIN_SERVER_VERSION)) throw LoginException(serverTooOld(version))
        return api.authBootstrapStatus().initialized
    }

    // ---- 切换账号 ----

    /** 切到某台服务器上一个已登录的账号（可以跨服务器），换用它的令牌即可 */
    suspend fun switchAccount(username: String, address: ServerAddress) {
        val saved = store.token(address, username) ?: throw NeedsPasswordException(address, username)
        try {
            activate(address, api(address, saved).authMe(), saved)
        } catch (e: ApiException) {
            if (!e.isUnauthorized) throw e
            store.deleteToken(address, username)
            throw NeedsPasswordException(address, username)
        }
    }

    fun update(session: SessionView) {
        if (session == this.session) return
        _phase.value = Phase.Ready(session)
        server?.let {
            persist(SavedServers.upserting(_savedServers.value, it, SavedServers.snapshot(session, active = true)))
            store.cacheSession(session, it)
        }
    }

    // ---- 退出 ----

    /** 退出当前账号；同服务器还有别的账号就自动切过去，返回切到的会话 */
    suspend fun logout(): SessionView? {
        val address = server ?: return null
        val current = session ?: return null
        token?.let { revokeDevice(address, it) }
        store.deleteToken(address, current.username)
        token = null
        persist(SavedServers.removingAccount(_savedServers.value, current.username, address))
        for (account in _savedServers.value.firstOrNull { it.origin == address.toString() }?.accounts.orEmpty()) {
            val saved = store.token(address, account.username) ?: continue
            try {
                val next = api(address, saved).authMe()
                activate(address, next, saved)
                return next
            } catch (e: ApiException) {
                if (e.isUnauthorized) store.deleteToken(address, account.username) else return unreachableAfterLogout(current, saved)
            } catch (_: UnreachableException) {
                return unreachableAfterLogout(current, saved)
            }
        }
        // 这台服务器上没有能用的账号了
        for (account in _savedServers.value.firstOrNull { it.origin == address.toString() }?.accounts.orEmpty()) {
            store.deleteToken(address, account.username)
        }
        persist(SavedServers.replacingAccounts(_savedServers.value, address, emptyList()))
        expiredUsername = null
        _phase.value = if (accountsOnOtherServers.isEmpty()) Phase.NeedsLogin else Phase.ChooseAccount
        return null
    }

    private fun unreachableAfterLogout(current: SessionView, nextToken: String): SessionView? {
        token = nextToken
        launchError = "已退出「${current.nickname}」。服务器暂时连不上，恢复后点「重试」进入其他账号"
        _phase.value = Phase.Unreachable
        return null
    }

    /** 在服务端注销这台设备上的登录：5 秒超时，连不上记下来以后补发 */
    private suspend fun revokeDevice(address: ServerAddress, bearer: String) {
        if (!revoke(address, bearer)) {
            store.pendingRevocations = store.pendingRevocations.filterNot { it.token == bearer } +
                LocalStore.Revocation(address.toString(), bearer)
        }
    }

    private suspend fun revoke(address: ServerAddress, bearer: String): Boolean = withTimeoutOrNull(5_000) {
        try {
            McApi(OkHttpTransport(address.apiBase, http.newBuilder().callTimeout(5, TimeUnit.SECONDS).build(), { bearer }))
                .authDevicesRevokeCurrent()
            true
        } catch (e: ApiException) {
            e.status == 401 || e.status == 404
        } catch (_: Exception) {
            false
        }
    } ?: false

    /** 补发之前没注销成功的令牌（启动后、联网时调用） */
    suspend fun retryRevocations() {
        val done = store.pendingRevocations.filter { entry ->
            val address = ServerAddress.parse(entry.origin) ?: return@filter true
            revoke(address, entry.token)
        }.map { it.token }.toSet()
        store.pendingRevocations = store.pendingRevocations.filterNot { it.token in done }
    }

    // ---- 内部 ----

    private fun activate(address: ServerAddress, session: SessionView, bearer: String) {
        server = address
        token = bearer
        store.currentOrigin = address.toString()
        launchError = null
        expiredUsername = null
        var list = SavedServers.touching(_savedServers.value, address, null)
        list = SavedServers.upserting(list, address, SavedServers.snapshot(session, active = true))
        persist(SavedServers.pruned(list, address))
        store.cacheSession(session, address)
        _phase.value = Phase.Ready(session)
    }

    private fun activeAccount(address: ServerAddress) = _savedServers.value.firstOrNull { it.origin == address.toString() }?.activeAccount

    private fun persist(list: List<SavedServer>) {
        _savedServers.value = list
        store.savedServers = list
    }

    /** 当前令牌收到 401：删掉它，回登录页并预填用户名。带着别的令牌的 401 不算 */
    private fun sessionExpired(address: ServerAddress, rejected: String) {
        val current = session ?: return
        if (address != server || rejected != token) return
        store.deleteToken(address, current.username)
        token = null
        expiredUsername = current.username
        _phase.value = Phase.NeedsLogin
    }

    /** 欢迎页的本地跳转（选服务器、加账号）：只在登录相关的阶段之间切换 */
    fun showWelcome(phase: Phase) {
        _phase.value = phase
    }

    companion object {
        /** 最低服务器版本（同 Apple 端口径取 0.28.0 起；androidtv 设备类型更晚才认，由登录时的 422 说明） */
        const val MIN_SERVER_VERSION = "0.28.0"

        fun serverTooOld(version: String?) =
            "服务器版本${version?.let { " v$it " } ?: ""}太旧，App 需要 v$MIN_SERVER_VERSION 或更新版本。" +
                "请先在网页「设置 → 更新与维护」里把服务器升级到最新版"
    }
}

class LoginException(message: String, cause: Throwable? = null) : Exception(message, cause)

class NeedsPasswordException(val server: ServerAddress, val username: String) :
    Exception("「$username」的登录已失效，请重新输入密码")

internal object Versions {
    /** 比较 `0.33.0`、`0.33.1-dev.20261008` 这类版本号的数字部分 */
    fun atLeast(version: String, minimum: String): Boolean {
        fun parts(v: String) = v.substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
        val a = parts(version)
        val b = parts(minimum)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return true
    }
}
