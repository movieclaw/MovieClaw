package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary

/**
 * 有序列表 + **长按拖动排序**（iOS `SettingsBScrapeOrderChips` 的交互）：
 * 顺序就是优先级，第一项带「主 / 首选」标记；松手时才提交一次，拖动过程不发请求。
 *
 * 手感细节：
 * - `detectDragGesturesAfterLongPress`：长按之后才接管，普通滑动仍然滚页面；
 * - 每行用 `key(code)` 固定身份，换位时正在拖的那一行不会被重建，手势不会断；
 * - 越过半行高度就与相邻项交换，同时把位移扣掉一行，行会"跟手"。
 */
@Composable
fun DragReorderList(
    items: List<String>,
    label: (String) -> String,
    primaryTag: String = "",
    onOrder: (List<String>) -> Unit,
    onRemove: ((String) -> Unit)? = null,
) {
    if (items.isEmpty()) {
        Text("未选择", style = McType.caption, color = TextFaint)
        return
    }
    val order: SnapshotStateList<String> = remember { items.toMutableStateList() }
    val dragCode = remember { mutableStateOf<String?>(null) }
    val dragIndex = remember { mutableIntStateOf(-1) }
    val dragOffset = remember { mutableFloatStateOf(0f) }
    val dragStart = remember { mutableStateOf<List<String>>(emptyList()) }

    // 外部数据刷新（保存回来）时同步；拖动中不打断
    LaunchedEffect(items) {
        if (dragIndex.intValue < 0 && order.toList() != items) {
            order.clear()
            order.addAll(items)
        }
    }

    val rowHeight = 44.dp
    val hPx = with(LocalDensity.current) { rowHeight.toPx() }

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        order.forEach { code ->
            key(code) {
                val index = order.indexOf(code)
                val dragging = dragCode.value == code
                Row(
                    Modifier
                        .fillMaxWidth()
                        .height(rowHeight)
                        .zIndex(if (dragging) 1f else 0f)
                        .graphicsLayer { translationY = if (dragging) dragOffset.floatValue else 0f }
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (dragging) Accent.copy(alpha = 0.26f) else Accent.copy(alpha = 0.12f))
                        .pointerInput(Unit) {
                            detectDragGesturesAfterLongPress(
                                onDragStart = {
                                    dragCode.value = code
                                    dragIndex.intValue = order.indexOf(code)
                                    dragOffset.floatValue = 0f
                                    dragStart.value = order.toList()
                                },
                                onDrag = { change, delta ->
                                    change.consume()
                                    dragOffset.floatValue += delta.y
                                    var i = order.indexOf(code)
                                    if (i < 0) return@detectDragGesturesAfterLongPress
                                    while (dragOffset.floatValue > hPx * 0.5f && i < order.lastIndex) {
                                        order[i] = order[i + 1]
                                        order[i + 1] = code
                                        dragOffset.floatValue -= hPx
                                        i += 1
                                    }
                                    while (dragOffset.floatValue < -hPx * 0.5f && i > 0) {
                                        order[i] = order[i - 1]
                                        order[i - 1] = code
                                        dragOffset.floatValue += hPx
                                        i -= 1
                                    }
                                },
                                onDragEnd = {
                                    val changed = order.toList() != dragStart.value
                                    dragCode.value = null
                                    dragIndex.intValue = -1
                                    dragOffset.floatValue = 0f
                                    if (changed) onOrder(order.toList())
                                },
                                onDragCancel = {
                                    // 取消拖拽要把中途交换过的顺序还原，否则界面与已保存值不一致
                                    order.clear()
                                    order.addAll(dragStart.value)
                                    dragCode.value = null
                                    dragIndex.intValue = -1
                                    dragOffset.floatValue = 0f
                                },
                            )
                        }
                        .padding(start = 8.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier.clip(RoundedCornerShape(999.dp)).background(Accent)
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    ) { Text("${index + 1}", style = McType.caption, color = Color(0xFF141821)) }
                    Spacer(Modifier.width(8.dp))
                    Text(
                        label(code), style = McType.caption, color = TextPrimary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                    )
                    if (index == 0 && primaryTag.isNotEmpty()) {
                        Text(primaryTag, style = McType.caption, color = TextFaint)
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(
                        "≡", style = McType.caption, color = TextMuted,
                        modifier = Modifier.padding(horizontal = 8.dp),
                    )
                    if (onRemove != null) {
                        Box(
                            Modifier.size(34.dp)
                                .clip(RoundedCornerShape(999.dp))
                                .clickable(
                                    interactionSource = remember { MutableInteractionSource() },
                                    indication = null,
                                ) { onRemove(code) },
                            contentAlignment = Alignment.Center,
                        ) { Text("×", style = McType.caption, color = TextMuted) }
                    }
                }
            }
        }
    }
    Text(
        "长按一行上下拖动排序，越靠上越优先。",
        style = McType.caption, color = TextFaint, modifier = Modifier.padding(top = 6.dp),
    )
}
