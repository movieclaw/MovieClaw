package io.movieclaw.android.core.network

import android.os.Build
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import io.movieclaw.android.core.session.TokenVault
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Qualifier
import javax.inject.Singleton
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.ConnectionPool
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * 客户端版本信息：从构建产物读（`version.properties` → Gradle versionName/versionCode），
 * 对齐 TV 版（`BuildConfig.VERSION_NAME`）与 iOS（`CFBundleShortVersionString`）。
 *
 * 以前这里是写死的 "0.1.0"/1，发行版走到 0.2.0/30000003 它也不动——页脚、UA、
 * 设备管理里的版本、播放上报全被冻在 0.1.0，认不出用户装的是哪一次构建。
 */
object BuildInfo {
    /** 营销版本（上报用的 clientVersion；iOS 同为 CFBundleShortVersionString，不带构建号） */
    val APP_VERSION: String = io.movieclaw.android.BuildConfig.VERSION_NAME

    /** 构建号（versionCode） */
    val BUILD_NUMBER: Int = io.movieclaw.android.BuildConfig.VERSION_CODE

    /** 显示串「0.2.0（30000003）」——iOS 关于页 versionText 同口径 */
    val DISPLAY_VERSION: String = "$APP_VERSION（$BUILD_NUMBER）"

    val USER_AGENT: String =
        "MovieClaw-Android/$APP_VERSION (${Build.MODEL}; Android ${Build.VERSION.RELEASE}; build $BUILD_NUMBER)"
}

fun newDeviceClientInfo(installationId: String) = io.movieclaw.android.core.model.DeviceClientInfo(
    kind = "android",
    name = Build.MODEL ?: "Android",
    installationId = installationId,
    clientVersion = BuildInfo.APP_VERSION,
    platform = "Android ${Build.VERSION.RELEASE}",
)

/** 通用通道:页面与常规请求 */
@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class GeneralChannel

/** 实时通道:SSE 与高频轮询,独立连接池防队头阻塞 */
@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class LiveChannel

/** 播放通道:会话建立/进度/心跳,保证 stop 不排在图片请求后面 */
@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class PlaybackChannel

private fun userAgentInterceptor() = Interceptor { chain ->
    chain.proceed(
        chain.request().newBuilder()
            .header("User-Agent", BuildInfo.USER_AGENT)
            .build()
    )
}

/** 仅对显式绑定身份且属于同一服务器的请求附带 Bearer；原始探测与分享保持匿名。 */
internal fun authInterceptor(@Suppress("UNUSED_PARAMETER") vault: TokenVault) = Interceptor { chain ->
    val request = chain.request()
    val binding = request.tag(RequestIdentity::class.java)
    val identity = binding?.identity
    // 「同一服务器」= 登录地址 + 已验证的地址簿入口（内网/外网两个主机名都算），见 ServerTrust
    val authorized = identity != null && ServerTrust.matches(request.url, identity.origin) && !isShareUrl(request.url)
    val builder = request.newBuilder()
    if (authorized) builder.header("Authorization", "Bearer ${identity!!.token}")
    else builder.removeHeader("Authorization")
    chain.proceed(builder.build())
}

private fun baseClient(vault: TokenVault, reachability: Boolean = false): OkHttpClient.Builder =
    OkHttpClient.Builder()
        // 页面与播放请求的结果交给离线下载的可达性判断（旁听，不发额外请求）；实时通道（SSE）不计
        .apply { if (reachability) addInterceptor(io.movieclaw.android.core.offline.ReachabilityTap.interceptor) }
        // 连不上要**快**失败：内网地址在蜂窝下根本不可达，15 秒的干等既卡界面又让
        // 「切错地址 / 不在同一网络」这件事 15 秒后才可见（实机：切账号后每轮请求都要等满 15 秒）
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .addInterceptor(userAgentInterceptor())
        .addInterceptor(routeHeaderInterceptor())
        .addInterceptor(failoverInterceptor())
        .addInterceptor(loggingInterceptor())
        .addInterceptor(authInterceptor(vault))

/** 每条服务端请求声明自己走的路线（docs/design/server-addresses.md §5.2）。 */
private fun routeHeaderInterceptor(): Interceptor = Interceptor { chain ->
    val route = ServerRoutes.route
    chain.proceed(chain.request().newBuilder().header("X-MovieClaw-Route", route.header).build())
}

/** 媒体断流由控制器等待选路并重签 token；请求层不能拿旧 token 直接换入口。 */
internal object PlaybackMediaRequest

internal fun playbackMediaClient(http: OkHttpClient): OkHttpClient = http.newBuilder().apply {
    interceptors().add(0, Interceptor { chain ->
        chain.proceed(chain.request().newBuilder().tag(PlaybackMediaRequest::class.java, PlaybackMediaRequest).build())
    })
}.build()

/** 换地址重试用过的标记，避免连环重试 */
private const val FAILOVER_TRY = "X-MovieClaw-Retried"

/**
 * 请求级故障转移（§4.6）：当前入口出硬错误（拒绝连接 / 主机不可达 / TLS）时，
 * 幂等请求（GET / HEAD）换到另一个**已验证**的入口重试一次；软错误（超时、DNS）不换。
 * 无论能不能重试，都顺手触发一次重新选路（地址簿里有防抖）。
 */
private fun failoverInterceptor(): Interceptor = Interceptor { chain ->
    val request = chain.request()
    try {
        chain.proceed(request)
    } catch (e: java.io.IOException) {
        if (request.tag(PlaybackMediaRequest::class.java) != null) throw e
        val hard = isHardNetworkFailure(e)
        if (hard) ServerRoutes.onHardError?.invoke()
        if (!hard || (request.method != "GET" && request.method != "HEAD") ||
            request.header(FAILOVER_TRY) != null
        ) {
            throw e
        }
        val current = ServerRoutes.baseFor(null)?.toHttpUrlOrNull() ?: throw e
        val onCurrentEntry = current.scheme == request.url.scheme &&
            current.host == request.url.host && current.port == request.url.port
        if (!onCurrentEntry) throw e
        val alternate = ServerRoutes.alternates.asSequence()
            .mapNotNull { it.toHttpUrlOrNull() }
            .firstOrNull {
                it.scheme != request.url.scheme || it.host != request.url.host || it.port != request.url.port ||
                    it.encodedPath.trimEnd('/') != current.encodedPath.trimEnd('/')
            } ?: throw e
        val retried = request.newBuilder()
            .url(failoverUrl(request.url, current, alternate))
            .header(FAILOVER_TRY, "1")
            .build()
        android.util.Log.w("McRoutes", "硬错误 ${request.method} ${request.url.host} → ${alternate.host}，重试一次")
        chain.proceed(retried)
    }
}

/**
 * 换入口时把「当前入口路径前缀」换成「备选入口路径前缀」，查询串原样保留。
 *
 * 除了 scheme/host/port，子路径反代（`https://example.com/movieclaw`）也要一起换：
 * 只改 host 会把 `/movieclaw/api/v1/...` 原样带到内网地址，或从内网切回域名时丢掉
 * `/movieclaw` 前缀，两种都会 404。
 */
internal fun failoverUrl(request: okhttp3.HttpUrl, currentOrigin: okhttp3.HttpUrl, alternate: okhttp3.HttpUrl): okhttp3.HttpUrl {
    val currentPrefix = currentOrigin.encodedPath.trimEnd('/')
    val suffix = when {
        currentPrefix.isEmpty() -> request.encodedPath
        request.encodedPath == currentPrefix -> "/"
        request.encodedPath.startsWith("$currentPrefix/") -> request.encodedPath.removePrefix(currentPrefix)
        else -> request.encodedPath
    }
    val alternatePrefix = alternate.encodedPath.trimEnd('/')
    return request.newBuilder()
        .scheme(alternate.scheme)
        .host(alternate.host)
        .port(alternate.port)
        .encodedPath((alternatePrefix + suffix).ifEmpty { "/" })
        .build()
}

/** 硬错误 = 换地址可能有用；超时 / DNS 失败算软错误，只累计不切换 */
internal fun isHardNetworkFailure(error: java.io.IOException): Boolean {
    var cause: Throwable? = error
    while (cause != null) {
        when (cause) {
            is java.net.SocketTimeoutException, is java.net.UnknownHostException -> return false
            is java.net.ConnectException,
            is java.net.NoRouteToHostException,
            is javax.net.ssl.SSLException,
            -> return true
        }
        cause = cause.cause
    }
    return false
}

/** 非 2xx 仅记录状态、方法和路径；查询参数、用户信息和响应体可能含凭据。 */
private fun loggingInterceptor(): Interceptor = Interceptor { chain ->
    val response = chain.proceed(chain.request())
    if (!response.isSuccessful) {
        val request = chain.request()
        val safeUrl = request.url.newBuilder()
            .username("")
            .password("")
            .query(null)
            .fragment(null)
            .build()
        android.util.Log.w("McHttp", "${response.code} ${request.method} $safeUrl")
    }
    response
}

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun json(): Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
        namingStrategy = JsonNamingStrategy.SnakeCase
        // 关键:kotlinx 默认不序列化等于默认值的字段——DeviceClientInfo.kind("android")、
        // capability.isMobile/nativeHls 等会被静默丢弃,服务端 422(缺必填字段)或误判能力
        encodeDefaults = true
    }

    @Provides
    @Singleton
    @GeneralChannel
    fun generalClient(vault: TokenVault): OkHttpClient = baseClient(vault, reachability = true).build()

    @Provides
    @Singleton
    @LiveChannel
    fun liveClient(vault: TokenVault): OkHttpClient = baseClient(vault)
        .connectionPool(ConnectionPool(4, 65, TimeUnit.SECONDS))
        .build()

    @Provides
    @Singleton
    @PlaybackChannel
    fun playbackClient(vault: TokenVault): OkHttpClient = baseClient(vault, reachability = true)
        .connectionPool(ConnectionPool(4, 65, TimeUnit.SECONDS))
        .build()
}
