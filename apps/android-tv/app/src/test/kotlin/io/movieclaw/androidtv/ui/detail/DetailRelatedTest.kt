package io.movieclaw.androidtv.ui.detail

import android.app.Application
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import io.movieclaw.androidtv.core.model.generated.ActorView
import io.movieclaw.androidtv.core.model.generated.CollectionSeriesView
import io.movieclaw.androidtv.core.model.generated.DirectorView
import io.movieclaw.androidtv.core.model.generated.LibraryItemDetailView
import io.movieclaw.androidtv.core.model.generated.LibraryItemView
import io.movieclaw.androidtv.core.model.generated.LocalMetaView
import io.movieclaw.androidtv.core.model.generated.SeriesPartView
import io.movieclaw.androidtv.ui.FakeTransport
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.Router
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
 * 电影详情的下半截（同 Apple TV，2026-10-12 用户定）：演职员 → 相似推荐 → 系列。
 * 有系列一行时相似推荐排除同系列的片（exclude_series=true）；系列拉不到上游档案时再拉一次不排除的，续集照样出；
 * 系列里库中没有的那部置灰、不能选中。真的 ItemDetailScreen，假服务端给条目、系列与相似推荐。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class DetailRelatedTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    private val similarPath = "/libraries/1/items/13/similar"

    /** 《沙丘》：导演 + 两位主演，属于系列合集 5 */
    private val dune = LibraryItemDetailView(
        mediaItemId = 13, kind = "movie", title = "沙丘", year = 2021, seriesCollectionId = 5,
        localMeta = LocalMetaView(
            directorCredits = listOf(DirectorView(name = "丹尼斯·维伦纽瓦", tmdbPersonId = 137427)),
            actors = listOf(ActorView("提莫西·查拉梅", "保罗·厄崔迪", null, 1190668), ActorView("丽贝卡·弗格森", "杰西卡夫人", null, 933238)),
        ),
    )

    /** 系列按上映顺序：本片、库里没有的《沙丘：救世主》（夹在中间）、库里有的《沙丘2》 */
    private fun series(available: Boolean) = CollectionSeriesView(
        seriesName = "沙丘（系列）", ownedCount = 2, total = 3, available = available,
        parts = listOf(
            SeriesPartView(tmdbId = 438631, title = "沙丘", releaseDate = "2021-09-15", mediaItemId = 13),
            SeriesPartView(tmdbId = 1170608, title = "沙丘：救世主", releaseDate = "2026-12-16"),
            SeriesPartView(tmdbId = 693134, title = "沙丘2", releaseDate = "2024-02-27", mediaItemId = 12),
        ),
    )

    private fun similarItem(id: Long, title: String, year: Long, library: Long? = 1) =
        LibraryItemView(mediaItemId = id, kind = "movie", libraryId = library, title = title, year = year)

    private fun open(routes: Map<String, Any>, detail: LibraryItemDetailView = dune): FakeTransport {
        val env = rule.setTvContent(mapOf("/libraries/1/items/13" to detail) + routes) {
            CompositionLocalProvider(LocalRouter provides Router()) { ItemDetailScreen(1, 13) }
        }
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        return env.transport
    }

    /** 行在整页里的上沿（下半截在屏幕外时可见部分被裁掉，按未裁切的算） */
    private fun top(tag: String) = rule.onNodeWithTag(tag, useUnmergedTree = true).getUnclippedBoundsInRoot().top

    private fun assertFocused(tag: String) = rule.onNodeWithTag(tag, useUnmergedTree = true).assert(hasAnyDescendant(isFocused()))

    private fun similarQueries(transport: FakeTransport) = transport.queries.filter { it.first == similarPath }.map { it.second }

    @Test
    fun castThenSimilarThenSeries() {
        // 服务端按 exclude_series 已排掉《沙丘2》；假服务端不看参数，所以另外核对请求带了排除
        val transport = open(
            mapOf(
                "/collections/5/series" to series(available = true),
                similarPath to listOf(similarItem(20, "银翼杀手2049", 2017), similarItem(21, "降临", 2016, library = 2)),
            ),
        )
        assertEquals(listOf(listOf("exclude_series" to "true")), similarQueries(transport))
        assertTrue("演职员在相似推荐上面", top("person:0") < top("similar:20"))
        assertTrue("相似推荐在系列上面", top("similar:20") < top("series:438631"))
        rule.onNodeWithTag("similar:12", useUnmergedTree = true).assertDoesNotExist()
        rule.onNodeWithText("相似推荐").assertExists()

        // 电影往下第一行是演职员（不再先露系列），再往下相似推荐落在第一张，再往下系列落在「本片」
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 1_000)
        assertFocused("person:0")
        rule.savePreview("detail-related-cast")
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 1_000)
        assertFocused("similar:20")
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 1_000)
        assertFocused("series:438631")
        rule.savePreview("detail-related-series")
    }

    @Test
    fun missingSeriesPartIsNotFocusable() {
        open(mapOf("/collections/5/series" to series(available = true), similarPath to listOf(similarItem(20, "银翼杀手2049", 2017))))
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 1_000)
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 1_000)
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 1_000)
        assertFocused("series:438631")
        // 往右越过置灰的《沙丘：救世主》，直接落到《沙丘2》
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertFocused("series:693134")
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertFocused("series:438631")
        rule.onNodeWithTag("series:1170608", useUnmergedTree = true).assert(!hasAnyDescendant(isFocused()))
    }

    @Test
    fun unavailableSeriesRefetchesSimilarWithSequels() {
        // 本地 NFO 定的系列没有上游档案：系列一行不出，相似推荐再拉一次不排除的，续集《沙丘2》在相似推荐里
        val transport = open(
            mapOf(
                "/collections/5/series" to series(available = false),
                similarPath to listOf(similarItem(12, "沙丘2", 2024), similarItem(20, "银翼杀手2049", 2017)),
            ),
        )
        assertEquals(listOf(listOf("exclude_series" to "true"), emptyList()), similarQueries(transport))
        rule.onNodeWithTag("similar:12", useUnmergedTree = true).assertExists()
        rule.onNodeWithTag("series:438631", useUnmergedTree = true).assertDoesNotExist()
        assertTrue("演职员在相似推荐上面", top("person:0") < top("similar:12"))
    }

    @Test
    fun failedSeriesFallsBackToUnfilteredSimilar() {
        // 系列请求失败（假服务端没有这条路由）：同「拉不到上游档案」，回退成不排除的
        val transport = open(mapOf(similarPath to listOf(similarItem(20, "银翼杀手2049", 2017))))
        assertTrue(transport.requested.contains("/collections/5/series"))
        assertEquals(listOf(listOf("exclude_series" to "true"), emptyList()), similarQueries(transport))
    }

    @Test
    fun movieOutsideAnySeriesFetchesSimilarOnce() {
        val transport = open(mapOf(similarPath to listOf(similarItem(20, "银翼杀手2049", 2017))), dune.copy(seriesCollectionId = null))
        assertEquals(listOf(emptyList<Pair<String, String>>()), similarQueries(transport))
        assertFalse(transport.requested.any { it.startsWith("/collections/") })
        rule.onNodeWithTag("similar:20", useUnmergedTree = true).assertExists()
    }
}
