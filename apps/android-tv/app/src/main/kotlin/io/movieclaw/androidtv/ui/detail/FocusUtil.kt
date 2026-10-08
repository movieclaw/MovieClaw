package io.movieclaw.androidtv.ui.detail

import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties

/** 请求焦点；目标还没组合出来（惰性行滚出屏）时返回 false，不抛 */
internal fun FocusRequester.tryFocus(): Boolean = runCatching { requestFocus(FocusDirection.Enter) }.getOrDefault(false)

/**
 * 一行（焦点区）的进出规则，对应 tvOS 的 focusSection + defaultFocus：
 * - 上下方向键进到这一行时落在 [entry] 给的那一张（返回 null 或没组合出来就按几何就近）；
 * - 在行尾再按右不跳到别的行上去（tvOS 横排到头就停住）。
 */
internal fun Modifier.focusSection(entry: () -> FocusRequester? = { null }): Modifier = focusProperties {
    onEnter = {
        if (requestedFocusDirection == FocusDirection.Up || requestedFocusDirection == FocusDirection.Down) {
            entry()?.tryFocus()
        }
    }
    onExit = {
        if (requestedFocusDirection == FocusDirection.Right) cancelFocusChange()
    }
}
