package io.movieclaw.androidtv

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.disk.directory
import coil3.memory.MemoryCache
import coil3.network.okhttp.OkHttpNetworkFetcherFactory

class MovieClawApp : Application(), SingletonImageLoader.Factory {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph(this)
    }

    /** 图片接口要登录：只给当前服务器的请求带令牌（谁在看页的别的服务器头像按各自令牌带） */
    override fun newImageLoader(context: PlatformContext): ImageLoader {
        val client = graph.http.newBuilder().addInterceptor { chain ->
            val request = chain.request()
            val model = graph.model
            val match = model.savedServers.value.firstOrNull { saved ->
                val origin = saved.address.origin
                request.url.host == origin.host && request.url.port == origin.port
            }
            val bearer = when {
                match == null -> null
                match.origin == model.server?.toString() -> model.token
                else -> match.activeAccount?.let { model.tokenFor(match.address, it.username) }
            }
            chain.proceed(if (bearer != null) request.newBuilder().header("Authorization", "Bearer $bearer").build() else request)
        }.build()
        return ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { client })) }
            .memoryCache { MemoryCache.Builder().maxSizePercent(context, 0.25).build() }
            .diskCache { DiskCache.Builder().directory(context.cacheDir.resolve("images")).maxSizeBytes(256L * 1024 * 1024).build() }
            .build()
    }
}

val android.content.Context.graph: AppGraph get() = (applicationContext as MovieClawApp).graph
