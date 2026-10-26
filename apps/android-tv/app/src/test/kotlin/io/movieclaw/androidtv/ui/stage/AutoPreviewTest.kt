package io.movieclaw.androidtv.ui.stage

import android.app.Application
import android.os.Looper
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import io.movieclaw.androidtv.AppGraph
import io.movieclaw.core.model.generated.LibraryView
import io.movieclaw.core.model.generated.UpNextItemView
import io.movieclaw.core.model.generated.UpNextView
import io.movieclaw.androidtv.ui.LaunchArgs
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.TvEnv
import io.movieclaw.androidtv.ui.accounts.AccountsScreen
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.MainShell
import io.movieclaw.androidtv.ui.shell.Router
import androidx.compose.runtime.CompositionLocalProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

/**
 * 大图自动播放预告：默认关（首页一个片段请求都不发、不建播放器）；在「谁在看」页打开后，焦点停稳 2 秒才去要片段，
 * 一路划过去的卡不发请求。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
class AutoPreviewTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    private fun upNext(id: Long, title: String) = UpNextItemView(
        mediaItemId = id, libraryId = 1, kind = "movie", title = title, positionMs = 60_000, durationMs = 5_400_000,
    )

    private fun home(): TvEnv {
        val env = rule.setTvContent(
            mapOf(
                "/libraries" to listOf(LibraryView(id = 1, name = "电影", kind = "movie", viewerAccess = true)),
                "/playback/up-next" to UpNextView((11L..16L).map { upNext(it, "片$it") }),
            ),
        ) { MainShell(LaunchArgs()) }
        rule.mainClock.autoAdvance = false
        rule.mainClock.advanceTimeBy(2_000)
        rule.waitForIdle()
        return env
    }

    /** 预告控制器跑在 App 级协程（主线程 Looper）上，界面时钟之外还要让 Looper 的时间走 */
    private fun settle(ms: Long) {
        rule.mainClock.advanceTimeBy(ms)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
        rule.waitForIdle()
    }

    private fun TvEnv.reels() = transport.requested.filter { it.startsWith("/reels/") }

    @Test
    fun homeShowsStillsOnlyByDefault() {
        val env = home()
        assertFalse(env.graph.autoPreview)
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        settle(10_000)
        assertEquals(emptyList<String>(), env.reels())
    }

    @Test
    fun enabledPreviewWaitsForFocusToSettle() {
        val env = home()
        rule.runOnUiThread { env.graph.saveAutoPreview(true) }
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        // 一张张划过去（每张 0.4 秒）：不发片段请求
        repeat(4) { rule.press(KeyEvent.KEYCODE_DPAD_RIGHT) }
        assertEquals(emptyList<String>(), env.reels())
        // 停住 2 秒多：只为停住的这一部要一次
        settle(2_500)
        assertEquals(listOf("/reels/preview/15"), env.reels())
        // 关掉：之后不再请求
        rule.runOnUiThread { env.graph.saveAutoPreview(false) }
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        settle(5_000)
        assertEquals(1, env.reels().size)
    }

    @Test
    fun switchOnAccountsPageTogglesAndPersists() {
        val env = rule.setTvContent(emptyMap()) {
            CompositionLocalProvider(LocalRouter provides Router()) { AccountsScreen() }
        }
        rule.waitForIdle()
        rule.onNodeWithText("自动播放预告：关").performSemanticsAction(SemanticsActions.OnClick)
        rule.waitForIdle()
        assertTrue(env.graph.autoPreview)
        rule.onNodeWithText("自动播放预告：开").assertExists()
        // 下次启动照样是开着的
        assertTrue(AppGraph(rule.activity.application).autoPreview)
    }
}
