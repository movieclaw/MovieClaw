package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.McJson
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/**
 * 这台机器上实测坏掉的解码器（androidtv-app.md §8「厂商 ROM 的解码器怪癖」）：盒子自报能解 4K HEVC、实际花屏 / 报错的
 * 不少见。确定这一路解不了（原位重试也救不回来、要改走服务端）时记下出错的解码器：之后选解码器跳过它、能力探测也
 * 不再算它——这台机器真的没别的解码器时，服务端一开始就给服务端流，不用每次先失败一回。
 *
 * 30 天过期、App 升级清空：厂商会推固件修解码器，不能永远拉黑。
 */
class DecoderDenylist(private val prefs: PrefsStore, private val appVersion: String, private val now: () -> Long = System::currentTimeMillis) {
    data class Entry(val mime: String, val at: Long, val appVersion: String, val reason: String)

    private fun load(): Map<String, Entry> {
        val root = prefs.string(KEY)?.let { runCatching { McJson.parseToJsonElement(it).jsonObject }.getOrNull() } ?: return emptyMap()
        return root.mapNotNull { (name, value) ->
            runCatching {
                val o = value.jsonObject
                name to Entry(o["mime"]!!.jsonPrimitive.content, o["at"]!!.jsonPrimitive.long, o["app"]!!.jsonPrimitive.content, o["reason"]?.jsonPrimitive?.content ?: "")
            }.getOrNull()
        }.toMap().filterValues { it.appVersion == appVersion && now() - it.at < TTL_MS }
    }

    private fun save(entries: Map<String, Entry>) {
        val root = JsonObject(
            entries.mapValues { (_, e) ->
                JsonObject(mapOf("mime" to JsonPrimitive(e.mime), "at" to JsonPrimitive(e.at), "app" to JsonPrimitive(e.appVersion), "reason" to JsonPrimitive(e.reason)))
            },
        )
        prefs.putString(KEY, root.toString())
    }

    fun isDenied(decoderName: String): Boolean = decoderName in load()

    fun deny(decoderName: String, mime: String, reason: String) {
        save(load() + (decoderName to Entry(mime, now(), appVersion, reason.take(200))))
        EngineLog.add("player", "拉黑解码器 $decoderName（$mime）：$reason")
    }

    fun clear() = prefs.putString(KEY, null)

    /** 设备快照里列出来，真机排查时一眼看到哪个解码器被避开了 */
    fun entries(): Map<String, Entry> = load()

    companion object {
        private const val KEY = "playback.decoder-denylist"
        const val TTL_MS = 30L * 24 * 3600 * 1000
    }
}
