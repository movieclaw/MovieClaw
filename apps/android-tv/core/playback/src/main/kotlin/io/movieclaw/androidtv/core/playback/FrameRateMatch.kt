package io.movieclaw.androidtv.core.playback

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 自动帧率匹配（androidtv-app.md §4.4）：按片源帧率挑显示模式，消除 24p / 25p 在 60Hz 下的抖动。
 *
 * 规则：分辨率不变（4K 屏不降到 1080p），刷新率是片源帧率的整数倍、误差 ≤ 0.15%（23.976 帧优先 23.976Hz，
 * 没有就退 24Hz；25 帧切 50Hz；29.97 帧切 59.94Hz）；倍数小的优先（24Hz 优于 48Hz）。当前模式已经满足就不切。
 */
object FrameRateMatch {
    data class Mode(val id: Int, val width: Int, val height: Int, val refreshRate: Float)

    /** 系统「匹配内容帧率」设置（Android 12+ `DisplayManager.getMatchContentFrameRateUserPreference`） */
    enum class Preference { Never, SeamlessOnly, Always }

    private const val TOLERANCE = 0.0015
    private const val EXACT = 0.0001

    /** 要切到的模式；不用切（当前已是最合适的、没有合适的、帧率未知）返回 null */
    fun pick(modes: List<Mode>, current: Mode, contentFps: Float?): Mode? {
        if (contentFps == null || contentFps < 10f || contentFps > 121f) return null
        val best = modes
            .filter { it.width == current.width && it.height == current.height }
            .mapNotNull { mode -> rank(mode.refreshRate, contentFps)?.let { mode to it } }
            .minWithOrNull(compareBy({ it.second.first }, { it.second.second }, { it.second.third }))
            ?: return null
        val now = rank(current.refreshRate, contentFps)
        return if (now != null && !better(best.second, now)) null else best.first
    }

    /** 排序键：（不是精确倍数 = 1, 倍数, 相对误差）；不是整数倍返回 null */
    private fun rank(refreshRate: Float, fps: Float): Triple<Int, Int, Double>? {
        val multiple = (refreshRate / fps).roundToInt()
        if (multiple < 1) return null
        val error = (abs(refreshRate - multiple * fps) / refreshRate).toDouble()
        if (error > TOLERANCE) return null
        return Triple(if (error <= EXACT) 0 else 1, multiple, error)
    }

    private fun better(a: Triple<Int, Int, Double>, b: Triple<Int, Int, Double>): Boolean =
        compareValuesBy(a, b, { it.first }, { it.second }, { it.third }) < 0
}
