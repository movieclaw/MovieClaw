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
fun rememberAmbientColor(url: String?, origin: String?, bottomBand: Boolean = false): Color? {
    val context = LocalContext.current
    val client = (context.applicationContext as MovieClawApp).imageLoaders.http
    val resolved = if (url.isNullOrEmpty()) null else if (url.startsWith("http")) url else origin?.let { it.trimEnd('/') + url }
    // 取色只需要 ~50px：TMDB 图按尺寸变体取一张最小的（原来下 w1280 原图，
    // 那一次下载就是肉眼可见的等待来源）
    val sampleUrl = resolved?.let { u ->
        if (u.contains("image.tmdb.org/t/p/")) {
            u.replace(Regex("/t/p/(w|original)[0-9]*/"), "/t/p/w92/")
        } else u
    }
    val state = produceState<Color?>(initialValue = null, sampleUrl, bottomBand) {
        // 键用采样地址：同一张图不同尺寸变体共享缓存
        val cacheKey = sampleUrl + "#" + bottomBand
        cache[cacheKey]?.let { value = it; return@produceState }
        if (sampleUrl == null) {
            value = AmbientColor.FALLBACK.toColor()
            return@produceState
        }
        value = try {
            val bitmap = withContext(Dispatchers.IO) {
                client.newCall(Request.Builder().url(sampleUrl ?: resolved).build()).execute().use { response ->
                    val body = response.body
                    if (!response.isSuccessful || body == null) return@use null
                    val options = BitmapFactory.Options().apply { inSampleSize = 8 }
                    BitmapFactory.decodeStream(body.byteStream(), null, options)
                }
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
            android.util.Log.w("MovieClaw", "ambient: failed for $resolved -> ${e.message}")
            AmbientColor.FALLBACK.toColor()
        }
    }
    return state.value
}
