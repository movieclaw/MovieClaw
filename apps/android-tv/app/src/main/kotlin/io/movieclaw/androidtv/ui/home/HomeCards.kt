package io.movieclaw.androidtv.ui.home

import android.os.Build
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import io.movieclaw.androidtv.ui.components.FocusCard
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.imageUrl
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.components.layerFocus

/**
 * 媒体库卡（TVLibraryCard）：565×317.8（16:9）；上部是 21:10 的封面、下沿 80%→100% 渐隐，
 * 背后垫同一张图的模糊版加 30% 黑；左下角一条名字带（38 半粗），合集再在右边挂「合集」标签。
 */
@Composable
fun LibraryCard(name: String, image: String?, onClick: () -> Unit, modifier: Modifier = Modifier, collection: Boolean = false) {
    val url = imageUrl(image, 565f, McMetrics.FocusZoom)
    FocusCard(onClick, modifier.width(McMetrics.LibraryWidth).height(317.8f.pt)) {
        Box(Modifier.fillMaxSize().background(McColors.SurfaceRaised)) {
            if (url != null) {
                AsyncImage(
                    url, null, contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize().then(if (Build.VERSION.SDK_INT >= 31) Modifier.blur(20.dp) else Modifier),
                )
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.3f)))
                AsyncImage(
                    url, null, contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(269.pt)
                        .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                        .fadeBottom(0.8f),
                )
            } else {
                Icon(if (collection) McIcons.Stack else McIcons.Film, null, tint = McColors.TextFaint, modifier = Modifier.align(Alignment.Center).size(60.pt))
            }
            Row(
                Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth()
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.82f))))
                    .padding(start = 28.pt, end = 28.pt, top = 56.pt, bottom = 20.pt),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    name,
                    style = McType.size(38, FontWeight.SemiBold).copy(shadow = Shadow(Color.Black.copy(alpha = 0.5f), blurRadius = 12f)),
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (collection) {
                    Row(
                        Modifier
                            .background(Color.White.copy(alpha = 0.12f), RoundedCornerShape(50))
                            .border(1.pt, Color.White.copy(alpha = 0.18f), RoundedCornerShape(50))
                            .padding(horizontal = 12.pt, vertical = 5.pt),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.pt),
                    ) {
                        Icon(McIcons.Stack, null, tint = Color.White.copy(alpha = 0.88f), modifier = Modifier.size(20.pt))
                        Text("合集", style = McType.size(20, FontWeight.SemiBold), color = Color.White.copy(alpha = 0.88f))
                    }
                }
            }
        }
    }
}

/** 下沿渐隐遮罩：[from] 以上不透明、到底部全透明（DstIn，要配合离屏合成） */
private fun Modifier.fadeBottom(from: Float): Modifier = drawWithContent {
    drawContent()
    drawRect(
        Brush.verticalGradient(0f to Color.Black, from to Color.Black, 1f to Color.Transparent),
        blendMode = androidx.compose.ui.graphics.BlendMode.DstIn,
    )
}

/**
 * 「按类型找」贴图卡（TVGenreCard + GenreCardFace）：416×234、圆角 20；图未选中时饱和度 0.76、选中 1；
 * 左下两层托字暗角，类型名 40 半粗（左 30、底 66）、部数 24 等宽数字（左 30、底 29）。
 * 焦点不用系统抬起：放大 1.07、3pt 白 88% 描边、投影，0.23 秒。
 */
@Composable
fun GenreCard(label: String, count: Long, mediaKind: String, cover: String?, onClick: () -> Unit, modifier: Modifier = Modifier) {
    var focused by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (focused) 1.07f else 1f, tween(230), label = "genre-scale")
    val saturation by animateFloatAsState(if (focused) 1f else 0.76f, tween(230), label = "genre-sat")
    val url = imageUrl(cover, 416f, 1.07f)
    val shape = RoundedCornerShape(McMetrics.CardCorner)
    Surface(
        onClick = onClick,
        modifier = modifier
            .layerFocus()
            .width(McMetrics.GenreWidth)
            .height(234.pt)
            .scale(scale)
            .then(if (focused) Modifier.shadow(18.pt, shape, spotColor = Color.Black.copy(alpha = 0.4f)) else Modifier)
            .onFocusChanged { focused = it.isFocused },
        shape = ClickableSurfaceDefaults.shape(shape),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
        border = ClickableSurfaceDefaults.border(
            border = androidx.tv.material3.Border(BorderStroke(0.5f.pt, Color.White.copy(alpha = 0.08f)), shape = shape),
            focusedBorder = androidx.tv.material3.Border(BorderStroke(3.pt, Color.White.copy(alpha = 0.88f)), shape = shape),
        ),
        colors = ClickableSurfaceDefaults.colors(containerColor = McColors.SurfaceRaised, focusedContainerColor = McColors.SurfaceRaised),
    ) {
        Box(Modifier.fillMaxSize().clip(shape)) {
            if (url != null) {
                AsyncImage(
                    url, null, contentScale = ContentScale.Crop,
                    colorFilter = ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(saturation) }),
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.28f), Color.White.copy(alpha = 0.12f)))))
            }
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.46f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.28f))))
            // 左下角椭圆暗角：中心 (0.12w, h)，宽 1.56w × 高 1.44h，最深 50%
            Box(
                Modifier.fillMaxSize().drawBehind {
                    drawRect(
                        Brush.radialGradient(
                            listOf(Color.Black.copy(alpha = 0.5f), Color.Transparent),
                            center = androidx.compose.ui.geometry.Offset(size.width * 0.12f, size.height),
                            radius = size.width * 0.78f,
                        ),
                    )
                },
            )
            Text(
                label,
                style = McType.size(40, FontWeight.SemiBold).copy(shadow = Shadow(Color.Black.copy(alpha = 0.32f), blurRadius = 8f)),
                color = Color.White,
                maxLines = 1,
                modifier = Modifier.align(Alignment.BottomStart).padding(start = 30.pt, bottom = 66.pt),
            )
            Text(
                "$count 部${if (mediaKind == "tv") "剧集" else "电影"}",
                style = McType.size(24).copy(fontFamily = FontFamily.Monospace),
                color = Color.White.copy(alpha = 0.72f),
                modifier = Modifier.align(Alignment.BottomStart).padding(start = 30.pt, bottom = 29.pt),
            )
        }
    }
}
