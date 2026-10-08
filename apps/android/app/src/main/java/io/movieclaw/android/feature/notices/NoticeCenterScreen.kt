package io.movieclaw.android.feature.notices

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.DoneAll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.Notice
import io.movieclaw.android.core.model.visibleNotices
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * 通知中心(管理员):只有需要处理的问题才出现在这里。
 * 30s 轮询 + 忽略(乐观更新),对齐 iOS NoticeCenter 的行为;
 * 服务端无推送基础设施,故用轮询(设计方案 §7.9)。
 */
@HiltViewModel
class NoticeCenterViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
) : ViewModel() {

    private val _state = MutableStateFlow<Loadable<List<Notice>>>(Loadable.Loading)
    val state = _state.asStateFlow()

    private var pollJob: Job? = null

    init {
        refresh()
        pollJob = viewModelScope.launch {
            while (isActive) {
                delay(POLL_INTERVAL_MS)
                refresh(silent = true)
            }
        }
    }

    fun refresh(silent: Boolean = false) {
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            if (!silent) _state.value = Loadable.Loading
            runCatching { apiFactory.forOrigin(origin).notices().dataOrThrow() }
                // 与「我的」页待处理计数同一口径（网页 notice-center / iOS NoticeCenterView.visible）：
                // 目录级根因告警存在时，被它收编的单种子告警折叠不显示
                .onSuccess { notices -> _state.value = Loadable.Ready(visibleNotices(notices)) }
                .onFailure { e ->
                    if (_state.value !is Loadable.Ready) _state.value = Loadable.Failed(friendlyMessage(e))
                }
        }
    }

    /** 乐观忽略:先从列表移除,失败则回滚(下次轮询会带回) */
    fun dismiss(notice: Notice) {
        val current = (_state.value as? Loadable.Ready)?.value ?: return
        _state.value = Loadable.Ready(current.filterNot { it.id == notice.id })
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).dismissNotice(notice.id) }
                .onFailure { _state.value = Loadable.Ready(current) }
        }
    }

    fun dismissAll() {
        val current = (_state.value as? Loadable.Ready)?.value ?: return
        if (current.isEmpty()) return
        _state.value = Loadable.Ready(emptyList())
        viewModelScope.launch {
            val origin = sessionRepository.ui.value.origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            current.forEach { runCatching { api.dismissNotice(it.id) } }
            refresh(silent = true)
        }
    }

    override fun onCleared() {
        pollJob?.cancel()
        super.onCleared()
    }

    private companion object {
        const val POLL_INTERVAL_MS = 30_000L
    }
}

@Composable
fun NoticeCenterScreen(onBack: () -> Unit, vm: NoticeCenterViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 4.dp)) {
            McNavButton(
                icon = Icons.AutoMirrored.Rounded.ArrowBack,
                contentDescription = "返回",
                onClick = onBack,
            )
            Text("通知中心", style = McType.headline)
            Spacer(Modifier.weight(1f))
            if ((state as? Loadable.Ready)?.value?.isNotEmpty() == true) {
                TextButton(onClick = vm::dismissAll) {
                    Icon(Icons.Rounded.DoneAll, contentDescription = null, tint = Accent, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("全部忽略", fontSize = 12.sp, color = Accent)
                }
            }
        }
        when (val s = state) {
            Loadable.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            is Loadable.Failed -> ErrorPane(message = s.message, onRetry = { vm.refresh() })
            is Loadable.Ready -> if (s.value.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("没有需要处理的问题", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.height(6.dp))
                        Text("订阅失败、上游不可达等运行时异常会出现在这里", fontSize = 11.5.sp, color = TextFaint)
                    }
                }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(s.value, key = { it.id }) { notice -> NoticeCard(notice) { vm.dismiss(notice) } }
                }
            }
        }
    }
}

@Composable
private fun NoticeCard(notice: Notice, onDismiss: () -> Unit) {
    val color = when (notice.severity) {
        "error", "critical" -> Danger
        "warning" -> Warning
        else -> Info
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.045f))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(7.dp).background(color, CircleShape))
            Spacer(Modifier.width(8.dp))
            Text(
                notice.title,
                fontSize = 13.5.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(notice.source, fontSize = 10.5.sp, color = TextFaint)
        }
        if (notice.message.isNotEmpty()) {
            Spacer(Modifier.height(7.dp))
            Text(notice.message, fontSize = 12.sp, color = TextMuted, lineHeight = 18.sp)
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            notice.updatedAt?.let {
                Text(McFormat.relative(it), style = McType.caption, color = TextFaint)
            }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onDismiss) {
                Text("忽略", fontSize = 12.sp, color = Accent)
            }
        }
    }
}
