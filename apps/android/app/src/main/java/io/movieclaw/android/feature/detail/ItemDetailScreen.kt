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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.PlayArrow
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
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.RowScope
import io.movieclaw.android.core.designsystem.TextPrimary
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Delete
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
import io.movieclaw.android.core.designsystem.Accent2
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
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

@HiltViewModel
class ItemDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
    private val preconnect: io.movieclaw.android.core.playback.PlaybackPreconnect,
    private val eventStream: io.movieclaw.android.core.network.EventStream,
) : ViewModel() {

    val libraryId: Long = savedStateHandle.get<String>("libraryId")?.toLongOrNull() ?: -1L
    val itemId: Long = savedStateHandle.get<String>("itemId")?.toLongOrNull() ?: -1L

    data class Detail(
        val item: LibraryItemDetailView,
        val episodes: Map<Int, List<EpisodeView>> = emptyMap(),
    )

    private val _state = MutableStateFlow<Loadable<Detail>>(Loadable.Loading)
    val state = _state.asStateFlow()

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

    fun load() {
        viewModelScope.launch {
            _state.value = Loadable.Loading
            val origin = repository.ui.value.origin
            if (origin == null) {
                _state.value = Loadable.Failed("尚未连接服务器")
                return@launch
            }
            try {
                val api = apiFactory.forOrigin(origin)
                val detail = api.libraryItemDetail(libraryId, itemId).dataOrThrow()
                val episodes = if (detail.kind == "tv") {
                    detail.seasons.associateWith { season ->
                        api.seasonEpisodes(libraryId, itemId, season).dataOrThrow().episodes
                    }
                } else {
                    emptyMap()
                }
                _state.value = Loadable.Ready(Detail(detail, episodes))
                episodesBySeason = episodes
                // 初始选中：服务端续播那一个单元（跨季第一个没看的在库集）。
                // 季的回退链照 iOS `SeasonEpisodesSection.currentSeason`：
                // 续播那季 → 第一个在库的季 → 第一个季
                val seed = pickResumeEpisode(detail, episodes).takeIf { it.second > 0 }
                    ?: detail.seasons.firstOrNull()?.let { season ->
                        episodes[season]?.firstOrNull()?.let { Triple(season, it.episodeNumber, it.name) }
                    }
                seedUnit = seed?.let { SelectedUnit(it.first, it.second) }
                val ownedSeasons = detail.files.map { it.seasonNumber }.toSet()
                _selectedSeason.value = seed?.first?.takeIf { episodes.containsKey(it) }
                    ?: detail.seasons.firstOrNull { it in ownedSeasons }
                    ?: detail.seasons.firstOrNull()
                _selectedEpisode.value = seedUnit
                    ?: _selectedSeason.value?.let { s ->
                        episodes[s]?.firstOrNull()?.let { SelectedUnit(s, it.episodeNumber) }
                    }
            } catch (e: Exception) {
                _state.value = Loadable.Failed(friendlyMessage(e))
            }
        }
    }

    /**
     * 换季：**连带把选中集切到这一季**（iOS `SeasonEpisodesSection.load(reset:)` 同口径）——
     * 优先「初始续播那一集」（若正好是这一季且在库）、否则这一季第一个没看的在库集、
     * 再次第一个在库集、最后第一集。只换季不换集的话，播放键会拿「第 3 季 + 第 1 季的那一集」
     * 去起播，服务端找不到就退回第一季——现象与用户报的完全一致。
     */
    fun selectSeason(season: Int) {
        _selectedSeason.value = season
        val list = episodesBySeason[season].orEmpty()
        val picked = seedUnit?.takeIf { it.season == season && list.any { e -> e.episodeNumber == it.episode && e.owned } }?.episode
            ?: list.firstOrNull { !it.played && it.owned }?.episodeNumber
            ?: list.firstOrNull { it.owned }?.episodeNumber
            ?: list.firstOrNull()?.episodeNumber
        if (picked != null) _selectedEpisode.value = SelectedUnit(season, picked)
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

    fun loadMarks(mediaItemId: Long) {
        viewModelScope.launch {
            val origin = repository.ui.value.origin ?: return@launch
            // 查不到收藏态不影响浏览，心按未收藏渲染即可
            runCatching {
                apiFactory.forOrigin(origin).playbackMarks(mediaItemId).dataOrThrow()
            }.onSuccess { _marks.value = it }
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
            }.onSuccess {
                _marks.value = it
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
                // 标已看会清零续播位置、取消会清零播放次数——结论以服务端为准，写完重查
                runCatching {
                    apiFactory.forOrigin(origin).playbackMarks(
                        mediaItemId = mediaItemId,
                        seasonNumber = seasonNumber,
                        episodeNumber = episodeNumber,
                    ).dataOrThrow()
                }.onSuccess { fresh -> _marks.value = fresh }
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
        }
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
        }.map { }
    }

    /** 立即清理一个待回收的文件（真删磁盘，不等保留期） */
    suspend fun purgeFile(fileId: Long): Result<Unit> {
        val origin = repository.ui.value.origin
            ?: return Result.failure(IllegalStateException("尚未连接服务器"))
        return runCatching {
            apiFactory.forOrigin(origin).purgeLibraryFile(libraryId, itemId, fileId).dataOrThrow()
        }.map { }
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
    vm: ItemDetailViewModel = hiltViewModel(),
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val selectedSeason by vm.selectedSeason.collectAsStateWithLifecycle()
    /** 选中的单元（季 + 集）：播放键、续播点、已看、版本都以它为准（iOS SelectedEpisode） */
    val selectedUnit by vm.selectedEpisode.collectAsStateWithLifecycle()
    val marks by vm.marks.collectAsStateWithLifecycle()
    val resume by vm.resume.collectAsStateWithLifecycle()
    val origin = vm.origin
    val feedback = LocalFeedback.current
    val permissions = io.movieclaw.android.core.session.LocalPermissions.current
    // 文件区动作：删除走底部确认单（iOS `DeleteFileSheet`），立即清理走确认弹窗
    var trashTarget by remember { mutableStateOf<io.movieclaw.android.core.model.LibraryFileView?>(null) }
    var purgeTarget by remember { mutableStateOf<io.movieclaw.android.core.model.LibraryFileView?>(null) }
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
        is Loadable.Failed -> ErrorPane(message = s.message, onRetry = vm::load)
        is Loadable.Ready -> Column(
            Modifier
                .fillMaxSize()
                .background(Bg)
                .verticalScroll(rememberScrollState()),
        ) {
            Hero(
                detail = s.value.item,
                origin = origin,
                onBack = onBack,
                onPlay = onPlay,
                libraryId = libraryId,
                episodes = s.value.episodes,
                marks = marks,
                resume = resume,
                unit = selectedUnit,
                onResumeUnitChanged = { season, episode -> vm.loadResume(s.value.item.mediaItemId, season, episode) },
                onToggleFavorite = { vm.toggleFavorite(s.value.item.mediaItemId) },
                onTogglePlayed = { season, episode ->
                    vm.togglePlayed(s.value.item.mediaItemId, season, episode)
                },
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
                        origin = origin,
                        onPlay = onPlay,
                        libraryId = libraryId,
                        itemId = itemId,
                        itemTitle = s.value.item.title,
                    )
                }
                CastSection(detail = s.value.item, origin = origin, onOpenPerson = onOpenPerson)
                // 文件区（iOS `isMovie ? detail.files : selectedEpisode.files`）：
                // 电影 = 整条的文件；剧集 = 当前选中那一集的文件（没选中就不显示这一区）
                val sectionFiles = sectionFilesFor(s.value.item, selectedUnit, s.value.episodes)
                if (sectionFiles.isNotEmpty()) {
                    FilesSection(
                        detail = s.value.item,
                        files = sectionFiles,
                        canManage = permissions.canManageLibraries,
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
                Spacer(Modifier.height(32.dp))
            }
        }
    }

    // 文件区动作的宿主：删除底部单（iOS `DeleteFileSheet`）与立即清理确认弹窗。
    // 放在 when 之外——两者都是窗口级浮层，不该跟着页面一起滚
    val readyDetail = (state as? Loadable.Ready)?.value?.item
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
    /** AI 字幕生成的状态与动作（同 iOS `TrackSubtitleGenButton`：仅管理员 + 文件在盘才出现） */
    subtitleGen: SubtitleGenUiState,
    isAdmin: Boolean,
    subtitleGenActions: SubtitleGenActions,
    /** 正文其余部分（分集 / 演职员 / 文件）：与简介同用那一块上提 124 的列 */
    content: @Composable ColumnScope.() -> Unit,
) {
    // 版本/文件、音轨源、discSource 都跟着**选中的那一集**走（iOS `selectedEpisode.files`）：
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

    Column {
        Box(Modifier.fillMaxWidth().height(heroHeight())) {
            RemoteImage(
                url = detail.backdropUrl ?: detail.posterUrl,
                origin = origin,
                contentDescription = detail.title,
                modifier = Modifier.fillMaxSize(),
            )
            Box(
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            0f to Color.Black.copy(alpha = 0.42f),
                            0.22f to Color.Transparent,
                            0.52f to Color.Black.copy(alpha = 0.28f),
                            0.84f to Color.Black.copy(alpha = 0.8f),
                            1f to Bg,
                        )
                    ),
            )
            Row(
                Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(horizontal = 8.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                McNavButton(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回", onClick = onBack)
                // 网页这里只有一颗「更多操作」（搜索资源 / 加入合集 / 分享 / 洗版 /
                // 重新刮削 / 换海报 / 转移 / 删除 / 清除观看记录）。
                // 那个菜单还没接，先不挂两颗点不动的键——假控件。
            }
        }

        Column(Modifier.padding(horizontal = McMetrics.pagePadding).offset(y = (-124).dp)) {
            // 片名 Logo（网页/iOS 同款，iOS titleArt）：区高固定 96dp——加载前后下面的
            // 元信息/类型行不跳；本地资产存的是给电视端用的原图；**加载失败或没有
            // Logo 都回退文字片名**（RemoteImage 的 fallback 正是失败回落）
            Box(Modifier.fillMaxWidth().height(96.dp), contentAlignment = Alignment.BottomStart) {
                if (detail.logoUrl.isNullOrBlank()) {
                    Text(
                        detail.title,
                        style = McType.title.copy(lineHeight = 36.sp),
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
                                style = McType.title.copy(lineHeight = 36.sp),
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
                style = McType.sub,
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
                    style = McType.sub,
                    color = Color.White.copy(alpha = 0.72f),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Spacer(Modifier.height(13.dp))
            TrackRow("音轨", audioText, onClick = if (audioOptions.isEmpty()) null else {{ sheet = "audio" }})
            Spacer(Modifier.height(13.dp))
            TrackRow(
                "字幕",
                subtitleText,
                dim = subtitleOptions.isEmpty(),
                onClick = if (subtitleOptions.isEmpty()) null else {{ sheet = "subtitle" }},
            )

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

            // ── AI 生成字幕入口（iOS `TrackSubtitleGenButton`：仅管理员 + 文件在盘）──
            // 三态：未接 AI = 「接入… 去接入」引导（点了进「模型接入」）；运行中 / 有终态问题 =
            // 状态徽章（忽略门禁，永远显示）；空闲 = 「AI 生成字幕」按钮（点开预检弹层）。
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
                            // 原盘（ISO / BDMV 目录）本机引擎读不了盘内结构，协商时特殊处理
                            discSource = file?.container == "iso" || file?.container == "bluray",
                        )
                    )
                },
                shape = RoundedCornerShape(999.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = Color(0xFF141821)),
                contentPadding = PaddingValues(0.dp),
                elevation = null,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6)))),
            ) {
                Icon(Icons.Rounded.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(playLabel, style = McType.bodySemibold)
            }

            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GlassPill(
                    "收藏",
                    if (marks.isFavorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                    marks.isFavorite,
                ) { onToggleFavorite() }
                GlassPill("标为已看", Icons.Rounded.CheckCircle, marks.played) {
                    onTogglePlayed(resumeSeason.takeIf { it > 0 }, resumeEpisode.takeIf { it > 0 })
                }
            }

            detail.localMeta?.plot?.takeIf { it.isNotBlank() }?.let { plot ->
                Spacer(Modifier.height(18.dp))
                Text(
                    plot,
                    style = McType.body.copy(lineHeight = 30.sp),
                    color = TextMuted,
                    maxLines = if (expanded) Int.MAX_VALUE else 4,
                    overflow = TextOverflow.Ellipsis,
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

            // 正文其余部分都挂在这块**上提 124** 的列里：偏移只作用到这里，
            // 整块一起上提，简介与下一段之间才不会留下一个 124 高的空洞
            // （之前分集/文件在偏移列之外，那块空白就是它）
            content()
        }
    }
}

@Composable
private fun heroHeight(): androidx.compose.ui.unit.Dp =
    (androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp * 0.52f)
        .coerceAtMost(420f).dp

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
    /** 本机渲染不了/服务端给不了地址时的原因；非空则置灰不可选（与播放器菜单同口径） */
    val unavailableReason: String? = null,
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
                    unavailableReason = TrackLabels.subtitleUnsupportedReason(kindOfCodec(s.codec)),
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
                val reason = option.unavailableReason
                Row(
                    Modifier
                        .fillMaxWidth()
                        .then(if (reason == null) Modifier.clickable { onPick(option.ref) } else Modifier)
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
                            color = if (reason != null) TextFaint else TextPrimary,
                            maxLines = 2,
                        )
                        if (reason != null) {
                            Text(reason, style = McType.caption2, color = TextFaint)
                        } else if (option.isDefault) {
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
            modifier = Modifier.padding(horizontal = McMetrics.pagePadding),
        )
        Spacer(Modifier.height(10.dp))
        LazyRow(
            contentPadding = PaddingValues(horizontal = McMetrics.pagePadding),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(people, key = { "${it.name}-${it.role}" }) { person ->
                Column(
                    Modifier
                        .width(104.dp)
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
    origin: String?,
    onPlay: (PlayTarget) -> Unit,
    libraryId: Long,
    itemId: Long,
    itemTitle: String,
) {
    val seasonLabel = { season: Int ->
        val name = if (season == 0) "特别篇" else "第 $season 季"
        if (season in ownedSeasons) name else "$name · 未入库"
    }
    Column(Modifier.padding(vertical = 6.dp)) {
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
            // 「在库 X / Y 集」（网页/iOS 都有这一行）：一眼看出这一季收了多少
            val seasonEpisodes = episodes[selected].orEmpty()
            if (seasonEpisodes.isNotEmpty()) {
                Spacer(Modifier.width(10.dp))
                Text(
                    "在库 ${seasonEpisodes.count { it.owned }} / ${seasonEpisodes.size} 集",
                    style = McType.sub,
                    color = TextFaint,
                )
            }
        }

        // 分集横滚卡：一季一屏，点一集 = 选中它（播放是详情页那颗播放键，选中的集就是它要播的）
        val list = episodes[selected] ?: emptyList()
        val picked = selectedEpisode ?: list.firstOrNull()?.episodeNumber
        Spacer(Modifier.height(12.dp))
        val strip = rememberLazyListState()
        // 进页/换季时把选中那一集滚到可见处（续播进来的那一集常常在列表深处，
        // 不滚的话得手动滑几十屏；网页/iOS 同样会滚到当前集）
        LaunchedEffect(selected, list.size, picked) {
            val index = list.indexOfFirst { it.episodeNumber == picked }
            if (index > 0) strip.animateScrollToItem((index - 1).coerceAtLeast(0))
        }
        LazyRow(
            state = strip,
            contentPadding = PaddingValues(horizontal = McMetrics.pagePadding),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(list, key = { it.episodeNumber }) { episode ->
                EpisodeCard(
                    episode = episode,
                    selected = episode.episodeNumber == picked,
                    origin = origin,
                    onSelect = { onPickEpisode(episode.episodeNumber) },
                )
            }
        }
    }
}

/**
 * 分集横滚卡（网页 `EpisodeCard`）：200 宽、16:9 剧照 + 「N. 集名」。
 *
 * 观看状态与首页「最近观看」卡同一套语言：看了一半底部细进度条、看完右上角绿对勾，
 * 扫一眼就知道追到哪了；缺集整卡压暗 + 右上角「缺」；选中那集套一圈亮环。
 * 点一集**只切换选中**（网页行为），要播的是详情页那颗播放键。
 */
@Composable
private fun EpisodeCard(
    episode: EpisodeView,
    selected: Boolean,
    origin: String?,
    onSelect: () -> Unit,
) {
    val progress = if (episode.played) 100f else episode.progressPercent?.toFloat()
    Column(
        Modifier
            .width(200.dp)
            .clickable(onClick = onSelect)
            .then(if (episode.owned) Modifier else Modifier.alpha(0.45f)),
    ) {
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
            RemoteImage(
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
            // 右上角状态位：缺集与已看对勾同排（看过之后文件丢了两者会同时出现）
            if (!episode.owned || episode.played) {
                Row(
                    Modifier.align(Alignment.TopEnd).padding(6.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (!episode.owned) {
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
                episode.owned && episode.played.not() && episode.positionMs > 0 -> Box(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .padding(horizontal = 6.dp, vertical = 6.dp)
                        .fillMaxWidth()
                        .height(3.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(Accent2.copy(alpha = 0.6f)),
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
    Column(Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("文件", style = McType.subheadlineSemibold, color = TextMuted)
            Text("${files.size}", fontSize = 12.sp, color = TextFaint)
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
                .verticalScroll(rememberScrollState())
                .padding(horizontal = McMetrics.pagePadding, vertical = 4.dp),
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
