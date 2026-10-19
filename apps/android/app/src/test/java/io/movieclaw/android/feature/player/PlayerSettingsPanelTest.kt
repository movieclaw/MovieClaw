package io.movieclaw.android.feature.player

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import io.movieclaw.android.core.designsystem.MovieClawTheme
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** ⋮ 设置面板：一级写着当前值，点进二级选，选了就收起；二级「←」回一级；访客没有画质 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = "w800dp-h360dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PlayerSettingsPanelTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private var open by mutableStateOf(true)
    private var speed by mutableFloatStateOf(1f)
    private var picked: Float? = null

    private fun show(guest: Boolean = false) {
        compose.setContent {
            MovieClawTheme {
                Box(Modifier.fillMaxSize().background(Color(0xFF181A20))) {
                    PlayerSettingsPanel(
                        visible = open,
                        quality = 1080,
                        qualityReason = "原文件直连",
                        canPickQuality = !guest,
                        speed = speed,
                        diagnosticsOpen = false,
                        onSelectQuality = {},
                        onSelectSpeed = { picked = it; speed = it },
                        onToggleDiagnostics = {},
                        onDismiss = { open = false },
                    )
                }
            }
        }
    }

    @Test fun pickSpeedFromSecondLevel() {
        show()
        compose.onNodeWithText("1080p").assertIsDisplayed()
        compose.onNodeWithText("正常").assertIsDisplayed()
        snapshot("player-settings-root")
        compose.onNodeWithTag("settings-speed").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("speed-1.5×").assertIsDisplayed()
        snapshot("player-settings-speed")
        compose.onNodeWithTag("speed-1.5×").performClick()
        compose.waitForIdle()
        assertEquals(1.5f, picked)
        assertFalse("选了就收起", open)
    }

    @Test fun backReturnsToFirstLevel() {
        show()
        compose.onNodeWithTag("settings-quality").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("720p").assertIsDisplayed()
        compose.onNodeWithTag("settings-back").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("settings-speed").assertIsDisplayed()
        assertNull(picked)
    }

    @Test fun guestHasNoQuality() {
        show(guest = true)
        compose.onNodeWithTag("settings-quality").assertDoesNotExist()
        compose.onNodeWithTag("settings-speed").assertIsDisplayed()
    }

    private fun snapshot(name: String) {
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/$name.png").outputStream().use {
            val view = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
