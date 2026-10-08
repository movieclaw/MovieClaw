package io.movieclaw.android.feature.search

import io.movieclaw.android.core.designsystem.LocalFeedback
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.foundation.border
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.rounded.Close
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.PaletteSurface
import io.movieclaw.android.core.designsystem.TextPrimary
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.foundation.layout.aspectRatio
import io.movieclaw.android.core.designsystem.Placeholder
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.TorrentCategory
import io.movieclaw.android.core.model.TorrentHit

@Composable
fun SearchScreen(
    onBack: () -> Unit,
    onOpenLibraryItem: (Long, Long) -> Unit,
    onSubscribe: (String) -> Unit,
    onOpenTitle: (String) -> Unit,
    /** 带词进入（标题详情「搜索资源」→ search?q=）：预填并自动搜一次；空手进入则聚焦弹键盘 */
    initialKeyword: String = "",
    /** 进页时预选的分区；null = 维持资源（与网页 /search?q= 不带 tab 同语义） */
    initialMode: SearchMode? = null,
    /** 进页时预选的资源分类（详情页「搜索资源」按影片类型收窄 → search?q=&cat=；null = 不收窄） */
    initialCategory: TorrentCategory? = null,
    /** 手动选种模式（订阅详情「手动选种」→ search?forSub=）：结果全投给这条订阅 */
    forSubscriptionId: Long? = null,
    forSubscriptionTitle: String = "",
    vm: SearchViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val origin = vm.origin
    val keyboard = LocalSoftwareKeyboardController.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val focusRequester = remember { androidx.compose.ui.focus.FocusRequester() }

    // ── 分区裁剪（member-permissions-v2 §3.3 canOpenSearch）──
    // 影视 = 订阅能力；资源 = 资源搜索能力；媒体库 = 可见库白名单（成员要探测一次，见 SearchAccessRepository）。
    // **分段栏与有没有关键词无关**（iOS `.searchScopes` / 手机网页命令面板同款）：没输关键词时
    // 差别只在正文——资源给分类，影视 / 媒体库等输入；只在「一个可用分区都没有」时才是空态。
    val searchAccess = io.movieclaw.android.core.session.LocalSearchAccess.current
    val availableModes = buildList {
        if (searchAccess.canMedia) add(SearchMode.TITLES)
        if (searchAccess.canTorrent) add(SearchMode.TORRENTS)
        if (searchAccess.canLibrary) add(SearchMode.LIBRARY)
    }
    // 落在无权分区时切到第一个可用分区（web/iOS 同款兜底）
    LaunchedEffect(searchAccess.ready, availableModes, state.mode) {
        if (searchAccess.ready && availableModes.isNotEmpty() && state.mode !in availableModes) {
            val fallback = availableModes.first()
            vm.onMode(fallback)
            // 兜底落点也记下来（同 web：预选的模式写进 palette state）
            vm.rememberMode(fallback)
        }
    }

    val feedback = LocalFeedback.current
    val rememberedMode by vm.rememberedMode.collectAsStateWithLifecycle()
    // 预填只在进页做一次：读盘回来的「上次分区」不该把用户已切过的分区再拨回去
    var entryResolved by remember { mutableStateOf(false) }

    LaunchedEffect(state.notice) {
        state.notice?.let {
            feedback.show(it)
            vm.consumeNotice()
        }
    }

    // 首次进入：
    //  · 带词（详情页「搜索资源」→ search?q=[&cat=]）＝ 预填并自动搜一次（不弹键盘，用户要看的是结果），
    //    只有 q 不带 tab 时按网页老链接落在资源分区；cat 非空再按影片类型收窄分类（v0.32）；
    //  · 带 tab（放大镜按来源页签预选：发现 / 订阅 → 影视，媒体库 → 媒体库，活动 → 资源）＝ 直接落在该分区；
    //  · 手动选种（search?forSub=）＝ 资源分区；
    //  · 什么都没有（「我的」放大镜）＝ 沿用上次停留的分区（Web localStorage / iOS @AppStorage 同款）。
    // 空手进来还要聚焦弹键盘——点了放大镜就是要输入。
    LaunchedEffect(initialKeyword, initialMode, initialCategory, forSubscriptionId, rememberedMode) {
        if (entryResolved) return@LaunchedEffect
        val resolved = when {
            forSubscriptionId != null -> SearchMode.TORRENTS
            initialMode != null -> initialMode
            initialKeyword.isNotBlank() -> SearchMode.TORRENTS
            else -> rememberedMode ?: SearchMode.TORRENTS
        }
        entryResolved = true
        vm.prefill(resolved, initialKeyword.trim(), initialCategory)
        // 预选出来的分区也记下来（同 web `writeSearchPaletteState`）
        vm.rememberMode(resolved)
        if (initialKeyword.isNotBlank()) vm.submit()
    }
    // 手动选种模式：这一页的结果都投给这条订阅（网页 /search?for_sub= 同语义）
    LaunchedEffect(forSubscriptionId) {
        if (forSubscriptionId != null) vm.prefillGrabTarget(forSubscriptionId, forSubscriptionTitle)
    }
    LaunchedEffect(Unit) {
        if (initialKeyword.isBlank()) {
            focusRequester.requestFocus()
            keyboard?.show()
        }
    }

    // 全屏命令面板（实测：底色 rgba(15,17,23,.94)，URL 不变）
    Box(Modifier.fillMaxSize().background(PaletteSurface)) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            // 头部：输入框 312×40、圆角 999、白 9%；右侧「取消」17px
            Row(
                Modifier.fillMaxWidth().height(56.dp).padding(horizontal = McMetrics.pagePadding),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    Modifier
                        .weight(1f)
                        .height(40.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.09f))
                        .padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Rounded.Search, contentDescription = null, tint = TextFaint, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(8.dp))
                    // 分类 token（方案 a，同 web/iOS）：资源模式且选了分类时进框，点它清回全部分类；
                    // 框下 chips 行保留管「换范围」
                    if (state.mode == SearchMode.TORRENTS) {
                        state.category?.let { category ->
                            Row(
                                Modifier
                                    .clip(RoundedCornerShape(999.dp))
                                    .background(Color(0xFF56637A))
                                    .clickable { vm.onCategory(null) }
                                    .padding(start = 10.dp, end = 6.dp, top = 4.dp, bottom = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(category.label, fontSize = 12.sp, color = Color.White, maxLines = 1)
                                Spacer(Modifier.width(3.dp))
                                Icon(
                                    Icons.Rounded.Close,
                                    contentDescription = "清除分类，回到全部分类",
                                    tint = Color.White.copy(alpha = 0.85f),
                                    modifier = Modifier.size(12.dp),
                                )
                            }
                            Spacer(Modifier.width(6.dp))
                        }
                    }
                    Box(Modifier.weight(1f)) {
                        if (state.query.isEmpty()) {
                            Text(placeholderFor(state.mode), style = McType.body, color = TextFaint, maxLines = 1)
                        }
                        BasicTextField(
                            value = state.query,
                            onValueChange = vm::onQuery,
                            singleLine = true,
                            textStyle = McType.body.copy(color = Color.White),
                            cursorBrush = Brush.verticalGradient(listOf(AccentStrong, AccentStrong)),
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                            keyboardActions = KeyboardActions(onSearch = { keyboard?.hide(); vm.submit() }),
                            modifier = Modifier.fillMaxWidth().focusRequester(focusRequester),
                        )
                    }
                    if (state.searching) {
                        CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(15.dp), strokeWidth = 2.dp)
                    } else if (state.query.isNotEmpty()) {
                        Icon(
                            Icons.Rounded.Close,
                            contentDescription = "清空",
                            tint = TextFaint,
                            modifier = Modifier.size(16.dp).clickable { vm.onQuery("") },
                        )
                    }
                }
                Spacer(Modifier.width(12.dp))
                Text(
                    "取消",
                    style = McType.headline.copy(fontWeight = FontWeight.Normal),
                    color = TextPrimary,
                    modifier = Modifier.clickable { keyboard?.hide(); onBack() },
                )
            }

            // 一个可用分区都没有：入口本来就按 canOpenSearch 藏了，这里是深链兜底。
            // 「没有关键词」不算空态——分段栏照常画全（iOS / 手机网页命令面板同款）。
            if (searchAccess.ready && availableModes.isEmpty()) {
                Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    Text(
                        "当前账号没有可用的搜索入口，请联系管理员调整成员权限。",
                        fontSize = 13.sp,
                        color = TextMuted,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 28.dp),
                    )
                }
                return@Column
            }

            // 分区分段：只有一个可用分区时不画（iOS `.searchScopes` 同款）；
            // 用户切换即记下（下次「我的」进搜索沿用）
            if (availableModes.size > 1) {
                SearchModeSelector(
                    modes = availableModes,
                    current = state.mode,
                    onSelect = { mode -> vm.onMode(mode); vm.rememberMode(mode) },
                )
            }

            // 手动选种模式的横幅：这一页搜出的种子都会投给这条订阅（跳过规则组过滤，身份匹配照常）
            state.grabTarget?.let { (_, title) ->
                Text(
                    "手动选种：把选中的种子投给《$title》",
                    fontSize = 12.5.sp,
                    color = Info,
                    modifier = Modifier
                        .padding(horizontal = McMetrics.pagePadding)
                        .padding(top = 8.dp)
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Info.copy(alpha = 0.12f))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }

            if (state.mode == SearchMode.TORRENTS) {
                CategoryChips(selected = state.category, onSelect = vm::onCategory)
            }

            if (state.history.isNotEmpty() && state.blocks.isEmpty() && state.titles.isEmpty() && state.librarySearch?.items.isNullOrEmpty()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(top = 12.dp, bottom = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("最近搜索", style = McType.headline)
                    Spacer(Modifier.weight(1f))
                    Text("清空", style = McType.caption, color = TextFaint, modifier = Modifier.clickable { vm.clearHistory() })
                }
                LazyRow(
                    contentPadding = PaddingValues(horizontal = McMetrics.pagePadding, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(state.history, key = { it.id }) { item ->
                        Text(
                            item.keyword,
                            style = McType.sub,
                            color = TextPrimary,
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .background(Color.White.copy(alpha = 0.06f))
                                .border(1.dp, LineSoft, RoundedCornerShape(999.dp))
                                .clickable { vm.submit(item.keyword) }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        )
                    }
                }
            }

            // 空历史时的分区说明（网页命令面板 MODE_HINT 原话：影视 / 媒体库没有「浏览」语义，
            // 空词时该做的就是把片名打进去；资源分区空词时给的是分类，不占这一行）
            if (state.history.isEmpty() && state.query.isBlank() &&
                state.mode != SearchMode.TORRENTS &&
                state.titles.isEmpty() && state.librarySearch?.items.isNullOrEmpty()
            ) {
                Text(
                    "还没有搜索记录。" + when (state.mode) {
                        SearchMode.TITLES -> "在豆瓣与 TMDB 中搜索影视条目"
                        SearchMode.LIBRARY -> "在媒体库中搜索已入库的影片"
                        else -> "跨全部已配置站点搜索种子"
                    } + "。",
                    fontSize = 13.sp,
                    color = TextFaint,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 28.dp, vertical = 40.dp),
                )
            }

            state.error?.let { error ->
                Text(
                    error,
                    fontSize = 12.sp,
                    color = Danger,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                )
            }

            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = 24.dp),
            ) {
                if (state.mode == SearchMode.TORRENTS) {
                    items(state.blocks, key = { it.siteId }) { block ->
                        SiteSection(
                            block = block,
                            downloadStates = state.downloadStates,
                            grabStates = state.grabStates,
                            onOpenActions = { vm.openActions(it) },
                        )
                    }
                    state.done?.let { done ->
                        item {
                            Text(
                                "共 ${done.total} 条 · ${done.elapsedMs} ms · ${done.sites.size} 个站点",
                                fontSize = 11.5.sp,
                                color = TextFaint,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                            )
                        }
                    }
                }

                if (state.mode == SearchMode.TITLES) {
                    // iOS MediaSearchResultsView：豆瓣 / TMDB 两栏并排，各自带来源标签与条数
                    val douban = state.titles.filter { it.provider.equals("douban", true) }
                    val tmdb = state.titles.filterNot { it.provider.equals("douban", true) }
                    item(key = "titles-dual") {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding, vertical = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            listOf("豆瓣" to douban, "TMDB" to tmdb).forEach { (label, list) ->
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        label,
                                        fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                                        color = Color(0xFF9FB0C9),
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(7.dp))
                                            .background(Color.White.copy(alpha = 0.06f))
                                            .padding(horizontal = 7.dp, vertical = 3.dp),
                                    )
                                    Text("共 ${list.size} 条结果", fontSize = 12.sp, color = TextFaint, modifier = Modifier.padding(top = 6.dp, bottom = 8.dp))
                                    list.forEach { title ->
                                        TitleRow(
                                            title = title,
                                            origin = origin,
                                            onOpen = { onOpenTitle(title.titleRef) },
                                            onSubscribe = { onSubscribe(title.titleRef) },
                                        )
                                    }
                                    if (list.isEmpty()) Text("没有结果", fontSize = 12.sp, color = TextFaint)
                                }
                            }
                        }
                    }
                }

                if (state.mode == SearchMode.LIBRARY) {
                    // 媒体库（v0.31 /search/library）：相关度平铺的两列海报格 + 顶部人物行 +
                    // 每格注明命中原因（「演员：史蒂芬·朗」）。旧接口按库分组、组内拼音排，
                    // 人物带出的片会沉底，v0.31 起服务端已删除。
                    val lib = state.librarySearch
                    // 人物行：点头像下钻这个人的库内作品；下钻态给「返回全部」
                    if (lib != null && lib.people.isNotEmpty() && state.libraryPerson == null) {
                        item(key = "library-people") {
                            Column {
                                Row(Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding, vertical = 8.dp)) {
                                    // 只有「人物」一个标题（iOS LibrarySearchResultsView 同款）
                                    Text("人物", style = McType.headline, color = TextPrimary)
                                }
                                LazyRow(
                                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = McMetrics.pagePadding),
                                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                                ) {
                                    items(lib.people, key = { "p-${it.id}" }) { person ->
                                        PersonSearchChip(person = person, origin = origin, onClick = { vm.drillPerson(person) })
                                    }
                                }
                            }
                        }
                    }
                    if (state.libraryPerson != null) {
                        item(key = "library-person-bar") {
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    state.libraryPerson?.name ?: "",
                                    style = McType.subSemibold, color = TextPrimary,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(999.dp))
                                        .background(Color.White.copy(alpha = 0.08f))
                                        .padding(horizontal = 10.dp, vertical = 4.dp),
                                )
                                Spacer(Modifier.width(10.dp))
                                Text("只看 TA 的作品 · ", style = McType.caption, color = TextFaint)
                                Text("返回全部", style = McType.caption, color = Accent, modifier = Modifier.clickable { vm.exitPerson() })
                            }
                        }
                    }
                    if (state.searching && state.librarySearch?.items.isNullOrEmpty()) {
                        // 加载骨架：格宽与结果一致（网页 7 块 / iOS 6 块，这里三行两列）
                        item(key = "library-skeleton") {
                            Column(Modifier.padding(horizontal = McMetrics.pagePadding)) {
                                repeat(3) {
                                    Row(
                                        Modifier.fillMaxWidth().padding(vertical = 8.dp),
                                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                                    ) {
                                        repeat(2) {
                                            io.movieclaw.android.core.designsystem.SkeletonBlock(
                                                Modifier.weight(1f).aspectRatio(2f / 3f),
                                                radius = McMetrics.cardRadius,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    val total = lib?.items?.size ?: 0
                    if (!state.searching && total == 0 && state.query.isNotBlank()) {
                        // 空态：出口指向「影视」——库里没有 ≈ 想要但还没入手（网页/iOS 原话）
                        item(key = "library-empty") {
                            LibraryEmptyState { vm.onMode(SearchMode.TITLES); vm.submit() }
                        }
                    }
                    // 相关度平铺：每行两格，格下多一行命中原因（非片名命中才解释，同 iOS）
                    val hits = lib?.items.orEmpty()
                    if (total > 0) {
                        item(key = "library-count") {
                            Text(
                                "共 $total 条结果 · 按相关度排序",
                                style = McType.sub, color = TextMuted,
                                modifier = Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 8.dp),
                            )
                        }
                    }
                    items(hits.chunked(2), key = { row -> "lib-row-${row.firstOrNull()?.item?.mediaItemId}" }) { row ->
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding, vertical = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                        ) {
                            row.forEach { hit ->
                                LibraryResultCell(
                                    item = hit.item,
                                    origin = origin,
                                    modifier = Modifier.weight(1f),
                                    onClick = { onOpenLibraryItem(
                                        hit.item.libraryId ?: hit.libraryIds.firstOrNull() ?: -1L,
                                        hit.item.mediaItemId,
                                    ) },
                                    // 命中原因抑制规则照 iOS：只在「纯片名文本匹配」时不显示
                                    //（`person_id == nil && source_field == "title" && type 以 text 开头`），
                                    // 其余场景（演员 / 导演 / 别名…）都要把原因写出来
                                    matchLabel = hit.match.label.takeIf {
                                        it.isNotBlank() && !(
                                            hit.match.personId == null &&
                                                hit.match.sourceField == "title" &&
                                                hit.match.type.startsWith("text")
                                            )
                                    },
                                )
                            }
                            if (row.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                    // 游标续页：滚到接近底部再取下一页
                    if (lib?.nextCursor != null) {
                        item(key = "library-more") {
                            Box(Modifier.fillMaxWidth().padding(vertical = 14.dp), contentAlignment = Alignment.Center) {
                                // 分页按钮照 iOS/Web：正常「更多结果」、取下一页时「正在加载…」且不可点
                                val loadingMore = state.searching
                                Text(
                                    if (loadingMore) "正在加载…" else "更多结果",
                                    style = McType.sub,
                                    color = if (loadingMore) TextFaint else Accent,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(999.dp))
                                        .border(1.dp, LineSoft, RoundedCornerShape(999.dp))
                                        .clickable(enabled = !loadingMore) { vm.loadMoreLibrary() }
                                        .padding(horizontal = 16.dp, vertical = 8.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // ── 资源操作面板 / 落点确认条 / 完整落点弹窗（batch 3）──
    // 交互照 iOS TorrentActionsState：点行开面板 → 面板点「下载」收面板、按记忆弹确认条或完整弹窗。
    val permissions = io.movieclaw.android.core.session.LocalPermissions.current
    state.actionHit?.let { hit ->
        TorrentActionsSheet(
            hit = hit,
            isAdmin = permissions.isAdmin,
            canDirectDownload = permissions.canDirectDownload,
            canGrabForSubscription = permissions.canGrabForSubscription,
            grabTargetTitle = state.grabTarget?.second,
            downloadState = state.downloadStates[hitKey(hit)] ?: TorrentSubmitState.IDLE,
            grabState = state.grabStates[hitKey(hit)] ?: TorrentSubmitState.IDLE,
            onViewDetail = { url ->
                vm.closeActions()
                runCatching {
                    context.startActivity(
                        android.content.Intent(
                            android.content.Intent.ACTION_VIEW,
                            android.net.Uri.parse(url),
                        )
                    )
                }
            },
            onGrab = { vm.grab(hit) },
            onDownload = { vm.startDownload(hit) },
            onDismiss = { vm.closeActions() },
        )
    }
    val flow = state.download
    if (flow.request != null && flow.confirmOnly && flow.remembered != null) {
        DownloadConfirmSheet(
            pref = flow.remembered!!,
            categoryLabel = categoryLabel(flow.request!!.category),
            busy = flow.busy,
            onConfirm = { vm.confirmRemembered() },
            onChange = { vm.reopenTargetDialog() },
            onForget = { vm.forgetRemembered() },
            onDismiss = { vm.closeTargetSheet() },
        )
    } else if (flow.request != null) {
        DownloadTargetSheet(
            flow = flow,
            isAdmin = permissions.isAdmin,
            onDismiss = { vm.closeTargetSheet() },
            onSelect = { vm.selectOption(it) },
            onSetRemember = { vm.setRemember(it) },
            onSelectDownloader = { vm.setDownloader(it) },
            onShowOther = { vm.showOtherTargets() },
            onHintDraft = { vm.setHintDraft(it) },
            onSearchHint = { vm.searchHint() },
            onSelectCandidate = { vm.selectCandidate(it) },
            onSubmit = { vm.submitSelected() },
        )
    }
}

/** 种子分类的中文名（记忆确认条上展示「保存到 · <分类>」） */
private fun categoryLabel(category: String): String =
    io.movieclaw.android.core.model.TorrentCategory.of(category)?.label ?: "其他"

@Composable
private fun SearchModeSelector(modes: List<SearchMode>, current: SearchMode, onSelect: (SearchMode) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = McMetrics.pagePadding)
            .height(37.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Color.White.copy(alpha = 0.06f)),
        // 分段垂直居中：之前漏了这行，高亮条和文字缩在 37dp 栏的顶部（用户报「聚焦效果不对、字不居中」）
        verticalAlignment = Alignment.CenterVertically,
    ) {
        modes.forEach { mode ->
            val on = mode == current
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .padding(2.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(if (on) Color.White.copy(alpha = 0.13f) else Color.Transparent)
                    .clickable { onSelect(mode) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    when (mode) {
                        SearchMode.TITLES -> "影视"
                        SearchMode.TORRENTS -> "资源"
                        SearchMode.LIBRARY -> "媒体库"
                    },
                    style = McType.subSemibold,
                    color = if (on) TextPrimary else TextMuted,
                )
            }
        }
    }
}

@Composable
private fun CategoryChips(selected: TorrentCategory?, onSelect: (TorrentCategory?) -> Unit) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            FilterChip(
                selected = selected == null,
                onClick = { onSelect(null) },
                label = { Text("全部") },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = AccentSoft,
                    selectedLabelColor = Accent,
                ),
            )
        }
        items(TorrentCategory.entries.toList()) { category ->
            FilterChip(
                selected = selected == category,
                onClick = { onSelect(category) },
                label = { Text(category.label) },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = AccentSoft,
                    selectedLabelColor = Accent,
                ),
            )
        }
    }
}

@Composable
private fun SiteSection(
    block: SiteBlock,
    downloadStates: Map<String, TorrentSubmitState>,
    grabStates: Map<String, TorrentSubmitState>,
    onOpenActions: (TorrentHit) -> Unit,
) {
    Column(Modifier.padding(top = 10.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        ) {
            Text(block.siteName.ifEmpty { block.siteId }, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.width(8.dp))
            when {
                block.error != null -> Text("失败:${block.error}", fontSize = 11.sp, color = Danger, maxLines = 1, overflow = TextOverflow.Ellipsis)
                block.items.isNotEmpty() -> Text("${block.items.size} 条 · ${block.elapsedMs} ms", fontSize = 11.sp, color = TextFaint)
                else -> Text("搜索中…", fontSize = 11.sp, color = TextFaint)
            }
        }
        if (block.error == null && block.items.isEmpty()) {
            Box(Modifier.fillMaxWidth().height(28.dp).padding(horizontal = 16.dp), contentAlignment = Alignment.CenterStart) {
                CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
            }
        }
        block.items.take(30).forEach { hit ->
            TorrentRow(
                hit = hit,
                state = downloadStates[hitKey(hit)] ?: TorrentSubmitState.IDLE,
                grabState = grabStates[hitKey(hit)] ?: TorrentSubmitState.IDLE,
                onOpen = { onOpenActions(hit) },
            )
        }
    }
}

/**
 * 一条搜索结果：点按打开**资源操作面板**（查看详情 / 投给订阅 / 下载）——
 * 以前点一下就直接弹「提交下载」确认框，用户看不见落点也看不到站点详情页。
 */
@Composable
private fun TorrentRow(
    hit: TorrentHit,
    state: TorrentSubmitState,
    grabState: TorrentSubmitState,
    onOpen: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                hit.attrs?.titlesZh?.firstOrNull() ?: hit.attrs?.titlesEn?.firstOrNull() ?: hit.title,
                fontSize = 12.5.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                lineHeight = 17.sp,
            )
            Spacer(Modifier.height(4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                hit.size?.let { Text(it, fontSize = 11.sp, color = TextFaint) }
                Text("↑${hit.seeders}", fontSize = 11.sp, color = if (hit.seeders > 0) Success else TextFaint)
                Text("↓${hit.leechers}", fontSize = 11.sp, color = TextFaint)
                if (hit.free || hit.downloadVolumeFactor == 0f) {
                    Text(
                        "免费",
                        fontSize = 10.sp,
                        color = Success,
                        modifier = Modifier
                            .clip(RoundedCornerShape(4.dp))
                            .background(Success.copy(alpha = 0.14f))
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
                hit.category?.let { category ->
                    TorrentCategory.of(category)?.let {
                        Text(it.label, fontSize = 10.sp, color = Info)
                    }
                }
            }
        }
        // 行尾状态：提交中 / 已提交 / 已在下载器 / 投递中 / 已投递
        when {
            state == TorrentSubmitState.SUBMITTING || grabState == TorrentSubmitState.SUBMITTING ->
                CircularProgressIndicator(color = Accent, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            grabState == TorrentSubmitState.DONE ->
                Text("已投递", fontSize = 11.sp, color = Info, modifier = Modifier.padding(start = 8.dp))
            state == TorrentSubmitState.DONE || state == TorrentSubmitState.EXISTS ->
                Text(
                    if (state == TorrentSubmitState.EXISTS) "已在下载器" else "已提交",
                    fontSize = 11.sp,
                    color = Success,
                    modifier = Modifier.padding(start = 8.dp),
                )
            else -> Unit
        }
    }
}

@Composable
private fun TitleRow(
    title: io.movieclaw.android.core.model.DiscoveredTitle,
    origin: String?,
    onOpen: () -> Unit,
    onSubscribe: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onOpen)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Box(Modifier.width(64.dp).height(96.dp).clip(RoundedCornerShape(8.dp))) {
            RemoteImage(url = title.posterUrl, origin = origin, contentDescription = title.title, modifier = Modifier.fillMaxSize())
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title.title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(3.dp))
            Text(
                listOfNotNull(
                    title.releaseYear?.toString(),
                    title.providerRating.takeIf { it > 0f }?.let { "★ ${"%.1f".format(it)}" },
                    title.extentLabel.takeIf { it.isNotEmpty() },
                    title.provider.uppercase().takeIf { it.isNotEmpty() },
                ).joinToString(" · "),
                fontSize = 11.sp,
                color = TextFaint,
            )
            if (title.overview.isNotEmpty()) {
                Spacer(Modifier.height(5.dp))
                Text(title.overview, fontSize = 11.5.sp, color = TextMuted, maxLines = 3, overflow = TextOverflow.Ellipsis, lineHeight = 16.sp)
            }
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("查看详情 ›", fontSize = 11.sp, color = TextMuted)
                Spacer(Modifier.width(12.dp))
                Text(
                    "订阅",
                    fontSize = 11.sp,
                    color = Accent,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(AccentSoft)
                        .clickable(onClick = onSubscribe)
                        .padding(horizontal = 10.dp, vertical = 3.dp),
                )
            }
        }
    }
}

/**
 * 媒体库搜索结果的一格（网页 `LibraryResultCell` / iOS `LibrarySearchResultsView.cell`）：
 * 海报卡 2:3 + 标题 + 一行库存概况（剧集写「第 N 季 · M 集」/「N 季 · M 集」，再拼分辨率）。
 * 与「影视」垂直的结果卡同一档尺寸——三个垂直的结果卡视觉上是一套。
 */
@Composable
private fun LibraryResultCell(
    item: io.movieclaw.android.core.model.LibraryItemView,
    origin: String?,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
    /** 为什么命中（「演员：史蒂芬·朗」）；片名直接命中的不给 */
    matchLabel: String? = null,
) {
    Column(modifier.clickable(onClick = onClick)) {
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
        }
        Spacer(Modifier.height(8.dp))
        Text(
            item.title,
            style = McType.bodySemibold,
            color = TextPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        val footnote = buildList {
            if (item.kind == "tv" && item.seasons.isNotEmpty()) {
                val season = item.seasons.first()
                add(
                    if (item.seasons.size == 1) {
                        "第 $season 季" + (item.episodeCount?.let { " · $it 集" } ?: "")
                    } else {
                        "${item.seasons.size} 季" + (item.episodeCount?.let { " · $it 集" } ?: "")
                    },
                )
            }
            if (item.resolutions.isNotEmpty()) add(item.resolutions.joinToString("/"))
        }.joinToString(" · ")
        if (footnote.isNotBlank()) {
            Spacer(Modifier.height(2.dp))
            Text(footnote, style = McType.caption, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (matchLabel != null) {
            Spacer(Modifier.height(2.dp))
            Text(
                matchLabel,
                style = McType.caption, color = Accent,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** 人物行的一格：圆头像 72 + 名字 + 「库内 N 部」，整格 96 宽（iOS LibrarySearchPeopleRow 同尺寸） */
@Composable
private fun PersonSearchChip(
    person: io.movieclaw.android.core.model.LibrarySearchPerson,
    origin: String?,
    onClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.width(96.dp).clickable(onClick = onClick),
    ) {
        Box(
            Modifier
                .size(72.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(Placeholder),
        ) {
            RemoteImage(
                url = person.avatarUrl ?: person.profilePath,
                origin = origin,
                contentDescription = person.name,
                modifier = Modifier.fillMaxSize(),
                fallback = {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            person.name.take(1),
                            fontSize = 22.sp, fontWeight = FontWeight.Bold,
                            color = Color.White.copy(alpha = 0.35f),
                        )
                    }
                },
            )
        }
        Spacer(Modifier.height(6.dp))
        Text(
            person.name,
            style = McType.sub.copy(fontWeight = FontWeight.Medium), color = TextPrimary,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Text(
            "库内 ${person.itemCount} 部",
            style = McType.caption, color = TextFaint,
        )
    }
}

/** 媒体库搜索空态（网页/iOS 文案照抄）：出口指向「影视」——库里没有 ≈ 想要但还没入手 */
@Composable
private fun LibraryEmptyState(onSwitchToMedia: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = McMetrics.pagePadding, vertical = 56.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("媒体库中没有找到相关影片", style = McType.headline, color = TextPrimary)
        Spacer(Modifier.height(6.dp))
        Text(
            "已入库条目按标题和原名匹配；库里还没有的片子，去影视条目里找。",
            style = McType.sub,
            color = TextMuted,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            lineHeight = 19.sp,
        )
        Spacer(Modifier.height(16.dp))
        Box(
            Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))))
                .clickable(onClick = onSwitchToMedia)
                .padding(horizontal = 18.dp, vertical = 9.dp),
        ) {
            Text("搜索影视条目", style = McType.subSemibold, color = Color(0xFF141821))
        }
    }
}

@Composable
internal fun GlassNotice(text: String) {
    GlassCard(Modifier.padding(horizontal = 16.dp)) {
        Text(text, fontSize = 12.5.sp, color = Warning)
    }
}

private fun placeholderFor(mode: SearchMode): String = when (mode) {
    SearchMode.TORRENTS -> "片名 / 关键词 / IMDb ID"
    SearchMode.TITLES -> "搜索影视标题"
    SearchMode.LIBRARY -> "搜索已入库的影片…"
}
