package io.movieclaw.androidtv.ui.shell

import android.view.KeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.font.FontWeight
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt

private data class TabItem(val tab: MainTab, val title: String, val icon: ImageVector)

@Composable
private fun tabItems(): List<TabItem> {
    val nickname = LocalSession.current.session.nickname.ifEmpty { "账号" }
    return listOf(
        TabItem(MainTab.Account, nickname, McIcons.Account),
        TabItem(MainTab.Search, "搜索", McIcons.Search),
        TabItem(MainTab.Home, "首页", McIcons.Home),
    )
}

/** 收起时左上角的胶囊：「‹ [图标] 当前页」 */
@Composable
fun SidebarPill(tab: MainTab) {
    val item = tabItems().first { it.tab == tab }
    Row(
        Modifier
            .padding(start = 36.pt, top = 48.pt)
            .height(62.pt)
            .background(Color.Black.copy(alpha = 0.35f), RoundedCornerShape(50))
            .border(1.pt, Color.White.copy(alpha = 0.12f), RoundedCornerShape(50))
            .padding(horizontal = 20.pt),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.pt),
    ) {
        Icon(McIcons.Back, null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(30.pt))
        Icon(item.icon, null, tint = Color.White, modifier = Modifier.size(30.pt))
        Text(item.title, style = McType.size(30, FontWeight.Medium), color = Color.White)
    }
}

/**
 * 展开的侧边栏：左上角一块深色玻璃面板，三项竖排；焦点项白底黑字。
 * 上下移动不换页，按确认才切过去；按右收起、焦点回页面。
 */
@Composable
fun Sidebar(
    current: MainTab,
    focusRequester: FocusRequester,
    onSelect: (MainTab) -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .padding(start = 36.pt, top = 36.pt)
            .width(356.pt)
            .shadow(30.pt, RoundedCornerShape(40.pt))
            .background(Color(0xE6141519), RoundedCornerShape(40.pt))
            .border(1.pt, Color.White.copy(alpha = 0.1f), RoundedCornerShape(40.pt))
            .padding(12.pt)
            .onPreviewKeyEvent { event ->
                if (event.type == KeyEventType.KeyDown && event.nativeKeyEvent.keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) {
                    onClose()
                    true
                } else {
                    false
                }
            },
        verticalArrangement = Arrangement.spacedBy(4.pt),
    ) {
        for (item in tabItems()) {
            Surface(
                onClick = { onSelect(item.tab) },
                modifier = Modifier
                    .height(72.pt)
                    .width(332.pt)
                    .then(if (item.tab == current) Modifier.focusRequester(focusRequester) else Modifier),
                shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(50)),
                scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
                colors = ClickableSurfaceDefaults.colors(
                    containerColor = Color.Transparent,
                    contentColor = McColors.Text,
                    focusedContainerColor = Color.White,
                    focusedContentColor = Color.Black,
                ),
            ) {
                Row(
                    Modifier.padding(horizontal = 24.pt).height(72.pt),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(18.pt),
                ) {
                    Icon(item.icon, null, modifier = Modifier.size(32.pt))
                    Text(item.title, style = McType.size(31, FontWeight.Medium), maxLines = 1)
                }
            }
        }
    }
}
