package io.movieclaw.android.core.offline

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.AppScopes
import io.movieclaw.android.core.model.OfflineExportRequest
import io.movieclaw.android.core.model.OfflineFileProfiles
import io.movieclaw.android.core.model.OfflineManifest
import io.movieclaw.android.core.model.OfflineProfile
import io.movieclaw.android.core.network.ApiException
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.ServerRoutes
import io.movieclaw.android.core.network.dataOrThrow
import java.io.File
import java.io.FileOutputStream
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Request

/**
 * 离线下载（docs/design/offline-download.md §5.4；iOS `OfflineDownloader` 的安卓版）：期望状态 + 对账。
 *
 * - **后台**：iOS 用系统的后台下载会话；安卓的对应物是 WorkManager 的长时作业（[OfflineDownloadWorker]，前台通知），
 *   退到后台、锁屏照常下，被系统杀掉后按约束（网络）自动重跑。一次只下一个：家里上行有限，串行让第一集最早能看。
 * - **网络策略**放在作业的约束上：只用 Wi-Fi（不计费网络，个人热点、计费网络都不下）或任何网络（「使用蜂窝网络下载」）。
 * - **期望状态**：要下什么记在每个单元的 `unit.json`；作业跑起来时按单元状态逐个准备、下载（[drive]）。
 *   崩溃、被杀、断网之后都能自愈：已下的字节在 `media.part`，带 Range + If-Range 续传。
 * - **顺序**（§5.5）：准备、下载都按下载顺序挑；「优先下载」、拖动排序后排第一、能下的换了人，正在下的让路（字节留着）。
 * - **准备**：视频之外的东西（清单、字幕、图片、转码导出）先拉好，再建视频下载。
 */
@Singleton
class OfflineDownloader @Inject constructor(
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
    private val store: OfflineStore,
    private val prefs: OfflinePrefs,
    private val reachability: ServerReachability,
) {
    private val scope = AppScopes.io("OfflineDownloader")

    /** 有新活要看一眼（开始、继续、删除、准备完、到点重试）：正在跑的 [drive] 收到就重新挑 */
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val driveLock = Mutex()

    /** 正在准备的单元（一次一个） */
    @Volatile private var preparing: Long? = null
    private var prepareJob: Job? = null
    /** 正在下的单元与它的任务 */
    @Volatile private var transferring: Long? = null
    private var transferJob: Job? = null
    @Volatile private var transferCall: okhttp3.Call? = null
    /** 连接断了、网络还在时原地重来的次数（一个单元连续几次一个字节都没收到才算真失败） */
    private val quickRetries = java.util.concurrent.ConcurrentHashMap<Long, Int>()

    /** 眼下只有计费网络（蜂窝、个人热点；系统报 NOT_METERED 缺失） */
    private val metered = MutableStateFlow(false)

    /**
     * 下载在等 Wi-Fi：没开「使用蜂窝网络下载」，眼下又是计费网络——作业按约束一动不动，界面要说出来，不然看着像卡住了
     */
    val waitingForWiFi: StateFlow<Boolean> =
        combine(metered, prefs.allowCellular) { onMetered, cellular -> onMetered && !cellular }
            .stateIn(scope, SharingStarted.Eagerly, false)

    init {
        store.onAdopted = { kick("adopt") }
        // 改了「使用蜂窝网络下载」：作业约束跟着换（正在下的停下，按新约束重跑、从已下的字节续传）
        scope.launch {
            var first = true
            prefs.allowCellular.collect {
                if (!first) OfflineDownloadWorker.schedule(context, it, replace = true)
                first = false
            }
        }
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
        cm?.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: android.net.Network, caps: android.net.NetworkCapabilities) {
                metered.value = caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    !caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            }

            override fun onLost(network: android.net.Network) {
                metered.value = false
            }
        })
    }

    // ── 发起 ──

    sealed class StartError(message: String) : Exception(message) {
        class Unsupported(device: String) : StartError("这台服务器还不支持下载到 $device，请先把服务器升级到最新版本")
        class NoSpace(device: String, needed: Long, available: Long, estimated: Boolean) :
            StartError("$device 空间不足：需要 ${if (estimated) "≈ " else ""}${OfflineFormat.bytes(needed)}（含预留 2 GB），只剩 ${OfflineFormat.bytes(available)}")
        class Unavailable(reason: String) : StartError(reason)
    }

    /** 下载一个播放单元：清单已拉好，按选中的档位开始。已经在下 / 下完的同档不重复 */
    fun start(manifest: OfflineManifest, profile: OfflineProfile) {
        val device = OfflineFormat.deviceName(context)
        if (store.owner == null || !store.state.value.serverSupported) throw StartError.Unsupported(device)
        manifest.unavailableReason?.let { throw StartError.Unavailable(it) }
        val existing = store.state.value.units[manifest.fileId]
        if (existing != null && existing.profile == profile.profile && existing.state != OfflineUnit.State.failed && !existing.damaged) return
        checkSpace(profile, device)
        store.ensureOwnerOnDisk()
        // 换档（比如原画改 720p）：旧的那份连同任务一起去掉，条目的展示数据与本机进度留着
        if (existing != null) {
            cancelTransfer(existing.fileId)
            store.removeUnit(existing.fileId, keepItem = true)
        }
        val detail = store.decodeDetail(manifest.item)
        val library = store.decodeLibrary(manifest.library)
        store.upsertSummary(
            OfflineItemSummary(
                mediaItemId = manifest.mediaItemId,
                libraryId = manifest.libraryId,
                libraryName = library?.name.orEmpty(),
                libraryKind = library?.kind ?: detail?.kind ?: "movie",
                kind = detail?.kind ?: "movie",
                title = detail?.title.orEmpty(),
                year = detail?.year,
                posterUrl = detail?.posterUrl,
                backdropUrl = detail?.backdropUrl,
                primaryAspect = detail?.primaryAspect ?: 0.6667f,
                addedAt = System.currentTimeMillis(),
            ),
        )
        val still = store.decodeSeason(manifest.season)?.episodes?.firstOrNull { it.episodeNumber == manifest.episodeNumber }?.stillUrl
        val unit = OfflineUnit(
            fileId = manifest.fileId,
            mediaItemId = manifest.mediaItemId,
            season = manifest.seasonNumber,
            episode = manifest.episodeNumber,
            profile = profile.profile,
            profileLabel = profile.label,
            state = OfflineUnit.State.preparing,
            expectedBytes = profile.expectedBytes,
            fileExtension = if (profile.profile == "original") fileExtension(manifest.container) else "mp4",
            stillUrl = still,
            createdAt = System.currentTimeMillis(),
        )
        store.upsert(unit)
        scope.launch { prefs.setLastProfile(profile.profile) }
        pendingManifests[unit.fileId] = manifest
        reachability.catalogChanged()
        kick("start")
    }

    /**
     * 整批下载里除第一集外的各集：只凭选档表单的批量结果先建「准备中」单元（目录里马上有、强退也不丢），
     * 完整清单由准备阶段逐集去取。条目的展示数据要已由第一集的 [start] 存好
     */
    fun enqueue(entry: OfflineFileProfiles, profile: OfflineProfile) {
        val device = OfflineFormat.deviceName(context)
        if (store.owner == null || !store.state.value.serverSupported || store.state.value.items[entry.mediaItemId] == null) {
            throw StartError.Unsupported(device)
        }
        entry.unavailableReason?.let { throw StartError.Unavailable(it) }
        val existing = store.state.value.units[entry.fileId]
        if (existing != null && existing.profile == profile.profile && existing.state != OfflineUnit.State.failed && !existing.damaged) return
        checkSpace(profile, device)
        if (existing != null) {
            cancelTransfer(existing.fileId)
            store.removeUnit(existing.fileId, keepItem = true)
        }
        store.upsert(
            OfflineUnit(
                fileId = entry.fileId,
                mediaItemId = entry.mediaItemId,
                season = entry.seasonNumber,
                episode = entry.episodeNumber,
                profile = profile.profile,
                profileLabel = profile.label,
                state = OfflineUnit.State.preparing,
                expectedBytes = profile.expectedBytes,
                fileExtension = if (profile.profile == "original") fileExtension(entry.container) else "mp4",
                createdAt = System.currentTimeMillis(),
            ),
        )
        scope.launch { prefs.setLastProfile(profile.profile) }
        kick("enqueue")
    }

    private fun checkSpace(profile: OfflineProfile, device: String) {
        val needed = profile.expectedBytes + OFFLINE_RESERVE_BYTES
        val available = OfflineDisk.availableBytes() ?: return
        if (available < needed) throw StartError.NoSpace(device, needed, available, profile.profile != "original")
    }

    /** 选档面板里已取到的完整清单（开始时用，免得准备阶段再取一次） */
    private val pendingManifests = java.util.concurrent.ConcurrentHashMap<Long, OfflineManifest>()

    // ── 用户操作 ──

    fun pause(fileId: Long) {
        val unit = store.state.value.units[fileId] ?: return
        if (unit.state != OfflineUnit.State.queued && unit.state != OfflineUnit.State.downloading) return
        store.upsert(unit.copy(state = OfflineUnit.State.paused))
        cancelTransfer(fileId)
        kick("paused")
    }

    fun resume(fileId: Long) {
        val unit = store.state.value.units[fileId] ?: return
        if (unit.state != OfflineUnit.State.paused && unit.state != OfflineUnit.State.failed) return
        store.upsert(
            unit.copy(
                state = if (unit.profile != "original" && unit.exportId == null) OfflineUnit.State.preparing else OfflineUnit.State.queued,
                error = null, transcodeWait = null, retryable = true, nextRetryAt = null,
            ),
        )
        kick("resume")
    }

    // ── 下载顺序（§5.5） ──

    /**
     * 优先下载：这几个单元按给定顺序排到最前（整部剧 = 它还没下完的各集，按季集），暂停的、出错的顺带继续。
     * 排第一的能马上下就立刻开始：正在下的让路，已下的字节留在 media.part、排在它们后面。在等转码、还在准备的不打断正在下的
     */
    fun prioritize(fileIds: List<Long>) {
        for (fileId in fileIds) {
            val unit = store.state.value.units[fileId] ?: continue
            if (unit.state == OfflineUnit.State.paused || (unit.state == OfflineUnit.State.failed && !unit.waitingForTranscode)) resume(fileId)
        }
        applyOrder(fileIds)
    }

    fun prioritizeItem(itemId: Long) {
        prioritize(store.unitsOfItem(itemId).filter { it.isActive }.map { it.fileId })
    }

    /** 拖动排序后：进行中的单元按这个顺序下（顺序就是优先级，排在最前、能下的那个在下） */
    fun reorder(fileIds: List<Long>) = applyOrder(fileIds)

    private fun applyOrder(fileIds: List<Long>) {
        store.renumberQueue(fileIds)
        val head = store.state.value.units.values.filter { it.runnable }.minWithOrNull(OfflineQueue.order)
        val running = transferring
        if (head != null && running != null && head.fileId != running) cancelTransfer(running)
        kick("order")
    }

    /** 删除本机副本（任意状态）：先停掉任务，再删目录 */
    fun delete(fileId: Long) {
        cancelTransfer(fileId)
        if (preparing == fileId) prepareJob?.cancel()
        pendingManifests.remove(fileId)
        store.removeUnit(fileId)
        kick("deleted")
    }

    fun deleteItem(itemId: Long) {
        store.unitsOfItem(itemId).forEach { delete(it.fileId) }
    }

    /** 停掉某个单元正在跑的视频下载（删除、换档、暂停）。已下的字节留在 media.part */
    fun cancelTransfer(fileId: Long) {
        if (transferring != fileId) return
        transferCall?.cancel()
        transferJob?.cancel()
    }

    // ── 对账 ──

    /** 有活了：确保下载作业在跑（按当前网络策略），并叫醒正在跑的那一个 */
    fun kick(@Suppress("UNUSED_PARAMETER") reason: String) {
        wake.trySend(Unit)
        val units = store.state.value.units.values
        if (units.any { it.state != OfflineUnit.State.done && it.state != OfflineUnit.State.paused }) {
            OfflineDownloadWorker.schedule(context, prefs.allowCellular.value, replace = false)
        }
    }

    private fun online(): Boolean =
        !reachability.isOffline && reachability.status.value != ServerReachability.Status.UNREACHABLE

    /**
     * 作业本体（在 [OfflineDownloadWorker] 里跑）：逐个准备、逐个下载，直到没有能做的活。
     * 返回下一次该醒来的时刻（只剩到点才重试的失败时），没有为 null
     */
    suspend fun drive(onProgress: suspend () -> Unit): Long? = driveLock.withLock {
        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                store.waitUntilLoaded(10_000)
                val owner = store.owner ?: return@withLock null
                val now = System.currentTimeMillis()
                val units = store.state.value.units.values.sortedWith(OfflineQueue.order)
                // 失败到点了：改回准备 / 排队（iOS 对账同一条）
                for (unit in units) {
                    if (unit.state != OfflineUnit.State.failed || !unit.retryable) continue
                    val at = unit.nextRetryAt
                    if (at != null && at > now) continue
                    store.upsert(unit.copy(state = if (unit.profile != "original" && unit.exportId == null) OfflineUnit.State.preparing else OfflineUnit.State.queued))
                }
                // 准备、下载都按下载顺序挑（§5.5）
                val current = store.state.value.units.values.sortedWith(OfflineQueue.order)
                if (preparing == null && online()) {
                    current.firstOrNull { it.state == OfflineUnit.State.preparing }?.let { unit ->
                        preparing = unit.fileId
                        prepareJob = scope.launch {
                            try {
                                prepare(unit, owner)
                            } finally {
                                preparing = null
                                wake.trySend(Unit)
                            }
                        }
                    }
                }
                if (transferring == null && networkAllowsDownload()) {
                    current.firstOrNull { it.state == OfflineUnit.State.queued || it.state == OfflineUnit.State.downloading }?.let { unit ->
                        transferring = unit.fileId
                        transferJob = scope.launch {
                            try {
                                transfer(unit, owner)
                            } finally {
                                transferring = null
                                transferCall = null
                                wake.trySend(Unit)
                            }
                        }
                    }
                }
                val busy = preparing != null || transferring != null
                val pendingPrepare = current.any { it.state == OfflineUnit.State.preparing }
                val pendingTransfer = current.any { it.state == OfflineUnit.State.queued || it.state == OfflineUnit.State.downloading }
                val nextRetry = current.filter { it.state == OfflineUnit.State.failed && it.retryable }.mapNotNull { it.nextRetryAt }.minOrNull()
                // 有要下的、但眼下没有能下的网络：交回作业，按网络约束在 Wi-Fi 回来时重跑
                if (!busy && pendingTransfer && !networkAllowsDownload()) return@withLock System.currentTimeMillis()
                if (!busy && !pendingPrepare) return@withLock nextRetry
                if (!busy && pendingPrepare && !online()) {
                    // 要准备的都得连上服务器：离线时不空转，等可达性恢复（重新连上时外壳会再叫一次）
                    return@withLock nextRetry ?: (System.currentTimeMillis() + 60_000)
                }
                onProgress()
                // 等任一件活做完 / 有新活 / 到点重试；每秒刷新一次通知
                withTimeoutOrNull(1_000) { wake.receive() }
            }
            @Suppress("UNREACHABLE_CODE")
            null
        } finally {
            // 作业被系统停掉（换了网络、超时）：正在下的停下，下次作业从已下的字节接着下
            transferCall?.cancel()
            transferJob?.cancel()
            prepareJob?.cancel()
        }
    }

    // ── 准备（要在线） ──

    /** 拉齐视频之外的东西：展示数据、字幕、图片；转码档再建导出。都齐了才排队下视频 */
    private suspend fun prepare(unit: OfflineUnit, owner: OfflineOwner) {
        val api = apiFactory.forOrigin(owner.origin)
        val base = ServerRoutes.baseFor(owner.origin) ?: owner.origin
        try {
            val manifest = pendingManifests.remove(unit.fileId) ?: api.offlineManifest(unit.fileId).dataOrThrow()
            if (store.key != owner.key) return  // 准备途中换了账号：留给它自己的账号下次
            OfflinePackager(apiFactory.downloadClient(owner.origin), base, owner.key, manifest, unit, store).run()
            var current = store.state.value.units[unit.fileId] ?: return
            if (store.key != owner.key || current.state != OfflineUnit.State.preparing || current.profile != unit.profile) return
            // 整批下载先建的单元没有剧照：拿到完整清单后补上
            if (current.stillUrl == null) {
                current = current.copy(stillUrl = store.decodeSeason(manifest.season)?.episodes?.firstOrNull { it.episodeNumber == manifest.episodeNumber }?.stillUrl)
            }
            if (current.profile != "original") {
                val export = api.offlineExportCreate(OfflineExportRequest(unit.fileId, current.profile, manifest.defaultAudio)).dataOrThrow()
                if (store.key != owner.key || store.state.value.units[unit.fileId]?.state != OfflineUnit.State.preparing) return
                current = current.copy(exportId = export.exportId, expectedBytes = if (export.expectedBytes > 0) export.expectedBytes else current.expectedBytes)
            }
            store.upsert(current.copy(state = OfflineUnit.State.queued, error = null))
            reachability.catalogChanged()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (store.key != owner.key) return
            val status = (e as? OfflineHttpException)?.status ?: (e as? retrofit2.HttpException)?.code()
                ?: (e as? ApiException)?.httpCode?.takeIf { it > 0 }
            when (status) {
                400, 422 -> fail(unit.fileId, io.movieclaw.android.core.network.friendlyMessage(e), retryable = false)
                403 -> fail(unit.fileId, NOT_ALLOWED, retryable = false)
                404 -> fail(unit.fileId, "服务器上已没有这个文件", retryable = false)
                else -> fail(unit.fileId, if (e is java.io.IOException) networkMessage(e) else io.movieclaw.android.core.network.friendlyMessage(e), retryable = true)
            }
        }
    }

    // ── 视频下载 ──

    private fun contentUrl(unit: OfflineUnit, base: String): String? {
        val root = base.trimEnd('/')
        if (unit.profile == "original") return "$root/api/v1/offline/files/${unit.fileId}/content"
        val exportId = unit.exportId ?: return null
        return "$root/api/v1/offline/exports/$exportId/content"
    }

    /**
     * 流式落盘到 `media.part`，带 Range + If-Range 续传；收完整才改名成 `media.<扩展名>`、标完成。
     * 状态码是 200 或 206；有 Content-Length 的核对字节数；分块传输（边转边下）靠正常结束来判断
     */
    private suspend fun transfer(unit: OfflineUnit, owner: OfflineOwner) {
        // 发到这台服务器当前选中的地址（在家内网、出门外网）：每次（重新）开始时定
        val base = ServerRoutes.baseFor(owner.origin) ?: owner.origin
        val url = contentUrl(unit, base) ?: run {
            store.upsert(unit.copy(state = OfflineUnit.State.preparing))
            return
        }
        val key = owner.key
        val dir = OfflineDisk.unitDir(key, unit.mediaItemId, unit.fileId)
        val part = File(dir, "media.part")
        val target = File(dir, unit.mediaFileName)
        var offset = if (part.isFile) part.length() else 0L
        val startLength = offset
        val request = Request.Builder().url(url).apply {
            if (offset > 0) {
                header("Range", "bytes=$offset-")
                unit.etag?.let { header("If-Range", it) }
            }
        }.build()
        val call = apiFactory.downloadClient(owner.origin).newBuilder()
            .readTimeout(120, java.util.concurrent.TimeUnit.SECONDS)  // 边转边下时转码一时没产出的空档要扛得住
            .build().newCall(request)
        transferCall = call
        try {
            withContext(kotlinx.coroutines.Dispatchers.IO) {
                call.execute().use { resp ->
                    if (resp.code != 200 && resp.code != 206) {
                        val body = runCatching { resp.body.string().take(2000) }.getOrNull()
                        failedHTTP(
                            unit.fileId, resp.code, resp.header("Retry-After")?.toLongOrNull(), body,
                            resp.header("x-export-wait"), resp.header("x-export-ahead")?.toIntOrNull(),
                        )
                        return@use
                    }
                    val etag = resp.header("ETag")
                    var expected: Long? = null
                    if (resp.code == 206) {
                        val start = resp.header("Content-Range")?.substringAfter("bytes ")?.substringBefore('-')?.trim()?.toLongOrNull()
                        if (start != offset) offset = 0  // 服务端给的不是接着的那段：从头下
                        expected = parseContentRangeTotal(resp.header("Content-Range"))
                    } else {
                        offset = 0
                        expected = resp.body.contentLength().takeIf { it > 0 }
                    }
                    store.state.value.units[unit.fileId]?.let { current ->
                        store.upsert(current.copy(state = OfflineUnit.State.downloading, etag = etag ?: current.etag, receivedBytes = offset))
                    }
                    dir.mkdirs()
                    FileOutputStream(part, offset > 0).use { out ->
                        if (offset == 0L) out.channel.truncate(0)
                        val input = resp.body.byteStream()
                        val buf = ByteArray(256 * 1024)
                        var received = offset
                        var lastTick = 0L
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            received += n
                            val now = System.currentTimeMillis()
                            if (now - lastTick >= 1_000) {
                                lastTick = now
                                store.updateReceived(unit.fileId, received, expected)
                            }
                        }
                        out.fd.sync()
                        // 有长度却没收全：不当成完成
                        if (expected != null && received != expected) throw java.io.IOException("下载中断")
                    }
                    finished(unit, owner, part, target)
                }
            }
        } catch (e: CancellationException) {
            // 暂停、删除、作业被停：已下的字节留着
            persistReceived(unit.fileId, part)
            throw e
        } catch (e: java.io.IOException) {
            persistReceived(unit.fileId, part)
            if (call.isCanceled()) return
            val noSpace = e.message?.contains("ENOSPC") == true || e.message?.contains("No space", ignoreCase = true) == true
            if (!noSpace && networkAllowsDownload() && quickRetry(unit.fileId, progressed = part.length() != startLength)) {
                // 连接断了、网络还在（多半是切了网络：蜂窝 ↔ Wi-Fi）：占着「正在下」稍等一下原地接着下，
                // 不按失败退避——不然排在后面的趁机先开始，排第一的反倒要等它下完（§5.5，iOS 真机遇到过）
                delay(2_000)
                return
            }
            failedTransport(unit.fileId, e, noSpace)
        }
    }

    /**
     * 这一回断了还原地重来吗：这一回收到过数据就从头数；连续 3 回一个字节都没收到才按失败退避。
     * 收没收到看已下文件的长度变没变（服务端整份重给时先截成 0 再写，变短也算收到过）
     */
    private fun quickRetry(fileId: Long, progressed: Boolean): Boolean {
        val count = (if (progressed) 0 else quickRetries[fileId] ?: 0) + 1
        quickRetries[fileId] = count
        return count <= 3
    }

    /** 停下来时把已下字节写进单元（界面上的进度与下次续传的起点一致） */
    private fun persistReceived(fileId: Long, part: File) {
        val current = store.state.value.units[fileId] ?: return
        if (!part.isFile) return
        val next = current.copy(receivedBytes = part.length(), state = if (current.state == OfflineUnit.State.downloading) OfflineUnit.State.queued else current.state)
        store.upsert(next)
    }

    /** 下完：改名进来、标完成；转码档告诉服务端可以回收导出（尽力而为，服务端另有过期） */
    private suspend fun finished(unit: OfflineUnit, owner: OfflineOwner, part: File, target: File) {
        quickRetries.remove(unit.fileId)
        val moved = OfflineDisk.perform {
            // 读单元、挪文件和删除走同一个写盘线程：删到一半挪进来会在删掉的目录里留下孤儿文件
            if (!OfflineDisk.unitFile(owner.key, unit.mediaItemId, unit.fileId).isFile) return@perform false
            // 转码档：负的 tfdt 改成 0，Exo 才读得了（见 Fmp4Fixup）
            // 补分片索引，才拖得动、才能从续播点起播
            if (unit.profile != "original") {
                runCatching { Fmp4Fixup.clampNegativeTfdt(part) }
                runCatching { Fmp4Fixup.addSegmentIndex(part) }
            }
            target.delete()
            part.renameTo(target)
        }
        if (!moved) return
        val size = target.length()
        val current = store.state.value.units[unit.fileId] ?: return
        store.upsert(
            current.copy(
                state = OfflineUnit.State.done, receivedBytes = size, expectedBytes = size, completedAt = System.currentTimeMillis(),
                error = null, attempts = 0, nextRetryAt = null, transcodeWait = null,
            ),
        )
        reachability.catalogChanged()
        store.onCatalogChanged?.invoke()
        current.exportId?.let { exportId ->
            scope.launch { runCatching { apiFactory.forOrigin(owner.origin).offlineExportRelease(exportId) } }
        }
    }

    private fun failedHTTP(fileId: Long, status: Int, retryAfter: Long?, message: String?, exportWait: String?, exportsAhead: Int?) {
        when (status) {
            503 -> {
                // 导出还在排队：按服务端说的时间再来。界面写在等什么
                val note = transcodeWaitNote(exportWait, exportsAhead)
                update(fileId) {
                    it.copy(
                        state = OfflineUnit.State.failed, retryable = true, error = "服务器正在排队转码", transcodeWait = note,
                        nextRetryAt = System.currentTimeMillis() + (retryAfter ?: 60) * 1000,
                    )
                }
            }
            // 可重试：重新登录后会接着下（退避到最长一小时，不会一直打服务器）
            401 -> fail(fileId, "这个账号在本机的登录已失效，重新登录后会接着下", retryable = true)
            403 -> fail(fileId, NOT_ALLOWED, retryable = false)
            404, 410 -> {
                val transcoded = store.state.value.units[fileId]?.profile != "original"
                fail(fileId, "服务器上已没有这个文件（可能被删除、移动或回收了导出）", retryable = transcoded, resetExport = true)
            }
            416 -> {
                // 续传的起点超出了服务端那份（换了文件）：从头下
                update(fileId) { it.copy(etag = null) }
                OfflineDisk.enqueue { store.unitDir(store.state.value.units[fileId] ?: return@enqueue)?.let { File(it, "media.part").delete() } }
                fail(fileId, "服务器出错了（HTTP 416）", retryable = true)
            }
            422 -> fail(fileId, message?.let(::errorMessage) ?: "服务器转码失败", retryable = false)
            else -> fail(fileId, "服务器出错了（HTTP $status）", retryable = true)
        }
    }

    private fun failedTransport(fileId: Long, error: java.io.IOException, noSpace: Boolean) {
        if (noSpace) {
            fail(fileId, "${OfflineFormat.deviceName(context)} 空间不足，清理一些空间后点「重试」", retryable = false)
            return
        }
        // 没有能下的网络了（Wi-Fi 断了、只剩蜂窝）：不算失败，作业按约束在网络回来后接着下
        if (!networkAllowsDownload()) {
            update(fileId) { if (it.state == OfflineUnit.State.downloading) it.copy(state = OfflineUnit.State.queued) else it }
            return
        }
        fail(fileId, networkMessage(error), retryable = true)
    }

    private fun networkAllowsDownload(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager ?: return true
        val caps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) } ?: return false
        if (!caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
        return prefs.allowCellular.value || caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    private fun fail(fileId: Long, message: String, retryable: Boolean, resetExport: Boolean = false) {
        update(fileId) { unit ->
            val attempts = unit.attempts + 1
            val steps = longArrayOf(30, 120, 600, 1800, 3600)
            unit.copy(
                state = OfflineUnit.State.failed, transcodeWait = null, error = message, retryable = retryable, attempts = attempts,
                nextRetryAt = if (retryable) System.currentTimeMillis() + steps[minOf(attempts - 1, steps.size - 1)] * 1000 else null,
                // 转码档 404 = 导出被回收：回到准备阶段重建导出
                exportId = if (retryable && resetExport && unit.profile != "original") null else unit.exportId,
                etag = if (retryable && resetExport) null else unit.etag,
            )
        }
    }

    private fun update(fileId: Long, change: (OfflineUnit) -> OfflineUnit) {
        val unit = store.state.value.units[fileId] ?: return
        store.upsert(change(unit))
    }

    companion object {
        private const val NOT_ALLOWED = "管理员未对你开放下载影片到设备"

        /** 排队转码时界面上的一句话（服务端 503 的 x-export-wait / x-export-ahead；旧服务端没有，就只说在排队） */
        fun transcodeWaitNote(wait: String?, ahead: Int?): String = when {
            wait == "transcoder" -> "等待转码器空闲"
            ahead != null && ahead > 0 -> "等待转码，前面还有 $ahead 个"
            wait == "queue" -> "即将开始转码"
            else -> "等待转码"
        }

        fun fileExtension(container: String?): String {
            val raw = container.orEmpty().lowercase()
            val known = listOf("mp4", "mkv", "m4v", "mov", "ts", "m2ts", "avi", "webm", "flv", "wmv", "mpg", "mpeg", "iso", "rmvb")
            if (raw in known) return raw
            if (raw == "matroska") return "mkv"
            return if (raw.isEmpty()) "mkv" else raw.filter { it.isLetter() }.take(5)
        }

        private fun networkMessage(error: java.io.IOException): String = when (error) {
            is java.net.SocketTimeoutException -> "连接超时，稍后自动重试"
            is java.net.UnknownHostException, is java.net.ConnectException -> "连不上服务器，稍后自动重试"
            else -> "下载中断"
        }

        /** 422 的响应体是统一信封：取它的 message */
        private fun errorMessage(body: String): String? = runCatching {
            (kotlinx.serialization.json.Json.parseToJsonElement(body) as? kotlinx.serialization.json.JsonObject)
                ?.get("message")?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
        }.getOrNull()
    }
}

/** `Content-Range: bytes 0-99/1000` → 1000；总长为 `*`（未知）或格式不对 → null */
internal fun parseContentRangeTotal(header: String?): Long? {
    val raw = header?.trim().orEmpty()
    if (!raw.startsWith("bytes ", ignoreCase = true)) return null
    return raw.substringAfter('/', "").trim().toLongOrNull()
}
