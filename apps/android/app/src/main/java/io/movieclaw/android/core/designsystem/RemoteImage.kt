package io.movieclaw.android.core.designsystem

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import coil3.compose.AsyncImage
import coil3.compose.AsyncImagePainter

/**
 * 服务器图片：地址按 iOS `ServerAddress.imageURL` 的口径解析（远程图走服务端代理 + `w=` 尺寸档），
 * 经带鉴权头的 ImageLoader 加载；空值/失败回落占位。
 */
@Composable
fun RemoteImage(
    url: String?,
    origin: String?,
    modifier: Modifier = Modifier,
    contentScale: ContentScale = ContentScale.Crop,
    contentDescription: String? = null,
    /**
     * 取图的像素宽档（照 iOS `ImageWidth` 的「按显示尺寸要图」）。
     * 不传就按**自身约束实测**（`BoxWithConstraints` 的框 × 屏幕倍率）：
     * 给了 [aspect] 且高度有界时按「铺满」算（竖框铺 16:9 背景要按高算），否则按宽算。
     */
    widthHint: Int? = null,
    /** 图片宽高比（宽 ÷ 高），见 [ImageAspect]；配合实测框算出「铺满」需要的宽 */
    aspect: Float? = null,
    /** 预放大系数（如 Hero 慢推 1.1 倍，取图时就按放大后的尺寸要） */
    zoom: Float = 1f,
    /** 分享图片必须走独立 Cookie 通道，不能附带成员身份。 */
    guest: Boolean = false,
    /**
     * 没有地址或**加载失败**时的回落内容。null = 渐变占位。
     *
     * 失败也要回落是有实际场景的：媒体库封面 `GET /libraries/{id}/cover` 在
     * 「该库还没有海报资产」时返回 404（服务端原文），不接一下就是一块空黑。
     */
    fallback: (@Composable () -> Unit)? = null,
    /** 图片颜色滤镜（如类型卡「压暗区提饱和」叠画层的 ×1.2 饱和度）；null = 原样 */
    colorFilter: androidx.compose.ui.graphics.ColorFilter? = null,
) {
    if (url.isNullOrEmpty() || (origin == null && !url.startsWith("http"))) {
        if (fallback != null) fallback() else PosterPlaceholder(seed = url ?: "movieclaw", modifier = modifier)
        return
    }
    val context = LocalContext.current.applicationContext
    val loader = remember(context, guest) {
        val loaders = (context as io.movieclaw.android.MovieClawApp).imageLoaders
        if (guest) loaders.guestLoader else loaders.loader
    }
    var failed by remember(url, origin, guest) { mutableStateOf(false) }
    if (failed) {
        if (fallback != null) fallback() else PosterPlaceholder(seed = url, modifier = modifier)
        return
    }
    BoxWithConstraints(modifier) {
        val density = LocalDensity.current.density
        val px = widthHint ?: run {
            val w = maxWidth
            val h = maxHeight
            when {
                !w.value.isFinite() || w.value <= 0f -> null
                aspect != null && h.value.isFinite() && h.value > 0f ->
                    ImageWidth.cover(w.value, h.value, density, aspect, zoom)
                // 高度无界（横滑行里、wrapContent）时按宽算，够铺满
                else -> ImageWidth.pixels(w.value, density, zoom)
            }
        }
        val base = origin?.trimEnd('/')
        val resolved = remember(url, base, px) { resolveImageUrl(url, base, px) }
        AsyncImage(
            model = resolved,
            imageLoader = loader,
            contentDescription = contentDescription,
            contentScale = contentScale,
            colorFilter = colorFilter,
            onState = { state ->
                if (state is AsyncImagePainter.State.Error) {
                    failed = true
                    // 「图没了」这类问题只有 URL + 错误能定性（实机反馈：订阅 hero、订阅墙封面）。
                    android.util.Log.w(
                        "McImage",
                        "加载失败 url=$resolved err=" +
                            "${state.result.throwable::class.java.simpleName}: ${state.result.throwable.message}",
                    )
                }
            },
            modifier = Modifier.fillMaxSize(),
        )
    }
}

/**
 * 后端给的图片地址 → 可请求的 URL（照 iOS `ServerAddress.imageURL` / Web `imageUrl()`）：
 * - http(s) 远程图（TMDB、豆瓣、PT 站截图）一律走后端缓存代理 `/api/v1/images/proxy?url=…`，
 *   尺寸由服务端按 `w=` 出变体——**不能**往外部地址上直接追加 `w=`（TMDB 的档位在路径里，
 *   追加查询参数没用，还会绕开代理缓存）；
 * - 相对路径补来源直连（站内根目录样式 `/images/assets/...` 缺 `/api/v1` 前缀要补上），
 *   并补 `w=`——所有服务端出图路由都认它；
 * - Windows 刮削器写入的反斜杠统一换成 `/`。
 */
internal fun resolveImageUrl(raw: String?, base: String?, px: Int?): String? {
    if (raw.isNullOrEmpty()) return null
    val width = px?.let { ImageWidth.snap(it) }
    val absolute = raw.startsWith("http")
    // 自家服务器的绝对地址（服务端有些字段带域名，如库封面 `/{origin}/api/v1/libraries/1/cover`）
    // 剥掉域名按相对路径直连：包一层 `/images/proxy` 既绕远，又会被服务端的域名白名单打回 400
    // （实机日志抓到过：媒体库封面整批 400）。真正的远程图（TMDB 等）才走代理。
    val path = when {
        !absolute -> raw
        base != null && raw.startsWith(base) -> raw.removePrefix(base)
        else -> null
    }
    if (path != null) {
        if (base == null) return raw
        val clean = path.replace('\\', '/')
        val joined = when {
            clean.startsWith("/api/") -> base + clean
            clean.startsWith("/") -> "$base/api/v1$clean"
            else -> "$base/$clean"
        }
        return appendWidth(joined, width)
    }
    // 远程图：走后端缓存代理，尺寸由服务端按 `w=` 出变体
    if (base == null) return raw
    return buildString {
        append(base).append("/api/v1/images/proxy?url=")
        append(java.net.URLEncoder.encode(raw, "UTF-8"))
        if (width != null) append("&w=").append(width)
    }
}

/** 地址补/换 `w=`（同 iOS `URL.imageWidth`：已有的 `w` 换掉，不重复堆参数） */
private fun appendWidth(url: String, px: Int?): String {
    if (px == null) return url
    val path = url.substringBefore('?')
    val query = url.substringAfter('?', "")
    val kept = query.split('&').filter { it.isNotEmpty() && !it.startsWith("w=") }
    return "$path?" + (kept + "w=$px").joinToString("&")
}
