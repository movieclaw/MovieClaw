package io.movieclaw.androidtv.ui.shell

import android.app.Application
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import io.movieclaw.core.model.generated.LibraryView
import io.movieclaw.core.model.generated.UpNextItemView
import io.movieclaw.core.model.generated.UpNextView
import io.movieclaw.androidtv.ui.LaunchArgs
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.focusedText
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.setTvContent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 侧边栏 ↔ 首页的焦点（用户真机：首页按左弹出菜单，选「首页」或收起菜单后方向键全失灵，只剩按左再弹菜单）。
 * 真的 MainShell + HomeScreen，假服务端只给媒体库和「接下来继续」。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
class ShellFocusTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    private fun upNext(id: Long, title: String) = UpNextItemView(
        mediaItemId = id, libraryId = 1, kind = "tv", title = title, seasonNumber = 1, episodeNumber = 2, positionMs = 60_000, durationMs = 1_800_000,
    )

    @Before
    fun launch() {
        rule.setTvContent(
            mapOf(
                "/libraries" to listOf(LibraryView(id = 1, name = "剧集", kind = "tv", viewerAccess = true)),
                "/playback/up-next" to UpNextView(listOf(upNext(11, "甲剧"), upNext(12, "乙剧"), upNext(13, "丙剧"))),
            ),
        ) { MainShell(LaunchArgs()) }
        rule.mainClock.advanceTimeBy(2_000)
        rule.waitForIdle()
        assertEquals("开机焦点在「继续播放」", "继续播放", rule.focusedText())
    }

    @Test
    fun choosingHomeInSidebarHandsFocusBackToThePage() {
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("首页", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals("继续播放", rule.focusedText())
        // 方向键照常：往右到「详情」，往左回来，再往左才又展开侧边栏
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("详情", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("继续播放", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("甲剧", rule.focusedText()?.substringBefore(" "))
    }

    @Test
    fun closingSidebarReturnsToTheCardThatOpenedIt() {
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("甲剧", rule.focusedText()?.substringBefore(" "))
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("首页", rule.focusedText())
        // 按右收起：焦点回到离开时那张卡，往右接着走
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("甲剧", rule.focusedText()?.substringBefore(" "))
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("乙剧", rule.focusedText()?.substringBefore(" "))
    }

    @Test
    fun backFromSidebarOnASecondaryPageReturnsToIt() {
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("详情", rule.focusedText())
        // 压一页详情（假服务端拿不到条目，页里只有「返回」），再从侧边栏按返回键收起
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        assertEquals("返回", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("首页", rule.focusedText())
        back()
        assertFalse(rule.activity.isFinishing)
        assertEquals("返回", rule.focusedText())
    }

    private fun back() {
        rule.runOnUiThread { rule.activity.onBackPressedDispatcher.onBackPressed() }
        rule.mainClock.advanceTimeBy(400)
        rule.waitForIdle()
    }

    @Test
    fun backOnOpenSidebarClosesItInsteadOfExiting() {
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("首页", rule.focusedText())
        // 菜单开着按返回：收起、焦点回页面，不退出
        back()
        assertFalse(rule.activity.isFinishing)
        assertEquals("继续播放", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("详情", rule.focusedText())
        // 首页内容区（菜单收起）再按返回才退出
        back()
        assertTrue(rule.activity.isFinishing)
    }

    @Test
    fun sidebarKeepsFocusAtItsEnds() {
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("首页", rule.focusedText())
        // 「首页」是最后一项：往下不掉进页面
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("首页", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("搜索", rule.focusedText())
    }
}
