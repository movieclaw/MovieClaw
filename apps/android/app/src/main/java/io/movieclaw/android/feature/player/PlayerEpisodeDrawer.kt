package io.movieclaw.android.feature.player

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.core.playback.EpisodePickerText
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** 一块矩形（dp），选集让位布局用 */
internal data class StageRect(val x: Float, val y: Float, val width: Float, val height: Float) {
    val right get() = x + width
    val bottom get() = y + height
}

/** 选集面板打开时画面、面板、集名简介各在哪（整屏坐标，dp） */
internal data class EpisodeStage(val video: StageRect, val drawer: StageRect, val caption: StageRect?)

/**
 * 选集打开时的「画面让位」（同 iPhone 横屏 `EpisodeStageLayout`）：面板靠右，画面缩到左边、保持片子比例，
 * 下面写这一集的集名与简介；窗口太矮（分屏小窗）放不下集名简介就全给画面。手机播放器固定横屏，只有这一种排法。
 */
internal object EpisodeStageLayout {
    const val DRAWER_MARGIN = 8f
    const val GAP = 16f
    const val CAPTION_HEIGHT = 62f
    const val CAPTION_GAP = 12f
    const val VIDEO_CORNER = 18f
    const val DRAWER_CORNER = 36f

    /**
     * @param startInset 左侧刘海 / 挖孔的避让（横屏时在哪一侧都可能）
     * @param endInset 右侧刘海 / 挖孔的避让：面板让开它
     * @param aspect 片子宽高比；不知道时按 16:9
     */
    fun resolve(width: Float, height: Float, startInset: Float, endInset: Float, aspect: Float): EpisodeStage {
        val ratio = if (aspect > 0f && aspect.isFinite()) aspect else 16f / 9f
        val drawerWidth = min(380f, max(300f, Math.round(width * 0.365f).toFloat()))
        val trailing = max(DRAWER_MARGIN, endInset)
        val drawer = StageRect(width - trailing - drawerWidth, DRAWER_MARGIN, drawerWidth, height - DRAWER_MARGIN * 2)
        val leading = startInset + 16f
        val available = drawer.x - GAP - leading
        val top = 20f
        val bottom = height - 12f
        var budget = bottom - top - CAPTION_GAP - CAPTION_HEIGHT
        val showsCaption = budget >= 120f
        if (!showsCaption) budget = bottom - top
        var w = available
        var h = available / ratio
        if (h > budget) {
            h = budget
            w = budget * ratio
        }
        val block = h + if (showsCaption) CAPTION_GAP + CAPTION_HEIGHT else 0f
        val video = StageRect(leading + (available - w) / 2f, top + (bottom - top - block) / 2f, w, h)
        val caption = if (showsCaption) StageRect(video.x, video.bottom + CAPTION_GAP, video.width, CAPTION_HEIGHT) else null
        return EpisodeStage(video, drawer, caption)
    }
}

/**
 * 选集面板（手机，同 iPhone 的 `PlayerEpisodeDrawer` 横屏侧栏）：底栏「选集」打开，点一集就换。
 *
 * 规则与 iPhone、Mac、电视一致：打开停在正在放的那一集；正在放的那一集单独成卡（剧照大一号、实时进度、还剩几分钟），
 * 其余各集是紧凑的行；简介只给正在放的那一集（写在让位后的画面下方，面板里不重复）；看完的集名变暗带对勾，
 * 看了一半的剧照下有细进度条并写看到哪；缺集置灰点不动。换季只换列表，用 Material 的下拉菜单；别的季现取。
 * 点一行有水波纹（安卓的按压反馈）；返回键收起由播放页处理。
 */
@Composable
internal fun PlayerEpisodeDrawer(
    title: String,
    currentSeason: Long,
    currentEpisode: Long,
    /** 正在放的这一季（引擎里的 state.episodes） */
    playingEpisodes: List<EpisodeView>,
    seasons: List<Long>,
    loadSeason: suspend (Long) -> List<EpisodeView>?,
    onRefresh: () -> Unit,
    positionMs: Long,
    durationMs: Long?,
    paused: Boolean,
    imageOrigin: String?,
    guest: Boolean,
    onPick: (season: Long, episode: Long, seasonEpisodes: List<EpisodeView>?) -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var season by remember(currentSeason) { mutableStateOf(currentSeason) }
    val others = remember { mutableStateMapOf<Long, List<EpisodeView>>() }
    val playingSeason = season == currentSeason
    val episodes: List<EpisodeView>? = if (playingSeason) playingEpisodes else others[season]
    var menuOpen by remember { mutableStateOf(false) }
    var retry by remember { mutableIntStateOf(0) }

    LaunchedEffect(Unit) { onRefresh() }
    LaunchedEffect(season, retry) {
        if (!playingSeason && others[season] == null) others[season] = loadSeason(season) ?: emptyList()
    }

    val shape = RoundedCornerShape(EpisodeStageLayout.DRAWER_CORNER.dp)
    Column(
        modifier
            .clip(shape)
            // 播放页的玻璃只能是「黑底等价」（视频在 SurfaceView 上，模糊抓不到它的像素）：深色半透明 + 一圈淡白边
            .background(Brush.verticalGradient(listOf(Color(0xFF34343A).copy(alpha = 0.9f), Color(0xFF16161A).copy(alpha = 0.94f))))
            .border(1.dp, Color.White.copy(alpha = 0.14f), shape)
            .testTag("player-episodes"),
    ) {
        // 头部：剧名与集数小字，季名大字（多于一季时点开下拉菜单换季），右上 ✕
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 10.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    episodes?.takeIf { it.isNotEmpty() }?.let { "$title · ${it.size} 集" } ?: title,
                    style = McType.caption, color = Color.White.copy(alpha = 0.55f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Box {
                    val multi = seasons.size > 1
                    Row(
                        Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .then(if (multi) Modifier.clickable { menuOpen = true } else Modifier)
                            .padding(vertical = 2.dp)
                            .testTag("episodes-season"),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(EpisodePickerText.seasonName(season), style = McType.title3, color = Color.White)
                        if (multi) {
                            Box(Modifier.size(20.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
                                Icon(Icons.Rounded.ExpandMore, contentDescription = "换季", tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        seasons.forEach { number ->
                            DropdownMenuItem(
                                text = { Text(EpisodePickerText.seasonName(number)) },
                                leadingIcon = {
                                    Icon(Icons.Rounded.Check, null, modifier = Modifier.alpha(if (number == season) 1f else 0f))
                                },
                                onClick = {
                                    menuOpen = false
                                    season = number
                                },
                            )
                        }
                    }
                }
            }
            // ✕：可见圆 32，触控区 48（安卓最小触控尺寸）
            Box(Modifier.size(48.dp).clip(CircleShape).clickable(onClick = onClose).testTag("episodes-close"), contentAlignment = Alignment.Center) {
                Box(Modifier.size(32.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Close, contentDescription = "关闭", tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(18.dp))
                }
            }
        }

        when {
            episodes == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
            }
            episodes.isEmpty() -> Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("分集信息加载失败，请稍后重试。", style = McType.caption, color = Color.White.copy(alpha = 0.6f))
                    if (!playingSeason) {
                        TextButton(onClick = { others.remove(season); retry++ }) { Text("重试", color = Color.White) }
                    }
                }
            }
            else -> EpisodeList(
                episodes = episodes,
                season = season,
                playingSeason = playingSeason,
                currentEpisode = currentEpisode,
                positionMs = positionMs,
                durationMs = durationMs,
                paused = paused,
                imageOrigin = imageOrigin,
                guest = guest,
                onPick = { number -> onPick(season, number, if (playingSeason) null else episodes) },
                onClose = onClose,
            )
        }
    }
}

@Composable
private fun EpisodeList(
    episodes: List<EpisodeView>,
    season: Long,
    playingSeason: Boolean,
    currentEpisode: Long,
    positionMs: Long,
    durationMs: Long?,
    paused: Boolean,
    imageOrigin: String?,
    guest: Boolean,
    onPick: (Long) -> Unit,
    onClose: () -> Unit,
) {
    val anchor = if (playingSeason) episodes.indexOfFirst { it.episodeNumber == currentEpisode }.coerceAtLeast(0) else 0
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = anchor)
    // 打开、换季：把正在放的那一集摆到正中（先跳到它，量出视口和它的高再挪半屏）
    LaunchedEffect(season, episodes.size) {
        listState.scrollToItem(anchor)
        val info = listState.layoutInfo
        val item = info.visibleItemsInfo.firstOrNull { it.index == anchor } ?: return@LaunchedEffect
        val viewport = info.viewportEndOffset - info.viewportStartOffset
        listState.scrollToItem(anchor, -(viewport / 2 - item.size / 2))
    }
    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier
            .fillMaxSize()
            // 列表在上下两端淡出，不被面板的边硬切（同 iPhone 的渐隐遮罩）
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                drawRect(
                    Brush.verticalGradient(
                        0f to Color.Transparent,
                        (14.dp.toPx() / size.height) to Color.Black,
                        (1f - 28.dp.toPx() / size.height) to Color.Black,
                        1f to Color.Transparent,
                    ),
                    blendMode = BlendMode.DstIn,
                )
            },
    ) {
        itemsIndexed(episodes, key = { _, it -> "$season-${it.episodeNumber}" }) { index, episode ->
            // 弹出时各行从正在放的那一集向两边依次浮现：离它越远越晚，最多错开 8 步
            val step = min(8, abs(index - anchor))
            RiseIn(step) {
                if (playingSeason && episode.episodeNumber == currentEpisode) {
                    HeroCard(episode, positionMs, durationMs, paused, imageOrigin, guest, onClose)
                } else {
                    EpisodeRow(episode, imageOrigin, guest) { onPick(episode.episodeNumber) }
                }
            }
        }
    }
}

/** 弹出时的浮现：从下面 12dp 升上来并淡入，按步错开 */
@Composable
private fun RiseIn(step: Int, content: @Composable () -> Unit) {
    val progress = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        delay(60L + step * 30L)
        progress.animateTo(1f, spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMediumLow))
    }
    Box(Modifier.graphicsLayer { alpha = progress.value; translationY = (1f - progress.value) * 12.dp.toPx() }) { content() }
}

/** 正在放的那一集：剧照大一号、「正在播放」、实时进度与还剩几分钟 */
@Composable
private fun HeroCard(
    episode: EpisodeView,
    positionMs: Long,
    durationMs: Long?,
    paused: Boolean,
    imageOrigin: String?,
    guest: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(24.dp)
    Column(
        Modifier
            .padding(vertical = 4.dp)
            .fillMaxWidth()
            .clip(shape)
            .background(Color.White.copy(alpha = 0.12f))
            .border(0.5.dp, Color.White.copy(alpha = 0.2f), shape)
            .clickable(onClick = onClick)
            .padding(start = 10.dp, end = 10.dp, top = 10.dp, bottom = 12.dp)
            .semantics { selected = true; contentDescription = "正在播放 " + EpisodePickerText.caption(episode.episodeNumber, episode.name) }
            .testTag("episode-current"),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Still(episode, imageOrigin, guest, width = 124f, corner = 14f)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    // 在放时声波一明一暗地跳（iPhone 的可变色声波），暂停时停住
                    val pulse = if (paused) 1f else rememberInfiniteTransition(label = "pulse")
                        .animateFloat(0.45f, 1f, infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "pulse").value
                    Icon(Icons.Rounded.GraphicEq, null, tint = Color.White.copy(alpha = 0.62f * pulse), modifier = Modifier.size(13.dp))
                    Text("正在播放", style = McType.microSemibold, color = Color.White.copy(alpha = 0.62f))
                }
                EpisodeTitle(episode, dimmed = false, big = true)
            }
        }
        val fraction = EpisodePickerText.fraction(positionMs, durationMs)
        Column(Modifier.padding(horizontal = 2.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.22f))) {
                Box(Modifier.fillMaxWidth(fraction).fillMaxHeight().clip(CircleShape).background(Color.White))
            }
            Row {
                Text(McFormat.clock(positionMs), style = McType.micro, color = Color.White.copy(alpha = 0.6f))
                Spacer(Modifier.weight(1f))
                if (durationMs != null && durationMs > 0) {
                    Text("剩 ${EpisodePickerText.minutesLeft(positionMs, durationMs)} 分钟", style = McType.micro, color = Color.White.copy(alpha = 0.6f))
                }
            }
        }
    }
}

/** 其余各集：剧照 + 集号集名 + 状态；点一下就换（水波纹反馈）；缺集置灰点不动 */
@Composable
private fun EpisodeRow(episode: EpisodeView, imageOrigin: String?, guest: Boolean, onClick: () -> Unit) {
    val meta = EpisodePickerText.meta(episode)
    Row(
        Modifier
            .fillMaxWidth()
            .alpha(if (episode.owned) 1f else 0.36f)
            .clip(RoundedCornerShape(18.dp))
            .clickable(enabled = episode.owned, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 7.dp)
            .testTag("episode-${episode.episodeNumber}"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box {
            Still(episode, imageOrigin, guest, width = 96f, corner = 10f)
            EpisodePickerText.partial(episode)?.let { partial ->
                Box(
                    Modifier.align(Alignment.BottomCenter).padding(start = 5.dp, end = 5.dp, bottom = 4.dp)
                        .width(86.dp).height(3.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.32f)),
                ) {
                    Box(Modifier.fillMaxWidth(partial).fillMaxHeight().clip(CircleShape).background(Color.White))
                }
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            EpisodeTitle(episode, dimmed = episode.played, big = false)
            meta?.let { (text, done) ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (done) Icon(Icons.Rounded.Check, null, tint = Color.White.copy(alpha = 0.56f), modifier = Modifier.size(12.dp))
                    Text(text, style = McType.caption, color = Color.White.copy(alpha = 0.56f))
                }
            }
        }
    }
}

@Composable
private fun Still(episode: EpisodeView, imageOrigin: String?, guest: Boolean, width: Float, corner: Float) {
    val height = (width * 9f / 16f).toInt().toFloat()
    Box(Modifier.size(width.dp, height.dp).clip(RoundedCornerShape(corner.dp)).background(Color.White.copy(alpha = 0.08f))) {
        if (!episode.stillUrl.isNullOrEmpty()) {
            RemoteImage(episode.stillUrl, imageOrigin, Modifier.fillMaxSize(), aspect = 16f / 9f, guest = guest, fallback = {})
        }
    }
}

/** 灰色集号 + 集名；没有集名只写「第 N 集」 */
@Composable
private fun EpisodeTitle(episode: EpisodeView, dimmed: Boolean, big: Boolean) {
    val style = if (big) McType.headline else McType.subSemibold
    val name = episode.name?.takeIf { it.isNotEmpty() }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (name != null) {
            Text("${episode.episodeNumber}", style = style, color = Color.White.copy(alpha = 0.42f), maxLines = 1)
            Text(name, style = style, color = Color.White.copy(alpha = if (dimmed) 0.6f else 1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        } else {
            Text("第 ${episode.episodeNumber} 集", style = style, color = Color.White.copy(alpha = if (dimmed) 0.6f else 1f), maxLines = 1)
        }
    }
}
