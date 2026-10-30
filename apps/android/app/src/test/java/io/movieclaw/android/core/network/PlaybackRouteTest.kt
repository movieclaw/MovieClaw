package io.movieclaw.android.core.network

import io.movieclaw.android.core.session.TokenVault
import io.movieclaw.core.model.generated.PlaybackSessionRequest
import io.movieclaw.core.model.generated.ClientCapabilityIn
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
class PlaybackRouteTest {
    @Test fun loginOnWanThenStartOnLan() = runTest {
        MockWebServer().use { lan ->
            lan.start()
            val login = "https://movie.example.com"
            val http = OkHttpClient()
            val factory = ApiFactory(Json { ignoreUnknownKeys = true }, http, http,
                TokenVault(RuntimeEnvironment.getApplication()), ShareCookieJar())
            factory.setRoutedBase(login, lan.url("/api/v1").toString())
            val channel = factory.corePlaybackForIdentity(login, null)
            lan.enqueue(MockResponse().setBody("""{"data":{"decision":{"outcome":"play","tier":0,"file_id":7},"stream_url":"/api/v1/playback/files/7/stream?token=t"}}"""))
            channel.api.playbackSessionStart(PlaybackSessionRequest(capability = ClientCapabilityIn(), mediaItemId = 7))
            assertEquals("/api/v1/playback/sessions", lan.takeRequest().path)
            // 与 PlaybackSessionHolder 一样，从同一通道取得媒体入口快照。
            val mediaServer = channel.server
            assertEquals(lan.url("/api/v1/playback/files/7/stream?token=t"),
                mediaServer.resolve("/api/v1/playback/files/7/stream?token=t"))
        }
    }
    @Test fun mediaFailureDoesNotRetryOldTokenOnAnotherEntry() {
        val context = RuntimeEnvironment.getApplication()
        val vault = TokenVault(context)
        MockWebServer().use { dead -> MockWebServer().use { alternate ->
            dead.start(); alternate.start()
            val login = dead.url("/").toString().trimEnd('/')
            val previousProvider = ServerRoutes.provider
            val previousAlternates = ServerRoutes.alternates
            val previousHardError = ServerRoutes.onHardError
            try {
                ServerRoutes.provider = { login }
                ServerRoutes.alternates = listOf(alternate.url("/").toString())
                var hardErrors = 0
                ServerRoutes.onHardError = { hardErrors++ }
                val http = NetworkModule.playbackClient(vault).newBuilder().retryOnConnectionFailure(false).build()
                val channel = ApiFactory(Json, http, http, vault, ShareCookieJar()).corePlaybackForIdentity(login, null)
                dead.shutdown()
                org.junit.Assert.assertThrows(java.io.IOException::class.java) {
                    playbackMediaClient(channel.http).newCall(okhttp3.Request.Builder()
                        .url(channel.server.resolve("/api/v1/playback/files/7/stream?token=old")!!).build()).execute().close()
                }
                assertEquals(0, alternate.requestCount)
                assertEquals(0, hardErrors)
            } finally {
                ServerRoutes.provider = previousProvider
                ServerRoutes.alternates = previousAlternates
                ServerRoutes.onHardError = previousHardError
            }
        } }
    }

}
