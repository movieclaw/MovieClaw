package io.movieclaw.androidtv.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Card
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import io.movieclaw.androidtv.core.network.ImageUrls
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.ui.McColors

/**
 * 一张海报 / 剧照卡：焦点时由 tv-material 的 Card 放大。[aspect] 是宽 / 高。
 * 图片按卡片实际像素宽度（× 焦点放大 1.1）向上取宽度阶梯，见 image-sizing.md。
 */
@Composable
fun MediaCard(
    server: ServerAddress,
    imageUrl: String?,
    title: String,
    width: Dp,
    aspect: Float,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    progress: Float? = null,
) {
    val px = with(LocalDensity.current) { (width * 1.1f).roundToPx() }
    Column(modifier.width(width)) {
        Card(onClick = onClick, modifier = Modifier.fillMaxWidth().aspectRatio(aspect)) {
            Box(Modifier.fillMaxSize().background(McColors.Surface)) {
                AsyncImage(
                    model = ImageUrls.build(server, imageUrl, px)?.toString(),
                    contentDescription = title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
                if (progress != null && progress > 0f) {
                    Box(
                        Modifier.align(Alignment.BottomStart).fillMaxWidth(progress.coerceIn(0f, 1f)).height(4.dp)
                            .background(McColors.Silver),
                    )
                }
            }
        }
        Text(
            title,
            color = McColors.TextPrimary,
            fontSize = 16.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}
