package io.movieclaw.android.core.push

import io.movieclaw.android.core.network.NetworkModule
import io.movieclaw.android.core.notify.Notifier
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** 实时通知的纯逻辑：通知内容解析、渠道 / 落点映射、collapse、退避、单次 SSE 连接（真实 HTTP）。 */
class PushStreamTest {
    private val json = NetworkModule.json()
    private lateinit var server: MockWebServer

    @Before fun setUp() {
        server = MockWebServer().also { it.start() }
    }

    @After fun tearDown() {
        server.shutdown()
    }

    private fun data(id: Long, title: String, extra: String = "") =
        """{"id":$id,"event":"subscription.fulfilled","title":"$title","body":"正文","deeplink":"/library/3/item/42?season=1&episode=2",""" +
            """"priority":"passive","collapse":"abcdef0123456789","sent_at":1791674053,"server":{"id":"s","name":"NAS"},""" +
            """"account":{"id":"0","name":"admin"}$extra}"""

    @Test fun `parses server payload with snake case and unknown fields`() {
        val n = StreamNotifications.parse(json, data(7, "沙丘", ""","thread":"t","image":"/x""""))!!
        assertEquals(7L, n.id)
        assertEquals("沙丘", n.title)
        assertEquals("正文", n.body)
        assertEquals("abcdef0123456789", n.collapse)
        assertEquals(1791674053L, n.sentAt)
        assertTrue(StreamNotifications.silent(n))
        // 坏数据、缺 id / 标题的不显示
        assertNull(StreamNotifications.parse(json, "not json"))
        assertNull(StreamNotifications.parse(json, """{"id":0,"title":"x"}"""))
        assertNull(StreamNotifications.parse(json, """{"id":3,"title":""}"""))
    }

    @Test fun `events map to the four local channels`() {
        assertEquals(Notifier.CH_ARRIVAL, StreamNotifications.channelFor("subscription.fulfilled"))
        assertEquals(Notifier.CH_ARRIVAL, StreamNotifications.channelFor("library.items.arrived"))
        assertEquals(Notifier.CH_DOWNLOAD, StreamNotifications.channelFor("subscription.download_started"))
        assertEquals(Notifier.CH_SUBSCRIPTION, StreamNotifications.channelFor("subscription.identity_skipped"))
        assertEquals(Notifier.CH_TASK, StreamNotifications.channelFor("acme.quota.exceeded"))
        // 旧服务端的旧键照样认
        assertEquals(Notifier.CH_ARRIVAL, StreamNotifications.channelFor("imported"))
        assertEquals(Notifier.CH_ARRIVAL, StreamNotifications.channelFor("library_new"))
        assertEquals(Notifier.CH_ARRIVAL, StreamNotifications.channelFor("upgraded"))
        assertEquals(Notifier.CH_DOWNLOAD, StreamNotifications.channelFor("download_started"))
        assertEquals(Notifier.CH_SUBSCRIPTION, StreamNotifications.channelFor("identity_skipped"))
        assertEquals(Notifier.CH_TASK, StreamNotifications.channelFor("system_alert"))
        assertEquals(Notifier.CH_TASK, StreamNotifications.channelFor("test"))
        assertEquals(Notifier.CH_TASK, StreamNotifications.channelFor("something_new"))
    }

    @Test fun `web deeplinks become app routes`() {
        assertEquals(Landing("item/3/42", null), StreamNotifications.landingFor("/library/3/item/42?season=1&episode=2"))
        assertEquals(Landing("library/3?name=", null), StreamNotifications.landingFor("/library/3"))
        assertEquals(Landing("subscription/9", null), StreamNotifications.landingFor("/subscriptions/9"))
        assertEquals(Landing(null, Notifier.TAB_SUBSCRIPTIONS), StreamNotifications.landingFor("/subscriptions"))
        assertEquals(Landing("settings/NOTIFY", null), StreamNotifications.landingFor("/settings/notifications"))
        assertEquals(Landing("settings/DEVICES", null), StreamNotifications.landingFor("/settings/devices"))
        assertEquals(Landing("settings/SITES_WEB", null), StreamNotifications.landingFor("/settings/sites"))
        assertEquals(Landing("settings", null), StreamNotifications.landingFor("/settings/unknown"))
        assertEquals(Landing(null, null), StreamNotifications.landingFor("/play/5/s01e02"))
        assertEquals(Landing(null, null), StreamNotifications.landingFor(null))
        assertEquals(Landing(null, null), StreamNotifications.landingFor("/library/x/item/y"))
    }

    @Test fun `collapse key replaces, otherwise each outbox id is its own notification`() {
        val a = StreamNotifications.parse(json, data(1, "第一集"))!!
        val b = StreamNotifications.parse(json, data(2, "第二集"))!!
        assertEquals(StreamNotifications.notificationId(a), StreamNotifications.notificationId(b))
        val c = a.copy(collapse = null)
        val d = b.copy(collapse = null)
        assertNotEquals(StreamNotifications.notificationId(c), StreamNotifications.notificationId(d))
        assertNotEquals(StreamNotifications.notificationId(a), StreamNotifications.notificationId(c))
    }

    @Test fun `stale replays are not shown`() {
        val n = StreamNotifications.parse(json, data(1, "旧的"))!!
        assertFalse(StreamNotifications.isStale(n, n.sentAt + 60))
        assertTrue(StreamNotifications.isStale(n, n.sentAt + StreamNotifications.STALE_SECONDS + 1))
        assertFalse(StreamNotifications.isStale(n.copy(sentAt = 0), 10_000_000_000L))
    }

    @Test fun `backoff doubles with jitter, caps and resets`() {
        val max = Backoff(baseMs = 1_000, maxMs = 16_000, random = { 1.0 })
        assertEquals(listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 16_000L), List(6) { max.next() })
        max.reset()
        assertEquals(0, max.attempt)
        assertEquals(1_000L, max.next())
        val min = Backoff(baseMs = 1_000, maxMs = 16_000, random = { 0.0 })
        assertEquals(listOf(500L, 1_000L, 2_000L), List(3) { min.next() })
        // 默认：2 秒起，5 分钟封顶
        val real = Backoff()
        repeat(30) { assertTrue(real.next() in 1_000L..300_000L) }
    }

    @Test fun `stream url carries the resume cursor`() {
        assertEquals(
            "http://nas.local:3000/api/v1/push/me/stream?since=42",
            PushStreamConnection.url("http://nas.local:3000/api/v1/", 42),
        )
        assertTrue(PushStreamConnection.url("https://a.example/api/v1", -5).endsWith("since=0"))
    }

    @Test fun `one connection replays then ends when server closes`() = runBlocking {
        val status = """{"server":"家里的 NAS","today":{"imported":5,"updated":2},"downloads":{"active":1,""" +
            """"speed":6500000,"progress":0.5,"items":[{"title":"遮天","episode":"E135","progress":0.5,"eta":540,"state":"downloading"}]}}"""
        val body = ": connected\n\n" +
            "event: status\ndata: $status\n\n" +
            "event: status\ndata: {broken\n\n" +
            "id: 5\nevent: notification\ndata: ${data(5, "第一条")}\n\n" +
            ": heartbeat\n\n" +
            "event: other\ndata: {}\n\n" +
            "id: 6\nevent: notification\ndata: ${data(6, "第二条")}\n\n"
        server.enqueue(MockResponse().setHeader("Content-Type", "text/event-stream").setBody(body))
        val client = OkHttpClient.Builder().readTimeout(5, TimeUnit.SECONDS).build()
        val base = server.url("/api/v1").toString()
        val signals = withTimeout(5_000) { PushStreamConnection.open(client, base, 4, json).toList() }
        assertEquals(StreamSignal.Opened, signals.first())
        val items = signals.filterIsInstance<StreamSignal.Notification>().map { it.item }
        assertEquals(listOf(5L, 6L), items.map { it.id })
        assertEquals(listOf("第一条", "第二条"), items.map { it.title })
        // 状态快照：坏的那帧丢掉，不影响通知
        val snapshot = signals.filterIsInstance<StreamSignal.Status>().single().snapshot
        assertEquals("家里的 NAS", snapshot.server)
        assertEquals(5, snapshot.today.imported)
        assertEquals("E135", snapshot.downloads!!.items.single().episode)
        assertEquals(6_500_000L, snapshot.downloads!!.speed)
        val request = server.takeRequest()
        assertEquals("/api/v1/push/me/stream", request.requestUrl!!.encodedPath)
        assertEquals("4", request.requestUrl!!.queryParameter("since"))
        assertEquals("text/event-stream", request.getHeader("Accept"))
    }

    @Test fun `http errors surface with status code`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(409).setBody("""{"success":false}"""))
        val client = OkHttpClient()
        try {
            withTimeout(5_000) { PushStreamConnection.open(client, server.url("/api/v1").toString(), 0, json).toList() }
            fail("应该失败")
        } catch (e: StreamHttpException) {
            assertEquals(409, e.code)
        }
    }
}
