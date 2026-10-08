package io.movieclaw.androidtv.ui.components

import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged

/**
 * 导航栈里一页最后拿到焦点的那颗控件：退回这一页时把焦点还给它（同 tvOS 导航栈）。
 * Compose 的 focusRestorer 只记住直接子级，隔着滚动容器就退回到第一颗，所以由可聚焦控件自己登记。
 */
class LayerFocusMemory {
    private var last: FocusRequester? = null

    fun remember(requester: FocusRequester) {
        last = requester
    }

    fun forget(requester: FocusRequester) {
        if (last === requester) last = null
    }

    fun restore(): Boolean = last?.let { runCatching { it.requestFocus() }.getOrDefault(false) } ?: false
}

val LocalLayerFocusMemory = staticCompositionLocalOf<LayerFocusMemory?> { null }

/** 卡片、按钮这类可聚焦控件挂上它，所在页被压下去再退回来时焦点能回到这里 */
fun Modifier.layerFocus(): Modifier = composed {
    val memory = LocalLayerFocusMemory.current ?: return@composed Modifier
    val requester = remember { FocusRequester() }
    DisposableEffect(memory, requester) { onDispose { memory.forget(requester) } }
    Modifier.focusRequester(requester).onFocusChanged { if (it.isFocused) memory.remember(requester) }
}
