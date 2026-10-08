package io.movieclaw.android.core.playback

import android.os.SystemClock

/**
 * 起播分段计时（iOS `PlaybackStartupTrace` 的对应物）。
 *
 * 从「点下播放」起算，每个阶段记一条；首帧到了把整行打出来——logcat 里
 * `McPlayer: 起播分段：…` 这一行就是「这部片起播慢」的第一现场（iOS 文档原话：
 * 用户说起播慢时先看这一行）。阶段名与 iOS 对齐：点击 → 决策+会话 → 引擎 → 首帧。
 *
 * 服务器侧的 `startup` 事件上报后续再接（QoE 的 `PlaybackMetricPayload` 已经有
 * ttff/firstFrame/playing 三个分段，缺的是全链路的细分）。
 */
object PlaybackStartupTrace {
    private val lock = Any()
    private var startedAt = 0L
    private val stages = LinkedHashMap<String, Long>()

    /** 点下播放（或「下一集」）的那一刻 */
    fun start() {
        synchronized(lock) {
            startedAt = SystemClock.elapsedRealtime()
            stages.clear()
        }
    }

    /** 记一个阶段（相对点击的毫秒） */
    fun mark(stage: String) {
        synchronized(lock) {
            if (startedAt == 0L) return
            stages[stage] = SystemClock.elapsedRealtime() - startedAt
        }
    }

    /** 首帧到了：整行打出来并收工 */
    fun finish() {
        val line = synchronized(lock) {
            if (startedAt == 0L) return
            val text = stages.entries.joinToString(" ") { "${it.key}=${it.value}ms" }
            startedAt = 0L
            stages.clear()
            text
        }
        android.util.Log.i("McPlayer", "起播分段：$line")
    }
}
