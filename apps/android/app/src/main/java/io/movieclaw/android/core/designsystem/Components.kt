package io.movieclaw.android.core.designsystem

import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.draw.alpha

/** 简单加载态包装:Loading / Ready / Failed(对齐 iOS Loadable<Value>) */
sealed interface Loadable<out T> {
    data object Loading : Loadable<Nothing>
    data class Ready<T>(val value: T) : Loadable<T>
    data class Failed(val message: String) : Loadable<Nothing>
}

@Composable
fun <T> LoadablePane(
    state: Loadable<T>,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable (T) -> Unit,
) {
    when (state) {
        Loadable.Loading -> Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = TextMuted)
        }
        is Loadable.Failed -> ErrorPane(
            message = state.message,
            onRetry = onRetry,
            modifier = modifier,
        )
        is Loadable.Ready -> content(state.value)
    }
}

@Composable
fun ErrorPane(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("加载失败", style = McType.bodySemibold)
        Spacer(Modifier.height(6.dp))
        Text(message, style = McType.caption, color = TextMuted, lineHeight = 20.sp)
        Spacer(Modifier.height(14.dp))
        TextButton(onClick = onRetry) { Text("重试", style = McType.subSemibold, color = Accent) }
    }
}

/* ══════════════════════════════════════════════════════════════════════════════
 * 分区标题 —— 实测两档：
 *   17px/600：发现（豆瓣实时热门电影）、媒体库（接下来继续 / 最近添加）、搜索结果分组
 *   20px/700：库详情、订阅（日程 / 剧集订阅）、我的、设置、观看统计
 * 右侧动作「查看全部」是 14px、62% 白、**没有箭头**；部分分区右侧是计数（13px 36%）。
 * ══════════════════════════════════════════════════════════════════════════════ */

@Composable
fun SectionHeader(
    title: String,
    actionText: String? = null,
    onAction: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    /** 右侧计数（如「共 1 部」「10月4日 · 1 部」），13px 36% */
    counter: String? = null,
    /**
     * 右侧动作是不是「去往下一页」：是就带一枚右箭头（用户要求：不带箭头看着不像能点的按钮），
     * 就地动作（点一下清空 / 忽略之类）传 false。
     *
     * 两端参考在这里其实**不带**箭头（网页 `MediaRow` 的 more 链接与 iOS `LibrarySectionHeader`
     * 都是纯文字），活动页那种「查看全部 ›」才带；这里是按用户要求统一补上，只对
     * 「点进去还有一页」的动作生效。
     */
    actionChevron: Boolean = true,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = McMetrics.pagePadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = McType.headline, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.weight(1f))
        if (counter != null) {
            Text(counter, style = McType.caption, color = TextFaint, maxLines = 1)
        }
        if (actionText != null && onAction != null) {
            Spacer(Modifier.width(10.dp))
            Row(
                modifier = Modifier
                    .clickable(onClick = onAction)
                    .padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    actionText,
                    style = McType.sub,
                    color = TextMuted,
                    maxLines = 1,
                )
                if (actionChevron) {
                    Spacer(Modifier.width(2.dp))
                    Icon(
                        Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                        contentDescription = null,
                        tint = TextMuted,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }
    }
}

/** 20/700 的大分区标题（库详情 / 订阅日程 / 我的 / 设置） */
@Composable
fun SectionHeaderLarge(
    title: String,
    modifier: Modifier = Modifier,
    counter: String? = null,
    actionText: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = McMetrics.pagePadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = McType.title3, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.weight(1f))
        if (counter != null) Text(counter, style = McType.caption, color = TextFaint)
        if (actionText != null && onAction != null) {
            Spacer(Modifier.width(10.dp))
            Text(
                actionText,
                style = McType.sub,
                color = TextMuted,
                modifier = Modifier.clickable(onClick = onAction).padding(vertical = 6.dp),
            )
        }
    }
}

/** 分组小标签：实测 11/650、36% 白（「常用」「账号」「账号 / 资源与下载」…） */
@Composable
fun GroupLabel(text: String, modifier: Modifier = Modifier, inset: Dp = McMetrics.pagePadding) {
    Text(
        text,
        style = McType.groupLabel,
        color = TextFaint,
        modifier = modifier.padding(start = inset, end = inset, bottom = 6.dp),
    )
}

/** 渐变海报占位(无图 / 加载失败兜底,色相由 seed 决定) */
@Composable
fun PosterPlaceholder(seed: String, modifier: Modifier = Modifier) {
    val hue = remember(seed) { seed.hashCode().mod(360).toFloat() }
    Box(
        modifier.background(
            Brush.linearGradient(
                listOf(
                    Color.hsl(hue, 0.42f, 0.26f),
                    Color.hsl((hue + 45f) % 360f, 0.36f, 0.07f),
                )
            )
        )
    )
}

/** 保留类型（网页端海报卡没有缎带，仅为旧调用兼容） */
enum class PosterRibbon(val label: String) {
    OWNED("已入库"),
    SUBSCRIBED("已订阅"),
}

/**
 * 评分徽标 —— 实测：右上角内距 8、高 24、圆角 6、黑 70%、星 12 琥珀、文字 13/600 白。
 * （此前是 11pt 字 + 10dp 星 + 5/2 内边距，偏小。）
 */
@Composable
private fun RatingBadge(rating: Float, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .height(24.dp)
            .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(6.dp))
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Rounded.Star, contentDescription = null, tint = Warn, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(4.dp))
        Text("%.1f".format(rating), style = McType.badge, color = Color.White)
    }
}

/**
 * 海报卡「展开层」的宿主 —— 网页里这一层是 hover 出现的（整卡上浮、底部升起
 * 渐变信息层 + 次级操作键）。触摸端没有 hover，网页的语义是
 * **首次点按只展开**、看清后再点海报才进详情、点卡片外任意处收起
 * （components/poster-card.tsx 的 revealOnTouch / data-revealed）。
 * 这里用一枚共享的 key 表达「当前展开的是哪一张」，同一时刻只展开一张。
 */
val LocalPosterReveal = androidx.compose.runtime.compositionLocalOf<androidx.compose.runtime.MutableState<String?>?> { null }

/**
 * 海报卡 —— 实测（网页 .poster-card / 媒体库行）：**126×189、圆角 16、无描边**，
 * 图上只有一个右上角评分徽标（内距 8）；标题 16/600、副行 13/400 62%。
 * 网页端没有缎带 / 收藏心 / 左上角标签，这三个是此前照 iOS 加的，已停用。
 */
@Composable
fun PosterCard(
    imageUrl: String?,
    origin: String?,
    title: String,
    modifier: Modifier = Modifier,
    aspect: Float = McMetrics.posterAspect,
    meta: String? = null,
    rating: Float? = null,
    /** 海报角上的斜向**常显**标签（网页 poster-card：已入库绿、已订阅蓝） */
    ribbon: PosterRibbon? = null,
    @Suppress("UNUSED_PARAMETER") favorite: Boolean = false,
    @Suppress("UNUSED_PARAMETER") cornerLabel: String? = null,
    /** 展开层里的次级操作（网页：订阅影片 / 补齐缺集 / 自动续订）。给了它就按
     *  「首次点按展开」走，卡片不再单击直达详情。 */
    actionLabel: String? = null,
    actionIcon: ImageVector? = null,
    /** 中性动作键（已订阅：白 18% 底 + 绿勾），false 时是强调色（订阅影片） */
    actionNeutral: Boolean = false,
    /** 展开层的唯一标识：同一部片出现在多行时，只按片名做 key 会「一处展开、处处展开」 */
    instanceKey: String? = null,
    onAction: (() -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    val host = LocalPosterReveal.current
    val cardKey = instanceKey ?: (title + "@" + imageUrl.orEmpty())
    val hasAction = actionLabel != null && onAction != null
    val revealed = hasAction && host?.value == cardKey
    val tap: (() -> Unit)? = when {
        hasAction && !revealed -> ({ host?.value = cardKey })
        onClick != null -> ({ host?.value = null; onClick() })
        revealed -> ({ host?.value = null })
        else -> null
    }
    Column(
        modifier = modifier.then(if (tap != null) Modifier.clickable(onClick = tap) else Modifier),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(aspect)
                .shadow(10.dp, RoundedCornerShape(McMetrics.posterRadius), spotColor = Color.Black.copy(alpha = 0.35f))
                .clip(RoundedCornerShape(McMetrics.posterRadius))
                .background(Placeholder),
        ) {
            RemoteImage(
                url = imageUrl,
                origin = origin,
                contentDescription = title,
                modifier = Modifier.fillMaxSize(),
            )
            rating?.takeIf { it > 0f }?.let {
                RatingBadge(it, Modifier.align(Alignment.TopEnd).padding(8.dp))
            }
            // 常显斜标：已订阅（蓝）/ 已入库（绿）。网页卡片上"这部片订没订"就是靠它
            // 一眼看出来的——展开层里的动作键是第二层信息。
            ribbon?.let { r ->
                val tone = if (r == PosterRibbon.OWNED) Ok else Color(0xFF60A5FA)
                Box(
                    Modifier
                        .align(Alignment.TopStart)
                        .padding(8.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .background(tone.copy(alpha = 0.9f))
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                ) {
                    Text(r.label, style = McType.microSemibold, color = Color(0xFF0A0E12))
                }
            }
            if (hasAction) {
                val layer by androidx.compose.animation.core.animateFloatAsState(
                    targetValue = if (revealed) 1f else 0f,
                    animationSpec = tween(180),
                    label = "poster-action-layer",
                )
                Box(
                    Modifier
                        .matchParentSize()
                        .alpha(layer)
                        .background(
                            Brush.verticalGradient(
                                0.5f to Color.Transparent,
                                1f to Color.Black.copy(alpha = 0.82f),
                            )
                        ),
                ) {
                    Row(
                        Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 10.dp)
                            .height(32.dp)
                            .clip(RoundedCornerShape(999.dp))
                            // 未订阅：银白实底 + 深色字（discoverProminentButton 同款）；
                            // 已订阅：白 18% 底 + 白字 + 绿勾（移动端网页实测的「已订阅」键）
                            .background(
                                if (actionNeutral) {
                                    Brush.linearGradient(listOf(Color.White.copy(alpha = 0.18f), Color.White.copy(alpha = 0.18f)))
                                } else {
                                    Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6)))
                                }
                            )
                            .clickable(enabled = revealed) { host?.value = null; onAction?.invoke() }
                            .padding(horizontal = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        actionIcon?.let {
                            Icon(
                                it,
                                contentDescription = null,
                                tint = if (actionNeutral) Ok else Color(0xFF141821),
                                modifier = Modifier.size(14.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                        }
                        Text(
                            actionLabel.orEmpty(),
                            style = McType.captionSemibold,
                            color = if (actionNeutral) Color.White else Color(0xFF141821),
                            maxLines = 1,
                        )
                    }
                }
            }
        }
        if (title.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Text(
                title,
                style = McType.bodySemibold,
                color = TextPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (!meta.isNullOrEmpty()) {
            Spacer(Modifier.height(2.dp))
            Text(meta, style = McType.caption, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** 横滑行容器:统一 16 内边距 + 12 间距(横滑行的黄金数字) */
@Composable
fun McRow(content: LazyListScope.() -> Unit) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = McMetrics.pagePadding),
        horizontalArrangement = Arrangement.spacedBy(McMetrics.rowSpacing),
        content = content,
    )
}

/**
 * 继续观看卡（媒体库「接下来继续」）—— 按 iOS `LibraryHomeView.UpNextCard` 复刻：
 *   卡 200 宽、图 16:9、圆角 16；
 *   **图上**底部 56 高的渐变（黑 75% → 透明），渐变里叠「已播/总时长」与一条进度条
 *   （轨白 25%、已播段 accent2 实心），中央一枚 40 空心播放钮；
 *   图下三到四行：标题 / 分集（`S1E3 · 集名`，电影是年份）/ 为什么在这儿（「3 天前看到 37%」）/「还有 N 集」。
 *
 * 之前那版没有进度条、剧集也只显示年份——用户反馈"没有进度条，没有集数"。
 */
@Composable
fun ContinueWatchingCard(
    imageUrl: String?,
    origin: String?,
    title: String,
    /** 分集「S1E3 · 集名」；电影给年份 */
    context: String?,
    /** 第三行：为什么它在这儿（「3 天前看到 37%」） */
    stateLabel: String?,
    /** 「已播 / 总时长」，只在看了一半时给 */
    clockText: String? = null,
    /** 0~100；null = 不画进度条 */
    progressPercent: Int? = null,
    /** 「还有 N 集」；null/0 = 不显示 */
    remainingEpisodes: Int? = null,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    /** 右上角 ✕：把这条从「接下来继续」里叉掉（本机偏好；null = 不显示 ✕） */
    onClose: (() -> Unit)? = null,
) {
    Column(
        modifier = modifier.width(200.dp).then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(McMetrics.cardRadius))
                .background(Placeholder),
        ) {
            RemoteImage(imageUrl, origin, contentDescription = title, modifier = Modifier.fillMaxSize())
            // 右上角 ✕：叉掉这条（iOS 46e425f0；暗底圆钮，避免和整卡点击混在一起）
            if (onClose != null) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .padding(4.dp)
                        .size(26.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.Black.copy(alpha = 0.45f))
                        .clickable(onClick = onClose),
                    contentAlignment = Alignment.Center,
                ) {
                    androidx.compose.material3.Icon(
                        Icons.Rounded.Close,
                        contentDescription = "从接下来继续中隐藏",
                        tint = Color.White,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .height(56.dp)
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f)))),
            )
            // 渐变里的「已播 / 总时长」与进度条（iOS 同款位置：贴图底、左侧对齐）
            Column(
                Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth()
                    .padding(start = 10.dp, end = 10.dp, bottom = 9.dp),
            ) {
                if (!clockText.isNullOrEmpty()) {
                    Text(
                        clockText,
                        style = McType.caption2Semibold,
                        color = Color.White.copy(alpha = 0.85f),
                        maxLines = 1,
                    )
                }
                if (progressPercent != null) {
                    Spacer(Modifier.height(5.dp))
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(3.dp)
                            .clip(RoundedCornerShape(999.dp))
                            .background(Color.White.copy(alpha = 0.25f)),
                    ) {
                        Box(
                            Modifier
                                .fillMaxWidth((progressPercent / 100f).coerceIn(0f, 1f))
                                .height(3.dp)
                                .clip(RoundedCornerShape(999.dp))
                                .background(Accent2),
                        )
                    }
                }
            }
            Box(
                Modifier
                    .align(Alignment.Center)
                    .size(40.dp)
                    .clip(CircleShape)
                    .border(1.5.dp, Color.White.copy(alpha = 0.75f), CircleShape),
                contentAlignment = Alignment.Center,
            ) { PlayGlyph() }
        }
        Spacer(Modifier.height(8.dp))
        Text(title, style = McType.bodySemibold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (!context.isNullOrEmpty()) {
            Spacer(Modifier.height(2.dp))
            Text(context, style = McType.sub, color = TextMuted, maxLines = 1)
        }
        if (!stateLabel.isNullOrEmpty()) {
            Text(stateLabel, style = McType.caption, color = TextFaint, maxLines = 1)
        }
        if (remainingEpisodes != null && remainingEpisodes > 0) {
            Text("还有 $remainingEpisodes 集", style = McType.caption, color = TextFaint, maxLines = 1)
        }
    }
}

/** 播放三角（实测路径：从 x=8 起、宽约 11 的圆角三角） */
@Composable
private fun PlayGlyph(size: Dp = 32.dp) {
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
            val s = this.size.minDimension
            val p = androidx.compose.ui.graphics.Path().apply {
                moveTo(s * 0.34f, s * 0.24f)
                lineTo(s * 0.34f, s * 0.76f)
                quadraticBezierTo(s * 0.34f, s * 0.81f, s * 0.385f, s * 0.78f)
                lineTo(s * 0.80f, s * 0.53f)
                quadraticBezierTo(s * 0.845f, s * 0.50f, s * 0.80f, s * 0.47f)
                lineTo(s * 0.385f, s * 0.22f)
                quadraticBezierTo(s * 0.34f, s * 0.19f, s * 0.34f, s * 0.24f)
                close()
            }
            drawPath(p, Color.White)
        }
    }
}

/**
 * 平色列表卡 —— 实测：white 4% 填充 + 1px white 8% 描边 + 圆角 16，
 * 行间 6% 白分隔线。**不是玻璃**（这是列表卡与浮层卡的关键区别）。
 */
@Composable
fun FlatCard(
    modifier: Modifier = Modifier,
    radius: Dp = McMetrics.cardRadius,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(radius))
            .background(FillCard)
            .border(1.dp, LineColor, RoundedCornerShape(radius)),
        content = content,
    )
}

/** 玻璃浮层卡 —— 实测 rgba(14,16,22,.45)（继续观看的浮层 / 订阅空态那类） */
@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    radius: Dp = McMetrics.cardRadius,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(radius))
            .background(GlassCard)
            .border(1.dp, LineSoft, RoundedCornerShape(radius))
            .padding(14.dp),
        content = content,
    )
}

/** 平色卡里的一行：49 高（我的）/ 45（设置），左图标列 30，行尾雪佛龙 */
@Composable
fun FlatRow(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    height: Dp = 49.dp,
    icon: ImageVector? = null,
    titleColor: Color = TextPrimary,
    trailing: (@Composable () -> Unit)? = null,
    showChevron: Boolean = true,
    onClick: (() -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Box(
                Modifier
                    .size(30.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(Color.White.copy(alpha = 0.04f)),
                contentAlignment = Alignment.Center,
            ) { Icon(icon, contentDescription = null, tint = titleColor, modifier = Modifier.size(17.dp)) }
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = McType.bodyMedium, color = titleColor, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!subtitle.isNullOrEmpty()) {
                Spacer(Modifier.height(3.dp))
                Text(subtitle, style = McType.caption, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (trailing != null) trailing()
        if (showChevron) {
            Icon(
                Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                contentDescription = null,
                tint = TextFaint,
                modifier = Modifier.size(15.dp),
            )
        }
    }
}

/** 骨架块:白 8% ↔ 4% 呼吸,0.9s 循环(iOS DiscoverSkeletonBlock) */
@Composable
fun SkeletonBlock(modifier: Modifier = Modifier, radius: Dp = 12.dp) {
    val transition = rememberInfiniteTransition(label = "skeleton")
    val alpha by transition.animateFloat(
        initialValue = 0.08f,
        targetValue = 0.04f,
        animationSpec = infiniteRepeatable(tween(900, easing = EaseInOut), RepeatMode.Reverse),
        label = "skeleton-alpha",
    )
    Box(modifier.clip(RoundedCornerShape(radius)).background(Color.White.copy(alpha = alpha)))
}

/** 海报行骨架:保留真实标题 + 4 个 126×189 块(布局不跳) */
@Composable
fun PosterRowSkeleton(title: String) {
    Column {
        SectionHeader(title)
        Spacer(Modifier.height(11.dp))
        Row(
            modifier = Modifier.padding(horizontal = McMetrics.pagePadding),
            horizontalArrangement = Arrangement.spacedBy(McMetrics.rowSpacing),
        ) {
            repeat(4) {
                SkeletonBlock(
                    Modifier
                        .width(McMetrics.rowCardWidth)
                        .aspectRatio(McMetrics.posterAspect),
                )
            }
        }
    }
}

/** 网格骨架(2:3 海报,cols 列) */
@Composable
fun GridSkeleton(cols: Int = 3, rows: Int = 2, modifier: Modifier = Modifier) {
    Column(modifier.padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        repeat(rows) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                repeat(cols) {
                    SkeletonBlock(
                        Modifier
                            .weight(1f)
                            .aspectRatio(McMetrics.posterAspect),
                    )
                }
            }
        }
    }
}

/** 细进度条（轨道白 12%，填充可指定色） */
@Composable
fun ProgressBar(fraction: Float, modifier: Modifier = Modifier, tint: Color = Accent) {
    Box(
        modifier
            .fillMaxWidth()
            .height(3.dp)
            .clip(RoundedCornerShape(3.dp))
            .background(Color.White.copy(alpha = 0.12f)),
    ) {
        Box(
            Modifier
                .fillMaxWidth(fraction.coerceIn(0f, 1f))
                .height(3.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(tint),
        )
    }
}

/** 居中信息占位页 */
@Composable
fun InfoPane(icon: ImageVector, title: String, message: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(icon, contentDescription = null, tint = TextFaint, modifier = Modifier.size(44.dp))
        Spacer(Modifier.height(14.dp))
        Text(title, style = McType.headline)
        Spacer(Modifier.height(8.dp))
        Text(
            message,
            style = McType.caption,
            color = TextMuted,
            lineHeight = 20.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}

/** 标签胶囊(iOS DiscoverTag / LibraryChip) */
@Composable
fun McTag(
    text: String,
    modifier: Modifier = Modifier,
    foreground: Color = TextMuted,
    background: Color = Color.White.copy(alpha = 0.06f),
) {
    Text(
        text,
        style = McType.tag,
        color = foreground,
        maxLines = 1,
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(background)
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

@Composable
fun MetaText(text: String, modifier: Modifier = Modifier) {
    Text(text, style = McType.caption, color = TextMuted, modifier = modifier)
}

/** 圆形状态点(活动页:iOS ActivityStatusDot,可脉冲) */
@Composable
fun StatusDot(color: Color, size: Dp = 8.dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size).background(color, CircleShape))
}

@Composable
fun BodyText(text: String, modifier: Modifier = Modifier, color: Color = TextPrimary) {
    Text(text, style = McType.body, color = color, modifier = modifier, lineHeight = 26.sp)
}

@Composable
fun Caption(text: String, modifier: Modifier = Modifier, color: Color = TextMuted) {
    Text(text, style = McType.caption, color = color, modifier = modifier)
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(text, style = McType.title3, modifier = modifier, color = TextPrimary)
}

@Composable
fun WeightedMeta(text: String, weight: FontWeight, modifier: Modifier = Modifier) {
    Text(text, style = McType.caption.copy(fontWeight = weight), color = TextMuted, modifier = modifier)
}

/** 页签根页标题：实测 16/600（不是 28/700 —— 那是发现页专用的大标题） */
@Composable
fun PageTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = McType.bodySemibold, color = TextPrimary, modifier = modifier)
}

/** 发现页大标题：30/700 */
@Composable
fun BigPageTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = McType.display, color = TextPrimary, modifier = modifier)
}

@Composable
fun InlineTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = McType.headline, color = TextPrimary, modifier = modifier)
}

@Composable
fun MutedText(text: String, modifier: Modifier = Modifier, style: androidx.compose.ui.text.TextStyle = McType.caption) {
    Text(text, style = style, color = TextMuted, modifier = modifier)
}

@Composable
fun FaintText(text: String, modifier: Modifier = Modifier, style: androidx.compose.ui.text.TextStyle = McType.caption) {
    Text(text, style = style, color = TextFaint, modifier = modifier)
}

/**
 * 库详情卡 —— 实测：两列、宽 156、图 2:3（234 高）、圆角 16；
 * 卡下半部有一条 130 高的信息层（底部压暗渐变），内容是「第 1 季 · 全 26 集」13/600 `#9fb0c1`、
 * 「★ 5.5」13/75% 白，以及一枚 92×28 的操作按钮（自动续订 / 补齐缺集）。
 *
 * **触摸端取舍**：网页上这层与那颗按钮是 hover 才出现的（默认 opacity:0 + translate-y-3），
 * 触屏没有 hover。这里把「信息」（集数 + 评分）常显，把「动作」（订阅开关）留空
 * —— 后者需要长按菜单或放进详情页，等产品定了入口再补。
 */
@Composable
fun LibraryItemCard(
    item: io.movieclaw.android.core.model.LibraryItemView,
    origin: String?,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
) {
    Column(modifier.then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(McMetrics.cardRadius))
                .background(Placeholder),
        ) {
            RemoteImage(
                url = item.posterUrl ?: item.backdropUrl,
                origin = origin,
                contentDescription = item.title,
                modifier = Modifier.fillMaxSize(),
            )
            Column(
                Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth()
                    .background(
                        Brush.verticalGradient(
                            0f to Color.Transparent,
                            0.34f to Color.Black.copy(alpha = 0.55f),
                            1f to Color.Black.copy(alpha = 0.9f),
                        )
                    )
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                val episodeLine = item.seasons.takeIf { it.isNotEmpty() }?.let { seasons ->
                    val season = seasons.first()
                    if (item.episodeCount != null) "第 $season 季 · 全 ${item.episodeCount} 集" else "第 $season 季"
                }
                if (episodeLine != null) {
                    Text(episodeLine, style = McType.captionSemibold, color = Accent2, maxLines = 1)
                }
                item.rating?.takeIf { it > 0f }?.let {
                    Spacer(Modifier.height(3.dp))
                    Text("★ %.1f".format(it), style = McType.caption, color = Color.White.copy(alpha = 0.75f))
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            item.title,
            style = McType.bodySemibold,
            color = TextPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        item.year?.let {
            Spacer(Modifier.height(2.dp))
            Text(it.toString(), style = McType.caption, color = TextMuted)
        }
    }
}
