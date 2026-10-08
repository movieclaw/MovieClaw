package io.movieclaw.androidtv.ui.components

import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.updateTransition
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer

/**
 * 交叉淡入（同 Compose 的 Crossfade，新旧内容叠在同一个框里），但透明度直接乘到每一笔绘制上，不离屏。
 * Crossfade / AnimatedContent 给整块套透明度图层，淡入淡出的每一帧新旧两块各离屏渲染一遍；
 * 首页换片时整屏剧照、片名简介都在淡入淡出，电视盒子的 GPU 吃不消（docs/perf/androidtv-home-scroll-2026-10.md）。
 * 只适合内部各笔互不重叠的内容（单张图、几行字）：重叠处会互相透出来，与整层淡入略有不同。
 */
@Composable
fun <T> ModulatedCrossfade(
    target: T,
    animationSpec: FiniteAnimationSpec<Float>,
    modifier: Modifier = Modifier,
    contentAlignment: Alignment = Alignment.TopStart,
    content: @Composable (T) -> Unit,
) {
    val transition = updateTransition(target, label = "modulated-crossfade")
    val visible = remember { mutableStateListOf(transition.currentState) }
    if (transition.currentState == transition.targetState && (visible.size != 1 || visible[0] != transition.targetState)) {
        visible.removeAll { it != transition.targetState }
    }
    if (transition.targetState !in visible) visible.add(transition.targetState)
    Box(modifier, contentAlignment = contentAlignment) {
        visible.forEach { state ->
            key(state) {
                val alpha = transition.animateFloat(transitionSpec = { animationSpec }, label = "alpha") { if (it == state) 1f else 0f }
                Box(
                    Modifier.graphicsLayer {
                        this.alpha = alpha.value
                        compositingStrategy = CompositingStrategy.ModulateAlpha
                    },
                ) { content(state) }
            }
        }
    }
}
