package io.movieclaw.androidtv.core.network

/**
 * 这台电视在服务端眼里的样子。User-Agent 的格式服务端按正则认（watch.py `_APP_USER_AGENT`），
 * 活动页据此记成「MovieClaw Android TV · Android TV · Android 12」。
 */
data class ClientIdentity(
    val appVersion: String,
    val buildNumber: Long,
    val model: String,
    val osVersion: String,
) {
    val userAgent: String
        get() = "MovieClaw-AndroidTV/$appVersion ($model; Android $osVersion; build $buildNumber)"

    /** 登录设备列表里的「平台」一行。 */
    val platform: String get() = "Android $osVersion · $model"

    companion object {
        /** 服务端的设备类型（login_devices.KINDS）与播放上报的 client 字段。 */
        const val KIND = "androidtv"
    }
}
