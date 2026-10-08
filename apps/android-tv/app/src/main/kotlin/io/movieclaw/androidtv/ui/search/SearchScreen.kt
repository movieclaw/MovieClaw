package io.movieclaw.androidtv.ui.search

import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.core.model.generated.LibrarySearchHit
import io.movieclaw.androidtv.core.model.generated.LibrarySearchPerson
import io.movieclaw.androidtv.core.session.SearchResults
import io.movieclaw.androidtv.ui.components.Avatar
import io.movieclaw.androidtv.ui.components.CaptionMode
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.PosterCard
import io.movieclaw.androidtv.ui.components.Shelf
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.LocalShellChrome
import io.movieclaw.androidtv.ui.shell.Route
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.welcome.TvTextField
import io.movieclaw.androidtv.ui.welcome.WelcomeButton
import io.movieclaw.androidtv.ui.welcome.tvClickable
import kotlinx.coroutines.delay

/** 人物卡的头像（TVPersonCard.searchAvatarSize） */
private const val AVATAR = 150

/**
 * 搜索（TVSearchView）：顶上一个输入框（按确认弹出系统键盘，也能用遥控器语音），下面一排联想词，再往下是结果：
 * 「人物」（小一号的演职员头像卡，进影人页）、「最相关的影片」（海报下常显片名、年份·类型、命中原因），
 * 有下一页时行尾「更多结果」。名称、别名、拼音首字母、演员导演都能搜。
 *
 * tvOS 用的是系统搜索页（整排屏幕键盘）；电视上的 Android 没有这种内嵌键盘，换成输入框 + 系统输入法 + 联想词条。
 */
@Composable
fun SearchScreen() {
    val session = LocalSession.current
    val router = LocalRouter.current
    val chrome = LocalShellChrome.current
    val model = viewModel(key = "search#${session.key}") { SearchModel(session.api) }
    val list = rememberLazyListState()
    val requesters = remember { HashMap<String, FocusRequester>() }
    fun requester(key: String) = requesters.getOrPut(key) { FocusRequester() }
    fun Modifier.tracked(key: String) = focusRequester(requester(key)).onFocusChanged { if (it.isFocused || it.hasFocus) model.focusedKey = key }

    // 进页面：焦点落在输入框；从详情退回来还给上次的那张卡
    LaunchedEffect(Unit) {
        val key = model.focusedKey ?: "field"
        for (wait in listOf(0L, 50L, 100L, 200L, 400L)) {
            delay(wait)
            if (runCatching { requester(key).requestFocus() }.getOrDefault(false)) return@LaunchedEffect
        }
        runCatching { requester("field").requestFocus() }
    }
    // 左上角「‹ 搜索」胶囊只在滚到顶时显示
    LaunchedEffect(list) {
        snapshotFlow { list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset < 40 }.collect { chrome.pillVisible = it }
    }
    DisposableEffect(Unit) { onDispose { chrome.pillVisible = true } }

    val trimmed = model.trimmed
    LazyColumn(
        Modifier.fillMaxSize(),
        state = list,
        contentPadding = PaddingValues(top = 60.pt, bottom = 40.pt),
        verticalArrangement = Arrangement.spacedBy(McMetrics.RowSpacing),
    ) {
        item(key = "field") {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.pt)) {
                TvTextField(
                    model.query,
                    model::onQueryChange,
                    "片名、拼音首字母、演员或导演",
                    Modifier.width(1100.pt).onFocusChanged { if (it.isFocused) model.focusedKey = "field" },
                    focusRequester = requester("field"),
                    imeAction = ImeAction.Search,
                    leadingIcon = McIcons.Search,
                    onSubmit = { model.submit() },
                )
                if (model.suggestions.isNotEmpty()) Suggestions(model)
            }
        }
        if (model.searching) {
            item(key = "searching") {
                Column(Modifier.padding(horizontal = McMetrics.Edge), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.pt)) {
                    Spinner(sizePt = 50)
                    Text("正在搜索…", style = McType.Body, color = McColors.Secondary)
                }
            }
        }
        if (model.people.isNotEmpty()) {
            item(key = "people") {
                Shelf("人物") {
                    items(model.people, key = { it.id }) { person ->
                        PersonCard(person, Modifier.tracked("person:${person.id}")) {
                            // 旧服务端不返回 TMDB 影人 id：没有影人页可进，按确认不跳转
                            val tmdb = person.tmdbPersonId ?: return@PersonCard
                            router.push(Route.Person(tmdb, person.name, person.avatarUrl, null))
                        }
                    }
                }
            }
        }
        if (model.items.isNotEmpty()) {
            item(key = "items") {
                Shelf("最相关的影片") {
                    items(model.items, key = { it.item.mediaItemId }) { hit -> HitCard(hit, Modifier.tracked("item:${hit.item.mediaItemId}")) }
                    if (model.nextCursor != null) {
                        item(key = "more") {
                            // 与海报同高，按钮在中间
                            Box(Modifier.height(McMetrics.PosterWidth * 1.5f), contentAlignment = Alignment.Center) {
                                WelcomeButton(
                                    if (model.loadingMore) "正在加载…" else "更多结果",
                                    onClick = model::loadMore,
                                    enabled = !model.loadingMore,
                                    modifier = Modifier.tracked("more"),
                                )
                            }
                        }
                    }
                }
            }
        }
        val failed = model.failed
        when {
            failed != null -> item(key = "failed") {
                StateView(McIcons.WifiError, "搜索失败", message = failed, action = "重试", height = 420.pt, onAction = { model.submit() })
            }
            model.items.isEmpty() && !model.searching && trimmed.isNotEmpty() -> item(key = "empty") {
                StateView(McIcons.Search, "没有找到相关影片", message = "试试片名、别名、拼音首字母或演员、导演姓名。", height = 420.pt)
            }
            trimmed.isEmpty() && !model.searching -> item(key = "idle") {
                StateView(McIcons.Search, "搜索你的媒体库", message = "输入 xjcy、星际cy 或诺兰，也可以使用遥控器听写。", height = 420.pt)
            }
        }
    }
}

/** 联想词（tvOS 键盘上的建议列表）：选一个就把它填进输入框、立即搜 */
@Composable
private fun Suggestions(model: SearchModel) {
    LazyRow(
        Modifier.fillMaxWidth().focusGroup(),
        contentPadding = PaddingValues(horizontal = McMetrics.Edge, vertical = 8.pt),
        horizontalArrangement = Arrangement.spacedBy(20.pt, Alignment.CenterHorizontally),
    ) {
        items(model.suggestions, key = { "${it.type}:${it.text}:${it.mediaItemId}:${it.personId}" }) { suggestion ->
            Surface(
                onClick = { model.submit(suggestion.text) },
                shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(50)),
                scale = ClickableSurfaceDefaults.scale(focusedScale = 1.06f),
                colors = ClickableSurfaceDefaults.colors(
                    containerColor = Color.White.copy(alpha = 0.1f),
                    contentColor = McColors.Text,
                    focusedContainerColor = Color.White,
                    focusedContentColor = Color.Black,
                ),
            ) {
                Text(
                    suggestion.text,
                    style = McType.Callout,
                    maxLines = 1,
                    modifier = Modifier.padding(horizontal = 28.pt, vertical = 12.pt),
                )
            }
        }
    }
}

/** 一部命中的作品（TVPosterCard，说明常显）：片名、「年份 · 类型」、命中原因（人物带出的作品用人像图标） */
@Composable
private fun HitCard(hit: LibrarySearchHit, modifier: Modifier) {
    val router = LocalRouter.current
    PosterCard(
        image = hit.item.posterUrl,
        title = hit.item.title,
        onClick = {
            val library = SearchResults.libraryId(hit) ?: return@PosterCard
            router.push(Route.Item(library, hit.item.mediaItemId))
        },
        modifier = modifier,
        subtitle = SearchResults.subtitle(hit).ifEmpty { null },
        caption = CaptionMode.Always,
        note = hit.match.label.ifEmpty { null },
        noteIcon = if (SearchResults.matchedByPerson(hit)) McIcons.Person else McIcons.TextSearch,
    )
}

/**
 * 人物卡（TVPersonCard，搜索用小一号的头像 150）：卡宽 = 头像 + 26；名字 24 半粗一行，「库内 N 部」20 白 60%。
 * 获得焦点时头像放大 1.12、套 6pt 白边。
 */
@Composable
private fun PersonCard(person: LibrarySearchPerson, modifier: Modifier, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Column(
        modifier.width((AVATAR + 26).pt).tvClickable(interaction, onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.pt),
    ) {
        Avatar(person.name, person.avatarUrl, AVATAR, focused = focused)
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.pt)) {
            Text(person.name, style = McType.size(24, FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
            Text("库内 ${person.itemCount} 部", style = McType.size(20), color = Color.White.copy(alpha = 0.6f), maxLines = 1)
        }
    }
}
