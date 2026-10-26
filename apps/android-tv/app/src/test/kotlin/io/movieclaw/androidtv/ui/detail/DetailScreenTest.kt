package io.movieclaw.androidtv.ui.detail

import android.app.Application
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.Dp
import io.movieclaw.core.model.generated.LibraryItemDetailView
import io.movieclaw.core.model.generated.SeasonEpisodesView
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.episodes
import io.movieclaw.androidtv.ui.focusedText
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.Router
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.abs

/**
 * 剧集详情（175 集的长季，看到第 60 集）：往下滑到选集要跟手，滑下来后集段页签（1–50、51–100…）能用遥控器选段、
 * 在段上按确认打开「全部分集」挑一集。真的 ItemDetailScreen，假服务端只给条目与分集。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class DetailScreenTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    @Before
    fun open() {
        val detail = LibraryItemDetailView(mediaItemId = 7, kind = "tv", title = "吞噬星空", year = 2020, seasons = listOf(1))
        rule.setTvContent(
            mapOf(
                "/libraries/1/items/7" to detail,
                "/libraries/1/items/7/episodes" to SeasonEpisodesView(1, episodes(175, played = 59), resumeEpisode = 60),
            ),
        ) {
            CompositionLocalProvider(LocalRouter provides Router()) { ItemDetailScreen(1, 7) }
        }
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        assertTrue("首屏焦点在主按钮：${rule.focusedText()}", rule.focusedText().orEmpty().contains("播放"))
    }

    private fun rowTop(): Dp = rule.onNodeWithTag("episode-row", useUnmergedTree = true).getBoundsInRoot().top

    private fun assertEpisodeFocused(number: Int) =
        rule.onNodeWithTag("ep:$number", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))

    @Test
    fun slideToEpisodesFollowsTheRemote() {
        val start = rowTop()
        // 时钟手动走：看按下之后半秒滑到了哪
        rule.mainClock.autoAdvance = false
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 0)
        // 0.5 秒内滑到位（原先每帧只走剩余距离的 0.3%，一秒才挪出不到两成）
        rule.mainClock.advanceTimeBy(500)
        val atHalfSecond = rowTop()
        rule.mainClock.advanceTimeBy(3_000)
        val settled = rowTop()
        rule.waitForIdle()
        assertTrue("分集横排应往上滑走一大截：$start → $settled", start - settled > Dp(300f))
        assertTrue("0.5 秒时还差 ${atHalfSecond - settled}", abs((atHalfSecond - settled).value) < 2f)
        assertEpisodeFocused(60)
        // 往上（经过集段页签）回首屏同样跟手
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 500)
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 500)
        assertTrue("回到首屏：${rule.focusedText()}", rule.focusedText().orEmpty().contains("播放"))
        assertTrue("0.5 秒回到首屏：${rowTop()} vs $start", abs((rowTop() - start).value) < 2f)
    }

    @Test
    fun rangeTabsPickASegmentThenAnEpisode() {
        // 时钟手动走、每下按键之间只停 0.4 秒（遥控器的正常节奏）：页签要随下半截滑上来才显示、才接焦点，
        // 原先滑得太慢，这时按上直接回了首屏，用户根本看不到分段
        rule.mainClock.autoAdvance = false
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEpisodeFocused(60)
        // 横排往上是当前段（第 60 集在 51–100）
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("51–100", rule.focusedText())
        rule.savePreview("detail-episode-ranges")
        // 换段：横排跳到这一段的段首
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("101–150", rule.focusedText())
        rule.onNodeWithTag("ep:101", useUnmergedTree = true).assertExists()
        // 段上按确认：全部分集，焦点在段首；往右一格、确认，回到横排的那一集
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals("101", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("102", rule.focusedText())
        rule.savePreview("detail-episode-panel")
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEpisodeFocused(102)
    }
}
