package io.movieclaw.core.playback

import android.app.Application
import android.media.MediaFormat
import androidx.media3.common.Format
import androidx.media3.common.C
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.mediacodec.MediaCodecDecoderException
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecRenderer
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.exoplayer.trackselection.TrackSelectorResult
import io.movieclaw.core.model.McJson
import io.movieclaw.core.model.generated.PlaybackProgressRequest
import io.movieclaw.core.model.generated.PlaybackSessionRequest
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
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.MediaCodecInfoBuilder
import org.robolectric.shadows.ShadowMediaCodecList

/** 真实 HTTP 协商 → 控制器 → Exo 装载；引擎事件由测试注入，不依赖设备解码器。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class, UnstableApi::class)
class PlaybackReconnectTest {
    @Test fun ordinaryDecodeFailureRetriesThenFallsBackWithoutDisablingHevcForTheNextMovie() = runTest {
        installHevcDecoder()
        val prefs = MemoryPrefs()
        val hevc = Fixture(this, prefs = prefs).use { f ->
            f.open()
            f.await { f.controller.state.value.phase == Phase.Buffering }
            val hevc = f.sessionRequest(0).capability.video!!.single { it.codec == "hevc" }
            assertTrue(hevc.maxHeight!! >= 2160)
            assertEquals(true, hevc.powerEfficient)
            // Tier is not known when the first request is made, so PGS capability
            // is conservative and cannot suppress a server burn on HLS.
            assertFalse(f.sessionRequest(0).capability.pgsOverlay == true)
            assertFalse(f.sessionRequest(0).burnRequested == true)

            // 普通解码失败先原位重开；预算耗尽后仅当前影片回退服务端流。
            repeat(2) { index ->
                f.decoderFailure(PlaybackException.ERROR_CODE_DECODING_FAILED)
                f.await { f.sessions.size == index + 2 && f.controller.state.value.phase == Phase.Buffering }
                assertEquals(if (index == 0) null else listOf(0L), f.sessionRequest(index + 1).failedTiers)
                assertTrue(DecoderDenylist(f.prefs, "test").entries().isEmpty())
            }

            hevc
        }
        // 退出播放后用同一份偏好打开另一部影片：HEVC 硬解和 4K 能力都仍在。
        Fixture(this, prefs = prefs, mediaItemId = 8).use { next ->
            next.open()
            next.await { next.controller.state.value.phase == Phase.Buffering }
            assertEquals(8L, next.sessionRequest(0).mediaItemId)
            assertEquals(hevc, next.sessionRequest(0).capability.video!!.single { it.codec == "hevc" })
            assertEquals(null, next.sessionRequest(0).failedTiers)
        }
    }

    @Test fun finalDecoderInitializationFailureStillPersistsTheBlacklistAndFallsBackImmediately() = runTest {
        installHevcDecoder()
        Fixture(this).use { f ->
            f.open()
            f.await { f.controller.state.value.phase == Phase.Buffering }
            f.decoderFailure(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED)
            f.await { f.sessions.size == 2 && f.controller.state.value.phase == Phase.Buffering }
            assertEquals(listOf(0L), f.sessionRequest(1).failedTiers)
            val entry = DecoderDenylist(f.prefs, "test").entries().getValue("OMX.MS.HEVC.Decoder")
            assertEquals("video/hevc", entry.mime)
            assertEquals("播放失败：ERROR_CODE_DECODER_INIT_FAILED", entry.reason)
            assertFalse(f.sessionRequest(1).capability.video!!.any { it.codec == "hevc" })
        }
    }

    @Test fun serverStreamDecodeFailuresStillStepDownWithoutBlacklisting() = runTest {
        for (code in listOf(PlaybackException.ERROR_CODE_DECODING_FAILED, PlaybackException.ERROR_CODE_DECODER_INIT_FAILED)) {
            Fixture(this, tier = 3).use { f ->
                f.open()
                f.await { f.controller.state.value.phase == Phase.Buffering }
                f.decoderFailure(code)
                f.await { f.sessions.size == 2 && f.controller.state.value.phase == Phase.Buffering }
                assertEquals(listOf(3L), f.sessionRequest(1).failedTiers)
                assertTrue(DecoderDenylist(f.prefs, "test").entries().isEmpty())
            }
        }
    }

    @Test fun selectingEmbeddedPgsStaysLocalUntilBurnIsExplicit() = runTest {
        Fixture(this, subtitleKind = "pgs").use { f ->
            f.open()
            f.await { f.controller.state.value.phase == Phase.Buffering }
            f.controller.selectSubtitle("embedded:0")
            runCurrent()
            assertEquals(1, f.sessions.size)
            assertFalse(f.sessionRequest(0).burnRequested == true)
            val group = f.emitEmbeddedPgsTrack()
            val override = f.controller.player.trackSelectionParameters.overrides.get<TrackGroup, TrackSelectionOverride>(group)
            assertTrue(override != null)
            assertEquals(listOf(0), override!!.trackIndices)

            f.controller.burnSubtitle("embedded:0")
            f.await { f.decides.size == 1 }
            f.await { f.sessions.size == 2 }
            assertTrue(f.sessionRequest(1).burnRequested == true)
            assertTrue(f.sessionRequest(1).capability.pgsOverlay == true)
        }
    }

    @Test fun selectingPgsOnHlsFallsBackExplicitlyWithoutPretendingToRenderSidecar() = runTest {
        Fixture(this, subtitleKind = "pgs", tier = 1).use { f ->
            f.open()
            f.await { f.controller.state.value.phase == Phase.Buffering }
            f.controller.selectSubtitle("embedded:0")
            runCurrent()
            assertEquals(1, f.sessions.size)
            assertFalse(f.sessionRequest(0).burnRequested == true)
            assertEquals("embedded:0", f.controller.state.value.selectedSubtitle)
            assertTrue(f.controller.player.currentMediaItem?.localConfiguration?.subtitleConfigurations.orEmpty().none {
                it.mimeType == androidx.media3.common.MimeTypes.APPLICATION_PGS
            })
        }
    }

    @Test fun unburningPgsClearsUiRenderingAndProgressAcrossTheReplacementSession() = runTest {
        Fixture(this, subtitleKind = "pgs", tier = 1, unburnTier = 0).use { f ->
            f.open()
            f.await { f.controller.state.value.phase == Phase.Buffering }
            f.controller.selectSubtitle("embedded:0")
            f.controller.burnSubtitle("embedded:0")
            f.await { f.decides.size == 1 && f.sessions.size == 2 &&
                f.controller.decision?.video?.burnSubtitle == "embedded:0" &&
                f.controller.state.value.phase == Phase.Buffering }
            assertEquals("embedded:0", f.controller.state.value.selectedSubtitle)
            f.event("reportStart")
            f.await { f.progress.size == 1 }

            f.controller.unburnSubtitle()
            assertEquals(null, f.controller.state.value.selectedSubtitle)
            assertFalse(f.controller.state.value.engineSubtitles)
            assertEquals(null, f.controller.state.value.overlaySubtitleUrl)
            f.await { f.sessions.size == 3 && f.progress.size == 2 && f.controller.decision?.tier == 0L &&
                f.controller.state.value.phase == Phase.Buffering }

            assertEquals("off", f.sessionRequest(2).subtitleTrack)
            assertFalse(f.sessionRequest(2).burnRequested == true)
            assertEquals(null, f.controller.state.value.selectedSubtitle)
            assertFalse(f.controller.state.value.engineSubtitles)
            val group = f.emitEmbeddedPgsTrack()
            assertTrue(f.controller.player.trackSelectionParameters.overrides
                .get<TrackGroup, TrackSelectionOverride>(group) == null)
            assertEquals("off", f.progressRequest(1).subtitleTrack)
        }
    }

    @Test fun embeddedTextOnHlsUsesTheOverlayInsteadOfAnUnconfiguredExoTrack() = runTest {
        Fixture(this, subtitleKind = "vtt", tier = 1).use { f ->
            f.open()
            f.await { f.controller.state.value.phase == Phase.Buffering }
            f.controller.selectSubtitle("embedded:0")
            runCurrent()
            assertFalse(f.controller.state.value.engineSubtitles)
            assertTrue(f.controller.state.value.overlaySubtitleUrl?.contains("/subtitle?token=t&format=vtt") == true)
            assertTrue(f.controller.player.currentMediaItem?.localConfiguration?.subtitleConfigurations.orEmpty().isEmpty())
        }
    }

    @Test fun embeddedAssOnHlsUsesTheOverlayInsteadOfAnUnconfiguredExoTrack() = runTest {
        Fixture(this, subtitleKind = "ass", tier = 1).use { f ->
            f.open()
            f.await { f.controller.state.value.phase == Phase.Buffering }
            f.controller.selectSubtitle("embedded:0")
            runCurrent()
            assertFalse(f.controller.state.value.engineSubtitles)
            assertTrue(f.controller.state.value.overlaySubtitleUrl?.contains("/subtitle?token=t&format=vtt") == true)
            assertTrue(f.controller.player.currentMediaItem?.localConfiguration?.subtitleConfigurations.orEmpty().isEmpty())
        }
    }

    private fun installHevcDecoder() {
        val capabilities = MediaCodecInfoBuilder.CodecCapabilitiesBuilder.newBuilder()
            .setMediaFormat(MediaFormat.createVideoFormat("video/hevc", 3840, 2160))
            .setColorFormats(intArrayOf(android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)).build()
        ShadowMediaCodecList.addCodec(MediaCodecInfoBuilder.newBuilder()
            .setName("OMX.MS.HEVC.Decoder").setCapabilities(capabilities).build())
        MediaCodecUtil.clearDecoderInfoCache()
    }

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

    private class MemoryPrefs : PrefsStore {
        private val values = mutableMapOf<String, String>()
        override fun string(key: String) = values[key]
        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }

    private class Fixture(
        val scope: TestScope,
        val prefs: PrefsStore = MemoryPrefs(),
        private val mediaItemId: Long = 7,
        private val tier: Int = 0,
        private val subtitleKind: String? = null,
        private val unburnTier: Int? = null,
    ) : AutoCloseable {
        val sessions = CopyOnWriteArrayList<RecordedRequest>()
        val decides = CopyOnWriteArrayList<RecordedRequest>()
        val progress = CopyOnWriteArrayList<RecordedRequest>()
        val connections = mutableListOf<Boolean>()
        @Volatile var status = 200
        var connectFailure: IOException? = null
        private val server = MockWebServer().apply {
            dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.url.encodedPath == "/api/v1/playback/progress") {
                        progress += request
                        return MockResponse.Builder().body("""{"data":{"ended_by_admin":false}}""").build()
                    }
                    if (request.url.encodedPath == "/api/v1/playback/decide") {
                        decides += request
                        val body = McJson.decodeFromString<io.movieclaw.core.model.generated.PlaybackDecideRequest>(request.body!!.utf8())
                        val burn = if (body.burnRequested == true) ",\"burn_subtitle\":\"embedded:0\"" else ""
                        return MockResponse.Builder().body(
                            """{"data":{"outcome":"plan","tier":$tier,"file_id":7,"video":{"action":"transcode"$burn},"subtitles":[]}}""",
                        ).build()
                    }
                    if (request.url.encodedPath == "/api/v1/playback/sessions") {
                        sessions += request
                        val sessionBody = McJson.decodeFromString<PlaybackSessionRequest>(request.body!!.utf8())
                        val failed = sessionBody.failedTiers.orEmpty()
                        val nextTier = if (tier.toLong() in failed) tier + 1 else tier
                        val responseTier = if (sessionBody.subtitleTrack == "off") unburnTier ?: nextTier else nextTier
                        val decision = if (subtitleKind !== null) {
                            val burn = if (sessionBody.burnRequested == true) ",\"burn_subtitle\":\"embedded:0\"" else ""
                            ",\"subtitles\":[{\"track_ref\":\"embedded:0\",\"kind\":\"$subtitleKind\",\"language\":\"eng\",\"is_default\":false}],\"video\":{\"action\":\"copy\"$burn}"
                        } else ""
                        val urls = if (subtitleKind !== null) "\"subtitle_urls\":[\"/subtitle?token=t\"]," else ""
                        return MockResponse.Builder().code(status).body(
                            """{"data":{"decision":{"outcome":"play","tier":$responseTier,"file_id":7$decision},"stream_url":"/stream?token=t","start_ms":45000,$urls"watch":null}}"""
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
            prefs, scope, PlaybackTarget(mediaItemId = mediaItemId, startMs = 45_000),
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

        fun sessionRequest(index: Int) = McJson.decodeFromString<PlaybackSessionRequest>(sessions[index].body!!.utf8())

        fun progressRequest(index: Int) = McJson.decodeFromString<PlaybackProgressRequest>(progress[index].body!!.utf8())

        fun emitEmbeddedPgsTrack(): TrackGroup {
            val group = TrackGroup(Format.Builder().setId("0").setSampleMimeType(androidx.media3.common.MimeTypes.APPLICATION_PGS).build())
            val tracks = Tracks(listOf(Tracks.Group(group, false, intArrayOf(C.FORMAT_HANDLED), booleanArrayOf(false))))
            // Exo publishes currentTracks before onTracksChanged. Copy its application-thread
            // snapshot so this injected event does not mutate the playback thread's shared info.
            val exo = PlaybackController::class.java.getDeclaredField("exo").apply { isAccessible = true }.get(controller)
            val infoField = exo.javaClass.getDeclaredField("playbackInfo").apply { isAccessible = true }
            val info = infoField.get(exo)
            val updated = info.javaClass.getDeclaredMethod("copyWithPlaybackState", Int::class.javaPrimitiveType)
                .apply { isAccessible = true }.invoke(info, controller.player.playbackState)
            val resultField = updated.javaClass.getDeclaredField("trackSelectorResult").apply { isAccessible = true }
            val result = resultField.get(updated) as TrackSelectorResult
            resultField.set(updated, TrackSelectorResult(result.rendererConfigurations, result.selections, tracks, result.info))
            infoField.set(exo, updated)
            assertSame(tracks, controller.player.currentTracks)
            PlaybackController::class.java.getDeclaredMethod("handleTracks", Tracks::class.java)
                .apply { isAccessible = true }.invoke(controller, tracks)
            return group
        }

        fun decoderFailure(code: Int) {
            val info = MediaCodecInfo.newInstance("OMX.MS.HEVC.Decoder", "video/hevc", "video/hevc", null,
                true, false, true, false, false)
            val cause = if (code == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED) {
                MediaCodecRenderer.DecoderInitializationException(Format.Builder().setSampleMimeType("video/hevc").build(),
                    IllegalStateException("decoder init failed"), false, info)
            } else {
                MediaCodecDecoderException(IllegalStateException("decode failed"), info)
            }
            val listener = PlaybackController::class.java.declaredClasses.single { it.simpleName == "ExoListener" }
                .getDeclaredConstructor(PlaybackController::class.java).apply { isAccessible = true }
                .newInstance(controller) as Player.Listener
            listener.onPlayerError(PlaybackException("decode failed", cause, code))
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
