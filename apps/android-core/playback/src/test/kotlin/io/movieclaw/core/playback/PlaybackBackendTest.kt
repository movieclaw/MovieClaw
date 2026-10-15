package io.movieclaw.core.playback

import io.movieclaw.core.model.generated.ClientCapabilityIn
import io.movieclaw.core.model.generated.PlaybackProgressRequest
import io.movieclaw.core.model.generated.PlaybackSessionRequest
import io.movieclaw.core.network.OkHttpTransport
import io.movieclaw.core.network.ServerAddress
import io.movieclaw.core.network.generated.McApi
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** 成员 / 访客两种身份的播放接口落点：访客一律走 /share/{slug}/playback/…，且没有成员专属的能力 */
class PlaybackBackendTest {
    private val server = MockWebServer()
    private lateinit var api: McApi

    @Before
    fun setUp() {
        server.start()
        val address = ServerAddress.parse(server.url("/").toString())!!
        api = McApi(OkHttpTransport(address.apiBase, OkHttpClient(), { null }))
    }

    @After
    fun tearDown() = server.close()

    private fun ok(data: String = "{}") = server.enqueue(MockResponse.Builder().code(200).body("""{"data":$data}""").build())

    private val session = PlaybackSessionRequest(capability = ClientCapabilityIn(), mediaItemId = 7)
    private val progress = PlaybackProgressRequest(mediaItemId = 7, event = "progress")

    @Test
    fun shareBackendUsesTheSharePlaybackChannel() = runTest {
        val backend = ShareBackend(api, "abc123")
        repeat(6) { ok() }
        backend.startSession(session)
        backend.pingSession("s1")
        backend.stopSession("s1")
        backend.progress(progress)
        backend.itemInfo(7)
        backend.episodes(7, 2)
        val calls = List(6) { server.takeRequest().let { "${it.method} ${it.url.encodedPath}${it.url.query?.let { q -> "?$q" } ?: ""}" } }
        assertEquals(
            listOf(
                "POST /api/v1/share/abc123/playback/sessions",
                "POST /api/v1/share/abc123/playback/sessions/s1/ping",
                "DELETE /api/v1/share/abc123/playback/sessions/s1",
                "POST /api/v1/share/abc123/playback/progress",
                "GET /api/v1/share/abc123/playback/items/7",
                "GET /api/v1/share/abc123/playback/items/7/episodes?season_number=2",
            ),
            calls,
        )
    }

    @Test
    fun shareBackendHasNoMemberOnlyAbilities() = runTest {
        val backend = ShareBackend(api, "abc123")
        assertNull(backend.enableSoftwareTranscode())
        assertNull(backend.trickplay(1, "t"))
        assertFalse(backend.reportsMetrics)
        // 访客没有的接口一个请求都不发
        assertEquals(0, server.requestCount)
    }

    @Test
    fun memberBackendUsesTheMemberPlaybackApi() = runTest {
        val backend = MemberBackend(api)
        repeat(3) { ok() }
        ok("""{"software_transcode_enabled":true}""")
        backend.startSession(session)
        backend.stopSession("s1")
        backend.progress(progress)
        assertTrue(backend.enableSoftwareTranscode())
        assertTrue(backend.reportsMetrics)
        val paths = List(4) { server.takeRequest().let { "${it.method} ${it.url.encodedPath}" } }
        assertEquals(
            listOf(
                "POST /api/v1/playback/sessions",
                "DELETE /api/v1/playback/sessions/s1",
                "POST /api/v1/playback/progress",
                "PUT /api/v1/playback/policy",
            ),
            paths,
        )
    }
}
