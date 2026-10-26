package io.movieclaw.android.feature.detail

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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.ArtworkCandidateView
import io.movieclaw.android.core.model.ArtworkCandidatesView
import io.movieclaw.android.core.model.CollectionView
import io.movieclaw.android.core.model.DiscoveredTitle
import io.movieclaw.android.core.model.LibraryItemDetailView
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.ReidentifyGroupView
import io.movieclaw.android.core.model.ReidentifyPreviewView
import io.movieclaw.android.core.model.ShareView
import io.movieclaw.android.core.model.TransferPreviewView
import io.movieclaw.android.core.model.TransferStatusView
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Calendar
import io.movieclaw.android.core.designsystem.mcCards
import io.movieclaw.android.core.designsystem.formSheetScroll

/*
 * 详情页「⋯」菜单各动作的面板（iOS 同名弹层的安卓版）。
 *
 * 文案一律照抄 iOS（`AddToCollectionSheet` / `LibraryShareSheet` / `ArtworkPickerSheet` /
 * `TransferItemSheet` / `ReidentifySheet` / `DeleteItemSheets` / `LibraryItemDetailView`
 * 的确认文案），不要就近改写措辞——两端的提示语要能逐字对上。
 */

private val SheetBg = Color(0xFF15161A)

/* ---------------- 加入合集（iOS `AddToCollectionSheet`） ---------------- */

/**
 * 「加入合集」：只列**名单驱动**且自己能动的合集（规则驱动的塞进去会静默消失，
 * 一个点了会报错的选项比没有更糟），并给「新建并加入」——新建时直接把这部片带上。
 */
@Composable
fun AddToCollectionSheet(
    title: String,
    onDismiss: () -> Unit,
    loadCollections: suspend () -> Result<List<CollectionView>>,
    addTo: suspend (Long) -> Result<CollectionView>,
    createAndAdd: suspend (String) -> Result<CollectionView>,
) {
    val feedback = LocalFeedback.current
    val scope = rememberCoroutineScope()
    var rows by remember { mutableStateOf<List<CollectionView>?>(null) }
    var name by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        // 读取失败按空列表处理（同 iOS / Web）：只给「新建」这一条路，不给死路
        rows = loadCollections().getOrDefault(emptyList()).filter { !it.ruleDriven && it.editable }
    }

    SheetScaffold(busy = busy, onDismiss = onDismiss) {
        SheetTitle("加入合集")
        Text(
            "手动合集不会自动收录新片，加进去的就是你挑的那些。",
            fontSize = 13.sp,
            color = TextFaint,
            lineHeight = 19.sp,
        )
        Spacer(Modifier.height(10.dp))
        val list = rows
        when {
            list == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(color = TextFaint, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(8.dp))
                Text("正在读取合集…", fontSize = 14.sp, color = TextFaint)
            }

            list.isEmpty() -> Text("还没有手动合集。下面新建一个。", fontSize = 14.sp, color = TextFaint)

            else -> list.forEach { row ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .height(44.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .clickable(enabled = !busy) {
                            scope.launch {
                                busy = true
                                addTo(row.id)
                                    .onSuccess {
                                        feedback.success("《$title》已加入「${row.name}」")
                                        busy = false
                                        onDismiss()
                                    }
                                    .onFailure { feedback.error(it.message ?: "加入失败，请稍后重试"); busy = false }
                            }
                        }
                        .padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(row.name, fontSize = 15.sp, color = TextPrimary, modifier = Modifier.weight(1f), maxLines = 1)
                    Text("${row.itemCount} 部", fontSize = 12.sp, color = TextFaint)
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                placeholder = { Text("新建合集，取个名字", fontSize = 14.sp, color = TextFaint) },
                singleLine = true,
                colors = sheetFieldColors(),
                modifier = Modifier.weight(1f),
            )
            Button(
                onClick = {
                    val trimmed = name.trim()
                    if (trimmed.isEmpty() || busy) return@Button
                    scope.launch {
                        busy = true
                        createAndAdd(trimmed)
                            .onSuccess {
                                feedback.success("已新建「${it.name}」并加入《$title》")
                                busy = false
                                onDismiss()
                            }
                            .onFailure { feedback.error(it.message ?: "新建失败，请稍后重试"); busy = false }
                    }
                },
                enabled = !busy && name.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.12f), contentColor = TextPrimary),
                shape = RoundedCornerShape(999.dp),
            ) { Text("新建并加入", fontSize = 14.sp) }
        }
        Spacer(Modifier.height(6.dp))
    }
}

/* ---------------- 分享（iOS `LibraryShareSheet`） ---------------- */

private val shareExpiryOptions = listOf(1 to "1 天", 3 to "3 天", 7 to "7 天", 30 to "30 天")
private const val shareDefaultDays = 7
private const val sharePasswordLength = 6
private const val shareMinPassword = 4
private const val shareMaxPassword = 32

/** 访问码字符集：去掉 0/o/1/l 这种口头转述会混淆的字符（同 iOS `sharePasswordAlphabet`） */
private const val sharePasswordAlphabet = "abcdefghijkmnpqrstuvwxyz23456789"

private fun generateSharePassword(): String =
    (0 until sharePasswordLength).map { sharePasswordAlphabet.random() }.joinToString("")

/** 空 = 不设密码；非空须在 4–32 位之间。返回错误文案，合法为 null */
private fun validateSharePassword(password: String): String? {
    val cleaned = password.trim()
    if (cleaned.isEmpty()) return null
    if (cleaned.length < shareMinPassword || cleaned.length > shareMaxPassword) {
        return "密码长度须在 $shareMinPassword–$shareMaxPassword 位之间"
    }
    return null
}

private fun isRelativeShareUrl(url: String): Boolean =
    !(url.lowercase().startsWith("http://") || url.lowercase().startsWith("https://"))

/**
 * 当前有效分享的面板：还没分享过 = 有效期四档 + 密码开关的表单；
 * 已有一条 = 链接 / 密码 / 到期 / 打开次数，可复制、可取消（取消后回到表单，可再生成一条）。
 */
@Composable
fun ItemShareSheet(
    title: String,
    origin: String?,
    onDismiss: () -> Unit,
    loadShare: suspend () -> Result<ShareView?>,
    createShare: suspend (days: Int, password: String?) -> Result<Pair<ShareView, Boolean>>,
    revokeShare: suspend () -> Result<Unit>,
) {
    val feedback = LocalFeedback.current
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    var resolved by remember { mutableStateOf(false) }
    var share by remember { mutableStateOf<ShareView?>(null) }
    var days by remember { mutableStateOf(shareDefaultDays) }
    var passwordOn by remember { mutableStateOf(false) }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmingRevoke by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        share = loadShare().getOrNull()
        resolved = true
    }

    /** 相对路径 `/s/{slug}` 用当前服务器根地址补全（同 iOS `absoluteShareURL`） */
    fun absolute(url: String): String {
        if (!isRelativeShareUrl(url)) return url
        val base = origin?.trimEnd('/') ?: return url
        return if (url.startsWith("/")) base + url else "$base/$url"
    }

    fun copy(text: String, what: String) {
        clipboard.setText(AnnotatedString(text))
        feedback.success("已复制$what")
    }

    SheetScaffold(busy = busy, onDismiss = onDismiss) {
        val current = share
        when {
            !resolved -> Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
            }

            current != null -> {
                SheetTitle("分享《$title》")
                val link = absolute(current.url)
                CopyRow("链接", link, mono = false, locked = false) { copy(link, "链接") }
                current.password?.let { pw ->
                    CopyRow("密码", pw, mono = true, locked = true) { copy(pw, "密码") }
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    shareFacts(current),
                    fontSize = 12.sp,
                    color = TextFaint,
                    lineHeight = 18.sp,
                )
                if (isRelativeShareUrl(current.url)) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "链接用的是当前连接的服务器地址。在「设置 → 网络 → 外部访问」填写外网地址后，链接会用该地址生成。",
                        fontSize = 12.sp,
                        color = TextFaint,
                        lineHeight = 18.sp,
                    )
                }
                Spacer(Modifier.height(14.dp))
                Button(
                    onClick = {
                        val text = buildString {
                            append("《$title》 链接：$link")
                            current.password?.let { append(" 密码：$it") }
                        }
                        copy(text, "链接和密码")
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.14f), contentColor = TextPrimary),
                    shape = RoundedCornerShape(999.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(if (current.password != null) "复制链接和密码" else "复制链接", fontSize = 14.sp, fontWeight = FontWeight.SemiBold) }
                Spacer(Modifier.height(6.dp))
                TextButton(
                    onClick = { confirmingRevoke = true },
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("取消分享", color = Danger, fontSize = 14.sp) }
            }

            else -> {
                SheetTitle("分享《$title》")
                SheetFieldLabel("有效期")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    shareExpiryOptions.forEach { (d, label) ->
                        FilterChip(
                            selected = days == d,
                            onClick = { days = d },
                            label = { Text(label, fontSize = 13.sp) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = Color.White.copy(alpha = 0.16f),
                                labelColor = TextMuted,
                                selectedLabelColor = TextPrimary,
                            ),
                        )
                    }
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    "$days 天后自动失效（${expiryDateTime(days)}）；到期后可以再分享一次。",
                    fontSize = 12.sp,
                    color = TextFaint,
                    lineHeight = 18.sp,
                )
                Spacer(Modifier.height(14.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("密码保护", fontSize = 15.sp, color = TextPrimary, modifier = Modifier.weight(1f))
                    Switch(
                        checked = passwordOn,
                        onCheckedChange = { on ->
                            error = null
                            passwordOn = on
                            if (on && password.isBlank()) password = generateSharePassword()
                        },
                    )
                }
                if (passwordOn) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedTextField(
                            value = password,
                            onValueChange = { password = it.take(shareMaxPassword); error = null },
                            placeholder = { Text("访问密码", fontSize = 14.sp, color = TextFaint) },
                            singleLine = true,
                            textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 15.sp),
                            colors = sheetFieldColors(),
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = { password = generateSharePassword(); error = null }) {
                            Text("换一个", color = TextMuted, fontSize = 14.sp)
                        }
                    }
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    if (passwordOn) "访客打开链接时需要输入这个密码；密码之前不会显示片名和海报。"
                    else "不设密码：拿到链接就能看。",
                    fontSize = 12.sp,
                    color = TextFaint,
                    lineHeight = 18.sp,
                )
                error?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(it, fontSize = 13.sp, color = Danger)
                }
                Spacer(Modifier.height(10.dp))
                Text("访客的播放会出现在「活动」页，你随时可以取消分享。", fontSize = 12.sp, color = TextFaint, lineHeight = 18.sp)
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TextButton(onClick = onDismiss, enabled = !busy) { Text("取消", color = TextMuted, fontSize = 14.sp) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = {
                            validateSharePassword(password)?.let { error = it; return@Button }
                            scope.launch {
                                busy = true
                                createShare(days, password.trim().ifEmpty { null })
                                    .onSuccess { (view, existed) ->
                                        share = view
                                        busy = false
                                        feedback.success(if (existed) "这部影片已有一条有效分享" else "分享链接已生成")
                                    }
                                    .onFailure {
                                        error = it.message ?: "生成分享链接失败，请稍后重试"
                                        busy = false
                                    }
                            }
                        },
                        enabled = !busy,
                        colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color.White),
                        shape = RoundedCornerShape(999.dp),
                    ) {
                        if (busy) {
                            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(8.dp))
                        }
                        Text(if (busy) "正在生成…" else "生成链接", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
        Spacer(Modifier.height(6.dp))
    }

    if (confirmingRevoke) {
        AlertDialog(
            onDismissRequest = { confirmingRevoke = false },
            containerColor = Color(0xFF171A23),
            title = { Text("取消《$title》的分享？", style = McType.bodySemibold, color = TextPrimary) },
            text = {
                Text(
                    "链接立即失效，正在播放的访客会在一分钟内中断。之后可以重新生成一条新链接。",
                    style = McType.sub,
                    color = TextMuted,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmingRevoke = false
                    scope.launch {
                        busy = true
                        revokeShare()
                            .onSuccess {
                                share = null
                                days = shareDefaultDays
                                passwordOn = false
                                password = ""
                                busy = false
                                feedback.success("分享已取消")
                            }
                            .onFailure { feedback.error(it.message ?: "取消分享失败，请稍后重试"); busy = false }
                    }
                }) { Text("取消分享", color = Danger) }
            },
            dismissButton = { TextButton(onClick = { confirmingRevoke = false }) { Text("先不", color = TextMuted) } },
        )
    }
}

/** 「N 天后失效（时间）· 已打开 N 次 · 最近 X 前」（同 iOS `facts`；最后一段没有「最近」就不出） */
private fun shareFacts(share: ShareView): String {
    val parts = mutableListOf("${expiryHint(share.expiresAt)}（${share.expiresAt.orEmpty().take(16).replace('T', ' ')}）")
    parts += if (share.viewCount > 0) "已打开 ${share.viewCount} 次" else "还没有人打开"
    if (share.lastAccessedAt != null && share.viewCount > 0) parts += "最近打开过"
    return parts.joinToString(" · ")
}

/** 到期提示：「N 天后失效」/「N 小时后失效」/「N 分钟后失效」/「已失效」（同 iOS `expiryHint`） */
private fun expiryHint(expiresAt: String?): String {
    val millis = parseIsoMillis(expiresAt) ?: return "已失效"
    val remainingMs = millis - System.currentTimeMillis()
    if (remainingMs <= 0) return "已失效"
    val hours = remainingMs / 3_600_000.0
    return when {
        hours >= 47 -> "${Math.round(hours / 24).toInt()} 天后失效"
        hours >= 1 -> "${hours.toInt()} 小时后失效"
        else -> "${maxOf(1, (remainingMs / 60_000.0).toInt())} 分钟后失效"
    }
}

private fun expiryDateTime(days: Int): String {
    val cal = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, days) }
    return "%04d-%02d-%02d %02d:%02d".format(
        cal.get(Calendar.YEAR), cal.get(Calendar.MONTH) + 1, cal.get(Calendar.DAY_OF_MONTH),
        cal.get(Calendar.HOUR_OF_DAY), cal.get(Calendar.MINUTE),
    )
}

/** 解析服务端 ISO 时间（带 `+00:00` 偏移）；解析不出返回 null */
private fun parseIsoMillis(iso: String?): Long? {
    if (iso.isNullOrBlank()) return null
    return runCatching { java.time.OffsetDateTime.parse(iso).toInstant().toEpochMilli() }
        .recoverCatching { java.time.Instant.parse(iso).toEpochMilli() }
        .getOrNull()
}

@Composable
private fun CopyRow(label: String, value: String, mono: Boolean, locked: Boolean, onCopy: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onCopy)
            .padding(horizontal = 10.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(label, fontSize = 13.sp, color = TextMuted, modifier = Modifier.width(34.dp))
        if (locked) {
            Icon(Icons.Rounded.Lock, contentDescription = null, tint = TextFaint, modifier = Modifier.size(13.dp))
        }
        Text(
            value,
            fontSize = 14.sp,
            color = TextPrimary,
            fontFamily = if (mono) FontFamily.Monospace else null,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.MiddleEllipsis,
            modifier = Modifier.weight(1f),
        )
        Text("复制", fontSize = 13.sp, color = Info)
    }
}

/* ---------------- 更换图片（iOS `ArtworkPickerSheet`） ---------------- */

/**
 * 「更换图片」：背景 / 海报两档候选图，选中即生效（并写回媒体目录，此后刷新元数据不覆盖）。
 * 手动选过的那一档显示蓝色横幅与「恢复自动选图」。
 */
@Composable
fun ArtworkPickerSheet(
    onDismiss: () -> Unit,
    origin: String?,
    loadCandidates: suspend () -> Result<ArtworkCandidatesView>,
    select: suspend (kind: String, filePath: String?) -> Result<Unit>,
) {
    val feedback = LocalFeedback.current
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<ArtworkCandidatesView?>(null) }
    var failed by remember { mutableStateOf(false) }
    var applying by remember { mutableStateOf<String?>(null) }
    var saveError by remember { mutableStateOf<String?>(null) }
    var tab by remember { mutableStateOf("backdrop") }

    suspend fun load() {
        failed = false
        loadCandidates()
            .onSuccess { data = it }
            .onFailure { if (data == null) failed = true }
    }

    LaunchedEffect(Unit) { load() }

    val candidates = if (tab == "poster") data?.posters.orEmpty() else data?.backdrops.orEmpty()
    val locked = if (tab == "poster") data?.posterLocked == true else data?.backdropLocked == true
    val current = if (tab == "poster") data?.currentPoster else data?.currentBackdrop
    val tabLabel = if (tab == "poster") "海报" else "背景"

    fun apply(filePath: String?) {
        scope.launch {
            applying = filePath ?: ""
            saveError = null
            select(tab, filePath)
                .onSuccess { load() }
                .onFailure { saveError = "保存失败：${it.message ?: "请稍后重试"}" }
            applying = null
        }
    }

    SheetScaffold(busy = applying != null, onDismiss = onDismiss) {
        SheetTitle("更换图片")
        Text(
            "选中即生效，并同步写入媒体目录；此后刷新元数据不会覆盖你选的图",
            fontSize = 13.sp,
            color = TextMuted,
            lineHeight = 19.sp,
        )
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("backdrop" to "背景", "poster" to "海报").forEach { (key, label) ->
                FilterChip(
                    selected = tab == key,
                    onClick = { tab = key },
                    label = { Text(label, fontSize = 13.sp) },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = Color.White.copy(alpha = 0.16f),
                        labelColor = TextMuted,
                        selectedLabelColor = TextPrimary,
                    ),
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        if (locked) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(Info.copy(alpha = 0.08f))
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "当前$tabLabel 由你手动选定，刷新元数据不会覆盖",
                    fontSize = 13.sp,
                    color = Info,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = { apply(null) }, enabled = applying == null) {
                    Text("恢复自动选图", fontSize = 13.sp, color = TextPrimary)
                }
            }
            Spacer(Modifier.height(10.dp))
        }
        saveError?.let {
            Text(it, fontSize = 13.sp, color = Danger)
            Spacer(Modifier.height(8.dp))
        }
        when {
            data == null && failed -> {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("候选图加载失败（TMDB 可能不可达）", fontSize = 14.sp, color = TextMuted)
                    Spacer(Modifier.height(8.dp))
                    Button(
                        onClick = { scope.launch { load() } },
                        colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.12f), contentColor = TextPrimary),
                        shape = RoundedCornerShape(999.dp),
                    ) { Text("重试", fontSize = 14.sp) }
                }
            }

            data == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(color = TextFaint, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(8.dp))
                Text("正在拉取候选图…", fontSize = 14.sp, color = TextMuted)
            }

            candidates.isEmpty() -> Text("TMDB 上没有这个条目的$tabLabel", fontSize = 14.sp, color = TextMuted)

            else -> Column(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 360.dp)
                    .formSheetScroll().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                candidates.chunked(3).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEach { c ->
                            ArtworkCell(
                                candidate = c,
                                isCurrent = current == c.filePath,
                                origin = origin,
                                busy = applying != null,
                                modifier = Modifier.weight(1f),
                            ) { apply(c.filePath) }
                        }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = onDismiss, enabled = applying == null) { Text("完成", color = TextPrimary, fontSize = 14.sp) }
        }
        Spacer(Modifier.height(6.dp))
    }
}

@Composable
private fun ArtworkCell(
    candidate: ArtworkCandidateView,
    isCurrent: Boolean,
    origin: String?,
    busy: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .height(96.dp)
            .clip(RoundedCornerShape(10.dp))
            .border(
                if (isCurrent) 2.dp else 1.dp,
                if (isCurrent) Info else LineSoft,
                RoundedCornerShape(10.dp),
            )
            .clickable(enabled = !busy, onClick = onClick),
    ) {
        RemoteImage(
            url = candidate.previewUrl,
            origin = origin,
            modifier = Modifier.fillMaxWidth().height(96.dp),
        )
        if (isCurrent) {
            Box(
                Modifier
                    .align(Alignment.BottomStart)
                    .padding(6.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(Info)
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            ) { Text("当前", fontSize = 10.sp, color = Color.White) }
        }
    }
}

/* ---------------- 转移到其他媒体库（iOS `TransferItemSheet`） ---------------- */

/**
 * 「转移到其他库」：先挑目标库（同类型、非本库），再看转移计划（搬哪些路径、多少字节、
 * 跨不跨盘、有没有被挡），确认后轮询状态直到搬完。
 */
@Composable
fun TransferItemSheet(
    title: String,
    kind: String,
    /** 当前库 id 与来源（tmdb / local）：候选口径同 iOS `loadCandidates` 与后端 `assert_transferable` */
    sourceLibraryId: Long,
    sourceOrigin: String?,
    onDismiss: () -> Unit,
    loadCandidates: suspend () -> Result<List<LibraryView>>,
    loadPreview: suspend (targetId: Long) -> Result<TransferPreviewView>,
    run: suspend (targetId: Long) -> Result<Unit>,
    pollStatus: suspend () -> Result<TransferStatusView>,
    onOpenLibrary: (Long) -> Unit,
) {
    val feedback = LocalFeedback.current
    val scope = rememberCoroutineScope()
    var candidates by remember { mutableStateOf<List<LibraryView>?>(null) }
    var candidatesFailed by remember { mutableStateOf(false) }
    var targetId by remember { mutableStateOf<Long?>(null) }
    var preview by remember { mutableStateOf<TransferPreviewView?>(null) }
    var loadingPreview by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf<TransferStatusView?>(null) }
    var starting by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        // iOS `loadCandidates`：`libs.filter { $0.id != libraryId && $0.source == source }`
        // ——比的是**库**的来源（不是条目的），且要把当前库排掉（转到自己是后端会拒的）
        val source = sourceOrigin
        loadCandidates()
            .onSuccess { all ->
                candidates = all.filter {
                    it.id != sourceLibraryId && it.kind == kind && (source == null || it.source == source)
                }
            }
            .onFailure {
                candidatesFailed = true
                error = "读取媒体库列表失败，请稍后重试"
            }
    }

    // 选好目标库立刻算计划：用户要先看清「搬到哪、搬多少」才谈得上确认
    LaunchedEffect(targetId) {
        val id = targetId ?: return@LaunchedEffect
        loadingPreview = true
        error = null
        loadPreview(id)
            .onSuccess { preview = it }
            .onFailure { error = it.message ?: "计算转移计划失败，请稍后重试" }
        loadingPreview = false
    }

    // 转移中：每秒看一次状态，搬完就停（iOS `pollWhileRunning` 同口径）
    LaunchedEffect(status?.running) {
        while (status?.running == true) {
            delay(1000)
            pollStatus().onSuccess { next ->
                status = next
                if (!next.running && next.errors.isEmpty()) feedback.success("已转移到「${next.targetLibraryName ?: ""}」")
            }
        }
    }

    SheetScaffold(busy = starting, onDismiss = onDismiss) {
        SheetTitle("把「$title」转移到其他媒体库")
        Text(
            if (kind == "tv") "分错库时用它补救（例如韩剧被判进了「大陆华语剧」）。磁盘上的整个条目目录（视频、NFO、海报、字幕）会连同库存记录一起搬到目标库；目录名原样保留，需要规范化请到目标库运行「整理文件名」。"
            else "放错库时用它补救。这个条目的文件（连同同名的 NFO、字幕）会连同库存记录一起搬到目标库；文件在库里的所在目录结构原样保留，同目录下别的条目留在原地不动。",
            fontSize = 13.sp,
            color = Color.White.copy(alpha = 0.8f),
            lineHeight = 19.sp,
        )
        Spacer(Modifier.height(12.dp))
        val done = status != null && status?.running == false
        val list = candidates
        when {
            done -> {
                val st = status!!
                Text(
                    if (st.errors.isEmpty()) "已转移到「${st.targetLibraryName ?: ""}」" else "部分转移完成",
                    fontSize = 16.sp,
                    color = if (st.errors.isEmpty()) TextPrimary else Danger,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.height(10.dp))
                if (st.movedPaths.isEmpty()) {
                    Text("没有搬运任何磁盘路径", fontSize = 13.sp, color = TextMuted)
                } else {
                    PathBox(st.movedPaths)
                }
                Spacer(Modifier.height(10.dp))
                Text(
                    "已随迁 ${st.filesRelocated} 条库存记录（${McFormat.bytes(st.bytesMoved)}）" +
                        if (st.removedDirs > 0) "，清理空目录 ${st.removedDirs} 个" else "",
                    fontSize = 13.sp,
                    color = TextMuted,
                )
                if (st.subscriptionMoved) {
                    Spacer(Modifier.height(6.dp))
                    Text("该片的订阅已一并改挂到目标库，后续剧集直接入新库。", fontSize = 13.sp, color = TextMuted)
                }
                st.errors.forEach {
                    Spacer(Modifier.height(4.dp))
                    Text(it, fontSize = 13.sp, color = Danger)
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TextButton(onClick = onDismiss) { Text("留在本页", color = TextMuted, fontSize = 14.sp) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { st.targetLibraryId?.let(onOpenLibrary); onDismiss() },
                        colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.14f), contentColor = TextPrimary),
                        shape = RoundedCornerShape(999.dp),
                    ) { Text("去目标库查看", fontSize = 14.sp) }
                }
            }

            status?.running == true -> {
                val st = status!!
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(color = Info, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(10.dp))
                    Text(
                        "正在转移" + if (st.total > 0) "（${st.processed}/${st.total}）" else "" + "；跨盘转移需要完整复制文件，请勿关闭页面以外的操作",
                        fontSize = 13.sp,
                        color = TextMuted,
                    )
                }
            }

            list == null -> Text("正在读取媒体库…", fontSize = 14.sp, color = TextMuted)

            list.isEmpty() -> Text(
                "没有其他${if (kind == "tv") "剧集" else "电影"}库可选——请先在「媒体库」页新建一个，再回来转移。",
                fontSize = 14.sp,
                color = TextMuted,
            )

            candidatesFailed -> Text(
                "读取媒体库列表失败，请稍后重试",
                fontSize = 14.sp,
                color = Danger,
            )

            else -> {
                // 失败原因两个阶段都要看得见（拉列表失败 / 算计划失败），别等计划真出来才显示
                error?.let {
                    Text(it, fontSize = 13.sp, color = Danger)
                    Spacer(Modifier.height(8.dp))
                }
                if (preview == null) {
                    if (loadingPreview) {
                        Text("正在计算转移计划…", fontSize = 14.sp, color = TextMuted)
                    } else {
                        Text("转移到", fontSize = 13.sp, color = TextFaint)
                        Spacer(Modifier.height(6.dp))
                        list.forEach { lib ->
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .height(44.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .clickable { targetId = lib.id }
                                    .padding(horizontal = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(lib.name, fontSize = 15.sp, color = TextPrimary, modifier = Modifier.weight(1f), maxLines = 1)
                                if (lib.isDefault) Text("默认库", fontSize = 12.sp, color = TextFaint)
                            }
                        }
                    }
                }
                val plan = preview
                if (plan != null) {
                    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            "${plan.moves.size} 个路径 · ${McFormat.bytes(plan.totalBytes)}" +
                                if (plan.missingCount > 0) " · ${plan.missingCount} 个缺失记录随迁" else "",
                            fontSize = 13.sp,
                            color = TextMuted,
                        )
                        plan.moves.take(6).forEach { move ->
                            Text("↳ ${plan.targetLibraryName} · ${move.targetPath}", fontSize = 11.sp, color = TextFaint, maxLines = 1)
                        }
                    }
                    if (plan.crossDevice) {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            "目标库与当前位置不在同一块盘：文件需要完整复制（${McFormat.bytes(plan.totalBytes)}），耗时取决于体积与盘速；复制会产生新文件，与下载器做种目录的硬链接关系将断开，两边各占一份空间。",
                            fontSize = 12.sp,
                            color = TextMuted,
                            lineHeight = 18.sp,
                        )
                    }
                    plan.skips.forEach { skip ->
                        Spacer(Modifier.height(4.dp))
                        Text("${skip.filePath}：${skip.reason}", fontSize = 11.sp, color = TextFaint, fontFamily = FontFamily.Monospace)
                    }
                    plan.blocked.forEach {
                        Spacer(Modifier.height(6.dp))
                        Text(it, fontSize = 13.sp, color = Danger)
                    }
                    error?.let {
                        Spacer(Modifier.height(6.dp))
                        Text(it, fontSize = 13.sp, color = Danger)
                    }
                    Spacer(Modifier.height(14.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        TextButton(onClick = { preview = null; targetId = null; error = null }, enabled = !starting) {
                            Text("取消", color = TextMuted, fontSize = 14.sp)
                        }
                        Spacer(Modifier.weight(1f))
                        Button(
                            onClick = {
                                val id = targetId ?: return@Button
                                scope.launch {
                                    starting = true
                                    run(id)
                                        .onSuccess {
                                            pollStatus().onSuccess { status = it }
                                            if (status == null) {
                                                // 状态还没写进去：先给一个「进行中」的壳，轮询会立刻接上
                                                status = TransferStatusView(running = true)
                                            }
                                        }
                                        .onFailure {
                                            error = it.message ?: "转移失败，请稍后重试"
                                            starting = false
                                        }
                                    starting = false
                                }
                            },
                            enabled = !starting && plan.blocked.isEmpty(),
                            colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color.White),
                            shape = RoundedCornerShape(999.dp),
                        ) {
                            if (starting) {
                                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                                Spacer(Modifier.width(8.dp))
                            }
                            Text("确认转移", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(6.dp))
    }
}

/* ---------------- 修正识别结果（iOS `ReidentifySheet`） ---------------- */

/**
 * 「修正识别结果」：打开即重走一遍识别链（预览接口就是重走），把机器结论摊开给人拍板。
 * 每组三个出口——按结论改挂 / 标为非独立作品 / 自己搜一个；关掉窗口则什么都不改。
 */
@Composable
fun ReidentifySheet(
    onDismiss: () -> Unit,
    origin: String?,
    loadPreview: suspend () -> Result<ReidentifyPreviewView>,
    assign: suspend (fileIds: List<Long>, titleRef: String) -> Result<Unit>,
    markExtras: suspend (fileIds: List<Long>) -> Result<Unit>,
    searchTitles: suspend (String) -> Result<List<DiscoveredTitle>>,
) {
    val feedback = LocalFeedback.current
    val scope = rememberCoroutineScope()
    var preview by remember { mutableStateOf<ReidentifyPreviewView?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    /** 已拍板的组：group.key → 结果文案（拍板后不再给按钮） */
    var settled by remember { mutableStateOf(mapOf<String, String>()) }
    val sourceLabels = mapOf(
        "path_tag" to "目录名的 tmdbid 标记",
        "nfo" to "NFO",
        "resolved" to "名称解析 + TMDB 收敛",
    )
    val codeLabels = mapOf(
        "tmdb_unreachable" to "TMDB 不可达",
        "kind_mismatch" to "类型与本库不符",
        "ambiguous" to "候选之间分不出",
        "no_match" to "TMDB 里没找到匹配",
        "unparsable" to "从文件名认不出片名",
    )

    LaunchedEffect(Unit) {
        loadPreview()
            .onSuccess { preview = it }
            .onFailure { error = it.message ?: "重新识别失败，请稍后重试" }
    }

    fun act(group: ReidentifyGroupView, message: String, work: suspend () -> Result<Unit>) {
        scope.launch {
            work()
                .onSuccess {
                    settled = settled + (group.key to message)
                    feedback.success(message)
                }
                .onFailure { feedback.error(it.message ?: "操作失败，请稍后重试") }
        }
    }

    SheetScaffold(busy = false, onDismiss = onDismiss) {
        SheetTitle("修正识别结果")
        val p = preview
        when {
            error != null -> {
                Text(error!!, fontSize = 14.sp, color = Danger)
                Spacer(Modifier.height(10.dp))
                Button(
                    onClick = { error = null; scope.launch { loadPreview().onSuccess { preview = it }.onFailure { error = it.message } } },
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.12f), contentColor = TextPrimary),
                    shape = RoundedCornerShape(999.dp),
                ) { Text("重试", fontSize = 14.sp) }
            }

            p == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(color = TextFaint, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(8.dp))
                Text("正在重新识别…", fontSize = 14.sp, color = TextMuted)
            }

            else -> {
                Text(
                    "已重走识别链。下面是机器给出的结论——" +
                        (if (p.movie) "电影" else "剧集") +
                        "库按「名称解析 + TMDB 收敛」判定，改挂会记为人工身份、扫描不会再翻案，条目 NFO 里矛盾的 tmdbid 也会被一并改正；但目录名上的标记需要你自己改，否则下次整理/重扫的命名仍会带着旧 id。关掉这个窗口则不会有任何改动。",
                    fontSize = 12.sp,
                    color = TextMuted.copy(alpha = 0.8f),
                    lineHeight = 18.sp,
                )
                if (p.pinnedIdentity) {
                    Spacer(Modifier.height(8.dp))
                    Text("改挂会记为人工身份，之后识别器升级不再自动翻案", fontSize = 12.sp, color = Info)
                }
                if (p.unreachable) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "有文件因为 TMDB 不可达没能得出结论——那是网络问题不是识别问题。建议先修好网络再来，此刻的结论不足以据此拍板。",
                        fontSize = 12.sp,
                        color = Danger,
                        lineHeight = 18.sp,
                    )
                }
                if (p.skippedMissing > 0) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "另有 ${p.skippedMissing} 个文件已从磁盘消失（缺失清单里那些），没有实体可供识别，保持原身份不参与。",
                        fontSize = 12.sp,
                        color = TextFaint,
                        lineHeight = 18.sp,
                    )
                }
                Spacer(Modifier.height(12.dp))
                // 现身份卡：拍板前先看清「现在挂的是谁」
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.White.copy(alpha = 0.03f))
                        .border(1.dp, LineSoft, RoundedCornerShape(12.dp))
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    RemoteImage(
                        url = p.current.posterUrl,
                        origin = origin,
                        modifier = Modifier.width(44.dp).height(64.dp).clip(RoundedCornerShape(8.dp)),
                    )
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("当前身份", fontSize = 12.sp, color = TextFaint)
                        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(p.current.title, fontSize = 14.sp, color = TextPrimary.copy(alpha = 0.95f), maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                            p.current.year?.let { Text(it.toString(), fontSize = 14.sp, color = TextMuted) }
                        }
                        p.current.tmdbId?.let { Text("TMDB #$it ↗", fontSize = 12.sp, color = TextMuted) }
                    }
                }
                Spacer(Modifier.height(14.dp))
                Column(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(max = 320.dp)
                        .formSheetScroll().verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    p.groups.forEach { group ->
                        ReidentifyGroupCard(
                            group = group,
                            movie = p.movie,
                            origin = origin,
                            sourceLabels = sourceLabels,
                            codeLabels = codeLabels,
                            settledMessage = settled[group.key],
                            searchSeed = p.searchSeed,
                            onAssign = { ref, label ->
                                act(group, "${group.fileCount} 个文件已改挂为《$label》") { assign(group.fileIds, ref) }
                            },
                            onExtras = {
                                act(group, "${group.fileCount} 个文件已标为非独立作品") { markExtras(group.fileIds) }
                            },
                            onSearch = searchTitles,
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = onDismiss) { Text("关闭", color = TextPrimary, fontSize = 14.sp) }
        }
        Spacer(Modifier.height(6.dp))
    }
}

@Composable
private fun ReidentifyGroupCard(
    group: ReidentifyGroupView,
    movie: Boolean,
    origin: String?,
    sourceLabels: Map<String, String>,
    codeLabels: Map<String, String>,
    settledMessage: String?,
    searchSeed: String,
    onAssign: (titleRef: String, label: String) -> Unit,
    onExtras: () -> Unit,
    onSearch: suspend (String) -> Result<List<DiscoveredTitle>>,
) {
    val outcome = group.outcome
    var searching by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf(searchSeed) }
    var results by remember { mutableStateOf<List<DiscoveredTitle>?>(null) }
    val scope = rememberCoroutineScope()

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.03f))
            .border(1.dp, LineSoft, RoundedCornerShape(12.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("${group.fileCount} 个文件", fontSize = 12.sp, color = TextFaint)
        group.sampleNames.take(3).forEach {
            Text(it, fontSize = 11.sp, color = TextFaint, fontFamily = FontFamily.Monospace, maxLines = 1)
        }
        when {
            settledMessage != null -> Text(settledMessage, fontSize = 13.sp, color = Info)

            outcome.title != null -> {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    RemoteImage(
                        url = outcome.posterUrl,
                        origin = origin,
                        modifier = Modifier.width(38.dp).height(54.dp).clip(RoundedCornerShape(6.dp)),
                    )
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(outcome.title, fontSize = 14.sp, color = TextPrimary, maxLines = 2, modifier = Modifier.weight(1f, fill = false))
                            outcome.year?.let { Text(it.toString(), fontSize = 13.sp, color = TextMuted) }
                        }
                        outcome.source?.let { Text("依据：${sourceLabels[it] ?: it}", fontSize = 11.sp, color = TextFaint) }
                    }
                }
                if (outcome.sameAsCurrent) {
                    Text("重新识别的结论：与当前一致", fontSize = 12.sp, color = TextMuted)
                }
                outcome.candidates.takeIf { it.isNotEmpty() }?.let { list ->
                    Text("「都不对？」候选", fontSize = 11.sp, color = TextFaint)
                    list.take(4).forEach { c ->
                        Text("· ${c.title}${c.year?.let { " ($it)" } ?: ""}", fontSize = 12.sp, color = TextMuted, maxLines = 1)
                    }
                }
            }

            else -> {
                val code = outcome.code?.let { "（${codeLabels[it] ?: it}）" } ?: ""
                Text("没能认出来$code${outcome.reason ?: ""}", fontSize = 13.sp, color = TextMuted)
            }
        }
        if (settledMessage == null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (outcome.tmdbId != null && !outcome.sameAsCurrent) {
                    TextButton(onClick = { onAssign("tmdb:${if (movie) "movie" else "tv"}:${outcome.tmdbId}", outcome.title ?: "") }) {
                        Text("改挂到这里", fontSize = 13.sp, color = Info)
                    }
                }
                TextButton(onClick = onExtras) { Text("标为非独立作品", fontSize = 13.sp, color = TextMuted) }
                TextButton(onClick = { searching = !searching; results = null }) {
                    Text("都不对，自己搜…", fontSize = 13.sp, color = TextMuted)
                }
            }
        }
        if (searching && settledMessage == null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    placeholder = { Text("片名", fontSize = 14.sp, color = TextFaint) },
                    singleLine = true,
                    colors = sheetFieldColors(),
                    modifier = Modifier.weight(1f),
                )
                Button(
                    onClick = {
                        scope.launch { results = onSearch(query).getOrDefault(emptyList()) }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.12f), contentColor = TextPrimary),
                    shape = RoundedCornerShape(999.dp),
                ) { Text("搜索", fontSize = 13.sp) }
            }
            results?.forEach { t ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .height(40.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .clickable { onAssign(t.titleRef, t.title) }
                        .padding(horizontal = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    RemoteImage(
                        url = t.posterUrl,
                        origin = origin,
                        modifier = Modifier.width(24.dp).height(34.dp).clip(RoundedCornerShape(4.dp)),
                    )
                    Text(t.title, fontSize = 14.sp, color = TextPrimary, maxLines = 1, modifier = Modifier.weight(1f))
                    t.releaseYear?.let { Text(it.toString(), fontSize = 12.sp, color = TextMuted) }
                }
            }
        }
    }
}

/* ---------------- 删除影片（iOS `DeleteItemSheet`） ---------------- */

/**
 * 删除整个条目：讲透后果 → 勾选确认 → 红色按钮 → 结果清单。
 * 「这不是从列表移除」，磁盘上的目录连 NFO/海报/字幕一起删。
 */
@Composable
fun DeleteItemSheet(
    detail: LibraryItemDetailView,
    onDismiss: () -> Unit,
    run: suspend () -> Result<io.movieclaw.android.core.model.ItemDeleteResultView>,
    onDeleted: () -> Unit,
) {
    var confirmed by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<io.movieclaw.android.core.model.ItemDeleteResultView?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val paths = detail.entryDirs.ifEmpty { detail.files.mapNotNull { it.filePath } }

    SheetScaffold(busy = busy || result != null, onDismiss = onDismiss) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Rounded.Delete, contentDescription = null, tint = Danger, modifier = Modifier.size(18.dp))
            Text("删除「${detail.title}」", style = McType.bodySemibold, color = TextPrimary)
        }
        Spacer(Modifier.height(12.dp))
        val done = result
        if (done != null) {
            Text(
                if (done.errors.isEmpty()) "已从磁盘彻底删除" else "部分删除完成",
                style = McType.bodySemibold,
                color = if (done.errors.isEmpty()) TextPrimary else Danger,
            )
            Spacer(Modifier.height(12.dp))
            if (done.removedPaths.isEmpty()) {
                Text("没有删除任何磁盘路径", fontSize = 13.sp, color = TextMuted)
            } else {
                PathBox(done.removedPaths)
            }
            done.errors.forEach {
                Spacer(Modifier.height(4.dp))
                Text(it, fontSize = 13.sp, color = Danger)
            }
            Spacer(Modifier.height(10.dp))
            Text("已清理 ${done.rowsDeleted} 条台账，释放 ${McFormat.bytes(done.freedBytes)}。", fontSize = 13.sp, color = TextMuted)
            Spacer(Modifier.height(16.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Button(
                    onClick = onDeleted,
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.14f), contentColor = TextPrimary),
                    shape = RoundedCornerShape(999.dp),
                ) { Text("回到库存页", fontSize = 14.sp) }
            }
        } else {
            Text(
                "这不是「从列表移除」——将把下列目录从磁盘彻底删除，包括视频文件、NFO、海报、字幕等全部刮削产物，" +
                    "共 ${detail.fileCount} 个媒体文件、${McFormat.bytes(detail.totalSizeBytes)}。此操作不可恢复。",
                fontSize = 14.sp,
                color = Color.White.copy(alpha = 0.8f),
                lineHeight = 20.sp,
            )
            Spacer(Modifier.height(14.dp))
            if (paths.isEmpty()) {
                Text("没有可列的磁盘路径", fontSize = 13.sp, color = TextMuted)
            } else {
                PathBox(paths)
            }
            Spacer(Modifier.height(14.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = confirmed, onCheckedChange = { confirmed = it })
                Text("我已明白：以上目录及其中全部文件将被永久删除，无法恢复。", fontSize = 13.sp, color = TextMuted, lineHeight = 18.sp)
            }
            error?.let {
                Spacer(Modifier.height(10.dp))
                Text(it, fontSize = 13.sp, color = Danger)
            }
            Spacer(Modifier.height(16.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                SheetDangerButton(
                    text = if (busy) "正在删除…" else "彻底删除",
                    enabled = confirmed,
                    busy = busy,
                ) {
                    scope.launch {
                        busy = true
                        error = null
                        run()
                            .onSuccess { result = it }
                            .onFailure { error = it.message ?: "删除失败，请稍后重试" }
                        busy = false
                    }
                }
            }
        }
        Spacer(Modifier.height(8.dp))
    }
}

/* ---------------- 两个确认框（刷新元数据 / 清除观看记录） ---------------- */

/** 「刷新元数据」的确认（iOS 两套文案：视频库读 NFO、刮削库重新获取） */
@Composable
fun RefreshMetadataDialog(
    detail: LibraryItemDetailView,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val readsNfo = detail.kind == "video"
    val title = if (readsNfo) "重新读取《${detail.title}》的 NFO 与封面？" else "刷新《${detail.title}》的元数据？"
    val header = if (readsNfo) "本次会：" else "本次刷新会："
    val bullets = if (readsNfo) {
        listOf(
            "重新读取视频旁同名的 NFO 文件，标题、简介、系列等以 NFO 为准",
            "重新生成封面",
            "不联网，不会改动你的文件",
        )
    } else {
        listOf(
            "重新获取这部作品的简介、评分和演职员",
            "重新下载海报和背景图（你手动锁定的不动）",
            "同步更新影片文件夹里的海报和 NFO 信息文件",
            "不会改动你的视频文件",
        )
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF171A23),
        title = { Text(title, style = McType.bodySemibold, color = TextPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(header, style = McType.sub, color = TextMuted)
                bullets.forEach { Text("· $it", style = McType.sub, color = TextMuted) }
            }
        },
        confirmButton = { TextButton(onClick = onConfirm) { Text(if (readsNfo) "读取" else "刷新", color = Accent) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) } },
    )
}

/** 「清除观看记录」的确认（iOS `clearHistory` 的 confirm 文案） */
@Composable
fun ClearHistoryDialog(
    title: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF171A23),
        title = { Text("清除《$title》的观看记录？", style = McType.bodySemibold, color = TextPrimary) },
        text = {
            Text(
                "续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录。",
                style = McType.sub,
                color = TextMuted,
            )
        },
        confirmButton = { TextButton(onClick = onConfirm) { Text("清除", color = Danger) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) } },
    )
}

/* ---------------- 面板里的小件 ---------------- */

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun SheetScaffold(
    busy: Boolean,
    onDismiss: () -> Unit,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = { if (!busy) onDismiss() },
        containerColor = SheetBg,
        contentColor = TextPrimary,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .formSheetScroll().verticalScroll(rememberScrollState())
                .padding(horizontal = mcCards.pagePadding, vertical = 4.dp),
            content = content,
        )
    }
}

@Composable
private fun SheetTitle(text: String) {
    Text(text, style = McType.bodySemibold, color = TextPrimary, modifier = Modifier.padding(bottom = 8.dp))
}

@Composable
private fun SheetFieldLabel(text: String) {
    Text(text, fontSize = 12.sp, color = TextFaint, modifier = Modifier.padding(bottom = 6.dp))
}

@Composable
private fun PathBox(paths: List<String>) {
    Column(
        Modifier
            .fillMaxWidth()
            .heightIn(max = 180.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.03f))
            .border(1.dp, LineSoft, RoundedCornerShape(12.dp))
            .padding(12.dp)
            .formSheetScroll().verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        paths.forEach { Text(it, fontSize = 12.sp, color = Color.White.copy(alpha = 0.7f), fontFamily = FontFamily.Monospace) }
    }
}

@Composable
private fun SheetDangerButton(
    text: String,
    enabled: Boolean = true,
    busy: Boolean = false,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled && !busy,
        colors = ButtonDefaults.buttonColors(
            containerColor = Danger,
            contentColor = Color.White,
            disabledContainerColor = Danger.copy(alpha = 0.35f),
            disabledContentColor = Color.White.copy(alpha = 0.6f),
        ),
        shape = RoundedCornerShape(999.dp),
    ) {
        if (busy) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun sheetFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = TextPrimary,
    unfocusedTextColor = TextPrimary,
    focusedBorderColor = Color.White.copy(alpha = 0.3f),
    unfocusedBorderColor = Color.White.copy(alpha = 0.15f),
    cursorColor = Accent,
)
