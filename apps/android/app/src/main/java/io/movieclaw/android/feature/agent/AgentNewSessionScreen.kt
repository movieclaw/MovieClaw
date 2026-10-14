package io.movieclaw.android.feature.agent

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import io.movieclaw.android.core.designsystem.FeedbackTone
import io.movieclaw.android.core.designsystem.McNotice
import io.movieclaw.android.core.designsystem.AccentSoft
import androidx.compose.material.icons.rounded.Image
import androidx.compose.foundation.clickable
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.draw.clip
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.material3.IconButton
import androidx.compose.material3.Icon
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.AgentSessionStart
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

@HiltViewModel
class AgentNewSessionViewModel @Inject constructor(
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: android.content.Context,
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
) : ViewModel() {

    data class UiState(
        val input: String = "",
        val creating: Boolean = false,
        val error: String? = null,
        /** 可选模型（`GET /llm/models`）；与对话页同一套选择器 */
        val models: List<io.movieclaw.android.core.model.LlmModelOption> = emptyList(),
        /** null = 智能体默认 */
        val modelRef: String? = null,
        /** null = 由模型自行决定 */
        val thinkingLevel: String? = null,
        /** 已上传的图片附件（首条消息一起发出去） */
        val attachments: List<io.movieclaw.android.core.model.AgentAttachment> = emptyList(),
        val uploading: Boolean = false,
        val notice: io.movieclaw.android.core.designsystem.McNotice? = null,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    init {
        // 与对话页同一份模型清单（同一个端点；失败不影响建会话）
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).llmModels().dataOrThrow() }
                .onSuccess { list ->
                    val choice = AgentComposerPrefs.reconcile(AgentComposerPrefs.load(context), list)
                    AgentComposerPrefs.save(context, choice)
                    _ui.update { it.copy(models = list, modelRef = choice.model, thinkingLevel = choice.thinking) }
                }
        }
    }

    fun onInput(value: String) = _ui.update { it.copy(input = value) }

    fun setModel(ref: String?) {
        _ui.update { it.copy(modelRef = ref, thinkingLevel = null) }
        AgentComposerPrefs.save(context, AgentComposerPrefs.Choice(ref, null))
    }

    fun setThinkingLevel(level: String?) {
        _ui.update { it.copy(thinkingLevel = level) }
        AgentComposerPrefs.save(context, AgentComposerPrefs.Choice(_ui.value.modelRef, level))
    }

    fun consumeNotice() = _ui.update { it.copy(notice = null) }

    /** 图片附件：读字节 → multipart 上传 → 记录 attachment_id（与对话页同一份实现） */
    fun attachImage(uri: android.net.Uri) {
        _ui.update { it.copy(uploading = true) }
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin
            if (origin == null) {
                _ui.update { it.copy(uploading = false) }
                return@launch
            }
            val api = apiFactory.forOrigin(origin)
            when (val outcome = uploadAgentAttachment(context, uri) { file, mime ->
                val part = okhttp3.MultipartBody.Part.createFormData(
                    "file", file.name, file.asRequestBody(mime.toMediaType()),
                )
                api.uploadAgentAttachment(part).dataOrThrow()
            }) {
                is UploadOutcome.Ok -> _ui.update {
                    it.copy(uploading = false, attachments = it.attachments + outcome.attachment)
                }
                UploadOutcome.Unreadable -> _ui.update {
                    it.copy(uploading = false, notice = McNotice("无法读取所选图片", FeedbackTone.Error))
                }
                is UploadOutcome.Failed -> _ui.update {
                    it.copy(uploading = false, notice = McNotice(friendlyMessage(outcome.error), FeedbackTone.Error))
                }
            }
        }
    }

    fun removeAttachment(id: String) = _ui.update { state ->
        state.copy(attachments = state.attachments.filterNot { it.attachmentId == id })
    }

    fun create(onCreated: (String) -> Unit) {
        val state = _ui.value
        val text = state.input.trim()
        // 与按钮同一个条件：要有文字或图片、不在创建中、也不在上传中（上传没完就建会话会把图丢掉）
        if (state.creating || state.uploading) return
        if (text.isEmpty() && state.attachments.isEmpty()) return
        _ui.update { it.copy(creating = true, error = null) }
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin
            if (origin == null) {
                _ui.update { it.copy(creating = false) }   // 别把按钮卡在"创建中"
                return@launch
            }
            runCatching {
                // 首条消息就带上模型 / 思维链选择（与对话页发送同口径）
                apiFactory.forOrigin(origin).startAgentSession(
                    AgentSessionStart(
                        content = text,
                        attachments = _ui.value.attachments.map { it.attachmentId },
                        model = _ui.value.modelRef ?: "",
                        thinkingLevel = _ui.value.thinkingLevel,
                    )
                ).dataOrThrow()
            }
                .onSuccess { accepted ->
                    // 建完清空：这个页面可能还在返回栈上，别留下上次的图和文字
                    _ui.update { it.copy(creating = false, attachments = emptyList(), input = "") }
                    // 会话列表立刻能看到这条（「我的」页订阅这个信号）
                    sessionRepository.notifyAgentSessionsChanged()
                    onCreated(accepted.sessionId)
                }
                .onFailure { e -> _ui.update { it.copy(creating = false, error = friendlyMessage(e)) } }
        }
    }
}

/** 新建会话:输入首条消息即开始(与网页端一致:消息与建会话同一请求) */
@Composable
fun AgentNewSessionScreen(
    onBack: () -> Unit,
    onCreated: (String) -> Unit,
    vm: AgentNewSessionViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize().imePadding()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.statusBarsPadding().padding(horizontal = 4.dp)) {
            TextButton(onClick = onBack) { Text("取消", color = TextMuted) }
            Text("新会话", fontSize = 18.sp, fontWeight = FontWeight.Bold)
        }
        Column(Modifier.padding(16.dp)) {
            GlassCard(Modifier.fillMaxWidth()) {
                Text("你可以让我做什么", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                listOf(
                    "「帮我订阅《幕府将军》,只要 4K」",
                    "「看看现在有哪些任务在跑,失败的重试一下」",
                    "「这部剧缺了第 4 集,帮我找找资源」",
                    "「最近空间不够了,清理一下重复文件」",
                ).forEach { example ->
                    Text(example, fontSize = 14.sp, color = TextMuted, lineHeight = 21.sp)
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        // 图片附件（iOS 新会话页用的同一个 AgentComposer，`+` 菜单里就有图片）：
        // 选择器 + 已选图片条 + 工具行里的图片键，与对话页同一份口径
        val pickImage = androidx.activity.compose.rememberLauncherForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia(),
        ) { uri -> uri?.let(vm::attachImage) }
        // 与对话页共用的 composer（附件 tray + 输入容器 + 工具行 + 模型菜单都在组件里）
        AgentComposerBar(
            input = state.input,
            onInput = vm::onInput,
            placeholder = "描述你的需求…",
            attachments = state.attachments,
            uploading = state.uploading,
            onPickImage = {
                pickImage.launch(
                    androidx.activity.result.PickVisualMediaRequest(
                        androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly,
                    )
                )
            },
            onRemoveAttachment = vm::removeAttachment,
            models = state.models,
            modelRef = state.modelRef,
            thinkingLevel = state.thinkingLevel,
            onPickModel = vm::setModel,
            onPickThinking = vm::setThinkingLevel,
            sendEnabled = !state.creating && !state.uploading &&
                (state.input.isNotBlank() || state.attachments.isNotEmpty()),
            sending = state.creating,
            onSend = { vm.create(onCreated) },
            minLines = 3,
            maxLines = 8,
            horizontalPadding = 16.dp,
            menuLift = 210.dp,
        )
    }
}
