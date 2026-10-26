package io.movieclaw.androidtv.ui.shell

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 主界面返回键的判断（用户真机：「谁在看？」、搜索页签根页按返回直接退出 App；首页一按就退也容易误触）。
 */
class BackActionTest {
    private fun action(sidebarOpen: Boolean = false, stackEmpty: Boolean = true, tab: MainTab = MainTab.Home, lastBackAtMs: Long? = null, nowMs: Long = 10_000) =
        backAction(sidebarOpen, stackEmpty, tab, lastBackAtMs, nowMs)

    @Test
    fun openSidebarClosesFirst() {
        for (tab in MainTab.entries) {
            assertEquals(tab.name, BackAction.CloseSidebar, action(sidebarOpen = true, tab = tab))
            assertEquals(tab.name, BackAction.CloseSidebar, action(sidebarOpen = true, stackEmpty = false, tab = tab))
        }
        // 首页刚出过退出提示，侧边栏开着也只收起侧边栏
        assertEquals(BackAction.CloseSidebar, action(sidebarOpen = true, lastBackAtMs = 9_500))
    }

    @Test
    fun secondaryPagePopsOnEveryTab() {
        for (tab in MainTab.entries) assertEquals(tab.name, BackAction.Pop, action(stackEmpty = false, tab = tab))
        assertEquals(BackAction.Pop, action(stackEmpty = false, lastBackAtMs = 9_500))
    }

    @Test
    fun accountAndSearchRootsGoHomeInsteadOfExiting() {
        assertEquals(BackAction.GoHome, action(tab = MainTab.Account))
        assertEquals(BackAction.GoHome, action(tab = MainTab.Search))
        assertEquals(BackAction.GoHome, action(tab = MainTab.Search, lastBackAtMs = 9_500))
    }

    @Test
    fun homeRootExitsOnlyOnASecondPressWithinTheWindow() {
        // 第一下只出提示
        assertEquals(BackAction.ArmExit, action())
        // 时限内再按：退出
        assertEquals(BackAction.Exit, action(lastBackAtMs = 10_000))
        assertEquals(BackAction.Exit, action(lastBackAtMs = 10_000 - EXIT_WINDOW_MS + 1))
        // 过了时限：重新提示，不退出
        assertEquals(BackAction.ArmExit, action(lastBackAtMs = 10_000 - EXIT_WINDOW_MS))
        assertEquals(BackAction.ArmExit, action(lastBackAtMs = 1_000))
        // 时钟倒退（不该发生）：按没按过算
        assertEquals(BackAction.ArmExit, action(lastBackAtMs = 12_000))
    }
}
