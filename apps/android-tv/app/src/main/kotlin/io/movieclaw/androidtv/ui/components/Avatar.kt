package io.movieclaw.androidtv.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.TextUnitType
import androidx.tv.material3.Text
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.pt

/** 头像缩写（TVAvatar.initials）：去掉首尾空白；首字是汉字（U+4E00–9FFF）取一个字，否则取前两个字符大写；空名字是「?」 */
fun initials(name: String): String {
    val trimmed = name.trim()
    val first = trimmed.firstOrNull() ?: return "?"
    return if (first.code in 0x4E00..0x9FFF) first.toString() else trimmed.take(2).uppercase()
}

/**
 * 圆形头像（TVAvatar）：白 35%→18% 的竖向渐变底 + 缩写（尺寸 × 0.38，半粗），远程图盖在上面裁成圆。
 * [focused] 时放大 1.12、内描 6pt 白边、投影（TVProfileAvatarFocus），0.2 秒 easeOut。
 */
@Composable
fun Avatar(
    name: String,
    image: String?,
    sizePt: Int,
    modifier: Modifier = Modifier,
    focused: Boolean = false,
    focusable: Boolean = true,
) {
    val scale by animateFloatAsState(if (focused) McMetrics.AvatarFocusZoom else 1f, tween(200), label = "avatar")
    val size: Dp = sizePt.pt
    Box(
        modifier
            .size(size)
            .scale(scale)
            .then(if (focused || !focusable) Modifier.shadow(28.pt, CircleShape, ambientColor = Color.Black, spotColor = Color.Black.copy(alpha = 0.55f)) else Modifier)
            .clip(CircleShape)
            .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.35f), Color.White.copy(alpha = 0.18f)))),
        contentAlignment = Alignment.Center,
    ) {
        Text(initials(name), fontSize = TextUnit(sizePt * 0.38f * 0.5f, TextUnitType.Sp), fontWeight = FontWeight.SemiBold, color = Color.White)
        if (image != null) {
            RemoteImage(image, sizePt.toFloat(), Modifier.fillMaxSize(), zoom = McMetrics.AvatarFocusZoom, showsPlaceholderBox = false)
        }
        if (focused) Box(Modifier.fillMaxSize().border(6.pt, Color.White, CircleShape))
    }
}

/**
 * 浮层玻璃卡（欢迎、登录、配对卡）：tvOS 的 `.glassEffect(.regular, in: .rect(cornerRadius: 48))`。
 * 电视上做不到实时背景模糊（性能），用半透明白 + 细边近似。
 */
fun Modifier.glass(corner: Dp = 48.pt): Modifier = this
    .background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(corner))
    .border(1.pt, Color.White.copy(alpha = 0.16f), RoundedCornerShape(corner))
