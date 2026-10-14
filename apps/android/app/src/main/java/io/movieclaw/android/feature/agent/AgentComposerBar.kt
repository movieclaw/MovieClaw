package io.movieclaw.android.feature.agent

import android.content.Context
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.MenuAppear
import io.movieclaw.android.core.designsystem.MenuSurface
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.AgentAttachment
import io.movieclaw.android.core.model.LlmModelOption
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody.Companion.asRequestBody
import java.io.File

/**
 * Agent 对话框（composer）：**对话页与新会话页共用同一份**（iOS 也是同一个 `AgentComposer`）。
 *
 * 抽出来的原因见 PR 评论：原先两个页面各写了一份容器/工具行/模型菜单，附件上传逻辑在两个
 * ViewModel 里也各一份。这里只做「输入 + 附件 + 模型 / 思维链 + 发送」这一块的 UI；
 * 状态仍由各自的 ViewModel 持有（两边的状态不止这些字段，各有各的流式/创建态）。
 *
 * @param menuLift 模型菜单相对页面底部的抬升量：输入框行数越多、抬得越高（默认按一行算）
 */
@Composable
internal fun AgentComposerBar(
    input: String,
    onInput: (String) -> Unit,
    placeholder: String,
    attachments: List<AgentAttachment>,
    uploading: Boolean,
    onPickImage: () -> Unit,
    onRemoveAttachment: (String) -> Unit,
    models: List<LlmModelOption>,
    modelRef: String?,
    thinkingLevel: String?,
    onPickModel: (String?) -> Unit,
    onPickThinking: (String?) -> Unit,
    sendEnabled: Boolean,
    sending: Boolean,
    onSend: () -> Unit,
    modifier: Modifier = Modifier,
    minLines: Int = 1,
    maxLines: Int = 5,
    /** 输入区左右外边距：对话页是 12dp（贴边），新会话页是 16dp（跟上面卡片对齐） */
    horizontalPadding: Dp = 12.dp,
    menuLift: Dp = 112.dp,
) {
    var showModelMenu by remember { mutableStateOf(false) }

    Column(modifier) {
        // 已选图片：文件名 + ×（上传中显示进度）。
        // iOS 的 composer 里就是这一条 tray，两个页面共用
        if (attachments.isNotEmpty() || uploading) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(horizontal = horizontalPadding, vertical = 4.dp),
            ) {
                attachments.forEach { attachment ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .background(AccentSoft)
                            .clickable { onRemoveAttachment(attachment.attachmentId) }
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                    ) {
                        Icon(Icons.Rounded.Image, contentDescription = null, tint = Accent, modifier = Modifier.size(13.dp))
                        Spacer(Modifier.width(5.dp))
                        Text(attachment.name.take(18), fontSize = 11.sp, color = Accent)
                        Spacer(Modifier.width(5.dp))
                        Text("×", fontSize = 12.sp, color = Accent)
                    }
                }
                if (uploading) {
                    Text("上传中…", fontSize = 11.sp, color = TextFaint)
                }
            }
        }

        // iOS `AgentComposer` 结构：白 5%、圆角 22 的容器 = 输入框 + 底部工具行
        Column(
            Modifier
                .padding(horizontal = horizontalPadding, vertical = 8.dp)
                .clip(RoundedCornerShape(22.dp))
                .background(Color.White.copy(alpha = 0.05f))
                .border(1.dp, Color.White.copy(alpha = 0.07f), RoundedCornerShape(22.dp)),
        ) {
            TextField(
                value = input,
                onValueChange = onInput,
                placeholder = { Text(placeholder, fontSize = 15.sp, color = TextFaint) },
                minLines = minLines,
                maxLines = maxLines,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    cursorColor = Accent,
                ),
                shape = RoundedCornerShape(22.dp),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
            )
            // 工具行（iOS `toolRow`）：图片 · 模型 chip …… 发送
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onPickImage, modifier = Modifier.size(44.dp)) {
                    Icon(Icons.Rounded.Image, contentDescription = "添加图片", tint = TextMuted, modifier = Modifier.size(20.dp))
                }
                if (models.isNotEmpty()) {
                    ModelChip(
                        label = AgentThinking.resolve(models, modelRef)?.label ?: "模型",
                        enabled = !sending,
                        onClick = { showModelMenu = true },
                    )
                }
                Spacer(Modifier.weight(1f))
                IconButton(
                    onClick = onSend,
                    enabled = sendEnabled,
                    modifier = Modifier.size(44.dp).background(
                        if (sendEnabled) Accent else Color.White.copy(alpha = 0.08f),
                        CircleShape,
                    ),
                ) {
                    if (sending) {
                        CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(
                            Icons.AutoMirrored.Rounded.Send,
                            contentDescription = "发送",
                            tint = Color(0xFF0A0E12),
                            modifier = Modifier.size(19.dp),
                        )
                    }
                }
            }
        }
    }

    // 模型 / 思维链菜单（iOS `AgentModelMenu`）：锚在输入区上方
    if (showModelMenu) {
        val menuOffset = with(LocalDensity.current) {
            IntOffset(horizontalPadding.roundToPx(), -menuLift.roundToPx())
        }
        Popup(
            alignment = Alignment.BottomStart,
            offset = menuOffset,
            onDismissRequest = { showModelMenu = false },
            properties = PopupProperties(focusable = true),
        ) {
            MenuAppear(originX = 0.12f, originY = 1f) {
                Surface(
                    shape = RoundedCornerShape(16.dp),
                    color = MenuSurface,
                    border = androidx.compose.foundation.BorderStroke(1.dp, LineColor),
                    shadowElevation = 12.dp,
                ) {
                    ModelMenu(
                        models = models,
                        modelRef = modelRef,
                        thinkingLevel = thinkingLevel,
                        onPickModel = { ref ->
                            onPickModel(ref)
                            showModelMenu = false
                        },
                        onPickThinking = onPickThinking,
                    )
                }
            }
        }
    }
}

/** 附件上传结果：读不出来 / 上传失败分开，调用方各自决定提示文案 */
internal sealed interface UploadOutcome {
    data class Ok(val attachment: AgentAttachment) : UploadOutcome
    data object Unreadable : UploadOutcome
    data class Failed(val error: Throwable) : UploadOutcome
}

/**
 * 图片附件上传（两个 ViewModel 共用一份）：读字节 → 写成缓存里的临时文件（MIME 与扩展名
 * 按真实类型）→ 交给 [upload] → **无论成败都删临时文件**。
 *
 * [upload] 由调用方提供（它带着各自的服务端客户端），参数是临时文件与 MIME。
 */
internal suspend fun uploadAgentAttachment(
    context: Context,
    uri: Uri,
    upload: suspend (File, String) -> AgentAttachment,
): UploadOutcome {
    val bytes = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
    } ?: return UploadOutcome.Unreadable

    val mime = context.contentResolver.getType(uri) ?: "image/jpeg"
    val ext = when (mime) {
        "image/png" -> "png"
        "image/webp" -> "webp"
        "image/gif" -> "gif"
        "image/heic", "image/heif" -> "heic"
        else -> "jpg"
    }
    val temp = File(context.cacheDir, "agent_upload_${System.currentTimeMillis()}.$ext")
    return try {
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { runCatching { temp.writeBytes(bytes) } }
        UploadOutcome.Ok(upload(temp, mime))
    } catch (e: Throwable) {
        UploadOutcome.Failed(e)
    } finally {
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { runCatching { temp.delete() } }
    }
}
