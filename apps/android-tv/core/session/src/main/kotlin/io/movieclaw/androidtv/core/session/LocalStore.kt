package io.movieclaw.androidtv.core.session

import android.content.Context
import io.movieclaw.androidtv.core.model.McJson
import io.movieclaw.androidtv.core.model.generated.SessionView
import io.movieclaw.androidtv.core.network.ServerAddress
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.util.UUID

/**
 * 本机持久化：服务器与账号列表、各账号的令牌（KeyStore 加密）、会话快照、待补发的注销、安装标识。
 * 对应 Apple 端的 SavedServers / TokenVault / SessionCache / PendingRevocations 四处存储。
 */
class LocalStore(context: Context) {
    private val prefs = context.getSharedPreferences("movieclaw", Context.MODE_PRIVATE)
    private val cipher = TokenCipher()

    var currentOrigin: String?
        get() = prefs.getString(KEY_SERVER, null)
        set(value) = prefs.edit().putString(KEY_SERVER, value).apply()

    var savedServers: List<SavedServer>
        get() = prefs.getString(KEY_SERVERS, null)
            ?.let { runCatching { McJson.decodeFromString(SERVERS, it) }.getOrNull() }
            .orEmpty()
        set(value) = prefs.edit().putString(KEY_SERVERS, McJson.encodeToString(SERVERS, value)).apply()

    /** 服务端登录设备的安装标识（8～128 字符）：重装 App 才会变，同一台电视重复登录会顶掉旧令牌 */
    val installationId: String
        get() = prefs.getString(KEY_INSTALLATION, null) ?: ("androidtv-" + UUID.randomUUID()).also {
            prefs.edit().putString(KEY_INSTALLATION, it).apply()
        }

    /** 播放上报的设备标识（`^[A-Za-z0-9_-]{8,64}$`，同 Apple 端 PlayerPreferences.deviceId：一台设备一个） */
    val playbackDeviceId: String
        get() = prefs.getString(KEY_DEVICE, null) ?: ("atv-" + UUID.randomUUID().toString().replace("-", "").take(24)).also {
            prefs.edit().putString(KEY_DEVICE, it).apply()
        }

    // ---- 令牌 ----

    fun token(server: ServerAddress, username: String): String? =
        prefs.getString(tokenKey(server, username), null)?.let(cipher::open)

    fun saveToken(token: String, server: ServerAddress, username: String) {
        prefs.edit().putString(tokenKey(server, username), cipher.seal(token)).apply()
    }

    fun deleteToken(server: ServerAddress, username: String) {
        prefs.edit().remove(tokenKey(server, username)).apply()
    }

    private fun tokenKey(server: ServerAddress, username: String) = "token.$server#${username.lowercase()}"

    // ---- 会话快照：冷启动直接进主界面，不转圈 ----

    fun cachedSession(server: ServerAddress, username: String): SessionView? =
        prefs.getString(sessionKey(server, username), null)
            ?.let { runCatching { McJson.decodeFromString(SessionView.serializer(), it) }.getOrNull() }

    fun cacheSession(session: SessionView, server: ServerAddress) {
        prefs.edit().putString(sessionKey(server, session.username), McJson.encodeToString(SessionView.serializer(), session)).apply()
    }

    private fun sessionKey(server: ServerAddress, username: String) = "session.$server#${username.lowercase()}"

    // ---- 连不上时没注销成功的令牌，下次联网补发 ----

    @Serializable
    data class Revocation(val origin: String, val token: String)

    var pendingRevocations: List<Revocation>
        get() = prefs.getString(KEY_REVOCATIONS, null)
            ?.let { runCatching { McJson.decodeFromString(REVOCATIONS, it) }.getOrNull() }
            .orEmpty()
        set(value) = prefs.edit().putString(KEY_REVOCATIONS, McJson.encodeToString(REVOCATIONS, value.takeLast(50))).apply()

    // ---- 小件偏好（墙的排序、画质记忆……） ----

    fun string(key: String): String? = prefs.getString("pref.$key", null)
    fun putString(key: String, value: String?) = prefs.edit().apply {
        if (value == null) remove("pref.$key") else putString("pref.$key", value)
    }.apply()

    private companion object {
        val SERVERS = ListSerializer(SavedServer.serializer())
        val REVOCATIONS = ListSerializer(Revocation.serializer())
        const val KEY_SERVER = "server.origin"
        const val KEY_SERVERS = "server.saved"
        const val KEY_INSTALLATION = "installation_id"
        const val KEY_DEVICE = "playback_device_id"
        const val KEY_REVOCATIONS = "pending_revocations"
    }
}
