package io.movieclaw.android.core.designsystem

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * silver glass 设计 tokens —— **逐值实测自项目自己的移动端网页**
 * （apps/web/app/globals.css + themes/types.ts，用 getComputedStyle 量的，
 *  不是照抄 iOS 的 Theme.swift）。
 *
 * 为什么以网页为准：iOS 端与网页端是同一套 UI，安卓端要对齐的是这套共同设计，
 * 而网页端的值可以直接量、可复核。此前这里写的是 iOS Theme.swift 的值，
 * 与网页实测不符（surfaceRaised / accent2 / info / warn 都不同），已修正。
 *
 * ── 玻璃（实测三套，互不相同）─────────────────────────────────────────────
 *   胶囊 gesture：rgba(62,62,66,.4)  + blur(14px) saturate(1.8) + 白 8% 内描边
 *   卡片浮层：    rgba(14,16,22,.45) + blur(24px)
 *   行内翻页钮：  rgba(32,32,35,.74) + blur(22px) saturate(1.6)
 * 安卓渲染取舍：Compose 没有 backdrop-filter（没有"模糊背后内容"的 API）。
 * 但实测本项目的页面背景就是纯黑（body #000，壁纸为空）——
 * **纯黑上做高斯模糊等于什么都没做**，所以这里用「半透明色 + 白描边 + 顶部内高光」
 * 等价表达，在纯黑底上与网页渲染一致；只有压在图片上时（英雄区顶部）才会看出差别，
 * 那里按网页做法另铺一层暗渐变保证可读性。
 *
 * ── 平色卡（不是玻璃）─────────────────────────────────────────────────────
 *   background white/4% + border white/8% + radius 16 + 行间 white/6% 分隔线。
 *   设置页连卡都没有：45 高的透明行直接落在黑底上。
 */
val Bg = Color(0xFF000000)

/** 图片占位（实测 --poster-placeholder） */
val Placeholder = Color(0xFF1C1C1E)

val TextPrimary = Color(0xFFF3F5F9)
val TextMuted = TextPrimary.copy(alpha = 0.62f)
val TextFaint = TextPrimary.copy(alpha = 0.36f)

/** --accent / --accent-strong：银白强调（按钮实底、进度填充） */
val Accent = Color(0xFFCDD6E6)
val AccentStrong = Color(0xFFEEF2F8)

/** --accent-2：实测 rgb(159,176,201)，用于类型文字/集数行/章节徽标 */
val Accent2 = Color(0xFF9FB0C1)

/** 语义色：实测值（此前用的 iOS 值 60A5FA / FBBF24 都不对） */
val Info = Color(0xFF7FB0FF)
val Warn = Color(0xFFF5C451)
val Danger = Color(0xFFFF6B6B)
val Ok = Color(0xFF4ADE80)

/** 全局发丝线：分隔线 6% / 卡片描边 8% */
val LineSoft = Color(0x0FFFFFFF)
val LineColor = Color(0x14FFFFFF)

/** 平色卡填充（white 4%）、行 hover 填充（white 7.5%） */
val FillCard = Color(0x0AFFFFFF)
val FillHover = Color(0x13FFFFFF)

/** 弹层表面：菜单 rgba(21,23,29,.96) / 搜索面板 rgba(15,17,23,.94) */
val MenuSurface = Color(0xF515171D)
val PaletteSurface = Color(0xF00F1117)

/** 玻璃三套（Android 上用半透明近似，理由见文件头） */
val GlassCapsule = Color(0x663E3E42)
val GlassCard = Color(0x730E1016)
val GlassRaised = Color(0xBD202023)

/**
 * 字号阶梯 —— 实测自网页（--micro/--caption/--sub/--body/--title 五档 + 两处大标题）。
 * 与 iOS 阶梯的主要差异：正文是 16 不是 17；分区标题是 17/600 与 20/700 两档；
 * 发现页大标题是 30/700；欢迎页片名是 46/300。
 */
object McType {
    /** 发现页大标题（实测 30px/700，行高 33） */
    val display = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.3).sp)
    /** 条目详情主标题（实测 28/700） */
    val title = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.3).sp)
    /** 欢迎页片名（实测 46/300 衬线） */
    val wordmark = TextStyle(fontSize = 46.sp, fontWeight = FontWeight.Light)
    /** 欢迎页星期（实测 36/300） */
    val hero = TextStyle(fontSize = 36.sp, fontWeight = FontWeight.Light)
    /** 登录卡标题（实测 22/400 衬线） */
    val title2 = TextStyle(fontSize = 22.sp)
    /** 分区大标题（实测 20/700：库详情 / 订阅 / 日程 / 统计 …） */
    val title3 = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.2).sp)
    /** 分区标题（实测 17/600：发现 / 媒体库 / 活动 …） */
    val headline = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.2).sp)
    /** 正文（实测 --body = 16） */
    val body = TextStyle(fontSize = 16.sp)
    /** 行标题 16/500 */
    val bodyMedium = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium)
    /** 行标题 16/600 */
    val bodySemibold = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    /** 次要行（实测 --sub = 14） */
    val sub = TextStyle(fontSize = 14.sp)
    val subSemibold = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    /** 副行（实测 --caption = 13） */
    val caption = TextStyle(fontSize = 13.sp)
    val captionSemibold = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    /** 微标（实测 --micro = 11） */
    val micro = TextStyle(fontSize = 11.sp)
    val microSemibold = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
    /** 徽标（评分徽标 13/600、状态胶囊 10.5/600） */
    val badge = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    val pill = TextStyle(fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold)
    /** 分区小标签（11/650 36%） */
    val groupLabel = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.2.sp)

    // ── 旧名兼容（值已换成实测值；新代码用上面的名字）──
    val largeTitle = display
    val callout = body
    val subheadline = sub
    val subheadlineSemibold = subSemibold
    val footnote = caption
    val caption2 = micro
    val caption2Semibold = microSemibold
    /** 微徽标 */
    val tag = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium)
}

/* ── 旧名兼容别名（新代码请用上面的语义名） ──────────────────────────────────────────────────────────
 * 这些名字来自上一版（按 iOS Theme.swift 写的）值。保留名字、把值换成实测值，
 * 这样调用点可以逐个迁移，不必一次性改崩整个工程。新代码请用上面的语义名。
 */
val SurfaceInset = FillCard
val SurfaceRaised = GlassCapsule
val AccentSoft = Color(0x24CDD6E6)
val Success = Ok
val Warning = Warn

val McTypeCallout = McType.body
val McTypeFootnote = McType.caption
val McTypeCaption2 = McType.micro

/** 实测尺寸 */
object McMetrics {
    val pagePadding = 16.dp
    /** 顶栏动作钮 36×36 */
    val navButton = 36.dp
    /** 页签根页标题 16/600 在 x=12；子页标题 20/600 在 x=48，返回钮在 x=8 */
    val topBarHeight = 52.dp
    val topBarInsetRoot = 12.dp
    val topBarInsetSub = 8.dp

    /** 海报卡（实测 126×189，**圆角 16**；此前写的 12 是错的） */
    val posterRadius = 16.dp
    val rowCardWidth = 126.dp
    val rowSpacing = 12.dp
    const val posterAspect = 2f / 3f

    /** 平色卡/玻璃卡圆角 */
    val cardRadius = 16.dp
    /** 订阅卡与库详情卡的圆角是 12（比海报卡小） */
    val tileRadius = 12.dp
    /** 弹层圆角：菜单 14 */
    val menuRadius = 14.dp
    /** 待办卡/空态卡圆角 22 */
    val panelRadius = 22.dp

    /** 底栏：胶囊 348×54，左右 21、距底 22，5 格各 68×48，药丸白 15% */
    val tabBarHeight = 54.dp
    val tabBarInset = 21.dp
    val tabBarBottom = 22.dp

    /** 分区标题与内容间距：活动/我的 上 28 下 12；发现/媒体库 上 38 下 14 */
    val sectionTopTight = 28.dp
    val sectionBottomTight = 12.dp
    val sectionTop = 38.dp
    val sectionBottom = 14.dp
}

private val MovieClawColorScheme = darkColorScheme(
    primary = Accent,
    onPrimary = Color(0xFF141821),
    primaryContainer = Accent.copy(alpha = 0.14f),
    onPrimaryContainer = AccentStrong,
    secondary = Accent,
    onSecondary = Color(0xFF141821),
    background = Bg,
    onBackground = TextPrimary,
    surface = Bg,
    onSurface = TextPrimary,
    surfaceVariant = FillCard,
    onSurfaceVariant = TextMuted,
    surfaceContainer = Color(0xFF14161D),
    surfaceContainerHigh = Color(0xFF191C24),
    surfaceContainerLow = Color(0xFF0B0D12),
    error = Danger,
    outline = LineColor,
    outlineVariant = LineSoft,
)

private val MovieClawTypography = Typography(
    displayLarge = McType.display,
    headlineLarge = McType.title,
    headlineMedium = McType.title2,
    headlineSmall = McType.title3,
    titleLarge = McType.headline,
    titleMedium = McType.bodySemibold,
    titleSmall = McType.sub,
    bodyLarge = McType.body,
    bodyMedium = McType.sub,
    bodySmall = McType.caption,
    labelLarge = McType.subSemibold,
    labelMedium = McType.captionSemibold,
    labelSmall = McType.microSemibold,
)

private val MovieClawShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(24.dp),
)

@Composable
fun MovieClawTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = MovieClawColorScheme,
        typography = MovieClawTypography,
        shapes = MovieClawShapes,
        content = {
            // Material3 的 `LocalContentColor` 默认是**黑**，而 colorScheme 只影响
            // 走 colorScheme 取色的组件、不影响裸 `Text`。不设这一行，任何没写
            // `color =` 的 Text 都是黑字压黑底（＝看不见）。主题的 onBackground/onSurface
            // 本就是 TextPrimary，这里把它落到 LocalContentColor 上，语义一致。
            CompositionLocalProvider(LocalContentColor provides TextPrimary, content = content)
        },
    )
}
