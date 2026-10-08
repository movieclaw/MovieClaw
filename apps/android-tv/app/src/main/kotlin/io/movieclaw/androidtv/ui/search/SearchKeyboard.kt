package io.movieclaw.androidtv.ui.search

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.min
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt

/** 键盘的三档：字母、数字、符号（tvOS 的「123」「#+=」，切回字母的键写「ABC」） */
enum class KeyMode(val keys: List<String>, val switchLabel: String) {
    Letters(('a'..'z').map(Char::toString), "123"),
    Digits("1234567890".map(Char::toString), "#+="),
    Symbols(listOf("·", "'", "\"", ";", ":", "~", "=", "*", "+", "-", "_", ",", "。", "?", "!", "@", "#", "$", "%", "^", "&", "|", "/", "、", "(", ")", "【】", "{", "}", "《》"), "ABC"),
    ;

    val next: KeyMode get() = entries[(ordinal + 1) % entries.size]
}

/** 平时的字色：灰白；焦点所在的字键白底黑字 */
private val KeyText = Color.White.copy(alpha = 0.55f)
/** 功能键（123、空格）平时是一块浅灰底深字，焦点时反过来黑底白字、套白边（同 tvOS） */
private val FnFill = Color.White.copy(alpha = 0.5f)

/**
 * tvOS 搜索页的内嵌键盘（系统 `.searchable` 那一排）：「换输入法 · 切档 · 空格 · 一排字 · 删除」整排居中。
 * 尺寸照 tvOS 27 模拟器量的：字键一格 54，功能键 60 / 88 × 36，几样之间隔 24 / 30 / 28 / 26；
 * 字太多（符号档）时字键挤窄，整排不超出左右边距。
 */
@Composable
fun SearchKeyboard(
    mode: KeyMode,
    onKey: (String) -> Unit,
    onSpace: () -> Unit,
    onDelete: () -> Unit,
    onClear: () -> Unit,
    onSwitchMode: () -> Unit,
    onSystemInput: () -> Unit,
    modifier: Modifier = Modifier,
    firstKey: Modifier = Modifier,
) {
    val fixed = (40 + 24 + 60 + 30 + 88 + 28 + 26 + 44).pt
    val slot = min(54.pt, (1920.pt - 160.pt - fixed) / mode.keys.size)
    Row(modifier.fillMaxWidth().height(80.pt), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        IconKey(McIcons.Globe, "换输入法", 40.pt, 28.pt, onSystemInput)
        Spacer(Modifier.width(24.pt))
        FnKey(mode.switchLabel, 60.pt, onSwitchMode)
        Spacer(Modifier.width(30.pt))
        FnKey("空格", 88.pt, onSpace)
        Spacer(Modifier.width(28.pt))
        mode.keys.forEachIndexed { index, key ->
            CharKey(key, slot, if (index == 0) firstKey else Modifier) { onKey(key) }
        }
        Spacer(Modifier.width(26.pt))
        IconKey(McIcons.Backspace, "删除", 44.pt, 34.pt, onDelete, onLongClick = onClear)
    }
}

/** 一个字：平时只有灰白的字，焦点时 48×56 白底圆角、黑字 */
@Composable
private fun CharKey(text: String, slot: Dp, modifier: Modifier, onClick: () -> Unit) {
    Box(Modifier.width(slot).height(80.pt), contentAlignment = Alignment.Center) {
        Surface(
            onClick = onClick,
            modifier = modifier.size(minOf(48.pt, slot), 56.pt),
            shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(14.pt)),
            scale = ClickableSurfaceDefaults.scale(focusedScale = 1.12f, pressedScale = 1.04f),
            colors = ClickableSurfaceDefaults.colors(
                containerColor = Color.Transparent,
                contentColor = KeyText,
                focusedContainerColor = Color.White,
                focusedContentColor = Color.Black,
                pressedContainerColor = Color.White,
                pressedContentColor = Color.Black,
            ),
            glow = ClickableSurfaceDefaults.glow(),
        ) {
            Box(Modifier.size(minOf(48.pt, slot), 56.pt), contentAlignment = Alignment.Center) {
                Text(text, style = McType.size(if (text.length > 1) 22 else 38), maxLines = 1)
            }
        }
    }
}

/**
 * 功能键（123 / #+= / ABC、空格）：浅灰底小字，焦点黑底白字白边。
 * 焦点区与字键一样 56 高（底块只画 36）：高矮不一时上下找焦点会偏向更高的那颗，与 tvOS 落点不同
 */
@Composable
private fun FnKey(text: String, width: Dp, onClick: () -> Unit) {
    val shape = RoundedCornerShape(8.pt)
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    Surface(
        onClick = onClick,
        modifier = Modifier.size(width, 56.pt),
        interactionSource = interaction,
        shape = ClickableSurfaceDefaults.shape(shape),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.2f, pressedScale = 1.1f),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            focusedContainerColor = Color.Transparent,
            pressedContainerColor = Color.Transparent,
        ),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Box(Modifier.size(width, 56.pt), contentAlignment = Alignment.Center) {
            Box(
                Modifier
                    .size(width, 36.pt)
                    .background(if (focused) Color.Black else FnFill, shape)
                    .then(if (focused) Modifier.border(2.5.pt, Color.White, shape) else Modifier),
                contentAlignment = Alignment.Center,
            ) {
                Text(text, style = McType.size(18, FontWeight.Medium), color = if (focused) Color.White else Color.Black.copy(alpha = 0.6f), maxLines = 1)
            }
        }
    }
}

/** 图标键（换输入法、删除）：灰白图标，焦点白底黑图标 */
@Composable
private fun IconKey(icon: ImageVector, label: String, width: Dp, iconSize: Dp, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    Surface(
        onClick = onClick,
        onLongClick = onLongClick,
        modifier = Modifier.size(width, 56.pt),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(14.pt)),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.1f, pressedScale = 1.04f),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            contentColor = KeyText,
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
            pressedContainerColor = Color.White,
            pressedContentColor = Color.Black,
        ),
        glow = ClickableSurfaceDefaults.glow(),
    ) {
        Box(Modifier.size(width, 56.pt), contentAlignment = Alignment.Center) {
            Icon(icon, label, modifier = Modifier.size(iconSize))
        }
    }
}
