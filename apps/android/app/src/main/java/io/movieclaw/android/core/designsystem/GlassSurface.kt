package io.movieclaw.android.core.designsystem

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.HazeInputScale
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect

/**
 * 顶栏玻璃件（胶囊 / 圆钮）的材质：**与底栏栏身同一族**——真背景模糊（Haze 采内容层）
 * + 栏身同款灰膜 + 顶层多一档白（选中感）+ 顶亮底回光的高光边。
 *
 * 为什么不用 [glassBubble] 那套 AGSL：那些胶囊/圆钮画在**页面内容层内部**，
 * AGSL 取样要去读「正在录制中的同一张纹理」，实机读到的是空内容（整块发黑）。
 * Haze 自己会做坐标与顺序处理，是这里唯一可靠的路径。
 *
 * 用法：挂在**已经有 clip(胶囊/圆)** 的修饰符链末尾即可（材质会被那个 clip 裁形），
 * 子节点（图标/文字）自动画在材质之上。无来源（二级页、开关关闭）时原样返回。
 */
@Composable
fun Modifier.glassSurface(
    /** 模糊半径：顶栏小件比底栏（14dp）浅一档，避免小圆钮糊成一片 */
    blurRadius: androidx.compose.ui.unit.Dp = 10.dp,
): Modifier {
    // 优先 Haze 真背景模糊：稳定、与底栏栏身同一族，各页面观感一致。
    // （试过让顶栏走 AGSL 折射那套，取样在这些位置不可靠——实机反馈「首页的全部/放大镜太黑」
    //  且与媒体库风格不统一；那条路只保留给底栏选中气泡，那里取样源与绘制顺序是确定的）
    val state = LocalTabHazeState.current
        ?: return if (LocalTabGlassLayer.current != null) this.glassSurfaceLens() else this
    return this
        .hazeEffect(state) {
            style = HazeStyle(
                backgroundColor = Color(0xFF0B0C10),
                // 栏身灰膜 + 一档白：与选中气泡同一族，比栏身略亮
                tints = listOf(HazeTint(GlassCapsule), HazeTint(Color.White.copy(alpha = 0.10f))),
                blurRadius = blurRadius,
                noiseFactor = 0f,
            )
            // 与底栏同款降档抓取：顶栏件一直可见，别按全分辨率每帧抓
            inputScale = HazeInputScale.Auto
        }
        // 1px 高光边：光从左上打来——左上主高光、右下回光（与底栏栏身同一套口径）
        .drawWithCache {
            val stroke = Stroke(width = 1.dp.toPx())
            val corner = CornerRadius(minOf(size.height, size.width) / 2f)
            val topLeft = Brush.radialGradient(
                colors = listOf(Color.White.copy(alpha = 0.55f), Color.Transparent),
                center = Offset(size.width * 0.18f, 0f),
                radius = 40.dp.toPx(),
            )
            val bottomRight = Brush.radialGradient(
                colors = listOf(Color.White.copy(alpha = 0.28f), Color.Transparent),
                center = Offset(size.width * 0.82f, size.height),
                radius = 40.dp.toPx(),
            )
            onDrawWithContent {
                drawContent()
                drawRoundRect(topLeft, size = size, style = stroke, cornerRadius = corner)
                drawRoundRect(bottomRight, size = size, style = stroke, cornerRadius = corner)
            }
        }
}

/** 圆形件（导航圆钮）用的胶囊形状，便于调用点统一写法 */
val GlassSurfaceShape = RoundedCornerShape(999.dp)
