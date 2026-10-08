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
