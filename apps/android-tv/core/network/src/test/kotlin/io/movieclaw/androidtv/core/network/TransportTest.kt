package io.movieclaw.androidtv.core.network

import io.movieclaw.androidtv.core.model.generated.ClientCapabilityIn
import io.movieclaw.androidtv.core.model.generated.PlaybackSessionRequest
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** 协议契约：信封拆包、错误、令牌、对新旧服务端的宽容（docs/design/androidtv-app.md §3.2）。 */
class TransportTest {
    private val server = MockWebServer()
    private var token: String? = "mclaw_abc"
    private lateinit var api: McApi

    @Before
    fun setUp() {
        server.start()
        val address = ServerAddress.parse(server.url("/").toString())!!
        api = McApi(OkHttpTransport(address.apiBase, OkHttpClient(), { token }))
    }

    @After
    fun tearDown() = server.close()

    private fun reply(code: Int, body: String) =
        server.enqueue(MockResponse.Builder().code(code).body(body).build())

    @Test
    fun unwrapsEnvelopeAndSendsBearerToken() = runTest {
        reply(200, """{"success":true,"code":"OK","message":"success","data":{"initialized":true}}""")
        assertTrue(api.authBootstrapStatus().initialized)
        val request = server.takeRequest()
        assertEquals("/api/v1/auth/bootstrap", request.url.encodedPath)
        assertEquals("Bearer mclaw_abc", request.headers["Authorization"])
    }

    @Test
    fun omitsAuthorizationWithoutToken() = runTest {
        token = null
        reply(200, """{"data":{"initialized":false}}""")
        api.authBootstrapStatus()
        assertNull(server.takeRequest().headers["Authorization"])
    }

    @Test
    fun healthIsNotEnveloped() = runTest {
        reply(200, """{"status":"ok","service":"movieclaw","environment":"local","spec_hash":"x","version":"0.33.0"}""")
        assertEquals("0.33.0", api.healthCheck().version)
    }

    @Test
    fun toleratesMissingUnknownAndNullFields() = runTest {
        // 老服务端缺字段、新服务端多字段、非空字段给了 null：都不该让整包失败
        reply(200, """{"data":{"items":[{"media_item_id":7,"title":null,"brand_new_field":{"x":1}}]}}""")
        val item = api.playbackUpNext().items.single()
        assertEquals(7L, item.mediaItemId)
        assertEquals("", item.title)
        assertEquals(0L, item.positionMs)
    }

    @Test
    fun mapsErrorEnvelope() = runTest {
        reply(400, """{"success":false,"code":"AUTHORIZATION_DENIED","message":"已拒绝","data":null}""")
        try {
            api.authDeviceToken(io.movieclaw.androidtv.core.model.generated.DeviceTokenRequest(deviceCode = "d"))
            fail("应当抛出 ApiException")
        } catch (e: ApiException) {
            assertEquals(400, e.status)
            assertEquals("AUTHORIZATION_DENIED", e.code)
            assertEquals("已拒绝", e.message)
        }
    }

    @Test
    fun pendingPairingDecodesAsNull() = runTest {
        reply(202, """{"success":true,"code":"AUTHORIZATION_PENDING","message":"等待批准","data":null}""")
        assertNull(api.authDeviceToken(io.movieclaw.androidtv.core.model.generated.DeviceTokenRequest(deviceCode = "d")))
    }

    @Test
    fun unreachableServerIsDistinguished() = runTest {
        server.close()
        try {
            api.authBootstrapStatus()
            fail("应当抛出 UnreachableException")
        } catch (_: UnreachableException) {
        }
    }

    @Test
    fun requestOmitsNullOptionalFields() = runTest {
        reply(200, """{"data":{"decision":{"outcome":"plan","tier":0},"stream_url":"/x"}}""")
        api.playbackSessionStart(
            PlaybackSessionRequest(
                mediaItemId = 1,
                capability = ClientCapabilityIn(containers = listOf("mkv"), localTracks = true),
                client = ClientIdentity.KIND,
            ),
        )
        val body = Json.parseToJsonElement(server.takeRequest().body!!.utf8()).jsonObject
        assertEquals(setOf("media_item_id", "capability", "client"), body.keys)
        assertFalse("video" in body.getValue("capability").jsonObject)
    }

    @Test
    fun queryParametersAreEncoded() = runTest {
        reply(200, """{"data":{"query":"x","items":[],"people":[],"suggestions":[]}}""")
        api.searchLibrary(q = "星际 穿越", limit = 24)
        val url = server.takeRequest().url
        assertEquals("星际 穿越", url.queryParameter("q"))
        assertEquals("24", url.queryParameter("limit"))
    }

    /** 连上了只是响应慢：提示「响应太慢」，不叫人去查地址（同 Apple 端 .timeout） */
    @Test
    fun readTimeoutSaysServerIsSlowNotUnreachable() = runTest {
        val address = ServerAddress.parse(server.url("/").toString())!!
        val quick = OkHttpClient.Builder().readTimeout(300, java.util.concurrent.TimeUnit.MILLISECONDS).build()
        val slowApi = McApi(OkHttpTransport(address.apiBase, quick, { token }))
        server.enqueue(MockResponse.Builder().headersDelay(2, java.util.concurrent.TimeUnit.SECONDS).body("""{"data":{"initialized":true}}""").build())
        try {
            slowApi.authBootstrapStatus()
            fail("应当超时")
        } catch (e: UnreachableException) {
            assertEquals("服务器响应太慢，请求已取消——请稍后重试", e.message)
        }
    }

    /** 开播放会话走单独的长读超时：服务端采样关键帧要几十秒时不该被当成连不上 */
    @Test
    fun sessionStartWaitsLongerThanOrdinaryCalls() = runTest {
        val address = ServerAddress.parse(server.url("/").toString())!!
        val quick = OkHttpClient.Builder().readTimeout(300, java.util.concurrent.TimeUnit.MILLISECONDS).build()
        val slowApi = McApi(OkHttpTransport(address.apiBase, quick, { token }))
        server.enqueue(MockResponse.Builder().headersDelay(1, java.util.concurrent.TimeUnit.SECONDS).body("""{"data":{}}""").build())
        try {
            slowApi.playbackSessionStart(PlaybackSessionRequest(mediaItemId = 1, capability = ClientCapabilityIn()))
        } catch (e: UnreachableException) {
            fail("不该超时：${e.message}")
        }
        assertEquals("/api/v1/playback/sessions", server.takeRequest().url.encodedPath)
    }
}
