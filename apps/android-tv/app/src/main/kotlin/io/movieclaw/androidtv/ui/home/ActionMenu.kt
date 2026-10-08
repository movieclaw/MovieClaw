package io.movieclaw.androidtv.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.window.Dialog
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt

data class MenuAction(val title: String, val icon: ImageVector, val run: () -> Unit)

/** 长按确认键弹出的菜单（tvOS contextMenu）：一列按钮，焦点落在第一项，返回键关掉 */
@Composable
fun ActionMenu(actions: List<MenuAction>, onDismiss: () -> Unit) {
    val first = remember { FocusRequester() }
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier.width(560.pt).background(Color(0xF01C1D22), RoundedCornerShape(32.pt)).padding(16.pt),
            verticalArrangement = Arrangement.spacedBy(6.pt),
        ) {
            actions.forEachIndexed { index, action ->
                Surface(
                    onClick = {
                        onDismiss()
                        action.run()
                    },
                    modifier = if (index == 0) Modifier.focusRequester(first) else Modifier,
                    shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(20.pt)),
                    scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
                    colors = ClickableSurfaceDefaults.colors(
                        containerColor = Color.Transparent,
                        contentColor = McColors.Text,
                        focusedContainerColor = Color.White,
                        focusedContentColor = Color.Black,
                    ),
                ) {
                    Row(Modifier.padding(horizontal = 28.pt, vertical = 20.pt), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.pt)) {
                        Icon(action.icon, null, modifier = Modifier.size(34.pt))
                        Text(action.title, style = McType.size(31, FontWeight.Medium))
                    }
                }
            }
        }
        LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    }
}
