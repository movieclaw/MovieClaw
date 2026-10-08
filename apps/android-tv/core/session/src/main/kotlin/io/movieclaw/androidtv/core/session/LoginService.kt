package io.movieclaw.androidtv.core.session

import io.movieclaw.androidtv.core.model.generated.DeviceClientInfo
import io.movieclaw.androidtv.core.model.generated.DeviceLoginRequest
import io.movieclaw.androidtv.core.network.ApiException
import io.movieclaw.androidtv.core.network.ClientIdentity
import io.movieclaw.androidtv.core.network.OkHttpTransport
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.generated.McApi
import okhttp3.OkHttpClient

/** 登录前的事：探测服务器、账号密码换设备令牌（docs/design/androidtv-app.md §5）。 */
class LoginService(
    private val http: OkHttpClient,
    private val store: AccountStore,
    private val identity: ClientIdentity,
    private val deviceName: String,
) {
    /** 地址能连上、是 MovieClaw、版本够新、已完成初始化，才往下走。失败抛 [LoginException]。 */
    suspend fun probe(address: ServerAddress) {
        val api = anonymous(address)
        val health = try {
            api.healthCheck()
        } catch (e: ApiException) {
            throw LoginException("这个地址不是 MovieClaw 服务器", e)
        }
        if (health.status != "ok") throw LoginException("服务器状态异常：${health.status}")
        val version = health.version
        if (version != null && !Versions.atLeast(version, MIN_SERVER_VERSION)) {
            throw LoginException("服务器版本 $version 太旧，请先升级到 $MIN_SERVER_VERSION 或更新")
        }
        if (!api.authBootstrapStatus().initialized) {
            throw LoginException("这台服务器还没初始化，请先在网页上创建管理员账号")
        }
    }

    suspend fun passwordLogin(address: ServerAddress, username: String, password: String): Account {
        probe(address)
        val result = try {
            anonymous(address).authDeviceLogin(
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
            throw LoginException(loginError(e), e)
        }
        val session = result.session
        return store.upsert(address.toString(), session.username, session.nickname, session.avatarUrl, result.token)
    }

    private fun loginError(e: ApiException): String = when {
        // 服务端还不认识 androidtv 这种设备类型（升级前的版本）
        e.status == 422 -> "服务器版本太旧，还不支持 Android TV，请先升级服务器"
        e.status == 404 || e.status == 405 -> "服务器版本太旧，请先升级服务器"
        e.status == 429 -> e.message ?: "尝试次数太多，请稍后再试"
        else -> e.message ?: "登录失败"
    }

    private fun anonymous(address: ServerAddress) = McApi(OkHttpTransport(address.apiBase, http))

    companion object {
        /** 最低服务器版本：up-next 带剧照与 Logo、首页按类型的行都从这版起（同 Apple 端口径） */
        const val MIN_SERVER_VERSION = "0.33.0"
    }
}

class LoginException(message: String, cause: Throwable? = null) : Exception(message, cause)

internal object Versions {
    /** 比较 `0.33.0`、`0.33.1-dev.20261008` 这类版本号的数字部分。 */
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
