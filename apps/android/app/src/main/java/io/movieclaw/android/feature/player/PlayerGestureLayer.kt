package io.movieclaw.android.feature.player

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import kotlin.math.abs
import kotlin.math.hypot
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 播放器手势层 —— 逐条对齐 iOS PlayerGestureLayer.swift 的语义与常量:
 *   · 单击**立即**生效(不为等双击延迟);双击事后推断(0.3s 窗口),三击按新的单击算
 *   · 首次移动超过 12px 才判定方向:横向 → 定位(满屏一划 = 90 秒),纵向 → 亮度/音量
 *   · 长按 0.5s = 2× 变速(仅播放中可触发;移动超阈值即作废)
 *   · 起始点落在上下 32px 边缘守卫内 → 整个手势交给系统
 *   · 竖向调节只在 12%~76% 高度、且距左右边 ≥32px 时生效,其余区域放弃该手势
 *   · 满行程 = 视口高度的 60%
 * 控制层排除由布局承担:手势层是控制层下方的兄弟节点,控件上的触摸不会落到这里。
 */
internal enum class GestureIntent { UNDECIDED, SCRUB, ADJUST, HOLD, CANCEL }

internal fun Modifier.playerGestures(
    enabled: Boolean,
    canHold: Boolean,
    onTap: () -> Unit,
    onDoubleTap: (xRatio: Float) -> Unit,
    onScrubStart: () -> Unit,
    onScrubTo: (deltaRatio: Float) -> Unit,
    onScrubEnd: () -> Unit,
    onAdjustStart: (brightness: Boolean) -> Unit,
    onAdjust: (brightness: Boolean, delta: Float) -> Unit,
    onAdjustEnd: () -> Unit,
    onHoldStart: () -> Unit,
    onHoldEnd: () -> Unit,
): Modifier = pointerInput(enabled, canHold) {
    if (!enabled) return@pointerInput
    var lastTapAt = 0L
    coroutineScope {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            val start = down.position
            val width = size.width.toFloat()
            val height = size.height.toFloat()
            if (!insideEdgeGuard(start, height)) return@awaitEachGesture

            var intent = GestureIntent.UNDECIDED
            var isBrightness = false
            var holdJob: Job? = null
            if (canHold) {
                holdJob = launch {
                    delay(HOLD_DELAY_MS)
                    if (intent == GestureIntent.UNDECIDED) {
                        intent = GestureIntent.HOLD
                        onHoldStart()
                    }
                }
            }

            while (true) {
                val event = awaitPointerEvent()
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                val position = change.position

                if (intent == GestureIntent.UNDECIDED) {
                    val dx = position.x - start.x
                    val dy = position.y - start.y
                    if (hypot(dx, dy) > ACTIVATE_PX) {
                        holdJob?.cancel()
                        if (abs(dx) >= abs(dy)) {
                            intent = GestureIntent.SCRUB
                            onScrubStart()
                        } else if (insideAdjustBand(start, width, height)) {
                            intent = GestureIntent.ADJUST
                            isBrightness = start.x < width / 2f
                            onAdjustStart(isBrightness)
                        } else {
                            // 竖向滑动落在排除区(顶部/底部/左右边缘):整个手势作废
                            intent = GestureIntent.CANCEL
                        }
                    }
                }

                when (intent) {
                    GestureIntent.SCRUB -> onScrubTo((position.x - start.x) / width)
                    GestureIntent.ADJUST -> onAdjust(
                        isBrightness,
                        -(position.y - start.y) / (height * FULL_SWEEP_RATIO),
                    )
                    else -> Unit
                }

                if (!change.pressed) break
            }

            holdJob?.cancel()
            when (intent) {
                GestureIntent.HOLD -> onHoldEnd()
                GestureIntent.SCRUB -> onScrubEnd()
                GestureIntent.ADJUST -> onAdjustEnd()
                GestureIntent.UNDECIDED -> {
                    val now = System.currentTimeMillis()
                    val isDouble = now - lastTapAt <= DOUBLE_TAP_WINDOW_MS
                    if (isDouble) {
                        lastTapAt = 0L // 三击视为新的单击
                        onDoubleTap((start.x / width).coerceIn(0f, 1f))
                    } else {
                        lastTapAt = now
                        onTap()
                    }
                }
                GestureIntent.CANCEL -> Unit
            }
        }
    }
}

private const val ACTIVATE_PX = 12f
private const val EDGE_GUARD_PX = 32f
private const val DOUBLE_TAP_WINDOW_MS = 300L
private const val HOLD_DELAY_MS = 500L
private const val FULL_SWEEP_RATIO = 0.6f
private const val ADJUST_TOP_EXCLUDE = 0.12f
private const val ADJUST_BOTTOM_EXCLUDE = 0.24f

private fun insideEdgeGuard(point: Offset, height: Float): Boolean =
    point.y > EDGE_GUARD_PX && point.y < height - EDGE_GUARD_PX

private fun insideAdjustBand(point: Offset, width: Float, height: Float): Boolean {
    val ratio = point.y / height
    val withinVertical = ratio in ADJUST_TOP_EXCLUDE..(1f - ADJUST_BOTTOM_EXCLUDE)
    val withinHorizontal = point.x >= EDGE_GUARD_PX && point.x <= width - EDGE_GUARD_PX
    return withinVertical && withinHorizontal
}

/** 供 UI 复用的常量(定位满屏行程等) */
internal object PlayerGestureMath {
    const val FULL_SWEEP_SEEK_MS = 90_000L
}
