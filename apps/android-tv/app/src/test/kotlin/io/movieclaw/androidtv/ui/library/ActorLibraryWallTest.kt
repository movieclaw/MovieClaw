package io.movieclaw.androidtv.ui.library

import android.app.Application
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import io.movieclaw.androidtv.core.session.LocalStore
import io.movieclaw.androidtv.ui.Responder
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.LaunchArgs
import io.movieclaw.androidtv.ui.TvEnv
import io.movieclaw.androidtv.ui.detail.ItemDetailScreen
import io.movieclaw.androidtv.ui.focusedText
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.MainShell
import io.movieclaw.androidtv.ui.shell.Route
import io.movieclaw.androidtv.ui.shell.Router
import io.movieclaw.core.model.generated.ActorView
import io.movieclaw.core.model.generated.LibraryFacetsView
import io.movieclaw.core.model.generated.LibraryItemDetailView
import io.movieclaw.core.model.generated.LibraryItemView
import io.movieclaw.core.model.generated.LibraryStats
import io.movieclaw.core.model.generated.LibraryView
import io.movieclaw.core.model.generated.LocalMetaView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * 本地/NFO 库点演员（#1193 的电视版）：详情页演职员一行里没有影人 id 的演员按确认 → 同库按演员名筛的海报墙；
 * 墙上标题旁写「演员：姓名」，「排序与筛选」里能摘掉它，摘掉后回到整库。真的 ItemDetailScreen / LibraryWallScreen，
 * 假服务端按演员名现算（去首尾空白、不分大小写、整名相等，同后端口径）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ActorLibraryWallTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    /** 标题 → 演员表 */
    private val cast = linkedMapOf(
        "甲" to listOf("张三", "Alice Smith"),
        "乙" to listOf(" 张三 ", "李四"),
        "丙" to listOf("ALICE SMITH"),
        "丁" to listOf("张三丰"),
        "戊" to emptyList(),
    )
    private val catalog = cast.keys.mapIndexed { i, title -> LibraryItemView(mediaItemId = i + 1L, libraryId = 1, title = title, year = 2020) }

    private fun matching(actor: String?) = catalog.filter { item ->
        actor == null || cast.getValue(item.title).any { it.trim().equals(actor.trim(), ignoreCase = true) }
    }

    private fun routes(): Map<String, Any> = mapOf(
        "/libraries" to listOf(LibraryView(id = 1, name = "本地库", kind = "video", viewerAccess = true, stats = LibraryStats(itemCount = catalog.size.toLong()))),
        "/libraries/1/items" to Responder { q -> matching(q["actor"]).drop(q["offset"]?.toInt() ?: 0) },
        "/libraries/1/facets" to Responder { q -> LibraryFacetsView(total = matching(q["actor"]).size.toLong()) },
        "/libraries/1/items/1" to LibraryItemDetailView(
            mediaItemId = 1,
            kind = "video",
            source = "local",
            title = "甲",
            year = 2020,
            localMeta = LocalMetaView(
                directors = listOf("王导"),
                actors = listOf(ActorView(" 张三 ", "主角"), ActorView("Alice Smith", "Guest", tmdbPersonId = 42)),
            ),
        ),
    )

    @Test
    fun localActorOpensTheLibraryWallFilteredByName() {
        val router = Router()
        rule.setTvContent(routes()) {
            CompositionLocalProvider(LocalRouter provides router) { ItemDetailScreen(1, 1) }
        }
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        // 遥控器往下：电影没有分集，下半截第一行就是演职员，焦点落在第一格（导演）
        var guard = 0
        while (rule.focusedText()?.contains("王导") != true && guard++ < 6) rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 800)
        assertEquals(true, rule.focusedText()?.contains("王导"))
        // 导演（没有影人 id）：确认没反应
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertNull(router.stack.lastOrNull())
        // 没有影人 id 的演员：同库按演员名筛（去首尾空白）
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals(true, rule.focusedText()?.contains("张三"))
        rule.savePreview("tv-detail-local-actor")
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(Route.Library(1, actor = "张三"), router.stack.last())
        // 有影人 id 的演员：影人页照旧
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals(Route.Person(42, "Alice Smith", null, 1), router.stack.last())
    }

    private fun openWall(actor: String?): TvEnv {
        LocalStore(rule.activity.application).putString(WallLogic.sortKey(1), WallLogic.encodeSort(WallSort("title")))
        val env = rule.setTvContent(routes()) {
            CompositionLocalProvider(LocalRouter provides Router()) { LibraryWallScreen(1, actor) }
        }
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        return env
    }

    private fun TvEnv.lastQuery(path: String) = transport.queries.last { it.first == path }.second.toMap()

    @Test
    fun actorConditionShowsAndCanBeRemoved() {
        val env = openWall("张三")
        // 墙、计数都带着演员名；标题旁写条件与部数
        assertEquals("张三", env.lastQuery("/libraries/1/items")["actor"])
        assertEquals("张三", env.lastQuery("/libraries/1/facets")["actor"])
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("演员：张三 · 2 部"))
        rule.onNodeWithTag("poster:1", useUnmergedTree = true).assertExists()
        rule.onNodeWithTag("poster:2", useUnmergedTree = true).assertExists()
        rule.onNodeWithTag("poster:4", useUnmergedTree = true).assertDoesNotExist()
        rule.savePreview("tv-wall-actor-filter")

        // 「排序与筛选」→「移除演员：张三」
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("排序与筛选 · A–Z", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        // 四档排序、未看完、只看没看过的，接着就是「筛选」一节的第一行
        repeat(6) { rule.press(KeyEvent.KEYCODE_DPAD_DOWN) }
        assertEquals("移除演员：张三", rule.focusedText())
        rule.savePreview("tv-wall-actor-menu")
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)

        assertNull(env.lastQuery("/libraries/1/items")["actor"])
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("5 部"))
        rule.onNodeWithTag("poster:4", useUnmergedTree = true).assertExists()
    }

    @Test
    fun plainLibraryWallSendsNoActor() {
        val env = openWall(null)
        assertNull(env.lastQuery("/libraries/1/items")["actor"])
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("5 部"))
    }

    private fun pressUntil(key: Int, text: String, max: Int = 10) {
        var guard = 0
        while (rule.focusedText()?.contains(text) != true && guard++ < max) rule.press(key, settleMs = 500)
        assertEquals(true, rule.focusedText()?.contains(text))
    }

    /**
     * 真的 MainShell：详情 → 演员墙 → 摘掉演员 → 侧边栏切到「搜索」→ 切回「首页」→ 仍是整库。
     * （手机平板上同样的路径曾把摘掉的演员带回来；电视按页实例保存墙的状态，这里锁住它。）
     */
    @Test
    fun removedActorStaysRemovedAfterSwitchingTabsAndBack() {
        LocalStore(rule.activity.application).putString(WallLogic.sortKey(1), WallLogic.encodeSort(WallSort("title")))
        val env = rule.setTvContent(routes()) { MainShell(LaunchArgs(item = 1L to 1L)) }
        rule.mainClock.advanceTimeBy(2_000)
        rule.waitForIdle()
        pressUntil(KeyEvent.KEYCODE_DPAD_DOWN, "王导", max = 6)
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals(true, rule.focusedText()?.contains("张三"))
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_500)
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("演员：张三 · 2 部"))
        assertEquals("张三", env.lastQuery("/libraries/1/items")["actor"])

        // 「排序与筛选」→「移除演员：张三」
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("排序与筛选 · A–Z", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        pressUntil(KeyEvent.KEYCODE_DPAD_DOWN, "移除演员：张三")
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("5 部"))

        // 侧边栏切到「搜索」，再切回「首页」
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        pressUntil(KeyEvent.KEYCODE_DPAD_LEFT, "首页")
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("搜索", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assertDoesNotExist()
        pressUntil(KeyEvent.KEYCODE_DPAD_LEFT, "搜索")
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("首页", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_500)

        // 回到首页页签栈顶的那面墙：整库，没有演员条件
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("5 部"))
        rule.onNodeWithTag("poster:4", useUnmergedTree = true).assertExists()
        assertNull(env.lastQuery("/libraries/1/items")["actor"])
    }
}
