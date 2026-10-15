package io.movieclaw.android.core.playback

import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.NetworkModule
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
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.TimeUnit

/**
 * 播放宿主只管身份与生命周期（播放本身在统一引擎里）：成员播放归属启动它的账号、访客播放不绑成员身份、
 * 换片替换旧的、请求走对通道（成员带令牌、访客走分享通道且不带令牌）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class, kotlinx.serialization.ExperimentalSerializationApi::class)
class PlaybackSessionHolderTest {
    private data class Fixture(
        val holder: PlaybackSessionHolder,
        val vault: TokenVault,
        val ui: MutableStateFlow<SessionUi>,
    )

    @Suppress("UNCHECKED_CAST")
    private fun fixture(): Fixture {
        val context = RuntimeEnvironment.getApplication()
        val json = Json { ignoreUnknownKeys = true; namingStrategy = JsonNamingStrategy.SnakeCase }
        val client = OkHttpClient()
        val vault = TokenVault(context)
        val cookies = ShareCookieJar()
        // 与生产同一套客户端（带 User-Agent 与按身份附令牌的拦截器）：令牌附没附上要测的就是这层接线
        val api = ApiFactory(
            json, NetworkModule.generalClient(vault), NetworkModule.playbackClient(vault), vault, cookies,
        )
        val images = ImageLoaders(context, vault, client, cookies)
        val cleaner = SessionCacheCleaner(context, images, LibraryHomeSnapshotStore(context, json))
        val repository = SessionRepository(context, json, vault, api, client, cleaner)
        val holder = PlaybackSessionHolder(context, api, repository, PlaybackDataEvents(), CorePlaybackPrefs(context))
        val field = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
        return Fixture(holder, vault, field.get(repository) as MutableStateFlow<SessionUi>)
    }

    private val target = PlayTarget(1, 1, "movie", "Movie")

    /** 取设备号走 DataStore（真实 IO 线程）：边推主线程边等 */
    private fun TestScope.awaitState(holder: PlaybackSessionHolder, done: (PlaybackSessionHolder.State) -> Boolean) {
        repeat(300) {
            runCurrent()
            if (done(holder.state.value)) return
            Thread.sleep(10)
        }
        fail("状态没有到位：${holder.state.value}")
    }

    private fun TestScope.nextRequest(server: MockWebServer): RecordedRequest {
        repeat(300) {
            runCurrent()
            server.takeRequest(10, TimeUnit.MILLISECONDS)?.let { return it }
        }
        error("播放请求没有发出")
    }

    /** 退出后控制器还有请求在 IO 线程上收尾、会切回主线程：等它们落地再撤掉测试用的主线程调度器 */
    private fun TestScope.drain() = repeat(30) {
        runCurrent()
        Thread.sleep(10)
    }

    private fun Fixture.signIn(origin: String, user: String) {
        vault.activate(origin, user, "$user-token")
        ui.value = SessionUi(SessionPhase.READY, origin, SessionView(user))
    }

    private suspend fun Fixture.signOut() {
        vault.deactivateActive()
        ui.value = SessionUi(SessionPhase.NEEDS_LOGIN)
    }

    private fun MockWebServer.answerEverything() {
        dispatcher = object : okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: RecordedRequest) = MockResponse().setResponseCode(503)
        }
    }

    private fun playing(state: PlaybackSessionHolder.State) = state is PlaybackSessionHolder.State.Playing

    @Test fun memberPlaybackStopsWhenTheAccountLogsOut() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val fixture = fixture()
        try {
            fixture.signIn("http://127.0.0.1:1", "alice")
            fixture.holder.open(target)
            awaitState(fixture.holder, ::playing)
            assertNotNull(fixture.holder.sessionPlayer.value)
            fixture.signOut()
            runCurrent()
            assertEquals(PlaybackSessionHolder.State.Idle, fixture.holder.state.value)
            assertNull(fixture.holder.sessionPlayer.value)
        } finally {
            fixture.holder.exit()
            drain()
            Dispatchers.resetMain()
        }
    }

    @Test fun logoutWhileOpeningNeverStartsAPlayer() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val fixture = fixture()
        try {
            fixture.signIn("http://127.0.0.1:1", "alice")
            fixture.holder.open(target)
            assertEquals(PlaybackSessionHolder.State.Opening, fixture.holder.state.value)
            fixture.signOut()
            repeat(30) { runCurrent(); Thread.sleep(10) }
            assertEquals(PlaybackSessionHolder.State.Idle, fixture.holder.state.value)
            assertNull(fixture.holder.sessionPlayer.value)
        } finally {
            fixture.holder.exit()
            drain()
            Dispatchers.resetMain()
        }
    }

    @Test fun switchingAccountsStopsTheOldMembersPlayback() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val fixture = fixture()
        try {
            fixture.signIn("http://127.0.0.1:1", "alice")
            fixture.holder.open(target)
            awaitState(fixture.holder, ::playing)
            fixture.signIn("http://127.0.0.1:1", "bob")
            runCurrent()
            assertEquals(PlaybackSessionHolder.State.Idle, fixture.holder.state.value)
            assertNull(fixture.holder.sessionPlayer.value)
        } finally {
            fixture.holder.exit()
            drain()
            Dispatchers.resetMain()
        }
    }

    @Test fun memberLogoutKeepsGuestPlayback() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val fixture = fixture()
        try {
            fixture.signIn("http://127.0.0.1:1", "alice")
            fixture.holder.openGuest("http://127.0.0.1:1", "share", target)
            awaitState(fixture.holder, ::playing)
            fixture.signOut()
            runCurrent()
            assertTrue(playing(fixture.holder.state.value))
        } finally {
            fixture.holder.exit()
            drain()
            Dispatchers.resetMain()
        }
    }

    @Test fun openingAnotherTitleReplacesTheCurrentPlayback() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val fixture = fixture()
        try {
            fixture.signIn("http://127.0.0.1:1", "alice")
            fixture.holder.open(target)
            awaitState(fixture.holder, ::playing)
            val first = fixture.holder.sessionPlayer.value
            fixture.holder.open(target.copy(mediaItemId = 2))
            awaitState(fixture.holder) { (it as? PlaybackSessionHolder.State.Playing)?.active?.target?.mediaItemId == 2L }
            assertNotSame(first, fixture.holder.sessionPlayer.value)
            fixture.holder.exit()
            assertEquals(PlaybackSessionHolder.State.Idle, fixture.holder.state.value)
            assertNull(fixture.holder.sessionPlayer.value)
        } finally {
            fixture.holder.exit()
            drain()
            Dispatchers.resetMain()
        }
    }

    @Test fun memberRequestsCarryTheAccountsToken() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val server = MockWebServer().apply { answerEverything(); start() }
        val fixture = fixture()
        try {
            fixture.signIn(server.url("/").toString().trimEnd('/'), "alice")
            fixture.holder.open(target)
            val paths = mutableMapOf<String, String?>()
            repeat(2) { nextRequest(server).let { paths[it.path!!.substringBefore('?')] = it.getHeader("Authorization") } }
            assertEquals("Bearer alice-token", paths["/api/v1/playback/sessions"])
            assertTrue(paths.keys.toString(), "/api/v1/playback/items/1" in paths)
        } finally {
            fixture.holder.exit()
            server.shutdown()
            drain()
            Dispatchers.resetMain()
        }
    }

    @Test fun guestRequestsGoThroughTheShareChannelWithoutMemberToken() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val server = MockWebServer().apply { answerEverything(); start() }
        val fixture = fixture()
        try {
            val origin = server.url("/").toString().trimEnd('/')
            fixture.signIn(origin, "alice")
            fixture.holder.openGuest(origin, "abc", target)
            val requests = List(2) { nextRequest(server) }
            assertEquals(
                setOf("/api/v1/share/abc/playback/sessions", "/api/v1/share/abc/playback/items/1"),
                requests.map { it.path!!.substringBefore('?') }.toSet(),
            )
            requests.forEach { assertNull(it.getHeader("Authorization")) }
        } finally {
            fixture.holder.exit()
            server.shutdown()
            drain()
            Dispatchers.resetMain()
        }
    }
}
