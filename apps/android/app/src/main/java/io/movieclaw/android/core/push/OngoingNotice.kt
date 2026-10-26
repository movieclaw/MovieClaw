package io.movieclaw.android.core.push

import io.movieclaw.android.core.designsystem.McFormat
import kotlin.math.roundToInt
import kotlinx.serialization.Serializable

/*
 * 常驻通知显示什么（纯逻辑，不碰 Android 组件，便于单测）：
 * 服务器在实时连接上发的状态快照（event: status，服务端 services/push/status.py）+ 用户选的显示方式
 * → 标题、正文、进度条、展开后的列表、要不要「打开下载」按钮。只用原生通知模板。
 */

/** 服务器的状态快照；[downloads] 为 null = 这个账号看不到下载（成员） */
@Serializable
data class StreamStatusSnapshot(
    val server: String = "",
    val today: Today = Today(),
    val downloads: Downloads? = null,
) {
    @Serializable
    data class Today(val imported: Int = 0, val updated: Int = 0)

    @Serializable
    data class Downloads(
        val active: Int = 0,
        /** 总下载速度（字节/秒） */
        val speed: Long = 0,
        /** 整体进度 0..1；算不出（没有体积）为 null */
        val progress: Double? = null,
        val items: List<Item> = emptyList(),
    )

    @Serializable
    data class Item(
        val title: String = "",
        /** 「E12」「E12 等 3 集」；电影、手动下载为空 */
        val episode: String = "",
        val progress: Double? = null,
        val eta: Long? = null,
        /** downloading / checking / stalled / queued / paused */
        val state: String = "",
    )
}

enum class OngoingMode(val key: String, val title: String, val subtitle: String) {
    SMART("smart", "智能", "有下载 → 下载看板；没有 → 自定义文字"),
    DOWNLOADS("downloads", "下载看板", "只看下载进度和速度"),
    CUSTOM("custom", "自定义文字", "支持 emoji 和变量"),
    ;

    companion object {
        fun of(key: String?): OngoingMode = entries.firstOrNull { it.key == key } ?: SMART
    }
}

/** 一条常驻通知的内容 */
data class OngoingView(
    val title: String,
    val text: String,
    /** 展开后逐行列出（InboxStyle）；空 = 不展开 */
    val lines: List<String> = emptyList(),
    /** 进度条 0..100；null = 不画（[indeterminate] 时画不定进度） */
    val progress: Int? = null,
    val indeterminate: Boolean = false,
    /** 下载看板：带「打开下载」按钮，点按去活动页 */
    val openDownloads: Boolean = false,
)

object OngoingNotice {
    /** 没填自定义文字时用这句 */
    const val DEFAULT_TEMPLATE = "今天入库 {今日入库} 集"
    val VARIABLES = listOf("{下载数}", "{速度}", "{今日入库}", "{今日更新}", "{服务器名}")
    val EMOJIS = listOf("🦀", "🎬", "🍿", "📺", "✨", "🌙")

    /** 还没收到快照（或这个账号看不到下载）时变量显示成它，不拿 0 冒充 */
    private const val UNKNOWN = "–"

    /** 把模板里的变量换成快照里的值；不认识的花括号原样保留 */
    fun render(template: String, snapshot: StreamStatusSnapshot?): String {
        val downloads = snapshot?.downloads
        val values = mapOf(
            "{下载数}" to (downloads?.active?.toString() ?: UNKNOWN),
            "{速度}" to (downloads?.let { McFormat.speed(it.speed.toDouble()).ifEmpty { "0 KB/s" } } ?: UNKNOWN),
            "{今日入库}" to (snapshot?.today?.imported?.toString() ?: UNKNOWN),
            "{今日更新}" to (snapshot?.today?.updated?.toString() ?: UNKNOWN),
            "{服务器名}" to (snapshot?.server?.takeIf { it.isNotBlank() } ?: UNKNOWN),
        )
        return values.entries.fold(template) { text, (key, value) -> text.replace(key, value) }
    }

    /**
     * 连接不正常时只说连接状态（快照可能已经过时，不能拿来假装一切正常）；
     * 连着时按显示方式：智能 = 有下载显示看板，否则自定义文字；看板 = 一直显示下载（看不到下载的账号
     * 退回自定义文字）；自定义文字 = 一直显示用户的模板。
     */
    fun build(
        mode: OngoingMode,
        template: String,
        connection: PushStreamStatus,
        snapshot: StreamStatusSnapshot?,
    ): OngoingView {
        when (connection) {
            PushStreamStatus.Off, PushStreamStatus.Connecting ->
                return OngoingView("正在连接服务器…", "MovieClaw 实时通知")
            is PushStreamStatus.Retrying ->
                return OngoingView("实时通知已断开", "${connection.reason}，会自动重连")
            is PushStreamStatus.Connected -> Unit
        }
        val downloads = snapshot?.downloads
        if (downloads != null) {
            val board = when (mode) {
                OngoingMode.SMART -> downloads.active > 0
                OngoingMode.DOWNLOADS -> true
                OngoingMode.CUSTOM -> false
            }
            if (board) return board(downloads, snapshot?.today?.imported ?: 0)
        }
        return OngoingView(
            title = render(template.ifBlank { DEFAULT_TEMPLATE }, snapshot),
            text = listOfNotNull("已连接", snapshot?.server?.takeIf { it.isNotBlank() }).joinToString(" · "),
        )
    }

    private fun board(downloads: StreamStatusSnapshot.Downloads, importedToday: Int): OngoingView {
        if (downloads.active == 0) {
            val prefix = if (importedToday > 0) "今天已入库 $importedToday 集 · " else ""
            return OngoingView("下载全部完成", prefix + "已连接，有新通知会立即提醒")
        }
        val speed = McFormat.speed(downloads.speed.toDouble())
        val more = downloads.active - downloads.items.size
        val progress = downloads.progress?.let { (it * 100).roundToInt().coerceIn(0, 100) }
        return OngoingView(
            title = "下载中 ${downloads.active} 个" + if (speed.isEmpty()) "" else " · ↓ $speed",
            text = downloads.items.joinToString(" · ") { name(it) } + if (more > 0) " 等 ${downloads.active} 个" else "",
            lines = downloads.items.map { "${name(it)}　${detail(it)}" } + if (more > 0) listOf("还有 $more 个") else emptyList(),
            progress = progress ?: 0,
            indeterminate = progress == null,
            openDownloads = true,
        )
    }

    private fun name(item: StreamStatusSnapshot.Item): String =
        listOf(item.title, item.episode).filter { it.isNotBlank() }.joinToString(" ")

    /** 剩余时间：一天以内按分钟，再长按天（「805 小时」没法读），超过 30 天就不报了 */
    internal fun etaText(seconds: Long): String? = when {
        seconds <= 0 -> null
        seconds < 86_400 -> McFormat.durationMinutes(maxOf(1, (seconds / 60).toInt()))
        seconds <= 30 * 86_400L -> "约 ${(seconds + 43_200) / 86_400} 天"
        else -> null
    }

    /** 「78% · 2 分钟」；没在下载的说状态 */
    private fun detail(item: StreamStatusSnapshot.Item): String = when (item.state) {
        "downloading" -> {
            val percent = item.progress?.let { "${(it * 100).toInt()}%" }
            val eta = item.eta?.let(::etaText)
            listOfNotNull(percent, eta).joinToString(" · ").ifEmpty { "下载中" }
        }
        "stalled" -> "等待做种"
        "queued" -> "排队中"
        "paused" -> "已暂停"
        "checking" -> "校验中"
        else -> "下载中"
    }
}
