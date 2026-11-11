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
import androidx.compose.ui.test.onNodeWithText
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * 播放器的「下一集」「选集」：控制层进度条上方两颗按钮；选集剧照排（同 Apple TV / iPhone）用遥控器挑任意一集，可跨季。
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
        var diagnostics = 0
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
                    EpisodeActions(state.nextEpisode, onNext = { next++ }, onEpisodes = { opened++ }, focus = focus, onLeave = { left++ }, onDiagnostics = { diagnostics++ })
                }
            }
            LaunchedEffect(Unit) { focus.requestFocus() }
        }
        rule.waitForIdle()
        assertEquals("下一集", rule.focusedText())
        rule.savePreview("player-episode-actions")
        // 左右在三颗之间走（下一集、选集、播放诊断）、到头不出去，上键不动
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("选集", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("播放诊断", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("播放诊断", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("播放诊断", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(1, diagnostics)
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
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
    fun shelfOpensOnPlayingEpisodeAndRightThenSelectPlaysTheNext() {
        val picked = mutableListOf<Triple<Long, Long, List<EpisodeView>?>>()
        var refreshed = 0
        showShelf(episodes(9, played = 2), current = 3, onPick = { s, e, l -> picked += Triple(s, e, l) }, onRefresh = { refreshed++ })
        // 打开时焦点在正在放的这一集；简介写在剧照排下面
        assertFocusedCard("正在播放 第 3 集 · 第 3 集的标题")
        rule.onNodeWithText("第三集的简介").assertExists()
        assertEquals(1, refreshed)
        rule.savePreview("player-episode-shelf")
        // 看下一集：右、确认
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertFocusedCard("第 4 集 · 第 4 集的标题")
        rule.onNodeWithText("第三集的简介").assertDoesNotExist()
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(listOf(Triple(1L, 4L, null)), picked)
    }

    @Test
    fun missingEpisodesAreSkippedAndCurrentEpisodeOnlyCloses() {
        val picked = mutableListOf<Long>()
        var closed = 0
        showShelf(episodes(9, owned = { it != 4L && it != 5L }), current = 3, onPick = { _, e, _ -> picked += e }, onClose = { closed++ })
        // 缺集拿不到焦点：从第 3 集往右直接落在第 6 集
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertFocusedCard("第 6 集 · 第 6 集的标题")
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        // 正在放的这一集按确认只是收起
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(emptyList<Long>(), picked)
        assertEquals(1, closed)
    }

    @Test
    fun upMovesToSeasonTabsAndFocusingASeasonSwitchesTheRow() {
        val picked = mutableListOf<Triple<Long, Long, List<EpisodeView>?>>()
        val loaded = mutableListOf<Long>()
        val second = episodes(10, owned = { it <= 3 }).map { it.copy(name = "第二季 ${it.episodeNumber}") }
        showShelf(
            episodes(9, played = 2), current = 3, seasons = listOf(1L, 2L),
            loadSeason = { season -> loaded += season; second },
            onPick = { s, e, l -> picked += Triple(s, e, l) },
        )
        // 往上落在正在看的这一季（不按位置挑），往右移到第 2 季：下面换成第 2 季，不用按确认
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("第 1 季", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("第 2 季", rule.focusedText())
        assertEquals(listOf(2L), loaded)
        rule.onNodeWithText("第二季 1").assertExists()
        // 看别的季时没有「正在播放」那一张；焦点在季页签上时没有哪张卡算「焦点所在」，也就不写简介
        rule.onNodeWithText("正在播放").assertDoesNotExist()
        rule.onNodeWithText("第三集的简介").assertDoesNotExist()
        rule.savePreview("player-episode-shelf-season2")
        // 往下落在第 2 季第一个有片源的集，确认就跨季播放，带上取到的分集
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertFocusedCard("第 1 集 · 第二季 1")
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(listOf(Triple(2L, 1L, second)), picked)
    }

    @Test
    fun backOrDownOnTheRowCloses() {
        var closed = 0
        showShelf(episodes(9), current = 3, onClose = { closed++ })
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals(1, closed)
        rule.runOnUiThread { rule.activity.onBackPressedDispatcher.onBackPressed() }
        rule.waitForIdle()
        assertEquals(2, closed)
    }

    /** 焦点所在卡片的读屏名（测试里没有图片服务器，剧照位的占位字也并进了焦点文字，只看末尾的读屏名） */
    private fun assertFocusedCard(description: String) {
        val text = rule.focusedText()
        assertTrue("焦点应在「$description」，实际是「$text」", text?.endsWith(description) == true)
    }

    private fun showShelf(
        list: List<EpisodeView>,
        current: Long,
        seasons: List<Long> = listOf(1L),
        loadSeason: suspend (Long) -> List<EpisodeView>? = { null },
        onPick: (Long, Long, List<EpisodeView>?) -> Unit = { _, _, _ -> },
        onClose: () -> Unit = {},
        onRefresh: () -> Unit = {},
    ) {
        rule.setTvContent(emptyMap()) {
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF34506B), Color(0xFF1B2230))))) {
                EpisodeShelf(
                    title = "人生切割术",
                    currentSeason = 1,
                    currentEpisode = current,
                    playingEpisodes = list,
                    currentOverview = "第三集的简介",
                    seasons = seasons,
                    loadSeason = loadSeason,
                    onRefresh = onRefresh,
                    positionMs = 18 * 60_000L,
                    durationMs = 52 * 60_000L,
                    onPick = onPick,
                    onClose = onClose,
                )
            }
        }
        // 剧照排等排好再交焦点（几帧）
        rule.mainClock.advanceTimeBy(600)
        rule.waitForIdle()
    }
}
