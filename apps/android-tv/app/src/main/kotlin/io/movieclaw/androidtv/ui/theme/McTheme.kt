package io.movieclaw.androidtv.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme

@Composable
fun McTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Color.White,
            onPrimary = Color.Black,
            background = McColors.Background,
            surface = McColors.SurfaceRaised,
            onSurface = McColors.Text,
            border = Color.White,
        ),
    ) {
        CompositionLocalProvider(LocalContentColor provides McColors.Text, content = content)
    }
}

/** 时间显示（Theme.swift Formatters.clock）：一小时以上 H:MM:SS，否则 M:SS；无效值 --:-- */
object Formatters {
    fun clock(seconds: Double?): String {
        if (seconds == null || seconds.isNaN() || seconds.isInfinite() || seconds < 0) return "--:--"
        val total = seconds.toLong()
        val h = total / 3600
        val m = total % 3600 / 60
        val s = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }

    fun clockMs(ms: Long?): String = clock(ms?.div(1000.0))

    /** 「N 分钟 / H 小时 M 分 / H 小时」（首页卡片带的时长） */
    fun duration(ms: Long): String {
        val minutes = (ms / 60_000).toInt()
        val h = minutes / 60
        val m = minutes % 60
        return when {
            h == 0 -> "$m 分钟"
            m == 0 -> "$h 小时"
            else -> "$h 小时 $m 分"
        }
    }

    /** 详情页 / 大图区的片长（TVItemDetailView.runtimeText）：「N 分钟 / H 小时 M 分钟 / H 小时」 */
    fun runtime(minutes: Int): String {
        val h = minutes / 60
        val m = minutes % 60
        return when {
            h == 0 -> "$m 分钟"
            m == 0 -> "$h 小时"
            else -> "$h 小时 $m 分钟"
        }
    }
}
