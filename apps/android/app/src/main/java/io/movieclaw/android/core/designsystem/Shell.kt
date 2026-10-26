package io.movieclaw.android.core.designsystem

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.background
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import dev.chrisbanes.haze.HazeInputScale
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.VideoLibrary
import androidx.compose.material.icons.rounded.CollectionsBookmark

/* ══════════════════════════════════════════════════════════════════════════════
 * 外壳件（顶栏 / 底栏）—— 全部按移动端网页实测重做。
 *
 * 雾层：实测顶栏内容高 52，底下一层向下渐隐到 76（52 实心 + 24 渐隐），
 *      网页是 gradient + backdrop-filter: blur(14px) + mask；
 *      安卓没有 backdrop-filter，这里用同一梯度表达（纯黑底上等价，见 Theme.kt 注释）。
 * ══════════════════════════════════════════════════════════════════════════════ */

enum class McTopBarVariant {
    /** 发现页：大标题 30/700 + 源标签 13/600 62% 基线对齐；右侧「全部」胶囊 + 搜索圆钮 */
    Discover,

    /** 页签根页（媒体库/订阅/活动/我的）：标题 16/600 在 x=12 */
    Root,

    /** 子页（设置/搜索/库详情…）：返回钮 36×36 在 x=8，标题 20/600 在 x=48 */
    Sub,
}

/** 圆形玻璃动作钮（实测 36×36 / rgba(62,62,66,.4) / r999 / 图标约 18） */
@Composable
fun McNavButton(
    icon: ImageVector,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    tint: Color = Color.White.copy(alpha = 0.92f),
    badgeDot: Color? = null,
) {
    Box(
        modifier = modifier
            .size(McMetrics.navButton)
            .clip(CircleShape)
            .background(GlassCapsule)
            .border(1.dp, LineSoft, CircleShape)
            .glassSurface()
            // 液态玻璃（有取样源时覆盖上面的填充与边线；二级页无源则原样）
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(20.dp))
        if (badgeDot != null) {
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(7.dp)
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(badgeDot),
            )
        }
    }
}

/**
 * 顶栏。高度固定 52；雾层是「上黑 88% → 62% 处 60% → 底部透明」的竖直渐变，
 * 渐隐段一直铺到 76（= 52 + 24），与网页实测一致。
 */
@Composable
fun McTopBar(
    variant: McTopBarVariant,
    title: String,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    /** 发现页源标签（豆瓣 / TMDB），点开数据源菜单 */
    sourceLabel: String? = null,
    onSourceClick: (() -> Unit)? = null,
    /** 子页标题字号：设置类子页是 20/700（默认），库详情是 17/600 */
    titleStyle: androidx.compose.ui.text.TextStyle = McType.title3,
    /** 雾层顶部黑度（iOS 发现页压在英雄上时只有 0.5，其余页面 0.88） */
    mistStrength: Float = 0.88f,
    /** 雾层高度：发现页按英雄 26% ≈ 135dp 淡尽 */
    mistHeight: androidx.compose.ui.unit.Dp = McMetrics.topBarHeight + 24.dp,
    /**
     * 根页大标题。网页里「标签根页」挂大字标题（`setTopBarTitle(…, { large: true })`，
     * 28px/700）——活动页就是这样；媒体库 / 我的 走普通字重。
     */
    largeTitle: Boolean = false,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Box(modifier.fillMaxWidth()) {
        // 雾层（连状态栏一起盖）
        Box(
            Modifier
                .matchParentSize()
                .height(mistHeight)
                .background(
                    Brush.verticalGradient(
                        0f to Color.Black.copy(alpha = mistStrength),
                        0.62f to Color.Black.copy(alpha = mistStrength * 0.68f),
                        1f to Color.Transparent,
                    )
                ),
        )
        Row(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .height(McMetrics.topBarHeight)
                // 顶栏是浮层：它盖住的那条带子必须自己吃掉点击。空白处不吞的话，
                // 「电影 TMDB」这类按钮旁边差几像素的点击会**穿透到下面的 hero**，
                // 用户想换数据源却进了详情页（实测反馈）。
                .pointerInput(Unit) { detectTapGestures { /* 只吞掉，不做任何事 */ } }
                .padding(
                    horizontal = when (variant) {
                        McTopBarVariant.Discover, McTopBarVariant.Root -> McMetrics.topBarInsetRoot
                        McTopBarVariant.Sub -> McMetrics.topBarInsetSub
                    }
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            when (variant) {
                McTopBarVariant.Sub -> {
                    if (onBack != null) {
                        McNavButton(
                            icon = Icons.AutoMirrored.Rounded.ArrowBack,
                            contentDescription = "返回",
                            onClick = onBack,
                        )
                        Spacer(Modifier.width(4.dp))
                    }
                    Text(title, style = titleStyle, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                McTopBarVariant.Root -> {
                    Text(
                        title,
                        style = if (largeTitle) McType.display else McType.bodySemibold,
                        color = TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                McTopBarVariant.Discover -> {
                    Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(start = 4.dp)) {
                        Text(title, style = McType.display, color = TextPrimary, maxLines = 1)
                        if (sourceLabel != null) {
                            Spacer(Modifier.width(6.dp))
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                // 触控区按系统最小尺寸给足（44dp 高、左右各留 6dp），
                                // 视觉不变——小字按钮最容易被"差一点"点到别处
                                modifier = Modifier
                                    .padding(bottom = 2.dp)
                                    .let { m ->
                                        if (onSourceClick != null) {
                                            m
                                                .clip(RoundedCornerShape(8.dp))
                                                .clickable(onClick = onSourceClick)
                                                .padding(horizontal = 6.dp, vertical = 12.dp)
                                        } else {
                                            m
                                        }
                                    },
                            ) {
                                Text(sourceLabel, style = McType.badge, color = TextMuted, maxLines = 1)
                                Icon(
                                    Icons.Rounded.KeyboardArrowDown,
                                    contentDescription = null,
                                    tint = TextMuted,
                                    modifier = Modifier.size(13.dp),
                                )
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            actions()
        }
    }
}

/** 底栏页签上的状态点：颜色 + 读屏用的状态说明（iOS `TabBarDotBridge.Dot` 的对应物） */
data class TabDot(val color: androidx.compose.ui.graphics.Color, val label: String)

/**
 * 悬浮胶囊底栏 —— 实测：348×54（左右各 21、距底 22），圆角 999，
 * 底色 rgba(62,62,66,.4)，5 格各 68×48，当前格背后一枚白 15% 药丸。
 * **图标-only**：网页底栏没有文字标签（标签只存在于 aria-label）。
 */
@Composable
fun McCapsuleTabBar(
    icons: List<ImageVector>,
    labels: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    /** 最后一格是账号头像：有 `avatarUrl` 显示同步头像（iOS/网页同口径），否则首字徽标 */
    avatarInitials: String? = null,
    /** 当前账号的服务端头像（相对路径，走鉴权图片管线） */
    avatarUrl: String? = null,
    /** 头像地址解析用的服务器来源 */
    origin: String? = null,
    /** 要挂状态点的格下标 → 点（iOS：活动页签三色状态点、头像页签「有可用更新」蓝点） */
    dots: Map<Int, TabDot> = emptyMap(),
) {
    val count = icons.size
    // HTML：.tabbar{transition:transform .35s cubic-bezier(.32,.9,.3,1), opacity .3s}
    // 圆钮 .38s cubic-bezier(.32,.9,.3,1.08)（带一点回弹）
    val mini by animateFloatAsState(
        targetValue = if (TabBarMinimize.minimized) 1f else 0f,
        animationSpec = tween(
            durationMillis = 360,
            easing = androidx.compose.animation.core.CubicBezierEasing(0.32f, 0.9f, 0.3f, 1.02f),
        ),
        label = "tabbar-minimize",
    )
    Box(
        modifier
            .fillMaxWidth()
            .height(McMetrics.tabBarHeight + 8.dp),
    ) {
    // ── 收起态：液玻璃在左下角捏成 56pt 圆钮，只留当前格图标（点它弹回） ──
    if (mini > 0.01f) {
        Box(
            Modifier
                .align(Alignment.BottomStart)
                .size(56.dp)
                .graphicsLayer {
                    alpha = mini
                    scaleX = 0.6f + 0.4f * mini
                    scaleY = 0.6f + 0.4f * mini
                }
                .clip(RoundedCornerShape(999.dp))
                .background(GlassRaised)
                .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(999.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { TabBarMinimize.restore() },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icons.getOrNull(selectedIndex) ?: icons.first(),
                contentDescription = labels.getOrNull(selectedIndex),
                tint = Color.White,
                modifier = Modifier.size(23.dp),
            )
        }
    }
    // 关键：内容层必须用「真实宽度」——之前 matchParentSize + padding 让内边距不生效，
    // 胶囊与格子各按不同宽度计算，于是胶囊偏窄且偏左（这就是「不协调」的根因）
    androidx.compose.foundation.layout.BoxWithConstraints(
        Modifier
            // **顺序要紧**：`widthIn` 必须在 `fillMaxWidth` 之前——先收窄约束，
            // fillMaxWidth 才只填到 420dp；写反了就等于被撑满、上限不生效（踩过一次）。
            .widthIn(max = 420.dp)
            .fillMaxWidth()
            .padding(horizontal = McMetrics.tabBarInset)
            .height(McMetrics.tabBarHeight)
            .align(Alignment.BottomCenter)
            .graphicsLayer {
                alpha = 1f - mini
                translationX = -44.dp.toPx() * mini
                scaleX = 1f - 0.12f * mini
                scaleY = 1f - 0.12f * mini
            },
    ) {
        Box(
            Modifier
                .matchParentSize()
                .clip(RoundedCornerShape(999.dp))
                // 大屏（平板竖屏也走这里）用**实底深色**：`GlassCapsule` 是半透明玻璃，
                // 压在亮色剧照上五个图标就是几条细白线（真机截图确认）；低性能平板也省一次模糊。
                // **手机保留玻璃**：这是手机上一贯的观感，不为平板降级。
                .background(GlassCapsule)

                .border(1.dp, LineSoft, RoundedCornerShape(999.dp)),
        )
        // 点击反馈一律不要水波纹：格子是方的，Material 的 ripple 就是一圈**矩形光晕**
        // （用户反馈"点一下有个矩形的光晕"）。交互源在这里统一建，循环里 remember 依赖
        // 调用顺序，count 一变就错位。
        val cellInteractions = remember(count) { List(count) { MutableInteractionSource() } }
        val cellWidth = (maxWidth - 6.dp) / count
        val pillOffset by animateDpAsState(
            targetValue = cellWidth * selectedIndex,
            animationSpec = tween(durationMillis = 420, easing = androidx.compose.animation.core.CubicBezierEasing(0.2f, 0.9f, 0.25f, 1.08f)),
            label = "tab-pill",
        )
        Box(
            Modifier
                .padding(3.dp)
                .offset(x = pillOffset)
                .width(cellWidth)
                .height(48.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(Color.White.copy(alpha = 0.15f)),
        )
        Row(Modifier.matchParentSize().padding(3.dp), verticalAlignment = Alignment.CenterVertically) {
            repeat(count) { i ->
                val active = i == selectedIndex
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxSize()
                        .clickable(
                            interactionSource = cellInteractions[i],
                            indication = null,
                        ) { onSelect(i) },
                    contentAlignment = Alignment.Center,
                ) {
                    if (i == count - 1 && (avatarUrl != null || avatarInitials != null)) {
                        // 「我的」格 = 当前账号头像：有同步头像显示头像，否则首字徽标（iOS/网页同口径）
                        if (avatarUrl != null) {
                            RemoteImage(
                                url = avatarUrl,
                                origin = origin,
                                widthHint = 96,
                                contentDescription = labels.getOrNull(i),
                                modifier = Modifier.size(25.dp).clip(CircleShape),
                            )
                        } else {
                            Box(
                                Modifier.size(25.dp).clip(CircleShape).background(Color.White),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(avatarInitials ?: "", style = McType.microSemibold, color = Color(0xFF141821))
                            }
                        }
                    } else {
                        Icon(
                            icons[i],
                            contentDescription = labels.getOrNull(i),
                            tint = if (active) Color.White else Color.White.copy(alpha = 0.42f),
                            modifier = Modifier.size(23.dp),
                        )
                    }
                    dots[i]?.let { dot ->
                        Box(
                            Modifier
                                .align(Alignment.TopCenter)
                                .offset(y = 8.dp, x = 10.dp)
                                .size(6.dp)
                                .clip(CircleShape)
                                .background(dot.color)
                                // 读屏念状态说明（iOS `TabBarDotBridge.Dot.label` 同款），别只念出个圆点
                                .semantics { stateDescription = dot.label },
                        )
                    }
                }
            }
        }
    }
    }
}

/** 内容区为悬浮底栏预留的底部留白（底栏 54 + 距底 22 + 呼吸 20） */
val McTabBarContentPadding: Dp = McMetrics.tabBarHeight + McMetrics.tabBarBottom + 20.dp

/** 宽窗口侧边栏宽度（照 Mac 版侧边栏的视觉量级，比 92 的图标栏宽出文字位） */
val McSidebarWidth: Dp = 248.dp

/** 宽窗口外壳留白：侧栏四周留 14dp，背景剧照从缝隙里透出（网页端同款） */
val McShellInset: Dp = 14.dp

/** 浮起侧栏卡片的圆角（网页端 GlassPanel 的 16px） */
val McSidebarCorner: Dp = 16.dp


/**
 * 宽窗口的**侧边栏**（对应 iOS `.sidebarAdaptable` 的展开态，`docs/design/ipad.md` §3）。
 *
 * 文档里那句「侧边栏和 Mac 版同构」：除页签外还按
 * 「媒体库」「合集」两个分组把库与合集**逐个列出**。窄窗口仍用底栏，不走这里。
 *
 * 已知差距（文档里 iOS 有、安卓这边还缺）：每项各自的导航栈、侧边栏上的「编辑」、
 * 库名后面的部数（服务端 `LibraryView` 没有这个字段）。
 */
@Composable
fun McSidebar(
    icons: List<ImageVector>,
    labels: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    libraries: List<Pair<Long, String>> = emptyList(),
    onOpenLibrary: (Long, String) -> Unit = { _, _ -> },
    collections: List<Pair<Long, String>> = emptyList(),
    onOpenCollection: (Long, String) -> Unit = { _, _ -> },
    onSearch: () -> Unit = {},
    accountName: String? = null,
    accountInitials: String? = null,
    /** 账号头像（相对路径，走鉴权图片管线）；没有就退回首字徽标 */
    accountAvatarUrl: String? = null,
    accountOrigin: String? = null,
    onOpenAccount: () -> Unit = {},
    dots: Map<Int, TabDot> = emptyMap(),
    /** 外壳整窗背景的取样源：侧栏是透光磨砂玻璃（网页端 sampleBackground: 1） */
    hazeState: dev.chrisbanes.haze.HazeState? = null,
    /** 当前正打开的库 / 合集 id：对应那一行要高亮（iOS 侧边栏会选中所处的那一项） */
    selectedLibraryId: Long? = null,
    selectedCollectionId: Long? = null,
) {
    val shape = RoundedCornerShape(McSidebarCorner)
    Box(
        modifier
            .width(McSidebarWidth)
            .fillMaxHeight()
            // 网页端侧栏是浮起的**透光磨砂玻璃卡片**：采样整窗剧照（sampleBackground:1）。
            .shadow(8.dp, shape, clip = false)
            .clip(shape)
            .then(
                if (hazeState != null) {
                    Modifier.hazeEffect(hazeState) {
                        style = HazeStyle(
                            // 不透明中性底：只让外壳窗口背景参与磨砂，不让卡片下方的内容
                            // 再透出来（网页端侧栏 opacity 0.96，也是这个效果）。
                            backgroundColor = Color(0xFF1A1C22),
                            tints = listOf(
                                HazeTint(Color.Black.copy(alpha = 0.18f)),
                                HazeTint(Color.White.copy(alpha = 0.04f)),
                            ),
                            blurRadius = 24.dp,
                            noiseFactor = 0f,
                        )
                        inputScale = HazeInputScale.Auto
                    }
                } else {
                    Modifier.background(Color.White.copy(alpha = 0.10f))
                },
            )
            .background(
                Brush.verticalGradient(
                    0f to Color.White.copy(alpha = 0.06f),
                    0.45f to Color.Transparent,
                    1f to Color.Black.copy(alpha = 0.10f),
                )
            ),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(top = 10.dp, bottom = 2.dp),
        ) {
        // 列表区：搜索与页签固定在顶部，只有库/合集列表滚动；账号行固定在底部
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth(),
        ) {
        // 搜索（`ipad.md` §3：侧边栏模式下用侧边栏第一行的搜索框，右上角放大镜保留在标签栏模式）
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Color.White.copy(alpha = 0.06f))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { onSearch() }
                .padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                androidx.compose.material.icons.Icons.Rounded.Search,
                contentDescription = "搜索",
                tint = TextMuted,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text("搜索", style = McType.sub, color = TextMuted, maxLines = 1)
        }
        Spacer(Modifier.height(8.dp))

        // 固定页签
        icons.forEachIndexed { i, icon ->
            val sel = i == selectedIndex
            SidebarRow(
                label = labels.getOrNull(i).orEmpty(),
                selected = sel,
                dot = dots[i],
                onClick = { onSelect(i) },
            ) {
                Icon(
                    icon,
                    contentDescription = labels.getOrNull(i),
                    tint = if (sel) Color.White else TextMuted,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        // 中间区可滚动：库/合集多时不会把账号行挤出屏幕
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
        if (libraries.isNotEmpty()) {
            SidebarGroupLabel("媒体库")
            libraries.forEach { (id, name) ->
                SidebarRow(label = name, selected = id == selectedLibraryId, dot = null, onClick = { onOpenLibrary(id, name) }) {
                    Icon(
                        androidx.compose.material.icons.Icons.Rounded.VideoLibrary,
                        contentDescription = null,
                        tint = TextMuted,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }

        if (collections.isNotEmpty()) {
            SidebarGroupLabel("合集")
            collections.forEach { (id, name) ->
                SidebarRow(label = name, selected = id == selectedCollectionId, dot = null, onClick = { onOpenCollection(id, name) }) {
                    Icon(
                        androidx.compose.material.icons.Icons.Rounded.CollectionsBookmark,
                        contentDescription = null,
                        tint = TextMuted,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }

        }
        }
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 4.dp)
                .clip(RoundedCornerShape(10.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { onOpenAccount() }
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(26.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                if (accountAvatarUrl != null) {
                    RemoteImage(url = accountAvatarUrl, origin = accountOrigin, contentDescription = accountName, modifier = Modifier.fillMaxSize().clip(CircleShape))
                } else {
                Text(
                    accountInitials?.take(1)?.uppercase() ?: "?",
                    style = McType.caption2Semibold,
                        color = Color.White,
                    )
                }
            }
            Spacer(Modifier.width(8.dp))
            Text(
                accountName ?: "未登录",
                style = McType.sub,
                color = TextPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
    }
}

@Composable
private fun SidebarGroupLabel(text: String) {
    Text(
        text,
        style = McType.caption2,
        color = TextFaint,
        modifier = Modifier.padding(start = 20.dp, top = 14.dp, bottom = 4.dp),
    )
}

@Composable
private fun SidebarRow(
    label: String,
    selected: Boolean,
    dot: TabDot?,
    onClick: () -> Unit,
    leading: @Composable () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 1.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (selected) Color.White.copy(alpha = 0.12f) else Color.Transparent)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) { onClick() }
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // 状态点画在**行尾**（原来只有 6dp、叠在图标右上角，压在图标上根本看不出来）
        Box { leading() }
        Spacer(Modifier.width(10.dp))
        Text(
            label,
            style = McType.sub,
            color = if (selected) Color.White else TextMuted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        dot?.let {
            Spacer(Modifier.weight(1f))
            Box(
                Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(it.color)
                    .semantics { stateDescription = it.label },
            )
        }
    }
}
