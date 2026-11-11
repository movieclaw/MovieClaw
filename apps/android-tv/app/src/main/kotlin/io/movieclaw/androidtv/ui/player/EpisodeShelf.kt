package io.movieclaw.androidtv.ui.player

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.Icon
import io.movieclaw.androidtv.ui.components.FocusCard
import io.movieclaw.androidtv.ui.components.ProgressStrip
import io.movieclaw.androidtv.ui.components.RemoteImage
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.detail.SeasonTab
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.core.playback.EpisodePickerText
import kotlinx.coroutines.delay

/**
 * 选集剧照排（电视，同 Apple TV 的 `TVEpisodeShelf`、iPhone 的选集抽屉）：进度条上方「选集」打开，挑一集就换。
 *
 * 电视离得远，剧照比文字列表好认，所以是一排横卡（尺寸、焦点放大与详情页的分集横排一致），画面不缩、下半压暗、照常在播。
 * - 打开时焦点落在正在放的那一集：看下一集就是「右、确认」；
 * - 往上是季页签，焦点移到哪一季，下面就换成哪一季（同详情页，不用按确认），往下回到剧照；
 * - 缺集置灰、拿不到焦点，焦点直接跳过；
 * - 简介只给正在放的那一集（焦点在它上面时写在剧照排下面），没看过的集不剧透；
 * - 返回键或在剧照排上往下：收起。
 */
@Composable
internal fun EpisodeShelf(
    title: String,
    currentSeason: Long,
    currentEpisode: Long,
    /** 正在放的这一季（引擎里的 state.episodes） */
    playingEpisodes: List<EpisodeView>,
    currentOverview: String?,
    seasons: List<Long>,
    loadSeason: suspend (Long) -> List<EpisodeView>?,
    onRefresh: () -> Unit,
    positionMs: Long,
    durationMs: Long?,
    onPick: (season: Long, episode: Long, seasonEpisodes: List<EpisodeView>?) -> Unit,
    onClose: () -> Unit,
) {
    var season by remember(currentSeason) { mutableStateOf(currentSeason) }
    val others = remember { mutableStateMapOf<Long, List<EpisodeView>>() }
    val playingSeason = season == currentSeason
    val episodes: List<EpisodeView>? = if (playingSeason) playingEpisodes else others[season]
    var focusedEpisode by remember { mutableStateOf<Long?>(null) }
    val anchorFocus = remember { FocusRequester() }
    val seasonFocus = remember(seasons) { seasons.associateWith { FocusRequester() } }
    val listState = rememberLazyListState()
    /** 焦点该落在哪一集：本季是正在放的那集，别的季是第一个有片源的 */
    val anchor: Long? = if (playingSeason) currentEpisode else episodes?.firstOrNull { it.owned }?.episodeNumber

    BackHandler(onBack = onClose)
    LaunchedEffect(Unit) { onRefresh() }
    LaunchedEffect(season) {
        if (!playingSeason && others[season] == null) others[season] = loadSeason(season) ?: emptyList()
    }
    // 换了季：剧照排挪到那一季该停的那一集（焦点还在季页签上，不抢）
    LaunchedEffect(season, episodes?.size) {
        val index = episodes?.indexOfFirst { it.episodeNumber == anchor } ?: return@LaunchedEffect
        if (index >= 0) listState.scrollToItem((index - 1).coerceAtLeast(0))
    }
    // 刚升起：等剧照排好再把焦点交给正在放的那一集（同播放器里其他浮层的做法）
    LaunchedEffect(Unit) {
        repeat(10) {
            delay(40)
            if (runCatching { anchorFocus.requestFocus() }.getOrDefault(false)) return@LaunchedEffect
        }
    }

    Box(Modifier.fillMaxSize().testTag("player-episodes")) {
        // 画面退后而不熄灭：下半压暗托住卡片，上半照常看得清
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0f to Color.Black.copy(alpha = 0.1f),
                    0.4f to Color.Black.copy(alpha = 0.25f),
                    0.62f to Color.Black.copy(alpha = 0.82f),
                    1f to Color.Black.copy(alpha = 0.92f),
                ),
            ),
        )
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(bottom = 50.pt),
            verticalArrangement = Arrangement.spacedBy(30.pt),
        ) {
            // 季：剧名小字 + 一排季页签（多于一季时）；往下回到剧照
            Row(
                Modifier
                    .padding(horizontal = McMetrics.Edge)
                    .height(64.pt),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(28.pt),
            ) {
                Text(title, style = McType.size(25, FontWeight.Medium), color = Color.White.copy(alpha = 0.55f), maxLines = 1)
                if (seasons.size > 1) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.pt)) {
                        seasons.forEach { number ->
                            SeasonTab(
                                EpisodePickerText.seasonName(number),
                                selected = number == season,
                                onClick = { runCatching { anchorFocus.requestFocus() } },
                                modifier = Modifier
                                    .focusRequester(seasonFocus.getValue(number))
                                    // 往下回到剧照：落在该停的那一集，不按位置挑
                                    .focusProperties { down = anchorFocus }
                                    .onFocusChanged { if (it.isFocused && number != season) season = number }
                                    .testTag("episodes-season-$number"),
                            )
                        }
                    }
                } else {
                    Text(EpisodePickerText.seasonName(season), style = McType.size(28, FontWeight.SemiBold))
                }
            }

            val rowHeight = 234.pt + 150.pt
            when {
                episodes == null -> Box(Modifier.fillMaxWidth().height(rowHeight), contentAlignment = Alignment.Center) { Spinner() }
                episodes.isEmpty() -> Box(Modifier.fillMaxWidth().height(rowHeight), contentAlignment = Alignment.Center) {
                    Text("分集信息加载失败，请稍后重试。", style = McType.size(26), color = Color.White.copy(alpha = 0.6f))
                }
                else -> LazyRow(
                    state = listState,
                    contentPadding = PaddingValues(horizontal = McMetrics.Edge, vertical = 24.pt),
                    horizontalArrangement = Arrangement.spacedBy(McMetrics.CardSpacing),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(rowHeight)
                        // 剧照排最下面再往下：收起
                        .onPreviewKeyEvent { event ->
                            if (event.nativeKeyEvent.keyCode != android.view.KeyEvent.KEYCODE_DPAD_DOWN) return@onPreviewKeyEvent false
                            if (event.type == KeyEventType.KeyDown) onClose()
                            true
                        },
                ) {
                    items(episodes, key = { "$season-${it.episodeNumber}" }) { episode ->
                        val current = playingSeason && episode.episodeNumber == currentEpisode
                        ShelfCard(
                            episode = episode,
                            current = current,
                            focused = focusedEpisode == episode.episodeNumber,
                            positionMs = positionMs,
                            durationMs = durationMs,
                            onClick = {
                                if (current) onClose() else onPick(season, episode.episodeNumber, if (playingSeason) null else episodes)
                            },
                            // 焦点离开剧照（上到季页签）就清掉，换季后别把另一季的同号集当成焦点所在
                            onFocus = { focused ->
                                if (focused) focusedEpisode = episode.episodeNumber
                                else if (focusedEpisode == episode.episodeNumber) focusedEpisode = null
                            },
                            // 往上到正在看的这一季（不按位置挑）
                            up = seasonFocus[season],
                            modifier = if (episode.episodeNumber == anchor) Modifier.focusRequester(anchorFocus) else Modifier,
                        )
                    }
                }
            }

            // 剧照排下面：焦点在正在放的那一集上时写它的简介
            Text(
                if (playingSeason && focusedEpisode == currentEpisode) currentOverview.orEmpty() else "",
                style = McType.size(25),
                color = Color.White.copy(alpha = 0.72f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = McMetrics.Edge).widthIn(max = 1300.pt).height(34.pt),
            )
        }
    }
}

/** 一张剧照卡：剧照 416×234（正在放的那集左上「正在播放」、下沿实时进度；看了一半的也有进度）+ 集号集名 + 状态 */
@Composable
private fun ShelfCard(
    episode: EpisodeView,
    current: Boolean,
    focused: Boolean,
    positionMs: Long,
    durationMs: Long?,
    onClick: () -> Unit,
    onFocus: (Boolean) -> Unit,
    up: FocusRequester?,
    modifier: Modifier = Modifier,
) {
    val width = McMetrics.LandscapeWidth
    val number = episode.episodeNumber
    val caption = EpisodePickerText.caption(number, episode.name)
    Column(
        Modifier.alpha(if (episode.owned) 1f else 0.34f),
        verticalArrangement = Arrangement.spacedBy(McMetrics.CaptionSpacing),
    ) {
        FocusCard(
            onClick,
            modifier
                .size(width, 234.pt)
                // 缺集拿不到焦点：左右走时直接跳过
                .focusProperties {
                    canFocus = episode.owned
                    up?.let { this.up = it }
                }
                .semantics { contentDescription = if (current) "正在播放 $caption" else caption }
                .testTag(if (current) "episode-current" else "episode-$number"),
            onFocus = onFocus,
        ) {
            Box(Modifier.fillMaxSize()) {
                RemoteImage(episode.stillUrl, 416f, Modifier.fillMaxSize(), zoom = McMetrics.FocusZoom, placeholder = "第 $number 集")
                if (current) {
                    Row(
                        Modifier
                            .align(Alignment.TopStart)
                            .padding(14.pt)
                            .background(Color(0xFF141416).copy(alpha = 0.6f), RoundedCornerShape(50))
                            .padding(horizontal = 16.pt, vertical = 8.pt),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.pt),
                    ) {
                        Icon(Icons.Filled.GraphicEq, null, tint = Color.White, modifier = Modifier.size(22.pt))
                        Text("正在播放", style = McType.size(21, FontWeight.SemiBold))
                    }
                }
                val progress = if (current) EpisodePickerText.fraction(positionMs, durationMs) else EpisodePickerText.partial(episode)
                if (progress != null) {
                    ProgressStrip(
                        progress,
                        Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(start = 16.pt, end = 16.pt, bottom = 14.pt),
                        track = Color.White.copy(alpha = 0.3f),
                    )
                }
            }
        }
        Column(Modifier.widthIn(max = width), verticalArrangement = Arrangement.spacedBy(6.pt)) {
            val name = episode.name?.takeIf { it.isNotEmpty() }
            Row(horizontalArrangement = Arrangement.spacedBy(12.pt)) {
                val style = McType.size(29, FontWeight.SemiBold)
                val bright = focused || current
                if (name != null) {
                    Text("$number", style = style, color = Color.White.copy(alpha = 0.45f), maxLines = 1)
                    Text(name, style = style, color = Color.White.copy(alpha = if (bright) 1f else 0.72f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                } else {
                    Text("第 $number 集", style = style, color = Color.White.copy(alpha = if (bright) 1f else 0.72f), maxLines = 1)
                }
            }
            val subline = when {
                current && durationMs != null && durationMs > 0 -> "剩 ${EpisodePickerText.minutesLeft(positionMs, durationMs)} 分钟"
                current -> ""
                else -> EpisodePickerText.meta(episode)?.first.orEmpty()
            }
            Text(subline, style = McType.size(23), color = Color.White.copy(alpha = 0.55f), maxLines = 1)
        }
    }
}
