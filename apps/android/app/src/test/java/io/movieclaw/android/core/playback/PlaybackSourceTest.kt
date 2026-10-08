package io.movieclaw.android.core.playback

import io.movieclaw.android.core.model.PlaybackDecisionView
import io.movieclaw.android.core.model.PlaybackSessionView
import org.junit.Assert.*
import org.junit.Test
import org.junit.Before
import org.junit.After
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class PlaybackSourceTest {
    @Before fun setMain() { Dispatchers.setMain(StandardTestDispatcher()) }
    @After fun resetMain() { Dispatchers.resetMain() }
    private val view = PlaybackSessionView(PlaybackDecisionView("ready"))
    @Test fun progressiveFileTimelineDoesNotBecomeHls() {
        assertFalse(isHlsSource(view.copy(timeline = "file"), "https://example.com/files/1/stream"))
    }
    @Test fun manifestsAndMasterPlanAreHls() {
        assertTrue(isHlsSource(view, "https://example.com/master.M3U8?token=x"))
        assertTrue(isHlsSource(view.copy(masterUrl = "/master"), "https://example.com/master"))
    }
    @Test fun cacheIdentitiesAreScopedToServer() {
        assertNotEquals(SourceByteCache.key(1, 100, "https://a.test"), SourceByteCache.key(1, 100, "https://b.test"))
        assertEquals(SourceByteCache.key(1, 100, "https://a.test/"), SourceByteCache.key(1, 100, "https://a.test"))
    }
}
