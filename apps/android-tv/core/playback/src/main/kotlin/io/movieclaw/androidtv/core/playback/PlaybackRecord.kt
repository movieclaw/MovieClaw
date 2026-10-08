package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.generated.PlaybackMetricPayload
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID

/**
 * 一次播放的质量记录（docs/design/playback-qoe.md，口径与 Apple 端 PlaybackRecord.swift 一致）：每个单元一条、
 * 错误页上重试再起一条，离开时上报（所有结局都报）。[id] 同时作为开会话的 `attempt_id`，服务端据此把日志串起来。
 *
 * 明细按服务端 `services/playback/qoe.py` 读的键组织：起播分段、跳转、换轨、中断（卡顿按播放头判）、规格快照、
 * 行为、环境、设备、资源、时间线。真机上的问题（种子用户）靠它和失败时附带的引擎日志尾巴还原现场。
 *
 * 时间一律是 [clock] 的毫秒数（生产用 `SystemClock.elapsedRealtime`，单测注入）。
 */
class PlaybackRecord(
    val unit: PlaybackUnit,
    val origin: String,
    private val startedAt: Long,
    private val clock: () -> Long,
    /** 实验室场景名（调试参数 mc_lab）；空 = 真实使用，统计默认排除非空的 */
    val lab: String = "",
) {
    val id: String = UUID.randomUUID().toString().lowercase()
    var tier: Long = -1
    var degradedFrom: Long? = null
    var libraryFileId: Long? = null
    var hwBackend: String = ""
    var route: String = ""
    var watchedMs = 0L
    var errorKind = ""
    var errorCategory = ""
    var errorStage = ""

    var firstFrameAt: Long? = null
        private set
    private var playingAt: Long? = null

    /** 起播到首帧的耗时（毫秒，已扣掉等用户拍板的时间）；还没出首帧时 null */
    val firstFrameMs: Long?
        get() = firstFrameAt?.let { (it - startedAt - userWaitMs).coerceAtLeast(0) }

    private fun elapsed(at: Long = clock()) = (at - startedAt).coerceAtLeast(0)
    private val sinceFirstFrameMs: Long? get() = firstFrameAt?.let { clock() - it }

    // ---- 快：起播 ----

    private val marks = linkedMapOf<String, Long>()
    var startPositionMs = 0L
    var resumed = false
    private var userWaitStartedAt: Long? = null
    private var userWaitMs = 0L

    /** 起播检查点（deciding / session_ready / media_prepared / first_frame / playing），每个只记第一次 */
    fun mark(name: String) {
        if (name !in marks) marks[name] = elapsed()
    }

    /** 等用户拍板（软件转码同意弹窗）的时间不算进起播 */
    fun beginUserWait() {
        if (userWaitStartedAt == null) userWaitStartedAt = clock()
    }

    fun endUserWait() {
        userWaitStartedAt?.let { userWaitMs += clock() - it }
        userWaitStartedAt = null
    }

    fun noteFirstFrame(now: Long = clock()) {
        if (firstFrameAt != null) return
        firstFrameAt = now
        mark("first_frame")
        awaitingResumeSince = now
        event("first_frame", "首帧")
    }

    fun notePlaying() {
        if (playingAt == null) playingAt = clock()
        mark("playing")
    }

    // ---- 快：跳转 ----

    private class Seek(
        val seq: Int, val source: String, val fromMs: Long, val toMs: Long, val buffered: Boolean, val paused: Boolean,
        val restart: Boolean, val atMs: Long, var ms: Long? = null, var outcome: String = "pending",
    )

    private val seeks = mutableListOf<Seek>()
    private var openSeek: Pair<Seek, Long>? = null

    val seekCount: Long get() = seeks.size.toLong()

    /** 发起一次跳转。[source]：dpad（左右键 ±10）/ scrub（拖动）/ skip（跳过片头片尾）/ chapter / media_key / auto */
    fun beginSeek(source: String, fromMs: Long, toMs: Long, buffered: Boolean, paused: Boolean, restart: Boolean) {
        val now = clock()
        openSeek?.let { (seek, at) ->
            seek.ms = now - at
            seek.outcome = "superseded"
        }
        closeStall(now)
        awaitingResumeSince = null
        val seek = Seek(seeks.size + 1, source, fromMs, toMs, buffered, paused, restart, elapsed(now))
        if (seeks.size < MAX_LIST) seeks.add(seek)
        openSeek = seek to now
        // 续播后 30 秒内的远跳：续播位置猜错了（进北极星）
        val since = sinceFirstFrameMs
        if (resumed && since != null && since <= MISGUESS_WINDOW_MS && kotlin.math.abs(toMs - fromMs) > 120_000) {
            noteBehavior("resume_seek", fromMs.toString(), toMs.toString(), misguess = true)
        }
        event("seek", "跳转 $source ${fromMs / 1000}s → ${toMs / 1000}s${if (restart) "（换会话）" else ""}")
    }

    /** 跳转落地（落点画面出来了）。返回耗时，没有在途的跳转返回 null */
    fun seekPresented(): Long? {
        val (seek, at) = openSeek ?: return null
        val now = clock()
        seek.ms = now - at
        seek.outcome = "landed"
        openSeek = null
        awaitingResumeSince = now
        event("seek_landed", "跳转落地 ${seek.ms} 毫秒")
        return seek.ms
    }

    fun seekFailed() {
        val (seek, at) = openSeek ?: return
        seek.ms = clock() - at
        seek.outcome = "failed"
        openSeek = null
    }

    val seekPending: Boolean get() = openSeek != null

    // ---- 快：换音轨 / 字幕 / 画质 ----

    private class Switch(val kind: String, val from: String?, val to: String?, val atMs: Long, var ms: Long? = null)

    private val switches = mutableListOf<Switch>()
    private var openSwitch: Pair<Switch, Long>? = null

    /** 开始一次切换（audio / subtitle / quality）；不用重载、当场生效的传 [immediate] */
    fun beginSwitch(kind: String, from: String?, to: String?, immediate: Boolean = false) {
        val now = clock()
        val item = Switch(kind, from, to, elapsed(now), if (immediate) 0 else null)
        if (switches.size < MAX_LIST) switches.add(item)
        openSwitch = if (immediate) null else item to now
        event("switch", "切换 $kind ${from ?: "-"} → ${to ?: "-"}")
    }

    /** 切换后的首帧 / 就绪：记下耗时；15 秒还没结果的作废（留空） */
    fun switchPresented() {
        val (item, at) = openSwitch ?: return
        val ms = clock() - at
        item.ms = ms.takeIf { it <= SWITCH_TIMEOUT_MS }
        openSwitch = null
        awaitingResumeSince = clock()
    }

    // ---- 稳：卡顿（按播放头判）、重连、报错 ----

    private class Interruption(val kind: String, val atMs: Long, val ms: Long?, val cause: String? = null, val detail: String? = null)

    private val interruptions = mutableListOf<Interruption>()
    private var stallOpen: Triple<Long, Long, String>? = null // 开始时刻、距起点、原因
    private var lastPlayheadMs: Long? = null
    private var lastAdvanceAt: Long? = null
    private var awaitingResumeSince: Long? = null
    private var reconnectOpen: Triple<Long, Long, String>? = null
    var rebufferCount = 0L
        private set
    var rebufferMs = 0L
        private set
    private var engineTrouble = false

    /**
     * 每 250 毫秒采一次播放头。[eligible]：用户想看、出过画、不在后台、没在跳转或换轨。播放头 0.5 秒不走算一次卡顿；
     * 首帧、跳转落地、切换出画后 1.5 秒内不判（起步宽限，§3.2），过了还不走从那一刻起算。[cause] 在卡顿开始时问一次。
     */
    fun samplePlayhead(positionMs: Long, eligible: Boolean, cause: () -> String) {
        val now = clock()
        if (!eligible) {
            closeStall(now)
            lastPlayheadMs = positionMs
            lastAdvanceAt = now
            return
        }
        val last = lastPlayheadMs
        if (last == null) {
            // 第一次采样只记基准，不算「走动」：起步宽限要留着
            lastPlayheadMs = positionMs
            lastAdvanceAt = now
            return
        }
        if (positionMs != last) {
            closeStall(now)
            lastPlayheadMs = positionMs
            lastAdvanceAt = now
            awaitingResumeSince = null
            return
        }
        if (stallOpen != null) return
        val grace = awaitingResumeSince
        if (grace != null) {
            if (now - grace < RESUME_GRACE_MS) return
            awaitingResumeSince = null
            openStall(grace, cause())
            return
        }
        val since = lastAdvanceAt ?: now
        if (now - since >= STALL_MS) openStall(since, cause())
    }

    private fun openStall(at: Long, cause: String) {
        stallOpen = Triple(at, elapsed(at), cause)
        event("rebuffer", "卡顿开始（$cause）")
    }

    private fun closeStall(now: Long) {
        val (at, atMs, cause) = stallOpen ?: return
        stallOpen = null
        val ms = now - at
        rebufferCount += 1
        rebufferMs += ms
        add(Interruption("rebuffer", atMs, ms, cause))
        event("rebuffer_end", "卡顿 $ms 毫秒")
    }

    val stalling: Boolean get() = stallOpen != null

    fun beginReconnect(reason: String) {
        if (reconnectOpen != null) return
        reconnectOpen = Triple(clock(), elapsed(), reason)
        event("reconnect", "重连：$reason")
    }

    /** 重新放起来了：重连结束 */
    fun endReconnect() {
        val (at, atMs, reason) = reconnectOpen ?: return
        reconnectOpen = null
        add(Interruption("reconnect", atMs, clock() - at, detail = reason.take(200)))
    }

    /** 落到错误页 */
    fun noteError(message: String, category: String, stage: String) {
        errorKind = message.take(120)
        errorCategory = category
        errorStage = stage
        seekFailed()
        add(Interruption("error", elapsed(), null, category, message.take(200)))
        event("error", "错误页：$message")
    }

    /** 引擎报了失败但被重连 / 原位重开 / 降档接住（不计入中断，看得见的部分会表现为卡顿） */
    fun noteEngineFailure(reason: String, cause: String) {
        engineTrouble = true
        add(Interruption("engine_failure", elapsed(), null, cause, reason.take(200)))
        event("engine_failure", "引擎失败（$cause）：$reason")
    }

    /** 降档 / 改走服务端流 */
    fun noteFallback(reason: String) {
        engineTrouble = true
        add(Interruption("fallback", elapsed(), null, detail = reason.take(200)))
        event("fallback", "降级：$reason")
    }

    private fun add(item: Interruption) {
        if (interruptions.size < MAX_LIST) interruptions.add(item)
    }

    // ---- 对：规格快照 ----

    var delivery: JsonObject? = null
        private set

    /** 首帧时记一次，之后有变化再记（损失判定由服务端按规则表算） */
    fun noteDelivery(snapshot: JsonObject) {
        if (snapshot == delivery) return
        delivery = snapshot
        event("delivery", "规格：${snapshot["route"]?.toString()?.trim('"')} 档 ${snapshot["tier"]}")
    }

    // ---- 行为 ----

    private class Behavior(val kind: String, val atMs: Long, val sinceFirstFrameMs: Long?, val from: String?, val to: String?, val misguess: Boolean)

    private val behaviors = mutableListOf<Behavior>()

    fun noteBehavior(kind: String, from: String? = null, to: String? = null, misguess: Boolean = false) {
        if (behaviors.size < MAX_LIST) behaviors.add(Behavior(kind, elapsed(), sinceFirstFrameMs, from, to, misguess))
    }

    /** 用户换了音轨 / 字幕：首帧后 30 秒内换的算「自动选错了」（进北极星） */
    fun noteTrackChange(kind: String, from: String?, to: String?) {
        val since = sinceFirstFrameMs
        noteBehavior("${kind}_change", from, to, misguess = since != null && since <= MISGUESS_WINDOW_MS)
    }

    /** 离开这次播放：首帧后 10 秒内退出记「快速退出」；记下离开，60 秒内又进同一部算「重进」 */
    fun noteLeaving() {
        val since = sinceFirstFrameMs
        if (since != null && since < 10_000) noteBehavior("quick_exit")
        lastExit = unit.mediaItemId to clock()
        event("leave", "离开")
    }

    // ---- 环境与资源 ----

    /** 机型、系统、显示器、音频输出、解码器清单（设备级，同一进程不变） */
    var device: JsonObject = JsonObject(emptyMap())
    private var memoryPeakMb = 0L
    private var thermalStart: Int? = null
    private var thermalMax = 0
    private var downlinkPeakBps: Double? = null

    fun sampleResources(memoryMb: Long, thermal: Int?) {
        memoryPeakMb = maxOf(memoryPeakMb, memoryMb)
        if (thermal != null) {
            if (thermalStart == null) thermalStart = thermal
            thermalMax = maxOf(thermalMax, thermal)
        }
    }

    fun noteDownlink(bps: Double) {
        if (bps > (downlinkPeakBps ?: 0.0)) downlinkPeakBps = bps
    }

    // ---- 时间线 ----

    private val timeline = mutableListOf<Pair<Long, Pair<String, String>>>()

    fun event(kind: String, text: String) {
        if (timeline.size < MAX_TIMELINE) timeline.add(elapsed() to (kind to text.take(200)))
    }

    init {
        lastExit?.let { (item, at) -> if (item == unit.mediaItemId && clock() - at < 60_000) noteBehavior("reenter") }
        event("start", "开始（$origin）")
    }

    // ---- 结局与上报 ----

    /** 结局：出错 → failed；没出过画 → exit_before_start；播完或到了片尾附近 → watched；其余 exited */
    fun outcome(phaseIsError: Boolean, phaseIsEnded: Boolean, positionMs: Long, durationMs: Long?): String = when {
        phaseIsError -> "failed"
        firstFrameAt == null -> "exit_before_start"
        phaseIsEnded -> "watched"
        durationMs != null && durationMs > 0 && positionMs >= durationMs - maxOf(60_000L, durationMs / 20) -> "watched"
        else -> "exited"
    }

    /** 这次播放值得附上引擎日志：失败、异常退出、出过卡顿、引擎失败被接住、降过级 */
    fun wantsLogTail(outcome: String): Boolean =
        outcome == "failed" || outcome == "abnormal_exit" || rebufferCount > 0 || stallOpen != null || engineTrouble

    fun payload(
        outcome: String,
        network: PlaybackNetwork,
        appVersion: String,
        networkInterface: String,
        context: JsonObject,
        positionMs: Long,
        durationMs: Long?,
        droppedFrames: Long?,
        totalFrames: Long?,
        logTail: String?,
    ): PlaybackMetricPayload {
        val now = clock()
        // 还开着的卡顿 / 重连 / 跳转 / 切换：算到离开这一刻（不改记录本身，异常退出的快照之后还要接着记）
        val extraInterruptions = buildList {
            stallOpen?.let { (at, atMs, cause) -> add(Interruption("rebuffer", atMs, now - at, cause)) }
            reconnectOpen?.let { (at, atMs, reason) -> add(Interruption("reconnect", atMs, now - at, detail = reason)) }
        }
        val openStallMs = stallOpen?.let { now - it.first } ?: 0
        val detail = buildJsonObject {
            put("startup", buildJsonObject {
                put("marks", JsonObject(marks.mapValues { JsonPrimitive(it.value) }))
                put("start_position_ms", startPositionMs)
                put("resumed", resumed)
            })
            put("seeks", JsonArray(seeks.map { s ->
                val open = openSeek?.first === s
                buildJsonObject {
                    put("seq", s.seq); put("source", s.source); put("from_ms", s.fromMs); put("to_ms", s.toMs)
                    put("buffered", s.buffered); put("paused", s.paused); put("restart", s.restart); put("at_ms", s.atMs)
                    put("ms", if (open) JsonPrimitive(now - openSeek!!.second) else s.ms?.let(::JsonPrimitive) ?: JsonNull)
                    put("outcome", if (open) "abandoned" else s.outcome)
                }
            }))
            put("switches", JsonArray(switches.map { w ->
                buildJsonObject {
                    put("kind", w.kind); put("from", w.from); put("to", w.to); put("at_ms", w.atMs)
                    put("ms", w.ms?.let(::JsonPrimitive) ?: JsonNull)
                }
            }))
            put("interruptions", JsonArray((interruptions + extraInterruptions).map { i ->
                buildJsonObject {
                    put("kind", i.kind); put("at_ms", i.atMs); put("ms", i.ms?.let(::JsonPrimitive) ?: JsonNull)
                    i.cause?.let { put("cause", it) }
                    i.detail?.let { put("detail", it) }
                }
            }))
            delivery?.let { put("delivery", it) }
            put("behaviors", JsonArray(behaviors.map { b ->
                buildJsonObject {
                    put("kind", b.kind); put("at_ms", b.atMs)
                    put("since_first_frame_ms", b.sinceFirstFrameMs?.let(::JsonPrimitive) ?: JsonNull)
                    put("from", b.from); put("to", b.to); put("misguess", b.misguess)
                }
            }))
            put("context", JsonObject(context + mapOf(
                "downlink_mbps" to (downlinkPeakBps?.let { JsonPrimitive(Math.round(it / 10_000.0) / 100.0) } ?: JsonNull),
                "origin" to JsonPrimitive(origin),
                "lab" to JsonPrimitive(lab),
            )))
            put("device", device)
            put("resources", buildJsonObject {
                put("thermal_start", thermalStart?.let(::JsonPrimitive) ?: JsonNull)
                put("thermal_max", thermalMax)
                put("memory_peak_mb", memoryPeakMb)
            })
            put("timeline", JsonArray(timeline.map { (at, e) ->
                buildJsonObject { put("at_ms", at); put("kind", e.first); put("text", e.second) }
            }))
            put("end", buildJsonObject {
                put("position_ms", positionMs)
                put("duration_ms", durationMs?.let(::JsonPrimitive) ?: JsonNull)
            })
        }
        val first = firstFrameMs
        val playing = playingAt?.let { (it - startedAt - userWaitMs).coerceAtLeast(0) }
        return PlaybackMetricPayload(
            libraryFileId = libraryFileId,
            tier = tier,
            degradedFrom = degradedFrom,
            engine = "exo",
            hwBackend = hwBackend,
            ttffMs = first,
            firstFrameMs = first,
            playingMs = playing,
            userWaitMs = userWaitMs,
            rebufferMs = rebufferMs + openStallMs,
            rebufferCount = rebufferCount + if (stallOpen != null) 1 else 0,
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
            labScenario = lab,
            route = route,
            networkClass = network.key,
            `interface` = networkInterface,
            appVersion = appVersion,
            errorKind = errorKind.ifEmpty { null },
            errorCategory = errorCategory.ifEmpty { null },
            errorStage = errorStage.ifEmpty { null },
            detail = detail,
            logTail = logTail?.takeIf { it.isNotEmpty() },
        )
    }

    companion object {
        const val STALL_MS = 500L
        const val RESUME_GRACE_MS = 1500L
        const val MISGUESS_WINDOW_MS = 30_000L
        const val SWITCH_TIMEOUT_MS = 15_000L
        const val MAX_LIST = 50
        const val MAX_TIMELINE = 200

        /** 最近一次离开：（条目, 时刻）。60 秒内又进同一部 = 重进 */
        private var lastExit: Pair<Long, Long>? = null

        /** 测试用 */
        fun resetLastExit() {
            lastExit = null
        }
    }
}

/**
 * 通路（与网页同口径，playback-qoe.md §3.7）：档 0 直出 `direct`；档 1、2 视频原样只换封装 / 转音轨 `server_remux`；
 * 档 3 起整片转码——降过档、或用户限了画质的是 `server_transcode`（可能可避免，规则表算损失），一上来就要转码的是
 * `server_transcode_required`（设备解不了这个编码 / 显示不了 HDR，是设备上限，不算损失）。
 */
object PlaybackRoute {
    fun of(original: Boolean, tier: Long?, degraded: Boolean, userCapped: Boolean): String = when {
        original -> "direct"
        (tier ?: 0) <= 2 -> "server_remux"
        degraded || userCapped -> "server_transcode"
        else -> "server_transcode_required"
    }
}
