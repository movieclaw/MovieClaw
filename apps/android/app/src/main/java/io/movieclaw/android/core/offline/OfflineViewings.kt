package io.movieclaw.android.core.offline

import io.movieclaw.android.core.AppScopes
import io.movieclaw.android.core.api.McApi
import io.movieclaw.android.core.model.OfflineViewingRecord
import io.movieclaw.android.core.model.OfflineViewingsRequest
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.core.playback.LocalViewing
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.launch

/**
 * 本机播放的观看记录（docs/design/offline-download.md §7；iOS `OfflineViewingRecorder`）。
 *
 * 本机播放一律走这条路，在线离线一样；流式播放保持实时上报。两条不混用，免得一次观看被记两遍。
 * 先落盘再发：每 10 秒、暂停、停止、退后台时写一次；能连上就发最新的快照，连不上攒着，回来后一批补传。
 * 服务端按编号幂等合并、按发生时间判新旧、校正手机时钟偏差。
 */
class OfflineViewingRecorder(
    unit: OfflineUnit,
    startPositionMs: Long,
    durationMs: Long?,
    private val store: OfflineStore,
    private val ownerKey: String,
    /** 能连上时立即发（离线时为 null 也没关系：下次可达时由外壳补传） */
    private val api: () -> McApi?,
) : LocalViewing {
    private var record: OfflineViewing
    /** 上一次计时的时刻（在播时才累计观看时长） */
    private var lastTick: Long? = null
    private var lastSave = 0L
    /** 这次播放有没有真的开始（还没出画就退出的不记） */
    private var started = false

    init {
        val now = System.currentTimeMillis()
        record = OfflineViewing(
            viewingId = UUID.randomUUID().toString().lowercase(),
            mediaItemId = unit.mediaItemId, season = unit.season, episode = unit.episode, fileId = unit.fileId,
            startedAt = now, updatedAt = now, startPositionMs = startPositionMs, positionMs = startPositionMs,
            watchedMs = 0, completed = false, ended = false, durationMs = durationMs, dirty = true,
            launch = OfflineViewingUploader.launch,
        )
    }

    /** 播放读数（播放器每秒调一次）：在播的墙钟时间才算观看时长 */
    @Synchronized
    override fun tick(positionMs: Long, playing: Boolean, durationMs: Long?) {
        val now = System.currentTimeMillis()
        val wasPlaying = lastTick != null
        val last = lastTick
        var watched = record.watchedMs
        if (playing && last != null) watched += maxOf(0, now - last)
        lastTick = if (playing) now else null
        // 刚暂停：立即落一次盘（暂停后被系统回收也不丢这段进度）
        if (wasPlaying && !playing) lastSave = 0
        if (playing) started = true
        record = record.copy(
            positionMs = positionMs, updatedAt = now, durationMs = durationMs ?: record.durationMs, watchedMs = watched, dirty = true,
        )
        if (started && now - lastSave >= 10_000) save()
    }

    /** 暂停、退后台：立即落一次盘并尝试发出 */
    @Synchronized
    override fun checkpoint() {
        if (started) save()
    }

    /** 这次播放结束（退出、换集、播完） */
    @Synchronized
    override fun finish(positionMs: Long, completed: Boolean) {
        if (!started && !completed) return
        record = record.copy(
            positionMs = positionMs, completed = record.completed || completed, ended = true,
            updatedAt = System.currentTimeMillis(), dirty = true,
        )
        save()
    }

    private fun save() {
        lastSave = System.currentTimeMillis()
        val snapshot = record
        val current = store.localProgress(snapshot.mediaItemId, snapshot.season, snapshot.episode)
        val outcome = resolve(
            positionMs = if (snapshot.completed) null else snapshot.positionMs,
            runtimeMs = snapshot.durationMs,
            currentlyPlayed = current?.played ?: false,
        )
        store.recordProgress(snapshot.mediaItemId, snapshot.season, snapshot.episode, outcome.first, outcome.second, snapshot.durationMs)
        val key = ownerKey
        OfflineDisk.enqueue { OfflineDisk.write(OfflineViewing.serializer(), snapshot, OfflineDisk.viewingFile(key, snapshot.viewingId)) }
        api()?.let { OfflineViewingUploader.flush(it, key) }
    }

    companion object {
        /**
         * 本机续播点与服务端同一套阈值（movieclaw_playback/progress.py `resolve_progress`）：
         * 不足 5% 不记续播点、超过 90% 或离结尾 1 秒内算看完、短于 5 分钟的片过了开头就算看完。
         * 不同口径的话，离线时显示「继续 0:12」，连上之后服务端却说没看过
         */
        fun resolve(positionMs: Long?, runtimeMs: Long?, currentlyPlayed: Boolean): Pair<Long, Boolean> {
            if (positionMs == null) return 0L to true
            if (positionMs <= 0) return 0L to currentlyPlayed
            if (runtimeMs == null || runtimeMs <= 0) return 0L to true
            val pct = positionMs.toDouble() / runtimeMs * 100
            if (pct < 5) return 0L to currentlyPlayed
            if (pct > 90 || positionMs >= runtimeMs - 1000) return 0L to true
            if (runtimeMs < 300_000) return 0L to true
            return positionMs to currentlyPlayed
        }
    }
}

/** 把攒着的观看记录发给服务器：同一时刻只有一个在途请求；确认后、且这次播放已结束的才删 */
object OfflineViewingUploader {
    /** 这次启动的编号（见 [OfflineViewing.launch]） */
    val launch: String = UUID.randomUUID().toString()

    private val scope = AppScopes.io("OfflineViewingUploader")
    private var inFlight = false
    private var again = false

    fun flush(api: McApi, ownerKey: String) {
        synchronized(this) {
            if (inFlight) {
                again = true
                return
            }
            inFlight = true
        }
        scope.launch {
            while (true) {
                synchronized(this@OfflineViewingUploader) { again = false }
                runCatching { send(api, ownerKey) }
                synchronized(this@OfflineViewingUploader) {
                    if (!again) {
                        inFlight = false
                        return@launch
                    }
                }
            }
        }
    }

    private suspend fun send(api: McApi, ownerKey: String) {
        val dir = OfflineDisk.viewingsDir(ownerKey)
        // 在写盘线程上读：与播放器排着的快照写入保持先后
        val records = OfflineDisk.perform {
            OfflineDisk.children(dir).mapNotNull { file ->
                var record = OfflineDisk.read(OfflineViewing.serializer(), file) ?: return@mapNotNull null
                if (!record.ended && record.launch != launch) {
                    // 上次启动时播放中被强退：这次播放到最后一次落盘的位置就结束了
                    record = record.copy(ended = true, dirty = true)
                    OfflineDisk.write(OfflineViewing.serializer(), record, file)
                }
                record.takeIf { it.dirty }
            }
        }
        if (records.isEmpty()) return
        for (batch in records.chunked(100)) {
            val body = OfflineViewingsRequest(
                sentAt = Instant.now().toString(),
                records = batch.map { record ->
                    OfflineViewingRecord(
                        viewingId = record.viewingId, mediaItemId = record.mediaItemId,
                        seasonNumber = record.season, episodeNumber = record.episode, fileId = record.fileId,
                        startedAt = Instant.ofEpochMilli(record.startedAt).toString(),
                        updatedAt = Instant.ofEpochMilli(record.updatedAt).toString(),
                        startPositionMs = record.startPositionMs, positionMs = record.positionMs,
                        watchedMs = record.watchedMs, completed = record.completed, ended = record.ended,
                        durationMs = record.durationMs,
                    )
                },
            )
            val result = runCatching { api.playbackViewings(body).dataOrThrow() }.getOrNull() ?: return
            val acknowledged = result.results.map { it.viewingId }.toSet()
            // 同样在写盘线程上：不然读到旧快照、写回「已发」的同时，播放器的新快照刚好落盘，会被盖掉
            val newer = OfflineDisk.perform {
                var newer = false
                for (record in batch.filter { it.viewingId in acknowledged }) {
                    val file = OfflineDisk.viewingFile(ownerKey, record.viewingId)
                    val current = OfflineDisk.read(OfflineViewing.serializer(), file) ?: continue
                    if (current != record) {
                        // 发出去之后又有了新快照（还在播）：留着，再发一次
                        newer = true
                        continue
                    }
                    if (current.ended) OfflineDisk.remove(file)
                    else OfflineDisk.write(OfflineViewing.serializer(), current.copy(dirty = false), file)
                }
                newer
            }
            if (newer) synchronized(this) { again = true }
        }
    }

    /** 是否还有没确认的记录（在线拿到服务器的续播点时，有待发的本机记录就不拿服务器的覆盖本机进度） */
    fun hasPending(ownerKey: String, itemId: Long, season: Int, episode: Int): Boolean =
        OfflineDisk.children(OfflineDisk.viewingsDir(ownerKey)).any { file ->
            val record = OfflineDisk.read(OfflineViewing.serializer(), file) ?: return@any false
            record.mediaItemId == itemId && record.season == season && record.episode == episode && record.dirty
        }
}
