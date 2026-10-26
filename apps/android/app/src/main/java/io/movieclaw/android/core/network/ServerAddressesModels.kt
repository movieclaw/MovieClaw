package io.movieclaw.android.core.network

import kotlinx.serialization.Serializable

/** GET /server/addresses：这台服务器的访问地址簿（内网 / 外网） */
@Serializable
data class ServerAddressesView(
    @kotlinx.serialization.SerialName("instance_id") val instanceId: String = "",
    @kotlinx.serialization.SerialName("host_key") val hostKey: String = "",
    val addresses: List<ServerAddressItem> = emptyList(),
    @kotlinx.serialization.SerialName("lan_subnets") val lanSubnets: List<String> = emptyList(),
)

@Serializable
data class ServerAddressItem(
    val url: String,
    /** lan = 内网（在家用），wan = 外网（出门用） */
    val kind: String,
    /** learned / configured / manual */
    val source: String,
    @kotlinx.serialization.SerialName("last_seen") val lastSeen: String? = null,
)

/**
 * 图片/取流等「按 origin 拼 URL」的地方统一经它换到当前选中的入口。
 * 由 [ServerAddressBook] 在选路后注入 provider（designsystem 不反向依赖会话层）。
 */
object ServerRoutes {
    /** 当前请求应该声明的路线（docs/design/server-addresses.md §5.2，`X-MovieClaw-Route`） */
    enum class Route(val header: String) { LAN("lan"), VPN("vpn"), WAN("wan") }

    @Volatile var provider: ((origin: String?) -> String?)? = null

    /** 当前入口的路线；还没选路时按外网处理（服务端会把「认不准」往安全的一边算） */
    @Volatile var route: Route = Route.WAN

    /** 已验证过的其它入口（绝对 origin）：当前入口硬错误时，幂等请求换过去重试一次 */
    @Volatile var alternates: List<String> = emptyList()

    /** 请求遇到硬错误 → 触发重新选路（由 ServerAddressBook 挂上，带防抖） */
    @Volatile var onHardError: (() -> Unit)? = null

    fun baseFor(origin: String?): String? = provider?.invoke(origin) ?: origin
}
