package io.movieclaw.android.core.designsystem

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = "w400dp-h300dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class McLiquidTabBarTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private var selected by mutableIntStateOf(0)

    @After fun reset() = TabBarMinimize.restore()

    private fun setBar() {
        compose.setContent {
            MovieClawTheme {
                val haze = rememberHazeState()
                Box(Modifier.fillMaxSize().background(Bg)) {
                    Column(Modifier.fillMaxSize().hazeSource(haze)) {
                        listOf(Color(0xFF3B6FE0), Color(0xFFE0A33B), Color(0xFF3BE07A)).forEach {
                            Box(Modifier.fillMaxWidth().height(100.dp).background(it)) { Text("内容") }
                        }
                    }
                    McLiquidTabBar(
                        icons = listOf(Icons.Rounded.Home, Icons.Rounded.Search, Icons.Rounded.Star, Icons.Rounded.Notifications),
                        labels = listOf("发现", "媒体库", "订阅", "活动"),
                        selectedIndex = selected,
                        onSelect = { selected = it },
                        dots = mapOf(3 to TabDot(Accent, "有更新")),
                        hazeState = haze,
                        modifier = Modifier.align(Alignment.BottomCenter),
                    )
                }
            }
        }
    }

    @Test fun tapSelectsTabAndCollapseRestores() {
        setBar()
        snapshot("liquid-expanded")
        compose.onAllNodesWithContentDescription("订阅")[0].performClick()
        compose.waitForIdle()
        assertEquals(2, selected)

        val expanded = compose.onAllNodesWithContentDescription("发现")[0].getUnclippedBoundsInRoot()
        compose.mainClock.autoAdvance = false
        TabBarMinimize.onScroll(0, 2f)
        TabBarMinimize.onScroll(1_000, 2f)
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeBy(200)
        compose.mainClock.autoAdvance = true
        compose.waitForIdle()
        snapshot("liquid-collapsed")
        val collapsedTab = compose.onAllNodesWithContentDescription("发现")[0].getUnclippedBoundsInRoot()
        // 收起后页签层随胶囊缩到 44dp 内
        assertTrue("tabs did not collapse", collapsedTab.right < expanded.right)

        TabBarMinimize.restore()
        compose.waitForIdle()
        val restored = compose.onAllNodesWithContentDescription("发现")[0].getUnclippedBoundsInRoot()
        assertEquals(expanded.left.value, restored.left.value, 0.5f)
        assertEquals(expanded.right.value, restored.right.value, 0.5f)
        compose.onAllNodesWithContentDescription("媒体库")[0].performClick()
        compose.waitForIdle()
        assertEquals(1, selected)
    }

    private fun snapshot(name: String) {
        if (compose.mainClock.autoAdvance) compose.waitForIdle()
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/$name.png").outputStream().use {
            val view = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
