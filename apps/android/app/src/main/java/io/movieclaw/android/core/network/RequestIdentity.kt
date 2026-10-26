package io.movieclaw.android.core.network

import io.movieclaw.android.core.session.TokenVault
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import javax.inject.Inject
import javax.inject.Singleton

/** origin 必须按协议、主机和有效端口逐项比较，字符串前缀不能作为凭证边界。 */
internal fun sameOrigin(url: HttpUrl, origin: String): Boolean {
    val expected = origin.toHttpUrlOrNull() ?: return false
    return url.scheme == expected.scheme && url.host == expected.host && url.port == expected.port
}

/**
 * 「同一服务器」的可信地址集合（评审 PR #1001 的问题 1）。
 *
 * 登录只发生在一个 origin（地址簿里的入口是同一台服务器的另一个地址），但内网/外网
 * 两个主机名不同，`sameOrigin` 认不出是同一台机器：切换到外网域名后 Bearer 会被去掉，成员接口全 401。
 * 这里登记「登录 origin → 已通过 `/health` 身份校验（instance_id + Ed25519 proof）的入口」，
 * 鉴权拦截器与图片加载器按这个集合放行——**只放行验证过的入口**，不为未验证的地址簿条目放行。
 */
object ServerTrust {
    @Volatile private var owner: String? = null
    @Volatile private var trusted: Set<String> = emptySet()

    private fun normalize(origin: String): String = origin.trim().trimEnd('/')

    /** 选路验证成功后登记：owner = 登录 origin，origins = 已验证的入口（含登录地址本身） */
    fun allow(loginOrigin: String, origins: Collection<String>) {
        owner = normalize(loginOrigin)
        trusted = origins.map(::normalize).toSet()
    }

    fun clear() {
        owner = null
        trusted = emptySet()
    }

    /** 这个 URL 是否属于登录的那台服务器（登录地址本身，或已验证的入口） */
    fun matches(url: HttpUrl, loginOrigin: String): Boolean {
        if (sameOrigin(url, loginOrigin)) return true
        // 信任集只对本账号这次登录的 origin 生效（退出/切账号会 clear）
        val currentOwner = owner ?: return false
        if (normalize(loginOrigin) != currentOwner) return false
        return trusted.any { sameOrigin(url, it) }
    }
}

/** null 表示明确匿名；成员 API、图片与实时请求在发起时固定身份。 */
internal data class RequestIdentity(val identity: TokenVault.Identity?)

/** 把身份绑定在创建 API 时，排队/重试期间不再读取另一个账号的凭证。 */
internal fun identityClient(client: OkHttpClient, identity: TokenVault.Identity?): OkHttpClient =
    client.newBuilder().apply {
        interceptors().add(0, Interceptor { chain ->
            chain.proceed(chain.request().newBuilder().tag(RequestIdentity::class.java, RequestIdentity(identity)).build())
        })
    }.build()

/** 分享凭据只接受同主机、分享路径的 HttpOnly Cookie；内存保存，不与成员认证混用。 */
@Singleton
class ShareCookieJar @Inject constructor() : CookieJar {
    private data class Stored(val origin: String, val cookie: Cookie)
    private val cookies = mutableListOf<Stored>()

    @Synchronized override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        if (!isShareUrl(url)) return
        val origin = url.newBuilder().encodedPath("/").query(null).fragment(null).build().toString()
        cookies.filter { it.hostOnly && it.domain == url.host && it.httpOnly && it.path.contains("/share/") }
            .forEach { cookie ->
                this.cookies.removeAll { it.origin == origin && it.cookie.name == cookie.name && it.cookie.path == cookie.path }
                if (cookie.expiresAt > System.currentTimeMillis()) this.cookies += Stored(origin, cookie)
            }
    }

    @Synchronized override fun loadForRequest(url: HttpUrl): List<Cookie> {
        cookies.removeAll { it.cookie.expiresAt <= System.currentTimeMillis() }
        return if (isShareUrl(url)) cookies.filter { sameOrigin(url, it.origin) && it.cookie.matches(url) }.map { it.cookie } else emptyList()
    }
}

internal fun isShareUrl(url: HttpUrl): Boolean = url.encodedPath.contains("/api/v1/share/")
