package io.movieclaw.androidtv.ui.detail

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.pt
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** 分集卡下面的字：没有真名（空或 TMDB 的「第 N 集」占位名）只写一次「第 N 集」，有真名写小字集号 + 集名 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class EpisodeCardTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun episodeNumberShowsOnceWithoutARealTitle() {
        val cards = listOf(
            EpisodeView(episodeNumber = 1, name = "第 1 集", owned = true, overview = "TMDB 没有中文集名时给的占位名。"),
            EpisodeView(episodeNumber = 2, name = null, owned = true, overview = "没有集名。"),
            EpisodeView(episodeNumber = 3, name = "归来", owned = true, overview = "有真名。"),
        )
        rule.setTvContent(emptyMap()) {
            Row(Modifier.fillMaxSize().background(McColors.Page).padding(McMetrics.Edge, 80.pt), horizontalArrangement = Arrangement.spacedBy(McMetrics.CardSpacing)) {
                cards.forEach { EpisodeCard(it, 24, onClick = {}, onLongClick = {}, modifier = Modifier.testTag("ep:${it.episodeNumber}")) }
            }
        }
        rule.waitForIdle()
        fun count(number: Int, text: String) =
            rule.onAllNodes(hasText(text) and hasAnyAncestor(hasTestTag("ep:$number")), useUnmergedTree = true).fetchSemanticsNodes().size
        // 剧照没图时中间的占位字也是「第 N 集」，算上它卡里一共两处（原来是三处：小字、标题各一）
        assertEquals(2, count(1, "第 1 集"))
        assertEquals(2, count(2, "第 2 集"))
        assertEquals(1, count(3, "归来"))
        assertEquals(2, count(3, "第 3 集"))
        rule.savePreview("detail-episode-cards")
    }
}
