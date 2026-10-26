package io.movieclaw.android.feature.update

import android.app.Application
import io.movieclaw.android.core.AppScopes
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.BuildInfo
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.core.model.generated.ClientReleaseView
import io.movieclaw.android.core.network.ServerAddress
import io.movieclaw.core.update.AppUpdater
import io.movieclaw.core.update.UpdatePolicy
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * App 自身更新（core/update）：启动后每天自动问一次自己的服务器，有新版弹窗；「我的」页底部的版本号可手动检查。
 * 下载走服务器（手机常常连不上 GitHub），校验 sha256 后交给系统安装器。
 */
@Singleton
class AppUpdateController @Inject constructor(
    app: Application,
    private val session: SessionRepository,
    private val apiFactory: ApiFactory,
) {
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

    private val updater = AppUpdater(app, product = "android", currentBuild = BuildInfo.BUILD_NUMBER.toLong())
    private val scope = AppScopes.main("AppUpdateController")
    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()
    private var job: Job? = null

    val canInstall: Boolean get() = updater.canInstall()
    fun installPermissionIntent() = updater.installPermissionIntent()

    /** 当前服务器的接口与带账号凭证的 HTTP 客户端（官网查不到时兜底）；没连服务器时为 null */
    private fun core() = session.ui.value.origin?.let { origin -> origin to apiFactory.corePlayback(origin) }

    /** 启动时：一天最多问一次（先官网、不通再问服务器），跳过过的版本不再弹；失败不打扰 */
    fun autoCheck() {
        if (job?.isActive == true || _state.value !is State.Idle) return
        val core = core()?.second
        job = scope.launch {
            updater.autoCheck(core?.api)?.let { _state.value = State.Available(it) }
        }
    }

    /** 手动检查（版本号那一行）：结果总会告诉用户，包括「已是最新」与失败原因 */
    fun checkNow() {
        val core = core()?.second
        job?.cancel()
        _state.value = State.Checking
        job = scope.launch {
            _state.value = runCatching { updater.check(core?.api, force = true) }.fold(
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

    fun startUpdate(offer: AppUpdater.Check.Available) {
        val release = offer.release
        val server = core()
        val apiBase = server?.first?.let { ServerAddress.normalize(it)?.apiBase?.toHttpUrlOrNull() }
        job?.cancel()
        var fromServer = offer.officialApkUrl == null
        _state.value = State.Downloading(release, 0f, fromServer)
        job = scope.launch {
            val apk = runCatching {
                // 先官网直链，不通再经服务器（账号凭证由 core.http 自己带上）
                updater.download(offer, server?.second?.http, apiBase, null, onSource = { fromServer = it == AppUpdater.Source.Server }) { p ->
                    _state.value = State.Downloading(release, p, fromServer)
                }
            }.getOrElse {
                _state.value = State.Failed(io.movieclaw.core.update.UpdatePolicy.errorText(it), offer)
                return@launch
            }
            _state.value = State.Installing(release)
            updater.install(apk) { status ->
                when (status) {
                    AppUpdater.InstallStatus.WaitingForUser -> Unit
                    // 装好后进程会被系统结束，这里多半走不到
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

    fun summary(release: ClientReleaseView) = UpdatePolicy.summary(release.changelog)
}
