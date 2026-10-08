package io.movieclaw.android.feature.library

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.CollectionView
import io.movieclaw.android.core.model.HomePrefsBus
import io.movieclaw.android.core.model.HomeRows
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 自定义首页（Web `library-customize-view.tsx` / iOS `LibraryCustomizeView`，路由 `/library/customize`）。
 *
 * 一张行清单：**按住左侧把手自由拖动**换位、眼睛显隐；可设的行（收藏 / 库行 / 合集行）
 * 点名字展开设置——排序（一档一个条目，「最近添加」「最早添加」各一条）、名字、
 * 「只显示我没看过的」、删除（仅自加行）。底部「＋ 添加一行 · 从哪来？」选一个库或合集；
 * 「恢复默认」存空清单。
 *
 * 字号与行高照**移动端网页**（移动档：caption 13 / sub 14 / ui 16）：行 48 高、行名 16、
 * 「已隐藏」13、设置标签与控件 14、候选胶囊 14。行内不再另写「来源 · 排序」小字——
 * 网页与 iOS 都不渲染它（iOS 里 `Row.meta` 是个没人用的属性）。
 *
 * 保存：每次改动先落本地草稿，400ms 防抖后整份 PUT `/ui/preferences`
 * （后端是**整体覆盖**，所以要带上主题、侧栏等其余偏好原值）。保存成功让首页重拉。
 */
@HiltViewModel
class LibraryCustomizeViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {
    data class Ui(
        val loading: Boolean = true,
        /** 读取失败：整张清单不画——残缺清单上点一下眼睛就会整份保存，把认不出的库行/合集行永久丢掉 */
        val loadFailed: Boolean = false,
        val rows: List<HomeRows.Row> = emptyList(),
        val libraries: List<LibraryView> = emptyList(),
        val collections: List<CollectionView> = emptyList(),
        val saveError: String? = null,
        val saving: Boolean = false,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui = _ui.asStateFlow()

    /** 还没落地的草稿（防抖窗口里的那份） */
    private var draft: List<HomeRows.Row>? = null
    private var saveJob: Job? = null

    init { load() }

    fun load() {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, loadFailed = false)
            val origin = repository.ui.value.origin
            if (origin == null) {
                _ui.value = _ui.value.copy(loading = false, loadFailed = true)
                return@launch
            }
            try {
                val api = apiFactory.forOrigin(origin)
                // 三份一起拉：库、合集（都是候选与合并的依据）、完整偏好
                val libs = api.libraries().dataOrThrow()
                val cols = runCatching { api.collections().dataOrThrow() }.getOrDefault(emptyList())
                val prefs = api.uiPreferences().dataOrThrow()
                draft = null
                _ui.value = Ui(
                    loading = false,
                    loadFailed = false,
                    rows = HomeRows.build(prefs.home.rows, libs, cols),
                    libraries = libs,
                    collections = cols,
                )
            } catch (_: Exception) {
                _ui.value = _ui.value.copy(loading = false, loadFailed = true)
            }
        }
    }

    /** 改动落草稿，400ms 防抖后保存 */
    private fun commit(next: List<HomeRows.Row>) {
        draft = next
        _ui.value = _ui.value.copy(rows = next, saveError = null)
        saveJob?.cancel()
        saveJob = viewModelScope.launch {
            delay(400)
            save(next)
        }
    }

    fun update(id: String, patch: (HomeRows.Row) -> HomeRows.Row) {
        commit(_ui.value.rows.map { if (it.id == id) patch(it) else it })
    }

    /** 拖到新位置（直接给整份顺序，拖拽期间会连着调用） */
    fun reorder(next: List<HomeRows.Row>) {
        commit(next)
    }

    /** 一次换一位（无障碍路径 / 双击把手） */
    fun move(id: String, delta: Int) {
        val list = _ui.value.rows.toMutableList()
        val index = list.indexOfFirst { it.id == id }
        val to = index + delta
        if (index < 0 || to < 0 || to > list.lastIndex) return
        val row = list.removeAt(index)
        list.add(to, row)
        commit(list)
    }

    fun remove(id: String) {
        commit(_ui.value.rows.filterNot { it.id == id })
    }

    fun add(row: HomeRows.Row) {
        commit(_ui.value.rows + row)
    }

    /** 离开页面时把还在防抖窗口里的改动立即存掉 */
    fun flush() {
        val pending = draft ?: return
        saveJob?.cancel()
        saveJob = null
        viewModelScope.launch { save(pending) }
    }

    fun restoreDefaults() {
        saveJob?.cancel()
        saveJob = null
        commit(emptyList())
        // 立刻落地，不留防抖窗口（用户点完就会退出去看）
        flush()
    }

    private suspend fun save(rows: List<HomeRows.Row>) {
        val origin = repository.ui.value.origin ?: return
        _ui.value = _ui.value.copy(saving = true)
        try {
            val api = apiFactory.forOrigin(origin)
            // PUT 整体覆盖：每次保存先读最新偏好，不能写回其他设备已改过的旧主题。
            val base = api.uiPreferences().dataOrThrow()
            val next = HomeRows.toPrefs(rows).toMutableList()
            // 普通编辑总有内置行；空清单是用户明确点击「恢复默认」。
            if (rows.isNotEmpty()) {
                val editableIds = HomeRows.build(base.home.rows, _ui.value.libraries, _ui.value.collections)
                    .map { it.id }.toSet()
                // 未展示的类型行或暂不可见的来源不等于用户删除；保留其配置及位置。
                base.home.rows.forEachIndexed { index, pref ->
                    if (pref.id !in editableIds) next.add(index.coerceAtMost(next.size), pref)
                }
            }
            val body = base.copy(home = base.home.copy(rows = next))
            val saved = api.updateUiPreferences(body).dataOrThrow()
            if (draft == rows) draft = null
            _ui.value = _ui.value.copy(
                saving = false,
                saveError = null,
                // 服务端存回来的形状可能与草稿不同（空字段被省略等），以后端为准重画
                rows = HomeRows.build(saved.home.rows, _ui.value.libraries, _ui.value.collections),
            )
            // 首页立刻按新清单重排（iOS 写 LibraryHomePrefs.shared 同效）
            HomePrefsBus.bump()
        } catch (e: Exception) {
            _ui.value = _ui.value.copy(saving = false, saveError = friendlyMessage(e))
        }
    }
}

@Composable
fun LibraryCustomizeScreen(
    onBack: () -> Unit,
    vm: LibraryCustomizeViewModel = hiltViewModel(),
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    var expanded by remember { mutableStateOf<String?>(null) }
    var confirmRestore by remember { mutableStateOf(false) }
    var dragId by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableStateOf(0f) }
    val heights = remember { mutableStateMapOf<String, Int>() }
    val shifts = remember { mutableStateMapOf<String, Float>() }
    val density = LocalDensity.current
    val listScroll = rememberScrollState()
    // 返回时先把防抖窗口里的改动存掉
    val back: () -> Unit = { vm.flush(); onBack() }

    /**
     * 拖到一半换位：交换两行，并让被跨过的那行从反向滑到位（网页是 transition，这里同理）。
     * **一律从 VM 的流里取当前清单**：手势协程会长期持有拖拽开始那一刻的闭包，
     * 拿它捕获的旧清单算下标会来回抖（「拖着拖着卡住」有一半出在这儿）。
     */
    fun swap(fromIndex: Int, toIndex: Int) {
        val rows = vm.ui.value.rows
        if (fromIndex !in rows.indices || toIndex !in rows.indices) return
        val crossed = rows[toIndex]
        val list = rows.toMutableList()
        val moved = list.removeAt(fromIndex)
        list.add(toIndex, moved)
        shifts[crossed.id] = (heights[crossed.id] ?: 0).toFloat() * if (toIndex > fromIndex) -1f else 1f
        vm.reorder(list)
    }

    Column(Modifier.fillMaxSize().background(Bg)) {
        McTopBar(
            variant = McTopBarVariant.Sub,
            title = "自定义首页",
            onBack = back,
        ) {
            // iOS 这一颗是**导航栏右上角的纯文字按钮**（`ToolbarItem(.topBarTrailing) { Button("恢复默认") }`），
            // 没有任何底色 / 描边——玻璃胶囊（btn-glass）是网页那版的做法。
            // 点下去会弹确认（iOS 的 feedback.confirm / 网页的 window.confirm 都是这样），文案就是它原话。
            TextButton(onClick = { confirmRestore = true }) {
                Text("恢复默认", style = McType.subheadline, color = Accent)
            }
        }

        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(listScroll)
                .padding(horizontal = McMetrics.pagePadding),
        ) {
            Spacer(Modifier.height(4.dp))
            Text(
                if (ui.loading) "正在读取…"
                else "${ui.rows.count { !it.hidden }} 行显示 · ${ui.rows.count { it.hidden }} 行隐藏",
                fontSize = 14.sp, color = TextMuted,
            )
            if (ui.loadFailed) {
                Spacer(Modifier.height(10.dp))
                // 同 Web：读取失败时整张清单不画——残缺清单上点一下眼睛就会整份保存，
                // 把认不出的库行/合集行永久丢掉
                Text(
                    "读取媒体库与合集失败，行清单可能不完整；退出重进重试。",
                    fontSize = 14.sp, color = Warning,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Warning.copy(alpha = 0.1f))
                        .border(1.dp, Warning.copy(alpha = 0.25f), RoundedCornerShape(12.dp))
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                )
            }
            ui.saveError?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, fontSize = 14.sp, color = Danger)
            }

            if (ui.loading) return@Column
            if (ui.loadFailed && ui.rows.isEmpty()) return@Column

            // 行清单：外层是一张卡（白 3% 底 + 白 9% 描边 + 白 7% 分隔线），行 48 高。
            // 不做裁剪：拖起来的那一行要带着圆角与投影探出卡片边界（网页同做法）。
            Spacer(Modifier.height(14.dp))
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color.White.copy(alpha = 0.03f))
                    .border(1.dp, Color.White.copy(alpha = 0.09f), RoundedCornerShape(16.dp)),
            ) {
                ui.rows.forEachIndexed { index, row ->
                    // **key(row.id) 是必须的**：不按 id 认领，换位后 Compose 按位置复用槽位，
                    // 行里的 pointerInput 键跟着变 → 正在进行的拖拽手势被取消（实测「拖一下就卡住」）
                    androidx.compose.runtime.key(row.id) {
                        val isDragging = dragId == row.id
                        val shift by animateDpAsState(
                            targetValue = with(density) { (shifts[row.id] ?: 0f).toDp() },
                            animationSpec = tween(160),
                            label = "row-shift",
                        )
                        LaunchedEffect(shifts[row.id]) {
                            if ((shifts[row.id] ?: 0f) != 0f) {
                                delay(16)
                                shifts[row.id] = 0f
                            }
                        }
                        CustomizeRow(
                            row = row,
                            expanded = expanded == row.id,
                            dragging = isDragging,
                            dragOffset = if (isDragging) dragOffset else 0f,
                            shift = shift,
                            onToggleExpand = { expanded = if (expanded == row.id) null else row.id },
                            onChange = { patch -> vm.update(row.id) { patch(it) } },
                            onRemove = {
                                if (expanded == row.id) expanded = null
                                vm.remove(row.id)
                            },
                            onMove = { delta -> vm.move(row.id, delta) },
                            onMeasured = { h -> heights[row.id] = h },
                            onDragStart = { dragId = row.id; dragOffset = 0f },
                            // 跨越判断在屏幕级做：只认 dragId 与 VM 里的**当前**清单，
                            // 既不认闭包捕获的那一行，也不认拖拽开始那一刻的旧顺序
                            onDragBy = { dy ->
                                dragOffset += dy
                                val id = dragId ?: return@CustomizeRow
                                val rows = vm.ui.value.rows
                                val currentIndex = rows.indexOfFirst { it.id == id }
                                if (currentIndex < 0) return@CustomizeRow
                                // 越过邻行一半就换位：换位后把位移补回来，拖起来的那行才始终跟着手指
                                val selfH = (heights[id] ?: 0).toFloat()
                                if (dragOffset > selfH / 2f && currentIndex < rows.lastIndex) {
                                    val nextH = (heights[rows[currentIndex + 1].id] ?: 0).toFloat()
                                    swap(currentIndex, currentIndex + 1)
                                    dragOffset -= nextH
                                } else if (dragOffset < -selfH / 2f && currentIndex > 0) {
                                    val prevH = (heights[rows[currentIndex - 1].id] ?: 0).toFloat()
                                    swap(currentIndex, currentIndex - 1)
                                    dragOffset += prevH
                                }
                            },
                            onDragEnd = { dragId = null; dragOffset = 0f },
                        )
                        if (index != ui.rows.lastIndex) {
                            Box(
                                Modifier
                                    .fillMaxWidth()
                                    .padding(start = McMetrics.pagePadding)
                                    .height(1.dp)
                                    .background(Color.White.copy(alpha = 0.07f)),
                            )
                        }
                    }
                }
            }

            // ＋ 添加一行 · 从哪来？（虚框卡 + 胶囊候选）
            Spacer(Modifier.height(14.dp))
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(12.dp))
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                Text("＋ 添加一行 · 从哪来？", fontSize = 13.sp, color = TextFaint)
                Spacer(Modifier.height(8.dp))
                AddRowSection(
                    libraries = ui.libraries.filter { it.viewerAccess },
                    // 内置的「我的收藏」等自动合集不进候选（首页已有「我的收藏」这一行）
                    collections = ui.collections.filter { it.kind == "user" },
                    onHome = ui.rows.filter { it.kind is HomeRows.Kind.Collection }
                        .mapNotNull { (it.kind as? HomeRows.Kind.Collection)?.collection?.id }
                        .toSet(),
                    onAdd = { row ->
                        vm.add(row)
                        expanded = row.id
                    },
                )
            }
            Spacer(Modifier.height(14.dp))
            Text(
                "改动即时生效，只影响你自己的首页；效果回首页看。",
                fontSize = 13.sp, color = TextFaint,
            )
            Spacer(Modifier.height(28.dp))
        }
    }

    if (confirmRestore) {
        AlertDialog(
            onDismissRequest = { confirmRestore = false },
            containerColor = Color(0xFF1E212B),
            title = { Text("恢复默认布局？", color = TextPrimary, fontSize = 16.sp) },
            text = { Text("你自己加的行会被移除。", color = TextMuted, fontSize = 14.sp) },
            confirmButton = {
                TextButton(onClick = {
                    confirmRestore = false
                    expanded = null
                    vm.restoreDefaults()
                }) { Text("恢复默认", color = Danger) }
            },
            dismissButton = {
                TextButton(onClick = { confirmRestore = false }) { Text("取消", color = TextMuted) }
            },
        )
    }
}

/* ---------------- 一行 ---------------- */

/** 一个可选项：档位 + 是否反转 + 显示名（同 iOS RowItem.SortOption） */
private data class SortOption(val key: String, val reversed: Boolean, val label: String)

@Composable
private fun CustomizeRow(
    row: HomeRows.Row,
    expanded: Boolean,
    dragging: Boolean,
    dragOffset: Float,
    shift: Dp,
    onToggleExpand: () -> Unit,
    onChange: ((HomeRows.Row) -> HomeRows.Row) -> Unit,
    onRemove: () -> Unit,
    onMove: (Int) -> Unit,
    onMeasured: (Int) -> Unit,
    onDragStart: () -> Unit,
    onDragBy: (Float) -> Unit,
    onDragEnd: () -> Unit,
) {
    val options = remember(row.kind, row.sort, row.reversed) { sortOptions(row) }
    val editable = options != null

    Column(
        Modifier
            .fillMaxWidth()
            .onSizeChanged { onMeasured(it.height) }
            .graphicsLayer {
                translationY = dragOffset
                if (dragging) {
                    scaleX = 1.015f
                    scaleY = 1.015f
                    shadowElevation = 16.dp.toPx()
                }
            }
            .offset(y = shift)
            // 拖起来的那一行：几乎不透的底 + 细描边 + 圆角，看着是「被拿在手里的一张卡」
            .then(
                if (dragging) {
                    Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color(0xFF1D222D).copy(alpha = 0.95f))
                        .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(12.dp))
                } else {
                    Modifier
                },
            ),
    ) {
        Row(
            Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // 把手：唯一的换位入口（44 触屏目标，iOS HIG 最小可点尺寸）。
            // 手势**不按行 id 做键**（键一变 Compose 就会取消进行中的手势，拖一下就断）；
            // 跨越判断靠屏幕级的 dragId，不依赖这里闭包捕获的那一行。
            // 回调一律经 rememberUpdatedState 转发：pointerInput(Unit) 的协程活得比一次重组久，
            // 直接调参数就会一直用拖拽开始那一刻那份（旧清单 / 旧状态）。
            val dragStart by rememberUpdatedState(onDragStart)
            val dragBy by rememberUpdatedState(onDragBy)
            val dragEnd by rememberUpdatedState(onDragEnd)
            val doubleTap by rememberUpdatedState(onMove)
            Box(
                Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .pointerInput(Unit) {
                        detectDragGestures(
                            onDragStart = { dragStart() },
                            onDragEnd = { dragEnd() },
                            onDragCancel = { dragEnd() },
                            onDrag = { change, delta ->
                                change.consume()
                                dragBy(delta.y)
                            },
                        )
                    }
                    .pointerInput(Unit) {
                        // 双击把手 = 下移一位（没有鼠标的「Alt+方向键」的对应物）
                        detectTapGestures(onDoubleTap = { doubleTap(1) })
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Rounded.DragHandle,
                    contentDescription = "拖动调整「${row.title}」的顺序",
                    tint = Color.White.copy(alpha = 0.35f),
                    modifier = Modifier.size(18.dp),
                )
            }
            Row(
                Modifier
                    .weight(1f)
                    .height(48.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .let { if (editable) it.clickable(onClick = onToggleExpand) else it }
                    .padding(horizontal = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    row.title,
                    fontSize = 16.sp,
                    color = if (row.hidden) TextFaint else TextPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (row.hidden) {
                    Spacer(Modifier.width(8.dp))
                    Text("已隐藏", fontSize = 13.sp, color = TextFaint)
                }
                if (editable) {
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        Icons.Rounded.KeyboardArrowDown,
                        contentDescription = if (expanded) "收起" else "展开",
                        tint = TextFaint,
                        modifier = Modifier
                            .size(14.dp)
                            .graphicsLayer { rotationZ = if (expanded) 180f else 0f },
                    )
                }
            }
            // 眼睛：显隐（位置保留）
            Box(
                Modifier
                    .size(32.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { onChange { it.copy(hidden = !it.hidden) } },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (row.hidden) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility,
                    contentDescription = if (row.hidden) "显示「${row.title}」" else "隐藏「${row.title}」",
                    tint = if (row.hidden) TextFaint else TextMuted,
                    modifier = Modifier.size(16.dp),
                )
            }
        }

        if (expanded && options != null) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                SortRow(row, options, onChange)
                when (val k = row.kind) {
                    is HomeRows.Kind.Library -> NameRow(
                        hint = row.defaultTitle,
                        value = k.name,
                        onName = { name ->
                            onChange { r ->
                                val lib = r.kind as? HomeRows.Kind.Library ?: return@onChange r
                                r.copy(kind = lib.copy(name = name.take(40)))
                            }
                        },
                    )
                    is HomeRows.Kind.Collection -> NameRow(
                        hint = row.defaultTitle,
                        value = k.name,
                        onName = { name ->
                            onChange { r ->
                                val col = r.kind as? HomeRows.Kind.Collection ?: return@onChange r
                                r.copy(kind = col.copy(name = name.take(40)))
                            }
                        },
                    )
                    else -> Unit
                }
                val libraryKind = row.kind as? HomeRows.Kind.Library
                val showUnwatched = libraryKind != null && libraryKind.sort != "last_played"
                if (showUnwatched || row.removable) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        if (libraryKind != null && showUnwatched) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .clickable {
                                        onChange { r ->
                                            val lib = r.kind as? HomeRows.Kind.Library ?: return@onChange r
                                            r.copy(kind = lib.copy(unwatched = !lib.unwatched))
                                        }
                                    }
                                    .padding(vertical = 4.dp),
                            ) {
                                Icon(
                                    if (libraryKind.unwatched) Icons.Rounded.CheckCircle
                                    else Icons.Rounded.RadioButtonUnchecked,
                                    contentDescription = null,
                                    tint = if (libraryKind.unwatched) Info else TextFaint,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(8.dp))
                                Text("只显示我没看过的", fontSize = 14.sp, color = TextMuted)
                            }
                        }
                        Spacer(Modifier.weight(1f))
                        if (row.removable) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickable(onClick = onRemove)
                                    .padding(horizontal = 8.dp, vertical = 6.dp),
                            ) {
                                Icon(
                                    Icons.Rounded.Delete, contentDescription = null,
                                    tint = TextMuted, modifier = Modifier.size(14.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text("删除这一行", fontSize = 14.sp, color = TextMuted)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 这一行可选的排序：每个有方向的指标两条（自然方向在前），随机 / 未看优先各一条 */
private fun sortOptions(row: HomeRows.Row): List<SortOption>? {
    fun options(keys: List<String>, preset: (String) -> HomeRows.Preset): List<SortOption> =
        keys.flatMap { key ->
            val p = preset(key)
            val dir = p.direction
            if (dir == null) listOf(SortOption(key, false, p.short(false)))
            else listOf(SortOption(key, false, p.short(false)), SortOption(key, true, p.short(true)))
        }
    return when (val k = row.kind) {
        is HomeRows.Kind.Favorites -> options(HomeRows.favoritesSorts) { HomeRows.favoritesPreset(it) }
        is HomeRows.Kind.Library -> options(HomeRows.sortsFor(k.library.kind)) { HomeRows.preset(it) }
        is HomeRows.Kind.Collection -> options(HomeRows.allSorts) { HomeRows.preset(it) }
        else -> null
    }
}

@Composable
private fun SortRow(
    row: HomeRows.Row,
    options: List<SortOption>,
    onChange: ((HomeRows.Row) -> HomeRows.Row) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val current = options.firstOrNull { it.key == row.sort && it.reversed == row.reversed }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("排序", fontSize = 14.sp, color = TextMuted, modifier = Modifier.width(32.dp))
        Box {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .height(32.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(6.dp))
                    .background(Color.White.copy(alpha = 0.05f))
                    .clickable { open = true }
                    .padding(horizontal = 10.dp),
            ) {
                Text(current?.label ?: "排序", fontSize = 14.sp, color = TextPrimary)
                Spacer(Modifier.width(6.dp))
                Icon(
                    Icons.Rounded.KeyboardArrowDown,
                    contentDescription = null,
                    tint = TextFaint,
                    modifier = Modifier.size(14.dp),
                )
            }
            DropdownMenu(
                expanded = open,
                onDismissRequest = { open = false },
                containerColor = Color(0xFF22252C),
            ) {
                options.forEach { option ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                option.label, fontSize = 14.sp,
                                color = if (option == current) Accent else TextPrimary,
                            )
                        },
                        onClick = {
                            open = false
                            onChange { r -> applySort(r, option) }
                        },
                    )
                }
            }
        }
    }
}

private fun applySort(row: HomeRows.Row, option: SortOption): HomeRows.Row = when (val k = row.kind) {
    is HomeRows.Kind.Favorites -> row.copy(kind = k.copy(sort = option.key, reversed = option.reversed))
    is HomeRows.Kind.Library -> row.copy(
        kind = k.copy(
            sort = option.key,
            reversed = option.reversed,
            // 换成「最近观看」时把「只看没看过的」收掉（两者互斥）
            unwatched = if (option.key == "last_played") false else k.unwatched,
        ),
    )
    is HomeRows.Kind.Collection -> row.copy(kind = k.copy(sort = option.key, reversed = option.reversed))
    else -> row
}

/** 名字输入框：输入途中不 trim（免得吃掉词间的空格），回车 / 点「改」时去首尾空白 */
@Composable
private fun NameRow(hint: String, value: String, onName: (String) -> Unit) {
    var text by remember(value) { mutableStateOf(value) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("名字", fontSize = 14.sp, color = TextMuted, modifier = Modifier.width(32.dp))
        BasicTextField(
            value = text,
            onValueChange = { text = it.take(40) },
            singleLine = true,
            textStyle = TextStyle(color = TextPrimary, fontSize = 14.sp),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            cursorBrush = SolidColor(Accent),
            modifier = Modifier
                .weight(1f)
                .height(32.dp)
                .clip(RoundedCornerShape(6.dp))
                .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(6.dp))
                .background(Color.White.copy(alpha = 0.05f))
                .padding(horizontal = 8.dp, vertical = 7.dp),
            decorationBox = { inner ->
                Box {
                    if (text.isEmpty()) {
                        Text(hint.ifBlank { "跟随推荐" }, fontSize = 14.sp, color = TextFaint)
                    }
                    inner()
                }
            },
        )
        TextButton(
            onClick = { text = text.trim(); onName(text) },
            modifier = Modifier.height(32.dp),
        ) {
            Text("改", fontSize = 14.sp, color = Accent)
        }
    }
}

/* ---------------- 添加一行 ---------------- */

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun AddRowSection(
    libraries: List<LibraryView>,
    collections: List<CollectionView>,
    onHome: Set<Long>,
    onAdd: (HomeRows.Row) -> Unit,
) {
    // 库与合集同属「从哪来」的候选，必须待在同一个流式布局里（拆开会贴死）
    FlowRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        libraries.forEach { lib ->
            AddChip("${lib.name}库") { onAdd(HomeRows.newLibraryRow(lib)) }
        }
        collections.forEach { collection ->
            val already = onHome.contains(collection.id)
            AddChip(
                text = collection.name,
                suffix = if (already) "已在首页" else "${collection.itemCount} 部",
                enabled = !already,
            ) { onAdd(HomeRows.newCollectionRow(collection)) }
        }
    }
}

@Composable
private fun AddChip(
    text: String,
    suffix: String? = null,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(999.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 5.dp),
    ) {
        Text(text, fontSize = 14.sp, color = if (enabled) TextMuted else TextFaint)
        if (suffix != null) {
            Spacer(Modifier.width(6.dp))
            Text(suffix, fontSize = 13.sp, color = TextFaint)
        }
    }
}
