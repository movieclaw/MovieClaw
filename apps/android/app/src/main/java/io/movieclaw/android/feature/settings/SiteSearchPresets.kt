package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.FeedbackBus
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.ConfiguredSite
import io.movieclaw.android.core.model.SearchTabView
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import java.util.UUID
import io.movieclaw.android.core.designsystem.formSheetScroll

/*
 * 资源站点 → 搜索分类（同 Web `search-settings.tsx`）：
 * 内置分类与自定义「分类组合 × 站点组合」统一混排；长按 ≡ 拖动排序、开关即时保存、
 * 自定义分类可新建/编辑/删除（整体覆盖 PUT /search/presets，失败回滚）。
 */

@Composable
internal fun SitesPageTabs(selected: String, onSelect: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 2.dp)) {
        listOf("sites" to "站点接入", "search" to "搜索分类").forEach { (key, label) ->
            val active = selected == key
            Column(
                Modifier.weight(1f).clickable { onSelect(key) }.padding(top = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(label, style = McType.bodyMedium, color = if (active) TextPrimary else TextMuted)
                Spacer(Modifier.height(7.dp))
                Box(Modifier.fillMaxWidth().height(2.dp).background(if (active) Accent else Color.Transparent))
            }
        }
    }
}

private val SEARCH_CATEGORY_LABELS = listOf(
    "movie" to "电影",
    "tv" to "剧集",
    "documentary" to "纪录片",
    "anime" to "动漫",
    "music" to "音乐",
    "game" to "游戏",
    "av" to "成人",
    "other" to "其他",
)

internal fun SearchTabView.toSearchTabJson(): JsonObject = buildJsonObject {
    put("type", JsonPrimitive(type))
    put("id", JsonPrimitive(id))
    put("visible", JsonPrimitive(visible))
    if (type == "preset") {
        put("name", JsonPrimitive(name.orEmpty()))
        put("categories", JsonArray(categories.map { JsonPrimitive(it) }))
        put("site_ids", JsonArray(siteIds.map { JsonPrimitive(it) }))
        put("poster_mode", JsonPrimitive(posterMode))
        put("skip_history", JsonPrimitive(skipHistory))
    }
}

private fun searchTabLabel(tab: SearchTabView): String =
    if (tab.type == "category") {
        SEARCH_CATEGORY_LABELS.firstOrNull { it.first == tab.id }?.second ?: tab.id
    } else {
        tab.name.orEmpty()
    }

private fun searchTabSummary(tab: SearchTabView): String? {
    if (tab.type != "preset") return null
    val cats = if (tab.categories.isEmpty()) "不限分类"
    else tab.categories
        .mapNotNull { id -> SEARCH_CATEGORY_LABELS.firstOrNull { it.first == id }?.second }
        .joinToString("、")
        .ifBlank { "不限分类" }
    val sites = if (tab.siteIds.isEmpty()) "全部站点" else "${tab.siteIds.size} 个站点"
    val flags = (if (tab.posterMode) " · 图览" else "") + (if (tab.skipHistory) " · 无痕" else "")
    return "$cats · $sites$flags"
}

/**
 * 搜索分类列表：内置与自定义统一混排。长按左侧 «≡» 拖动排序，开关即时保存。
 * 列在长按后开始拖动，跨过半行即与相邻行交换（行高固定，算法与网页端拖拽同口径）。
 */
@Composable
internal fun SearchPresetsSection(
    tabs: List<SearchTabView>,
    sites: List<ConfiguredSite>,
    nameOf: (String) -> String,
    loading: Boolean,
    busy: Boolean,
    error: String?,
    feedback: FeedbackBus,
    onChange: (List<SearchTabView>) -> Unit,
    onReload: () -> Unit,
) {
    val local = remember(tabs) { tabs.toMutableStateList() }
    var creating by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<SearchTabView?>(null) }
    var deleting by remember { mutableStateOf<SearchTabView?>(null) }
    val rowHeight = 64.dp
    val rowPx = with(LocalDensity.current) { rowHeight.toPx() }
    var dragIndex by remember { mutableStateOf<Int?>(null) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    var dragStart by remember { mutableStateOf<List<SearchTabView>>(emptyList()) }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("搜索分类", style = McType.title3, color = TextPrimary)
                Spacer(Modifier.height(3.dp))
                Text(
                    if (local.none { it.type == "preset" }) "搜索面板分类栏的内置与自定义分类，顺序即展示顺序"
                    else "${local.count { it.type == "preset" }} 个自定义分类",
                    style = McType.footnote, color = TextMuted,
                )
            }
            Text(
                "+ 新建自定义分类", style = McType.caption, color = Accent,
                modifier = Modifier.clip(RoundedCornerShape(999.dp))
                    .background(Color.White.copy(alpha = 0.06f))
                    .clickable(enabled = !busy) { creating = true }
                    .padding(horizontal = 12.dp, vertical = 7.dp),
            )
        }
        error?.let {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(it, style = McType.caption, color = Color(0xFFFF8A80), modifier = Modifier.weight(1f))
                Text(
                    "重试", style = McType.caption, color = Accent,
                    modifier = Modifier.clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.06f))
                        .clickable { onReload() }
                        .padding(horizontal = 10.dp, vertical = 5.dp),
                )
            }
        }
        Text(
            "按住左侧手柄拖动调整顺序——列表顺序即搜索面板中分类标签的排列顺序，「全部」固定在首位。自定义分类可组合多个资源分类与指定站点，一次搜索只打勾选的站点。改动即时保存到服务端，所有设备保持一致。",
            style = McType.caption, color = TextFaint, lineHeight = 18.sp,
        )

        when {
            loading -> Text("加载中…", style = McType.caption, color = TextMuted)
            local.isEmpty() -> GlassCard(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(18.dp)) {
                    Text("还没有分类配置", style = McType.subheadlineSemibold, color = TextPrimary)
                    Spacer(Modifier.height(4.dp))
                    Text("点「新建自定义分类」创建，或点上方重试重新读取。", style = McType.footnote, color = TextMuted)
                }
            }
            else -> GlassCard(Modifier.fillMaxWidth()) {
                Column {
                    local.forEachIndexed { index, item ->
                        key(item.id) {
                            val currentIndex by rememberUpdatedState(index)
                            val haptic = LocalHapticFeedback.current
                            val dragging = dragIndex == index
                            // 长按手柄或行内容都能拖；松手才落盘（中途只在本地挪动）
                            val dragModifier = Modifier.pointerInput(busy) {
                                if (busy) return@pointerInput
                                detectDragGesturesAfterLongPress(
                                    onDragStart = {
                                        dragIndex = currentIndex
                                        dragOffset = 0f
                                        dragStart = local.toList()
                                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    },
                                    onDrag = { change, amount ->
                                        change.consume()
                                        dragOffset += amount.y
                                        val from = dragIndex ?: return@detectDragGesturesAfterLongPress
                                        if (dragOffset > rowPx * 0.5f && from < local.lastIndex) {
                                            local.add(from + 1, local.removeAt(from))
                                            dragIndex = from + 1
                                            dragOffset -= rowPx
                                        } else if (dragOffset < -rowPx * 0.5f && from > 0) {
                                            local.add(from - 1, local.removeAt(from))
                                            dragIndex = from - 1
                                            dragOffset += rowPx
                                        }
                                    },
                                    onDragEnd = {
                                        dragIndex = null
                                        dragOffset = 0f
                                        onChange(local.toList())
                                    },
                                    onDragCancel = {
                                        local.clear()
                                        local.addAll(dragStart)
                                        dragIndex = null
                                        dragOffset = 0f
                                    },
                                )
                            }
                            Row(
                                Modifier.fillMaxWidth().height(rowHeight)
                                    .zIndex(if (dragging) 1f else 0f)
                                    .graphicsLayer {
                                        translationY = if (dragging) dragOffset else 0f
                                        scaleX = if (dragging) 1.02f else 1f
                                        scaleY = if (dragging) 1.02f else 1f
                                    }
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(if (dragging) Color(0xFF1D222D) else Color.Transparent)
                                    .padding(horizontal = 10.dp, vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Box(
                                    Modifier.width(44.dp).fillMaxHeight().then(dragModifier)
                                        .alpha(if (busy) 0.4f else 1f),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        "≡", style = McType.body,
                                        color = if (dragging) TextPrimary else TextMuted,
                                    )
                                }
                                Column(Modifier.weight(1f).padding(end = 6.dp).then(dragModifier)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(
                                            searchTabLabel(item), style = McType.subheadlineSemibold,
                                            color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                        )
                                        if (item.type == "preset") {
                                            Spacer(Modifier.width(5.dp))
                                            Text(
                                                "自定义", style = McType.caption, color = Accent,
                                                modifier = Modifier.clip(RoundedCornerShape(999.dp))
                                                    .background(Accent.copy(alpha = 0.14f))
                                                    .padding(horizontal = 6.dp, vertical = 1.dp),
                                            )
                                        }
                                    }
                                    searchTabSummary(item)?.let { summary ->
                                        Text(
                                            summary, style = McType.caption, color = TextFaint,
                                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                                if (item.type == "preset") {
                                    Text(
                                        "⋯", style = McType.sub, color = TextMuted,
                                        modifier = Modifier.clip(RoundedCornerShape(999.dp))
                                            .clickable(enabled = !busy) { editing = item }
                                            .padding(horizontal = 8.dp, vertical = 4.dp),
                                    )
                                }
                                Switch(
                                    checked = item.visible,
                                    onCheckedChange = { visible ->
                                        onChange(
                                            local.mapIndexed { i, t ->
                                                if (i == index) t.copy(visible = visible) else t
                                            },
                                        )
                                    },
                                    enabled = !busy,
                                    colors = SwitchDefaults.colors(
                                        checkedTrackColor = Accent,
                                        checkedThumbColor = Color(0xFF141821),
                                    ),
                                )
                            }
                        }
                        if (index != local.lastIndex) HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
                    }
                }
            }
        }
        if (local.any { it.type == "preset" }) {
            Text(
                "「⋯」编辑自定义分类（改名、换分类/站点、图览与无痕、删除）。内置分类只可排序与显隐。",
                style = McType.caption, color = TextFaint,
            )
        }
    }

    // 编辑弹窗里带删除入口（与 Web 的 ⋯ 菜单等价）
    if (creating || editing != null) {
        PresetEditorSheet(
            initial = editing,
            sites = sites,
            nameOf = nameOf,
            onDismiss = { creating = false; editing = null },
            onDelete = editing?.let { target ->
                {
                    editing = null
                    deleting = target
                }
            },
            onSave = { tab ->
                val next = if (editing == null) local.toList() + tab
                else local.map { if (it.id == tab.id) tab else it }
                onChange(next)
                creating = false
                editing = null
                feedback.success("已保存，正在生效…")
            },
        )
    }
    deleting?.let { item ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            containerColor = Color(0xFF171A23),
            title = { Text("删除自定义分类「${item.name}」？", style = McType.bodySemibold, color = TextPrimary) },
            text = { Text("搜索历史不受影响。", style = McType.body, color = TextMuted) },
            confirmButton = {
                TextButton(onClick = {
                    val target = item
                    deleting = null
                    onChange(local.filterNot { it.id == target.id })
                    feedback.success("已删除")
                }) { Text("删除", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消", color = TextMuted) } },
        )
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun PresetEditorSheet(
    initial: SearchTabView?,
    sites: List<ConfiguredSite>,
    nameOf: (String) -> String,
    onDismiss: () -> Unit,
    onDelete: (() -> Unit)?,
    onSave: (SearchTabView) -> Unit,
) {
    var name by remember { mutableStateOf(initial?.name.orEmpty()) }
    var categories by remember { mutableStateOf(initial?.categories.orEmpty()) }
    var siteIds by remember { mutableStateOf(initial?.siteIds.orEmpty()) }
    var posterMode by remember { mutableStateOf(initial?.posterMode ?: false) }
    var skipHistory by remember { mutableStateOf(initial?.skipHistory ?: false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier.fillMaxWidth().heightIn(max = 720.dp).formSheetScroll().verticalScroll(rememberScrollState())
                .padding(horizontal = 18.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(
                if (initial == null) "新建自定义分类" else "编辑自定义分类",
                style = McType.title3, color = TextPrimary,
            )
            Text(
                "自定义分类 = 命名的「分类组合 × 站点组合」。分类和站点都不勾选表示不限；勾选的站点暂时不可用时会自动跳过。",
                style = McType.caption, color = TextFaint, lineHeight = 17.sp,
            )

            Text("名称（最多 16 字）", style = McType.caption, color = TextFaint)
            TextField(
                value = name, onValueChange = { name = it.take(16) }, singleLine = true,
                placeholder = { Text("如：4K 电影、追番", style = McType.caption, color = TextFaint) },
                modifier = Modifier.fillMaxWidth(),
            )

            Text("分类（可多选；不选 = 不限分类）", style = McType.caption, color = TextFaint)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SEARCH_CATEGORY_LABELS.forEach { (id, label) ->
                    SearchPresetChip(label, selected = id in categories) {
                        categories = if (id in categories) categories - id else categories + id
                    }
                }
            }

            Text("站点（不选 = 全部可用站点）", style = McType.caption, color = TextFaint)
            if (sites.isEmpty()) {
                Text("还没有配置任何站点。", style = McType.caption, color = TextFaint)
            } else {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    sites.forEach { site ->
                        val label = nameOf(site.siteId) + if (!site.usable) "（不可用）" else ""
                        SearchPresetChip(label, selected = site.siteId in siteIds) {
                            siteIds = if (site.siteId in siteIds) siteIds - site.siteId
                            else siteIds + site.siteId
                        }
                    }
                }
            }

            Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("图览模式", style = McType.sub, color = TextPrimary)
                    Text("用该分类搜索时，结果默认以图墙展示", style = McType.caption, color = TextFaint)
                }
                Switch(
                    checked = posterMode, onCheckedChange = { posterMode = it },
                    colors = SwitchDefaults.colors(checkedTrackColor = Accent, checkedThumbColor = Color(0xFF141821)),
                )
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("无痕搜索", style = McType.sub, color = TextPrimary)
                    Text("用该分类搜索时不写入搜索历史", style = McType.caption, color = TextFaint)
                }
                Switch(
                    checked = skipHistory, onCheckedChange = { skipHistory = it },
                    colors = SwitchDefaults.colors(checkedTrackColor = Accent, checkedThumbColor = Color(0xFF141821)),
                )
            }

            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                onDelete?.let { onDeleteAction ->
                    TextButton(onClick = onDeleteAction) { Text("删除", color = Danger) }
                }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) }
                Button(
                    enabled = name.isNotBlank(),
                    onClick = {
                        onSave(
                            SearchTabView(
                                type = "preset",
                                id = initial?.id
                                    ?: ("p-" + UUID.randomUUID().toString().replace("-", "").take(8)),
                                visible = initial?.visible ?: true,
                                name = name.trim(),
                                categories = categories,
                                siteIds = siteIds,
                                posterMode = posterMode,
                                skipHistory = skipHistory,
                            ),
                        )
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF141821)),
                    shape = RoundedCornerShape(999.dp),
                ) { Text("保存", fontSize = 14.sp) }
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun SearchPresetChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        label, style = McType.caption,
        color = if (selected) Color(0xFF141821) else TextMuted,
        maxLines = 1, overflow = TextOverflow.Ellipsis,
        modifier = Modifier.clip(RoundedCornerShape(999.dp))
            .background(if (selected) Accent else Color.White.copy(alpha = 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    )
}
