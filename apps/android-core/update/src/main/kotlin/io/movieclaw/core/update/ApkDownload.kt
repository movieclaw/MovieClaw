package io.movieclaw.core.update

import io.movieclaw.core.model.generated.ClientReleaseView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

/**
 * 下载新版 APK（官网直链，或自己的服务器 `GET /app/clients/{product}/apk`），边下边算 sha256，
 * 对不上就删掉、报错——不把一个来路不明的包交给安装器。下过的同一版直接复用。
 */
object ApkDownload {
    /** 经自己的服务器代下的地址 */
    fun serverUrl(apiBase: HttpUrl, product: String): HttpUrl =
        apiBase.newBuilder().addPathSegments("app/clients/$product/apk").build()

    suspend fun fetch(
        http: OkHttpClient,
        url: HttpUrl,
        bearer: String?,
        release: ClientReleaseView,
        dir: File,
        onProgress: (Float) -> Unit = {},
    ): File = withContext(Dispatchers.IO) {
        dir.mkdirs()
        val target = File(dir, "movieclaw-${release.product}-${release.build}.apk")
        if (target.isFile && target.length() == release.size && sha256(target) == release.sha256.lowercase()) {
            onProgress(1f)
            return@withContext target
        }
        // 旧版本的包用不上了，顺手清掉
        dir.listFiles()?.filter { it.name.startsWith("movieclaw-${release.product}-") && it != target }?.forEach { it.delete() }
        val part = File(dir, target.name + ".part")
        val request = Request.Builder().url(url).apply { bearer?.let { header("Authorization", "Bearer $it") } }.build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException(serverMessage(response.code, response.body.string()))
            val digest = MessageDigest.getInstance("SHA-256")
            val total = release.size.takeIf { it > 0 } ?: response.body.contentLength()
            var done = 0L
            part.outputStream().use { out ->
                response.body.byteStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val read = input.read(buffer)
                        if (read < 0) break
                        out.write(buffer, 0, read)
                        digest.update(buffer, 0, read)
                        done += read
                        if (total > 0) onProgress((done.toFloat() / total).coerceIn(0f, 1f))
                    }
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (actual != release.sha256.lowercase()) {
                part.delete()
                throw IOException("下载的安装包校验失败（sha256 不符），已丢弃，请重试")
            }
        }
        if (!part.renameTo(target)) throw IOException("保存安装包失败")
        target
    }

    internal fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** 服务端的中文报错（如「无法连接 GitHub……」）优先 */
    private fun serverMessage(code: Int, body: String): String =
        Regex("\"message\"\\s*:\\s*\"([^\"]+)\"").find(body)?.groupValues?.get(1) ?: "下载失败（HTTP $code）"
}
