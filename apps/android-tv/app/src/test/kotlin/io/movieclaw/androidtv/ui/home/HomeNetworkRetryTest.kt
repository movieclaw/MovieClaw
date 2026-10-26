package io.movieclaw.androidtv.ui.home

import android.app.Application
import android.net.ConnectivityManager
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import io.movieclaw.androidtv.ui.LaunchArgs
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.focusedText
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.shell.MainShell
import io.movieclaw.core.model.generated.LibraryItemView
import io.movieclaw.core.model.generated.LibraryView
import io.movieclaw.core.model.generated.UpNextItemView
import io.movieclaw.core.model.generated.UpNextView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetwork

/**
 * 开机直达 MovieClaw 时 Wi-Fi 比 App 晚连上（用户真机：重启电视后停在「连不上服务器」，要手动点重试）：
 * 首页第一次加载失败后，网络一连上就自己重试，不等每分钟的定时刷新。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
class HomeNetworkRetryTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    private fun errorCount() = rule.onAllNodesWithText("连不上服务器").fetchSemanticsNodes().size

    private fun connectivity() = shadowOf(rule.activity.application.getSystemService(ConnectivityManager::class.java))

    /** Wi-Fi 连上：系统发来网络回调 */
    private fun networkComesUp() = connectivity().networkCallbacks.forEach { it.onAvailable(ShadowNetwork.newInstance(100)) }

    /** 刚开机还没网：假服务端什么都不答，首页报错 */
    private fun bootOffline(routes: MutableMap<String, Any>, delays: Map<String, Long> = emptyMap()) =
        rule.setTvContent(routes, delays) { MainShell(LaunchArgs()) }.also {
            rule.mainClock.advanceTimeBy(2_000)
            rule.waitForIdle()
            assertEquals("没网时首页报错", 1, errorCount())
        }

    @Test
    fun firstLoadRetriesWhenNetworkComesUp() {
        val routes = mutableMapOf<String, Any>()
        bootOffline(routes)

        // 服务端已经能答，但系统还没报网络连上：不自己轮询
        routes["/libraries"] = listOf(LibraryView(id = 1, name = "剧集", kind = "tv", viewerAccess = true))
        routes["/playback/up-next"] = UpNextView(
            listOf(
                UpNextItemView(
                    mediaItemId = 11, libraryId = 1, kind = "tv", title = "甲剧", seasonNumber = 1, episodeNumber = 2,
                    positionMs = 60_000, durationMs = 1_800_000,
                ),
            ),
        )
        rule.mainClock.advanceTimeBy(5_000)
        rule.waitForIdle()
        assertEquals(1, errorCount())

        // 网络回调一来，首页立即重试（远不到 60 秒的定时刷新）
        networkComesUp()
        rule.mainClock.advanceTimeBy(2_000)
        rule.waitForIdle()
        assertEquals("网络一来首页就加载出来", 0, errorCount())
        assertEquals("继续播放", rule.focusedText())
        // 加载成功后退订网络回调
        assertEquals(0, connectivity().networkCallbacks.size)
    }

    @Test
    fun retryFinishesSlowRowsAndKeepsPeriodicRefresh() {
        // 真机网络有延迟：媒体库先到、失败标记先清掉，内容行晚 1 秒才答。重试不能被半路取消，否则各行是空的
        val routes = mutableMapOf<String, Any>()
        val env = bootOffline(routes, delays = mapOf("/libraries/1/items" to 1_000L))
        routes["/libraries"] = listOf(LibraryView(id = 1, name = "剧集", kind = "tv", viewerAccess = true))
        routes["/libraries/1/items"] = listOf(LibraryItemView(mediaItemId = 21, kind = "tv", libraryId = 1, title = "乙剧"))

        networkComesUp()
        rule.mainClock.advanceTimeBy(3_000)
        rule.waitForIdle()
        assertTrue("内容行加载完整", rule.onAllNodesWithText("乙剧").fetchSemanticsNodes().isNotEmpty())

        // 之后每分钟的定时刷新照常在跑
        val before = env.transport.requested.count { it == "/libraries" }
        rule.mainClock.advanceTimeBy(61_000)
        rule.waitForIdle()
        assertTrue("定时刷新还在", env.transport.requested.count { it == "/libraries" } > before)
    }
}
