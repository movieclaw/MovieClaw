package io.movieclaw.androidtv.ui.detail

import android.app.Application
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.episodes
import io.movieclaw.androidtv.ui.focusedText
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.Router
import io.movieclaw.core.model.generated.LibraryItemDetailView
import io.movieclaw.core.model.generated.SeasonEpisodesView
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * 普通多季剧（没有集段页签、没有播出日历）：从分集横排往上要停在选季上，不越过选季回首屏。
 * 真机上焦点往右走几集后按上，几何就近选中了滑走的首屏按钮（它们在几何上和选季叠着），选季永远选不到。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SeasonTabsFocusTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun upFromEpisodeRowStopsOnTheSeasonTabs() {
        val detail = LibraryItemDetailView(mediaItemId = 7, kind = "tv", title = "长街夜行", year = 2020, seasons = listOf(1, 2, 3))
        rule.setTvContent(
            mapOf(
                "/libraries/1/items/7" to detail,
                "/libraries/1/items/7/episodes" to SeasonEpisodesView(1, episodes(12)),
            ),
        ) {
            CompositionLocalProvider(LocalRouter provides Router()) { ItemDetailScreen(1, 7) }
        }
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 800)
        rule.onNodeWithTag("ep:1", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))
        // 行首那一集往上：当前季
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 500)
        rule.onNodeWithTag("season-tab:1", useUnmergedTree = true).assert(isFocused())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 500)
        rule.onNodeWithTag("episode-row", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))
        // 往右走到屏幕右边那几集（离选季的胶囊远、离首屏按钮近）再往上：仍是当前季
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        rule.onNodeWithTag("ep:4", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 500)
        rule.onNodeWithTag("season-tab:1", useUnmergedTree = true).assert(isFocused())
        // 选季往上回首屏
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 800)
        assertTrue("回到首屏：${rule.focusedText()}", rule.focusedText().orEmpty().contains("播放"))
    }
}
