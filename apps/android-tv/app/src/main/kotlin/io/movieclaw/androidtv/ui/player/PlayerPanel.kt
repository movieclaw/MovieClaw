package io.movieclaw.androidtv.ui.player

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.Icon
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import io.movieclaw.androidtv.core.playback.PlaybackController
import io.movieclaw.androidtv.core.playback.PlayerState
import io.movieclaw.androidtv.core.playback.QualityOption
import io.movieclaw.androidtv.core.playback.SubtitleSections
import io.movieclaw.androidtv.core.playback.TrackText
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** 面板的三栏（下键呼出） */
enum class PanelTab(val title: String) { Subtitles("字幕"), Audio("音轨"), Quality("画质") }

/**
 * 播放器的字幕 / 音轨 / 画质面板（Apple 端 TVPlayerPanel.swift，同 Netflix 电视版的「音频与字幕」）：
 * - 画面退后而不熄灭：整屏由中间向外渐暗（不磨砂），播放照常继续；
 * - 对称三栏竖排，左右换栏、上下选，每栏各自滚动（上下边缘渐隐）；
 * - 字幕按语言分组：关闭 → 正在使用 → 中文 → 英语 → 其他语言（多时折叠成一行，按确认展开）；
 * - 选了就切：直接在画面上看到效果，面板不关、不加提示。返回键收起面板（由播放器处理）。
 */
@Composable
fun PlayerPanel(state: PlayerState, controller: PlaybackController) {
    var expanded by remember { mutableStateOf(false) }
    // 「正在使用」按打开面板那一刻的字幕固定：面板开着时换字幕只挪对勾、不重排——否则焦点所在的行没了
    val pinned = remember { state.selectedSubtitle }
    val requesters = remember { HashMap<String, FocusRequester>() }
    fun requester(id: String) = requesters.getOrPut(id) { FocusRequester() }
    var focusedRow by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val tabs = PanelTab.entries.filter { it != PanelTab.Audio || state.audioOptions.isNotEmpty() }

    LaunchedEffect(Unit) {
        // 打开时焦点落在字幕栏已选中的那一项上（按一下返回就收起，不会误改）。刚出现时请求焦点可能落空，隔一会儿再补
        var waited = 0L
        for (at in longArrayOf(0, 120, 300, 600)) {
            delay(at - waited)
            waited = at
            if (focusedRow != null) return@LaunchedEffect
            val id = state.selectedSubtitle?.let { "subtitle-$it" } ?: "subtitle-off"
            if (runCatching { requester(id).requestFocus() }.isFailure) runCatching { requester("subtitle-off").requestFocus() }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .drawBehind {
                // 由中间向外渐暗：半径 150pt 以内黑 66%，到 1150pt 渐变为黑 38%
                val radius = 1150.pt.toPx()
                drawRect(
                    Brush.radialGradient(
                        0f to Color.Black.copy(alpha = 0.66f),
                        150f / 1150f to Color.Black.copy(alpha = 0.66f),
                        1f to Color.Black.copy(alpha = 0.38f),
                        center = center,
                        radius = radius,
                    ),
                )
            },
    ) {
        Row(
            Modifier.padding(start = 90.pt, end = 90.pt, top = 70.pt).height(690.pt).fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(60.pt),
        ) {
            for (tab in tabs) {
                val active = focusedRow?.startsWith(tab.prefix) == true
                val headerColor by animateColorAsState(if (active) Color.White else Color.White.copy(alpha = 0.45f), tween(200), label = "header")
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(18.pt)) {
                    Row(Modifier.padding(start = 28.pt), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(12.pt)) {
                        Text(tab.title, style = McType.size(32, FontWeight.Bold), color = headerColor, modifier = Modifier.alignByBaseline())
                        Text(
                            "${count(tab, state)}",
                            style = McType.size(22, FontWeight.Medium),
                            color = Color.White.copy(alpha = 0.4f),
                            modifier = Modifier.alignByBaseline(),
                        )
                    }
                    Box(
                        Modifier
                            .weight(1f)
                            .bleed(40.pt)
                            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
                            .drawWithContent {
                                drawContent()
                                // 上下边缘渐隐：提示还有内容（同 tvOS 的长列表）
                                drawRect(
                                    Brush.verticalGradient(
                                        0f to Color.Transparent, 0.04f to Color.Black, 0.9f to Color.Black, 1f to Color.Transparent,
                                    ),
                                    blendMode = BlendMode.DstIn,
                                )
                            }
                            .padding(horizontal = 40.pt),
                    ) {
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .verticalScroll(rememberScrollState())
                                .padding(horizontal = 6.pt, vertical = 14.pt),
                            verticalArrangement = Arrangement.spacedBy(4.pt),
                        ) {
                            val row = @Composable { id: String, title: String, detail: String?, isActive: Boolean, disabled: Boolean, onClick: () -> Unit ->
                                PanelOption(
                                    title, detail, isActive, disabled, wraps = id.startsWith("subtitle-"), onClick = onClick,
                                    modifier = Modifier
                                        .focusRequester(requester(id))
                                        .onFocusChanged { if (it.isFocused) focusedRow = id else if (focusedRow == id) focusedRow = null },
                                )
                            }
                            when (tab) {
                                PanelTab.Subtitles -> for (section in SubtitleSections.build(state.subtitles, pinned, state.selectedSubtitle, expanded)) {
                                    section.title?.let {
                                        Text(
                                            it,
                                            style = McType.size(20, FontWeight.Bold),
                                            color = Color.White.copy(alpha = 0.4f),
                                            modifier = Modifier.padding(start = 28.pt, top = 16.pt, bottom = 2.pt),
                                        )
                                    }
                                    for (item in section.rows) {
                                        when (item) {
                                            SubtitleSections.Row.Off ->
                                                row("subtitle-off", "关闭", null, state.selectedSubtitle == null, false) { controller.selectSubtitle(null) }
                                            is SubtitleSections.Row.Option -> row(
                                                "subtitle-${item.option.ref}", item.option.displayTitle, item.option.detail,
                                                state.selectedSubtitle == item.option.ref, false,
                                            ) { controller.selectSubtitle(item.option.ref) }
                                            is SubtitleSections.Row.Unavailable ->
                                                row("subtitle-x-${item.item.ref}", item.item.label, item.item.reason, false, true) {}
                                            is SubtitleSections.Row.More -> row("subtitle-more", "展开其他 ${item.count} 条字幕", item.names, false, false) {
                                                expanded = true
                                                // 展开后焦点挪到其他语言的第一条（「展开」这一行没了，焦点不能悬空）
                                                scope.launch {
                                                    delay(80)
                                                    SubtitleSections.firstOther(state.subtitles, pinned)?.let { first ->
                                                        runCatching { requester("subtitle-${first.ref}").requestFocus() }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                PanelTab.Audio -> for (item in state.audioOptions) {
                                    val active = item.ref == state.currentAudio || (state.currentAudio == null && item.isDefault)
                                    val (title, rest) = TrackText.split(item.label)
                                    val detail = listOfNotNull(rest, if (item.isDefault) "默认" else null, item.unavailableReason).joinToString(" · ")
                                    row("audio-${item.ref}", title, detail, active, item.unavailableReason != null) { controller.selectAudio(item.ref) }
                                }
                                PanelTab.Quality -> for (item in QualityOption.ALL) {
                                    row("quality-${item.label}", item.label, item.hint, state.quality == item.maxHeight, false) {
                                        controller.selectQuality(item.maxHeight)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private val PanelTab.prefix: String
    get() = when (this) {
        PanelTab.Subtitles -> "subtitle-"
        PanelTab.Audio -> "audio-"
        PanelTab.Quality -> "quality-"
    }

private fun count(tab: PanelTab, state: PlayerState): Int = when (tab) {
    PanelTab.Subtitles -> state.subtitleCount
    PanelTab.Audio -> state.audioOptions.size
    PanelTab.Quality -> QualityOption.ALL.size
}

/** 让渐隐蒙版左右各宽出 [amount]：拿焦点的行放大、投影时不被栏宽裁掉（同 Apple 端蒙版的 -40 内边距） */
private fun Modifier.bleed(amount: Dp): Modifier = layout { measurable, constraints ->
    val extra = amount.roundToPx() * 2
    val placeable = measurable.measure(
        constraints.copy(
            minWidth = constraints.minWidth + extra,
            maxWidth = if (constraints.hasBoundedWidth) constraints.maxWidth + extra else constraints.maxWidth,
        ),
    )
    layout(placeable.width - extra, placeable.height) { placeable.place(-extra / 2, 0) }
}

/**
 * 面板选项：获得焦点时一块半透明的玻璃胶囊（不反白——压暗的画面上更安静），略微放大。
 * 对勾 22 粗 #FFD478、宽 26；标题 30 半粗、说明 21（60%）；字幕行可换行，其余一行。
 */
@Composable
private fun PanelOption(
    title: String,
    detail: String?,
    active: Boolean,
    disabled: Boolean,
    wraps: Boolean,
    onClick: () -> Unit,
    modifier: Modifier,
) {
    val shape = RoundedCornerShape(22.pt)
    Surface(
        onClick = onClick,
        enabled = !disabled,
        modifier = modifier.fillMaxWidth().focusProperties { canFocus = !disabled },
        shape = ClickableSurfaceDefaults.shape(shape),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.04f, pressedScale = 0.98f),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            contentColor = Color.White,
            focusedContainerColor = Color.White.copy(alpha = 0.17f),
            focusedContentColor = Color.White,
            pressedContainerColor = Color.White.copy(alpha = 0.17f),
            pressedContentColor = Color.White,
            disabledContainerColor = Color.Transparent,
            disabledContentColor = Color.White.copy(alpha = 0.38f),
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(BorderStroke(1.pt, Color.White.copy(alpha = 0.22f)), shape = shape),
        ),
        glow = ClickableSurfaceDefaults.glow(focusedGlow = Glow(Color.Black.copy(alpha = 0.35f), 16.pt)),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 22.pt, vertical = 13.pt),
            horizontalArrangement = Arrangement.spacedBy(14.pt),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.width(26.pt), contentAlignment = Alignment.Center) {
                Icon(McIcons.Check, null, tint = McColors.Check, modifier = Modifier.size(26.pt).alpha(if (active) 1f else 0f))
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.pt)) {
                Text(
                    title,
                    style = McType.size(30, FontWeight.SemiBold),
                    maxLines = if (wraps) Int.MAX_VALUE else 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (!detail.isNullOrEmpty()) {
                    Text(
                        detail,
                        style = McType.size(21),
                        color = LocalContentColor.current.copy(alpha = LocalContentColor.current.alpha * 0.6f),
                        maxLines = if (wraps) Int.MAX_VALUE else 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}
