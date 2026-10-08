package io.movieclaw.android.core.playback

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import java.net.InetAddress
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.first
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private val Context.qualityStore by preferencesDataStore(name = "mc_quality")

/**
 * 画质记忆(iOS QualityMemory):按「网络环境 × 片名」记住用户选的画质上限。
 * 只记**限制性**的选择(上限低于源分辨率)以及等于「自动」的 0。
 * 上限 300 条,按时间 LRU 淘汰。
 */
@Singleton
class QualityMemory @Inject constructor(
    @ApplicationContext private val context: Context,
    private val json: Json,
) {

    @Serializable
    private data class Entry(val key: String, val height: Int, val at: Long)

    /** 返回记住的画质上限;null = 没记过,0 = 记住的是「自动」 */
    suspend fun remembered(mediaItemId: Long, network: PlaybackNetwork): Int? {
        val key = key(network, mediaItemId)
        return load().firstOrNull { it.key == key }?.height
    }

    suspend fun remember(mediaItemId: Long, network: PlaybackNetwork, capHeight: Int?) {
        val key = key(network, mediaItemId)
        val entries = load().filterNot { it.key == key } +
            Entry(key, capHeight ?: 0, System.currentTimeMillis())
        val trimmed = entries.sortedByDescending { it.at }.take(MAX_ENTRIES)
        context.qualityStore.edit { it[KEY_MEMORY] = json.encodeToString(trimmed) }
    }

    suspend fun forget(mediaItemId: Long, network: PlaybackNetwork) {
        val key = key(network, mediaItemId)
        val entries = load().filterNot { it.key == key }
        context.qualityStore.edit { it[KEY_MEMORY] = json.encodeToString(entries) }
    }

    /* ---------------- 片段（刷片）的画质档位 ----------------
     * 与正片分开记：刷片是「连着看很多条」，一个片名一条记忆没有意义，只按**网络环境**记一份。
     * 用户没选过时按默认策略走（见 ReelsQuality.defaultCap）：局域网原画直出、外网 720p。
     */

    /** 片段的画质档位；null = 没选过（走默认策略） */
    suspend fun reelsCap(network: PlaybackNetwork): Int? {
        val raw = context.qualityStore.data.first()[KEY_REELS] ?: return null
        val entries = runCatching { json.decodeFromString<List<Entry>>(raw) }.getOrDefault(emptyList())
        return entries.firstOrNull { it.key == "reels:${network.id}" }?.height
    }

    suspend fun rememberReels(network: PlaybackNetwork, capHeight: Int?) {
        val raw = context.qualityStore.data.first()[KEY_REELS]
        val entries = runCatching { json.decodeFromString<List<Entry>>(raw ?: "") }.getOrDefault(emptyList())
            .filterNot { it.key == "reels:${network.id}" } +
            Entry("reels:${network.id}", capHeight ?: 0, System.currentTimeMillis())
        context.qualityStore.edit { it[KEY_REELS] = json.encodeToString(entries) }
    }

    private suspend fun load(): List<Entry> {
        val raw = context.qualityStore.data.first()[KEY_MEMORY] ?: return emptyList()
        return runCatching { json.decodeFromString<List<Entry>>(raw) }.getOrDefault(emptyList())
    }

    private fun key(network: PlaybackNetwork, mediaItemId: Long) = "${network.id}:$mediaItemId"

    private companion object {
        val KEY_MEMORY = stringPreferencesKey("quality_memory")
        val KEY_REELS = stringPreferencesKey("reels_quality_memory")
        const val MAX_ENTRIES = 300
    }
}

/**
 * 片段的画质策略（iOS 没有这一层：iOS 的刷片一律原画直出）。
 *
 * 「自动」的含义按网络分档：**局域网原画直出**（服务端按文件签发令牌，零转码、起播最快），
 * **外网 720p**（借正片的播放会话转码，见 `ReelsPlayers.openSource`）。用户显式选过就按选的走。
 */
object ReelsQuality {
    const val AUTO = 0

    val options: List<Pair<Int, String>> = listOf(
        AUTO to "自动",
        2160 to "4K",
        1080 to "1080p",
        720 to "720p",
    )

    /** 这一档在当前网络下实际会用什么（给界面写小字用） */
    fun label(cap: Int, network: PlaybackNetwork): String = when (cap) {
        AUTO -> if (network == PlaybackNetwork.AWAY) "自动（外网 720p）" else "自动（局域网原画）"
        else -> options.firstOrNull { it.first == cap }?.second ?: "自动"
    }

    /** 记住的档位 → 这次实际要用的上限；null = 直出 */
    fun effectiveCap(cap: Int, network: PlaybackNetwork): Int? = when (cap) {
        AUTO -> if (network == PlaybackNetwork.AWAY) 720 else null
        else -> cap
    }
}

/** 网络环境:服务器是私网地址 → 局域网;公网域名/IP → 外网(iOS 另有同网段判定,这里按私网近似) */
enum class PlaybackNetwork(val id: String, val label: String) {
    HOME("home", "局域网"),
    AWAY("away", "外网"),
    UNKNOWN("unknown", ""),
    ;

    companion object {
        fun of(host: String?): PlaybackNetwork {
            if (host.isNullOrEmpty()) return UNKNOWN
            return runCatching {
                val address = InetAddress.getByName(host)
                if (address.isSiteLocalAddress || address.isLoopbackAddress) HOME else AWAY
            }.getOrDefault(AWAY)
        }
    }
}
