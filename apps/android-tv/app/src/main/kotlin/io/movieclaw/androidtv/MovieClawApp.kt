package io.movieclaw.androidtv

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade

class MovieClawApp : Application(), SingletonImageLoader.Factory {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph(this)
    }

    /** 图片接口要登录：只给当前服务器的请求带令牌，别的域名（不该有）一概不带。 */
    override fun newImageLoader(context: PlatformContext): ImageLoader {
        val client = graph.http.newBuilder().addInterceptor { chain ->
            val request = chain.request()
            val session = graph.session.value
            val sameServer = session != null && request.url.host == session.server.origin.host &&
                request.url.port == session.server.origin.port
            chain.proceed(
                if (sameServer) request.newBuilder().header("Authorization", "Bearer ${session.token}").build() else request,
            )
        }.build()
        return ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { client })) }
            .crossfade(true)
            .build()
    }
}

val android.content.Context.graph: AppGraph get() = (applicationContext as MovieClawApp).graph
