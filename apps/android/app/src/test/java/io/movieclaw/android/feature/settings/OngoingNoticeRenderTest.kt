package io.movieclaw.android.feature.settings

import android.app.Application
import android.app.Notification
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color as AndroidColor
import android.os.Looper
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.MovieClawTheme
import io.movieclaw.android.core.push.OngoingMode
import io.movieclaw.android.core.push.OngoingNotice
import io.movieclaw.android.core.push.PushStreamService
import io.movieclaw.android.core.push.PushStreamStatus
import io.movieclaw.android.core.push.StreamStatusSnapshot
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

/** 「常驻通知显示」设置与常驻通知本身（原生模板）各渲染一张预览图到 build/ui-previews/。 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = "w360dp-h1400dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class OngoingNoticeRenderTest {
    private val snapshot = StreamStatusSnapshot(
        server = "家里的 NAS",
        today = StreamStatusSnapshot.Today(imported = 5, updated = 2),
        downloads = StreamStatusSnapshot.Downloads(
            active = 3,
            speed = 6_500_000,
            progress = 0.46,
            items = listOf(
                StreamStatusSnapshot.Item("牧神记", "E12", 0.78, 120, "downloading"),
                StreamStatusSnapshot.Item("遮天", "E135", 0.41, 540, "downloading"),
                StreamStatusSnapshot.Item("仙逆", "E160", 0.0, null, "stalled"),
            ),
        ),
    )
    private val connected = PushStreamStatus.Connected(0)

    @Test fun `settings section renders`() {
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        val template = "🦀 {下载数} 个在下 · 今天入库 {今日入库} 集"
        activity.setContent {
            MovieClawTheme {
                Column(Modifier.fillMaxSize().background(Bg).padding(16.dp)) {
                    OngoingSection(
                        mode = OngoingMode.CUSTOM,
                        template = template,
                        preview = OngoingNotice.build(OngoingMode.CUSTOM, template, connected, snapshot),
                        onMode = {},
                        onTemplate = {},
                    )
                }
            }
        }
        save(activity.window.decorView, 360, 900, "notify-ongoing-settings")
        controller.pause().stop().destroy()
    }

    @Test fun `ongoing notification renders with native templates`() {
        val app = org.robolectric.RuntimeEnvironment.getApplication()
        val views = listOf(
            OngoingNotice.build(OngoingMode.SMART, "", connected, snapshot),
            OngoingNotice.build(OngoingMode.DOWNLOADS, "", connected, snapshot.copy(downloads = StreamStatusSnapshot.Downloads())),
            OngoingNotice.build(OngoingMode.CUSTOM, "🦀 {下载数} 个在下 · 今天入库 {今日入库} 集", connected, snapshot),
            OngoingNotice.build(OngoingMode.SMART, "", PushStreamStatus.Retrying("连不上服务器", 0), snapshot),
        )
        val board = PushStreamService.ongoingNotification(app, views[0]).build()
        assertEquals("下载中 3 个 · ↓ 6.2 MB/s", board.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(46, board.extras.getInt(Notification.EXTRA_PROGRESS))
        assertEquals(3, board.extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)!!.size)
        assertEquals(listOf("打开下载"), board.actions.map { it.title.toString() })
        assertTrue(board.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertTrue(board.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
        assertEquals(null, PushStreamService.ongoingNotification(app, views[2]).build().actions)

        val column = LinearLayout(app).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(AndroidColor.rgb(242, 243, 245)) // 系统默认（浅色）通知模板
        }
        views.forEach { view ->
            val notification = PushStreamService.ongoingNotification(app, view).build()
            val builder = Notification.Builder.recoverBuilder(app, notification)
            // 第一张画展开态（列表 + 按钮），其余画收起态
            val remote = if (view.lines.isNotEmpty()) builder.createBigContentView() else builder.createContentView()
            column.addView(remote.apply(app, FrameLayout(app)), LinearLayout.LayoutParams(360, LinearLayout.LayoutParams.WRAP_CONTENT).apply { bottomMargin = 12 })
        }
        save(column, 360, 700, "notify-ongoing-notification")
    }

    private fun save(view: View, width: Int, height: Int, name: String) {
        repeat(10) {
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(16))
            view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.AT_MOST))
            view.layout(0, 0, width, view.measuredHeight)
        }
        val bitmap = Bitmap.createBitmap(width, view.measuredHeight.coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(AndroidColor.WHITE)
        view.draw(Canvas(bitmap))
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        assertTrue("$name did not draw", pixels.toSet().size > 30)
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
