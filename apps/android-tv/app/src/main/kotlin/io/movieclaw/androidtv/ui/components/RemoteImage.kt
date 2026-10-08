package io.movieclaw.androidtv.ui.components

import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.crossfade
import io.movieclaw.androidtv.core.network.ImageUrls
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt

/** 当前账号的服务器：图片地址按它解析（图片接口要登录，令牌由全局图片加载器按主机带上） */
val LocalServer = compositionLocalOf<ServerAddress> { error("LocalServer 未提供") }

/**
 * 图片要的像素宽：点 × 屏幕比例 × 焦点放大（RemoteImage.swift ImageWidth）。
 * 1 pt = 0.5 dp，所以像素 = pt × 0.5 × density。
 */
@Composable
fun imagePixels(widthPt: Float, zoom: Float = 1f): Int = with(LocalDensity.current) { (widthPt * 0.5f * density * zoom).toInt() }

@Composable
fun imageUrl(raw: String?, widthPt: Float?, zoom: Float = 1f): String? {
    val server = LocalServer.current
    val px = widthPt?.let { imagePixels(it, zoom) }
    return ImageUrls.build(server, raw, px)?.toString()
}

/**
 * 远程图（RemoteImage.swift）：填满裁切，到了淡入 0.2 秒；加载中 / 没图时是 surfaceRaised 底，
 * 失败或没有地址时再叠一行淡字占位。
 */
@Composable
fun RemoteImage(
    raw: String?,
    widthPt: Float?,
    modifier: Modifier = Modifier,
    zoom: Float = 1f,
    contentScale: ContentScale = ContentScale.Crop,
    placeholder: String? = null,
    alignment: Alignment = Alignment.Center,
    showsPlaceholderBox: Boolean = true,
) {
    val url = imageUrl(raw, widthPt, zoom)
    var failed by remember(url) { mutableStateOf(false) }
    Box(modifier.then(if (showsPlaceholderBox) Modifier.background(McColors.SurfaceRaised) else Modifier)) {
        if (url != null) {
            AsyncImage(
                model = ImageRequest.Builder(LocalContext.current).data(url).crossfade(200).build(),
                contentDescription = null,
                contentScale = contentScale,
                alignment = alignment,
                onError = { failed = true },
                modifier = Modifier.fillMaxSize(),
            )
        }
        if ((url == null || failed) && placeholder != null) {
            Text(
                placeholder,
                style = McType.Caption,
                color = McColors.TextFaint,
                textAlign = TextAlign.Center,
                modifier = Modifier.align(Alignment.Center).padding(12.pt),
            )
        }
    }
}

/** 淡入淡出用的统一时长 */
fun <T> fade(ms: Int) = tween<T>(ms)
