package io.movieclaw.android.core.discovery

import android.graphics.BitmapFactory
import androidx.compose.runtime.Composable
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import io.movieclaw.android.MovieClawApp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request

/**
 * 取某张图的主色（氛围底色）——用 AmbientColor 的实测算法。
 *
 * 与图片本身的加载分开走：这里只为了算颜色，48px 下采样拉一张，算完即弃。
 * **不走 Coil**：Coil 3 默认解码成 Config#HARDWARE 位图，`getPixels()` 直接抛
 * 「pixel access is not supported on Config#HARDWARE bitmaps」，取色会静默失败、
 * 氛围底退化成纯黑（实机踩过：英雄区下方一道断差）。BitmapFactory 出的都是软件位图。
 * 取不到（网络失败 / 灰调剧照）回落 AmbientColor.FALLBACK —— 网页也是回落冷银灰。
 */
/**
 * 取色结果的内存缓存：key = URL + 是否底边色带。
 * 首页英雄与详情页常常是**同一张剧照**，缓存命中后进详情页不再有「黑 → 底色」的等待。
 */
private val cache = java.util.concurrent.ConcurrentHashMap<String, Color>()

@Composable
fun rememberAmbientColor(
    url: String?,
    origin: String?,
    bottomBand: Boolean = false,
    /**
     * 取样失败（404 / 解码不出来）时再试的地址。
     * 库里很多条目**没有 fanart**：`/libraries/{id}/items/{id}/artwork?kind=fanart` 服务端直接 404，
     * 那一条链上每次都落兜底灰 →「每个条目的底色都一样」（2026-10-13 用户反馈）。
     * 传海报地址进来，fanart 缺了就按海报取色。
     */
    fallbackUrl: String? = null,
): Color? {
    val context = LocalContext.current
    val client = (context.applicationContext as MovieClawApp).imageLoaders.http
    // 取色只需要 ~50px：TMDB 图按尺寸变体取一张最小的（原来下 w1280 原图，
    // 那一次下载就是肉眼可见的等待来源）
    fun sample(u: String?): String? = u?.let { raw ->
        if (raw.startsWith("http")) raw else origin?.let { o ->
            // 服务端相对路径要**补 `/api/v1` 前缀**再按站内出图路由取（与 RemoteImage
            // resolveImageUrl 同一口径）：`/libraries/5/items/1420/artwork?...` 直接拼
            // origin 是 404 —— 「每个条目底色都一样」的真正根因
            val base = o.trimEnd('/')
            val clean = raw.replace("\\", "/")
            when {
                clean.startsWith("/api/") -> base + clean
                clean.startsWith("/") -> "$base/api/v1$clean"
                else -> "$base/$clean"
            }
        }
    }?.let { r ->
        val small = if (r.contains("image.tmdb.org/t/p/")) r.replace(Regex("/t/p/(w|original)[0-9]*/"), "/t/p/w92/") else r
        // 站内出图路由都认 w=：取色只要 ~200px（配 inSampleSize=8 → ~25px）
        if (small.contains("/api/v1/")) small.substringBefore('?') + "?" + (small.substringAfter('?', "").split('&')
            .filter { it.isNotEmpty() && !it.startsWith("w=") } + "w=200").joinToString("&") else small
    }
    val candidates = listOfNotNull(sample(url), sample(fallbackUrl)).distinct()
    val state = produceState<Color?>(initialValue = null, candidates, bottomBand) {
        // 键用采样地址：同一张图不同尺寸变体共享缓存
        val cacheKey = candidates.joinToString("|") + "#" + bottomBand
        cache[cacheKey]?.let { value = it; return@produceState }
        if (candidates.isEmpty()) {
            value = AmbientColor.FALLBACK.toColor()
            return@produceState
        }
        value = try {
            val bitmap = withContext(Dispatchers.IO) {
                for (candidate in candidates) {
                    val bmp = client.newCall(Request.Builder().url(candidate).build()).execute().use { response ->
                        val body = response.body
                        if (!response.isSuccessful || body == null) {
                            android.util.Log.w("MovieClaw", "ambient: $candidate -> HTTP ${response.code}")
                            return@use null
                        }
                        val options = BitmapFactory.Options().apply { inSampleSize = 8 }
                        BitmapFactory.decodeStream(body.byteStream(), null, options)
                    }
                    if (bmp != null) return@withContext bmp
                }
                null
            }
            // iOS ImmersiveHero 用的是「整图主色 + 亮度钉 0.44」（底部色带那套只用于详情页底色；
            // 图底边本身已压暗，取底部会得到近黑，实机验证过）
            val c = bitmap?.let {
                // 详情页用「底边色带」（iOS HeroEdgeColor：饱和 ×1.1、亮度 ≤0.34）；
                // 英雄氛围底用整图主色（亮度 0.44）
                // bottomBand 保留参数（详情页底色想更暗时可开），但默认与英雄同源，
                // 这样「首页英雄 → 详情页」同图同键，缓存直接命中、不再等第二次下载
                (if (bottomBand) AmbientColor.fromBottomBand(it) else AmbientColor.fromBitmap(it)).toColor()
            } ?: AmbientColor.FALLBACK.toColor()
            cache[cacheKey] = c
            c
        } catch (e: Throwable) {
            android.util.Log.w("MovieClaw", "ambient: failed for ${candidates.firstOrNull()} -> ${e.message}")
            AmbientColor.FALLBACK.toColor()
        }
    }
    return state.value
}
