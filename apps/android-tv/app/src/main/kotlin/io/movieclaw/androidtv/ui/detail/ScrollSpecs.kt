package io.movieclaw.androidtv.ui.detail

import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.BringIntoViewSpec
import kotlin.math.abs

/**
 * 焦点滚动：只滚到焦点那张卡完整露出、且离可见区两边留 [marginPx]（同 tvOS 滚动视图按焦点滚的手感）。
 * Android TV 上系统默认是「把焦点卡钉在 30% 处」（PivotBringIntoViewSpec），横排一动就整排挪，和 Apple 端不一样。
 */
internal fun minimalScroll(offset: Float, size: Float, container: Float, marginPx: Float): Float {
    val leading = offset - marginPx
    val trailing = offset + size + marginPx - container
    return when {
        leading >= 0 && trailing <= 0 -> 0f
        // 卡比可见区还大：对齐开头
        size + marginPx * 2 > container -> leading
        leading < 0 -> leading
        else -> trailing
    }
}

/** [minimalScroll] 做成 BringIntoViewSpec：页面里的横排、海报墙都用它 */
internal class MarginBringIntoViewSpec(private val marginPx: Float) : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float =
        minimalScroll(offset, size, containerSize, marginPx)
}

/**
 * 竖向页面：焦点在头部附近（[topSnapPx] 以内）时直接滚回最顶，标题不被顶出去；其余按 [minimalScroll]。
 * [scrollValue] 是当前滚动量（像素）。
 */
internal class TopSnapBringIntoViewSpec(
    private val marginPx: Float,
    private val topSnapPx: Float,
    private val scrollValue: () -> Float,
) : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        val s = scrollValue()
        if (s + offset < topSnapPx) return -s
        return minimalScroll(offset, size, containerSize, marginPx)
    }
}

/** 详情页焦点所在的那一截：首屏的按钮 / 下半截第一行（含选季）/ 下面的行 */
internal enum class DetailZone { Stage, Top, Below }

/**
 * 详情页的滚动吸附（TVDetailSnap）：两截之间不停在半中间。
 * - 焦点在首屏按钮上：滚回 0；
 * - 焦点在下半截第一行（分集 / 系列 / 演职员）或选季上：停在下半截的顶（[lowerPx]）；
 * - 焦点在更下面的行：按露全的最小距离滚，但不高于下半截的顶。
 * 系统按焦点滚动时每一帧都会来问这里，所以只按「焦点在哪一截」决定目标，与滚到一半无关。
 */
internal class DetailSnapSpec(
    private val zone: () -> DetailZone,
    private val scrollValue: () -> Float,
    private val maxScroll: () -> Float,
    private val lowerPx: () -> Float,
    private val marginPx: Float,
) : BringIntoViewSpec {
    @Deprecated("跟随接口")
    override val scrollAnimationSpec: AnimationSpec<Float> = tween(400, easing = FastOutSlowInEasing)

    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
        val s = scrollValue()
        val lower = lowerPx()
        val target = when (zone()) {
            DetailZone.Stage -> 0f
            DetailZone.Top -> lower
            DetailZone.Below -> maxOf(lower, s + minimalScroll(offset, size, containerSize, marginPx))
        }.coerceIn(0f, maxOf(0f, maxScroll()))
        val distance = target - s
        return if (abs(distance) < 0.5f) 0f else distance
    }
}
