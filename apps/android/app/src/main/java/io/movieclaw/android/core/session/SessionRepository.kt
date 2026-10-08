package io.movieclaw.android.core.session

import io.movieclaw.android.core.AppScopes

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.model.CreateAdminRequest
import io.movieclaw.android.core.model.DeviceLoginRequest
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.ApiException
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.GeneralChannel
import io.movieclaw.android.core.network.SetupRequiredException
import io.movieclaw.android.core.network.ServerAddress
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.newDeviceClientInfo
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import retrofit2.HttpException

private val Context.serverStore by preferencesDataStore(name = "mc_servers")

enum class SessionPhase { BOOTING, NEEDS_LOGIN, READY }

data class SessionUi(
    val phase: SessionPhase = SessionPhase.BOOTING,
    val origin: String? = null,
    val session: SessionView? = null,
    val cached: Boolean = false,
    val presetUsername: String? = null,
)

@Serializable
data class SavedAccount(
    val username: String,
    val nickname: String? = null,
    val role: String = "member",
    val session: SessionView? = null,
    /** 令牌失效(换账号时 401):界面提示重新输密码,而不是静默消失 */
    val expired: Boolean = false,
)

@Serializable
data class SavedServer(
    val origin: String,
    val accounts: List<SavedAccount> = emptyList(),
    val activeAccount: String? = null,
    /** 探活后的 API 基址；跨进程保留反向代理子路径。 */
    val apiBase: String? = null,
)

/**
 * 会话仓库:登录(探测 → bootstrap 检查 → 设备登录)、多服务器多账号、
 * 冷启动快开(缓存快照直出 + 后台 revalidate)、身份校验 401 回落登录页。
 */
@Singleton
class SessionRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val json: Json,
    private val vault: TokenVault,
    private val apiFactory: ApiFactory,
    @GeneralChannel private val rawClient: OkHttpClient,
    private val cacheCleaner: SessionCacheCleaner,
) {
    private val scope = AppScopes.io("SessionRepository")
    private val sessionMutex = Mutex()

    private val _ui = MutableStateFlow(SessionUi())
    val ui: StateFlow<SessionUi> = _ui.asStateFlow()

    private val _servers = MutableStateFlow<List<SavedServer>>(emptyList())
    val servers: StateFlow<List<SavedServer>> = _servers.asStateFlow()

    init {
        scope.launch { sessionMutex.withLock { _servers.value = loadServers() } }
    }

    /** 冷启动:令牌 + 会话快照存在则直接进主界面,再后台校验 */
    suspend fun boot() {
        val restored = sessionMutex.withLock {
            if (_ui.value.phase != SessionPhase.BOOTING) return@withLock null
            val servers = loadServers()
            _servers.value = servers
            vault.warmUp()
            val server = servers.firstOrNull { it.activeAccount != null } ?: servers.firstOrNull()
            val account = server?.let { s ->
                s.accounts.firstOrNull { it.username == s.activeAccount } ?: s.accounts.firstOrNull()
            }
            val token = if (server != null && account != null) vault.token(server.origin, account.username) else null
            if (server == null || account == null || token == null) {
                _ui.value = SessionUi(phase = SessionPhase.NEEDS_LOGIN, presetUsername = account?.username)
                return@withLock null
            }
            server.apiBase?.let { apiFactory.registerApiBase(server.origin, it) }
            vault.activate(server.origin, account.username, token)
            _ui.value = SessionUi(
                phase = SessionPhase.READY,
                origin = server.origin,
                session = account.session,
                cached = true,
            )
            server.origin
        }
        restored?.let { revalidate(it) }
    }

    /** 播放/实时请求捕获同一份身份，回调只允许更新仍活跃的这一代。 */
    fun requestIdentity(origin: String): TokenVault.Identity? = vault.snapshot()?.takeIf { it.origin == origin }
    fun isCurrentIdentity(identity: TokenVault.Identity?): Boolean = identity != null && vault.isCurrent(identity)

    suspend fun revalidate(origin: String) {
        val expected = vault.snapshot()?.takeIf { it.origin == origin } ?: return
        try {
            val fresh = apiFactory.forIdentity(origin, expected).me().dataOrThrow()
            sessionMutex.withLock {
                if (!vault.isCurrent(expected) || fresh.username != expected.username) return@withLock
                _ui.value = _ui.value.copy(session = fresh, cached = false)
                updateActiveSession(origin, fresh)
            }
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: Exception) {
            if (failure is HttpException && failure.code() == 401) {
                sessionMutex.withLock {
                    if (!vault.isCurrent(expected)) return@withLock
                    markExpired(origin, expected.username)
                    vault.deactivateActive(expected)
                    _ui.value = SessionUi(phase = SessionPhase.NEEDS_LOGIN, presetUsername = expected.username)
                }
            }
        }
    }

    /** 一次提交:探测 + bootstrap 检查 + 设备登录 */
    suspend fun login(serverInput: String, username: String, password: String): SessionView {
        val addr = requireNormalized(serverInput)
        val probed = probe(addr)
        val api = apiFactory.forIdentity(probed.origin, null)
        val initialized = runCatching { api.bootstrapStatus().dataOrThrow().initialized }.getOrDefault(true)
        if (!initialized) throw SetupRequiredException(probed.origin)
        return deviceLogin(probed.origin, username, password)
    }

    /** 未初始化服务器:先创建管理员再登录 */
    suspend fun createAdminAndLogin(serverInput: String, username: String, password: String): SessionView {
        val addr = requireNormalized(serverInput)
        val probed = probe(addr)
        apiFactory.forIdentity(probed.origin, null).bootstrapCreate(CreateAdminRequest(username, password)).dataOrThrow()
        return deviceLogin(probed.origin, username, password)
    }

    private suspend fun deviceLogin(origin: String, username: String, password: String): SessionView = sessionMutex.withLock {
        val info = newDeviceClientInfo(installationId())
        val view = try {
            apiFactory.forIdentity(origin, null).deviceLogin(DeviceLoginRequest(username, password, info)).dataOrThrow()
        } catch (e: HttpException) {
            val detail = httpDetail(e)
            throw when (e.code()) {
                401 -> ApiException("BAD_CREDENTIALS", "用户名或密码错误", 401)
                429 -> ApiException("RATE_LIMITED", "尝试过于频繁,请稍后再试", 429)
                404, 405 -> ApiException("SERVER_TOO_OLD", "服务器版本过旧,请先升级 MovieClaw", e.code())
                else -> ApiException(
                    "HTTP_${e.code()}",
                    buildString {
                        append("登录失败(HTTP ${e.code()})")
                        if (!detail.isNullOrEmpty()) append(":$detail")
                    },
                    e.code(),
                )
            }
        }
        vault.saveToken(origin, username, view.token)
        vault.activate(origin, username, view.token)
        clearExpired(origin, username)
        upsertAccount(
            origin = origin,
            account = SavedAccount(username, view.session.nickname, view.session.role, view.session),
            setActive = true,
        )
        _ui.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = view.session, cached = false)
        view.session
    }

    /** 从本机移除一个已保存的账号(不动服务端凭证;要撤销请用设备管理) */
    suspend fun removeAccount(origin: String, username: String) = sessionMutex.withLock {
        val active = vault.snapshot()?.takeIf { it.origin == origin && it.username == username }
        if (active != null) {
            vault.clearActive(active)
            _ui.value = SessionUi(phase = SessionPhase.NEEDS_LOGIN, presetUsername = username)
        }
        vault.deleteToken(origin, username)
        val servers = _servers.value.map { server ->
            if (server.origin != origin) {
                server
            } else {
                server.copy(
                    accounts = server.accounts.filterNot { it.username == username },
                    activeAccount = if (server.activeAccount == username) null else server.activeAccount,
                )
            }
        }.filter { it.accounts.isNotEmpty() }
        _servers.value = servers
        persistServers(servers)
        // 展示/播放缓存跨账号共用：移除账号时一并清掉，免得残留的图与字节在换账号后还命中（iOS 退出即删快照）
        cacheCleaner.clear()
    }

    /** 退出全部账号(仅清本机;服务端凭证需逐台在设备管理里撤销) */
    suspend fun logoutAll() = sessionMutex.withLock {
        val origin = _ui.value.origin
        if (origin != null) {
            runCatching { apiFactory.forOrigin(origin).logoutCurrentDevice() }
        }
        _servers.value.forEach { server ->
            server.accounts.forEach { account -> vault.deleteToken(server.origin, account.username) }
        }
        _servers.value = emptyList()
        persistServers(emptyList())
        vault.deactivateActive()
        cacheCleaner.clear()
        _ui.value = SessionUi(phase = SessionPhase.NEEDS_LOGIN)
    }

    /** 切换账号:令牌不在(被移除/失效)就标记失效并回落登录 */
    suspend fun switchAccount(origin: String, username: String) {
        val selected = sessionMutex.withLock {
            val token = vault.token(origin, username)
            if (token == null) {
                vault.clearActive()
                markExpired(origin, username)
                _ui.value = SessionUi(
                    phase = SessionPhase.NEEDS_LOGIN,
                    presetUsername = username,
                )
                return@withLock false
            }
            _servers.value.firstOrNull { it.origin == origin }?.apiBase?.let { apiFactory.registerApiBase(origin, it) }
            vault.activate(origin, username, token)
            markActive(origin, username)
            val snapshot = _servers.value
                .firstOrNull { it.origin == origin }?.accounts
                ?.firstOrNull { it.username == username }?.session
            _ui.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = snapshot, cached = true)
            true
        }
        if (selected) revalidate(origin)
    }

    /** 登出本设备:尽力撤销服务端凭证,清除本地令牌 */
    suspend fun logout() = sessionMutex.withLock {
        val origin = _ui.value.origin
        val preset = _ui.value.session?.username
        if (origin != null) {
            withContext(Dispatchers.IO) {
                runCatching {
                    apiFactory.forOrigin(origin).logoutCurrentDevice()
                }
            }
            clearActiveFlag(origin)
        }
        vault.deactivateActive()
        cacheCleaner.clear()
        _ui.value = SessionUi(phase = SessionPhase.NEEDS_LOGIN, presetUsername = preset)
    }

    /**
     * 探活并**采用最终地址**:OkHttp 默认跟随重定向(含 http→https),
     * 反向代理强制跳转、挂在子路径(https://host/movieclaw/)都能落对基址。
     */
    private suspend fun probe(addr: ServerAddress.Normalized): ServerAddress.Normalized = withContext(Dispatchers.IO) {
        val request = okhttp3.Request.Builder().url("${addr.apiBase}/health").build()
        val response = runCatching { rawClient.newCall(request).execute() }.getOrNull()
            ?: throw ApiException("UNREACHABLE", "无法连接服务器,请检查地址与网络(${addr.origin})")
        response.use { r ->
            val body = r.body?.string().orEmpty()
            val isMovieClaw = r.isSuccessful &&
                (body.contains("movieclaw", ignoreCase = true) || body.contains("spec_hash"))
            if (!isMovieClaw) {
                throw ApiException("NOT_MOVIECLAW", "不是 MovieClaw 服务器或接口不可用(HTTP ${r.code})")
            }
            val finalUrl = r.request.url
            val apiBase = finalUrl.toString().removeSuffix("/health").trimEnd('/')
            val isDefaultPort = (finalUrl.scheme == "http" && finalUrl.port == 80) ||
                (finalUrl.scheme == "https" && finalUrl.port == 443)
            val origin = if (isDefaultPort) {
                "${finalUrl.scheme}://${finalUrl.host}"
            } else {
                "${finalUrl.scheme}://${finalUrl.host}:${finalUrl.port}"
            }
            apiFactory.registerApiBase(origin, apiBase)
            ServerAddress.Normalized(
                origin = origin,
                apiBase = apiBase,
                host = finalUrl.host,
                port = finalUrl.port,
            )
        }
    }

    private fun requireNormalized(serverInput: String): ServerAddress.Normalized {
        val address = ServerAddress.normalize(serverInput)
            ?: throw ApiException("INVALID_SERVER", "服务器地址无法解析,请检查格式")
        // 显式输入反向代理子路径时直接探测该目录；origin 仍保持严格的凭证边界。
        val text = serverInput.trim()
        val url = (if (text.startsWith("http", ignoreCase = true)) text else "http://$text").toHttpUrlOrNull()
            ?: throw ApiException("INVALID_SERVER", "服务器地址无法解析,请检查格式")
        val path = url.encodedPath.trimEnd('/')
        val apiPath = if (path.endsWith("/api/v1")) path else "$path/api/v1"
        return address.copy(apiBase = address.origin + apiPath)
    }

    /** 播放/进度上报的设备标识(与 installationId 同源) */
    suspend fun deviceId(): String = installationId()

    private suspend fun installationId(): String {
        val key = stringPreferencesKey("install_id")
        val existing = context.serverStore.data.first()[key]
        if (!existing.isNullOrEmpty()) return existing
        val created = "android-" + UUID.randomUUID().toString()
        context.serverStore.edit { it[key] = created }
        return created
    }

    private suspend fun loadServers(): List<SavedServer> {
        val raw = context.serverStore.data.first()[stringPreferencesKey(KEY_SERVERS)] ?: return emptyList()
        return runCatching { json.decodeFromString<List<SavedServer>>(raw) }.getOrDefault(emptyList())
    }

    private suspend fun persistServers(servers: List<SavedServer>) {
        context.serverStore.edit {
            it[stringPreferencesKey(KEY_SERVERS)] = json.encodeToString(servers)
        }
    }

    private suspend fun upsertAccount(origin: String, account: SavedAccount, setActive: Boolean) {
        val servers = _servers.value.toMutableList()
        val index = servers.indexOfFirst { it.origin == origin }
        if (index >= 0) {
            val server = servers[index]
            val accounts = server.accounts.filterNot { it.username == account.username } + account
            servers[index] = server.copy(
                accounts = accounts,
                activeAccount = if (setActive) account.username else server.activeAccount,
                apiBase = apiFactory.apiBaseOf(origin) ?: server.apiBase,
            )
        } else {
            servers += SavedServer(
                origin = origin,
                accounts = listOf(account),
                activeAccount = if (setActive) account.username else null,
                apiBase = apiFactory.apiBaseOf(origin),
            )
        }
        if (setActive) {
            for (i in servers.indices) {
                if (servers[i].origin != origin && servers[i].activeAccount != null) {
                    servers[i] = servers[i].copy(activeAccount = null)
                }
            }
        }
        _servers.value = servers
        persistServers(servers)
    }

    private suspend fun updateActiveSession(origin: String, session: SessionView) {
        val servers = _servers.value.toMutableList()
        val index = servers.indexOfFirst { it.origin == origin }
        if (index < 0) return
        val server = servers[index]
        val account = server.accounts.firstOrNull { it.username == server.activeAccount } ?: return
        val updated = account.copy(nickname = session.nickname ?: account.nickname, session = session)
        servers[index] = server.copy(accounts = server.accounts.map { if (it.username == account.username) updated else it })
        _servers.value = servers
        persistServers(servers)
    }

    private suspend fun markActive(origin: String, username: String) {
        val servers = _servers.value.map {
            if (it.origin == origin) it.copy(activeAccount = username)
            else it.copy(activeAccount = null)
        }
        _servers.value = servers
        persistServers(servers)
    }

    private suspend fun markExpired(origin: String, username: String) {
        val servers = _servers.value.map { server ->
            if (server.origin != origin) {
                server
            } else {
                server.copy(
                    accounts = server.accounts.map {
                        if (it.username == username) it.copy(expired = true) else it
                    },
                )
            }
        }
        _servers.value = servers
        persistServers(servers)
    }

    /** 登录成功后清掉该账号的失效标记 */
    private suspend fun clearExpired(origin: String, username: String) {
        val servers = _servers.value.map { server ->
            if (server.origin != origin) {
                server
            } else {
                server.copy(
                    accounts = server.accounts.map {
                        if (it.username == username) it.copy(expired = false) else it
                    },
                )
            }
        }
        _servers.value = servers
        persistServers(servers)
    }

    private suspend fun clearActiveFlag(origin: String) {
        val servers = _servers.value.map {
            if (it.origin == origin) it.copy(activeAccount = null) else it
        }
        _servers.value = servers
        persistServers(servers)
    }

    /** 透传 FastAPI 422 的校验详情(缺哪个字段/哪条规则没过),避免只报状态码 */
    private fun httpDetail(e: HttpException): String? = runCatching {
        val body = e.response()?.errorBody()?.string().orEmpty()
        if (body.isEmpty()) return@runCatching null
        when (val root = json.parseToJsonElement(body)) {
            is kotlinx.serialization.json.JsonObject -> when (val detail = root["detail"]) {
                is kotlinx.serialization.json.JsonArray ->
                    detail.firstOrNull()?.jsonObject?.get("msg")?.jsonPrimitive?.content
                is kotlinx.serialization.json.JsonPrimitive -> detail.content
                else -> null
            }
            else -> null
        }
    }.getOrNull()

    private companion object {
        const val KEY_SERVERS = "servers_json"
    }
}
