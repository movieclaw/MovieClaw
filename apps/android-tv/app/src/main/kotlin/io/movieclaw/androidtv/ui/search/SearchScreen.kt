package io.movieclaw.androidtv.ui.search

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.tv.material3.Icon
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
import io.movieclaw.androidtv.ui.components.TvScrollSpec
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.LocalShellChrome
import io.movieclaw.androidtv.ui.shell.Route
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.welcome.WelcomeButton
import io.movieclaw.androidtv.ui.welcome.tvClickable
import kotlinx.coroutines.delay

/** 人物卡的头像（TVPersonCard.searchAvatarSize） */
private const val AVATAR = 150

/**
 * 搜索（TVSearchView）：照 tvOS 系统搜索页——顶上一行搜索字（左放大镜、右「按下 ⏯ 更改键盘」），下面一整排屏幕键盘，
 * 有联想时键盘下一排联想词（第一个是搜「当前输入」本身，焦点停在哪个，顶上就先显示哪个），一道分隔线，再往下是结果：
 * 「人物」（小一号的演职员头像卡，进影人页）、「最相关的影片」（海报下常显片名、年份·类型、命中原因），有下一页时行尾「更多结果」。
 *
 * 键盘只有字母、数字、符号三档（拼音首字母就能搜中文片名）；要打汉字或用语音，按「换输入法」键或遥控器的播放 / 暂停键
 * 换成系统输入法。接了实体键盘也能直接打字。
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
    var mode by rememberSaveable { mutableStateOf(KeyMode.Letters) }
    var keyboardFocused by remember { mutableStateOf(false) }
    /** 焦点停在联想词上：顶上先显示它 */
    var preview by remember { mutableStateOf<String?>(null) }
    var systemInput by remember { mutableStateOf(false) }

    // 进页面：焦点落在键盘第一个字上；切页签回来还给上次的那张卡
    LaunchedEffect(Unit) {
        val key = model.focusedKey ?: "key"
        for (wait in listOf(0L, 50L, 100L, 200L, 400L)) {
            delay(wait)
            if (runCatching { requester(key).requestFocus() }.getOrDefault(false)) return@LaunchedEffect
        }
        runCatching { requester("key").requestFocus() }
    }
    // 左上角「‹ 搜索」胶囊只在滚到顶时显示
    LaunchedEffect(list) {
        snapshotFlow { list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset < 40 }.collect { chrome.pillVisible = it }
    }
    DisposableEffect(Unit) { onDispose { chrome.pillVisible = true } }

    // 回到键盘（或换成系统输入法）时整页滚回顶上：输入的那一行要看得见
    LaunchedEffect(keyboardFocused, systemInput) {
        if (keyboardFocused || systemInput) list.animateScrollToItem(0)
    }

    fun type(text: String) = model.onQueryChange(model.query + text)
    fun delete() = model.onQueryChange(model.query.dropLast(1))

    val trimmed = model.trimmed
    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(Color(0xFF34393F), Color(0xFF24231F))))
            // 遥控器的播放 / 暂停键换成系统输入法；实体键盘直接打字
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                val native = event.nativeKeyEvent
                when {
                    native.keyCode == android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE && keyboardFocused -> {
                        systemInput = true
                        true
                    }
                    native.keyCode == android.view.KeyEvent.KEYCODE_DEL -> {
                        delete()
                        true
                    }
                    native.unicodeChar > 0 && !native.isCtrlPressed && native.unicodeChar.toChar().let { !it.isISOControl() } -> {
                        type(native.unicodeChar.toChar().toString())
                        true
                    }
                    else -> false
                }
            },
    ) {
        // 只在焦点那一行露不全时才滚（同 tvOS），键盘、联想词之间上下挪不动页面
        TvScrollSpec(80) {
        LazyColumn(
            Modifier.fillMaxSize(),
            state = list,
            contentPadding = PaddingValues(bottom = 40.pt),
        ) {
            item(key = "keyboard") {
                Column(Modifier.fillMaxWidth()) {
                    Spacer(Modifier.height(110.pt))
                    SearchField(preview ?: model.query, showHint = keyboardFocused && preview == null)
                    Spacer(Modifier.height(93.pt))
                    SearchKeyboard(
                        mode = mode,
                        onKey = ::type,
                        onSpace = { type(" ") },
                        onDelete = ::delete,
                        onClear = { model.onQueryChange("") },
                        onSwitchMode = { mode = mode.next },
                        onSystemInput = { systemInput = true },
                        modifier = Modifier.onFocusChanged { keyboardFocused = it.hasFocus },
                        firstKey = Modifier.tracked("key"),
                    )
                    if (model.suggestions.isNotEmpty() && trimmed.isNotEmpty()) {
                        Spacer(Modifier.height(35.pt))
                        Suggestions(model, onPreview = { preview = it })
                        Spacer(Modifier.height(40.pt))
                    } else {
                        Spacer(Modifier.height(38.pt))
                    }
                    Box(Modifier.padding(horizontal = McMetrics.Edge).fillMaxWidth().height(1.pt).background(Color.White.copy(alpha = 0.16f)))
                    Spacer(Modifier.height(if (model.people.isNotEmpty() || model.items.isNotEmpty()) 50.pt else 20.pt))
                }
            }
            if (model.searching) {
                item(key = "searching") {
                    Column(Modifier.fillMaxWidth().padding(bottom = McMetrics.RowSpacing), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.pt)) {
                        Spinner(sizePt = 50)
                        Text("正在搜索…", style = McType.Body, color = McColors.Secondary)
                    }
                }
            }
            if (model.people.isNotEmpty()) {
                item(key = "people") {
                    Shelf("人物", modifier = Modifier.padding(bottom = McMetrics.RowSpacing)) {
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
        if (systemInput) {
            SystemInput(
                value = model.query,
                onValueChange = model::onQueryChange,
                onSubmit = { model.submit() },
                onClose = {
                    systemInput = false
                    runCatching { requester("key").requestFocus() }
                },
            )
        }
    }
}

/** 顶上那一行：放大镜 + 输入的字（没输入时灰色提示语）；键盘有焦点时右边写「按下 ⏯ 更改键盘」 */
@Composable
private fun SearchField(text: String, showHint: Boolean) {
    Row(
        Modifier.fillMaxWidth().height(90.pt).padding(start = 104.pt, end = McMetrics.Edge),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(McIcons.SearchOutline, null, tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(52.pt))
        Spacer(Modifier.width(42.pt))
        Text(
            text.ifEmpty { "片名、拼音首字母、演员或导演" },
            style = McType.size(44, FontWeight.Medium),
            color = Color.White.copy(alpha = if (text.isEmpty()) 0.4f else 0.7f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (showHint) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.pt)) {
                Text("按下", style = McType.size(29), color = Color.White.copy(alpha = 0.4f))
                Icon(McIcons.PlayPauseCircle, null, tint = Color.White.copy(alpha = 0.4f), modifier = Modifier.size(32.pt))
                Text("更改键盘", style = McType.size(29), color = Color.White.copy(alpha = 0.4f))
            }
        }
    }
}

/**
 * 系统输入法（打汉字、语音）：一个看不见的输入框接住输入法，字照常显示在顶上那一行。
 * 输入法上按「搜索」立即搜；收起输入法后再按方向键 / 返回键回到屏幕键盘。
 */
@Composable
private fun SystemInput(value: String, onValueChange: (String) -> Unit, onSubmit: () -> Unit, onClose: () -> Unit) {
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    BackHandler(onBack = onClose)
    LaunchedEffect(Unit) {
        repeat(5) {
            delay(16)
            if (runCatching { focus.requestFocus() }.getOrDefault(false)) {
                keyboard?.show()
                return@LaunchedEffect
            }
        }
    }
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier
            .size(1.pt)
            .graphicsLayer { alpha = 0f }
            .focusRequester(focus)
            .onPreviewKeyEvent { event ->
                // 输入法开着时方向键归它；收起之后的方向键说明想回屏幕键盘
                val code = event.nativeKeyEvent.keyCode
                val nav = code in android.view.KeyEvent.KEYCODE_DPAD_UP..android.view.KeyEvent.KEYCODE_DPAD_CENTER
                if (nav && event.type == KeyEventType.KeyDown) {
                    onClose()
                    true
                } else {
                    false
                }
            },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search, autoCorrectEnabled = false),
        keyboardActions = KeyboardActions(onAny = {
            keyboard?.hide()
            onSubmit()
            onClose()
        }),
    )
}

/**
 * 联想词（tvOS 键盘下的建议）：第一个是放大镜 +「当前输入」，后面是服务端给的联想。
 * 焦点停在哪个，顶上先显示哪个；选一个就按它立即搜。
 */
@Composable
private fun Suggestions(model: SearchModel, onPreview: (String?) -> Unit) {
    val texts = listOf(model.query.trim()) + model.suggestions.map { it.text }.filter { it != model.query.trim() }.distinct()
    LazyRow(
        Modifier.fillMaxWidth().focusGroup().onFocusChanged { if (!it.hasFocus) onPreview(null) },
        contentPadding = PaddingValues(horizontal = McMetrics.Edge),
        horizontalArrangement = Arrangement.spacedBy(21.pt),
    ) {
        itemsIndexed(texts, key = { index, text -> "$index:$text" }) { index, text ->
            Surface(
                onClick = { model.submit(text) },
                modifier = Modifier.height(66.pt).onFocusChanged { if (it.isFocused) onPreview(if (index == 0) null else text) },
                shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(50)),
                scale = ClickableSurfaceDefaults.scale(focusedScale = 1.06f),
                colors = ClickableSurfaceDefaults.colors(
                    containerColor = Color.White.copy(alpha = 0.14f),
                    contentColor = McColors.Text,
                    focusedContainerColor = Color.White,
                    focusedContentColor = Color.Black,
                ),
                glow = ClickableSurfaceDefaults.glow(),
            ) {
                Row(
                    Modifier.height(66.pt).padding(horizontal = 25.pt),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.pt),
                ) {
                    if (index == 0) Icon(McIcons.SearchOutline, null, modifier = Modifier.size(38.pt))
                    Text(if (index == 0) "\"$text\"" else text, style = McType.size(35), maxLines = 1)
                }
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
