package io.movieclaw.android.routing

import kotlinx.coroutines.flow.MutableStateFlow
import io.movieclaw.android.feature.share.ShareRoute
import io.movieclaw.android.core.session.DeepLinkBus
import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.designsystem.FeedbackHost
import io.movieclaw.android.core.designsystem.FeedbackBus
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.session.SessionPhase
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.core.session.LocalPermissions
import io.movieclaw.android.core.session.LocalSearchAccess
import io.movieclaw.android.core.session.Permissions
import io.movieclaw.android.core.session.SearchAccessRepository
import io.movieclaw.android.feature.onboarding.LoginScreen
import io.movieclaw.android.feature.root.MainTabScreen
import javax.inject.Inject
import kotlinx.coroutines.launch

@HiltViewModel
class RootViewModel @Inject constructor(
    private val repository: SessionRepository,
    val feedback: FeedbackBus,
    private val deepLinkBus: DeepLinkBus,
    private val searchAccess: SearchAccessRepository,
) : ViewModel() {
    val state = repository.ui
    val share = deepLinkBus.pendingShare

    /** 搜索分区（成员那格要探测可见库，见 SearchAccessRepository） */
    val searchAccessState = searchAccess.state

    fun dismissShare(slug: String) {
        if (share.value?.slug == slug) deepLinkBus.consume()
    }

    init {
        if (repository.ui.value.phase == SessionPhase.BOOTING) {
            viewModelScope.launch { repository.boot() }
        }
        // 权限快照随会话变化重算（换账号即重探可见库）
        viewModelScope.launch {
            repository.ui.collect { ui -> searchAccess.sync(ui.session) }
        }
    }
}

/** 顶层状态机:BOOTING(黑屏)→ NEEDS_LOGIN(登录页)/ READY(主壳) */
@Composable
fun MovieClawRoot(vm: RootViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    val shareLink by vm.share.collectAsStateWithLifecycle()
    val toasts by vm.feedback.toasts.collectAsStateWithLifecycle()
    val searchAccess by vm.searchAccessState.collectAsStateWithLifecycle()

    // 权限快照 + 搜索分区下发给整棵主壳：页面读它裁剪入口（安全边界仍在后端）
    androidx.compose.runtime.CompositionLocalProvider(
        LocalFeedback provides vm.feedback,
        LocalPermissions provides Permissions.of(state.session),
        LocalSearchAccess provides searchAccess,
    ) {
        Box(Modifier.fillMaxSize().background(Bg)) {
            when {
                // 访客分享不需要登录:深链打开时优先展示分享页
                shareLink != null -> ShareRoute(
                    link = shareLink!!,
                    onExit = { vm.dismissShare(shareLink!!.slug) },
                )
                state.phase == SessionPhase.BOOTING -> Box(Modifier.fillMaxSize().background(Bg))
                // 未登录只有登录页：批准设备登录是登录后的事（设置 → 设备管理），iOS 同为登录后入口
                state.phase == SessionPhase.NEEDS_LOGIN -> LoginScreen(presetUsername = state.presetUsername)
                else -> androidx.compose.runtime.key(state.origin, state.session?.username) { AppNav() }
            }
            // 顶部 Toast 常驻在所有内容之上(iOS Feedback 宿主)
            FeedbackHost(
                toasts = toasts,
                onDismiss = vm.feedback::dismiss,
                modifier = Modifier.align(androidx.compose.ui.Alignment.TopCenter),
            )
        }
    }
}
