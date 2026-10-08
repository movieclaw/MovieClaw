package io.movieclaw.android.core.network

import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.MediaType.Companion.toMediaType
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import io.movieclaw.android.core.api.McApi
import io.movieclaw.android.core.session.TokenVault
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** 按服务器缓存 Retrofit 实例(多服务器各一个 baseUrl) */
@Singleton
class ApiFactory @Inject constructor(
    private val json: Json,
    @GeneralChannel private val client: OkHttpClient,
    @PlaybackChannel private val playbackClient: OkHttpClient,
    private val vault: TokenVault,
    private val shareCookies: ShareCookieJar,
) {
    private data class Binding(val base: String, val identity: io.movieclaw.android.core.session.TokenVault.Identity?)
    private data class Cached(val binding: Binding, val api: McApi)
    private val cache = ConcurrentHashMap<String, Cached>()
    private val playbackCache = ConcurrentHashMap<String, Cached>()
    private val guestCache = ConcurrentHashMap<String, Cached>()
    private val guestPlaybackCache = ConcurrentHashMap<String, Cached>()
    private val apiBaseOverrides = ConcurrentHashMap<String, String>()

    /** 基址变更必须重建 Retrofit，不复用旧代理路由。 */
    fun registerApiBase(origin: String, apiBase: String) {
        val url = apiBase.toHttpUrlOrNull() ?: throw ApiException("INVALID_API_BASE", "无效的 API 地址")
        require(sameOrigin(url, origin)) { "API 基址必须属于同一服务器" }
        apiBaseOverrides[origin] = apiBase.trimEnd('/')
    }

    fun apiBaseOf(origin: String): String? = apiBaseOverrides[origin]

    fun forOrigin(origin: String): McApi = forIdentity(origin, vault.snapshot())
    fun forIdentity(origin: String, identity: TokenVault.Identity?): McApi = build(origin, client, cache, identity)
    fun playbackForOrigin(origin: String): McApi = build(origin, playbackClient, playbackCache, vault.snapshot())
    fun guestForOrigin(origin: String): McApi = build(origin, guestClient, guestCache, null)
    fun guestPlaybackForOrigin(origin: String): McApi = build(origin, guestPlaybackClient, guestPlaybackCache, null)

    /** 分享接口、图片和访客播放共用同一份 Cookie，但不安装成员凭证。 */
    val guestClient: OkHttpClient by lazy { identityClient(client, null).newBuilder().cookieJar(shareCookies).build() }
    private val guestPlaybackClient: OkHttpClient by lazy {
        identityClient(playbackClient, null).newBuilder().cookieJar(shareCookies).build()
    }

    private fun build(origin: String, client: OkHttpClient, cache: ConcurrentHashMap<String, Cached>, identity: TokenVault.Identity?): McApi {
        val normalized = ServerAddress.normalize(origin)
            ?: throw ApiException("INVALID_ORIGIN", "无效的服务器地址:$origin")
        val binding = Binding(apiBaseOverrides[normalized.origin] ?: normalized.apiBase,
            identity?.takeIf { sameOrigin(normalized.origin.toHttpUrlOrNull()!!, it.origin) })
        return cache.compute(normalized.origin) { _, old ->
            if (old?.binding == binding) old else Cached(binding,
                Retrofit.Builder()
                    .baseUrl(binding.base + "/")
                    .client(identityClient(client, binding.identity))
                    .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
                    .build().create(McApi::class.java))
        }!!.api
    }
}
