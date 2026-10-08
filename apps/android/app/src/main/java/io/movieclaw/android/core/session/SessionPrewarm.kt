package io.movieclaw.android.core.session

import io.movieclaw.android.core.AppScopes

import android.content.Context
import coil3.request.ImageRequest
import coil3.request.crossfade
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 落地页稳定后的一次性预热（iOS `MainTabView` 的 idle 预热 + `LibraryHomeStore.prefetch` 的对应物）。
 *
 * 做两件事，都往后让 2 秒、不和首屏抢：
 *  1. **静默预取**：把最常用的两份数据（「接下来继续」「我的收藏」）先拉一遍——服务端缓存与
 *     连接池跟着热起来，真正切过去时是命中而不是首次建连；顺带把它们的条目灌进字节/图片缓存；
 *  2. **首屏图片预热**：把这两行第一屏的封面按页面的同一套 `w=` 口径取一遍，落进 Coil 的
 *     磁盘缓存——进页面时「当场出图」而不是先占位再拉。
 *
 * 与 iOS 的差别（如实记）：iOS 的「页面预热」是把页签在背后不可见地预画一遍（消化第一次
 * 上屏的一次性开销），Compose 里没有等价物（没有可复用的离屏组合），所以这里只做数据与图片
 * 两层预热，页面本身的首帧开销仍在。
 */
@Singleton
class SessionPrewarm @Inject constructor(
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    private val imageLoaders: ImageLoaders,
) {
    private val scope = AppScopes.io("SessionPrewarm")

    @Volatile private var started = false

    /** 外壳起来后调用（重复调用无害，只跑一次） */
    fun warmOnce() {
        if (started) return
        started = true
        scope.launch {
            delay(2_000)
            val origin = repository.ui.value.origin ?: return@launch
            val api = runCatching { apiFactory.forOrigin(origin) }.getOrNull() ?: return@launch

            // ① 静默预取（失败无所谓：真正进页面时还会再拉一遍）
            val upNext = runCatching { api.upNext(limit = 24).dataOrThrow().items }.getOrDefault(emptyList())
            val favorites = runCatching {
                api.favorites(limit = 20, offset = 0, unwatchedFirst = true).dataOrThrow()
            }.getOrNull()

            // ② 首屏图片：拼服务端来源与页面同一套 `w=` 口径（200dp 卡 × 3 倍 ≈ 600 → 阶梯 720）
            val urls = buildList {
                upNext.take(6).forEach { add(it.episodeStillUrl ?: it.backdropUrl ?: it.posterUrl) }
                favorites?.items.orEmpty().take(6).forEach { add(it.posterUrl ?: it.backdropUrl) }
            }.filterNotNull().distinct()
            val base = origin.trimEnd('/')
            urls.forEach { raw ->
                runCatching {
                    val absolute = if (raw.startsWith("http")) raw else if (raw.startsWith("/api/")) base + raw else "$base/api/v1$raw"
                    val sized = if (absolute.startsWith(base)) {
                        absolute + (if (absolute.contains('?')) "&" else "?") + "w=720"
                    } else {
                        absolute
                    }
                    imageLoaders.loader.enqueue(
                        ImageRequest.Builder(context)
                            .data(sized)
                            .crossfade(false)
                            .build(),
                    )
                }
            }
            android.util.Log.i(
                "McPerf",
                "预热完成：接下来继续=${upNext.size} 收藏=${favorites?.items?.size ?: 0} 首屏图=${urls.size}",
            )
        }
    }
}
