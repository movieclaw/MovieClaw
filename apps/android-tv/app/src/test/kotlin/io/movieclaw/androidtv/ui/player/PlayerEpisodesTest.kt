package io.movieclaw.androidtv.ui.player

import android.app.Application
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.core.model.generated.PlaybackItemView
import io.movieclaw.core.playback.Phase
import io.movieclaw.core.playback.PlaybackUnit
import io.movieclaw.core.playback.PlayerState
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.episodes
import io.movieclaw.androidtv.ui.focusedText
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * 播放器的「下一集」「选集」：控制层进度条上方两颗按钮，选集面板（左栏分段、右边宫格）用遥控器挑任意一集。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PlayerEpisodesTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun actionRowMovesBetweenButtonsAndLeavesDownward() {
        var next = 0
        var opened = 0
        var left = 0
        val state = PlayerState(
            unit = PlaybackUnit(7, 1, 5),
            phase = Phase.Playing,
            info = PlaybackItemView(mediaItemId = 7, kind = "tv", title = "吞噬星空"),
            episodes = episodes(24, played = 4),
            hasSession = true,
            paused = false,
            positionMs = 9 * 60_000,
            durationMs = 24 * 60_000,
        )
        rule.setTvContent(emptyMap()) {
            val focus = remember { FocusRequester() }
            val scope = rememberCoroutineScope()
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF34506B), Color(0xFF1B2230))))) {
                Chrome(state, null, remember { TrickplayImages(OkHttpClient(), scope) { null } }) {
                    EpisodeActions(state.nextEpisode, onNext = { next++ }, onEpisodes = { opened++ }, focus = focus, onLeave = { left++ })
                }
            }
            LaunchedEffect(Unit) { focus.requestFocus() }
        }
        rule.waitForIdle()
        assertEquals("下一集", rule.focusedText())
        rule.savePreview("player-episode-actions")
        // 左右在两颗之间走、到头不出去，上键不动
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("选集", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("选集", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("选集", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(1, opened)
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("下一集", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(1, next)
        // 下键回到画面
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals(1, left)
    }

    @Test
    fun shortSeasonPickerIsOneRangeAndPicksAnyEpisode() {
        val picked = mutableListOf<Long>()
        var closed = 0
        showPicker(episodes(24, played = 4), current = 5, onPick = { picked += it }, onClose = { closed++ })
        // 打开时焦点在正在放的这一集
        assertEquals("5", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("15", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(listOf(16L), picked)
        // 左栏只有整季一段
        repeat(6) { rule.press(KeyEvent.KEYCODE_DPAD_LEFT) }
        assertEquals("1–24", rule.focusedText())
        rule.runOnUiThread { rule.activity.onBackPressedDispatcher.onBackPressed() }
        rule.waitForIdle()
        assertEquals(1, closed)
    }

    @Test
    fun longSeasonPickerChoosesARangeThenAnEpisode() {
        val picked = mutableListOf<Long>()
        showPicker(episodes(175, played = 119), current = 120, onPick = { picked += it }, onClose = {})
        assertEquals("120", rule.focusedText())
        rule.savePreview("player-episode-picker")
        // 宫格最左列再按左进左栏（当前段），往下换段，往右落在那一段的段首，确认就播
        repeat(9) { rule.press(KeyEvent.KEYCODE_DPAD_LEFT) }
        assertEquals("111", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("101–150", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("151–175", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("151", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(listOf(151L), picked)
    }

    private fun showPicker(list: List<EpisodeView>, current: Long, onPick: (Long) -> Unit, onClose: () -> Unit) {
        val state = PlayerState(unit = PlaybackUnit(7, 1, current), info = PlaybackItemView(mediaItemId = 7, kind = "tv", title = "吞噬星空"), episodes = list)
        rule.setTvContent(emptyMap()) { EpisodePicker(state, onPick, onClose) }
        // 面板等排好再交焦点（几帧）
        rule.mainClock.advanceTimeBy(300)
        rule.waitForIdle()
    }
}
