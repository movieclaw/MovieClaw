package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.ui.window.Dialog
import io.movieclaw.android.core.designsystem.TextPrimary
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Cached
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.FeedbackBus
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.ProgressBar
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.SurfaceRaised
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.GithubToken
import io.movieclaw.android.core.model.GithubTokenPayload
import io.movieclaw.android.core.model.ModelUpdateCheck
import io.movieclaw.android.core.model.PendingUpdate
import io.movieclaw.android.core.model.RollbackOptions
import io.movieclaw.android.core.model.RollbackRequest
import io.movieclaw.android.core.model.RollbackTarget
import io.movieclaw.android.core.model.ScheduledTask
import io.movieclaw.android.core.model.ScheduledTaskUpdate
import io.movieclaw.android.core.model.LogDay
import io.movieclaw.android.core.model.LogContent
import io.movieclaw.android.core.model.NetworkConfig
import io.movieclaw.android.core.model.NetworkTestResult
import io.movieclaw.android.core.model.StorageState
import io.movieclaw.android.core.model.UpdateCheck
import io.movieclaw.android.core.model.UpdateProgress
import io.movieclaw.android.core.model.UpdateStatus
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import io.movieclaw.android.core.designsystem.formSheetScroll

/* ---------------- 更新与维护 ---------------- */

@HiltViewModel
class MaintenanceViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val feedback: FeedbackBus,
) : ViewModel() {

    /** 重启等待态：Idle → Waiting（轮询 /health）→ 恢复后回 Idle / Timeout */
    enum class RestartWait { Idle, Waiting, Timeout }

    private enum class RestartKind { Version, App }

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val status: UpdateStatus? = null,
        /** 进页预填的待更新快照（读库不触网）；手动检查后由 check/modelCheck 接管 */
        val pending: PendingUpdate? = null,
        val check: UpdateCheck? = null,
        val checking: Boolean = false,
        val progress: UpdateProgress? = null,
        val actionError: String? = null,
        val modelCheck: ModelUpdateCheck? = null,
        val modelChecking: Boolean = false,
        val rollback: RollbackOptions? = null,
        val retentionBusy: Boolean = false,
        val token: GithubToken? = null,
        val tokenBusy: Boolean = false,
        val restart: RestartWait = RestartWait.Idle,
        val tasks: List<ScheduledTask>? = null,
        val tasksError: String? = null,
        val taskBusyKey: String? = null,
        val storage: StorageState? = null,
        val storageLoading: Boolean = false,
        val applying: Boolean = false,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            val api = apiFactory.forOrigin(origin)
            runCatching { api.updateStatus().dataOrThrow() }
                .onSuccess { status -> _ui.update { it.copy(loading = false, status = status) } }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
            // 进页预填：定时检查留下的快照（读库不触网），有新版直接摆出卡片
            runCatching { api.pendingUpdate().dataOrThrow() }
                .onSuccess { pending -> _ui.update { it.copy(pending = pending) } }
            runCatching { api.storageState().dataOrThrow() }
                .onSuccess { storage -> _ui.update { it.copy(storage = storage) } }
            // 回退候选与保留策略（纯本地读盘）；失败不打扰——回退区自然不显示
            runCatching { api.rollbackOptions().dataOrThrow() }
                .onSuccess { rollback -> _ui.update { it.copy(rollback = rollback) } }
            runCatching { api.githubToken().dataOrThrow() }
                .onSuccess { token -> _ui.update { it.copy(token = token) } }
            loadTasks()
        }
    }

    private suspend fun loadTasks() {
        val origin = origin ?: return
        runCatching { apiFactory.forOrigin(origin).scheduledTasks().dataOrThrow() }
            .onSuccess { tasks -> _ui.update { it.copy(tasks = tasks, tasksError = null) } }
            .onFailure { e -> _ui.update { it.copy(tasksError = friendlyMessage(e)) } }
    }

    /** 恢复进行中的更新跟踪：进页时后台可能正在下载安装（进度在后端单例里） */
    fun resumeProgressTracking() {
        if (_ui.value.applying || _ui.value.restart != RestartWait.Idle) return
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val p = runCatching { apiFactory.forOrigin(origin).updateProgress().dataOrThrow() }.getOrNull() ?: return@launch
            when (p.phase) {
                "checking", "downloading", "verifying", "applying" -> {
                    _ui.update { it.copy(progress = p, applying = true) }
                    pollProgress()
                }
                "restarting" -> {
                    _ui.update { it.copy(progress = p) }
                    waitForRestart(RestartKind.Version)
                }
            }
        }
    }

    fun checkUpdate() {
        if (_ui.value.checking) return
        _ui.update { it.copy(checking = true, check = null, actionError = null) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).checkUpdate().dataOrThrow() }
                .onSuccess { check -> _ui.update { it.copy(checking = false, check = check) } }
                .onFailure { e ->
                    _ui.update { it.copy(checking = false) }
                    feedback.error(friendlyMessage(e))
                }
        }
    }

    /** 应用更新：起一次并把进度轮询到结束（服务端更新期间会重启） */
    fun applyUpdate() {
        if (_ui.value.applying) return
        _ui.update { it.copy(applying = true, actionError = null) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            runCatching { api.applyUpdate().dataOrThrow() }
                .onSuccess { p ->
                    _ui.update { it.copy(progress = p) }
                    pollProgress()
                }
                .onFailure { e ->
                    _ui.update { it.copy(applying = false) }
                    feedback.error(friendlyMessage(e))
                }
        }
    }

    /** 更新执行中：轮询进度直到失败或进入重启阶段（Web 同款：连续 3 次失败才算进入重启） */
    private fun pollProgress() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            var failStreak = 0
            repeat(600) {
                delay(1_500)
                val current = runCatching { api.updateProgress().dataOrThrow() }.getOrNull()
                if (current == null) {
                    failStreak += 1
                    if (failStreak >= 3) {
                        _ui.update { it.copy(applying = false) }
                        waitForRestart(RestartKind.Version)
                        return@launch
                    }
                } else {
                    failStreak = 0
                    _ui.update { it.copy(progress = current) }
                    when (current.phase.lowercase()) {
                        "failed" -> {
                            _ui.update { it.copy(applying = false) }
                            return@launch
                        }
                        "restarting" -> {
                            _ui.update { it.copy(applying = false) }
                            waitForRestart(RestartKind.Version)
                            return@launch
                        }
                        "idle" -> {
                            // 活跃阶段之后读到 idle = 后端已重启完毕：更新已生效，刷新整页数据
                            _ui.update { it.copy(applying = false) }
                            refresh()
                            return@launch
                        }
                    }
                }
            }
            _ui.update { it.copy(applying = false) }
            feedback.info("更新仍在进行,可稍后再打开查看")
        }
    }

    fun dismissLastAbnormalExit() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).dismissLastAbnormalExit() }
                .onSuccess { _ui.update { it.copy(status = it.status?.copy(lastAbnormalExit = null)) } }
                .onFailure { e -> feedback.error(friendlyMessage(e)) }
        }
    }

    fun checkModelUpdate() {
        if (_ui.value.modelChecking) return
        _ui.update { it.copy(modelChecking = true, modelCheck = null, actionError = null) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).checkModelUpdate().dataOrThrow() }
                .onSuccess { check -> _ui.update { it.copy(modelChecking = false, modelCheck = check) } }
                .onFailure { e ->
                    _ui.update { it.copy(modelChecking = false) }
                    feedback.error(friendlyMessage(e))
                }
        }
    }

    fun applyModelUpdate() {
        if (_ui.value.applying) return
        _ui.update { it.copy(applying = true, actionError = null) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).applyModelUpdate().dataOrThrow() }
                .onSuccess { p ->
                    _ui.update { it.copy(progress = p) }
                    pollProgress()
                }
                .onFailure { e ->
                    _ui.update { it.copy(applying = false) }
                    feedback.error(friendlyMessage(e))
                }
        }
    }

    fun saveRetention(value: Int) {
        val rollback = _ui.value.rollback ?: return
        if (_ui.value.retentionBusy) return
        val next = value.coerceIn(2, 20)
        if (next == rollback.keepVersions) return
        _ui.update { it.copy(retentionBusy = true) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).saveUpdateRetention(io.movieclaw.android.core.model.RetentionRequest(next)).dataOrThrow()
            }.onSuccess {
                runCatching { apiFactory.forOrigin(origin).rollbackOptions().dataOrThrow() }
                    .onSuccess { options -> _ui.update { it.copy(rollback = options) } }
            }.onFailure { e -> feedback.error(friendlyMessage(e)) }
            _ui.update { it.copy(retentionBusy = false) }
        }
    }

    /** 执行回退：restore 由目标的数据兼容判定决定（restore 档自动带上恢复） */
    fun rollbackTo(target: RollbackTarget) {
        if (_ui.value.applying) return
        _ui.update { it.copy(applying = true, actionError = null) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).rollbackTo(
                    RollbackRequest(
                        target = if (target.kind == "baseline" || target.version == null) "baseline" else target.version!!,
                        restoreBackup = target.schemaAction == "restore",
                    ),
                )
            }.onSuccess {
                waitForRestart(RestartKind.Version)
            }.onFailure { e ->
                _ui.update { it.copy(applying = false) }
                feedback.error(friendlyMessage(e))
            }
        }
    }

    /** 保存或清除 GitHub 访问令牌（空串 = 清除） */
    fun saveGithubToken(token: String) {
        if (_ui.value.tokenBusy) return
        _ui.update { it.copy(tokenBusy = true, actionError = null) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).saveGithubToken(GithubTokenPayload(token)).dataOrThrow()
            }.onSuccess { saved -> _ui.update { it.copy(token = saved) } }
                .onFailure { e -> feedback.error(friendlyMessage(e)) }
            _ui.update { it.copy(tokenBusy = false) }
        }
    }

    /** 重启应用：请求后端优雅停机，随后轮询 /health 等服务恢复（先见到不可达、再见到恢复） */
    fun restartApp() {
        if (_ui.value.restart != RestartWait.Idle) return
        waitForRestart(RestartKind.App)
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).restartApp() }
            // 请求可能因进程退出而中断，属预期：等待流程已经在轮询 /health 了
        }
    }

    /** 重启超时后的「返回」：回 Idle 让用户可以重试或离开 */
    fun restartRecovered() {
        _ui.update { it.copy(restart = RestartWait.Idle) }
    }

    private fun waitForRestart(kind: RestartKind) {
        _ui.update { it.copy(restart = RestartWait.Waiting) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            var sawDown = false
            // 90 轮 × 2 秒 = 3 分钟封顶；30 轮（≈60 秒）没见到不可达也放行（重启在探测间隙完成）
            for (i in 0 until 90) {
                delay(2_000)
                val up = runCatching { apiFactory.forOrigin(origin).health() }.isSuccess
                if (up) {
                    if (sawDown || i >= 30) {
                        _ui.update { it.copy(restart = RestartWait.Idle) }
                        refresh()
                        return@launch
                    }
                } else {
                    sawDown = true
                }
            }
            _ui.update { it.copy(restart = RestartWait.Timeout) }
        }
    }

    /** 只切启停：周期一律取服务器上已保存的那份（界面草稿不借开关夹带提交，Web toggleUpdate 同款） */
    fun toggleTask(task: ScheduledTask, enabled: Boolean) {
        if (_ui.value.taskBusyKey != null) return
        _ui.update { it.copy(taskBusyKey = task.key) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val body = if (task.triggerType == "cron") {
                ScheduledTaskUpdate(enabled, "cron", cronExpr = task.cronExpr)
            } else {
                ScheduledTaskUpdate(enabled, "interval", intervalSeconds = task.intervalSeconds)
            }
            runCatching { apiFactory.forOrigin(origin).updateScheduledTask(task.key, body).dataOrThrow() }
                .onSuccess { updated ->
                    _ui.update { st ->
                        st.copy(
                            taskBusyKey = null,
                            tasks = st.tasks?.map { if (it.key == updated.key) updated else it },
                        )
                    }
                }
                .onFailure { e ->
                    _ui.update { it.copy(taskBusyKey = null) }
                    feedback.error(friendlyMessage(e))
                }
        }
    }

    /** 保存周期：interval 秒数或 cron 表达式整体提交 */
    fun saveTaskSchedule(task: ScheduledTask, triggerType: String, intervalSeconds: Long?, cronExpr: String?) {
        if (_ui.value.taskBusyKey != null) return
        _ui.update { it.copy(taskBusyKey = task.key) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val body = ScheduledTaskUpdate(
                enabled = task.enabled,
                triggerType = triggerType,
                intervalSeconds = intervalSeconds,
                cronExpr = cronExpr,
            )
            runCatching { apiFactory.forOrigin(origin).updateScheduledTask(task.key, body).dataOrThrow() }
                .onSuccess { updated ->
                    _ui.update { st ->
                        st.copy(
                            taskBusyKey = null,
                            tasks = st.tasks?.map { if (it.key == updated.key) updated else it },
                        )
                    }
                    feedback.success("已保存「${updated.title}」的周期")
                }
                .onFailure { e ->
                    _ui.update { it.copy(taskBusyKey = null) }
                    feedback.error(friendlyMessage(e))
                }
        }
    }

    fun clean(key: String) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(storageLoading = true) }
            runCatching { apiFactory.forOrigin(origin).cleanStorage(key).dataOrThrow() }
                .onSuccess { result ->
                    feedback.success(
                        "已清理 ${result.removed} 项,释放 ${McFormat.bytes(result.freedBytes)}" +
                            if (result.skippedBusy > 0) "(跳过 ${result.skippedBusy} 项使用中)" else ""
                    )
                    runCatching { apiFactory.forOrigin(origin).storageState().dataOrThrow() }
                        .onSuccess { storage -> _ui.update { it.copy(storage = storage) } }
                }
                .onFailure { e -> feedback.error(friendlyMessage(e)) }
            _ui.update { it.copy(storageLoading = false) }
        }
    }
}

/** 周期文案（Web `describeSchedule` 同款）：「每 N 小时 / 每 N 分钟 / 每天 HH:MM / cron 原文」 */
internal fun describeSchedule(triggerType: String, intervalSeconds: Long?, cronExpr: String?): String {
    if (triggerType == "interval") {
        val seconds = intervalSeconds ?: 0
        if (seconds <= 0) return "间隔未设置"
        if (seconds % 3600 == 0L) return "每 ${seconds / 3600} 小时"
        if (seconds % 60 == 0L) return "每 ${seconds / 60} 分钟"
        return "每 $seconds 秒"
    }
    val daily = dailyTimeOf(cronExpr)
    if (daily != null) {
        return "每天 %02d:%02d".format(daily.first, daily.second)
    }
    return cronExpr?.let { "cron：$it" } ?: "未设置"
}

/** 「每天 HH:MM」形状的 cron（分 时 * * *）；不是这个形状返回 null */
internal fun dailyTimeOf(cron: String?): Pair<Int, Int>? {
    if (cron == null) return null
    val parts = cron.trim().split(Regex("\\s+"))
    if (parts.size != 5) return null
    val (minute, hour, dom, month, dow) = parts
    if (dom != "*" || month != "*" || dow != "*") return null
    val h = hour.toIntOrNull() ?: return null
    val m = minute.toIntOrNull() ?: return null
    if (h !in 0..23 || m !in 0..59) return null
    return h to m
}

@Composable
fun MaintenanceSettingsScreen(onBack: () -> Unit, vm: MaintenanceViewModel = hiltViewModel()) {
    val state by vm.ui.collectAsStateWithLifecycle()

    // 恢复进行中的更新跟踪：进页时后台可能正在下载安装（不恢复会显示空闲、按钮可点）
    LaunchedEffect(Unit) { vm.resumeProgressTracking() }

    Column(Modifier.fillMaxSize()) {
        SettingsHeader(title = "更新与维护", onBack = onBack)
        when (state.restart) {
            MaintenanceViewModel.RestartWait.Waiting -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(32.dp)) {
                    CircularProgressIndicator(color = TextMuted)
                    Spacer(Modifier.height(14.dp))
                    Text("正在重启应用…", style = McType.title3)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "服务恢复后会自动刷新,通常需要几秒到几十秒。",
                        style = McType.footnote,
                        color = TextMuted,
                    )
                }
            }
            MaintenanceViewModel.RestartWait.Timeout -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(32.dp)) {
                    Text("等待超时,应用尚未恢复", style = McType.title3)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "Docker 部署通常几秒内自动拉起,请稍后回到本页查看;源码部署且无守护时,需要到服务器上手动启动。",
                        style = McType.footnote,
                        color = TextMuted,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                    Spacer(Modifier.height(14.dp))
                    SettingsActionButton("返回") { vm.restartRecovered() }
                }
            }
            MaintenanceViewModel.RestartWait.Idle -> when {
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted)
                }
                state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::refresh)
                else -> MaintenanceBody(state, vm)
            }
        }
    }
}

@Composable
private fun MaintenanceBody(state: MaintenanceViewModel.UiState, vm: MaintenanceViewModel) {
    val updating = state.progress != null &&
        state.progress.phase !in setOf("idle", "failed") && state.progress.phase.isNotEmpty()

    // 手机上一页装下全部太长：按 Web 同款分三页签（版本与更新 / 定时任务 / 存储），
    // 有可用更新时「版本与更新」页签点一颗小蓝点（Web AppUpdateDot 同款）
    var tab by rememberSaveable { mutableStateOf(0) }
    val pendingUpdate = (state.check?.updateAvailable == true) ||
        (state.check == null && state.pending?.appVersion != null)
    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            listOf("版本与更新", "定时任务", "存储").forEachIndexed { index, label ->
                val on = tab == index
                Row(
                    Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(if (on) AccentSoft else Color.Transparent)
                        .clickable { tab = index }
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(label, style = McType.sub, color = if (on) Accent else TextMuted)
                    if (index == 0 && pendingUpdate) {
                        Spacer(Modifier.width(5.dp))
                        Box(
                            Modifier
                                .size(6.dp)
                                .clip(androidx.compose.foundation.shape.CircleShape)
                                .background(Accent),
                        )
                    }
                }
            }
        }
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            if (tab == 0) {
                    // ── 版本 ──
                    state.status?.let { status ->
                        GlassCard(Modifier.fillMaxWidth()) {
                            Text("服务器版本", style = McType.subheadlineSemibold)
                            Spacer(Modifier.height(6.dp))
                            Text(
                                buildString {
                                    append("v").append(status.currentVersion.ifEmpty { "未知" })
                                    append(" · ").append(
                                        when (status.codeSource) {
                                            "overlay" -> "应用内更新版本${status.overlayVersion?.let { " v$it" } ?: ""}"
                                            "baseline" -> "Docker 镜像内置"
                                            else -> "源码部署"
                                        },
                                    )
                                },
                                style = McType.footnote,
                                color = TextMuted,
                            )
                            if (!status.canUpdate) {
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    "仅 Docker 镜像部署支持应用内更新;源码部署请用 git pull 更新。",
                                    style = McType.caption,
                                    color = TextFaint,
                                )
                            }
                            if (status.badVersions.isNotEmpty()) {
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    "版本 ${status.badVersions.joinToString("、")} 曾连续启动失败,已被自动回落保护。",
                                    style = McType.caption,
                                    color = Warning,
                                )
                            }
                            if (status.inactiveOverlayVersion != null) {
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    "已安装的 v${status.inactiveOverlayVersion} 未在运行${status.inactiveOverlayReason?.let { "：$it" } ?: ""}",
                                    style = McType.caption,
                                    color = Warning,
                                    lineHeight = 17.sp,
                                )
                            }
                            status.lastAbnormalExit?.let { exit ->
                                Spacer(Modifier.height(8.dp))
                                Column(
                                    Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(Warning.copy(alpha = 0.12f))
                                        .padding(10.dp),
                                ) {
                                    Text(
                                        "应用曾于 ${McFormat.relative(exit.at)} 异常退出并被容器自动恢复(exit=${exit.exitCode}):${exit.detail}",
                                        style = McType.caption,
                                        color = Warning,
                                        lineHeight = 17.sp,
                                    )
                                    TextButton(onClick = { vm.dismissLastAbnormalExit() }) {
                                        Text("知道了", style = McType.caption, color = Warning)
                                    }
                                }
                            }
                            Spacer(Modifier.height(12.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                SettingsActionButton(
                                    text = if (state.checking) "正在检查…" else "检查更新",
                                    enabled = !state.checking && !updating,
                                ) { vm.checkUpdate() }
                                if (updating) {
                                    SettingsActionButton("更新中…", enabled = false) {}
                                }
                            }
                        }
                    }

                    // ── 更新进度（紧跟版本行，替换新版本卡片的位置）──
                    if (updating) {
                        state.progress?.let { progress ->
                            Spacer(Modifier.height(10.dp))
                            GlassCard(Modifier.fillMaxWidth()) {
                                Text(progress.detail.ifEmpty { "正在更新…" }, style = McType.subheadlineSemibold)
                                if (progress.phase == "downloading" && progress.percent != null) {
                                    Spacer(Modifier.height(8.dp))
                                    ProgressBar(fraction = progress.percent / 100f)
                                    Spacer(Modifier.height(4.dp))
                                    Text("%.0f%%".format(progress.percent), style = McType.caption, color = TextMuted)
                                }
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    "更新在后台执行,完成后会自动重启。",
                                    style = McType.caption2,
                                    color = TextFaint,
                                )
                            }
                        }
                    }

                    // ── 新版本卡片：进页由快照预填，手动检查后以检查结果为准 ──
                    if (!updating) {
                        val availableVersion: String?
                        val availableCompatible: Boolean
                        val availableChangelog: String
                        val availableKnownBad: Boolean
                        if (state.check != null) {
                            availableVersion = state.check!!.latestVersion.takeIf { state.check!!.updateAvailable }
                            availableCompatible = state.check!!.compatible
                            availableChangelog = state.check!!.changelog
                            availableKnownBad = state.check!!.latestKnownBad
                        } else {
                            availableVersion = state.pending?.appVersion
                            availableCompatible = state.pending?.appCompatible ?: true
                            availableChangelog = state.pending?.appChangelog.orEmpty()
                            availableKnownBad = false
                        }
                        if (availableVersion != null) {
                            Spacer(Modifier.height(10.dp))
                            GlassCard(Modifier.fillMaxWidth()) {
                                Text("发现新版本 v$availableVersion", style = McType.subheadlineSemibold)
                                if (!availableCompatible) {
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        "本次更新包含依赖变化,需拉取新的 Docker 镜像升级。",
                                        style = McType.caption,
                                        color = Warning,
                                    )
                                }
                                if (availableKnownBad) {
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        "注意:v$availableVersion 此前曾在本机连续启动失败被自动回落。重新更新会清除失败标记再试一次。",
                                        style = McType.caption,
                                        color = Warning,
                                        lineHeight = 17.sp,
                                    )
                                }
                                if (availableChangelog.isNotEmpty()) {
                                    Spacer(Modifier.height(8.dp))
                                    Text(
                                        availableChangelog.take(1200),
                                        style = McType.caption,
                                        color = TextMuted,
                                        lineHeight = 18.sp,
                                    )
                                }
                                if (availableCompatible && state.status?.canUpdate == true) {
                                    Spacer(Modifier.height(12.dp))
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        SettingsActionButton(
                                            text = if (state.applying) "更新中…" else "立即更新",
                                            enabled = !state.applying,
                                            primary = true,
                                        ) { vm.applyUpdate() }
                                    }
                                }
                            }
                        } else if (state.check != null) {
                            Spacer(Modifier.height(10.dp))
                            GlassCard(Modifier.fillMaxWidth()) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("已是最新", style = McType.subheadlineSemibold)
                                    Spacer(Modifier.weight(1f))
                                    Text("v${state.check!!.currentVersion}", style = McType.caption, color = Success)
                                }
                            }
                        }
                    }

                    // ── 上一次更新失败的统一外显 ──
                    if (state.progress?.phase == "failed" && !state.progress.error.isNullOrEmpty()) {
                        Spacer(Modifier.height(10.dp))
                        GlassCard(Modifier.fillMaxWidth()) {
                            Text(
                                buildString {
                                    append("上次更新")
                                    state.progress.targetVersion?.let { append("（v$it）") }
                                    append("失败：").append(state.progress.error)
                                },
                                style = McType.caption,
                                color = Danger,
                                lineHeight = 17.sp,
                            )
                        }
                    }
                    state.actionError?.let {
                        Spacer(Modifier.height(10.dp))
                        GlassCard(Modifier.fillMaxWidth()) {
                            Text(it, style = McType.caption, color = Danger, lineHeight = 17.sp)
                        }
                    }

                    // ── NER 识别模型（独立于代码更新；生效需全量重启）──
                    if (state.status?.canUpdate == true) {
                        Spacer(Modifier.height(16.dp))
                        Text("NER 识别模型", style = McType.caption, color = TextFaint)
                        Spacer(Modifier.height(6.dp))
                        GlassCard(Modifier.fillMaxWidth()) {
                            Text(
                                "当前模型：${state.status.modelTag ?: "无法识别（较早的镜像）"}",
                                style = McType.footnote,
                            )
                            state.modelCheck?.let { check ->
                                if (!check.updateAvailable) {
                                    Spacer(Modifier.height(4.dp))
                                    Text("模型已是最新（${check.latestTag}）", style = McType.caption, color = Success)
                                } else if (!check.installable) {
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        "发现新模型 ${check.latestTag},但该发布未携带更新清单,暂无法应用内安装。",
                                        style = McType.caption,
                                        color = Warning,
                                    )
                                }
                            }
                            Spacer(Modifier.height(10.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                SettingsActionButton(
                                    text = if (state.modelChecking) "正在检查…" else "检查模型更新",
                                    enabled = !state.modelChecking && !updating,
                                ) { vm.checkModelUpdate() }
                                val modelAvailable = (state.modelCheck?.takeIf { it.updateAvailable && it.installable }?.latestTag)
                                    ?: state.pending?.modelTag
                                if (modelAvailable != null) {
                                    SettingsActionButton(
                                        text = "更新模型",
                                        enabled = !updating,
                                        primary = true,
                                    ) { vm.applyModelUpdate() }
                                }
                            }
                        }
                    }

                    // ── 回退与版本保留 ──
                    if (state.status?.canUpdate == true && state.rollback != null) {
                        val rollback = state.rollback!!
                        Spacer(Modifier.height(16.dp))
                        Text("回退", style = McType.caption, color = TextFaint)
                        Spacer(Modifier.height(6.dp))
                        GlassCard(Modifier.fillMaxWidth()) {
                            if (rollback.targets.isNotEmpty()) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f)) {
                                        Text("回退到历史版本", style = McType.footnote)
                                        Text(
                                            "更新后遇到问题时,可切换到本机保留的历史版本;跨数据库升级的回退会恢复对应时点的自动备份。",
                                            style = McType.caption2,
                                            color = TextFaint,
                                        )
                                    }
                                    RollbackLauncher(state, vm)
                                }
                                Spacer(Modifier.height(10.dp))
                            }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    "本地保留版本数",
                                    style = McType.footnote,
                                    modifier = Modifier.weight(1f),
                                )
                                RetentionStepper(rollback, state.retentionBusy) { vm.saveRetention(it) }
                            }
                            if (rollback.versionsDirBytes > 0) {
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    "保留越多可回退的范围越大,占用磁盘越多(当前占用 ${McFormat.bytes(rollback.versionsDirBytes)})",
                                    style = McType.caption2,
                                    color = TextFaint,
                                )
                            }
                        }
                    }

                    // ── GitHub 访问令牌 ──
                    Spacer(Modifier.height(16.dp))
                    Text("GitHub 访问令牌", style = McType.caption, color = TextFaint)
                    Spacer(Modifier.height(6.dp))
                    GlassCard(Modifier.fillMaxWidth()) {
                        Text(
                            if (state.token?.configured == true) "已配置 ${state.token!!.masked}" else "未配置",
                            style = McType.footnote,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "检查更新走 GitHub API,匿名按出口 IP 限 60 次/小时(走代理时与同节点用户共享,极易限流)。填入自己的令牌后,额度改按你的账号计算;只需能读公开仓库。",
                            style = McType.caption2,
                            color = TextFaint,
                            lineHeight = 16.sp,
                        )
                        Spacer(Modifier.height(8.dp))
                        var tokenInput by remember { mutableStateOf("") }
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedTextField(
                                value = tokenInput,
                                onValueChange = { tokenInput = it },
                                enabled = !state.tokenBusy,
                                singleLine = true,
                                placeholder = {
                                    Text(
                                        if (state.token?.configured == true) "填写新令牌以替换" else "github_pat_… 或 ghp_…",
                                        style = McType.caption,
                                    )
                                },
                                visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = Accent,
                                    unfocusedBorderColor = LineColor,
                                ),
                                modifier = Modifier.weight(1f),
                            )
                            SettingsActionButton(
                                text = "保存",
                                enabled = !state.tokenBusy && tokenInput.isNotBlank(),
                                primary = true,
                            ) {
                                vm.saveGithubToken(tokenInput.trim())
                                tokenInput = ""
                            }
                            if (state.token?.configured == true) {
                                SettingsActionButton("清除", enabled = !state.tokenBusy) { vm.saveGithubToken("") }
                            }
                        }
                    }

                    // ── 维护：重启应用（危险动作，放最后）──
                    Spacer(Modifier.height(16.dp))
                    Text("维护", style = McType.caption, color = TextFaint)
                    Spacer(Modifier.height(6.dp))
                    GlassCard(Modifier.fillMaxWidth()) {
                        Text("重启应用", style = McType.subheadlineSemibold, color = Danger)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "优雅停机后重新启动后端服务,正在进行的任务会中断。Docker 部署由容器入口自动拉起,通常几秒内恢复;源码部署需有守护进程。",
                            style = McType.caption,
                            color = TextMuted,
                            lineHeight = 17.sp,
                        )
                        Spacer(Modifier.height(10.dp))
                        var confirmRestart by remember { mutableStateOf(false) }
                        SettingsActionButton(
                            text = "重启应用",
                            enabled = !updating,
                        ) { confirmRestart = true }
                        if (confirmRestart) {
                            ConfirmDialog(
                                title = "重启应用?",
                                message = "重启期间服务短暂不可用,正在进行的下载投递/整理任务会中断。Docker 部署通常几秒内自动拉起;源码部署需有 systemd 等守护。",
                                confirmLabel = "确认重启",
                                onDismiss = { confirmRestart = false },
                                onConfirm = {
                                    confirmRestart = false
                                    vm.restartApp()
                                },
                            )
                        }
                    }


            }
            if (tab == 1) {
                    // ── 定时任务 ──
                    Spacer(Modifier.height(16.dp))
                    Text("定时任务", style = McType.caption, color = TextFaint)
                    Spacer(Modifier.height(6.dp))
                    when {
                        state.tasks == null -> GlassCard(Modifier.fillMaxWidth()) {
                            Text(state.tasksError ?: "加载中…", style = McType.caption, color = TextFaint)
                        }
                        else -> GlassCard(Modifier.fillMaxWidth()) {
                            state.tasks!!.forEachIndexed { index, task ->
                                if (index > 0) {
                                    Spacer(Modifier.height(1.dp))
                                    Box(
                                        Modifier
                                            .fillMaxWidth()
                                            .height(1.dp)
                                            .background(LineColor),
                                    )
                                    Spacer(Modifier.height(1.dp))
                                }
                                TaskRow(
                                    state = state,
                                    task = task,
                                    onToggle = { vm.toggleTask(task, it) },
                                    onSave = { type, seconds, cron -> vm.saveTaskSchedule(task, type, seconds, cron) },
                                )
                            }
                        }
                    }


            }
            if (tab == 2) {
                    // ── 存储 ──
                    state.storage?.let { storage ->
                        Spacer(Modifier.height(16.dp))
                        Text("存储", style = McType.caption, color = TextFaint)
                        Spacer(Modifier.height(6.dp))
                        GlassCard(Modifier.fillMaxWidth()) {
                            storage.usage?.let { usage ->
                                Row(Modifier.fillMaxWidth()) {
                                    StorageFact("磁盘可用", McFormat.bytes(usage.diskFree))
                                    StorageFact("缓存", McFormat.bytes(usage.cacheBytes))
                                    StorageFact("数据", McFormat.bytes(usage.dataBytes))
                                }
                                Spacer(Modifier.height(8.dp))
                                ProgressBar(
                                    fraction = if (usage.diskTotal > 0) usage.diskUsed.toFloat() / usage.diskTotal else 0f,
                                )
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    "已用 ${McFormat.bytes(usage.diskUsed)} / 共 ${McFormat.bytes(usage.diskTotal)}",
                                    style = McType.caption2,
                                    color = TextFaint,
                                )
                            } ?: Text(
                                if (storage.computing) "正在统计存储用量…" else (storage.error ?: "暂无用量数据"),
                                style = McType.caption,
                                color = TextFaint,
                            )
                            Spacer(Modifier.height(10.dp))
                            storage.usage?.dirs?.filter { it.group == "cache" && it.clearable }?.forEach { dir ->
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.fillMaxWidth().padding(vertical = 5.dp),
                                ) {
                                    Column(Modifier.weight(1f)) {
                                        Text(dir.title, style = McType.footnote)
                                        Text(
                                            dir.summary.ifEmpty { dir.path },
                                            style = McType.caption2,
                                            color = TextFaint,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                        if (dir.rebuildCost == "expensive") {
                                            Text("清理后重建较慢", style = McType.caption2, color = Warning)
                                        }
                                    }
                                    TextButton(
                                        onClick = { vm.clean(dir.key) },
                                        enabled = !state.storageLoading && dir.exists,
                                    ) { Text("清理", style = McType.caption, color = Accent) }
                                }
                            }
                        }
                    }


            }
            Spacer(Modifier.height(30.dp))
        }
    }
}

/** 「选择版本回退…」按钮 + 弹窗本体（候选列表 → 展开详情 → 确认） */
@Composable
private fun RollbackLauncher(state: MaintenanceViewModel.UiState, vm: MaintenanceViewModel) {
    var open by remember { mutableStateOf(false) }
    SettingsActionButton(
        text = "选择版本回退…",
        enabled = !state.applying,
    ) { open = true }
    if (open) {
        RollbackDialog(
            targets = state.rollback?.targets.orEmpty(),
            onDismiss = { open = false },
            onConfirm = { target ->
                open = false
                vm.rollbackTo(target)
            },
        )
    }
}

@Composable
private fun RollbackDialog(
    targets: List<RollbackTarget>,
    onDismiss: () -> Unit,
    onConfirm: (RollbackTarget) -> Unit,
) {
    var selected by remember { mutableStateOf<Int?>(null) }
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(18.dp),
            color = io.movieclaw.android.core.designsystem.Bg,
            border = androidx.compose.foundation.BorderStroke(1.dp, LineColor),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(16.dp)) {
                Text("选择回退版本", style = McType.title3)
                Spacer(Modifier.height(4.dp))
                Text(
                    "回退会重启应用;是否需要恢复数据备份取决于目标版本的数据结构差异,结论已在每一项里标明。",
                    style = McType.caption,
                    color = TextMuted,
                    lineHeight = 17.sp,
                )
                Spacer(Modifier.height(10.dp))
                Column(
                    Modifier
                        .heightIn(max = 420.dp)
                        .formSheetScroll().verticalScroll(rememberScrollState()),
                ) {
                    targets.forEachIndexed { index, target ->
                        val isSel = selected == index
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(if (isSel) Color.White.copy(alpha = 0.08f) else Color.Transparent)
                                .clickable { selected = if (isSel) null else index }
                                .padding(horizontal = 10.dp, vertical = 9.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    if (target.kind == "baseline") {
                                        "镜像内置版本${target.version?.let { " v$it" } ?: ""}"
                                    } else {
                                        "v${target.version}"
                                    },
                                    style = McType.footnote,
                                    color = TextPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                Text(
                                    when (target.schemaAction) {
                                        "switch" -> "可直接切换,数据保留"
                                        "restore" -> "需恢复备份"
                                        else -> "无对应数据备份"
                                    },
                                    style = McType.caption2,
                                    color = when (target.schemaAction) {
                                        "switch" -> Success
                                        "restore" -> Warning
                                        else -> Danger
                                    },
                                )
                            }
                            target.installedAt?.let {
                                Text("装于 ${McFormat.relative(it)}", style = McType.caption2, color = TextFaint)
                            }
                            if (isSel) {
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    when (target.schemaAction) {
                                        "switch" -> "该版本与当前的数据结构一致:直接切换代码,全部数据原样保留。"
                                        "restore" -> "当前数据结构比该版本新(中间经过数据库升级)。回退将恢复 ${target.backupTakenAt?.let { McFormat.relative(it) } ?: "对应时点"} 自动备份的数据,此后产生的数据将丢失;回退前会再自动备份一次当前数据。"
                                        else -> "没有可对应时点的数据备份:切换后该版本将直接使用当前数据,若中间经过数据库升级可能无法正常运行(启动失败时会自动回落)。"
                                    },
                                    style = McType.caption2,
                                    color = TextMuted,
                                    lineHeight = 16.sp,
                                )
                                target.changelog?.takeIf { it.isNotEmpty() }?.let { changelog ->
                                    Spacer(Modifier.height(6.dp))
                                    Text(
                                        changelog.take(600),
                                        style = McType.caption2,
                                        color = TextFaint,
                                        lineHeight = 15.sp,
                                        maxLines = 8,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.align(Alignment.End)) {
                    SettingsActionButton("取消") { onDismiss() }
                    val pick = selected?.let { targets.getOrNull(it) }
                    SettingsActionButton(
                        text = when {
                            pick == null -> "选择一个版本"
                            pick.schemaAction == "restore" -> "回退并恢复备份"
                            else -> "回退并重启"
                        },
                        enabled = pick != null,
                        primary = true,
                    ) { pick?.let(onConfirm) }
                }
            }
        }
    }
}

/** 保留版本数 − / + 步进（2..20，立即生效并按新策略清理） */
@Composable
private fun RetentionStepper(rollback: RollbackOptions, busy: Boolean, onChange: (Int) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SettingsActionButton("−", enabled = !busy && rollback.keepVersions > 2) {
            onChange(rollback.keepVersions - 1)
        }
        Text(
            rollback.keepVersions.toString(),
            style = McType.subheadlineSemibold,
            color = TextPrimary,
            modifier = Modifier.width(24.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        SettingsActionButton("+", enabled = !busy && rollback.keepVersions < 20) {
            onChange(rollback.keepVersions + 1)
        }
    }
}

/** 一条定时任务：标题/说明 + 周期文案 + 上次/下次运行 + 启停开关；点行编辑周期 */
@Composable
private fun TaskRow(
    state: MaintenanceViewModel.UiState,
    task: ScheduledTask,
    onToggle: (Boolean) -> Unit,
    onSave: (String, Long?, String?) -> Unit,
) {
    var editing by remember(task.key) { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 9.dp),
    ) {
        Column(Modifier.weight(1f).clickable(enabled = state.taskBusyKey == null) { editing = true }) {
            Text(task.title, style = McType.footnote, color = TextPrimary)
            if (task.description.isNotEmpty()) {
                Text(
                    task.description,
                    style = McType.caption2,
                    color = TextFaint,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(2.dp))
            Text(
                buildString {
                    append(describeSchedule(task.triggerType, task.intervalSeconds, task.cronExpr))
                    // 时间解析不出（任务还没跑过 / 服务端字段为空）就不显示，免得出现「上次 · 下次」空壳
                    task.lastRunAt?.let { McFormat.relative(it).takeIf { t -> t.isNotEmpty() }?.let { t -> append(" · 上次 $t") } }
                    task.nextRunAt?.let { McFormat.relative(it).takeIf { t -> t.isNotEmpty() }?.let { t -> append(" · 下次 $t") } }
                },
                style = McType.caption2,
                color = if (task.enabled) TextMuted else TextFaint,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (state.taskBusyKey == task.key) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = TextMuted)
        } else {
            Switch(
                checked = task.enabled,
                onCheckedChange = onToggle,
                enabled = state.taskBusyKey == null,
            )
        }
    }
    if (editing) {
        TaskScheduleDialog(
            task = task,
            busy = state.taskBusyKey == task.key,
            onDismiss = { editing = false },
            onSave = { type, seconds, cron ->
                editing = false
                onSave(type, seconds, cron)
            },
        )
    }
}

@Composable
private fun TaskScheduleDialog(
    task: ScheduledTask,
    busy: Boolean,
    onDismiss: () -> Unit,
    onSave: (String, Long?, String?) -> Unit,
) {
    // 初始形状：interval → 「每 N 小时」；daily cron → 「每天 HH:MM」；其它 cron 原文
    val daily = dailyTimeOf(task.cronExpr)
    var mode by remember(task.key) {
        mutableStateOf(
            when {
                task.triggerType == "interval" -> "interval"
                daily != null -> "daily"
                else -> "cron"
            },
        )
    }
    var hours by remember(task.key) {
        mutableStateOf(((task.intervalSeconds ?: 3600L) / 3600L).coerceAtLeast(1).toString())
    }
    var hour by remember(task.key) { mutableStateOf((daily?.first ?: 3).toString()) }
    var minute by remember(task.key) { mutableStateOf((daily?.second ?: 0).toString()) }
    var cron by remember(task.key) { mutableStateOf(task.cronExpr ?: "") }
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(18.dp),
            color = io.movieclaw.android.core.designsystem.Bg,
            border = androidx.compose.foundation.BorderStroke(1.dp, LineColor),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(16.dp)) {
                Text(task.title, style = McType.title3)
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("interval" to "每 N 小时", "daily" to "每天固定时刻", "cron" to "cron 表达式").forEach { (value, label) ->
                        val on = mode == value
                        Text(
                            label,
                            style = McType.caption,
                            color = if (on) Accent else TextMuted,
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .background(if (on) AccentSoft else SurfaceRaised)
                                .clickable { mode = value }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                }
                Spacer(Modifier.height(10.dp))
                when (mode) {
                    "interval" -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("每", style = McType.footnote)
                        OutlinedTextField(
                            value = hours,
                            onValueChange = { hours = it.filter(Char::isDigit).take(3) },
                            enabled = !busy,
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Accent, unfocusedBorderColor = LineColor),
                            modifier = Modifier.width(90.dp),
                        )
                        Text("小时执行一次", style = McType.footnote)
                    }
                    "daily" -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("每天", style = McType.footnote)
                        OutlinedTextField(
                            value = hour,
                            onValueChange = { hour = it.filter(Char::isDigit).take(2) },
                            enabled = !busy,
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Accent, unfocusedBorderColor = LineColor),
                            modifier = Modifier.width(64.dp),
                        )
                        Text(":", style = McType.footnote)
                        OutlinedTextField(
                            value = minute,
                            onValueChange = { minute = it.filter(Char::isDigit).take(2) },
                            enabled = !busy,
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Accent, unfocusedBorderColor = LineColor),
                            modifier = Modifier.width(64.dp),
                        )
                        Text("执行", style = McType.footnote)
                    }
                    else -> OutlinedTextField(
                        value = cron,
                        onValueChange = { cron = it },
                        enabled = !busy,
                        singleLine = true,
                        placeholder = { Text("分 时 日 月 周,如 0 */6 * * *", style = McType.caption) },
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Accent, unfocusedBorderColor = LineColor),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.align(Alignment.End)) {
                    SettingsActionButton("取消") { onDismiss() }
                    val valid = when (mode) {
                        "interval" -> hours.toLongOrNull()?.let { it in 1..720 } == true
                        "daily" -> (hour.toIntOrNull() in 0..23) && (minute.toIntOrNull() in 0..59)
                        else -> cron.isNotBlank()
                    }
                    SettingsActionButton(
                        text = "保存",
                        enabled = !busy && valid,
                        primary = true,
                    ) {
                        when (mode) {
                            "interval" -> onSave("interval", (hours.toLongOrNull() ?: 1) * 3600, null)
                            "daily" -> onSave(
                                "cron",
                                null,
                                "%s %s * * *".format((minute.toIntOrNull() ?: 0).coerceIn(0, 59), (hour.toIntOrNull() ?: 0).coerceIn(0, 23)),
                            )
                            else -> onSave("cron", null, cron.trim())
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(18.dp),
            color = io.movieclaw.android.core.designsystem.Bg,
            border = androidx.compose.foundation.BorderStroke(1.dp, LineColor),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(16.dp)) {
                Text(title, style = McType.title3, color = Danger)
                Spacer(Modifier.height(6.dp))
                Text(message, style = McType.caption, color = TextMuted, lineHeight = 17.sp)
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.align(Alignment.End)) {
                    SettingsActionButton("取消") { onDismiss() }
                    SettingsActionButton(confirmLabel, primary = true) { onConfirm() }
                }
            }
        }
    }
}


@Composable
private fun androidx.compose.foundation.layout.RowScope.StorageFact(label: String, value: String) {
    Column(Modifier.weight(1f)) {
        Text(label, style = McType.caption2, color = TextFaint)
        Text(value, style = McType.footnote, color = TextPrimary)
    }
}

private val TextPrimary2 = Color(0xFFF3F5F9)

/* ---------------- 网络 ---------------- */

@HiltViewModel
class NetworkSettingsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val feedback: FeedbackBus,
    /** 内外双地址自动选连：地址簿展示 + 手动重选（docs/design/server-addresses.md） */
    private val addressBook: io.movieclaw.android.core.network.ServerAddressBook,
) : ViewModel() {

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val config: NetworkConfig = NetworkConfig(),
        val saving: Boolean = false,
        /** 这台服务器的访问地址簿（lan/wan）；null = 老服务端没有接口 */
        val addresses: List<io.movieclaw.android.core.network.ServerAddressBook.Entry>? = null,
        /** 当前自动选中的入口 */
        val selected: io.movieclaw.android.core.network.ServerAddressBook.Selection? = null,
        /** 逐服务的测试结果（iOS `tests[service]`）：id → 结果 / 测试中 */
        val serviceTests: Map<String, ServiceTest> = emptyMap(),
        /** 应用设置（外部访问地址）：根页「外部访问」行显示它的值（iOS `navigationRow`） */
        val appConfig: io.movieclaw.android.core.model.AppConfig? = null,
    )

    /** 一个服务的测试状态（iOS `NetworkTestState`） */
    data class ServiceTest(val pending: Boolean = false, val result: NetworkTestResult? = null)

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    init {
        load()
        // 地址簿与当前选路：冷启动选路完成后就有值
        viewModelScope.launch {
            addressBook.book.collect { list -> _ui.update { it.copy(addresses = list) } }
        }
        viewModelScope.launch {
            addressBook.selection.collect { sel -> _ui.update { it.copy(selected = sel) } }
        }
    }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            runCatching { apiFactory.forOrigin(origin).networkConfig().dataOrThrow() }
                .onSuccess { config -> _ui.update { it.copy(loading = false, config = config) } }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
            // 外部访问行的当前值（iOS `ExternalAccessSettingsView` 的入口行）
            runCatching { apiFactory.forOrigin(origin).appConfigShow().dataOrThrow() }
                .onSuccess { c -> _ui.update { it.copy(appConfig = c) } }
        }
    }

    /** 逐服务开关（iOS：改动立即保存） */
    fun toggleService(id: String, on: Boolean) {
        val current = _ui.value.config
        val next = if (on) (current.proxyServices + id).distinct() else current.proxyServices - id
        saveConfig(current.copy(proxyServices = next), "代理开关已保存")
    }

    /** 逐服务测试连接（iOS `netTest`：按已保存的配置发真实请求） */
    fun testService(id: String) {
        val state = _ui.value
        if (state.serviceTests[id]?.pending == true) return
        _ui.update { it.copy(serviceTests = it.serviceTests + (id to ServiceTest(pending = true))) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).testNetwork(io.movieclaw.android.core.model.NetworkTestPayload(id)).dataOrThrow() }
                .onSuccess { result ->
                    _ui.update { it.copy(serviceTests = it.serviceTests + (id to ServiceTest(result = result))) }
                }
                .onFailure { e ->
                    _ui.update {
                        it.copy(
                            serviceTests = it.serviceTests + (
                                id to ServiceTest(result = NetworkTestResult(ok = false, message = friendlyMessage(e)))
                            ),
                        )
                    }
                }
        }
    }

    /** 手动重选：清掉按网络的记忆重新竞速（设置页「重新选择」按钮） */
    fun reselect() {
        addressBook.reselect(origin)
        feedback.info("正在重新探测可用地址…")
    }

    fun update(transform: (NetworkConfig) -> NetworkConfig) = _ui.update { it.copy(config = transform(it.config)) }

    /** 保存整份配置（服务端是全量覆盖；调用方已把要改的字段并进最新那份） */
    private fun saveConfig(next: NetworkConfig, successText: String) {
        if (_ui.value.saving) return
        _ui.update { it.copy(saving = true, config = next) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).saveNetworkConfig(next).dataOrThrow() }
                .onSuccess { saved ->
                    // 配置变了：旧测试结果不再可信（iOS `invalidateTests`）
                    _ui.update { it.copy(saving = false, config = saved, serviceTests = emptyMap()) }
                    feedback.success(successText)
                }
                .onFailure { e ->
                    _ui.update { it.copy(saving = false) }
                    feedback.error(friendlyMessage(e))
                }
        }
    }

    /** 代理配置抽屉保存（iOS `NetworkEditorKind.proxy.merging`：只替换本抽屉负责的字段） */
    fun saveProxy(mode: String, url: String) =
        saveConfig(_ui.value.config.copy(proxyMode = mode, proxyUrl = url), "代理配置已保存")

    /** TMDB 镜像抽屉保存（iOS `NetworkEditorKind.mirrors.merging`） */
    fun saveMirrors(api: String, image: String) =
        saveConfig(_ui.value.config.copy(tmdbApiBaseUrl = api, tmdbImageBaseUrl = image), "TMDB 镜像已保存")

    /** 服务代理页的重试入口（进子页时重新拉一次外部访问值不必） */
    fun reloadAppConfig() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).appConfigShow().dataOrThrow() }
                .onSuccess { c -> _ui.update { it.copy(appConfig = c) } }
        }
    }
}

/** 网络页的两级：根页（iOS 的 List 行）/ 服务代理子页 / PT 站点子页 */
private enum class NetworkPage { Root, Services, Sites }

/** 根页的两个抽屉编辑器（iOS `NetworkEditorKind`） */
private enum class NetworkEditor { Proxy, Mirrors }

/** iOS `NetworkSettingsValidation.validURL`：http(s)；代理另允许 socks5/socks5h */
internal fun validNetworkUrl(value: String, proxy: Boolean = false): Boolean {
    val v = value.trim()
    if (v.isEmpty()) return true
    if (v.any { it.isWhitespace() }) return false
    val uri = runCatching { java.net.URI(v) }.getOrNull() ?: return false
    val scheme = uri.scheme?.lowercase() ?: return false
    val allowed = if (proxy) listOf("http", "https", "socks5", "socks5h") else listOf("http", "https")
    return scheme in allowed && !uri.host.isNullOrEmpty()
}

/** 代理模式的说法（iOS `NetworkSettingsValidation.proxyTitle`） */
internal fun proxyTitle(mode: String?): String = when (mode) {
    "manual" -> "手动"
    "env" -> "环境变量"
    else -> "不使用"
}

@Composable
fun NetworkSettingsScreen(
    onBack: () -> Unit,
    /** 「外部访问」行 → 外部访问地址与端口（iOS `network-external-access`） */
    onOpenExternalAccess: () -> Unit = {},
    vm: NetworkSettingsViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    var page by remember { mutableStateOf(NetworkPage.Root) }
    var editor by remember { mutableStateOf<NetworkEditor?>(null) }

    // 从「外部访问」页返回时刷新那一行的当前值
    LaunchedEffect(page) {
        if (page == NetworkPage.Root) vm.reloadAppConfig()
    }

    Column(Modifier.fillMaxSize()) {
        SettingsHeader(
            title = when (page) {
                NetworkPage.Root -> "网络"
                NetworkPage.Services -> "服务代理"
                NetworkPage.Sites -> "PT 站点"
            },
            onBack = { if (page == NetworkPage.Root) onBack() else page = NetworkPage.Root },
        )
        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::load)
            else -> Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
            ) {
                val nonSite = state.config.services.filterNot { it.isSite }
                val sites = state.config.services.filter { it.isSite }
                val proxyActive = state.config.proxyMode == "manual" ||
                    (state.config.proxyMode == "env" && state.config.envProxyDetected.isNotEmpty())

                when (page) {
                    // ── 根页（iOS `loaded(current)` 的 List）──
                    NetworkPage.Root -> {
                        Spacer(Modifier.height(10.dp))
                        SectionLabel("连接")
                        GlassCard(Modifier.fillMaxWidth()) {
                            NetworkNavRow("代理配置", proxyTitle(state.config.proxyMode), "network-proxy-settings") {
                                editor = NetworkEditor.Proxy
                            }
                            RowDividerLine()
                            NetworkNavRow("服务代理与测试", "", "network-services") {
                                page = NetworkPage.Services
                            }
                            if (sites.isNotEmpty()) {
                                RowDividerLine()
                                NetworkNavRow("PT 站点", "", "network-sites") {
                                    page = NetworkPage.Sites
                                }
                            }
                        }
                        SectionFooter("按服务选择代理。内网下载器和媒体服务器始终直连。")

                        Spacer(Modifier.height(18.dp))
                        GlassCard(Modifier.fillMaxWidth()) {
                            NetworkNavRow(
                                "外部访问",
                                state.appConfig?.externalUrl?.takeIf { it.isNotBlank() } ?: "未设置",
                                "network-external-access",
                            ) { onOpenExternalAccess() }
                            RowDividerLine()
                            NetworkNavRow(
                                "TMDB 镜像",
                                if (state.config.tmdbApiBaseUrl.isBlank() && state.config.tmdbImageBaseUrl.isBlank()) "默认" else "自定义",
                                "network-mirror",
                            ) { editor = NetworkEditor.Mirrors }
                        }

                        // ── 访问地址（安卓特有：内外双地址自动选连的当前状态）──
                        state.addresses?.let { addresses ->
                            Spacer(Modifier.height(18.dp))
                            SectionLabel("访问地址")
                            GlassCard(Modifier.fillMaxWidth()) {
                                Text(
                                    "App 自动在内网 / 外网地址之间选路：在家直连内网，出门走外网，" +
                                        "网络变化自动重选；当前用的是哪条看下面。",
                                    style = McType.caption2, color = TextFaint, lineHeight = 16.sp,
                                )
                                Spacer(Modifier.height(8.dp))
                                addresses.forEach { addr ->
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier.fillMaxWidth().padding(vertical = 5.dp),
                                    ) {
                                        Box(
                                            Modifier
                                                .size(6.dp)
                                                .clip(androidx.compose.foundation.shape.CircleShape)
                                                .background(if (addr.kind == "lan") Success else Accent),
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Text(
                                            addr.url,
                                            style = McType.footnote,
                                            color = TextPrimary,
                                            modifier = Modifier.weight(1f),
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                        val inUse = state.selected?.url?.trimEnd('/') == addr.url.trimEnd('/')
                                        Text(
                                            (if (addr.kind == "lan") "内网" else "外网") + if (inUse) " · 使用中" else "",
                                            style = McType.caption2,
                                            color = if (inUse) Accent else TextFaint,
                                        )
                                    }
                                }
                                Spacer(Modifier.height(8.dp))
                                SettingsActionButton("重新选择") { vm.reselect() }
                            }
                        }
                        Spacer(Modifier.height(30.dp))
                    }

                    // ── 服务代理与测试（iOS `serviceList`）──
                    NetworkPage.Services -> {
                        Spacer(Modifier.height(10.dp))
                        ServiceListBody(state, nonSite, proxyActive, vm)
                        SectionFooter(
                            if (proxyActive) "开关决定此服务是否走代理，改动立即生效。测试会按已保存的配置发起真实请求。"
                            else "当前没有可用代理。测试仍可检查直连或镜像的连通性。",
                        )
                        Spacer(Modifier.height(30.dp))
                    }

                    NetworkPage.Sites -> {
                        Spacer(Modifier.height(10.dp))
                        ServiceListBody(state, sites, proxyActive, vm)
                        SectionFooter(
                            if (proxyActive) "开关决定这些站点是否走代理，改动立即生效。测试会按已保存的配置发起真实请求。"
                            else "当前没有可用代理。测试仍可检查直连的连通性。",
                        )
                        Spacer(Modifier.height(30.dp))
                    }
                }
            }
        }
    }

    when (editor) {
        NetworkEditor.Proxy -> ProxyEditorSheet(
            mode = state.config.proxyMode,
            url = state.config.proxyUrl,
            envDetected = state.config.envProxyDetected,
            saving = state.saving,
            onDismiss = { editor = null },
            onSave = { mode, url ->
                editor = null
                vm.saveProxy(mode, url)
            },
        )
        NetworkEditor.Mirrors -> MirrorEditorSheet(
            api = state.config.tmdbApiBaseUrl,
            image = state.config.tmdbImageBaseUrl,
            defaults = state.config.mirrorDefaults,
            saving = state.saving,
            onDismiss = { editor = null },
            onSave = { api, image ->
                editor = null
                vm.saveMirrors(api, image)
            },
        )
        null -> Unit
    }
}

/** iOS `SettingsFormSection` 的分组标题 */
@Composable
private fun SectionLabel(text: String) {
    Spacer(Modifier.height(2.dp))
    Text(text, style = McType.caption, color = TextFaint, modifier = Modifier.padding(bottom = 6.dp))
}

/** iOS `SettingsFormSection` 的 footer 说明 */
@Composable
private fun SectionFooter(text: String) {
    Spacer(Modifier.height(6.dp))
    Text(
        text,
        style = McType.caption2,
        color = TextFaint,
        lineHeight = 16.sp,
        modifier = Modifier.padding(horizontal = 4.dp),
    )
}

@Composable
private fun RowDividerLine() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.05f)))
}

/** 根页的导航行（iOS `navigationRow`）：标题 + 右侧当前值 + › */
@Composable
private fun NetworkNavRow(title: String, value: String, tag: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .testTag(tag)
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = McType.sub, color = TextPrimary)
        Spacer(Modifier.weight(1f))
        if (value.isNotEmpty()) {
            Text(value, style = McType.sub, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(6.dp))
        Text("›", style = McType.sub, color = TextFaint)
    }
}

/** 服务列表本体（服务代理 / PT 站点两页共用） */
@Composable
private fun ServiceListBody(
    state: NetworkSettingsViewModel.UiState,
    services: List<io.movieclaw.android.core.model.EgressService>,
    proxyActive: Boolean,
    vm: NetworkSettingsViewModel,
) {
    GlassCard(Modifier.fillMaxWidth()) {
        services.forEach { service ->
            ServiceProxyRow(
                service = service,
                on = service.id in state.config.proxyServices,
                proxyActive = proxyActive,
                saving = state.saving,
                test = state.serviceTests[service.id],
                onToggle = { on -> vm.toggleService(service.id, on) },
                onTest = { vm.testService(service.id) },
            )
        }
    }
}

/**
 * 代理配置抽屉（iOS `NetworkConfigEditor` proxy 分支）：三档模式 + 手动地址 + 环境变量探测值。
 * 保存只替换本抽屉的字段（服务端是全量覆盖，其它字段沿用最新那份）。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun ProxyEditorSheet(
    mode: String,
    url: String,
    envDetected: String,
    saving: Boolean,
    onDismiss: () -> Unit,
    onSave: (mode: String, url: String) -> Unit,
) {
    var draftMode by remember(mode) { mutableStateOf(mode) }
    var draftUrl by remember(url) { mutableStateOf(url) }
    val valid = draftMode != "manual" || validNetworkUrl(draftUrl, proxy = true)
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("代理配置", style = McType.title3, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) }
                TextButton(
                    enabled = valid && !saving && (draftMode != mode || draftUrl != url),
                    onClick = { onSave(draftMode, draftUrl.trim()) },
                ) { Text("保存", color = if (valid && !saving) Accent else TextFaint) }
            }
            Spacer(Modifier.height(4.dp))
            listOf(
                "off" to "不使用",
                "env" to "环境变量",
                "manual" to "手动",
            ).forEach { (value, label) ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .clickable { draftMode = value }
                        .padding(horizontal = 10.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier
                            .size(20.dp)
                            .clip(androidx.compose.foundation.shape.CircleShape)
                            .background(if (draftMode == value) Accent else Color.Transparent)
                            .border(
                                1.dp,
                                if (draftMode == value) Accent else io.movieclaw.android.core.designsystem.LineColor,
                                androidx.compose.foundation.shape.CircleShape,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (draftMode == value) {
                            Icon(
                                Icons.Rounded.Check,
                                contentDescription = null,
                                tint = Color(0xFF141821),
                                modifier = Modifier.size(13.dp),
                            )
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    Text(label, style = McType.sub, color = TextPrimary)
                }
            }
            if (draftMode == "env") {
                Spacer(Modifier.height(6.dp))
                Text(
                    if (envDetected.isNotEmpty()) "环境变量:$envDetected" else "环境变量:未检测到代理",
                    style = McType.caption, color = TextMuted,
                )
            }
            if (draftMode == "manual") {
                Spacer(Modifier.height(10.dp))
                SettingsTextField(
                    value = draftUrl,
                    placeholder = "socks5://192.168.1.2:7891",
                    onValueChange = { draftUrl = it },
                )
            }
            if (!valid) {
                Spacer(Modifier.height(6.dp))
                Text(
                    "请输入包含域名或 IP 的完整地址，并检查协议。代理支持 http(s) / socks5(h)，镜像支持 http(s)。",
                    style = McType.caption2, color = Warning, lineHeight = 16.sp,
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                if (draftMode == "manual") "支持 HTTP、HTTPS、SOCKS5 和 SOCKS5H。地址必须能由服务器访问，保存后立即生效。"
                else "环境变量使用服务器的 HTTPS_PROXY、HTTP_PROXY 或 ALL_PROXY；不使用时全部服务直连。",
                style = McType.caption2, color = TextFaint, lineHeight = 16.sp,
            )
            Spacer(Modifier.height(20.dp))
        }
    }
}

/** TMDB 镜像抽屉（iOS `NetworkConfigEditor` mirrors 分支）：两项都留空 = 用默认 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun MirrorEditorSheet(
    api: String,
    image: String,
    defaults: Map<String, String>,
    saving: Boolean,
    onDismiss: () -> Unit,
    onSave: (api: String, image: String) -> Unit,
) {
    var draftApi by remember(api) { mutableStateOf(api) }
    var draftImage by remember(image) { mutableStateOf(image) }
    val valid = validNetworkUrl(draftApi) && validNetworkUrl(draftImage)
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("TMDB 镜像", style = McType.title3, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) }
                TextButton(
                    enabled = valid && !saving && (draftApi != api || draftImage != image),
                    onClick = { onSave(draftApi.trim(), draftImage.trim()) },
                ) { Text("保存", color = if (valid && !saving) Accent else TextFaint) }
            }
            Spacer(Modifier.height(8.dp))
            Text("接口地址", style = McType.caption, color = TextFaint)
            Spacer(Modifier.height(4.dp))
            SettingsTextField(
                value = draftApi,
                placeholder = defaults["tmdb_api_base_url"].orEmpty().ifEmpty { "https://api.themoviedb.org" },
                onValueChange = { draftApi = it },
            )
            Spacer(Modifier.height(12.dp))
            Text("图床地址", style = McType.caption, color = TextFaint)
            Spacer(Modifier.height(4.dp))
            SettingsTextField(
                value = draftImage,
                placeholder = defaults["tmdb_image_base_url"].orEmpty().ifEmpty { "https://image.tmdb.org" },
                onValueChange = { draftImage = it },
            )
            if (!valid) {
                Spacer(Modifier.height(6.dp))
                Text(
                    "请输入包含域名或 IP 的完整地址，并检查协议。代理支持 http(s) / socks5(h)，镜像支持 http(s)。",
                    style = McType.caption2, color = Warning, lineHeight = 16.sp,
                )
            }
            Spacer(Modifier.height(8.dp))
            Text(
                "留空使用默认地址。只填域名时会自动补全接口 /3 和图床 /t/p 路径。" +
                    "镜像可作为代理的替代方案；同时配置时会经代理访问镜像。公共镜像会接触你的 API Key，请选可信服务。",
                style = McType.caption2, color = TextFaint, lineHeight = 16.sp,
            )
            Spacer(Modifier.height(20.dp))
        }
    }
}

/* ---------------- 日志 ---------------- */

@HiltViewModel
class LogsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {

    private val _days = MutableStateFlow<Loadable<List<LogDay>>>(Loadable.Loading)
    val days = _days.asStateFlow()

    private val _content = MutableStateFlow<LogContent?>(null)
    val content = _content.asStateFlow()

    val origin: String? get() = repository.ui.value.origin

    init {
        loadDays()
    }

    fun loadDays() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _days.value = Loadable.Loading
            runCatching { apiFactory.forOrigin(origin).logDays().dataOrThrow().days }
                .onSuccess { _days.value = Loadable.Ready(it) }
                .onFailure { e -> _days.value = Loadable.Failed(friendlyMessage(e)) }
        }
    }

    fun open(day: String) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).logContent(day).dataOrThrow() }
                .onSuccess { _content.value = it }
        }
    }

    fun close() {
        _content.value = null
    }
}

@Composable
fun LogsSettingsScreen(onBack: () -> Unit, vm: LogsViewModel = hiltViewModel()) {
    val days by vm.days.collectAsStateWithLifecycle()
    val content by vm.content.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize()) {
        SettingsHeader(
            title = if (content == null) "日志" else "日志 · ${content!!.day}",
            onBack = { if (content != null) vm.close() else onBack() },
        )
        when {
            content != null -> {
                val log = content!!
                Column(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 6.dp)) {
                        Text(
                            "${log.totalLines} 行 · ${McFormat.bytes(log.sizeBytes)}" +
                                if (log.truncated) " · 已截断(仅显示末尾)" else "",
                            style = McType.caption,
                            color = TextFaint,
                        )
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = vm::close) {
                            Text("返回列表", style = McType.caption, color = Accent)
                        }
                    }
                    androidx.compose.foundation.lazy.LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(bottom = 24.dp),
                    ) {
                        items(log.lines) { line ->
                            Text(
                                line,
                                style = McType.caption2.copy(
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 10.5.sp,
                                    lineHeight = 15.sp,
                                ),
                                color = when {
                                    line.contains("ERROR", ignoreCase = true) -> Danger
                                    line.contains("WARN", ignoreCase = true) -> Warning
                                    else -> TextMuted
                                },
                            )
                        }
                    }
                }
            }
            days is Loadable.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            days is Loadable.Failed -> ErrorPane(
                message = (days as Loadable.Failed).message,
                onRetry = vm::loadDays,
            )
            else -> LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items((days as Loadable.Ready<List<LogDay>>).value, key = { it.day }) { day ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(SurfaceRaised)
                            .clickable { vm.open(day.day) }
                            .padding(14.dp),
                    ) {
                        Icon(
                            Icons.Rounded.Cached,
                            contentDescription = null,
                            tint = TextFaint,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(day.day, style = McType.subheadline, modifier = Modifier.weight(1f))
                        Text(McFormat.bytes(day.sizeBytes), style = McType.caption, color = TextFaint)
                    }
                }
                if ((days as Loadable.Ready<List<LogDay>>).value.isEmpty()) {
                    item {
                        Text(
                            "服务端还没有日志文件",
                            style = McType.footnote,
                            color = TextFaint,
                            modifier = Modifier.padding(vertical = 20.dp),
                        )
                    }
                }
            }
        }
    }
}

/* ---------------- 共用小件 ---------------- */

/** 子页顶栏：直接用全站那一条（`McTopBar(Sub)`），返回键与标题各页统一 */
@Composable
internal fun SettingsHeader(title: String, onBack: () -> Unit) {
    io.movieclaw.android.core.designsystem.McTopBar(
        variant = io.movieclaw.android.core.designsystem.McTopBarVariant.Sub,
        title = title,
        onBack = onBack,
    )
}

@Composable
internal fun SettingsActionButton(
    text: String,
    enabled: Boolean = true,
    primary: Boolean = false,
    onClick: () -> Unit,
) {
    TextButton(onClick = onClick, enabled = enabled) {
        Text(
            text,
            style = if (primary) McType.subheadlineSemibold else McType.subheadline,
            color = when {
                !enabled -> TextFaint
                primary -> Accent
                else -> TextMuted
            },
        )
    }
}

/** 一行服务代理：名字 + 开关 + 「测试连接」（行尾给结果与延迟，iOS `testResult`） */
@Composable
private fun ServiceProxyRow(
    service: io.movieclaw.android.core.model.EgressService,
    on: Boolean,
    proxyActive: Boolean,
    saving: Boolean,
    test: NetworkSettingsViewModel.ServiceTest?,
    onToggle: (Boolean) -> Unit,
    onTest: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(service.label.ifEmpty { service.id }, style = McType.sub, color = TextPrimary)
                if (service.description.isNotEmpty()) {
                    Text(
                        service.description,
                        style = McType.caption2, color = TextFaint,
                        maxLines = 2, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Switch(
                checked = on,
                enabled = !saving && proxyActive,
                onCheckedChange = onToggle,
                colors = SwitchDefaults.colors(
                    checkedTrackColor = Accent,
                    uncheckedTrackColor = Color.White.copy(alpha = 0.12f),
                    uncheckedBorderColor = Color.White.copy(alpha = 0.18f),
                ),
            )
        }
        Row(
            Modifier
                .clip(RoundedCornerShape(8.dp))
                .clickable(enabled = test?.pending != true) { onTest() }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("测试连接", style = McType.caption, color = Accent)
            Spacer(Modifier.width(8.dp))
            when {
                test?.pending == true -> Text("测试中…", style = McType.caption2, color = TextMuted)
                test?.result != null -> Text(
                    if (test.result.ok) {
                        (test.result.latencyMs?.let { "$it ms" } ?: "连通")
                    } else {
                        "不通 · ${test.result.message}".take(40)
                    },
                    style = McType.caption2,
                    color = if (test.result.ok) Success else Danger,
                )
            }
        }
    }
}

@Composable
internal fun SettingsTextField(
    value: String,
    placeholder: String,
    onValueChange: (String) -> Unit,
    keyboardType: KeyboardType = KeyboardType.Uri,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        placeholder = { Text(placeholder, style = McType.caption, color = TextFaint) },
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = Color.White.copy(alpha = 0.055f),
            unfocusedContainerColor = Color.White.copy(alpha = 0.055f),
            focusedBorderColor = Accent.copy(alpha = 0.45f),
            unfocusedBorderColor = Color.White.copy(alpha = 0.1f),
            focusedTextColor = Color.White,
            unfocusedTextColor = Color.White,
            cursorColor = Accent,
        ),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    )
}
