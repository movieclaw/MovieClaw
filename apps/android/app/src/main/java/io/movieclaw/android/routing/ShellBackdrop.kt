package io.movieclaw.android.routing

import androidx.compose.foundation.ScrollState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp

/**
 * 外壳的「窗口背景」（iOS `PadBackdropUnderSidebar` / 网页 `useHeroWindowBackdrop` 的安卓对应物）。
 *
 * 发现页 hero 是沉浸式的：[heroHeight] 不为 null 时，剧照只铺 hero 那一段，
 * 并随页面的 [scrollState] 一起上移、底部淡入 [tint]；hero 滚走后只剩环境底。
 * 为 null 时（详情等整页沉浸页面）剧照按整窗铺满。
 */
data class ShellBackdrop(
    val url: String?,
    val origin: String?,
    val tint: Color,
    val heroHeight: Dp? = null,
    val scrollState: ScrollState? = null,
)

/**
 * 页面 → 外壳 的发布口。详情页在进入时设值、离开时置 null。
 * 默认是空实现，所以没接进外壳的页面（以及手机路径）行为不变。
 */
val LocalShellBackdropSetter = staticCompositionLocalOf<(ShellBackdrop?) -> Unit> { {} }
