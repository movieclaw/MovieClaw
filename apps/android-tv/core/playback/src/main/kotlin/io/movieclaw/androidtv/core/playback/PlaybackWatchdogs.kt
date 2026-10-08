package io.movieclaw.androidtv.core.playback

// 看门狗与重试预算：阈值逐一照搬 Apple 端 Shared/Player/PlaybackWatchdogs.swift（它们又照搬 Web lib/player/*）。

/**
 * 掉帧看门狗：视频直通期间持续掉帧超阈值，就把当前档报废、走降档回路换转码。
 * 窗口 10 秒（每秒一个样本，要 11 个样本才构成 10 秒的首尾差）、窗口内至少 100 帧、比率 ≥ 10%。
 * 调用方在后台、seek、换会话时 [reset]，只在视频直通时喂样本。
 */
class FrameDropTracker {
    private val history = ArrayDeque<Pair<Long, Long>>()

    /** 喂一个累计样本；返回 null = 没到判定条件，否则是窗口掉帧率（≥ [RATIO] 时应降档） */
    fun sample(dropped: Long, total: Long): Double? {
        val last = history.lastOrNull()
        // 累计计数变小 = 引擎换了流，旧窗口作废
        if (last != null && (total < last.second || dropped < last.first)) history.clear()
        history.addLast(dropped to total)
        if (history.size > WINDOW_SAMPLES + 1) history.removeFirst()
        if (history.size != WINDOW_SAMPLES + 1) return null
        val first = history.first()
        val totalDelta = total - first.second
        if (totalDelta < MIN_FRAMES) return null
        return (dropped - first.first).toDouble() / totalDelta
    }

    fun reset() = history.clear()

    companion object {
        const val WINDOW_SAMPLES = 10
        const val MIN_FRAMES = 100L
        const val RATIO = 0.1
    }
}

/**
 * 卡顿归因：只看「播放头不动」会把处置完全不同的几件事混为一谈——
 * - **解码卡死**：缓冲里明明还有 ≥ 3 秒却不走：先原地推两把，推不动 8 秒判「解不了」，走兜底阶梯；
 * - **线路慢**：前方缓冲见底，但字节还在进来：不是失败，一直等（转圈下显示实时加载速度）；
 * - **连接断了**：缓冲见底且连续十几秒一个字节都没收到：原文件 15 秒、服务端流 45 秒（转码器赶片时本来就一阵阵没有字节）。
 * 每秒喂一次；暂停、结束、定位中、播放头前进都不算停顿。
 */
class StallWatch {
    enum class Verdict { Ok, Nudge, DecodeStalled, Dead }

    private var lastTime: Double? = null
    private var stalledFor = 0
    private var silentFor = 0
    private var nudges = 0
    private var sinceNudge = 99
    private var everAdvanced = false

    fun reset() {
        lastTime = null
        stalledFor = 0
        silentFor = 0
        nudges = 0
        sinceNudge = 99
        everAdvanced = false
    }

    /** [receiving]：这一秒有没有收到字节；[deadLimit]：缓冲见底后连续多少秒没字节算断线 */
    fun sample(
        time: Double, bufferedAhead: Double, paused: Boolean, ended: Boolean, seeking: Boolean,
        receiving: Boolean, deadLimit: Int,
    ): Verdict {
        val previous = lastTime
        val advanced = previous != null && time > previous
        // 「真正播起来过」只认小步前进：起播定位、用户拖动是一次大跳，不算
        if (advanced && !seeking && previous != null && time - previous < 5) everAdvanced = true
        lastTime = time
        sinceNudge += 1
        if (paused || ended || seeking || advanced) {
            stalledFor = 0
            silentFor = 0
            // 只有远离上次推动的真实前进才算恢复——推动自己造成的播放头变化不作数
            if (advanced && sinceNudge > 3) nudges = 0
            return Verdict.Ok
        }
        stalledFor += 1
        if (bufferedAhead >= DECODE_STALL_MIN_BUFFER) {
            silentFor = 0
            if (stalledFor >= DECODE_STALL_SECONDS) {
                stalledFor = 0
                nudges = 0
                return Verdict.DecodeStalled
            }
            // 有数据却不动：先推一把（起播预滚阶段不推，否则会把预滚冲掉重来）
            if (everAdvanced && stalledFor >= NUDGE_AT_SECONDS && nudges < MAX_NUDGES) {
                nudges += 1
                sinceNudge = 0
                stalledFor = 0
                return Verdict.Nudge
            }
            return Verdict.Ok
        }
        // 缓冲见底：只看字节还在不在进来。在进来就是线路慢，不算失败
        silentFor = if (receiving) 0 else silentFor + 1
        if (silentFor >= deadLimit) {
            stalledFor = 0
            silentFor = 0
            nudges = 0
            return Verdict.Dead
        }
        return Verdict.Ok
    }

    companion object {
        const val DECODE_STALL_SECONDS = 8
        const val DECODE_STALL_MIN_BUFFER = 3.0
        const val SERVER_DEAD_SECONDS = 45
        const val DIRECT_DEAD_SECONDS = 15
        const val NUDGE_AT_SECONDS = 3
        const val MAX_NUDGES = 2
        const val NUDGE_STEP_MS = 100L

        fun reason(verdict: Verdict, deadLimit: Int): String {
            if (verdict == Verdict.DecodeStalled) return "播放停滞超过 $DECODE_STALL_SECONDS 秒，这一档的码流播放器吃不下"
            return if (deadLimit < SERVER_DEAD_SECONDS) {
                "连续 $deadLimit 秒没有收到数据——连接可能中断了"
            } else {
                "连续 $deadLimit 秒没有收到服务端的数据——转码可能中断了"
            }
        }
    }
}

/**
 * 拖动跟随的节奏（同 Web `lib/player/scrub-follow.ts`）：落点已在缓冲里时 10Hz 跟随，
 * 原文件直出拖出缓冲时只在停住 60ms 后跟一次（每次 seek 都是一条新的 Range 请求），其余情况松手才跳。
 */
object ScrubFollow {
    const val SETTLE_MS = 60L
    const val MAX_WAIT_MS = 100L

    sealed interface Plan {
        data object Skip : Plan
        data object Follow : Plan
        data class Deferred(val ms: Long) : Plan
    }

    fun plan(nowMs: Long, lastFollowMs: Long, cheap: Boolean, reachable: Boolean, settleOnly: Boolean): Plan {
        if (!reachable) return Plan.Skip
        if (!cheap) return if (settleOnly) Plan.Deferred(SETTLE_MS) else Plan.Skip
        val waited = nowMs - lastFollowMs
        if (waited >= MAX_WAIT_MS) return Plan.Follow
        return Plan.Deferred((MAX_WAIT_MS - waited).coerceIn(0, SETTLE_MS))
    }
}

/**
 * 取流失败的同档重开预算：「网络」归因的失败走同档原地重开（新会话 = 新 token），不降档。
 * 归因可能出错（某档格式放不了却报成网络错误），连续重开 [LIMIT] 次都没能出画，就交给调用方按「这一档放不了」降档。
 */
class NetworkRestartBudget {
    var consecutive = 0
        private set

    fun allowRestart(): Boolean {
        if (consecutive >= LIMIT) return false
        consecutive += 1
        return true
    }

    /** 真正放起来了：之前的失败不再算「连续」 */
    fun reachedPlaying() {
        consecutive = 0
    }

    fun reset() {
        consecutive = 0
    }

    companion object {
        const val LIMIT = 2
    }
}

/**
 * 引擎报「播完」时离片尾还远：是取流断了，不是真播完，不能弹「即将播放下一集」。从当前位置重开；
 * 重开后在原地附近又报播完，就认定真到了结尾（片长信息本身可能不准），不在片尾反复重开。
 */
class PrematureEndGuard {
    private var resumedAtMs: Long? = null

    fun shouldResume(positionMs: Long, durationMs: Long?): Boolean {
        if (durationMs == null || durationMs - positionMs <= MARGIN_MS) return false
        val last = resumedAtMs
        if (last != null && kotlin.math.abs(positionMs - last) < MARGIN_MS) return false
        resumedAtMs = positionMs
        return true
    }

    fun reset() {
        resumedAtMs = null
    }

    companion object {
        const val MARGIN_MS = 30_000L
    }
}

/** 播放中重开时服务端暂时连不上（多半在重启）：按 2、4、8、15、15、15 秒退避重试，约 1 分钟仍不行才落错误页 */
class ReconnectBackoff {
    private var index = 0

    fun nextDelayMs(): Long? {
        if (index >= DELAYS_S.size) return null
        return DELAYS_S[index++] * 1000L
    }

    fun reset() {
        index = 0
    }

    companion object {
        val DELAYS_S = longArrayOf(2, 4, 8, 15, 15, 15)
    }
}

/** Exo 一时出问题（中途出错、楞住、持续掉帧）时先原位重开的额度：同一集 3 分钟内只重开一次，再失败才改走服务端流 */
class NativeRetryBudget {
    private var lastRetryAt: Long? = null

    fun allowRetry(nowMs: Long): Boolean {
        val last = lastRetryAt
        if (last != null && nowMs - last < WINDOW_MS) return false
        lastRetryAt = nowMs
        return true
    }

    fun reset() {
        lastRetryAt = null
    }

    companion object {
        const val WINDOW_MS = 180_000L
    }
}
