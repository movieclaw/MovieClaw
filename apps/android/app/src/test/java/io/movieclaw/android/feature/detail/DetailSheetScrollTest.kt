package io.movieclaw.android.feature.detail

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.Dp
import io.movieclaw.android.core.designsystem.MovieClawTheme
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.model.SeasonAirSchedule
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.shadows.ShadowDialog
import org.robolectric.annotation.Config

/**
 * 详情页两张可滚动底部面板（播出日历、全部分集）的手势（issue #1103 / #1117）：
 * 在列表上下拉只滚列表、不把面板拖走；关面板仍可拖列表外的面板头部。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = "w400dp-h800dp-xhdpi")
class DetailSheetScrollTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private var open by mutableStateOf(true)

    private val today = LocalDate.of(2026, 10, 30)

    private fun setAirSheet(onSubscribe: (() -> Unit)? = null, fromCard: Boolean = false) {
        if (fromCard) open = false
        // 40 集周更，全部待播：列表远高于面板的 560dp 上限
        val episodes = (1..40).map { EpisodeView(episodeNumber = it, airDate = today.plusWeeks(it - 1L).toString()) }
        val schedule = SeasonAirSchedule(
            today = today.toString(),
            weekdays = listOf(today.dayOfWeek.value - 1),
            lastAirDate = episodes.last().airDate,
        )
        compose.setContent {
            MovieClawTheme {
                if (fromCard) AirScheduleSummary(episodes, schedule, onOpen = { open = true })
                if (open) {
                    AirScheduleSheet(
                        title = "测试剧",
                        seasonLabel = "第 1 季",
                        episodes = episodes,
                        schedule = schedule,
                        canSubscribe = false,
                        searching = false,
                        onFindMissing = {},
                        onSubscribe = onSubscribe,
                        onDismiss = { open = false },
                    )
                }
            }
        }
        compose.waitForIdle()
    }

    private fun setEpisodesSheet() {
        // 120 集分三段，第一段 50 集 5 列 10 行，宫格高于 460dp 上限
        val episodes = (1..120).map { EpisodeView(episodeNumber = it) }
        compose.setContent {
            MovieClawTheme {
                if (open) {
                    AllEpisodesSheet(
                        episodes = episodes,
                        ranges = EpisodeRanges.of(episodes),
                        anchor = null,
                        selected = null,
                        onPick = {},
                        onDismiss = { open = false },
                    )
                }
            }
        }
        compose.waitForIdle()
    }

    private fun top(tag: String): Dp = compose.onNodeWithTag(tag, useUnmergedTree = true).getUnclippedBoundsInRoot().top

    private fun pullDown(listTag: String, message: String) {
        compose.onNodeWithTag(listTag, useUnmergedTree = true).performTouchInput { swipeDown() }
        compose.waitForIdle()
        assertTrue(message, open)
    }

    /** 列表在顶部时下拉：面板不关、不下移 */
    private fun assertPullAtTopKeepsSheet(sheetTag: String, listTag: String) {
        val before = top(sheetTag)
        repeat(3) { pullDown(listTag, "列表在顶部下拉不应关闭面板") }
        assertEquals("面板不应被拖动", before.value, top(sheetTag).value, 0.5f)
    }

    /** 先上滑再滑回顶部继续下拉：面板不关、回到原位不跳 */
    private fun assertScrollBackKeepsSheet(sheetTag: String, listTag: String) {
        val before = top(sheetTag)
        compose.onNodeWithTag(listTag, useUnmergedTree = true).performTouchInput { swipeUp() }
        compose.waitForIdle()
        repeat(4) { pullDown(listTag, "滑回顶部继续下拉不应关闭面板") }
        assertEquals("面板位置不应跳变", before.value, top(sheetTag).value, 0.5f)
    }

    @Test fun airSheetPullAtTopKeepsSheetOpen() {
        setAirSheet()
        assertPullAtTopKeepsSheet("air-schedule-sheet", "air-schedule-list")
    }

    @Test fun airSheetScrollBackToTopKeepsSheetStill() {
        setAirSheet()
        assertScrollBackKeepsSheet("air-schedule-sheet", "air-schedule-list")
    }

    @Test fun airSheetDividerPullKeepsSheetStill() {
        setAirSheet(onSubscribe = {})
        val before = top("air-schedule-sheet")
        // 列表上方 1px 的留白，不经过 LazyColumn 的手势处理。
        compose.onNodeWithTag("air-schedule-list").performTouchInput {
            down(Offset(centerX, -1f))
            moveBy(Offset(0f, 200f), delayMillis = 500)
        }
        compose.waitForIdle()
        assertEquals("拖动过程中面板不应下移", before.value, top("air-schedule-sheet").value, 0.5f)
        compose.onNodeWithTag("air-schedule-list").performTouchInput { up() }
        compose.waitForIdle()
        assertTrue(open)
    }

    @Test fun airSheetSubscribePullKeepsButtonStillAndClickable() {
        var subscriptions = 0
        setAirSheet(onSubscribe = { subscriptions++ })
        val sheetBefore = top("air-schedule-sheet")
        val buttonBefore = top("air-schedule-subscribe")
        compose.onNodeWithTag("air-schedule-subscribe").performTouchInput {
            down(center)
            moveBy(Offset(0f, 200f), delayMillis = 500)
        }
        compose.waitForIdle()
        assertEquals("拖动过程中按钮不应下移", buttonBefore.value, top("air-schedule-subscribe").value, 0.5f)
        compose.onNodeWithTag("air-schedule-subscribe").performTouchInput { up() }
        compose.waitForIdle()
        assertTrue("订阅区下拉不应关闭面板", open)
        assertEquals(sheetBefore.value, top("air-schedule-sheet").value, 0.5f)
        assertEquals("拖动不应误订阅", 0, subscriptions)
        compose.onNodeWithTag("air-schedule-subscribe").performClick()
        assertEquals(1, subscriptions)
    }

    /** 真实摘要入口 → 浏览日历 → 固定区拖动 → 订阅回调 → 再打开并返回关闭。 */
    @Test fun calendarToSubscribeUserFlow() {
        var subscribed = false
        setAirSheet(onSubscribe = { subscribed = true; open = false }, fromCard = true)
        compose.onNodeWithTag("air-schedule-summary").performClick()
        compose.waitForIdle()
        assertScrollBackKeepsSheet("air-schedule-sheet", "air-schedule-list")
        compose.onNodeWithTag("air-schedule-subscribe").performTouchInput {
            swipeDown(endY = centerY + 300f)
        }
        compose.waitForIdle()
        assertTrue("浏览后订阅入口应仍可用", open)
        compose.onNodeWithTag("air-schedule-subscribe").performClick()
        compose.waitForIdle()
        assertTrue(subscribed)
        compose.onNodeWithTag("air-schedule-sheet").assertDoesNotExist()
        compose.onNodeWithTag("air-schedule-summary").performClick()
        compose.waitForIdle()
        compose.runOnIdle { ShadowDialog.getLatestDialog().onBackPressed() }
        compose.waitForIdle()
        compose.onNodeWithTag("air-schedule-sheet").assertDoesNotExist()
    }

    @Test fun airSheetHeaderDragStillDismisses() {
        setAirSheet()
        compose.onNodeWithText("播出日历").performTouchInput { swipeDown(endY = centerY + 1500f) }
        compose.waitForIdle()
        assertFalse("拖面板头部仍应能关闭", open)
    }

    @Test fun episodesSheetPullAtTopKeepsSheetOpen() {
        setEpisodesSheet()
        assertPullAtTopKeepsSheet("ep-sheet", "ep-sheet-grid")
    }

    @Test fun episodesSheetScrollBackToTopKeepsSheetStill() {
        setEpisodesSheet()
        assertScrollBackKeepsSheet("ep-sheet", "ep-sheet-grid")
    }

    @Test fun episodesSheetRangeChipsPullKeepsSheetStill() {
        setEpisodesSheet()
        val before = top("ep-sheet")
        compose.onNodeWithTag("ep-sheet-chip-1-50", useUnmergedTree = true).performTouchInput {
            down(center)
            moveBy(Offset(0f, 200f), delayMillis = 500)
        }
        compose.waitForIdle()
        assertEquals("分段选择区下拉不应移动面板", before.value, top("ep-sheet").value, 0.5f)
        compose.onNodeWithTag("ep-sheet-chip-1-50", useUnmergedTree = true).performTouchInput { up() }
        compose.waitForIdle()
        assertTrue(open)
        compose.onNodeWithTag("ep-sheet-chip-51-100", useUnmergedTree = true).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("ep-cell-51", useUnmergedTree = true).assertExists()
    }

    @Test fun episodesSheetHeaderDragStillDismisses() {
        setEpisodesSheet()
        compose.onNodeWithText("全部分集").performTouchInput { swipeDown(endY = centerY + 1500f) }
        compose.waitForIdle()
        assertFalse("拖面板头部仍应能关闭", open)
    }
}
