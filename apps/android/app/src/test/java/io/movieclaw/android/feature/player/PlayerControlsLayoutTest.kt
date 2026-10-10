package io.movieclaw.android.feature.player

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ClosedCaption
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.MovieClawTheme
import io.movieclaw.android.core.designsystem.McType
import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = "w800dp-h360dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PlayerControlsLayoutTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun seriesControlsAreCenteredAndRender() = render(true, "player-series-800")

    @Test @Config(qualifiers = "w640dp-h360dp-mdpi")
    fun narrowSeriesControlsRemainInsideTheScreen() = render(true, "player-series-640")

    @Test fun movieControlsAreCenteredWithoutEpisodeButtons() = render(false, "player-movie-800")

    private fun render(series: Boolean, name: String) {
        compose.setContent {
            MovieClawTheme {
                Box(Modifier.fillMaxSize().background(Color(0xFF181A20))) {
                    PlayerCenterControls(true, {}, {}, {}, Modifier.align(Alignment.Center))
                    Box(Modifier.align(Alignment.BottomCenter).padding(bottom = 48.dp)) {
                        PlayerBottomControls(series, true, {}, {}, tracks = {
                            IconButton(onClick = {}) { Icon(Icons.Rounded.GraphicEq, "音轨", tint = Color.White) }
                            IconButton(onClick = {}) { Icon(Icons.Rounded.ClosedCaption, "字幕", tint = Color.White) }
                        }, speed = {
                            TextButton(onClick = {}) { Text("1.0×", style = McType.caption, color = Color.White) }
                        })
                    }
                }
            }
        }
        val root = compose.onRoot().getUnclippedBoundsInRoot()
        val play = compose.onNodeWithContentDescription("暂停").getUnclippedBoundsInRoot()
        val back = compose.onNodeWithContentDescription("后退 10 秒").getUnclippedBoundsInRoot()
        val fwd = compose.onNodeWithContentDescription("前进 10 秒").getUnclippedBoundsInRoot()
        val subs = compose.onNodeWithContentDescription("字幕").getUnclippedBoundsInRoot()
        assertEquals("Play button is not centered", (root.left.value + root.right.value) / 2, (play.left.value + play.right.value) / 2, 0.5f)
        assertEquals("Play button is not vertically centered", (root.top.value + root.bottom.value) / 2, (play.top.value + play.bottom.value) / 2, 0.5f)
        assertTrue("Seek buttons not around play", back.right < play.left && fwd.left > play.right)
        assertTrue("Tool row overlaps transport", subs.top > play.bottom)
        if (series) {
            val next = compose.onNodeWithContentDescription("下一集").getUnclippedBoundsInRoot()
            val picker = compose.onNodeWithContentDescription("选集").getUnclippedBoundsInRoot()
            assertTrue("Next not in tool row", next.top > play.bottom && next.left > fwd.right)
            assertTrue("Picker clipped", picker.right <= root.right - 35.dp)
            assertTrue("Next overlaps picker", next.right <= picker.left)
        } else {
            compose.onNodeWithContentDescription("下一集").assertDoesNotExist()
            compose.onNodeWithContentDescription("选集").assertDoesNotExist()
        }
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/$name.png").outputStream().use {
            val view = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
