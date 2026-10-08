@file:OptIn(ExperimentalFoundationApi::class)

package io.movieclaw.androidtv.ui.detail

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.Text
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.core.model.generated.PersonCreditView
import io.movieclaw.androidtv.core.model.generated.PersonView
import io.movieclaw.androidtv.core.network.ApiException
import io.movieclaw.androidtv.core.network.generated.McApi
import io.movieclaw.androidtv.ui.components.Avatar
import io.movieclaw.androidtv.ui.components.CaptionMode
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.PosterCard
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.components.StateView
import io.movieclaw.androidtv.ui.components.imageUrl
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.Route
import io.movieclaw.androidtv.ui.stage.BlurredBackdrop
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

/** 海报墙版式（TVWallLayout）：一屏 5 列，左右间距 24、上下 40，5 张加 4 个间距铺满安全区内的 1760 点 */
internal object WallLayout {
    const val COLUMNS = 5
    const val COLUMN_SPACING = 24
    const val ROW_SPACING = 40
    const val POSTER_WIDTH = (1920f - 80 * 2 - (COLUMNS - 1) * COLUMN_SPACING) / COLUMNS
}

@Stable
private class PersonState(private val api: McApi, private val tmdbId: Long) {
    enum class Failure { Missing, Error }

    var person by mutableStateOf<PersonView?>(null)
        private set
    var failure by mutableStateOf<Failure?>(null)
        private set

    suspend fun load() {
        failure = null
        try {
            person = api.peopleShow(tmdbId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 404 = 库内没有这位影人的作品（多半是库早前扫描时还没建影人档案），文案与真出错分开说
            failure = if ((e as? ApiException)?.status == 404) Failure.Missing else Failure.Error
        }
    }
}

/**
 * 影人页（TVPersonView）：这个人在我库里的作品。头部（圆头像 + 姓名 + 原名 + 「库内 12 部 · 参演 10 · 执导 2」）随路由带过来，
 * 一打开就是全的；作品与海报墙同一套版式（5 列、海报下不挂字），饰演的角色收进海报底部只在焦点时浮现的暗带里。
 * 从哪部片点进来的那张标「本片」，按确认退回；文件已删的置灰、点不进去。
 */
@Composable
fun PersonScreen(route: Route.Person) {
    val session = LocalSession.current
    val router = LocalRouter.current
    val token = rememberSaveable { UUID.randomUUID().toString() }
    val state = remember(token) { PageStates.getOrPut("person:${session.key}:$token") { PersonState(session.api, route.tmdbId) } }
    val scope = rememberCoroutineScope()
    var focusKey by rememberSaveable { mutableStateOf<String?>(null) }
    var backdropKey by remember { mutableStateOf<String?>(null) }
    var pageFocused by remember { mutableStateOf(false) }
    val requesters = remember { HashMap<String, FocusRequester>() }
    fun req(key: String) = requesters.getOrPut(key) { FocusRequester() }
    val ptPx = LocalDensity.current.density * 0.5f
    val scroll = rememberScrollState()
    val spec = remember(scroll) { TopSnapBringIntoViewSpec(60 * ptPx, 300 * ptPx) { scroll.value.toFloat() } }

    LaunchedEffect(state) { if (state.person == null) state.load() }

    val person = state.person
    // 背景跟着焦点那一部：停稳 0.2 秒再换
    var backdropPoster by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(focusKey) {
        val key = focusKey ?: return@LaunchedEffect
        if (key == backdropKey) return@LaunchedEffect
        delay(200)
        backdropKey = key
        backdropPoster = person?.credits?.firstOrNull { creditKey(it) == key }?.posterUrl
    }
    // 作品出来 0.15 秒后焦点还没地方落：放到记下的那张，没有就第一张
    // 加载失败：焦点放到状态页的按钮上
    val stateFocus = remember { FocusRequester() }
    LaunchedEffect(state.failure) {
        if (state.failure == null) return@LaunchedEffect
        delay(150)
        if (!pageFocused) stateFocus.tryFocus()
    }
    LaunchedEffect(person != null) {
        val loaded = person ?: return@LaunchedEffect
        val first = PersonLogic.sections(loaded).firstOrNull()?.credits?.firstOrNull() ?: return@LaunchedEffect
        delay(150)
        if (pageFocused) return@LaunchedEffect
        val saved = focusKey
        if (saved != null && requesters[saved]?.tryFocus() == true) return@LaunchedEffect
        req(creditKey(first)).tryFocus()
    }

    Box(Modifier.fillMaxSize().onFocusChanged { pageFocused = it.hasFocus }) {
        BlurredBackdrop(imageUrl(backdropPoster, McMetrics.BlurredBackdropWidth.toFloat()))
        CompositionLocalProvider(LocalBringIntoViewSpec provides spec) {
            Column(
                Modifier.fillMaxSize().verticalScroll(scroll).padding(start = McMetrics.Edge, end = McMetrics.Edge, top = 20.pt, bottom = 80.pt),
                verticalArrangement = Arrangement.spacedBy(36.pt),
            ) {
                PersonHeader(route, person)
                val failure = state.failure
                when {
                    failure == PersonState.Failure.Missing -> StateView(
                        McIcons.PersonCard,
                        "库内没有这位影人的作品",
                        Modifier.focusRequester(stateFocus).focusGroup(),
                        message = "可能是这位影人参演的片都已从库里移除；也可能这个库是早前扫描的——影人档案随入库刮削一并建立，" +
                            "在手机或网页上对这个库执行一次「刷新元数据」即可补齐。",
                        action = "返回",
                        height = 640.pt,
                    ) { router.pop() }
                    failure == PersonState.Failure.Error -> StateView(
                        McIcons.WarningOutline,
                        "未能加载影人档案",
                        Modifier.focusRequester(stateFocus).focusGroup(),
                        message = "请稍后重试；若持续失败，请查看系统日志。",
                        action = "重试",
                        height = 640.pt,
                    ) { scope.launch { state.load() } }
                    person == null -> Box(Modifier.fillMaxWidth().padding(top = 120.pt), contentAlignment = Alignment.Center) { Spinner() }
                    else -> Credits(
                        person = person,
                        fromItem = route.fromItem,
                        cardModifier = { key ->
                            Modifier.focusRequester(req(key)).onFocusChanged { if (it.isFocused) focusKey = key }
                        },
                        onSelect = { credit ->
                            val libraryId = credit.libraryId
                            if (credit.mediaItemId == route.fromItem) {
                                // 「本片」就是上一页：退回去，不在栈里再压一份
                                router.pop()
                            } else if (libraryId != null) {
                                router.push(Route.Item(libraryId, credit.mediaItemId))
                            }
                        },
                    )
                }
            }
        }
    }
}

/** 同一部片可能既演又导，两段里各出现一次，焦点标识带上身份 */
private fun creditKey(credit: PersonCreditView) = "${credit.department}:${credit.mediaItemId}"

/** 圆头像 168（不可聚焦）+ 姓名 52 粗体 + 原名 + 库内作品统计 */
@Composable
private fun PersonHeader(route: Route.Person, person: PersonView?) {
    val displayName = person?.name ?: route.name
    Row(horizontalArrangement = Arrangement.spacedBy(36.pt), verticalAlignment = Alignment.CenterVertically) {
        Avatar(
            displayName,
            person?.avatarUrl ?: route.avatar,
            168,
            focusable = false,
        )
        Column(verticalArrangement = Arrangement.spacedBy(10.pt)) {
            Row(horizontalArrangement = Arrangement.spacedBy(20.pt)) {
                Text(displayName, style = McType.size(52, FontWeight.Bold), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.alignByBaseline())
                val original = person?.originalName
                if (!original.isNullOrEmpty() && original != displayName) {
                    Text(
                        original,
                        style = McType.size(26, FontWeight.Medium),
                        color = Color.White.copy(alpha = 0.6f),
                        maxLines = 1,
                        modifier = Modifier.alignByBaseline(),
                    )
                }
            }
            // 统计没回来时占住一行，接口回来不跳动
            Text(
                person?.let(PersonLogic::summary) ?: " ",
                style = McType.size(26, FontWeight.Medium).copy(fontFeatureSettings = "tnum"),
                color = Color.White.copy(alpha = 0.6f),
            )
        }
    }
}

/** 参演 / 执导两段；只有一种身份时不写段标题。每段按 5 张一排，每排是一个焦点区 */
@Composable
private fun Credits(
    person: PersonView,
    fromItem: Long?,
    cardModifier: (String) -> Modifier,
    onSelect: (PersonCreditView) -> Unit,
) {
    val parts = PersonLogic.sections(person)
    if (parts.isEmpty()) {
        StateView(McIcons.Film, "库内还没有这位影人的作品", height = 500.pt)
        return
    }
    parts.forEach { part ->
        Column(verticalArrangement = Arrangement.spacedBy(24.pt)) {
            if (parts.size > 1) {
                Row(horizontalArrangement = Arrangement.spacedBy(16.pt)) {
                    Text(part.title, style = McType.size(32, FontWeight.SemiBold), modifier = Modifier.alignByBaseline())
                    Text("${part.credits.size} 部", style = McType.Callout, color = McColors.Secondary, modifier = Modifier.alignByBaseline())
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(WallLayout.ROW_SPACING.pt)) {
                part.credits.chunked(WallLayout.COLUMNS).forEach { row ->
                    Row(
                        Modifier.fillMaxWidth().focusSection().focusGroup(),
                        horizontalArrangement = Arrangement.spacedBy(WallLayout.COLUMN_SPACING.pt),
                    ) {
                        row.forEach { credit ->
                            PosterCard(
                                image = credit.posterUrl,
                                title = credit.title,
                                onClick = { onSelect(credit) },
                                modifier = cardModifier(creditKey(credit)).alpha(if (credit.libraryId == null) 0.45f else 1f),
                                width = WallLayout.POSTER_WIDTH.pt,
                                widthPt = WallLayout.POSTER_WIDTH,
                                subtitle = credit.year?.toString(),
                                caption = CaptionMode.Hidden,
                                badge = if (credit.mediaItemId == fromItem) "本片" else null,
                                focusDetail = PersonLogic.focusDetail(credit),
                            )
                        }
                    }
                }
            }
        }
    }
}
