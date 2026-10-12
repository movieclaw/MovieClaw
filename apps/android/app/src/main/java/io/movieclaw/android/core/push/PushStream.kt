package io.movieclaw.android.core.push

import io.movieclaw.android.core.notify.Notifier
import kotlin.math.min
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources

/*
 * 自托管实时通知的纯逻辑部分（不碰 Android 组件，便于单测）：
 * 服务器发来的一条通知长什么样、落到哪个通知渠道 / 哪个页面、重连退避、单次 SSE 连接。
 *
 * 服务端协议（docs/design/cloud-push.md §4.1）：GET /push/me/stream?since=<id>，
 * `id: <发件箱 id>` + `event: notification` + `data: <JSON>`；空闲时 `: heartbeat` 注释；
 * 另有不带 id 的 `event: status`（状态快照，常驻通知用，见 OngoingNotice.kt）。
 */

/** 服务器发件箱里的一条通知（字段见服务端 notify._stream_payload） */
@Serializable
data class StreamNotification(
    val id: Long,
    val event: String = "",
    val title: String = "",
    val subtitle: String? = null,
    val body: String? = null,
    /** 网页站内路径（与网页、iOS 同一套），由 [StreamNotifications.landingFor] 翻成 App 路由 */
    val deeplink: String? = null,
    val thread: String? = null,
    val category: String? = null,
    /** 相同的新通知替换旧的（同一部剧的进度卡、同一个待处理问题） */
    val collapse: String? = null,
    /** 打扰级别：passive 不响不振，active / time-sensitive 正常提醒 */
    val priority: String = "active",
    val sentAt: Long = 0,
)

/** 点开通知去哪：具体路由（AppNav 的 `item/{库}/{条目}` 等），否则退到底栏页 */
data class Landing(val route: String?, val tab: String?)

object StreamNotifications {
    /** 超过这么久的补发通知只确认、不弹出：换回一个很久没用的账号时不刷屏 */
    const val STALE_SECONDS = 24 * 3600L

    fun parse(json: Json, data: String): StreamNotification? =
        runCatching { json.decodeFromString(StreamNotification.serializer(), data) }
            .getOrNull()
            ?.takeIf { it.id > 0 && it.title.isNotBlank() }

    /**
     * 服务端通知键 → 本机通知渠道（与设置页 4 个渠道同一套）。通知键是触发它的事件名
     * （docs/design/domain-events.md §6.1）；旧服务端发的旧键照样认。插件的通知归「任务」。
     */
    fun channelFor(event: String): String = when (event) {
        "subscription.fulfilled", "subscription.upgraded", "library.items.arrived",
        "imported", "upgraded", "library_new" -> Notifier.CH_ARRIVAL
        "subscription.download_started", "download_started" -> Notifier.CH_DOWNLOAD
        "subscription.identity_skipped", "identity_skipped", "subscription.completed",
        "subscription.download_stuck", "subscription.more_episodes" -> Notifier.CH_SUBSCRIPTION
        else -> Notifier.CH_TASK // 新设备登录 / 待处理事项（含已恢复）/ 新版本 / 使用建议 / 插件 / test
    }

    /** 同一个 collapse 用同一个通知 id（新的替换旧的）；没有就按发件箱 id，各占一条 */
    fun notificationId(n: StreamNotification): Int =
        (n.collapse?.takeIf { it.isNotBlank() }?.let { "push:c:$it" } ?: "push:i:${n.id}").hashCode()

    fun isStale(n: StreamNotification, nowSeconds: Long): Boolean =
        n.sentAt > 0 && nowSeconds - n.sentAt > STALE_SECONDS

    fun silent(n: StreamNotification): Boolean = n.priority == "passive"

    /** 网页路径 → App 路由（AppNav）。认不出的只打开 App。 */
    fun landingFor(deeplink: String?): Landing {
        val path = deeplink?.substringBefore('?')?.substringBefore('#')?.trim('/')
            ?: return Landing(null, null)
        val parts = path.split('/')
        val first = parts.getOrNull(0)
        return when {
            first == "library" && parts.getOrNull(2) == "item" -> {
                val library = parts.getOrNull(1)?.toLongOrNull()
                val item = parts.getOrNull(3)?.toLongOrNull()
                if (library != null && item != null) Landing("item/$library/$item", null) else Landing(null, null)
            }
            first == "library" -> parts.getOrNull(1)?.toLongOrNull()
                ?.let { Landing("library/$it?name=", null) } ?: Landing(null, null)
            first == "subscriptions" -> parts.getOrNull(1)?.toLongOrNull()
                ?.let { Landing("subscription/$it", null) } ?: Landing(null, Notifier.TAB_SUBSCRIPTIONS)
            first == "settings" -> SETTINGS[parts.getOrNull(1)]
                ?.let { Landing("settings/$it", null) } ?: Landing("settings", null)
            first == "downloads" || first == "activity" -> Landing(null, Notifier.TAB_ACTIVITY)
            else -> Landing(null, null)
        }
    }

    /** 网页设置页 → App 的 SettingsSection 名 */
    private val SETTINGS = mapOf(
        "notifications" to "NOTIFY",
        "devices" to "DEVICES",
        "playback" to "PLAYBACK",
        "app" to "MAINTENANCE",
        "maintenance" to "MAINTENANCE",
        "network" to "NETWORK",
        "logs" to "LOGS",
        "members" to "MEMBERS",
        "sites" to "SITES_WEB",
        "downloaders" to "DOWNLOADERS_WEB",
        "profile" to "PROFILE",
    )
}

/** 指数退避（带一半抖动）：2 秒起，翻倍到 5 分钟封顶；连上一次就归零 */
class Backoff(
    private val baseMs: Long = 2_000L,
    private val maxMs: Long = 300_000L,
    private val random: () -> Double = Math::random,
) {
    var attempt: Int = 0
        private set

    fun next(): Long {
        val ceiling = min(maxMs, baseMs shl min(attempt, 20))
        attempt++
        return ceiling / 2 + (random() * (ceiling / 2)).toLong()
    }

    fun reset() {
        attempt = 0
    }
}

/** 一次连接里发生的事 */
sealed interface StreamSignal {
    data object Opened : StreamSignal
    data class Notification(val item: StreamNotification) : StreamSignal
    data class Status(val snapshot: StreamStatusSnapshot) : StreamSignal
}

/** HTTP 层面的失败（带状态码，409 = 服务器上还没登记成实时通知设备） */
class StreamHttpException(val code: Int, message: String) : Exception(message)

/**
 * 单次 SSE 连接：连上发 [StreamSignal.Opened]，每条 notification 发一次；服务器正常结束时
 * flow 正常结束，网络错误 / 非 2xx 以异常结束。重连、游标、确认由调用方（前台服务）负责。
 */
object PushStreamConnection {
    fun url(apiBase: String, since: Long): String =
        (apiBase.trimEnd('/') + "/push/me/stream").toHttpUrl().newBuilder()
            .addQueryParameter("since", since.coerceAtLeast(0).toString())
            .build().toString()

    fun open(client: OkHttpClient, apiBase: String, since: Long, json: Json): Flow<StreamSignal> = callbackFlow {
        val request = Request.Builder()
            .url(url(apiBase, since))
            .header("Accept", "text/event-stream")
            .build()
        val listener = object : EventSourceListener() {
            override fun onOpen(eventSource: EventSource, response: Response) {
                trySend(StreamSignal.Opened)
            }

            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                if (type == "status") {
                    runCatching { json.decodeFromString(StreamStatusSnapshot.serializer(), data) }
                        .onSuccess { trySend(StreamSignal.Status(it)) }
                    return
                }
                if (type != "notification") return
                val item = StreamNotifications.parse(json, data) ?: return
                if (trySend(StreamSignal.Notification(item)).isFailure) {
                    // 缓冲满就断开，靠游标从最后处理的那条续传，不静默丢通知
                    close(StreamHttpException(0, "实时通知过快，正在重连"))
                    eventSource.cancel()
                }
            }

            override fun onClosed(eventSource: EventSource) {
                close()
            }

            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                val code = response?.code ?: 0
                close(
                    if (code != 0) StreamHttpException(code, "实时连接失败（HTTP $code）")
                    else t ?: StreamHttpException(0, "实时连接中断"),
                )
            }
        }
        val source = EventSources.createFactory(client).newEventSource(request, listener)
        awaitClose { source.cancel() }
    }
}
