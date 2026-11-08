package io.movieclaw.androidtv.ui.detail

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.theme.ptSp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** 完整简介要显示的东西：片名、副标题（剧集写第几季第几集，电影写年份类型那一行）、全文 */
internal data class OverviewContent(val title: String, val subtitle: String?, val text: String)

/** 上下键一次滚多少 */
private const val ScrollStepPt = 320

/**
 * 完整简介（TVOverviewPanel，issue #1238）：首屏的简介、分集卡长按菜单里的「完整简介」打开，盖满整屏，返回键 [onClose]。
 * 正文居中一栏、比详情页的字大一号。极长的简介一屏放不下时上下键一次翻约三分之一屏：面板上没有别的焦点，
 * 整块自己接焦点、把上下键换成滚动。焦点关在面板里（同全部分集面板）
 */
@Composable
internal fun OverviewPanel(content: OverviewContent, onClose: () -> Unit) {
    val focus = remember { FocusRequester() }
    val scroll = rememberScrollState()
    val scope = rememberCoroutineScope()
    val stepPx = with(LocalDensity.current) { ScrollStepPt.pt.toPx() }

    BackHandler(onBack = onClose)
    LaunchedEffect(Unit) {
        // 等面板排好再交焦点
        repeat(5) {
            delay(16)
            if (runCatching { focus.requestFocus() }.isSuccess) return@LaunchedEffect
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFF0B0D12))
            .testTag("overview-panel")
            .focusRequester(focus)
            .onPreviewKeyEvent { event ->
                val delta = when (event.key) {
                    Key.DirectionDown -> stepPx
                    Key.DirectionUp -> -stepPx
                    // 左右没有可去的地方，吃掉免得焦点跑出面板
                    Key.DirectionLeft, Key.DirectionRight -> 0f
                    else -> return@onPreviewKeyEvent false
                }
                if (event.type == KeyEventType.KeyDown && delta != 0f) {
                    scope.launch { scroll.animateScrollBy(delta, tween(250)) }
                }
                true
            }
            .focusable(),
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(Modifier.width(1240.pt).padding(top = 90.pt, bottom = 90.pt)) {
            Text(content.title, style = McType.size(52, FontWeight.Bold), maxLines = 2)
            content.subtitle?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = McType.size(27, FontWeight.SemiBold), color = McColors.TextMuted, maxLines = 1, modifier = Modifier.padding(top = 14.pt))
            }
            Text(
                content.text,
                style = McType.size(30).copy(lineHeight = (30 + 11 + 11).ptSp),
                color = Color.White.copy(alpha = 0.9f),
                modifier = Modifier
                    .padding(top = 44.pt)
                    .verticalScroll(scroll)
                    .testTag("overview-text"),
            )
        }
    }
}
