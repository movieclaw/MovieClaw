package io.movieclaw.core.update

import io.movieclaw.core.model.generated.ClientReleaseView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * 直接问官方发布处（官网的下载地址就是跳到 GitHub Release）：这个客户端的最新正式版。
 * 手机、电视在 GitHub 不通的网络里会失败，由 [AppUpdater] 改问自己的服务器兜底。
 *
 * 只用两三个匿名请求（未认证配额 60 次/小时/IP，一天查一次绰绰有余）：
 * 列出 `android-v*` / `androidtv-v*` 的 tag → 从版本最高的取 Release（草稿匿名 404，跳过）→ 读包信息 JSON。
 */
class OfficialReleases(
    private val product: String,
    private val http: OkHttpClient = defaultClient,
    private val apiBase: String = "https://api.github.com/repos/movieclaw/movieclaw",
) {
    /** 最新正式版与它的 APK 直链 */
    data class Found(val release: ClientReleaseView, val apkUrl: String)

    private val prefix = PRODUCTS[product]?.first ?: throw IllegalArgumentException("未知客户端：$product")
    private val infoAsset = PRODUCTS.getValue(product).second

    suspend fun latest(): Found = withContext(Dispatchers.IO) {
        val refs = get("$apiBase/git/matching-refs/tags/$prefix")?.jsonArray ?: throw IOException("官网没有这个客户端的发布")
        val tags = refs.mapNotNull { it.jsonObject["ref"]?.jsonPrimitive?.contentOrNull?.removePrefix("refs/tags/") }
            .filter { STABLE.matches(it.removePrefix(prefix)) && it.startsWith(prefix) }
            .sortedWith(compareByDescending<String> { versionKey(it.removePrefix(prefix)) }.thenByDescending { it })
        for (tag in tags.take(5)) {
            val release = get("$apiBase/releases/tags/$tag")?.jsonObject ?: continue
            if (release.bool("draft") || release.bool("prerelease")) continue
            val assets = release["assets"] as? JsonArray ?: continue
            fun asset(name: String) = assets.map { it.jsonObject }.firstOrNull { it.str("name") == name }?.str("browser_download_url")
            val infoUrl = asset(infoAsset) ?: continue
            val info = get(infoUrl)?.jsonObject ?: continue
            val apkUrl = info.str("asset")?.let(::asset) ?: continue
            val view = ClientReleaseView(
                product = product,
                version = info.str("version") ?: continue,
                build = info.str("build")?.toLongOrNull() ?: info["build"]?.jsonPrimitive?.longOrNull ?: continue,
                size = info["size"]?.jsonPrimitive?.longOrNull ?: 0,
                sha256 = info.str("sha256")?.lowercase() ?: continue,
                certificateSha256 = info.str("certificateSha256"),
                minimumSdk = info["minimumSdk"]?.jsonPrimitive?.longOrNull,
                changelog = release.str("body").orEmpty(),
                publishedAt = release.str("published_at"),
                releaseUrl = release.str("html_url").orEmpty(),
            )
            return@withContext Found(view, apkUrl)
        }
        throw IOException("官网没有这个客户端的正式发布")
    }

    /** 200 → JSON；404 → null（草稿、没有这个 tag）；其余抛错 */
    private fun get(url: String) = http.newCall(
        Request.Builder().url(url).header("Accept", "application/vnd.github+json").header("User-Agent", "movieclaw-app").build(),
    ).execute().use { response ->
        when {
            response.code == 404 -> null
            !response.isSuccessful -> throw IOException("官网返回 HTTP ${response.code}")
            else -> Json.parseToJsonElement(response.body.string())
        }
    }

    private fun JsonObject.str(key: String) = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull
    private fun JsonObject.bool(key: String) = str(key) == "true"

    companion object {
        /** product → (tag 前缀, Release 里的包信息 JSON) */
        val PRODUCTS = mapOf(
            "android" to ("android-v" to "MovieClaw-Android-arm64.json"),
            "androidtv" to ("androidtv-v" to "MovieClaw-AndroidTV.json"),
        )
        private val STABLE = Regex("""\d+(\.\d+)*""")

        private fun versionKey(version: String): String = version.split('.').joinToString(".") { it.padStart(6, '0') }

        /** 不带账号凭证的独立客户端：走系统代理（手机上开了代理就用），超时比接口短——不通就尽快改走服务器 */
        val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(8, TimeUnit.SECONDS)
                .readTimeout(20, TimeUnit.SECONDS)
                .build()
        }
    }
}
