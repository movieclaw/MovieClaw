package io.movieclaw.android.core.designsystem

import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource

/**
 * 液态底栏的模糊源（glass-kit 同款结构）：MainTabScreen 在**开关打开时**提供，
 * 各页签根页的内容层用 [tabGlassSource] 标记。开关关闭时 Local 为 null，标记原样返回，
 * 不付任何图层捕获的代价。
 */
val LocalTabHazeState = staticCompositionLocalOf<HazeState?> { null }

/** 内容层标记：把本节点的绘制喂给玻璃件的背景模糊（`hazeSource`） */
@Composable
fun Modifier.tabGlassSource(): Modifier {
    val state = LocalTabHazeState.current ?: return this
    return this.hazeSource(state)
}
