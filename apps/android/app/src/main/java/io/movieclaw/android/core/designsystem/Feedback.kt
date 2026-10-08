package io.movieclaw.android.core.designsystem

import io.movieclaw.android.core.AppScopes

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class FeedbackTone { Success, Info, Warning, Error }

/** 一条待展示的提示(VM 侧构造,由顶部 Toast 宿主消费) */
data class McNotice(val text: String, val tone: FeedbackTone = FeedbackTone.Info)

/**
 * 全局提示总线 —— 对齐 iOS Feedback:
 *   顶部玻璃条、最多同时 4 条(超出丢最旧)、错误 6 秒其余 4 秒、点任意处关闭。
 */
@Singleton
class FeedbackBus @Inject constructor() {

    data class Toast(
        val id: Long,
        val text: String,
        val tone: FeedbackTone,
        val actionLabel: String? = null,
        val onAction: (() -> Unit)? = null,
    )

    private val scope = AppScopes.main("Feedback")
    private val counter = AtomicLong(0)

    private val _toasts = MutableStateFlow<List<Toast>>(emptyList())
    val toasts: StateFlow<List<Toast>> = _toasts.asStateFlow()

    fun show(
        text: String,
        tone: FeedbackTone = FeedbackTone.Info,
        actionLabel: String? = null,
        onAction: (() -> Unit)? = null,
    ) {
        if (text.isBlank()) return
        val toast = Toast(counter.incrementAndGet(), text, tone, actionLabel, onAction)
        _toasts.update { (it + toast).takeLast(MAX_TOASTS) }
        scope.launch {
            delay(if (tone == FeedbackTone.Error) ERROR_DURATION_MS else DURATION_MS)
            dismiss(toast.id)
        }
    }

    fun show(notice: McNotice) = show(notice.text, notice.tone)

    fun success(text: String) = show(text, FeedbackTone.Success)
    fun info(text: String) = show(text, FeedbackTone.Info)
    fun warning(text: String) = show(text, FeedbackTone.Warning)
    fun error(text: String) = show(text, FeedbackTone.Error)

    fun dismiss(id: Long) = _toasts.update { list -> list.filterNot { it.id == id } }

    private companion object {
        const val MAX_TOASTS = 4
        const val DURATION_MS = 4_000L
        const val ERROR_DURATION_MS = 6_000L
    }
}

/** 顶部 Toast 宿主(根布局挂在内容之上) */
@Composable
fun FeedbackHost(toasts: List<FeedbackBus.Toast>, onDismiss: (Long) -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        toasts.forEach { toast ->
            androidx.compose.runtime.key(toast.id) {
                val visible = remember { MutableTransitionState(false).apply { targetState = true } }
                AnimatedVisibility(
                    visibleState = visible,
                    enter = slideInVertically(
                        initialOffsetY = { -it },
                        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMediumLow),
                    ) + fadeIn(),
                    exit = slideOutVertically(targetOffsetY = { -it }) + fadeOut(),
                ) {
                    ToastRow(toast = toast, onDismiss = { onDismiss(toast.id) })
                }
            }
        }
    }
}

@Composable
private fun ToastRow(toast: FeedbackBus.Toast, onDismiss: () -> Unit) {
    val (icon, toneColor) = when (toast.tone) {
        FeedbackTone.Success -> Icons.Rounded.CheckCircle to Success
        FeedbackTone.Info -> Icons.Rounded.Info to Info
        FeedbackTone.Warning -> Icons.Rounded.Warning to Warning
        FeedbackTone.Error -> Icons.Rounded.Error to Danger
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(SurfaceRaised, RoundedCornerShape(18.dp))
            .border(1.dp, LineColor, RoundedCornerShape(18.dp))
            .clickable(onClick = onDismiss)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = toneColor, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Text(
            toast.text,
            style = McType.subheadline,
            color = TextPrimary,
            modifier = Modifier.weight(1f),
        )
        toast.actionLabel?.let { label ->
            Spacer(Modifier.width(10.dp))
            Text(
                label,
                style = McType.subheadlineSemibold,
                color = Accent,
                modifier = Modifier.clickable {
                    toast.onAction?.invoke()
                    onDismiss()
                },
            )
        }
    }
}

/** 全局反馈总线在 Compose 里的入口(根布局提供) */
val LocalFeedback = androidx.compose.runtime.staticCompositionLocalOf<FeedbackBus> {
    error("FeedbackBus 未提供:应在根布局用 LocalFeedback 注入")
}
