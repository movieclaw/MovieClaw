package io.movieclaw.android.feature.offline

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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.OfflineFileProfiles
import io.movieclaw.android.core.model.OfflineProfile
import io.movieclaw.android.core.offline.OfflineDownloadChoices
import io.movieclaw.android.core.designsystem.formSheetScroll

/**
 * 下载选档（iOS `OfflineProfileSheet` 的对应物，docs/design/offline-download.md §5、§8）：
 * 点一行只是选中（打勾），右上角「下载」才开始——同系统的选择类表单。
 * 每一档显示**整批总大小**；空间不够时说明并禁用「下载」。
 * 剧集从右上角菜单进来时顶部多一排范围（选中的集 / 未看 / 剩余），切换范围不发请求。
 *
 * 档位来自批量接口 `POST /offline/profiles`：打开时把所有范围的文件一次问完。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun DownloadScopeSheet(
    /** 面板标题里的条目名 */
    title: String,
    /** 剧集的范围（null / 空 = 单文件，不显示分段） */
    scopes: List<OfflineDownloadChoices.Scope>?,
    /** 「为什么有些集不在里面」的一句说明 */
    note: String?,
    /** 单文件时的文件 id */
    singleFileId: Long? = null,
    deviceName: String,
    freeBytes: Long,
    /** 上次选的档位（iOS `OfflineSettings.lastProfile`）：有就默认选它 */
    defaultProfile: String? = null,
    /** 打开时把所有范围的文件一次问完：文件 id → 档位 */
    loadProfiles: suspend (List<Long>) -> Map<Long, OfflineFileProfiles>,
    onDismiss: () -> Unit,
    /** 点「下载」：要下的文件（按集顺序）与选中的档位（original / 1080p / 720p / 480p） */
    onStart: (fileIds: List<Long>, profile: String) -> Unit,
) {
    val effectiveScopes = remember(scopes, singleFileId) {
        when {
            !scopes.isNullOrEmpty() -> scopes
            singleFileId != null -> listOf(
                OfflineDownloadChoices.Scope("file", title, null, listOf(singleFileId), preferred = true),
            )
            else -> emptyList()
        }
    }
    var scopeId by remember(effectiveScopes) {
        mutableStateOf((effectiveScopes.firstOrNull { it.preferred } ?: effectiveScopes.firstOrNull())?.id)
    }
    var entries by remember { mutableStateOf<Map<Long, OfflineFileProfiles>>(emptyMap()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var choice by remember { mutableStateOf<String?>(null) }
    var starting by remember { mutableStateOf(false) }

    val fileIds = remember(effectiveScopes, scopeId) {
        effectiveScopes.firstOrNull { it.id == scopeId }?.fileIds.orEmpty()
    }
    val batch = fileIds.size > 1

    LaunchedEffect(effectiveScopes) {
        if (effectiveScopes.isEmpty()) {
            loading = false
            return@LaunchedEffect
        }
        val all = effectiveScopes.flatMap { it.fileIds }.distinct()
        loading = true
        runCatching { loadProfiles(all) }
            .onSuccess { map ->
                entries = map
                // 默认带上次选的档位；没有/已下架才落到第一档（原画在服务端清单里排第一）
                val profiles = map[all.firstOrNull()]?.profiles.orEmpty()
                choice = profiles.firstOrNull { it.profile == defaultProfile }?.profile
                    ?: profiles.firstOrNull()?.profile
                loading = false
            }
            .onFailure {
                error = it.message ?: "拿不到下载信息"
                loading = false
            }
    }

    // 当前范围里能取的档位（以第一集的档位表为准；批量时大小按各集累加）
    val profileTemplate: List<OfflineProfile> = entries[fileIds.firstOrNull()]?.profiles.orEmpty()
    val missingCount = fileIds.count { entries[it] == null }

    fun totalBytesFor(profile: String): Long =
        fileIds.sumOf { id ->
            entries[id]?.profiles?.firstOrNull { it.profile == profile }?.expectedBytes ?: 0L
        }

    val totalBytes = choice?.let { totalBytesFor(it) } ?: 0L
    val overSpace = totalBytes > freeBytes && totalBytes > 0
    val canStart = !starting && !loading && error == null && choice != null && fileIds.isNotEmpty() && !overSpace

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "下载到 $deviceName",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) {
                    Text("取消", style = McType.sub, color = TextMuted)
                }
                TextButton(
                    onClick = {
                        val p = choice ?: return@TextButton
                        starting = true
                        onStart(fileIds, p)
                    },
                    enabled = canStart,
                ) {
                    if (starting) {
                        CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    } else {
                        Text("下载", style = McType.subheadlineSemibold, color = if (canStart) Accent else TextFaint)
                    }
                }
            }
            Text(title, style = McType.caption, color = TextMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(12.dp))

            when {
                loading -> Box(Modifier.fillMaxWidth().padding(vertical = 36.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted)
                }
                error != null -> Text(error!!, style = McType.footnote, color = TextMuted, lineHeight = 20.sp)
                effectiveScopes.isEmpty() -> Text("都已下载", style = McType.footnote, color = TextMuted)
                else -> Column(Modifier.formSheetScroll().verticalScroll(rememberScrollState()).heightIn(max = 520.dp)) {
                    // 范围分段（剧集）：选中的集 / 未看 / 剩余
                    if (effectiveScopes.size > 1) {
                        Text("下载范围", style = McType.caption, color = TextFaint)
                        Spacer(Modifier.height(6.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            effectiveScopes.forEach { scope ->
                                val on = scope.id == scopeId
                                Box(
                                    Modifier
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(if (on) Accent.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.05f))
                                        .clickable { scopeId = scope.id }
                                        .padding(horizontal = 12.dp, vertical = 8.dp),
                                ) {
                                    Text(scope.label, style = McType.caption, color = if (on) Accent else TextPrimary)
                                }
                            }
                        }
                        effectiveScopes.firstOrNull { it.id == scopeId }?.detail?.let {
                            Spacer(Modifier.height(6.dp))
                            Text(it, style = McType.caption2, color = TextFaint)
                        }
                        Spacer(Modifier.height(14.dp))
                    }
                    // 档位：点一行只是选中
                    Text("画质", style = McType.caption, color = TextFaint)
                    Spacer(Modifier.height(4.dp))
                    profileTemplate.forEach { profile ->
                        val on = profile.profile == choice
                        val bytes = totalBytesFor(profile.profile)
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .clickable { choice = profile.profile }
                                .padding(horizontal = 10.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(
                                Modifier
                                    .size(20.dp)
                                    .clip(CircleShape)
                                    .background(if (on) Accent else Color.Transparent)
                                    .border(1.dp, if (on) Accent else LineColor, CircleShape),
                                contentAlignment = Alignment.Center,
                            ) {
                                if (on) {
                                    Icon(
                                        Icons.Rounded.Check,
                                        contentDescription = null,
                                        tint = Color(0xFF141821),
                                        modifier = Modifier.size(13.dp),
                                    )
                                }
                            }
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(profile.label, style = McType.sub, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(
                                    if (batch) "整批约 ${McFormat.bytes(bytes)}" else "约 ${McFormat.bytes(bytes)}",
                                    style = McType.caption2,
                                    color = TextFaint,
                                )
                            }
                        }
                    }
                    if (missingCount > 0) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "$missingCount 集取不到下载信息，开始下载时会跳过",
                            style = McType.caption2,
                            color = Warning,
                        )
                    }
                    if (overSpace) {
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "本机空间不足:需要 ${McFormat.bytes(totalBytes)},可用 ${McFormat.bytes(freeBytes)}",
                            style = McType.caption2,
                            color = Danger,
                        )
                    }
                    note?.let {
                        Spacer(Modifier.height(10.dp))
                        HorizontalDivider(color = LineColor)
                        Spacer(Modifier.height(8.dp))
                        Text(it, style = McType.caption2, color = TextFaint, lineHeight = 16.sp)
                    }
                    Spacer(Modifier.height(16.dp))
                }
            }
        }
    }
}
