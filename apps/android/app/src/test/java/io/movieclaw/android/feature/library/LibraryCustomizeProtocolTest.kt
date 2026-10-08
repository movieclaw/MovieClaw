package io.movieclaw.android.feature.library

import android.app.Application
import androidx.lifecycle.ViewModelStore
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.*
import io.movieclaw.android.core.session.*
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** 页面加载 → 另一客户端修改 → Android 编辑/保存 → 另一客户端读取。 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [28])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class LibraryCustomizeProtocolTest {
    private val json = NetworkModule.json()
    private val puts = AtomicInteger()
    @Volatile private var prefs = json.parseToJsonElement("""{"theme":"silver","home":{"rows":[]}}""")
    @Volatile private var failRead = false
    private lateinit var server: MockWebServer
    private val http = OkHttpClient()
    // 本地端到端验证可连接隔离的真实后端；CI 默认用内存服务验证整条页面请求链。
    private val backendUrl = System.getProperty("movieclaw.test.api")
    private val backendToken = System.getProperty("movieclaw.test.token")

    private fun TestScope.waitFor(predicate: () -> Boolean) {
        repeat(200) {
            runCurrent()
            if (predicate()) return
            Thread.sleep(10)
        }
        fail("Timed out waiting for homepage save")
    }

    private fun peer(method: String, body: JsonElement? = null): JsonObject {
        val request = Request.Builder().url(server.url("/api/v1/ui/preferences"))
            .method(method, body?.toString()?.toRequestBody("application/json".toMediaType()))
            .build()
        return http.newCall(request).execute().use {
            assertTrue(it.isSuccessful)
            json.parseToJsonElement(it.body!!.string()).jsonObject["data"]!!.jsonObject
        }
    }

    private suspend fun TestScope.withEditor(block: suspend TestScope.(LibraryCustomizeViewModel) -> Unit) {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.path == "/api/v1/ui/preferences" && request.method == "GET" && failRead) {
                    return MockResponse().setResponseCode(503)
                }
                if (backendUrl != null) {
                    val body = if (request.method == "PUT") request.body.readUtf8()
                        .toRequestBody("application/json".toMediaType()) else null
                    val forwarded = Request.Builder().url(backendUrl + request.path)
                        .header("Authorization", "Bearer $backendToken")
                        .method(request.method!!, body).build()
                    return http.newCall(forwarded).execute().use {
                        if (request.method == "PUT") puts.incrementAndGet()
                        MockResponse().setResponseCode(it.code).setBody(it.body!!.string())
                    }
                }
                if (request.path == "/api/v1/libraries" || request.path == "/api/v1/collections") {
                    return MockResponse().setBody("""{"success":true,"data":[]}""")
                }
                if (request.path == "/api/v1/ui/preferences") {
                    if (request.method == "GET" && failRead) return MockResponse().setResponseCode(503)
                    if (request.method == "PUT") {
                        prefs = json.parseToJsonElement(request.body.readUtf8())
                        puts.incrementAndGet()
                    }
                    return MockResponse().setBody("""{"success":true,"data":$prefs}""")
                }
                return MockResponse().setResponseCode(404)
            }
        }
        server.start()
        if (backendUrl != null) peer("PUT", prefs)
        val context = RuntimeEnvironment.getApplication()
        val vault = TokenVault(context)
        val cookies = ShareCookieJar()
        val factory = ApiFactory(json, http, http, vault, cookies)
        val repository = SessionRepository(context, json, vault, factory, http,
            SessionCacheCleaner(context, ImageLoaders(context, vault, http, cookies), LibraryHomeSnapshotStore(context, json)))
        val origin = server.url("/").toString().trimEnd('/')
        vault.activate(origin, "alice", "token")
        @Suppress("UNCHECKED_CAST")
        val state = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
            .get(repository) as MutableStateFlow<SessionUi>
        state.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = SessionView("alice"))
        val vm = LibraryCustomizeViewModel(factory, repository)
        val store = ViewModelStore().also { it.put("editor", vm) }
        try {
            waitFor { !vm.ui.value.loading }
            assertFalse(vm.ui.value.loadFailed)
            block(vm)
        } finally {
            store.clear()
            server.shutdown()
            Dispatchers.resetMain()
        }
    }

    @Test fun `saving preserves type rows and the other clients latest preferences`() = runTest {
        val types = json.parseToJsonElement("""[{"id":"kind:movie","sort":"rating","unwatched":true},{"id":"row:tv","media_kind":"tv","name":"今晚追哪部","hidden":true}]""")
        prefs = buildJsonObject {
            put("theme", "silver")
            put("home", buildJsonObject { put("rows", types) })
        }
        withEditor { vm ->
            val changed = buildJsonObject {
                peer("GET").forEach { (key, value) -> put(key, value) }
                put("theme_mobile", "netflix")
                put("nav", buildJsonObject { put("order", buildJsonArray { add("library"); add("discover") }) })
            }
            peer("PUT", changed)
            val before = puts.get()
            vm.update("libraries") { it.copy(hidden = true) }
            vm.flush()
            waitFor { puts.get() > before && !vm.ui.value.saving }
            val saved = peer("GET")
            assertEquals(changed["theme_mobile"], saved["theme_mobile"])
            assertEquals(changed["nav"], saved["nav"])
            val rows = saved["home"]!!.jsonObject["rows"]!!.jsonArray
            types.jsonArray.forEachIndexed { index, original ->
                original.jsonObject.forEach { (key, value) -> assertEquals(value, rows[index].jsonObject[key]) }
            }
            assertTrue(rows.single { it.jsonObject["id"]!!.jsonPrimitive.content == "libraries" }
                .jsonObject["hidden"]!!.jsonPrimitive.boolean)
        }
    }

    @Test fun `reset explicitly clears unsupported rows but preserves latest theme`() = runTest {
        prefs = json.parseToJsonElement("""{"theme":"silver","home":{"rows":[{"id":"row:tv","media_kind":"tv"}]}}""")
        withEditor { vm ->
            peer("PUT", buildJsonObject {
                peer("GET").forEach { (key, value) -> put(key, value) }
                put("theme_desktop", "netflix")
            })
            val before = puts.get()
            vm.restoreDefaults()
            waitFor { puts.get() > before && !vm.ui.value.saving }
            val saved = peer("GET")
            assertEquals("netflix", saved["theme_desktop"]!!.jsonPrimitive.content)
            assertTrue(saved["home"]!!.jsonObject["rows"]!!.jsonArray.isEmpty())
        }
    }

    @Test fun `failed refresh does not overwrite server preferences`() = runTest {
        withEditor { vm ->
            val before = puts.get()
            failRead = true
            vm.update("libraries") { it.copy(hidden = true) }
            vm.flush()
            waitFor { vm.ui.value.saveError != null && !vm.ui.value.saving }
            assertEquals(before, puts.get())
        }
    }
}
