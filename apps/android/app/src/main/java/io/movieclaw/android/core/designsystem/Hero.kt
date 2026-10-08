package io.movieclaw.android.core.designsystem

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Hero 轮播的一屏数据 */
data class HeroSlide(
    val id: String,
    val backdropUrl: String?,
    val origin: String?,
    /** 「今日精选 · 电影」——13/600、#9fb0c1、字距 .2em、大写 */
    val label: String,
    val title: String,
    /** 原名（西文小字，13/400、白 55%） */
    val originalTitle: String? = null,
    val rating: Float? = null,
    val year: String? = null,
    /** 「恐怖 / 科幻 / 冒险」 */
    val genres: String? = null,
    val synopsis: String? = null,
    /** 右下动作按钮（订阅影片 / 已订阅） */
    val actionLabel: String = "订阅影片",
    val subscribed: Boolean = false,
)

/** 轮播停留时长 —— 实测 8000ms（进度条就是按这个时长跑满） */
const val HERO_INTERVAL_MS = 8000

/**
 * 沉浸式 Hero 轮播 —— 实测（apps/web components/immersive-hero.tsx）：
 *   · 背景整幅剧照，高 520（= 屏宽的 1.333），**图片带遮罩**
 *     `#000 0% → #000 56% → rgba(0,0,0,.6) 80% → transparent 100%`，
 *     让标题/简介所在的区域自己淡出（文字不是"压在图上"，是"图让开了"）；
 *   · 同一遮罩也罩住那层 `transparent 36% → 黑 50%` 的压暗渐变 —— 两者必须同遮罩，
 *     否则底边会留一道 50% 黑的断差（这是实测踩过的坑）；
 *   · 图片另做 1.1 倍过扫（实测 img 盒 418×572 @ (-19,-26) = 380×520 × 1.1）；
 *   · 底部页码：当前格是 **26×5 进度条**（轨道白 26%，内层白 95% 按 8s 线性填满），
 *     其余是 5×5 圆点（白 34%）；容器距底 16、间距 6。
 */
@Composable
fun HeroCarousel(
    slides: List<HeroSlide>,
    modifier: Modifier = Modifier,
    currentPage: Int,
    onPageChange: (Int) -> Unit,
    onOpenSlide: (HeroSlide) -> Unit,
    onAction: (HeroSlide) -> Unit,
    /** 列车式视差（网页 translate3d(0, scroll×0.4px)）：传滚动距离即可 */
    parallaxPx: Float = 0f,
    /** 内容淡出（iOS：1 - scroll/260，滚到 260pt 时文字与指示器全透明） */
    contentFade: Float = 1f,
    showChrome: Boolean = true,
) {
    if (slides.isEmpty()) return
    val page = currentPage.coerceIn(0, slides.lastIndex)

    // 自动轮播：每 8s 前进一屏（与进度条同步）
    LaunchedEffect(page, slides.size) {
        kotlinx.coroutines.delay(HERO_INTERVAL_MS.toLong())
        onPageChange((page + 1) % slides.size)
    }

    /*
     * 切换方式：**原地交叉淡入**，不是横滑。
     * 网页把六张图层叠在同一位置，当前张 opacity=1、其余 0，
     * transition-opacity 700ms ease-out（components/immersive-hero.tsx）。
     * 之前用 HorizontalPager 横滑，切换时会看到两张各露一半、且每张都被推出画面
     * （“没铺满”）——与实测行为不符。
     */
    Box(
        modifier
            .fillMaxWidth()
            .height(HERO_HEIGHT)
            .clipToBounds(),
    ) {
        slides.forEachIndexed { i, slide ->
            val active = i == page
            val alpha by animateFloatAsState(
                targetValue = if (active) 1f else 0f,
                animationSpec = tween(durationMillis = 700, easing = EaseOut),
                label = "hero-fade-$i",
            )
            // Ken Burns：当前屏 12s 线性推近到 1.10（切换时归零重来）
            val kenBurns = remember(i) { Animatable(1f) }
            LaunchedEffect(active) {
                if (active) {
                    kenBurns.snapTo(1f)
                    kenBurns.animateTo(1.1f, tween(durationMillis = 12000, easing = LinearEasing))
                } else {
                    kenBurns.snapTo(1f)
                }
            }
            if (active || alpha > 0.001f) {
                HeroSlidePane(
                    slide = slide,
                    alpha = alpha,
                    zoom = kenBurns.value,
                    interactive = active,
                    parallaxPx = parallaxPx,
                    showChrome = showChrome && active,
                    contentFade = contentFade,
                    onClick = { onOpenSlide(slide) },
                    onAction = { onAction(slide) },
                    modifier = Modifier.matchParentSize(),
                )
            }
        }
        HeroProgressIndicator(
            count = slides.size,
            current = page,
            onSelect = onPageChange,
            // iOS DiscoverHero：指示器在右下（trailing 20 + 安全区），只有订阅页居中
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 20.dp, bottom = 16.dp)
                .graphicsLayer { this.alpha = contentFade },
        )
    }
}

/**
 * 剧照遮罩（实测）：`#000 0% → #000 56% → rgba(0,0,0,.6) 80% → transparent 100%`。
 * Compose 没有 mask-image，用 offscreen 图层 + BlendMode.DstIn 全等表达。
 * 注意：图与那层压暗渐变必须罩同一个遮罩，否则底边会留一道 50% 黑的断差。
 */
private fun Modifier.heroMask(): Modifier = this
    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        drawRect(
            brush = Brush.verticalGradient(
                0f to Color.Black,
                0.56f to Color.Black,
                0.80f to Color.Black.copy(alpha = 0.6f),
                1f to Color.Transparent,
            ),
            blendMode = BlendMode.DstIn,
        )
    }

@Composable
private fun HeroBackdrop(imageUrl: String?, origin: String?, contentDescription: String?) {
    RemoteImage(
        url = imageUrl,
        origin = origin,
        contentDescription = contentDescription,
        contentScale = ContentScale.Crop,
        modifier = Modifier.fillMaxSize(),
    )
}

/** Hero 高度：实测 520（视口 390 宽） */
val HERO_HEIGHT = 520.dp

@Composable
private fun HeroSlidePane(
    slide: HeroSlide,
    alpha: Float,
    zoom: Float,
    interactive: Boolean,
    parallaxPx: Float,
    showChrome: Boolean,
    contentFade: Float = 1f,
    onClick: () -> Unit,
    onAction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier
            .graphicsLayer { this.alpha = alpha }
            .then(if (interactive) Modifier.clickable(onClick = onClick) else Modifier),
    ) {
        // 剧照：1.1 倍过扫 + 滚动视差（实测 img 盒 418×572 @ -19,-26）。
        // 关键（HTML .hero-par 同款）：视差层比可视区**多出血**（上 160 / 下 80）并底对齐，
        // 否则图一往下移，顶部就露出黑带——「hero 与下面衔接颜色不对」的根因。
        // ⚠️ 遮罩必须同时罩住「图 + 压暗」——之前只罩了压暗层，剧照到 hero 底边是硬切，
        // 就是那条明显的分界线（HTML .hero-media 正是罩住两者的）。
        // 遮罩挂在**不动**的外层；里面才是会视差位移的出血层。
        Box(Modifier.matchParentSize().heroMask()) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(HERO_HEIGHT + 240.dp)
                    .align(Alignment.BottomCenter)
                    .graphicsLayer {
                        scaleX = zoom
                        scaleY = zoom
                        translationY = parallaxPx
                    },
            ) {
                HeroBackdrop(imageUrl = slide.backdropUrl, origin = slide.origin, contentDescription = slide.title)
                // 压暗渐变：transparent 36% → 黑 50%（与图同罩、一起溶解）
                Box(
                    Modifier
                        .matchParentSize()
                        .background(
                            Brush.verticalGradient(
                                0.36f to Color.Transparent,
                                1f to Color.Black.copy(alpha = 0.5f),
                            )
                        ),
                )
            }
        }
        // 顶部 scrim：高 26%、黑 50% → 透明（给顶栏留可读性）
        Box(
            Modifier
                .fillMaxWidth()
                .height(HERO_HEIGHT * 0.26f)
                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.5f), Color.Transparent))),
        )

        if (showChrome) {
            Column(
                Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth()
                    // iOS：滚动 260pt 内文字淡出，并随滚动下沉 0.15×
                    .graphicsLayer {
                        this.alpha = contentFade
                        this.translationY = parallaxPx * 0.375f
                    }
                    .padding(start = McMetrics.pagePadding, end = McMetrics.pagePadding, bottom = 32.dp),
            ) {
                Text(
                    slide.label,
                    style = McType.captionSemibold,
                    color = Accent2,
                    letterSpacing = 2.6.sp,
                    maxLines = 1,
                )
                Spacer(Modifier.height(4.dp))
                Text(slide.title, style = McType.display, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                if (!slide.originalTitle.isNullOrEmpty()) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        slide.originalTitle,
                        style = McType.caption.copy(fontWeight = FontWeight.Normal),
                        color = Color.White.copy(alpha = 0.55f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    slide.rating?.takeIf { it > 0f }?.let { r ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.Star, contentDescription = null, tint = Warn, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("%.1f".format(r), style = McType.subSemibold, color = Color.White)
                        }
                    }
                    slide.year?.let { Text(it, style = McType.sub, color = Color.White.copy(alpha = 0.8f)) }
                    slide.genres?.let {
                        Text(it, style = McType.sub, color = Color.White.copy(alpha = 0.8f), maxLines = 1)
                    }
                }
                if (!slide.synopsis.isNullOrEmpty()) {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        slide.synopsis,
                        style = McType.sub.copy(lineHeight = 20.sp),
                        color = Color.White.copy(alpha = 0.75f),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(13.dp))
                HeroActionPill(label = slide.actionLabel, subscribed = slide.subscribed, onClick = onAction)
            }
        }
    }
}

/** 实测：120×34、圆角 999；未订阅是银白实底深色字，已订阅是深色半透明底白字 */
@Composable
private fun HeroActionPill(label: String, subscribed: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .height(34.dp)
            .clip(RoundedCornerShape(999.dp))
            .then(
                if (subscribed) {
                    Modifier
                        .background(GlassCapsule)
                        .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(999.dp))
                } else {
                    Modifier.background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))))
                }
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (subscribed) Icons.Rounded.Check else Icons.Rounded.Add,
            contentDescription = null,
            // iOS 的对勾是成功绿；未订阅的加号/文字是深色（银白实底）
            tint = if (subscribed) Color(0xFF4ADE80) else Color(0xFF141821),
            modifier = Modifier.size(18.dp),
        )
        // Material Add 字形自带 ~3dp 内边距，6dp 间距的光学效果才对齐 iOS 的 ~6pt
        Spacer(Modifier.width(4.dp))
        Text(
            label,
            style = McType.bodySemibold,
            color = if (subscribed) Color.White else Color(0xFF141821),
        )
    }
}

/**
 * 轮播指示器 —— 实测：当前格 26×5（轨道白 26% + 内层白 95% 按停留时长线性填满），
 * 其余 5×5 白 34%；间距 6、距底 16。
 */
@Composable
fun HeroProgressIndicator(
    count: Int,
    current: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val progress = remember { Animatable(0f) }
    LaunchedEffect(current, count) {
        progress.snapTo(0f)
        progress.animateTo(1f, tween(HERO_INTERVAL_MS, easing = LinearEasing))
    }
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        repeat(count) { i ->
            if (i == current) {
                Box(
                    Modifier
                        .width(26.dp)
                        .height(5.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.26f)),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    Box(
                        Modifier
                            .fillMaxSize()
                            .graphicsLayer {
                                transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0f, 0.5f)
                                scaleX = progress.value
                            }
                            .background(Color.White.copy(alpha = 0.95f)),
                    )
                }
            } else {
                Box(
                    Modifier
                        .size(5.dp)
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.34f))
                        .clickable { onSelect(i) },
                )
            }
        }
    }
}

/**
 * 氛围底 —— 实测（HeroAmbientBackdrop）：整页竖直渐变
 * `c/.85 0% → c/.5 42% → c/.14 72% → transparent`，
 * 放在页面根、滚动容器之外；**最多留两层**（旧色在下面，新色 1.2s 淡入压上去）；
 * 下滚整体退淡到 0.35（900px 处）。颜色是当前剧照的主色（AmbientColor 取）。
 */
@Composable
fun HeroAmbientBackdrop(
    color: Color?,
    modifier: Modifier = Modifier,
    /** 滚动距离（px）；0 表示在顶部 */
    scrollPx: Float = 0f,
) {
    Box(modifier.fillMaxSize().background(Color.Black)) {
        if (color == null) return@Box
        val fade = (1f - scrollPx / 900f).coerceIn(0.35f, 1f)
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer { alpha = fade }
                .background(
                    Brush.verticalGradient(
                        0f to color.copy(alpha = 0.85f),
                        0.42f to color.copy(alpha = 0.50f),
                        0.72f to color.copy(alpha = 0.14f),
                        1f to Color.Transparent,
                    )
                ),
        )
    }
}
