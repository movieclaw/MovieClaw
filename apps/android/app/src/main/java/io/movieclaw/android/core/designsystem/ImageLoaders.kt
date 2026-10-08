package io.movieclaw.android.core.designsystem

import android.content.Context
import coil3.ImageLoader
import coil3.disk.DiskCache
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.network.GeneralChannel
import io.movieclaw.android.core.network.identityClient
import io.movieclaw.android.core.network.ShareCookieJar
import io.movieclaw.android.core.session.TokenVault
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton
import okhttp3.OkHttpClient
import okio.Path.Companion.toPath

/**
 * Coil 图片加载器:复用通用通道的鉴权拦截器(会员区图片需 Bearer),
 * 磁盘缓存 300MB(对齐 iOS Nuke 缓存配额)。
 */
@Singleton
class ImageLoaders @Inject constructor(
    @ApplicationContext context: Context,
    private val vault: TokenVault,
    @GeneralChannel private val baseClient: OkHttpClient,
    shareCookies: ShareCookieJar,
) {
    /** 图片用的带鉴权客户端；ambient 取色也走它（服务端图片需要带 token） */
    val http: OkHttpClient get() = identityClient(baseClient, vault.snapshot())

    val loader: ImageLoader = ImageLoader.Builder(context)
        .components {
            add(OkHttpNetworkFetcherFactory(callFactory = { http }))
        }
        .diskCache {
            DiskCache.Builder()
                .directory(File(context.cacheDir, "image_cache").absolutePath.toPath())
                .maxSizeBytes(300L * 1024 * 1024)
                .build()
        }
        .build()

    /** 访客图片只用分享 Cookie，不读成员 token，也不复用成员图片磁盘缓存。 */
    val guestLoader: ImageLoader = ImageLoader.Builder(context)
        .components {
            add(OkHttpNetworkFetcherFactory(callFactory = {
                identityClient(baseClient, null).newBuilder().cookieJar(shareCookies).build()
            }))
        }.build()

    /** 退出登录 / 移除账号时清空（内存 + 磁盘）：iOS 那边快照按账号存、退出即删，我的缓存不分账号，整份清才不串号 */
    suspend fun clear() {
        runCatching { loader.memoryCache?.clear() }
        runCatching { guestLoader.memoryCache?.clear() }
        runCatching { loader.diskCache?.clear() }
    }
}
