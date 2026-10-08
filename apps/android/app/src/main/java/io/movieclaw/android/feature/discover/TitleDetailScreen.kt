package io.movieclaw.android.feature.discover

import io.movieclaw.android.core.model.MediaImage
import io.movieclaw.android.core.designsystem.Lightbox
import androidx.compose.ui.text.TextStyle
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import io.movieclaw.android.core.designsystem.Warn
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.statusLabel
import io.movieclaw.android.core.designsystem.statusColor
import io.movieclaw.android.core.model.SubscriptionView
import io.movieclaw.android.core.model.TitlePreviewRequest
import io.movieclaw.android.core.designsystem.McNavButton
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.NotificationsNone
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Search
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.PosterCard
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.CollectionTitles
import io.movieclaw.android.core.model.DiscoveredTitle
import io.movieclaw.android.core.model.TitleDetails
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

@HiltViewModel
class TitleDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
) : ViewModel() {

    // 路由是 title?ref={ref} —— 之前读的是 "titleRef"，取到空串，
    // 请求会打到 /discover/titles/（列表路由）并 422。两个 key 都兜住。
    val titleRef: String = (savedStateHandle.get<String>("ref")
        ?: savedStateHandle.get<String>("titleRef")).orEmpty()

    private val _state = MutableStateFlow<Loadable<TitleDetails>>(Loadable.Loading)
    val state = _state.asStateFlow()

    val origin: String? get() = sessionRepository.ui.value.origin

    /**
     * 这部作品**是否已订阅**（以及状态）。
     *
     * 以前按钮是拿"是否已入库"当"是否已订阅"用的（`libraryLinks`），于是库里已有的片会显示
     * 「已订阅」，真正订阅了但还没入库的反而显示「订阅」，点了也没反应——用户报的
     * "订阅按钮 UI 不对"就是这个。iOS 用的是订阅本体（`sub != nil` + `SubscriptionStatusMeta`）。
     */
    private val _sub = MutableStateFlow<SubscriptionView?>(null)
    val sub = _sub.asStateFlow()

    fun loadSubscription() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            val preview = runCatching {
                api.titlePreview(TitlePreviewRequest(titleRef)).dataOrThrow()
            }.getOrNull() ?: return@launch
            val id = preview.existingSubscriptionId ?: return@launch
            runCatching { api.subscription(id).dataOrThrow() }.onSuccess { _sub.value = it }
        }
    }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _state.value = Loadable.Loading
            runCatching { apiFactory.forOrigin(origin).titleDetails(titleRef).dataOrThrow() }
                .onSuccess { _state.value = Loadable.Ready(it) }
                .onFailure { e -> _state.value = Loadable.Failed(friendlyMessage(e)) }
        }
        loadSubscription()
    }

    init {
        load()
    }
}

/** 标题详情(发现页身份):资料 + 演职员 + 相关推荐 + 订阅/播放入口 */
@Composable
fun TitleDetailScreen(
    titleRef: String,
    onBack: () -> Unit,
    onOpenTitle: (String) -> Unit,
    onSubscribe: (String) -> Unit,
    onOpenItem: (Long, Long) -> Unit,
    onPlay: (PlayTarget) -> Unit,
    /** 「搜索资源」：带片名与影片类型进搜索页（kind 供按类型收窄，v0.32 iOS / Web 同款） */
    onSearch: (String, String?) -> Unit = { _, _ -> },
    /** 演职员点进「TMDB 影人页」（iOS `MediaDetailView` 的 `.discoveredPerson`；与库内影人页是两个页面） */
    onOpenPerson: (Int) -> Unit = {},
    vm: TitleDetailViewModel = hiltViewModel(),
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val sub by vm.sub.collectAsStateWithLifecycle()
    val origin = vm.origin
    val permissions = io.movieclaw.android.core.session.LocalPermissions.current
    var lightbox by remember { mutableStateOf<Pair<List<MediaImage>, Int>?>(null) }

    when (val s = state) {
        Loadable.Loading -> Box(Modifier.fillMaxSize().background(Bg), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = TextMuted)
        }
        is Loadable.Failed -> ErrorPane(message = s.message, onRetry = vm::load)
        is Loadable.Ready -> {
            val details = s.value
            val title = details.title
            // 页面底色 = 剧照底边色带（网页 .detail-ambient / iOS HeroEdgeColor）
            val rawTint = io.movieclaw.android.core.discovery.rememberAmbientColor(
                details.backdropOriginalUrl ?: title.backdropUrl ?: title.posterUrl,
                origin,
                // 与首页英雄同源（同一张剧照 → 同一个缓存键）：从英雄点进来时零等待；
                // 底色本身仍是「图的主色」，配合淡入不会有跳变
                bottomBand = false,
            )
            // 取色是异步的：底色淡入而不是从黑跳变（iOS heroEdgeBackground 也是 0.5s 渐显）
            val detailTint by androidx.compose.animation.animateColorAsState(
                targetValue = rawTint ?: Bg,
                animationSpec = androidx.compose.animation.core.tween(420),
                label = "detail-tint",
            )
            val link = details.libraryLinks.firstOrNull()
            Column(
                Modifier
                    .fillMaxSize()
                    .background(detailTint)
                    .verticalScroll(rememberScrollState()),
            ) {
                val gallery = details.backdrops + details.posters
                val screenH = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.dp
                // 与首页英雄同高（iOS DiscoverHero.height = 520；网页首页英雄图高 572）。
                // 详情页封面之前按网页的 449 做，明显比首页矮一截 —— 统一到 520
                val heroH = 520.dp
                // 网页：剧照层 449、内容块从 299 起 → 让 hero 的**布局高度**只占 299，
                // 图仍按 449 绘制并允许溢出（不裁），这样标题压在图上、后面内容不再留 150 空档
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(heroH - 150.dp)
                        .then(
                            if (gallery.isNotEmpty()) {
                                Modifier.clickable { lightbox = gallery to 0 }
                            } else {
                                Modifier
                            }
                        )
                ) {
                    // 剧照 + 底部渐隐放**同一个 heroH 高的图层**里（网页 .detail-hero-fade 从 189 起、
                    // 到剧照底边淡成页面色）。之前渐隐挂在「布局高 heroH-150」的框上，
                    // 底边落在 297，剧照画到 447 → 447 处硬切（和首页英雄那次同一种错）。
                    // 封面高度 = heroH（网页实测 449 / 视口 844 = 53%），
                    // 渐隐 189→449（0.42 → 1.0）；外层布局高度 heroH-150 让内容从 299 起
                    Box(Modifier.fillMaxWidth().height(heroH).align(Alignment.TopCenter)) {
                        RemoteImage(
                            url = details.backdropOriginalUrl ?: title.backdropUrl ?: title.posterUrl,
                            origin = origin,
                            contentDescription = title.title,
                            modifier = Modifier.fillMaxSize(),
                        )
                        Box(
                            Modifier
                                .fillMaxSize()
                                .background(
                                    Brush.verticalGradient(
                                        // 从 62% 才开始淡：标题→上映日期→按钮都还压在图上，
                                        // 之后才溶进页面底色（之前 42% 就淡，文字后面已经看不到图）
                                        0.62f to Color.Transparent,
                                        1f to detailTint,
                                    )
                                ),
                        )
                    }
                    // 顶部压暗：iOS 是 black@0.45 高 112；这里再加一层更陡的顶部暗带，
                    // 保证浅色剧照上「返回/搜索」圆钮与状态栏也清楚
                    Box(
                        Modifier.fillMaxWidth().height(200.dp).align(Alignment.TopCenter)
                            .background(
                                Brush.verticalGradient(
                                    0f to Color.Black.copy(alpha = 0.62f),
                                    0.35f to Color.Black.copy(alpha = 0.30f),
                                    1f to Color.Transparent,
                                )
                            ),
                    )

                    // 顶栏：只有返回（网页/iOS 的标题详情都没有顶栏搜索键——「搜索资源」在操作行）
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .statusBarsPadding()
                            .padding(horizontal = McMetrics.pagePadding, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        McNavButton(icon = Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回", onClick = onBack)
                    }
                }

                // 标题区：iOS 用 -150 上移压在剧照上
                Column(Modifier.padding(horizontal = McMetrics.pagePadding)) {
                    Text(
                        title.title,
                        fontSize = 27.sp, fontWeight = FontWeight.Bold, lineHeight = 33.sp,
                        color = Color.White, maxLines = 3, overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(8.dp))
                    // 事实行：★ 20/700 + 年份 · 片长（iOS MetaRow）
                    Row(verticalAlignment = Alignment.Bottom) {
                        title.providerRating.takeIf { it > 0f }?.let { r ->
                            Icon(Icons.Rounded.Star, contentDescription = null, tint = Warn, modifier = Modifier.size(15.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("%.1f".format(r), fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.8f))
                            Spacer(Modifier.width(8.dp))
                        }
                        Text(
                            listOfNotNull(
                                title.releaseYear?.toString(),
                                // 网页：电影给「128 分钟」、剧集给「1 季」（extentLabel 就是它）
                                if (title.mediaType == "tv") {
                                    title.extentLabel.takeIf { it.isNotBlank() }
                                } else {
                                    details.metadata.runtimeMinutes?.let { "${it} 分钟" }
                                },
                            ).joinToString(" · "),
                            fontSize = 15.sp, color = Color.White.copy(alpha = 0.8f),
                            modifier = Modifier.padding(bottom = 2.dp),
                        )
                    }
                    // 国家 · 语言 ｜ 类型
                    val countryLang = listOfNotNull(
                        details.metadata.country.takeIf { it.isNotBlank() },
                        details.metadata.language.takeIf { it.isNotBlank() },
                    ).joinToString(" · ")
                    val genreList = details.metadata.genres.ifEmpty { title.genres }
                    if (countryLang.isNotBlank() || genreList.isNotEmpty()) {
                        Spacer(Modifier.height(6.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (countryLang.isNotBlank()) {
                                Text(countryLang, fontSize = 15.sp, color = Color.White.copy(alpha = 0.65f))
                                Text("  |  ", fontSize = 15.sp, color = Color.White.copy(alpha = 0.25f))
                            }
                            Text(
                                genreList.joinToString(" · "),
                                fontSize = 15.sp, color = Color.White.copy(alpha = 0.72f),
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    // 上映 / 首播日期
                    details.metadata.released.takeIf { it.isNotBlank() }?.let { d ->
                        Spacer(Modifier.height(4.dp))
                        Text(
                            (if (title.mediaType == "tv") "首播日期 · " else "上映日期 · ") + d,
                            fontSize = 15.sp, color = Color.White.copy(alpha = 0.55f),
                        )
                    }
                    // 在库条（iOS：绿底绿框 + folder 图标 + 库名下划线链接）
                    if (link != null && link.mediaItemId > 0) {
                        Spacer(Modifier.height(12.dp))
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(Color(0x144ADE80))
                                .border(1.dp, Color(0x334ADE80), RoundedCornerShape(10.dp))
                                .clickable { onOpenItem(link.libraryId, link.mediaItemId) }
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Rounded.Folder, contentDescription = null, tint = Color(0xFF99F2CC), modifier = Modifier.size(15.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("在库", fontSize = 14.sp, color = Color(0xFF99F2CC))
                            Spacer(Modifier.width(6.dp))
                            Text(
                                link.libraryName,
                                fontSize = 14.sp, color = Color(0xFFD9FFF0),
                                textDecoration = androidx.compose.ui.text.style.TextDecoration.Underline,
                            )
                        }
                    }
                    // 操作行（iOS DiscoverFlowLayout：订阅追踪 / 已订阅 · 状态 / 搜索资源）
                    // 在库收起规则（网页/iOS 同一条，2026-10-02 定版）：电影入库即完成——再摆
                    // 「订阅 / 搜索资源」等于邀请用户重下一遍已有的片子，隐藏后由上方「在库」
                    // 信息条接手；**剧集不适用**（在库≠收齐，缺集与未来新季仍要追更/手动找资源，
                    // 两颗照常显示）。已订阅的在库电影保留状态键：它是管理/取消订阅入口。
                    // 「搜索资源」另看**资源搜索**权限（member-permissions-v2：条目详情同口径）——
                    // 成员没这个开关时这里不摆按钮，免得点了被后端拒。
                    val ownedMovie = title.mediaType == "movie" && details.libraryLinks.isNotEmpty()
                    val subscription = sub
                    val showSubscribe = subscription != null || !ownedMovie
                    val showSearch = !ownedMovie && permissions.canSearch
                    if (showSubscribe || showSearch) {
                        Spacer(Modifier.height(12.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (showSubscribe) {
                                if (subscription == null) {
                                    // 未订阅：按作品类型说"订阅影片 / 订阅剧集"（用户要的口径），强调样式
                                    val label = if (title.mediaType == "tv") "订阅剧集" else "订阅影片"
                                    ActionPill(label, Icons.Rounded.NotificationsNone, filled = true) {
                                        onSubscribe(title.titleRef)
                                    }
                                } else {
                                    // 已订阅：中性玻璃 + 对勾（颜色随状态），点它**同样打开订阅弹层**——
                                    // 弹层看到已有订阅会进管理态（iOS 同款行为）。以前这里 onClick 是空的。
                                    ActionPill(
                                        label = "已订阅 · ${subscription.statusLabel()}",
                                        icon = Icons.Rounded.Check,
                                        filled = false,
                                        tint = subscription.statusColor(),
                                    ) { onSubscribe(title.titleRef) }
                                }
                            }
                            if (showSearch) {
                                ActionPill("搜索资源", Icons.Rounded.Search, filled = false) { onSearch(title.title, title.mediaType) }
                            }
                        }
                    }
                }

                // 旧版的操作行（播放/订阅 + TMDB 灰字）已删除：网页版是「订阅追踪 / 搜索资源」两颗，
                // 它们在新标题区里（见上方 ActionPill 行）

                // 简介：正文在 title.overview（metadata 无 plot 字段）；网页是 4 行截断 + 「展开全文」
                val plot = details.metadata.plot?.takeIf { it.isNotBlank() } ?: details.title.overview
                if (!plot.isNullOrBlank()) {
                    var plotOpen by remember { mutableStateOf(false) }
                    Column(Modifier.padding(start = McMetrics.pagePadding, end = McMetrics.pagePadding, top = 16.dp)) {
                        Text(
                            plot,
                            fontSize = 15.sp,
                            color = Color.White.copy(alpha = 0.78f),
                            lineHeight = 24.sp,
                            maxLines = if (plotOpen) Int.MAX_VALUE else 4,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            if (plotOpen) "收起" else "展开全文 ⌄",
                            fontSize = 14.sp, color = Color.White.copy(alpha = 0.62f),
                            modifier = Modifier.padding(top = 6.dp).clickable { plotOpen = !plotOpen },
                        )
                    }
                }

                // 类型已在「国家 · 语言 ｜ 类型」行里，不再单列一行标签

                if (details.metadata.cast.isNotEmpty()) {
                    Text("演职员", style = McType.title3, color = TextPrimary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        // iOS 不截断（全量）；有 TMDB 影人 id 的可点进 TMDB 影人页
                        items(details.metadata.cast) { member ->
                            Column(
                                Modifier
                                    .width(104.dp)
                                    .clickable(enabled = member.tmdbPersonId != null) {
                                        member.tmdbPersonId?.let(onOpenPerson)
                                    },
                                horizontalAlignment = Alignment.Start,
                            ) {
                                Box(Modifier.width(104.dp).height(156.dp).clip(RoundedCornerShape(12.dp))) {
                                    RemoteImage(
                                        url = member.avatarUrl,
                                        origin = origin,
                                        contentDescription = member.name,
                                        modifier = Modifier.fillMaxSize(),
                                    )
                                }
                                Spacer(Modifier.height(6.dp))
                                // 网页：名字 15sp/600 主色；角色 13sp faint（之前名字漏传 color → 黑底黑字看不见）
                                Text(
                                    member.name,
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = TextPrimary,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    // 网页写「饰 角色」；有 character 用 character，否则用 role
                                    (member.character ?: member.role)?.let { "饰 $it" } ?: "演员",
                                    fontSize = 13.sp,
                                    color = TextMuted,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.padding(top = 2.dp),
                                )
                            }
                        }
                    }
                }

                // 剧照与海报 —— 网页实测：标题行（17/600 标题 + 两个 74×29 圆角 chip）
                // 独立一行，下面**一条横滑**按页签切换：剧照 185×104、海报 84×126、间距 12
                if (details.backdrops.isNotEmpty() || details.posters.isNotEmpty()) {
                    var showStills by remember { mutableStateOf(true) }
                    Row(
                        Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("剧照与海报", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
                        Spacer(Modifier.weight(1f))
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            listOf("剧照 ${details.backdrops.size}" to true, "海报 ${details.posters.size}" to false).forEach { (label, isStills) ->
                                val on = showStills == isStills
                                Text(
                                    label,
                                    fontSize = 13.sp,
                                    fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                                    color = if (on) TextPrimary else TextMuted,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(999.dp))
                                        .background(Color.White.copy(alpha = if (on) 0.16f else 0.06f))
                                        .clickable { showStills = isStills }
                                        .padding(horizontal = 12.dp, vertical = 5.dp),
                                )
                            }
                        }
                    }
                    val pics = if (showStills) details.backdrops else details.posters
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        items(pics.take(20)) { image ->
                            Box(
                                Modifier
                                    .then(if (showStills) Modifier.width(185.dp).aspectRatio(16f / 9f) else Modifier.width(84.dp).aspectRatio(2f / 3f))
                                    .clip(RoundedCornerShape(10.dp))
                                    .clickable { lightbox = pics to pics.indexOf(image) },
                            ) {
                                RemoteImage(url = image.previewUrl, origin = origin, contentDescription = null, modifier = Modifier.fillMaxSize())
                            }
                        }
                    }
                }

                if (details.recommendations.isNotEmpty()) {
                    Text("相似推荐", style = McType.title3, color = TextPrimary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        items(details.recommendations.distinctBy { it.titleRef }, key = { it.titleRef }) { item ->
                            PosterCard(
                                imageUrl = item.posterUrl,
                                origin = origin,
                                title = item.title,
                                modifier = Modifier.width(104.dp),
                                onClick = { onOpenTitle(item.titleRef) },
                            )
                        }
                    }
                }


                // 相关链接：网页是「标签 + 可点外链」，没有卡片底。
                // 链接按 provider 拼：TMDB → themoviedb.org/movie|tv/{id}；豆瓣 → movie.douban.com/subject/{id}/
                val ctx = androidx.compose.ui.platform.LocalContext.current
                fun openUrl(url: String) {
                    runCatching {
                        ctx.startActivity(
                            android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
                }
                val links = buildList {
                    if (title.externalId.isNotBlank()) {
                        when (title.provider.lowercase()) {
                            "tmdb" -> add(
                                "TMDB ↗" to "https://www.themoviedb.org/" +
                                    (if (title.mediaType == "tv") "tv/" else "movie/") + title.externalId
                            )
                            "douban" -> add("豆瓣 ↗" to "https://movie.douban.com/subject/${title.externalId}/")
                        }
                    }
                }
                Row(
                    Modifier.padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("相关链接", color = TextFaint, fontSize = 13.sp)
                    Spacer(Modifier.width(12.dp))
                    links.forEach { (label, url) ->
                        Text(
                            label,
                            fontSize = 13.sp,
                            color = TextMuted,
                            modifier = Modifier.padding(end = 16.dp).clickable { openUrl(url) },
                        )
                    }
                    details.metadata.network?.let {
                        Text("$it ↗", fontSize = 13.sp, color = TextMuted)
                    }
                }
                Spacer(Modifier.height(24.dp))
            }

            lightbox?.let { (images, index) ->
                Lightbox(
                    images = images,
                    title = title.title,
                    initialIndex = index,
                    onDismiss = { lightbox = null },
                )
            }
        }
    }
}

/* ---------------- 合集完整列表 ---------------- */

@HiltViewModel
class CollectionViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
) : ViewModel() {

    // 路由是 collection?ref={ref}&title={title} —— 两个 key 都兜（同 title 页的坑）
    val collectionRef: String = (savedStateHandle.get<String>("ref")
        ?: savedStateHandle.get<String>("collectionRef")).orEmpty()

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val info: io.movieclaw.android.core.model.DiscoveryCollectionInfo = io.movieclaw.android.core.model.DiscoveryCollectionInfo(),
        val titles: List<DiscoveredTitle> = emptyList(),
        val loadingMore: Boolean = false,
        val hasMore: Boolean = false,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    private var page = 1

    /** 重查代号：重试/换合集后作废在飞的翻页响应（旧页混进新列表 → 重复 ref → 网格崩，实机抓到过） */
    private var generation = 0
    val origin: String? get() = sessionRepository.ui.value.origin

    init {
        load()
    }

    fun load() {
        val gen = ++generation
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            page = 1
            runCatching {
                apiFactory.forOrigin(origin).collectionTitles(collectionRef, limit = 30, page = 1).dataOrThrow()
            }
                .onSuccess { result: CollectionTitles ->
                    if (gen != generation) return@onSuccess
                    _ui.update {
                        it.copy(
                            loading = false,
                            info = result.collection,
                            // 按 titleRef 去重：网格用它当 key，重复一条就会崩
                            titles = result.titles.distinctBy { t -> t.titleRef },
                            hasMore = result.hasMore,
                        )
                    }
                }
                .onFailure { e ->
                    if (gen != generation) return@onFailure
                    _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
                }
        }
    }

    fun loadMore() {
        val state = _ui.value
        if (state.loadingMore || !state.hasMore) return
        val gen = generation
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loadingMore = true) }
            runCatching {
                apiFactory.forOrigin(origin).collectionTitles(collectionRef, limit = 30, page = page + 1).dataOrThrow()
            }
                .onSuccess { result ->
                    // 重查发生后这一页作废（与发现页 loadMoreFiltered 同一道守卫）
                    if (gen != generation) return@onSuccess
                    page += 1
                    _ui.update {
                        it.copy(
                            loadingMore = false,
                            titles = (it.titles + result.titles).distinctBy { t -> t.titleRef },
                            hasMore = result.hasMore,
                        )
                    }
                }
                .onFailure {
                    if (gen != generation) return@onFailure
                    _ui.update { it.copy(loadingMore = false) }
                }
        }
    }
}

@Composable
fun CollectionScreen(
    title: String,
    onBack: () -> Unit,
    onOpenTitle: (String) -> Unit,
    vm: CollectionViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val origin = vm.origin

    var query by remember { mutableStateOf("") }
    var genre by remember { mutableStateOf<String?>(null) }

    Column(Modifier.fillMaxSize().background(Bg)) {
        // 顶栏：返回（网页是左上玻璃圆钮，这里保持紧凑顶栏）
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.statusBarsPadding().padding(horizontal = 4.dp)) {
            McNavButton(
                icon = Icons.AutoMirrored.Rounded.ArrowBack,
                contentDescription = "返回",
                onClick = onBack,
            )
            Spacer(Modifier.weight(1f))
        }
        // 卡片上方那一整块，按网页补齐：eyebrow → 大标题 → 已加载计数 → 搜索框 → 类型 chips
        Column(Modifier.padding(horizontal = 16.dp)) {
            Text(
                if (state.info.name.isNotEmpty() && !title.isNullOrEmpty() && state.info.name != title) "TMDB COLLECTION" else "TMDB COLLECTION",
                fontSize = 13.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp, color = Color(0xFF9FB0C9),
            )
            Text(
                state.info.name.ifEmpty { title },
                fontSize = 28.sp, fontWeight = FontWeight.Bold, color = TextPrimary,
                modifier = Modifier.padding(top = 6.dp),
            )
            Text(
                // 网页文案：已加载 20 / 46 部影片（总数服务端未给时只报已加载数）
                "已加载 ${state.titles.size} 部影片" + if (state.hasMore) " · 还有更多" else "",
                fontSize = 15.sp, color = TextMuted, modifier = Modifier.padding(top = 6.dp),
            )
            // 搜索已加载片名（本地过滤，网页 .searchable 同语义）
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(Color.White.copy(alpha = 0.06f))
                    .padding(horizontal = 10.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Rounded.Search, contentDescription = null, tint = TextFaint, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                androidx.compose.foundation.text.BasicTextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(color = TextPrimary, fontSize = 15.sp),
                    modifier = Modifier.weight(1f),
                    decorationBox = { inner ->
                        if (query.isEmpty()) Text("搜索已加载片名", fontSize = 15.sp, color = Color.White.copy(alpha = 0.3f))
                        inner()
                    },
                )
            }
            // 类型 chips（网页：已加载类型 + 全部 / 剧情 9 / 动作 7 …，点选本地过滤）
            val genreCounts = state.titles.flatMap { it.genres }.groupingBy { it }.eachCount().entries.sortedByDescending { it.value }
            if (genreCounts.isNotEmpty()) {
                Text("已加载类型", fontSize = 13.sp, color = TextFaint, modifier = Modifier.padding(top = 12.dp, bottom = 6.dp))
                androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item {
                        GenreChip("全部", on = genre == null) { genre = null }
                    }
                    items(genreCounts) { (g, n) ->
                        GenreChip("$g $n", on = genre == g) { genre = if (genre == g) null else g }
                    }
                }
            }
            Spacer(Modifier.height(10.dp))
        }
        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::load)
            else -> {
                val gridState = androidx.compose.foundation.lazy.grid.rememberLazyGridState()
                LaunchedEffect(gridState) {
                    androidx.compose.runtime.snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
                        .collect { last ->
                            val total = gridState.layoutInfo.totalItemsCount
                            if (total > 0 && last >= total - 6) vm.loadMore()
                        }
                }
                // 网页实测（390 视口）：**2 列、卡宽 166（图 2:3 高 249）、横向间距 16**；
                // 卡片下是「标题 / 年份」两行（不是「片名 (年份)」拼一行）
                LazyVerticalGrid(
                    state = gridState,
                    // 列数保持 3 列（用户要求）；间距按网页实测：横向 16、纵向 24、内距 16
                    columns = GridCells.Fixed(3),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(24.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    val shown = state.titles.filter {
                        (genre == null || it.genres.contains(genre)) &&
                            (query.isBlank() || it.title.contains(query, ignoreCase = true))
                    }
                    items(
                        shown.distinctBy { it.titleRef.ifEmpty { it.title } },
                        key = { it.titleRef.ifEmpty { it.title } },
                    ) { item ->
                        PosterCard(
                            imageUrl = item.posterUrl,
                            origin = origin,
                            title = item.title,
                            meta = item.releaseYear?.toString(),
                            modifier = Modifier.fillMaxWidth(),
                            onClick = { onOpenTitle(item.titleRef) },
                        )
                    }
                    if (state.loadingMore) {
                        item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(3) }) {
                            Box(Modifier.fillMaxWidth().padding(12.dp), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(20.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ActionPill(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    filled: Boolean,
    /** 图标颜色（已订阅的勾按状态着色）；null = 跟随文字色 */
    tint: androidx.compose.ui.graphics.Color? = null,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .height(34.dp)
            .clip(RoundedCornerShape(999.dp))
            .then(
                if (filled) {
                    Modifier.background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))))
                } else {
                    Modifier
                        .background(Color.White.copy(alpha = 0.14f))
                        .border(1.dp, LineSoft, RoundedCornerShape(999.dp))
                }
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = tint ?: if (filled) Color(0xFF141821) else Color.White,
            modifier = Modifier.size(15.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = if (filled) Color(0xFF141821) else Color.White)
    }
}

@Composable
private fun GenreChip(label: String, on: Boolean, onClick: () -> Unit) {
    Text(
        label,
        fontSize = 13.sp,
        fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
        color = if (on) TextPrimary else TextMuted,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(Color.White.copy(alpha = if (on) 0.16f else 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}
