package io.movieclaw.androidtv.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalDensity
import io.movieclaw.androidtv.ui.theme.pt

/** 焦点移动时列表一律不自己滚：滚动全由页面按 Apple 端的规则控制（首页） */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun NoAutoScroll(content: @Composable () -> Unit) {
    val spec = remember {
        object : BringIntoViewSpec {
            override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float = 0f
        }
    }
    CompositionLocalProvider(LocalBringIntoViewSpec provides spec, content = content)
}

/**
 * 焦点移动时列表怎么滚（tvOS 的口径）：只滚到焦点元素完整露出、离边缘留 [marginPt]，已经在可视区里就不动。
 * Compose 在电视上默认把焦点元素钉在可视区约 1/3 处，首页、详情页的首屏会被一进来就滚走，所以全局换掉。
 * 需要固定位置的（首页卡片行滚到 334、海报行滚到顶）由页面自己 animateScrollTo。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvScrollSpec(marginPt: Int, content: @Composable () -> Unit) {
    val margin = with(LocalDensity.current) { marginPt.pt.toPx() }
    val spec = remember(margin) {
        object : BringIntoViewSpec {
            override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
                val trailing = offset + size
                val leadingEdge = margin
                val trailingEdge = containerSize - margin
                return when {
                    offset < leadingEdge -> offset - leadingEdge
                    trailing > trailingEdge -> minOf(trailing - trailingEdge, offset - leadingEdge)
                    else -> 0f
                }
            }
        }
    }
    CompositionLocalProvider(LocalBringIntoViewSpec provides spec, content = content)
}
