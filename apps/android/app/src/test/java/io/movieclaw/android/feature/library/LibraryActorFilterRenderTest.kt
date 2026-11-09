package io.movieclaw.android.feature.library

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.*
import io.movieclaw.android.core.model.ActorView
import io.movieclaw.android.core.model.LibraryFilter
import io.movieclaw.android.core.model.LibraryItemDetailView
import io.movieclaw.android.core.model.LocalMetaView
import io.movieclaw.android.feature.detail.CastSection
import java.io.File
import java.time.Duration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * 真渲染：详情页演职员一行（导演无 id 静态 / 演员有 id 进影人页 / 演员无 id 进同库按演员筛）
 * 与墙页条件行里那枚可摘掉的「演员：姓名」。截图落 build/ui-previews/。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = "w360dp-h640dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class LibraryActorFilterRenderTest {
    private val width = 360
    private val height = 640

    @Test fun `cast row routes actors without person id to the library wall`() {
        val detail = LibraryItemDetailView(
            mediaItemId = 1,
            kind = "video",
            source = "local",
            title = "甲",
            localMeta = LocalMetaView(
                directors = listOf("王导"),
                actors = listOf(
                    ActorView(name = " 张三 ", role = "主角"),
                    ActorView(name = "Alice Smith", role = "Guest", tmdbPersonId = 42),
                ),
            ),
        )
        val bounds = mutableMapOf<String, Rect>()
        val people = mutableListOf<Int>()
        val actors = mutableListOf<String>()
        var clearedActor = 0
        var clearedAll = 0
        val filter = LibraryFilter(actor = "张三", genres = setOf("18"))
        val (activity, view, controller) = launch {
            Column(Modifier.fillMaxSize().background(Bg).padding(vertical = 16.dp)) {
                Box(Modifier.onGloballyPositioned { bounds["cast"] = it.boundsInWindow() }) {
                    CastSection(detail, origin = null, onOpenPerson = { people += it }, onOpenActorInLibrary = { actors += it })
                }
                Spacer(Modifier.height(24.dp))
                Box(Modifier.onGloballyPositioned { bounds["summary"] = it.boundsInWindow() }) {
                    ActiveFilterSummary(filter, onClearActor = { clearedActor++ }, onClear = { clearedAll++ })
                }
            }
        }
        snapshot(view, "library-actor-filter-phone")

        val cast = bounds.getValue("cast")
        // 手机尺寸 token（mdpi 下 1dp = 1px）：页边距 16、卡宽 104、卡间距 10。
        // 卡位按顺序：导演（无 id，静态）、张三（无 id）、Alice（有 id）
        val y = cast.top + cast.height / 2
        listOf(0, 1, 2).forEach { i -> tap(view, cast.left + 16f + i * (104f + 10f) + 52f, y) }
        assertEquals(listOf("张三"), actors)
        assertEquals(listOf(42), people)

        val summary = bounds.getValue("summary")
        tap(view, summary.left + 40f, summary.center.y) // 左侧那枚「演员：张三 ×」
        assertEquals(1, clearedActor)
        assertEquals(0, clearedAll)
        tap(view, summary.right - 30f, summary.center.y) // 右侧「清空」
        assertEquals(1, clearedAll)
        controller.pause().stop().destroy()
    }

    private fun launch(content: @androidx.compose.runtime.Composable () -> Unit):
        Triple<ComponentActivity, View, org.robolectric.android.controller.ActivityController<ComponentActivity>> {
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        activity.setContent { MovieClawTheme { content() } }
        val view = activity.window.decorView
        repeat(10) {
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(16))
            view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, width, height)
        }
        return Triple(activity, view, controller)
    }

    private fun snapshot(view: View, name: String) {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        assertTrue("Compose content did not draw", pixels.toSet().size > 30)
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun tap(view: View, x: Float, y: Float) {
        val t = SystemClock.uptimeMillis()
        listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP).forEachIndexed { i, action ->
            val event = MotionEvent.obtain(t, t + i * 16, action, x, y, 0)
            view.dispatchTouchEvent(event)
            event.recycle()
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(16))
        }
    }
}
