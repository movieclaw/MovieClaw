package io.movieclaw.androidtv.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme

/** 纯黑底、冷银强调（同网页 / Apple TV 的观感）。正式的设计令牌在 A1 补齐。 */
object McColors {
    val Background = Color(0xFF000000)
    val Surface = Color(0xFF141416)
    val Silver = Color(0xFFC9CDD2)
    val TextPrimary = Color(0xFFF2F3F5)
    val TextSecondary = Color(0xFF9AA0A6)
    val Danger = Color(0xFFFF6B6B)
}

/** 电视安全区：四周各留 5%（1080p 下约 48dp × 27dp） */
object McMetrics {
    val SafeHorizontal = 48.dp
    val SafeVertical = 27.dp
}

@Composable
fun McTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = McColors.Silver,
            onPrimary = Color.Black,
            background = McColors.Background,
            surface = McColors.Surface,
            onSurface = McColors.TextPrimary,
        ),
        content = content,
    )
}
