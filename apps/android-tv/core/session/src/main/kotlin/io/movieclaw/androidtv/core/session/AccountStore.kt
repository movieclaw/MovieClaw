package io.movieclaw.androidtv.core.session

import android.content.Context
import io.movieclaw.androidtv.core.model.McJson
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.builtins.ListSerializer
import java.util.UUID

/** 本机的账号库：账号列表、各自的令牌、当前账号、安装标识。 */
class AccountStore(context: Context) {
    private val prefs = context.getSharedPreferences("accounts", Context.MODE_PRIVATE)
    private val cipher = TokenCipher()
    private val _accounts = MutableStateFlow(load())
    val accounts: StateFlow<List<Account>> = _accounts.asStateFlow()

    /** 服务端登录设备的安装标识（8～128 字符）。重装 App 才会变，同一台电视重复登录会顶掉旧令牌。 */
    val installationId: String
        get() = prefs.getString(KEY_INSTALLATION, null) ?: ("androidtv-" + UUID.randomUUID()).also {
            prefs.edit().putString(KEY_INSTALLATION, it).apply()
        }

    val currentId: String? get() = prefs.getString(KEY_CURRENT, null)?.takeIf { id -> _accounts.value.any { it.id == id } }
    val current: Account? get() = currentId?.let { id -> _accounts.value.firstOrNull { it.id == id } }

    fun token(accountId: String): String? = prefs.getString(KEY_TOKEN + accountId, null)?.let(cipher::open)

    /** 登录成功：同一服务器同一用户就覆盖旧的（保留 id 与设备标识），并设为当前账号。 */
    fun upsert(origin: String, username: String, nickname: String, avatarUrl: String?, token: String): Account {
        val existing = _accounts.value.firstOrNull { it.origin == origin && it.username == username }
        val account = existing?.copy(nickname = nickname, avatarUrl = avatarUrl) ?: Account(
            id = UUID.randomUUID().toString(),
            origin = origin,
            username = username,
            nickname = nickname,
            avatarUrl = avatarUrl,
            deviceId = "atv-" + UUID.randomUUID().toString().replace("-", "").take(24),
            addedAt = System.currentTimeMillis(),
        )
        val list = _accounts.value.filterNot { it.id == account.id } + account
        prefs.edit()
            .putString(KEY_ACCOUNTS, McJson.encodeToString(LIST, list))
            .putString(KEY_TOKEN + account.id, cipher.seal(token))
            .putString(KEY_CURRENT, account.id)
            .apply()
        _accounts.value = list
        return account
    }

    fun select(accountId: String) {
        prefs.edit().putString(KEY_CURRENT, accountId).apply()
    }

    /** 退出登录：删掉账号与令牌；退的是当前账号就清掉当前账号。 */
    fun remove(accountId: String) {
        val list = _accounts.value.filterNot { it.id == accountId }
        prefs.edit().apply {
            putString(KEY_ACCOUNTS, McJson.encodeToString(LIST, list))
            remove(KEY_TOKEN + accountId)
            if (prefs.getString(KEY_CURRENT, null) == accountId) remove(KEY_CURRENT)
        }.apply()
        _accounts.value = list
    }

    private fun load(): List<Account> = prefs.getString(KEY_ACCOUNTS, null)
        ?.let { runCatching { McJson.decodeFromString(LIST, it) }.getOrNull() }
        .orEmpty()

    private companion object {
        val LIST = ListSerializer(Account.serializer())
        const val KEY_ACCOUNTS = "accounts"
        const val KEY_CURRENT = "current"
        const val KEY_TOKEN = "token."
        const val KEY_INSTALLATION = "installation_id"
    }
}
