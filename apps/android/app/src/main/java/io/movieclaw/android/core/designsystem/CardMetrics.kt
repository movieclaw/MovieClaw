package io.movieclaw.android.core.designsystem

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * 与窗口宽度有关的尺寸 token —— **一套手机、一套宽窗口**，按窗口实际宽度注入。
 *
 * 对应 iOS `CardMetrics`（`Shared/DesignSystem/RemoteImage.swift`），
 * 取值逐条照 `docs/design/ipad.md` **§4.1「卡片尺寸」**那张表：
 *
 * | | 手机 | 宽窗口 |
 * |---|---|---|
 * | 首页 / 相似 / 系列 / 发现 / 订阅 海报 | 126 | 168 |
 * | 接下来继续、分集（16:9） | 200 | 296 |
 * | 我的媒体库库卡 | 230 | 296 |
 * | 订阅「刚刚入库」 | 264 | 296 |
 * | 演职员（2:3） | 96 | 128 |
 * | 海报墙最小列宽 | 140 | 150 |
 * | 横滑行间距 | 12 | 18 |
 * | 页边距 | 16 | 32 |
 *
 * 两条口径照 iOS：
 * 1. **靠排版，不靠放大**：多出来的宽度用来多放内容与留白，控件与字号不变。
 * 2. **紧凑宽度下走原来那套**：手机侧每个值都等于改动前 `McMetrics` 的取值，
 *    [LocalCardMetrics] 的默认值也是 [Phone]，所以手机版式不会变。
 */
@Immutable
data class CardMetrics(
    /** 页面左右边距。手机 16（= 原 `McMetrics.pagePadding`），宽窗口 32（同 iOS `edge`） */
    val pagePadding: Dp,
    /** 横滑行卡间距。手机 12，宽窗口 18 */
    val rowSpacing: Dp,
    /** 海报墙网格的最小列宽（§4.1「海报墙最小列宽」） */
    val wallMinColumn: Dp,
    /** 列表类页面的阅读宽上限；`null` = 不限宽（手机） */
    val readableWidth: Dp?,
    /** 横滑行海报卡宽（首页/相似/系列/发现/订阅行） */
    val posterWidth: Dp,
    /** 16:9 横卡宽（「接下来继续」、分集卡） */
    val wideThumbWidth: Dp,
    /** 「我的媒体库」库卡宽 */
    val libraryCardWidth: Dp,
    /** 订阅「刚刚入库」卡宽 */
    val newInWidth: Dp,
    /** 演职员头像卡宽（2:3） */
    val castWidth: Dp,
    /** 分集卡宽（16:9）。iOS `episode`：手机 200、宽窗口 296 */
    val episodeWidth: Dp = 200.dp,
    /** 「刚刚入库」左下角小号片名 Logo 最大宽。iOS `recentLogo`：手机 118、宽窗口 140 */
    val recentLogoWidth: Dp = 118.dp,
    /** 「按类型找电影 / 剧集」全幅剧照卡。iOS `genreTile`：两套都是 196（不随窗口放大） */
    val genreTileWidth: Dp = 196.dp,
    /**
     * 内容区宽度（已扣掉侧边栏）。`0` = 还没量到。
     * 宽窗口按它把海报排成整列——见 [fitted]，与 iOS `CardMetrics.contentWidth` 同口径。
     */
    val contentWidth: Dp = 0.dp,
    /** 是否宽窗口版式。各页的宽版分支都看它 */
    val isWide: Boolean = false,
) {
    /** 横滑行骨架屏铺几张（宽窗口一行约 6 张，手机 4 张） */
    val skeletonCount: Int get() = if (isWide) 6 else 4

    /** 排海报的可用宽：内容区减两侧页边距（iOS `rowWidth`） */
    private val rowWidth: Dp get() = contentWidth - pagePadding * 2

    /** 按目标宽排成整列时的列数：取**最接近**目标宽的那个整数（iOS `columnCount`，四舍五入） */
    private fun columnCount(target: Dp): Int {
        if (rowWidth.value <= 0f) return 1
        return maxOf(1, ((rowWidth.value + rowSpacing.value) / (target.value + rowSpacing.value)).roundToInt())
    }

    /** 按目标宽排成整列后的实际列宽（iOS `columnWidth`，向下取整） */
    private fun columnWidth(target: Dp): Dp {
        val count = columnCount(target).toFloat()
        if (rowWidth.value <= 0f) return target
        val w = (rowWidth.value - (count - 1) * rowSpacing.value) / count
        return floor(w).dp
    }

    /**
     * 宽窗口：按内容区宽把海报排成整列（iOS `CardMetrics.fitted(contentWidth:)`）。
     *
     * 同一个窗口宽度下首页横排和海报墙的海报**一样大**，展开/收起侧边栏时一起变
     * —— 这是 iOS 真机反馈过的修正（原本首页 168、海报墙 157，看着不一致）。
     */
    fun fitted(contentWidth: Dp): CardMetrics {
        if (!isWide || contentWidth.value <= 0f) return this
        val poster = copy(contentWidth = contentWidth).columnWidth(WIDE_POSTER_TARGET.dp)
        return copy(contentWidth = contentWidth, posterWidth = poster)
    }

    companion object {
        /** 宽窗口海报的目标宽（iOS `widePosterTarget`）：实际宽由 [fitted] 算出 */
        const val WIDE_POSTER_TARGET = 168f

        /**
         * 宽版式的判定阈值：Material 3 的 **expanded** 断点。
         * 本平板（华为 MRR-W29，1600×2560 @400dpi）实测横屏 `w1024dp`、竖屏 `w640dp`
         * —— 横屏落进宽版式，竖屏维持手机版式。
         *
         * iOS 那边判断是「常规宽度且是 iPad」（iPhone Pro Max 横屏也是常规宽度，仍走手机），
         * 安卓没有 `idiom` 这个概念，用宽度断点是最接近的等价物。
         */
        val WIDE_MIN_WIDTH = 840.dp

        /**
         * 平板竖屏自适应列数的起点：≥ 600dp（折叠屏展开 / 平板竖屏）但 < [WIDE_MIN_WIDTH]
         * 的窗口，海报墙按 [mcGridCells] 的 minColumn 自适应；再往下是手机，逐值不动。
         */
        val TABLET_PORTRAIT_MIN = 600.dp

        /** 手机那套。**紧凑宽度下必须逐值等于改动前的 `McMetrics`** */
        val Phone = CardMetrics(
            pagePadding = 16.dp,
            rowSpacing = 12.dp,
            wallMinColumn = 140.dp,
            readableWidth = null,
            posterWidth = 126.dp,
            wideThumbWidth = 200.dp,
            libraryCardWidth = 230.dp,
            newInWidth = 264.dp,
            castWidth = 104.dp,
            episodeWidth = 200.dp,
            recentLogoWidth = 118.dp,
            genreTileWidth = 196.dp,
        )

        /** 宽窗口那套（= `ipad.md` §4.1 的「宽窗口」列） */
        val Wide = CardMetrics(
            pagePadding = 32.dp,
            rowSpacing = 18.dp,
            wallMinColumn = 150.dp,
            readableWidth = 720.dp,
            posterWidth = 168.dp,
            wideThumbWidth = 296.dp,
            libraryCardWidth = 296.dp,
            newInWidth = 296.dp,
            castWidth = 128.dp,
            episodeWidth = 296.dp,
            recentLogoWidth = 140.dp,
            genreTileWidth = 196.dp,
            isWide = true,
        )

        /** 按窗口宽度选一套（iOS `forWindow(regular:)` 的安卓对应物） */
        fun forWindow(maxWidth: Dp): CardMetrics =
            if (maxWidth >= WIDE_MIN_WIDTH) Wide else Phone
    }
}

/**
 * 当前窗口的尺寸 token。**默认值是手机那套** —— 没注入的地方（以及忘了改的地方）
 * 行为与改动前完全一致，这是「手机版式零变化」能成立的原因。
 */
val LocalCardMetrics = staticCompositionLocalOf { CardMetrics.Phone }

/** 页面里取当前尺寸 token 的简写：`mcCards.pagePadding` */
val mcCards: CardMetrics
    @Composable
    get() = LocalCardMetrics.current

/**
 * 网格列数：**手机沿用原来的固定列数**，宽窗口按 §4.1 的「海报墙最小列宽」自适应；
 * 平板竖屏这类「非宽但很大」的窗口（≥ [TABLET_PORTRAIT_MIN]）也按窗口宽自适应，
 * 不再沿用手机的固定 2/3 列（MRR-W29 竖屏 640dp 只有 2 列，海报大到浪费）。
 *
 * @param phoneColumns 手机/紧凑宽度下的列数，即改动前写死的那个 N
 * @param minColumn 自适应时每列的最小宽；海报墙用 [Phone.wallMinColumn]，
 *   2:3 演职员卡这类更窄的格子传 [Phone.castWidth]
 */
@Composable
fun mcGridCells(phoneColumns: Int, minColumn: Dp = CardMetrics.Phone.wallMinColumn): GridCells {
    val cards = LocalCardMetrics.current
    // 宽窗口用 fitted() 算出的列数（Fixed），这样墙和横排的卡片**一样大**；
    // 用 Adaptive(minColumn) 会出现墙 172dp / 横排 166dp 的不一致（实测）。
    if (cards.isWide && cards.contentWidth > 0.dp) {
        val gap = cards.rowSpacing
        val count = ((cards.contentWidth + gap) / (cards.posterWidth + gap)).toInt().coerceAtLeast(2)
        return GridCells.Fixed(count)
    }
    // 平板竖屏（非宽窗口）：按窗口宽算列数，不比手机列数少
    val windowWidth = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp.dp
    if (windowWidth >= CardMetrics.TABLET_PORTRAIT_MIN) {
        val gap = cards.rowSpacing
        val rowWidth = windowWidth - cards.pagePadding * 2
        val count = ((rowWidth + gap) / (minColumn + gap)).toInt()
            .coerceAtLeast(phoneColumns)
            .coerceAtMost(8)
        if (count > phoneColumns) return GridCells.Fixed(count)
    }
    return GridCells.Fixed(phoneColumns)
}

/**
 * 列表类页面的**阅读宽上限 + 居中**（对应 iOS `PadReadableWidth`，`ipad.md` §4）。
 *
 * 手机下 `readableWidth == null`，直接原样返回内容（零布局改动）。
 */
@Composable
fun McReadableWidthBox(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val limited = LocalCardMetrics.current.readableWidth
    if (limited == null) {
        Box(modifier) { content() }
        return
    }
    Layout(
        content = { Box(Modifier.fillMaxHeight()) { content() } },
        modifier = modifier,
    ) { measurables, constraints ->
        val cap = limited.roundToPx()
        val maxW = if (constraints.hasBoundedWidth) minOf(cap, constraints.maxWidth) else cap
        val placeable = measurables.first().measure(
            constraints.copy(minWidth = maxW, maxWidth = maxW),
        )
        val outerW = if (constraints.hasBoundedWidth) constraints.maxWidth else maxW
        layout(outerW, placeable.height) {
            placeable.place((outerW - placeable.width) / 2, 0)
        }
    }
}
