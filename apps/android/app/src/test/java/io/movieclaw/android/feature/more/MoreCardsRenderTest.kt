package io.movieclaw.android.feature.more

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.*
import io.movieclaw.android.core.model.SessionView
import java.io.File
import java.time.Duration
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Render the shipped Compose cards, including narrow displays and larger system fonts. */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = "w360dp-h900dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MoreCardsRenderTest {
    @Test fun `account and settings render with native graphics`() = render("more-normal", 1f)

    @Test fun `settings rows expand for larger accessibility fonts`() = render("more-large-font", 1.3f)

    private fun render(name: String, fontScale: Float) {
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        val bounds = mutableMapOf<String, Rect>()
        var profileClicks = 0
        var settingsClicks = 0
        var newClicks = 0
        var appearanceChanged = false
        val config = activity.resources.configuration
        config.fontScale = fontScale
        @Suppress("DEPRECATION")
        activity.resources.updateConfiguration(config, activity.resources.displayMetrics)
        activity.setContent {
            MovieClawTheme {
                Column(Modifier.fillMaxSize().background(Bg).padding(16.dp)) {
                    Text("我的", style = McType.display, color = TextPrimary)
                    Spacer(Modifier.height(20.dp))
                    Box(Modifier.onGloballyPositioned { bounds["account"] = it.boundsInWindow() }) {
                        MoreAccountCard(SessionView("MovieClaw", role = "admin", capabilities = SessionView.Capabilities(true, true, true)), "https://nas.example", { profileClicks++ })
                    }
                    GroupLabel("连接", Modifier.padding(top = 20.dp), inset = 0.dp)
                    Box(Modifier.onGloballyPositioned { bounds["connection"] = it.boundsInWindow() }) {
                        MoreConnectionCard("https://movieclaw.example.com", 1, { settingsClicks++ })
                    }
                    GroupLabel("显示与外观", Modifier.padding(top = 20.dp), inset = 0.dp)
                    Box(Modifier.onGloballyPositioned { bounds["appearance"] = it.boundsInWindow() }) {
                        MoreAppearanceCard(false, { appearanceChanged = it })
                    }
                    GroupLabel("最近会话", Modifier.padding(top = 20.dp), inset = 0.dp)
                    Box(Modifier.onGloballyPositioned { bounds["sessions"] = it.boundsInWindow() }) {
                        MoreEmptySessions({ newClicks++ })
                    }
                }
            }
        }
        val view = activity.window.decorView
        repeat(10) {
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(16))
            view.measure(View.MeasureSpec.makeMeasureSpec(360, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, 360, 900)
        }
        val bitmap = Bitmap.createBitmap(360, 900, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        // The native render must contain content, rather than a blank window.
        val pixels = IntArray(360 * 900)
        bitmap.getPixels(pixels, 0, 360, 0, 0, 360, 900)
        assertTrue("Compose cards did not draw", pixels.toSet().size > 30)
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        fun tap(x: Float, y: Float) {
            val t = SystemClock.uptimeMillis()
            listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP).forEachIndexed { i, action ->
                val event = MotionEvent.obtain(t, t + i * 16, action, x, y, 0)
                view.dispatchTouchEvent(event)
                event.recycle()
                shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(16))
            }
        }
        bounds.getValue("account").let { tap(it.center.x, it.center.y) }
        bounds.getValue("connection").let { tap(it.center.x, it.top + 30f) }
        bounds.getValue("appearance").let { tap(it.right - 42f, it.center.y) }
        bounds.getValue("sessions").let {
            assertTrue("New conversation action clipped by viewport", it.bottom <= 900)
            tap(it.center.x, it.bottom - 40f)
        }
        assertEquals(1, profileClicks)
        assertEquals(1, settingsClicks)
        assertEquals(1, newClicks)
        assertTrue(appearanceChanged)
        controller.pause().stop().destroy()
    }
}
