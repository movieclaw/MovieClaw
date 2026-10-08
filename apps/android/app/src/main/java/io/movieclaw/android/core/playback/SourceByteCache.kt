package io.movieclaw.android.core.playback

import android.content.Context
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import io.movieclaw.android.core.network.BuildInfo
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 片源字节缓存 —— iOS `PlaybackController.sourceCacheKey` + `AetherPlayback.prefetchSource`
 * 的对应物。
 *
 * 两件事共用同一份缓存：
 *  · **播放时顺手下**：引擎的数据源链里挂一层 `CacheDataSource`，放过的字节落盘；
 *  · **刷片预取**：`/reels` 的 `play.prefetch` 给出该取的字节范围（文件头 / 索引 /
 *    起点后几秒），按范围下进去。滑到下一条时那一段已经在本地，起播不用等网络。
 *
 * 键与 iOS 同一口径（文件 id + 大小）：同一个文件在不同入口（正片页 / 刷片 /
 * 「接着看」）下过的字节彼此复用。缓存目录用 `cacheDir`（系统可回收），带 LRU 上限。
 */
@UnstableApi
object SourceByteCache {

    private const val DIR = "source-bytes"

    /** 上限 1.5 GB：一集 4K 大约 20~40 GB，缓存只为「刚看过的那点」服务，不做全片下载 */
    private const val MAX_BYTES = 1_500L * 1024 * 1024

    @Volatile private var instance: Cache? = null

    /**
     * 上限按**剩余空间**降档（iOS `NativeStoragePlan` 的对应物：存储紧张时收小、再紧不落盘）：
     * ≥24GB 给满 1.5GB；<24GB 收到 768MB；<8GB 收到 256MB；<2GB 基本不缓存（留 1MB 给 SimpleCache 建起来）。
     */
    private fun capBytes(context: Context): Long {
        val free = runCatching { context.applicationContext.cacheDir.usableSpace }.getOrDefault(Long.MAX_VALUE)
        val mb = 1024L * 1024
        return when {
            free < 2L * 1024 * mb -> 1L * mb
            free < 8L * 1024 * mb -> 256L * mb
            free < 24L * 1024 * mb -> 768L * mb
            else -> MAX_BYTES
        }
    }

    fun cache(context: Context): Cache = instance ?: synchronized(this) {
        instance ?: run {
            val cap = capBytes(context)
            android.util.Log.i("McPlayer", "片源字节缓存 上限=${cap / 1024 / 1024}MB（按剩余空间定档）")
            SimpleCache(
                File(context.applicationContext.cacheDir, DIR),
                LeastRecentlyUsedCacheEvictor(cap),
                StandaloneDatabaseProvider(context.applicationContext),
            ).also { instance = it }
        }
    }

    /** 退出登录 / 移除账号时清空（跨账号共用的字节不该留着） */
    fun clear(context: Context) {
        synchronized(this) {
            val dir = File(context.applicationContext.cacheDir, DIR)
            runCatching { instance?.release() }
            instance = null
            // 用 Media3 的静态删除：连元数据一起收干净（只删目录会留下指向空文件的索引）
            runCatching {
                SimpleCache.delete(dir, StandaloneDatabaseProvider(context.applicationContext))
            }
        }
    }

    /** 缓存键：文件 id + 大小（`fileId` 为 0 或大小未知时不下缓存） */
    fun key(fileId: Long, sizeBytes: Long?, origin: String): String? {
        if (fileId <= 0L) return null
        val scope = java.security.MessageDigest.getInstance("SHA-256")
            .digest(origin.trimEnd('/').toByteArray()).joinToString("") { "%02x".format(it) }
        return "$scope-file-$fileId-${sizeBytes ?: 0L}"
    }

    private fun httpFactory(): DefaultHttpDataSource.Factory = DefaultHttpDataSource.Factory()
        .setAllowCrossProtocolRedirects(true)
        .setConnectTimeoutMs(15_000)
        .setReadTimeoutMs(30_000)
        .setUserAgent(BuildInfo.USER_AGENT)

    /** 引擎侧要挂的那层：读命中缓存、放过的字节顺手写进去 */
    fun playbackFactory(context: Context, upstream: androidx.media3.datasource.DataSource.Factory): CacheDataSource.Factory = CacheDataSource.Factory()
        .setCache(cache(context))
        .setUpstreamDataSourceFactory(upstream)
        .setCacheWriteDataSinkFactory(
            androidx.media3.datasource.cache.CacheDataSink.Factory().setCache(cache(context)),
        )
        // 缓存目录写不进去（盘满 / 权限）时别影响播放：直接走网络
        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

    /**
     * 按字节范围把一段下进缓存。已缓存的区段由 `CacheDataSource` 跳过，不会重下。
     *
     * @return 实际本次写入的字节数（失败的那几段不计）
     */
    suspend fun prefetch(
        context: Context,
        url: String,
        cacheKey: String,
        ranges: List<Pair<Long, Long>>,
    ): Long = withContext(Dispatchers.IO) {
        if (ranges.isEmpty()) return@withContext 0L
        val dataSource = CacheDataSource.Factory()
            .setCache(cache(context))
            .setUpstreamDataSourceFactory(httpFactory())
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            .createDataSource()
        var written = 0L
        try {
            for ((offset, length) in ranges) {
                currentCoroutineContext().ensureActive()
                if (length <= 0L) continue
                val spec = DataSpec.Builder()
                    .setUri(url)
                    .setKey(cacheKey)
                    .setPosition(offset)
                    .setLength(length)
                    .build()
                val writer = CacheWriter(dataSource, spec, ByteArray(CacheWriter.DEFAULT_BUFFER_SIZE_BYTES), null)
                try {
                    coroutineScope {
                        // 取消立即告知 CacheWriter；当前有界网络读取完成后停止，不继续下载下一范围。
                        val cancellation = launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
                            try { awaitCancellation() } finally { writer.cancel() }
                        }
                        try { writer.cache() } finally { cancellation.cancel() }
                    }
                    written += length
                } catch (e: CancellationException) { throw e } catch (_: java.io.IOException) { break }
                // 失败（断网 / 令牌过期 / 这条被取消）就到此为止：只是预取，播放时还会再取一遍
                if (!cache(context).isCached(cacheKey, offset, length)) break
            }
        } finally {
            runCatching { dataSource.close() }
        }
        written
    }

    /** 这一段已经在本地了吗（等于「下载完成」，与 iOS `prefetch` 的 await 同义） */
    fun isCached(context: Context, cacheKey: String, ranges: List<Pair<Long, Long>>): Boolean =
        ranges.all { (offset, length) ->
            length <= 0L || cache(context).isCached(cacheKey, offset, length)
        }
}
