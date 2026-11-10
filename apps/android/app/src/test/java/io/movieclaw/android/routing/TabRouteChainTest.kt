package io.movieclaw.android.routing

import android.app.Application
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import io.movieclaw.android.feature.library.libraryActorRoute
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 平板侧边栏「每页签一条导航链」+ 库墙上摘掉演员条件：
 * 演员墙 → 摘掉演员 → 切到别的页签 → 切回 → 必须是整库，而不是又按演员筛回去。
 *
 * 用真 NavHost / 真返回栈条目跑；页签链的记账与 AppNav 同一套（[TabRouteChain]、[LIBRARY_ROUTE]），
 * 切页签照 AppNav 侧边栏 onSelect：先取出目标页签的链，pop 到 tabs，再按顺序重放。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class TabRouteChainTest {
    @get:Rule val compose = createComposeRule()

    private val actorRoute = libraryActorRoute(3, "张三")

    private lateinit var nav: NavHostController
    private var shellTab by mutableStateOf("library")
    private var libraryChain: () -> List<String> = { emptyList() }
    private var clearActor: (NavBackStackEntry) -> Unit = {}

    private fun content(setContent: (@androidx.compose.runtime.Composable () -> Unit) -> Unit) = setContent {
        nav = rememberNavController()
        // 同 AppNav 的 tabChains：可保存（旋转 / 进程重建后还在）
        var chain by rememberSaveable(saver = listSaver(save = { it.value }, restore = { mutableStateOf(it) })) {
            mutableStateOf(emptyList<String>())
        }
        libraryChain = { chain }
        clearActor = { entry -> chain = TabRouteChain.clearActor(chain, entry) }
        val current by nav.currentBackStackEntryAsState()
        LaunchedEffect(current) {
            val entry = current ?: return@LaunchedEffect
            if (entry.destination.route == "tabs") {
                if (shellTab == "library") chain = emptyList()
                return@LaunchedEffect
            }
            shellTab = "library"
            chain = TabRouteChain.record(chain, entry)
        }
        NavHost(nav, startDestination = "tabs") {
            composable("tabs") {}
            composable(LIBRARY_ROUTE) {}
            composable("item/{libraryId}/{itemId}") {}
        }
    }

    private fun switchTab(target: String) {
        compose.runOnIdle {
            val restore = if (target == "library") libraryChain() else emptyList()
            shellTab = target
            nav.popBackStack("tabs", inclusive = false)
            restore.forEach { nav.navigate(it) }
        }
        compose.waitForIdle()
    }

    private fun currentEntry(): NavBackStackEntry = compose.runOnIdle { nav.currentBackStackEntry!! }

    @Test fun `cleared actor stays cleared after switching tabs away and back`() {
        content { compose.setContent(it) }
        compose.runOnIdle { nav.navigate(actorRoute) }
        compose.waitForIdle()
        assertEquals(listOf("library/3?actor=%E5%BC%A0%E4%B8%89"), libraryChain())
        assertEquals("张三", currentEntry().arguments?.getString("actor"))

        // 墙页条件行摘掉演员（AppNav 的 onActorCleared）
        compose.runOnIdle { clearActor(nav.currentBackStackEntry!!) }
        assertEquals(listOf("library/3"), libraryChain())
        // 条目实参里的 actor 还在（Navigation 不让改）——正是旧实现重放时把它带回来的原因
        assertEquals("张三", currentEntry().arguments?.getString("actor"))

        switchTab("discover")
        assertEquals("tabs", currentEntry().destination.route)
        switchTab("library")

        val back = currentEntry()
        assertEquals(LIBRARY_ROUTE, back.destination.route)
        assertEquals("3", back.arguments?.getString("libraryId"))
        assertNull("切回来应是整库", back.arguments?.getString("actor"))
        assertEquals(listOf("library/3"), libraryChain())
    }

    @Test fun `rotation re-report and returning from an item do not bring the actor back`() {
        content { compose.setContent(it) }
        compose.runOnIdle { nav.navigate(actorRoute) }
        compose.waitForIdle()
        compose.runOnIdle { clearActor(nav.currentBackStackEntry!!) }
        // 同一层再上报一次（重组 / 旋转）：按摘过演员的样子记，不追加带 actor 的那层
        compose.runOnIdle { assertEquals(listOf("library/3"), TabRouteChain.record(libraryChain(), nav.currentBackStackEntry!!)) }
        compose.runOnIdle { nav.navigate("item/3/9") }
        compose.waitForIdle()
        compose.runOnIdle { nav.popBackStack() }
        compose.waitForIdle()
        assertEquals(false, libraryChain().any { it.contains("actor=") })
    }

    @Test fun `cleared actor survives saved-state restore`() {
        val restoration = StateRestorationTester(compose)
        content { restoration.setContent(it) }
        compose.runOnIdle { nav.navigate(actorRoute) }
        compose.waitForIdle()
        compose.runOnIdle { clearActor(nav.currentBackStackEntry!!) }

        restoration.emulateSavedInstanceStateRestore()
        compose.waitForIdle()

        // 恢复出来的条目仍带原始实参，但记账以条目上保存的「已摘掉」为准
        val restored = currentEntry()
        assertEquals("张三", restored.arguments?.getString("actor"))
        assertEquals("library/3", TabRouteChain.routeOf(restored))
        assertEquals(listOf("library/3"), libraryChain())

        switchTab("discover")
        switchTab("library")
        assertNull(currentEntry().arguments?.getString("actor"))
    }

    @Test fun `plain library walls are untouched`() {
        content { compose.setContent(it) }
        compose.runOnIdle { nav.navigate("library/3?name=${android.net.Uri.encode("本地 库")}") }
        compose.waitForIdle()
        compose.runOnIdle { clearActor(nav.currentBackStackEntry!!) }
        assertEquals(listOf("library/3?name=%E6%9C%AC%E5%9C%B0%20%E5%BA%93"), libraryChain())
    }

    @Test fun `query helpers`() {
        assertEquals("library/3", TabRouteChain.withoutQuery("library/3?actor=%E5%BC%A0%E4%B8%89", "actor"))
        assertEquals("library/3?name=a%20b&w=unfinished",
            TabRouteChain.withoutQuery("library/3?name=a%20b&actor=x&w=unfinished", "actor"))
        assertEquals("library/3?name=x", TabRouteChain.withoutQuery("library/3?name=x", "actor"))
        assertEquals(listOf("a", "b", "c"), TabRouteChain.replaceLast(listOf("a", "b", "b"), "b", "c"))
        assertEquals(listOf("a"), TabRouteChain.replaceLast(listOf("a"), "z", "y"))
    }
}
