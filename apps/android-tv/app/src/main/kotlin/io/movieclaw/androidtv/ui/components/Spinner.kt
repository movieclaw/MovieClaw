package io.movieclaw.androidtv.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.rotate
import io.movieclaw.androidtv.ui.theme.pt
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** 转圈（tvOS ProgressView 的样子）：8 根辐条，亮度依次递减，一秒转一圈 */
@Composable
fun Spinner(modifier: Modifier = Modifier, sizePt: Int = 60, color: Color = Color.White) {
    val transition = rememberInfiniteTransition(label = "spinner")
    val step by transition.animateFloat(0f, 8f, infiniteRepeatable(tween(1000, easing = LinearEasing), RepeatMode.Restart), label = "spin")
    Canvas(modifier.size(sizePt.pt)) {
        val r = size.minDimension / 2
        val stroke = r * 0.22f
        rotate(step.toInt() * 45f) {
            for (i in 0 until 8) {
                val angle = (i * 45f - 90f) * PI.toFloat() / 180f
                val start = Offset(center.x + cos(angle) * r * 0.45f, center.y + sin(angle) * r * 0.45f)
                val end = Offset(center.x + cos(angle) * (r - stroke / 2), center.y + sin(angle) * (r - stroke / 2))
                drawLine(color.copy(alpha = 1f - i * 0.11f), start, end, stroke, StrokeCap.Round)
            }
        }
    }
}
