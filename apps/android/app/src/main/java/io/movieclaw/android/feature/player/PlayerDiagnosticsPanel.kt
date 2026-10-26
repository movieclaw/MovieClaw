package io.movieclaw.android.feature.player

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.core.playback.DiagLine
import io.movieclaw.core.playback.DiagSection

/**
 * 播放诊断面板（iOS PlayerDiagnosticsPanel）：用户报「放不出来 / 很卡」时截这一张图。
 * 内容由引擎的 DiagnosticsReport 拼好，这里只负责画：每节标题，「源」一行，「→ 处理」若干行。
 */
@Composable
fun PlayerDiagnosticsPanel(
    sections: List<DiagSection>,
    maxHeight: Dp,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(20.dp)
    Column(
        modifier
            .widthIn(max = 340.dp)
            .heightIn(max = maxHeight)
            .clip(shape)
            .background(Color.Black.copy(alpha = 0.72f))
            .border(1.dp, Color.White.copy(alpha = 0.12f), shape)
            .padding(14.dp)
            .semantics { contentDescription = "播放诊断" },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("播放诊断", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.9f))
            Spacer(Modifier.weight(1f))
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.14f))
                    .clickable(onClick = onClose)
                    .semantics { contentDescription = "关闭播放诊断" },
            ) {
                Icon(Icons.Rounded.Close, contentDescription = null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(14.dp))
            }
        }
        Spacer(Modifier.size(8.dp))
        SelectionContainer {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                sections.forEach { section -> DiagnosticsSection(section) }
            }
        }
    }
}

@Composable
private fun DiagnosticsSection(section: DiagSection) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        section.title?.let {
            Text(it, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.6f))
        }
        Column(
            Modifier.padding(start = if (section.title != null) 12.dp else 0.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            section.lines.forEach { line -> DiagnosticsLine(line) }
        }
    }
}

@Composable
private fun DiagnosticsLine(line: DiagLine) {
    val alert = Color(0xFFFF6B6B).copy(alpha = 0.85f)
    when (line.kind) {
        DiagLine.Kind.Source -> Text(line.text, fontSize = 11.5.sp, fontWeight = FontWeight.Medium, color = Color.White.copy(alpha = 0.95f))
        DiagLine.Kind.Action -> Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = Color.White.copy(alpha = 0.4f))) { append("→ ") }
                withStyle(SpanStyle(color = if (line.alert) alert else Color.White.copy(alpha = 0.75f))) { append(line.text) }
            },
            fontSize = 11.5.sp,
        )
        DiagLine.Kind.Muted -> Text(line.text, fontSize = 11.5.sp, color = Color.White.copy(alpha = 0.55f))
        DiagLine.Kind.Plain -> Text(line.text, fontSize = 11.5.sp, color = if (line.alert) alert else Color.White.copy(alpha = 0.75f))
    }
}
