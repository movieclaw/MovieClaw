package io.movieclaw.android.core.offline

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.AppScopes
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.model.LibraryItemDetailView
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.SeasonEpisodesView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

/**
 * 本机副本的目录（docs/design/offline-download.md §3、§4；iOS `OfflineStore` 逐条对应）：
 * 当前账号有哪些条目、哪些单元、各自的状态与本机进度。
 *
 * 改动在锁里改内存、写盘排进 [OfflineDisk] 的单线程（先改先写），界面观察它发布的只读快照。
 * 海报墙、首页只看 [doneFileIds] / [downloadedItemIds]（完成、删除时才变）：下载进度每秒刷一次 [units]，
 * 不该连带整面墙重算。
 */
@Singleton
class OfflineStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
    /** App 的网络 Json（蛇形命名）：接口模型原样存、原样读 */
    private val apiJson: Json,
) {
    init {
        OfflineDisk.init(context.filesDir)
    }

    private val scope = AppScopes.io("OfflineStore")
    private val lock = Any()

    data class State(
        val owner: OfflineOwner? = null,
        val items: Map<Long, OfflineItemSummary> = emptyMap(),
        val units: Map<Long, OfflineUnit> = emptyMap(),
        val progress: Map<Long, Map<String, OfflineProgress>> = emptyMap(),
        /** 这台服务器支持离线下载（有实例号）：没有时下载入口不出现 */
        val serverSupported: Boolean = false,
        /** 读完本机存档了（离线首页据此区分「还在读」和「真的没有」） */
        val loaded: Boolean = false,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()
    private val s: State get() = _state.value

    val units: StateFlow<Map<Long, OfflineUnit>> = derived { it.units }
    val items: StateFlow<Map<Long, OfflineItemSummary>> = derived { it.items }
    val progress: StateFlow<Map<Long, Map<String, OfflineProgress>>> = derived { it.progress }
    val loaded: StateFlow<Boolean> = derived { it.loaded }
    val serverSupported: StateFlow<Boolean> = derived { it.serverSupported }
    val ownerKey: StateFlow<String?> = derived { it.owner?.key }

    /** 下完、能播的单元 */
    val doneFileIds: StateFlow<Set<Long>> = derived { st -> st.units.values.filter { it.playable }.map { it.fileId }.toSet() }

    /** 至少有一个能播单元的条目 */
    val downloadedItemIds: StateFlow<Set<Long>> = derived { st -> st.units.values.filter { it.playable }.map { it.mediaItemId }.toSet() }

    /** 下完的副本占的字节（按条目）：只在完成、删除时变，下载进度不改它 */
    val doneBytesByItem: StateFlow<Map<Long, Long>> = derived { st ->
        st.units.values.filter { it.playable }.groupBy { it.mediaItemId }.mapValues { (_, list) -> list.sumOf { it.receivedBytes } }
    }
    val doneBytes: StateFlow<Long> = derived { st -> st.units.values.filter { it.playable }.sumOf { it.receivedBytes } }

    data class ActiveUnit(val fileId: Long, val season: Int, val episode: Int)

    /** 每个条目还没下完的单元（详情页「取消下载」）：只在开始 / 完成 / 删除时变，下载进度不改它 */
    val activeByItem: StateFlow<Map<Long, List<ActiveUnit>>> = derived { st ->
        st.units.values.filter { it.isActive }.groupBy { it.mediaItemId }
            .mapValues { (_, list) -> list.map { ActiveUnit(it.fileId, it.season, it.episode) }.sortedBy { it.fileId } }
    }

    /**
     * 进行中的单元按下载顺序排（§5.5，含暂停、失败；正在下的排最前）：只在开始 / 完成 / 删除 / 调顺序 / 状态变化时变，
     * 下载进度不改它——排第几、「优先下载」该不该出现都看它
     */
    val queue: StateFlow<List<OfflineQueue.Entry>> = derived { st -> OfflineQueue.entries(st.units.values) }

    /** 正在下载的单元的实时速度（字节 / 秒，平滑过）：只在内存里 */
    private val _speeds = MutableStateFlow<Map<Long, Double>>(emptyMap())
    val speeds: StateFlow<Map<Long, Double>> = _speeds.asStateFlow()
    private val speedSamples = mutableMapOf<Long, Pair<Long, Long>>()

    private fun <T> derived(pick: (State) -> T): StateFlow<T> =
        _state.map(pick).distinctUntilChanged().stateIn(scope, SharingStarted.Eagerly, pick(_state.value))

    val key: String? get() = s.owner?.key
    val owner: OfflineOwner? get() = s.owner

    /** 准备、下载、对账在这里登记回调（避免与下载器互相注入） */
    @Volatile var onAdopted: (() -> Unit)? = null
    @Volatile var onCatalogChanged: (() -> Unit)? = null

    // ── 账号 ──

    @Volatile private var adoptingToken: String? = null

    /**
     * 以这个账号的身份使用：找到它的存档（按实例号；还不知道实例号时按地址 + 用户名找），读进内存。
     * 实例号第一次要向服务器问（`/health`），之后记在本机，离线也认得出
     */
    suspend fun adopt(origin: String, username: String) {
        val normalized = origin.trimEnd('/')
        val token = "$normalized|$username"
        if (adoptingToken == token) return
        adoptingToken = token
        val owners = withContext(OfflineDisk.dispatcher) { OfflineOwners.scan() }
        var instance = OfflineOwners.instanceId(context, normalized)
        // 认得实例号时只按实例号找：同一个地址上换了一台服务器（重装），旧存档不能套到新服务器上
        var match = instance?.let { id -> owners.firstOrNull { it.instanceId == id && it.username == username } }
            ?: owners.firstOrNull { it.origin == normalized && it.username == username }
        if (instance == null) {
            instance = fetchInstanceId(normalized)
            if (instance != null) owners.firstOrNull { it.instanceId == instance && it.username == username }?.let { match = it }
        }
        if (adoptingToken != token) return
        // 没问到实例号（冷启动时连不上）、本机也没有存档：下次连上时再来（readoptIfNeeded）
        if (instance == null && match == null) adoptingToken = null
        val current = match
        when {
            current != null -> {
                val owner = if (current.origin != normalized) current.copy(origin = normalized) else current
                if (owner != current) OfflineDisk.enqueue { OfflineDisk.write(OfflineOwner.serializer(), owner, OfflineDisk.ownerFile(owner.key)) }
                apply(owner)
            }
            instance != null -> apply(OfflineOwner(instanceId = instance, username = username, origin = normalized))
            else -> {
                // 旧服务器（没有实例号）或冷启动时连不上、本机也没有存档：先不开离线下载
                _state.value = State(loaded = true)
                OfflineImages.reset()
            }
        }
    }

    private suspend fun apply(owner: OfflineOwner) {
        val changed = owner.key != s.owner?.key
        if (!changed) {
            _state.update { it.copy(owner = owner, serverSupported = true) }
            return
        }
        _state.value = State(owner = owner, serverSupported = true, loaded = false)
        val key = owner.key
        val snapshot = withContext(OfflineDisk.dispatcher) {
            // 旧版安卓的存档（按地址 + 用户名分目录、每个单元一个 pack.json）：挪进新格式一次
            OfflineLegacy.migrate(owner, apiJson)
            OfflineDisk.loadSnapshot(key)
        }
        if (s.owner?.key != key) return
        _state.update { it.copy(items = snapshot.items, units = snapshot.units, progress = snapshot.progress, loaded = true) }
        withContext(OfflineDisk.dispatcher) { OfflineImages.load(key, snapshot.items.keys) }
        onCatalogChanged?.invoke()
        onAdopted?.invoke()
    }

    /** 连上服务器 / 回前台时调：上次没认出服务器（离线冷启动）就再认一次；认得的话顺手核对实例号（重装换了服务器时改认新的） */
    suspend fun readoptIfNeeded(origin: String, username: String) {
        if (s.owner == null || !s.serverSupported) {
            adoptingToken = null
            adopt(origin, username)
            return
        }
        val known = s.owner?.instanceId ?: return
        val fresh = fetchInstanceId(origin.trimEnd('/')) ?: return
        if (fresh == known) return
        reset()
        adopt(origin, username)
    }

    private suspend fun fetchInstanceId(origin: String): String? {
        val health = runCatching { apiFactory.forOrigin(origin).health() }.getOrNull() ?: return null
        val id = health.instanceId?.takeIf { it.isNotEmpty() } ?: return null
        OfflineOwners.remember(context, origin, id)
        return id
    }

    /** 本机目录读完为止（最多等 [timeoutMs]）：冷启动直达播放、详情页秒开要先知道本机有没有副本 */
    suspend fun waitUntilLoaded(timeoutMs: Long = 3_000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        // 没在读任何账号的存档（还没登录、旧服务器）：没什么可等的
        while (!s.loaded && (adoptingToken != null || s.owner != null) && System.currentTimeMillis() < deadline) delay(50)
    }

    /** 换账号 / 退出时清空内存（存档留在盘上，同一账号回来就还在） */
    fun reset() {
        adoptingToken = null
        _state.value = State()
        _speeds.value = emptyMap()
        synchronized(speedSamples) { speedSamples.clear() }
        OfflineImages.reset()
    }

    // ── 查询 ──

    fun unitsOfItem(itemId: Long, st: State = s): List<OfflineUnit> =
        st.units.values.filter { it.mediaItemId == itemId }.sortedWith(compareBy({ it.season }, { it.episode }))

    /** 这个单元有没有能播的本机副本（一集有多个版本时取最新下完的那个） */
    fun playableUnit(mediaItemId: Long, season: Int, episode: Int, st: State = s): OfflineUnit? =
        st.units.values.filter { it.mediaItemId == mediaItemId && it.season == season && it.episode == episode && it.playable }
            .maxByOrNull { it.completedAt ?: 0 }

    /** 这个单元的本机副本（任意状态）：详情页的下载状态条看它 */
    fun unit(mediaItemId: Long, season: Int, episode: Int, st: State = s): OfflineUnit? {
        val matches = st.units.values.filter { it.mediaItemId == mediaItemId && it.season == season && it.episode == episode }
        return matches.firstOrNull { it.playable } ?: matches.maxByOrNull { it.createdAt }
    }

    /** 已下载的条目（离线首页、存储页）：最近下载的在前 */
    fun downloadedItems(st: State = s): List<OfflineItemSummary> {
        val ids = st.units.values.filter { it.playable }.map { it.mediaItemId }.toSet()
        return ids.mapNotNull { st.items[it] }.sortedByDescending { it.addedAt }
    }

    /** 还在进行中（含失败、暂停）的单元，按下载顺序：首页「正在下载」行、存储页「下载中」 */
    fun activeUnits(st: State = s): List<OfflineUnit> = OfflineQueue.entries(st.units.values).mapNotNull { st.units[it.fileId] }

    /** 下载队列里排在它前面、还会轮到的有几个（「下一个下载」「前面还有 N 个」） */
    fun queueAhead(fileId: Long, queue: List<OfflineQueue.Entry> = this.queue.value): Int = OfflineQueue.ahead(fileId, queue)

    fun localProgress(itemId: Long, season: Int, episode: Int, st: State = s): OfflineProgress? = st.progress[itemId]?.get("$season-$episode")

    fun mediaFile(unit: OfflineUnit): File? = key?.let { File(OfflineDisk.unitDir(it, unit.mediaItemId, unit.fileId), unit.mediaFileName) }

    fun unitDir(unit: OfflineUnit): File? = key?.let { OfflineDisk.unitDir(it, unit.mediaItemId, unit.fileId) }

    suspend fun spec(unit: OfflineUnit): OfflinePlaybackSpec? {
        val key = key ?: return null
        return withContext(OfflineDisk.dispatcher) {
            OfflineDisk.read(OfflinePlaybackSpec.serializer(), OfflineDisk.playbackFile(key, unit.mediaItemId, unit.fileId))
        }
    }

    /** 本机存的详情（接口模型原样）；没有或解不开为 null */
    suspend fun detail(itemId: Long): LibraryItemDetailView? = readApi(itemId) { key -> OfflineDisk.detailFile(key, itemId) }?.let {
        runCatching { apiJson.decodeFromString(LibraryItemDetailView.serializer(), it) }.getOrNull()
    }

    suspend fun library(itemId: Long): LibraryView? = readApi(itemId) { key -> OfflineDisk.libraryFile(key, itemId) }?.let {
        runCatching { apiJson.decodeFromString(LibraryView.serializer(), it) }.getOrNull()
    }

    suspend fun season(itemId: Long, season: Int): SeasonEpisodesView? = seasonJson(itemId, season)?.let {
        runCatching { apiJson.decodeFromString(SeasonEpisodesView.serializer(), it) }.getOrNull()
    }

    /** 季的原样 JSON（播放器用另一套生成的模型解） */
    suspend fun seasonJson(itemId: Long, season: Int): String? = readApi(itemId) { key -> OfflineDisk.seasonFile(key, itemId, season) }

    private suspend fun readApi(itemId: Long, file: (String) -> File): String? {
        val key = key ?: return null
        if (s.items[itemId] == null) return null
        return withContext(OfflineDisk.dispatcher) { runCatching { file(key).readText() }.getOrNull() }
    }

    /** 本机这个条目的副本占了多少空间 */
    fun bytesOfItem(itemId: Long): Long = unitsOfItem(itemId).sumOf { it.receivedBytes }

    val totalBytes: Long get() = s.units.values.sumOf { it.receivedBytes }

    // ── 离线显示的变换（§4：在线请求失败回落本机时同样做） ──

    /** 详情：文件只留本机有的，季只留有下载的 */
    fun offlineDetail(detail: LibraryItemDetailView): LibraryItemDetailView {
        val local = unitsOfItem(detail.mediaItemId).filter { it.playable }.map { it.fileId }.toSet()
        val files = detail.files.filter { it.id in local }
        return detail.copy(
            files = files,
            fileCount = files.size,
            totalSizeBytes = files.sumOf { it.sizeBytes },
            seasons = if (detail.kind == "tv") files.map { it.seasonNumber }.toSet().let { owned -> detail.seasons.filter { it in owned } } else detail.seasons,
            scraping = false,
            chaptersPending = false,
        )
    }

    /** 分集：「在库」改成「本机有没有」（没下的集沿用缺集置灰），进度取本机 */
    fun offlineSeason(view: SeasonEpisodesView, itemId: Long): SeasonEpisodesView {
        val episodes = view.episodes.map { episode -> offlineEpisode(episode, itemId, view.seasonNumber) }
        // 服务端的锚点可能指向一集没下的：交给客户端规则在本机有的集里挑
        val anchor = view.resumeEpisode?.takeIf { a -> episodes.firstOrNull { it.episodeNumber == a }?.owned == true }
        return view.copy(episodes = episodes, resumeEpisode = anchor)
    }

    fun offlineEpisode(episode: EpisodeView, itemId: Long, season: Int): EpisodeView {
        val unit = playableUnit(itemId, season, episode.episodeNumber)
        var copy = episode.copy(owned = unit != null, fileIds = unit?.let { listOf(it.fileId) } ?: emptyList())
        localProgress(itemId, season, episode.episodeNumber)?.let { local ->
            copy = copy.copy(positionMs = local.positionMs, played = local.played)
            val duration = local.durationMs
            if (duration != null && duration > 0 && local.positionMs > 0) {
                copy = copy.copy(progressPercent = minOf(100, (local.positionMs * 100 / duration).toInt()))
            }
        }
        return copy
    }

    // ── 写入 ──

    fun upsert(unit: OfflineUnit) {
        val key = key ?: return
        synchronized(lock) { _state.update { it.copy(units = it.units + (unit.fileId to unit)) } }
        if (unit.state != OfflineUnit.State.downloading) clearSpeed(unit.fileId)
        OfflineDisk.enqueue { OfflineDisk.write(OfflineUnit.serializer(), unit, OfflineDisk.unitFile(key, unit.mediaItemId, unit.fileId)) }
    }

    /** 按给定顺序给进行中的单元重新编号 0、1、2…（§5.5）；没列出的接在后面、保持原来的先后。只写编号变了的 */
    fun renumberQueue(fileIds: List<Long>) {
        val order = OfflineQueue.order(fileIds, OfflineQueue.entries(s.units.values))
        order.forEachIndexed { index, fileId ->
            val unit = s.units[fileId] ?: return@forEachIndexed
            if (unit.queueOrder != index.toDouble()) upsert(unit.copy(queueOrder = index.toDouble()))
        }
    }

    /** 只改内存里的进度读数（下载进度每秒一次，不值得每次写盘） */
    fun updateReceived(fileId: Long, received: Long, expected: Long?) {
        synchronized(lock) {
            val unit = s.units[fileId] ?: return
            if (unit.state != OfflineUnit.State.downloading && unit.state != OfflineUnit.State.queued) return
            var next = unit.copy(receivedBytes = received)
            if (expected != null && expected > 0 && (unit.profile == "original" || unit.expectedBytes == 0L)) next = next.copy(expectedBytes = expected)
            if (next.state == OfflineUnit.State.queued) next = next.copy(state = OfflineUnit.State.downloading)
            _state.update { it.copy(units = it.units + (fileId to next)) }
        }
        sampleSpeed(fileId, received)
    }

    /** 速度 = 两次进度读数之间的字节差 / 时间差，再做指数平滑（读数约每秒一次，原始值跳得厉害） */
    private fun sampleSpeed(fileId: Long, received: Long) {
        val now = System.currentTimeMillis()
        synchronized(speedSamples) {
            val last = speedSamples[fileId]
            if (last == null) {
                speedSamples[fileId] = now to received
                return
            }
            val elapsed = now - last.first
            if (elapsed < 500) return
            val instant = maxOf(0.0, (received - last.second) * 1000.0 / elapsed)
            _speeds.update { speeds -> speeds + (fileId to (speeds[fileId]?.let { it * 0.6 + instant * 0.4 } ?: instant)) }
            speedSamples[fileId] = now to received
        }
    }

    private fun clearSpeed(fileId: Long) {
        synchronized(speedSamples) { speedSamples.remove(fileId) }
        if (_speeds.value.containsKey(fileId)) _speeds.update { it - fileId }
    }

    fun upsertSummary(summary: OfflineItemSummary) {
        val key = key ?: return
        synchronized(lock) { _state.update { it.copy(items = it.items + (summary.mediaItemId to summary)) } }
        OfflineDisk.enqueue { OfflineDisk.write(OfflineItemSummary.serializer(), summary, OfflineDisk.summaryFile(key, summary.mediaItemId)) }
    }

    /** 在线拿到最新详情：本机有这个条目就顺手刷新存档（下次离线看到的是最新的） */
    fun refresh(detail: LibraryItemDetailView) {
        val key = key ?: return
        val summary = s.items[detail.mediaItemId] ?: return
        val next = summary.copy(
            title = detail.title, year = detail.year, posterUrl = detail.posterUrl,
            backdropUrl = detail.backdropUrl, primaryAspect = detail.primaryAspect,
        )
        if (next != summary) upsertSummary(next)
        val text = apiJson.encodeToString(LibraryItemDetailView.serializer(), detail)
        OfflineDisk.enqueue { OfflineDisk.writeText(text, OfflineDisk.detailFile(key, detail.mediaItemId)) }
    }

    fun refresh(season: SeasonEpisodesView, itemId: Long) {
        val key = key ?: return
        if (s.items[itemId] == null) return
        val text = apiJson.encodeToString(SeasonEpisodesView.serializer(), season)
        OfflineDisk.enqueue { OfflineDisk.writeText(text, OfflineDisk.seasonFile(key, itemId, season.seasonNumber)) }
    }

    /** 记一次本机进度（本机播放时每 10 秒；在线拿到服务器的续播点也写进来） */
    fun recordProgress(itemId: Long, season: Int, episode: Int, positionMs: Long, played: Boolean, durationMs: Long?, at: Long = System.currentTimeMillis()) {
        val key = key ?: return
        if (s.items[itemId] == null) return
        val map: Map<String, OfflineProgress>
        synchronized(lock) {
            map = (s.progress[itemId] ?: emptyMap()) + ("$season-$episode" to OfflineProgress(positionMs, played, durationMs, at))
            _state.update { it.copy(progress = it.progress + (itemId to map)) }
        }
        OfflineDisk.enqueue { OfflineDisk.writeProgress(map, OfflineDisk.progressFile(key, itemId)) }
    }

    /**
     * 删一个单元（取消下载、删本机副本）。条目的单元删光了，整个条目目录一起删；
     * [keepItem]：换档时只换这个单元，条目的展示数据、图片、本机进度都留着
     */
    fun removeUnit(fileId: Long, keepItem: Boolean = false) {
        val key = key ?: return
        val itemEmpty: Boolean
        val itemId: Long
        synchronized(lock) {
            val unit = s.units[fileId] ?: return
            itemId = unit.mediaItemId
            val rest = s.units - fileId
            itemEmpty = !keepItem && rest.values.none { it.mediaItemId == itemId }
            _state.update {
                it.copy(
                    units = rest,
                    items = if (itemEmpty) it.items - itemId else it.items,
                    progress = if (itemEmpty) it.progress - itemId else it.progress,
                )
            }
        }
        clearSpeed(fileId)
        OfflineDisk.enqueue { OfflineDisk.remove(if (itemEmpty) OfflineDisk.itemDir(key, itemId) else OfflineDisk.unitDir(key, itemId, fileId)) }
        if (itemEmpty) OfflineImages.forget(itemId)
        onCatalogChanged?.invoke()
    }

    /**
     * App 升级后第一次在线：按顺序重拉全部副本的展示数据（§3.3），同一个 App 版本只做一次。
     * 安卓的接口模型字段都有默认值、旧存档解得开；这一步保证离线前看到的是最新的展示数据
     * （旧版安卓存档没有详情，迁过来后也靠它补齐）
     */
    suspend fun refreshArchivedMetadataIfNeeded(isOffline: () -> Boolean) {
        val key = key ?: return
        val owner = owner ?: return
        val version = io.movieclaw.android.BuildConfig.VERSION_CODE.toString()
        val prefs = context.getSharedPreferences("mc_offline_meta", Context.MODE_PRIVATE)
        val prefKey = "metadataVersion.$key"
        if (s.items.isEmpty() || prefs.getString(prefKey, null) == version) return
        val api = apiFactory.forOrigin(owner.origin)
        var complete = true
        for (item in s.items.values.toList()) {
            if (isOffline()) return
            runCatching { api.libraryItemDetail(item.libraryId, item.mediaItemId).dataOrThrow() }
                .onSuccess { refresh(it) }.onFailure { complete = false }
            if (OfflineDisk.libraryFile(key, item.mediaItemId).isFile.not()) {
                runCatching { api.library(item.libraryId).dataOrThrow() }.onSuccess { lib ->
                    val text = apiJson.encodeToString(LibraryView.serializer(), lib)
                    OfflineDisk.enqueue { OfflineDisk.writeText(text, OfflineDisk.libraryFile(key, item.mediaItemId)) }
                }
            }
            if (item.kind != "tv") continue
            for (season in unitsOfItem(item.mediaItemId).map { it.season }.toSet()) {
                runCatching { api.seasonEpisodes(item.libraryId, item.mediaItemId, season).dataOrThrow() }
                    .onSuccess { refresh(it.copy(seasonNumber = season), item.mediaItemId) }.onFailure { complete = false }
            }
        }
        // 有没拉到的（连不上、条目已删）：下次在线再来
        if (complete) prefs.edit().putString(prefKey, version).apply()
    }

    /** 首次下载这个账号的东西：建账号目录 */
    fun ensureOwnerOnDisk() {
        val owner = owner ?: return
        OfflineDisk.enqueue { OfflineDisk.write(OfflineOwner.serializer(), owner, OfflineDisk.ownerFile(owner.key)) }
    }

    fun encodeSeason(view: SeasonEpisodesView): String = apiJson.encodeToString(SeasonEpisodesView.serializer(), view)

    fun encodeApi(element: JsonElement?): String? = element?.let { apiJson.encodeToString(JsonElement.serializer(), it) }

    fun decodeDetail(element: JsonElement?): LibraryItemDetailView? =
        element?.let { runCatching { apiJson.decodeFromJsonElement(LibraryItemDetailView.serializer(), it) }.getOrNull() }

    fun decodeLibrary(element: JsonElement?): LibraryView? =
        element?.let { runCatching { apiJson.decodeFromJsonElement(LibraryView.serializer(), it) }.getOrNull() }

    fun decodeSeason(element: JsonElement?): SeasonEpisodesView? =
        element?.let { runCatching { apiJson.decodeFromJsonElement(SeasonEpisodesView.serializer(), it) }.getOrNull() }

    fun launchIO(block: suspend () -> Unit) {
        scope.launch { block() }
    }
}

/** 本机存过哪些账号（存储页的「其他账号」、按实例号认服务器） */
object OfflineOwners {
    private const val PREFS = "mc_offline_instances"

    fun scan(): List<OfflineOwner> = OfflineDisk.children(OfflineDisk.root).mapNotNull { dir ->
        OfflineDisk.read(OfflineOwner.serializer(), File(dir, "owner.json"))
    }

    /** 服务器地址 → 实例号（问过一次就记下：离线时也认得出是哪台） */
    fun instanceId(context: Context, origin: String): String? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(origin.trimEnd('/'), null)

    fun remember(context: Context, origin: String, id: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(origin.trimEnd('/'), id).apply()
    }

    /** 某个账号存档占的空间与条目数（存储页「其他账号」一节） */
    fun usage(owner: OfflineOwner): Pair<Long, Int> =
        OfflineDisk.size(OfflineDisk.ownerDir(owner.key)) to OfflineDisk.children(OfflineDisk.itemsDir(owner.key)).size

    fun remove(owner: OfflineOwner) {
        OfflineDisk.enqueue { OfflineDisk.remove(OfflineDisk.ownerDir(owner.key)) }
    }
}
