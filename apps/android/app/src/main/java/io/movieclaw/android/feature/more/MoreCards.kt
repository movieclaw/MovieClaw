package io.movieclaw.android.feature.more

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.designsystem.*
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.session.initials

private val AccountTint = Color(0xFF98BFFF)

@Composable
internal fun MoreAccountCard(session: SessionView?, origin: String?, onClick: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp))
            .background(Brush.linearGradient(listOf(Color(0xFF18263A), Color(0xFF111820))))
            .border(1.dp, AccountTint.copy(alpha = 0.15f), RoundedCornerShape(24.dp))
            .clickable(onClick = onClick).padding(18.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).background(AccountTint.copy(alpha = 0.13f)),
                contentAlignment = Alignment.Center,
            ) {
                if (!session?.avatarUrl.isNullOrBlank()) {
                    RemoteImage(session?.avatarUrl, origin, Modifier.fillMaxSize(), widthHint = 192)
                } else {
                    Text(session.initials(), fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = AccountTint)
                }
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    session?.nickname?.takeIf { it.isNotBlank() } ?: session?.username ?: "未登录",
                    fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(5.dp))
                Text(
                    when (session?.role) { "admin" -> "超级管理员"; "member" -> "成员"; else -> "访客" },
                    style = McType.microSemibold, color = AccountTint,
                    modifier = Modifier.clip(RoundedCornerShape(6.dp))
                        .background(AccountTint.copy(alpha = 0.1f)).padding(horizontal = 7.dp, vertical = 3.dp),
                )
            }
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, "个人资料", tint = TextMuted, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.height(16.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(AccountTint.copy(alpha = 0.1f)))
        Spacer(Modifier.height(11.dp))
        Text(
            session?.capabilities?.let { caps ->
                listOfNotNull(
                    "资源搜索".takeIf { caps.allowSearch }, "订阅".takeIf { caps.allowSubscribe },
                    "一键下载".takeIf { caps.allowDirectDownload },
                ).ifEmpty { listOf("仅浏览") }.joinToString(" · ")
            } ?: "登录后管理订阅与下载",
            style = McType.caption, color = TextMuted,
        )
    }
}

@Composable
internal fun MoreConnectionCard(origin: String?, savedCount: Int, onClick: () -> Unit) {
    FlatCard(Modifier.fillMaxWidth(), radius = 20.dp) {
        MoreActionRow(
            title = "服务器设置", subtitle = origin?.removePrefix("https://")?.removePrefix("http://") ?: "尚未连接",
            onClick = onClick,
        ) { Icon(Icons.Rounded.Settings, null, tint = AccountTint, modifier = Modifier.size(19.dp)) }
        Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp).height(1.dp).background(LineSoft))
        Text("已保存 $savedCount 台服务器", style = McType.caption, color = TextMuted, modifier = Modifier.padding(horizontal = 16.dp, vertical = 11.dp))
    }
}

@Composable
internal fun MoreAppearanceCard(liquid: Boolean, onChange: (Boolean) -> Unit) {
    FlatCard(Modifier.fillMaxWidth(), radius = 20.dp) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 72.dp).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            MoreIcon { Icon(Icons.Rounded.Star, null, tint = AccountTint, modifier = Modifier.size(19.dp)) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text("玻璃底栏", fontSize = 15.sp, fontWeight = FontWeight.Medium, color = TextPrimary)
                Spacer(Modifier.height(3.dp))
                Text("透明背景与轻盈动效", style = McType.caption, color = TextMuted)
            }
            Spacer(Modifier.width(8.dp))
            Switch(checked = liquid, onCheckedChange = onChange, colors = SwitchDefaults.colors(checkedTrackColor = AccountTint))
        }
    }
}

@Composable
internal fun MoreEmptySessions(onNew: () -> Unit) {
    FlatCard(Modifier.fillMaxWidth(), radius = 20.dp) {
        Column(Modifier.padding(18.dp)) {
            Text("开始一段新对话", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
            Spacer(Modifier.height(5.dp))
            Text("搜索影片、管理订阅、安排下载", style = McType.caption, color = TextMuted)
            Spacer(Modifier.height(16.dp))
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color(0xFFE0E9F6))
                    .clickable(onClick = onNew).heightIn(min = 44.dp).padding(vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center,
            ) {
                Icon(Icons.Rounded.Add, null, tint = Color(0xFF142238), modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("新会话", style = McType.subSemibold, color = Color(0xFF142238))
            }
        }
    }
}

@Composable
private fun MoreIcon(content: @Composable () -> Unit) {
    Box(Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).background(AccountTint.copy(alpha = 0.08f)), contentAlignment = Alignment.Center) { content() }
}

@Composable
private fun MoreActionRow(title: String, subtitle: String, onClick: () -> Unit, icon: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 76.dp).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MoreIcon(icon)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = TextPrimary)
            Spacer(Modifier.height(4.dp))
            Text(subtitle, style = McType.caption, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(8.dp))
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = TextFaint, modifier = Modifier.size(17.dp))
    }
}
