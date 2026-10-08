package io.movieclaw.androidtv.ui.player

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Glow
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import io.movieclaw.androidtv.core.model.generated.EpisodeView
import io.movieclaw.androidtv.core.model.generated.PlaybackDecisionView
import io.movieclaw.androidtv.core.model.generated.PlaybackSegmentView
import io.movieclaw.androidtv.core.playback.Phase
import io.movieclaw.androidtv.core.playback.PlayerFormat
import io.movieclaw.androidtv.core.playback.QualitySuggestion
import io.movieclaw.androidtv.core.playback.SkipSegments
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.RemoteImage
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.theme.ptSp
import kotlinx.coroutines.launch

// 播放器上的浮层（Apple 端 TVPlayerOverlays.swift）：转圈、提示、暂停片名、跳过 / 下一集 / 换画质建议、出错与需要转码的对话框。

/** 起播 / 缓冲转圈：说清楚卡在哪一段，下面一行实时加载速度 */
@Composable
fun BusyView(phase: Phase, speed: String?) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.pt)) {
        // tvOS ProgressView 放大 1.6 倍
        Spinner(sizePt = 96)
        Text(phase.busyLabel, style = McType.Headline, color = Color.White.copy(alpha = 0.8f))
        if (speed != null) {
            Text("↓ $speed", style = McType.Callout.copy(fontFeatureSettings = "tnum"), color = Color.White.copy(alpha = 0.5f))
        }
    }
}

/** 顶部的一句话提示（换轨、降档、网络提示） */
@Composable
fun NoticeCapsule(text: String) {
    Text(
        text,
        style = McType.Callout.copy(fontWeight = FontWeight.Medium),
        color = Color.White,
        modifier = Modifier
            .glassPanel(RoundedCornerShape(50))
            .padding(horizontal = 28.pt, vertical = 14.pt),
    )
}

/** 暂停时左上角的片名 */
@Composable
fun PausedTitle(title: String, episodeLabel: String?, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.pt)) {
        Text(
            "已暂停",
            style = McType.Caption.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 4.ptSp),
            color = Color.White.copy(alpha = 0.6f),
        )
        Text(
            title,
            // tvOS 的 largeTitle 在模拟器上实测约 62（不是文档里的 76）
            style = McType.size(62, FontWeight.Bold).copy(shadow = Shadow(Color.Black.copy(alpha = 0.5f), blurRadius = 16f)),
            color = Color.White,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (episodeLabel != null) {
            Text(episodeLabel, style = McType.Title3, color = Color.White.copy(alpha = 0.75f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** 「跳过片头 / 片尾」：出现时自动拿焦点，按一下跳到这一段结束处 */
@Composable
fun SkipButton(segment: PlaybackSegmentView, onClick: () -> Unit, modifier: Modifier = Modifier) {
    GlassButton(onClick, modifier) {
        Row(
            // 整颗 88 高（tvOS 量出）：Noto 行框高，上下内边距比 Apple 的 4 + 18 少一截
            Modifier.padding(horizontal = (12 + 28).pt, vertical = 16.pt),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.pt),
        ) {
            Icon(McIcons.SkipForward, null, modifier = Modifier.size(38.pt))
            Text(SkipSegments.label(segment), style = McType.Headline)
        }
    }
}

/** 片尾「下一集」卡片：剧照 + 集数集名；认出了片尾时卡片底边是倒计时进度，走满自动换集 */
@Composable
fun UpNextCard(episode: EpisodeView, countdown: Double?, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(20.pt)
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = ClickableSurfaceDefaults.shape(shape),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.06f, pressedScale = 1f),
        // tvOS 的玻璃卡透出后面的画面：平时白 20%，焦点白 32%（不做背后模糊）
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.White.copy(alpha = 0.2f),
            contentColor = Color.White,
            focusedContainerColor = Color.White.copy(alpha = 0.32f),
            focusedContentColor = Color.White,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(BorderStroke(1.pt, Color.White.copy(alpha = 0.4f)), shape = shape),
        ),
        glow = ClickableSurfaceDefaults.glow(focusedGlow = Glow(Color.Black.copy(alpha = 0.6f), 18.pt)),
    ) {
        Row(Modifier.padding(20.pt), horizontalArrangement = Arrangement.spacedBy(24.pt), verticalAlignment = Alignment.CenterVertically) {
            RemoteImage(
                episode.stillUrl,
                widthPt = STILL_WIDTH.toFloat(),
                modifier = Modifier.width(STILL_WIDTH.pt).height((STILL_WIDTH * 9 / 16).pt).clip(RoundedCornerShape(12.pt)),
            )
            Column(Modifier.width(300.pt), verticalArrangement = Arrangement.spacedBy(8.pt)) {
                Text(
                    if (countdown == null) "下一集" else "即将播放",
                    style = McType.Caption.copy(fontWeight = FontWeight.SemiBold),
                    color = McColors.Secondary,
                )
                Text("第 ${episode.episodeNumber} 集", style = McType.Headline)
                val name = episode.name
                if (!name.isNullOrEmpty()) {
                    Text(name, style = McType.Callout, color = McColors.Secondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        if (countdown != null) {
            // 贴着卡片内边（左右 20、底 8），不撑大卡片
            Box(Modifier.matchParentSize().padding(start = 20.pt, end = 20.pt, bottom = 8.pt), contentAlignment = Alignment.BottomStart) {
                Box(Modifier.fillMaxWidth(countdown.toFloat().coerceIn(0f, 1f)).height(6.pt).background(Color.White, RoundedCornerShape(50)))
            }
        }
    }
}

private const val STILL_WIDTH = 256

/** 网速跟不上时的换画质建议 */
@Composable
fun QualityOfferCard(
    offer: QualitySuggestion.Offer,
    onAccept: () -> Unit,
    onDismiss: () -> Unit,
    acceptFocus: FocusRequester,
    modifier: Modifier = Modifier,
    buttonModifier: Modifier = Modifier,
) {
    val measured = PlayerFormat.bandwidth(offer.measuredBps) ?: "很慢"
    val required = PlayerFormat.bandwidth(offer.requiredBps) ?: "更快"
    Column(
        modifier.width(640.pt).glassPanel(RoundedCornerShape(32.pt)).padding(32.pt),
        verticalArrangement = Arrangement.spacedBy(18.pt),
    ) {
        Text("网速跟不上当前画质", style = McType.Headline)
        Text(
            "实测约 $measured，这一版需要约 $required。可以暂停攒一会缓冲再看，或改用 ${offer.maxHeight}p（服务端转码，画质会降低）。",
            style = McType.Callout,
            color = McColors.Secondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(20.pt)) {
            PlayerButton("改用 ${offer.maxHeight}p", onAccept, buttonModifier.focusRequester(acceptFocus))
            PlayerButton("继续当前画质", onDismiss, buttonModifier)
        }
    }
}

/** 出错 / 无法播放：后端中文原因 + 建议 + 按钮（焦点落在主按钮上） */
@Composable
fun PlayerDialog(
    title: String,
    message: String?,
    primary: Pair<String, () -> Unit>,
    secondary: Pair<String, () -> Unit>?,
    primaryFocus: FocusRequester,
) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.85f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier.widthIn(max = 1000.pt),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(28.pt),
        ) {
            Icon(McIcons.WarningOutline, null, tint = McColors.Warning, modifier = Modifier.size(64.pt))
            Text(title, style = McType.Title3.copy(fontWeight = FontWeight.SemiBold), textAlign = TextAlign.Center)
            if (message != null) {
                Text(message, style = McType.Callout, color = McColors.Secondary, textAlign = TextAlign.Center)
            }
            Row(Modifier.padding(top = 10.pt), horizontalArrangement = Arrangement.spacedBy(30.pt)) {
                PlayerButton(primary.first, primary.second, Modifier.focusRequester(primaryFocus))
                secondary?.let { PlayerButton(it.first, it.second) }
            }
        }
    }
}

/** 需要服务端软件转码才能放：说明原因与代价，能自行开启的给「开启并播放」。电视上没有设置页，不给「去设置」 */
@Composable
fun ConsentDialog(decision: PlaybackDecisionView, grant: suspend () -> Unit, cancel: () -> Unit, primaryFocus: FocusRequester) {
    val scope = rememberCoroutineScope()
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.85f)), contentAlignment = Alignment.Center) {
        Column(Modifier.widthIn(max = 1000.pt), verticalArrangement = Arrangement.spacedBy(24.pt)) {
            Text("这部片需要软件转码才能播放", style = McType.Title3.copy(fontWeight = FontWeight.SemiBold))
            Labeled("原因", decision.reason)
            decision.costHint?.let { Labeled("代价", it) }
            error?.let { Text(it, style = McType.Callout, color = McColors.Danger) }
            val selfEnable = decision.canSelfEnable == true
            if (!selfEnable) {
                Text(
                    "当前未开启软件转码。请联系管理员开启（管理员播放此类影片时会收到开启询问）。",
                    style = McType.Callout,
                    color = McColors.Secondary,
                )
            }
            Row(Modifier.padding(top = 10.pt), horizontalArrangement = Arrangement.spacedBy(30.pt)) {
                if (selfEnable) {
                    PlayerButton(
                        if (saving) "正在开启…" else "开启并播放",
                        onClick = {
                            if (saving) return@PlayerButton
                            saving = true
                            error = null
                            scope.launch {
                                try {
                                    grant()
                                } catch (e: Exception) {
                                    error = e.message ?: "开启失败"
                                    saving = false
                                }
                            }
                        },
                        modifier = Modifier.focusRequester(primaryFocus),
                    )
                    PlayerButton("取消", cancel)
                } else {
                    PlayerButton("知道了", cancel, Modifier.focusRequester(primaryFocus))
                }
            }
        }
    }
}

@Composable
private fun Labeled(title: String, text: String) {
    Column(verticalArrangement = Arrangement.spacedBy(6.pt)) {
        Text(title, style = McType.Caption, color = McColors.Secondary)
        Text(text, style = McType.Callout)
    }
}

/** tvOS 默认按钮：平时半透明白底白字，拿到焦点变白底黑字并略放大 */
@Composable
fun PlayerButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(16.pt)
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = ClickableSurfaceDefaults.shape(shape),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.08f),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.White.copy(alpha = 0.12f),
            contentColor = Color.White,
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White.copy(alpha = 0.85f),
            pressedContentColor = Color.Black,
        ),
        glow = ClickableSurfaceDefaults.glow(focusedGlow = Glow(Color.Black.copy(alpha = 0.4f), 12.pt)),
    ) {
        Text(text, style = McType.Headline.copy(fontWeight = FontWeight.Medium), modifier = Modifier.padding(horizontal = 40.pt, vertical = 20.pt))
    }
}

/** tvOS 26 `.buttonStyle(.glass)`：平时是半透明玻璃，拿到焦点变亮白、略放大 */
@Composable
fun GlassButton(onClick: () -> Unit, modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val shape = RoundedCornerShape(50)
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = ClickableSurfaceDefaults.shape(shape),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.08f),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.White.copy(alpha = 0.14f),
            contentColor = Color.White,
            // 焦点时的玻璃也透一点画面（tvOS 上是被画面染了色的亮白）
            focusedContainerColor = Color.White.copy(alpha = 0.85f),
            focusedContentColor = Color.Black,
        ),
        border = ClickableSurfaceDefaults.border(
            border = Border(BorderStroke(1.pt, Color.White.copy(alpha = 0.2f)), shape = shape),
        ),
        glow = ClickableSurfaceDefaults.glow(focusedGlow = Glow(Color.Black.copy(alpha = 0.4f), 14.pt)),
        content = content,
    )
}

/** 浮层玻璃（提示胶囊、换画质卡）：电视上不做实时背景模糊，用深色半透明 + 细边近似 */
fun Modifier.glassPanel(shape: Shape): Modifier = this
    .background(Color(0xFF1E2028).copy(alpha = 0.78f), shape)
    .border(1.pt, Color.White.copy(alpha = 0.16f), shape)
