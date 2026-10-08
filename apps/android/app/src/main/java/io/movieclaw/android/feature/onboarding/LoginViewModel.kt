package io.movieclaw.android.feature.onboarding

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.discovery.ServerDiscovery
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 登录 / 初始化的状态机。
 * 两个分支：服务器已初始化 → `login(server, username, password)`；
 * 全新服务器（needSetup）→ `createAdminAndLogin(server, username, password)`，
 * 并校验两次密码一致。
 */
@HiltViewModel
class LoginViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val discovery: ServerDiscovery,
) : ViewModel() {

    data class UiState(
        val server: String = "",
        val username: String = "",
        val password: String = "",
        val confirmPassword: String = "",
        val needSetup: Boolean = false,
        val loading: Boolean = false,
        val discovering: Boolean = false,
        val error: String? = null,
        val loggedIn: Boolean = false,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    fun presetUsername(value: String) = _ui.update { it.copy(username = value) }
    fun onServer(v: String) = _ui.update { it.copy(server = v, error = null) }
    fun onUsername(v: String) = _ui.update { it.copy(username = v, error = null) }
    fun onPassword(v: String) = _ui.update { it.copy(password = v, error = null) }
    fun onConfirm(v: String) = _ui.update { it.copy(confirmPassword = v, error = null) }

    fun discoverServer() {
        if (_ui.value.discovering) return
        viewModelScope.launch {
            _ui.update { it.copy(discovering = true, error = null) }
            val found = runCatching { discovery.findFirst() }.getOrNull()
            _ui.update {
                it.copy(
                    discovering = false,
                    server = found ?: it.server,
                    error = if (found == null) "没有在局域网里发现服务器，请手动填写地址" else null,
                )
            }
        }
    }

    fun submit() {
        val s = _ui.value
        if (s.loading) return
        if (s.server.isBlank() || s.username.isBlank() || s.password.isBlank()) {
            _ui.update { it.copy(error = "请填写服务器地址、用户名与密码") }
            return
        }
        if (s.needSetup && s.password != s.confirmPassword) {
            _ui.update { it.copy(error = "两次输入的密码不一致") }
            return
        }
        viewModelScope.launch {
            _ui.update { it.copy(loading = true, error = null) }
            try {
                if (s.needSetup) {
                    repository.createAdminAndLogin(s.server, s.username, s.password)
                } else {
                    repository.login(s.server, s.username, s.password)
                }
                _ui.update { it.copy(loading = false, loggedIn = true) }
            } catch (e: Exception) {
                _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
            }
        }
    }
}
