package io.movieclaw.android.core.playback

import android.content.Context
import android.graphics.Bitmap
import androidx.collection.LruCache
import coil3.request.ImageRequest
import coil3.toBitmap
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.api.McApi
import io.movieclaw.android.core.model.TrickplayView
import io.movieclaw.android.core.network.dataOrThrow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * trickplay 进度条缩略图(iOS TrickplayImages 的对应物):
 *   服务端把整片按时长切成雪碧图(sheet),每个小格 interval_ms 一格;
 *   客户端按位置算格号 → 取对应 sheet → 裁出那一格。
 * sheet 走签名 token(从会话的 streamUrl 里复用,与 iOS 同款做法)。
 */
@Singleton
class TrickplayProvider @Inject constructor(
    @ApplicationContext private val context: Context,
    private val imageLoaders: ImageLoaders,
) {

    private val sheetCache = LruCache<String, Bitmap>(6)
    private val tileCache = LruCache<String, Bitmap>(48)

    private var info: TrickplayView? = null
    private var token: String = ""

    /** 换片/重开会话时让上一轮的轮询作废 */
    private var generation = 0

    /**
     * 会话返回 streamUrl 后调用:解析 token 并拉取雪碧图信息。
     *
     * **雪碧图是开会话时在服务端后台生成的**，第一次问基本都是 `ready:false`（服务端原话：
     * "没就绪就是 ready:false，表现为没有预览，不影响播放。所以调用方轮询几次即可"）。
     * 旧实现只问一次就完了，于是进度条预览从来没出来过。这里持续轮询直到就绪或换片
     * （每次 prepare 都会让上一轮的轮询作废）。
     */
    suspend fun prepare(api: McApi, fileId: Long?, streamUrl: String?) {
        info = null
        generation++
        val mine = generation
        if (fileId == null || streamUrl.isNullOrEmpty()) return
        token = extractToken(streamUrl)
        if (token.isEmpty()) return
        repeat(MAX_POLLS) { attempt ->
            val view = runCatching { api.trickplay(fileId, token).dataOrThrow() }.getOrNull()
            if (mine != generation) return          // 已经换片/重开会话，这一轮作废
            if (view != null) info = view
            if (view?.ready == true && view.sheets.isNotEmpty()) {
                android.util.Log.i("McPlayer", "trickplay 就绪（第 ${attempt + 1} 次查询，${view.count} 格）")
                return
            }
            kotlinx.coroutines.delay(POLL_INTERVAL_MS)
        }
        android.util.Log.i("McPlayer", "trickplay 轮询 ${MAX_POLLS} 次仍未就绪，本次不显示预览")
    }

    val ready: Boolean get() = info?.ready == true && info!!.sheets.isNotEmpty()

    fun intervalMs(): Int = info?.intervalMs ?: 0

    fun tileCount(): Int = info?.count ?: 0

    /** 取某一时刻的缩略图;未就绪/超出范围返回 null */
    suspend fun tileAt(positionMs: Long): Bitmap? {
        val view = info ?: return null
        if (!view.ready || view.sheets.isEmpty() || view.intervalMs <= 0) return null
        val index = (positionMs / view.intervalMs).toInt().coerceIn(0, view.count - 1)
        val perSheet = (view.columns * view.rows).coerceAtLeast(1)
        val sheetIndex = (index / perSheet).coerceAtMost(view.sheets.lastIndex)
        val tileInSheet = index % perSheet
        val cacheKey = "${sheetIndex}_$tileInSheet"
        tileCache.get(cacheKey)?.let { return it }

        val sheet = loadSheet(view.sheets[sheetIndex]) ?: return null
        if (sheet.width < view.tileWidth || sheet.height < view.tileHeight) return null
        val column = tileInSheet % view.columns
        val row = tileInSheet / view.columns
        val x = (column * view.tileWidth).coerceAtMost(sheet.width - view.tileWidth)
        val y = (row * view.tileHeight).coerceAtMost(sheet.height - view.tileHeight)
        val tile = runCatching {
            Bitmap.createBitmap(sheet, x, y, view.tileWidth, view.tileHeight)
        }.getOrNull() ?: return null
        tileCache.put(cacheKey, tile)
        return tile
    }

    private suspend fun loadSheet(relativePath: String): Bitmap? {
        sheetCache.get(relativePath)?.let { return it }
        val url = absoluteUrl(relativePath)
        val request = ImageRequest.Builder(context)
            .data(url)
            .build()
        val result = runCatching { imageLoaders.loader.execute(request) }.getOrNull() ?: return null
        val bitmap = runCatching { result.image?.toBitmap() }.getOrNull() ?: return null
        sheetCache.put(relativePath, bitmap)
        return bitmap
    }

    /**
     * 服务端给的 sheets 已经是「API 根起算的绝对路径 + 签名 token」:
     *   `/api/v1/playback/files/{id}/trickplay/sprite_0.jpg?token=…`
     * （playback.py 拼的）。再补一次 `/api/v1` 就成了 `/api/v1/api/v1/…` → 404，
     * 表现是拖进度条迟迟看不到预览。这里只在缺前缀/缺 token 时补。
     */
    private fun absoluteUrl(relativePath: String): String {
        val base = when {
            relativePath.startsWith("http") -> relativePath
            relativePath.startsWith("/api/") -> origin + relativePath
            relativePath.startsWith("/") -> origin + "/api/v1" + relativePath
            else -> origin + "/api/v1/" + relativePath
        }
        return if (base.contains("token=")) base else "$base${if (base.contains('?')) '&' else '?'}token=$token"
    }

    private var origin: String = ""

    /** 由控制器在准备阶段告知 origin(不能依赖 SessionRepository:访客态也要能用) */
    fun setOrigin(value: String) {
        origin = value.trimEnd('/')
    }

    companion object {
        /**
         * 服务端是**开会话后延迟 90 秒**才开始生成雪碧图（原话："起播关键窗口不与首片
         * 转码抢 IO"），再加上通读容器的生成时间，所以预览最早也要一分半以后才有。
         * 5 秒一次、最多 60 次（约 5 分钟）；生成好之后服务端有缓存，下次进直接就有。
         */
        private const val POLL_INTERVAL_MS = 5_000L
        private const val MAX_POLLS = 60

        fun extractToken(streamUrl: String): String =
            runCatching {
                android.net.Uri.parse(streamUrl).getQueryParameter("token").orEmpty()
            }.getOrDefault("")
    }
}
