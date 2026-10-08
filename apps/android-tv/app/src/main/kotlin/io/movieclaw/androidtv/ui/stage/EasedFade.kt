package io.movieclaw.androidtv.ui.stage

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/**
 * 大图区所有渐隐都用的缓动（TVEasedFade）：smootherstep `t³(t(6t−15)+10)`，取 12 段色标。
 * 直线渐变在暗图上会看出一道「平台」，这条曲线两端都是平滑过渡。
 */
object EasedFade {
    private fun eased(t: Float) = t * t * t * (t * (t * 6 - 15) + 10)

    /** 从 [from] 处满色一路淡到 [to] 处全透明 */
    fun stops(color: Color, from: Float, to: Float, steps: Int = 12): Array<Pair<Float, Color>> {
        val list = mutableListOf(0f to color)
        for (i in 0..steps) {
            val t = i.toFloat() / steps
            list += (from + (to - from) * t) to color.copy(alpha = color.alpha * (1 - eased(t)))
        }
        if (to < 1f) list += 1f to color.copy(alpha = 0f)
        return list.toTypedArray()
    }

    /** 从 [from] 处全透明一路变到底部满色（首页剧照下沿渐隐进边缘色） */
    fun rising(color: Color, from: Float, steps: Int = 12): Array<Pair<Float, Color>> {
        val list = mutableListOf(0f to color.copy(alpha = 0f))
        for (i in 0..steps) {
            val t = i.toFloat() / steps
            list += (from + (1 - from) * t) to color.copy(alpha = color.alpha * eased(t))
        }
        return list.toTypedArray()
    }

    /** 渐隐曲线在 [location] 处的不透明度（逐段线性插值，同渐变绘制） */
    fun alpha(location: Float, from: Float, to: Float, steps: Int = 12): Float {
        if (location <= from) return 1f
        if (location >= to) return 0f
        val position = (location - from) / (to - from) * steps
        val index = minOf(position.toInt(), steps - 1)
        val a = 1 - eased(index.toFloat() / steps)
        val b = 1 - eased((index + 1).toFloat() / steps)
        return a + (b - a) * (position - index)
    }

    fun vertical(stops: Array<Pair<Float, Color>>) = Brush.verticalGradient(*stops)
    fun horizontal(stops: Array<Pair<Float, Color>>) = Brush.horizontalGradient(*stops)
}
