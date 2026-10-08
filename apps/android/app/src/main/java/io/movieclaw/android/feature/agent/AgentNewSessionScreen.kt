package io.movieclaw.android.feature.agent

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
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
) : ViewModel() {

    data class UiState(
        val input: String = "",
        val creating: Boolean = false,
        val error: String? = null,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    fun onInput(value: String) = _ui.update { it.copy(input = value) }

    fun create(onCreated: (String) -> Unit) {
        val text = _ui.value.input.trim()
        if (text.isEmpty() || _ui.value.creating) return
        _ui.update { it.copy(creating = true, error = null) }
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).startAgentSession(AgentSessionStart(content = text)).dataOrThrow()
            }
                .onSuccess { accepted ->
                    _ui.update { it.copy(creating = false) }
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
                Text("你可以让我做什么", fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                listOf(
                    "「帮我订阅《幕府将军》,只要 4K」",
                    "「看看现在有哪些任务在跑,失败的重试一下」",
                    "「这部剧缺了第 4 集,帮我找找资源」",
                    "「最近空间不够了,清理一下重复文件」",
                ).forEach { example ->
                    Text(example, fontSize = 11.5.sp, color = TextMuted, lineHeight = 19.sp)
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        TextField(
            value = state.input,
            onValueChange = vm::onInput,
            placeholder = { Text("描述你的需求…", fontSize = 13.5.sp, color = TextFaint) },
            minLines = 3,
            maxLines = 8,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { vm.create(onCreated) }),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = Color.White.copy(alpha = 0.06f),
                unfocusedContainerColor = Color.White.copy(alpha = 0.06f),
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
                focusedTextColor = Color.White,
                unfocusedTextColor = Color.White,
                cursorColor = Accent,
            ),
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        )
        state.error?.let {
            Text(it, fontSize = 12.sp, color = Danger, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
        }
        Spacer(Modifier.height(14.dp))
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.End) {
            Button(
                onClick = { vm.create(onCreated) },
                enabled = !state.creating && state.input.isNotBlank(),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF0A0E12)),
            ) {
                if (state.creating) {
                    CircularProgressIndicator(color = Color(0xFF0A0E12), modifier = Modifier.height(16.dp), strokeWidth = 2.dp)
                } else {
                    Text("开始对话", fontSize = 14.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}
