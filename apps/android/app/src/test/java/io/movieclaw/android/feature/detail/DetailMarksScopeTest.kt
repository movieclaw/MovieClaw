package io.movieclaw.android.feature.detail

import androidx.lifecycle.SavedStateHandle
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.EventStream
import io.movieclaw.android.core.network.ShareCookieJar
import io.movieclaw.android.core.playback.PlaybackPreconnect
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
import java.util.concurrent.ConcurrentHashMap

/**
 * 详情页「标为已看 / 收藏」的作用域（服务端口径：收藏在整剧上，已看在单集上）。
 * 真 Retrofit 请求打到 MockWebServer，服务端按季集分别记账。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class, kotlinx.serialization.ExperimentalSerializationApi::class)
class DetailMarksScopeTest {
    private fun TestScope.waitFor(what: String, predicate: () -> Boolean) {
        repeat(300) {
            runCurrent()
            if (predicate()) return
            Thread.sleep(10)
        }
        fail("Timed out waiting for $what")
    }

    @Test fun episodeWatchedAndShowFavoriteDoNotOverwriteEachOther() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        // 服务端状态：键 "s/e"（整剧 = "-/-"）。整剧收藏、整剧已看；单集各自记已看、没有收藏
        val played = ConcurrentHashMap(mapOf("-/-" to true, "1/1" to true, "1/2" to false))
        var favorite = true
        fun key(season: String?, episode: String?) = "${season ?: "-"}/${episode ?: "-"}"
        fun marks(k: String) = """{"success":true,"data":{"played":${played[k] ?: false},"is_favorite":${if (k == "-/-") favorite else false}}}"""
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val url = request.requestUrl!!
                if (!url.encodedPath.endsWith("/playback/marks")) return MockResponse().setResponseCode(403).setBody("{}")
                if (request.method == "GET") {
                    return MockResponse().setBody(marks(key(url.queryParameter("season_number"), url.queryParameter("episode_number"))))
                }
                val body = Json.parseToJsonElement(request.body.readUtf8()) as kotlinx.serialization.json.JsonObject
                fun field(name: String) = body[name]?.toString()?.trim('"')?.takeIf { it != "null" }
                val k = key(field("season_number"), field("episode_number"))
                field("played")?.let { played[k] = it.toBoolean() }
                field("favorite")?.let { favorite = it.toBoolean() }
                return MockResponse().setBody(marks(k))
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
            SessionCacheCleaner(context, ImageLoaders(context, vault, client, cookies), LibraryHomeSnapshotStore(context, json)),
            dagger.Lazy { throw UnsupportedOperationException() })
        val origin = server.url("/").toString().trimEnd('/')
        vault.activate(origin, "alice", "token")
        @Suppress("UNCHECKED_CAST")
        val ui = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
            .get(repository) as MutableStateFlow<SessionUi>
        ui.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = SessionView("alice"))
        val vm = ItemDetailViewModel(
            SavedStateHandle(mapOf("libraryId" to "1", "itemId" to "7")),
            repository, api, PlaybackPreconnect(api, repository), EventStream(client, repository, api),
            io.movieclaw.android.core.offline.OfflineStore(context, repository).also {},
            io.movieclaw.android.core.offline.OfflineDownloader(
                context,
                api,
                io.movieclaw.android.core.offline.OfflineStore(context, repository),
                io.movieclaw.android.core.offline.OfflinePrefs(context),
            ),
        io.movieclaw.android.core.offline.OfflinePrefs(context),
        )
        try {
            // 进页：整条目的标记（心亮），随后选中第 1 季第 2 集——它没看过
            vm.loadMarks(7)
            waitFor("item marks") { vm.marks.value.isFavorite }
            vm.loadUnitPlayed(7, 1, 2)
            waitFor("episode 2 played state") { !vm.marks.value.played }
            assertTrue("favorite must stay from the show", vm.marks.value.isFavorite)

            // 标第 2 集已看：写完重查的是单集（单集上没有收藏），心不能被清掉
            vm.togglePlayed(7, 1, 2)
            waitFor("episode 2 marked") { played["1/2"] == true && vm.marks.value.played }
            repeat(20) { runCurrent(); Thread.sleep(5) }
            assertTrue("marking an episode watched cleared the favorite", vm.marks.value.isFavorite)

            // 切到第 1 集再切回：已看跟着集走
            played["1/1"] = false
            vm.loadUnitPlayed(7, 1, 1)
            waitFor("episode 1 played state") { !vm.marks.value.played }

            // 取消收藏：返回的是整剧的「已看」（true），不能盖掉第 1 集的未看
            vm.toggleFavorite(7)
            waitFor("favorite removed") { !favorite && !vm.marks.value.isFavorite }
            repeat(20) { runCurrent(); Thread.sleep(5) }
            assertFalse("show-level played overwrote the selected episode", vm.marks.value.played)

            // 晚到的整条目结果也不能覆盖单集的已看
            vm.loadMarks(7)
            repeat(30) { runCurrent(); Thread.sleep(5) }
            assertFalse(vm.marks.value.played)
        } finally {
            androidx.lifecycle.ViewModelStore().apply { put("detail", vm); clear() }
            runCurrent()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }
}
