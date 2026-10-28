package io.movieclaw.android.core.offline

import io.movieclaw.android.core.designsystem.resolveImageUrl
import io.movieclaw.android.core.model.OfflineManifest
import java.io.File
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * 打包一个单元视频之外的东西（docs/design/offline-download.md §5.4「准备中」；iOS `OfflinePackager`）：
 * 展示数据（详情、库、这一季的分集）、播放数据（片段、章节、轨道）、字幕、图片。
 * 都在前台、普通接口通道里拉（体积小）；图片缺了不影响完成，其余失败整次准备失败、对账时重来。
 *
 * 与 iOS 的一处取舍：不下 ASS 的内嵌字体——安卓播放器在线时也不取服务端的字体（libass 用自带字体），
 * 下了也用不上。
 */
class OfflinePackager(
    private val client: OkHttpClient,
    /** 当前选中的入口（`http(s)://host:port[/子路径]`），清单里的 `/api/v1/...` 拼在它后面 */
    private val base: String,
    private val ownerKey: String,
    private val manifest: OfflineManifest,
    private val unit: OfflineUnit,
    private val store: OfflineStore,
) {
    suspend fun run() {
        val itemId = manifest.mediaItemId
        val key = ownerKey
        val unitDir = OfflineDisk.unitDir(key, itemId, unit.fileId)
        val detail = store.encodeApi(manifest.item)
        val library = store.encodeApi(manifest.library)
        val season = store.encodeApi(manifest.season)
        val seasonNumber = store.decodeSeason(manifest.season)?.seasonNumber ?: manifest.seasonNumber
        OfflineDisk.perform {
            detail?.let { OfflineDisk.writeText(it, OfflineDisk.detailFile(key, itemId)) }
            library?.let { OfflineDisk.writeText(it, OfflineDisk.libraryFile(key, itemId)) }
            season?.let { OfflineDisk.writeText(it, OfflineDisk.seasonFile(key, itemId, seasonNumber)) }
            unitDir.mkdirs()
        }

        // 打包时服务器上的续播点：本机还没有进度时先用它（离线时从这里接着看）
        val resume = manifest.resumePositionMs
        if (resume != null && resume > 0 && store.localProgress(itemId, unit.season, unit.episode) == null) {
            store.recordProgress(itemId, unit.season, unit.episode, resume, false, manifest.durationMs, at = 0)
        }

        // 字幕：原画档的内封轨在文件里，引擎自己读；外挂轨、转码档的全部文字轨存成旁挂文件。
        // 文本轨请服务端转成 VTT 存（播放器与调时间轴的叠层都认 VTT），ASS 原样存（保留定位与样式）
        val original = unit.profile == "original"
        val subtitles = mutableListOf<OfflinePlaybackSpec.Subtitle>()
        manifest.subtitles.forEachIndexed { index, sub ->
            if (original && sub.embedded) return@forEachIndexed
            val url = sub.url ?: return@forEachIndexed
            val ass = sub.format == "ass" || sub.format == "ssa"
            val ext = if (ass) "ass" else "vtt"
            val name = "$index-${OfflineDisk.safeName(sub.language ?: "und")}.$ext"
            val fetchUrl = if (ass) url else url.replace("format=srt", "format=vtt").let { if (it.contains("format=")) it else "$it&format=vtt" }
            val bytes = fetch(fetchUrl)
            OfflineDisk.perform { OfflineDisk.writeBytes(bytes, File(unitDir, "subs/$name")) }
            subtitles += OfflinePlaybackSpec.Subtitle(
                ref = "external:$name", fileName = name, kind = if (ass) "ass" else "vtt",
                language = sub.language, title = sub.title, isDefault = sub.isDefault,
                isForced = sub.isForced, isAi = sub.isAi, sourceRef = sub.trackRef,
            )
        }

        val detailView = store.decodeDetail(manifest.item)
        val file = detailView?.files?.firstOrNull { it.id == unit.fileId }
        val audioTracks = if (original) manifest.audioTracks else manifest.audioTracks?.let { tracks ->
            (tracks as? kotlinx.serialization.json.JsonArray)?.filter { track ->
                (track as? kotlinx.serialization.json.JsonObject)?.get("ref")
                    ?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content } == manifest.defaultAudio
            }?.let { kotlinx.serialization.json.JsonArray(it) }
        }
        val spec = OfflinePlaybackSpec(
            durationMs = manifest.durationMs,
            chapters = manifest.chapters,
            segments = manifest.segments,
            audioTracks = audioTracks,
            defaultAudio = manifest.defaultAudio,
            subtitles = subtitles,
            resolution = if (original) file?.resolution else unit.profile,
            videoCodec = if (original) file?.videoCodec else null,
            container = if (original) manifest.container else "mp4",
        )
        OfflineDisk.perform { OfflineDisk.write(OfflinePlaybackSpec.serializer(), spec, OfflineDisk.playbackFile(key, itemId, unit.fileId)) }

        saveImages(detailView)
    }

    /** 详情页、海报格、分集卡、演职员要的图，每张存一份（按图片键，任何显示宽度都用它） */
    private suspend fun saveImages(detail: io.movieclaw.android.core.model.LibraryItemDetailView?) {
        val itemId = manifest.mediaItemId
        val wanted = mutableListOf<Pair<String, Int>>()
        fun add(raw: String?, width: Int) {
            if (!raw.isNullOrEmpty()) wanted += raw to width
        }
        add(detail?.posterUrl, 780)
        add(detail?.backdropUrl, 1920)
        add(detail?.logoUrl, 780)
        detail?.localMeta?.actors?.take(20)?.forEach { add(it.thumbUrl, 300) }
        detail?.localMeta?.directorCredits?.take(5)?.forEach { add(it.thumbUrl, 300) }
        store.decodeSeason(manifest.season)?.episodes?.take(80)?.forEach { add(it.stillUrl, 600) }

        val dir = OfflineDisk.imagesDir(ownerKey, itemId)
        val index = OfflineDisk.perform { OfflineImages.readIndex(dir) ?: emptyMap() }.toMutableMap()
        for ((raw, width) in wanted) {
            val url = resolveImageUrl(raw, base.trimEnd('/'), width)?.toHttpUrlOrNull() ?: continue
            val key = OfflineImages.key(url)
            if (index.containsKey(key)) continue
            val (bytes, mime) = runCatching {
                client.newCall(Request.Builder().url(url).build()).execute().use { resp ->
                    if (resp.code != 200) null else resp.body.bytes().takeIf { it.isNotEmpty() }?.let { it to resp.header("Content-Type").orEmpty() }
                }
            }.getOrNull() ?: continue
            val ext = when {
                mime.contains("png") -> "png"
                mime.contains("webp") -> "webp"
                else -> "jpg"
            }
            val name = OfflineDisk.imageFileName(key, ext)
            val target = File(dir, name)
            val ok = runCatching { OfflineDisk.perform { OfflineDisk.writeBytes(bytes, target) } }.isSuccess
            if (!ok) continue
            index[key] = name
            OfflineImages.register(key, target, itemId)
        }
        val snapshot = index.toMap()
        OfflineDisk.enqueue { OfflineImages.writeIndex(dir, snapshot) }
    }

    /** 清单里的地址是 `/api/v1/...` 的绝对路径（字幕带了签名 token） */
    private fun fetch(path: String): ByteArray {
        val url = if (path.startsWith("http")) path else base.trimEnd('/') + path
        val request = Request.Builder().url(url).build()
        val slow = client.newBuilder().readTimeout(600, java.util.concurrent.TimeUnit.SECONDS).build()
        slow.newCall(request).execute().use { resp ->
            if (resp.code !in 200..299) throw OfflineHttpException(resp.code, "附件下载失败（HTTP ${resp.code}）")
            return resp.body.bytes()
        }
    }
}

/** 准备阶段的 HTTP 失败（按状态码分可重试与否） */
class OfflineHttpException(val status: Int, message: String) : java.io.IOException(message)
