package io.movieclaw.android.feature.reels

import io.movieclaw.android.core.model.ReelItemView
import io.movieclaw.android.core.model.ReelPlayView
import io.movieclaw.android.core.model.ReelSegmentView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.playback.PlaybackNetwork
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ReelsPlayersTest {
    private fun api(): ApiFactory {
        val client = OkHttpClient()
        return ApiFactory(
            Json { ignoreUnknownKeys = true }, client, client,
            io.movieclaw.android.core.session.TokenVault(RuntimeEnvironment.getApplication()),
            io.movieclaw.android.core.network.ShareCookieJar(),
        )
    }

    @Test fun leavingDuringNegotiationDoesNotFallBackToAudibleDirectPlayback() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val deviceId = CompletableDeferred<String?>()
        val events = mutableListOf<String>()
        val players = ReelsPlayers(
            RuntimeEnvironment.getApplication(), api(), backgroundScope,
            { "http://127.0.0.1:1" }, { deviceId.await() },
            { _, event, _, _, _, _ -> events.add(event) },
        )
        try {
            players.setNetwork(PlaybackNetwork.AWAY)
            players.setQuality(720)
            val item = ReelItemView(id = "clip", play = ReelPlayView(streamUrl = "/video.mp4"))
            players.settle(item, 0, listOf(item))
            runCurrent()
            players.release()
            deviceId.complete("device")
            runCurrent()
            assertNull(players.currentEngine)
            assertNull(players.currentItemId())
            assertFalse(players.playing)
            assertEquals(listOf("impression"), events)
        } finally {
            players.release()
            Dispatchers.resetMain()
        }
    }

    @Test fun replayReinstatesTheClipEndBoundary() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val events = mutableListOf<String>()
        val players = ReelsPlayers(
            RuntimeEnvironment.getApplication(), api(), backgroundScope,
            { "http://127.0.0.1:1" },
            onEvent = { _, event, _, _, _, _ -> events.add(event) },
        )
        try {
            // 起点/终点均为零让真实 Exo 在无需解码资源的情况下立即命中片段边界。
            val item = ReelItemView(
                id = "clip", segment = ReelSegmentView(startMs = 0, endMs = 0),
                play = ReelPlayView(streamUrl = "/video.mp4"),
            )
            players.settle(item, 0, listOf(item))
            runCurrent()
            advanceTimeBy(250)
            runCurrent()
            assertTrue(players.ended)
            players.replay()
            assertFalse(players.ended)
            runCurrent()
            advanceTimeBy(250)
            runCurrent()
            assertTrue(players.ended)
            assertFalse(players.playing)
            assertEquals(2, events.count { it == "complete" })
        } finally {
            players.release()
            Dispatchers.resetMain()
        }
    }
}
