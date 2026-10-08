package io.movieclaw.androidtv.core.session

import io.movieclaw.androidtv.core.model.generated.SessionView
import io.movieclaw.androidtv.core.network.ServerAddress
import kotlinx.serialization.Serializable

/** 本机登录过的一个账号的快照（谁在看页的头像、昵称）。同 Apple 端 `API.AccountView`。 */
@Serializable
data class AccountSnapshot(
    val username: String,
    val nickname: String,
    val avatarUrl: String? = null,
    val role: String = "",
    val active: Boolean = false,
)

/** 本机登录过的一台服务器（SavedServers.swift）：最近用过的在前。 */
@Serializable
data class SavedServer(
    val origin: String,
    val accounts: List<AccountSnapshot>,
    val lastUsed: Long,
) {
    val address: ServerAddress get() = requireNotNull(ServerAddress.parse(origin)) { "坏地址：$origin" }
    val activeAccount: AccountSnapshot? get() = accounts.firstOrNull { it.active } ?: accounts.firstOrNull()
}

/** 某台服务器上的一个账号（谁在看、选择账号用）。 */
data class SavedAccount(val server: ServerAddress, val account: AccountSnapshot) {
    val id: String get() = "$server#${account.username}"
}

/** SavedServers.swift 的纯函数部分：逐个对齐。 */
object SavedServers {
    fun touching(list: List<SavedServer>, address: ServerAddress, accounts: List<AccountSnapshot>?, at: Long = System.currentTimeMillis()): List<SavedServer> {
        val origin = address.toString()
        val result = if (list.any { it.origin == origin }) {
            list.map { if (it.origin == origin) it.copy(lastUsed = at, accounts = accounts ?: it.accounts) else it }
        } else {
            list + SavedServer(origin, accounts.orEmpty(), at)
        }
        return result.sortedByDescending { it.lastUsed }
    }

    fun replacingAccounts(list: List<SavedServer>, address: ServerAddress, accounts: List<AccountSnapshot>): List<SavedServer> =
        list.map { if (it.origin == address.toString()) it.copy(accounts = accounts) else it }

    fun upserting(list: List<SavedServer>, address: ServerAddress, account: AccountSnapshot): List<SavedServer> {
        val origin = address.toString()
        val base = if (list.any { it.origin == origin }) list else touching(list, address, null)
        return base.map { saved ->
            if (saved.origin != origin) return@map saved
            val same = { a: AccountSnapshot -> a.username.equals(account.username, ignoreCase = true) }
            val others = saved.accounts.filterNot(same)
            when {
                account.active -> saved.copy(accounts = listOf(account) + others.map { it.copy(active = false) })
                saved.accounts.any(same) -> saved.copy(accounts = saved.accounts.map { if (same(it)) account else it })
                else -> saved.copy(accounts = others + account)
            }
        }
    }

    fun snapshot(session: SessionView, active: Boolean) = AccountSnapshot(
        username = session.username,
        nickname = session.nickname,
        avatarUrl = session.avatarUrl,
        role = session.role,
        active = active,
    )

    fun removingAccount(list: List<SavedServer>, username: String, address: ServerAddress): List<SavedServer> =
        list.map { if (it.origin == address.toString()) it.copy(accounts = it.accounts.filterNot { a -> a.username == username }) else it }

    fun pruned(list: List<SavedServer>, keeping: ServerAddress?): List<SavedServer> =
        list.filter { it.accounts.isNotEmpty() || it.origin == keeping?.toString() }
}
