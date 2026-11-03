package io.movieclaw.android.core.designsystem

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 内联的使用提示卡（与 iOS `TipCard` 同一版式，照 TipKit 的 TipView：左边图标、标题加一句说明、右上角关闭）。
 * 什么时候出现、关掉之后怎么记，由页面按 `TipsStore` 判定与上报（docs/design/tips.md）。
 */
@Composable
fun TipCard(
    title: String,
    message: String,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector = Icons.Rounded.ArrowDownward,
) {
    // 图标隔一会儿往下跳一下（iOS `.symbolEffect(.bounce.down, .periodic)`）
    val bounce by rememberInfiniteTransition(label = "tip-icon").animateFloat(
        initialValue = 0f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(
            keyframes {
                durationMillis = 3200
                0f at 0
                5f at 180
                -1.5f at 380
                0f at 560
            },
            repeatMode = RepeatMode.Restart,
            initialStartOffset = StartOffset(800),
        ),
        label = "tip-icon-bounce",
    )
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(GlassCard)
            .border(1.dp, LineColor, RoundedCornerShape(22.dp))
            .padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = Accent,
            modifier = Modifier.width(30.dp).size(26.dp).graphicsLayer { translationY = bounce.dp.toPx() },
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary)
            Text(message, fontSize = 15.sp, lineHeight = 20.sp, color = TextMuted)
        }
        Box(
            Modifier.size(28.dp).clip(CircleShape).clickable(onClick = onClose),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.Close, contentDescription = "关闭", tint = TextFaint, modifier = Modifier.size(16.dp))
        }
    }
}
