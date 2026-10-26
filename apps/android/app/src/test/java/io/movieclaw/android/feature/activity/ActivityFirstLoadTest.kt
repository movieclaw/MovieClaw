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

/**
 * 「进行中 · 查看全部」是新开的 ViewModel：下载任务必须一进页就拉，不能等第一个 10 秒轮询周期
 * （用户报：总览「进行中 · 5」，点进去「当前没有进行中的任务」）。
 * 只推进真实时间、不推进虚拟时钟：若仍是「先等再拉」，这里永远拿不到。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class, kotlinx.serialization.ExperimentalSerializationApi::class)
class ActivityFirstLoadTest {
    @Test fun freshViewModelLoadsDownloadTasksImmediately() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl!!.encodedPath
                return when {
                    path.endsWith("/downloaders/tasks") -> MockResponse().setBody(
                        """{"success":true,"data":{"items":[{"id":"t1","info_hash":"abc","name":"吞噬星空","progress":0.03,"state":"downloading"}]}}""",
                    )
                    path.endsWith("/jobs") -> MockResponse().setBody("""{"success":true,"data":{"items":[]}}""")
                    path.endsWith("/playback/activity") -> MockResponse().setBody("""{"success":true,"data":{"sessions":[],"downloads":[]}}""")
                    else -> MockResponse().setResponseCode(403).setBody("{}")
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
            SessionCacheCleaner(context, ImageLoaders(context, vault, client, cookies), LibraryHomeSnapshotStore(context, json)),
            dagger.Lazy { throw UnsupportedOperationException() })
        val origin = server.url("/").toString().trimEnd('/')
        vault.activate(origin, "alice", "token")
        @Suppress("UNCHECKED_CAST")
        val ui = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
            .get(repository) as MutableStateFlow<SessionUi>
        ui.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = SessionView("alice"))
        val vm = ActivityViewModel(api, EventStream(client, repository, api), repository, json, PlaybackDataEvents())
        try {
            repeat(200) {
                runCurrent()
                if (vm.ui.value.downloads.isNotEmpty()) return@repeat
                Thread.sleep(10)
            }
            assertEquals(listOf("t1"), vm.ui.value.downloads.map { it.id })
            assertEquals(1, deriveTaskActivity(vm.ui.value.downloads, vm.ui.value.jobs).activeTotal)
        } finally {
            androidx.lifecycle.ViewModelStore().apply { put("activity", vm); clear() }
            runCurrent()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }
}
