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
import java.util.concurrent.CopyOnWriteArrayList

/**
 * 详情页下面「相似推荐 + 系列」两行的取数规则（iOS / Apple TV / Web 同一套）：
 * 电影有系列合集时相似推荐排除同系列；系列一行出不来（拉不到上游档案）时再拉一次不排除的。
 * 真 Retrofit 请求打到 MockWebServer。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class, kotlinx.serialization.ExperimentalSerializationApi::class)
class DetailRelatedTest {
    private fun TestScope.waitFor(what: String, predicate: () -> Boolean) {
        repeat(300) {
            runCurrent()
            if (predicate()) return
            Thread.sleep(10)
        }
        fail("Timed out waiting for $what")
    }

    private val detail = """{"success":true,"data":{"media_item_id":7,"kind":"movie","title":"沙丘",
        "series_collection_id":30,"tmdb_id":438631,"imdb_id":"tt1160419"}}"""

    private fun series(available: Boolean) = """{"success":true,"data":{"series_name":"沙丘（系列）",
        "owned_count":2,"total":3,"available":$available,"parts":[
        {"tmdb_id":438631,"title":"沙丘","media_item_id":7},
        {"tmdb_id":693134,"title":"沙丘2","media_item_id":8},
        {"tmdb_id":1170608,"title":"沙丘3"}]}}"""

    /** 服务端：排除同系列时不给《沙丘2》 */
    private fun similar(exclude: Boolean) = if (exclude) {
        """{"success":true,"data":[{"media_item_id":9,"title":"银翼杀手2049","library_id":1}]}"""
    } else {
        """{"success":true,"data":[{"media_item_id":8,"title":"沙丘2","library_id":1},
            {"media_item_id":9,"title":"银翼杀手2049","library_id":1}]}"""
    }

    private fun TestScope.withVm(seriesAvailable: Boolean, block: TestScope.(ItemDetailViewModel, List<String?>) -> Unit) {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val similarCalls = CopyOnWriteArrayList<String?>()
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val url = request.requestUrl!!
                val path = url.encodedPath
                return when {
                    path.endsWith("/libraries/1/items/7") -> MockResponse().setBody(detail)
                    path.endsWith("/collections/30/series") -> MockResponse().setBody(series(seriesAvailable))
                    path.endsWith("/libraries/1/items/7/similar") -> {
                        val exclude = url.queryParameter("exclude_series")
                        similarCalls += exclude
                        MockResponse().setBody(similar(exclude == "true"))
                    }
                    else -> MockResponse().setResponseCode(404).setBody("{}")
                }
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
        val vm = ItemDetailViewModel(
            SavedStateHandle(mapOf("libraryId" to "1", "itemId" to "7")),
            repository, api, PlaybackPreconnect(api, repository), EventStream(client, repository, api),
        )
        try {
            block(vm, similarCalls)
        } finally {
            androidx.lifecycle.ViewModelStore().apply { put("detail", vm); clear() }
            runCurrent()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }

    @Test fun seriesRowTakesSeriesOutOfSimilar() = runTest {
        withVm(seriesAvailable = true) { vm, calls ->
            waitFor("related rows") { vm.related.value.series != null && vm.related.value.similar.isNotEmpty() }
            assertEquals(listOf("银翼杀手2049"), vm.related.value.similar.map { it.title })
            assertEquals(3, vm.related.value.series!!.parts.size)
            assertEquals("有系列一行时只拉一次、带排除", listOf("true"), calls.toList())
            // 外部词条随详情一起到手（页底「相关链接」）
            val item = (vm.state.value as io.movieclaw.android.core.designsystem.Loadable.Ready).value.item
            assertEquals(438631L, item.tmdbId)
            assertEquals("tt1160419", item.imdbId)
        }
    }

    @Test fun missingSeriesRowKeepsSequelsInSimilar() = runTest {
        withVm(seriesAvailable = false) { vm, calls ->
            waitFor("similar row") { vm.related.value.similar.size == 2 }
            assertNull("拉不到上游档案时不出系列一行", vm.related.value.series)
            assertEquals(listOf("沙丘2", "银翼杀手2049"), vm.related.value.similar.map { it.title })
            assertEquals("系列一行没出来就再拉一次不排除的", null, calls.last())
        }
    }
}
