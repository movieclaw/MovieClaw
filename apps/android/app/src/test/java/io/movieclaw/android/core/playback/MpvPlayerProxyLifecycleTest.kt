package io.movieclaw.android.core.playback

import android.app.Application
import androidx.media3.common.Player
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class MpvPlayerProxyLifecycleTest {
    private class Engine : PlayerEngine {
        var buffering = false
        var enginePlaying = false
        var releases = 0
        var rate = 1.0f
        override fun open(source: EngineSource, sidecars: List<Sidecar>) {}
        override fun positionMs() = 1000L
        override fun durationMs() = 60_000L
        override fun isPlaying() = enginePlaying
        override fun isBuffering() = buffering
        override fun setPlaying(playing: Boolean) { enginePlaying = playing }
        override fun seekTo(playerMs: Long) {}
        override fun seekBy(deltaMs: Long) {}
        override fun setSpeed(speed: Float) { rate = speed }
        override fun release() { releases++ }
    }

    @Test fun `buffering preserves play intent even when duration is known`() = runTest {
        val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        val engine = Engine().apply { buffering = true }
        val proxy = MpvPlayerProxy(engine, scope)
        assertEquals(Player.STATE_BUFFERING, proxy.playbackState)
        assertTrue(proxy.playWhenReady)
        assertFalse(proxy.isPlaying)
        proxy.pause()
        assertFalse(proxy.playWhenReady)
        proxy.release()
        scope.cancel()
    }

    @Test fun `media session pause and speed commands synchronize controller intentions`() = runTest {
        val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        val engine = Engine()
        var commanded = true
        var currentSpeed = 1.0f
        val proxy = MpvPlayerProxy(engine, scope, onPlayingChanged = { commanded = it }, onSpeedChanged = { currentSpeed = it })
        proxy.pause()
        assertFalse(commanded)
        proxy.play()
        assertTrue(commanded)
        assertTrue(engine.enginePlaying)
        proxy.syncSpeedIntent(1.5f)
        assertEquals(1.5f, proxy.playbackParameters.speed, 0.001f)
        assertEquals(1.0f, engine.rate, 0.001f) // 同步 setter 不递归控制内核。
        proxy.setPlaybackParameters(androidx.media3.common.PlaybackParameters(2.0f))
        assertEquals(2.0f, engine.rate, 0.001f)
        assertEquals(2.0f, currentSpeed, 0.001f)
        proxy.release()
        scope.cancel()
    }

    @Test fun `release stops polling without destroying controllers engine`() = runTest {
        val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        val engine = Engine()
        val proxy = MpvPlayerProxy(engine, scope)
        testScheduler.runCurrent()
        assertTrue(scope.coroutineContext[Job]!!.children.any { it.isActive })
        assertFalse(proxy.isCommandAvailable(Player.COMMAND_SET_MEDIA_ITEM))
        assertFalse(proxy.isCommandAvailable(Player.COMMAND_CHANGE_MEDIA_ITEMS))
        proxy.release()
        testScheduler.runCurrent()
        assertFalse(scope.coroutineContext[Job]!!.children.any { it.isActive })
        assertEquals(0, engine.releases)
        engine.release()
        assertEquals(1, engine.releases)
        scope.cancel()
    }
}
