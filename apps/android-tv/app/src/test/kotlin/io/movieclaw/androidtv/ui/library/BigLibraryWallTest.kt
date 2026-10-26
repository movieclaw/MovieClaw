package io.movieclaw.androidtv.ui.library

import android.app.Application
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.requestFocus
import io.movieclaw.androidtv.core.session.LocalStore
import io.movieclaw.androidtv.ui.Responder
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.TvEnv
import io.movieclaw.androidtv.ui.focusedText
import io.movieclaw.androidtv.ui.press
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.LaunchArgs
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.MainShell
import io.movieclaw.androidtv.ui.shell.Router
import io.movieclaw.core.model.generated.FacetValueView
import io.movieclaw.core.model.generated.LibraryFacetsView
import io.movieclaw.core.model.generated.LibraryIndexEntryView
import io.movieclaw.core.model.generated.LibraryItemView
import io.movieclaw.core.model.generated.LibraryRelaxView
import io.movieclaw.core.model.generated.LibraryStats
import io.movieclaw.core.model.generated.LibraryView
import io.movieclaw.core.model.generated.RelaxSuggestionView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * 大库海报墙（#942）：3000 部的库，用遥控器走 Apple TV 同一套流程——焦点暗带、按住往下滚的位置提示、
 * 从最右一列进索引条（落在当前档、跳过空档）、跳到 S、往上一排（前一页已补上）、左键回海报；
 * 「排序与筛选」里选类型 → 筛空 → 放宽建议找回来。真的 LibraryWallScreen，假服务端按 offset / 条件现算。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BigLibraryWallTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    /** 按片名排好的 3000 部：每个字母约 125 部，I、U、V、X 开头的没有 */
    private val letters = "ABCDEFGHJKLMNOPQRSTWYZ#"
    /** 每个字母多少部：默认约 131；改小了相邻字母的跳转窗口会重叠 */
    private var perLetter = 3000 / letters.length + 1
    /** 库里共几部（默认 3000，受每档部数所限） */
    private var size = 3000
    private val catalog get() = (0 until minOf(size, letters.length * perLetter)).map { i ->
        val letter = letters[i / perLetter]
        LibraryItemView(mediaItemId = i + 1L, libraryId = 1, title = "${if (letter == '#') "1" else letter.toString()}片 $i", year = 1990L + i % 35)
    }
    private val index get() = letters.mapIndexed { n, c ->
        LibraryIndexEntryView(c.toString(), catalog.count { it.title.startsWith(if (c == '#') "1" else c.toString()) }.toLong(), (n * perLetter).toLong())
    }

    private fun open(): TvEnv {
        LocalStore(rule.activity.application).putString(WallLogic.sortKey(1), WallLogic.encodeSort(WallSort("title")))
        val env = rule.setTvContent(routes()) {
            CompositionLocalProvider(LocalRouter provides Router()) { LibraryWallScreen(1) }
        }
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        return env
    }

    private fun routes(): Map<String, Any> = mapOf(
                "/libraries" to listOf(LibraryView(id = 1, name = "大电影库", kind = "movie", viewerAccess = true, stats = LibraryStats(itemCount = 3000))),
                // 西部片一部没有：选了就筛空
                "/libraries/1/items" to Responder { q ->
                    if (q["g"] == "37") return@Responder emptyList<LibraryItemView>()
                    val offset = q["offset"]?.toInt() ?: 0
                    catalog.drop(offset).take(q["limit"]?.toInt() ?: 60)
                },
                "/libraries/1/item-index" to Responder { q -> if (q["g"] == "37") emptyList<LibraryIndexEntryView>() else index },
                "/libraries/1/facets" to Responder { q ->
                    LibraryFacetsView(
                        total = if (q["g"] == "37") 0 else 3000,
                        genres = listOf(FacetValueView("37", "西部", 540), FacetValueView("99", "纪录", 0)),
                    )
                },
                "/libraries/1/relax" to LibraryRelaxView(0, listOf(RelaxSuggestionView(dim = "genres", value = "37", label = "西部", count = 3000))),
    )

    private fun assertPosterFocused(id: Long) =
        rule.onNodeWithTag("poster:$id", useUnmergedTree = true).assert(hasAnyDescendant(isFocused()) or isFocused())

    @Test
    fun railJumpsIntoTheMiddleAndComesBack() {
        val env = open()
        assertPosterFocused(1)
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("3000 部"))
        // 焦点那张底部浮出「片名 · 年份」
        rule.onNodeWithText("A片 0 · 1990", useUnmergedTree = true).assertExists()
        rule.savePreview("wall-focus-band")

        // 按住往下：连着几次挨得很近，中央浮出所在的档和第几部
        repeat(4) { rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 150) }
        rule.onNodeWithTag("wall-hud", useUnmergedTree = true).assertExists()
        rule.onNodeWithText("第 21 部 / 共 3000 部", useUnmergedTree = true).assertExists()
        rule.savePreview("wall-quick-scroll-hud")
        rule.mainClock.advanceTimeBy(2_000)

        // 最右一列再按右：进索引条，落在当前所在的那一档（A）
        repeat(4) { rule.press(KeyEvent.KEYCODE_DPAD_RIGHT) }
        assertPosterFocused(25)
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("A", rule.focusedText())
        // 往下到 H 再往下：I 是空档，跳过落到 J
        repeat(7) { rule.press(KeyEvent.KEYCODE_DPAD_DOWN) }
        assertEquals("H", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("J", rule.focusedText())
        // 往上到头就停，不跑到标题行的按钮上
        repeat(12) { rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 50) }
        assertEquals("A", rule.focusedText())
        // 选到 S（A 往下数，跳过 I）
        while (rule.focusedText() != "S") rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 100)
        rule.savePreview("wall-rail-bubble")
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        val sOffset = letters.indexOf('S') * perLetter
        assertPosterFocused(sOffset + 1L)
        // 目标那一排滚到顶上（标题行的位置），不是露在第二排
        val rowTop = rule.onNodeWithTag("poster:${sOffset + 1L}", useUnmergedTree = true).getBoundsInRoot().top
        assertTrue("跳转后那一排的顶：$rowTop", rowTop < Dp(100f))
        rule.onNodeWithText("第 ${sOffset + 1} 部 / 共 3000 部", useUnmergedTree = true).assertExists()
        rule.savePreview("wall-rail-jump")
        // 跳转换了窗口（按整排对齐）并补上了前一页，不是从头一页页追过去
        val offsets = env.transport.queries.filter { it.first == "/libraries/1/items" }.mapNotNull { (_, q) -> q.toMap()["offset"]?.toInt() }
        val aligned = sOffset - sOffset % 5
        assertTrue("跳转请求：$offsets", aligned in offsets && (aligned - 60) in offsets)
        assertTrue("没有一页页追过去：$offsets", offsets.count { it in 120 until aligned - 60 } == 0)

        // 再跳一次（两个窗口一样大，都是前一页 + 这一页）：仍然是目标那一排在顶上
        repeat(4 - sOffset % 5) { rule.press(KeyEvent.KEYCODE_DPAD_RIGHT) }
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("S", rule.focusedText())
        while (rule.focusedText() != "D") rule.press(KeyEvent.KEYCODE_DPAD_UP, settleMs = 100)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        val dOffset = letters.indexOf('D') * perLetter
        assertPosterFocused(dOffset + 1L)
        val dTop = rule.onNodeWithTag("poster:${dOffset + 1L}", useUnmergedTree = true).getBoundsInRoot().top
        assertTrue("第二次跳转后那一排的顶：$dTop", dTop < Dp(100f))
        // 回到 S 接着往下验
        repeat(4 - dOffset % 5) { rule.press(KeyEvent.KEYCODE_DPAD_RIGHT) }
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        while (rule.focusedText() != "S") rule.press(KeyEvent.KEYCODE_DPAD_DOWN, settleMs = 100)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        assertPosterFocused(sOffset + 1L)

        // 往上一排：前一页已经补上，焦点落在上一排同一列
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertPosterFocused(sOffset + 1L - 5)
        // 再进索引条，左键回到刚才那张
        val column = (sOffset - 5) % 5
        repeat(4 - column) { rule.press(KeyEvent.KEYCODE_DPAD_RIGHT) }
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        // 上一排是 R 开头的最后几部：索引条亮的是 R
        assertEquals("R", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertPosterFocused(sOffset + 1L - 5 + (4 - column))
    }

    @Test
    fun filterThenRelaxBringsTitlesBack() {
        val env = open()
        // 第一排往上：标题行的「排序与筛选」
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("排序与筛选 · A–Z", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals("最近添加", rule.focusedText())
        // 四档排序、只看没看过的、类型
        repeat(5) { rule.press(KeyEvent.KEYCODE_DPAD_DOWN) }
        assertEquals("类型 全部", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        rule.onNodeWithTag("submenu").assertExists()
        assertEquals("全部", rule.focusedText())
        // 0 部的「纪录」置灰、选不到：往下两次仍停在西部
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("西部 540 部", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("西部 540 部", rule.focusedText())
        rule.savePreview("wall-filter-submenu")
        // 返回键回到「类型」那一行，再进去选西部
        rule.press(KeyEvent.KEYCODE_BACK)
        // 返回键走 Activity 的返回分发，状态变化在这一轮时钟之后才生效：再走一轮让焦点交接跑完
        rule.press(KeyEvent.KEYCODE_UNKNOWN)
        assertEquals("类型 全部", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        assertTrue(env.transport.queries.any { (path, q) -> path == "/libraries/1/items" && q.toMap()["g"] == "37" })

        // 筛空：不留空墙，给出放宽建议；摘要写条件与部数
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("西部 · 0 部"))
        rule.onNodeWithText("没有符合条件的影片", useUnmergedTree = true).assertExists()
        // 菜单收起后焦点回到按钮上（同 tvOS 系统菜单），往下落到离它最近的「清除全部条件」，左边是放宽建议
        assertEquals("排序与筛选 · A–Z", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertEquals("清除全部条件", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("去掉“西部”可看 3000 部", rule.focusedText())
        rule.savePreview("wall-filter-empty-relax")
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("3000 部"))
        assertPosterFocused(1)
    }

    /** 选了条件、退出去再进来：是新的一页（同 tvOS），类型 / 年代 / 画质清空、从头开始；排序照旧按库记着 */
    @Test
    fun reenteringTheLibraryStartsFresh() {
        LocalStore(rule.activity.application).putString(WallLogic.sortKey(1), WallLogic.encodeSort(WallSort("title")))
        rule.setTvContent(routes()) { MainShell(LaunchArgs()) }
        rule.mainClock.advanceTimeBy(2_000)
        rule.waitForIdle()
        fun openLibrary() {
            rule.onNodeWithText("大电影库").requestFocus()
            rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_500)
            assertPosterFocused(1)
        }
        openLibrary()
        // 选类型「西部」：筛空
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        repeat(5) { rule.press(KeyEvent.KEYCODE_DPAD_DOWN) }
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("西部 · 0 部"))
        // 退回首页再进来：没有条件、从第一部开始，排序还是 A–Z
        rule.runOnUiThread { rule.activity.onBackPressedDispatcher.onBackPressed() }
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        rule.onNodeWithText("我的媒体库", useUnmergedTree = true).assertExists()
        openLibrary()
        rule.onNodeWithTag("wall-subtitle", useUnmergedTree = true).assert(hasText("3000 部"))
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("排序与筛选 · A–Z", rule.focusedText())
    }

    /** 合集墙：「排序」菜单（合集顺序 / 最近添加 / 最近上映 / 评分最高 / A–Z），按合集记在本机；合集没有索引接口，不显示索引条 */
    @Test
    fun collectionWallSorts() {
        val env = rule.setTvContent(
            mapOf("/collections/5/items" to Responder { q -> catalog.drop(q["offset"]?.toInt() ?: 0).take(q["limit"]?.toInt() ?: 60) }),
        ) {
            CompositionLocalProvider(LocalRouter provides Router()) { CollectionWallScreen(5, "漫威") }
        }
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        assertPosterFocused(1)
        // 默认合集顺序：不带 sort
        assertEquals(null, env.transport.queries.last { it.first == "/collections/5/items" }.second.toMap()["sort"])
        rule.press(KeyEvent.KEYCODE_DPAD_UP)
        assertEquals("排序 · 合集顺序", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertEquals("合集顺序", rule.focusedText())
        repeat(4) { rule.press(KeyEvent.KEYCODE_DPAD_DOWN) }
        assertEquals("A–Z", rule.focusedText())
        rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
        assertEquals("排序 · A–Z", rule.focusedText())
        assertEquals("title", env.transport.queries.last { it.first == "/collections/5/items" }.second.toMap()["sort"])
        assertEquals(WallSort("title"), WallLogic.decodeSort(env.graph.store.string(WallLogic.collectionSortKey(5)), WallLogic.COLLECTION_SORTS))
        rule.onNodeWithTag("wall-rail", useUnmergedTree = true).assertDoesNotExist()
    }

    /** 字母档很小（每个 20 部）时，相邻两档的跳转窗口互相重叠：连着跳仍然落在目标那一排、目标排在顶上 */
    @Test
    fun jumpsBetweenNearbyLettersWithOverlappingWindows() {
        perLetter = 20
        open()
        // 先跳 M，再跳 N（窗口起点差 20 部，两个窗口大半重叠）
        fun jumpTo(letter: Char) {
            // 一路往右进索引条（索引条上的字是单个字母）
            while (rule.focusedText()?.length != 1) rule.press(KeyEvent.KEYCODE_DPAD_RIGHT, settleMs = 100)
            while (rule.focusedText() != letter.toString()) {
                val down = letters.indexOf(rule.focusedText()!!.single()) < letters.indexOf(letter)
                rule.press(if (down) KeyEvent.KEYCODE_DPAD_DOWN else KeyEvent.KEYCODE_DPAD_UP, settleMs = 100)
            }
            rule.press(KeyEvent.KEYCODE_DPAD_CENTER, settleMs = 1_000)
            val offset = letters.indexOf(letter) * perLetter
            assertPosterFocused(offset + 1L)
            val top = rule.onNodeWithTag("poster:${offset + 1L}", useUnmergedTree = true).getBoundsInRoot().top
            assertTrue("跳到 $letter 后那一排的顶：$top", top < Dp(100f))
        }
        jumpTo('M')
        jumpTo('N')
        jumpTo('L')
        jumpTo('O')
    }

    /** 只有一排的墙（筛得只剩几部）：往下不会掉进右边的索引条，索引条只能从最右一张按右键进去（同 tvOS） */
    @Test
    fun railIsOnlyEnteredFromTheRight() {
        size = 3
        open()
        assertPosterFocused(1)
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertPosterFocused(1)
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertPosterFocused(3)
        rule.press(KeyEvent.KEYCODE_DPAD_DOWN)
        assertPosterFocused(3)
        rule.press(KeyEvent.KEYCODE_DPAD_RIGHT)
        assertEquals("A", rule.focusedText())
    }
}
