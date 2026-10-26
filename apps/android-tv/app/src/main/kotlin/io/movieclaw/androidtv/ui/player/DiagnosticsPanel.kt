package io.movieclaw.androidtv.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.core.playback.DiagLine
import io.movieclaw.core.playback.DiagSection

/**
 * 播放诊断（Apple 端 PlayerDiagnosticsPanel 的电视版）：左上角半透明卡片，纯展示、不接焦点，
 * 控制层收起后也留着，方便对着电视拍照。内容由引擎的 DiagnosticsReport 拼好。
 * 电视看得远，字比手机大一号；装不下的部分按行截掉（服务端日志尾巴之类长行只留开头）。
 */
@Composable
fun TvDiagnosticsPanel(sections: List<DiagSection>, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(28.pt)
    Column(
        modifier
            .width(640.pt)
            .clip(shape)
            .background(Color.Black.copy(alpha = 0.72f))
            .border(1.pt, Color.White.copy(alpha = 0.12f), shape)
            .padding(horizontal = 28.pt, vertical = 22.pt),
        verticalArrangement = Arrangement.spacedBy(10.pt),
    ) {
        Text("播放诊断", style = McType.size(22, FontWeight.SemiBold), color = Color.White.copy(alpha = 0.9f))
        for (section in sections) {
            Column(verticalArrangement = Arrangement.spacedBy(2.pt)) {
                section.title?.let {
                    Text(it, style = McType.size(18, FontWeight.SemiBold), color = Color.White.copy(alpha = 0.6f))
                }
                Column(Modifier.padding(start = if (section.title != null) 18.pt else 0.pt)) {
                    for (line in section.lines) Line(line)
                }
            }
        }
    }
}

@Composable
private fun Line(line: DiagLine) {
    val alert = Color(0xFFFF6B6B).copy(alpha = 0.85f)
    val style = McType.size(18)
    when (line.kind) {
        DiagLine.Kind.Source -> Text(line.text, style = McType.size(18, FontWeight.Medium), color = Color.White.copy(alpha = 0.95f), maxLines = 2)
        DiagLine.Kind.Action -> Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = Color.White.copy(alpha = 0.4f))) { append("→ ") }
                withStyle(SpanStyle(color = if (line.alert) alert else Color.White.copy(alpha = 0.75f))) { append(line.text) }
            },
            style = style,
            maxLines = 2,
        )
        DiagLine.Kind.Muted -> Text(line.text, style = style, color = Color.White.copy(alpha = 0.55f), maxLines = 3)
        DiagLine.Kind.Plain -> Text(line.text, style = style, color = if (line.alert) alert else Color.White.copy(alpha = 0.75f), maxLines = 2)
    }
}
