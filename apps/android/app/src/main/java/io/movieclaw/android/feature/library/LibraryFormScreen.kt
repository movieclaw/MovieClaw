package io.movieclaw.android.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.DirectoryPickerSheet
import io.movieclaw.android.core.designsystem.headTruncatedPath
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.FsBrowseView
import io.movieclaw.android.core.model.LibraryPayload
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.MemberView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 媒体库表单（创建 / 编辑两用；Web `library-form-dialog.tsx`，iOS `LibraryFormSheet`）。
 *
 * 路由 `libraryForm`（创建）与 `libraryForm/{libraryId}`（编辑）。此前「创建媒体库 /
 * 编辑媒体库…」落点是 `onOpenWebManage`——一个**没有接线**的参数（AppNav 里根本没传），
 * 点了毫无反应（实机反馈「不可用」）。现在原生化：表单字段照 Web/IOS 的分组——
 * 名称 / 类型与来源（仅创建）/ 根路径 / 内容开关 / 可见范围。
 *
 * 「根目录」是服务器上的绝对路径（NAS 目录）：照 iOS 走 `GET /fs/browse` 的目录选择器点选
 * （只读、只列子目录），不再手输——Docker 部署时宿主机看到的路径在容器里可能根本不存在。
 */
@HiltViewModel
class LibraryFormViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {

    /** 编辑目标；null = 创建 */
    val libraryId: Long = savedStateHandle.get<String>("libraryId")?.toLongOrNull() ?: -1L
    val isEdit: Boolean get() = libraryId > 0

    data class Ui(
        val loading: Boolean = true,
        val saving: Boolean = false,
        val error: String? = null,
        val members: List<MemberView> = emptyList(),
        /** 编辑时带出的原值（rootPaths 等要整份回显） */
        val original: LibraryView? = null,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    /** `GET /fs/browse`：目录选择器逐级下钻（与 iOS `SettingsBDirectoryPicker` 同一个只读接口）；失败抛给 UI 提示 */
    suspend fun browse(path: String?): FsBrowseView {
        val origin = origin ?: throw IllegalStateException("尚未连接服务器")
        return apiFactory.forOrigin(origin).fsBrowse(path).dataOrThrow()
    }

    init { load() }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: run { _ui.update { it.copy(loading = false) }; return@launch }
            val api = apiFactory.forOrigin(origin)
            // 成员清单（可见范围 selected 时勾人用；拉不到就不显示这一组）
            val members = runCatching { api.members().dataOrThrow() }.getOrDefault(emptyList())
            if (!isEdit) {
                _ui.update { it.copy(loading = false, members = members) }
                return@launch
            }
            runCatching {
                // 列表接口里就有这个库的完整档案（rootPaths / 开关 / 可见范围）
                api.libraries().dataOrThrow().firstOrNull { it.id == libraryId }
                    ?: throw IllegalStateException("找不到要编辑的媒体库")
            }.onSuccess { lib ->
                _ui.update { it.copy(loading = false, members = members, original = lib) }
            }.onFailure { e ->
                _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
            }
        }
    }

    fun save(payload: LibraryPayload, onDone: (String?) -> Unit) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(saving = true, error = null) }
            val call = runCatching {
                if (isEdit) apiFactory.forOrigin(origin).updateLibrary(libraryId, payload).dataOrThrow()
                else apiFactory.forOrigin(origin).createLibrary(payload).dataOrThrow()
            }
            call.onSuccess {
                _ui.update { it.copy(saving = false) }
                onDone(null)
            }.onFailure { e ->
                _ui.update { it.copy(saving = false, error = friendlyMessage(e)) }
                onDone(friendlyMessage(e))
            }
        }
    }
}

/** 表单里的一组开关行（「标题 + 说明 + 开关」，照设置页的行） */
@Composable
private fun FormSwitch(
    title: String,
    subtitle: String,
    checked: Boolean,
    enabled: Boolean = true,
    onChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled) { onChange(!checked) }
            .padding(vertical = 8.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = McType.subheadline, color = if (enabled) TextPrimary else TextFaint)
            Text(subtitle, style = McType.caption, color = TextFaint, lineHeight = 17.sp)
        }
        Spacer(Modifier.width(12.dp))
        androidx.compose.material3.Switch(
            checked = checked,
            onCheckedChange = onChange,
            enabled = enabled,
            colors = androidx.compose.material3.SwitchDefaults.colors(checkedTrackColor = Accent),
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, style = McType.caption, color = TextFaint, modifier = Modifier.padding(top = 14.dp, bottom = 6.dp))
}

@Composable
private fun FormFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = TextPrimary,
    unfocusedTextColor = TextPrimary,
    focusedBorderColor = Color.White.copy(alpha = 0.3f),
    unfocusedBorderColor = Color.White.copy(alpha = 0.15f),
    cursorColor = Accent,
)

@Composable
fun LibraryFormScreen(
    onBack: (Boolean) -> Unit,
    vm: LibraryFormViewModel = hiltViewModel(),
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val original = ui.original

    // 表单状态（编辑时先落原值）
    var name by remember(original) { mutableStateOf(original?.name ?: "") }
    // 类型与来源仅创建时可改（服务端更新时忽略）
    var kind by remember(original) { mutableStateOf(original?.kind ?: "movie") }
    var source by remember(original) { mutableStateOf(original?.source ?: "tmdb") }
    var roots by remember(original) {
        mutableStateOf(original?.rootPaths?.filter { it.isNotBlank() } ?: emptyList())
    }
    // 目录选择器：-1 = 追加一条；>=0 = 原位替换第几条（iOS ManageRootsEditor.PickTarget）
    var pickTarget by remember { mutableStateOf<Int?>(null) }
    var thumbs by remember(original) { mutableStateOf(original?.let { !it.excludeFromHome } ?: true) }
    var chapters by remember(original) { mutableStateOf(original?.chapterJob != null) }
    var skipIntro by remember(original) { mutableStateOf(original?.kind == "tv") }
    var excludeHome by remember(original) { mutableStateOf(original?.excludeFromHome ?: false) }
    var seriesCollections by remember(original) { mutableStateOf(original?.kind != "tv" || true) }
    var realtimeWatch by remember(original) { mutableStateOf(original?.networkMount != true) }
    var accessEveryone by remember(original) { mutableStateOf(original?.accessMode != "selected") }
    var selectedMembers by remember(original) { mutableStateOf(original?.memberIds?.toSet<Long>() ?: emptySet<Long>()) }

    // 章节开关的初值：编辑时按原库是否已有章节作业；创建默认关（Web 同）
    LaunchedEffect(original) {
        if (original == null) chapters = false
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(Bg)
            .imePadding(),
    ) {
        McTopBar(
            variant = McTopBarVariant.Sub,
            title = if (vm.isEdit) "编辑媒体库" else "创建媒体库",
            onBack = { onBack(false) },
        )
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            ui.error?.let {
                Text(it, style = McType.footnote, color = Danger, lineHeight = 18.sp)
                Spacer(Modifier.height(8.dp))
            }

            SectionLabel("名称")
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                singleLine = true,
                textStyle = McType.body.copy(color = TextPrimary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                colors = FormFieldColors(),
                shape = RoundedCornerShape(10.dp),
                modifier = Modifier.fillMaxWidth(),
            )

            if (!vm.isEdit) {
                SectionLabel("内容形态")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(
                        "movie" to "电影",
                        "tv" to "剧集",
                        "video" to "其他视频",
                    ).forEach { (value, label) ->
                        FormChip(label, on = kind == value) { kind = value }
                    }
                }
                SectionLabel("身份来源")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(
                        "tmdb" to "TMDB（电影 / 剧集刮削）",
                        "local" to "本地（NFO 为准）",
                    ).forEach { (value, label) ->
                        FormChip(label, on = source == value) { source = value }
                    }
                }
            } else if (original != null) {
                SectionLabel("内容形态")
                Text(
                    "${if (original.kind == "movie") "电影" else if (original.kind == "tv") "剧集" else "其他视频"} · 创建后不可改",
                    style = McType.footnote, color = TextFaint,
                )
            }

            SectionLabel("根目录（第一个为主根，新内容落在这里）")
            // 行内不是输入框而是「浏览点选」（iOS ManageRootsEditor）：点路径从该路径开始重选，
            // 确认后原位替换；第一条挂「主根」签，其余可一键设为主根（提到列表首位）
            roots.forEachIndexed { index, root ->
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Rounded.Folder, contentDescription = null,
                        tint = Accent.copy(alpha = 0.8f), modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        headTruncatedPath(root),
                        style = McType.footnote.copy(fontFamily = FontFamily.Monospace),
                        color = TextPrimary,
                        maxLines = 1,
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(6.dp))
                            .clickable { pickTarget = index }
                            .padding(vertical = 4.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    if (index == 0) {
                        Text(
                            "主根", fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = Accent,
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .background(Accent.copy(alpha = 0.15f))
                                .padding(horizontal = 7.dp, vertical = 2.dp),
                        )
                    } else {
                        Text(
                            "设为主根",
                            style = McType.caption, color = TextMuted,
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable { roots = listOf(root) + roots.filter { it != root } }
                                .padding(horizontal = 6.dp, vertical = 4.dp),
                        )
                    }
                    Spacer(Modifier.width(2.dp))
                    Icon(
                        Icons.Rounded.Close, contentDescription = "移除 $root",
                        tint = TextFaint,
                        modifier = Modifier
                            .size(26.dp)
                            .clip(RoundedCornerShape(999.dp))
                            .clickable { roots = roots.filter { it != root } }
                            .padding(6.dp),
                    )
                }
            }
            Text(
                if (roots.isEmpty()) "＋ 浏览服务器目录并添加" else "＋ 添加目录",
                style = McType.footnote, color = Accent,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { pickTarget = -1 }
                    .padding(vertical = 6.dp, horizontal = 2.dp),
            )
            if (roots.isEmpty()) {
                Text(
                    "还没有根目录：媒体库至少要有一条根目录才能扫描出内容。",
                    style = McType.caption, color = TextFaint,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            pickTarget?.let { target ->
                DirectoryPickerSheet(
                    // 追加时从最近添加的那条起步，替换时从被改的那条起步（iOS initialPath）
                    initialPath = if (target < 0) roots.lastOrNull() else roots.getOrNull(target),
                    browse = { path -> vm.browse(path) },
                    onSelect = { path ->
                        roots = if (target < 0) {
                            if (roots.contains(path)) roots else roots + path
                        } else if (target in roots.indices) {
                            val next = roots.toMutableList()
                            next[target] = path
                            // 撞上已有路径时合并去重，改的那条留原位（首位仍是主根）
                            next.filterIndexed { i, r -> r != path || i == target }
                        } else roots
                    },
                    onDismiss = { pickTarget = null },
                )
            }

            SectionLabel("内容")
            FormSwitch(
                title = "生成缩略图",
                subtitle = "缺图时从视频抓帧；网络挂载库抓帧等于全量下载，可关",
                checked = thumbs,
                onChange = { thumbs = it },
            )
            FormSwitch(
                title = "生成章节",
                subtitle = "详情页章节横排与图廊章节图；后台低优先级作业",
                checked = chapters,
                onChange = { chapters = it },
            )
            FormSwitch(
                title = "识别片头片尾",
                subtitle = "只对剧集库起作用；播放时给「跳过片头」与「下一集」",
                checked = skipIntro,
                enabled = kind == "tv",
                onChange = { skipIntro = it },
            )
            FormSwitch(
                title = "按作品系列自动生成合集",
                subtitle = "《哈利·波特》这种；关掉后已有系列补齐不联网刮削",
                checked = seriesCollections,
                onChange = { seriesCollections = it },
            )
            FormSwitch(
                title = "在首页展示",
                subtitle = "关掉后不参与首页「最近添加」等汇总",
                checked = !excludeHome,
                onChange = { excludeHome = !it },
            )
            FormSwitch(
                title = "实时监控目录变化",
                subtitle = "SMB/NFS 网络挂载建议关闭，靠定期对账发现新文件",
                checked = realtimeWatch,
                onChange = { realtimeWatch = it },
            )

            SectionLabel("可见范围")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FormChip("全部成员", on = accessEveryone) { accessEveryone = true }
                FormChip("指定成员", on = !accessEveryone) { accessEveryone = false }
            }
            if (!accessEveryone) {
                Spacer(Modifier.height(8.dp))
                ui.members.forEach { member ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                val id = member.id.toLong()
                                selectedMembers = if (id in selectedMembers) {
                                    selectedMembers - id
                                } else {
                                    selectedMembers + id
                                }
                            }
                            .padding(vertical = 7.dp),
                    ) {
                        Icon(
                            if (member.id.toLong() in selectedMembers) Icons.Rounded.CheckCircle
                            else Icons.Rounded.RadioButtonUnchecked,
                            contentDescription = null,
                            tint = if (member.id.toLong() in selectedMembers) Accent else TextFaint,
                            modifier = Modifier.size(17.dp),
                        )
                        Spacer(Modifier.width(9.dp))
                        Text(
                            member.nickname.ifBlank { member.username },
                            style = McType.subheadline, color = TextPrimary,
                        )
                    }
                }
                if (ui.members.isEmpty()) {
                    Text("成员清单拉取失败，保存后到网页端再调可见范围。", style = McType.caption, color = TextFaint)
                }
            }

            Spacer(Modifier.height(20.dp))
            Button(
                onClick = {
                    val payload = LibraryPayload(
                        name = name.trim(),
                        kind = kind,
                        source = source.takeIf { !vm.isEdit },
                        rootPaths = roots.map { it.trim() }.filter { it.isNotEmpty() },
                        generateThumbnails = thumbs,
                        extractChapterImages = chapters,
                        detectMediaSegments = skipIntro.takeIf { kind == "tv" },
                        excludeFromHome = excludeHome,
                        autoSeriesCollections = seriesCollections,
                        accessMode = if (accessEveryone) "everyone" else "selected",
                        memberIds = if (accessEveryone) null else selectedMembers.toList(),
                        realtimeWatch = realtimeWatch,
                    )
                    vm.save(payload) { onBack(true) }
                },
                enabled = !ui.saving && name.isNotBlank() && roots.any { it.isNotBlank() },
                shape = RoundedCornerShape(999.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = Color(0xFF141821)),
                elevation = null,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(46.dp)
                    .background(
                        Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))),
                        RoundedCornerShape(999.dp),
                    ),
            ) {
                if (ui.saving) {
                    CircularProgressIndicator(color = Color(0xFF141821), modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                }
                Text(if (vm.isEdit) "保存" else "创建", style = McType.bodySemibold)
            }
            Spacer(Modifier.height(28.dp))
        }
    }
}

@Composable
private fun FormChip(label: String, on: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(if (on) Color.White.copy(alpha = 0.14f) else Color.White.copy(alpha = 0.05f))
            .border(
                1.dp,
                if (on) Color.White.copy(alpha = 0.4f) else LineSoft,
                RoundedCornerShape(999.dp),
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 13.dp, vertical = 8.dp),
    ) {
        Text(label, style = McType.footnote, color = if (on) TextPrimary else TextMuted)
    }
}
