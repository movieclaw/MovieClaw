package io.movieclaw.android.core.designsystem

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp

/**
 * 底栏图标 —— 直接照 MovieClaw-iOS端复刻.html 的 SVG 精灵逐条路径搬过来
 * （24×24 视口、描边 1.7、圆头圆角），保证与原型一一对应：
 *   房子（发现）/ 播放方块（媒体库）/ 书签（订阅）/ 心电（活动）。
 * 「我的」格在底栏里是账号头像，不用图标。
 */
object McTabIcons {

    private fun build(name: String, vararg paths: Pair<String, Boolean>): ImageVector {
        val builder = ImageVector.Builder(
            name = name,
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        )
        paths.forEach { (data, filled) ->
            val nodes = PathParser().parsePathString(data).toNodes()
            builder.addPath(
                pathData = nodes,
                fill = if (filled) SolidColor(Color.White) else null,
                stroke = if (filled) null else SolidColor(Color.White),
                strokeLineWidth = 1.7f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round,
            )
        }
        return builder.build()
    }

    /** #i-house：屋顶一条线 + 屋身，无门 */
    val House: ImageVector by lazy {
        build(
            "mc-home",
            "M3 10.5 12 3l9 7.5" to false,
            "M5.5 9.5V20h13V9.5" to false,
        )
    }

    /** #i-lib：网页 LibraryStackIcon 同款——横宽圆角卡 + 实心播放三角 + 顶部两条渐短堆叠线 */
    val Library: ImageVector by lazy {
        build(
            "mc-library",
            // 圆角矩形 (3.5,8.5)-(20.5,20.5)，rx 2.2
            "M5.7 8.5H18.3A2.2 2.2 0 0 1 20.5 10.7V18.3A2.2 2.2 0 0 1 18.3 20.5H5.7A2.2 2.2 0 0 1 3.5 18.3V10.7A2.2 2.2 0 0 1 5.7 8.5Z" to false,
            "M5.8 5.5H18.2" to false,
            "M8 2.9H16" to false,
            "M10.5 11.7v5.6l4.6-2.8Z" to true,
        )
    }

    /** #i-bookmark：书签（下缘 V 形缺口） */
    val Bookmark: ImageVector by lazy {
        build(
            "mc-bookmark",
            "M7 4h10a1 1 0 0 1 1 1v15l-6-4-6 4V5a1 1 0 0 1 1-1z" to false,
        )
    }

    /** #i-wave：心电折线 */
    val Wave: ImageVector by lazy {
        build(
            "mc-wave",
            "M3 12h3l2-5 3 10 2.5-7 2 4h3.5" to false,
        )
    }
}
