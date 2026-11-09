package io.movieclaw.android.feature.library

import android.app.Application
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModelStore
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.model.LibraryFilter
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.*
import io.movieclaw.android.core.session.*
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * 本地/NFO 库点演员 → 同库按演员筛的海报墙：路由 → 墙页 ViewModel → 接口查询串 → 摘掉演员条件。
 *
 * 默认用内存服务模拟后端的演员口径（去首尾空白、ASCII 不分大小写、整名相等）；
 * 设了环境变量 `MOVIECLAW_TEST_API=<http://host:port/api/v1>`、`MOVIECLAW_TEST_TOKEN=<设备令牌>`、
 * `MOVIECLAW_TEST_LIBRARY=<本地/NFO 库 id>`、`MOVIECLAW_TEST_ACTOR=<演员名>` 就把请求转给真实后端
 * （Gradle 的测试进程继承环境变量，不继承 -D 系统属性）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [28])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class LibraryActorFilterTest {
    private val json = NetworkModule.json()
    private val http = OkHttpClient()
    private val requests = CopyOnWriteArrayList<HttpUrl>()
    private lateinit var server: MockWebServer
    private val backendUrl = System.getenv("MOVIECLAW_TEST_API")
    private val backendToken = System.getenv("MOVIECLAW_TEST_TOKEN")
    private val libraryId = System.getenv("MOVIECLAW_TEST_LIBRARY")?.toLong() ?: 7L
    private val actor = System.getenv("MOVIECLAW_TEST_ACTOR") ?: "张三"

    /** 内存库：标题 → 演员表（与后端测试同一组口径用例） */
    private val wall = linkedMapOf(
        "甲" to listOf("张三", "Alice Smith"),
        "乙" to listOf(" 张三 ", "李四"),
        "丙" to listOf("ALICE SMITH"),
        "丁" to listOf("张三丰"),
        "戊" to emptyList(),
    )

    private fun matches(cast: List<String>, actor: String?) =
        actor == null || cast.any { it.trim().lowercase() == actor.trim().lowercase() }

    private fun fake(request: RecordedRequest): MockResponse {
        val url = request.requestUrl!!
        val actor = url.queryParameter("actor")
        return when (url.encodedPath) {
            "/api/v1/libraries/$libraryId" ->
                MockResponse().setBody("""{"success":true,"data":{"id":$libraryId,"name":"本地库","kind":"video"}}""")
            "/api/v1/libraries/$libraryId/items" -> {
                val rows = wall.entries.filter { matches(it.value, actor) }.mapIndexed { i, (title, _) ->
                    """{"media_item_id":${i + 1},"kind":"video","library_id":$libraryId,"title":"$title"}"""
                }
                MockResponse().setBody("""{"success":true,"data":[${rows.joinToString(",")}]}""")
            }
            "/api/v1/libraries/$libraryId/item-index" -> MockResponse().setBody("""{"success":true,"data":[]}""")
            else -> MockResponse().setResponseCode(404)
        }
    }

    private fun TestScope.waitFor(predicate: () -> Boolean) {
        repeat(300) {
            runCurrent()
            if (predicate()) return
            Thread.sleep(10)
        }
        fail("Timed out waiting for the library wall")
    }

    private suspend fun TestScope.withWall(args: Map<String, String>, block: suspend TestScope.(LibraryDetailViewModel) -> Unit) {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request.requestUrl!!
                if (backendUrl == null) return fake(request)
                val forwarded = Request.Builder()
                    .url(backendUrl.trimEnd('/') + request.path!!.removePrefix("/api/v1"))
                    .header("Authorization", "Bearer $backendToken")
                    .build()
                return http.newCall(forwarded).execute().use {
                    MockResponse().setResponseCode(it.code).setBody(it.body!!.string())
                }
            }
        }
        server.start()
        val context = RuntimeEnvironment.getApplication()
        val vault = TokenVault(context)
        val cookies = ShareCookieJar()
        val factory = ApiFactory(json, http, http, vault, cookies)
        val repository = SessionRepository(context, json, vault, factory, http,
            SessionCacheCleaner(context, ImageLoaders(context, vault, http, cookies), LibraryHomeSnapshotStore(context, json)), dagger.Lazy { throw UnsupportedOperationException() })
        val origin = server.url("/").toString().trimEnd('/')
        vault.activate(origin, "alice", "token")
        @Suppress("UNCHECKED_CAST")
        val state = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
            .get(repository) as MutableStateFlow<SessionUi>
        state.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = SessionView("alice"))
        val vm = LibraryDetailViewModel(SavedStateHandle(args), repository, factory)
        val store = ViewModelStore().also { it.put("wall", vm) }
        try {
            waitFor { !vm.ui.value.loading }
            block(vm)
        } finally {
            store.clear()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }

    private fun itemRequests() = requests.filter { it.encodedPath.endsWith("/items") }

    @Test fun `actor counts as one condition and clear-all drops it`() {
        val filter = LibraryFilter(actor = "张三", genres = setOf("18"), sort = "rating")
        assertEquals(2, filter.activeCount)
        assertFalse(LibraryFilter(actor = "张三").isEmpty())
        assertEquals(LibraryFilter(sort = "rating"), filter.cleared())
        assertTrue(filter.copy(actor = null, genres = emptySet()).isEmpty())
    }

    @Test fun `route encodes the trimmed actor name`() {
        assertEquals("library/7?actor=%E5%BC%A0%E4%B8%89", libraryActorRoute(7, " 张三 "))
        // 空格编成 %20（不是 +）：Navigation 解码查询参数时不把 + 还原成空格
        assertEquals("library/7?actor=Alice%20Smith", libraryActorRoute(7, "Alice Smith"))
    }

    @Test fun `actor from the route narrows every wall request and can be removed`() = runTest {
        // 路由参数原样带进来（Navigation 已解码），首尾空白由墙页去掉
        withWall(mapOf("libraryId" to "$libraryId", "actor" to " $actor ")) { vm ->
            assertEquals(actor, vm.ui.value.filter.actor)
            assertEquals(1, vm.ui.value.filter.activeCount)
            val first = itemRequests().single()
            assertEquals(actor, first.queryParameter("actor"))
            waitFor { requests.any { it.encodedPath.endsWith("/item-index") } }
            assertEquals(actor, requests.last { it.encodedPath.endsWith("/item-index") }.queryParameter("actor"))
            if (backendUrl == null) {
                // 整名相等、不分大小写、去空白；「张三丰」不算
                assertEquals(listOf("甲", "乙"), vm.ui.value.items.map { it.title })
            }
            val narrowed = vm.ui.value.items.size
            assertTrue("演员筛出来应有作品", narrowed > 0)

            // 库名：演员卡跳进来时路由里没有，按 id 补取一次
            vm.loadNameIfMissing("")
            waitFor { vm.libraryName.value != null }
            assertTrue(requests.any { it.encodedPath == "/api/v1/libraries/$libraryId" })
            val before = requests.size
            vm.loadNameIfMissing("本地库")
            runCurrent()
            assertEquals(before, requests.size)

            // 筛选面板里改别的维度，演员条件留着
            vm.applyFilter(vm.ui.value.filter.copy(sort = "release_date"))
            waitFor { itemRequests().size == 2 && !vm.ui.value.loading }
            assertEquals(actor, itemRequests().last().queryParameter("actor"))
            assertEquals("release_date", itemRequests().last().queryParameter("sort"))

            // 条件行摘掉演员 → 整库
            vm.applyFilter(vm.ui.value.filter.copy(actor = null))
            waitFor { itemRequests().size == 3 && !vm.ui.value.loading }
            assertNull(itemRequests().last().queryParameter("actor"))
            assertTrue(vm.ui.value.filter.isEmpty())
            assertTrue(vm.ui.value.items.size >= narrowed)
            if (backendUrl == null) assertEquals(wall.size, vm.ui.value.items.size)
        }
    }

    @Test fun `plain library route sends no actor`() = runTest {
        withWall(mapOf("libraryId" to "$libraryId", "name" to "本地库")) { vm ->
            assertNull(vm.ui.value.filter.actor)
            assertNull(itemRequests().single().queryParameter("actor"))
        }
    }

    @Test fun `blank actor in the route is ignored`() = runTest {
        withWall(mapOf("libraryId" to "$libraryId", "actor" to "  ")) { vm ->
            assertTrue(vm.ui.value.filter.isEmpty())
            assertNull(itemRequests().single().queryParameter("actor"))
        }
    }
}
