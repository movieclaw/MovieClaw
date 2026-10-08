package io.movieclaw.android.feature.reels

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class DeferredReelReleasesTest {
    @Test fun leavingBeforeAnimationEndsReleasesExactlyOnce() = runTest {
        val owner = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        val released = mutableListOf<String>()
        val releases = DeferredReelReleases<String>(owner) { released.add(it) }
        releases.defer("old decoder")
        runCurrent()
        releases.flush()
        assertEquals(listOf("old decoder"), released)
        owner.cancel()
        advanceTimeBy(500)
        runCurrent()
        assertEquals(listOf("old decoder"), released)
    }

    @Test fun scopeCancellationBeforeCoroutineStartsStillReleasesDecoder() = runTest {
        val owner = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        val released = mutableListOf<String>()
        val releases = DeferredReelReleases<String>(owner) { released.add(it) }
        releases.defer("old decoder")
        owner.cancel()
        runCurrent()
        assertEquals(listOf("old decoder"), released)
    }

    @Test fun animationDelayPreservesDecoderThenReleasesIt() = runTest {
        val owner = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        val released = mutableListOf<String>()
        val releases = DeferredReelReleases<String>(owner) { released.add(it) }
        releases.defer("old decoder")
        runCurrent()
        advanceTimeBy(499)
        assertEquals(emptyList<String>(), released)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf("old decoder"), released)
        releases.flush()
        assertEquals(listOf("old decoder"), released)
        owner.cancel()
    }
}
