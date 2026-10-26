package io.movieclaw.android.core.offline

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import io.movieclaw.android.core.network.ServerRoutes
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

private const val BATCH_MANIFEST_RETRY_MS = 5_000L

/** 断网时最多等约 5 分钟；服务器真没有这个文件时不要无限重试 */
private const val BATCH_MANIFEST_ATTEMPTS = 60

/**
 * 离线下载器：一个单元一个 Job（串行队列），OkHttp 流式落盘 + Range 续传。
 *
 * 原画档：GET /offline/files/{id}/content（Range 续传）；
 * 转码档：POST /offline/exports 建导出 → 轮询进度（503 + Retry-After = 排队/转码中）→
 * GET /offline/exports/{id}/content 下载；完成后 DELETE 通知服务端回收。
 * 海报与 manifest 在开始时一并落盘，文件夹即完整副本。
 */
@Singleton
class OfflineDownloader @Inject constructor(
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
    private val store: OfflineStore,
    private val prefs: OfflinePrefs,
) {
    sealed interface TaskState {
        data object Queued : TaskState
        data class Downloading(val downloadedBytes: Long, val totalBytes: Long, val speedBps: Long) : TaskState
        data object Paused : TaskState
        data class Failed(val message: String) : TaskState
        /** 只在 Wi-Fi 下下载（iOS 默认）：当前是蜂窝且没允许蜂窝，等网络 */
        data object WaitingForWifi : TaskState
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }

    private val _tasks = MutableStateFlow<Map<Long, TaskState>>(emptyMap())
    val tasks: StateFlow<Map<Long, TaskState>> = _tasks.asStateFlow()

    private val jobs = java.util.concurrent.ConcurrentHashMap<Long, Job>()

    /** 当前在跑的下载请求：取消/暂停时直接 cancel()，否则阻塞在 socket 读上停不下来（评审问题 3） */
    private val calls = java.util.concurrent.ConcurrentHashMap<Long, okhttp3.Call>()
    @Volatile private var pausedIds = setOf<Long>()

    /** 已经开始过（含暂停/失败）的单元：详情页的下载状态条据此出现，不用回下载页找 */
    private val _known = MutableStateFlow<Map<Long, OfflineStore.Pack>>(emptyMap())
    val known: StateFlow<Map<Long, OfflineStore.Pack>> = _known.asStateFlow()

    /** 清单缓存：暂停后「继续」「重试」不必重新问服务端 */
    private val manifests = java.util.concurrent.ConcurrentHashMap<Long, io.movieclaw.android.core.model.OfflineManifest>()

    private data class PendingStart(
        val origin: String,
        val pack: OfflineStore.Pack,
        val manifest: io.movieclaw.android.core.model.OfflineManifest,
        val profile: String?,
    )

    /** 因为「只在 Wi-Fi 下下载」而停下的任务：等网络条件满足后从已落盘字节续传 */
    private val waiting = java.util.concurrent.ConcurrentHashMap<Long, PendingStart>()
    private val activeArgs = java.util.concurrent.ConcurrentHashMap<Long, PendingStart>()
    @Volatile private var allowCellular = false

    init {
        scope.launch {
            prefs.allowCellular.collect { allowed ->
                val changed = allowed != allowCellular
                allowCellular = allowed
                if (changed) syncNetworkPolicy()
            }
        }
        scope.launch { syncNetworkPolicy() }
        registerNetworkCallback()
        // 切账号：旧账号的任务不能在别人的目录里继续写
        scope.launch {
            var lastOwner = store.ownerKey.value
            store.ownerKey.collect { key ->
                if (lastOwner != null && key != lastOwner) {
                    jobs.values.toList().forEach { runCatching { it.cancel() } }
                    synchronized(jobs) { jobs.clear() }
                    calls.values.forEach { runCatching { it.cancel() } }
                    calls.clear()
                    waiting.clear()
                    activeArgs.clear()
                    _tasks.value = emptyMap()
                    _known.value = emptyMap()
                }
                lastOwner = key
            }
        }
    }

    private fun registerNetworkCallback() {
        val cm = context.getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager ?: return
        runCatching {
            cm.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) {
                    syncNetworkPolicy()
                }

                override fun onLost(network: android.net.Network) {
                    // Wi-Fi 直接断掉、没有蜂窝可切时也要把任务停进等待态，而不是让 socket 报错收场
                    syncNetworkPolicy()
                }

                override fun onCapabilitiesChanged(network: android.net.Network, caps: android.net.NetworkCapabilities) {
                    syncNetworkPolicy()
                }
            })
        }
    }

    /** 当前网络能不能下载：允许蜂窝时任何网络都行；否则要有 Wi-Fi / 有线 / VPN 通路 */
    private fun networkAllowsDownload(): Boolean {
        if (allowCellular) return true
        val cm = context.getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager ?: return true
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) ||
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)
    }

    private fun syncNetworkPolicy() {
        if (!networkAllowsDownload()) parkAllForWifi() else resumeWaiting()
    }

    private fun parkAllForWifi() {
        // 已经在等待的也保持「等待 Wi-Fi」，不要因为后续网络事件又变回排队
        waiting.keys.forEach { id ->
            if (_tasks.value[id] != TaskState.WaitingForWifi) {
                _tasks.update { it + (id to TaskState.WaitingForWifi) }
            }
        }
        jobs.keys.toList().forEach { id ->
            val pending = activeArgs[id] ?: return@forEach
            // 先登记再 cancel：cancel 出来的 IOException 会走 onFailure，看到 waiting 就不再标失败
            waiting[id] = pending
            _tasks.update { it + (id to TaskState.WaitingForWifi) }
            calls.remove(id)?.cancel()
            jobs.remove(id)?.cancel()
        }
    }

    private fun resumeWaiting() {
        if (!networkAllowsDownload()) return
        val pending = waiting.entries.toList()
        pending.forEach { (id, p) ->
            // 旧 job 还在收尾时先留在等待队列；它的 invokeOnCompletion 会再触发一次
            if (jobs.containsKey(id)) return@forEach
            waiting.remove(id)
            start(p.origin, p.pack, p.manifest, p.profile)
        }
    }

    fun isBusy(fileId: Long): Boolean = jobs.containsKey(fileId)

    /** 原画：直接下原文件 */
    fun enqueueOriginal(origin: String, pack: OfflineStore.Pack, manifest: io.movieclaw.android.core.model.OfflineManifest) {
        start(origin, pack, manifest, profile = null)
    }

    /** 转码档：建导出 → 轮询 → 下载导出文件 */
    fun enqueueExport(origin: String, pack: OfflineStore.Pack, manifest: io.movieclaw.android.core.model.OfflineManifest, profile: String) {
        start(origin, pack, manifest, profile = profile)
    }

    /**
     * 批量下载（剧集范围）：清单在应用级 scope 里逐集取，断网时等网络恢复再继续，
     * 不把「范围里还没轮到的集」静默跳过。切账号后旧批次的后续集不再启动。
     */
    fun enqueueBatch(
        origin: String,
        fileIds: List<Long>,
        profile: String,
        packOf: (io.movieclaw.android.core.model.OfflineManifest) -> OfflineStore.Pack,
    ) {
        val owner = store.ownerKey.value
        scope.launch {
            val api = apiFactory.forOrigin(origin)
            for (fileId in fileIds) {
                if (owner != null && store.ownerKey.value != owner) return@launch
                if (store.packFor(fileId) != null) continue
                var manifest = manifests[fileId]
                var attempts = 0
                while (manifest == null && attempts < BATCH_MANIFEST_ATTEMPTS) {
                    if (owner != null && store.ownerKey.value != owner) return@launch
                    attempts++
                    manifest = runCatching { api.offlineManifest(fileId).dataOrThrow() }.getOrNull()
                    if (manifest == null && attempts < BATCH_MANIFEST_ATTEMPTS) {
                        kotlinx.coroutines.delay(BATCH_MANIFEST_RETRY_MS)
                    }
                }
                val ready = manifest
                if (ready == null) {
                    android.util.Log.w("OfflineDownload", "批量下载取清单失败，跳过 fileId=$fileId")
                    continue
                }
                start(origin, packOf(ready), ready, profile.takeIf { it != "original" })
            }
            store.scan()
        }
    }

    fun pause(fileId: Long) {
        pausedIds = pausedIds + fileId
        waiting.remove(fileId)
        activeArgs.remove(fileId)
        calls.remove(fileId)?.cancel()
        jobs.remove(fileId)?.cancel()
        _tasks.update { it + (fileId to TaskState.Paused) }
    }

    /** 续传：从已落盘字节起 Range 续（转码档 503 排队时从头，服务端支持导出续传） */
    fun resume(origin: String, pack: OfflineStore.Pack, manifest: io.movieclaw.android.core.model.OfflineManifest, profile: String?) {
        pausedIds = pausedIds - pack.fileId
        start(origin, pack, manifest, profile)
    }

    /** 继续 / 重试（详情页状态条用）：清单有缓存就用缓存，没缓存现取一份 */
    fun resumePack(origin: String, pack: OfflineStore.Pack) {
        pausedIds = pausedIds - pack.fileId
        _tasks.update { it - pack.fileId }   // 清掉上一次的失败/暂停态，交给 start 置 Queued
        scope.launch {
            val manifest = manifests[pack.fileId] ?: runCatching {
                apiFactory.forOrigin(origin).offlineManifest(pack.fileId).dataOrThrow()
            }.getOrNull()
            if (manifest == null) {
                _tasks.update { it + (pack.fileId to TaskState.Failed("拿不到下载信息")) }
                return@launch
            }
            start(origin, pack, manifest, pack.profile.takeIf { it != "original" })
        }
    }

    /** 删除本机副本 / 取消下载（详情页与下载页共用）：只动本机，观看进度保留在服务端 */
    fun deleteLocal(origin: String, pack: OfflineStore.Pack) {
        cancel(origin, pack, exportId = null)
        _known.update { it - pack.fileId }
        manifests.remove(pack.fileId)
    }

    fun cancel(origin: String, pack: OfflineStore.Pack, exportId: String?) {
        pausedIds = pausedIds - pack.fileId
        waiting.remove(pack.fileId)
        activeArgs.remove(pack.fileId)
        calls.remove(pack.fileId)?.cancel()
        jobs.remove(pack.fileId)?.cancel()
        _tasks.update { it - pack.fileId }
        exportId?.let { id ->
            scope.launch { runCatching { apiFactory.forOrigin(origin).offlineExportRelease(id) } }
        }
        store.delete(pack.mediaItemId, pack.fileId)
    }

    private fun start(origin: String, pack: OfflineStore.Pack, manifest: io.movieclaw.android.core.model.OfflineManifest, profile: String?) {
        if (jobs.containsKey(pack.fileId)) return
        manifests[pack.fileId] = manifest
        _known.update { it + (pack.fileId to pack) }
        if (!networkAllowsDownload()) {
            waiting[pack.fileId] = PendingStart(origin, pack, manifest, profile)
            _tasks.update { it + (pack.fileId to TaskState.WaitingForWifi) }
            return
        }
        waiting.remove(pack.fileId)
        activeArgs[pack.fileId] = PendingStart(origin, pack, manifest, profile)
        _tasks.update { it + (pack.fileId to TaskState.Queued) }
        val job = scope.launch {
            runCatching { run(origin, pack, manifest, profile) }
                .onFailure { e ->
                    if (e is CancellationException) return@onFailure // 暂停/取消：保留已落盘字节
                    // 已被网络策略停进等待队列：cancel() 带来的 IOException 不能把它改写成失败
                    if (waiting.containsKey(pack.fileId)) return@onFailure
                    if (!networkAllowsDownload()) {
                        // 下载途中 Wi-Fi 掉线、蜂窝又不可用：回等待队列，网络恢复后从已落盘字节续传
                        waiting[pack.fileId] = PendingStart(origin, pack, manifest, profile)
                        _tasks.update { it + (pack.fileId to TaskState.WaitingForWifi) }
                        android.util.Log.i("OfflineDownload", "网络断开，等待 Wi-Fi 后继续 fileId=${pack.fileId}")
                        return@onFailure
                    }
                    android.util.Log.w("OfflineDownload", "下载失败 fileId=${pack.fileId}: ${e.message}", e)
                    _tasks.update { it + (pack.fileId to TaskState.Failed(e.message ?: "下载失败")) }
                }
        }
        jobs[pack.fileId] = job
        // 无论成功、失败还是取消，任务结束都要把 jobs 里的记录摘掉——
        // 否则「重试/继续」会被 start() 的 containsKey 判断直接挡回，界面永远停在排队（评审问题 3）
        job.invokeOnCompletion {
            synchronized(jobs) { if (jobs[pack.fileId] === job) jobs.remove(pack.fileId) }
            activeArgs.remove(pack.fileId)
            // 网络在 job 收尾前就恢复了：任务还在 waiting，补一次续传
            if (waiting.containsKey(pack.fileId) && networkAllowsDownload()) resumeWaiting()
        }
    }

    private suspend fun run(origin: String, pack: OfflineStore.Pack, manifest: io.movieclaw.android.core.model.OfflineManifest, profile: String?) {
        val api = apiFactory.forOrigin(origin)
        val client = apiFactory.downloadClient(origin)

        // 所有下载请求都走当前选中的入口（内网/外网自动选连；登录地址出门可能不可达）
        val base = ServerRoutes.baseFor(origin) ?: origin.trimEnd('/')

        // 1) pack.json + 海报先落盘（文件夹即事实来源）
        store.savePack(pack)
        manifest.posterUrl()?.let { poster ->
            runCatching {
                val url = poster.let { raw ->
                    if (raw.startsWith("http")) raw
                    else base + "/api/v1/images/proxy?url=" + java.net.URLEncoder.encode(raw, "UTF-8") + "&w=600"
                }
                client.newCall(okhttp3.Request.Builder().url(url).build()).execute().use { resp ->
                    if (resp.isSuccessful) store.posterFile(pack.mediaItemId, pack.fileId).outputStream().use { out ->
                        resp.body.byteStream().copyTo(out)
                    }
                }
            }
        }

        // 2) 正片
        when (profile) {
            null -> {
                val target = store.videoFile(pack.mediaItemId, pack.fileId, manifest.container)
                downloadWithResume(client, base, "/api/v1/offline/files/${pack.fileId}/content", pack, target)
            }
            else -> {
                val created = api.offlineExportCreate(io.movieclaw.android.core.model.OfflineExportRequest(pack.fileId, profile)).dataOrThrow()
                val target = store.videoFile(pack.mediaItemId, pack.fileId, "mp4")
                waitExport(client, origin, created.exportId, pack)
                // contentUrl 已含 /api/v1 前缀（服务端原样给），不要再拼
                downloadWithResume(client, base, created.contentUrl, pack, target)
                // 下载完成：通知服务端回收这份导出（只摘本设备，别的设备还要时留着）
                runCatching { api.offlineExportRelease(created.exportId) }
            }
        }

        // 3) 完成：登记副本；状态条随之消失（副本改由「文件」区的本机行代表）
        _tasks.update { it - pack.fileId }
        _known.update { it - pack.fileId }
        store.scan()
    }

    /** 轮询导出：queued/running 继续等（服务端 503 带 Retry-After），done/failed 落定 */
    private suspend fun waitExport(client: okhttp3.OkHttpClient, origin: String, exportId: String, pack: OfflineStore.Pack) {
        val api = apiFactory.forOrigin(origin)
        var polls = 0
        while (true) {
            val state = runCatching { api.offlineExportGet(exportId).dataOrThrow() }.getOrNull()
                ?: throw IllegalStateException("导出查询失败")
            polls++
            when (state.status) {
                "done" -> return
                "failed" -> throw IllegalStateException(state.error ?: "转码失败")
                else -> {
                    // 转码中：状态条写「等待转码」而不是假装 0%（iOS 的 hourglass 同义）
                    _tasks.update { it + (pack.fileId to TaskState.Queued) }
                    withContext(kotlinx.coroutines.Dispatchers.IO) { kotlinx.coroutines.delay(2_000) }
                }
            }
        }
    }

    /**
     * 流式落盘 + Range 续传 + 速度/进度发布；暂停/取消会 cancel OkHttp 的 Call，阻塞读立刻结束。
     *
     * 下载中的字节写在 `download.part`，完整收下才改名成 `video.*`：否则 OfflineStore.scan()
     * 见到未下完的 video 文件就当成本机副本，下载页会把「下载中」误算成「已下载」，
     * 断 Wi-Fi 续传时也找不到真正的进度。
     */
    private suspend fun downloadWithResume(
        client: okhttp3.OkHttpClient,
        base: String,
        path: String,
        pack: OfflineStore.Pack,
        target: File,
    ): File {
        target.parentFile?.mkdirs()
        val part = File(target.parentFile, "download.part")
        var downloaded = if (part.isFile) part.length() else 0L
        val startedAt = System.currentTimeMillis()
        var lastTick = startedAt
        var lastBytes = downloaded

        val request = okhttp3.Request.Builder()
            .url(base.trimEnd('/') + path)
            .apply { if (downloaded > 0) header("Range", "bytes=$downloaded-") }
            .build()
        val call = client.newCall(request)
        calls[pack.fileId] = call
        try {
            call.execute().use { resp ->
                if (resp.code != 200 && resp.code != 206) {
                    throw IllegalStateException("下载失败(HTTP ${resp.code})")
                }
                val body = resp.body ?: throw IllegalStateException("下载失败：空响应")
                val total = if (resp.code == 206) {
                    // Content-Range: bytes a-b/total → total（以前多 +1，进度到不了 100%）
                    parseContentRangeTotal(resp.header("content-range")) ?: (downloaded + body.contentLength())
                } else body.contentLength()
                java.io.FileOutputStream(part, resp.code == 206).use { out ->
                    if (resp.code == 200) {
                        out.channel.truncate(0) // 服务端不支持 Range：从头重下
                        downloaded = 0L
                        lastBytes = 0L
                    }
                    val buf = ByteArray(256 * 1024)
                    body.byteStream().let { input ->
                        while (true) {
                            // 暂停/取消：calls.cancel() 会让阻塞读抛 IOException；协程取消走 ensureActive
                            if (pausedIds.contains(pack.fileId)) throw CancellationException("paused")
                            kotlinx.coroutines.currentCoroutineContext().ensureActive()
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            downloaded += n
                            val now = System.currentTimeMillis()
                            if (now - lastTick >= 800) {
                                val speed = ((downloaded - lastBytes) * 1000 / (now - lastTick)).coerceAtLeast(0)
                                lastTick = now; lastBytes = downloaded
                                _tasks.update {
                                    it + (pack.fileId to TaskState.Downloading(downloaded, total, speed))
                                }
                            }
                        }
                    }
                }
            }
        } finally {
            calls.remove(pack.fileId)
        }
        if (target.exists()) target.delete()
        if (!part.renameTo(target)) throw IllegalStateException("下载完成但保存失败")
        return target
    }
}

/** manifest 里挖海报地址（item.poster_url 优先，其次 backdrop） */
private fun io.movieclaw.android.core.model.OfflineManifest.posterUrl(): String? {
    val item = item ?: return null
    val obj = item as? kotlinx.serialization.json.JsonObject ?: return null
    return (obj["poster_url"] ?: obj["backdrop_url"])
        ?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
        ?: (obj["poster_url"] as? kotlinx.serialization.json.JsonPrimitive)?.content
}

/**
 * `Content-Range: bytes 0-99/1000` → 1000；总长为 `*`（未知）或格式不对 → null。
 * 以前是 substringAfter('/') 再 +1，总大小多一字节、进度永远差 1（评审问题 3 的小项）。
 */
internal fun parseContentRangeTotal(header: String?): Long? {
    val raw = header?.trim().orEmpty()
    if (!raw.startsWith("bytes ", ignoreCase = true)) return null
    val totalPart = raw.substringAfter('/', "").trim()
    return totalPart.toLongOrNull()
}
