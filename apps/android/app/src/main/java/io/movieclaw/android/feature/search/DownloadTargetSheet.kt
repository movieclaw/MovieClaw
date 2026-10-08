package io.movieclaw.android.feature.search

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.MoveToInbox
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.TaskAlt
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.DownloadTargetPrefView
import io.movieclaw.android.core.model.ManualDownloadCandidateView
import io.movieclaw.android.core.model.TorrentHit

private val SheetSurface = Color(0xFF15161A)
private val SheetCard = Color.White.copy(alpha = 0.05f)
private val SheetLine = Color.White.copy(alpha = 0.1f)
private val SheetAccent = Color(0xFF9FB0C9)
private val SheetDanger = Color(0xFFFF6B6B)
private val SheetInfo = Color(0xFF60A5FA)

/**
 * 资源操作面板（对应 Web `TorrentActionsSheet` / iOS `TorrentActionsSheet`）：
 * 片名与站点信息 + 三个动作。成员看不到「下载」（要一键下载权限），
 * 也不会有「投给订阅」（那要订阅 + 资源搜索 + 一键下载三项能力）。
 * **没有「浏览图片」**：2026-10-02 拍板去掉（网页只有图览卡片才给，原生这层不提供）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TorrentActionsSheet(
    hit: TorrentHit,
    isAdmin: Boolean,
    canDirectDownload: Boolean,
    canGrabForSubscription: Boolean,
    grabTargetTitle: String?,
    downloadState: TorrentSubmitState,
    grabState: TorrentSubmitState,
    onViewDetail: (String) -> Unit,
    onGrab: () -> Unit,
    onDownload: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SheetSurface,
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 24.dp)) {
            Text(
                hit.attrs?.titlesZh?.firstOrNull() ?: hit.attrs?.titlesEn?.firstOrNull() ?: hit.title,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = TextPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            val secondary = hit.subtitle.takeIf { it.isNotBlank() }
            if (secondary != null) {
                Spacer(Modifier.height(3.dp))
                Text(secondary, fontSize = 12.sp, color = TextMuted, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.height(4.dp))
            Text(
                listOfNotNull(
                    hit.siteName.takeIf { it.isNotBlank() },
                    hit.size?.takeIf { it.isNotBlank() },
                    "${hit.seeders} 做种",
                    hit.uploadTime?.takeIf { it.isNotBlank() },
                ).joinToString(" · "),
                fontSize = 12.sp,
                color = TextFaint,
            )
            Spacer(Modifier.height(16.dp))

            val detailUrl = hit.detailUrl?.takeIf { it.isNotBlank() }
            if (detailUrl != null) {
                SheetWideButton("查看详情", Icons.Rounded.Language, onClick = { onViewDetail(detailUrl) })
                Spacer(Modifier.height(10.dp))
            }
            if (grabTargetTitle != null && canGrabForSubscription && hit.downloadUrl != null) {
                SheetWideButton(
                    grabState.grabLabel,
                    Icons.Rounded.MoveToInbox,
                    enabled = grabState != TorrentSubmitState.SUBMITTING && grabState != TorrentSubmitState.DONE,
                    onClick = onGrab,
                )
                Spacer(Modifier.height(10.dp))
            }
            if (canDirectDownload && hit.downloadUrl != null) {
                SheetWideButton(
                    downloadState.downloadLabel,
                    Icons.Rounded.TaskAlt,
                    prominent = true,
                    enabled = downloadState != TorrentSubmitState.SUBMITTING &&
                        downloadState != TorrentSubmitState.DONE &&
                        downloadState != TorrentSubmitState.EXISTS,
                    onClick = onDownload,
                )
            }
        }
    }
}

/**
 * 保存位置确认条（命中记忆时点「下载」先弹它）：提交前就看得见落点。
 * smart 记忆存的是策略不是路径，由服务端重新路由。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DownloadConfirmSheet(
    pref: DownloadTargetPrefView,
    categoryLabel: String,
    busy: Boolean,
    onConfirm: () -> Unit,
    onChange: () -> Unit,
    onForget: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SheetSurface,
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 24.dp)) {
            Text("保存到", fontSize = 11.sp, color = TextFaint, letterSpacing = 1.sp)
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(categoryLabel, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
                Text(" · ", fontSize = 15.sp, color = TextFaint)
                Text(
                    if (pref.kind == "smart") "智能入库" else (pref.downloaderName ?: "默认下载器"),
                    fontSize = 14.sp,
                    color = TextMuted,
                )
            }
            Spacer(Modifier.height(6.dp))
            Text(
                when {
                    pref.kind == "smart" -> "按作品身份自动选择媒体库与投递目录"
                    pref.kind == "dir" -> pref.savePath ?: "由下载器决定"
                    else -> "由下载器自身设置决定，不会自动整理入库"
                },
                fontSize = 12.sp,
                color = TextFaint,
                lineHeight = 17.sp,
            )
            Spacer(Modifier.height(16.dp))
            SheetWideButton(
                if (busy) "提交中…" else "确认下载",
                Icons.Rounded.TaskAlt,
                prominent = true,
                enabled = !busy,
                onClick = onConfirm,
            )
            Spacer(Modifier.height(10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.weight(1f)) {
                    SheetWideButton("更改", Icons.Rounded.Folder, enabled = !busy, onClick = onChange)
                }
                Box(Modifier.weight(1f)) {
                    SheetWideButton("不再记住", Icons.Rounded.RadioButtonUnchecked, enabled = !busy, onClick = onForget)
                }
            }
        }
    }
}

/**
 * 完整「选择保存位置」弹窗（对应 Web `download-target-dialog.tsx` / iOS `DownloadTargetSheet`）。
 * 管理员三层候选（智能入库 / 已配目录 / 下载器默认）+ 记住本次选择；成员两层（可见库 / 下载器默认）。
 * 「这是哪部作品？」——自动识别没收敛（或种子没身份）时常驻候选与搜索框。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DownloadTargetSheet(
    flow: DownloadFlow,
    isAdmin: Boolean,
    onDismiss: () -> Unit,
    onSelect: (String) -> Unit,
    onSetRemember: (Boolean) -> Unit,
    onSelectDownloader: (Long) -> Unit,
    onShowOther: () -> Unit,
    onHintDraft: (String) -> Unit,
    onSearchHint: () -> Unit,
    onSelectCandidate: (ManualDownloadCandidateView) -> Unit,
    onSubmit: () -> Unit,
) {
    val request = flow.request ?: return
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SheetSurface,
        contentColor = TextPrimary,
    ) {
        val options = computeTargetOptions(
            isAdmin = isAdmin,
            target = flow.target,
            showOther = flow.showOther,
            downloader = flow.downloaders.firstOrNull { it.id == flow.downloaderId },
            memberLibraries = flow.memberLibraries,
            request = request,
        )
        Column(
            Modifier
                .fillMaxWidth()
                .heightIn(max = 620.dp)
                .verticalScroll(rememberScrollState())
                .padding(start = 20.dp, end = 20.dp, bottom = 24.dp),
        ) {
            Text("选择保存位置", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
            Spacer(Modifier.height(12.dp))

            request.reason?.let { reason ->
                SheetNotice(reason, Warning)
                Spacer(Modifier.height(10.dp))
            }
            flow.error?.let { error ->
                SheetNotice(error, SheetDanger)
                Spacer(Modifier.height(10.dp))
            }

            if (isAdmin && flow.picking) {
                CandidatePicker(
                    caption = pickerCaption(flow),
                    candidates = flow.candidates,
                    selected = flow.selectedCandidate,
                    hintDraft = flow.hintDraft,
                    loading = flow.loadingTarget,
                    onHintDraft = onHintDraft,
                    onSearch = onSearchHint,
                    onSelect = onSelectCandidate,
                )
                Spacer(Modifier.height(12.dp))
            }
            if (isAdmin && flow.loadingTarget) {
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(SheetCard)
                        .padding(horizontal = 14.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(15.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(10.dp))
                    Text(
                        if (flow.selectedCandidate != null) "正在预演自动入库…" else "正在识别影视条目并预演智能入库…",
                        fontSize = 12.sp,
                        color = TextFaint,
                    )
                }
                Spacer(Modifier.height(10.dp))
            }
            if (isAdmin && !flow.loadingTarget && flow.target != null && flow.target!!.status == "ready" && !flow.target!!.ok) {
                SheetNotice(
                    "已识别资源，但当前不能自动入库：${flow.target!!.warning ?: "请检查媒体库和自动入库配置。"}",
                    Warning,
                )
                Spacer(Modifier.height(10.dp))
            }
            if (!isAdmin && !flow.memberLibrariesLoaded) {
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(SheetCard)
                        .padding(horizontal = 14.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(15.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(10.dp))
                    Text("正在读取可见的媒体库…", fontSize = 12.sp, color = TextFaint)
                }
                Spacer(Modifier.height(10.dp))
            }
            if (isAdmin && flow.showOther && flow.loadingDownloaders) {
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(SheetCard)
                        .padding(horizontal = 14.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(15.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(10.dp))
                    Text("正在读取下载器目录…", fontSize = 12.sp, color = TextFaint)
                }
                Spacer(Modifier.height(10.dp))
            }

            options.forEach { option ->
                OptionRow(
                    option = option,
                    selected = flow.selected == option.id,
                    onClick = { onSelect(option.id) },
                )
                Spacer(Modifier.height(8.dp))
            }

            if (isAdmin && !flow.showOther) {
                Spacer(Modifier.height(2.dp))
                SheetWideButton("其他保存位置", Icons.Rounded.Folder, onClick = onShowOther)
                Spacer(Modifier.height(10.dp))
            }
            if (isAdmin && flow.showOther && flow.downloaders.size >= 2) {
                Text("下载器", fontSize = 12.sp, color = TextFaint)
                Spacer(Modifier.height(6.dp))
                flow.downloaders.forEach { d ->
                    val on = flow.downloaderId == d.id
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                            .background(if (on) Color.White.copy(alpha = 0.08f) else Color.Transparent)
                            .clickable { onSelectDownloader(d.id) }
                            .padding(horizontal = 12.dp, vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            d.name + if (d.isDefault) "（默认）" else "",
                            fontSize = 14.sp,
                            color = if (on) TextPrimary else TextMuted,
                        )
                        Spacer(Modifier.weight(1f))
                        if (on) Icon(Icons.Rounded.Check, contentDescription = null, tint = SheetInfo, modifier = Modifier.size(16.dp))
                    }
                }
                Spacer(Modifier.height(6.dp))
            }
            if (isAdmin) {
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(SheetCard)
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("记住本次选择", fontSize = 14.sp, color = TextPrimary)
                        Spacer(Modifier.height(2.dp))
                        Text(
                            if (flow.remember) {
                                "之后点「下载」先给你确认一次落点，随时可以改，或在确认条上「不再记住」。"
                            } else {
                                "不勾选就只对这一次下载生效，不会留下默认位置。"
                            },
                            fontSize = 11.5.sp,
                            color = TextFaint,
                            lineHeight = 16.sp,
                        )
                    }
                    Switch(
                        checked = flow.remember,
                        onCheckedChange = onSetRemember,
                        colors = SwitchDefaults.colors(checkedTrackColor = SheetInfo),
                    )
                }
                Spacer(Modifier.height(10.dp))
            }
            if (isAdmin && flow.showOther) {
                Text(
                    "movieclaw 与下载器不在同一容器/主机、看到的路径不同？到「设置 → 下载器」配置路径映射，提交时会自动翻译成下载器视角。",
                    fontSize = 11.sp,
                    color = TextFaint,
                    lineHeight = 16.sp,
                )
                Spacer(Modifier.height(10.dp))
            }

            SheetWideButton(
                if (flow.busy) "提交中…" else confirmTitle(flow, options),
                Icons.Rounded.TaskAlt,
                prominent = true,
                enabled = !flow.busy && flow.selected != null,
                onClick = onSubmit,
            )
        }
    }
}

private fun confirmTitle(flow: DownloadFlow, options: List<TargetOption>): String {
    val selected = options.firstOrNull { it.id == flow.selected }
    if (selected?.kind == TargetOption.Kind.SMART) {
        flow.target?.libraryName?.let { return "下载到「$it」" }
    }
    return "确认下载"
}

private fun pickerCaption(flow: DownloadFlow): String {
    if (!flow.loadingTarget && flow.target?.status == "not_found") {
        val hint = flow.hint
        return if (hint != null) {
            "没找到与「$hint」匹配的作品，换个片名试试（中文名搜不到时可试英文/原名）。"
        } else {
            "输入片名搜索，确认后会自动分配媒体库。"
        }
    }
    return if (flow.candidates.isEmpty()) {
        "输入片名搜索，确认后会自动分配媒体库。"
    } else {
        "没能自动认出这条资源。点选正确的作品，媒体库会按收藏范围自动分配。"
    }
}

@Composable
private fun CandidatePicker(
    caption: String,
    candidates: List<ManualDownloadCandidateView>,
    selected: ManualDownloadCandidateView?,
    hintDraft: String,
    loading: Boolean,
    onHintDraft: (String) -> Unit,
    onSearch: () -> Unit,
    onSelect: (ManualDownloadCandidateView) -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Warning.copy(alpha = 0.06f))
            .border(1.dp, Warning.copy(alpha = 0.2f), RoundedCornerShape(12.dp))
            .padding(12.dp),
    ) {
        Text("这是哪部作品？", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = TextPrimary)
        Spacer(Modifier.height(2.dp))
        Text(caption, fontSize = 11.5.sp, color = TextFaint, lineHeight = 16.sp)
        if (candidates.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            candidates.forEach { c ->
                val on = selected?.tmdbId == c.tmdbId && selected.kind == c.kind
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp))
                        .background(if (on) Color.White.copy(alpha = 0.1f) else Color.White.copy(alpha = 0.04f))
                        .clickable { onSelect(c) }
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        c.title + (c.year?.let { " ($it)" } ?: "") + " · " +
                            (if (c.kind == "tv") "剧集" else "电影") +
                            (c.episodeCount?.let { " · $it 集" } ?: ""),
                        fontSize = 12.5.sp,
                        color = if (on) TextPrimary else TextMuted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(6.dp))
            }
        }
        Spacer(Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(
                Modifier
                    .weight(1f)
                    .height(36.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(Color.White.copy(alpha = 0.07f))
                    .padding(horizontal = 10.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (hintDraft.isEmpty()) {
                    Text(
                        if (candidates.isEmpty()) "输入片名" else "都不对？换个片名搜",
                        fontSize = 13.sp,
                        color = TextFaint,
                    )
                }
                BasicTextField(
                    value = hintDraft,
                    onValueChange = onHintDraft,
                    singleLine = true,
                    textStyle = TextStyle(color = Color.White, fontSize = 13.sp),
                    cursorBrush = Brush.verticalGradient(listOf(SheetInfo, SheetInfo)),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { onSearch() }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            TextButton(onClick = onSearch, enabled = hintDraft.isNotBlank() && !loading) {
                Text("搜索", fontSize = 13.sp, color = SheetInfo)
            }
        }
    }
}

@Composable
private fun OptionRow(option: TargetOption, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) Color.White.copy(alpha = 0.08f) else Color.White.copy(alpha = 0.03f))
            .border(
                1.dp,
                if (selected) Color.White.copy(alpha = 0.25f) else SheetLine,
                RoundedCornerShape(12.dp),
            )
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        Icon(
            if (selected) Icons.Rounded.Check else Icons.Rounded.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (selected) SheetInfo else TextFaint,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (option.kind == TargetOption.Kind.SMART) Icons.Rounded.Check else Icons.Rounded.Folder,
                    contentDescription = null,
                    tint = SheetInfo.copy(alpha = 0.8f),
                    modifier = Modifier.size(13.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    option.label,
                    fontSize = 13.5.sp,
                    fontWeight = FontWeight.Medium,
                    color = TextPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            option.detail?.let { detail ->
                Spacer(Modifier.height(3.dp))
                Text(detail, fontSize = 11.5.sp, color = TextFaint, lineHeight = 16.sp)
            }
        }
    }
}

@Composable
private fun SheetNotice(text: String, tone: Color) {
    Text(
        text,
        fontSize = 11.5.sp,
        color = tone.copy(alpha = 0.95f),
        lineHeight = 16.sp,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(tone.copy(alpha = 0.1f))
            .border(1.dp, tone.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
            .padding(12.dp),
    )
}

/** 面板与弹窗里的整宽按钮（玻璃风格；prominent = 强调态反白） */
@Composable
private fun SheetWideButton(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    prominent: Boolean = false,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val alpha = if (enabled) 1f else 0.45f
    Row(
        Modifier
            .fillMaxWidth()
            .height(42.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(
                when {
                    prominent && enabled -> Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6)))
                    prominent -> Brush.linearGradient(listOf(Color(0xFF3A3F4A), Color(0xFF3A3F4A)))
                    else -> Brush.linearGradient(listOf(Color.White.copy(alpha = 0.12f), Color.White.copy(alpha = 0.12f)))
                }
            )
            .border(1.dp, if (prominent) Color.Transparent else SheetLine, RoundedCornerShape(999.dp))
            .clickable(enabled = enabled, onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (prominent && enabled) Color(0xFF141821) else TextPrimary.copy(alpha = alpha),
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(7.dp))
        Text(
            label,
            fontSize = 14.5.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (prominent && enabled) Color(0xFF141821) else TextPrimary.copy(alpha = alpha),
        )
    }
}
