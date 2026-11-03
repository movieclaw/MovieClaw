package io.movieclaw.android.feature.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.MenuAppear
import io.movieclaw.android.core.designsystem.MenuSurface
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.LibraryItemDetailView
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.session.Permissions

/**
 * 媒体库详情页右上角的「更多操作」（iOS `LibraryItemDetailView.actionsMenu`，line 677–725）。
 *
 * 与 iOS 逐条对齐的判定（**顺序、文案、显隐条件都照抄**，不要按自己的直觉改）：
 * - `搜索资源` 要 `canSearch`；`加入合集…` 恒有；
 * - `分享…` 要管理员且不是图片；`洗版…` 要订阅权限 + 有 TMDB id + 不是视频/图片；
 * - 下面一组（修正识别结果 / 刷新元数据 / 重新生成章节 / 更换图片 / 转移到其他库 / 删除影片）
 *   要 `canManageLibraries`（= 管理员）；
 * - `识别类` 三个动作（修正识别、刷新元数据、更换图片）还要**库本身有刮削链**
 *   （`library.capabilities.scraped`，取不到时退回「来源是 tmdb」这条 iOS 的老口径）；
 * - `重新生成章节` 只在库开了「生成章节」时出现；
 * - 刮削中：`⋯` 右上角点一颗蓝点，且「刷新元数据」禁用（文案换成「正在刷新元数据…」这类进行时）。
 */
enum class ItemActionId {
    /** 离线下载（iOS `actionsMenu` 的「下载」）：电影选画质、剧集选范围 */
    DOWNLOAD,
    /** 取消这部剧 / 这部电影正在进行的下载（iOS 的「取消下载 / 取消下载选中的集 / 取消全部下载」） */
    CANCEL_DOWNLOADS,
    CANCEL_SELECTED_DOWNLOAD,
    /** 整部剧插队（§5.5）：还没下完的各集按季集排到最前 */
    PRIORITIZE_DOWNLOADS,
    SEARCH,
    ADD_TO_COLLECTION,
    SHARE,
    UPGRADE,
    REIDENTIFY,
    REFRESH_METADATA,
    REGENERATE_CHAPTERS,
    ARTWORK,
    TRANSFER,
    DELETE_ITEM,
    CLEAR_HISTORY,
}

/** 菜单里的一行；[Divider] 是 iOS `Divider()` 的分组线 */
sealed interface ItemMenuEntry {
    data class Action(
        val id: ItemActionId,
        val label: String,
        val enabled: Boolean = true,
        val danger: Boolean = false,
    ) : ItemMenuEntry

    data object Divider : ItemMenuEntry
}

/**
 * 按 iOS 的判定算出这一屏该摆哪些行。[scraping] 传「服务端说在刮」或「本地点了刷新还没回来」，
 * 两者在 iOS 是同一个 `scraping = detail.scraping || kicking`。
 */
fun itemMenuEntries(
    detail: LibraryItemDetailView,
    library: LibraryView?,
    permissions: Permissions,
    scraping: Boolean,
    /** 离线下载：能不能下（权限 + 本机是否已有；iOS `canDownload`） */
    canDownload: Boolean = false,
    /** 这部剧 / 这部电影还在下的单元数（iOS `active.count`） */
    activeDownloads: Int = 0,
    /** 剧集选中的那一集正在下（iOS `activeSelected`）：多一项「取消下载选中的集」 */
    activeSelected: Boolean = false,
    /** 别的条目排在这部剧某一集前面（iOS `canPrioritize(itemId:)`）：多一项「优先下载剩下的 N 集」 */
    canPrioritizeShow: Boolean = false,
): List<ItemMenuEntry> {
    val manage = permissions.canManageLibraries
    val scraped = detail.source == "tmdb"
    // iOS：library?.capabilities.scraped ?? scraped。库还没拉到（或老服务端没这个字段）时退回来源判断
    val identifiable = library?.capabilities?.scraped ?: scraped
    val readsNfo = detail.kind == "video"
    val tmdb = detail.tmdbId ?: 0L
    val canUpgrade = permissions.canSubscribe && tmdb > 0 &&
        detail.kind != "video" && detail.kind != "photo"
    val canShare = permissions.isAdmin && detail.kind != "photo"

    val out = mutableListOf<ItemMenuEntry>()
    // 离线下载（iOS：在下时先给「取消下载」；能下时与「加入合集 / 分享」同排）
    if (activeDownloads > 0 && canPrioritizeShow && detail.kind == "tv") {
        out += ItemMenuEntry.Action(ItemActionId.PRIORITIZE_DOWNLOADS, "优先下载剩下的 $activeDownloads 集")
    }
    if (activeDownloads > 0 && activeSelected && detail.kind == "tv") {
        out += ItemMenuEntry.Action(ItemActionId.CANCEL_SELECTED_DOWNLOAD, "取消下载选中的集")
    }
    if (activeDownloads > 0) {
        out += ItemMenuEntry.Action(
            ItemActionId.CANCEL_DOWNLOADS,
            if (detail.kind == "tv") "取消全部下载（$activeDownloads 集）" else "取消下载",
            danger = detail.kind != "tv",
        )
    }
    if (canDownload) {
        out += ItemMenuEntry.Action(ItemActionId.DOWNLOAD, "下载")
    }
    if (permissions.canSearch) {
        out += ItemMenuEntry.Action(ItemActionId.SEARCH, "搜索资源")
    }
    out += ItemMenuEntry.Action(ItemActionId.ADD_TO_COLLECTION, "加入合集…")
    if (canShare) out += ItemMenuEntry.Action(ItemActionId.SHARE, "分享…")
    if (canUpgrade) out += ItemMenuEntry.Action(ItemActionId.UPGRADE, "洗版…")

    if (manage) {
        out += ItemMenuEntry.Divider
        if (identifiable) {
            out += ItemMenuEntry.Action(ItemActionId.REIDENTIFY, "修正识别结果…")
        }
        out += ItemMenuEntry.Action(
            ItemActionId.REFRESH_METADATA,
            label = when {
                scraping && scraped -> "正在刷新元数据…"
                scraping && readsNfo -> "正在读取 NFO…"
                scraping -> "正在生成封面…"
                scraped -> "刷新元数据"
                readsNfo -> "重新读取 NFO 与封面"
                else -> "重新生成封面"
            },
            enabled = !scraping,
        )
        if (library?.extractChapterImages == true) {
            out += ItemMenuEntry.Action(
                ItemActionId.REGENERATE_CHAPTERS,
                label = if (detail.chaptersPending) "正在生成章节…" else "重新生成章节",
                enabled = !detail.chaptersPending,
            )
        }
        if (scraped) out += ItemMenuEntry.Action(ItemActionId.ARTWORK, "更换图片…")
        out += ItemMenuEntry.Action(ItemActionId.TRANSFER, "转移到其他库…")
        out += ItemMenuEntry.Divider
        out += ItemMenuEntry.Action(ItemActionId.DELETE_ITEM, "删除影片", danger = true)
    }
    if (manage || canUpgrade || canShare) out += ItemMenuEntry.Divider
    out += ItemMenuEntry.Action(ItemActionId.CLEAR_HISTORY, "清除观看记录…")
    return out
}

/**
 * 「⋯」玻璃圆钮（与返回键同一份材质：`McNavButton` = GlassCapsule + glassSurface + 1px 边）。
 * [scraping] 为真时右上角点一颗蓝点——iOS 是压在 `ellipsis` 上的 6pt 小圆点，位置口径一致。
 */
@Composable
fun ItemActionsButton(
    scraping: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    McNavButton(
        icon = Icons.Rounded.MoreHoriz,
        contentDescription = "更多操作",
        modifier = modifier,
        onClick = onClick,
        badgeDot = if (scraping) Info else null,
    )
}

/** 菜单面板：容器材质与发现页/媒体库的其它菜单同款（MenuSurface + 1px 边 + 4dp 内边距） */
@Composable
fun ItemActionsMenuPanel(
    entries: List<ItemMenuEntry>,
    onPick: (ItemActionId) -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = 208.dp,
    maxHeight: Dp = 480.dp,
) {
    Column(
        modifier
            .width(width)
            // 11 行满编时比一屏还高：面板自己可滚，最后一行不会被挤出屏幕
            .heightIn(max = maxHeight)
            .clip(RoundedCornerShape(McMetrics.menuRadius))
            .background(MenuSurface)
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(McMetrics.menuRadius))
            .padding(4.dp)
            .verticalScroll(rememberScrollState()),
    ) {
        entries.forEach { entry ->
            when (entry) {
                is ItemMenuEntry.Divider -> Box(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 4.dp)
                        .height(1.dp)
                        .background(Color.White.copy(alpha = 0.08f)),
                )

                is ItemMenuEntry.Action -> ItemMenuRow(
                    label = entry.label,
                    enabled = entry.enabled,
                    danger = entry.danger,
                    onClick = { onPick(entry.id) },
                )
            }
        }
    }
}

/** 菜单里的一行（行高/圆角/字号与发现页菜单一致；iOS 的菜单项只有文字，这里不加图标） */
@Composable
private fun ItemMenuRow(
    label: String,
    enabled: Boolean,
    danger: Boolean,
    onClick: () -> Unit,
) {
    val color = when {
        !enabled -> TextMuted.copy(alpha = 0.45f)
        danger -> Danger
        else -> TextPrimary
    }
    Row(
        Modifier
            .fillMaxWidth()
            .height(38.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            style = McType.sub.copy(fontWeight = if (danger) FontWeight.Medium else null),
            color = color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** 面板出现/缩回动画的包装（与发现页菜单同一个 spring 参数；菜单在右上角，原点也就是右上） */
@Composable
fun ItemActionsMenuAppear(visible: Boolean = true, content: @Composable () -> Unit) {
    MenuAppear(visible = visible, originX = 0.9f, originY = 0.06f) { content() }
}

/**
 * ⋯ 菜单的宿主：顶在右上角、**独立成一层**（活动页长按菜单同款 `Popup`）。
 *
 * 不能直接摆在 hero 里——菜单有 11 行，比 hero 还高，溢出部分会被后画的正文盖住
 * （实测「转移到其他库」往下就看不见了）。Popup 是单独的窗口，多高都压在所有内容之上，
 * 顺带白拿「点空白 / 返回键关掉」（`focusable = true`）。
 *
 * [visible] 切 false 时 Popup 不立刻销毁：多留一帧动画的时间，面板缩回右上再关窗。
 */
@Composable
fun ItemActionsMenuPopup(
    entries: List<ItemMenuEntry>,
    onPick: (ItemActionId) -> Unit,
    onDismiss: () -> Unit,
    visible: Boolean = true,
) {
    if (!io.movieclaw.android.core.designsystem.rememberMenuRetained(visible)) return
    val density = LocalDensity.current
    // 与 ⋯ 钮的右边缘对齐（顶栏横向内距 8dp），纵向落在钮下方一点点
    val edgePx = with(density) { 8.dp.roundToPx() }
    val topPx = WindowInsets.statusBars.getTop(density) + with(density) { 62.dp.roundToPx() }
    Popup(
        alignment = Alignment.TopEnd,
        offset = IntOffset(x = -edgePx, y = topPx),
        onDismissRequest = onDismiss,
        properties = PopupProperties(focusable = true),
    ) {
        ItemActionsMenuAppear(visible = visible) {
            ItemActionsMenuPanel(entries = entries, onPick = onPick)
        }
    }
}
