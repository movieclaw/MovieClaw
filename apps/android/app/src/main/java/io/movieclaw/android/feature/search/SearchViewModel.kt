package io.movieclaw.android.feature.search

import io.movieclaw.android.core.designsystem.FeedbackTone
import io.movieclaw.android.core.designsystem.McNotice
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.model.DiscoveredTitle
import io.movieclaw.android.core.model.DownloadSubmitRequest
import io.movieclaw.android.core.model.DownloadTargetPrefView
import io.movieclaw.android.core.model.DownloaderView
import io.movieclaw.android.core.model.GrabPayload
import io.movieclaw.android.core.model.LibraryItemView
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.ManualDownloadCandidateView
import io.movieclaw.android.core.model.ManualDownloadTargetRequest
import io.movieclaw.android.core.model.ManualDownloadTargetView
import io.movieclaw.android.core.model.SearchHistoryItem
import io.movieclaw.android.core.model.SearchStreamDone
import io.movieclaw.android.core.model.SearchStreamStart
import io.movieclaw.android.core.model.SiteStreamError
import io.movieclaw.android.core.model.SiteStreamResult
import io.movieclaw.android.core.model.TorrentCategory
import io.movieclaw.android.core.model.TorrentHit
import io.movieclaw.android.core.model.TitleSearchRequest
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.EventStream
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

enum class SearchMode(val label: String) {
    TITLES("标题"),
    TORRENTS("资源"),
    LIBRARY("库内"),
}

/** 一个站点的流式结果块(边收边渲染) */
data class SiteBlock(
    val siteId: String,
    val siteName: String,
    val items: List<TorrentHit> = emptyList(),
    val error: String? = null,
    val elapsedMs: Int = 0,
)

/**
 * 「选择保存位置」弹窗的整套状态（照 iOS `TorrentActionsState` + `DownloadTargetSheet`）。
 *
 * [request] 为 null = 弹层关着。有保存位置记忆时先走 [confirmOnly] 的确认条，
 * 用户点「更改 / 不再记住」才进完整弹窗；记忆失效时把原因写进 request.reason 直接展开。
 */
data class DownloadFlow(
    val request: DownloadTargetRequest? = null,
    val remembered: DownloadTargetPrefView? = null,
    val confirmOnly: Boolean = false,
    val target: ManualDownloadTargetView? = null,
    val candidates: List<ManualDownloadCandidateView> = emptyList(),
    val selectedCandidate: ManualDownloadCandidateView? = null,
    /** 「这是哪部作品？」确认模式：自动识别没收敛（或种子没身份）时常驻候选与搜索框 */
    val picking: Boolean = false,
    val hint: String? = null,
    val hintDraft: String = "",
    val showOther: Boolean = false,
    val downloaders: List<DownloaderView> = emptyList(),
    val dirs: Set<String>? = null,
    val memberLibraries: List<LibraryView> = emptyList(),
    val memberLibrariesLoaded: Boolean = false,
    val downloaderId: Long? = null,
    val selected: String? = null,
    val remember: Boolean = false,
    val loadingTarget: Boolean = false,
    val loadingDownloaders: Boolean = false,
    val busy: Boolean = false,
    val error: String? = null,
)

@HiltViewModel
class SearchViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val eventStream: EventStream,
    private val sessionRepository: SessionRepository,
    private val json: Json,
    private val modeMemory: SearchModeMemory,
) : ViewModel() {

    /** 上次停留的分区（冷启动读盘后才有值；null = 调用方按资源起步） */
    val rememberedMode: kotlinx.coroutines.flow.StateFlow<SearchMode?> = modeMemory.mode

    fun rememberMode(mode: SearchMode) = modeMemory.remember(mode)

    data class UiState(
        val mode: SearchMode = SearchMode.TORRENTS,
        val query: String = "",
        val category: TorrentCategory? = null,
        val searching: Boolean = false,
        val error: String? = null,
        val notice: McNotice? = null,
        // 站点搜索(流式)
        val start: SearchStreamStart? = null,
        val blocks: List<SiteBlock> = emptyList(),
        val done: SearchStreamDone? = null,
        // 标题搜索
        val titles: List<DiscoveredTitle> = emptyList(),
        // 库内搜索（v0.31 /search/library：相关度平铺 + 人物行 + 命中原因 + 游标分页）
        val librarySearch: io.movieclaw.android.core.model.LibrarySearchView? = null,
        /** 人物下钻中（点人物行：只看这个人的库内作品） */
        val libraryPerson: io.movieclaw.android.core.model.LibrarySearchPerson? = null,
        val history: List<SearchHistoryItem> = emptyList(),
        val submitting: String? = null,
        // ── 下载 / 手动选种（batch 3）──────────────
        /** 资源操作面板的那一条（null = 面板关着） */
        val actionHit: TorrentHit? = null,
        val download: DownloadFlow = DownloadFlow(),
        /** 按行记的下载状态：终态不可再点，error 可重试 */
        val downloadStates: Map<String, TorrentSubmitState> = emptyMap(),
        /** 按行记的投递状态（手动选种模式） */
        val grabStates: Map<String, TorrentSubmitState> = emptyMap(),
        /** 手动选种目标订阅（`search?forSub=` 进来时写入） */
        val grabTarget: Pair<Long, String>? = null,
        /** 本页的搜索关键词（种子身份识别失败时给候选当线索） */
        val keyword: String = "",
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = sessionRepository.ui.value.origin

    private var searchJob: Job? = null

    /** 预检请求序号：只允许最后一次请求更新界面（切候选 / 换下载器时连点不发散） */
    private var preflightSeq = 0

    init {
        loadHistory()
        modeMemory.ensureLoaded()
    }

    fun onMode(mode: SearchMode) = _ui.update { it.copy(mode = mode, error = null) }
    fun onQuery(value: String) = _ui.update { it.copy(query = value) }
    fun onCategory(category: TorrentCategory?) = _ui.update { it.copy(category = category) }
    fun consumeNotice() = _ui.update { it.copy(notice = null) }

    /**
     * 带词/带分区进入（详情页「搜索资源」→ `search?q=&tab=&cat=`）：先预填再由页面自动搜一次。
     * mode 传 null = 维持当前分区（路由 tab 缺省时的语义：资源）。
     * category 非空 = 按影片类型收窄资源分类（v0.32，Web `scopeOfMediaKind` /
     * iOS `SearchScope.ofMediaKind` 同款：电影只搜电影分类、剧集只搜剧集分类，结果页
     * 分类胶囊会高亮，可一键放宽）。
     */
    fun prefill(mode: SearchMode?, keyword: String, category: TorrentCategory? = null) {
        _ui.update {
            it.copy(
                mode = mode ?: it.mode,
                query = keyword.ifBlank { it.query },
                category = category ?: it.category,
            )
        }
    }

    /**
     * 手动选种模式（订阅详情的「手动选种」→ `search?forSub=`）：这一页搜出的结果
     * 全部投给这条订阅（`POST /subscriptions/{id}/selected-torrent-downloads`）。
     */
    fun prefillGrabTarget(subscriptionId: Long, title: String) {
        _ui.update { it.copy(grabTarget = subscriptionId to title) }
    }

    fun loadHistory() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).searchHistory().dataOrThrow() }
                .onSuccess { list -> _ui.update { it.copy(history = list) } }
        }
    }

    fun clearHistory() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).clearSearchHistory() }
            _ui.update { it.copy(history = emptyList()) }
        }
    }

    fun submit(keywordOverride: String? = null) {
        val state = _ui.value
        val keyword = (keywordOverride ?: state.query).trim()
        if (keyword.isEmpty() && state.mode != SearchMode.TORRENTS) {
            _ui.update { it.copy(error = "请输入关键词") }
            return
        }
        searchJob?.cancel()
        _ui.update {
            it.copy(
                query = keyword,
                // 本页关键词：种子身份识别失败时给落点弹窗当候选线索
                keyword = keyword,
                searching = true,
                error = null,
                start = null,
                blocks = emptyList(),
                done = null,
                titles = emptyList(),
                librarySearch = null,
                libraryPerson = null,
            )
        }
        when (state.mode) {
            SearchMode.TORRENTS -> searchTorrents(keyword, state.category)
            SearchMode.TITLES -> searchTitles(keyword)
            SearchMode.LIBRARY -> searchLibrary(keyword)
        }
    }

    private fun searchTitles(keyword: String) {
        searchJob = viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).searchTitles(TitleSearchRequest(query = keyword)).dataOrThrow()
            }
                .onSuccess { view -> _ui.update { it.copy(titles = view.titles, searching = false) } }
                .onFailure { e -> _ui.update { it.copy(error = friendlyMessage(e), searching = false) } }
            loadHistory()
        }
    }

    private fun searchLibrary(keyword: String) {
        searchJob = viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).searchLibrary(q = keyword).dataOrThrow()
            }
                .onSuccess { view -> _ui.update { it.copy(librarySearch = view, libraryPerson = null, searching = false) } }
                .onFailure { e -> _ui.update { it.copy(error = friendlyMessage(e), searching = false) } }
        }
    }

    /** 点人物行下钻：只看这个人的库内作品 */
    fun drillPerson(person: io.movieclaw.android.core.model.LibrarySearchPerson) {
        val keyword = _ui.value.query
        searchJob = viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(searching = true, error = null) }
            runCatching {
                apiFactory.forOrigin(origin).searchLibrary(q = keyword, personId = person.id).dataOrThrow()
            }
                .onSuccess { view -> _ui.update { it.copy(librarySearch = view, libraryPerson = person, searching = false) } }
                .onFailure { e -> _ui.update { it.copy(error = friendlyMessage(e), searching = false) } }
        }
    }

    /** 从人物下钻回到整页结果 */
    fun exitPerson() {
        submit()
    }

    /** 游标续页：把新的一页追加在后面（没有 next_cursor 就不动） */
    fun loadMoreLibrary() {
        val state = _ui.value
        val view = state.librarySearch ?: return
        val cursor = view.nextCursor ?: return
        if (state.searching) return
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(searching = true) }
            runCatching {
                apiFactory.forOrigin(origin).searchLibrary(
                    q = view.query,
                    personId = view.personId,
                    cursor = cursor,
                ).dataOrThrow()
            }.onSuccess { page ->
                _ui.update {
                    it.copy(
                        searching = false,
                        librarySearch = page.copy(items = view.items + page.items),
                    )
                }
            }.onFailure { _ui.update { s -> s.copy(searching = false) } }
        }
    }

    /** 站点搜索:SSE 逐站点渲染(快的先出,单站失败不影响整体) */
    private fun searchTorrents(keyword: String, category: TorrentCategory?) {
        val params = buildList {
            add("keyword=" + java.net.URLEncoder.encode(keyword, "UTF-8"))
            category?.let { add("categories=${it.id}") }
        }.joinToString("&")
        searchJob = viewModelScope.launch {
            runCatching {
                eventStream.reliableEvents("search/torrents/stream?$params").collect { event ->
                    when (event.name) {
                        "start" -> {
                            val start = json.decodeFromString<SearchStreamStart>(event.data)
                            _ui.update {
                                it.copy(
                                    start = start,
                                    blocks = start.sites.map { site ->
                                        SiteBlock(siteId = site.siteId, siteName = site.siteName)
                                    },
                                )
                            }
                        }
                        "site_result" -> {
                            val result = json.decodeFromString<SiteStreamResult>(event.data)
                            _ui.update { state ->
                                state.copy(blocks = state.blocks.mergeResult(result))
                            }
                        }
                        "site_error" -> {
                            val error = json.decodeFromString<SiteStreamError>(event.data)
                            _ui.update { state ->
                                state.copy(
                                    blocks = state.blocks.map { block ->
                                        if (block.siteId == error.siteId) {
                                            block.copy(error = error.error, elapsedMs = error.elapsedMs)
                                        } else {
                                            block
                                        }
                                    },
                                )
                            }
                        }
                        "done" -> {
                            val done = json.decodeFromString<SearchStreamDone>(event.data)
                            _ui.update { it.copy(done = done, searching = false) }
                            loadHistory()
                        }
                    }
                }
            }.onFailure { e ->
                _ui.update { it.copy(error = friendlyMessage(e), searching = false) }
            }
        }
    }

    /* ---------------- 下载 / 手动选种 ----------------
     *
     * 流程照 iOS `TorrentActionsState`：点行 → 资源操作面板（查看详情 / 投给订阅 / 下载）
     * → 点「下载」时按保存位置记忆决定弹确认条还是完整落点弹窗 → 提交。
     * 成员的服务端强制（不能带目录 / 下载器 / 智能入库）在落点候选层就体现出来。
     */

    /** 点一行：打开资源操作面板 */
    fun openActions(hit: TorrentHit) = _ui.update { it.copy(actionHit = hit) }

    fun closeActions() = _ui.update { it.copy(actionHit = null) }

    /** 面板里点「下载」：先查这一分类有没有保存位置记忆 */
    fun startDownload(hit: TorrentHit) {
        val request = DownloadTargetRequest.of(hit, _ui.value.keyword) ?: return
        val state = _ui.value.downloadStates[request.hitKey] ?: TorrentSubmitState.IDLE
        if (state == TorrentSubmitState.SUBMITTING || state == TorrentSubmitState.DONE ||
            state == TorrentSubmitState.EXISTS
        ) {
            return
        }
        _ui.update { it.copy(actionHit = null) }
        openTargetSheet(request)
    }

    /** 打开落点弹窗（有记忆先弹确认条；记忆失效把原因摆在弹窗顶上） */
    private fun openTargetSheet(request: DownloadTargetRequest) {
        val permissions = io.movieclaw.android.core.session.Permissions.of(sessionRepository.ui.value.session)
        val isAdmin = permissions.isAdmin
        _ui.update { it.copy(download = DownloadFlow(request = request)) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            var remembered: DownloadTargetPrefView? = null
            var dirs: Set<String>? = null
            if (isAdmin) {
                // 保存位置记忆只对管理员记（服务端也不给成员返回）
                remembered = runCatching { api.downloadTargetPrefs().dataOrThrow() }
                    .getOrDefault(emptyList())
                    .firstOrNull { it.category == request.category }
                if (remembered != null) {
                    // 记忆是否失效要看下载器目录；拉不到就不判失效
                    dirs = runCatching { api.downloaders().dataOrThrow() }
                        .onSuccess { list -> _ui.update { s -> s.copy(download = s.download.copy(downloaders = list.filter { it.usable })) } }
                        .map { downloaderDirs(it) }
                        .getOrNull()
                }
            }
            val issue = remembered?.let { rememberedPrefIssue(it, request, dirs) }
            if (remembered != null && issue == null) {
                _ui.update { it.copy(download = it.download.copy(remembered = remembered, dirs = dirs, confirmOnly = true)) }
                return@launch
            }
            val patched = if (issue != null) request.copy(reason = issue) else request
            _ui.update {
                it.copy(
                    download = it.download.copy(
                        request = patched,
                        remembered = remembered,
                        dirs = dirs,
                        confirmOnly = false,
                        remember = remembered != null,
                    )
                )
            }
            prepareSheet(patched)
        }
    }

    /** 确认条上「更改」→ 进完整弹窗（记忆已失效时带上原因） */
    fun reopenTargetDialog(reason: String? = null) {
        val flow = _ui.value.download
        val request = flow.request ?: return
        _ui.update {
            it.copy(
                download = it.download.copy(
                    request = if (reason != null) request.copy(reason = reason) else request,
                    confirmOnly = false,
                    error = null,
                )
            )
        }
        prepareSheet(_ui.value.download.request!!)
    }

    /** 「不再记住」：先本地摘掉再打请求 */
    fun forgetRemembered() {
        val flow = _ui.value.download
        val request = flow.request ?: return
        _ui.update { it.copy(download = it.download.copy(remembered = null, confirmOnly = false, remember = false)) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).forgetDownloadTargetPref(request.category) }
        }
    }

    /** 完整弹窗的初始化：按角色拉候选所需的数据（成员只拉自己的可见库） */
    private fun prepareSheet(request: DownloadTargetRequest) {
        val permissions = io.movieclaw.android.core.session.Permissions.of(sessionRepository.ui.value.session)
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val api = apiFactory.forOrigin(origin)
            if (!permissions.isAdmin) {
                // 成员版：只拉自己可见的库，不碰下载器配置与智能入库预检
                val libraries = runCatching { api.libraries().dataOrThrow() }
                    .getOrDefault(emptyList())
                    .filter { it.viewerAccess }
                _ui.update {
                    it.copy(download = it.download.copy(memberLibraries = libraries, memberLibrariesLoaded = true))
                }
                autoSelect()
                return@launch
            }
            _ui.update {
                it.copy(
                    download = it.download.copy(
                        hint = request.hint,
                        hintDraft = request.hint.orEmpty(),
                        picking = request.identityKind == null,
                        // 有线索时先问「这是哪部」，目录收在「其他保存位置」里：摊开的目录会被默认
                        // 选中，用户一点确认就下进了不会自动入库的目录
                        showOther = request.identityKind == null ||
                            (_ui.value.download.remembered?.kind ?: "smart") != "smart",
                    )
                )
            }
            val rememberedKind = _ui.value.download.remembered?.kind
            if (rememberedKind == "smart") {
                _ui.update { it.copy(download = it.download.copy(downloaderId = it.download.remembered?.downloaderId)) }
            }
            if (request.identityKind != null || request.hint != null) {
                runPreflight(
                    downloaderId = if (rememberedKind == "smart") _ui.value.download.remembered?.downloaderId else null,
                    candidate = null,
                    hint = request.hint,
                    initial = true,
                )
            }
            autoSelect()
        }
    }

    /** 「其他保存位置」展开时才读下载器配置 */
    fun loadDownloaders() {
        if (_ui.value.download.loadingDownloaders || _ui.value.download.downloaders.isNotEmpty()) return
        _ui.update { it.copy(download = it.download.copy(loadingDownloaders = true)) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val usable = runCatching { apiFactory.forOrigin(origin).downloaders().dataOrThrow() }
                .getOrDefault(emptyList())
                .filter { it.usable }
            val current = _ui.value.download.downloaderId
            val rememberedDownloader = _ui.value.download.remembered?.downloaderId
            val chosen = usable.firstOrNull { it.id == current }
                ?: usable.firstOrNull { it.id == rememberedDownloader }
                ?: usable.firstOrNull { it.isDefault }
                ?: usable.firstOrNull()
            val preflightId = chosen?.takeIf { !it.isDefault }?.id
            _ui.update {
                it.copy(
                    download = it.download.copy(
                        downloaders = usable,
                        dirs = downloaderDirs(usable),
                        downloaderId = chosen?.id,
                        loadingDownloaders = false,
                    )
                )
            }
            val request = _ui.value.download.request ?: return@launch
            if (request.identityKind != null || _ui.value.download.hint != null) {
                if (preflightId != current) {
                    runPreflight(
                        downloaderId = preflightId,
                        candidate = _ui.value.download.selectedCandidate,
                        hint = _ui.value.download.hint,
                    )
                }
            }
            autoSelect()
        }
    }

    fun selectOption(id: String) = _ui.update { it.copy(download = it.download.copy(selected = id)) }

    /** 展开「其他保存位置」：这时才去读下载器配置 */
    fun showOtherTargets() {
        _ui.update { it.copy(download = it.download.copy(showOther = true)) }
        loadDownloaders()
    }

    fun setRemember(value: Boolean) = _ui.update { it.copy(download = it.download.copy(remember = value)) }

    fun setDownloader(id: Long) {
        _ui.update { it.copy(download = it.download.copy(downloaderId = id)) }
        val flow = _ui.value.download
        runPreflight(downloaderId = id, candidate = flow.selectedCandidate, hint = flow.hint)
    }

    fun setHintDraft(value: String) = _ui.update { it.copy(download = it.download.copy(hintDraft = value)) }

    /** 「都不对？换个词搜」：用新词重跑预检，候选随之刷新 */
    fun searchHint() {
        val draft = _ui.value.download.hintDraft.trim()
        if (draft.isEmpty()) return
        _ui.update { it.copy(download = it.download.copy(hint = draft, selectedCandidate = null)) }
        runPreflight(downloaderId = _ui.value.download.downloaderId, candidate = null, hint = draft)
    }

    /** 点选「这是哪部作品」的候选：服务端按同一线索重新验证后重跑预检 */
    fun selectCandidate(candidate: ManualDownloadCandidateView) {
        _ui.update { it.copy(download = it.download.copy(selectedCandidate = candidate)) }
        runPreflight(
            downloaderId = _ui.value.download.downloaderId,
            candidate = candidate,
            hint = _ui.value.download.hint,
        )
    }

    fun closeTargetSheet() = _ui.update { it.copy(download = DownloadFlow()) }

    /**
     * 预检：`POST /downloaders/resolve-target`。识别条目 → 库路由 → 投递目录，
     * 识别不出就带候选回来让用户确认「这是哪部作品」。
     */
    private fun runPreflight(
        downloaderId: Long?,
        candidate: ManualDownloadCandidateView?,
        hint: String?,
        initial: Boolean = false,
    ) {
        val request = _ui.value.download.request ?: return
        val identityReady = request.identityKind != null
        if (!identityReady && hint == null && candidate == null) {
            _ui.update { it.copy(download = it.download.copy(picking = true)) }
            return
        }
        val requestId = ++preflightSeq
        _ui.update {
            it.copy(
                download = it.download.copy(
                    loadingTarget = true,
                    target = if (initial) it.download.target else null,
                )
            )
        }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).resolveDownloadTarget(
                    ManualDownloadTargetRequest(
                        kind = request.identityKind,
                        title = request.identityTitle,
                        year = request.identityYear,
                        subtitle = request.subtitle,
                        hint = hint,
                        downloaderId = downloaderId,
                        selectedTmdbId = candidate?.tmdbId,
                        selectedKind = candidate?.kind,
                    )
                ).dataOrThrow()
            }
                .onSuccess { target ->
                    if (requestId != preflightSeq) return@onSuccess
                    _ui.update { s ->
                        s.copy(
                            download = s.download.copy(
                                target = target,
                                candidates = target.candidates,
                                loadingTarget = false,
                                picking = if (initial) target.status != "ready" else s.download.picking,
                                // 有候选可点时目录继续收着；找不到 / 不能自动入库 / 识别不可用时
                                // 才摊开目录兜底
                                showOther = s.download.showOther || target.status == "not_found" ||
                                    (target.status == "ready" && !target.ok),
                            )
                        )
                    }
                    // 用户刚点选了条目：直接选中随之出现的「自动入库」，别停在先前默认的目录上
                    if (candidate != null && target.status == "ready" && target.ok) {
                        selectOption("smart")
                    } else {
                        autoSelect()
                    }
                }
                .onFailure { e ->
                    if (requestId != preflightSeq) return@onFailure
                    _ui.update {
                        it.copy(
                            download = it.download.copy(
                                target = null,
                                loadingTarget = false,
                                showOther = true,
                                error = null,
                            )
                        )
                    }
                    android.util.Log.i("McSearch", "落点预检失败：${friendlyMessage(e)}")
                    autoSelect()
                }
        }
    }

    /** 默认选中：记忆命中 > 智能入库可用 > 第一个目录 > 下载器默认（成员版：对得上类型的库） */
    private fun autoSelect() {
        val flow = _ui.value.download
        val request = flow.request ?: return
        if (flow.selected != null) return
        val permissions = io.movieclaw.android.core.session.Permissions.of(sessionRepository.ui.value.session)
        val options = computeTargetOptions(
            isAdmin = permissions.isAdmin,
            target = flow.target,
            showOther = flow.showOther,
            downloader = flow.downloaders.firstOrNull { it.id == flow.downloaderId },
            memberLibraries = flow.memberLibraries,
            request = request,
        )
        if (options.isEmpty()) {
            if (!permissions.isAdmin && flow.memberLibrariesLoaded) selectOption("default")
            return
        }
        val remembered = flow.remembered
        if (remembered != null) {
            val match = options.firstOrNull { o ->
                when (remembered.kind) {
                    "dir" -> o.kind == TargetOption.Kind.DIR && o.savePath == remembered.savePath
                    "smart" -> o.kind == TargetOption.Kind.SMART
                    else -> o.kind == TargetOption.Kind.FALLBACK
                }
            }
            if (match != null) {
                selectOption(match.id)
                return
            }
        }
        if (!permissions.isAdmin) {
            val kind = request.identityKind
            val fit = flow.memberLibraries.filter { it.kind == kind }
            val library = fit.firstOrNull { it.isDefault } ?: fit.firstOrNull()
            selectOption(library?.let { "library:${it.id}" } ?: "default")
            return
        }
        if (flow.loadingTarget || (flow.showOther && flow.downloaders.isEmpty())) return
        val pick = options.firstOrNull { it.kind == TargetOption.Kind.SMART }
            ?: options.firstOrNull { it.kind != TargetOption.Kind.SMART }
            ?: options.first()
        selectOption(pick.id)
    }

    /** 确认条「确认下载」：按记忆直接提交（记忆是策略时由服务端按身份重新路由） */
    fun confirmRemembered() {
        val flow = _ui.value.download
        val request = flow.request ?: return
        val pref = flow.remembered ?: return
        val option = when (pref.kind) {
            "smart" -> TargetOption("smart", TargetOption.Kind.SMART, label = "")
            "dir" -> TargetOption("dir:${pref.savePath}", TargetOption.Kind.DIR, savePath = pref.savePath, label = "")
            else -> TargetOption("default", TargetOption.Kind.FALLBACK, label = "")
        }
        submitOption(request, option, downloaderId = pref.downloaderId, remember = false)
    }

    /** 完整弹窗的「确认下载」 */
    fun submitSelected() {
        val flow = _ui.value.download
        val request = flow.request ?: return
        val permissions = io.movieclaw.android.core.session.Permissions.of(sessionRepository.ui.value.session)
        val options = computeTargetOptions(
            isAdmin = permissions.isAdmin,
            target = flow.target,
            showOther = flow.showOther,
            downloader = flow.downloaders.firstOrNull { it.id == flow.downloaderId },
            memberLibraries = flow.memberLibraries,
            request = request,
        )
        val option = options.firstOrNull { it.id == flow.selected } ?: return
        val pickedDownloaderId = flow.downloaders.firstOrNull { it.id == flow.downloaderId }
            ?.takeIf { !it.isDefault }?.id
        submitOption(
            request = request,
            option = option,
            downloaderId = pickedDownloaderId,
            remember = flow.remember && permissions.isAdmin,
        )
    }

    private fun submitOption(
        request: DownloadTargetRequest,
        option: TargetOption,
        downloaderId: Long?,
        remember: Boolean,
    ) {
        if (_ui.value.download.busy) return
        val permissions = io.movieclaw.android.core.session.Permissions.of(sessionRepository.ui.value.session)
        val flow = _ui.value.download
        val payload = if (!permissions.isAdmin) {
            // 成员版只带 library_id（+ 推导条目子目录用的片名年份）：目录 / 下载器 /
            // 智能入库 / 记忆分类都被服务端强制拒绝
            DownloadSubmitRequest(
                siteId = request.siteId,
                downloadUrl = request.downloadUrl,
                torrentId = request.torrentId,
                libraryId = option.libraryId,
                title = request.identityTitle,
                year = request.identityYear,
                subtitle = request.subtitle,
            )
        } else {
            var body = DownloadSubmitRequest(
                siteId = request.siteId,
                downloadUrl = request.downloadUrl,
                torrentId = request.torrentId,
                // 只有勾了「记住本次选择」才带分类：服务端拿不到分类就不写记忆
                category = request.category.takeIf { remember },
                downloaderId = downloaderId,
            )
            val target = flow.target
            if (option.kind == TargetOption.Kind.SMART && target?.tmdbId != null &&
                target.kind != null && !target.title.isNullOrBlank()
            ) {
                // 身份一律取预检确认的结论：类型可能与种子解析的不同，标题是 TMDB 标题
                body = body.copy(
                    autoRoute = true,
                    mediaKind = target.kind,
                    tmdbId = target.tmdbId,
                    title = target.title,
                    year = target.year,
                    subtitle = request.subtitle,
                )
            }
            if (option.kind == TargetOption.Kind.DIR) body = body.copy(savePath = option.savePath)
            body
        }
        _ui.update {
            it.copy(
                download = it.download.copy(busy = true, error = null),
                downloadStates = it.downloadStates + (request.hitKey to TorrentSubmitState.SUBMITTING),
            )
        }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).submitDownload(payload).dataOrThrow() }
                .onSuccess { result ->
                    val label = if (result.alreadyExists) {
                        "该种子已在下载器中，未重复添加"
                    } else {
                        "已提交到「${result.downloaderName}」" +
                            (result.savePath?.let { " · $it" } ?: "")
                    }
                    _ui.update {
                        it.copy(
                            download = DownloadFlow(),
                            downloadStates = it.downloadStates + (
                                request.hitKey to
                                    if (result.alreadyExists) TorrentSubmitState.EXISTS else TorrentSubmitState.DONE
                                ),
                            notice = McNotice(label),
                        )
                    }
                }
                .onFailure { e ->
                    _ui.update {
                        it.copy(
                            download = it.download.copy(busy = false, error = friendlyMessage(e)),
                            downloadStates = it.downloadStates + (request.hitKey to TorrentSubmitState.ERROR),
                        )
                    }
                }
        }
    }

    /**
     * 手动选种：把选中的种子投给订阅（跳过规则组过滤，身份匹配照常）。
     * 服务端还会校验订阅归属——只能投给自己发起或关注的订阅。
     */
    fun grab(hit: TorrentHit) {
        val flow = _ui.value.download
        val target = _ui.value.grabTarget ?: return
        val key = hitKey(hit)
        val state = _ui.value.grabStates[key] ?: TorrentSubmitState.IDLE
        if (state == TorrentSubmitState.SUBMITTING || state == TorrentSubmitState.DONE) return
        val url = hit.downloadUrl?.takeIf { it.isNotBlank() }
        if (url == null) {
            _ui.update { it.copy(notice = McNotice("该结果没有下载入口")) }
            return
        }
        _ui.update {
            it.copy(
                actionHit = null,
                grabStates = it.grabStates + (key to TorrentSubmitState.SUBMITTING),
            )
        }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val attrsJson = hit.attrs?.let {
                runCatching { json.encodeToJsonElement(io.movieclaw.android.core.model.TorrentAttrs.serializer(), it) }
                    .getOrNull() as? kotlinx.serialization.json.JsonObject
            }
            runCatching {
                apiFactory.forOrigin(origin).grabSubscriptionTorrent(
                    target.first,
                    GrabPayload(
                        siteId = hit.siteId,
                        torrentId = hit.torrentId,
                        title = hit.title,
                        subtitle = hit.subtitle.ifBlank { null },
                        category = hit.category,
                        downloadUrl = url,
                        sizeBytes = hit.sizeBytes.takeIf { it > 0 },
                        seeders = hit.seeders,
                        isFree = hit.free,
                        hitAndRun = hit.hitAndRun,
                        attrs = attrsJson,
                        publishTime = hit.uploadTime,
                    ),
                ).dataOrThrow()
            }
                .onSuccess { result ->
                    _ui.update {
                        it.copy(
                            grabStates = it.grabStates + (key to TorrentSubmitState.DONE),
                            notice = McNotice("已投给《${target.second}》，覆盖 ${result.units.size} 个追踪单元"),
                        )
                    }
                    // 投递会改变缺口状态：让订阅索引重拉一次
                    io.movieclaw.android.feature.subscriptions.SubscriptionEvents.notifyChanged()
                }
                .onFailure { e ->
                    _ui.update {
                        it.copy(
                            grabStates = it.grabStates + (key to TorrentSubmitState.ERROR),
                            notice = McNotice(friendlyMessage(e), FeedbackTone.Error),
                        )
                    }
                }
        }
    }
}

private fun List<SiteBlock>.mergeResult(result: SiteStreamResult): List<SiteBlock> {
    val existing = indexOfFirst { it.siteId == result.siteId }
    val merged = SiteBlock(
        siteId = result.siteId,
        siteName = result.siteName,
        items = result.items,
        elapsedMs = result.elapsedMs,
    )
    return if (existing >= 0) toMutableList().also { it[existing] = merged } else this + merged
}
