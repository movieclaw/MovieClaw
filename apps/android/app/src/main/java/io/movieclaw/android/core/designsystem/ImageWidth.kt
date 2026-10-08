package io.movieclaw.android.core.designsystem

/**
 * 取图宽度阶梯（与后端 `image_variants.WIDTH_LADDER` 同一张表，见 iOS `ImageWidth`）：
 * 相邻两档不超过 1.5 倍，超过 3840 按 3840。服务端按 `w=` 出对应尺寸的变体并缓存，
 * 客户端不再为大图付「下载 + 解码」两份代价。
 */
object ImageWidth {
    val ladder = intArrayOf(160, 240, 360, 480, 720, 960, 1280, 1920, 2560, 3840)

    /** 只为量亮度、边缘色这类分析取的小图：不必解码整张大图（iOS `ImageWidth.analysis`） */
    const val analysis = 240

    /** 需要的像素宽向上取到阶梯 */
    fun snap(pixels: Int): Int = ladder.firstOrNull { it >= pixels } ?: ladder.last()

    /** 显示宽（dp）× 屏幕倍率（× 放大系数）→ 阶梯上的一档 */
    fun pixels(dp: Float, density: Float, zoom: Float = 1f): Int = snap((dp * density * zoom).toInt())

    /** 铺满（fill）一个框时图片实际被拉到的宽（dp）：图比框扁（若竖框铺 16:9 背景）时按高算 */
    fun coverPoints(boxWidthDp: Float, boxHeightDp: Float, aspect: Float): Float =
        maxOf(boxWidthDp, boxHeightDp * aspect)

    /** 铺满一个框要请求的 `w`；`aspect` 是图片宽高比（见 [ImageAspect]） */
    fun cover(boxWidthDp: Float, boxHeightDp: Float, density: Float, aspect: Float, zoom: Float = 1f): Int =
        pixels(coverPoints(boxWidthDp, boxHeightDp, aspect), density, zoom)
}

/** 图片宽高比（宽 ÷ 高）未知时按资产类型兜底（docs/design/image-sizing.md §6） */
object ImageAspect {
    /** 海报、头像 */
    const val poster = 2f / 3f

    /** 背景、剧照 */
    const val backdrop = 16f / 9f
}
