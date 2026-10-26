package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/*
 * 推送登记与实时通知（服务端 docs/design/cloud-push.md §4.1）。
 * Android 不接 APNs / 厂商推送：登记成「实时通知」设备（stream=true），由前台服务一直连着
 * GET /push/me/stream，显示后 POST /push/me/ack。
 */

/** PUT /push/me/registration：实时通知只需要权限和开关，不带令牌与密钥 */
@Serializable
data class PushRegistrationBody(
    val permission: String,
    val stream: Boolean,
    val clientVersion: String? = null,
)

@Serializable
data class PushRegistrationView(
    val registered: Boolean = false,
    val status: String = "",
    val statusText: String = "",
    val channelName: String? = null,
)

@Serializable
data class PushAckBody(val upTo: Long)

@Serializable
data class PushAckView(val acked: Int = 0)

@Serializable
data class PushTestResult(
    val deviceId: String = "",
    val deviceName: String = "",
    val result: String = "",
    val message: String = "",
)

@Serializable
data class PushTestView(
    val sent: Int = 0,
    val results: List<PushTestResult> = emptyList(),
)

/** GET /push/me 里的一项事件偏好：按账号存，iOS、网页、Android 共用同一份 */
@Serializable
data class PushEventPref(
    val key: String = "",
    val title: String = "",
    val description: String = "",
    val group: String = "",
    val enabled: Boolean = false,
)

/** GET /push/me（只取这里用得到的字段） */
@Serializable
data class MyPushView(val events: List<PushEventPref> = emptyList())

/** PUT /push/me/preferences：只改事件开关，不带 library_ids（不传 = 不改） */
@Serializable
data class PushPreferencesBody(val events: Map<String, Boolean>)
