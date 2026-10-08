package io.movieclaw.android.feature.activity

import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.EventStream
import io.movieclaw.android.core.network.ShareCookieJar
import io.movieclaw.android.core.playback.PlaybackDataEvents
import io.movieclaw.android.core.session.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Real Retrofit requests: the history page stays alive while playback finishes elsewhere. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class, kotlinx.serialization.ExperimentalSerializationApi::class)
class PlaybackHistoryRefreshTest {
    private fun TestScope.waitFor(predicate: () -> Boolean) {
        repeat(200) {
            runCurrent()
            if (predicate()) return
            Thread.sleep(10)
        }
        fail("Timed out waiting for playback history refresh")
    }

    @Test fun committedPlaybackRefreshesRetainedPageAndOldResponseCannotOverwriteIt() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val server = MockWebServer()
        val firstHistory = CountDownLatch(1)
        val releaseOldHistory = CountDownLatch(1)
        val histories = AtomicInteger()
        val libraryRequests = AtomicInteger()
        val subscriptionRequests = AtomicInteger()
        val committed = java.util.concurrent.atomic.AtomicBoolean(false)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl!!.encodedPath
                if (path.endsWith("/playback/history")) {
                    val number = histories.incrementAndGet()
                    if (number == 1) {
                        firstHistory.countDown()
                        releaseOldHistory.await(5, TimeUnit.SECONDS)
                    }
                    return MockResponse().setBody("""{"success":true,"data":{"entries":[{"id":$number,"progress_percent":$number}]}}""")
                }
                if (path.endsWith("/playback/stats/watch")) return MockResponse().setBody("""{"success":true,"data":{"days":7}}""")
                if (path.endsWith("/libraries")) {
                    libraryRequests.incrementAndGet()
                    return MockResponse().setBody("""{"success":true,"data":[]}""")
                }
                if (path.endsWith("/subscriptions")) {
                    subscriptionRequests.incrementAndGet()
                    return MockResponse().setBody("""{"success":true,"data":[]}""")
                }
                if (path.endsWith("/collections") || path.endsWith("/subscriptions/today-arrivals")) {
                    return MockResponse().setBody("""{"success":true,"data":[]}""")
                }
                if (path.endsWith("/subscriptions/recent-arrivals")) {
                    val percent = if (committed.get()) 42 else 0
                    return MockResponse().setBody("""{"success":true,"data":[{"subscription_id":1,"media":{"media_item_id":1,"title":"Movie"},"progress_percent":$percent}]}""")
                }
                if (path.endsWith("/playback/up-next")) {
                    val items = if (committed.get()) """[{"media_item_id":1,"library_id":1,"title":"Movie","progress_percent":42}]""" else "[]"
                    return MockResponse().setBody("""{"success":true,"data":{"items":$items}}""")
                }
                // Other Activity endpoints are irrelevant to this scenario.
                return MockResponse().setResponseCode(403).setBody("{}")
            }
        }
        server.start()
        val context = RuntimeEnvironment.getApplication()
        val json = Json { ignoreUnknownKeys = true; namingStrategy = JsonNamingStrategy.SnakeCase }
        val client = OkHttpClient()
        val vault = TokenVault(context)
        val cookies = ShareCookieJar()
        val api = ApiFactory(json, client, client, vault, cookies)
        val repository = SessionRepository(context, json, vault, api, client,
            SessionCacheCleaner(context, ImageLoaders(context, vault, client, cookies), LibraryHomeSnapshotStore(context, json)))
        val origin = server.url("/").toString().trimEnd('/')
        vault.activate(origin, "alice", "token")
        @Suppress("UNCHECKED_CAST")
        val ui = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
            .get(repository) as MutableStateFlow<SessionUi>
        ui.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = SessionView("alice"))
        val events = PlaybackDataEvents()
        val vm = ActivityViewModel(api, EventStream(client, repository, api), repository, json, events)
        val subs = io.movieclaw.android.feature.subscriptions.SubsHomeViewModel(api, repository, events)
        val library = io.movieclaw.android.feature.library.LibraryViewModel(repository, api,
            io.movieclaw.android.core.playback.ResumeBarPrefs(context),
            io.movieclaw.android.core.playback.PlaybackPreconnect(api, repository),
            LibraryHomeSnapshotStore(context, json), io.movieclaw.android.core.designsystem.FeedbackBus(), events)
        try {
            waitFor { firstHistory.count == 0L && !subs.ui.value.loading && library.state.value is io.movieclaw.android.core.designsystem.Loadable.Ready }
            val initialLibraries = libraryRequests.get()
            val initialSubscriptions = subscriptionRequests.get()
            val identity = vault.snapshot()!!
            // Completion from another server/account/generation must not refresh this page.
            events.committed(identity.copy(origin = "https://other.example"))
            runCurrent()
            assertEquals(1, histories.get())
            events.committed(identity.copy(generation = identity.generation + 1))
            runCurrent()
            assertEquals(1, histories.get())
            // Stop has now committed; refresh succeeds while the initial response is still blocked.
            committed.set(true)
            events.committed(identity)
            waitFor {
                val home = (library.state.value as? io.movieclaw.android.core.designsystem.Loadable.Ready)?.value
                vm.ui.value.history.firstOrNull()?.id == 2L &&
                    subs.ui.value.slides.firstOrNull()?.resumePercent == 42 &&
                    home?.upNext?.firstOrNull()?.progressPercent == 42
            }
            val home = (library.state.value as io.movieclaw.android.core.designsystem.Loadable.Ready).value
            assertTrue(home.rows.any { it.row.kind is io.movieclaw.android.core.model.HomeRows.Kind.UpNext })
            assertEquals(initialLibraries, libraryRequests.get())
            assertEquals(initialSubscriptions, subscriptionRequests.get())
            releaseOldHistory.countDown()
            repeat(20) { runCurrent(); Thread.sleep(10) }
            assertEquals(2L, vm.ui.value.history.single().id)
            assertNotNull(vm.ui.value.watchStats)
        } finally {
            releaseOldHistory.countDown()
            // Cancel ViewModel-owned pollers and SSE before closing the server.
            androidx.lifecycle.ViewModelStore().apply { put("activity", vm); put("subs", subs); put("library", library); clear() }
            runCurrent()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }
}
