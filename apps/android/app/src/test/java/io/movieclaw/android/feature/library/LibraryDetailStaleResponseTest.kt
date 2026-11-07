package io.movieclaw.android.feature.library

import androidx.lifecycle.SavedStateHandle
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.ShareCookieJar
import io.movieclaw.android.core.session.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * PR #1205 维护者 P1：从首页带「未看完」进库详情再切回「全部」时，慢的旧请求（列表、分页、A–Z 索引）
 * 晚到不能覆盖新条件的结果，旧筛选的下一页也不能拼到新列表后面。
 * 用真实 HTTP（MockWebServer）把旧请求卡住，等新请求落地后再放行，断言界面仍是新条件。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class, kotlinx.serialization.ExperimentalSerializationApi::class)
class LibraryDetailStaleResponseTest {
    private val server = MockWebServer()
    private val release = CountDownLatch(1)
    /** 被卡住的旧请求已真正发到服务端（否则放行前它可能还没出门，测不到竞态） */
    private val heldArrived = CountDownLatch(1)
    private lateinit var api: ApiFactory
    private lateinit var repository: SessionRepository

    private fun items(prefix: String, count: Int, startId: Int = 0) = (0 until count).joinToString(",") {
        """{"media_item_id":${startId + it},"title":"$prefix ${startId + it}"}"""
    }

    private fun ok(data: String) = MockResponse().setBody("""{"success":true,"data":$data}""")

    private fun held(response: MockResponse): MockResponse {
        heldArrived.countDown()
        release.await(10, TimeUnit.SECONDS)
        return response
    }

    @Before fun setUp() {
        val context = RuntimeEnvironment.getApplication()
        val json = Json { ignoreUnknownKeys = true; namingStrategy = JsonNamingStrategy.SnakeCase }
        val client = OkHttpClient()
        val vault = TokenVault(context)
        val cookies = ShareCookieJar()
        api = ApiFactory(json, client, client, vault, cookies)
        repository = SessionRepository(context, json, vault, api, client,
            SessionCacheCleaner(context, ImageLoaders(context, vault, client, cookies), LibraryHomeSnapshotStore(context, json)),
            dagger.Lazy { throw UnsupportedOperationException() })
    }

    @After fun tearDown() {
        release.countDown()
        server.shutdown()
        Dispatchers.resetMain()
    }

    private fun startServer(dispatch: (path: String, watch: String?, offset: Int) -> MockResponse): String {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val url = request.requestUrl!!
                return dispatch(url.encodedPath, url.queryParameter("w"), url.queryParameter("offset")?.toInt() ?: 0)
            }
        }
        server.start()
        val origin = server.url("/").toString().trimEnd('/')
        TokenVault(RuntimeEnvironment.getApplication()).activate(origin, "alice", "token")
        @Suppress("UNCHECKED_CAST")
        val ui = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
            .get(repository) as MutableStateFlow<SessionUi>
        ui.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = SessionView("alice"))
        return origin
    }

    private fun TestScope.pumpUntil(condition: () -> Boolean) {
        repeat(300) {
            runCurrent()
            if (condition()) return
            Thread.sleep(10)
        }
    }

    /** 真实网络回调回到主线程需要时间：放行后再多泵一会儿，确认旧响应不会「晚一点再盖上来」 */
    private fun TestScope.pumpFor(millis: Long) {
        val end = System.currentTimeMillis() + millis
        while (System.currentTimeMillis() < end) { runCurrent(); Thread.sleep(10) }
    }

    @Test fun clearingUnfinishedFilterIgnoresLateUnfinishedPageAndIndex() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        startServer { path, watch, _ ->
            when {
                path.endsWith("/items") && watch == "unfinished" -> held(ok("[${items("未看完", 2)}]"))
                path.endsWith("/items") -> ok("[${items("全部", 3, startId = 100)}]")
                path.endsWith("/item-index") && watch == "unfinished" -> held(ok("""[{"initial":"W","count":2,"offset":0}]"""))
                path.endsWith("/item-index") -> ok("""[{"initial":"A","count":1,"offset":0},{"initial":"Q","count":2,"offset":1}]""")
                else -> MockResponse().setResponseCode(404).setBody("{}")
            }
        }
        val vm = LibraryDetailViewModel(SavedStateHandle(mapOf("libraryId" to "7", "w" to "unfinished")), repository, api)
        try {
            assertEquals(setOf("unfinished"), vm.ui.value.filter.watch)
            pumpUntil { heldArrived.count == 0L }
            vm.clearFilter()
            pumpUntil { !vm.ui.value.loading && vm.index.value.isNotEmpty() }
            assertEquals((100..102).toList(), vm.ui.value.items.map { it.mediaItemId.toInt() })

            release.countDown()
            pumpFor(400)
            assertTrue(vm.ui.value.filter.watch.isEmpty())
            assertEquals("迟到的「未看完」第一页不能盖回列表", (100..102).toList(), vm.ui.value.items.map { it.mediaItemId.toInt() })
            assertEquals("迟到的「未看完」索引不能覆盖 A–Z", listOf("A", "Q"), vm.index.value.map { it.initial })
            assertNull(vm.ui.value.error)
        } finally {
            androidx.lifecycle.ViewModelStore().apply { put("detail", vm); clear() }
            runCurrent()
        }
    }

    /** 切筛选后、新一页的协程还没开跑的空隙里触底：不能按旧列表长度去取新条件的下一页 */
    @Test fun loadMoreRightAfterFilterChangeDoesNotRequestStaleOffset() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val offsets = java.util.concurrent.CopyOnWriteArrayList<Pair<String?, Int>>()
        startServer { path, watch, offset ->
            when {
                path.endsWith("/items") -> {
                    offsets += watch to offset
                    if (watch == null) ok("[${items("全部", 60)}]") else ok("[${items("未看完", 2, startId = 500)}]")
                }
                path.endsWith("/item-index") -> ok("[]")
                else -> MockResponse().setResponseCode(404).setBody("{}")
            }
        }
        val vm = LibraryDetailViewModel(SavedStateHandle(mapOf("libraryId" to "7")), repository, api)
        try {
            pumpUntil { !vm.ui.value.loading && vm.ui.value.items.size == 60 }
            vm.applyFilter(vm.ui.value.filter.copy(watch = setOf("unfinished")))
            vm.loadMore() // 同一帧内触底，新一页的协程尚未执行
            pumpUntil { !vm.ui.value.loading && vm.ui.value.items.map { it.mediaItemId } == listOf(500L, 501L) }
            pumpFor(300)
            assertEquals(listOf<Pair<String?, Int>>(null to 0, "unfinished" to 0), offsets.toList())
            assertEquals(listOf(500L, 501L), vm.ui.value.items.map { it.mediaItemId })
        } finally {
            androidx.lifecycle.ViewModelStore().apply { put("detail", vm); clear() }
            runCurrent()
        }
    }

    @Test fun lateNextPageOfOldFilterIsNotAppendedToNewFilter() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        startServer { path, watch, offset ->
            when {
                path.endsWith("/items") && watch == null && offset == 0 -> ok("[${items("全部", 60)}]")
                path.endsWith("/items") && watch == null -> held(ok("[${items("全部", 5, startId = offset)}]"))
                path.endsWith("/items") && watch == "unfinished" -> ok("[${items("未看完", 2, startId = 500)}]")
                path.endsWith("/item-index") -> ok("[]")
                else -> MockResponse().setResponseCode(404).setBody("{}")
            }
        }
        val vm = LibraryDetailViewModel(SavedStateHandle(mapOf("libraryId" to "7")), repository, api)
        try {
            pumpUntil { !vm.ui.value.loading && vm.ui.value.items.size == 60 }
            assertTrue(vm.ui.value.hasMore)
            vm.loadMore()
            pumpUntil { heldArrived.count == 0L }
            vm.applyFilter(vm.ui.value.filter.copy(watch = setOf("unfinished")))
            pumpUntil { !vm.ui.value.loading && vm.ui.value.items.map { it.mediaItemId } == listOf(500L, 501L) }

            release.countDown()
            pumpFor(400)
            assertEquals("旧筛选的下一页不能拼到「未看完」后面", listOf(500L, 501L), vm.ui.value.items.map { it.mediaItemId })
            assertFalse(vm.ui.value.loadingMore)
        } finally {
            androidx.lifecycle.ViewModelStore().apply { put("detail", vm); clear() }
            runCurrent()
        }
    }
}
