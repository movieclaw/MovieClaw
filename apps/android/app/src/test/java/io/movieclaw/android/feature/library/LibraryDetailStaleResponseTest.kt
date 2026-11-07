package io.movieclaw.android.feature.library

import android.app.Application
import android.os.Looper
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModelStore
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.model.LibraryIndexEntry
import io.movieclaw.android.core.model.LibraryFilter
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.*
import io.movieclaw.android.core.session.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
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
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * 慢的旧筛选响应不能盖掉已经显示的新筛选。
 * 服务端按调用顺序卡住，测试决定哪一次先返回。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [28])
@OptIn(ExperimentalCoroutinesApi::class)
class LibraryDetailStaleResponseTest {
    private lateinit var server: MockWebServer
    private lateinit var gate: HoldGate

    @Test fun `slow reload and index do not overwrite a newer filter`() = runLibrary {
        gate.hold("index:unfinished")
        val vm = newModel("unfinished")
        assertTrue(gate.await("index:unfinished"))
        gate.hold("items:unfinished:0")
        vm.reload()
        assertTrue(gate.await("items:unfinished:0"))
        vm.applyFilter(LibraryFilter(sort = "title"))
        waitFor { vm.ui.value.items.singleOrNull()?.title == "All" && vm.index.value.singleOrNull()?.initial == "A" }
        gate.release("items:unfinished:0")
        gate.release("index:unfinished")
        settle()
        assertEquals(listOf("All"), vm.ui.value.items.map { it.title })
        assertEquals(listOf("A"), vm.index.value.map { it.initial })
        assertNull(vm.ui.value.error)
    }

    @Test fun `old index cannot jump while the new index is loading`() = runLibrary {
        val vm = newModel("unfinished")
        waitFor { vm.index.value.singleOrNull()?.initial == "U" }
        gate.hold("index:all")
        vm.applyFilter(LibraryFilter(sort = "title"))
        assertTrue(gate.await("index:all"))
        waitFor { vm.ui.value.items.singleOrNull()?.title == "All" && !vm.ui.value.loading }

        assertTrue(vm.index.value.isEmpty())
        vm.index.value.firstOrNull()?.let(vm::jumpTo)
        settle()
        assertEquals(listOf("All"), vm.ui.value.items.map { it.title })
        assertEquals(0, vm.ui.value.windowStart)

        gate.release("index:all")
        waitFor { vm.index.value.singleOrNull()?.initial == "A" }
    }

    @Test fun `slow load more is not appended onto the new filter`() = runLibrary {
        gate.wide = true
        val vm = newModel("unfinished")
        waitFor { vm.ui.value.items.size == 60 && !vm.ui.value.loading }
        gate.hold("items:unfinished:60")
        vm.loadMore()
        assertTrue(gate.await("items:unfinished:60"))
        vm.applyFilter(LibraryFilter(sort = "title"))
        waitFor { vm.ui.value.items.singleOrNull()?.title == "All" }
        gate.release("items:unfinished:60")
        settle()
        assertEquals(listOf("All"), vm.ui.value.items.map { it.title })
        assertFalse(vm.ui.value.loadingMore)
    }

    @Test fun `slow letter jump does not overwrite a newer filter`() = runLibrary {
        val vm = newModel("unfinished")
        waitFor { vm.ui.value.items.singleOrNull()?.title == "Unfinished" && !vm.ui.value.loading }
        gate.hold("items:unfinished:40")
        vm.jumpTo(LibraryIndexEntry(initial = "U", offset = 40))
        assertTrue(gate.await("items:unfinished:40"))
        vm.applyFilter(LibraryFilter(sort = "title"))
        waitFor { vm.ui.value.items.singleOrNull()?.title == "All" }
        gate.release("items:unfinished:40")
        settle()
        assertEquals(listOf("All"), vm.ui.value.items.map { it.title })
        assertEquals(0, vm.ui.value.windowStart)
    }

    private fun newModel(watch: String): LibraryDetailViewModel {
        val context = RuntimeEnvironment.getApplication()
        val json = NetworkModule.json()
        val http = OkHttpClient()
        val vault = TokenVault(context)
        val cookies = ShareCookieJar()
        val factory = ApiFactory(json, http, http, vault, cookies)
        val repository = SessionRepository(
            context, json, vault, factory, http,
            SessionCacheCleaner(context, ImageLoaders(context, vault, http, cookies), LibraryHomeSnapshotStore(context, json)),
            dagger.Lazy { throw UnsupportedOperationException() },
        )
        val origin = server.url("/").toString().trimEnd('/')
        vault.activate(origin, "alice", "token")
        @Suppress("UNCHECKED_CAST")
        val state = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
            .get(repository) as MutableStateFlow<SessionUi>
        state.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = SessionView("alice"))
        return LibraryDetailViewModel(SavedStateHandle(mapOf("libraryId" to "7", "w" to watch, "sort" to "title")), repository, factory)
    }

    private fun runLibrary(block: () -> Unit) {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        server = MockWebServer()
        gate = HoldGate()
        server.dispatcher = gate
        server.start()
        val store = ViewModelStore()
        try {
            block()
            shadowOf(Looper.getMainLooper()).idle()
        } finally {
            gate.releaseAll()
            store.clear()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }

    private fun waitFor(predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            if (predicate()) return
            Thread.sleep(15)
        }
        fail("timed out waiting for the newer library response")
    }

    private fun settle() {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(400)
        while (System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(20)
        }
    }

    private class HoldGate : Dispatcher() {
        var wide = false
        private val holds = ConcurrentHashMap<String, CountDownLatch>()
        private val seen = ConcurrentHashMap<String, CountDownLatch>()

        fun hold(key: String) {
            holds[key] = CountDownLatch(1)
            seen[key] = CountDownLatch(1)
        }

        fun await(key: String): Boolean = seen[key]!!.await(5, TimeUnit.SECONDS)

        fun release(key: String) {
            holds[key]?.countDown()
        }

        fun releaseAll() {
            holds.values.forEach { it.countDown() }
        }

        override fun dispatch(request: RecordedRequest): MockResponse {
            val path = request.path.orEmpty()
            val key = requestKey(path)
            seen[key]?.countDown()
            holds[key]?.await(8, TimeUnit.SECONDS)
            val watch = watchOf(path)
            val offset = offsetOf(path)
            val body = when {
                path.contains("item-index") -> """{"success":true,"data":[{"initial":"${initialOf(watch)}","count":1,"offset":${indexOffsetOf(watch)}}]}"""
                path.contains("/items") && offset == 60 -> items("Late", 1, 1000)
                path.contains("/items") && offset == 40 -> items("Jump", 1, 2000)
                path.contains("/items") && watch == "unfinished" -> items("Unfinished", if (wide && offset == 0) 60 else 1, 1)
                path.contains("/items") -> items("All", 1, 3000)
                else -> """{"success":true,"data":[]}"""
            }
            return MockResponse().setBody(body)
        }

        private fun requestKey(path: String): String {
            val kind = if (path.contains("item-index")) "index" else if (path.contains("/items")) "items" else "other"
            val offset = if (kind == "items") offsetOf(path).toString() else ""
            return "$kind:${watchOf(path)}:$offset".trimEnd(':').let { if (kind == "index") "index:${watchOf(path)}" else it }
        }

        private fun watchOf(path: String): String =
            Regex("""[?&]w=([^&]*)""").find(path)?.groupValues?.get(1) ?: "all"

        private fun offsetOf(path: String): Int =
            Regex("""[?&]offset=(\d+)""").find(path)?.groupValues?.get(1)?.toInt() ?: 0

        private fun initialOf(watch: String): String = if (watch == "unfinished") "U" else "A"

        private fun indexOffsetOf(watch: String): Int = if (watch == "unfinished") 40 else 0

        private fun items(title: String, count: Int, idBase: Long): String {
            val rows = (0 until count).joinToString(",") { index ->
                """{"media_item_id":${idBase + index},"title":"$title${if (count == 1) "" else index}"}"""
            }
            return """{"success":true,"data":[$rows]}"""
        }
    }
}
