package io.movieclaw.androidtv.ui.update

import android.app.Application
import io.movieclaw.androidtv.AccountSession
import io.movieclaw.androidtv.BuildConfig
import io.movieclaw.core.model.generated.ClientReleaseView
import io.movieclaw.core.update.AppUpdater
import io.movieclaw.core.update.UpdatePolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/**
 * 电视 App 自身更新（core/update）：进主界面后每天自动问一次自己的服务器，有新版弹窗；「谁在看」页底部可手动检查。
 * 先直接找官网（GitHub）查、下；电视在内网常常连不上，就改经自己的服务器。校验 sha256 后交给系统安装器。
 */
class TvAppUpdate(app: Application, private val http: OkHttpClient, private val scope: CoroutineScope) {
    sealed interface State {
        data object Idle : State
        data object Checking : State
        data class UpToDate(val latest: ClientReleaseView) : State
        data class Available(val offer: AppUpdater.Check.Available) : State {
            val release get() = offer.release
            val signatureMatches get() = offer.signatureMatches
        }
        data class Downloading(val release: ClientReleaseView, val progress: Float, val fromServer: Boolean) : State
        data class Installing(val release: ClientReleaseView) : State
        data class Failed(val message: String, val offer: AppUpdater.Check.Available? = null) : State
    }

    private val updater = AppUpdater(app, product = "androidtv", currentBuild = BuildConfig.VERSION_CODE.toLong())
    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()
    private var job: Job? = null

    val canInstall: Boolean get() = updater.canInstall()
    fun installPermissionIntent() = updater.installPermissionIntent()
    fun summary(release: ClientReleaseView) = UpdatePolicy.summary(release.changelog)

    fun autoCheck(session: AccountSession) {
        if (job?.isActive == true || _state.value !is State.Idle) return
        job = scope.launch {
            updater.autoCheck(session.api)?.let { _state.value = State.Available(it) }
        }
    }

    fun checkNow(session: AccountSession) {
        job?.cancel()
        _state.value = State.Checking
        job = scope.launch {
            _state.value = runCatching { updater.check(session.api, force = true) }.fold(
                onSuccess = { result ->
                    when (result) {
                        is AppUpdater.Check.Available -> State.Available(result)
                        is AppUpdater.Check.UpToDate -> State.UpToDate(result.latest)
                    }
                },
                onFailure = { State.Failed(io.movieclaw.core.update.UpdatePolicy.errorText(it)) },
            )
        }
    }

    fun startUpdate(session: AccountSession, offer: AppUpdater.Check.Available) {
        val release = offer.release
        job?.cancel()
        var fromServer = offer.officialApkUrl == null
        _state.value = State.Downloading(release, 0f, fromServer)
        job = scope.launch {
            val apk = runCatching {
                // 先官网直链，不通再经服务器
                updater.download(offer, http, session.server.apiBase, session.token, onSource = { fromServer = it == AppUpdater.Source.Server }) { p ->
                    _state.value = State.Downloading(release, p, fromServer)
                }
            }.getOrElse {
                _state.value = State.Failed(UpdatePolicy.errorText(it), offer)
                return@launch
            }
            _state.value = State.Installing(release)
            updater.install(apk) { status ->
                when (status) {
                    AppUpdater.InstallStatus.WaitingForUser -> Unit
                    AppUpdater.InstallStatus.Installed -> _state.value = State.Idle
                    is AppUpdater.InstallStatus.Failed -> _state.value = State.Failed(status.message, offer)
                }
            }
        }
    }

    fun skip(release: ClientReleaseView) {
        updater.skippedBuild = release.build
        dismiss()
    }

    fun dismiss() {
        job?.cancel()
        _state.value = State.Idle
    }
}
