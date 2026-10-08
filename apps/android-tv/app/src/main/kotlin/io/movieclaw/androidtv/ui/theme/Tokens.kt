package io.movieclaw.androidtv.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/*
 * 设计令牌：逐项对齐 Apple TV 版（apps/apple/MovieClawTV/DesignSystem/TVCards.swift、Shared/DesignSystem/Theme.swift）。
 *
 * 单位换算：tvOS 在 1920×1080「点」的画布上排版，Android TV 是 960×540 dp，所以 1 pt = 0.5 dp（字号同理）。
 * 代码里一律写 `266.pt`、`38.ptSp`，数值与 Apple 端源码一一对应，走查对不上时直接比数。
 */

val Int.pt: Dp get() = (this * 0.5f).dp
val Float.pt: Dp get() = (this * 0.5f).dp
val Double.pt: Dp get() = (this * 0.5).dp
val Int.ptSp: TextUnit get() = (this * 0.5f).sp
val Float.ptSp: TextUnit get() = (this * 0.5f).sp

/** Theme.swift */
object McColors {
    val Background = Color.Black
    /** 大图区下面的页面底色（Color.tvPage） */
    val Page = Color(0xFF16171C)
    val SurfaceRaised = Color(30, 33, 43).copy(alpha = 0.74f)
    val SurfaceInset = Color.White.copy(alpha = 0.05f)
    val Text = Color(0xFFF3F5F9)
    val TextMuted = Text.copy(alpha = 0.62f)
    val TextFaint = Text.copy(alpha = 0.36f)
    /** 系统「次要」文字（约白 60%） */
    val Secondary = Color.White.copy(alpha = 0.6f)
    val Accent = Color(0xFFCDD6E6)
    val AccentStrong = Color(0xFFEEF2F8)
    val AccentSoft = Accent.copy(alpha = 0.14f)
    val Danger = Color(0xFFFF6B6B)
    val Success = Color(0xFF4ADE80)
    val Warning = Color(0xFFFBBF24)
    val Info = Color(0xFF60A5FA)
    val Line = Color.White.copy(alpha = 0.08f)
    /** 播放器信息面板的勾 */
    val Check = Color(0xFFFFD478)
}

/** TVMetrics（TVCards.swift） */
object McMetrics {
    val Edge = 80.pt
    val SafeTop = 60.pt
    val PosterWidth = 266.pt
    val LandscapeWidth = 416.pt
    val ShowcasePosterWidth = 300.pt
    val ShowcaseHeight = 450.pt
    val ShowcaseExpandedWidth = 800.pt
    val LibraryWidth = 565.pt
    val GenreWidth = 416.pt
    val RowSpacing = 56.pt
    val CardSpacing = 32.pt
    val CaptionSpacing = 24.pt
    val CardCorner = 20.pt
    const val FocusZoom = 1.1f
    const val AvatarFocusZoom = 1.12f
    const val StageZoom = 1.06f
    /** 模糊背景用的图宽（pt） */
    const val BlurredBackdropWidth = 480
    /** 画布宽高（pt），换算屏幕上的位置用 */
    const val CanvasWidth = 1920
    const val CanvasHeight = 1080
}

/**
 * tvOS 系统字体档（pt）：title 76、title2 57、title3 48、headline 38、callout 31、body 29、caption 25、caption2 23。
 */
object McType {
    val Title = TextStyle(fontSize = 76.ptSp, fontWeight = FontWeight.Bold)
    val Title2 = TextStyle(fontSize = 57.ptSp)
    val Title3 = TextStyle(fontSize = 48.ptSp)
    val Headline = TextStyle(fontSize = 38.ptSp, fontWeight = FontWeight.SemiBold)
    val Callout = TextStyle(fontSize = 31.ptSp)
    val Body = TextStyle(fontSize = 29.ptSp)
    val Caption = TextStyle(fontSize = 25.ptSp)
    val Caption2 = TextStyle(fontSize = 23.ptSp)

    fun size(pt: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(fontSize = pt.ptSp, fontWeight = weight)
}
