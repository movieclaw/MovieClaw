package io.movieclaw.android.feature.activity

import io.movieclaw.android.core.designsystem.FeedbackTone
import io.movieclaw.android.core.designsystem.McNotice
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.model.ActivePlaybackSession
import io.movieclaw.android.core.model.AgentSessionStart
import io.movieclaw.android.core.model.DownloadTask
import io.movieclaw.android.core.model.HandoffRequest
import io.movieclaw.android.core.model.JobEventView
import io.movieclaw.android.core.model.JobView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.EventStream
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
import kotlinx.serialization.json.Json

/**
 * AI 能力门禁三态——与网页 `LlmCapabilityState` 同口径（`components/llm-gate.tsx`）：
 * 只看「是否至少接入了一个供应商」（`GET /llm/providers` 非空）。
 * `CHECKING` 时不锁 AI 入口（避免闪烁）；探测失败按 `UNAVAILABLE`（不误锁，
 * 交给提交时的服务端错误兜底）；只有确认没配置（`MISSING`）才整个不渲染。
 */
enum class LlmGate { CHECKING, CONFIGURED, MISSING, UNAVAILABLE }

/**
 * 活动中心:后台任务(jobs 快照 + SSE 实时增量)、下载任务(10s 轮询)、
 * 播放监控(8s 轮询)。轮询间隔与 iOS 端一致(设计方案 §7.6)。
 */
@HiltViewModel
class ActivityViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val eventStream: EventStream,
    private val sessionRepository: SessionRepository,
    private val json: Json,
    private val playbackEvents: io.movieclaw.android.core.playback.PlaybackDataEvents,
) : ViewModel() {

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val notice: McNotice? = null,
        val jobs: List<JobView> = emptyList(),
        val liveConnected: Boolean = false,
        val downloads: List<DownloadTask> = emptyList(),
        val sessions: List<ActivePlaybackSession> = emptyList(),
        /** 设备正在拉的整文件（播放器离线缓存）——「正在下载」分区，和下载器里的种子任务是两件事 */
        val fileDownloads: List<io.movieclaw.android.core.model.ActiveFileDownload> = emptyList(),
        /** 观看统计（管理员专属，非管理员为 null） */
        val watchStats: io.movieclaw.android.core.model.PlaybackWatchStatsView? = null,
        /** 统计周期：7 / 30 / 90 天（网页 `STATS_PERIODS`） */
        val watchStatsDays: Int = 7,
        /** 钻取到的成员；null = 全部（网页「点成员名钻取」） */
        val watchStatsMemberId: Int? = null,
        /** 最近播放流水（管理员专属） */
        val history: List<io.movieclaw.android.core.model.PlaybackLogEntry> = emptyList(),
        /** AI 入口门禁（模型供应商是否已接入） */
        val llmGate: LlmGate = LlmGate.CHECKING,
        /** 正在整理上下文的事项（下载任务 = info_hash、后台任务 = 任务 id）——按钮转「正在整理上下文…」 */
        val analyzingKey: String? = null,
        /** 工单已备好、会话已建立，屏幕据此跳到该会话 */
        val handoffSessionId: String? = null,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = sessionRepository.ui.value.origin

    private var pollJob: Job? = null
    private var watchJob: Job? = null
    private var historyJob: Job? = null
    private var watchGeneration = 0
    private var historyGeneration = 0

    init {
        loadSnapshot()
        observeJobsStream()
        startPolling()
        viewModelScope.launch {
            playbackEvents.changes.collect { change ->
                if (change != null && sessionRepository.isCurrentIdentity(change.identity)) loadWatchAndHistory()
            }
        }
    }

    fun consumeNotice() = _ui.update { it.copy(notice = null) }

    fun consumeHandoff() = _ui.update { it.copy(handoffSessionId = null) }

    /** 模型供应商探测（`GET /llm/providers`）；探测失败不锁 AI 功能，按 unavailable 处理 */
    private fun loadLlmGate() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).llmProviders().dataOrThrow() }
                .onSuccess { providers ->
                    _ui.update { it.copy(llmGate = if (providers.isEmpty()) LlmGate.MISSING else LlmGate.CONFIGURED) }
                }
                .onFailure { _ui.update { it.copy(llmGate = LlmGate.UNAVAILABLE) } }
        }
    }

    /** 「交给 AI 分析」：下载任务（ref = info_hash，网页 HandoffButton 的用法） */
    fun analyzeTask(task: DownloadTask) = handoff(kind = "download", ref = task.infoHash)

    /** 「交给 Agent」：失败的**后台任务**（ref = 任务 id，网页 JobCard 的 `handoff_agent` 动作） */
    fun analyzeJob(job: JobView) = handoff(kind = "job", ref = job.id)

    /**
     * 「交给 AI 分析」——网页 `HandoffButton`（`components/handoff-button.tsx`）同款两步：
     * ① `POST /agent-handoff` 拿服务端组装的诊断工单（kind：download=info_hash / job=任务 id）；
     * ② 把工单正文当首条消息 `POST /sessions` 起会话，成功后跳到该会话。
     * 工单正文一个字都不在前端拼——现场自检的结论只有服务端有。
     */
    private fun handoff(kind: String, ref: String) {
        if (_ui.value.analyzingKey != null) return
        if (ref.isBlank()) return
        _ui.update { it.copy(analyzingKey = ref) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            runCatching {
                val handoff = api.agentHandoff(HandoffRequest(kind = kind, ref = ref)).dataOrThrow()
                val accepted = api.startAgentSession(AgentSessionStart(content = handoff.prompt)).dataOrThrow()
                accepted.sessionId
            }
                .onSuccess { sessionId ->
                    _ui.update { it.copy(analyzingKey = null, handoffSessionId = sessionId) }
                }
                .onFailure { e ->
                    _ui.update {
                        it.copy(
                            analyzingKey = null,
                            notice = McNotice(friendlyMessage(e).ifBlank { "无法发起 AI 分析" }, FeedbackTone.Error),
                        )
                    }
                }
        }
    }

    /** 立即换种（网页 `replaceStalledTask` 同款）：POST /downloaders/{id}/torrents/{hash}/replace */
    fun replaceTask(task: DownloadTask) {
        val downloaderId = task.downloaderId ?: return
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).replaceDownloadTask(downloaderId, task.infoHash) }
                .onSuccess {
                    _ui.update { it.copy(notice = McNotice("已开始寻找同品质替代源；旧任务保留到新源有真实进度")) }
                    loadSnapshot()
                }
                .onFailure { e -> _ui.update { it.copy(notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }

    /**
     * 洗版：`POST /subscriptions/{id}/upgrade-runs`。
     * 提示用**服务端返回的摘要句**（`UpgradeRunView.summary`），不自己拼。
     */
    fun upgradeSubscription(subscriptionId: Long) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).upgradeRun(
                    subscriptionId,
                    // 这个接口的 body 必填：不带体服务端判 422
                    io.movieclaw.android.core.model.UpgradeRunPayload(),
                ).dataOrThrow()
            }
                .onSuccess { report ->
                    _ui.update {
                        it.copy(notice = McNotice(report.summary.ifBlank { "洗版已开始，进展在「追踪明细」里跟进" }))
                    }
                }
                .onFailure { e -> _ui.update { it.copy(notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }

    /** 撤销忽略：从「已结束」放回「需要处理」（网页 `restoreDismissedJob`） */
    fun undismissJob(job: JobView) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).undismissJob(job.id) }
                .onSuccess { loadSnapshot() }
                .onFailure { e -> _ui.update { it.copy(notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }

    /** 一次忽略所有失败任务（网页「全部忽略」） */
    fun dismissAllFailed() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).dismissAllJobs() }
                .onSuccess {
                    _ui.update { it.copy(notice = McNotice("已忽略全部失败任务")) }
                    loadSnapshot()
                }
                .onFailure { e -> _ui.update { it.copy(notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }

    /** 切换观看统计周期（网页 `STATS_PERIODS`：7 / 30 / 90 天），只重拉统计，不动整页 */
    fun setWatchStatsDays(days: Int) {
        if (_ui.value.watchStatsDays == days) return
        _ui.update { it.copy(watchStatsDays = days, watchStats = null) }
        reloadWatchStats()
    }

    /** 钻取到某个成员（点成员名再点一次取消）；统计随之按该成员重算 */
    fun drillWatchStatsMember(memberId: Int?) {
        if (_ui.value.watchStatsMemberId == memberId) return
        _ui.update { it.copy(watchStatsMemberId = memberId, watchStats = null) }
        reloadWatchStats()
    }

    private fun reloadWatchStats() {
        val generation = ++watchGeneration
        watchJob?.cancel()
        watchJob = viewModelScope.launch {
            val origin = origin ?: return@launch
            val identity = sessionRepository.requestIdentity(origin) ?: return@launch
            val state = _ui.value
            runCatching {
                apiFactory.forIdentity(origin, identity).playbackWatchStats(
                    days = state.watchStatsDays,
                    tzOffsetMinutes = tzOffsetMinutes(),
                    memberId = state.watchStatsMemberId,
                ).dataOrThrow()
            }.onSuccess { stats ->
                if (generation == watchGeneration && sessionRepository.isCurrentIdentity(identity)) {
                    _ui.update { it.copy(watchStats = stats) }
                }
            }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }
        }
    }

    private fun tzOffsetMinutes(): Int =
        java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 60000

    /** 删除下载任务（默认不删已下载的文件；网页的删除确认里那个开关默认也是关的） */
    fun deleteTask(task: DownloadTask) {
        val downloaderId = task.downloaderId ?: return
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).deleteDownloadTask(downloaderId, task.infoHash, deleteFiles = false) }
                .onSuccess {
                    _ui.update { it.copy(notice = McNotice("已删除下载任务")) }
                    loadSnapshot()
                }
                .onFailure { e -> _ui.update { it.copy(notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }

    /**
     * 观看统计与最近播放（`/playback/stats/watch`、`/playback/history`）。
     * 两个接口都是**管理员专属**：非管理员 403，静默跳过——不报错、不显示空壳。
     */
    fun loadWatchAndHistory() {
        reloadWatchStats()
        val generation = ++historyGeneration
        historyJob?.cancel()
        historyJob = viewModelScope.launch {
            val origin = origin ?: return@launch
            val identity = sessionRepository.requestIdentity(origin) ?: return@launch
            runCatching { apiFactory.forIdentity(origin, identity).playbackHistory(limit = 20).dataOrThrow() }
                .onSuccess { history ->
                    if (generation == historyGeneration && sessionRepository.isCurrentIdentity(identity)) {
                        _ui.update { it.copy(history = history.entries) }
                    }
                }
                .onFailure {
                    if (it is kotlinx.coroutines.CancellationException) throw it
                    android.util.Log.i("McActivity", "播放历史跳过：${it.message}")
                }
        }
    }

    fun loadSnapshot() {
        loadWatchAndHistory()
        loadLlmGate()
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).jobs().dataOrThrow() }
                .onSuccess { list -> _ui.update { it.copy(loading = false, jobs = list.items) } }
                .onFailure { e ->
                    if (_ui.value.jobs.isEmpty()) _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
                }
        }
    }

    /** jobs 增量流:ready 事件给游标,之后每条 job 事件刷新(120ms 防抖对齐 iOS) */
    private fun observeJobsStream() {
        viewModelScope.launch {
            runCatching {
                eventStream.reliableEvents("jobs/stream").collect { event ->
                    when (event.name) {
                        "ready" -> {
                            _ui.update { it.copy(liveConnected = true) }
                            loadSnapshot()
                        }
                        "job" -> {
                            val eventView = runCatching { json.decodeFromString<JobEventView>(event.data) }.getOrNull() ?: return@collect
                            delay(120)
                            refreshJob(eventView.jobId)
                        }
                    }
                }
            }
        }
    }

    private suspend fun refreshJob(jobId: String) {
        val origin = origin ?: return
        runCatching { apiFactory.forOrigin(origin).jobs().dataOrThrow() }
            .onSuccess { list -> _ui.update { it.copy(jobs = list.items) } }
    }

    private fun startPolling() {
        pollJob = viewModelScope.launch {
            while (isActive) {
                delay(10_000)
                val origin = origin ?: continue
                runCatching { apiFactory.forOrigin(origin).downloadTasks().dataOrThrow() }
                    .onSuccess { tasks -> _ui.update { it.copy(downloads = tasks.items) } }
            }
        }
        viewModelScope.launch {
            while (isActive) {
                delay(8_000)
                val origin = origin ?: continue
                runCatching { apiFactory.forOrigin(origin).playbackActivity().dataOrThrow() }
                    .onSuccess { activity ->
                        _ui.update { it.copy(sessions = activity.sessions, fileDownloads = activity.downloads) }
                    }
            }
        }
    }

    fun cancelJob(job: JobView) = jobAction { it.cancelJob(job.id) }
    fun retryJob(job: JobView) = jobAction { it.retryJob(job.id) }
    fun dismissJob(job: JobView) = jobAction { it.dismissJob(job.id) }

    /** 任务动作（取消 / 重跑）：只看有没有抛错，做完重拉快照——返回类型不关心 */
    private fun jobAction(block: suspend (io.movieclaw.android.core.api.McApi) -> io.movieclaw.android.core.network.McEnvelope<*>) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { block(apiFactory.forOrigin(origin)) }
            loadSnapshot()
        }
    }

    fun endSession(session: ActivePlaybackSession) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).endPlaybackSession(session.deviceId).dataOrThrow() }
                .onSuccess { _ui.update { it.copy(notice = McNotice("已结束 ${session.deviceName} 的播放", FeedbackTone.Success)) } }
                .onFailure { e -> _ui.update { it.copy(notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }

    override fun onCleared() {
        pollJob?.cancel()
        super.onCleared()
    }
}
