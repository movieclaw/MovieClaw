package io.movieclaw.android.core.network

import android.app.Application
import io.movieclaw.android.core.session.TokenVault
import io.movieclaw.core.network.ClientIdentity
import io.movieclaw.core.playback.FailureCause
import io.movieclaw.core.playback.MemberBackend
import io.movieclaw.core.playback.Phase
import io.movieclaw.core.playback.PlaybackConnection
import io.movieclaw.core.playback.PlaybackController
import io.movieclaw.core.playback.PlaybackHost
import io.movieclaw.core.playback.PlaybackTarget
import io.movieclaw.core.playback.PrefsStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** 真实 HTTP 会话 → 控制器 → Exo 媒体地址；模拟网络断流后等待选路、从原位置重开。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class PlaybackRoutingScenarioTest {
    @Test fun originalFileReconnectsOnSelectedRoute() = scenario(0)
    @Test fun hlsReconnectsOnSelectedRoute() = scenario(1)

    private fun scenario(tier: Int) = runTest {
        val stream = if (tier == 0) "/api/v1/playback/files/7/stream?token=t"
            else "/api/v1/playback/sessions/s/stream.m3u8?token=t"
        MockWebServer().use { lan -> MockWebServer().use { wan ->
            val requests = java.util.concurrent.CopyOnWriteArrayList<RecordedRequest>()
            fun dispatcher() = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    requests += request
                    return when {
                        request.path!!.contains("/health?") -> MockResponse()
                            .setHeader("X-Movieclaw-Spec-Hash", "test")
                            .setBody("""{"instance_id":"same-server"}""")
                        request.path == "/api/v1/playback/sessions" -> MockResponse().setBody(
                            """{"data":{"decision":{"outcome":"play","tier":$tier,"file_id":7},"stream_url":"$stream","start_ms":45000}}""")
                        else -> MockResponse().setBody("{}")
                    }
                }
            }
            lan.dispatcher = dispatcher()
            wan.dispatcher = dispatcher()
            lan.start(); wan.start()
            val context = RuntimeEnvironment.getApplication()
            val http = OkHttpClient()
            val factory = ApiFactory(Json { ignoreUnknownKeys = true }, http, http, TokenVault(context), ShareCookieJar())
            val login = "https://movie.example.invalid"
            factory.setRoutedBase(login, lan.url("/api/v1").toString())
            val first = factory.corePlaybackForIdentity(login, null)
            val addresses = ServerAddressBook(context, factory)
            // 已登录取回的地址簿；断流时不先向失效入口拉地址簿。
            ServerAddressBook::class.java.getDeclaredField("lastBook").apply { isAccessible = true }
                .set(addresses, ServerAddressesView(instanceId = "same-server", addresses = listOf(
                    ServerAddressItem(wan.url("/").toString().trimEnd('/'), "wan", "manual"))))
            val gate = CompletableDeferred<Unit>()
            var waiting = false
            val controller = PlaybackController(
                context, MemberBackend(first.api), first.server, playbackMediaClient(first.http),
                ClientIdentity("test", 1, "test", "15"), "device", null,
                object : PrefsStore {
                    override fun string(key: String): String? = null
                    override fun putString(key: String, value: String?) {}
                }, this, PlaybackTarget(mediaItemId = 7, startMs = 45000),
                host = PlaybackHost(ownsMediaSession = false),
                connect = { reselect ->
                    if (reselect) {
                        waiting = true
                        gate.await()
                        addresses.reselectAndAwait(login)
                    }
                    val channel = factory.corePlaybackForIdentity(login, null)
                    PlaybackConnection(MemberBackend(channel.api), channel.server)
                },
            )
            fun pumpUntil(condition: () -> Boolean) {
                val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(30)
                while (!condition() && System.nanoTime() < deadline) {
                    runCurrent()
                    Thread.sleep(10)
                }
                assertTrue("等待控制器状态超时：${controller.state.value}", condition())
            }
            try {
                // 只启动协商，不启动无限 tick 循环；仍经过真实的会话响应处理和 Exo 装载。
                PlaybackController::class.java.getDeclaredMethod("request", java.lang.Long::class.java, Phase::class.java,
                    Boolean::class.javaPrimitiveType).apply { isAccessible = true }
                    .invoke(controller, 45000L, Phase.Deciding, false)
                pumpUntil { controller.player.currentMediaItem != null }
                assertEquals(lan.url(stream).toString(),
                    controller.player.currentMediaItem!!.localConfiguration!!.uri.toString())
                assertEquals(45000L, controller.state.value.positionMs)
                factory.setRoutedBase(login, wan.url("/api/v1").toString())
                val paths = listOf("/api/v1/playback/files/7/stream?token=t", "/api/v1/playback/sessions/s/master.m3u8?token=t",
                    "/api/v1/playback/subtitles/7?token=t", "/api/v1/playback/trickplay/7/0.jpg?token=t",
                    "/api/v1/playback/files/7/clips/0?token=t")
                paths.forEach { assertEquals(lan.url(it).toString(), controller.resolve(it)) }
                assertEquals("https://cdn.example.com/video", controller.resolve("https://cdn.example.com/video"))
                // 外部路由变化不影响正在播放的一轮；断流才会等待新选路。
                PlaybackController::class.java.getDeclaredMethod("engineFailed", String::class.java, FailureCause::class.java)
                    .apply { isAccessible = true }.invoke(controller, "network disconnected", FailureCause.Network)
                runCurrent()
                assertTrue(waiting)
                assertEquals(0, wan.requestCount)
                gate.complete(Unit)
                pumpUntil { controller.player.currentMediaItem?.localConfiguration?.uri?.port == wan.port }
                paths.forEach { assertEquals(wan.url(it).toString(), controller.resolve(it)) }
                assertEquals(45000L, controller.state.value.positionMs)
                val resumed = requests.last { it.path == "/api/v1/playback/sessions" }
                assertTrue(resumed.body.readUtf8().contains("\"start_ms\":45000"))
                val health = requests.indexOfFirst { it.path!!.contains("/health?") }
                assertTrue(health >= 0 && health < requests.indexOf(resumed))
            } finally {
                controller.close()
                runCurrent()
            }
        } }
    }
}
