package io.movieclaw.android.feature.offline

import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.FeedbackTone
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McNotice
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.designsystem.formSheetScroll
import io.movieclaw.android.core.model.OfflineFileProfiles
import io.movieclaw.android.core.model.OfflineProfile
import io.movieclaw.android.core.model.OfflineProfilesRequest
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.offline.OFFLINE_RESERVE_BYTES
import io.movieclaw.android.core.offline.OfflineDisk
import io.movieclaw.android.core.offline.OfflineDownloadChoices
import kotlinx.coroutines.launch

/**
 * 下载选档（docs/design/offline-download.md §5；iOS `OfflineProfileSheet`）：点一行只是选中（打勾），右上角「下载」才开始——
 * 同系统的选择类表单。每一档显示整批的总大小，空间不够时说明并禁用「下载」。剧集从右上角菜单进来时顶部多一排范围（§8）。
 *
 * 大小来自批量接口 `POST /offline/profiles`：打开时把所有范围的文件一次问完，切范围只是换个算法，不再发请求。
 * 点「下载」才取第一集的完整清单（存条目的展示数据），其余集先建「准备中」单元，由下载器逐集取清单。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun OfflineProfileSheet(
    title: String,
    /** 剧集按范围下（有「下载范围」分组）；单个文件（电影、分集长按、改下其他画质）没有 */
    ranged: Boolean,
    loadChoices: suspend () -> OfflineDownloadChoices.Choices,
    onDismiss: () -> Unit,
) {
    val offline = rememberOffline()
    val device = deviceName()
    val feedback = LocalFeedback.current
    val scope = rememberCoroutineScope()
    val allowCellular by offline.prefs().allowCellular.collectAsStateWithLifecycle()
    val lastProfile by offline.prefs().lastProfile.collectAsStateWithLifecycle()

    var scopes by remember { mutableStateOf<List<OfflineDownloadChoices.Scope>?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    var scopeId by remember { mutableStateOf<String?>(null) }
    var entries by remember { mutableStateOf<Map<Long, OfflineFileProfiles>>(emptyMap()) }
    var asked by remember { mutableStateOf<Set<Long>>(emptySet()) }
    var error by remember { mutableStateOf<String?>(null) }
    var startError by remember { mutableStateOf<String?>(null) }
    var choice by remember { mutableStateOf<String?>(null) }
    var starting by remember { mutableStateOf(false) }

    val fileIds = scopes?.firstOrNull { it.id == scopeId }?.fileIds.orEmpty()
    val batch = fileIds.size > 1
    val ready = fileIds.isNotEmpty() && fileIds.all { it in asked }
    val missing = fileIds.count { entries[it] == null }
    val current = fileIds.mapNotNull { entries[it] }
    val free = remember { OfflineDisk.availableBytes() }

    fun pick(profile: String, entry: OfflineFileProfiles): OfflineProfile? {
        val options = entry.profiles.orEmpty()
        return options.firstOrNull { it.profile == profile } ?: options.firstOrNull()
    }

    fun totalBytes(profile: String): Long = current.filter { it.unavailableReason == null }.sumOf { pick(profile, it)?.expectedBytes ?: 0L }

    /** 整批按这一档的大小里有没有预计值：有一集落在转码档上就是（原画是准数） */
    fun isEstimate(profile: String): Boolean = current.any { it.unavailableReason == null && (pick(profile, it)?.profile ?: "original") != "original" }

    fun selected(first: OfflineFileProfiles): String =
        choice ?: lastProfile?.takeIf { last -> first.profiles.orEmpty().any { it.profile == last } } ?: "original"

    LaunchedEffect(Unit) {
        val choices = runCatching { loadChoices() }.getOrElse {
            error = friendlyMessage(it)
            return@LaunchedEffect
        }
        note = choices.note
        scopeId = (choices.scopes.firstOrNull { it.preferred } ?: choices.scopes.firstOrNull())?.id
        scopes = choices.scopes
        // 所有范围的文件一次问完：切范围不再发请求
        val all = choices.scopes.flatMap { it.fileIds }.distinct()
        val origin = offline.store().owner?.origin ?: return@LaunchedEffect
        val api = offline.apiFactory().forOrigin(origin)
        for (chunk in all.chunked(500)) {
            runCatching { api.offlineProfiles(OfflineProfilesRequest(chunk)).dataOrThrow() }
                .onSuccess { view -> entries = entries + view.files.orEmpty().associateBy { it.fileId } }
                .onFailure { error = friendlyMessage(it) }
            asked = asked + chunk
        }
    }

    fun start() {
        val first = current.firstOrNull() ?: return
        val profile = selected(first)
        val files = current.filter { it.unavailableReason == null }
        val lead = files.firstOrNull() ?: run {
            startError = first.unavailableReason ?: "没能开始下载"
            return
        }
        starting = true
        scope.launch {
            try {
                val origin = offline.store().owner?.origin ?: throw IllegalStateException("没能开始下载")
                val manifest = offline.apiFactory().forOrigin(origin).offlineManifest(lead.fileId).dataOrThrow()
                val leadProfile = manifest.profiles.firstOrNull { it.profile == profile } ?: manifest.profiles.firstOrNull()
                    ?: throw IllegalStateException(manifest.unavailableReason ?: "没能开始下载")
                offline.downloader().start(manifest, leadProfile)
                if (!batch) {
                    onDismiss()
                    return@launch
                }
                var started = 1
                var failures = 0
                for (entry in files.drop(1)) {
                    val chosen = pick(profile, entry) ?: continue
                    runCatching { offline.downloader().enqueue(entry, chosen) }.onSuccess { started += 1 }.onFailure { failures += 1 }
                }
                val skipped = failures + missing + (current.size - files.size)
                feedback.show(McNotice(if (skipped > 0) "已开始下载 $started 集，$skipped 集没能开始" else "已开始下载 $started 集", FeedbackTone.Success))
                onDismiss()
            } catch (e: Exception) {
                startError = friendlyMessage(e)
            } finally {
                starting = false
            }
        }
    }

    val first = current.firstOrNull()
    val needed = first?.let { totalBytes(selected(it)) + OFFLINE_RESERVE_BYTES }
    val canStart = ready && first != null && !starting &&
        (batch || first.unavailableReason == null) && (free == null || needed == null || needed <= free)

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Color(0xFF15161A), contentColor = TextPrimary) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss) { Text("取消", style = McType.body, color = TextMuted) }
                Text("下载到$device", style = McType.headline, color = TextPrimary, modifier = Modifier.weight(1f), maxLines = 1)
                if (starting) {
                    CircularProgressIndicator(color = TextMuted, modifier = Modifier.padding(horizontal = 16.dp).size(18.dp), strokeWidth = 2.dp)
                } else {
                    TextButton(onClick = ::start, enabled = canStart, modifier = Modifier.testTag("offline-profile-confirm")) {
                        Text("下载", style = McType.bodySemibold, color = if (canStart) Info else TextFaint)
                    }
                }
            }
            Column(Modifier.formSheetScroll().verticalScroll(rememberScrollState()).heightIn(max = 560.dp)) {
                val loaded = scopes
                when {
                    loaded != null && loaded.isEmpty() -> EmptyNotice("都已下载", "这部剧能下的集都已在${device}上")
                    loaded == null && error != null -> EmptyNotice("拿不到下载信息", error.orEmpty())
                    loaded == null -> Box(Modifier.fillMaxWidth().padding(vertical = 36.dp), contentAlignment = Alignment.Center) {
                        Text("正在读取可下载的集", style = McType.sub, color = TextMuted)
                    }
                    else -> {
                        val currentScope = loaded.firstOrNull { it.id == scopeId }
                        Section {
                            Text(title, style = McType.headline, color = TextPrimary)
                            note?.let { Text(it, style = McType.footnote, color = TextMuted, modifier = Modifier.padding(top = 4.dp).testTag("offline-download-note")) }
                        }
                        if (ranged && currentScope != null) {
                            SectionHeader("下载范围")
                            Section {
                                if (loaded.size > 1) {
                                    Row(
                                        Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(Color.White.copy(alpha = 0.08f)).padding(2.dp).testTag("offline-scope"),
                                    ) {
                                        loaded.forEach { s ->
                                            val on = s.id == scopeId
                                            Text(
                                                s.label, style = McType.footnote, color = if (on) TextPrimary else TextMuted, maxLines = 1,
                                                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                                                modifier = Modifier.weight(1f).clip(RoundedCornerShape(7.dp))
                                                    .background(if (on) Color.White.copy(alpha = 0.18f) else Color.Transparent)
                                                    .clickable { scopeId = s.id; startError = null }.padding(vertical = 7.dp),
                                            )
                                        }
                                    }
                                } else {
                                    Text(currentScope.label, style = McType.body, color = TextPrimary, modifier = Modifier.testTag("offline-scope-only"))
                                }
                                currentScope.detail?.let { detail ->
                                    val skipped = if (ready && missing > 0) "（其中 $missing 集取不到下载信息，会跳过）" else ""
                                    Text(detail + skipped, style = McType.footnote, color = TextMuted, modifier = Modifier.padding(top = 6.dp).testTag("offline-scope-detail"))
                                }
                            }
                        }
                        when {
                            ready && first != null -> {
                                val reason = first.unavailableReason
                                if (reason != null && !batch) {
                                    Section { Text(reason, style = McType.sub, color = Warning) }
                                } else {
                                    SectionHeader("画质")
                                    Section(padding = false) {
                                        first.profiles.orEmpty().forEach { profile ->
                                            val on = profile.profile == selected(first)
                                            Row(
                                                Modifier.fillMaxWidth().clickable { choice = profile.profile }.padding(horizontal = 14.dp, vertical = 11.dp)
                                                    .testTag("offline-profile-${profile.profile}"),
                                                verticalAlignment = Alignment.CenterVertically,
                                            ) {
                                                Column(Modifier.weight(1f)) {
                                                    Text(profile.label, style = McType.body, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                                    Text(
                                                        if (profile.profile == "original") "原文件，画质最好" else "服务器转码后下载，边转边下",
                                                        style = McType.caption, color = TextMuted,
                                                    )
                                                }
                                                // 原画是文件实际大小，写准数；转码档是预计，前面带 ≈
                                                Text(
                                                    (if (batch) "共 " else "") + (if (isEstimate(profile.profile)) "≈ " else "") + McFormat.bytes(totalBytes(profile.profile)),
                                                    style = McType.sub, color = TextMuted,
                                                )
                                                Spacer(Modifier.size(10.dp))
                                                Icon(Icons.Rounded.Check, null, tint = if (on) Info else Color.Transparent, modifier = Modifier.size(18.dp))
                                            }
                                        }
                                    }
                                    val footer = if (free != null && needed != null && needed > free) {
                                        "空间不够：需要 ${if (isEstimate(selected(first))) "≈ " else ""}${McFormat.bytes(needed)}（含预留 2 GB），${device}只剩 ${McFormat.bytes(free)}。换个小一点的画质，或先清理空间。"
                                    } else {
                                        val network = if (allowCellular) "会使用蜂窝网络下载" else "只在 Wi-Fi 下下载，可在「我的 → 下载」里改"
                                        free?.let { "${device}剩余 ${McFormat.bytes(it)} · $network" } ?: network
                                    }
                                    Text(
                                        footer, style = McType.caption,
                                        color = if (free != null && needed != null && needed > free) Danger else TextFaint,
                                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
                                    )
                                }
                            }
                            ready -> Section { Text(error ?: "拿不到下载信息", style = McType.sub, color = Warning) }
                            else -> Box(Modifier.fillMaxWidth().padding(vertical = 24.dp), contentAlignment = Alignment.Center) {
                                Text(if (batch) "正在计算 ${fileIds.size} 集的大小" else "正在读取可下载的画质", style = McType.sub, color = TextMuted)
                            }
                        }
                        startError?.let { Section { Text(it, style = McType.sub, color = Danger) } }
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(text, style = McType.caption, color = TextFaint, modifier = Modifier.padding(start = 4.dp, top = 14.dp, bottom = 6.dp))
}

@Composable
private fun Section(padding: Boolean = true, content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(top = 8.dp).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.05f))
            .then(if (padding) Modifier.padding(14.dp) else Modifier),
    ) { content() }
}

@Composable
private fun EmptyNotice(title: String, message: String) {
    Column(Modifier.fillMaxWidth().padding(vertical = 36.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, style = McType.headline, color = TextPrimary)
        Spacer(Modifier.height(6.dp))
        Text(message, style = McType.sub, color = TextMuted, lineHeight = 20.sp)
    }
}
