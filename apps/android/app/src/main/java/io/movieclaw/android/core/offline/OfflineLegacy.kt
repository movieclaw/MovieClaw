package io.movieclaw.android.core.offline

import java.io.File
import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * 旧版安卓（0.8.0 及以前）的离线存档迁移：那时按「地址 + 用户名」分目录（`owner_<摘要>/`），
 * 每个单元一个 `pack.json`（片名、海报等少量字段）+ `video.<扩展名>`，没有详情、分集、字幕与播放数据。
 *
 * 迁成与 iOS 同一格式：摘要 + 已完成的单元 + 本机进度（只有「看完了」）+ 没补传的观看记录。
 * 详情等展示数据留空：离线时退回极简详情（能播、能删），下次联网由 [OfflineStore.refreshArchivedMetadataIfNeeded] 补齐。
 */
internal object OfflineLegacy {
    private val loose = Json { ignoreUnknownKeys = true }

    private fun legacyKey(origin: String, username: String): String =
        MessageDigest.getInstance("SHA-256").digest((origin.trimEnd('/') + "\n" + username).toByteArray())
            .joinToString("") { "%02x".format(it) }.take(16)

    /** 在写盘线程上调 */
    fun migrate(owner: OfflineOwner, apiJson: Json) {
        val old = File(OfflineDisk.root, "owner_${legacyKey(owner.origin, owner.username)}")
        if (!old.isDirectory) return
        val key = owner.key
        OfflineDisk.write(OfflineOwner.serializer(), owner, OfflineDisk.ownerFile(key))
        val now = System.currentTimeMillis()
        for (itemDir in OfflineDisk.children(old).filter { it.isDirectory }) {
            for (fileDir in OfflineDisk.children(itemDir).filter { it.isDirectory }) {
                runCatching { migrateUnit(key, fileDir, now) }
            }
        }
        old.deleteRecursively()
    }

    private fun migrateUnit(key: String, dir: File, now: Long) {
        val pack = loose.parseToJsonElement(File(dir, "pack.json").readText()).jsonObject
        fun str(name: String) = pack[name]?.jsonPrimitive?.content?.takeIf { it != "null" }
        fun num(name: String) = pack[name]?.jsonPrimitive?.longOrNull
        val itemId = num("mediaItemId") ?: return
        val fileId = num("fileId") ?: return
        val video = dir.listFiles()?.firstOrNull { it.name.startsWith("video.") && it.name != "video.part" && it.length() > 0 } ?: return
        val season = (num("seasonNumber") ?: 0).toInt()
        val episode = (num("episodeNumber") ?: 0).toInt()
        val profile = str("profile") ?: "original"
        val summaryFile = OfflineDisk.summaryFile(key, itemId)
        if (!summaryFile.isFile) {
            OfflineDisk.write(
                OfflineItemSummary.serializer(),
                OfflineItemSummary(
                    mediaItemId = itemId, libraryId = num("libraryId") ?: 0, libraryName = str("libraryName").orEmpty(),
                    libraryKind = if (season > 0) "tv" else "movie", kind = if (season > 0) "tv" else "movie",
                    title = str("title").orEmpty(), posterUrl = str("posterUrl"), addedAt = now,
                ),
                summaryFile,
            )
        }
        val ext = video.extension.ifEmpty { "mkv" }
        val unit = OfflineUnit(
            fileId = fileId, mediaItemId = itemId, season = season, episode = episode, profile = profile,
            profileLabel = if (profile == "original") "原画" else profile, state = OfflineUnit.State.done,
            expectedBytes = video.length(), receivedBytes = video.length(), fileExtension = ext, createdAt = now, completedAt = now,
        )
        val unitDir = OfflineDisk.unitDir(key, itemId, fileId)
        unitDir.mkdirs()
        if (!video.renameTo(File(unitDir, unit.mediaFileName))) return
        OfflineDisk.write(OfflineUnit.serializer(), unit, OfflineDisk.unitFile(key, itemId, fileId))
        OfflineDisk.write(
            OfflinePlaybackSpec.serializer(),
            OfflinePlaybackSpec(durationMs = num("durationMs"), container = if (profile == "original") ext else "mp4"),
            OfflineDisk.playbackFile(key, itemId, fileId),
        )
        if (pack["played"]?.jsonPrimitive?.booleanOrNull == true) {
            val progressFile = OfflineDisk.progressFile(key, itemId)
            val map = OfflineDisk.readProgress(progressFile).orEmpty() +
                ("$season-$episode" to OfflineProgress(0, true, num("durationMs"), now))
            OfflineDisk.writeProgress(map, progressFile)
        }
        // 没补传的观看记录：当成已结束、待发
        val viewings = File(dir, "viewings.json").takeIf { it.isFile }?.let { runCatching { loose.parseToJsonElement(it.readText()) as? JsonArray }.getOrNull() }
        viewings?.forEach { entry ->
            val record = (entry as? JsonObject)?.get("record") as? JsonObject ?: return@forEach
            fun rs(name: String) = record[name]?.jsonPrimitive?.content
            fun rn(name: String) = record[name]?.jsonPrimitive?.longOrNull
            val id = rs("viewing_id") ?: return@forEach
            fun time(name: String) = rs(name)?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() }.getOrNull() } ?: now
            OfflineDisk.write(
                OfflineViewing.serializer(),
                OfflineViewing(
                    viewingId = id, mediaItemId = itemId, season = season, episode = episode, fileId = fileId,
                    startedAt = time("started_at"), updatedAt = time("updated_at"), startPositionMs = rn("start_position_ms") ?: 0,
                    positionMs = rn("position_ms") ?: 0, watchedMs = rn("watched_ms") ?: 0,
                    completed = record["completed"]?.jsonPrimitive?.booleanOrNull ?: false, ended = true,
                    durationMs = rn("duration_ms"), dirty = true,
                ),
                OfflineDisk.viewingFile(key, id),
            )
        }
    }
}
