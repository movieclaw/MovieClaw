package io.movieclaw.core.playback

import android.app.Application
import io.movieclaw.core.network.ClientIdentity
import io.movieclaw.core.network.OkHttpTransport
import io.movieclaw.core.network.ServerAddress
import io.movieclaw.core.network.generated.McApi
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** 真实 HTTP 协商 → 控制器 → Exo 装载；引擎事件由测试注入，不依赖设备解码器。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class PlaybackReconnectTest {
    @Test fun bufferingStreamDropRetriesRouteAndSessionThenResumesAtOriginalPosition() = runTest {
        Fixture(this).use { f ->
            f.open()
            f.await { f.controller.state.value.phase == Phase.Buffering }
            assertFalse(f.reportedStart())
            f.connectFailure = IOException("network disconnected")
            f.dropStream()
            runCurrent()
            assertEquals(Phase.SessionStarting, f.controller.state.value.phase)
            assertEquals(listOf(false, true), f.connections)

            // 选路暂时失败：两秒后再试；选路恢复了，开会话仍可能返回 503。
            f.connectFailure = null
            f.status = 503
            f.controller.flash("")
            advanceTimeBy(1_999)
            runCurrent()
            assertEquals(2, f.connections.size)
            advanceTimeBy(1)
            f.await { f.sessions.size == 2 }
            f.awaitRequestFinished()
            assertEquals(Phase.SessionStarting, f.controller.state.value.phase)
            assertFalse(f.reportedStart())

            f.status = 200
            advanceTimeBy(3_999)
            runCurrent()
            assertEquals(3, f.connections.size)
            advanceTimeBy(1)
            f.await { f.connections.size == 4 && f.controller.state.value.phase == Phase.Buffering }
            assertEquals(listOf(false, true, true, true), f.connections)
            assertTrue(f.sessions.all { it.body!!.utf8().contains("\"start_ms\":45000") })
            assertEquals(45_000L, f.controller.state.value.positionMs)
            assertEquals(45_000L, f.controller.player.currentPosition)
            assertTrue(f.controller.player.playWhenReady)
            f.event("onPlaying")
            assertEquals(Phase.Playing, f.controller.state.value.phase)
            assertTrue(f.reportedStart())

            // 已恢复出画，后续非断流的会话请求不能沿用断流恢复状态。
            f.status = 503
            f.open(Phase.SessionStarting)
            f.await { f.controller.state.value.phase == Phase.Error }
        }
    }

    @Test fun initialNetworkFailureDoesNotRetry() = runTest {
        Fixture(this).use { f ->
            f.connectFailure = IOException("network disconnected")
            f.open()
            f.await { f.controller.state.value.phase == Phase.Error }
            advanceTimeBy(60_000)
            runCurrent()
            assertEquals(listOf(false), f.connections)
            assertTrue(f.sessions.isEmpty())
        }
    }

    @Test fun initial503DoesNotRetry() = runTest {
        Fixture(this).use { f ->
            f.status = 503
            f.open()
            f.await { f.controller.state.value.phase == Phase.Error }
            advanceTimeBy(60_000)
            runCurrent()
            assertEquals(listOf(false), f.connections)
            assertEquals(1, f.sessions.size)
        }
    }

    @Test fun streamDropBackoffIsBoundedAndManualRetryStartsFresh() = runTest {
        Fixture(this).use { f ->
            f.open()
            f.await { f.controller.state.value.phase == Phase.Buffering }
            f.status = 503
            f.dropStream()
            f.await { f.sessions.size == 2 }
            f.awaitRequestFinished()
            for ((index, seconds) in listOf(2L, 4L, 8L, 15L, 15L, 15L).withIndex()) {
                assertEquals(Phase.SessionStarting, f.controller.state.value.phase)
                f.controller.flash("")
                advanceTimeBy(seconds * 1000)
                f.await { f.sessions.size == index + 3 }
                f.awaitRequestFinished()
            }
            assertEquals(Phase.Error, f.controller.state.value.phase)
            assertEquals(45_000L, f.controller.state.value.positionMs)
            f.controller.retry()
            f.await { f.controller.state.value.phase == Phase.Error }
            advanceTimeBy(60_000)
            runCurrent()
            assertEquals(9, f.sessions.size)
        }
    }

    private class Fixture(val scope: TestScope) : AutoCloseable {
        val sessions = CopyOnWriteArrayList<RecordedRequest>()
        val connections = mutableListOf<Boolean>()
        @Volatile var status = 200
        var connectFailure: IOException? = null
        private val server = MockWebServer().apply {
            dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.url.encodedPath == "/api/v1/playback/sessions") {
                        sessions += request
                        return MockResponse.Builder().code(status).body(
                            """{"data":{"decision":{"outcome":"play","tier":0,"file_id":7},"stream_url":"/stream?token=t","start_ms":45000}}"""
                        ).build()
                    }
                    return MockResponse.Builder().body("""{"data":{}}""").build()
                }
            }
            start()
        }
        private val http = OkHttpClient()
        private val address = ServerAddress.parse(server.url("/").toString())!!
        private val backend = MemberBackend(McApi(OkHttpTransport(address.apiBase, http)))
        val controller = PlaybackController(
            RuntimeEnvironment.getApplication(), backend, address, http,
            ClientIdentity("test", 1, "test", "15"), "device", null,
            object : PrefsStore {
                override fun string(key: String): String? = null
                override fun putString(key: String, value: String?) {}
            }, scope, PlaybackTarget(mediaItemId = 7, startMs = 45_000),
            host = PlaybackHost(ownsMediaSession = false),
            connect = { reselect ->
                connections += reselect
                connectFailure?.let { throw it }
                PlaybackConnection(backend, address)
            },
        )

        // 不启动无限 tick 循环；仍经过完整会话响应处理和 Exo 装载。
        fun open(phase: Phase = Phase.Deciding) {
            PlaybackController::class.java.getDeclaredMethod("request", Long::class.javaObjectType,
                Phase::class.java, Boolean::class.javaPrimitiveType).apply { isAccessible = true }
                .invoke(controller, 45_000L, phase, false)
        }

        fun event(name: String) {
            PlaybackController::class.java.getDeclaredMethod(name).apply { isAccessible = true }.invoke(controller)
        }

        fun dropStream() {
            PlaybackController::class.java.getDeclaredMethod("engineFailed", String::class.java, FailureCause::class.java)
                .apply { isAccessible = true }.invoke(controller, "network disconnected", FailureCause.Network)
        }

        fun reportedStart() = PlaybackController::class.java.getDeclaredField("reportedStart")
            .apply { isAccessible = true }.getBoolean(controller)

        fun awaitRequestFinished() = await {
            controller.state.value.phase == Phase.Error || controller.state.value.notice == "连接中断，正在重连…"
        }

        fun await(condition: () -> Boolean) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
            while (!condition() && System.nanoTime() < deadline) {
                scope.runCurrent()
                Thread.sleep(10)
            }
            assertTrue("等待控制器状态超时：${controller.state.value}", condition())
        }

        override fun close() {
            controller.close()
            scope.runCurrent()
            server.close()
        }
    }
}
