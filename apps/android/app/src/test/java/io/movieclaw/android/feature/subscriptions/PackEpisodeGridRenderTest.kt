package io.movieclaw.android.feature.subscriptions

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import io.movieclaw.android.core.designsystem.MovieClawTheme
import io.movieclaw.android.core.model.DownloadUnitView
import io.movieclaw.android.core.model.MediaBrief
import io.movieclaw.android.core.model.ProgressView
import io.movieclaw.android.core.model.SubscriptionDownloadView
import io.movieclaw.android.core.model.SubscriptionView
import io.movieclaw.android.core.model.WantedView
import java.io.File
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** 《牧神记》形态：E84–E102 同一个全集包，部分集已下完——包行下面一格一集 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = io.movieclaw.android.MovieClawApp::class, qualifiers = "w400dp-h1600dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PackEpisodeGridRenderTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun packRowShowsEachEpisodesProgress() {
        val eps = 84..102
        val wanted = eps.map { WantedView(id = it.toLong(), seasonNumber = 1, episodeNumber = it, status = "grabbed", grabbedAt = "2026-10-11T03:14:00", infoHash = "pack") }
        val snap = SubscriptionDownloadView(
            infoHash = "pack", state = "downloading", progress = 0.34, dlspeedBytes = 3_400_000, etaSeconds = 5400,
            units = eps.map { DownloadUnitView(1, it, when { it <= 89 -> 1.0; it == 90 -> 0.45; else -> 0.0 }) },
        )
        val sub = SubscriptionView(
            id = 17, media = MediaBrief(kind = "tv", title = "牧神记", year = 2024), status = "active",
            selectedSeasons = listOf(1), followFuture = true, ruleSetId = 1,
            progress = ProgressView(total = 19, wanted = 0, grabbed = 19, imported = 0), createdAt = "2026-10-11T03:14:00",
        )
        compose.setContent {
            MovieClawTheme {
                SubscriptionDetailContent(
                    sub = sub, wanted = wanted, activities = emptyList(), downloads = mapOf("pack" to snap),
                    origin = null, busy = false, showSearchNow = false, showManual = false, showMore = true,
                    onBack = {}, onSearchNow = {}, onManual = {}, onMore = {},
                )
            }
        }
        compose.onNodeWithText("E84–E102 · 19 集").performScrollTo()
        compose.onNodeWithText("E90").assertExists()
        compose.onNodeWithText("45%").assertExists()
        compose.waitForIdle()
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/pack-episode-grid.png").outputStream().use {
            val view = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
