package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.generated.PlaybackMetricPayload
import java.util.UUID

/**
 * 一次播放的质量记录（docs/design/playback-qoe.md，Apple 端 PlaybackRecord.swift 的精简版）：每个单元一条、
 * 错误页上重试再起一条，离开时上报（所有结局都报）。[id] 同时作为开会话的 `attempt_id`，服务端据此把日志串起来。
 *
 * 只记在内存里：Apple 端会落盘、闪退后下次启动补报，这里先不做（电视上很少被杀）。
 */
class PlaybackRecord(val unit: PlaybackUnit, val origin: String, private val startedAt: Long) {
    val id: String = UUID.randomUUID().toString().lowercase()
    var tier: Long = -1
    var degradedFrom: Long? = null
    var libraryFileId: Long? = null
    var hwBackend: String = ""
    var route: String = ""
    var firstFrameAt: Long? = null
        private set

    /** 起播到首帧的耗时（毫秒）；还没出首帧时 null */
    val firstFrameMs: Long?
        get() = firstFrameAt?.let { it - startedAt }
    var rebufferCount = 0L
        private set
    var rebufferMs = 0L
        private set
    private var rebufferSince: Long? = null
    var seekCount = 0L
        private set
    var watchedMs = 0L
    var errorKind = ""
    var errorCategory = ""
    var errorStage = ""

    fun noteFirstFrame(now: Long) {
        if (firstFrameAt == null) firstFrameAt = now
    }

    fun beginRebuffer(now: Long) {
        if (rebufferSince != null) return
        rebufferCount += 1
        rebufferSince = now
    }

    fun endRebuffer(now: Long) {
        rebufferSince?.let { rebufferMs += now - it }
        rebufferSince = null
    }

    fun noteSeek() {
        seekCount += 1
    }

    fun noteError(message: String, category: String, stage: String) {
        errorKind = message.take(120)
        errorCategory = category
        errorStage = stage
    }

    /** 结局：出错 → failed；没出过画 → exit_before_start；播完或到了片尾附近 → watched；其余 exited */
    fun outcome(phaseIsError: Boolean, phaseIsEnded: Boolean, positionMs: Long, durationMs: Long?): String = when {
        phaseIsError -> "failed"
        firstFrameAt == null -> "exit_before_start"
        phaseIsEnded -> "watched"
        durationMs != null && durationMs > 0 && positionMs >= durationMs - maxOf(60_000L, durationMs / 20) -> "watched"
        else -> "exited"
    }

    fun payload(
        outcome: String, now: Long, network: PlaybackNetwork, appVersion: String,
        droppedFrames: Long?, totalFrames: Long?,
    ): PlaybackMetricPayload {
        endRebuffer(now)
        val ttff = firstFrameMs
        return PlaybackMetricPayload(
            libraryFileId = libraryFileId,
            tier = tier,
            degradedFrom = degradedFrom,
            engine = "exo",
            hwBackend = hwBackend,
            ttffMs = ttff,
            firstFrameMs = ttff,
            rebufferMs = rebufferMs,
            rebufferCount = rebufferCount,
            seekCount = seekCount,
            droppedFrames = droppedFrames,
            totalFrames = totalFrames,
            watchedMs = watchedMs,
            attemptId = id,
            outcome = outcome,
            mediaItemId = unit.mediaItemId,
            seasonNumber = unit.season,
            episodeNumber = unit.episode,
            origin = origin,
            client = "androidtv",
            route = route,
            networkClass = network.key,
            appVersion = appVersion,
            playingMs = watchedMs,
            errorKind = errorKind.ifEmpty { null },
            errorCategory = errorCategory.ifEmpty { null },
            errorStage = errorStage.ifEmpty { null },
        )
    }
}
