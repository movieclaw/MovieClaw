package io.movieclaw.android.core.playback

import io.movieclaw.android.core.designsystem.FeedbackBus
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.ShareCookieJar
import io.movieclaw.android.core.session.LibraryHomeSnapshotStore
import io.movieclaw.android.core.session.SessionCacheCleaner
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.core.session.TokenVault
import io.movieclaw.android.core.session.SessionUi
import io.movieclaw.android.core.session.SessionPhase
import io.movieclaw.android.core.model.SessionView
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class, kotlinx.serialization.ExperimentalSerializationApi::class)
class PlaybackSessionHolderTest {
    private data class Fixture(
        val holder: PlaybackSessionHolder,
        val vault: TokenVault,
        val ui: MutableStateFlow<SessionUi>,
    )

    private fun holder(): PlaybackSessionHolder = fixture().holder

    @Suppress("UNCHECKED_CAST")
    private fun fixture(): Fixture {
        val context = RuntimeEnvironment.getApplication()
        val json = Json { ignoreUnknownKeys = true; namingStrategy = JsonNamingStrategy.SnakeCase }
        val client = OkHttpClient()
        val vault = TokenVault(context)
        val cookies = ShareCookieJar()
        val api = ApiFactory(json, client, client, vault, cookies)
        val images = ImageLoaders(context, vault, client, cookies)
        val cleaner = SessionCacheCleaner(context, images, LibraryHomeSnapshotStore(context, json))
        val repository = SessionRepository(context, json, vault, api, client, cleaner)
        val holder = PlaybackSessionHolder(
            context, api, repository, QualityMemory(context, json), FeedbackBus(),
            PlaybackQoe(context, api, json), TrickplayProvider(context, images),
        )
        val field = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
        return Fixture(holder, vault, field.get(repository) as MutableStateFlow<SessionUi>)
    }

    private fun TestScope.nextRequest(server: MockWebServer): RecordedRequest {
        repeat(150) {
            runCurrent()
            server.takeRequest(20, TimeUnit.MILLISECONDS)?.let { return it }
        }
        error("Playback request did not arrive")
    }

    private val target = PlayTarget(1, 1, "movie", "Movie")
    private fun response(reason: String) = MockResponse()
        .addHeader("Content-Type", "application/json")
        .setBody("""{"success":true,"code":"OK","message":"","data":{"decision":{"outcome":"consent","reason":"$reason"}}}""")

    @Test fun rapidGuestOpensKeepTheSecondRequestsState() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val server = MockWebServer()
        val releaseFirst = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                return if (request.path!!.contains("/first/")) {
                    releaseFirst.await(3, TimeUnit.SECONDS)
                    response("old request")
                } else response("current request")
            }
        }
        server.start()
        val holder = holder()
        try {
            val origin = server.url("/").toString()
            holder.openGuest(origin, "first", target)
            runCurrent()
            nextRequest(server)
            holder.openGuest(origin, "second", target.copy(mediaItemId = 2))
            runCurrent()
            nextRequest(server)
            repeat(100) {
                runCurrent()
                if (holder.state.value !is PlaybackSessionHolder.State.Consent) Thread.sleep(10)
            }
            assertEquals("current request", (holder.state.value as PlaybackSessionHolder.State.Consent).reason)
            releaseFirst.countDown()
            Thread.sleep(50)
            runCurrent()
            assertEquals("current request", (holder.state.value as PlaybackSessionHolder.State.Consent).reason)
            holder.exit()
            assertEquals(PlaybackSessionHolder.State.Idle, holder.state.value)
        } finally {
            holder.exit()
            releaseFirst.countDown()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }

    @Test fun exitingWhileGuestRequestIsPendingKeepsHolderIdle() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val server = MockWebServer()
        val respond = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                respond.await(3, TimeUnit.SECONDS)
                return response("late consent")
            }
        }
        server.start()
        val holder = holder()
        try {
            holder.openGuest(server.url("/").toString(), "share", target)
            runCurrent()
            nextRequest(server)
            holder.exit()
            respond.countDown()
            Thread.sleep(50)
            runCurrent()
            assertEquals(PlaybackSessionHolder.State.Idle, holder.state.value)
            assertNull(holder.sessionPlayer.value)
        } finally {
            holder.exit()
            respond.countDown()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }

    @Test fun newerQualityChoiceAndExitInvalidatePendingQualityRequest() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val server = MockWebServer()
        val releaseOldQuality = CountDownLatch(1)
        val calls = java.util.concurrent.atomic.AtomicInteger()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (calls.incrementAndGet()) {
                1 -> response("initial consent")
                2 -> {
                    releaseOldQuality.await(3, TimeUnit.SECONDS)
                    response("old quality")
                }
                else -> response("new quality")
            }
        }
        server.start()
        val holder = holder()
        try {
            holder.openGuest(server.url("/").toString(), "share", target)
            runCurrent()
            nextRequest(server)
            repeat(100) {
                runCurrent()
                if (holder.state.value !is PlaybackSessionHolder.State.Consent) Thread.sleep(10)
            }
            assertEquals("initial consent", (holder.state.value as PlaybackSessionHolder.State.Consent).reason)
            holder.changeQuality(720)
            runCurrent()
            nextRequest(server)
            holder.changeQuality(480)
            runCurrent()
            nextRequest(server)
            repeat(100) {
                runCurrent()
                if ((holder.state.value as? PlaybackSessionHolder.State.Consent)?.reason != "new quality") Thread.sleep(10)
            }
            assertEquals("new quality", (holder.state.value as PlaybackSessionHolder.State.Consent).reason)
            holder.exit()
            releaseOldQuality.countDown()
            Thread.sleep(50)
            runCurrent()
            assertEquals(PlaybackSessionHolder.State.Idle, holder.state.value)
            assertNull(holder.sessionPlayer.value)
        } finally {
            holder.exit()
            releaseOldQuality.countDown()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }


    @Test fun logoutCancelsMemberPreparationBeforeAnyPlayerCanStart() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val fixture = fixture()
        val origin = "http://127.0.0.1:1"
        try {
            fixture.vault.activate(origin, "alice", "alice-token")
            fixture.ui.value = SessionUi(SessionPhase.READY, origin, SessionView("alice"))
            fixture.holder.open(target)
            assertEquals(PlaybackSessionHolder.State.Preparing, fixture.holder.state.value)
            fixture.vault.deactivateActive()
            fixture.ui.value = SessionUi(SessionPhase.NEEDS_LOGIN)
            runCurrent()
            assertEquals(PlaybackSessionHolder.State.Idle, fixture.holder.state.value)
            assertNull(fixture.holder.sessionPlayer.value)
        } finally {
            fixture.holder.exit()
            Dispatchers.resetMain()
        }
    }

    @Test fun switchingAccountsCancelsOldMembersPreparation() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val fixture = fixture()
        val origin = "http://127.0.0.1:1"
        try {
            fixture.vault.activate(origin, "alice", "alice-token")
            fixture.ui.value = SessionUi(SessionPhase.READY, origin, SessionView("alice"))
            fixture.holder.open(target)
            fixture.vault.activate(origin, "bob", "bob-token")
            fixture.ui.value = SessionUi(SessionPhase.READY, origin, SessionView("bob"))
            runCurrent()
            assertEquals(PlaybackSessionHolder.State.Idle, fixture.holder.state.value)
            assertNull(fixture.holder.sessionPlayer.value)
        } finally {
            fixture.holder.exit()
            Dispatchers.resetMain()
        }
    }

    @Test fun memberLogoutDoesNotCancelGuestPreparation() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val server = MockWebServer()
        val respond = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                respond.await(3, TimeUnit.SECONDS)
                return response("guest consent")
            }
        }
        server.start()
        val fixture = fixture()
        try {
            val origin = server.url("/").toString()
            fixture.vault.activate(origin, "alice", "alice-token")
            fixture.ui.value = SessionUi(SessionPhase.READY, origin, SessionView("alice"))
            fixture.holder.openGuest(origin, "share", target)
            nextRequest(server)
            fixture.vault.deactivateActive()
            fixture.ui.value = SessionUi(SessionPhase.NEEDS_LOGIN)
            runCurrent()
            assertEquals(PlaybackSessionHolder.State.Preparing, fixture.holder.state.value)
            respond.countDown()
            repeat(100) {
                runCurrent()
                if (fixture.holder.state.value !is PlaybackSessionHolder.State.Consent) Thread.sleep(10)
            }
            assertEquals("guest consent", (fixture.holder.state.value as PlaybackSessionHolder.State.Consent).reason)
        } finally {
            fixture.holder.exit()
            respond.countDown()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }

}
