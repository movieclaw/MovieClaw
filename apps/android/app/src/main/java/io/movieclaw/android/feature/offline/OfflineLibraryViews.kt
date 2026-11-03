package io.movieclaw.android.feature.offline

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Sort
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.designsystem.mcCards
import io.movieclaw.android.core.offline.OfflineDownloadSummary
import io.movieclaw.android.core.offline.OfflineFormat
import io.movieclaw.android.core.offline.OfflineItemSummary
import io.movieclaw.android.core.offline.OfflineProgress
import io.movieclaw.android.core.offline.OfflineUnit
import io.movieclaw.android.core.playback.PlayTarget

// 离线模式下的媒体库（docs/design/offline-download.md §1、§4；iOS `OfflineLibraryViews`）：同一个媒体库页签、
// 同一种海报格，数据换成本机目录。首页只留「接着看」与按库分组的已下载条目，不还原自定义首页。

/** 离线模式顶部的提示条：说明在看的是手机上的内容，可以手动重连 */
@Composable
fun OfflineBanner(modifier: Modifier = Modifier, inset: Dp = mcCards.pagePadding) {
    val offline = rememberOffline()
    val downloaded by offline.store().downloadedItemIds.collectAsStateWithLifecycle()
    val device = deviceName()
    Row(
        modifier
            .fillMaxWidth()
            .padding(horizontal = inset)
            .clip(RoundedCornerShape(14.dp))
            .background(Warning.copy(alpha = 0.08f))
            .border(1.dp, Warning.copy(alpha = 0.22f), RoundedCornerShape(14.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .testTag("offline-banner"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Rounded.WifiOff, null, tint = Warning, modifier = Modifier.size(20.dp))
        Column(Modifier.weight(1f)) {
            Text("离线浏览", style = McType.subheadlineSemibold, color = TextPrimary)
            Text("显示${device}上已下载的 ${downloaded.size} 部", style = McType.caption, color = TextMuted)
        }
        GlassPill("重新连接", Modifier.testTag("offline-reconnect")) { offline.reachability().reconnect() }
    }
}

@Composable
private fun GlassPill(text: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Text(
        text,
        style = McType.subheadline.copy(fontWeight = FontWeight.Medium),
        color = TextPrimary,
        modifier = modifier
            .clip(RoundedCornerShape(999.dp))
            .background(Color.White.copy(alpha = 0.12f))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

/** 离线时页签的占位：订阅、发现、活动、搜索这些都要连服务器 */
@Composable
fun OfflinePlaceholder(onOpenLibrary: () -> Unit, title: String = "离线中") {
    val offline = rememberOffline()
    val device = deviceName()
    Column(
        Modifier.fillMaxSize().background(Bg).padding(32.dp).testTag("offline-placeholder"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Rounded.WifiOff, null, tint = TextMuted, modifier = Modifier.size(44.dp))
        Spacer(Modifier.height(14.dp))
        Text(title, style = McType.title3, color = TextPrimary)
        Spacer(Modifier.height(8.dp))
        Text("这里需要连接服务器。${device}上已下载的影片在「媒体库」里，可以照常播放。", style = McType.sub, color = TextMuted, textAlign = TextAlign.Center)
        Spacer(Modifier.height(20.dp))
        Text(
            "去媒体库",
            style = McType.subheadlineSemibold,
            color = Color(0xFF141821),
            modifier = Modifier.clip(RoundedCornerShape(999.dp)).background(TextPrimary).clickable(onClick = onOpenLibrary).padding(horizontal = 22.dp, vertical = 10.dp),
        )
        Spacer(Modifier.height(10.dp))
        GlassPill("重新连接") { offline.reachability().reconnect() }
    }
}

/** 页签内容的离线闸：离线模式时换成占位 */
@Composable
fun OfflineGate(onOpenLibrary: () -> Unit, content: @Composable () -> Unit) {
    val offline = rememberOffline()
    val mode by offline.reachability().mode.collectAsStateWithLifecycle()
    if (mode == io.movieclaw.android.core.offline.ServerReachability.Mode.OFFLINE) OfflinePlaceholder(onOpenLibrary) else content()
}

/** 一张本机条目的海报格（离线首页、离线海报墙共用）：长按「删除下载」 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun OfflinePosterCell(item: OfflineItemSummary, origin: String?, width: Dp?, onOpen: () -> Unit) {
    val offline = rememberOffline()
    val state by offline.store().state.collectAsStateWithLifecycle()
    val device = deviceName()
    var menu by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    val episodes = if (item.kind == "tv") offline.store().unitsOfItem(item.mediaItemId, state).count { it.playable } else 0
    Box(if (width != null) Modifier.width(width) else Modifier.fillMaxWidth()) {
        Column(
            Modifier.combinedClickable(onClick = onOpen, onLongClick = { menu = true }).testTag("offline-item-${item.mediaItemId}"),
        ) {
            Box(
                Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f)),
            ) {
                RemoteImage(url = item.posterUrl, origin = origin, contentDescription = item.title, modifier = Modifier.fillMaxSize())
            }
            Spacer(Modifier.height(6.dp))
            Text(item.title, style = McType.sub, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val meta = listOfNotNull(item.year?.toString(), if (episodes > 0) "已下载 $episodes 集" else null).joinToString(" · ")
            if (meta.isNotEmpty()) Text(meta, style = McType.caption, color = TextFaint, maxLines = 1)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("删除下载", color = io.movieclaw.android.core.designsystem.Danger) }, onClick = { menu = false; confirm = true })
        }
    }
    if (confirm) {
        OfflineConfirmDialog(
            title = "删除「${item.title}」的下载？",
            message = "只删${device}上的副本，观看进度会保留。",
            action = "删除下载（${McFormat.bytes(offline.store().bytesOfItem(item.mediaItemId))}）",
            onDismiss = { confirm = false },
            onConfirm = { offline.downloader().deleteItem(item.mediaItemId) },
        )
    }
}

/** 离线首页：接着看 + 按库分组的已下载条目 */
@Composable
fun OfflineLibraryHome(
    origin: String?,
    onOpenItem: (libraryId: Long, itemId: Long) -> Unit,
    onOpenLibrary: (libraryId: Long, name: String) -> Unit,
    onPlay: (PlayTarget) -> Unit,
    modifier: Modifier = Modifier,
) {
    val offline = rememberOffline()
    val state by offline.store().state.collectAsStateWithLifecycle()
    val device = deviceName()
    val items = offline.store().downloadedItems(state)
    Column(modifier.testTag("offline-home")) {
        OfflineBanner(Modifier.padding(top = 12.dp))
        if (items.isEmpty()) {
            Column(
                Modifier.fillMaxWidth().padding(top = 56.dp, start = 32.dp, end = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(Icons.Rounded.Download, null, tint = TextFaint, modifier = Modifier.size(40.dp))
                Spacer(Modifier.height(12.dp))
                Text("${device}上还没有下载", style = McType.headline, color = TextPrimary)
                Spacer(Modifier.height(6.dp))
                Text("连上服务器后，在影片详情页点「下载」，没网的时候也能看。", style = McType.sub, color = TextMuted, textAlign = TextAlign.Center)
            }
            return@Column
        }
        // 接着看：本机进度里有续播点、没看完的单元（续播只看位置 > 0，同服务端口径）
        val resume = buildList {
            for ((itemId, map) in state.progress) {
                val item = state.items[itemId] ?: continue
                for ((key, value) in map) {
                    if (value.positionMs <= 0) continue
                    val parts = key.split("-").mapNotNull { it.toIntOrNull() }
                    if (parts.size != 2) continue
                    val unit = offline.store().playableUnit(itemId, parts[0], parts[1], state) ?: continue
                    add(Triple(item, unit, value))
                }
            }
        }.sortedByDescending { it.third.updatedAt }
        if (resume.isNotEmpty()) {
            OfflineSectionHeader("接着看")
            LazyRow(contentPadding = PaddingValues(horizontal = mcCards.pagePadding), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(resume, key = { it.second.fileId }) { (item, unit, progress) ->
                    OfflineResumeCard(item, unit, progress, origin) {
                        onPlay(
                            PlayTarget(
                                mediaItemId = item.mediaItemId, libraryId = item.libraryId, kind = item.kind, title = item.title,
                                seasonNumber = unit.season, episodeNumber = unit.episode, startMs = progress.positionMs,
                            ),
                        )
                    }
                }
            }
        }
        // 按库分组（库的先后按最近下载）
        items.groupBy { it.libraryId }.forEach { (libraryId, group) ->
            OfflineSectionHeader(group.first().libraryName.ifEmpty { "媒体库" }, action = "全部") { onOpenLibrary(libraryId, group.first().libraryName) }
            LazyRow(contentPadding = PaddingValues(horizontal = mcCards.pagePadding), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(group, key = { it.mediaItemId }) { item ->
                    OfflinePosterCell(item, origin, mcCards.posterWidth) { onOpenItem(item.libraryId, item.mediaItemId) }
                }
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun OfflineSectionHeader(title: String, action: String? = null, onAction: () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().padding(start = mcCards.pagePadding, end = mcCards.pagePadding, top = 24.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = McType.headline, color = TextPrimary, modifier = Modifier.weight(1f))
        if (action != null) Text(action, style = McType.sub, color = TextMuted, modifier = Modifier.clickable(onClick = onAction))
    }
}

/** 「接着看」卡：横版剧照 + 进度条，点了直接从续播点接着放 */
@Composable
private fun OfflineResumeCard(item: OfflineItemSummary, unit: OfflineUnit, progress: OfflineProgress, origin: String?, onClick: () -> Unit) {
    Column(Modifier.width(260.dp).clickable(onClick = onClick).testTag("offline-resume-${unit.fileId}")) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.06f))) {
            RemoteImage(url = unit.stillUrl ?: item.backdropUrl ?: item.posterUrl, origin = origin, contentDescription = null, modifier = Modifier.fillMaxSize())
            val duration = progress.durationMs
            if (duration != null && duration > 0) {
                Box(Modifier.align(Alignment.BottomStart).padding(8.dp).fillMaxWidth().height(3.dp)) {
                    Box(
                        Modifier.fillMaxWidth((progress.positionMs.toFloat() / duration).coerceIn(0f, 1f)).height(3.dp)
                            .clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = 0.85f)),
                    )
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(item.title, style = McType.footnote.copy(fontWeight = FontWeight.Medium), color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(
            if (unit.isMovie) McFormat.clock(progress.positionMs) else "${OfflineFormat.seasonEpisode(unit.season, unit.episode)} · ${McFormat.clock(progress.positionMs)}",
            style = McType.caption, color = TextFaint, maxLines = 1,
        )
    }
}

/** 离线时的某个库的海报墙：本机有的条目，按最近下载 / 片名排 */
@Composable
fun OfflineLibraryWall(libraryId: Long, origin: String?, onBack: () -> Unit, onOpenItem: (Long, Long) -> Unit) {
    val offline = rememberOffline()
    val state by offline.store().state.collectAsStateWithLifecycle()
    val device = deviceName()
    var sortByTitle by rememberSaveable { mutableStateOf(OfflineWallSort.byTitle) }
    var sortMenu by remember { mutableStateOf(false) }
    val items = offline.store().downloadedItems(state).filter { it.libraryId == libraryId }
    val sorted = if (sortByTitle) items.sortedWith(compareBy(java.text.Collator.getInstance(java.util.Locale.CHINA)) { it.title }) else items
    Column(Modifier.fillMaxSize().background(Bg)) {
        McTopBar(
            variant = McTopBarVariant.Sub,
            title = items.firstOrNull()?.libraryName ?: "媒体库",
            onBack = onBack,
            actions = {
                Box {
                    IconButton(onClick = { sortMenu = true }) {
                        Icon(Icons.AutoMirrored.Rounded.Sort, contentDescription = "排序", tint = TextPrimary)
                    }
                    DropdownMenu(expanded = sortMenu, onDismissRequest = { sortMenu = false }) {
                        listOf(false to "最近下载", true to "片名").forEach { (value, label) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                trailingIcon = { if (sortByTitle == value) Icon(Icons.Rounded.Check, null) },
                                onClick = {
                                    sortMenu = false
                                    sortByTitle = value
                                    OfflineWallSort.byTitle = value
                                },
                            )
                        }
                    }
                }
            },
        )
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 110.dp),
            contentPadding = PaddingValues(horizontal = mcCards.pagePadding, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                OfflineBanner(inset = 0.dp)
            }
            if (sorted.isEmpty()) {
                item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                    Text("这个库在${device}上没有下载", style = McType.sub, color = TextMuted, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 40.dp).fillMaxWidth())
                }
            }
            items(sorted, key = { it.mediaItemId }) { item ->
                OfflinePosterCell(item, origin, null) { onOpenItem(item.libraryId, item.mediaItemId) }
            }
        }
    }
}

/** 离线海报墙的排序（同 iOS `@AppStorage("movieclaw.offline.wallSort")`，进程内记住即可） */
object OfflineWallSort {
    var byTitle = false
}

/**
 * 在线首页的「正在下载」提示条：有排队 / 下载中 / 暂停 / 失败的单元时才出现，下完自动消失。
 * 只汇总（在下什么、总速度、总进度）；每一集的状态在「我的 → 下载」的「下载中」里，点一下进去
 */
@Composable
fun OfflineDownloadingRow(onOpen: () -> Unit, modifier: Modifier = Modifier) {
    val offline = rememberOffline()
    val state by offline.store().state.collectAsStateWithLifecycle()
    val speeds by offline.store().speeds.collectAsStateWithLifecycle()
    val active = offline.store().activeUnits(state)
    if (active.isEmpty()) return
    val waitingForWiFi by offline.downloader().waitingForWiFi.collectAsStateWithLifecycle()
    val summary = OfflineDownloadSummary.make(active, speeds, state.items.mapValues { it.value.title }, waitingForWiFi)
    val tint = if (summary.warning) Warning else Info
    Row(
        modifier
            .fillMaxWidth()
            .padding(start = mcCards.pagePadding, end = mcCards.pagePadding, top = 16.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(tint.copy(alpha = 0.08f))
            .border(1.dp, tint.copy(alpha = 0.22f), RoundedCornerShape(14.dp))
            .clickable(onClick = onOpen)
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .testTag("home-downloading"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(34.dp), contentAlignment = Alignment.Center) {
            ProgressRing(summary.fraction ?: 0.0, tint, 34.dp)
            Icon(if (summary.allPaused) Icons.Rounded.Pause else Icons.Rounded.ArrowDownward, null, tint = tint, modifier = Modifier.size(15.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(summary.title, style = McType.subheadlineSemibold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(summary.detail, style = McType.caption, color = TextMuted, maxLines = 1)
        }
        Icon(Icons.Rounded.KeyboardArrowRight, null, tint = TextFaint, modifier = Modifier.size(20.dp))
    }
}

/** 极简离线详情（§3.3）：本机存的详情读不出来时（旧版存档迁过来、还没联网刷新），只靠摘要也能播、能删 */
@Composable
fun OfflineMinimalDetail(itemId: Long, origin: String?, onBack: () -> Unit, onPlay: (PlayTarget) -> Unit) {
    val offline = rememberOffline()
    val state by offline.store().state.collectAsStateWithLifecycle()
    val device = deviceName()
    val item = state.items[itemId]
    val units = offline.store().unitsOfItem(itemId, state).filter { it.playable }
    Column(Modifier.fillMaxSize().background(Bg).testTag("offline-minimal-detail")) {
        McTopBar(variant = McTopBarVariant.Sub, title = item?.title.orEmpty(), onBack = onBack)
        if (item == null) return@Column
        Row(Modifier.padding(mcCards.pagePadding), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(90.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(10.dp)).background(Color.White.copy(alpha = 0.06f))) {
                RemoteImage(url = item.posterUrl, origin = origin, contentDescription = null, modifier = Modifier.fillMaxSize())
            }
            Spacer(Modifier.width(14.dp))
            Column {
                Text(item.title, style = McType.title3, color = TextPrimary)
                item.year?.let { Text(it.toString(), style = McType.sub, color = TextMuted) }
                Text("${device}上的副本", style = McType.caption, color = TextFaint)
            }
        }
        units.forEach { unit ->
            var confirm by remember(unit.fileId) { mutableStateOf(false) }
            Row(
                Modifier.fillMaxWidth().clickable {
                    onPlay(PlayTarget(mediaItemId = itemId, libraryId = item.libraryId, kind = item.kind, title = item.title, seasonNumber = unit.season, episodeNumber = unit.episode))
                }.padding(horizontal = mcCards.pagePadding, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Rounded.PlayArrow, null, tint = TextPrimary, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(10.dp))
                Text(if (unit.isMovie) "播放" else OfflineFormat.seasonEpisode(unit.season, unit.episode), style = McType.body, color = TextPrimary, modifier = Modifier.weight(1f))
                Text(McFormat.bytes(unit.receivedBytes), style = McType.caption, color = TextMuted)
                IconButton(onClick = { confirm = true }) {
                    Icon(Icons.Rounded.Delete, "删除", tint = TextFaint, modifier = Modifier.size(18.dp))
                }
            }
            if (confirm) {
                OfflineConfirmDialog(
                    title = "删除这份下载？", message = "只删${device}上的副本，观看进度会保留。",
                    action = "删除下载（${McFormat.bytes(unit.receivedBytes)}）", onDismiss = { confirm = false },
                    onConfirm = { offline.downloader().delete(unit.fileId) },
                )
            }
        }
    }
}

/**
 * 海报卡长按菜单里的「删除下载」（已下载的条目才有；只进菜单，不加可见控件；iOS `OfflineDeleteMenuButton`）。
 * [content] 拿到长按回调（没有下载时为 null，卡片照旧只认点按）
 */
@Composable
fun OfflineDeleteMenu(itemId: Long, title: String, content: @Composable (onLongClick: (() -> Unit)?) -> Unit) {
    val offline = rememberOffline()
    val state by offline.store().state.collectAsStateWithLifecycle()
    val device = deviceName()
    val has = state.units.values.any { it.mediaItemId == itemId }
    var menu by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    Box {
        content(if (has) ({ menu = true }) else null)
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("删除下载", color = io.movieclaw.android.core.designsystem.Danger) }, onClick = { menu = false; confirm = true })
        }
    }
    if (confirm) {
        OfflineConfirmDialog(
            title = "删除「$title」的下载？",
            message = "释放 ${McFormat.bytes(offline.store().bytesOfItem(itemId))}，只删${device}上的副本，观看进度会保留。",
            action = "删除下载",
            onDismiss = { confirm = false },
            onConfirm = { offline.downloader().deleteItem(itemId) },
        )
    }
}
