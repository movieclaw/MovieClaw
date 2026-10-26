package io.movieclaw.android.core.designsystem

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow

/**
 * 底栏滚动收起（iOS 26 `.tabBarMinimizeBehavior(.onScrollDown)`，HTML 原型同款）：
 * 向下滚动累计 > 24dp → 整条玻璃向左塌缩淡出，左下角浮出 56pt 圆钮（只留当前格图标）；
 * 向上滚或回到顶部 → 弹回；点圆钮也弹回。片段页强制不收起。
 */
object TabBarMinimize {
    /** 是否收起（过渡动画由底栏自己用 animateFloatAsState 做，才有 HTML 那种自然感） */
    var minimized by androidx.compose.runtime.mutableStateOf(false)
        private set

    private var lastOffset = 0
    private var acc = 0f

    /** 每个顶层页面把自身滚动位置喂进来（单位 px） */
    fun onScroll(offsetPx: Int, density: Float) {
        val dy = (offsetPx - lastOffset).toFloat()
        lastOffset = offsetPx
        val accPx = 24f * density
        when {
            offsetPx <= 24 * density -> { acc = 0f; minimized = false }
            dy > 0f -> { acc += dy; if (acc > accPx) minimized = true }
            dy < 0f -> { acc = 0f; minimized = false }
        }
    }

    /** 点圆钮 / 换页时复位 */
    fun restore() {
        acc = 0f
        minimized = false
    }

    fun reset(offsetPx: Int) {
        lastOffset = offsetPx
        acc = 0f
        minimized = false
    }
}

/** 在顶层页面的滚动容器上调用一次即可 */
@Composable
fun TrackTabBarMinimize(scroll: ScrollState) {
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    val active = LocalTabActive.current
    // 后台页签不喂：几个页签同时在组合里，各自的滚动位置混着喂会把收起判断搅乱；
    // 切回前台时按本页当前位置重新起算
    // **平板不收起**：屏幕够大，底栏常驻更稳，也不用为了找回它再点一次。
    // 判据用最短边 ≥ 600dp（本机竖 640 / 横 608 都命中），小屏手机仍保留滚动收起。
    val cfg = androidx.compose.ui.platform.LocalConfiguration.current
    val keepVisible = minOf(cfg.screenWidthDp, cfg.screenHeightDp) >= 600
    LaunchedEffect(scroll, density, active, keepVisible) {
        if (!active) return@LaunchedEffect
        TabBarMinimize.reset(scroll.value)
        if (keepVisible) {
            TabBarMinimize.restore()
            return@LaunchedEffect
        }
        snapshotFlow { scroll.value }.collect { TabBarMinimize.onScroll(it, density) }
    }
}

/**
 * LazyColumn 版：`firstVisibleItemIndex/ScrollOffset` 拼成一个单调递增的伪偏移量。
 * 单条目高度不可能到 10 万 px，所以跨条目时（index+1、offset 归零）伪偏移量依然在增大，
 * 不会被误判成「向上滚」。
 */
@Composable
fun TrackTabBarMinimize(scroll: LazyListState) {
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    val active = LocalTabActive.current
    val cfg2 = androidx.compose.ui.platform.LocalConfiguration.current
    val keepVisible2 = minOf(cfg2.screenWidthDp, cfg2.screenHeightDp) >= 600
    LaunchedEffect(scroll, density, active, keepVisible2) {
        if (!active) return@LaunchedEffect
        TabBarMinimize.reset(scroll.firstVisibleItemIndex * 100_000 + scroll.firstVisibleItemScrollOffset)
        if (keepVisible2) {
            TabBarMinimize.restore()
            return@LaunchedEffect
        }
        snapshotFlow { scroll.firstVisibleItemIndex * 100_000 + scroll.firstVisibleItemScrollOffset }
            .collect { TabBarMinimize.onScroll(it, density) }
    }
}
