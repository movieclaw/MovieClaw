package io.movieclaw.core.network

/**
 * 这台设备在服务端眼里的样子。User-Agent 的格式服务端按正则认（watch.py `_APP_USER_AGENT`），
 * 活动页据此记成「MovieClaw Android TV · Android TV · Android 12」。默认值是电视；手机传 [PHONE_KIND] / [PHONE_PRODUCT]。
 */
data class ClientIdentity(
    val appVersion: String,
    val buildNumber: Long,
    val model: String,
    val osVersion: String,
    /** 服务端的设备类型（login_devices.KINDS）与播放上报的 client 字段 */
    val kind: String = KIND,
    /** User-Agent 的产品名（服务端按它区分平台） */
    val product: String = PRODUCT,
) {
    val userAgent: String
        get() = "$product/$appVersion ($model; Android $osVersion; build $buildNumber)"

    /** 登录设备列表里的「平台」一行。 */
    val platform: String get() = "Android $osVersion · $model"

    companion object {
        /** 电视的设备类型（login_devices.KINDS）与播放上报的 client 字段。 */
        const val KIND = "androidtv"
        const val PRODUCT = "MovieClaw-AndroidTV"
        const val PHONE_KIND = "android"
        const val PHONE_PRODUCT = "MovieClaw-Android"
    }
}
