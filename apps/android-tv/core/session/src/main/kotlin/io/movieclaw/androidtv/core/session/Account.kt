package io.movieclaw.androidtv.core.session

import io.movieclaw.androidtv.core.network.ServerAddress
import kotlinx.serialization.Serializable

/**
 * 本机登录过的一个账号（一台服务器 × 一个用户）。「谁在看」就是在这些账号之间切换：
 * 换一枚令牌、不联网（docs/design/androidtv-app.md §2）。
 */
@Serializable
data class Account(
    val id: String,
    val origin: String,
    val username: String,
    val nickname: String,
    val avatarUrl: String? = null,
    /** 播放上报的设备标识（`^[A-Za-z0-9_-]{8,64}$`），一个账号一个，活动页据此区分设备 */
    val deviceId: String,
    val addedAt: Long,
) {
    val server: ServerAddress get() = requireNotNull(ServerAddress.parse(origin)) { "账号里存了坏地址：$origin" }
}
