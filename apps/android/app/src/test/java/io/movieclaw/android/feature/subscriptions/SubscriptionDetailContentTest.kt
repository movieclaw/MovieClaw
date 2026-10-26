package io.movieclaw.android.feature.subscriptions

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import io.movieclaw.android.core.designsystem.MovieClawTheme
import io.movieclaw.android.core.model.MediaBrief
import io.movieclaw.android.core.model.ProgressView
import io.movieclaw.android.core.model.SubActivityView
import io.movieclaw.android.core.model.SubscriptionDownloadView
import io.movieclaw.android.core.model.SubscriptionView
import io.movieclaw.android.core.model.WantedView
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** 订阅详情新版面：用户截图里《仙逆》的数据形态（158/200、3 集在下载、39 集缺失、长排查记录） */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = io.movieclaw.android.MovieClawApp::class, qualifiers = "w400dp-h2400dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SubscriptionDetailContentTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val sub = SubscriptionView(
        id = 3,
        media = MediaBrief(kind = "tv", title = "仙逆", year = 2023),
        status = "active",
        selectedSeasons = listOf(1),
        followFuture = false,
        ruleSetId = 3,
        progress = ProgressView(total = 200, wanted = 39, grabbed = 3, downloaded = 0, imported = 158),
        createdAt = "2026-10-06T15:50:12",
    )
    private val wanted = (1..200).map { ep ->
        when {
            ep <= 158 -> WantedView(id = ep.toLong(), seasonNumber = 1, episodeNumber = ep, status = "imported", importedAt = "2026-10-07T00:00:00")
            ep in 159..161 -> WantedView(id = ep.toLong(), seasonNumber = 1, episodeNumber = ep, status = "grabbed", grabbedAt = "2026-10-10T23:00:00", infoHash = "h$ep")
            else -> WantedView(id = ep.toLong(), seasonNumber = 1, episodeNumber = ep, status = "wanted")
        }
    }
    private val downloads = (159..161).associate { ep ->
        "h$ep" to SubscriptionDownloadView(infoHash = "h$ep", state = "downloading", progress = 0.38, dlspeedBytes = 2_726_297, etaSeconds = 1200)
    }
    private val activities = (1..9).map { i ->
        SubActivityView(
            id = i.toLong(),
            type = if (i % 2 == 1) "subscription.search" else "subscription.grab",
            message = if (i % 2 == 1) "搜索《仙逆》（关键词「Renegade Immortal」154 条 /「仙逆」234 条）：4 个站点返回 235 个结果，身份命中 7，规则拒绝 0，投递覆盖 3 个单元；本组已全部安排"
            else "已投递 S1E${158 + i}（2160p · 做种 42）",
            createdAt = "2026-10-1${i % 2}T23:5$i:00",
        )
    }

    @Test fun rendersRedesignedDetailAndActionsWork() {
        var searched = 0
        var more = 0
        compose.setContent {
            MovieClawTheme {
                SubscriptionDetailContent(
                    sub = sub, wanted = wanted, activities = activities, downloads = downloads,
                    origin = null, busy = false, showSearchNow = true, showManual = true, showMore = true,
                    onBack = {}, onSearchNow = { searched++ }, onManual = {}, onMore = { more++ },
                )
            }
        }
        compose.onNodeWithText("158").assertIsDisplayed()
        compose.onNodeWithText("已入库 158").assertIsDisplayed()
        compose.onNodeWithText("缺失 39").assertIsDisplayed()
        compose.onNodeWithText("仙逆").assertExists()
        compose.onNodeWithText("立即搜索").performClick()
        compose.onNodeWithContentDescription("更多").performClick()
        assertEquals(1, searched)
        assertEquals(1, more)
        // 季卡与下载行
        compose.onNodeWithText("缺 39 集").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("E159").assertExists()
        // 排查记录默认 4 条，可展开
        compose.onNodeWithText("查看全部 9 条").performScrollTo().performClick()
        compose.onNodeWithText("收起").assertExists()
        snapshot("subscription-detail-redesign")
    }

    private fun snapshot(name: String) {
        compose.waitForIdle()
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/$name.png").outputStream().use {
            val view = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
