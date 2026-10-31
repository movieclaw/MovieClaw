package io.movieclaw.android.feature.detail

import androidx.compose.ui.text.TextStyle
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.offline.OfflineQueue
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.RowScope
import io.movieclaw.android.core.designsystem.TextPrimary
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.KeyboardArrowRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.TextButton
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.foundation.combinedClickable
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Search
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import io.movieclaw.android.core.designsystem.Accent2
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.LocalTabHazeState
import dev.chrisbanes.haze.hazeSource
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.Loadable
import io.movieclaw.android.core.designsystem.PosterCard
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.model.LibraryItemDetailView
import io.movieclaw.android.feature.offline.OfflineDownloadStrip
import io.movieclaw.android.feature.offline.OfflineJustFinished
import io.movieclaw.android.core.model.LibraryItemView
import io.movieclaw.android.core.model.CollectionSeriesView
import io.movieclaw.android.core.api.McApi
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import io.movieclaw.android.core.model.LibraryFileView
import io.movieclaw.android.core.model.DeleteFollowUpView
import io.movieclaw.android.core.model.ItemDeletePreviewView
import io.movieclaw.android.core.model.ItemDeleteResultView
import io.movieclaw.android.core.model.JobView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import androidx.compose.runtime.DisposableEffect
import io.movieclaw.android.feature.activity.LlmGate
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import androidx.compose.material.icons.rounded.Favorite
import io.movieclaw.android.core.designsystem.FeedbackTone
import io.movieclaw.android.core.designsystem.LocalFeedback
import io.movieclaw.android.core.designsystem.McNotice
import io.movieclaw.android.core.model.PlaybackMarks
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.ui.draw.alpha
import io.movieclaw.android.core.playback.TrackLabels
import io.movieclaw.android.core.model.AudioStreamView
import io.movieclaw.android.core.model.SubtitleStreamView
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.model.PlaybackStateView
import io.movieclaw.android.core.model.PlaybackMarksRequest
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.drop
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import io.movieclaw.android.core.designsystem.mcCards
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.graphicsLayer
import io.movieclaw.android.core.designsystem.formSheetScroll

@HiltViewModel
class ItemDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
    private val preconnect: io.movieclaw.android.core.playback.PlaybackPreconnect,
    private val eventStream: io.movieclaw.android.core.network.EventStream,
    /** 离线下载（iOS `OfflineDownloadControl` 的数据源） */
    private val offlineStore: io.movieclaw.android.core.offline.OfflineStore,
    private val offlineDownloader: io.movieclaw.android.core.offline.OfflineDownloader,
    private val reachability: io.movieclaw.android.core.offline.ServerReachability,
) : ViewModel() {

    /** 离线下载（docs/design/offline-download.md）：本机目录、下载器、可达性 */
    val offline: io.movieclaw.android.core.offline.OfflineStore get() = offlineStore
    val downloader: io.movieclaw.android.core.offline.OfflineDownloader get() = offlineDownloader

    /**
     * 只读：离线模式，或在线请求失败 / 服务器上已删除、回落本机副本（iOS `readOnly`）。
     * 只读时隐藏管理菜单、收藏、标记已看、相似推荐、系列；分集列表照常，没下载的集置灰
     */
    private val _localOnly = MutableStateFlow(false)
    private val _goneOnServer = MutableStateFlow(false)
    val goneOnServer = _goneOnServer.asStateFlow()
    val readOnly: kotlinx.coroutines.flow.StateFlow<Boolean> =
        kotlinx.coroutines.flow.combine(reachability.mode, _localOnly) { mode, local ->
            mode == io.movieclaw.android.core.offline.ServerReachability.Mode.OFFLINE || local
        }.stateIn(viewModelScope, kotlinx.coroutines.flow.SharingStarted.Eagerly, false)

    /** 本机存的详情读不出来（旧版存档、还没联网刷新）：退回只靠摘要的极简详情 */
    private val _minimal = MutableStateFlow(false)
    val minimal = _minimal.asStateFlow()

    private val isOffline: Boolean get() = reachability.isOffline

    val libraryId: Long = savedStateHandle.get<String>("libraryId")?.toLongOrNull() ?: -1L
    val itemId: Long = savedStateHandle.get<String>("itemId")?.toLongOrNull() ?: -1L

    data class Detail(
        val item: LibraryItemDetailView,
        val episodes: Map<Int, List<EpisodeView>> = emptyMap(),
        /** 每季「接着看」的锚点（服务端 resume_episode，没有就退回客户端原规则，见 [EpisodeRanges.anchor]） */
        val anchors: Map<Int, Int?> = emptyMap(),
        /** 每季的播出日历（issue #547）；只有在播的季有 */
        val schedules: Map<Int, io.movieclaw.android.core.model.SeasonAirSchedule?> = emptyMap(),
    )

    private val _state = MutableStateFlow<Loadable<Detail>>(Loadable.Loading)
    val state = _state.asStateFlow()

    /**
     * 详情页下面的「相似推荐」与电影的「作品系列」两行（iOS / Apple TV / Mac / Web 同一套规则）。
     * 有系列一行时相似推荐排除同系列的片——系列那一行已经按上映顺序列全了。
     */
    data class Related(
        val similar: List<LibraryItemView> = emptyList(),
        val series: CollectionSeriesView? = null,
    )

    private val _related = MutableStateFlow(Related())
    val related = _related.asStateFlow()

    /** 两行只在第一次拿到详情时拉：换字幕、恢复文件后整页重拉详情，推荐不跟着闪 */
    private var relatedRequested = false

    private val _selectedSeason = MutableStateFlow<Int?>(null)
    val selectedSeason = _selectedSeason.asStateFlow()

    /**
     * 选中的单元 —— 季 + 集（iOS `LibraryItemDetailView.SelectedEpisode` 的对应物）。
     *
     * iOS 上它是**详情页的一等状态**：播放键（`play` 带 `season`/`episode`）、续播点
     * （`playbackResume(seasonNumber:episodeNumber:)`，键就是「季/集」）、已看（`playUnit`）、
     * 版本/文件（`selectedEpisode.files`）全都以它为准。安卓此前只有「季」这一个状态，
     * 播放键又自己去扫「跨季第一个没看的在库集」，于是**选了季也照旧从第一季起播**。
     */
    data class SelectedUnit(val season: Int, val episode: Int)

    private val _selectedEpisode = MutableStateFlow<SelectedUnit?>(null)
    val selectedEpisode = _selectedEpisode.asStateFlow()

    /** 初始选中（= 服务端续播那一集，iOS 由路由 `?season=&episode=` 带进来，这里由详情自己算） */
    private var seedUnit: SelectedUnit? = null
    private var episodesBySeason: Map<Int, List<EpisodeView>> = emptyMap()
    private var anchorsBySeason: Map<Int, Int?> = emptyMap()

    val origin: String? get() = repository.ui.value.origin

    init {
        // 详情页是播放入口：进页就把起播要用的两条连接连好（iOS `LibraryItemDetailView.task` 同款）
        preconnect.warm()
        load()
    }

    // ───────────────────────── AI 字幕生成（iOS `TrackGenModel` 同款） ─────────────────────────
    // 全是管理员接口；能力门禁 `GET /llm/providers` 非空 = 已配置（网页 `LlmCapabilityState` 口径）。

    private val _subtitleGen = MutableStateFlow(SubtitleGenUiState())
    val subtitleGen = _subtitleGen.asStateFlow()

    /** 生成完成时回调（详情页据此重拉字幕清单，新字幕立刻可见） */
    var onSubtitleChanged: (() -> Unit)? = null

    private val _agentHandoff = MutableStateFlow<String?>(null)
    val agentHandoff = _agentHandoff.asStateFlow()
    fun consumeAgentHandoff() { _agentHandoff.value = null }

    private var previewSeq = 0
    private var previewTask: Job? = null
    private var trackedFileId: Long? = null

    /** 亲眼看到「活跃 → succeeded」才回调（初次读到历史成功任务不算，同 iOS `apply()`） */
    private var sawActiveJob = false

    fun closeSubtitleGen() {
        _subtitleGen.update { it.copy(mode = null, preview = null, requestError = null, pendingMessage = null) }
        previewTask?.cancel()
    }

    /** 能力门禁：探测失败 fail-open（按 unavailable 处理，交给提交时的服务端报错兜底） */
    fun checkLlmGate() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val gate = runCatching { apiFactory.forOrigin(origin).llmProviders().dataOrThrow() }
                .fold(
                    onSuccess = { if (it.isEmpty()) LlmGate.MISSING else LlmGate.CONFIGURED },
                    onFailure = { LlmGate.UNAVAILABLE },
                )
            _subtitleGen.update { it.copy(gate = gate) }
        }
    }

    /** 点入口：运行中 / 有终态问题 → 状态弹层；未接 AI → 由界面跳「模型接入」；否则开预检 */
    fun openSubtitleGen(fileId: Long, onNeedLlmSettings: () -> Unit) {
        val job = _subtitleGen.value.job
        if (job != null && (job.status in SUBTITLE_RUNNING_STATUSES || job.status in SUBTITLE_ISSUE_STATUSES)) {
            _subtitleGen.update { it.copy(mode = SubtitleGenMode.STATUS) }
            return
        }
        if (_subtitleGen.value.gate == LlmGate.MISSING) {
            onNeedLlmSettings()
            return
        }
        checkLlmGate()
        _subtitleGen.update { it.copy(mode = SubtitleGenMode.PREVIEW) }
        runPreview(fileId)
    }

    /**
     * 预检：参数（语言/参考字幕）一改就重发，且**先把在途预检掐掉**——不掐的话后端会对同一个
     * 大文件起多次抽取（iOS 同一纪律，issue #432）。客户端 20 秒超时：预检只读库，超了就是异常。
     */
    private fun runPreview(fileId: Long) {
        previewTask?.cancel()
        val seq = ++previewSeq
        previewTask = viewModelScope.launch {
            _subtitleGen.update {
                it.copy(previewing = true, requestError = null, pendingMessage = null)
            }
            val origin = origin ?: return@launch
            while (true) {
                val current = _subtitleGen.value
                val preview = try {
                    kotlinx.coroutines.withTimeout(20_000) {
                        apiFactory.forOrigin(origin).subtitleGenerationPreview(
                            fileId = fileId,
                            targetLanguage = current.targetLanguage,
                            secondaryLanguage = current.secondaryLanguage.takeIf { current.bilingual },
                            sourceCandidateKey = current.sourceKey,
                        ).dataOrThrow()
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (seq == previewSeq) {
                        _subtitleGen.update { it.copy(previewing = false, requestError = friendlyMessage(e)) }
                    }
                    return@launch
                }
                if (seq != previewSeq) return@launch
                val pending = preview.pending
                if (pending == null) {
                    _subtitleGen.update { it.copy(previewing = false, preview = preview, pendingMessage = null) }
                    return@launch
                }
                // 旧服务端：还在抽。这份快照的 chosen/blocker 都是空的，写进 preview 会误导成
                // 「没有参考字幕」——只显示等待文案，按服务端建议的间隔重拉。
                _subtitleGen.update { it.copy(pendingMessage = pending.message) }
                delay(pending.retryAfterMs.coerceAtLeast(1_000))
            }
        }
    }

    fun setTargetLanguage(fileId: Long, token: String) {
        _subtitleGen.update { s ->
            val secondary = if (s.bilingual && s.secondaryLanguage == token) firstOtherLanguage(token) else s.secondaryLanguage
            s.copy(targetLanguage = token, secondaryLanguage = secondary)
        }
        runPreview(fileId)
    }

    fun setSecondaryLanguage(fileId: Long, token: String) {
        _subtitleGen.update { it.copy(secondaryLanguage = token) }
        runPreview(fileId)
    }

    fun setBilingual(fileId: Long, on: Boolean) {
        _subtitleGen.update { s ->
            val secondary = if (on && s.secondaryLanguage == s.targetLanguage) firstOtherLanguage(s.targetLanguage) else s.secondaryLanguage
            s.copy(bilingual = on, secondaryLanguage = secondary)
        }
        runPreview(fileId)
    }

    /** 指定参考字幕（null 传不了，界面只在用户点选时调用） */
    fun setSourceKey(fileId: Long, ref: String) {
        _subtitleGen.update { it.copy(sourceKey = ref) }
        runPreview(fileId)
    }

    /** PGS 的「原字幕语言」：**不重发预检**，只在提交时带上（iOS 同款） */
    fun setPgsOcrLanguage(token: String) {
        _subtitleGen.update { it.copy(pgsOcrLanguage = token) }
    }

    fun confirmSubtitleGen(fileId: Long) {
        val s = _subtitleGen.value
        val canPreparePgs = s.preview?.blocker?.code == "pgs_conversion_required" &&
            s.preview.pgsConversion?.available == true
        viewModelScope.launch {
            _subtitleGen.update { it.copy(starting = true, requestError = null) }
            val origin = origin ?: return@launch
            val result = runCatching {
                apiFactory.forOrigin(origin).startSubtitleGeneration(
                    fileId = fileId,
                    body = io.movieclaw.android.core.model.SubtitleGenStartPayload(
                        targetLanguage = s.targetLanguage,
                        secondaryLanguage = s.secondaryLanguage.takeIf { s.bilingual },
                        sourceCandidateKey = s.sourceKey,
                        convertPgs = canPreparePgs,
                        pgsOcrLanguage = s.pgsOcrLanguage.takeIf { canPreparePgs && it.isNotBlank() },
                    ),
                ).dataOrThrow()
            }
            result.onSuccess { job ->
                if (job.status in SUBTITLE_RUNNING_STATUSES) sawActiveJob = true
                _subtitleGen.update { it.copy(starting = false, job = job, mode = SubtitleGenMode.STATUS) }
                trackSubtitleJob(fileId)
            }.onFailure { e ->
                _subtitleGen.update { it.copy(starting = false, requestError = friendlyMessage(e)) }
            }
        }
    }

    fun cancelSubtitleJob() {
        val job = _subtitleGen.value.job ?: return
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).cancelJob(job.id).dataOrThrow().job }
                .getOrNull()?.let { updated -> _subtitleGen.update { it.copy(job = updated) } }
        }
    }

    /** 「重新检查 / 重新预检」：回到预检模式重跑（状态弹层里点它是同一个语义） */
    fun retrySubtitlePreview(fileId: Long) {
        _subtitleGen.update { it.copy(mode = SubtitleGenMode.PREVIEW, preview = null) }
        runPreview(fileId)
    }

    /** 「交给 Agent 处理」：新会话的首条消息就是那段诊断提示词（逐字照 iOS/网页） */
    fun handOffSubtitleGenToAgent(fileId: Long) {
        val file = (state.value as? Loadable.Ready)?.value?.item?.files?.firstOrNull { it.id == fileId }
        viewModelScope.launch {
            _subtitleGen.update { it.copy(agentStarting = true) }
            val origin = origin ?: return@launch
            val prompt = subtitleGenAgentPrompt(fileId, file)
            val created = runCatching {
                apiFactory.forOrigin(origin)
                    .startAgentSession(io.movieclaw.android.core.model.AgentSessionStart(content = prompt))
                    .dataOrThrow()
            }
            _subtitleGen.update { it.copy(agentStarting = false) }
            created.onSuccess { accepted -> _agentHandoff.value = accepted.sessionId }
                .onFailure { e ->
                    _subtitleGen.update { it.copy(requestError = "无法启动 Agent：${friendlyMessage(e)}") }
                }
        }
    }

    /** 字幕任务的跟踪：SSE（ready/job，120ms 去抖）+ 15 秒兜底轮询（iOS `.polling(every: 15)`） */
    fun trackSubtitleJob(fileId: Long?) {
        if (fileId == null || trackedFileId == fileId) return
        trackedFileId = fileId
        viewModelScope.launch {
            runCatching {
                eventStream.reliableEvents("jobs/stream").collect { event ->
                    if (event.name == "ready" || event.name == "job") {
                        delay(120)
                        refreshSubtitleJob(fileId)
                    }
                }
            }
        }
        viewModelScope.launch {
            while (true) {
                refreshSubtitleJob(fileId)
                delay(15_000)
            }
        }
    }

    private suspend fun refreshSubtitleJob(fileId: Long) {
        val origin = origin ?: return
        val job = runCatching {
            apiFactory.forOrigin(origin).jobs(
                jobType = "subtitle.generate",
                resourceType = "library_file",
                resourceId = fileId,
                limit = 5,
            ).dataOrThrow().items.maxByOrNull { it.updatedAt.orEmpty() }
        }.getOrNull() ?: return
        val wasActive = sawActiveJob
        if (job.status in SUBTITLE_RUNNING_STATUSES) sawActiveJob = true
        _subtitleGen.update { it.copy(job = job) }
        if (wasActive && job.status == "succeeded") {
            sawActiveJob = false
            onSubtitleChanged?.invoke()
        }
    }

    /** 双语第二行默认取表里第一条不同语言（iOS `nextSecondary`） */
    private fun firstOtherLanguage(token: String): String =
        SubtitleGenText.outputLanguages.map { it.first }.firstOrNull { it != token } ?: token

    /** 「交给 Agent 处理」的提示词（逐字照 iOS/Web 的模板） */
    private fun subtitleGenAgentPrompt(
        fileId: Long,
        file: io.movieclaw.android.core.model.LibraryFileView?,
    ): String {
        val s = _subtitleGen.value
        val job = s.job
        val target = job?.progress?.details?.get("target_language")?.let { runCatching { it.toString().trim('"') }.getOrNull() }
            ?.takeIf { it.isNotBlank() } ?: s.targetLanguage
        val secondary = job?.progress?.details?.get("secondary_language")?.let { runCatching { it.toString().trim('"') }.getOrNull() }
            ?.takeIf { it.isNotBlank() && it != "null" } ?: s.secondaryLanguage.takeIf { s.bilingual }
        val sourceKey = job?.progress?.details?.get("source_candidate_key")?.let { runCatching { it.toString().trim('"') }.getOrNull() }
            ?.takeIf { it.isNotBlank() && it != "null" } ?: s.sourceKey
        val running = job != null && job.status in SUBTITLE_RUNNING_STATUSES
        val reason = if (running) {
            job?.progress?.message?.takeIf { it.isNotBlank() } ?: "任务未完成"
        } else {
            s.requestError ?: s.preview?.blocker?.message ?: "字幕生成预检没有通过"
        }
        val output = SubtitleGenText.outputLabel(target, secondary)
        val args = buildString {
            append("--target-language ").append(target)
            if (secondary != null) append(" --secondary-language ").append(secondary)
            if (sourceKey != null) append(" --source-candidate-key ").append(sourceKey)
        }
        val pgs = s.preview?.pgsConversion
        val lines = buildList {
            add("请帮我处理 MovieClaw 的 AI 字幕生成问题。")
            add("文件：${file?.fileName.orEmpty()}")
            add("文件台账 ID：$fileId")
            add("文件路径：${file?.filePath.orEmpty()}")
            add("期望输出：$output")
            add("对应参数：$args")
            add("当前问题：$reason")
            pgs?.let {
                val engine = it.engine ?: "未找到可用识别引擎"
                add("预检环境：${it.platform} ${it.architecture} · $engine")
                if (it.message.isNotBlank()) add("预检诊断：${it.message}")
            }
            s.preview?.blocker?.suggestions?.forEach { add("已有建议：$it") }
            add("请先判断原因；如果能通过 MovieClaw 的工具安全解决，请按上面的「对应参数」直接执行（不要换回默认参数），否则给出明确的操作步骤。不要修改影片原文件。")
        }
        return lines.joinToString("\n")
    }

    /**
     * 相似推荐与系列并行拉：先按「有系列合集」排除同系列；系列一行最后没出来（只有一部、
     * 或拉不到上游档案——本地 NFO 定的系列就没有）时再拉一次不排除的，否则续集哪儿都看不到。
     * 推荐是锦上添花：失败、旧服务端没有这个接口，都是那一行不出。
     */
    private suspend fun fetchRelated(api: McApi, detail: LibraryItemDetailView): Related = coroutineScope {
        val seriesId = detail.seriesCollectionId.takeIf { detail.kind != "tv" }
        suspend fun similar(excludeSeries: Boolean) = runCatching {
            api.similarItems(libraryId, itemId, excludeSeries = if (excludeSeries) true else null).dataOrThrow()
        }.getOrDefault(emptyList())
        val similarItems = async { similar(seriesId != null) }
        val series = seriesId?.let { id ->
            runCatching { api.collectionSeries(id).dataOrThrow() }.getOrNull()
                ?.takeIf { it.available && it.parts.size > 1 }
        }
        val items = if (seriesId != null && series == null) {
            similarItems.cancel()
            similar(false)
        } else {
            similarItems.await()
        }
        Related(items, series)
    }

    private var loadJob: Job? = null

    /**
     * 拉详情（iOS `reload`）：本机有副本时先用本机数据秒开，在线再静默拉服务器、写回本机。
     * 离线只读本机；在线失败回落本机（只读、每 10 秒重试）；服务器上已删除但手机上还有：显示本机副本，仍可播放、删除
     */
    fun load() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val hadDetail = _state.value is Loadable.Ready
            if (!hadDetail) _state.value = Loadable.Loading
            // 冷启动直达详情时本机目录可能还没读完：先等它，不然离线时判成「没有副本」
            offlineStore.waitUntilLoaded()
            val local = if (offlineStore.downloadedItemIds.value.contains(itemId)) offlineStore.detail(itemId) else null
            if (local != null && (!hadDetail || isOffline)) {
                val shown = if (isOffline) offlineStore.offlineDetail(local) else local
                _localOnly.value = isOffline
                _minimal.value = false
                applyDetail(shown, localSeasons(shown))
            }
            if (isOffline) {
                if (local == null && _state.value !is Loadable.Ready) {
                    _minimal.value = offlineStore.state.value.items[itemId] != null
                    _state.value = Loadable.Failed("离线时只能看已下载的内容")
                }
                return@launch
            }
            val origin = repository.ui.value.origin
            if (origin == null) {
                if (_state.value !is Loadable.Ready) _state.value = Loadable.Failed("尚未连接服务器")
                return@launch
            }
            try {
                val api = apiFactory.forOrigin(origin)
                val detail = api.libraryItemDetail(libraryId, itemId).dataOrThrow()
                val seasons = fetchSeasons(detail)
                _localOnly.value = false
                _goneOnServer.value = false
                _minimal.value = false
                offlineStore.refresh(detail)
                applyDetail(detail, seasons)
                if (!relatedRequested) {
                    relatedRequested = true
                    launch { _related.value = fetchRelated(api, detail) }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                val status = (e as? retrofit2.HttpException)?.code()
                if (local != null) {
                    // 连不上 / 服务器上已没有：停在本机数据上，只显示本机有的文件与集
                    val shown = offlineStore.offlineDetail(local)
                    _localOnly.value = true
                    _goneOnServer.value = status == 404
                    applyDetail(shown, localSeasons(shown))
                } else if (status == 404 || _state.value !is Loadable.Ready) {
                    // 条目已不存在：落到兜底态，别继续显示已不存在的条目
                    _minimal.value = offlineStore.state.value.items[itemId] != null && status != 404
                    _state.value = Loadable.Failed(friendlyMessage(e))
                }
            }
        }
    }

    /** 本机存的各季分集（离线显示：「在库」= 本机有、进度取本机） */
    private suspend fun localSeasons(
        detail: LibraryItemDetailView,
    ): Triple<Map<Int, List<EpisodeView>>, Map<Int, Int?>, Map<Int, io.movieclaw.android.core.model.SeasonAirSchedule?>> {
        if (detail.kind != "tv") return Triple(emptyMap(), emptyMap(), emptyMap())
        val views = detail.seasons.mapNotNull { season ->
            offlineStore.season(itemId, season)?.let { season to offlineStore.offlineSeason(it.copy(seasonNumber = season), itemId) }
        }.toMap()
        // 离线不显示播出日历（它来自服务器，iOS 同样离线时不给）
        return Triple(views.mapValues { it.value.episodes }, views.mapValues { EpisodeRanges.anchor(it.value.episodes, it.value.resumeEpisode) }, emptyMap())
    }

    private fun applyDetail(
        detail: LibraryItemDetailView,
        seasons: Triple<Map<Int, List<EpisodeView>>, Map<Int, Int?>, Map<Int, io.movieclaw.android.core.model.SeasonAirSchedule?>>,
    ) {
        val (episodes, anchors, schedules) = seasons
        val previous = (_state.value as? Loadable.Ready)?.value
        _state.value = Loadable.Ready(Detail(detail, episodes, anchors, schedules))
        episodesBySeason = episodes
        anchorsBySeason = anchors
        // 已经选过（重拉）：保留用户的选择，只在那一季已不存在时重新落点
        val keep = _selectedEpisode.value?.takeIf { previous != null && episodes.containsKey(it.season) || (previous != null && detail.kind != "tv") }
        if (keep != null) return
        // 初始选中：续播那一季的锚点（长剧分段 §3「进详情页」：段锁在它所在的段）。
        // 季的回退链照 iOS `SeasonEpisodesSection.currentSeason`：续播那季 → 第一个在库的季 → 第一个季
        val seed = pickResumeEpisode(detail, episodes).takeIf { it.second > 0 }
            ?: detail.seasons.firstOrNull()?.let { season ->
                episodes[season]?.firstOrNull()?.let { Triple(season, it.episodeNumber, it.name) }
            }
        seedUnit = seed?.let { SelectedUnit(it.first, anchors[it.first] ?: it.second) }
        val ownedSeasons = detail.files.map { it.seasonNumber }.toSet()
        _selectedSeason.value = seed?.first?.takeIf { episodes.containsKey(it) }
            ?: detail.seasons.firstOrNull { it in ownedSeasons }
            ?: detail.seasons.firstOrNull()
        _selectedEpisode.value = seedUnit
            ?: _selectedSeason.value?.let { s ->
                episodes[s]?.firstOrNull()?.let { SelectedUnit(s, it.episodeNumber) }
            }
    }

    init {
        // 离线 ↔ 在线切换：重拉（离线显示本机的、回到在线换成服务器的）
        viewModelScope.launch {
            reachability.mode.drop(1).collect { load() }
        }
        // 只读页上的本机副本变了（删了 / 下完了）：重载；删光则这一页没有能看、能播的了
        viewModelScope.launch {
            offlineStore.doneFileIds.drop(1).collect {
                if (!readOnly.value || !offlineStore.loaded.value) return@collect
                if (!offlineStore.downloadedItemIds.value.contains(itemId)) {
                    _closeRequest.value = true
                    return@collect
                }
                load()
            }
        }
        // 在线时请求失败回落了本机副本（一时的 502、超时）：隔一会儿再试，接口好了自己回到在线详情
        viewModelScope.launch {
            while (true) {
                delay(10_000)
                if (_localOnly.value && !_goneOnServer.value && !isOffline) load()
            }
        }
    }

    /** 只读页的本机副本删光了：请界面退回上一页 */
    private val _closeRequest = MutableStateFlow(false)
    val closeRequest = _closeRequest.asStateFlow()

    /**
     * 换季：**连带把选中集切到这一季**（iOS `SeasonEpisodesSection.load(reset:)` 同口径）——
     * 落在这一季的锚点（服务端 resume_episode；没有就第一个看了一半的 → 第一个没看的 → 第一集，
     * 有片源的优先）。只换季不换集的话，播放键会拿「第 3 季 + 第 1 季的那一集」
     * 去起播，服务端找不到就退回第一季——现象与用户报的完全一致。
     */
    fun selectSeason(season: Int) {
        _selectedSeason.value = season
        val picked = anchorsBySeason[season]
        if (picked != null) _selectedEpisode.value = SelectedUnit(season, picked)
    }

    /** 手动换段：段里有锚点选锚点，否则段首（段跟着选中集走，不单独存） */
    fun selectRange(season: Int, range: EpisodeRanges.Range) {
        _selectedEpisode.value = SelectedUnit(season, EpisodeRanges.entryOf(range, anchorsBySeason[season]))
    }

    /** 拉每一季的分集，并按 resume_episode 算出每季锚点；顺带每季的播出日历 */
    private suspend fun fetchSeasons(
        detail: LibraryItemDetailView,
    ): Triple<Map<Int, List<EpisodeView>>, Map<Int, Int?>, Map<Int, io.movieclaw.android.core.model.SeasonAirSchedule?>> {
        if (detail.kind != "tv") return Triple(emptyMap(), emptyMap(), emptyMap())
        val api = apiFactory.forOrigin(origin ?: return Triple(emptyMap(), emptyMap(), emptyMap()))
        val views = detail.seasons.associateWith { season ->
            api.seasonEpisodes(libraryId, itemId, season).dataOrThrow()
        }
        // 本机有这部剧的副本：顺手刷新存档的分集（下次离线看到的是最新的）
        views.forEach { (season, view) -> offlineStore.refresh(view.copy(seasonNumber = season), itemId) }
        return Triple(
            views.mapValues { it.value.episodes },
            views.mapValues { EpisodeRanges.anchor(it.value.episodes, it.value.resumeEpisode) },
            views.mapValues { it.value.airSchedule },
        )
    }

    /** 播出日历的「补缺集」：订阅立即搜索已经能搜的缺口（同订阅详情页的「立即搜索」） */
    suspend fun searchMissing(subscriptionId: Long): Result<String> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            val data = apiFactory.forOrigin(origin).searchMissingResources(subscriptionId).dataOrThrow()
            val count = (data as? kotlinx.serialization.json.JsonObject)?.get("reset_count")
                ?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull() } ?: 0
            "$count 个缺口已重新排队，正在搜索"
        }
    }

    /**
     * 播放回来 / 回到前台：静默重拉分集（不闪加载态）。当前季锚点变了（看完 1050 → 1051）
     * 就选中新锚点、段跟着锁过去；没变就不动，保留用户在别的段的浏览。
     */
    fun refreshEpisodes() {
        if (readOnly.value) return
        val ready = (_state.value as? Loadable.Ready)?.value ?: return
        viewModelScope.launch {
            val (episodes, anchors, schedules) = runCatching { fetchSeasons(ready.item) }.getOrNull() ?: return@launch
            val current = (_state.value as? Loadable.Ready)?.value ?: return@launch
            _state.value = Loadable.Ready(current.copy(episodes = episodes, anchors = anchors, schedules = schedules))
            episodesBySeason = episodes
            anchorsBySeason = anchors
            val season = _selectedSeason.value ?: return@launch
            EpisodeRanges.afterRefresh(current.anchors[season], anchors[season])
                ?.let { _selectedEpisode.value = SelectedUnit(season, it) }
        }
    }

    /** 点某一集 = 选中它（播放键、续播点、已看、版本都跟着走，iOS 同款） */
    fun selectEpisode(season: Int, episode: Int) {
        _selectedEpisode.value = SelectedUnit(season, episode)
    }

    /* ---------- 已看 / 收藏（与 Jellyfin 同一个服务，网页同款乐观更新） ---------- */

    private val _marks = MutableStateFlow(PlaybackMarks())
    val marks = _marks.asStateFlow()

    /**
     * 续播点与记忆轨（`GET /playback/resume`，iOS `LibraryItemDetailView` 同款数据源）：
     * 播放键三态要用 position/played，轨选择要用 audio_track/subtitle_track
     * （服务端口径：本集记着的 > 沿用上一集 > 默认轨策略）。
     */
    private val _resume = MutableStateFlow<PlaybackStateView?>(null)
    val resume = _resume.asStateFlow()

    fun loadResume(mediaItemId: Long, seasonNumber: Int, episodeNumber: Int) {
        if (readOnly.value) {
            // 本机进度 → 播放键要的观看状态
            _resume.value = offlineStore.localProgress(mediaItemId, seasonNumber, episodeNumber)?.let {
                PlaybackStateView(positionMs = it.positionMs, played = it.played, playCount = if (it.played) 1 else 0, durationMs = it.durationMs)
            }
            return
        }
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin)
                    .resumeState(mediaItemId, seasonNumber, episodeNumber)
                    .dataOrThrow()
            }.onSuccess { _resume.value = it }
        }
    }

    private val _notice = MutableStateFlow<McNotice?>(null)
    val notice = _notice.asStateFlow()

    fun consumeNotice() {
        _notice.value = null
    }

    /**
     * 两个标记的作用域不同（服务端口径）：收藏落在**整个条目**上，「已看」跟着当前播放单元——
     * 电影是整条，剧集是选中的那一集。剧集一旦按单集取过「已看」，就不让整剧的结果覆盖它。
     */
    private var playedIsUnitScoped = false
    private var unitPlayedJob: kotlinx.coroutines.Job? = null

    fun loadMarks(mediaItemId: Long) {
        if (readOnly.value) return
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            // 查不到收藏态不影响浏览，心按未收藏渲染即可
            runCatching {
                apiFactory.forOrigin(origin).playbackMarks(mediaItemId).dataOrThrow()
            }.onSuccess { m -> _marks.update { s -> m.copy(played = if (playedIsUnitScoped) s.played else m.played) } }
        }
    }

    /** 剧集换了选中的集：「已看」按这一集重新取（电影 0/0 用整条的结果，不用单取） */
    fun loadUnitPlayed(mediaItemId: Long, seasonNumber: Int, episodeNumber: Int) {
        if (seasonNumber <= 0 && episodeNumber <= 0) return
        playedIsUnitScoped = true
        unitPlayedJob?.cancel()   // 快速切集时，晚到的旧集结果不能盖掉新集
        unitPlayedJob = viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin)
                    .playbackMarks(mediaItemId, seasonNumber, episodeNumber)
                    .dataOrThrow()
            }.onSuccess { m -> _marks.update { it.copy(played = m.played) } }
        }
    }

    fun toggleFavorite(mediaItemId: Long) {
        val next = !_marks.value.isFavorite
        _marks.update { it.copy(isFavorite = next) }
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin)
                    .setPlaybackMarks(PlaybackMarksRequest(mediaItemId = mediaItemId, favorite = next))
                    .dataOrThrow()
            }.onSuccess { m ->
                // 只取收藏：这次查的是整个条目，它的「已看」不是剧集当前那一集的
                _marks.update { it.copy(isFavorite = m.isFavorite) }
                // 收藏变了：首页「我的收藏」行与收藏墙立刻重拉（否则那两处还是进页时的快照）
                io.movieclaw.android.core.model.LibraryMarksBus.bump()
            }
                .onFailure {
                    _marks.update { s -> s.copy(isFavorite = !next) }
                    _notice.value = McNotice(friendlyMessage(it), FeedbackTone.Error)
                }
        }
    }

    /** 标记当前播放单元已看 / 未看（电影，或剧集当前那一集）。 */
    fun togglePlayed(mediaItemId: Long, seasonNumber: Int?, episodeNumber: Int?) {
        val next = !_marks.value.played
        _marks.update { it.copy(played = next) }
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin)
                    .setPlaybackMarks(
                        PlaybackMarksRequest(
                            mediaItemId = mediaItemId,
                            seasonNumber = seasonNumber,
                            episodeNumber = episodeNumber,
                            played = next,
                        )
                    )
                    .dataOrThrow()
            }.onSuccess {
                // 标已看会清零续播位置、取消会清零播放次数——结论以服务端为准，写完重查。
                // 只取「已看」：剧集这里查的是单集，单集上没有收藏（收藏在整剧上），整份覆盖会把心清掉
                runCatching {
                    apiFactory.forOrigin(origin).playbackMarks(
                        mediaItemId = mediaItemId,
                        seasonNumber = seasonNumber,
                        episodeNumber = episodeNumber,
                    ).dataOrThrow()
                }.onSuccess { fresh -> _marks.update { it.copy(played = fresh.played) } }
                // 「已看」会影响首页的「接下来继续」与各行的进度，一起让首页重拉
                io.movieclaw.android.core.model.LibraryMarksBus.bump()
            }.onFailure {
                _marks.update { s -> s.copy(played = !next) }
                _notice.value = McNotice(friendlyMessage(it), FeedbackTone.Error)
            }
        }
    }

    /* ---------------- 文件区动作（iOS `LibraryItemDetailView` 的 delete/restore/purge） ---------------- */

    /**
     * 从磁盘删除一个文件（回收站语义由服务端定）。
     * 返回结果交给调用方：`errors` 为空 + 「这是最后一个文件」= 整条目已删，要离开详情页。
     */
    suspend fun deleteFile(
        fileId: Long,
        options: String? = null,
    ): Result<io.movieclaw.android.core.model.ItemDeleteResultView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).deleteLibraryFile(libraryId, itemId, fileId, options).dataOrThrow()
        }.onSuccess { io.movieclaw.android.core.model.LibraryMarksBus.bump() }
    }

    /** 删除前预览（附加选项）；取不到不挡删除，只是这次没有附加选项 */
    suspend fun deletePreview(fileId: Long): Result<io.movieclaw.android.core.model.ItemDeletePreviewView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).deletePreview(libraryId, itemId, fileId).dataOrThrow()
        }
    }

    /** 后续任务的当前状态 */
    suspend fun job(jobId: String): Result<io.movieclaw.android.core.model.JobView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { apiFactory.forOrigin(origin).job(jobId).dataOrThrow() }
    }

    /** 把待回收的文件恢复为在位版本 */
    suspend fun restoreFile(fileId: Long): Result<Unit> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).restoreLibraryFile(libraryId, itemId, fileId).dataOrThrow()
        }.map { io.movieclaw.android.core.model.LibraryMarksBus.bump() }
    }

    /** 立即清理一个待回收的文件（真删磁盘，不等保留期） */
    suspend fun purgeFile(fileId: Long): Result<Unit> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).purgeLibraryFile(libraryId, itemId, fileId).dataOrThrow()
        }.map { io.movieclaw.android.core.model.LibraryMarksBus.bump() }
    }

    /* ---------------- 「⋯」菜单的动作（iOS `LibraryItemDetailView.actionsMenu` 的同款动作） ---------------- */

    /**
     * 库本身（不是条目）。⋯ 菜单要用它的两处：
     * `capabilities.scraped`（决定刮削类动作摆不摆）与 `extract_chapter_images`（决定「重新生成章节」）。
     */
    private val _library = MutableStateFlow<io.movieclaw.android.core.model.LibraryView?>(null)
    val library = _library.asStateFlow()

    fun loadLibrary() {
        if (_library.value != null) return
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).library(libraryId).dataOrThrow() }
                .onSuccess { _library.value = it }
        }
    }

    /** 删除整个条目（⋯ 菜单的「删除影片」）：目录连 NFO/海报/字幕一起清掉 */
    suspend fun deleteItem(): Result<io.movieclaw.android.core.model.ItemDeleteResultView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).deleteLibraryItem(libraryId, itemId).dataOrThrow()
        }.onSuccess { io.movieclaw.android.core.model.LibraryMarksBus.bump() }
    }

    /** 刷新元数据（后台作业，202）：受理成功界面自己进「正在刷新」态（服务端 `scraping` 也会置位） */
    suspend fun refreshMetadata(): Result<io.movieclaw.android.core.model.ItemJobView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { apiFactory.forOrigin(origin).refreshItemMetadata(libraryId, itemId).dataOrThrow() }
    }

    /** 重新生成章节图（后台作业） */
    suspend fun regenerateChapters(): Result<io.movieclaw.android.core.model.ItemJobView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { apiFactory.forOrigin(origin).regenerateItemChapters(libraryId, itemId).dataOrThrow() }
    }

    /** 重新识别预览（打开面板时重走一遍识别链，只读不落库） */
    suspend fun reidentifyPreview(): Result<io.movieclaw.android.core.model.ReidentifyPreviewView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { apiFactory.forOrigin(origin).reidentifyPreview(libraryId, itemId).dataOrThrow() }
    }

    /** 把一组文件改挂到某部作品（走识别链的认领接口，会记为人工身份） */
    suspend fun assignFilesToTitle(
        fileIds: List<Long>,
        titleRef: String,
    ): Result<Unit> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).assignFilesToTitle(
                io.movieclaw.android.core.model.ClaimBatchPayload(fileIds = fileIds, titleRef = titleRef),
            ).dataOrThrow()
        }.map { io.movieclaw.android.core.model.LibraryMarksBus.bump() }
    }

    /** 标为非独立作品（花絮/预告类，不动磁盘） */
    suspend fun markFilesAsExtras(fileIds: List<Long>): Result<Unit> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).markFilesAsExtras(
                io.movieclaw.android.core.model.DetachPayload(fileIds = fileIds),
            ).dataOrThrow()
        }.map { io.movieclaw.android.core.model.LibraryMarksBus.bump() }
    }

    /** 面板里「自己搜…」用：按片名搜上游条目（不写搜索历史） */
    suspend fun searchTitlesForReidentify(query: String): Result<List<io.movieclaw.android.core.model.DiscoveredTitle>> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin)
                .searchTitles(
                    io.movieclaw.android.core.model.TitleSearchRequest(
                        query = query,
                        saveHistory = false,
                    )
                )
                .dataOrThrow()
                .titles
        }
    }

    /** 换图候选 */
    suspend fun artworkCandidates(): Result<io.movieclaw.android.core.model.ArtworkCandidatesView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { apiFactory.forOrigin(origin).artworkCandidates(libraryId, itemId).dataOrThrow() }
    }

    /** 选定一张图（`filePath = null` = 恢复自动选图）；选完详情页要重拉（海报/背景换了） */
    suspend fun selectArtwork(kind: String, filePath: String?): Result<Unit> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).selectArtwork(
                libraryId,
                itemId,
                io.movieclaw.android.core.model.ArtworkSelectPayload(kind = kind, filePath = filePath),
            ).dataOrThrow()
        }
    }

    /** 转移预览（只读） */
    suspend fun transferPreview(targetLibraryId: Long): Result<io.movieclaw.android.core.model.TransferPreviewView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).transferPreview(libraryId, itemId, targetLibraryId).dataOrThrow()
        }
    }

    /** 提交转移（后台作业） */
    suspend fun startTransfer(targetLibraryId: Long): Result<Unit> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).transferItem(
                libraryId,
                itemId,
                io.movieclaw.android.core.model.TransferPayload(targetLibraryId),
            ).dataOrThrow()
        }
    }

    /** 转移状态（源库一份） */
    suspend fun transferStatus(): Result<io.movieclaw.android.core.model.TransferStatusView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { apiFactory.forOrigin(origin).transferStatus(libraryId).dataOrThrow() }
    }

    /** 清除本条目的观看记录；返回服务端给的结论文案（信封 message） */
    suspend fun clearHistory(): Result<String> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            val env = apiFactory.forOrigin(origin).clearPlaybackHistory(scope = "item", mediaItemId = itemId)
            env.dataOrThrow()
            env.message
        }.onSuccess { io.movieclaw.android.core.model.LibraryMarksBus.bump() }
    }

    /** 可加入的合集（名单驱动 + 自己能动的；面板再按这个二次过滤） */
    suspend fun collectionsForPicker(): Result<List<io.movieclaw.android.core.model.CollectionView>> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).collections(libraryId = libraryId, includeEmpty = true).dataOrThrow()
        }
    }

    suspend fun addToCollection(collectionId: Long): Result<io.movieclaw.android.core.model.CollectionView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).collectionAddItems(
                collectionId,
                io.movieclaw.android.core.model.CollectionItemsPayload(mediaItemIds = listOf(itemId)),
            ).dataOrThrow()
        }
    }

    /** 新建手动合集并把这一个条目放进去（一次请求，同 iOS） */
    suspend fun createCollectionAndAdd(name: String): Result<io.movieclaw.android.core.model.CollectionView> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).createCollection(
                io.movieclaw.android.core.model.CollectionPayload(
                    name = name,
                    libraryId = libraryId,
                    itemIds = listOf(itemId),
                )
            ).dataOrThrow()
        }
    }

    /**
     * 当前有效分享；null = 还没分享过。
     * 服务端这里 `data` 可以为 null（信封仍 success），**不能走 dataOrThrow**。
     */
    suspend fun existingShare(): Result<io.movieclaw.android.core.model.ShareView?> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            val env = apiFactory.forOrigin(origin).libraryItemShare(libraryId, itemId)
            if (!env.success) {
                throw io.movieclaw.android.core.network.ApiException(
                    code = env.code.ifEmpty { "FAILED" },
                    message = env.message.ifEmpty { "请求失败" },
                )
            }
            env.data
        }
    }

    /** 生成分享链接；第二个值 = 服务端说「已有一条有效分享」（`SHARE_EXISTS`） */
    suspend fun createShare(
        days: Int,
        password: String?,
    ): Result<Pair<io.movieclaw.android.core.model.ShareView, Boolean>> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            val env = apiFactory.forOrigin(origin).createLibraryItemShare(
                libraryId,
                itemId,
                io.movieclaw.android.core.model.ShareCreateRequest(expiresInDays = days, password = password),
            )
            env.dataOrThrow() to (env.code == "SHARE_EXISTS")
        }
    }

    suspend fun revokeShare(): Result<Unit> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { apiFactory.forOrigin(origin).revokeLibraryItemShare(libraryId, itemId).dataOrThrow() }
            .map { }
    }

    /** 「洗版…」按条目类型找现成的订阅（找到就把订阅详情页跑一轮洗版） */
    suspend fun subscriptionsOfKind(kind: String): Result<List<io.movieclaw.android.core.model.SubscriptionView>> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { apiFactory.forOrigin(origin).subscriptions(kind = kind).dataOrThrow() }
    }

    /** 「转移到其他库…」的目标库候选（同类型、可见的库；面板再排掉本库） */
    suspend fun librariesForTransfer(): Result<List<io.movieclaw.android.core.model.LibraryView>> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching { apiFactory.forOrigin(origin).libraries().dataOrThrow() }
    }
}

@Composable
fun ItemDetailScreen(
    libraryId: Long,
    itemId: Long,
    onBack: () -> Unit,
    onPlay: (PlayTarget) -> Unit,
    /** 演职员点进「库内影人页」（iOS `LibraryItemDetailView` 的 `AppRoute.person` 同款） */
    onOpenPerson: (Int) -> Unit = {},
    /** 文件区「处理重复」→ 媒体库管理的「重复文件」页签（iOS `.libraryManage(tab: "duplicates")`） */
    onOpenDuplicates: () -> Unit = {},
    /** 「去接入」→ 设置里的「模型接入」（iOS `.settingsSection(.llm)`） */
    onOpenLlmSettings: () -> Unit = {},
    /** 「交给 Agent 处理」建好会话后跳会话页 */
    onOpenAgentSession: (String) -> Unit = {},
    /** 相似推荐 / 系列里库内有的那部 → 它的库内详情（库 id, 条目 id） */
    onOpenItem: (Long, Long) -> Unit = { _, _ -> },
    /** 系列里缺的那部 → 发现页的 TMDB 详情（title_ref 形如 tmdb:movie:123），在那里订阅 */
    onOpenTitle: (String) -> Unit = {},
    /** ⋯ 菜单「搜索资源」：带片名与类型进搜索页（iOS `SearchScope.ofMediaKind` 同口径） */
    onSearch: (String, String?) -> Unit = { _, _ -> },
    /** ⋯ 菜单「洗版…」已有订阅时：去订阅详情页跑一轮洗版（iOS `.subscription(id:upgradeRun: true)`） */
    onOpenSubscription: (Long, Boolean) -> Unit = { _, _ -> },
    /** ⋯ 菜单「洗版…」没有订阅时：打开订阅弹层（title_ref 形如 tmdb:movie:123） */
    onSubscribe: (String) -> Unit = {},
    /** 「转移到其他库」完成后「去目标库查看」（iOS `goToTarget`） */
    onOpenLibrary: (Long) -> Unit = {},
    /** 播放本机副本（离线下载的文件在「文件」区点播放时走这里） */
    onPlayLocal: ((mediaItemId: Long, fileId: Long) -> Unit)? = null,
    vm: ItemDetailViewModel = hiltViewModel(),
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val related by vm.related.collectAsStateWithLifecycle()
    val selectedSeason by vm.selectedSeason.collectAsStateWithLifecycle()
    /** 选中的单元（季 + 集）：播放键、续播点、已看、版本都以它为准（iOS SelectedEpisode） */
    val selectedUnit by vm.selectedEpisode.collectAsStateWithLifecycle()
    val marks by vm.marks.collectAsStateWithLifecycle()
    val resume by vm.resume.collectAsStateWithLifecycle()
    val origin = vm.origin
    val feedback = LocalFeedback.current
    val permissions = io.movieclaw.android.core.session.LocalPermissions.current
    // 离线下载（docs/design/offline-download.md）：本机目录随下载进度刷新；页面只读派生值，进度刷新不重建整页
    val offlineState by vm.offline.state.collectAsStateWithLifecycle()
    val offlineSpeeds by vm.offline.speeds.collectAsStateWithLifecycle()
    val doneFileIds by vm.offline.doneFileIds.collectAsStateWithLifecycle()
    val activeByItem by vm.offline.activeByItem.collectAsStateWithLifecycle()
    /** 下载顺序（§5.5）：只在开始 / 完成 / 调顺序 / 状态变化时变，开着的菜单不随进度重建 */
    val offlineQueue by vm.offline.queue.collectAsStateWithLifecycle()
    val waitingForWiFi by vm.downloader.waitingForWiFi.collectAsStateWithLifecycle()
    val downloadedItemIds by vm.offline.downloadedItemIds.collectAsStateWithLifecycle()
    val readOnly by vm.readOnly.collectAsStateWithLifecycle()
    val goneOnServer by vm.goneOnServer.collectAsStateWithLifecycle()
    val minimal by vm.minimal.collectAsStateWithLifecycle()
    val closeRequest by vm.closeRequest.collectAsStateWithLifecycle()
    LaunchedEffect(closeRequest) { if (closeRequest) onBack() }
    val readyItem = (state as? Loadable.Ready)?.value?.item
    // 选档面板：电影 / 单集 = 单文件；剧集 = 按范围
    var downloadSheet by remember { mutableStateOf<DownloadSheetTarget?>(null) }
    /** 「取消全部下载」的二次确认（iOS `confirmCancelDownloads`） */
    var cancelAllConfirm by remember { mutableStateOf(false) }
    ItemDownloadHost(
        detail = readyItem,
        episodes = (state as? Loadable.Ready)?.value?.episodes.orEmpty(),
        selected = selectedUnit,
        target = downloadSheet,
        onDismiss = { downloadSheet = null },
    )
    if (cancelAllConfirm) {
        val active = activeByItem[itemId].orEmpty()
        io.movieclaw.android.feature.offline.OfflineConfirmDialog(
            title = "取消这部剧正在进行的下载？",
            message = "已下完的集会保留。",
            action = "取消 ${active.size} 集的下载",
            onDismiss = { cancelAllConfirm = false },
            onConfirm = { active.forEach { vm.downloader.delete(it.fileId) } },
        )
    }

    // 文件区动作：删除走底部确认单（iOS `DeleteFileSheet`），立即清理走确认弹窗
    var trashTarget by remember { mutableStateOf<io.movieclaw.android.core.model.LibraryFileView?>(null) }
    var purgeTarget by remember { mutableStateOf<io.movieclaw.android.core.model.LibraryFileView?>(null) }
    // ⋯ 菜单（iOS `actionsMenu`）：菜单开关、点下的动作、两个确认框、本地「正在刷新」态
    var menuOpen by remember { mutableStateOf(false) }
    // 播出日历（issue #547）的底部面板与「补缺集」进行中
    var airSheet by remember { mutableStateOf(false) }
    var airSearching by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf<ItemActionId?>(null) }
    var refreshConfirm by remember { mutableStateOf(false) }
    var clearConfirm by remember { mutableStateOf(false) }
    /** 点下到服务端 `scraping` 置位之间挡住重复点击（iOS 的本地 `kicking`） */
    var kicking by remember { mutableStateOf(false) }
    val library by vm.library.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    // ── AI 字幕生成：状态 / 能力探测 / 任务跟踪 / 交付回调（iOS `TrackGenModel` 同款）──
    val subtitleGen by vm.subtitleGen.collectAsStateWithLifecycle()
    // 生成完成后重拉详情，新的 AI 字幕立刻出现在字幕清单里
    DisposableEffect(vm) {
        vm.onSubtitleChanged = { vm.load() }
        onDispose { vm.onSubtitleChanged = null }
    }
    // 「交给 Agent 处理」建好会话 → 跳会话页（一次性）
    val agentHandoff by vm.agentHandoff.collectAsStateWithLifecycle()
    LaunchedEffect(agentHandoff) {
        agentHandoff?.let {
            vm.consumeAgentHandoff()
            onOpenAgentSession(it)
        }
    }

    // 播放回来 / 回到前台：静默重拉分集，锚点变了就把选中与集段锁到新锚点（长剧分段 §3）
    androidx.lifecycle.compose.LifecycleEventEffect(androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
        vm.refreshEpisodes()
    }

    // 只在换条目时拉一次标记（marks 自身变化不能再触发，否则死循环）
    val loadedItemId = (state as? Loadable.Ready)?.value?.item?.mediaItemId
    LaunchedEffect(loadedItemId) {
        loadedItemId?.let { vm.loadMarks(it) }
    }
    LaunchedEffect(vm) {
        vm.notice.collect { notice ->
            if (notice != null) {
                feedback.show(notice)
                vm.consumeNotice()
            }
        }
    }

    when (val s = state) {
        Loadable.Loading -> Box(Modifier.fillMaxSize().background(Bg), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = TextMuted)
        }
        is Loadable.Failed -> if (minimal && (readOnly || offlineState.items[itemId] != null)) {
            // 本机存的详情读不出来（旧版存档、还没联网刷新）：退回只靠摘要的极简详情
            io.movieclaw.android.feature.offline.OfflineMinimalDetail(itemId = itemId, origin = origin, onBack = onBack, onPlay = onPlay)
        } else {
            ErrorPane(message = s.message, onRetry = vm::load)
        }
        is Loadable.Ready -> {
        // 沉浸式：页面底色 = 剧照的主色（iOS HeroEdgeColor / 网页 .detail-ambient；
        // 与首页英雄同源 → 同一个取色缓存键，从封面点进来零等待）。取色是异步的，
        // 底色淡入而不是从黑跳变（iOS heroEdgeBackground 也是 0.5s 渐显）
        val rawTint = io.movieclaw.android.core.discovery.rememberAmbientColor(
            s.value.item.backdropUrl ?: s.value.item.posterUrl,
            origin,
            // 详情页口径：**底边色带**（iOS HeroEdgeColor：饱和 ×1.1、亮度 ≤0.34）——
            // 比「整图主色」更暗更像页面底色（AmbientColorLoader 里详情页就是这么分的）
            bottomBand = true,
            // 无 fanart 的条目服务端对 kind=fanart 返回 404 → 退到海报再取
            fallbackUrl = s.value.item.posterUrl,
        )
        val detailTint by androidx.compose.animation.animateColorAsState(
            targetValue = rawTint ?: Bg,
            animationSpec = androidx.compose.animation.core.tween(420),
            label = "detail-tint",
        )
        // 把当前剧照/底色发布给外壳：宽窗口时外壳在最底层铺一张**全屏**剧照，
        // 半透明侧边栏透出它（iOS `PadBackdropUnderSidebar` 的等价物）。离开本页清空。
        val setShellBackdrop = io.movieclaw.android.routing.LocalShellBackdropSetter.current
        val shellBackdropUrl = s.value.item.backdropUrl ?: s.value.item.posterUrl
        // heroHeight() 是 @Composable（读 LocalConfiguration），必须在组合里取，不能进 effect 里
        val shellHeroHeight = heroHeight()
        androidx.compose.runtime.LaunchedEffect(shellBackdropUrl, origin, detailTint, shellHeroHeight) {
            setShellBackdrop(
                io.movieclaw.android.routing.ShellBackdrop(shellBackdropUrl, origin, detailTint),
            )
        }
        androidx.compose.runtime.DisposableEffect(Unit) {
            onDispose { setShellBackdrop(null) }
        }
        Column(
            Modifier
                .fillMaxSize()
                // 整页铺不透明底色：**宽屏也铺**。之前这里在宽屏返回 Transparent，
                // 结果外壳那层全屏剧照从 hero 以下透出来（下半屏又出现一张图、沉浸式底色没了）。
                .background(detailTint)
                .verticalScroll(rememberScrollState()),
        ) {
            Hero(
                detail = s.value.item,
                origin = origin,
                tint = detailTint,
                onBack = onBack,
                onPlay = onPlay,
                libraryId = libraryId,
                episodes = s.value.episodes,
                marks = marks,
                resume = resume,
                unit = selectedUnit,
                onResumeUnitChanged = { season, episode ->
                    vm.loadResume(s.value.item.mediaItemId, season, episode)
                    vm.loadUnitPlayed(s.value.item.mediaItemId, season, episode)
                },
                onToggleFavorite = { vm.toggleFavorite(s.value.item.mediaItemId) },
                onTogglePlayed = { season, episode ->
                    vm.togglePlayed(s.value.item.mediaItemId, season, episode)
                },
                downloadStatus = {
                    // 电影的下载状态条（在播放键上方）：没下完时才出现（开始下载在右上角「⋯」）；剧集的进度画在分集卡上
                    if (s.value.item.kind != "tv") {
                        io.movieclaw.android.feature.offline.OfflineDownloadControl(
                            s.value.item.mediaItemId, 0, 0,
                            onChangeQuality = if (!readOnly && permissions.canDownloadVideo) ({ fileId ->
                                downloadSheet = DownloadSheetTarget.File(fileId, s.value.item.title)
                            }) else null,
                        )
                    }
                    if (goneOnServer) {
                        Text("服务器上已没有这个条目，下面是${io.movieclaw.android.feature.offline.deviceName()}上的副本，仍可播放与删除。", style = McType.footnote, color = io.movieclaw.android.core.designsystem.Warning)
                    }
                },
                readOnly = readOnly,
                // AI 字幕生成：状态 + 动作集（Hero 拿不到 VM，与其它回调同一个路子）
                subtitleGen = subtitleGen,
                isAdmin = permissions.isAdmin,
                subtitleGenActions = SubtitleGenActions(
                    onEntryClick = { id -> vm.openSubtitleGen(id, onNeedLlmSettings = onOpenLlmSettings) },
                    onTrack = { id -> vm.checkLlmGate(); vm.trackSubtitleJob(id) },
                    onDismiss = { vm.closeSubtitleGen() },
                    onTargetLanguage = { id, token -> vm.setTargetLanguage(id, token) },
                    onSecondaryLanguage = { id, token -> vm.setSecondaryLanguage(id, token) },
                    onBilingual = { id, on -> vm.setBilingual(id, on) },
                    onSourceKey = { id, ref -> vm.setSourceKey(id, ref) },
                    onPgsLanguage = { vm.setPgsOcrLanguage(it) },
                    onConfirm = { id -> vm.confirmSubtitleGen(id) },
                    onRetryPreview = { id -> vm.retrySubtitlePreview(id) },
                    onCancelJob = { vm.cancelSubtitleJob() },
                    onHandOffToAgent = { id -> vm.handOffSubtitleGenToAgent(id) },
                ),
                trailingActions = {
                    // 刮削中：按钮右上角点一颗蓝点（iOS `actionsMenu` 的蓝点同款）；只读时没有管理菜单
                    if (!readOnly) ItemActionsButton(scraping = s.value.item.scraping || kicking) { menuOpen = !menuOpen }
                },
            ) {
                // 网页正文顺序：分集区 → 章节 → **演职员** → 文件区
                if (s.value.item.kind == "tv" && s.value.episodes.isNotEmpty()) {
                    SeasonSection(
                        seasons = s.value.item.seasons,
                        // 库里实有的季（台账文件的季号集合）：季选择器里给没有的季标「未入库」，
                        // 与网页/iOS 同口径——元数据的季和实有的季混在一起，不标出来会以为本地存了那么多季
                        ownedSeasons = s.value.item.files.map { it.seasonNumber }.toSet(),
                        selected = selectedSeason,
                        episodes = s.value.episodes,
                        onSelect = vm::selectSeason,
                        // 分集横滚的选中与滚动定位跟着「选中单元」走（受控，不再各存一份）
                        selectedEpisode = selectedUnit?.takeIf { it.season == selectedSeason }?.episode,
                        onPickEpisode = { ep -> vm.selectEpisode(selectedSeason ?: 0, ep) },
                        anchor = s.value.anchors[selectedSeason],
                        onPickRange = { range -> vm.selectRange(selectedSeason ?: 0, range) },
                        origin = origin,
                        onPlay = onPlay,
                        libraryId = libraryId,
                        itemId = itemId,
                        itemTitle = s.value.item.title,
                        schedule = selectedSeason?.let { s.value.schedules[it] },
                        onOpenSchedule = { airSheet = true },
                        // 分集卡的下载状态（iOS `OfflineDownloadStrip` / 绿箭头「已下载」）与长按菜单
                        offline = EpisodeOffline(
                            unitOf = { season, episode -> vm.offline.unit(s.value.item.mediaItemId, season, episode, offlineState) },
                            speeds = offlineSpeeds,
                            queue = offlineQueue,
                            waitingForWiFi = waitingForWiFi,
                            onPrioritize = { vm.downloader.prioritize(listOf(it)) },
                            canDownload = permissions.canDownloadVideo && offlineState.serverSupported && !readOnly,
                            onDownload = { season, episode, fileId ->
                                downloadSheet = DownloadSheetTarget.File(fileId, "${s.value.item.title} 第 $season 季第 $episode 集")
                            },
                            onPause = { vm.downloader.pause(it) },
                            onResume = { vm.downloader.resume(it) },
                            onDelete = { vm.downloader.delete(it) },
                        ),
                    )
                }
                CastSection(detail = s.value.item, origin = origin, onOpenPerson = onOpenPerson)
                // 演职员 → 相似推荐 → 系列（iOS / Apple TV / Mac / Web 同一个顺序）；只读时不显示
                if (!readOnly) SimilarSection(items = related.similar, libraryId = libraryId, origin = origin, onOpenItem = onOpenItem)
                related.series?.takeIf { !readOnly }?.let { series ->
                    SeriesSection(
                        series = series,
                        libraryId = libraryId,
                        itemId = itemId,
                        origin = origin,
                        onOpenItem = onOpenItem,
                        onOpenTitle = onOpenTitle,
                    )
                }
                // 文件区（iOS `isMovie ? detail.files : selectedEpisode.files`）：
                // 电影 = 整条的文件；剧集 = 当前选中那一集的文件（没选中就不显示这一区）
                val sectionFiles = sectionFilesFor(s.value.item, selectedUnit, s.value.episodes)
                if (sectionFiles.isNotEmpty()) {
                    FilesSection(
                        detail = s.value.item,
                        files = sectionFiles,
                        // 本机下完的副本（iOS `localIds`）：排在最前，标「本机」；展开、删除、长按改下其他画质
                        localUnits = sectionFiles.map { it.id }.filter { it in doneFileIds }.mapNotNull { offlineState.units[it] },
                        localTitle = if (s.value.item.kind == "tv") selectedUnit?.let { "${s.value.item.title} 第 ${it.season} 季第 ${it.episode} 集" } ?: s.value.item.title else s.value.item.title,
                        canChangeQuality = !readOnly && permissions.canDownloadVideo,
                        onChangeQuality = { fileId, title -> downloadSheet = DownloadSheetTarget.File(fileId, title) },
                        canManage = permissions.canManageLibraries && !readOnly,
                        onOpenDuplicates = onOpenDuplicates,
                        onTrash = { trashTarget = it },
                        onRestore = { file ->
                            scope.launch {
                                vm.restoreFile(file.id)
                                    .onSuccess {
                                        feedback.show(McNotice("「${file.fileName}」已恢复为在位版本", FeedbackTone.Success))
                                        vm.load()
                                    }
                                    .onFailure { feedback.show(McNotice(friendlyMessage(it), FeedbackTone.Error)) }
                            }
                        },
                        onPurge = { purgeTarget = it },
                        onCopyPath = { file ->
                            val path = file.filePath.orEmpty()
                            if (path.isNotEmpty()) {
                                val clipboard = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                                clipboard.setPrimaryClip(android.content.ClipData.newPlainText("path", path))
                                feedback.show(McNotice("已拷贝路径", FeedbackTone.Success))
                            }
                        },
                    )
                }
                ExternalLinks(s.value.item)
                Spacer(Modifier.height(32.dp))
            }
        }
        }
    }

    // 文件区动作的宿主：删除底部单（iOS `DeleteFileSheet`）与立即清理确认弹窗。
    // 放在 when 之外——两者都是窗口级浮层，不该跟着页面一起滚
    val readyDetail = (state as? Loadable.Ready)?.value?.item
    val airReady = (state as? Loadable.Ready)?.value
    val airSchedule = selectedSeason?.let { airReady?.schedules?.get(it) }
    if (airSheet && airReady != null && airSchedule != null) {
        val season = selectedSeason ?: 0
        val tmdb = airReady.item.tmdbId ?: 0L
        AirScheduleSheet(
            title = airReady.item.title,
            seasonLabel = if (season == 0) "特别篇" else "第 $season 季",
            episodes = airReady.episodes[season].orEmpty(),
            schedule = airSchedule,
            canSubscribe = permissions.canSubscribe,
            searching = airSearching,
            onFindMissing = {
                val id = airSchedule.subscriptionId ?: return@AirScheduleSheet
                airSearching = true
                scope.launch {
                    vm.searchMissing(id)
                        .onSuccess { feedback.show(it, FeedbackTone.Success) }
                        .onFailure { feedback.show(friendlyMessage(it), FeedbackTone.Error) }
                    airSearching = false
                }
            },
            onSubscribe = if (permissions.canSubscribe && tmdb > 0) {
                { airSheet = false; onSubscribe("tmdb:tv:$tmdb") }
            } else {
                null
            },
            onDismiss = { airSheet = false },
        )
    }
    trashTarget?.let { file ->
        if (readyDetail != null) {
            DeleteFileSheet(
                detail = readyDetail,
                file = file,
                isLast = readyDetail.files.size == 1,
                onDismiss = { trashTarget = null },
                run = { options -> vm.deleteFile(file.id, options) },
                loadOptions = { vm.deletePreview(file.id) },
                loadJob = { jobId -> vm.job(jobId) },
                onFinished = { deletedItem ->
                    trashTarget = null
                    // 最后一个文件删成功 = 整条目已删：离开详情页（iOS `onItemDeleted: leaveToLibrary`）
                    if (deletedItem) onBack() else vm.load()
                },
            )
        }
    }
    purgeTarget?.let { file ->
        PurgeFileDialog(
            file = file,
            onDismiss = { purgeTarget = null },
            onConfirm = {
                purgeTarget = null
                scope.launch {
                    vm.purgeFile(file.id)
                        .onSuccess {
                            feedback.show(McNotice("「${file.fileName}」已清理", FeedbackTone.Success))
                            vm.load()
                        }
                        .onFailure { feedback.show(McNotice(friendlyMessage(it), FeedbackTone.Error)) }
                }
            },
        )
    }

    /* ---------------- ⋯ 菜单的动作（iOS `actionsMenu` 的 switch） ---------------- */

    // 库能力（capabilities.scraped / extract_chapter_images）跟着条目一起要
    LaunchedEffect(readyDetail?.mediaItemId) {
        if (readyDetail != null) vm.loadLibrary()
    }
    // 菜单本体独立成一层（Popup）：11 行比 hero 高，摆在 hero 里会被正文盖住。
    // 一直组合、只切 visible——收起时 Popup 多留 150ms 播完缩回动画。
    if (readyDetail != null) {
        ItemActionsMenuPopup(
            visible = menuOpen,
            entries = itemMenuEntries(
                detail = readyDetail,
                library = library,
                permissions = permissions,
                scraping = readyDetail.scraping || kicking,
                // 电影已在本机（下着或下完）就不再给「下载」：状态条上管（iOS `movieLocal`）；
                // 只读派生值（开始 / 完成 / 删除时才变），下载进度刷新不重建开着的菜单
                canDownload = permissions.canDownloadVideo && offlineState.serverSupported && (
                    if (readyDetail.kind == "tv") true
                    else activeByItem[readyDetail.mediaItemId].isNullOrEmpty() && readyDetail.mediaItemId !in downloadedItemIds &&
                        readyDetail.files.any { !it.missing }
                    ),
                activeDownloads = activeByItem[readyDetail.mediaItemId].orEmpty().size,
                activeSelected = readyDetail.kind == "tv" && selectedUnit?.let { sel ->
                    activeByItem[readyDetail.mediaItemId].orEmpty().any { it.season == sel.season && it.episode == sel.episode }
                } == true,
                canPrioritizeShow = OfflineQueue.canPrioritizeItem(readyDetail.mediaItemId, offlineQueue),
            ),
            onPick = { id ->
                menuOpen = false
                picking = id
            },
            onDismiss = { menuOpen = false },
        )
    }
    picking?.let { action ->
        if (readyDetail != null) {
            when (action) {
                ItemActionId.DOWNLOAD -> {
                    picking = null
                    downloadSheet = if (readyDetail.kind == "tv") {
                        DownloadSheetTarget.Series
                    } else {
                        readyDetail.files.firstOrNull { !it.missing }?.let { DownloadSheetTarget.File(it.id, readyDetail.title) }
                    }
                }

                ItemActionId.CANCEL_DOWNLOADS -> {
                    picking = null
                    val active = activeByItem[readyDetail.mediaItemId].orEmpty()
                    // 电影：直接取消；剧集：确认后取消全部（已下完的保留）
                    if (readyDetail.kind == "tv") cancelAllConfirm = true else active.forEach { vm.downloader.delete(it.fileId) }
                }

                ItemActionId.PRIORITIZE_DOWNLOADS -> {
                    picking = null
                    vm.downloader.prioritizeItem(readyDetail.mediaItemId)
                }

                ItemActionId.CANCEL_SELECTED_DOWNLOAD -> {
                    picking = null
                    selectedUnit?.let { sel ->
                        activeByItem[readyDetail.mediaItemId].orEmpty().firstOrNull { it.season == sel.season && it.episode == sel.episode }
                            ?.let { vm.downloader.delete(it.fileId) }
                    }
                }

                ItemActionId.SEARCH -> {
                    picking = null
                    onSearch(
                        readyDetail.title,
                        readyDetail.kind.takeIf { it == "movie" || it == "tv" },
                    )
                }

                ItemActionId.ADD_TO_COLLECTION -> AddToCollectionSheet(
                    title = readyDetail.title,
                    onDismiss = { picking = null },
                    loadCollections = { vm.collectionsForPicker() },
                    addTo = { vm.addToCollection(it) },
                    createAndAdd = { vm.createCollectionAndAdd(it) },
                )

                ItemActionId.SHARE -> ItemShareSheet(
                    title = readyDetail.title,
                    origin = origin,
                    onDismiss = { picking = null },
                    loadShare = { vm.existingShare() },
                    createShare = { days, password -> vm.createShare(days, password) },
                    revokeShare = { vm.revokeShare() },
                )

                ItemActionId.UPGRADE -> {
                    // 洗版：已有订阅就去它那儿跑一轮（iOS `upgrade`）；没有就以洗版模式开订阅弹层
                    val subKind = if (readyDetail.kind == "tv") "tv" else "movie"
                    val tmdb = readyDetail.tmdbId ?: 0L
                    picking = null
                    // 组合提交后再启动（协程挂在外层 scope 上，分支随 picking=null 离开组合也不受影响）
                    androidx.compose.runtime.SideEffect {
                        scope.launch {
                            val existing = vm.subscriptionsOfKind(subKind).getOrDefault(emptyList())
                                .firstOrNull { it.media.tmdbId?.toLong() == tmdb }
                            if (existing != null) onOpenSubscription(existing.id, true)
                            else onSubscribe("tmdb:$subKind:$tmdb")
                        }
                    }
                }

                ItemActionId.REIDENTIFY -> ReidentifySheet(
                    onDismiss = { picking = null },
                    origin = origin,
                    loadPreview = { vm.reidentifyPreview() },
                    assign = { fileIds, titleRef -> vm.assignFilesToTitle(fileIds, titleRef) },
                    markExtras = { fileIds -> vm.markFilesAsExtras(fileIds) },
                    searchTitles = { query -> vm.searchTitlesForReidentify(query) },
                )

                ItemActionId.REFRESH_METADATA -> {
                    picking = null
                    refreshConfirm = true
                }

                ItemActionId.REGENERATE_CHAPTERS -> {
                    picking = null
                    androidx.compose.runtime.SideEffect {
                        scope.launch {
                            vm.regenerateChapters()
                                .onSuccess {
                                    feedback.show(McNotice("已开始重新生成章节", FeedbackTone.Success))
                                    vm.load()
                                }
                                .onFailure { feedback.show(McNotice(friendlyMessage(it), FeedbackTone.Error)) }
                        }
                    }
                }

                ItemActionId.ARTWORK -> ArtworkPickerSheet(
                    onDismiss = { picking = null },
                    origin = origin,
                    loadCandidates = { vm.artworkCandidates() },
                    select = { kind, filePath ->
                        vm.selectArtwork(kind, filePath).onSuccess { vm.load() }
                    },
                )

                ItemActionId.TRANSFER -> TransferItemSheet(
                    title = readyDetail.title,
                    kind = readyDetail.kind,
                    sourceLibraryId = libraryId,
                    // 候选口径同后端 `assert_transferable`：比的是**库**的来源
                    sourceOrigin = library?.source,
                    onDismiss = { picking = null },
                    loadCandidates = { vm.librariesForTransfer() },
                    loadPreview = { vm.transferPreview(it) },
                    run = { vm.startTransfer(it) },
                    pollStatus = { vm.transferStatus() },
                    onOpenLibrary = { id ->
                        picking = null
                        onOpenLibrary(id)
                    },
                )

                ItemActionId.DELETE_ITEM -> DeleteItemSheet(
                    detail = readyDetail,
                    onDismiss = { picking = null },
                    run = { vm.deleteItem() },
                    onDeleted = {
                        picking = null
                        // 整条删掉了：离开详情页（iOS `leaveToLibrary` 的等价物）
                        onBack()
                    },
                )

                ItemActionId.CLEAR_HISTORY -> {
                    picking = null
                    clearConfirm = true
                }
            }
        }
    }
    if (refreshConfirm && readyDetail != null) {
        RefreshMetadataDialog(
            detail = readyDetail,
            onDismiss = { refreshConfirm = false },
            onConfirm = {
                refreshConfirm = false
                scope.launch {
                    // iOS 的刷新：受理后原地重拉，1.5 秒后再拉一次（刮削结果通常这时才回来）
                    kicking = true
                    vm.refreshMetadata()
                        .onSuccess {
                            vm.load()
                            kotlinx.coroutines.delay(1500)
                            vm.load()
                        }
                        .onFailure { feedback.show(McNotice(friendlyMessage(it), FeedbackTone.Error)) }
                    kicking = false
                }
            },
        )
    }
    if (clearConfirm && readyDetail != null) {
        ClearHistoryDialog(
            title = readyDetail.title,
            onDismiss = { clearConfirm = false },
            onConfirm = {
                clearConfirm = false
                scope.launch {
                    vm.clearHistory()
                        .onSuccess { message ->
                            // 结论文案用服务端给的（iOS `feedback.success(message)` 同一句）
                            if (message.isNotBlank()) {
                                feedback.show(McNotice(message, FeedbackTone.Success))
                            }
                            vm.load()
                        }
                        .onFailure { feedback.show(McNotice(friendlyMessage(it), FeedbackTone.Error)) }
                }
            },
        )
    }
}

/**
 * 详情头部 —— 按移动端网页实测重做：
 *   · 整幅剧照（高 min(52vh,420)）+ 一道自下而上的压暗渐变压到纯黑，
 *     标题与简介就落在图片淡出的区域上（网页是「图让开」，不是「字压图」）；
 *   · 浮动导航（返回 / 搜索 / ⋯）36×36、内距 8；
 *   · 正文相对图片上提 124：标题 28/700 · 元信息 14/62%（· 分隔）·「音轨」「字幕」两行
 *     （40 宽淡色标签 + 玻璃胶囊值）· 琥珀提示胶囊 ·「播放」通栏 48 银白胶囊 ·
 *     两枚玻璃药丸（收藏 / 标为已看）· 剧情 16/1.85 ·「展开全文 ⌄」。
 */
@Composable
private fun Hero(
    detail: LibraryItemDetailView,
    origin: String?,
    /** 页面底色（剧照取色）：hero 底边淡成这个色，图与页面之间没有硬边 */
    tint: Color = Bg,
    onBack: () -> Unit,
    onPlay: (PlayTarget) -> Unit,
    libraryId: Long,
    episodes: Map<Int, List<EpisodeView>>,
    marks: PlaybackMarks,
    /** 续播点与记忆轨（`/playback/resume`）；null = 还没问到，按键先按「播放」渲染 */
    resume: PlaybackStateView?,
    /** 选中的单元（季 + 集）：播放键、续播点、已看、版本都跟着它（iOS SelectedEpisode） */
    unit: ItemDetailViewModel.SelectedUnit?,
    onResumeUnitChanged: (Int, Int) -> Unit,
    onToggleFavorite: () -> Unit,
    onTogglePlayed: (Int?, Int?) -> Unit,
    /** 下载状态条（iOS `OfflineDownloadControl`）：放在播放键上方；参数是当前单元（季, 集），电影 null */
    downloadStatus: @Composable (unit: Pair<Int, Int>?) -> Unit = {},
    /** 只读（离线、回落本机副本）：不给收藏、标记已看 */
    readOnly: Boolean = false,
    /** AI 字幕生成的状态与动作（同 iOS `TrackSubtitleGenButton`：仅管理员 + 文件在盘才出现） */
    subtitleGen: SubtitleGenUiState,
    isAdmin: Boolean,
    subtitleGenActions: SubtitleGenActions,
    /** 顶栏右侧的动作（详情页的「⋯」更多操作）：与返回键同一行、同一份玻璃 */
    trailingActions: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = {},
    /** hero 上的浮层（⋯ 面板挂在这里，跟随 hero 定位，不跟着正文滚） */
    heroOverlay: @Composable androidx.compose.foundation.layout.BoxScope.() -> Unit = {},
    /** 正文其余部分（分集 / 演职员 / 文件）：与简介同用那一块上提 124 的列 */
    content: @Composable ColumnScope.() -> Unit,
) {
    // 版本/文件、音轨源都跟着**选中的那一集**走（iOS `selectedEpisode.files`）：
    // 原来一律拿 `detail.files.firstOrNull()`（第 1 季第 1 个文件），选了季也对不上
    val unitFiles = remember(detail.mediaItemId, unit, episodes) {
        val ids = unit?.let { u -> episodes[u.season]?.firstOrNull { it.episodeNumber == u.episode }?.fileIds }
        detail.files.filter { f -> ids?.contains(f.id) == true }.ifEmpty { detail.files }
    }
    val file = unitFiles.firstOrNull()
    var expanded by remember { mutableStateOf(false) }
    // 「标为已看」与续播点都跟着选中的单元走：电影是整条（0/0），剧集是选中的那一集
    val playUnit = if (detail.kind == "tv") unit else null
    val resumeSeason = playUnit?.season ?: 0
    val resumeEpisode = playUnit?.episode ?: 0

    // 续播点与记忆轨：换单元要重新问（剧集从第 1 集切到第 3 集，续播点跟着变）
    LaunchedEffect(detail.mediaItemId, resumeSeason, resumeEpisode) {
        onResumeUnitChanged(resumeSeason, resumeEpisode)
    }

    /* ---------- 音轨 / 字幕的选择 ---------- */

    val audioOptions = remember(file?.id, file?.audioStreams) { trackOptions(file?.audioStreams.orEmpty(), false) }
    val subtitleOptions = remember(file?.id, file?.subtitleStreams) { trackOptions(file?.subtitleStreams.orEmpty(), true) }
    // 初始选中 = 服务端记忆的那条（本集记着的 > 沿用上一集 > 默认轨策略），用户点过就以用户为准
    var pickedAudio by remember(file?.id) { mutableStateOf<String?>(null) }
    var pickedSubtitle by remember(file?.id) { mutableStateOf<String?>(null) }
    // 初始选中：服务端算好的「起播会放哪条」（本集记着的 > 沿用同剧上一集 > 默认轨策略），
    // 用户点过就以用户为准。
    val defaults = file?.playbackDefaults
    val effectiveAudio = pickedAudio ?: defaults?.audioTrack?.takeIf { it.isNotBlank() }
        ?: audioOptions.firstOrNull { it.isDefault }?.ref ?: audioOptions.firstOrNull()?.ref
    val effectiveSubtitle = pickedSubtitle ?: defaults?.subtitleTrack?.takeIf { it.isNotBlank() }
        ?: resume?.subtitleTrack?.takeIf { it.isNotBlank() && it != "off" }
    var sheet by remember { mutableStateOf<String?>(null) }   // "audio" | "subtitle"
    val audioText = audioOptions.firstOrNull { it.ref == effectiveAudio }?.label
        ?: file?.audioStreams?.firstOrNull()?.let { "${it.language ?: "未标语言"} ${it.codec?.uppercase().orEmpty()}".trim() }
        ?: "尚未探测"
    val subtitleText = when {
        subtitleOptions.isEmpty() -> "无内封或外挂字幕"
        effectiveSubtitle == null -> "${subtitleOptions.size} 条字幕 · 未开启"
        else -> subtitleOptions.firstOrNull { it.ref == effectiveSubtitle }?.label ?: "${subtitleOptions.size} 条字幕"
    }

    // 播放键三态（iOS `LibraryItemDetailView`，v0.31 起同一口径）：继续 / 重新播放 / 播放。
    // **有续播点就续播**：看完（played）后重看到一半，服务端也记着续播点——
    // 旧口径 `!played && position>0` 会把这种重看判成「重新播放」，这次的进度就丢了
    val resumeMs = resume?.positionMs ?: 0L
    val finished = resume?.played == true && resumeMs <= 0L
    val resumable = resumeMs > 0L
    // 剧集写明续的是哪一集（iOS 42c1751d：只写「继续 46:56」看不出续的第几集）
    val playLabel = when {
        resumable -> if (detail.kind == "tv") {
            "继续 第 ${resumeSeason} 季第 ${resumeEpisode} 集 · ${McFormat.clock(resumeMs)}"
        } else "继续 ${McFormat.clock(resumeMs)}"
        finished -> "重新播放"
        else -> "播放"
    }
    val remainingMs = resume?.durationMs?.takeIf { it > 0 }?.minus(resumeMs)?.takeIf { it > 0 }

    // hero 内部一份玻璃取样源（剧照 = 模糊源）：返回圆钮压在剧照上，
    // 走的就是顶栏那套玻璃（iOS 详情页的返回也是 .glass）
    val heroHaze = dev.chrisbanes.haze.rememberHazeState()
    val wideHero = io.movieclaw.android.core.designsystem.LocalCardMetrics.current.isWide
    // iPad 那套参数是按 1024dp 高的屏定的。这块屏横屏只有 608dp——照搬会把剧照压到只剩半张、
    // 左列内容比 16:9 大图区还高（大图被撑高后渐变又按撑高后的高度算，图就提前淡尽）。
    // 所以按屏高等比缩：iPad 上 120dp≈11.7% 屏高、顶部压暗条 112dp≈11%。
    val screenH = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp
    val wideTopPad = minOf(120f, screenH * 0.15f).dp
    // 宽屏：简介移出 hero（跟音轨/字幕同区），左列才压得进剧照
    // 宽窗口：信息块要压在剧照上（iOS `wideStage` 的 `.bottomLeading` 叠法）。
    // 这里不动 Box 的子元素顺序，而是先量出信息块自身高度，再把它**上提**进图片区：
    // `dy = -(信息块高 + 28dp)` 让它的底边落在剧照底部上方 28dp（= iOS `.padding(.bottom, 28)`）。
    // 好处是窄/宽两套共用同一段信息块代码，不必把它抽成函数或复制一遍。
    var infoHeight by remember { mutableStateOf(0) }
    // 音轨 / 字幕两行（含「无可选」时的置灰）。窄屏摆在左列原位；
    // 宽屏整块挪到 hero 下方，左列才能矮到压进剧照里。
    @androidx.compose.runtime.Composable
    fun tracksBlock() {
        Spacer(Modifier.height(13.dp))
        TrackRow("音轨", audioText, onClick = if (audioOptions.isEmpty()) null else {{ sheet = "audio" }})
        Spacer(Modifier.height(13.dp))
        TrackRow(
            "字幕",
            subtitleText,
            dim = subtitleOptions.isEmpty(),
            onClick = if (subtitleOptions.isEmpty()) null else {{ sheet = "subtitle" }},
        )
        // AI 生成字幕入口（iOS `TrackSubtitleGenButton`：仅管理员 + 文件在盘）。
        // iOS 把它放在 `wideExtras`（大图下方的轨道区），所以跟着音轨/字幕一起走。
        // 三态：未接 AI = 「接入… 去接入」引导；运行中 / 有终态问题 = 状态徽章；空闲 = 「AI 生成字幕」。
        if (isAdmin && file != null && !file.missing) {
            Spacer(Modifier.height(12.dp))
            SubtitleGenEntry(
                generated = file.subtitleStreams.any { it.external && SubtitleGenText.isAiSubtitle(it.fileName.orEmpty()) },
                gate = subtitleGen.gate,
                job = subtitleGen.job,
                previewing = subtitleGen.previewing,
                targetLanguage = subtitleGen.targetLanguage,
                secondaryLanguage = subtitleGen.secondaryLanguage.takeIf { subtitleGen.bilingual },
                onClick = { subtitleGenActions.onEntryClick(file.id) },
            )
        }
    }
    // 大图右下角的一行演职员：标签压 55% 白、人名全白（iOS `stageCredits` 的层次）
    @androidx.compose.runtime.Composable
    fun stageCreditLine(label: String, value: String) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = McType.sub, color = Color.White.copy(alpha = 0.55f))
            Spacer(Modifier.width(8.dp))
            Text(
                value,
                style = McType.sub,
                color = Color.White.copy(alpha = 0.92f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
    // 宽屏文字阴影：iOS `wideStage` 给整块文字加了
    // `.shadow(color: .black.opacity(0.4), radius: 8)`——压在剧照上靠它保证可读性，
    // 而不是靠把背景压黑（压黑会和大图之间出现硬边）。Compose 的阴影只能落在 `TextStyle.shadow`。
    @androidx.compose.runtime.Composable
    fun wt(style: androidx.compose.ui.text.TextStyle) = if (wideHero) {
        style.copy(
            shadow = androidx.compose.ui.graphics.Shadow(
                color = Color.Black.copy(alpha = 0.4f),
                offset = androidx.compose.ui.geometry.Offset.Zero,
                blurRadius = 8f,
            ),
        )
    } else {
        style
    }
    // 剧照 + 四层压暗/淡出（iOS `wideStage` 的背景叠法）。抽成函数是因为宽窗口要把它画在
    // **信息块自己的 Box** 里——那样信息块才是大图的子元素、可以 `BottomStart` 对齐
    // （iOS 的 `.background{…}` + `.frame(alignment: .bottomLeading)` 就是这个关系）。
    @androidx.compose.runtime.Composable
    fun androidx.compose.foundation.layout.BoxScope.heroBg() {
        // 底色垫在**图片外面**，图片自己开一个离屏层跑 DstIn 蒙版——
        // 否则 DstIn 会把同一层里先前画的底色一起清掉（实测交界处 avg 掉到 0，露出黑底）。
        Box(Modifier.fillMaxSize().background(tint)) {
        // 宽屏：图由**外壳**按 hero 高度整屏画（同一张图的同一段像素），
        // 页面这里不再画 —— 否则内容区盖住外壳那层，侧栏边界又会出现竖线。
        RemoteImage(
            url = detail.backdropUrl ?: detail.posterUrl,
            origin = origin,
            contentDescription = detail.title,
            // **让图片自己淡出**，而不是在上面盖一层页面底色。
            // 盖色的做法实测压不到底（图底 avg=(101,76,64)，页面底色 (84,65,53)，
            // 那条 Δ≈39 的台阶就是肉眼看到的分界线）。`DstIn` 蒙版是让图片的 alpha 真的降到 0，
            // 底下垫的页面底色自然透出来，物理上不可能有接缝。
            modifier = Modifier
                .fillMaxSize()
                .hazeSource(heroHaze)
                .graphicsLayer {
                    compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen
                }
                .drawWithContent {
                    drawContent()
                    val h = size.height.coerceAtLeast(1f)
                    val infoTop = (h - 28.dp.toPx() - infoHeight).coerceIn(0f, h)
                    val fadeStart = (infoTop / h).coerceIn(0.10f, 0.80f)
                    drawRect(
                        brush = Brush.verticalGradient(
                            0f to Color.Black,
                            fadeStart to Color.Black,
                            // 到底部 alpha 归零 → 图片完全让位给下面的页面底色
                            1f to Color.Transparent,
                        ),
                        blendMode = androidx.compose.ui.graphics.BlendMode.DstIn,
                    )
                },
        )
        }
        //   ① 径向：左下角黑 0.55 → 透明（iOS `endRadius: 1000`）——文字区托底
        //   ② 左右线性：黑 0.35 → 透明（iOS leading → (0.6, 0.5)）——左侧文字再压一道
        //   ③ 顶部 112dp 条：黑 0.45 → 透明——返回/⋯ 可读
        //   ④ 底部溶进页面底色：clear@0.62 → tint α0.6@0.83 → tint@1.0
        Box(
            Modifier
                .fillMaxSize()
                .drawBehind {
                    drawRect(
                        Brush.radialGradient(
                            colors = listOf(Color.Black.copy(alpha = 0.55f), Color.Transparent),
                            center = androidx.compose.ui.geometry.Offset(0f, size.height),
                            radius = 1000f,
                        )
                    )
                    drawRect(
                        Brush.linearGradient(
                            colors = listOf(Color.Black.copy(alpha = 0.35f), Color.Transparent),
                            start = androidx.compose.ui.geometry.Offset.Zero,
                            end = androidx.compose.ui.geometry.Offset(size.width * 0.6f, size.height * 0.5f),
                        )
                    )
                    // （不画顶部压暗条：iOS 那条 112dp 黑 0.45 在 1024dp 高的屏上是薄薄一层，
                    // 到 608dp 的屏上就是一条明显的黑带，很违和。返回/⋯ 是自带玻璃底的圆钮，
                    // 不靠这条压暗也能看清。）
                    // 底部溶进页面底色。iOS 是固定 `clear@0.62 → tint@0.83 → tint@1.0`（按大图区高度），
                    // 那在 1024dp 高的 iPad 上没问题；这块屏横屏只有 400dp 的大图区，
                    // 62% = 248dp，而文字从 ~130dp 排到 ~398dp —— **整块文字都掉进渐隐区**，
                    // 于是再怎么减字都难看。这里改成**跟着信息块顶边走**：文字上方是干净剧照，
                    // 文字所在的那段开始溶进页面底色。文字变多/变少时自动跟随，不必再为好看去砍文字。
                    val boxH = size.height.coerceAtLeast(1f)
                    val infoTop = (boxH - 28.dp.toPx() - infoHeight).coerceIn(0f, boxH)
                    val fadeStart = (infoTop / boxH).coerceIn(0.10f, 0.80f)
                    // 实测（采样像素）：收到 0.94 时，图底仍是 (59,44,36)，而页面底色是 (86,67,54)，
                    // Δ≈+27 就是肉眼看到的那条分界线。原因是横屏渐变拉得长，底部那几行还没落到
                    // 纯底色图就结束了。所以提前到 0.85 落底，留 15% 纯底色把边吃掉。
                    val settleAt = 0.85f
                    drawRect(
                        Brush.verticalGradient(
                            0f to Color.Transparent,
                            fadeStart to Color.Transparent,
                            (fadeStart + (settleAt - fadeStart) * 0.55f) to tint.copy(alpha = 0.72f),
                            settleAt to tint,
                            1f to tint,
                        )
                    )
                },
        )
    }
    Column {
        androidx.compose.runtime.CompositionLocalProvider(LocalTabHazeState provides heroHaze) {
        // 窄屏：大图自成一块，信息块在它下面（offset 上提 124 叠一点点）。
        // 宽屏：不画这块——大图挪进信息块的 Box 里，信息块才能压在图的下沿（iOS `wideStage`）。
        if (!wideHero) {
        Box(Modifier.fillMaxWidth().height(heroHeight())) {
            heroBg()
            Row(
                Modifier
                    .fillMaxWidth()
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(horizontal = 8.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                McNavButton(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回", onClick = onBack)
                // 网页/iOS 这里只有一颗「更多操作」（搜索资源 / 加入合集 / 分享 / 洗版 /
                // 修正识别 / 刷新元数据 / 重新生成章节 / 更换图片 / 转移 / 删除 / 清除观看记录），
                // 判定与显隐照 iOS `actionsMenu`——见 ItemActionsMenu.kt
                Spacer(Modifier.weight(1f))
                trailingActions()
            }
            heroOverlay()
        }
        }
        }

        Column(
            Modifier
                // 宽屏：这一列**不再留水平内边距**，剧照才能铺到侧边栏右边（iOS
                // `.ignoresSafeArea(.container, edges: .horizontal)` 的效果）；边距改由
                // 信息 Row / 简介 / 正文各自补，见下面几处。窄屏保持原来的 16dp。
                .padding(horizontal = if (wideHero) 0.dp else mcCards.pagePadding)
                .offset {
                    // 窄屏：整列（信息 + 正文）一起上提 124，与改动前逐像素一致；
                    // 宽屏：整列不偏移——上提交给上面那个只包信息块的 Box，
                    // 否则 `content()` 会被一起拖上去、压在剧照上。
                    androidx.compose.ui.unit.IntOffset(
                        0,
                        if (wideHero) 0 else (-124).dp.roundToPx(),
                    )
                },
        ) {
            // iOS `wideStage`：左列 `maxWidth 640` + `Spacer` + 右下角演职员。
            // iOS 用 `.bottom` 对齐（那边 hero 会长高把左列包住，底边就是屏幕内的 hero 底边）；
            // 安卓这里信息块是 hero 的**兄弟节点**，比可视区还高，底部对齐会把它推出屏幕，
            // 所以演职员按**顶部**对齐，落在片名同一行的右侧——位置仍在大图右下区域。
            //
            // 这个 Box 只包住「信息块」，**不含 `content()`**：宽屏上提只作用在这里，
            // 正文因此不会被一起拖到剧照上。
            Box(
                Modifier
                    // 宽屏：这块 Box 就是大图区本身（高 = 页宽×9/16 夹区间，文字更高时长高），
                    // 信息 Row 在里面 `BottomStart` 对齐 —— 等价于 iOS
                    // `.background{ 剧照+渐变 }` + `.frame(maxWidth:.infinity, minHeight: heroHeight,
                    // alignment: .bottomLeading)`。不再用 offset 位移。
                    .then(
                        if (wideHero) {
                            Modifier.fillMaxWidth().height(heroHeight())
                        } else {
                            Modifier
                        },
                    ),
            ) {
                if (wideHero) {
                    heroBg()
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .align(Alignment.TopStart)
                            .statusBarsPadding()
                            .padding(horizontal = 8.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        McNavButton(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回", onClick = onBack)
                        Spacer(Modifier.weight(1f))
                        trailingActions()
                    }
                }
            Row(
                Modifier
                    .fillMaxWidth()
                    // 宽屏：信息块压到大图下沿——`BottomStart` + 上 120 / 下 28 内边距
                    // （iOS `wideStage` 的 `.padding(.top, 120)` `.padding(.bottom, 28)`）。
                    .then(
                        if (wideHero) {
                            // 剧照已全宽，信息列自己补左右边距（iOS `.padding(.horizontal, cards.edge)`）
                            Modifier.align(Alignment.BottomStart).padding(
                                start = mcCards.pagePadding,
                                end = mcCards.pagePadding,
                                top = wideTopPad,
                                bottom = 28.dp,
                            )
                        } else {
                            Modifier
                        },
                    ),
                verticalAlignment = Alignment.Bottom,
            ) {
            Column(
                Modifier
                    .weight(1f)
                    .then(if (wideHero) Modifier.widthIn(max = 640.dp) else Modifier)
                    // 左列真实高度 → 底部渐变的起点（跟着文字走，而不是固定 62%）
                    .onSizeChanged { if (wideHero) infoHeight = it.height },
            ) {
            // 片名 Logo（网页/iOS 同款，iOS titleArt）：区高固定 96dp——加载前后下面的
            // 元信息/类型行不跳；本地资产存的是给电视端用的原图；**加载失败或没有
            // Logo 都回退文字片名**（RemoteImage 的 fallback 正是失败回落）
            Box(
                Modifier.fillMaxWidth().height(96.dp),
                contentAlignment = Alignment.BottomStart,
            ) {
                if (detail.logoUrl.isNullOrBlank()) {
                    Text(
                        detail.title,
                        style = wt(McType.title.copy(lineHeight = 36.sp)),
                        color = TextPrimary,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                } else {
                    RemoteImage(
                        url = detail.logoUrl,
                        origin = origin,
                        contentScale = ContentScale.Fit,
                        contentDescription = detail.title,
                        modifier = Modifier.fillMaxHeight(),
                        fallback = {
                            Text(
                                detail.title,
                                style = wt(McType.title.copy(lineHeight = 36.sp)),
                                color = TextPrimary,
                                maxLines = 3,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                    )
                }
            }
            Spacer(Modifier.height(10.dp))
            Text(
                metaLine(detail),
                style = wt(McType.sub),
                color = TextMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )

            // 类型跟在元信息下面、**音轨之上**（网页 `meta.genres.join(" · ")`，
            // 一行纯文本；片源规格 → 类型 → 轨道 → 开播，是网页那条动线）
            val genres = detail.localMeta?.genres.orEmpty()
            if (genres.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text(
                    genres.joinToString(" · "),
                    style = wt(McType.sub),
                    color = Color.White.copy(alpha = 0.72f),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            // 音轨 / 字幕：**窄屏留在左列原位**；宽屏挪到 hero 下方（iOS `wideStage` 把轨道放在
            // `wideExtras`，左列因此只有片名→事实行→类型→简介→按钮，才压得进剧照里）。
            if (!wideHero) tracksBlock()

            // 轨选择面板：列出这个文件的全部音轨/字幕，选中的打勾（与播放器菜单同一套对勾约定）
            sheet?.let { kind ->
                TrackPickerSheet(
                    title = if (kind == "audio") "音轨" else "字幕",
                    options = if (kind == "audio") audioOptions else subtitleOptions,
                    selectedRef = if (kind == "audio") effectiveAudio else effectiveSubtitle,
                    // 服务端给的原因原话（"沿用上一集" / "上次换的" / "影片原声"…）
                    note = (if (kind == "audio") defaults?.audioNote else defaults?.subtitleNote)
                        ?.takeIf { it.isNotBlank() },
                    onPick = { ref ->
                        if (kind == "audio") pickedAudio = ref else pickedSubtitle = ref
                        sheet = null
                    },
                    onDismiss = { sheet = null },
                )
            }

            // ── AI 生成字幕入口已挪到 `tracksBlock()`（iOS 里它属于 `wideExtras`，
            // 跟音轨/字幕一起在大图下方；宽屏左列只放片名→事实行→类型→简介→按钮排）──

            // 能力探测 + 任务跟踪（换文件重建；从「模型接入」回来时这条 effect 会重跑 → 门禁自动刷新）
            LaunchedEffect(file?.id) { subtitleGenActions.onTrack(file?.id) }
            subtitleGen.mode?.let { mode ->
                val fid = file?.id
                SubtitleGenSheet(
                    mode = mode,
                    state = subtitleGen,
                    onDismiss = subtitleGenActions.onDismiss,
                    onTargetLanguage = { token -> fid?.let { subtitleGenActions.onTargetLanguage(it, token) } },
                    onSecondaryLanguage = { token -> fid?.let { subtitleGenActions.onSecondaryLanguage(it, token) } },
                    onBilingual = { on -> fid?.let { subtitleGenActions.onBilingual(it, on) } },
                    onSourceKey = { ref -> fid?.let { subtitleGenActions.onSourceKey(it, ref) } },
                    onPgsLanguage = subtitleGenActions.onPgsLanguage,
                    onConfirm = { fid?.let { subtitleGenActions.onConfirm(it) } },
                    onRetryPreview = { fid?.let { subtitleGenActions.onRetryPreview(it) } },
                    onCancelJob = subtitleGenActions.onCancelJob,
                    onHandOffToAgent = { fid?.let { subtitleGenActions.onHandOffToAgent(it) } },
                )
            }

            // 未下完的下载状态条（iOS：电影在播放键上方；剧集画在分集卡上，这里不出现）
            if (detail.kind != "tv") {
                downloadStatus(null)
                Spacer(Modifier.height(10.dp))
            }
            Spacer(Modifier.height(18.dp))
            Button(
                onClick = {
                    // 起播的就是**选中的那一季那一集**（iOS `play(start:)` 带 selectedEpisode 的
                    // season/episode）；只有还没选中任何单元时才回退到「跨季第一个没看的」（种子）
                    val (season, episode, subtitle) = detailEpisodeOf(detail, episodes, unit)
                        ?: pickResumeEpisode(detail, episodes)
                    android.util.Log.i(
                        "McPlayer",
                        "详情页起播 音轨=$effectiveAudio 字幕=$effectiveSubtitle" +
                            "（服务端默认：音轨=${defaults?.audioTrack} 字幕=${defaults?.subtitleTrack}）",
                    )
                    onPlay(
                        PlayTarget(
                            mediaItemId = detail.mediaItemId,
                            libraryId = libraryId,
                            kind = detail.kind,
                            title = detail.title,
                            subtitle = subtitle,
                            seasonNumber = season,
                            episodeNumber = episode,
                            // 详情页选好的轨随起播请求带走（服务端 apply 后返回的 plan 就是它）
                            preferredAudio = effectiveAudio,
                            preferredSubtitle = effectiveSubtitle,
                        )
                    )
                },
                shape = RoundedCornerShape(999.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = Color(0xFF141821)),
                contentPadding = PaddingValues(0.dp),
                elevation = null,
                modifier = Modifier
                    // 宽屏：主按钮不占满整行，跟后面的「从头播放 / 收藏 / 已看 / 剩余 X」并成一排
                    // （iOS `wideActions` 是 `HStack(spacing: 10)`）；窄屏仍是整行主按钮。
                    .then(if (wideHero) Modifier.widthIn(min = 240.dp) else Modifier.fillMaxWidth())
                    .height(48.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6)))),
            ) {
                Icon(Icons.Rounded.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(playLabel, style = McType.bodySemibold)
            }

            Spacer(Modifier.height(12.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // 宽屏：看过一段时多一颗「从头播放」（iOS `wideActions`：`state.resumable` 时那颗
                // `.glass` 钮）。`PlayTarget.startMs = 0` 让服务端别按续播点接，而是从 0 起。
                if (wideHero && resumable) {
                    GlassPill("从头播放", Icons.Rounded.Replay, false) {
                        val (season, episode, subtitle) = detailEpisodeOf(detail, episodes, unit)
                            ?: pickResumeEpisode(detail, episodes)
                        onPlay(
                            PlayTarget(
                                mediaItemId = detail.mediaItemId,
                                libraryId = libraryId,
                                kind = detail.kind,
                                title = detail.title,
                                subtitle = subtitle,
                                seasonNumber = season,
                                episodeNumber = episode,
                                preferredAudio = effectiveAudio,
                                preferredSubtitle = effectiveSubtitle,
                                startMs = 0L,
                            )
                        )
                    }
                }
                // 宽屏：收藏 / 已看是**圆形玻璃钮**（iOS `wideCircleButton`：`.glass` +
                // `.buttonBorderShape(.circle)`），复用顶栏那颗圆钮的玻璃样式；窄屏仍是带文字的胶囊。
                if (readOnly) {
                    // 离线：收藏、已看都要连服务器
                } else if (wideHero) {
                    McNavButton(
                        if (marks.isFavorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                        contentDescription = if (marks.isFavorite) "取消收藏" else "收藏",
                        onClick = { onToggleFavorite() },
                    )
                    McNavButton(
                        // 未看/已看要看得出区别：之前图标恒为 CheckCircle，点了也不变
                        // （状态其实变了，只是画面上没反馈）。两个图标依赖里都有。
                        if (marks.played) Icons.Rounded.CheckCircle else Icons.Rounded.Check,
                        contentDescription = if (marks.played) "标记为未看" else "标记为已看",
                        onClick = {
                            onTogglePlayed(resumeSeason.takeIf { it > 0 }, resumeEpisode.takeIf { it > 0 })
                        },
                    )
                } else {
                    GlassPill(
                        "收藏",
                        if (marks.isFavorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                        marks.isFavorite,
                    ) { onToggleFavorite() }
                    // 已看时换文案（iOS / 网页同口径）：选中色与正文白几乎一样，只靠颜色看不出点没点上
                    GlassPill(if (marks.played) "已看完" else "标为已看", Icons.Rounded.CheckCircle, marks.played) {
                        onTogglePlayed(resumeSeason.takeIf { it > 0 }, resumeEpisode.takeIf { it > 0 })
                    }
                }
                // 宽屏：「剩余 X」是**独立文本**放在按钮排末尾（iOS `wideActions` 末尾那个
                // `Text(progressText)`，字号 footnote、白 65%），不拼进主按钮文案。
                if (wideHero) {
                    remainingMs?.let {
                        Text(
                            "剩余 " + McFormat.clock(it),
                            style = McType.footnote,
                            color = Color.White.copy(alpha = 0.65f),
                            modifier = Modifier.padding(start = 4.dp),
                        )
                    }
                }
            }

            // 短屏：简介整块搬到大图下方（跟音轨/字幕同区）。左列只剩
            // 片名→事实行→类型→按钮排，高度才能落进固定的大图区里，
            // 不会把图撑高、也不会溢出到页面底色上（溢出会在大图下沿留下一道分界）。
            if (!wideHero) {
            detail.localMeta?.plot?.takeIf { it.isNotBlank() }?.let { plot ->
                Spacer(Modifier.height(18.dp))
                Text(
                    plot,
                style = wt(McType.body.copy(lineHeight = 30.sp)),
                    color = TextMuted,
                    maxLines = if (expanded) Int.MAX_VALUE else 4,
                    overflow = TextOverflow.Ellipsis,
                    // iOS `wideStage`：`ExpandablePlot ... .frame(maxWidth: 560)`。
                    // 宽窗口一行的字数控制住，长行读起来才不费劲（窄屏不限宽）。
                    modifier = if (wideHero) Modifier.widthIn(max = 560.dp) else Modifier,
                )
                Spacer(Modifier.height(9.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.clickable { expanded = !expanded },
                ) {
                    Text(if (expanded) "收起" else "展开全文", style = McType.sub, color = TextPrimary)
                    Icon(
                        if (expanded) Icons.Rounded.KeyboardArrowUp else Icons.Rounded.KeyboardArrowDown,
                        contentDescription = null,
                        tint = TextMuted,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
            }
            }
            // 大图右下角演职员：跟左列同处一个 `Row`（对齐方式 `Bottom`），靠 `Spacer` 顶到右边。
            // iOS `wideStage` 就是 `HStack(alignment: .bottom) { 左列; Spacer(); stageCredits }`。
            if (wideHero) {
                val meta = detail.localMeta
                val directors = meta?.directorCredits?.mapNotNull { it.name.takeIf(String::isNotBlank) }
                    .orEmpty()
                    .ifEmpty { meta?.directors?.filter { it.isNotBlank() }.orEmpty() }
                val actors = meta?.actors?.mapNotNull { it.name?.takeIf(String::isNotBlank) }.orEmpty()
                if (directors.isNotEmpty() || actors.isNotEmpty()) {
                    androidx.compose.foundation.layout.Box(Modifier.weight(1f)) {
                        Column(
                            Modifier.align(Alignment.BottomEnd).padding(bottom = 6.dp),
                            horizontalAlignment = Alignment.End,
                        ) {
                            if (directors.isNotEmpty()) stageCreditLine("导演", directors.joinToString(" / "))
                            if (actors.isNotEmpty()) stageCreditLine("主演", actors.take(3).joinToString(" / "))
                        }
                    }
                }
            }
            }
            }

            // 短屏：简介在大图下方（见左列里的同名条件），限宽 560
            if (wideHero) {
                detail.localMeta?.plot?.takeIf { it.isNotBlank() }?.let { plot ->
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = if (wideHero) mcCards.pagePadding else 0.dp)
                            .padding(bottom = 18.dp),
                    ) {
                        Text(
                            plot,
                            style = wt(McType.body.copy(lineHeight = 30.sp)),
                            color = TextMuted,
                            maxLines = if (expanded) Int.MAX_VALUE else 4,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.widthIn(max = 560.dp),
                        )
                        Spacer(Modifier.height(9.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable { expanded = !expanded },
                        ) {
                            Text(if (expanded) "收起" else "展开全文", style = McType.sub, color = TextPrimary)
                            Icon(
                                if (expanded) Icons.Rounded.KeyboardArrowUp else Icons.Rounded.KeyboardArrowDown,
                                contentDescription = null,
                                tint = TextMuted,
                                modifier = Modifier.size(14.dp),
                            )
                        }
                    }
                }
            }

            // 宽屏：轨道在 hero 下方（iOS `wideExtras`），限宽 720 居中。
            if (wideHero) {
                io.movieclaw.android.core.designsystem.McReadableWidthBox(
                    Modifier.fillMaxWidth().padding(horizontal = mcCards.pagePadding),
                ) {
                    Column { tracksBlock() }
                }
            }

            // 正文其余部分都挂在这块**上提 124** 的列里：偏移只作用到这里，
            // 整块一起上提，简介与下一段之间才不会留下一个 124 高的空洞
            // （之前分集/文件在偏移列之外，那块空白就是它）
            // content 是 ColumnScope 的槽位，这里用 Column 包（Box 会丢接收者）。
            // 宽屏正文各 Section 自己已有 pagePadding，这里不能再加一层，否则变成双倍边距。
            Column { content() }
        }
    }
}

@Composable
private fun heroHeight(): androidx.compose.ui.unit.Dp {
    val c = androidx.compose.ui.platform.LocalConfiguration.current
    val m = io.movieclaw.android.core.designsystem.LocalCardMetrics.current
    // 宽屏对齐 iPad：**内容宽 × 9/16**，clamp 到 420dp ..(屏高 × 82%)。
    // 旧口径 min(整屏宽×1.15, 屏高×0.62) 在这块屏只算出 377dp，比 iPad 的 436dp 矮一截。
    if (m.isWide && m.contentWidth > 0.dp) {
        val byWidth = m.contentWidth * 9f / 16f
        return minOf(maxOf(byWidth, 420.dp), (c.screenHeightDp * 0.82f).dp)
    }
    // 窄屏保持原口径
    return minOf(c.screenWidthDp * 1.15f, c.screenHeightDp * 0.62f).dp
}

private fun metaLine(detail: LibraryItemDetailView): String {
    val file = detail.files.firstOrNull()
    return buildList {
        detail.year?.let { add(it.toString()) }
        detail.localMeta?.runtimeMinutes?.let { add("$it 分钟") }
        file?.resolution?.let { add(it) }
        file?.videoCodec?.let { add(it.uppercase()) }
        file?.hdr?.let { add(it) }
        detail.localMeta?.rating?.takeIf { it > 0f }?.let { add("★ %.1f".format(it)) }
    }.joinToString("  ·  ")
}

/** 详情页一条可选轨（ref = 中性引用 embedded:N / external:文件名） */
internal data class DetailTrackOption(
    val ref: String,
    val label: String,
    val isDefault: Boolean = false,
)

/**
 * 文件的流列表 → 可选轨。ref 按服务端口径拼：
 * 内封轨 `embedded:<序号>`（编号只数内封的），外挂轨 `external:<文件名>`。
 */
private fun trackOptions(
    streams: List<Any>,
    subtitle: Boolean,
): List<DetailTrackOption> {
    var embeddedIndex = -1
    return streams.mapNotNull { raw ->
        if (subtitle) {
            val s = raw as? SubtitleStreamView ?: return@mapNotNull null
            if (s.external) {
                val name = s.fileName ?: return@mapNotNull null
                val ref = "external:$name"
                DetailTrackOption(
                    ref,
                    TrackLabels.subtitle(s.language, kindOfCodec(s.codec), ref, false, s.title, s.forced),
                    s.default,
                )
            } else {
                embeddedIndex++
                val ref = "embedded:$embeddedIndex"
                DetailTrackOption(
                    ref = ref,
                    label = TrackLabels.subtitle(s.language, kindOfCodec(s.codec), ref, false, s.title, s.forced),
                    isDefault = s.default,
                )
            }
        } else {
            val s = raw as? AudioStreamView ?: return@mapNotNull null
            embeddedIndex++
            val ref = "embedded:$embeddedIndex"
            DetailTrackOption(
                ref = ref,
                label = TrackLabels.audio(s.language, s.codec, s.channels, ref),
                isDefault = s.default,
            )
        }
    }
}

/** 服务端决策里的 kind（vtt/ass/pgs）在详情页只有 codec，按编码反推 */
private fun kindOfCodec(codec: String?): String = when (codec?.lowercase()) {
    "ass", "ssa" -> "ass"
    "pgs", "sup", "hdmv_pgs_subtitle" -> "pgs"
    else -> "vtt"
}

/** 轨选择面板（底部弹出）。选中的那条打勾——与播放器菜单同一套视觉约定 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun TrackPickerSheet(
    title: String,
    options: List<DetailTrackOption>,
    selectedRef: String?,
    onPick: (String) -> Unit,
    onDismiss: () -> Unit,
    /** 服务端对「起播会放哪条」的一句解释；空的就不显示 */
    note: String? = null,
) {
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            Text(
                title,
                style = McType.bodySemibold,
                color = TextPrimary,
                modifier = Modifier.padding(start = 20.dp, top = 4.dp, bottom = if (note == null) 8.dp else 2.dp),
            )
            if (note != null) {
                Text(
                    note,
                    style = McType.caption2,
                    color = TextFaint,
                    modifier = Modifier.padding(start = 20.dp, bottom = 8.dp),
                )
            }
            options.forEach { option ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onPick(option.ref) }
                        .padding(horizontal = 20.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.width(20.dp)) {
                        Icon(
                            Icons.Rounded.Check,
                            contentDescription = null,
                            tint = TextPrimary,
                            modifier = Modifier
                                .size(16.dp)
                                .alpha(if (option.ref == selectedRef) 1f else 0f),
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            option.label,
                            style = McType.sub,
                            color = TextPrimary,
                            maxLines = 2,
                        )
                        if (option.isDefault) {
                            Text("片源默认轨", style = McType.caption2, color = TextFaint)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TrackRow(
    label: String,
    value: String,
    dim: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = McType.sub, color = TextFaint, modifier = Modifier.width(40.dp))
        Spacer(Modifier.width(12.dp))
        Row(
            Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(GlassCapsule)
                .border(1.dp, LineSoft, RoundedCornerShape(999.dp))
                .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
                .padding(horizontal = 14.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(value, style = McType.sub, color = if (dim) TextMuted else TextPrimary, maxLines = 1)
            if (onClick != null) {
                Spacer(Modifier.width(6.dp))
                Icon(
                    Icons.Rounded.ExpandMore,
                    contentDescription = null,
                    tint = TextMuted,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

@Composable
private fun RowScope.GlassPill(label: String, icon: ImageVector, active: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .weight(1f)
            .height(40.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(GlassCapsule)
            .border(1.dp, LineSoft, RoundedCornerShape(999.dp))
            .clickable(onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = if (active) AccentStrong else TextPrimary, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(7.dp))
        Text(label, style = McType.sub, color = if (active) AccentStrong else TextPrimary)
    }
}

/** 剧集:第一个未看完且在位的分集;电影返回哨兵 (0,0) */
/**
 * 选中单元 →（季, 集, 副标题）。没选中（或电影）返回 null，调用方再回退到种子。
 */
private fun detailEpisodeOf(
    detail: LibraryItemDetailView,
    episodes: Map<Int, List<EpisodeView>>,
    unit: ItemDetailViewModel.SelectedUnit?,
): Triple<Int, Int, String?>? {
    if (detail.kind != "tv" || unit == null) return null
    val episode = episodes[unit.season]?.firstOrNull { it.episodeNumber == unit.episode } ?: return null
    return Triple(
        unit.season,
        unit.episode,
        "第 ${unit.episode} 集" + (episode.name?.let { " · $it" } ?: ""),
    )
}

private fun pickResumeEpisode(
    detail: LibraryItemDetailView,
    episodes: Map<Int, List<EpisodeView>>,
): Triple<Int, Int, String?> {
    if (detail.kind != "tv") return Triple(0, 0, null)
    for (season in detail.seasons.sorted()) {
        val list = episodes[season] ?: continue
        val candidate = list.firstOrNull { !it.played && it.owned }
            ?: list.firstOrNull { it.owned }
        if (candidate != null) {
            return Triple(season, candidate.episodeNumber, "第 ${candidate.episodeNumber} 集" + (candidate.name?.let { " · $it" } ?: ""))
        }
    }
    return Triple(0, 0, null)
}

/**
 * 演职员（网页 `CastRow`）：104 宽、2:3 头像、姓名 + 「饰 X」，横滚一行。
 * 导演排在演员前（网页 `...directorCast, ...meta.actors`），头像来自 NFO 的
 * `<thumb>`；没有照片就渲染姓名首字。
 */
@Composable
private fun CastSection(detail: LibraryItemDetailView, origin: String?, onOpenPerson: (Int) -> Unit) {
    val meta = detail.localMeta ?: return
    // 一格 = 姓名 / 身份 / 头像 / 影人 id（id 非空才可点，进库内影人页——iOS 同款）
    data class Person(val name: String, val role: String, val avatar: String?, val personId: Int?)
    val people = buildList {
        // 导演：库内人物关系（带头像）优先；老条目没有关系表就退回 NFO 里的姓名占位
        if (meta.directorCredits.isNotEmpty()) {
            meta.directorCredits.forEach { director ->
                if (director.name.isNotBlank()) {
                    add(Person(director.name, "导演", director.thumbUrl, director.tmdbPersonId))
                }
            }
        } else {
            meta.directors.forEach { name ->
                if (name.isNotBlank()) add(Person(name, "导演", null, null))
            }
        }
        meta.actors.forEach { actor ->
            actor.name?.takeIf { it.isNotBlank() }?.let { name ->
                add(
                    Person(
                        name,
                        actor.role?.takeIf { it.isNotBlank() }?.let { "饰 $it" } ?: "演员",
                        // 服务端给的是 `thumb_url`（TMDB 图床的绝对地址）
                        actor.thumbUrl,
                        actor.tmdbPersonId,
                    ),
                )
            }
        }
    }
    if (people.isEmpty()) return
    Column(Modifier.padding(top = 18.dp)) {
        Text(
            "演职员",
            style = McType.title3,
            color = TextPrimary,
            modifier = Modifier.padding(horizontal = mcCards.pagePadding),
        )
        Spacer(Modifier.height(10.dp))
        LazyRow(
            contentPadding = PaddingValues(horizontal = mcCards.pagePadding),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(people, key = { "${it.name}-${it.role}" }) { person ->
                Column(
                    Modifier
                        .width(mcCards.castWidth)
                        // 有 TMDB 影人 id 才可点（进库内影人页）；老条目只有姓名时保持静态（iOS 同款）
                        .clickable(enabled = person.personId != null) { person.personId?.let(onOpenPerson) },
                ) {
                    val initials: @Composable () -> Unit = {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Text(
                                io.movieclaw.android.core.designsystem.ImageInitials.of(person.name),
                                fontSize = 26.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = Color.White.copy(alpha = 0.3f),
                            )
                        }
                    }
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .aspectRatio(2f / 3f)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.05f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (person.avatar.isNullOrBlank()) {
                            initials()
                        } else {
                            // 头像多是 TMDB 图床的绝对地址；**加载失败也回落首字**，
                            // 不能留一块空黑（网页同款兜底）
                            RemoteImage(
                                person.avatar,
                                origin,
                                contentDescription = person.name,
                                modifier = Modifier.fillMaxSize(),
                                fallback = initials,
                            )
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(person.name, style = McType.subSemibold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(person.role, style = McType.micro, color = TextFaint, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/**
 * 分集区（网页 `SeasonEpisodesSection` / iOS `SeasonEpisodesSection`）：
 * **季选择器 + 一季一屏的横滚卡**，外加「在库 X / Y 集」计数。
 *
 * 集数多时两端都是这么解决的：**先按季收窄**（一次只铺一季的卡），其次把当前那一集
 * 自动滚到可见处（深链/续播进来一眼就看到自己追到哪，不用手动滑几十屏）。
 * 季选择器用下拉菜单而不是一排 chips：季多的剧（十几季很常见）chip 一行放不下，
 * 而这行不滚动——后排的季就点不到了；下拉菜单是可滚的，且能标「未入库」。
 */
/** 相似推荐：只推自己库里有的片（同主创、主演、类型相近），点进那一部的库内详情；没有就整行不出 */
@Composable
private fun SimilarSection(
    items: List<LibraryItemView>,
    libraryId: Long,
    origin: String?,
    onOpenItem: (Long, Long) -> Unit,
) {
    if (items.isEmpty()) return
    RelatedRow(title = "相似推荐") {
        items(items, key = { it.mediaItemId }) { item ->
            PosterCard(
                imageUrl = item.posterUrl ?: item.backdropUrl,
                origin = origin,
                title = item.title,
                meta = item.year?.toString(),
                modifier = Modifier.width(mcCards.posterWidth),
                onClick = { onOpenItem(item.libraryId ?: libraryId, item.mediaItemId) },
            )
        }
    }
}

/**
 * 电影的作品系列（排在相似推荐下面）：整个系列按上映顺序，标题旁写「已有 7 / 共 8」。
 * 这一部写「本片」；库里有的点进库内详情；缺的那部压暗、写「未入库」，点进 TMDB 详情去订阅
 * （与网页 / iOS 详情页的系列一行同口径）。
 */
@Composable
private fun SeriesSection(
    series: CollectionSeriesView,
    libraryId: Long,
    itemId: Long,
    origin: String?,
    onOpenItem: (Long, Long) -> Unit,
    onOpenTitle: (String) -> Unit,
) {
    RelatedRow(title = series.seriesName ?: "系列", detail = "已有 ${series.ownedCount} / 共 ${series.total}") {
        items(series.parts, key = { it.tmdbId }) { part ->
            val owned = part.mediaItemId
            val year = part.releaseDate?.take(4)
            val note = when {
                owned == itemId -> "本片"
                owned == null -> if (part.subscribed) "追踪中" else "未入库"
                else -> null
            }
            PosterCard(
                imageUrl = part.posterUrl,
                origin = origin,
                title = part.title,
                meta = listOfNotNull(year, note).joinToString(" · ").ifEmpty { null },
                modifier = Modifier.width(mcCards.posterWidth).alpha(if (owned == null) 0.45f else 1f),
                onClick = when {
                    owned == itemId -> null
                    owned != null -> ({ onOpenItem(libraryId, owned) })
                    else -> ({ onOpenTitle("tmdb:movie:${part.tmdbId}") })
                },
            )
        }
    }
}

/** 详情页的横排一行：标题（+ 右侧灰字）与演职员同一套排版 */
@Composable
private fun RelatedRow(
    title: String,
    detail: String? = null,
    content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit,
) {
    Column(Modifier.padding(top = 18.dp)) {
        Row(
            Modifier.padding(horizontal = mcCards.pagePadding),
            verticalAlignment = Alignment.Bottom,
        ) {
            Text(title, style = McType.title3, color = TextPrimary, modifier = Modifier.weight(1f, fill = false))
            detail?.let {
                Spacer(Modifier.width(10.dp))
                Text(it, style = McType.sub, color = TextFaint)
            }
        }
        Spacer(Modifier.height(10.dp))
        LazyRow(
            contentPadding = PaddingValues(horizontal = mcCards.pagePadding),
            horizontalArrangement = Arrangement.spacedBy(mcCards.rowSpacing),
            modifier = Modifier.fillMaxWidth(),
            content = content,
        )
    }
}

/** 页底「相关链接」（与网页 / iOS 详情页一致）：TMDB / IMDb / 豆瓣，有哪个出哪个，在浏览器（或已装的 App）里打开 */
@Composable
private fun ExternalLinks(detail: LibraryItemDetailView) {
    val links = buildList {
        detail.tmdbId?.takeIf { it > 0 }?.let {
            add("TMDB ↗" to "https://www.themoviedb.org/${if (detail.kind == "tv") "tv" else "movie"}/$it")
        }
        detail.imdbId?.takeIf { it.isNotBlank() }?.let { add("IMDb ↗" to "https://www.imdb.com/title/$it/") }
        detail.doubanId?.takeIf { it.isNotBlank() }?.let { add("豆瓣 ↗" to "https://movie.douban.com/subject/$it/") }
    }
    if (links.isEmpty()) return
    val ctx = LocalContext.current
    Row(
        Modifier.padding(start = mcCards.pagePadding, end = mcCards.pagePadding, top = 24.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("相关链接", style = McType.sub, color = TextFaint)
        Spacer(Modifier.width(12.dp))
        links.forEach { (label, url) ->
            Text(
                label,
                style = McType.sub,
                color = TextMuted,
                modifier = Modifier
                    .padding(end = 16.dp)
                    .clickable {
                        runCatching {
                            ctx.startActivity(
                                android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
                                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                        }
                    },
            )
        }
    }
}

@Composable
private fun SeasonSection(
    seasons: List<Int>,
    ownedSeasons: Set<Int>,
    selected: Int?,
    episodes: Map<Int, List<EpisodeView>>,
    onSelect: (Int) -> Unit,
    /** 选中的集号（受控：来自 VM 的选中单元，不再各存一份） */
    selectedEpisode: Int?,
    onPickEpisode: (Int) -> Unit,
    /** 本季「接着看」的锚点（长剧分段：橙点、「接着看」标、面板落点都以它为准） */
    anchor: Int?,
    /** 手动换段（段胶囊 / 横排两头的「上一段 / 下一段」） */
    onPickRange: (EpisodeRanges.Range) -> Unit,
    origin: String?,
    onPlay: (PlayTarget) -> Unit,
    libraryId: Long,
    itemId: Long,
    itemTitle: String,
    /** 分集的下载状态（本机已下载 / 下载中）与长按菜单：画在分集卡上 */
    offline: EpisodeOffline? = null,
    /** 当前季的播出日历（issue #547）：有它才画入口摘要、分清「还没播」与「缺集」 */
    schedule: io.movieclaw.android.core.model.SeasonAirSchedule? = null,
    onOpenSchedule: () -> Unit = {},
) {
    val seasonLabel = { season: Int ->
        val name = if (season == 0) "特别篇" else "第 $season 季"
        if (season in ownedSeasons) name else "$name · 未入库"
    }
    // 长剧分段（docs/design/long-season-episode-ranges.md §4）：本季超过 50 集才分段，
    // 当前段 = 选中那一集所在的段（换段总会连带选中段里的一集，所以不必单独存）
    val list = episodes[selected] ?: emptyList()
    val picked = selectedEpisode ?: list.firstOrNull()?.episodeNumber
    val ranges = remember(list) { EpisodeRanges.of(list) }
    val segmented = ranges.isNotEmpty()
    val currentRange = ranges.firstOrNull { picked != null && picked in it } ?: ranges.firstOrNull()
    var allSheet by remember { mutableStateOf(false) }
    Column(Modifier.padding(vertical = 6.dp).semantics { testTagsAsResourceId = true }) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        ) {
            Text("分集", style = McType.title3)
            Spacer(Modifier.width(10.dp))
            // 季选择器（iOS `SeasonEpisodesSection` 同款）：多季才给胶囊菜单（每项标「未入库」），
            // 只有一季时就是一行小字——单选的下拉菜单没有意义；缺省落在当前季，不再有「选择季」占位
            var seasonMenu by remember { mutableStateOf(false) }
            val activeSeason = selected ?: seasons.firstOrNull()
            if (seasons.size > 1) {
                Box {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .background(GlassCapsule)
                            .border(1.dp, LineSoft, RoundedCornerShape(999.dp))
                            .clickable { seasonMenu = true }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    ) {
                        Text(
                            activeSeason?.let(seasonLabel) ?: "第 1 季",
                            style = McType.subSemibold,
                            color = TextPrimary,
                        )
                        Spacer(Modifier.width(4.dp))
                        Icon(
                            Icons.Rounded.UnfoldMore,
                            contentDescription = "选择季",
                            tint = TextMuted,
                            modifier = Modifier.size(15.dp),
                        )
                    }
                    androidx.compose.material3.DropdownMenu(
                        expanded = seasonMenu,
                        onDismissRequest = { seasonMenu = false },
                        containerColor = Color(0xFF1E212B),
                        shape = RoundedCornerShape(14.dp),
                        modifier = Modifier.heightIn(max = 340.dp),
                    ) {
                        seasons.sorted().forEach { season ->
                            androidx.compose.material3.DropdownMenuItem(
                                text = {
                                    Text(
                                        seasonLabel(season),
                                        style = McType.sub,
                                        color = if (season == activeSeason) Accent else TextPrimary,
                                    )
                                },
                                onClick = { seasonMenu = false; onSelect(season) },
                            )
                        }
                    }
                }
            } else {
                Text(activeSeason?.let(seasonLabel) ?: "", style = McType.sub, color = TextMuted)
            }
            // 「在库 X / Y 集」（网页/iOS 都有这一行）：一眼看出这一季收了多少；
            // 分段时这个位置换成「全部 N 集 ›」（在库数挪进面板标题）
            val seasonEpisodes = episodes[selected].orEmpty()
            if (segmented) {
                Spacer(Modifier.weight(1f))
                Text(
                    "全部 ${seasonEpisodes.size} 集 ›",
                    style = McType.caption,
                    color = TextMuted,
                    modifier = Modifier
                        .testTag("ep-all-button")
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { allSheet = true }
                        .padding(start = 8.dp, top = 5.dp, bottom = 5.dp),
                )
            } else if (schedule != null) {
                Spacer(Modifier.weight(1f))
                Text(
                    "播出日历 ›",
                    style = McType.caption,
                    color = TextMuted,
                    modifier = Modifier
                        .testTag("air-schedule-open")
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(onClick = onOpenSchedule)
                        .padding(start = 8.dp, top = 5.dp, bottom = 5.dp),
                )
            } else if (seasonEpisodes.isNotEmpty()) {
                Spacer(Modifier.width(10.dp))
                Text(
                    "在库 ${seasonEpisodes.count { it.owned }} / ${seasonEpisodes.size} 集",
                    style = McType.sub,
                    color = TextFaint,
                )
            }
        }

        if (schedule != null && list.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            AirScheduleSummary(
                episodes = list,
                schedule = schedule,
                onOpen = onOpenSchedule,
                modifier = Modifier.padding(horizontal = mcCards.pagePadding),
            )
        }

        // 段胶囊：横滑，选中段实心、锚点段右上角橙点
        if (segmented && currentRange != null) {
            Spacer(Modifier.height(12.dp))
            EpisodeRangeChips(
                ranges = ranges,
                current = currentRange.index,
                anchor = anchor,
                onPick = onPickRange,
                tagPrefix = "ep-range-chip",
            )
        }

        // 分集横滚卡：一季一屏（分段时只放当前段），点一集 = 选中它（播放是详情页那颗播放键，选中的集就是它要播的）
        val shown = currentRange?.episodes ?: list
        // 「接着看」只标有观看记录的季：一集都没碰过的季，锚点只是退回规则落的第一集，标了是噪音
        val watched = list.any { it.played || it.positionMs > 0 }
        val prevRange = currentRange?.let { c -> ranges.getOrNull(ranges.indexOf(c) - 1) }
        val nextRange = currentRange?.let { c -> ranges.getOrNull(ranges.indexOf(c) + 1) }
        Spacer(Modifier.height(12.dp))
        val strip = rememberLazyListState()
        // 进页/换季/换段时把选中那一集滚到可见处（续播进来的那一集常常在列表深处，
        // 不滚的话得手动滑几十屏；网页/iOS 同样会滚到当前集）。选中的是第一张也要滚回开头——
        // 换季/换段后横排还停在旧位置（比如 120 集那季的第 70 张），新选中的第 1 集就看不见了
        LaunchedEffect(selected, currentRange?.index, list.size, picked) {
            val index = shown.indexOfFirst { it.episodeNumber == picked }
            if (index >= 0) {
                val item = index + (if (prevRange != null) 1 else 0)
                strip.animateScrollToItem((item - 1).coerceAtLeast(0))
            }
        }
        LazyRow(
            state = strip,
            contentPadding = PaddingValues(horizontal = mcCards.pagePadding),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            prevRange?.let { range ->
                item(key = "prev") { RangeEdgeCard("← 上一段", range, "ep-edge-prev") { onPickRange(range) } }
            }
            items(shown, key = { it.episodeNumber }) { episode ->
                EpisodeCard(
                    episode = episode,
                    selected = episode.episodeNumber == picked,
                    origin = origin,
                    onSelect = { onPickEpisode(episode.episodeNumber) },
                    resumeTag = watched && episode.episodeNumber == anchor,
                    offline = offline,
                    season = selected ?: 0,
                    schedule = schedule,
                )
            }
            nextRange?.let { range ->
                item(key = "next") { RangeEdgeCard("下一段 →", range, "ep-edge-next") { onPickRange(range) } }
            }
        }
    }

    if (allSheet && segmented) {
        AllEpisodesSheet(
            episodes = list,
            ranges = ranges,
            anchor = anchor,
            selected = picked,
            onPick = { ep -> allSheet = false; onPickEpisode(ep) },
            onDismiss = { allSheet = false },
        )
    }
}

/**
 * 分集横滚卡（网页 `EpisodeCard`）：200 宽、16:9 剧照 + 「N. 集名」。
 *
 * 观看状态与首页「最近观看」卡同一套语言：看了一半底部细进度条、看完右上角绿对勾，
 * 扫一眼就知道追到哪了；缺集整卡压暗 + 右上角「缺」；选中那集套一圈亮环。
 * 点一集**只切换选中**（网页行为），要播的是详情页那颗播放键。
 */
/** 分集卡上的下载状态（本机已下载 / 在下的任务） */
/** 分集卡的下载部件（iOS `episodeMenu` + `OfflineDownloadStrip`）：本机状态、实时速度、长按菜单的动作 */
private class EpisodeOffline(
    val unitOf: (season: Int, episode: Int) -> io.movieclaw.android.core.offline.OfflineUnit?,
    val speeds: Map<Long, Double>,
    /** 下载顺序（§5.5）与「等待 Wi-Fi」：卡上写排第几，长按菜单给「优先下载」 */
    val queue: List<io.movieclaw.android.core.offline.OfflineQueue.Entry>,
    val waitingForWiFi: Boolean,
    val onPrioritize: (Long) -> Unit,
    /** 能下这一集（有权限、服务器支持、在线） */
    val canDownload: Boolean,
    val onDownload: (season: Int, episode: Int, fileId: Long) -> Unit,
    val onPause: (Long) -> Unit,
    val onResume: (Long) -> Unit,
    val onDelete: (Long) -> Unit,
)

@Composable
private fun EpisodeCard(
    episode: EpisodeView,
    selected: Boolean,
    origin: String?,
    onSelect: () -> Unit,
    /** 锚点那张卡左上角标「接着看」（本季有观看记录才标，长短季一样；橙点 / 面板橙边不受此限） */
    resumeTag: Boolean = false,
    /**
     * 这一集在手机上的下载（iOS `EpisodeCard.download`）：没下完时剧照上叠 `OfflineDownloadStrip`；
     * 下完右上角绿箭头「已下载」，刚下完时底部短暂提示「下载完成」。暂停 / 继续 / 取消在长按菜单
     */
    offline: EpisodeOffline? = null,
    season: Int = 0,
    /** 播出日历：有它才分得清「还没播」与「缺集」；没有时库里没有的集一律按缺集 */
    schedule: io.movieclaw.android.core.model.SeasonAirSchedule? = null,
) {
    val download = offline?.unitOf(season, episode.episodeNumber)
    val pending = download != null && !download.playable
    // 看完后重看到一半：对勾保留，进度条按这次看到哪画；下载中底部是下载条，观看进度先不画
    val progress = when {
        pending -> null
        episode.positionMs > 0 -> episode.progressPercent?.toFloat()
        episode.played -> 100f
        else -> null
    }
    var menu by remember { mutableStateOf(false) }
    val tone = schedule?.takeIf { !episode.owned }?.let { AirSchedule.tone(episode, it) }
    val airsToday = tone == AirTone.Today || tone == AirTone.TodayFree
    // 还没播：不压暗、不标「缺」，剧照位换成播出日
    val unaired = airsToday || tone == AirTone.Upcoming
    Column(
        Modifier
            .width(mcCards.episodeWidth)
            .testTag("ep-card-${episode.episodeNumber}")
            .semantics { this.selected = selected }
            .combinedClickable(onClick = onSelect, onLongClick = if (offline != null) ({ menu = true }) else null)
            .then(if (episode.owned || unaired) Modifier else Modifier.alpha(0.45f)),
    ) {
        if (offline != null) EpisodeDownloadMenu(menu, { menu = false }, offline, download, season, episode)
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(12.dp))
                .background(Color.White.copy(alpha = 0.05f))
                .border(
                    width = if (selected) 2.dp else 1.dp,
                    color = if (selected) Color.White.copy(alpha = 0.85f) else Color.White.copy(alpha = 0.08f),
                    shape = RoundedCornerShape(12.dp),
                ),
        ) {
            if (unaired && schedule != null) UnairedStill(episode, schedule, today = airsToday) else RemoteImage(
                url = episode.stillUrl,
                origin = origin,
                contentDescription = "第 ${episode.episodeNumber} 集剧照",
                modifier = Modifier.fillMaxSize(),
                fallback = {
                    // 没有剧照就退回大大的集号（网页同款兜底）
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            "${episode.episodeNumber}",
                            fontSize = 22.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color.White.copy(alpha = 0.2f),
                        )
                    }
                },
            )
            if (resumeTag) ResumeTag(Modifier.align(Alignment.TopStart).padding(6.dp))
            // 右上角状态位：缺集与已看对勾同排（看过之后文件丢了两者会同时出现）
            if ((!episode.owned && !unaired) || episode.played || download?.playable == true) {
                Row(
                    Modifier.align(Alignment.TopEnd).padding(6.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (download?.playable == true) io.movieclaw.android.feature.offline.OfflineDownloadedBadge()
                    if (!episode.owned && !unaired) {
                        Text(
                            "缺",
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = Warning,
                            modifier = Modifier
                                .clip(RoundedCornerShape(4.dp))
                                .background(Color.Black.copy(alpha = 0.6f))
                                .padding(horizontal = 5.dp, vertical = 1.dp),
                        )
                    }
                    if (episode.played) {
                        Box(
                            Modifier
                                .size(20.dp)
                                .clip(CircleShape)
                                .background(Success),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Rounded.Check, contentDescription = "已看完", tint = Color(0xFF07120C), modifier = Modifier.size(13.dp))
                        }
                    }
                }
            }
            when {
                progress != null -> Box(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .padding(horizontal = 6.dp, vertical = 6.dp)
                        .fillMaxWidth()
                        .height(3.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.25f)),
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth((progress / 100f).coerceIn(0f, 1f))
                            .height(3.dp)
                            .clip(RoundedCornerShape(999.dp))
                            .background(if (episode.played) Success else Accent2),
                    )
                }
                // 有记录但算不出百分比（无时长）：一根半透明的整条兜底
                !pending && episode.owned && episode.played.not() && episode.positionMs > 0 -> Box(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .padding(horizontal = 6.dp, vertical = 6.dp)
                        .fillMaxWidth()
                        .height(3.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(Accent2.copy(alpha = 0.6f)),
                )
            }
            if (download != null) {
                OfflineJustFinished(download.playable)
                if (pending) OfflineDownloadStrip(
                    download, offline?.speeds?.get(download.fileId),
                    ahead = offline?.let { io.movieclaw.android.core.offline.OfflineQueue.ahead(download.fileId, it.queue) } ?: 0,
                    waitingForWiFi = offline?.waitingForWiFi == true,
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            "${episode.episodeNumber}. " + (episode.name?.takeIf { it.isNotBlank() } ?: "第 ${episode.episodeNumber} 集"),
            style = if (selected) McType.subSemibold else McType.sub,
            color = if (selected) Color.White else TextPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** 分集卡长按（iOS `episodeMenu`）：下载这一集 / 暂停 / 继续下载 / 取消下载或删除下载 */
@Composable
private fun EpisodeDownloadMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    offline: EpisodeOffline,
    unit: io.movieclaw.android.core.offline.OfflineUnit?,
    season: Int,
    episode: EpisodeView,
) {
    val file = episode.fileIds.firstOrNull()
    if (unit == null && !(offline.canDownload && file != null)) return
    androidx.compose.material3.DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        if (unit != null) {
            if (unit.state != io.movieclaw.android.core.offline.OfflineUnit.State.done &&
                io.movieclaw.android.core.offline.OfflineQueue.canPrioritize(unit.fileId, offline.queue)
            ) {
                androidx.compose.material3.DropdownMenuItem(text = { Text("优先下载") }, onClick = { onDismiss(); offline.onPrioritize(unit.fileId) })
            }
            if (unit.state == io.movieclaw.android.core.offline.OfflineUnit.State.queued || unit.state == io.movieclaw.android.core.offline.OfflineUnit.State.downloading) {
                androidx.compose.material3.DropdownMenuItem(text = { Text("暂停") }, onClick = { onDismiss(); offline.onPause(unit.fileId) })
            }
            // 排队等服务器转码不是出错：没有「继续下载」可点（到点自己会再去问）
            if (unit.state == io.movieclaw.android.core.offline.OfflineUnit.State.paused ||
                (unit.state == io.movieclaw.android.core.offline.OfflineUnit.State.failed && !unit.waitingForTranscode)
            ) {
                androidx.compose.material3.DropdownMenuItem(text = { Text("继续下载") }, onClick = { onDismiss(); offline.onResume(unit.fileId) })
            }
            androidx.compose.material3.DropdownMenuItem(
                text = { Text(if (unit.state == io.movieclaw.android.core.offline.OfflineUnit.State.done) "删除下载" else "取消下载", color = io.movieclaw.android.core.designsystem.Danger) },
                onClick = { onDismiss(); offline.onDelete(unit.fileId) },
            )
        } else if (file != null) {
            androidx.compose.material3.DropdownMenuItem(text = { Text("下载这一集") }, onClick = { onDismiss(); offline.onDownload(season, episode.episodeNumber, file) })
        }
    }
}

/* ---------------- 文件区（iOS `fileSection` + `LibraryFileRow` 的手机版） ---------------- */

/**
 * 文件区要显示的文件（iOS `isMovie ? detail.files : (selectedEpisode?.files ?? [])`）：
 * 电影 = 整条的文件；剧集 = 当前选中那一集（没选中 → 空，整区不显示）。
 * 注意与 Hero 里给音轨/字幕用的 `unitFiles`（取不到时回落整条）不同：那是"至少能显示点东西"，
 * 这里是"显示的就该是这一集的"。
 */
private fun sectionFilesFor(
    detail: LibraryItemDetailView,
    unit: ItemDetailViewModel.SelectedUnit?,
    episodes: Map<Int, List<EpisodeView>>,
): List<LibraryFileView> {
    if (detail.kind != "tv") return detail.files
    val ids = unit?.let { u -> episodes[u.season]?.firstOrNull { it.episodeNumber == u.episode }?.fileIds }.orEmpty()
    if (ids.isEmpty()) return emptyList()
    return detail.files.filter { f -> f.id in ids }
}

/**
 * 文件区：
 *   · 每行可展开：保存目录 / 入库时间 / 来源 / 多版本 / 文件尺寸 / 片源 / 画面规格 / 视频编码 /
 *     色深 / 帧率 / 色彩空间 / 视频码率（12 项逐项对齐 iOS `LibraryFileRow.details`）
 *   · 状态：待回收（划掉文件名 + 恢复 / 立即清理 + 清理倒计时）、文件缺失（标签）
 *   · 管理员：每行删除（底部确认单）、头部「N 个版本 / N 集有重复 · 处理重复」入口
 */
@Composable
private fun FilesSection(
    detail: LibraryItemDetailView,
    files: List<LibraryFileView>,
    canManage: Boolean,
    /** 本机下完的副本（iOS `localIds`）：排在最前、标「本机」 */
    localUnits: List<io.movieclaw.android.core.offline.OfflineUnit> = emptyList(),
    /** 改下其他画质时选档面板的标题 */
    localTitle: String = detail.title,
    canChangeQuality: Boolean = false,
    onChangeQuality: (fileId: Long, title: String) -> Unit = { _, _ -> },
    onOpenDuplicates: () -> Unit,
    onTrash: (LibraryFileView) -> Unit,
    onRestore: (LibraryFileView) -> Unit,
    onPurge: (LibraryFileView) -> Unit,
    onCopyPath: (LibraryFileView) -> Unit,
) {
    if (files.isEmpty()) return
    // 重复口径（iOS `fileSection`）：在位文件按「季:集」分组，多于一格才算重复；
    // 电影报「N 个版本」、剧集报「N 集有重复」
    val inPlace = detail.files.filter { it.state == "in_place" }
    val duplicateUnits = inPlace.groupBy { "${it.seasonNumber}:${it.episodeNumber}" }.values.count { it.size > 1 }
    val duplicateLabel = when {
        duplicateUnits == 0 -> null
        detail.kind == "tv" -> "$duplicateUnits 集有重复"
        else -> "${inPlace.size} 个版本"
    }
    Column(Modifier.padding(horizontal = mcCards.pagePadding, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("文件", style = McType.subheadlineSemibold, color = TextMuted)
            Text("${files.size + localUnits.size}", fontSize = 12.sp, color = TextFaint)
            if (canManage && duplicateLabel != null) {
                Text(
                    "$duplicateLabel · 处理重复",
                    fontSize = 12.sp,
                    color = Warning,
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .clickable(onClick = onOpenDuplicates)
                        .padding(horizontal = 6.dp, vertical = 3.dp),
                )
            }
        }
        Spacer(Modifier.height(10.dp))
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Color.White.copy(alpha = 0.015f))
                .border(1.dp, Color.White.copy(alpha = 0.04f), RoundedCornerShape(12.dp)),
        ) {
            localUnits.forEach { unit ->
                val source = files.firstOrNull { it.id == unit.fileId }
                io.movieclaw.android.feature.offline.OfflineLocalFileRow(
                    unit = unit,
                    source = source,
                    title = localTitle,
                    canChangeQuality = canChangeQuality && source != null,
                    onChangeQuality = { onChangeQuality(unit.fileId, localTitle) },
                    specRows = ::fileSpecRows,
                )
                Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.035f)))
            }
            files.forEachIndexed { index, file ->
                FileRow(
                    file = file,
                    canManage = canManage,
                    onTrash = { onTrash(file) },
                    onRestore = { onRestore(file) },
                    onPurge = { onPurge(file) },
                    onCopyPath = { onCopyPath(file) },
                )
                if (index != files.lastIndex) {
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.035f)))
                }
            }
        }
    }
}

/**
 * 一条文件（iOS `LibraryFileRow`）：折叠 = chevron + 文件名（待回收划掉）+ 状态标签 + 操作；
 * 展开 = 12 项元数据；长按文件名 = 拷贝路径。
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun FileRow(
    file: LibraryFileView,
    canManage: Boolean,
    onTrash: () -> Unit,
    onRestore: () -> Unit,
    onPurge: () -> Unit,
    onCopyPath: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val trashed = file.state == "trashed"
    val chevronAngle by animateFloatAsState(if (expanded) 90f else 0f, label = "file-chevron")
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 6.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier
                    .weight(1f)
                    .combinedClickable(onClick = { expanded = !expanded }, onLongClick = onCopyPath)
                    .padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Rounded.KeyboardArrowRight,
                    contentDescription = null,
                    tint = TextFaint,
                    modifier = Modifier.size(14.dp).rotate(chevronAngle),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    file.fileName,
                    fontSize = 13.sp,
                    color = if (trashed) TextFaint else TextMuted,
                    textDecoration = if (trashed) TextDecoration.LineThrough else null,
                    maxLines = if (expanded) Int.MAX_VALUE else 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (file.missing) FileTag("文件缺失", Warning)
            if (trashed) {
                FileTag("待回收", TextFaint)
                if (canManage) {
                    TextButton(
                        onClick = onRestore,
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    ) { Text("恢复", fontSize = 12.sp, color = TextPrimary, fontWeight = FontWeight.SemiBold) }
                    TextButton(
                        onClick = onPurge,
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    ) { Text("立即清理", fontSize = 12.sp, color = Danger, fontWeight = FontWeight.SemiBold) }
                }
            } else if (canManage) {
                IconButton(onClick = onTrash) {
                    Icon(Icons.Rounded.Delete, contentDescription = "删除此文件", tint = TextFaint, modifier = Modifier.size(16.dp))
                }
            }
        }
        if (trashed) {
            Text(
                purgeCountdown(file.purgeAfter) + (file.trashNote?.let { " · $it" } ?: ""),
                fontSize = 11.sp,
                color = TextFaint,
                modifier = Modifier.padding(start = 14.dp, end = 14.dp, bottom = 8.dp),
            )
        }
        if (expanded) FileDetails(file)
    }
}

/** 展开态 12 项元数据（iOS `LibraryFileRow.details` 逐项同款） */
@Composable
private fun FileDetails(file: LibraryFileView) {
    val picture = listOfNotNull(file.resolution?.let { resolutionLabel(it) }, file.hdr).joinToString(" · ")
    val addedAt = file.addedAt
    Column(
        Modifier.padding(start = 34.dp, end = 14.dp, top = 2.dp, bottom = 14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        FileDetailRow("保存目录", directoryOf(file.filePath.orEmpty()), mono = true)
        FileDetailRow("入库时间", if (addedAt.isNullOrEmpty()) "—" else "${McFormat.dateTime(addedAt)} · ${McFormat.relative(addedAt)}")
        FileDetailRow("来源", file.origin?.label ?: "—", note = file.origin?.detail)
        file.keptAt?.let {
            FileDetailRow("多版本", "你留下的 · ${McFormat.dateTime(it)}（不会再列为重复文件）")
        }
        FileDetailRow("文件尺寸", McFormat.bytes(file.sizeBytes))
        FileDetailRow("片源", mediaSourceLabel(file))
        FileDetailRow("画面规格", picture.ifEmpty { "未能探测（文件不可达或尚未扫描）" })
        FileDetailRow("视频编码", codecLabel(file.videoCodec) ?: "尚未探测")
        FileDetailRow("色深", file.bitDepth?.let { "$it-bit" } ?: "尚未探测")
        FileDetailRow("帧率", frameRateLabel(file.frameRate) ?: "尚未探测")
        FileDetailRow("色彩空间", file.colorSpace ?: "尚未探测")
        FileDetailRow("视频码率", file.bitRate?.let { "%.1f Mbps".format(it / 1_000_000.0) } ?: "尚未探测")
    }
}

/** 片源与画面规格那几行（本机副本的原画行照抄同一份，见 `OfflineLocalFileRow`；iOS `LibraryFileRow.specRows`） */
private fun fileSpecRows(file: LibraryFileView): List<Pair<String, String>> {
    val picture = listOfNotNull(file.resolution?.let { resolutionLabel(it) }, file.hdr).joinToString(" · ")
    return listOf(
        "片源" to mediaSourceLabel(file),
        "画面规格" to picture.ifEmpty { "未能探测（文件不可达或尚未扫描）" },
        "视频编码" to (codecLabel(file.videoCodec) ?: "尚未探测"),
        "色深" to (file.bitDepth?.let { "$it-bit" } ?: "尚未探测"),
        "帧率" to (frameRateLabel(file.frameRate) ?: "尚未探测"),
        "色彩空间" to (file.colorSpace ?: "尚未探测"),
        "视频码率" to (file.bitRate?.let { "%.1f Mbps".format(it / 1_000_000.0) } ?: "尚未探测"),
    )
}

@Composable
private fun FileDetailRow(label: String, value: String, mono: Boolean = false, note: String? = null) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, fontSize = 12.sp, color = TextFaint, modifier = Modifier.width(56.dp))
        Column(Modifier.weight(1f)) {
            Text(
                value,
                fontSize = 12.sp,
                color = TextMuted,
                fontFamily = if (mono) FontFamily.Monospace else null,
                lineHeight = 17.sp,
            )
            if (!note.isNullOrEmpty()) {
                Text(note, fontSize = 11.sp, color = TextFaint, fontFamily = FontFamily.Monospace, lineHeight = 15.sp)
            }
        }
    }
}

/** 状态小标签（iOS `tag`）：细描边小圆角 */
@Composable
private fun FileTag(text: String, color: Color) {
    Text(
        text,
        fontSize = 10.sp,
        color = color.copy(alpha = 0.85f),
        modifier = Modifier
            .padding(horizontal = 4.dp)
            .border(1.dp, color.copy(alpha = 0.3f), RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    )
}

/** 危险动作按钮（删除 / 立即清理 / 完成）：iOS `DangerButton` 的手机版 */
@Composable
private fun DangerButton(text: String, enabled: Boolean = true, busy: Boolean = false, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = enabled && !busy,
        colors = ButtonDefaults.buttonColors(
            containerColor = Danger,
            contentColor = Color.White,
            disabledContainerColor = Danger.copy(alpha = 0.35f),
            disabledContentColor = Color.White.copy(alpha = 0.6f),
        ),
        shape = RoundedCornerShape(999.dp),
    ) {
        if (busy) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

/**
 * 删除文件确认单（iOS `DeleteFileSheet` 的手机版）：
 * 确认步 = 说明 + 文件块 + 「最后一份文件会升级为整条目删除」警告 + 订阅说明 + 「我已明白」勾选；
 * 结果步 = 删掉的路径清单 / 错误 / 「已清理 N 条台账，释放 X」。
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun DeleteFileSheet(
    detail: LibraryItemDetailView,
    file: LibraryFileView,
    isLast: Boolean,
    onDismiss: () -> Unit,
    run: suspend (options: String?) -> Result<ItemDeleteResultView>,
    loadOptions: suspend () -> Result<ItemDeletePreviewView>,
    loadJob: suspend (jobId: String) -> Result<JobView>,
    onFinished: (deletedItem: Boolean) -> Unit,
) {
    var confirmed by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<ItemDeleteResultView?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    // 附加选项：打开时取一次删除预览；默认一律不勾；取不到不挡删除（缺失文件不问）
    var preview by remember { mutableStateOf<ItemDeletePreviewView?>(null) }
    var previewFailed by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(emptySet<String>()) }
    LaunchedEffect(file.id) {
        if (!file.missing) {
            loadOptions().onSuccess { preview = it }.onFailure { previewFailed = true }
        }
    }
    val scope = rememberCoroutineScope()
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = { if (!busy && result == null) onDismiss() },
        containerColor = Color(0xFF15161A),
        contentColor = TextPrimary,
    ) {
        // 附加选项是别的模块登记的、条数不定：内容超出一屏时可滚，删除按钮不会被挤出屏幕
        Column(
            Modifier.fillMaxWidth()
                .formSheetScroll().verticalScroll(rememberScrollState())
                .padding(horizontal = mcCards.pagePadding, vertical = 4.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Rounded.Delete, contentDescription = null, tint = Danger, modifier = Modifier.size(18.dp))
                Text("删除文件", style = McType.bodySemibold, color = TextPrimary)
            }
            Spacer(Modifier.height(12.dp))
            val done = result
            if (done != null) {
                Text(
                    if (done.errors.isEmpty()) "已从磁盘删除" else "删除失败",
                    style = McType.bodySemibold,
                    color = if (done.errors.isEmpty()) TextPrimary else Danger,
                )
                Spacer(Modifier.height(12.dp))
                if (done.removedPaths.isEmpty()) {
                    Box(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.03f))
                            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
                            .padding(14.dp),
                    ) {
                        Text(
                            "没有删除任何磁盘路径" + if (file.missing) "（文件本就缺失，仅清除了台账记录）" else "",
                            fontSize = 13.sp,
                            color = TextMuted,
                        )
                    }
                } else {
                    Column(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.03f))
                            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        done.removedPaths.forEach { path ->
                            Text(path, fontSize = 12.sp, color = Color.White.copy(alpha = 0.7f), fontFamily = FontFamily.Monospace)
                        }
                    }
                }
                if (done.errors.isNotEmpty()) {
                    Spacer(Modifier.height(10.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        done.errors.forEach { Text(it, fontSize = 13.sp, color = Danger) }
                    }
                }
                Spacer(Modifier.height(10.dp))
                Text("已清理 ${done.rowsDeleted} 条台账，释放 ${McFormat.bytes(done.freedBytes)}。", fontSize = 13.sp, color = TextMuted)
                done.followUps.orEmpty().forEach { item ->
                    Spacer(Modifier.height(10.dp))
                    DeleteFollowUpRow(item, loadJob)
                }
                Spacer(Modifier.height(16.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    DangerButton("完成") { onFinished(isLast && done.errors.isEmpty()) }
                }
                Spacer(Modifier.height(12.dp))
            } else {
                Text(
                    if (file.missing) "该文件在磁盘上已缺失，删除只会清掉这条台账记录。"
                    else "将把下列文件从磁盘彻底删除，同名的 NFO/字幕/图片附属文件一并清除。此操作不可恢复。",
                    fontSize = 14.sp,
                    color = Color.White.copy(alpha = 0.8f),
                    lineHeight = 20.sp,
                )
                Spacer(Modifier.height(12.dp))
                Column(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.White.copy(alpha = 0.03f))
                        .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
                        .padding(14.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (detail.kind != "movie" && (file.episodeNumber > 0 || file.seasonNumber > 0)) {
                            Text(
                                "S%02dE%02d".format(file.seasonNumber, file.episodeNumber),
                                fontSize = 13.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = Accent,
                            )
                            Spacer(Modifier.width(8.dp))
                        }
                        Text(
                            file.fileName,
                            fontSize = 13.sp,
                            color = TextPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(McFormat.bytes(file.sizeBytes), fontSize = 12.sp, color = TextMuted)
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        file.filePath.orEmpty(),
                        fontSize = 11.sp,
                        color = Color.White.copy(alpha = 0.5f),
                        fontFamily = FontFamily.Monospace,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (isLast) {
                    Spacer(Modifier.height(12.dp))
                    Box(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(Warning.copy(alpha = 0.06f))
                            .border(1.dp, Warning.copy(alpha = 0.3f), RoundedCornerShape(12.dp))
                            .padding(14.dp),
                    ) {
                        Text(
                            "这是「${detail.title}」在本库的最后一个文件——删除将升级为整条目删除，整个刮削目录（含 NFO/海报）一并清除，条目将从库存消失。",
                            fontSize = 13.sp,
                            color = Warning,
                            lineHeight = 19.sp,
                        )
                    }
                }
                Spacer(Modifier.height(12.dp))
                Text(
                    "若该作品有订阅且删除后此单元不再有其他拷贝，订阅会将其视为缺失并自动重新下载。",
                    fontSize = 11.sp,
                    color = TextFaint,
                    lineHeight = 16.sp,
                )
                if (!file.missing) {
                    Spacer(Modifier.height(12.dp))
                    DeleteOptionsSection(
                        preview = preview,
                        failed = previewFailed,
                        selected = selected,
                        enabled = !busy,
                        onToggle = { key -> selected = if (key in selected) selected - key else selected + key },
                    )
                }
                Spacer(Modifier.height(14.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(
                        checked = confirmed,
                        onCheckedChange = { confirmed = it },
                        colors = CheckboxDefaults.colors(checkedColor = Danger, uncheckedColor = TextFaint),
                    )
                    Text(
                        "我已明白：${if (isLast) "整个条目目录及其中全部文件" else "该文件及其同名附属文件"}将被永久删除，无法恢复。",
                        fontSize = 13.sp,
                        color = Color.White.copy(alpha = 0.8f),
                        lineHeight = 19.sp,
                    )
                }
                error?.let {
                    Spacer(Modifier.height(10.dp))
                    Text(it, fontSize = 13.sp, color = Danger)
                }
                Spacer(Modifier.height(14.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    DangerButton("删除", enabled = confirmed, busy = busy) {
                        scope.launch {
                            busy = true
                            error = null
                            run(selected.sorted().joinToString(",").ifEmpty { null })
                                .onSuccess { result = it }
                                .onFailure { error = friendlyMessage(it) }
                            busy = false
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
        }
    }
}

/**
 * 删除单的附加选项（iOS `DeleteOptionsSection`、Web `library-delete-options.tsx` 同款）：
 * 来自别的模块登记的删除参与方，媒体库不认识它们；不可勾的显示原因，勾上会发生什么逐行说明。
 */
@Composable
private fun DeleteOptionsSection(
    preview: ItemDeletePreviewView?,
    failed: Boolean,
    selected: Set<String>,
    enabled: Boolean,
    onToggle: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        when {
            failed -> Text("附加选项暂时加载不出来，这次只删除媒体库文件。", fontSize = 11.sp, color = TextFaint)
            preview == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = TextFaint)
                Spacer(Modifier.width(8.dp))
                Text("正在检查关联的下载任务…", fontSize = 11.sp, color = TextFaint)
            }
            else -> {
                if (preview.linkedBytes > 0) {
                    Text(
                        "其中 ${McFormat.bytes(preview.linkedBytes)} 与别处的文件是同一份数据（硬链接）：只删媒体库文件不会释放这部分空间。",
                        fontSize = 13.sp,
                        color = Color.White.copy(alpha = 0.7f),
                        lineHeight = 19.sp,
                    )
                }
                preview.options.forEach { option ->
                    val on = option.available && option.key in selected
                    Column(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.03f))
                            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
                            .padding(start = 4.dp, end = 14.dp, top = 4.dp, bottom = 12.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(
                                checked = on,
                                onCheckedChange = { onToggle(option.key) },
                                enabled = option.available && enabled,
                                colors = CheckboxDefaults.colors(checkedColor = Danger, uncheckedColor = TextFaint),
                            )
                            Column(Modifier.alpha(if (option.available) 1f else 0.5f)) {
                                Text(option.label, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = TextPrimary)
                                if (option.help.isNotEmpty()) {
                                    Text(option.help, fontSize = 11.sp, color = TextFaint, lineHeight = 16.sp)
                                }
                            }
                        }
                        Column(Modifier.padding(start = 44.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            if (option.available) {
                                option.lines.forEach { line ->
                                    Text(
                                        line.text,
                                        fontSize = 12.sp,
                                        lineHeight = 17.sp,
                                        color = when (line.tone) {
                                            "warn" -> Warning
                                            "danger" -> Danger
                                            else -> Color.White.copy(alpha = 0.7f)
                                        },
                                    )
                                }
                            } else {
                                Text("这次不能勾选：${option.reason ?: "不可用"}", fontSize = 12.sp, color = TextMuted)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 结果步：勾选的选项在后台跑，当场跟进到结束（失败了去「活动 → 任务」重试） */
@Composable
private fun DeleteFollowUpRow(item: DeleteFollowUpView, loadJob: suspend (String) -> Result<JobView>) {
    var job by remember { mutableStateOf<JobView?>(null) }
    LaunchedEffect(item.jobId) {
        while (true) {
            loadJob(item.jobId).onSuccess { job = it }
            if (job?.status in setOf("succeeded", "failed", "cancelled")) break
            delay(1500)
        }
    }
    val current = job
    val message = when (current?.status) {
        "succeeded" -> (current.result?.get("message") as? JsonPrimitive)?.contentOrNull ?: "已完成"
        "failed" -> "没能完成：${current.error?.message?.ifEmpty { null } ?: "未知原因"}。可在「活动 → 任务」里重试"
        "cancelled" -> "已取消"
        else -> "正在处理…"
    }
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.03f))
            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(item.label, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = TextPrimary)
        Text(message, fontSize = 12.sp, color = if (current?.status == "failed") Danger else TextMuted)
    }
}

/** 立即清理确认弹窗（iOS `purge` 的两段文案逐字同款） */
@Composable
private fun PurgeFileDialog(file: LibraryFileView, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val seeding = file.purgeAfter == null
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Color(0xFF171A23),
        title = { Text("立即清理「${file.fileName}」？", style = McType.bodySemibold, color = TextPrimary) },
        text = {
            Text(
                if (seeding) "该文件留在原位置（原盘目录或没能移入回收站），清理会直接从磁盘删除，此操作不可恢复。若它仍被下载器做种，清理会中断做种任务（PT 站请留意保种要求）。"
                else "将立即从回收站删除该文件，不再等待保留期，此操作不可恢复。",
                style = McType.sub,
                color = TextMuted,
            )
        },
        confirmButton = { TextButton(onClick = onConfirm) { Text("立即清理", color = Danger) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消", color = TextMuted) } },
    )
}

/** 分辨率标注（iOS `resolutionLabel` / Web 同口径）：4320p→8K、2160p→4K、1440p→2K */
private fun resolutionLabel(raw: String): String {
    val normalized = raw.trim().lowercase()
    val key = if (normalized.isNotEmpty() && normalized.all(Char::isDigit)) normalized + "p" else normalized
    return when (key) {
        "4320p" -> "8K"
        "2160p" -> "4K"
        "1440p" -> "2K"
        "4k" -> "4K"
        "2k" -> "2K"
        else -> raw
    }
}

/** 视频编码短名（iOS `codecs` 映射） */
private fun codecLabel(raw: String?): String? = raw?.let {
    when (it.lowercase()) {
        "hevc", "h265" -> "HEVC"
        "h264" -> "H.264"
        "av1" -> "AV1"
        "vc1" -> "VC-1"
        "mpeg2video" -> "MPEG-2"
        "vp9" -> "VP9"
        else -> it.uppercase()
    }
}

/** 帧率：整数不带 .0（iOS `frameRate` 同款） */
private fun frameRateLabel(raw: Float?): String? = raw?.takeIf { it > 0 }?.let { f ->
    val rounded = kotlin.math.round(f * 1000) / 1000
    if (rounded % 1f == 0f) "${rounded.toInt()} fps" else "$rounded fps"
}

/** 片源标注（iOS `source` 映射）：原盘 / 最低档（人工标注）/ 人工标注后缀 / 未识别 */
private fun mediaSourceLabel(file: LibraryFileView): String {
    val source = file.mediaSource?.takeIf { it.isNotEmpty() } ?: return "未识别"
    val label = when (source) {
        "user-lowest" -> "最低档（人工标注）"
        "Disc" -> "原盘"
        else -> source
    }
    return label + if (file.mediaSourceManual && source != "user-lowest") "（人工标注）" else ""
}

/** 待回收的清理倒计时（iOS `purgeCountdown` 逐字同款）：null = 不自动清理（旧数据） */
private fun purgeCountdown(raw: String?): String {
    if (raw == null) return "不自动清理"
    val instant = runCatching { java.time.OffsetDateTime.parse(raw).toInstant() }
        .recoverCatching { java.time.Instant.parse(raw) }
        .getOrNull() ?: return "即将自动清理"
    val ms = instant.toEpochMilli() - System.currentTimeMillis()
    if (ms <= 0) return "即将自动清理"
    val days = (ms / 86_400_000).toInt()
    val hours = ((ms % 86_400_000) / 3_600_000).toInt()
    return when {
        days > 0 -> "预计 $days 天 $hours 小时后自动清理"
        hours > 0 -> "预计 $hours 小时后自动清理"
        else -> "预计 1 小时内自动清理"
    }
}

/** 保存目录（iOS `directory(_:)`）：去掉末尾分隔符、取最后一段之前的路径；没有分隔符回「—」 */
private fun directoryOf(path: String): String {
    var normalized = path
    while (normalized.endsWith("/") || normalized.endsWith("\\")) normalized = normalized.dropLast(1)
    val index = normalized.indexOfLast { it == '/' || it == '\\' }
    return when {
        index < 0 -> "—"
        index == 0 -> normalized.take(1)
        else -> normalized.take(index)
    }
}
