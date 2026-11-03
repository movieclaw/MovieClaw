package io.movieclaw.android.core.offline

import kotlinx.serialization.builtins.serializer
import java.io.File
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.buffer
import okio.source

/**
 * 本机副本里的图片（docs/design/offline-download.md §3.2、§4；iOS `OfflineImages`）：海报、剧照、Logo、分集剧照、演职员头像。
 *
 * 同一张图在各处按不同宽度取（`w`），本机每张只存一份，所以按「图片键」认：地址去掉服务器前缀、宽度与变体参数，
 * TMDB 地址再去掉尺寸段——换了服务器地址（局域网 IP ↔ 域名）、换了显示宽度都还是同一张。
 *
 * 图片加载器在两种情况下用本机的（[interceptor]）：离线模式（不发请求）；在线时请求失败。
 */
object OfflineImages {
    private val lock = Any()
    /** 图片键 → 本机文件 */
    private var files: Map<String, File> = emptyMap()
    /** 条目 → 它的图片键（删条目时一起摘掉） */
    private var byItem: Map<Long, Set<String>> = emptyMap()

    /** 离线模式（图片加载线程上要知道）：可达性改模式时同步一份 */
    @Volatile var offline = false

    private val tmdbSize = Regex("/t/p/[^/]+/")

    /** 图片键：`/images/assets/12/poster.jpg?v=3`、`/images/proxy?url=https://image.tmdb.org/t/p/<尺寸>/abc.jpg`（尺寸段换成星号） */
    fun key(url: HttpUrl): String {
        var path = url.encodedPath
        val api = path.indexOf("/api/v1/")
        if (api >= 0) path = "/" + path.substring(api + "/api/v1/".length)
        val dropped = setOf("w", "variant", "mc_account")
        val items = (0 until url.querySize)
            .map { url.queryParameterName(it) to url.queryParameterValue(it) }
            .filter { it.first !in dropped }
            .map { (name, value) -> if (name == "url" && value != null) name to value.replace(tmdbSize, "/t/p/*/") else name to value }
            .sortedBy { it.first }
        if (items.isEmpty()) return path
        return path + "?" + items.joinToString("&") { (k, v) -> if (v == null) k else "$k=$v" }
    }

    fun key(raw: String): String? = raw.toHttpUrlOrNull()?.let(::key)

    /** 读一个账号全部条目的图片索引（换账号、启动时在后台） */
    fun load(ownerKey: String, itemIds: Collection<Long>) {
        val loaded = mutableMapOf<String, File>()
        val items = mutableMapOf<Long, Set<String>>()
        for (itemId in itemIds) {
            val dir = OfflineDisk.imagesDir(ownerKey, itemId)
            val index = readIndex(dir) ?: continue
            for ((key, name) in index) loaded[key] = File(dir, name)
            items[itemId] = index.keys
        }
        synchronized(lock) {
            files = loaded
            byItem = items
        }
    }

    fun reset() = synchronized(lock) {
        files = emptyMap()
        byItem = emptyMap()
    }

    /** 打包时存下一张图后登记 */
    fun register(key: String, file: File, itemId: Long) = synchronized(lock) {
        files = files + (key to file)
        byItem = byItem + (itemId to (byItem[itemId].orEmpty() + key))
    }

    fun forget(itemId: Long) = synchronized(lock) {
        val keys = byItem[itemId].orEmpty()
        files = files - keys
        byItem = byItem - itemId
    }

    fun has(key: String): Boolean = synchronized(lock) { files.containsKey(key) }

    fun localFile(url: HttpUrl): File? = synchronized(lock) { files[key(url)] }?.takeIf { it.isFile }

    private val indexSerializer = kotlinx.serialization.builtins.MapSerializer(
        String.serializer(), String.serializer(),
    )

    fun readIndex(dir: File): Map<String, String>? = OfflineDisk.read(indexSerializer, File(dir, "index.json"))

    fun writeIndex(dir: File, index: Map<String, String>) = OfflineDisk.write(indexSerializer, index, File(dir, "index.json"))

    /** 图片请求的拦截器：离线模式直接回本机文件；在线时请求失败（连不上、非 2xx）才回落本机 */
    val interceptor = Interceptor { chain ->
        val request = chain.request()
        val local = localFile(request.url)
        if (local != null && offline) return@Interceptor localResponse(chain, local)
        try {
            val response = chain.proceed(request)
            if (!response.isSuccessful && local != null) {
                response.close()
                localResponse(chain, local)
            } else {
                response
            }
        } catch (e: java.io.IOException) {
            if (local != null) localResponse(chain, local) else throw e
        }
    }

    private fun localResponse(chain: Interceptor.Chain, file: File): Response {
        val mime = when (file.extension.lowercase()) {
            "png" -> "image/png"
            "webp" -> "image/webp"
            else -> "image/jpeg"
        }
        return Response.Builder()
            .request(chain.request())
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(file.source().buffer().asResponseBody(mime.toMediaTypeOrNull(), file.length()))
            .build()
    }
}
