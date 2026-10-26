package io.movieclaw.android.feature.root

import android.app.Application
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.LocalTabActive
import io.movieclaw.android.core.designsystem.TabBarMinimize
import io.movieclaw.android.core.designsystem.TrackTabBarMinimize
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** 主页签切换不再拆页重建：去过的页签留在组合里，只换摆放哪一页 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = "w400dp-h800dp-mdpi")
class KeepAliveTabsTest {
    @get:Rule val compose = createComposeRule()

    @After fun reset() = TabBarMinimize.restore()

    @Test fun switchingBackReusesTabAndHidesInactiveOnes() {
        var selected by mutableStateOf("A")
        val pageBuilds = mutableMapOf<String, Int>()
        val rowBuilds = mutableMapOf<String, Int>()
        val activeSeen = mutableMapOf<String, Boolean>()
        compose.setContent {
            KeepAliveTabs(listOf("A", "B", "C"), selected) { tab, _ ->
                remember { pageBuilds.merge(tab, 1, Int::plus) }
                activeSeen[tab] = LocalTabActive.current
                val list = rememberLazyListState()
                TrackTabBarMinimize(list)
                LazyColumn(Modifier.fillMaxSize().testTag("list-$tab"), state = list) {
                    items(60) { i ->
                        remember { rowBuilds.merge("$tab-$i", 1, Int::plus) }
                        Text("$tab row $i", Modifier.height(60.dp))
                    }
                }
            }
        }
        compose.onNodeWithText("A row 0").assertIsDisplayed()
        // 把 A 往下滚：底栏收起
        compose.onNodeWithTag("list-A").performScrollToIndex(30)
        compose.waitForIdle()
        assertTrue(TabBarMinimize.minimized)

        selected = "B"
        compose.waitForIdle()
        // 后台的 A 不在屏上、知道自己在后台；底栏跟着 B（在顶部）展开
        compose.onNodeWithText("B row 0").assertIsDisplayed()
        assertTrue(compose.onAllNodes(androidx.compose.ui.test.hasText("A row 30")).fetchSemanticsNodes().isEmpty())
        assertEquals(false, activeSeen["A"])
        assertEquals(true, activeSeen["B"])
        assertFalse(TabBarMinimize.minimized)

        // 切回 A：不重建页面、不重建已组装过的行，滚动位置还在
        selected = "A"
        compose.waitForIdle()
        compose.onNodeWithText("A row 30").assertIsDisplayed()
        assertEquals(1, pageBuilds["A"])
        assertEquals(1, rowBuilds["A-30"])
        assertEquals(1, pageBuilds["B"])
        // 没去过的 C 不组装
        assertEquals(null, pageBuilds["C"])
    }
}
