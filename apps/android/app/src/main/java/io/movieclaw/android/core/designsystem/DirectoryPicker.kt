package io.movieclaw.android.core.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.SubdirectoryArrowLeft
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.model.FsBrowseView
import io.movieclaw.android.core.network.friendlyMessage
import kotlinx.coroutines.launch

/**
 * 服务器目录选择器（iOS `SettingsBDirectoryPicker`、Web `directory-picker`；`GET /fs/browse` 只读逐级下钻）。
 *
 * 根目录、下载器路径映射都要填服务器上的绝对路径，手打极易出错：这里逐级点选，
 * 顶部面包屑可跳回任意一层，右上角切手动输入（记得路径时不必逐级点）。起始目录无效时回落根目录。
 * 只列目录、不列文件——服务端就是这么设计的（Docker 部署时宿主机 `ls` 看到的路径
 * 在容器里可能根本不存在，得看服务器自己看到了什么）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DirectoryPickerSheet(
    initialPath: String?,
    browse: suspend (String?) -> FsBrowseView,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var view by remember { mutableStateOf<FsBrowseView?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    suspend fun navigate(path: String?) {
        loading = true
        error = null
        try {
            view = browse(path)
            editing = false
        } catch (e: Exception) {
            // 跳转失败保留当前列表，只提示错误（如手动输入了不存在的路径）
            error = friendlyMessage(e)
        } finally {
            loading = false
        }
    }

    LaunchedEffect(Unit) {
        loading = true
        try {
            view = browse(initialPath?.takeIf { it.isNotBlank() })
        } catch (e: Exception) {
            // 起始目录无效（早先手输的旧值 / 目录已被删）就回落根目录
            try {
                view = browse(null)
            } catch (e2: Exception) {
                error = friendlyMessage(e2)
            }
        } finally {
            loading = false
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = Color.White,
    ) {
        Column(Modifier.fillMaxWidth().padding(bottom = 20.dp)) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "选择服务器目录",
                    fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    if (editing) "浏览目录" else "手动输入路径",
                    style = McType.footnote, color = Accent,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable {
                            draft = view?.path ?: "/"
                            editing = !editing
                        }
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                )
                Spacer(Modifier.width(2.dp))
                Text(
                    "取消",
                    style = McType.footnote, color = TextMuted,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { onDismiss() }
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                )
            }
            Spacer(Modifier.height(4.dp))

            if (editing) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = true,
                    placeholder = { Text("输入绝对路径后回车跳转", style = McType.footnote, color = TextFaint) },
                    textStyle = McType.footnote.copy(color = TextPrimary, fontFamily = FontFamily.Monospace),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { scope.launch { navigate(draft.trim()) } }),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = LineSoft, unfocusedBorderColor = LineSoft,
                        cursorColor = Accent,
                        focusedTextColor = TextPrimary, unfocusedTextColor = TextPrimary,
                    ),
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                )
            } else {
                // 面包屑：根 "/" + 逐级路径段，点任意一段跳回该层（当前层加粗）
                Row(
                    Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CrumbButton("/", current = view?.path == "/") { scope.launch { navigate("/") } }
                    segmentsOf(view?.path).forEach { (name, path) ->
                        Icon(
                            Icons.Rounded.ChevronRight, contentDescription = null,
                            tint = TextFaint, modifier = Modifier.size(14.dp),
                        )
                        CrumbButton(name, current = path == view?.path) { scope.launch { navigate(path) } }
                    }
                }
            }

            error?.let {
                Text(
                    it, style = McType.footnote, color = Danger, lineHeight = 19.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                )
            }

            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 380.dp)) {
                val v = view
                if (v != null) {
                    v.parent?.let { parent ->
                        item(key = "parent") {
                            PickerRow(Icons.Rounded.SubdirectoryArrowLeft, "上一级", enabled = !loading) {
                                scope.launch { navigate(parent) }
                            }
                        }
                    }
                    if (v.entries.isEmpty()) {
                        item(key = "empty") {
                            Text(
                                "该目录下没有子目录，可直接选择当前目录",
                                style = McType.footnote, color = TextMuted,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
                            )
                        }
                    }
                    items(v.entries, key = { it.path }) { entry ->
                        PickerRow(Icons.Rounded.Folder, entry.name, enabled = !loading) {
                            scope.launch { navigate(entry.path) }
                        }
                    }
                } else if (loading) {
                    item(key = "loading") {
                        Box(
                            Modifier.fillMaxWidth().padding(vertical = 28.dp),
                            contentAlignment = Alignment.Center,
                        ) { CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(20.dp), strokeWidth = 2.dp) }
                    }
                }
            }

            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(start = 16.dp, end = 16.dp)
                    .padding(top = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    headTruncatedPath(view?.path ?: "…"),
                    style = McType.footnote.copy(fontFamily = FontFamily.Monospace),
                    color = TextMuted,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(12.dp))
                val enabled = view != null && !loading
                Box(
                    Modifier
                        .height(40.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(if (enabled) Accent else Color.White.copy(alpha = 0.08f))
                        .clickable(enabled = enabled) {
                            view?.path?.let(onSelect)
                            onDismiss()
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "选择此目录",
                        fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                        color = if (enabled) Color(0xFF0B0C0F) else TextFaint,
                        modifier = Modifier.padding(horizontal = 18.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun CrumbButton(label: String, current: Boolean, onClick: () -> Unit) {
    Text(
        label,
        style = McType.footnote.copy(fontFamily = FontFamily.Monospace),
        color = if (current) TextPrimary else TextMuted,
        fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal,
        maxLines = 1,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .clickable { onClick() }
            .padding(horizontal = 4.dp, vertical = 6.dp),
    )
}

@Composable
private fun PickerRow(icon: ImageVector, label: String, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = TextMuted, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Text(
            label, style = McType.body, color = TextPrimary,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Icon(
            Icons.Rounded.ChevronRight, contentDescription = null,
            tint = TextFaint, modifier = Modifier.size(16.dp),
        )
    }
}

/** 绝对路径 → 逐级 (名, 路径)（「/a/b」 → [("a","/a"), ("b","/a/b")]） */
private fun segmentsOf(path: String?): List<Pair<String, String>> {
    if (path.isNullOrEmpty()) return emptyList()
    var acc = ""
    return path.split('/').filter { it.isNotEmpty() }.map { part ->
        acc += "/$part"
        part to acc
    }
}

/** 头部截断（iOS `truncationMode(.head)`）：路径的关键信息在尾部的目录名上 */
internal fun headTruncatedPath(path: String, keep: Int = 34): String =
    if (path.length <= keep) path else "…" + path.takeLast(keep)
