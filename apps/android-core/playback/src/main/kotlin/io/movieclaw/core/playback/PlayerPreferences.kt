package io.movieclaw.core.playback

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/** 本机小件偏好的读写（LocalStore.string / putString），控制器不直接依赖账号库 */
interface PrefsStore {
    fun string(key: String): String?
    fun putString(key: String, value: String?)
}

/** 画质档（对应 Web `lib/player/quality.ts`）。语义是**上限**：源不超所选档就照常直通 */
data class QualityOption(val maxHeight: Int?, val label: String, val hint: String) {
    companion object {
        val ALL = listOf(
            QualityOption(null, "原画", "不限画质：能直通就播原文件，放不了时按原分辨率转码"),
            QualityOption(1080, "1080p", "约 6 Mbps"),
            QualityOption(720, "720p", "约 3 Mbps，网络一般时选它"),
            QualityOption(480, "480p", "约 1.5 Mbps，弱网救急"),
        )
    }
}

/**
 * 画质按影片、按网络环境记：在外面给一部片选了 1080p，回到家打开还是原画；剧集整部剧共用一份（按条目 id）。
 * 只存限了画质的选择，选回「原画」就删掉；最多 [LIMIT] 条，超出按最久没用的先丢。
 */
class QualityMemory(private val store: PrefsStore, private val now: () -> Long = System::currentTimeMillis) {
    fun quality(mediaItemId: Long, network: PlaybackNetwork): Int? {
        val height = entries()[key(mediaItemId, network)]?.first ?: return null
        return height.takeIf { h -> QualityOption.ALL.any { it.maxHeight == h } }
    }

    fun remember(maxHeight: Int?, mediaItemId: Long, network: PlaybackNetwork) {
        val all = entries().toMutableMap()
        val key = key(mediaItemId, network)
        if (maxHeight != null) {
            all[key] = maxHeight to now()
            if (all.size > LIMIT) {
                all.entries.sortedBy { it.value.second }.take(all.size - LIMIT).forEach { all.remove(it.key) }
            }
        } else {
            all.remove(key)
        }
        val json = JsonObject(all.mapValues { (_, v) -> JsonArray(listOf(JsonPrimitive(v.first), JsonPrimitive(v.second))) })
        store.putString(STORE_KEY, json.toString())
    }

    private fun entries(): Map<String, Pair<Int, Long>> {
        val raw = store.string(STORE_KEY) ?: return emptyMap()
        val obj = runCatching { Json.parseToJsonElement(raw) as JsonObject }.getOrNull() ?: return emptyMap()
        return obj.mapNotNull { (k, v) ->
            val array = runCatching { v.jsonArray }.getOrNull() ?: return@mapNotNull null
            val height = array.getOrNull(0)?.jsonPrimitive?.doubleOrNull?.toInt() ?: return@mapNotNull null
            val at = array.getOrNull(1)?.jsonPrimitive?.doubleOrNull?.toLong() ?: 0L
            k to (height to at)
        }.toMap()
    }

    private fun key(mediaItemId: Long, network: PlaybackNetwork) = "${network.key}:$mediaItemId"

    companion object {
        const val LIMIT = 300
        const val STORE_KEY = "player.quality-by-title"
    }
}

/** 倍速档（docs/design/playback-speed.md）：各端同一组，最高 2 倍（Apple 自研引擎视频通路的上限，也是 B 站、Infuse 的上限） */
object PlaybackSpeeds {
    val ALL = listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f)

    /** 「正常」/「1.25×」 */
    fun label(speed: Float): String = if (speed == 1f) "正常" else short(speed)

    /** 「1×」「1.25×」：时间旁的角标、开播提示用 */
    fun short(speed: Float): String = "%.2f".format(java.util.Locale.ROOT, speed).trimEnd('0').trimEnd('.') + "×"
}

/**
 * 倍速按片记：同一部剧换集、下次再打开都保持，换一部片从正常速度起（2026-10-19 用户拍板）。
 * 只存不是正常速度的选择，选回正常就删掉；最多 [LIMIT] 条，超出按最久没用的先丢（同 [QualityMemory]）。
 */
class SpeedMemory(private val store: PrefsStore, private val now: () -> Long = System::currentTimeMillis) {
    fun speed(mediaItemId: Long): Float? {
        val speed = entries()[mediaItemId.toString()]?.first ?: return null
        return speed.takeIf { it != 1f && it in PlaybackSpeeds.ALL }
    }

    fun remember(speed: Float, mediaItemId: Long) {
        val all = entries().toMutableMap()
        val key = mediaItemId.toString()
        if (speed != 1f) {
            all[key] = speed to now()
            if (all.size > LIMIT) {
                all.entries.sortedBy { it.value.second }.take(all.size - LIMIT).forEach { all.remove(it.key) }
            }
        } else {
            all.remove(key)
        }
        val json = JsonObject(all.mapValues { (_, v) -> JsonArray(listOf(JsonPrimitive(v.first), JsonPrimitive(v.second))) })
        store.putString(STORE_KEY, json.toString())
    }

    private fun entries(): Map<String, Pair<Float, Long>> {
        val raw = store.string(STORE_KEY) ?: return emptyMap()
        val obj = runCatching { Json.parseToJsonElement(raw) as JsonObject }.getOrNull() ?: return emptyMap()
        return obj.mapNotNull { (k, v) ->
            val array = runCatching { v.jsonArray }.getOrNull() ?: return@mapNotNull null
            val speed = array.getOrNull(0)?.jsonPrimitive?.doubleOrNull?.toFloat() ?: return@mapNotNull null
            val at = array.getOrNull(1)?.jsonPrimitive?.doubleOrNull?.toLong() ?: 0L
            k to (speed to at)
        }.toMap()
    }

    companion object {
        const val LIMIT = 300
        const val STORE_KEY = "player.speed-by-title"
    }
}

/**
 * 开播提示「已沿用上次的选择」：画质、音轨、字幕都按片记，下次打开时只有**不是默认**的选择才提示几秒，
 * 免得对着 720p 的画面、日语音轨纳闷「怎么是这样」。
 */
object RememberedChoices {
    /** 各项传 null = 这一项是默认（或这次没沿用记忆），不提 */
    fun notice(quality: Int?, network: PlaybackNetwork, audio: String?, subtitle: String?, speed: Float? = null): String? {
        val parts = mutableListOf<String>()
        if (quality != null) {
            // 画质按网络环境分开记：点明是哪个环境下的选择，回到家看到原画不会以为记忆失灵
            parts += network.label?.let { "画质 ${quality}p（$it）" } ?: "画质 ${quality}p"
        }
        audio?.let { parts += "音轨 $it" }
        subtitle?.let { parts += "字幕 $it" }
        speed?.let { parts += "倍速 ${PlaybackSpeeds.short(it)}" }
        return if (parts.isEmpty()) null else "已沿用上次的选择：" + parts.joinToString("，")
    }

    /** 菜单标签（「日语 · AC3 · 5.1」）在提示里只留语言；同语言有好几条时留全称才分得清 */
    fun shortLabel(label: String, among: List<String>): String {
        fun name(text: String) = text.split(" · ").first()
        val short = name(label)
        return if (among.count { name(it) == short } > 1) label else short
    }
}

/** 字幕外观（同 Web / Apple 端默认值；电视上没有样式设置）：字号是画面高度的 5.2%，距画面底边 8%，不加底 */
object SubtitleStyle {
    const val FONT_SCALE_PERCENT = 5.2f
    const val BOTTOM_PERCENT = 8f
}
