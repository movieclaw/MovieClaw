package io.movieclaw.androidtv.ui.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.text.withStyle
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import io.movieclaw.androidtv.core.model.generated.EpisodeView
import io.movieclaw.androidtv.ui.components.Avatar
import io.movieclaw.androidtv.ui.components.CardBadge
import io.movieclaw.androidtv.ui.components.FocusCard
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.ProgressStrip
import io.movieclaw.androidtv.ui.components.RemoteImage
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.components.layerFocus

/** 系统按钮的高度（tvOS 默认按钮：两台模拟器截图量出约 76 点、字约 29 点，同首页大图区按钮） */
private val ButtonHeight = 76.pt

/**
 * tvOS 默认样式的按钮（详情页的播放 / 从头播放、所属合集、海报墙的排序）：平时半透明白底白字，
 * 获得焦点白底黑字、微微放大、投影。[circle] 是只有图标的圆按钮（收藏、标为已看）。
 */
@Composable
internal fun PillButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    text: String? = null,
    icon: ImageVector? = null,
    circle: Boolean = false,
    extraPadding: Boolean = false,
    contentDescription: String? = null,
    height: Dp = ButtonHeight,
    iconSize: Dp = 28.pt,
    onFocus: (Boolean) -> Unit = {},
) {
    val shape = if (circle) CircleShape else RoundedCornerShape(50)
    Surface(
        onClick = onClick,
        modifier = modifier.layerFocus().height(height).then(if (circle) Modifier.width(height) else Modifier)
            .onFocusChanged { onFocus(it.isFocused) },
        shape = ClickableSurfaceDefaults.shape(shape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.White.copy(alpha = 0.16f),
            contentColor = Color.White,
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White.copy(alpha = 0.85f),
            pressedContentColor = Color.Black,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.06f, pressedScale = 1f),
        glow = ClickableSurfaceDefaults.glow(focusedGlow = Glow(Color.Black.copy(alpha = 0.45f), 20.pt)),
    ) {
        Row(
            // 只撑满高度：撑满宽度会让横排里的第一颗按钮吃掉整行
            Modifier.fillMaxHeight().then(if (circle) Modifier.fillMaxWidth() else Modifier).padding(horizontal = if (circle) 0.pt else (36 + if (extraPadding) 8 else 0).pt),
            horizontalArrangement = Arrangement.spacedBy(12.pt, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            icon?.let { Icon(it, contentDescription, modifier = Modifier.size(iconSize)) }
            text?.let { Text(it, style = McType.Body.copy(fontWeight = FontWeight.Medium), maxLines = 1) }
        }
    }
}

/** 季的胶囊（TVSeasonTabStyle）：28 半粗、内边 30/12；焦点白底黑字放大 1.08，选中的季垫白 20% 底 */
@Composable
internal fun SeasonTab(label: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        modifier = modifier.layerFocus(),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(50)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected) Color.White.copy(alpha = 0.2f) else Color.Transparent,
            contentColor = Color.White.copy(alpha = if (selected) 1f else 0.7f),
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White,
            pressedContentColor = Color.Black,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.08f, pressedScale = 1.08f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Text(label, style = McType.size(28, FontWeight.SemiBold), modifier = Modifier.padding(horizontal = 30.pt, vertical = 12.pt))
    }
}

/**
 * 一集（TVEpisodeCard）：剧照 416×234（左下片长或看到哪、进度条，看完的标「已看」）+ 第几集、集名、四行简介、首播日期。
 * 焦点效果只在剧照上；缺集整张 45% 不透明。
 */
@Composable
internal fun EpisodeCard(
    episode: EpisodeView,
    runtimeMinutes: Long?,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
    onFocus: (Boolean) -> Unit = {},
) {
    val width = McMetrics.LandscapeWidth
    val number = episode.episodeNumber
    Column(modifier.width(width).alpha(if (episode.owned) 1f else 0.45f), verticalArrangement = Arrangement.spacedBy(18.pt)) {
        FocusCard(onClick, Modifier.width(width).height(234.pt), onLongClick = onLongClick, onFocus = onFocus) {
            Box(Modifier.fillMaxSize()) {
                RemoteImage(episode.stillUrl, 416f, Modifier.fillMaxSize(), zoom = McMetrics.FocusZoom, placeholder = "第 $number 集")
                StillBand(episode, runtimeMinutes, Modifier.align(Alignment.BottomStart))
                if (episode.played) CardBadge("已看", Modifier.align(Alignment.TopStart))
            }
        }
        Column(Modifier.width(width), verticalArrangement = Arrangement.spacedBy(6.pt)) {
            Text("第 $number 集", style = McType.size(20, FontWeight.SemiBold), color = Color.White.copy(alpha = 0.6f))
            Text(episode.name ?: "第 $number 集", style = McType.size(26, FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                episode.overview.orEmpty(),
                style = McType.size(22),
                color = Color.White.copy(alpha = 0.78f),
                maxLines = 4,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.height(116.pt),
            )
            Text(
                if (episode.owned) episode.airDate?.take(10).orEmpty() else "缺集",
                style = McType.size(20),
                color = Color.White.copy(alpha = 0.55f),
            )
        }
    }
}

/** 剧照左下：▶ 片长（看了一半写「看到 m:ss」、压进度条） */
@Composable
private fun StillBand(episode: EpisodeView, runtimeMinutes: Long?, modifier: Modifier) {
    val inProgress = episode.positionMs > 0
    val text = DetailLogic.episodeBandText(episode, runtimeMinutes)
    if (text == null && !inProgress) return
    Column(
        modifier
            .fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f))))
            .padding(start = 16.pt, end = 16.pt, top = 36.pt, bottom = 14.pt),
        verticalArrangement = Arrangement.spacedBy(10.pt),
    ) {
        text?.let {
            Row(horizontalArrangement = Arrangement.spacedBy(8.pt), verticalAlignment = Alignment.CenterVertically) {
                Icon(McIcons.Play, null, tint = Color.White, modifier = Modifier.size(20.pt))
                Text(it, style = McType.size(20, FontWeight.SemiBold), color = Color.White)
            }
        }
        val percent = episode.progressPercent
        if (inProgress && percent != null) {
            ProgressStrip(percent / 100f, Modifier.fillMaxWidth(), track = Color.White.copy(alpha = 0.3f))
        }
    }
}

/**
 * 演职员一格（TVPersonCard）：圆头像 210 放在 236 宽的框里 + 姓名 + 身份。
 * 获得焦点时只有头像放大 1.12、套 6pt 白边（同「谁在看」），不浮方形底板。
 */
@Composable
internal fun PersonCard(person: CastPerson, onClick: () -> Unit, modifier: Modifier = Modifier, onFocus: (Boolean) -> Unit = {}) {
    var focused by remember { mutableStateOf(false) }
    Surface(
        onClick = onClick,
        modifier = modifier.layerFocus().width(236.pt).onFocusChanged { focused = it.isFocused; onFocus(it.isFocused) },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(0)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            contentColor = Color.White,
            focusedContainerColor = Color.Transparent,
            focusedContentColor = Color.White,
            pressedContainerColor = Color.Transparent,
            pressedContentColor = Color.White,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f, pressedScale = 0.98f),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.pt)) {
            Avatar(person.name, person.avatar, 210, focused = focused)
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.pt)) {
                Text(person.name, style = McType.size(24, FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                person.role?.let {
                    Text(it, style = McType.size(20), color = Color.White.copy(alpha = 0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

/** 首屏右下角的「导演  某某」「主演  某某、某某」：标签白 60%、人名白，24 中粗，投影托字 */
@Composable
internal fun StageCredits(director: String?, actors: List<String>, modifier: Modifier = Modifier) {
    if (director == null && actors.isEmpty()) return
    val style = McType.size(24, FontWeight.Medium).copy(shadow = Shadow(Color.Black.copy(alpha = 0.55f), blurRadius = 20f))
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.pt)) {
        director?.let { CreditLine("导演", listOf(it), style) }
        if (actors.isNotEmpty()) CreditLine("主演", actors, style)
    }
}

@Composable
private fun CreditLine(label: String, names: List<String>, style: androidx.compose.ui.text.TextStyle) {
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(color = Color.White.copy(alpha = 0.6f))) { append("$label  ") }
            withStyle(SpanStyle(color = Color.White)) { append(names.joinToString("、")) }
        },
        style = style,
        maxLines = 1,
    )
}
