package io.movieclaw.android.feature.subscriptions

import io.movieclaw.android.core.designsystem.LocalFeedback
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.designsystem.McType
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.ui.draw.alpha
import androidx.compose.material.icons.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.BookmarkBorder
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextAlign
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McTabBarContentPadding
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.Placeholder
import io.movieclaw.android.core.designsystem.SectionHeaderLarge
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warn
import io.movieclaw.android.core.model.TodayArrival
import java.time.LocalDate
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.statusColor
import io.movieclaw.android.core.designsystem.progressNote
import io.movieclaw.android.core.designsystem.statusLabel
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.PosterPlaceholder
import io.movieclaw.android.core.designsystem.ProgressBar
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.SubscriptionView

/**
 * 下一集英雄 —— 实测：高 500、整幅剧照铺满，图片带遮罩
 * `#000 0% → #000 56% → rgba(0,0,0,.6) 80% → transparent 100%`，
 * 同一遮罩罩住那层 `transparent 36% → 黑 50%` 的压暗；顶部另有 130 高的 scrim 给状态栏。
 * 内容居中竖排：剧集 logo（App 没有 logo 字段，用剧名大字替代）→「S01E08 · 10月4日」15/600 白 90%
 * →「周日」36/300 →「查看订阅」108×44 圆角 999 白 16% + blur 12。
 */
@Composable
private fun ArrivalHero(
    subscription: SubscriptionView,
    arrival: TodayArrival?,
    origin: String?,
    onOpen: () -> Unit,
) {
    Box(Modifier.fillMaxWidth().height(500.dp).clipToBounds()) {
        RemoteImage(
            url = subscription.media.backdropUrl ?: subscription.media.posterUrl,
            origin = origin,
            contentDescription = subscription.media.title,
            modifier = Modifier
                .matchParentSize()
                .graphicsLayer { scaleX = 1.1f; scaleY = 1.1f }
                .subsMask(),
        )
        Box(
            Modifier
                .matchParentSize()
                .subsMask()
                .background(
                    Brush.verticalGradient(0.36f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.5f))
                ),
        )
        Box(
            Modifier
                .fillMaxWidth()
                .height(130.dp)
                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.5f), Color.Transparent))),
        )
        Column(
            Modifier
                .align(Alignment.Center)
                .fillMaxWidth()
                .padding(horizontal = McMetrics.pagePadding),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                subscription.media.title,
                style = McType.display,
                color = Color.White,
                maxLines = 2,
                textAlign = TextAlign.Center,
                overflow = TextOverflow.Ellipsis,
            )
            if (arrival != null) {
                Spacer(Modifier.height(14.dp))
                Text(
                    "S%02dE%02d · %s".format(
                        arrival.seasonNumber,
                        arrival.episodeNumber,
                        formatMonthDay(arrival.expectedDay ?: arrival.airDate),
                    ),
                    style = McType.subSemibold,
                    color = Color.White.copy(alpha = 0.9f),
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    weekdayLabel(arrival.expectedDay ?: arrival.airDate),
                    style = McType.hero,
                    color = Color.White,
                )
            }
            Spacer(Modifier.height(20.dp))
            Row(
                Modifier
                    .height(44.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(Color.White.copy(alpha = 0.16f))
                    .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(999.dp))
                    .clickable(onClick = onOpen)
                    .padding(horizontal = 22.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("查看订阅", style = McType.subSemibold, color = Color.White)
            }
        }
    }
}

/**
 * 日程 —— 实测：标题 20/700 + 右侧「10月4日 · 1 部」13/36%；
 * 7 天日期条（45×68、圆角 15，未选白 5%，**选中整格反白**且标签转黑 55%、数字 19 加粗；
 * 有更新的那天数字下方一颗 4×4 黑点）；下面待办卡（圆角 22、白 4.5%）：
 * 「待定」20/400 36% +「● 预计入库」11/600 白 62% + 92×52 圆角 9 缩略图 +
 * 剧名 15/600 + 「S01E08」13/62%。
 */
@Composable
private fun ScheduleSection(
    arrivals: List<TodayArrival>,
    onOpen: (Long) -> Unit,
) {
    val today = LocalDate.now()
    val days = remember { (0..6).map { today.plusDays(it.toLong()) } }
    val arrivalByDay: Map<LocalDate, List<TodayArrival>> = remember(arrivals) {
        arrivals.groupBy { parseDay(it.expectedDay ?: it.airDate) ?: today }
    }
    var selected by remember(arrivals) {
        mutableStateOf(days.firstOrNull { arrivalByDay[it].orEmpty().isNotEmpty() } ?: today)
    }

    Spacer(Modifier.height(22.dp))
    SectionHeaderLarge(
        title = "日程",
        counter = buildString {
            val list = arrivalByDay[selected].orEmpty()
            append("%d月%d日".format(selected.monthValue, selected.dayOfMonth))
            append(" · ")
            append("${list.size} 部")
        },
    )
    Spacer(Modifier.height(12.dp))

    Row(
        Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        days.forEach { day ->
            val on = day == selected
            val has = arrivalByDay[day].orEmpty().isNotEmpty()
            Column(
                Modifier
                    .width(45.dp)
                    .height(68.dp)
                    .clip(RoundedCornerShape(15.dp))
                    .background(if (on) Color.White else Color.White.copy(alpha = 0.05f))
                    .clickable { selected = day },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    dayLabel(today, day),
                    style = McType.microSemibold,
                    color = if (on) Color.Black.copy(alpha = 0.55f) else TextMuted,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    day.dayOfMonth.toString(),
                    style = McType.caption.copy(
                        fontSize = 19.sp,
                        fontWeight = if (on) FontWeight.Bold else FontWeight.Medium,
                        color = if (on) Color.Black else TextPrimary,
                    ),
                )
                if (has && on) {
                    Spacer(Modifier.height(4.dp))
                    Box(Modifier.size(4.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.4f)))
                }
            }
        }
    }

    val todayArrivals = arrivalByDay[selected].orEmpty()
    if (todayArrivals.isNotEmpty()) {
        Spacer(Modifier.height(12.dp))
        val first = todayArrivals.first()
        val sub = remember(first.subscriptionId) { null }
        Column(
            Modifier
                .padding(horizontal = McMetrics.pagePadding)
                .fillMaxWidth()
                .clip(RoundedCornerShape(McMetrics.panelRadius))
                .background(Color.White.copy(alpha = 0.045f))
                .clickable { onOpen(first.subscriptionId) }
                .padding(4.dp),
        ) {
            Row(
                Modifier.fillMaxWidth().padding(10.dp, 10.dp, 12.dp, 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.width(62.dp)) {
                    Text(
                        if (first.status == "wanted") "待定" else "即将",
                        style = McType.title3.copy(fontWeight = FontWeight.Normal),
                        color = TextFaint,
                    )
                    Spacer(Modifier.height(5.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(5.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.62f)))
                        Spacer(Modifier.width(5.dp))
                        Text("预计入库", style = McType.microSemibold, color = Color.White.copy(alpha = 0.62f), maxLines = 1)
                    }
                }
                Spacer(Modifier.width(12.dp))
                Box(
                    Modifier
                        .width(92.dp)
                        .height(52.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Placeholder),
                ) {
                    RemoteImage(
                        url = null,
                        origin = null,
                        contentDescription = first.mediaTitle,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(first.mediaTitle, style = McType.subheadlineSemibold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.height(3.dp))
                    Text("S%02dE%02d".format(first.seasonNumber, first.episodeNumber), style = McType.caption, color = TextMuted)
                }
                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = TextFaint, modifier = Modifier.size(15.dp))
            }
        }
    }
}

/** 剧集订阅 / 电影订阅 一行（实测：20/700 + 「共 N 部」13/36%） */
@Composable
private fun SubscriptionRow(
    title: String,
    items: List<SubscriptionView>,
    origin: String?,
    onOpen: (Long) -> Unit,
) {
    SectionHeaderLarge(title = title, counter = "共 ${items.size} 部")
    Spacer(Modifier.height(16.dp))
    LazyRow(
        contentPadding = PaddingValues(horizontal = McMetrics.pagePadding),
        horizontalArrangement = Arrangement.spacedBy(McMetrics.rowSpacing),
    ) {
        items(items, key = { it.id }) { sub ->
            SubscriptionPosterCard(sub, origin) { onOpen(sub.id) }
        }
    }
}

/**
 * 订阅海报卡 —— 实测：126×189、**圆角 12**（比首页海报卡的 16 小）；
 * 左上角内距 7 一枚状态胶囊（高 19、圆角 999、黑 40% + blur 12、10.5/600）：
 * 「周日更新」白 90%（= 已排期）、「找资源中」琥珀 #f5c451（= 在找）；
 * 卡底 34 高渐变（transparent → 黑 55%）；卡下标题 13/600 + 副行 12/36%。
 */
@Composable
private fun SubscriptionPosterCard(
    sub: SubscriptionView,
    origin: String?,
    onClick: () -> Unit,
) {
    val searching = sub.status == "wanted" || sub.status == "searching"
    val pillText = if (searching) "找资源中" else "已入库"
    Column(Modifier.width(McMetrics.rowCardWidth).clickable(onClick = onClick)) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(McMetrics.posterAspect)
                .clip(RoundedCornerShape(McMetrics.tileRadius))
                .background(Placeholder),
        ) {
            RemoteImage(
                url = sub.media.posterUrl ?: sub.media.backdropUrl,
                origin = origin,
                contentDescription = sub.media.title,
                modifier = Modifier.fillMaxSize(),
            )
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .height(34.dp)
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.55f)))),
            )
            Row(
                Modifier
                    .align(Alignment.TopStart)
                    .padding(7.dp)
                    .height(19.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(Color.Black.copy(alpha = 0.4f))
                    .padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier
                        .size(5.dp)
                        .clip(CircleShape)
                        .background(if (searching) Warn else Color.White.copy(alpha = 0.62f)),
                )
                Spacer(Modifier.width(5.dp))
                Text(
                    pillText,
                    style = McType.pill,
                    color = if (searching) Warn else Color.White.copy(alpha = 0.9f),
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(sub.media.title, style = McType.captionSemibold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(1.dp))
        Text(
            subLine(sub),
            style = McType.caption.copy(fontSize = 12.sp),
            color = TextFaint,
            maxLines = 1,
        )
    }
}

private fun subLine(sub: SubscriptionView): String {
    val p = sub.progress
    return if (sub.media.kind == "tv") {
        val season = sub.selectedSeasons.firstOrNull()
        if (season != null) "第 $season 季 · ${p.imported} / ${p.total}" else "已入库 ${p.imported} / ${p.total}"
    } else {
        sub.media.year?.toString() ?: "已入库 ${p.imported}"
    }
}

/** 订阅空态（实测：玻璃卡 + 装饰图标簇 + 银白胶囊按钮） */
@Composable
private fun EmptySubscriptions(onDiscover: () -> Unit) {
    Column(
        Modifier
            .padding(horizontal = McMetrics.pagePadding)
            .fillMaxWidth()
            .clip(RoundedCornerShape(McMetrics.cardRadius))
            .background(GlassCard)
            .border(1.dp, LineSoft, RoundedCornerShape(McMetrics.cardRadius))
            .padding(horizontal = 22.dp, vertical = 30.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(38.dp).clip(RoundedCornerShape(11.dp)).background(Color.White.copy(alpha = 0.06f)))
            Box(
                Modifier.size(54.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Rounded.BookmarkBorder, contentDescription = null, tint = TextPrimary, modifier = Modifier.size(22.dp))
            }
            Box(Modifier.size(38.dp).clip(RoundedCornerShape(11.dp)).background(Color.White.copy(alpha = 0.06f)))
        }
        Spacer(Modifier.height(20.dp))
        Text("从一部想看的作品开始", style = McType.bodySemibold, color = TextPrimary)
        Spacer(Modifier.height(11.dp))
        Text(
            "去发现页挑选一部剧集或电影，打开详情并点击「订阅追踪」，有合适资源时会自动下载入库。",
            style = McType.sub,
            color = TextMuted,
            textAlign = TextAlign.Center,
            lineHeight = 25.sp,
        )
        Spacer(Modifier.height(20.dp))
        Button(
            onClick = onDiscover,
            shape = RoundedCornerShape(999.dp),
            colors = ButtonDefaults.buttonColors(containerColor = AccentStrong, contentColor = Color(0xFF141821)),
            modifier = Modifier.height(44.dp),
        ) { Text("去发现剧集", style = McType.subSemibold) }
    }
}

/** 与英雄区同一套遮罩（图与压暗渐变必须同遮罩，否则底边有断差） */
private fun Modifier.subsMask(): Modifier = this
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

private fun parseDay(raw: String?): LocalDate? = try {
    raw?.take(10)?.let { LocalDate.parse(it) }
} catch (_: Throwable) {
    null
}

private fun formatMonthDay(raw: String?): String {
    val d = parseDay(raw) ?: return "待定"
    return "%d月%d日".format(d.monthValue, d.dayOfMonth)
}

private fun weekdayLabel(raw: String?): String {
    val d = parseDay(raw) ?: return "待定"
    return chineseWeekday(d)
}

/** 今天/周四/周五…（实测日期条与英雄区都是这套中文星期） */
private fun dayLabel(today: LocalDate, day: LocalDate): String =
    if (day == today) "今天" else chineseWeekday(day)

private fun chineseWeekday(d: LocalDate): String =
    listOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")[d.dayOfWeek.value - 1]


@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun SubscribeScreen(
    onBack: () -> Unit,
    onCreated: () -> Unit,
    /** 管理态里「打开订阅详情」 */
    onOpenSubscription: (Long) -> Unit = {},
    /** 宿主模式：由 `SubscribeSheetHost` 指定作品（此时不依赖导航参数） */
    titleRefOverride: String? = null,
    /** 卡片上已有的信息：预检没回来之前先把头部画出来（不然是转圈，观感很慢） */
    seedTitle: String? = null,
    seedPosterUrl: String? = null,
    seedYear: Int? = null,
    seedKind: String? = null,
    vm: SubscribeViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val origin = vm.origin

    // 宿主模式：先让 VM 按外部 ref 重新预检（VM 是 hiltViewModel，进哪条导航都同一个实例）
    LaunchedEffect(titleRefOverride) {
        titleRefOverride?.let { vm.prepare(it) }
    }
    LaunchedEffect(state.created) { if (state.created) onCreated() }

    // 订阅入口在手机端是**底部表单弹层**（网页 `SheetScaffold`，注释写着"对齐 iOS SubscribeSheet"），
    // 不是整页。这里用 ModalBottomSheet 呈现，同时保留导航目标（各处的订阅入口都指向它）。
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onBack,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        // 抽屉最高 78% 屏高（HTML `max-height:78%` 同款）；头部常驻，主体自己滚——
        // 季数多的剧集（美国恐怖故事那种）不会再把下面整段挤出屏幕且滚不动
        val maxSheetHeight = (androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp * 0.78f).dp
        Column(Modifier.fillMaxWidth().heightIn(max = maxSheetHeight)) {
        when {
            state.loading -> Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                // 有种子就先画标题行，季节/规则等预检回来再补（观感上"点了就开"）
                if (seedTitle != null) {
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.width(56.dp).height(84.dp).clip(RoundedCornerShape(10.dp))) {
                            RemoteImage(seedPosterUrl, origin, contentDescription = seedTitle, modifier = Modifier.fillMaxSize())
                        }
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text(seedTitle, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(4.dp))
                            Text(
                                listOfNotNull(seedYear?.toString(), if (seedKind == "tv") "剧集" else "电影").joinToString(" · "),
                                fontSize = 11.5.sp,
                                color = TextFaint,
                            )
                        }
                    }
                    Spacer(Modifier.height(14.dp))
                }
                Box(Modifier.fillMaxWidth().height(if (seedTitle != null) 60.dp else 160.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted)
                }
            }
            state.error != null -> Text(
                state.error!!,
                fontSize = 12.5.sp,
                color = Danger,
                modifier = Modifier.padding(16.dp),
            )
            else -> state.preview?.let { preview ->
                var cancelOpen by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
                // 头部一行：左「✕ 取消」右「✓」（HTML 弹层的头部就是这两颗，确认键在右上）
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "关闭",
                        fontSize = 16.sp,
                        color = TextMuted,
                        modifier = Modifier.clip(RoundedCornerShape(999.dp)).clickable { onBack() }.padding(4.dp),
                    )
                    Spacer(Modifier.weight(1f))
                    if (state.existing == null) {
                        // 移动端网页实测：确认键就在头部右侧（文字「确认订阅」，不是底部整宽栏）
                        Text(
                            if (state.creating) "提交中…" else "确认订阅",
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                            color = if (state.creating) TextFaint else Accent,
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .clickable(enabled = !state.creating) { vm.create() }
                                .padding(horizontal = 8.dp, vertical = 6.dp),
                        )
                    }
                }
                var rulePicker by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
                var libraryPicker by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
                androidx.compose.foundation.layout.Column(
                    Modifier
                        .fillMaxWidth()
                        .weight(1f, fill = false)
                        .verticalScroll(androidx.compose.foundation.rememberScrollState()),
                ) {
                Column(Modifier.padding(horizontal = 16.dp)) {
                    Row {
                        Box(Modifier.width(84.dp).height(126.dp).clip(RoundedCornerShape(10.dp))) {
                            RemoteImage(
                                url = preview.media?.posterUrl,
                                origin = origin,
                                contentDescription = preview.media?.title,
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text(preview.media?.title ?: "未找到", fontSize = 16.sp, fontWeight = FontWeight.Bold)
                            Spacer(Modifier.height(4.dp))
                            Text(
                                listOfNotNull(
                                    preview.media?.year?.toString(),
                                    if (preview.media?.kind == "tv") "剧集" else "电影",
                                ).joinToString(" · "),
                                fontSize = 11.5.sp,
                                color = TextFaint,
                            )
                            Spacer(Modifier.height(8.dp))
                            when (preview.status) {
                                "not_found" -> Text("未在 TMDB/豆瓣找到该作品", fontSize = 12.sp, color = Warning)
                                "ambiguous" -> Text("身份不唯一,请在网页端确认后订阅", fontSize = 12.sp, color = Warning)
                                else -> {
                                    if (preview.movieOwned) {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Text("✓", fontSize = 12.sp, color = Success)
                                            Spacer(Modifier.width(4.dp))
                                            Text("媒体库已有，订阅后不会重复下载", fontSize = 13.sp, color = Success)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // —— 表单态（未订阅）：网页 `!existing_subscription_id` 才渲染这一段 ——
                    if (state.existing == null && preview.seasons.isNotEmpty()) {
                        Spacer(Modifier.height(18.dp))
                        Text("选择要收录的季", fontSize = 13.sp, color = TextFaint)
                        Spacer(Modifier.height(8.dp))
                        preview.seasons.sortedBy { it.seasonNumber }.forEach { season ->
                            val selected = season.seasonNumber in state.selectedSeasons
                            val aired = season.airedCount
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(if (selected) AccentSoft else Color.White.copy(alpha = 0.04f))
                                    .clickable { vm.toggleSeason(season.seasonNumber) }
                                    .padding(horizontal = 12.dp, vertical = 10.dp),
                            ) {
                                Box(
                                    Modifier
                                        .size(16.dp)
                                        .clip(RoundedCornerShape(4.dp))
                                        .background(if (selected) Accent else Color.Transparent),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (selected) Text("✓", fontSize = 10.sp, color = Color(0xFF0A0E12))
                                }
                                Spacer(Modifier.width(10.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        "第 ${season.seasonNumber} 季" + (season.name?.let { " · $it" } ?: ""),
                                        fontSize = 13.sp,
                                    )
                                    // 季行子文案（HTML 规范）：全 N 集已播完 / 已播 a/b 集 / 未播出
                                    val totalEpisodes = season.episodeCount ?: 0
                                    Text(
                                        when {
                                            aired <= 0 -> "未播出"
                                            totalEpisodes > 0 && aired >= totalEpisodes -> "全 $totalEpisodes 集已播完"
                                            totalEpisodes > 0 -> "已播 $aired/$totalEpisodes 集"
                                            else -> "已播 $aired 集"
                                        },
                                        fontSize = 10.5.sp,
                                        color = TextFaint,
                                    )
                                }
                                // 整季已在库（绿签）：已播的都入库了才给
                                if (aired > 0 && season.ownedCount >= aired) {
                                    Text(
                                        "整季已在库",
                                        fontSize = 10.sp,
                                        color = Success,
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(999.dp))
                                            .background(Success.copy(alpha = 0.12f))
                                            .padding(horizontal = 6.dp, vertical = 2.dp),
                                    )
                                }
                            }
                            Spacer(Modifier.height(6.dp))
                        }
                        Text("勾选即要整季（含未播出的集）", fontSize = 12.sp, color = TextFaint)
                    }

                    // 自动续订只对剧集有意义（网页：followFuture !== null 时才给这一项）
                    if (state.existing == null && preview.media?.kind == "tv") {
                    Spacer(Modifier.height(12.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(Color.White.copy(alpha = 0.04f))
                            .clickable { vm.setFollowFuture(!state.followFuture) }
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                    ) {
                        Box(
                            Modifier
                                .size(16.dp)
                                .clip(RoundedCornerShape(4.dp))
                                .background(if (state.followFuture) Accent else Color.Transparent),
                            contentAlignment = Alignment.Center,
                        ) {
                            if (state.followFuture) Text("✓", fontSize = 10.sp, color = Color(0xFF0A0E12))
                        }
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) {
                            Text("自动续订", fontSize = 15.sp)
                            Text("之后播出的新集、新一季自动加入追踪", fontSize = 12.sp, color = TextMuted)
                        }
                        androidx.compose.material3.Switch(
                            checked = state.followFuture,
                            onCheckedChange = { vm.setFollowFuture(it) },
                            colors = androidx.compose.material3.SwitchDefaults.colors(
                                checkedThumbColor = Color.White,
                                checkedTrackColor = Accent,
                            ),
                        )
                    }
                    }
                    // ↑ 这个 } 是「自动续订（只给剧集）」那个 if 的收尾。**它以前漏了**，
                    // 于是「资源规则 / 入库到 / 投递预检」被吞进"只给剧集"的分支里——
                    // 电影打开抽屉就只剩海报和说明（用户报的现象）。

                    // 规则组 / 入库目标库：与网页弹层同一组选项（都是创建订阅的一部分）
                    if (state.existing == null && state.ruleSets.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        val picked = state.ruleSets.firstOrNull { it.id == state.ruleSetId }
                            ?: state.ruleSets.firstOrNull { it.isDefault }
                        SheetChoiceRow(
                            label = "资源规则",
                            // 网页实测：这一行下面是**规格摘要**（`specSummary(spec)` 的芯片用 · 连接），
                            // 不是我拼的文案；空 spec 就只显示组名
                            value = picked?.let { rs ->
                                val chips = specSummary(parseRuleSetSpec(rs.spec))
                                listOf(rs.name + if (rs.isDefault) "（默认）" else "") + chips
                            }?.joinToString(" · ") ?: "默认",
                            onClick = { rulePicker = true },
                        )
                    }
                    if (state.existing == null && state.libraries.isNotEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        SheetChoiceRow(
                            label = "入库到",
                            value = state.routing?.libraryName
                                ?: state.libraries.firstOrNull { it.id == state.libraryId }?.name
                                ?: "默认库",
                            onClick = { libraryPicker = true },
                        )
                    }
                    // 投递路由预检（管理员）：移动端网页实测就是这两行——
                    // 「自动选库：<理由>」与不 ok 时的中文指引（例如没有可用下载器）
                    state.routing?.let { routing ->
                        routing.routeReason?.takeIf { it.isNotBlank() }?.let { reason ->
                            Spacer(Modifier.height(6.dp))
                            Text(
                                "自动选库：$reason",
                                fontSize = 12.sp,
                                color = Accent,
                            )
                        }
                        if (!routing.ok && !routing.warning.isNullOrBlank()) {
                            Spacer(Modifier.height(6.dp))
                            Text(
                                routing.warning,
                                fontSize = 12.sp,
                                color = Warning,
                            )
                        }
                    }
                    if (rulePicker) {
                        PickerSheet(
                            title = "资源规则",
                            options = buildList<Pair<String, Long?>> {
                                add("默认" to null)
                                state.ruleSets.forEach { add((it.name + if (it.isDefault) "（默认组）" else "") to it.id) }
                            },
                            current = state.ruleSetId,
                            onPick = { vm.setRuleSet(it); rulePicker = false },
                            onDismiss = { rulePicker = false },
                        )
                    }
                    if (libraryPicker) {
                        PickerSheet(
                            title = "入库到",
                            options = buildList<Pair<String, Long?>> {
                                add("默认库" to null)
                                state.libraries.forEach { add(it.name to it.id) }
                            },
                            current = state.libraryId,
                            onPick = { vm.setLibrary(it); libraryPicker = false },
                            onDismiss = { libraryPicker = false },
                        )
                    }

                    Spacer(Modifier.height(20.dp))
                    val existing = state.existing
                    if (existing != null) {
                        // 管理态：**严格照网页 `subscribe-dialog.tsx` 的「已订阅：管理态」**——
                        // 只有一句说明 + 两颗按钮。表单（选季/自动续订/资源规则/入库到）与
                        // 表单底栏都只在未订阅时出现；「打开订阅详情」是网页没有的，已去掉。
                        Column {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("✓", fontSize = 14.sp, color = Success)
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    "该片已在订阅中，movieclaw 正在持续追踪资源。",
                                    fontSize = 14.sp,
                                    color = TextPrimary.copy(alpha = 0.85f),
                                )
                            }
                            Spacer(Modifier.height(16.dp))
                            Row(
                                Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.End,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                TextButton(onClick = { onOpenSubscription(existing.id) }) {
                                    Text("查看订阅详情", fontSize = 14.sp, color = Accent, fontWeight = FontWeight.Bold)
                                }
                                Spacer(Modifier.width(10.dp))
                                Box(
                                    Modifier
                                        .clip(RoundedCornerShape(999.dp))
                                        .background(Danger.copy(alpha = 0.12f))
                                        .clickable { cancelOpen = true }
                                        .padding(horizontal = 16.dp, vertical = 8.dp),
                                ) {
                                    Text("取消订阅", fontSize = 14.sp, color = Danger)
                                }
                            }
                        }
                        if (cancelOpen) {
                            androidx.compose.material3.AlertDialog(
                                onDismissRequest = { cancelOpen = false },
                                title = { Text("取消订阅？", color = TextPrimary) },
                                text = {
                                    Text(
                                        "将停止为《${preview.media?.title.orEmpty()}》寻找与追更资源；已入库的文件不受影响。",
                                        color = TextMuted,
                                    )
                                },
                                confirmButton = {
                                    TextButton(onClick = { cancelOpen = false; vm.cancelExisting(onDone = onBack) }) {
                                        Text("取消订阅", color = Danger)
                                    }
                                },
                                dismissButton = {
                                    TextButton(onClick = { cancelOpen = false }) { Text("再想想", color = TextMuted) }
                                },
                                containerColor = Color(0xFF15161A),
                            )
                        }
                    } else {
                        Text(
                            "下载完成后自动整理入库。",
                            fontSize = 12.sp,
                            color = TextFaint,
                            modifier = Modifier.padding(vertical = 4.dp),
                        )
                        // 确认键在头部（移动端网页同款），底部只留这句说明
                    }
                }
                }
            }
        }
        }
    }
}

/** 弹层里的一行"选择项"：标签 + 当前值 + 右侧箭头 */
@Composable
private fun SheetChoiceRow(label: String, value: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 13.sp, color = TextMuted)
        Spacer(Modifier.weight(1f))
        Text(value, fontSize = 13.sp, color = TextPrimary, maxLines = 1)
        Spacer(Modifier.width(6.dp))
        Icon(
            Icons.Rounded.KeyboardArrowRight,
            contentDescription = null,
            tint = TextFaint,
            modifier = Modifier.size(16.dp),
        )
    }
}

/** 通用单选抽屉（规则组 / 目标库共用）：选中的打勾 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun PickerSheet(
    title: String,
    options: List<Pair<String, Long?>>,
    current: Long?,
    onPick: (Long?) -> Unit,
    onDismiss: () -> Unit,
) {
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(bottom = 20.dp)) {
            Text(
                title,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 20.dp, bottom = 6.dp),
            )
            options.forEach { (label, id) ->
                Row(
                    Modifier.fillMaxWidth().clickable { onPick(id) }.padding(horizontal = 20.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.width(22.dp)) {
                        Icon(
                            Icons.Rounded.Check,
                            contentDescription = null,
                            tint = TextPrimary,
                            modifier = Modifier.size(16.dp).alpha(if (id == current) 1f else 0f),
                        )
                    }
                    Text(label, fontSize = 14.sp)
                }
            }
        }
    }
}
