package io.movieclaw.androidtv.ui.library

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.detail.PageStates
import io.movieclaw.androidtv.ui.detail.PillButton
import io.movieclaw.androidtv.ui.detail.attempt
import io.movieclaw.androidtv.ui.detail.tryFocus
import io.movieclaw.androidtv.ui.shell.WallSource
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import kotlinx.coroutines.delay
import java.util.UUID

/** 这一页的分页加载器：按页面实例记住，从详情退回来不重取 */
@Composable
private fun rememberWallLoader(kind: String): WallLoader {
    val session = LocalSession.current
    val token = rememberSaveable { UUID.randomUUID().toString() }
    return remember(token) { PageStates.getOrPut("wall:$kind:${session.key}:$token") { WallLoader() } }
}

/**
 * 一个媒体库的海报墙（TVLibraryView）：库名 + 「N 部」+ 右上角排序按钮（最近添加 / 最近上映 / 评分最高 / A–Z + 只看没看过的），
 * 按库记在本机。条目分页加载，滚到底接着取。
 */
@Composable
fun LibraryWallScreen(libraryId: Long) {
    val session = LocalSession.current
    val store = LocalGraph.current.store
    val loader = rememberWallLoader("library")
    val key = WallLogic.sortKey(libraryId)
    var sort by remember { mutableStateOf(WallLogic.decodeSort(store.string(key))) }
    var unwatched by remember { mutableStateOf(store.string("$key.unwatched") == "true") }
    var menuOpen by remember { mutableStateOf(false) }
    val buttonFocus = remember { FocusRequester() }

    LaunchedEffect(libraryId) {
        if (loader.title != null) return@LaunchedEffect
        attempt { session.api.libraryList(scope = "all") }?.firstOrNull { it.id == libraryId }?.let {
            loader.title = it.name
            loader.count = it.stats.itemCount
        }
    }
    val queryKey = "${sort.sort}-${sort.reversed}-$unwatched"
    LaunchedEffect(queryKey) {
        if (loader.loadedKey == queryKey && loader.items != null) return@LaunchedEffect
        val query = WallLogic.libraryQuery(libraryId, sort, unwatched)
        loader.reset(queryKey) { offset, limit -> session.api.fetchWall(query, offset, limit) }
    }

    PosterWall(
        title = loader.title ?: "媒体库",
        loader = loader,
        subtitle = loader.count?.let { "$it 部" },
        fallbackLibrary = libraryId,
        emptyTitle = if (unwatched) "没有没看过的了" else "这个库里还没有内容",
        accessory = {
            PillButton(
                onClick = { menuOpen = true },
                text = WallLogic.sortButtonLabel(sort.sort, unwatched),
                icon = McIcons.Filter,
                modifier = Modifier.focusRequester(buttonFocus),
            )
        },
        overlay = {
            if (menuOpen) {
                SortMenu(
                    sort = sort.sort,
                    unwatched = unwatched,
                    onSort = {
                        sort = WallSort(it)
                        store.putString(key, WallLogic.encodeSort(sort))
                    },
                    onToggleUnwatched = {
                        unwatched = !unwatched
                        store.putString("$key.unwatched", unwatched.toString())
                    },
                    onDismiss = {
                        menuOpen = false
                        buttonFocus.tryFocus()
                    },
                )
            }
        },
    )
}

/** 合集墙（TVCollectionView）：同一套海报墙，条目来自合集接口，不另给排序 */
@Composable
fun CollectionWallScreen(collectionId: Long, name: String) {
    val session = LocalSession.current
    val loader = rememberWallLoader("collection")
    LaunchedEffect(collectionId) {
        if (loader.items != null) return@LaunchedEffect
        loader.reset("collection") { offset, limit ->
            session.api.collectionItemsList(collectionId, limit = limit, offset = offset).map { it.toWall() }
        }
    }
    PosterWall(title = name, loader = loader, emptyTitle = "合集里还没有内容")
}

/** 首页一行的「查看全部」/ 按类型墙（TVRowWallView）：取数参数与那一行完全一样，排序跟着行走 */
@Composable
fun RowWallScreen(title: String, source: WallSource) {
    val session = LocalSession.current
    val loader = rememberWallLoader("row")
    LaunchedEffect(source) {
        if (loader.items != null) return@LaunchedEffect
        val query = WallLogic.rowQuery(source)
        loader.reset("row") { offset, limit -> session.api.fetchWall(query, offset, limit) }
    }
    // 媒体库那一行没带部数时，按库的统计补上（只在没加筛选时写）
    LaunchedEffect(source) {
        if (source !is WallSource.Library || source.count != null || loader.count != null) return@LaunchedEffect
        if (WallLogic.rowCount(source, 0) == null) return@LaunchedEffect
        attempt { session.api.libraryList(scope = "all") }?.firstOrNull { it.id == source.id }?.let { loader.count = it.stats.itemCount }
    }
    PosterWall(
        title = title,
        loader = loader,
        subtitle = WallLogic.rowCount(source, loader.count)?.let { "$it 部" },
        fallbackLibrary = (source as? WallSource.Library)?.id,
    )
}

/**
 * 排序菜单（tvOS 的系统 Menu）：右上角浮一块深色面板，「排序」四档（当前档打勾）+ 分隔 + 「只看没看过的」开关。
 * 选一项就收起；返回键收起；焦点关在面板里，收起后回到排序按钮。
 */
@Composable
private fun BoxScope.SortMenu(
    sort: String,
    unwatched: Boolean,
    onSort: (String) -> Unit,
    onToggleUnwatched: () -> Unit,
    onDismiss: () -> Unit,
) {
    val first = remember { FocusRequester() }
    BackHandler(onBack = onDismiss)
    LaunchedEffect(Unit) {
        // 等面板排好再交焦点
        repeat(5) {
            delay(16)
            if (first.tryFocus()) return@LaunchedEffect
        }
    }
    val shape = RoundedCornerShape(28.pt)
    Column(
        Modifier
            .align(Alignment.TopEnd)
            .padding(top = 122.pt, end = McMetrics.Edge)
            .width(560.pt)
            .shadow(40.pt, shape, ambientColor = Color.Black, spotColor = Color.Black.copy(alpha = 0.6f))
            .background(Color(0xFF26282F).copy(alpha = 0.98f), shape)
            .padding(vertical = 16.pt)
            .focusProperties { onExit = { cancelFocusChange() } }
            .focusGroup(),
    ) {
        Text(
            "排序",
            style = McType.Caption.copy(fontWeight = FontWeight.SemiBold),
            color = McColors.Secondary,
            modifier = Modifier.padding(horizontal = 32.pt, vertical = 8.pt),
        )
        WallLogic.LIBRARY_SORTS.forEach { option ->
            MenuRow(
                text = WallLogic.shortLabel(option),
                checked = option == sort,
                modifier = if (option == sort) Modifier.focusRequester(first) else Modifier,
            ) {
                onSort(option)
                onDismiss()
            }
        }
        Box(Modifier.padding(vertical = 12.pt, horizontal = 24.pt).fillMaxWidth().height(1.pt).background(Color.White.copy(alpha = 0.12f)))
        MenuRow(text = "只看没看过的", checked = unwatched) {
            onToggleUnwatched()
            onDismiss()
        }
    }
}

/** 菜单里的一项：左边打勾的位置，获得焦点白底黑字 */
@Composable
private fun MenuRow(text: String, checked: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = modifier.padding(horizontal = 12.pt).fillMaxWidth().height(72.pt),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(16.pt)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            contentColor = Color.White,
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White.copy(alpha = 0.85f),
            pressedContentColor = Color.Black,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Row(Modifier.padding(horizontal = 20.pt).height(72.pt), horizontalArrangement = Arrangement.spacedBy(16.pt), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(32.pt), contentAlignment = Alignment.Center) {
                if (checked) Icon(McIcons.Check, null, modifier = Modifier.size(30.pt))
            }
            Text(text, style = McType.Callout)
        }
    }
}
