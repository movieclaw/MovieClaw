package io.movieclaw.androidtv.ui.home

import android.app.Application
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import io.movieclaw.androidtv.ui.LaunchArgs
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.focusedText
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.shell.MainShell
import io.movieclaw.core.model.generated.LibraryItemView
import io.movieclaw.core.model.generated.LibraryView
import io.movieclaw.core.model.generated.UpNextItemView
import io.movieclaw.core.model.generated.UpNextView
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 首页左右浏览（docs/perf/androidtv-home-scroll-2026-10.md §7，照 Apple TV 的做法）：
 * - 海报行展开位固定在行首（左 80 点）、大小不变，往右往左都是展开位里换一部；
 * - 「接下来继续」里挪焦点只在行内记，停稳 0.16 秒大图才换成焦点那一部。
 * 真的 MainShell + HomeScreen；1pt = 0.5dp。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
class HomeBrowseTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    private fun upNext(id: Long, title: String) = UpNextItemView(
        mediaItemId = id, libraryId = 1, kind = "tv", title = title, seasonNumber = 1, episodeNumber = 2, positionMs = 60_000, durationMs = 1_800_000,
    )

    private val movies = (1..8L).map { LibraryItemView(mediaItemId = 100 + it, kind = "movie", libraryId = 2, title = "电影$it") }

    @Before
    fun launch() {
        rule.setTvContent(
            mapOf(
                "/libraries" to listOf(
                    LibraryView(id = 1, name = "剧集", kind = "tv", viewerAccess = true),
                    LibraryView(id = 2, name = "电影", kind = "movie", viewerAccess = true),
                ),
                "/playback/up-next" to UpNextView(listOf(upNext(11, "甲剧"), upNext(12, "乙剧"), upNext(13, "丙剧"))),
                "/libraries/2/items" to movies,
            ),
        ) { MainShell(LaunchArgs()) }
        rule.mainClock.advanceTimeBy(2_000)
        rule.waitForIdle()
        assertEquals("继续播放", rule.focusedText())
    }

    private fun focusedBounds() = rule.onAllNodes(isFocused())[0].getBoundsInRoot()

    private fun countText(text: String) = rule.onAllNodesWithText(text, useUnmergedTree = true).fetchSemanticsNodes().size

    @Test
    fun posterRowKeepsTheExpandedSlotAtTheRowStart() {
        // 继续播放 → 接下来继续 → 我的媒体库 → 「最近添加的电影」海报行
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 1_000)
        assertEquals("电影1", rule.focusedText()?.substringBefore(" "))
        for (step in listOf(KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_LEFT)) {
            rule.press(step, settleMs = 600)
            val bounds = focusedBounds()
            assertEquals("展开位贴着行首（左 80 点）：${rule.focusedText()}", 40f, bounds.left.value, 0.5f)
            assertEquals("展开成 800 点宽", 400f, (bounds.right - bounds.left).value, 0.5f)
        }
        assertEquals("电影3", rule.focusedText()?.substringBefore(" "))
    }

    @Test
    fun heroFollowsTheUpNextCardOnceFocusSettles() {
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("甲剧", rule.focusedText()?.substringBefore(" "))
        // 时钟只按 press 给的时长走（默认 waitForIdle 会把 0.16 秒的停稳计时一并走完）
        rule.mainClock.autoAdvance = false
        // 卡片上的片名 2 处（图片占位字 + 卡片下的说明）；大图讲的是哪一部，片名就多 1 处
        assertEquals(3, countText("甲剧"))
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT, settleMs = 60)
        assertEquals("乙剧", rule.focusedText()?.substringBefore(" "))
        assertEquals("还没停稳，大图不换", 2, countText("乙剧"))
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        assertEquals("停稳后大图换成焦点那一部", 3, countText("乙剧"))
        assertEquals(2, countText("甲剧"))
        // 按住一路划过去：中间那张不换上大图，停下的那张才换
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT, settleMs = 60)
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT, settleMs = 60)
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT, settleMs = 1_000)
        assertEquals("甲剧", rule.focusedText()?.substringBefore(" "))
        assertEquals(3, countText("甲剧"))
        assertEquals(2, countText("丙剧"))
        // 往右挪到别的卡上停稳，回到按钮上再往下：落在大图正讲的那张
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT, settleMs = 1_000)
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 1_000)
        assertEquals(true, rule.focusedText() in setOf("继续播放", "详情"))
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 1_000)
        assertEquals("乙剧", rule.focusedText()?.substringBefore(" "))
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT, settleMs = 1_000)
        assertEquals("甲剧", rule.focusedText()?.substringBefore(" "))
    }
}
