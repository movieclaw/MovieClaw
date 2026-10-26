package io.movieclaw.android.core.push

import android.app.Application
import android.app.NotificationManager
import io.movieclaw.android.core.notify.Notifier
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** 游标持久化、轮询去重判断、通知按 collapse 替换（Robolectric：真实 DataStore 与通知管理器）。 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class PushStreamPrefsTest {
    private val app: Application get() = RuntimeEnvironment.getApplication()

    @Test fun `cursor is per server and account and never goes back`() = runBlocking {
        val prefs = PushStreamPrefs(app)
        val a = PushStreamPrefs.cursorKey("https://nas.example", "admin")
        val b = PushStreamPrefs.cursorKey("https://nas.example", "family")
        assertEquals(0L, prefs.cursor(a))
        prefs.saveCursor(a, 12)
        prefs.saveCursor(a, 7) // 乱序的旧确认不能把游标拉回去
        prefs.saveCursor(b, 3)
        assertEquals(12L, prefs.cursor(a))
        assertEquals(3L, prefs.cursor(b))
    }

    @Test fun `polling stays quiet only while the stream is healthy`() = runBlocking {
        val prefs = PushStreamPrefs(app)
        val now = 10_000_000L
        prefs.setEnabled(false)
        prefs.markHealthy(now)
        assertFalse(PushStreamState.coversPolling(app, now)) // 没开实时通知：轮询照常
        prefs.setEnabled(true)
        assertTrue(PushStreamState.coversPolling(app, now + 60_000))
        // 断开超过一小时：轮询兜底
        assertFalse(PushStreamState.coversPolling(app, now + PushStreamState.POLL_FALLBACK_MS + 1))
        // 此刻连着就不看时间
        PushStreamState.set(PushStreamStatus.Connected(now))
        assertTrue(PushStreamState.coversPolling(app, now + PushStreamState.POLL_FALLBACK_MS * 5))
        PushStreamState.set(PushStreamStatus.Off)
    }

    @Test fun `same collapse key replaces the notification`() {
        val json = io.movieclaw.android.core.network.NetworkModule.json()
        val first = StreamNotifications.parse(json, """{"id":1,"title":"开始下载","collapse":"k","priority":"passive"}""")!!
        val second = StreamNotifications.parse(json, """{"id":2,"title":"已入库","collapse":"k"}""")!!
        listOf(first, second).forEach { n ->
            Notifier.post(
                app,
                StreamNotifications.notificationId(n),
                StreamNotifications.channelFor(n.event),
                n.title,
                n.body.orEmpty(),
                "",
                silent = StreamNotifications.silent(n),
            )
        }
        val manager = app.getSystemService(NotificationManager::class.java)
        val shown = shadowOf(manager).allNotifications
        assertEquals(1, shown.size)
        assertEquals("已入库", shown[0].extras.getString("android.title"))
    }
}
