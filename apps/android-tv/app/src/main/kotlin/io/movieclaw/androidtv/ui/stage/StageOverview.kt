package io.movieclaw.androidtv.ui.stage

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Surface
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.components.layerFocus
import io.movieclaw.androidtv.ui.theme.pt

/** 简介焦点浅底往四周外扩多少（不占排版：接不接焦点，字的位置都不动） */
private val PlateX = 20.pt
private val PlateY = 14.pt

/**
 * 首屏的简介（TVOverviewButton，issue #1238）：给了 [onClick] 且字被截断时能接焦点，按确认看完整简介，
 * 同系统 Apple TV App、Infuse。没截断就只是一段字、不接焦点——全文都看得见，多一个停靠点只会让「往上」多按一下。
 * 首页不给 [onClick]，简介只是一段字。
 * 焦点样式同 tvOS：字底下垫一块半透明的圆角浅底、微微放大；浅底外扩到字的外面，排版只按字的大小算
 */
@Composable
internal fun StageOverview(
    text: String,
    lines: Int,
    style: TextStyle,
    color: Color,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    var overflow by remember(text, lines) { mutableStateOf(false) }
    val body = @Composable { inner: Modifier ->
        Text(
            text,
            style = style,
            color = color,
            maxLines = lines,
            overflow = TextOverflow.Ellipsis,
            onTextLayout = { overflow = it.hasVisualOverflow },
            modifier = inner.widthIn(max = 720.pt),
        )
    }
    if (onClick == null || !overflow) {
        body(Modifier)
        return
    }
    Surface(
        onClick = onClick,
        modifier = modifier
            .layerFocus()
            .testTag("overview")
            // 量的时候左右各多给浅底那一截，摆的时候往左上挪回去：外面一圈只画浅底，不占排版
            .layout { measurable, constraints ->
                val dx = PlateX.roundToPx()
                val dy = PlateY.roundToPx()
                val inner = if (constraints.hasBoundedWidth) constraints.copy(maxWidth = constraints.maxWidth + 2 * dx) else constraints
                val placeable = measurable.measure(inner.copy(minWidth = 0, minHeight = 0, maxHeight = Constraints.Infinity))
                layout(placeable.width - 2 * dx, placeable.height - 2 * dy) { placeable.place(-dx, -dy) }
            },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(18.pt)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.Transparent,
            contentColor = color,
            focusedContainerColor = Color.White.copy(alpha = 0.16f),
            focusedContentColor = color,
            pressedContainerColor = Color.White.copy(alpha = 0.12f),
            pressedContentColor = color,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.03f, pressedScale = 0.99f),
    ) {
        body(Modifier.padding(horizontal = PlateX, vertical = PlateY))
    }
}
