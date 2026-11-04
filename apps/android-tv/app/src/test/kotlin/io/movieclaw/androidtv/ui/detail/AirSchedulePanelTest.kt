package io.movieclaw.androidtv.ui.detail

import android.app.Application
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import io.movieclaw.androidtv.ui.Responder
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.TvEnv
import io.movieclaw.androidtv.ui.focusedText
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.Router
import io.movieclaw.core.model.generated.EpisodeArrivalView
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.core.model.generated.LibraryItemDetailView
import io.movieclaw.core.model.generated.MediaBrief
import io.movieclaw.core.model.generated.PrepareView
import io.movieclaw.core.model.generated.SearchNowView
import io.movieclaw.core.model.generated.SeasonAirScheduleView
import io.movieclaw.core.model.generated.SeasonEpisodesView
import io.movieclaw.core.model.generated.SeasonOverview
import io.movieclaw.core.model.generated.SessionCapabilities
import io.movieclaw.core.model.generated.SessionView
import io.movieclaw.core.model.generated.SmartPlanView
import io.movieclaw.core.model.generated.SubscriptionCreateView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * 播出日历的遥控器走查：真的 ItemDetailScreen，假服务端给在播剧的分集与日历。
 * 第 1 季 24 集、每天两集，今天播第 13–14 集，已入库到第 12 集、缺第 7 集。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AirSchedulePanelTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    private val today = AirDate.parse("2026-11-05")!!

    private fun showEpisodes() = (1L..24L).map { number ->
        val day = ((number - 1) / 2).toInt() - 6
        EpisodeView(
            episodeNumber = number,
            name = "第 $number 集的标题",
            owned = number <= 12 && number != 7L,
            airDate = today.plusDays(day).iso,
        )
    }

    private fun subscribedSchedule() = SeasonAirScheduleView(
        today = today.iso,
        weekdays = (0L..6L).toList(),
        lastAirDate = today.plusDays(5).iso,
        subscriptionId = 5,
        missingEpisodes = listOf(7),
        arrivals = listOf(EpisodeArrivalView(13, "downloading"), EpisodeArrivalView(14, "waiting")),
    )

    private fun open(
        routes: Map<String, Any>,
        account: SessionView = SessionView(username = "admin", nickname = "我", role = "admin"),
        seasons: List<Long> = listOf(1),
    ): TvEnv {
        val detail = LibraryItemDetailView(mediaItemId = 7, kind = "tv", title = "长街夜行", tmdbId = 777, seasons = seasons)
        val env = rule.setTvContent(mapOf("/libraries/1/items/7" to detail) + routes, account = account) {
            CompositionLocalProvider(LocalRouter provides Router()) { ItemDetailScreen(1, 7) }
        }
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        return env
    }

    /** 首屏往下进分集横排，再往上到入口条 */
    private fun focusStrip() {
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 800)
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 500)
        rule.onNodeWithTag("air-schedule-summary", useUnmergedTree = true).assert(isFocused())
    }

    @Test
    fun walkThroughTheScheduleWithTheRemote() {
        val env = open(
            mapOf(
                "/libraries/1/items/7/episodes" to SeasonEpisodesView(1, showEpisodes(), resumeEpisode = 6, airSchedule = subscribedSchedule()),
                "/subscriptions/5/missing-resource-searches" to SearchNowView(resetCount = 1),
            ),
        )
        focusStrip()
        // 入口条一行写完，缺集只在日程里标
        rule.onNodeWithText("第 13–14 集更新", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("每天更新 · 还剩 10 集 · 11月10日 完结", useUnmergedTree = true).assertIsDisplayed()
        assertEquals(0, rule.onAllNodes(hasText("缺第 7 集"), useUnmergedTree = true).fetchSemanticsNodes().size)
        rule.savePreview("air-schedule-strip")

        // 确认：打开日程，焦点落在今天
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 500)
        rule.onNodeWithTag("air-schedule-sheet", useUnmergedTree = true).assertExists()
        rule.onNodeWithTag("air-day-2026-11-05", useUnmergedTree = true).assert(isFocused())
        rule.onNodeWithText("还剩 10 集", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("本周", useUnmergedTree = true).assertIsDisplayed()
        rule.savePreview("air-schedule-panel")

        // 往下一天一天走
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        rule.onNodeWithTag("air-day-2026-11-06", useUnmergedTree = true).assert(isFocused())
        rule.press(KeyEvent.KEYCODE_DPAD_UP)

        // 往上是折叠的已播出；确认展开，缺集那天列出来
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        rule.onNodeWithTag("air-schedule-past", useUnmergedTree = true).assert(isFocused())
        assertEquals(0, rule.onAllNodes(hasText("补这一集"), useUnmergedTree = true).fetchSemanticsNodes().size)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        rule.onNodeWithTag("air-schedule-past", useUnmergedTree = true).assert(isFocused())
        rule.onNodeWithText("补这一集", useUnmergedTree = true).assertExists()
        rule.savePreview("air-schedule-past-open")

        // 缺集那一行整行就是「补这一集」（第 7 集在第 4 天：第 1–2、3–4、5–6、7–8）
        repeat(4) { rule.press(KeyEvent.KEYCODE_DPAD_DOWN) }
        rule.onNodeWithTag("air-day-${today.plusDays(-3).iso}", useUnmergedTree = true).assert(isFocused())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertTrue(env.transport.requested.contains("/subscriptions/5/missing-resource-searches"))
        rule.onNodeWithText("1 个缺口已重新排队，正在搜索", useUnmergedTree = true).assertIsDisplayed()

        // 往左到「补第 7 集」
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        rule.onNodeWithTag("air-schedule-find", useUnmergedTree = true).assert(isFocused())
        // 往右回到刚才那一行
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        rule.onNodeWithTag("air-day-${today.plusDays(-3).iso}", useUnmergedTree = true).assert(isFocused())

        // 返回：关面板，焦点回到入口条
        rule.press(KeyEvent.KEYCODE_BACK, settleMs = 500)
        rule.onNodeWithTag("air-schedule-sheet", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithTag("air-schedule-summary", useUnmergedTree = true).assert(isFocused())
        // 再往下是分集横排
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 500)
        rule.onNodeWithTag("ep:6", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))
    }

    @Test
    fun unairedEpisodesAreNotMissing() {
        open(mapOf("/libraries/1/items/7/episodes" to SeasonEpisodesView(1, showEpisodes(), resumeEpisode = 6, airSchedule = subscribedSchedule())))
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 800)
        // 从第 6 集往右走到今天、明天、真缺的第 7 集
        fun textsOf(number: Int) = rule.onAllNodes(hasText("缺集") and hasAnyAncestor(hasTestTag("ep:$number")), useUnmergedTree = true)
            .fetchSemanticsNodes().size
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("真缺的第 7 集标缺集", 1, textsOf(7))
        repeat(7) { rule.press(KeyEvent.KEYCODE_DPAD_RIGHT) }
        rule.onNodeWithTag("ep:14", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))
        rule.savePreview("air-schedule-cards")
        assertEquals("今天播出的不标缺集", 0, textsOf(13))
        // 今天播出的两集：第 13 集在下载、第 14 集在等资源
        assertEquals(2, rule.onAllNodes(hasText("今天播出"), useUnmergedTree = true).fetchSemanticsNodes().size)
        rule.onNode(hasText("下载中") and hasAnyAncestor(hasTestTag("ep:13")), useUnmergedTree = true).assertExists()
        rule.onNode(hasText("等待资源") and hasAnyAncestor(hasTestTag("ep:14")), useUnmergedTree = true).assertExists()
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("明天播出的不标缺集", 0, textsOf(16))
        assertTrue(rule.onAllNodes(hasText("明天"), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty())
    }

    @Test
    fun subscribeConfirmsTheDefaultsThenTheCalendarUpdates() {
        var subscribed = false
        val unsubscribed = SeasonAirScheduleView(
            today = today.iso,
            region = "US",
            weekdays = listOf(3),
            lastAirDate = today.plusDays(14).iso,
        )
        val episodes = listOf(
            EpisodeView(episodeNumber = 1, owned = true, airDate = today.plusDays(-7).iso),
            EpisodeView(episodeNumber = 2, airDate = today.plusDays(7).iso),
            EpisodeView(episodeNumber = 3, airDate = today.plusDays(14).iso),
        )
        val prepared = PrepareView(
            status = "ready",
            media = MediaBrief(mediaItemId = 7, kind = "tv", tmdbId = 777, title = "Harbor Lights", status = "Returning Series"),
            seasons = listOf(SeasonOverview(seasonNumber = 1, name = "第 1 季", airedCount = 1, ownedCount = 1)),
            smart = SmartPlanView(configured = true, profileRevision = 1, memoryRevision = 2, canEdit = true, qualityLabel = "优先 4K WEB-DL", waitLabel = "最多等 1 天"),
        )
        val env = open(
            mapOf(
                "/libraries/1/items/7/episodes" to Responder {
                    SeasonEpisodesView(1, episodes, airSchedule = if (subscribed) unsubscribed.copy(subscriptionId = 9) else unsubscribed)
                },
                "/subscriptions/title-preview" to prepared,
                "/subscriptions" to Responder {
                    subscribed = true
                    SubscriptionCreateView()
                },
            ),
        )
        focusStrip()
        // 下一集 7 天后，日期标地区
        rule.onNodeWithText("11月12日（美国）", useUnmergedTree = true).assertIsDisplayed()
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 500)
        rule.onNodeWithText("播出日期为美国当地日期", useUnmergedTree = true).assertIsDisplayed()
        // 没有缺集入口
        rule.onNodeWithTag("air-schedule-find", useUnmergedTree = true).assertDoesNotExist()

        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        rule.onNodeWithTag("air-schedule-subscribe", useUnmergedTree = true).assert(isFocused())
        assertEquals("订阅追更", rule.focusedText())
        // 第一下：读预检，列出默认值，焦点还在同一颗按钮上（变成「确认订阅」）
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals("确认订阅", rule.focusedText())
        rule.onNodeWithText("优先 4K WEB-DL", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("第 1 季", useUnmergedTree = true, substring = false).assertExists()
        rule.savePreview("air-schedule-subscribe-confirm")
        assertFalse("确认之前不建订阅", env.transport.requested.contains("/subscriptions"))

        // 返回先退回「订阅追更」，不关面板
        rule.press(KeyEvent.KEYCODE_BACK)
        rule.onNodeWithTag("air-schedule-sheet", useUnmergedTree = true).assertExists()
        assertEquals("订阅追更", rule.focusedText())

        // 再来一遍，这次确认：订阅建好，日历刷新，按钮收起，焦点回到时间线
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 800)
        assertTrue(env.transport.requested.contains("/subscriptions"))
        rule.onNodeWithTag("air-schedule-subscribe", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithText("播出日期来自 TMDB · 入库时间是订阅按站点发布规律推算的", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithTag("air-day-${today.plusDays(7).iso}", useUnmergedTree = true).assert(isFocused())
    }

    @Test
    fun smartSetupMissingExplainsWhereToGo() {
        open(
            mapOf(
                "/libraries/1/items/7/episodes" to SeasonEpisodesView(
                    1,
                    listOf(EpisodeView(episodeNumber = 1, airDate = today.plusDays(1).iso)),
                    airSchedule = SeasonAirScheduleView(today = today.iso, weekdays = listOf(4)),
                ),
                "/subscriptions/title-preview" to PrepareView(
                    status = "ready",
                    media = MediaBrief(mediaItemId = 7, kind = "tv", tmdbId = 777, title = "x"),
                    smart = SmartPlanView(configured = false, canEdit = true),
                ),
            ),
        )
        focusStrip()
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 500)
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        rule.onNodeWithText("首次订阅要先在手机或网页上完成智能设置", useUnmergedTree = true).assertIsDisplayed()
        assertEquals("订阅追更", rule.focusedText())
    }

    /** 两季长剧：选季 → 入口条 → 集段页签 → 横排，上下都一格一格走，不越过去回首屏 */
    @Test
    fun longSeasonWalksThroughEveryHeaderRow() {
        val long = (1L..120L).map { number ->
            EpisodeView(episodeNumber = number, name = "第 $number 集的标题", owned = number <= 60, airDate = today.plusDays((number - 61).toInt()).iso)
        }
        val schedule = SeasonAirScheduleView(today = today.iso, weekdays = (0L..6L).toList(), lastAirDate = today.plusDays(59).iso, subscriptionId = 3)
        open(
            mapOf("/libraries/1/items/7/episodes" to SeasonEpisodesView(1, long, resumeEpisode = 40, airSchedule = schedule)),
            seasons = listOf(1, 2),
        )
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 800)
        rule.onNodeWithTag("ep:40", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 500)
        rule.onNodeWithTag("range-tab:0", useUnmergedTree = true).assert(isFocused())
        rule.savePreview("air-schedule-long-season")
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 500)
        rule.onNodeWithTag("air-schedule-summary", useUnmergedTree = true).assert(isFocused())
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 500)
        rule.onNodeWithTag("season-tab:1", useUnmergedTree = true).assert(isFocused())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 500)
        rule.onNodeWithTag("air-schedule-summary", useUnmergedTree = true).assert(isFocused())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 500)
        rule.onNodeWithTag("range-tab:0", useUnmergedTree = true).assert(isFocused())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 500)
        rule.onNodeWithTag("ep:40", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))
        // 选季往上回首屏
        repeat(3) { rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 500) }
        rule.onNodeWithTag("season-tab:1", useUnmergedTree = true).assert(isFocused())
        rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 800)
        assertTrue("回到首屏：${rule.focusedText()}", rule.focusedText().orEmpty().contains("播放"))
    }

    @Test
    fun memberWithoutSubscribePermissionSeesNoActions() {
        val member = SessionView(username = "x", nickname = "小雨", role = "member", capabilities = SessionCapabilities(allowSubscribe = false))
        open(
            mapOf("/libraries/1/items/7/episodes" to SeasonEpisodesView(1, showEpisodes(), resumeEpisode = 6, airSchedule = subscribedSchedule().copy(subscriptionId = null, missingEpisodes = emptyList()))),
            account = member,
        )
        focusStrip()
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 500)
        rule.onNodeWithTag("air-schedule-sheet", useUnmergedTree = true).assertExists()
        rule.onNodeWithTag("air-schedule-subscribe", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithTag("air-schedule-find", useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun noScheduleNoEntry() {
        open(mapOf("/libraries/1/items/7/episodes" to SeasonEpisodesView(1, showEpisodes().map { it.copy(owned = true) })))
        rule.onNodeWithTag("air-schedule-summary", useUnmergedTree = true).assertDoesNotExist()
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 800)
        rule.onNodeWithTag("ep:1", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))
    }
}
