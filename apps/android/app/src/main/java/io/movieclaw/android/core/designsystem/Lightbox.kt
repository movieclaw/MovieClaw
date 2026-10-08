package io.movieclaw.android.core.designsystem

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import io.movieclaw.android.core.model.MediaImage

private val LightboxBackdrop = Color(0xFF040509).copy(alpha = 0.97f)

/**
 * 图片灯箱(iOS LibraryZoomableImage.Lightbox):
 *   捏合 1×–5×、双击 2.5× ↔ 1×、放大后才可平移;单击切显隐 chrome(0.25s);
 *   顶栏计数胶囊 + 标题 + 关闭(44×44),底部缩略图条(当前项高亮描边);
 *   渐进加载:先铺预览图(未出全图前轻微模糊),全图就绪后淡入。
 */
@Composable
fun Lightbox(
    images: List<MediaImage>,
    title: String,
    initialIndex: Int = 0,
    /** 服务端相对图的来源：图廊的图很多是相对路径，不给 origin 缩略图条与主图都画不出来 */
    origin: String? = null,
    /** 收藏态与切换（图廊模式顶栏那颗心，与详情页同一颗）；null = 不显示心 */
    favorite: Boolean? = null,
    onToggleFavorite: (() -> Unit)? = null,
    /** 有值就显示「详情」按钮（跳这一组的条目详情）；null = 不显示 */
    onOpenDetail: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    if (images.isEmpty()) return
    val pagerState = rememberPagerState(initialPage = initialIndex.coerceIn(0, images.lastIndex)) {
        images.size
    }
    var chromeVisible by remember { mutableStateOf(true) }
    val thumbState = rememberLazyListState()

    LaunchedEffect(pagerState.currentPage) {
        thumbState.animateScrollToItem(pagerState.currentPage)
    }

    Box(Modifier.fillMaxSize().background(LightboxBackdrop)) {
        HorizontalPager(
            state = pagerState,
            userScrollEnabled = true,
            modifier = Modifier.fillMaxSize(),
        ) { page ->
            ZoomableImage(
                image = images[page],
                origin = origin,
                onSingleTap = { chromeVisible = !chromeVisible },
            )
        }

        if (chromeVisible) {
            Column(Modifier.fillMaxSize()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        .background(
                            Brush.verticalGradient(
                                listOf(Color.Black.copy(alpha = 0.85f), Color.Black.copy(alpha = 0.4f), Color.Transparent)
                            )
                        )
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                ) {
                    Text(
                        "${pagerState.currentPage + 1} / ${images.size}",
                        style = McType.subheadline,
                        color = Color.White,
                        modifier = Modifier
                            .background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(999.dp))
                            .padding(horizontal = 10.dp, vertical = 3.dp),
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        title,
                        style = McType.subheadline,
                        color = Color.White.copy(alpha = 0.7f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = onDismiss, modifier = Modifier.size(44.dp)) {
                        Icon(Icons.Rounded.Close, contentDescription = "关闭", tint = Color.White)
                    }
                    if (onOpenDetail != null) {
                        IconButton(onClick = onOpenDetail, modifier = Modifier.size(44.dp)) {
                            Icon(Icons.Rounded.Info, contentDescription = "详情", tint = Color.White)
                        }
                    }
                    if (favorite != null && onToggleFavorite != null) {
                        IconButton(onClick = onToggleFavorite, modifier = Modifier.size(44.dp)) {
                            Icon(
                                if (favorite) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                                contentDescription = if (favorite) "取消收藏" else "收藏",
                                tint = if (favorite) Accent else Color.White,
                            )
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                if (images.size > 1) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .background(
                                Brush.verticalGradient(
                                    listOf(Color.Transparent, Color.Black.copy(alpha = 0.5f), Color.Black.copy(alpha = 0.9f))
                                )
                            )
                            .padding(vertical = 6.dp),
                    ) {
                        LazyRow(
                            state = thumbState,
                            contentPadding = PaddingValues(horizontal = 12.dp),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            items(images.size) { index ->
                                val isCurrent = index == pagerState.currentPage
                                Box(
                                    Modifier
                                        .height(48.dp)
                                        .width((48 * images[index].aspect.coerceIn(0.5f, 2f)).dp)
                                        .clip(RoundedCornerShape(6.dp))
                                        .graphicsLayer { alpha = if (isCurrent) 1f else 0.45f }
                                        .then(
                                            if (isCurrent) {
                                                Modifier.border(2.dp, Accent, RoundedCornerShape(6.dp))
                                            } else {
                                                Modifier
                                            }
                                        ),
                                ) {
                                    RemoteImage(
                                        url = images[index].previewUrl,
                                        origin = origin,
                                        contentDescription = null,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize(),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ZoomableImage(image: MediaImage, origin: String?, onSingleTap: () -> Unit) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var containerSize by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }
    var fullLoaded by remember { mutableStateOf(false) }
    val fullAlpha by animateFloatAsState(
        targetValue = if (fullLoaded) 1f else 0f,
        animationSpec = tween(220),
        label = "full-alpha",
    )
    val context = LocalContext.current

    Box(
        Modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    val next = (scale * zoom).coerceIn(1f, MAX_SCALE)
                    scale = next
                    offset = if (next <= 1.001f) {
                        Offset.Zero
                    } else {
                        // 限制平移范围,别把图拖出屏幕
                        val maxX = (containerSize.width * (next - 1f)) / 2f
                        val maxY = (containerSize.height * (next - 1f)) / 2f
                        Offset(
                            (offset.x + pan.x).coerceIn(-maxX, maxX),
                            (offset.y + pan.y).coerceIn(-maxY, maxY),
                        )
                    }
                }
            }
            .onSizeChanged { containerSize = it }
            .pointerInput(Unit) {
                detectTapGestures(
                    onTap = { onSingleTap() },
                    onDoubleTap = {
                        if (scale > 1.01f) {
                            scale = 1f
                            offset = Offset.Zero
                        } else {
                            scale = DOUBLE_TAP_SCALE
                        }
                    },
                )
            },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    translationX = offset.x
                    translationY = offset.y
                },
            contentAlignment = Alignment.Center,
        ) {
            // 预览图(未出全图前轻微模糊,避免放大后糊一片)
            RemoteImage(
                url = image.previewUrl.ifEmpty { image.fullUrl },
                origin = origin,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .blur(if (fullLoaded) 0.dp else 6.dp),
            )
            if (image.fullUrl.isNotEmpty() && image.fullUrl != image.previewUrl) {
                AsyncImage(
                    // 全图同样要按 iOS 的口径解析（远程图走代理、相对图补来源 + w=），否则相对路径的原图出不来
                    model = resolveImageUrl(image.fullUrl, origin?.trimEnd('/'), null),
                    imageLoader = remember(context.applicationContext) {
                        (context.applicationContext as io.movieclaw.android.MovieClawApp).imageLoaders.loader
                    },
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    onSuccess = { fullLoaded = true },
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer { alpha = fullAlpha },
                )
            } else if (image.fullUrl.isNotEmpty()) {
                LaunchedEffect(Unit) { fullLoaded = true }
            }
        }
    }
}

private const val MAX_SCALE = 5f
private const val DOUBLE_TAP_SCALE = 2.5f
