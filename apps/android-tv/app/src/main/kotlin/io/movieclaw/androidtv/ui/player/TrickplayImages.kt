package io.movieclaw.androidtv.ui.player

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import io.movieclaw.androidtv.core.model.generated.TrickplayView
import io.movieclaw.androidtv.core.playback.TrickplayMath
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * 进度条缩略图（Apple 端 PlayerSurface.swift TrickplayImages）：按需下载雪碧图并裁出目标格子。
 * 下好的整张图留在内存里；失败不退避，下次要到这一格时再下。雪碧图地址自带取流令牌，不用再带登录令牌。
 */
@Stable
class TrickplayImages(private val http: OkHttpClient, private val scope: CoroutineScope, private val resolve: (String) -> String?) {
    private val sheets = mutableStateMapOf<String, Bitmap>()
    private val loading = mutableSetOf<String>()
    private val tiles = HashMap<String, ImageBitmap>()

    /** 文件时间（毫秒）→ 该显示的格子；雪碧图还没下完返回 null（并开始下载） */
    fun tile(index: TrickplayView?, ms: Long): ImageBitmap? {
        val tile = TrickplayMath.tile(index, ms) ?: return null
        val sheet = sheets[tile.sheet]
        if (sheet == null) {
            load(tile.sheet)
            return null
        }
        val key = "${tile.sheet}#${tile.x},${tile.y}"
        tiles[key]?.let { return it }
        // 格子越过整张图的边（最后一张图不满）就不给
        val w = tile.width.coerceAtMost(sheet.width - tile.x)
        val h = tile.height.coerceAtMost(sheet.height - tile.y)
        if (w <= 0 || h <= 0) return null
        return Bitmap.createBitmap(sheet, tile.x, tile.y, w, h).asImageBitmap().also { tiles[key] = it }
    }

    private fun load(path: String) {
        val url = resolve(path) ?: return
        if (!loading.add(path)) return
        scope.launch {
            val bitmap = withContext(Dispatchers.IO) {
                runCatching {
                    http.newCall(Request.Builder().url(url).build()).execute().use { response ->
                        if (!response.isSuccessful) null else BitmapFactory.decodeStream(response.body.byteStream())
                    }
                }.getOrNull()
            }
            loading.remove(path)
            if (bitmap != null) sheets[path] = bitmap
        }
    }
}
