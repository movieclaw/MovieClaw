package io.movieclaw.android.feature.player

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.core.playback.PlaybackSpeeds
import io.movieclaw.core.playback.QualityOption

/** ⋮ 面板的页：一级（画质 / 倍速 / 播放诊断），或进了哪一项的二级 */
private enum class SettingsPage { Root, Quality, Speed }

/**
 * 播放器的 ⋮ 设置面板（docs/design/playback-speed.md）：横屏从右侧滑出、占满高度，同 B 站 / 腾讯视频等的横屏侧边栏——
 * 不挡画面中央，右手拇指够得着。结构与 iPhone 的 ⋯ 菜单一致：一级每项行尾写着当前值，点进二级选，选了就收起；
 * 二级左上「←」或返回键回到一级。点面板外面收起。
 */
@Composable
internal fun PlayerSettingsPanel(
    visible: Boolean,
    /** 当前画质上限（null = 原画） */
    quality: Int?,
    /** 服务端的判据原文：档位标签只说得清「结果」，这一行是排「为什么在转码」的入口 */
    qualityReason: String,
    /** 访客分享不能选画质（服务端按分享的设定给流） */
    canPickQuality: Boolean,
    speed: Float,
    diagnosticsOpen: Boolean,
    onSelectQuality: (Int?) -> Unit,
    onSelectSpeed: (Float) -> Unit,
    onToggleDiagnostics: () -> Unit,
    onDismiss: () -> Unit,
) {
    var page by rememberSaveable { mutableStateOf(SettingsPage.Root) }
    BackHandler(enabled = visible) {
        if (page == SettingsPage.Root) onDismiss() else page = SettingsPage.Root
    }
    Box(Modifier.fillMaxSize()) {
        if (visible) {
            // 点面板外面收起（不出波纹）
            Box(
                Modifier
                    .fillMaxSize()
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
            )
        }
        AnimatedVisibility(
            visible = visible,
            enter = slideInHorizontally { it } + fadeIn(),
            exit = slideOutHorizontally { it } + fadeOut(),
            modifier = Modifier.align(Alignment.CenterEnd),
        ) {
            Column(
                Modifier
                    .width(300.dp)
                    .fillMaxHeight()
                    .background(Color(0xE610121A))
                    // 吞掉面板上的点按，别漏到下面的「点外面收起」
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                    .padding(horizontal = 12.dp, vertical = 20.dp)
                    .testTag("player-settings-panel"),
            ) {
                AnimatedContent(
                    targetState = page,
                    transitionSpec = {
                        val forward = targetState != SettingsPage.Root
                        (slideInHorizontally { if (forward) it else -it } + fadeIn()) togetherWith
                            (slideOutHorizontally { if (forward) -it else it } + fadeOut())
                    },
                    label = "settings-page",
                ) { current ->
                    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
                        when (current) {
                            SettingsPage.Root -> {
                                if (canPickQuality) {
                                    EntryRow("画质", QualityOption.ALL.firstOrNull { it.maxHeight == quality }?.label ?: "原画", "settings-quality") {
                                        page = SettingsPage.Quality
                                    }
                                }
                                EntryRow("倍速", PlaybackSpeeds.label(speed), "settings-speed") { page = SettingsPage.Speed }
                                HorizontalDivider(color = LineColor, modifier = Modifier.padding(vertical = 6.dp))
                                ToggleRow("播放诊断", diagnosticsOpen, "settings-diagnostics") {
                                    onToggleDiagnostics()
                                    onDismiss()
                                }
                            }
                            SettingsPage.Quality -> {
                                PageHeader("画质") { page = SettingsPage.Root }
                                QualityOption.ALL.forEach { option ->
                                    OptionRow(option.label, option.hint, option.maxHeight == quality, "quality-${option.label}") {
                                        if (option.maxHeight != quality) onSelectQuality(option.maxHeight)
                                        onDismiss()
                                    }
                                }
                                if (qualityReason.isNotBlank()) {
                                    HorizontalDivider(color = LineColor, modifier = Modifier.padding(vertical = 6.dp))
                                    Text(
                                        qualityReason,
                                        style = McType.caption2,
                                        color = TextFaint,
                                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                    )
                                }
                            }
                            SettingsPage.Speed -> {
                                PageHeader("倍速") { page = SettingsPage.Root }
                                PlaybackSpeeds.ALL.forEach { value ->
                                    OptionRow(PlaybackSpeeds.label(value), null, value == speed, "speed-${PlaybackSpeeds.short(value)}") {
                                        if (value != speed) onSelectSpeed(value)
                                        onDismiss()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    // 收起后下次打开从一级起
    if (!visible && page != SettingsPage.Root) page = SettingsPage.Root
}

/** 一级行：名称 + 当前值 + 「›」 */
@Composable
private fun EntryRow(title: String, value: String, tag: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp)
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = McType.subheadline, color = Color.White, modifier = Modifier.weight(1f))
        Text(value, style = McType.subheadline, color = Color.White.copy(alpha = 0.55f))
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = Color.White.copy(alpha = 0.35f))
    }
}

/** 一级的开关行：与上面几行同一条左缘，开着时行尾打勾 */
@Composable
private fun ToggleRow(title: String, on: Boolean, tag: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp)
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = McType.subheadline, color = Color.White, modifier = Modifier.weight(1f))
        Icon(Icons.Rounded.Check, contentDescription = null, tint = Accent, modifier = Modifier.size(18.dp).alpha(if (on) 1f else 0f))
    }
}

/** 二级页头：「← 画质」，点它回到一级 */
@Composable
private fun PageHeader(title: String, onBack: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(onClick = onBack)
            .padding(horizontal = 8.dp)
            .testTag("settings-back"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回", tint = Color.White.copy(alpha = 0.75f), modifier = Modifier.size(20.dp))
        Text(title, style = McType.footnote, color = Color.White.copy(alpha = 0.75f))
    }
}

/** 选项行：行首对勾表示当前项（当前项字也提亮），可带一行说明 */
@Composable
private fun OptionRow(title: String, hint: String?, active: Boolean, tag: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Rounded.Check,
            contentDescription = null,
            tint = Accent,
            modifier = Modifier.size(18.dp).alpha(if (active) 1f else 0f),
        )
        Spacer(Modifier.width(10.dp))
        Column {
            Text(title, style = McType.subheadline, color = if (active) Accent else Color.White)
            if (hint != null) Text(hint, style = McType.caption2, color = TextFaint)
        }
    }
}
