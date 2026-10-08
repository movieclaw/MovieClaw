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

object BuildInfo {
    const val APP_VERSION = "0.1.0"
    const val BUILD_NUMBER = 1
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

/** 仅对显式绑定身份且同 origin 的请求附带 Bearer；原始探测与分享保持匿名。 */
internal fun authInterceptor(@Suppress("UNUSED_PARAMETER") vault: TokenVault) = Interceptor { chain ->
    val request = chain.request()
    val binding = request.tag(RequestIdentity::class.java)
    val identity = binding?.identity
    val authorized = identity != null && sameOrigin(request.url, identity.origin) && !isShareUrl(request.url)
    val builder = request.newBuilder()
    if (authorized) builder.header("Authorization", "Bearer ${identity!!.token}")
    else builder.removeHeader("Authorization")
    chain.proceed(builder.build())
}

private fun baseClient(vault: TokenVault): OkHttpClient.Builder =
    OkHttpClient.Builder()
        // 连不上要**快**失败：内网地址在蜂窝下根本不可达，15 秒的干等既卡界面又让
        // 「切错地址 / 不在同一网络」这件事 15 秒后才可见（实机：切账号后每轮请求都要等满 15 秒）
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .addInterceptor(userAgentInterceptor())
        .addInterceptor(loggingInterceptor())
        .addInterceptor(authInterceptor(vault))

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
    fun generalClient(vault: TokenVault): OkHttpClient = baseClient(vault).build()

    @Provides
    @Singleton
    @LiveChannel
    fun liveClient(vault: TokenVault): OkHttpClient = baseClient(vault)
        .connectionPool(ConnectionPool(4, 65, TimeUnit.SECONDS))
        .build()

    @Provides
    @Singleton
    @PlaybackChannel
    fun playbackClient(vault: TokenVault): OkHttpClient = baseClient(vault)
        .connectionPool(ConnectionPool(4, 65, TimeUnit.SECONDS))
        .build()
}
